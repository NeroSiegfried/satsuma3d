/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Renders the image or animation with a native sheet instead of Blender's render window: live
 * progress, then the result, kept with every earlier render in a film strip to look back at and
 * share. The scene's Output is honoured: an animation in an image format is kept as its frames, one
 * in a movie format becomes that movie, written by Blender's FFmpeg; frames are kept as they finish,
 * whatever ends the render. A render goes on in the background as a continued processing task,
 * with the system's progress, so leaving the app doesn't end it. Blender renders through
 * `bl_ui.native_render`; its state arrives in the toolbar snapshot.
 */

import AVFoundation
import AVKit
#if os(iOS)
import BackgroundTasks
#endif
import CryptoKit
import ImageIO
import SwiftUI
import UIKit

/** A render started from here, from Blender's `render` view, see `bridge_render_view_build`. */
@MainActor
enum BlenderRender {
  static let view = NativeViews.shared.subscribe("render")

  /** `cancel` the render, or `clear` its state. */
  static func run(_ action: String) { NativeViews.shared.send(view, target: action, op: .invoke) }

  /**
   * Start work that writes into `folder` (R6 BUSY-3): `image`, `animation`, `continue` (the frames
   * still missing from the animation in `folder`) or `video` (of the frames in `folder`). Its
   * number, to read whether Blender took it, see `NativeViews.outcome(of:)`.
   */
  static func start(_ verb: String, folder: URL) -> UInt32 {
    NativeViews.shared.send(view, target: verb + ":" + folder.path, op: .invoke, answer: true)
  }

  static var status: RenderStatus {
    var values: [String: Blender_NativeUI_Data] = [:]
    if let top = view.top {
      for node in view.children(of: top) where node.key.hasPrefix("state:") {
        if let data = node.content(Blender_NativeUI_Data.self) { values[String(node.key.dropFirst(6))] = data }
      }
    }
    return RenderStatus(values: values)
  }
}

/** The render's state, as `bl_ui.native_render.status` names its values. */
struct RenderStatus {
  let values: [String: Blender_NativeUI_Data]

  func string(_ key: String) -> String? { values[key]?.value(type: Blender_NativeUI_TextValue.self)?.value }
  func double(_ key: String) -> Double? { values[key]?.value(type: Blender_NativeUI_FloatValue.self)?.value }
  func int(_ key: String) -> Int { Int(double(key) ?? 0) }
  func bool(_ key: String) -> Bool { (double(key) ?? 0) != 0 }
  func strings(_ key: String) -> [String] {
    guard let texts = values[key]?.value(type: Blender_NativeUI_TextsValue.self) else { return [] }
    return (0..<texts.valueCount).compactMap { texts.value(at: $0) }
  }
}

/* -------------------------------------------------------------------- */
/** \name Render library
 *
 * Every render of a project, kept on disk in the app's Application Support folder, so none is lost
 * when the sheet closes, the next render starts or the app quits. Each project has its own folder,
 * found by the document's location. An animation's frames are written straight into a folder of
 * the library as they finish, and are listed from the start: a render that is stopped, ended by
 * the system, or killed with the app keeps every frame it finished, and can be continued or made a
 * video of (R6 BUSY-3, G5, D3).
 * \{ */

struct RenderItem: Codable, Identifiable, Hashable {
  let id: String
  /** The image or video, by path in the library folder; for an animation's frames, their folder. */
  var file: String
  /** The image shown: a video's still, the first of an animation's frames, or a still's PNG when
   * its own format is not one the iPad shows. */
  var poster: String?
  let video: Bool
  let date: Date
  var width: Int
  var height: Int
  /** Frames rendered. */
  var frames: Int
  /** `frames` for an animation kept as its frames. */
  var kind: String?
  /** How many frames the animation has, and the first still missing (0 once none is). */
  var total: Int?
  var next: Int?
  /** The frames' extension, and whether the scene's Output was a movie to be made of them. */
  var ext: String?
  var movie: Bool?
  /** A folder of the library's holding this render's files, removed with it. */
  var folder: String?

  var isFrames: Bool { kind == "frames" }
  /** Frames of an animation that stopped before its end. */
  var stopped: Bool { isFrames && (next ?? 0) > 0 }
  /** A video the iPad plays; others play in other apps. */
  var playable: Bool { ["mp4", "mov", "m4v"].contains((file as NSString).pathExtension.lowercased()) }

  var framesSummary: String {
    let format = (ext ?? "").dropFirst().uppercased()
    if stopped { return "\(frames) of \(total ?? frames) frames rendered" }
    return format.isEmpty ? "\(frames) frames" : "\(frames) frames, \(format)"
  }
}

@MainActor
final class RenderLibrary: ObservableObject {
  private static var libraries: [String: RenderLibrary] = [:]

  /** The renders of the document at `url`; renders of an unsaved scene share one library. */
  static func forDocument(_ url: URL?) -> RenderLibrary {
    let path = url?.standardizedFileURL.resolvingSymlinksInPath().path ?? ""
    let key = path.isEmpty ? "Unsaved" :
      SHA256.hash(data: Data(path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    if let library = libraries[key] { return library }
    let library = RenderLibrary(key: key)
    libraries[key] = library
    return library
  }

  /** Oldest first, as a film strip reads. */
  @Published private(set) var items: [RenderItem] = []
  let folder: URL
  private var index: URL { folder.appendingPathComponent("Renders.json") }

  private init(key: String) {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    folder = support.appendingPathComponent("Renders", isDirectory: true)
      .appendingPathComponent(key, isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if let data = try? Data(contentsOf: index),
       let stored = try? JSONDecoder().decode([RenderItem].self, from: data)
    {
      /* Frames are counted again from what Blender listed as written: the app may have been
       * killed after the index was last saved. Frames of which none was finished are not kept. */
      var kept: [RenderItem] = []
      for item in stored where FileManager.default.fileExists(atPath: url(item).path) {
        guard item.isFrames else {
          kept.append(item)
          continue
        }
        let refreshed = counted(item)
        if refreshed.frames > 0 { kept.append(refreshed) }
        else { try? FileManager.default.removeItem(at: url(item)) }
      }
      items = kept
      if kept != stored { save() }
    }
  }

  func url(_ item: RenderItem) -> URL { folder.appendingPathComponent(item.file) }

  /** The image shown for an item: a still, a video's still or the first frame. */
  func still(_ item: RenderItem) -> URL? {
    if let poster = item.poster { return folder.appendingPathComponent(poster) }
    return item.video || item.isFrames ? nil : url(item)
  }

  /** A path of the library's, as kept in the index; nil for one outside it. */
  func relative(_ path: String) -> String? {
    let base = folder.standardizedFileURL.path + "/"
    let full = URL(fileURLWithPath: path).standardizedFileURL.path
    return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : nil
  }

  /** A new folder for a render's files. */
  func makeFolder(_ id: String) -> URL {
    let url = folder.appendingPathComponent(id, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /** The frames an animation's folder lists as written whole (`Render.json`, written by
   * `bl_ui.native_render`), how many it wants and the first missing. */
  private func counted(_ item: RenderItem) -> RenderItem {
    var item = item
    guard let data = try? Data(contentsOf: url(item).appendingPathComponent("Render.json")),
          let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return item }
    let frames = manifest["frames"] as? [String: String] ?? [:]
    let numbers = frames.keys.compactMap(Int.init).sorted()
    let wanted = manifest["wanted"] as? [Int] ?? []
    let have = Set(numbers)
    item.frames = numbers.count
    item.total = wanted.count
    item.next = wanted.first { !have.contains($0) } ?? 0
    item.ext = manifest["ext"] as? String ?? item.ext
    item.movie = manifest["movie"] as? Bool ?? item.movie
    if item.poster == nil, let first = numbers.first, let name = frames[String(first)] {
      item.poster = item.file + "/" + name
    }
    return item
  }

  private func pixelSize(_ url: URL) -> (Int, Int) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return (0, 0) }
    return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
  }

  /** Keep a still Blender saved in the render's `folder` (as the scene's format names it), with
   * the PNG shown for it when the iPad cannot show that format. */
  func addImage(id: String, folder: URL, image: String, preview: String?) -> RenderItem? {
    guard let file = relative(image), FileManager.default.fileExists(atPath: image) else { return nil }
    let poster = preview.flatMap { $0.isEmpty ? nil : relative($0) }
    let (width, height) = pixelSize(self.folder.appendingPathComponent(poster ?? file))
    return append(RenderItem(id: id, file: file, poster: poster, video: false, date: .now, width: width,
                             height: height, frames: 1, folder: relative(folder.path)))
  }

  /** List an animation's frames as it starts: its folder, already in the library. */
  func addFrames(id: String, folder: URL) -> RenderItem? {
    guard let file = relative(folder.path) else { return nil }
    return append(RenderItem(id: id, file: file, poster: nil, video: false, date: .now, width: 0, height: 0,
                             frames: 0, kind: "frames", total: nil, next: nil, folder: file))
  }

  /** Change an item, keeping the index on disk up to date. */
  func update(_ id: String, _ change: (inout RenderItem) -> Void) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    var item = items[index]
    change(&item)
    guard item != items[index] else { return }
    items[index] = item
    save()
  }

  /** The frames an animation has now, as the render reports them. */
  func updateFrames(_ id: String, status: RenderStatus) {
    update(id) { item in
      item.frames = status.int("done")
      if status.double("total") != nil { item.total = status.int("total") }
      if status.double("next") != nil { item.next = status.int("next") }
      if let ext = status.string("ext") { item.ext = ext }
      if status.double("movie") != nil { item.movie = status.bool("movie") }
      if item.poster == nil, let first = status.strings("frames").first ?? status.string("last"),
         let poster = relative(first)
      {
        item.poster = poster
        (item.width, item.height) = pixelSize(self.folder.appendingPathComponent(poster))
      }
    }
  }

  /** Keep a video Blender wrote, moving it into the library. */
  func addVideo(_ video: URL, poster: String?, frames: Int) -> RenderItem? {
    let id = UUID().uuidString
    let file = id + "." + video.pathExtension
    guard (try? FileManager.default.moveItem(at: video, to: folder.appendingPathComponent(file))) != nil else { return nil }
    var still: String?
    if let poster {
      let name = id + "." + URL(fileURLWithPath: poster).pathExtension
      if (try? FileManager.default.copyItem(at: URL(fileURLWithPath: poster), to: folder.appendingPathComponent(name))) != nil {
        still = name
      }
    }
    let (width, height) = still.map { pixelSize(folder.appendingPathComponent($0)) } ?? (0, 0)
    return append(RenderItem(id: id, file: file, poster: still, video: true, date: .now, width: width,
                             height: height, frames: frames))
  }

  private func append(_ item: RenderItem) -> RenderItem {
    withMotion { items.append(item) }
    save()
    return item
  }

  func remove(_ item: RenderItem) {
    try? FileManager.default.removeItem(at: url(item))
    if let poster = item.poster { try? FileManager.default.removeItem(at: folder.appendingPathComponent(poster)) }
    if let own = item.folder { try? FileManager.default.removeItem(at: folder.appendingPathComponent(own)) }
    withMotion { items.removeAll { $0.id == item.id } }
    save()
  }

  /** A copy of an animation's frames alone, in a folder named for them, to save to Files. */
  func framesCopy(_ item: RenderItem, name: String) -> URL? {
    let source = url(item)
    let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent(name, isDirectory: true)
    guard (try? FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)) != nil,
          let names = try? FileManager.default.contentsOfDirectory(atPath: source.path) else { return nil }
    for frame in names where frame.hasPrefix("Frame ") {
      /* A clone on APFS: no space until either changes. */
      guard (try? FileManager.default.copyItem(at: source.appendingPathComponent(frame),
                                               to: copy.appendingPathComponent(frame))) != nil else { return nil }
    }
    return copy
  }

  private func save() {
    if let data = try? JSONEncoder().encode(items) { try? data.write(to: index, options: .atomic) }
  }
}

/** Small images for the film strip, decoded off the main thread. */
enum RenderThumbnails {
  private static let cache = NSCache<NSURL, UIImage>()

  static func load(_ url: URL, size: CGFloat) async -> UIImage? {
    if let cached = cache.object(forKey: url as NSURL) { return cached }
    let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceThumbnailMaxPixelSize: size,
              kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
      else { return nil }
      return UIImage(cgImage: cg)
    }.value
    if let image { cache.setObject(image, forKey: url as NSURL) }
    return image
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Background rendering
 *
 * A render is a continued processing task: iOS keeps the app running when it leaves the
 * foreground and shows the render's progress, as for a video export. Blender's loop keeps running
 * meanwhile, without drawing, see `GHOST_ios_engine_continue_work` — only once the task has
 * started, and for work on the GPU only when the task was granted the GPU (R6 BUSY-4, G8, see
 * `BackgroundWork.decide`). Otherwise the render pauses as the app leaves and goes on when it is
 * back, see `RenderSession.appLeft`.
 * \{ */

#if os(macOS)
/** A Mac keeps an app running in the background: nothing to ask for. */
@MainActor
final class BackgroundRender {
  static let shared = BackgroundRender()
  var expired: () -> Void = {}
  var needsGPU = true
  var taskStarted: Bool { true }
  var continues: Bool { true }
  var holding = false

  func begin(title: String) {}
  func update(title: String, subtitle: String, fraction: Double) {}
  func finish(success: Bool) {}
}
#elseif os(visionOS)
/** visionOS keeps an app running while its window is open: only Blender's loop must go on. */
@MainActor
final class BackgroundRender {
  static let shared = BackgroundRender()
  var expired: () -> Void = {}
  var needsGPU = true
  var taskStarted: Bool { true }
  var continues: Bool { true }
  var holding = false

  func begin(title: String) { GHOST_ios_engine_continue_work(true) }
  func update(title: String, subtitle: String, fraction: Double) {}
  func finish(success: Bool) { GHOST_ios_engine_continue_work(false) }
}
#else
@MainActor
final class BackgroundRender {
  static let shared = BackgroundRender()

  private let prefix = (Bundle.main.bundleIdentifier ?? "org.blender") + ".render"
  private var registered = false
  private var task: BGContinuedProcessingTask?
  private var pending: String?
  /** Whether the request waiting to start asked for the GPU, and whether the started one did. */
  private var pendingGPU = false
  private var gpuGranted = false
  private var title = ""
  private var subtitle = ""
  private var fraction = 0.0
  /** Called when the system ends the task, or the user stops it from the system's progress. */
  var expired: () -> Void = {}
  /** The work renders on the GPU, as Blender says; assumed until it has. */
  var needsGPU = true {
    didSet { if needsGPU != oldValue { apply() } }
  }
  /** Keep Blender's loop running in the background until a pause has reached it. */
  var holding = false {
    didSet { if holding != oldValue { apply() } }
  }

  /** iPadOS started the task (not merely accepted the request). */
  var taskStarted: Bool { task != nil }

  /** Whether the work may go on with the app in the background. */
  var continues: Bool {
    BackgroundWork.decide(taskStarted: task != nil, gpuGranted: gpuGranted, needsGPU: needsGPU) == .continueWork
  }

  private func apply() {
    GHOST_ios_engine_continue_work(continues || holding)
  }

  private var permitted: Bool {
    (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? [])
      .contains(prefix + ".*")
  }

  private func register() {
    guard !registered, permitted else { return }
    registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: prefix + ".*", using: .main) { task in
      MainActor.assumeIsolated { self.started(task) }
    }
  }

  func begin(title: String) {
    self.title = title
    subtitle = "Starting…"
    fraction = 0
    needsGPU = true
    gpuGranted = false
    /* Blender's loop is kept running only once the task has started, see #started. */
    apply()
    register()
    guard registered else {
      WM_native_ui_log("render", "background task not registered: the render pauses if the app leaves")
      return
    }
    let identifier = prefix + "." + UUID().uuidString
    pending = identifier
    let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
    request.strategy = .fail
    /* EEVEE and Cycles render on the GPU, which the background only allows when asked for. */
    if BGTaskScheduler.supportedResources.contains(.gpu) {
      request.requiredResources = .gpu
      do {
        try BGTaskScheduler.shared.submit(request)
        pendingGPU = true
        return
      }
      catch {
        WM_native_ui_log("render", "background task with the GPU refused: \(error.localizedDescription)")
      }
      request.requiredResources = []
    }
    do {
      try BGTaskScheduler.shared.submit(request)
      pendingGPU = false
    }
    catch {
      pending = nil
      WM_native_ui_log("render", "background task refused: \(error.localizedDescription)")
    }
  }

  private func started(_ background: BGTask) {
    guard let background = background as? BGContinuedProcessingTask else { return }
    guard background.identifier == pending else {
      background.setTaskCompleted(success: false)
      return
    }
    task = background
    gpuGranted = pendingGPU
    background.progress.totalUnitCount = 1000
    background.expirationHandler = { [weak self] in
      DispatchQueue.main.async {
        guard let self, self.task === background else { return }
        self.task = nil
        self.apply()
        self.expired()
        background.setTaskCompleted(success: false)
      }
    }
    apply()
    update(title: title, subtitle: subtitle, fraction: fraction)
  }

  func update(title: String, subtitle: String, fraction: Double) {
    let changed = title != self.title || subtitle != self.subtitle
    self.title = title
    self.subtitle = subtitle
    self.fraction = fraction
    guard let task else { return }
    task.progress.completedUnitCount = Int64((min(1, max(0, fraction)) * 1000).rounded())
    if changed { task.updateTitle(title, subtitle: subtitle) }
  }

  func finish(success: Bool) {
    pending = nil
    holding = false
    let finished = task
    task = nil
    apply()
    guard let finished else { return }
    finished.progress.completedUnitCount = finished.progress.totalUnitCount
    finished.setTaskCompleted(success: success)
  }
}

#endif

/** \} */

/* -------------------------------------------------------------------- */
/** \name Sheet
 * \{ */

@MainActor
final class RenderModel: ObservableObject {
  @Published var rendering = false
  @Published var animation = false
  /** What is being made: "Rendering Image", "Rendering Animation" or "Making Video". */
  @Published var title = ""
  @Published var progress = 0.0
  @Published var phase = ""
  @Published var remaining: String?
  /** The frame rendered last, while an animation renders. */
  @Published var live: UIImage?
  /** The render shown, or nil for the one in progress. */
  @Published var selection: String?
  /** Stop was asked for and Blender has not yet answered. */
  @Published var stopping = false
  /** What Stop would lose, when that is more than a minute of rendering: it asks first. */
  @Published var confirmStop: String?
  var started = Date.now
  /** Stop, asking first when more than a minute of rendering would be lost. */
  var stop: () -> Void = {}
  /** Stop, once asked. */
  var stopConfirmed: () -> Void = {}
  var close: () -> Void = {}
  /** An animation's kept frames (R6 BUSY-3): render the missing ones, make a video of them, or
   * save them to Files. */
  var continueFrames: (RenderItem) -> Void = { _ in }
  var makeVideo: (RenderItem) -> Void = { _ in }
  var saveFrames: (RenderItem) -> Void = { _ in }

  /** The page for the render in progress. */
  static let live = "rendering"

  /** The render shown: the one picked, else the one in progress, else the latest. */
  func current(_ library: RenderLibrary) -> String? {
    if let selection, library.items.contains(where: { $0.id == selection }) { return selection }
    return rendering ? RenderModel.live : library.items.last?.id
  }

  func select(_ id: String) {
    selection = id == RenderModel.live ? nil : id
  }
}

struct RenderSheetView: View {
  @ObservedObject var model: RenderModel
  @ObservedObject var library: RenderLibrary

  private var selected: RenderItem? {
    guard let id = model.current(library) else { return nil }
    return library.items.first { $0.id == id }
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        RenderGallery(model: model, library: library)
          .padding(.top, 8)
          .padding(.bottom, 12)
        if model.rendering {
          RenderProgressCard(model: model)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        if !library.items.isEmpty || model.rendering {
          FilmStrip(model: model, library: library)
        }
      }
      .animation(.smooth, value: model.rendering)
      .background(Color(uiColor: .systemGroupedBackground))
      .navigationTitle(model.rendering ? model.title : "Renders")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
#if !os(macOS)
        /* A Mac's window closes itself. */
        ToolbarItem(placement: .cancellationAction) {
          /* Closing keeps a render going; it lands in the film strip. */
          Button(role: .close, action: model.close)
        }
#endif
        if let selected, !selected.isFrames {
          ToolbarItem(placement: .primaryAction) {
            ShareLink(item: library.url(selected)) { Image(systemName: "square.and.arrow.up") }
              .accessibilityLabel("Share")
          }
        }
      }
    }
    .tint(Color(uiColor: .systemBlue))
    .alert("Stop Rendering?", isPresented: Binding(get: { model.confirmStop != nil },
                                                    set: { if !$0 { model.confirmStop = nil } })) {
      Button("Keep Rendering", role: .cancel) { model.confirmStop = nil }
      Button("Stop", role: .destructive) {
        model.confirmStop = nil
        model.stopConfirmed()
      }
    } message: {
      Text(model.confirmStop ?? "")
    }
  }
}

/** The renders side by side, a page each: swipe between them, pinch or double tap
 * to zoom. Picking a frame in the film strip slides the page over. */
struct RenderGallery: View {
  @ObservedObject var model: RenderModel
  @ObservedObject var library: RenderLibrary
  @State private var page: String?

  private var pages: [String] {
    library.items.map(\.id) + (model.rendering ? [RenderModel.live] : [])
  }

  var body: some View {
    GeometryReader { geometry in
      ScrollView(.horizontal) {
        LazyHStack(spacing: 0) {
          ForEach(pages, id: \.self) { id in
            pageView(id, active: id == (page ?? model.current(library)))
              .frame(width: geometry.size.width, height: geometry.size.height)
              .id(id)
          }
        }
        .scrollTargetLayout()
      }
      .scrollTargetBehavior(.paging)
      .scrollIndicators(.hidden)
      .scrollPosition(id: $page)
      .overlay {
        if pages.isEmpty {
          ContentUnavailableView("No Renders", systemImage: "camera.aperture",
                                 description: Text("Render an image or animation from the Share menu."))
        }
      }
    }
    .onAppear { page = model.current(library) }
    /* Swiping the page picks it in the film strip too. */
    .onChange(of: page) { _, page in
      guard let page, page != model.current(library) else { return }
      model.select(page)
    }
    /* A frame picked in the film strip, or a new render, slides its page over. */
    .onChange(of: model.current(library)) { _, current in
      guard current != page else { return }
      withMotion(.smooth(duration: 0.35)) { page = current }
    }
  }

  /** The render itself, filling the page. */
  @ViewBuilder
  private func pageView(_ id: String, active: Bool) -> some View {
    ZStack {
      if id == RenderModel.live {
        if let live = model.live {
          ZoomableImage(image: live, url: nil)
        }
        else {
          ProgressView().controlSize(.large)
        }
      }
      else if let item = library.items.first(where: { $0.id == id }) {
        let url = library.url(item)
        if item.isFrames {
          RenderFramesPage(item: item, model: model, still: library.still(item))
        }
        else if item.video && item.playable {
          RenderVideo(url: url, playing: active)
            /* Held, the video file drags out to other apps. */
            .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        }
        else if item.video {
          /* A container the iPad does not play (the scene's Output asked for it): its first frame,
           * and where it plays. */
          ZStack(alignment: .bottom) {
            if let still = library.still(item) { RenderStill(url: still) }
            Text("This \(url.pathExtension.uppercased()) video plays in other apps. Share it to open it.")
              .font(.footnote)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .background(.regularMaterial, in: Capsule())
              .padding(16)
          }
        }
        else {
          /* A still in a format the iPad does not show is shown by its PNG. */
          RenderStill(url: library.still(item) ?? url)
        }
      }
    }
  }
}

/** The render in progress: what is rendering, how far along, the time left, and Stop. */
struct RenderProgressCard: View {
  @ObservedObject var model: RenderModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(model.phase)
          .font(.headline)
          .contentTransition(.numericText())
        Spacer()
        Text(model.progress, format: .percent.precision(.fractionLength(0)))
          .font(.headline.monospacedDigit())
          .foregroundStyle(.secondary)
          .contentTransition(.numericText(value: model.progress))
      }
      ProgressView(value: model.progress)
        .progressViewStyle(.linear)
        .controlSize(.large)
        .accessibilityLabel(model.phase)
      HStack {
        Text(model.remaining ?? "Estimating time…")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .contentTransition(.opacity)
        Spacer()
        Button(model.stopping ? "Stopping…" : "Stop", role: .destructive, action: model.stop)
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(model.stopping)
      }
    }
    .animation(.smooth, value: model.progress)
    .padding(16)
    .background(Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

/** An animation kept as its frames (R6 BUSY-3): the first frame, how many there are, and what can
 * be done with them: continue from the first missing frame, make a video, save them to Files. */
struct RenderFramesPage: View {
  let item: RenderItem
  @ObservedObject var model: RenderModel
  let still: URL?

  var body: some View {
    ZStack(alignment: .bottom) {
      if let still {
        RenderStill(url: still)
      }
      VStack(spacing: 10) {
        Text(item.framesSummary)
          .font(.headline)
        if model.rendering {
          Text("Wait for the render in progress, or stop it.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        HStack(spacing: 10) {
          if item.stopped, let next = item.next {
            Button("Continue from Frame \(next)") { model.continueFrames(item) }
          }
          if item.frames > 0 {
            Button(item.stopped ? "Make Video of \(item.frames) Frames" : "Make Video") { model.makeVideo(item) }
            Button("Save Frames to Files…") { model.saveFrames(item) }
          }
        }
        .buttonStyle(.bordered)
        .disabled(model.rendering)
      }
      .padding(16)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .padding(20)
    }
  }
}

struct RenderStill: View {
  let url: URL
  @State private var image: UIImage?

  var body: some View {
    ZStack {
      if let image {
        ZoomableImage(image: image, url: url)
          .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.15), value: image != nil)
    .task(id: url) {
      image = await Task.detached(priority: .userInitiated) {
        await UIImage(contentsOfFile: url.path)?.byPreparingForDisplay()
      }.value
    }
  }
}

#if !os(macOS)
/** An image to pinch, pan and double tap into, fitting the page when zoomed out.
 * Zoomed out it leaves sideways swipes to the gallery's paging. Held, it drags out to other apps:
 * its file when it has one, otherwise the image. */
struct ZoomableImage: UIViewRepresentable {
  let image: UIImage
  let url: URL?

  func makeUIView(context: Context) -> ZoomView { ZoomView() }

  func updateUIView(_ view: ZoomView, context: Context) {
    if view.image !== image { view.image = image }
    view.url = url
  }
}

final class ZoomView: UIScrollView, UIScrollViewDelegate, UIDragInteractionDelegate {
  private let imageView = UIImageView()
  private var fitted = CGSize.zero
  /** The image's file, which dragging hands to other apps as it is. */
  var url: URL?

  var image: UIImage? {
    get { imageView.image }
    set {
      /* Lay the new image out unzoomed, then fit it. */
      minimumZoomScale = 1
      maximumZoomScale = 1
      zoomScale = 1
      imageView.image = newValue
      imageView.frame = CGRect(origin: .zero, size: newValue?.size ?? .zero)
      contentSize = imageView.frame.size
      fitted = .zero
      setNeedsLayout()
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    delegate = self
    showsHorizontalScrollIndicator = false
    showsVerticalScrollIndicator = false
    contentInsetAdjustmentBehavior = .never
    decelerationRate = .fast
    bouncesZoom = true
    imageView.accessibilityIgnoresInvertColors = true
    addSubview(imageView)
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
    doubleTap.numberOfTapsRequired = 2
    addGestureRecognizer(doubleTap)
    let drag = UIDragInteraction(delegate: self)
    drag.isEnabled = true
    addInteraction(drag)
  }

  func dragInteraction(_ interaction: UIDragInteraction,
                       itemsForBeginning session: UIDragSession) -> [UIDragItem]
  {
    guard let image else { return [] }
    let provider = url.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider(object: image)
    provider.suggestedName = url?.deletingPathExtension().lastPathComponent ?? "Render"
    let item = UIDragItem(itemProvider: provider)
    item.localObject = image
    return [item]
  }

  func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem,
                       session: UIDragSession) -> UITargetedDragPreview?
  {
    /* The image lifts, not the page around it. */
    UITargetedDragPreview(view: imageView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  private var fitScale: CGFloat {
    guard let size = image?.size, size.width > 0, size.height > 0, bounds.width > 0 else { return 1 }
    return min(bounds.width / size.width, bounds.height / size.height)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard image != nil, bounds.width > 1, bounds.height > 1, bounds.size != fitted else { return }
    /* A new size, or a new image: fit it, keeping a zoom the user chose if there is one. */
    let zoomedIn = fitted != .zero && zoomScale > minimumZoomScale + 0.001
    fitted = bounds.size
    minimumZoomScale = fitScale
    maximumZoomScale = max(fitScale * 8, 2)
    if !zoomedIn { zoomScale = fitScale }
    center()
  }

  private func center() {
    let x = max(0, (bounds.width - contentSize.width) / 2)
    let y = max(0, (bounds.height - contentSize.height) / 2)
    contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

  func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

  @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
    if zoomScale > minimumZoomScale + 0.001 {
      setZoomScale(minimumZoomScale, animated: true)
      return
    }
    let point = tap.location(in: imageView)
    let scale = min(maximumZoomScale, minimumZoomScale * 3)
    let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
    zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                    width: size.width, height: size.height), animated: true)
  }
}
#endif

/** A rendered animation, looping while its page is shown. */
struct RenderVideo: View {
  let url: URL
  let playing: Bool
  @State private var player: AVPlayer?
  @State private var loop: NSObjectProtocol?

  var body: some View {
    VideoPlayer(player: player)
      .onAppear {
        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .none
        loop = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                      object: player.currentItem, queue: .main) { _ in
          player.seek(to: .zero)
          player.play()
        }
        self.player = player
        if playing { player.play() }
      }
      .onChange(of: playing) { _, playing in
        if playing { player?.play() }
        else { player?.pause() }
      }
      .onDisappear {
        player?.pause()
        if let loop { NotificationCenter.default.removeObserver(loop) }
      }
  }
}

/** Every render, oldest first, as a scrubber: small frames packed together with the
 * picked one opened out in the middle. Sliding the strip picks the frame that lands in the middle;
 * tapping a frame slides it there. */
struct FilmStrip: View {
  @ObservedObject var model: RenderModel
  @ObservedObject var library: RenderLibrary
  @State private var centered: String?
  @State private var deleting: RenderItem?

  private var ids: [String] {
    library.items.map(\.id) + (model.rendering ? [RenderModel.live] : [])
  }

  var body: some View {
    GeometryReader { geometry in
      ScrollView(.horizontal) {
        LazyHStack(spacing: 2) {
          ForEach(ids, id: \.self) { id in
            frame(id)
              .id(id)
          }
        }
        .scrollTargetLayout()
      }
      /* Any frame can sit in the middle, the first and last too. */
      .contentMargins(.horizontal, geometry.size.width / 2 - 24, for: .scrollContent)
      .scrollTargetBehavior(.viewAligned)
      .scrollPosition(id: $centered, anchor: .center)
      .scrollIndicators(.hidden)
    }
    .frame(height: 72)
    .background(Color(uiColor: .secondarySystemGroupedBackground))
    .onAppear { centered = model.current(library) }
    .onChange(of: centered) { _, id in
      guard let id, id != model.current(library) else { return }
      model.select(id)
      Haptics.selection()
    }
    .onChange(of: model.current(library)) { _, current in
      guard current != centered else { return }
      withMotion(.smooth(duration: 0.35)) { centered = current }
    }
    .alert("Delete Render?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
      Button("Cancel", role: .cancel) { deleting = nil }
      Button("Delete", role: .destructive) {
        if let deleting {
          if model.selection == deleting.id { model.selection = nil }
          library.remove(deleting)
        }
        deleting = nil
      }
    } message: {
      Text(deleting?.isFrames == true ? "Its \(deleting?.frames ?? 0) frames will be deleted." :
            "This render will be removed from the film strip.")
    }
  }

  @ViewBuilder
  private func frame(_ id: String) -> some View {
    let selected = id == model.current(library)
    if id == RenderModel.live {
      Button {
        withMotion(.snappy) { model.select(id) }
      } label: {
        ZStack {
          Color(uiColor: .tertiarySystemFill)
          if let live = model.live { Image(uiImage: live).resizable().scaledToFill() }
          ProgressView(value: model.progress)
            .progressViewStyle(.circular)
            .controlSize(.small)
            .tint(.white)
            .padding(5)
            .background(.black.opacity(0.35), in: Circle())
        }
        .filmFrame(selected: selected, aspect: model.live.map { $0.size.width / max(1, $0.size.height) } ?? 1.5)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Render in progress")
    }
    else if let item = library.items.first(where: { $0.id == id }) {
      Button {
        withMotion(.snappy) { model.select(id) }
      } label: {
        FilmFrame(url: library.still(item), video: item.video, frames: item.frames, sequence: item.isFrames,
                  stopped: item.stopped)
          .filmFrame(selected: selected,
                     aspect: item.height > 0 ? CGFloat(item.width) / CGFloat(item.height) : 1.5)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(item.isFrames ? "Animation frames, " + item.framesSummary :
                            item.video ? "Animation, \(item.frames) frames" : "Image")
      .accessibilityValue(item.date.formatted(date: .abbreviated, time: .shortened))
      .accessibilityAddTraits(selected ? .isSelected : [])
      .contextMenu {
        if item.isFrames {
          Button { model.saveFrames(item) } label: { Label("Save Frames to Files…", systemImage: "folder") }
        }
        else {
          ShareLink(item: library.url(item)) { Label("Share", systemImage: "square.and.arrow.up") }
        }
        Button(role: .destructive) { deleting = item } label: { Label("Delete", systemImage: "trash") }
      } preview: {
        FilmFrame(url: library.still(item), video: item.video, frames: item.frames, sequence: item.isFrames,
                  stopped: item.stopped)
          .frame(width: 360, height: 360 / max(0.3, item.height > 0 ? CGFloat(item.width) / CGFloat(item.height) : 1.5))
      }
    }
  }
}

private extension View {
  /** A narrow frame packed against its neighbours, or the picked one opened out to its shape. */
  func filmFrame(selected: Bool, aspect: CGFloat) -> some View {
    let height: CGFloat = selected ? 56 : 48
    let width = selected ? min(112, max(40, height * aspect)) : 32
    return self
      .frame(width: width, height: height)
      .clipShape(RoundedRectangle(cornerRadius: selected ? 6 : 3, style: .continuous))
      .padding(.horizontal, selected ? 6 : 0)
      .animation(.smooth(duration: 0.25), value: selected)
  }
}

struct FilmFrame: View {
  let url: URL?
  let video: Bool
  let frames: Int
  /** An animation kept as its frames, and whether it stopped before its end. */
  var sequence = false
  var stopped = false
  @State private var image: UIImage?

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      Color(uiColor: .tertiarySystemFill)
      if let image {
        Image(uiImage: image).resizable().scaledToFill()
      }
      if video || sequence {
        Image(systemName: video ? "play.fill" : stopped ? "pause.fill" : "square.stack.fill")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.white)
          .padding(3)
          .background(.black.opacity(0.45), in: Circle())
          .padding(3)
      }
    }
    .task(id: url) {
      if let url { image = await RenderThumbnails.load(url, size: 360) }
    }
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Controller
 * \{ */

/**
 * A render and its results, whichever window shows them: the iPad's sheet or the Mac's window.
 * Blender's state arrives in the `render` view, see #updateStatus.
 *
 * Every render writes into a folder of the document's render library (R6 BUSY-3): a still's
 * image, or an animation's frames as they finish, listed from its start. Stop asks first when more
 * than a minute of rendering would be lost; whatever ends a render, the frames it finished stay,
 * to continue from the first missing frame or to make a video of.
 *
 * Work pauses rather than going on unseen where it may not (R6 BUSY-4, G8): as the app leaves, when
 * iPadOS has not started the background task or, for work on the GPU, not granted it the GPU; and
 * between frames when the iPad is too warm. It goes on from the next frame when the app is back,
 * or has cooled, and says so.
 */
@MainActor
final class RenderSession {
  /** What is being made. */
  private enum Work {
    case still
    case frames
    case video
  }

  /** Why work paused, to go on by itself (R6 BUSY-4). */
  private enum Pause: Equatable {
    /** The app left the foreground and the work could not go on there: why. */
    case away(String)
    /** The iPad was too warm after a frame. */
    case heat
  }

  let model = RenderModel()
  /** Where the render in progress is kept: the project it was started in. */
  private(set) var renderLibrary = RenderLibrary.forDocument(nil)
  private var work = Work.still
  /** The library item and folder of the work in progress. */
  private var itemID = ""
  private var folder = URL(fileURLWithPath: "/")
  /** The command that started it, until Blender answered it. */
  private var command: UInt32?
  /** The state Blender showed when the work started: older states are not this work's. */
  private var startedAfter = 0.0
  private var lastID: Double?
  private var lastFrame: String?
  private var lastDone = 0
  /** When the last frame finished, or the work started: what Stop would lose is rendered since. */
  private var lastFinished = Date.now
  /** The system ended the background work: said once the app is back. */
  private var expired = false
  private var cancelSentAgain = false
  /** Work paused by #pause, its item and kind, to go on from. */
  private var paused: Pause?
  private var pausedItem = ""
  private var pausedWork = Work.still
  /** The app is in the background. */
  private var away = false
  /** Shows the renders. */
  var present: () -> Void = {}
  /** Tells why a render could not be completed, or (`title`) why it stopped. */
  var fail: (_ message: String, _ title: String) -> Void = { _, _ in }
  /** Offers a folder to save in Files. */
  var export: (URL) -> Void = { _ in }

  init() {
    model.stop = { [weak self] in self?.requestStop() }
    model.stopConfirmed = { [weak self] in self?.stop() }
    model.continueFrames = { [weak self] in self?.continueFrames($0) }
    model.makeVideo = { [weak self] in self?.makeVideo($0) }
    model.saveFrames = { [weak self] in self?.saveFrames($0) }
    BackgroundRender.shared.expired = { [weak self] in
      guard let self, self.model.rendering else { return }
      self.expired = true
      /* Blender's loop runs in the background until the stop has reached it. */
      BackgroundRender.shared.holding = true
      self.stop()
    }
  }

  /** The open project's renders; while one renders, the project it belongs to. */
  var library: RenderLibrary {
    model.rendering ? renderLibrary : RenderLibrary.forDocument(wm_apple_ios_document_url())
  }

  /** The film strip, without rendering. */
  func showRenders() {
    model.selection = nil
    present()
  }

  /** The Storyboard's edit, the workspace's sequencer scene, as an animation: every shot in turn
   * with its sound and effects, not the one shot the window shows (ROUND6 EDIT-10, D17). */
  func renderStory() { renderAnimation(true, story: true) }

  func renderAnimation(_ animation: Bool, story: Bool = false) {
    /* One render at a time: a second request shows the one in progress. */
    if model.rendering {
      present()
      return
    }
    renderLibrary = RenderLibrary.forDocument(wm_apple_ios_document_url())
    let id = UUID().uuidString
    let folder = renderLibrary.makeFolder(id)
    if animation {
      /* Listed from the start, so whatever ends the render, the frames it finished are found. */
      guard renderLibrary.addFrames(id: id, folder: folder) != nil else {
        fail("The render's folder could not be made.", "Unable to Render")
        return
      }
    }
    begin(animation ? .frames : .still, id: id, folder: folder,
          phase: animation ? "Starting" : "Rendering Image",
          verb: story ? "story" : animation ? "animation" : "image")
  }

  /** Render the frames an animation is still missing, from the first one. */
  private func continueFrames(_ item: RenderItem) {
    guard !model.rendering, item.isFrames else { return }
    renderLibrary = library
    begin(.frames, id: item.id, folder: renderLibrary.url(item), phase: "Starting", verb: "continue")
  }

  /** Make a video of an animation's frames: the scene's movie, or a quick H.264 one. */
  private func makeVideo(_ item: RenderItem) {
    guard !model.rendering, item.isFrames else { return }
    renderLibrary = library
    begin(.video, id: item.id, folder: renderLibrary.url(item), phase: "Making Video", verb: "video")
  }

  private func saveFrames(_ item: RenderItem) {
    let name = (wm_apple_ios_document_url()?.deletingPathExtension().lastPathComponent ?? "Animation") + " Frames"
    guard let copy = library.framesCopy(item, name: name) else {
      fail("The frames could not be copied.", "Unable to Save Frames")
      return
    }
    export(copy)
  }

  private func begin(_ work: Work, id: String, folder: URL, phase: String, verb: String) {
    self.work = work
    itemID = id
    self.folder = folder
    lastID = nil
    lastFrame = nil
    lastDone = 0
    lastFinished = .now
    expired = false
    cancelSentAgain = false
    paused = nil
    startedAfter = BlenderRender.status.double("id") ?? 0
    model.animation = work != .still
    model.title = title
    model.rendering = true
    model.stopping = false
    model.progress = 0
    model.remaining = nil
    model.live = nil
    model.selection = nil
    model.phase = phase
    model.started = .now
    command = BlenderRender.start(verb, folder: folder)
    BackgroundRender.shared.begin(title: title)
    present()
  }

  private var title: String {
    switch work {
      case .still: return "Rendering Image"
      case .frames: return "Rendering Animation"
      case .video: return "Making Video"
    }
  }

  /** Stop asks first when it would lose more than a minute of rendering: the frame in progress,
   * or the whole still. Frames already finished are kept either way. */
  private func requestStop() {
    guard model.rendering, !model.stopping else { return }
    let lost = Date.now.timeIntervalSince(lastFinished)
    guard lost > 60, work != .video else {
      stop()
      return
    }
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .full
    formatter.maximumUnitCount = 1
    formatter.allowedUnits = lost >= 3600 ? [.hour] : [.minute]
    let time = formatter.string(from: lost) ?? ""
    model.confirmStop = work == .still ?
      "The image has been rendering for \(time). It will be lost." :
      "The frame in progress has been rendering for \(time). It will be lost; the \(lastDone) frames finished are kept."
  }

  /** Blender answers with the render's state: `cancelled`, with the frames it kept. */
  private func stop() {
    guard model.rendering, !model.stopping else { return }
    model.stopping = true
    model.phase = "Stopping"
    BlenderRender.run("cancel")
  }

  private func end(success: Bool) {
    model.rendering = false
    model.stopping = false
    model.live = nil
    command = nil
    BackgroundRender.shared.finish(success: success)
  }

  func updateStatus(_ status: RenderStatus) {
    guard model.rendering else { return }
    /* A command Blender refused (a bake running, say) leaves nothing to wait for. */
    if let sent = command, let outcome = NativeViews.shared.outcome(of: sent) {
      command = nil
      if let refusal = outcome {
        failed(refusal, frames: 0)
        return
      }
    }
    guard let id = status.double("id"), id > startedAfter, lastID != id else { return }
    let state = status.string("state")
    /* States of earlier work (a render stopped before this one began) are not this work's. */
    if let shown = status.string("folder"), shown != folder.path { return }
    lastID = id
    switch state {
      case "rendering":
        if model.stopping, !cancelSentAgain {
          /* Stop reached Blender before the work had started (it waited behind other work). */
          cancelSentAgain = true
          BlenderRender.run("cancel")
        }
        showProgress(status)
      case "done":
        BlenderRender.run("clear")
        finished(status)
      case "error":
        BlenderRender.run("clear")
        failed(status.string("message") ?? "The render could not be completed.", frames: status.int("done"),
               status: status)
      case "cancelled":
        BlenderRender.run("clear")
        cancelled(status)
      default:
        break
    }
  }

  private func estimate() -> String? {
    let elapsed = Date.now.timeIntervalSince(model.started)
    guard model.progress > 0.02, elapsed > 2 else { return nil }
    let left = elapsed * (1 - model.progress) / model.progress
    if left < 5 { return "Almost done" }
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .full
    formatter.maximumUnitCount = 1
    formatter.allowedUnits = left >= 3600 ? [.hour, .minute] : left >= 60 ? [.minute] : [.second]
    return formatter.string(from: left).map { "About \($0) remaining" }
  }

  private func showProgress(_ status: RenderStatus) {
    let total = Double(max(1, status.int("total")))
    let done = status.int("done")
    let samples = status.double("samples") ?? 0
    /* Frames there before a Continue are not progress of this render's. */
    let resumed = Double(status.int("resumed"))
    model.progress = min(1, (Double(done) - resumed + samples) / max(1, total - resumed))
    let video = status.string("phase") == "video"
    BackgroundRender.shared.needsGPU = status.bool("gpu")
    if done != lastDone, !video {
      lastDone = done
      lastFinished = .now
      if work == .frames {
        renderLibrary.updateFrames(itemID, status: status)
        /* Between frames: too warm, it pauses until the iPad has cooled. */
        if done > status.int("resumed"), done < Int(total), BackgroundWork.tooWarm(ProcessInfo.processInfo.thermalState) {
          pause(.heat)
        }
      }
    }
    switch status.string("phase") {
      case "video":
        model.phase = "Making Video"
      default:
        model.phase = model.stopping ? "Stopping" :
          work == .still ? "Rendering Image" : "Frame \(min(done + 1, Int(total))) of \(Int(total))"
    }
    /* Show each frame as it is finished. */
    if work == .frames, let last = status.string("last"), !last.isEmpty, last != lastFrame {
      lastFrame = last
      Task {
        let image = await Task.detached(priority: .utility) {
          await UIImage(contentsOfFile: last)?.byPreparingForDisplay()
        }.value
        if let image, self.model.rendering { self.model.live = image }
      }
    }
    model.remaining = estimate()
    BackgroundRender.shared.update(title: title,
                                   subtitle: work == .frames ? model.phase : "\(Int((model.progress * 100).rounded()))%",
                                   fraction: model.progress)
  }

  private func finished(_ status: RenderStatus) {
    switch work {
      case .still:
        guard let image = status.string("image"),
              let item = renderLibrary.addImage(id: itemID, folder: folder, image: image,
                                                preview: status.string("preview"))
        else {
          failed("The rendered image could not be kept.", frames: 0)
          return
        }
        show(item)
      case .frames, .video:
        renderLibrary.updateFrames(itemID, status: status)
        let video = status.string("video") ?? ""
        guard !video.isEmpty else {
          /* An image format: the frames are the result. */
          if let item = renderLibrary.items.first(where: { $0.id == itemID }) { show(item) }
          else { end(success: true) }
          return
        }
        let frames = status.strings("frames")
        guard let item = renderLibrary.addVideo(URL(fileURLWithPath: video), poster: frames.first,
                                                frames: frames.count)
        else {
          failed("The video could not be kept.", frames: frames.count)
          return
        }
        /* The scene's movie of all its frames stands for them, written only to make it; a video
         * made of an image format's frames, or of frames still to be continued, is an extra. */
        if status.bool("movie"), !status.bool("quick"), status.int("next") == 0,
           let frames = renderLibrary.items.first(where: { $0.id == itemID })
        {
          renderLibrary.remove(frames)
        }
        show(item)
    }
  }

  private func cancelled(_ status: RenderStatus) {
    let wasExpired = expired
    if let paused {
      pausedItem = itemID
      pausedWork = work
      if work == .frames { keepFrames(status) }
      else if work == .still { try? FileManager.default.removeItem(at: folder) }
      end(success: false)
      if paused == .heat {
        fail("Rendering paused after \(status.int("done")) of \(status.int("total")) frames: the iPad is too warm. " +
             "It goes on by itself once the iPad has cooled down.", "Rendering Paused")
      }
      resumeIfReady()
      return
    }
    switch work {
      case .still:
        try? FileManager.default.removeItem(at: folder)
      case .frames:
        keepFrames(status)
      case .video:
        break  // The frames are as they were.
    }
    end(success: false)
    if wasExpired {
      let kept = work == .frames && status.int("done") > 0 ?
        " The \(status.int("done")) frames rendered are kept in Renders: continue from there, or make a video of them." : ""
      fail("iPadOS ended the work in the background." + kept, "Rendering Stopped")
    }
  }

  /** The frames a render that ended early made: kept and listed, or the empty item removed. */
  private func keepFrames(_ status: RenderStatus) {
    renderLibrary.updateFrames(itemID, status: status)
    guard let item = renderLibrary.items.first(where: { $0.id == itemID }) else { return }
    if item.frames == 0 { renderLibrary.remove(item) }
    else { model.selection = item.id }
  }

  private func failed(_ message: String, frames: Int, status: RenderStatus? = nil) {
    switch work {
      case .still:
        try? FileManager.default.removeItem(at: folder)
      case .frames:
        if let status { keepFrames(status) }
        else if let item = renderLibrary.items.first(where: { $0.id == itemID }), item.frames == 0 {
          renderLibrary.remove(item)
        }
      case .video:
        break
    }
    end(success: false)
    let kept = work != .still && frames > 0 ? " The \(frames) frames rendered are kept in Renders." : ""
    fail(message + kept, "Unable to Render")
  }

  /** Stop the work so that it goes on later by itself: the frames finished are kept. */
  private func pause(_ reason: Pause) {
    guard model.rendering, !model.stopping else { return }
    paused = reason
    if case .away = reason {
      /* Blender's loop runs in the background until the stop has reached it. */
      BackgroundRender.shared.holding = true
    }
    stop()
  }

  /** The app left the foreground: work that may not go on there pauses. */
  func appLeft() {
    away = true
    guard model.rendering, !model.stopping, !BackgroundRender.shared.continues else { return }
    let why = BackgroundRender.shared.taskStarted ?
      "iPadOS did not allow it to use the GPU in the background" :
      "iPadOS did not allow it to go on in the background"
    WM_native_ui_log("render", "paused as the app left: " + why)
    pause(.away(why))
  }

  /** The app is back: work paused as it left goes on. */
  func appReturned() {
    away = false
    resumeIfReady()
  }

  /** The iPad's heat changed: work paused by heat goes on once it has cooled. */
  func thermalChanged() { resumeIfReady() }

  private func resumeIfReady() {
    guard let reason = paused, !model.rendering, !away else { return }
    if reason == .heat, !BackgroundWork.coolEnough(ProcessInfo.processInfo.thermalState) { return }
    paused = nil
    let item = renderLibrary.items.first { $0.id == pausedItem }
    switch pausedWork {
      case .still:
        if case let .away(why) = reason {
          fail("The image stopped rendering when the app left the foreground: \(why). Render it again from the Share menu.",
               "Rendering Paused")
        }
      case .frames:
        guard let item, item.stopped, let next = item.next else { return }
        if case let .away(why) = reason {
          fail("Rendering paused after \(item.frames) of \(item.total ?? item.frames) frames when the app left the " +
               "foreground: \(why). It goes on from frame \(next).", "Rendering Paused")
        }
        continueFrames(item)
      case .video:
        guard let item else { return }
        if case let .away(why) = reason {
          fail("The video stopped when the app left the foreground: \(why). It is being made again.", "Video Paused")
        }
        makeVideo(item)
    }
  }

  private func show(_ item: RenderItem) {
    model.selection = item.id
    end(success: true)
    Haptics.success()
  }
}

#if !os(macOS)
/** The iPad's renders, in a sheet over the document. */
@MainActor
@objc(WMIOSSwiftRender)
public final class SwiftRender: NSObject, UIAdaptivePresentationControllerDelegate, UIDocumentPickerDelegate {
  private weak var presenter: UIViewController?
  private var sheet: UIViewController?
  private let session = RenderSession()
  /** A copy of frames being saved to Files, removed once that is done. */
  private var exported: URL?

  @objc(initWithPresenter:)
  public init(presenter: UIViewController) {
    self.presenter = presenter
    super.init()
    session.model.close = { [weak self] in self?.close() }
    session.present = { [weak self] in self?.present() }
    session.fail = { [weak self] in self?.fail($0, title: $1) }
    session.export = { [weak self] in self?.export($0) }
    /* The app leaving and coming back, and the iPad's heat (R6 BUSY-4). Removed with this object. */
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(appLeft), name: UIApplication.didEnterBackgroundNotification,
                       object: nil)
    center.addObserver(self, selector: #selector(appReturned),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
    center.addObserver(self, selector: #selector(thermalChanged), name: ProcessInfo.thermalStateDidChangeNotification,
                       object: nil)
  }

  @objc private func appLeft() { session.appLeft() }
  @objc private func appReturned() { session.appReturned() }
  /* Posted on any thread. */
  @objc nonisolated private func thermalChanged() {
    DispatchQueue.main.async { MainActor.assumeIsolated { self.session.thermalChanged() } }
  }

  private func present() {
    guard sheet == nil, let presenter, presenter.presentedViewController == nil else { return }
    let controller = UIHostingController(rootView: RenderSheetView(model: session.model, library: session.library))
    controller.modalPresentationStyle = .formSheet
    controller.preferredContentSize = CGSize(width: 760, height: 700)
    controller.presentationController?.delegate = self
    sheet = controller
    presenter.present(controller, animated: true)
  }

  /** The film strip, without rendering. */
  @objc public func showRenders() { session.showRenders() }

  @objc(renderAnimation:)
  public func renderAnimation(_ animation: Bool) { session.renderAnimation(animation) }

  /** The Storyboard's Render Story. */
  public func renderStory() { session.renderStory() }

  /* The sheet was swiped away; a render goes on. */
  public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    sheet = nil
  }

  private func close() {
    let sheet = self.sheet
    self.sheet = nil
    sheet?.dismiss(animated: true)
  }

  func updateStatus(_ status: RenderStatus) { session.updateStatus(status) }

  private var top: UIViewController? {
    var top = presenter
    while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
    return top
  }

  private func fail(_ message: String, title: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    top?.present(alert, animated: true)
  }

  /** Save a folder of frames to Files, as a folder. */
  private func export(_ folder: URL) {
    exported = folder
    let picker = UIDocumentPickerViewController(forExporting: [folder], asCopy: true)
    picker.delegate = self
    top?.present(picker, animated: true)
  }

  public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    removeExported()
  }

  public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { removeExported() }

  private func removeExported() {
    if let exported { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
    exported = nil
  }
}
#endif

/** \} */
