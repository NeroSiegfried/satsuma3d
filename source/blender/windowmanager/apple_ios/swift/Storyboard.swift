/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The storyboard grown out of the timeline: the shots of the workspace's sequencer scene, each a
 * scene strip shown as a film strip of its frames along the edit's time. Shots are dragged to move
 * them, to other frames and other lanes, their edges to make them longer or shorter, and a new one
 * is added after the selected one. Moving the playhead over a shot shows its scene to draw in, as
 * Blender's Storyboarding workspace does. See `sequencer_native.cc` for Blender's side.
 */

import SwiftUI
import UIKit

struct StoryboardPicture: Equatable {
  /** The frame of the edit it shows, its left edge. */
  var frame: Int
  var path: String
}

struct StoryboardTemplate: Equatable, Identifiable {
  var name: String
  var id: String
}

struct StoryboardShot: Equatable, Identifiable {
  var name: String
  var channel: Int
  var start: Int
  var end: Int
  var scene: String
  var sceneStrip: Bool
  var selected: Bool
  var active: Bool
  var muted: Bool
  /** Its scene is kept as a template new shots can start from. */
  var template: Bool
  var color: Int
  /** Width over height of its scene's frames. */
  var aspect: Double
  var pictures: [StoryboardPicture]
  /** Where its drawings begin, in the edit's frames: its Grease Pencil keys. */
  var keys: [Int]
  /** Its scene's frames in the edit's: plus this. */
  var offset: Int

  var id: String { name }

  init(_ json: JSON) {
    name = json.string("name") ?? ""
    channel = json.int("channel") ?? 1
    start = json.int("start") ?? 0
    end = json.int("end") ?? 0
    scene = json.string("scene") ?? ""
    sceneStrip = json.bool("scene_strip")
    selected = json.bool("selected")
    template = json.bool("template")
    active = json.bool("active")
    muted = json.bool("muted")
    color = json.int("color") ?? 0
    aspect = json.double("aspect") ?? 16.0 / 9.0
    keys = ((json["keys"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue }
    offset = json.int("offset") ?? 0
    pictures = ((json["pictures"] as? [Any]) ?? []).compactMap { entry in
      guard let pair = entry as? [Any], pair.count == 2, let frame = (pair[0] as? NSNumber)?.intValue,
            let path = pair[1] as? String else { return nil }
      return StoryboardPicture(frame: frame, path: path)
    }
  }
}

struct StoryboardLayer: Equatable, Identifiable {
  var name: String
  var visible: Bool
  var locked: Bool
  var active: Bool
  /** Where its drawings begin, in its scene's frames. */
  var keys: [Int] = []
  var id: String { name }
}

@MainActor
@Observable
final class StoryboardModel {
  private(set) var shown = false
  private(set) var available = false
  private(set) var start = 1
  private(set) var end = 250
  /** The edit's frame, which playback and scrubbing move. */
  var frame = 1
  private(set) var fps = 24.0
  private(set) var playing = false
  /** Playback loops within the frames in view, as Blender's preview range. */
  private(set) var loop = false
  private(set) var loopRange = 1...250
  private(set) var shots: [StoryboardShot] = []
  /** The scenes a shot can show instead. */
  private(set) var scenes: [String] = []
  /** The scene assets a new shot can start from, by name and where they are. */
  private(set) var templates: [StoryboardTemplate] = []
  /** The layers of the drawing in the shot shown, the top one first. */
  private(set) var layers: [StoryboardLayer] = []
  /** A reordering just made here, kept until Blender's snapshot agrees or a while passes. */
  @ObservationIgnored private var expectedLayers: (names: [String], until: Date)?
  /** The shot opened to work in its own scene's time, which the timeline then shows; none, the
   * timeline shows the edit's. */
  private(set) var entered: String? {
    didSet { if entered != oldValue { enteredChanged?() } }
  }
  @ObservationIgnored var enteredChanged: (() -> Void)?
  @ObservationIgnored private var raw: NSDictionary?
  @ObservationIgnored private var sequence: UInt64 = 0
  /** While a finger moves the playhead, Blender's frame waits. */
  @ObservationIgnored var scrubbing = false
  @ObservationIgnored private var lastFrameSent = Date.distantPast
  /** Shots just edited here, kept as they are shown until Blender's snapshot agrees, or a while
   * passes: a snapshot from before the edit would put them back for a moment. */
  @ObservationIgnored private var expected: [String: (shot: StoryboardShot, until: Date)] = [:]
  /** How the pictures are asked for: the frames between them, and their height in pixels. */
  @ObservationIgnored private var pictureState: [Int] = []

  var channels: Int { max(1, shots.map(\.channel).max() ?? 1) }

  /** Set here, until Blender's snapshot shows it. */
  @ObservationIgnored private var loopPending = false

  /** Loops playback within `range`, the frames in view, or stops looping within it. */
  func setLoop(_ enabled: Bool, range: ClosedRange<Int>) {
    guard enabled != loop || (enabled && range != loopRange) else { return }
    loop = enabled
    loopRange = range
    loopPending = true
    send("loop", ["enabled": enabled ? 1 : 0, "start": range.lowerBound, "end": range.upperBound])
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(400))
      self.loopPending = false
    }
  }

  func setShown(_ shown: Bool) {
    guard shown != self.shown else { return }
    self.shown = shown
    Engine.setting("native_storyboard_visible", shown ? "1" : "0")
  }

  func update(_ snapshot: JSON) {
    let dictionary = snapshot as NSDictionary
    if let raw, raw.isEqual(dictionary) { return }
    raw = dictionary
    available = snapshot.bool("available")
    start = snapshot.int("start") ?? start
    end = max(start, snapshot.int("end") ?? end)
    fps = snapshot.double("fps") ?? fps
    playing = snapshot.bool("playing")
    if !loopPending {
      loop = snapshot.bool("loop")
      let low = snapshot.int("loop_start") ?? start
      loopRange = low...max(low, snapshot.int("loop_end") ?? end)
    }
    /* The frame comes from the timeline's snapshot, every frame; this one is older. */
    let scenes = (snapshot["scenes"] as? [String]) ?? []
    if scenes != self.scenes { self.scenes = scenes }
    let templates = snapshot.array("templates").map {
      StoryboardTemplate(name: $0.string("name") ?? "", id: $0.string("id") ?? "")
    }
    if templates != self.templates { self.templates = templates }
    let layers = snapshot.array("layers").map {
      StoryboardLayer(name: $0.string("name") ?? "", visible: $0.bool("visible"), locked: $0.bool("locked"),
                      active: $0.bool("active"),
                      keys: (($0["keys"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue })
    }
    if let expected = expectedLayers, layers.map(\.name) != expected.names && Date() < expected.until {
      /* Still the order from before the move. */
    }
    else {
      expectedLayers = nil
      if layers != self.layers { self.layers = layers }
    }
    let now = Date()
    let next = snapshot.array("strips").map(StoryboardShot.init).map { shot in
      guard let kept = expected[shot.id] else { return shot }
      let agrees = kept.shot.start == shot.start && kept.shot.end == shot.end && kept.shot.channel == shot.channel
      if agrees || now > kept.until {
        expected[shot.id] = nil
        return shot
      }
      /* Blender's pictures, with the place shown here; moved, they move along. */
      var shown = shot
      if kept.shot.end - kept.shot.start == shot.end - shot.start {
        let delta = kept.shot.start - shot.start
        shown.pictures = shot.pictures.map { StoryboardPicture(frame: $0.frame + delta, path: $0.path) }
        shown.keys = shot.keys.map { $0 + delta }
      }
      shown.start = kept.shot.start
      shown.end = kept.shot.end
      shown.channel = kept.shot.channel
      return shown
    }
    if next != shots { shots = next }
  }

  /** The edit's frame from the timeline's snapshot, which playback updates every frame; with a
   * shot opened, its own scene's frame, which then plays alone, in the edit's time. */
  func follow(frame: Int, sceneFrame: Int) {
    var frame = frame
    if shown, let entered, let shot = shots.first(where: { $0.id == entered }) {
      frame = sceneFrame + shot.offset
    }
    if !scrubbing, frame != self.frame { self.frame = frame }
  }

  /** Pictures `step` frames apart, `height` pixels high, as fit side by side at this zoom. */
  func requestPictures(step: Int, height: Int) {
    let state = [step, height]
    guard state != pictureState else { return }
    pictureState = state
    Engine.setting("native_storyboard_state", json: ["step": step, "height": height])
  }

  func send(_ action: String, _ extra: JSON = [:]) {
    sequence += 1
    var request: JSON = ["action": action, "sequence": NSNumber(value: sequence)]
    request.merge(extra) { $1 }
    Engine.setting("native_storyboard_edit", json: request)
  }

  /** Moves the playhead, the window following the shot under it. */
  func setFrame(_ frame: Int, final: Bool) {
    var frame = frame
    /* Closed, the shots are not kept up to date here: the small timeline keeps to the edit. */
    if shown {
      frame = min(end, max(start, frame))
      /* A shot opened keeps the playhead within it. */
      if let entered, let shot = shots.first(where: { $0.id == entered }) {
        frame = min(shot.end - 1, max(shot.start, frame))
      }
    }
    self.frame = frame
    /* Each frame sent switches scenes as needed: often enough to follow, not every touch. */
    guard final || Date().timeIntervalSince(lastFrameSent) > 1.0 / 30 else { return }
    lastFrameSent = Date()
    send("frame", ["frame": frame])
  }

  func activateLayer(_ layer: StoryboardLayer) {
    layers = layers.map { var other = $0; other.active = $0.id == layer.id; return other }
    send("layer_active", ["layer": layer.name])
  }

  /** A shot's drawings starting at these frames of the edit, in all its layers, moved by some
   * frames, shown at once. */
  func moveShotKeys(_ shot: StoryboardShot, frames: [Int], by delta: Int) {
    guard delta != 0, !frames.isEmpty, let index = shots.firstIndex(where: { $0.id == shot.id }) else { return }
    let moved = Set(frames.map { $0 + delta })
    shots[index].keys = (shots[index].keys.filter { !frames.contains($0) && !moved.contains($0) } + moved).sorted()
    send("shot_keys_move", ["name": shot.name, "frames": frames, "delta": delta])
  }

  func deleteShotKeys(_ shot: StoryboardShot, frames: [Int]) {
    guard !frames.isEmpty, let index = shots.firstIndex(where: { $0.id == shot.id }) else { return }
    shots[index].keys.removeAll { frames.contains($0) }
    send("shot_keys_delete", ["name": shot.name, "frames": frames])
  }

  /** A layer's drawings from these frames of its scene moved by some frames, shown at once. */
  func moveLayerKeys(_ layer: StoryboardLayer, frames: [Int], by delta: Int) {
    guard delta != 0, !frames.isEmpty, let index = layers.firstIndex(where: { $0.id == layer.id }) else { return }
    let moved = Set(frames.map { $0 + delta })
    layers[index].keys = (layers[index].keys.filter { !frames.contains($0) && !moved.contains($0) } + moved).sorted()
    send("layer_keys_move", ["layer": layer.name, "frames": frames, "delta": delta])
  }

  func deleteLayerKeys(_ layer: StoryboardLayer, frames: [Int]) {
    guard !frames.isEmpty, let index = layers.firstIndex(where: { $0.id == layer.id }) else { return }
    layers[index].keys.removeAll { frames.contains($0) }
    send("layer_keys_delete", ["layer": layer.name, "frames": frames])
  }

  func setLayerVisible(_ layer: StoryboardLayer, _ visible: Bool) {
    if let index = layers.firstIndex(where: { $0.id == layer.id }) { layers[index].visible = visible }
    send("layer_visible", ["layer": layer.name, "value": visible ? 1 : 0])
  }

  /** A layer dragged in the list, which shows the top one first: placed above the layer now at
   * `destination`, or below the last. */
  func moveLayers(from source: IndexSet, to destination: Int) {
    guard let from = source.first, from != destination, from + 1 != destination else { return }
    let layer = layers[from]
    let above = destination < from
    let target = above ? layers[destination] : layers[destination - 1]
    layers.move(fromOffsets: source, toOffset: destination)
    expectedLayers = (layers.map(\.name), Date().addingTimeInterval(1.5))
    send("layer_move", ["layer": layer.name, "target": target.name, "above": above ? 1 : 0])
  }

  /** Opens a shot: the window shows it, the timeline its own scene's time. */
  func enter(_ shot: StoryboardShot) {
    select(shot)
    if !(shot.start..<shot.end).contains(frame) { setFrame(shot.start, final: true) }
    entered = shot.name
  }

  /** Back to the edit: the timeline shows its time, the window the shot under its playhead. */
  func leave() {
    guard entered != nil else { return }
    entered = nil
    send("frame", ["frame": frame])
  }

  /** The cuts before and after the playhead, for the timeline's previous and next buttons. */
  func cut(after: Bool) -> Int? {
    let cuts = Set(shots.flatMap { [$0.start, $0.end] }).sorted()
    return after ? cuts.first { $0 > frame } : cuts.last { $0 < frame }
  }

  /* Each edit shows at once; Blender's snapshot confirms it. */
  func select(_ shot: StoryboardShot) {
    guard !shot.selected || !shot.active else { return }
    shots = shots.map { var other = $0; other.selected = $0.id == shot.id; other.active = other.selected; return other }
    send("select", ["name": shot.name])
  }

  private func edited(_ shot: StoryboardShot, _ change: (inout StoryboardShot) -> Void) {
    guard let index = shots.firstIndex(where: { $0.id == shot.id }) else { return }
    change(&shots[index])
    expected[shot.id] = (shots[index], Date().addingTimeInterval(1.5))
  }

  func move(_ shot: StoryboardShot, start: Int, channel: Int) {
    guard start != shot.start || channel != shot.channel else { return }
    edited(shot) {
      let delta = start - $0.start
      $0.end += delta
      $0.start = start
      $0.channel = channel
      $0.pictures = $0.pictures.map { StoryboardPicture(frame: $0.frame + delta, path: $0.path) }
      $0.keys = $0.keys.map { $0 + delta }
    }
    send("move", ["name": shot.name, "start": start, "channel": channel])
  }

  func trim(_ shot: StoryboardShot, left: Bool, frame: Int) {
    edited(shot) {
      if left { $0.start = min(frame, $0.end - 1) }
      else { $0.end = max(frame, $0.start + 1) }
    }
    send("trim", ["name": shot.name, "side": left ? "left" : "right", "frame": frame])
  }
}

/* -------------------------------------------------------------------- */
/** \name Storyboard View
 * \{ */

/** Shot pictures read once per file: Blender names each version anew. */
@MainActor
private enum ShotPictures {
  static var cache: [String: Image] = [:]

  static func image(_ path: String) -> Image? {
    guard !path.isEmpty else { return nil }
    if let image = cache[path] { return image }
    guard let image = UIImage(contentsOfFile: path) else { return nil }
    if cache.count > 600 { cache.removeAll() }
    let result = Image(uiImage: image)
    cache[path] = result
    return result
  }
}

private let headerHeight: CGFloat = 44
private let rulerHeight: CGFloat = 24
/** The scrubber along the bottom, its knob showing the frame. */
private let scrubberHeight: CGFloat = 40
/** An opened shot's keys, above the scrubber, to retime. */
/** A layer's strip below an opened shot. */
/** Inside a shot, a layer's row: its key rail. */
private let keyRailHeight: CGFloat = 26
private let layerRowHeight: CGFloat = 36
private let layerHeaderWidth: CGFloat = 130
private let gripWidth: CGFloat = 18

struct StoryboardView: View {
  let model: StoryboardModel
  /** The timeline it grew out of: its playback, and its other editors to switch to. */
  let timeline: TimelineStore
  /** Below each shot in keyframe mode, its key rail. */
  private var railHeight: CGFloat { keysShown ? keyRailHeight : 0 }
  /** Points per frame, pinched apart sideways to zoom in time. */
  @State private var scale: CGFloat = 4
  /** How much taller than fits the lanes are, pinched apart up and down. */
  @State private var laneZoom: CGFloat = 1
  @State private var pinchStart: (scale: CGFloat, laneZoom: CGFloat)?
  /** A pinch began during a shot's drag: the drag ends without moving it. */
  @State private var pinchCancelled = false
  /** The frames from the first one to the pinch's center as it began, in frames. */
  @State private var pinchAnchor: CGFloat?
  @State private var fitted = false
  /** A shot being moved or trimmed: by how many frames, and lanes. */
  @State private var drag: ShotDrag?
  /** The snap the drag last made, to tap once as it takes. */
  @State private var snappedTo: Int?
  @State private var renaming: StoryboardShot?
  /** The shot whose edit menu was asked for, and how often, which shows it again each time. */
  @State private var editMenuShot: String?
  @State private var editMenuRequest = 0
  @State private var renamingLayer: StoryboardLayer?
  @State private var newLayerName = ""
  @State private var newName = ""
  @Environment(\.displayScale) private var displayScale
  @State private var lanesWidth: CGFloat = 0
  /** The shot a hold on the lanes picked up, while it is moved. */
  @State private var movingShot: String?
  @State private var moveStart = CGPoint.zero
  private let lanesSpace = "storyboard.lanes"
  /** The opened shot's selected drawings, by layer, in its scene's frames, and how far they are
   * being dragged. */
  @State private var selectedKeys = KeySelection()
  @State private var keyDrag: (owner: String, frames: Int)?
  /** Each shot's keys on a rail of its own below it, to move them. */
  @AppStorage("BlenderStoryKeys") private var keysShown = false
  @State private var loopFollow: Task<Void, Never>?

  private struct LoopView: Equatable {
    var offset: CGFloat
    var scale: CGFloat
    var width: CGFloat
  }
  /** Where the shots are scrolled to: shots and the playhead are placed by offsets, so scrolled
   * to by position rather than by view. */
  @State private var position = ScrollPosition(edge: .leading)
  @State private var zoomBeforeEntering: CGFloat?
  /** How far the shots are scrolled, for the scrubber to follow. */
  @State private var scrollOffset: CGFloat = 0
  /** The frame under the finger on the scrubber, shown before Blender follows. */
  @State private var scrubbing: Int?

  private struct ShotDrag: Equatable {
    enum Kind { case move, left, right }
    var name: String
    var kind: Kind
    var frames: Int
    var channels: Int
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      lanes
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: model.entered)
    }
    .alert("Rename Shot", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
      TextField("Name", text: $newName)
      Button("Rename") {
        if let shot = renaming, !newName.isEmpty { model.send("rename", ["name": shot.name, "value": newName]) }
        renaming = nil
      }
      Button("Cancel", role: .cancel) { renaming = nil }
    }
    .alert("Rename Layer", isPresented: Binding(get: { renamingLayer != nil }, set: { if !$0 { renamingLayer = nil } })) {
      TextField("Name", text: $newLayerName)
      Button("Rename") {
        if let layer = renamingLayer, !newLayerName.isEmpty {
          model.send("layer_rename", ["layer": layer.name, "value": newLayerName])
        }
        renamingLayer = nil
      }
      Button("Cancel", role: .cancel) { renamingLayer = nil }
    }
    .accessibilityIdentifier("blender.storyboard")
  }

  /** The shots in their lanes, the opened one's layers, the ruler and the playhead. */
  private func shotsContent(opened: StoryboardShot?, width: CGFloat, content: CGFloat, laneHeight: CGFloat,
                            lanes: Int, playheadHeight: CGFloat) -> some View {
    ZStack(alignment: .topLeading) {
      ruler(width: width)
      /* Inside a shot, it alone at the top, its pictures for all its layers, and their keys below
       * it; leaving, it is one shot among the others again. */
      ForEach(model.shots) { shot in
        let hidden = opened != nil && opened?.id != shot.id
        shotView(shot, laneHeight: laneHeight, lanes: lanes, channel: opened?.id == shot.id ? 1 : nil)
          .opacity(hidden ? 0 : 1)
          .allowsHitTesting(!hidden)
        if keysShown && opened == nil {
          shotRail(shot, laneHeight: laneHeight, lanes: lanes)
            .transition(.opacity.combined(with: .offset(y: -keyRailHeight)))
        }
      }
      if let opened {
        layerStrips(opened, top: rulerHeight + laneHeight)
          .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
      }
      /* Before the edit's start and after its end, darker: shots reaching there are out of it. */
      Rectangle()
        .fill(Color.black.opacity(0.14))
        .frame(width: max(0, x(model.start)), height: content)
        .allowsHitTesting(false)
      Rectangle()
        .fill(Color.black.opacity(0.14))
        .frame(width: max(0, width - x(model.end + 1)), height: content)
        .offset(x: x(model.end + 1))
        .allowsHitTesting(false)
      /* Down the whole height, to the scrubber below. */
      playhead(height: playheadHeight)
    }
  }

  /** Opened, the shot fills the width, to work in its frames; closed, the zoom from before. */
  private func enteredChanged(_ entered: String?) {
    guard let shot = model.shots.first(where: { $0.id == entered }) else {
      if let zoom = zoomBeforeEntering {
        zoomBeforeEntering = nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { scale = zoom }
      }
      return
    }
    if zoomBeforeEntering == nil { zoomBeforeEntering = scale }
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(80))
      withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
        scale = min(40, max(0.5, (lanesWidth - layerHeaderWidth - 48) / CGFloat(max(1, shot.end - shot.start))))
      }
      withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
        /* With room before it for its layers' names. */
        position.scrollTo(x: max(0, x(shot.start) - layerHeaderWidth - 16))
      }
    }
  }

  /** Playback keeps the playhead in view, a page at a time. */
  private func followPlayhead(_ frame: Int) {
    let at = x(frame)
    guard model.playing, at < scrollOffset || at > scrollOffset + lanesWidth - 24 else { return }
    withAnimation(.easeInOut(duration: 0.3)) { position.scrollTo(x: max(0, at - 40)) }
  }

  private func pinchChanged(_ stretch: CGSize, _ center: CGPoint) {
    let base = pinchStart ?? (scale, laneZoom)
    if pinchStart == nil {
      /* A second finger: a pinch, not a shot moved by the first one. */
      drag = nil
      pinchCancelled = true
      /* The frame between the fingers, which stays there as it zooms. */
      pinchAnchor = (scrollOffset + center.x - leading) / max(0.01, scale)
    }
    pinchStart = base
    let zoomed = min(40, max(0.5, base.scale * stretch.width))
    scale = zoomed
    laneZoom = min(4, max(0.4, base.laneZoom * stretch.height))
    if let anchor = pinchAnchor {
      position.scrollTo(x: max(0, leading + anchor * zoomed - center.x))
    }
  }

  private func pinchEnded() {
    pinchStart = nil
    pinchAnchor = nil
  }

  /** The shots in view to begin with, from the edit's start. */
  private func fitShots(empty: Bool, width: CGFloat) {
    var zoom = scale
    if !empty, !fitted {
      fitted = true
      let last = model.shots.map(\.end).max() ?? model.end
      zoom = min(40, max(0.5, (width - 60) / CGFloat(max(1, last - model.start))))
      scale = zoom
    }
    let at = CGFloat(model.start - origin) * zoom
    /* Once the lanes are as wide as the new zoom makes them. */
    Task { @MainActor in position.scrollTo(x: at) }
  }

  private var lanes: some View {
      GeometryReader { proxy in
        let opened = model.shots.first { $0.id == model.entered }
        /* An empty lane below the shots, to move one into; inside a shot, its layers instead. */
        let lanes: Int = model.channels + 1
        let layerRows: CGFloat = CGFloat(model.layers.count) * layerRowHeight
        /* All of them in the panel's height, unless pinched taller, then scrolled to. */
        let room: CGFloat = proxy.size.height - rulerHeight - scrubberHeight - 4
        let fit: CGFloat = max(28, min(120, room / CGFloat(lanes) - railHeight))
        let laneHeight: CGFloat = max(20, min(240, fit * laneZoom))
        let content: CGFloat = rulerHeight + (opened != nil ? laneHeight + layerRows : CGFloat(lanes) * (laneHeight + railHeight))
        let width: CGFloat = max(proxy.size.width, x(model.end + 1) + 160)
        ScrollViewReader { _ in
          ScrollView([.horizontal, .vertical]) {
            shotsContent(opened: opened, width: width, content: content, laneHeight: laneHeight, lanes: lanes,
                         playheadHeight: max(content, proxy.size.height - scrubberHeight))
            .frame(width: width, height: content, alignment: .topLeading)
            .coordinateSpace(.named(lanesSpace))
            .gesture(laneMove(laneHeight: laneHeight, lanes: lanes))
          }
          .safeAreaInset(edge: .bottom, spacing: 0) {
            /* In step with the shots above: the same frames at the same places, scrolled with
             * them. */
            VStack(spacing: 0) {
              scrubber(width: width)
                .offset(x: -scrollOffset)
                .frame(width: proxy.size.width, height: scrubberHeight, alignment: .leading)
                /* At the sides only: the knob grows as it is held. */
                .mask(Rectangle().padding(.vertical, -40))
            }
          }
          .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, offset in
            scrollOffset = offset
          }
          .onChange(of: LoopView(offset: scrollOffset, scale: scale, width: lanesWidth)) {
            /* Looping, within the frames now in view, once the view settles. */
            guard model.loop else { return }
            loopFollow?.cancel()
            loopFollow = Task { @MainActor in
              try? await Task.sleep(for: .milliseconds(250))
              guard !Task.isCancelled else { return }
              model.setLoop(true, range: visibleFrames)
            }
          }
          .onChange(of: model.entered) { _, entered in enteredChanged(entered) }
          .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { lanesWidth = $0 }
          .scrollIndicators(.hidden)
          .scrollDisabled(drag != nil)
          .scrollPosition($position)
          /* At the sides only: the scrubber's knob grows as it is held. */
          .mask(Rectangle().padding(.vertical, -40))
          .onChange(of: model.frame) { _, frame in followPlayhead(frame) }
        }
        .gesture(AxisPinch(changed: pinchChanged, ended: pinchEnded))
        .onChange(of: model.shots.isEmpty, initial: true) { _, empty in
          fitShots(empty: empty, width: proxy.size.width)
        }
        .onChange(of: origin) { old, new in
          /* The lanes reach further back: the same frames stay in view. */
          position.scrollTo(x: max(0, scrollOffset + CGFloat(old - new) * scale))
        }
        .onChange(of: PictureRequest(scale: scale, laneHeight: laneHeight), initial: true) { _, request in
          requestPictures(request)
        }
      }
  }

  private struct PictureRequest: Equatable {
    var scale: CGFloat
    var laneHeight: CGFloat
  }

  /** Pictures as wide as they are at the lanes' height, every so many frames to fill the shots. */
  private func requestPictures(_ request: PictureRequest) {
    let height = request.laneHeight - 8
    let aspect = model.shots.first(where: \.sceneStrip)?.aspect ?? 16.0 / 9.0
    let step = max(1, Int((height * aspect / request.scale).rounded(.up)))
    model.requestPictures(step: step, height: Int(height * displayScale))
  }

  /** Room before the first frame for the scrubber's knob, centred on it. */
  private let leading: CGFloat = 30
  private func x(_ frame: Int) -> CGFloat { leading + CGFloat(frame - origin) * scale }
  private func frame(at x: CGFloat) -> Int { origin + Int(((x - leading) / scale).rounded(.down)) }
  /** The first frame the lanes reach: well before the edit's start, and any shot there, so shots
   * before frame 0 can be scrolled to and moved. */
  private var origin: Int { min(model.start, model.shots.map(\.start).min() ?? model.start) - 250 }

  /* -------------------------------------------------------------------- */
  /* Header, ruler and playhead */

  private var header: some View {
    HStack {
      if let entered = model.entered {
        Button {
          model.leave()
        } label: {
          Label("Story", systemImage: "chevron.backward")
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("blender.storyboard.leave")
        Text(entered)
          .font(.headline)
          .lineLimit(1)
      }
      else {
        Text("Story")
          .font(.headline)
      }
      Spacer(minLength: 8)
      transport
      loopButton
      keysButton
      Spacer(minLength: 8)
      Menu {
        if model.entered != nil {
          Button("New Layer", systemImage: "square.3.layers.3d.top.filled") { model.send("layer_add") }
          Divider()
        }
        Button("New Shot", systemImage: "plus.rectangle") {
          model.send("add")
          Haptics.impact(.light)
        }
        Menu {
          if model.templates.isEmpty {
            Text("No Scene Templates")
          }
          ForEach(model.templates) { template in
            Button(template.name) {
              model.send("add", ["template": template.id])
              Haptics.impact(.light)
            }
          }
        } label: {
          Label("Choose Template", systemImage: "square.on.square.dashed")
        }
      } label: {
        Label("Add Shot", systemImage: "plus")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.bordered)
      .buttonBorderShape(.circle)
      .accessibilityIdentifier("blender.storyboard.add")
      Button(action: timeline.toggleStoryboard) {
        Image(systemName: "film.stack.fill")
          .foregroundStyle(PanelStyle.selection)
          .frame(width: 36, height: 36)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close Story")
    }
    .padding(.horizontal, 12)
    .frame(height: headerHeight)
  }

  /** Keyframe mode: each shot's keys on a rail of their own below it, to move them. */
  private var keysButton: some View {
    Button {
      withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { keysShown.toggle() }
      Haptics.selection()
    } label: {
      Image(systemName: keysShown ? "diamond.fill" : "diamond")
        .foregroundStyle(keysShown ? PanelStyle.selection : .primary)
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .font(.system(size: 15))
    .accessibilityLabel("Keyframes")
    .accessibilityAddTraits(keysShown ? .isSelected : [])
    .disabled(model.entered != nil)
  }

  /** Loops playback within the frames in view, following as they are scrolled and zoomed. */
  private var loopButton: some View {
    Button {
      model.setLoop(!model.loop, range: visibleFrames)
      Haptics.selection()
    } label: {
      Image(systemName: "repeat")
        .foregroundStyle(model.loop ? PanelStyle.selection : .primary)
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .font(.system(size: 17))
    .accessibilityLabel("Loop Frames in View")
    .accessibilityAddTraits(model.loop ? .isSelected : [])
  }

  /** The edit's frames the shots show now, scrolled and zoomed. */
  private var visibleFrames: ClosedRange<Int> {
    let first = max(model.start, frame(at: scrollOffset))
    let last = min(model.end, frame(at: scrollOffset + max(1, lanesWidth)) - 1)
    return first...max(first, last)
  }

  /** Playback, as the timeline's: in the edit's time, from shot to shot. */
  private var transport: some View {
    HStack(spacing: 0) {
      Button {
        timeline.recording.toggle()
        timeline.send("timeline", "autokey")
      } label: {
        Image(systemName: timeline.recording ? "record.circle.fill" : "record.circle")
          .foregroundStyle(timeline.recording ? Color.red : .primary)
          .frame(width: 40, height: 40)
      }
      .accessibilityLabel("Auto Keying")
      transportButton("backward.end.fill", "Jump to Start", "start")
      transportButton("backward.frame.fill", model.entered == nil ? "Previous Cut" : "Previous Keyframe", "prev_key")
      transportButton(timeline.playing ? "pause.fill" : "play.fill", timeline.playing ? "Pause" : "Play", "play")
      transportButton("forward.frame.fill", model.entered == nil ? "Next Cut" : "Next Keyframe", "next_key")
      transportButton("forward.end.fill", "Jump to End", "end")
    }
    .buttonStyle(.plain)
    .font(.system(size: 17))
  }

  private func transportButton(_ symbol: String, _ label: String, _ command: String) -> some View {
    Button {
      /* Looping plays the edit, in the frames in view, even with a shot opened, not the shot's
       * scene alone. */
      if command == "play" && model.loop { model.send("play") } else { timeline.transport(command) }
    } label: {
      Image(systemName: symbol).frame(width: 40, height: 40).contentShape(Rectangle())
    }
    .accessibilityLabel(label)
  }

  /** Selected keys, on one shot's rail or one layer's, in the edit's frames. */
  struct KeySelection: Equatable {
    var owner = ""
    var frames: Set<Int> = []
    func frames(of owner: String) -> Set<Int> { self.owner == owner ? frames : [] }
  }

  /** Keys on a rail \a width wide from \a start, in the edit's frames: tapped to select, dragged
   * to move the selected ones, \a moved by as many frames. */
  private func keyRail(owner: String, keys: [Int], start: Int, width: CGFloat,
                       moved: @escaping ([Int], Int) -> Void) -> some View {
    let selected = selectedKeys.frames(of: owner)
    let shift = keyDrag?.owner == owner ? keyDrag?.frames ?? 0 : 0
    return ZStack(alignment: .leading) {
      Capsule()
        .fill(Color.primary.opacity(0.07))
        .frame(width: width, height: keyRailHeight - 6)
      ForEach(keys, id: \.self) { frame in
        let isSelected = selected.contains(frame)
        Image(systemName: "diamond.fill")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(isSelected ? PanelStyle.selection : Color.primary.opacity(0.7))
          .shadow(color: .black.opacity(0.2), radius: 1)
          .frame(width: 26, height: keyRailHeight)
          .contentShape(Rectangle())
          .position(x: x(frame + (isSelected ? shift : 0)) - x(start), y: keyRailHeight / 2)
          .onTapGesture {
            selectedKeys = KeySelection(owner: owner, frames: isSelected && selected.count == 1 ? [] : [frame])
            Haptics.selection()
          }
          .gesture(DragGesture(minimumDistance: 4)
            .onChanged { value in
              if keyDrag == nil {
                if !isSelected { selectedKeys = KeySelection(owner: owner, frames: [frame]) }
                Haptics.selection()
              }
              let frames = Int((value.translation.width / scale).rounded())
              if frames != keyDrag?.frames {
                if keyDrag != nil { Haptics.selection() }
                keyDrag = (owner, frames)
              }
            }
            .onEnded { _ in
              let keys = Array(selectedKeys.frames(of: owner))
              if let drag = keyDrag, drag.frames != 0 {
                moved(keys, drag.frames)
                selectedKeys = KeySelection(owner: owner, frames: Set(keys.map { $0 + drag.frames }))
              }
              keyDrag = nil
            })
          .accessibilityLabel("Drawing at frame \(frame)")
          .accessibilityAddTraits(isSelected ? .isSelected : [])
      }
    }
    .frame(width: width, height: keyRailHeight, alignment: .leading)
  }

  /** A shot's keys on a rail of its own below it, in keyframe mode. */
  private func shotRail(_ shot: StoryboardShot, laneHeight: CGFloat, lanes: Int) -> some View {
    let place = placement(shot, lanes: lanes)
    let moving = drag?.name == shot.name && drag?.kind == .move ? drag?.frames ?? 0 : 0
    let width = max(8, x(place.end) - x(place.start) - 2)
    let top = rulerHeight + CGFloat(place.channel - 1) * (laneHeight + keyRailHeight) + laneHeight
    return keyRail(owner: "shot:" + shot.name, keys: shot.keys.map { $0 + moving }, start: place.start,
                   width: width) { frames, delta in
      model.moveShotKeys(shot, frames: frames.map { $0 - moving }, by: delta)
    }
    .offset(x: x(place.start) + 1, y: top - 2)
  }

  /** Inside a shot, its layers below it, the top one first: each its keys on a rail, in the
   * edit's time. Tapped to draw on; keys tapped to select and dragged to move them. */
  private func layerStrips(_ shot: StoryboardShot, top: CGFloat) -> some View {
    let width = max(8, x(shot.end) - x(shot.start) - 2)
    /* Their names and controls just before them, staying in view as they are scrolled past. */
    let headers = max(scrollOffset + 4, x(shot.start) - layerHeaderWidth - 4)
    return ZStack(alignment: .topLeading) {
      VStack(spacing: 0) {
        ForEach(model.layers) { layer in
          layerStrip(layer, shot: shot, width: width)
        }
      }
      .offset(x: x(shot.start) + 1)
      VStack(spacing: 0) {
        ForEach(model.layers) { layer in
          layerHeader(layer)
        }
      }
      .offset(x: headers)
    }
    .offset(y: top)
  }

  /** A layer's visibility and its menu, beside its strip. */
  private func layerHeader(_ layer: StoryboardLayer) -> some View {
    HStack(spacing: 2) {
      Button {
        model.setLayerVisible(layer, !layer.visible)
      } label: {
        Image(systemName: layer.visible ? "eye" : "eye.slash")
          .font(.system(size: 13))
          .foregroundStyle(layer.visible ? .primary : .secondary)
          .frame(width: 26, height: layerRowHeight)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(layer.visible ? "Hide \(layer.name)" : "Show \(layer.name)")
      layerMenu(layer)
      Spacer(minLength: 0)
    }
    .frame(width: layerHeaderWidth, height: layerRowHeight)
  }

  private func layerStrip(_ layer: StoryboardLayer, shot: StoryboardShot, width: CGFloat) -> some View {
    keyRail(owner: "layer:" + layer.name, keys: layer.keys.map { $0 + shot.offset }, start: shot.start,
            width: width) { frames, delta in
      model.moveLayerKeys(layer, frames: frames.map { $0 - shot.offset }, by: delta)
    }
    .frame(height: layerRowHeight)
    /* The layer drawn on, highlighted; tapped, it is. */
    .background(layer.active ? PanelStyle.selection.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .contentShape(Rectangle())
    .onTapGesture { model.activateLayer(layer) }
    .opacity(layer.visible ? 1 : 0.5)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(layer.name)
    .accessibilityAddTraits(layer.active ? .isSelected : [])
  }

  /** A layer's name, tapped for what to do with it. */
  private func layerMenu(_ layer: StoryboardLayer) -> some View {
    let offset = model.shots.first { $0.id == model.entered }?.offset ?? 0
    let selected = selectedKeys.frames(of: "layer:" + layer.name).map { $0 - offset }
    let index = model.layers.firstIndex { $0.id == layer.id } ?? 0
    return Menu {
      if !selected.isEmpty {
        Button(selected.count == 1 ? "Delete Drawing" : "Delete \(selected.count) Drawings",
               systemImage: "trash", role: .destructive) {
          model.deleteLayerKeys(layer, frames: selected)
          selectedKeys = KeySelection()
        }
        Divider()
      }
      Button("Move Up", systemImage: "arrow.up") { model.moveLayers(from: [index], to: index - 1) }
        .disabled(index == 0)
      Button("Move Down", systemImage: "arrow.down") { model.moveLayers(from: [index], to: index + 2) }
        .disabled(index >= model.layers.count - 1)
      Button("Clear Drawing", systemImage: "eraser") { model.send("layer_clear", ["layer": layer.name]) }
      Button("Duplicate", systemImage: "plus.square.on.square") {
        model.send("layer_duplicate", ["layer": layer.name])
      }
      Button(layer.locked ? "Unlock" : "Lock", systemImage: layer.locked ? "lock.open" : "lock") {
        model.send("layer_lock", ["layer": layer.name, "value": layer.locked ? 0 : 1])
      }
      Button("Rename…", systemImage: "pencil") {
        newLayerName = layer.name
        renamingLayer = layer
      }
      Divider()
      Button("Delete Layer", systemImage: "trash", role: .destructive) {
        model.send("layer_delete", ["layer": layer.name])
      }
    } label: {
      HStack(spacing: 3) {
        if layer.locked { Image(systemName: "lock.fill").font(.system(size: 9)) }
        Text(layer.name)
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .bold))
      }
      .font(.caption2.weight(.semibold))
      .foregroundStyle(layer.visible ? .primary : .secondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(.ultraThinMaterial, in: Capsule())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .accessibilityLabel("\(layer.name) Actions")
  }

  /** The playhead's knob along the bottom at its frame, dragged anywhere along it to scrub. */
  private func scrubber(width: CGFloat) -> some View {
    let shown = scrubbing ?? model.frame
    return ZStack(alignment: .topLeading) {
      Capsule()
        .fill(.secondary.opacity(0.25))
        .frame(width: max(0, x(model.end + 1) - x(model.start)), height: 4)
        .offset(x: x(model.start), y: scrubberHeight / 2 - 2)
      /* The playhead's line, on from the shots down to the knob. */
      Rectangle()
        .fill(PanelStyle.selection)
        .frame(width: 2, height: scrubberHeight / 2)
        .offset(x: x(shown) - 1)
      Text(verbatim: String(shown))
        .font(.system(size: 14, weight: .bold).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(minWidth: 46, minHeight: 30)
        .panelGlass(.tinted(Color(uiColor: .systemBlue)), interactive: true, in: Capsule())
        .scaleEffect(scrubbing != nil ? 1.15 : 1)
        .fixedSize()
        /* Centred on its frame, as the playhead above it is. */
        .position(x: x(shown), y: scrubberHeight / 2)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: scrubbing != nil)
    }
    .frame(width: width, height: scrubberHeight, alignment: .topLeading)
    .contentShape(Rectangle())
    .gesture(scrub)
    .accessibilityElement()
    .accessibilityLabel("Frame")
    .accessibilityValue(String(shown))
    .accessibilityAdjustableAction { direction in
      model.setFrame(model.frame + (direction == .increment ? 1 : -1), final: true)
    }
  }

  /** Dragged along the ruler or the scrubber, both in the lanes' frames: the playhead and the
   * knob below it move together. */
  private var scrub: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        let frame = min(model.end, max(model.start, frame(at: value.location.x)))
        if frame != scrubbing { Haptics.selection() }
        scrubbing = frame
        model.scrubbing = true
        model.setFrame(frame, final: false)
      }
      .onEnded { value in
        model.setFrame(min(model.end, max(model.start, frame(at: value.location.x))), final: true)
        model.scrubbing = false
        scrubbing = nil
      }
  }

  private func ruler(width: CGFloat) -> some View {
    let step = rulerStep
    return Canvas { context, size in
      if model.loop {
        /* The frames playback loops within. */
        let band = CGRect(x: x(model.loopRange.lowerBound), y: 0,
                          width: x(model.loopRange.upperBound + 1) - x(model.loopRange.lowerBound),
                          height: rulerHeight)
        context.fill(Path(band), with: .color(PanelStyle.selection.opacity(0.18)))
      }
      var frame = Int((Double(origin) / Double(step)).rounded(.down)) * step
      while x(frame) < size.width {
        let px = x(frame)
        context.fill(Path(CGRect(x: px, y: rulerHeight - 7, width: 1, height: 7)), with: .color(.secondary.opacity(0.6)))
        context.draw(Text(verbatim: String(frame)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
                     at: CGPoint(x: px + 3, y: 8), anchor: .leading)
        frame += step
      }
    }
    .frame(width: width, height: rulerHeight)
    .contentShape(Rectangle())
    .gesture(scrub)
    .accessibilityLabel("Edit Time")
    .accessibilityValue("Frame \(model.frame)")
  }

  /** A label every so many frames, at least 60 points apart. */
  private var rulerStep: Int {
    let steps = [1, 2, 5, 10, 12, 24, 48, 96, 240, 480, 960]
    return steps.first { CGFloat($0) * scale >= 60 } ?? 1920
  }

  private func playhead(height: CGFloat) -> some View {
    ZStack(alignment: .top) {
      Rectangle().fill(PanelStyle.selection).frame(width: 2, height: height)
      Capsule().fill(PanelStyle.selection).frame(width: 12, height: rulerHeight - 6).offset(y: 2)
    }
    /* Centred on its frame, as the ruler's marks and the scrubber's knob are. */
    .frame(width: 12)
    .offset(x: x(scrubbing ?? model.frame) - 6)
    .allowsHitTesting(false)
  }

  /* -------------------------------------------------------------------- */
  /* Shots */

  private func placement(_ shot: StoryboardShot, lanes: Int) -> (start: Int, end: Int, channel: Int) {
    var start = shot.start, end = shot.end, channel = shot.channel
    if let moving = drag, moving.name == shot.name {
      switch moving.kind {
        case .move:
          start += moving.frames
          end += moving.frames
          channel = max(1, min(lanes, shot.channel + moving.channels))
        case .left: start = min(end - 1, start + moving.frames)
        case .right: end = max(start + 1, end + moving.frames)
      }
    }
    return (start, end, channel)
  }

  private func shotView(_ shot: StoryboardShot, laneHeight: CGFloat, lanes: Int, channel: Int? = nil) -> some View {
    var place = placement(shot, lanes: lanes)
    if let channel { place.channel = channel }
    let moving = drag?.name == shot.name && drag?.kind == .move
    let width = max(8, x(place.end) - x(place.start) - 2)
    let height = laneHeight - 6
    /* Channel 1 at the top, the lanes going down from it, so taller lanes keep it in view. */
    let top = rulerHeight + CGFloat(place.channel - 1) * (laneHeight + railHeight) + 3
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    return ZStack(alignment: .bottomLeading) {
      filmStrip(shot, start: place.start, end: place.end, width: width, height: height)
      /* Too narrow to name, zoomed out, the pictures alone. */
      if width >= 72 && height >= 40 {
        nameMenu(shot)
          .padding(5)
          .frame(maxWidth: width, alignment: .leading)
      }
    }
    .frame(width: width, height: height)
    .clipShape(shape)
    .overlay(shape.strokeBorder(shot.selected ? PanelStyle.selection : Color.white.opacity(0.2),
                                lineWidth: shot.selected ? 3 : 1))
    .overlay {
      if shot.selected && width > gripWidth * 3 {
        HStack(spacing: 0) {
          grip(shot, left: true, height: height)
          Spacer(minLength: 0)
          grip(shot, left: false, height: height)
        }
      }
    }
    .overlay(alignment: .top) {
      /* The selected shot opens to be edited on its own, in its own scene's time. */
      if shot.selected && model.entered != shot.name && drag == nil {
        Button("Edit") { model.enter(shot) }
          .font(.caption.weight(.semibold))
          .buttonStyle(.borderedProminent)
          .buttonBorderShape(.capsule)
          .controlSize(.mini)
          .padding(.top, 5)
          .transition(.scale(scale: 0.8).combined(with: .opacity))
          .accessibilityIdentifier("blender.storyboard.edit")
      }
    }
    .opacity(shot.muted ? 0.45 : model.entered != nil && model.entered != shot.name ? 0.4 : 1)
    .shadow(color: .black.opacity(moving ? 0.35 : 0), radius: 10, y: 5)
    .scaleEffect(moving ? 1.03 : 1)
    .onTapGesture {
      /* Tapped again once chosen, what can be done with it, in the system's edit menu over it. */
      if shot.selected && shot.active {
        editMenuShot = shot.name
        editMenuRequest += 1
        return
      }
      /* Choosing a shot shows it, to draw in; another than the one opened goes back to the edit. */
      if model.entered != shot.name { model.leave() }
      model.select(shot)
      if !(shot.start..<shot.end).contains(model.frame) { model.setFrame(shot.start, final: true) }
    }
    .background {
      if shot.selected {
        EditMenuHost(request: editMenuShot == shot.name ? editMenuRequest : 0) { shotMenu(shot) }
      }
    }
    /* Twice opens it, to work in its own time. */
    .simultaneousGesture(TapGesture(count: 2).onEnded { model.enter(shot) })
    .offset(x: x(place.start) + 1, y: top)
    .zIndex(drag?.name == shot.name ? 1 : 0)
    .animation(.spring(response: 0.18, dampingFraction: 0.9), value: moving)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(shot.name)
    .accessibilityValue("Frames \(shot.start) to \(shot.end - 1)")
    .accessibilityAddTraits(shot.selected ? [.isSelected, .isButton] : .isButton)
  }

  /** What can be done with a chosen shot, as the system's edit menu over it. */
  private func shotMenu(_ shot: StoryboardShot) -> UIMenu {
    UIMenu(children: [
      UIAction(title: "Edit", image: UIImage(systemName: "arrow.up.forward.square")) { _ in model.enter(shot) },
      UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { _ in
        model.send("duplicate", ["name": shot.name])
      },
      UIAction(title: "Rename…", image: UIImage(systemName: "pencil")) { _ in
        newName = shot.name
        renaming = shot
      },
      templateAction(shot),
      UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
        model.send("delete", ["name": shot.name])
      },
    ])
  }

  /** Keeps the shot's scene as a scene template to start new shots from, or no longer. */
  private func templateAction(_ shot: StoryboardShot) -> UIAction {
    UIAction(title: "Save as Template", image: UIImage(systemName: "square.on.square.dashed"),
             state: shot.template ? .on : .off) { _ in
      model.send("template", ["name": shot.name, "value": shot.template ? 0 : 1])
    }
  }

  /** The shot's name, tapped for what to do with it: show another scene, rename it, and so on. */
  private func nameMenu(_ shot: StoryboardShot) -> some View {
    Menu {
      Button("Edit", systemImage: "arrow.up.forward.square") { model.enter(shot) }
      if shot.sceneStrip && !model.scenes.isEmpty {
        Picker(selection: Binding(get: { shot.scene }, set: { scene in
          model.send("set_scene", ["name": shot.name, "value": scene])
        })) {
          ForEach(model.scenes, id: \.self) { Text($0).tag($0) }
        } label: {
          Label("Scene", systemImage: "film")
        }
        .pickerStyle(.menu)
      }
      Button("Rename…", systemImage: "pencil") {
        newName = shot.name
        renaming = shot
      }
      Button("Duplicate", systemImage: "plus.square.on.square") { model.send("duplicate", ["name": shot.name]) }
      let drawings = Array(selectedKeys.frames(of: "shot:" + shot.name))
      if !drawings.isEmpty {
        Button(drawings.count == 1 ? "Delete Drawing" : "Delete \(drawings.count) Drawings", systemImage: "trash",
               role: .destructive) {
          model.deleteShotKeys(shot, frames: drawings)
          selectedKeys = KeySelection()
        }
      }
      if shot.sceneStrip {
        Toggle("Save as Template", systemImage: "square.on.square.dashed", isOn: Binding(
          get: { shot.template },
          set: { model.send("template", ["name": shot.name, "value": $0 ? 1 : 0]) }))
      }
      Divider()
      Button("Delete", systemImage: "trash", role: .destructive) { model.send("delete", ["name": shot.name]) }
    } label: {
      HStack(spacing: 3) {
        Text(shot.name)
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .bold))
      }
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.primary)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(.ultraThinMaterial, in: Capsule())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .accessibilityLabel("\(shot.name), \(shot.scene)")
  }

  /** The shot's frames side by side at their times, as the Sequencer shows a movie's; a frame
   * still being drawn shows the one before it, so the strip is never broken. */
  private func filmStrip(_ shot: StoryboardShot, start: Int, end: Int, width: CGFloat, height: CGFloat) -> some View {
    /* While a shot moves, its pictures move with it; trimmed, they stay where they are. */
    let offset = drag?.name == shot.name && drag?.kind == .move ? drag?.frames ?? 0 : 0
    return Canvas { context, size in
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(tagColor(shot.color).opacity(0.3)))
      let pictures = shot.pictures
      guard !pictures.isEmpty else { return }
      let pictureWidth = height * shot.aspect
      /* A picture not read yet shows its neighbour, so the strip never has a gap. */
      var last = pictures.lazy.compactMap { ShotPictures.image($0.path) }.first
      for (index, picture) in pictures.enumerated() {
        let left = x(picture.frame + offset) - x(start)
        let next = index + 1 < pictures.count ? x(pictures[index + 1].frame + offset) - x(start) : size.width
        if let image = ShotPictures.image(picture.path) { last = image }
        guard next > 0, left < size.width, let image = last else { continue }
        /* Repeated to fill the room up to the next picture, should that be further. */
        var cell = left
        repeat {
          context.draw(image, in: CGRect(x: cell, y: 0, width: pictureWidth, height: size.height))
          cell += pictureWidth
        } while cell < next
      }
      /* Where each drawing begins: a line through the strip and a key on it, as the timeline
       * marks keys. */
      for key in shot.keys {
        let at = x(key + offset) - x(start)
        guard at >= 0, at < size.width else { continue }
        if at > 1 {
          context.fill(Path(CGRect(x: at - 0.5, y: 0, width: 1.5, height: size.height)),
                       with: .color(.black.opacity(0.45)))
        }
        let center = CGPoint(x: max(6, at), y: size.height - 8)
        let diamond = Path { path in
          path.move(to: CGPoint(x: center.x, y: center.y - 5))
          path.addLine(to: CGPoint(x: center.x + 5, y: center.y))
          path.addLine(to: CGPoint(x: center.x, y: center.y + 5))
          path.addLine(to: CGPoint(x: center.x - 5, y: center.y))
          path.closeSubpath()
        }
        context.fill(diamond, with: .color(.white))
        context.stroke(diamond, with: .color(.black.opacity(0.6)), lineWidth: 1)
      }
    }
    .frame(width: width, height: height)
  }

  /** The handle at one end of the selected shot, dragged to make it longer or shorter. */
  private func grip(_ shot: StoryboardShot, left: Bool, height: CGFloat) -> some View {
    Capsule()
      .fill(.white)
      .shadow(color: .black.opacity(0.4), radius: 1)
      .frame(width: 5, height: min(30, height * 0.45))
      .frame(width: gripWidth, height: height)
      .contentShape(Rectangle())
      .highPriorityGesture(shotDrag(shot, kind: left ? .left : .right, laneHeight: 1))
      .accessibilityLabel(left ? "Start of \(shot.name)" : "End of \(shot.name)")
  }

  /** Measured in the window, which stays put while the shot follows the finger. Edges snap to
   * the other shots' and to the playhead. */
  private func shotDrag(_ shot: StoryboardShot, kind: ShotDrag.Kind, laneHeight: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 2, coordinateSpace: .global)
      .onChanged { dragChanged(shot, kind: kind, translation: $0.translation, laneHeight: laneHeight) }
      .onEnded { _ in dragEnded(shot, kind: kind) }
  }

  /** Moving a shot waits for a hold, so a swipe over the shots scrolls them and never moves one
   * by accident. The shot under the finger lifts the moment the hold takes, and follows the
   * finger from there, whichever shot it is where they overlap. */
  private func laneMove(laneHeight: CGFloat, lanes: Int) -> some UIGestureRecognizerRepresentable {
    LaneHold { phase, location in
      switch phase {
        case .began:
          /* Inside a shot, its layers are worked on rather than shots moved. */
          guard model.entered == nil,
                let shot = shot(at: location, laneHeight: laneHeight, lanes: lanes) else { return false }
          movingShot = shot.name
          moveStart = location
          dragChanged(shot, kind: .move, translation: .zero, laneHeight: laneHeight)
        case .changed:
          guard let name = movingShot, let shot = model.shots.first(where: { $0.name == name }) else { return true }
          dragChanged(shot, kind: .move,
                      translation: CGSize(width: location.x - moveStart.x, height: location.y - moveStart.y),
                      laneHeight: laneHeight)
        case .ended:
          defer { movingShot = nil }
          guard let name = movingShot, let shot = model.shots.first(where: { $0.name == name }) else { return true }
          dragEnded(shot, kind: .move)
        default:
          movingShot = nil
          drag = nil
      }
      return true
    }
  }

  /** The shot drawn at a point of the lanes, the topmost where they overlap. */
  private func shot(at point: CGPoint, laneHeight: CGFloat, lanes: Int) -> StoryboardShot? {
    model.shots.last { shot in
      let top = rulerHeight + CGFloat(shot.channel - 1) * (laneHeight + railHeight) + 3
      return CGRect(x: x(shot.start), y: top, width: x(shot.end) - x(shot.start), height: laneHeight - 6)
        .contains(point)
    }
  }

  private func dragChanged(_ shot: StoryboardShot, kind: ShotDrag.Kind, translation: CGSize, laneHeight: CGFloat) {
    guard pinchStart == nil, !pinchCancelled else { return }
    if drag == nil {
      drag = ShotDrag(name: shot.name, kind: kind, frames: 0, channels: 0)
      snappedTo = nil
      if kind == .move { Haptics.impact(.light) } else { Haptics.selection() }
      model.select(shot)
    }
    guard var current = drag else { return }
    let frames = snapped(shot, kind: kind, frames: Int((translation.width / scale).rounded()))
    let channels = kind == .move ? Int((translation.height / (laneHeight + railHeight)).rounded()) : 0
    if frames != current.frames || channels != current.channels {
      current.frames = frames
      current.channels = channels
      drag = current
    }
  }

  private func dragEnded(_ shot: StoryboardShot, kind: ShotDrag.Kind) {
    if pinchCancelled {
      pinchCancelled = false
      drag = nil
      return
    }
    guard let current = drag else { return }
    /* The shot is placed where it was let go in the same update the drag ends in, so it does
     * not jump back first. */
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      switch kind {
        case .move:
          model.move(shot, start: shot.start + current.frames,
                     channel: max(1, min(model.channels + 1, shot.channel + current.channels)))
        case .left:
          if current.frames != 0 { model.trim(shot, left: true, frame: shot.start + current.frames) }
        case .right:
          if current.frames != 0 { model.trim(shot, left: false, frame: shot.end + current.frames) }
      }
      drag = nil
    }
  }

  /** The frames moved, snapped so an edge meets another shot's edge or the playhead nearby. */
  private func snapped(_ shot: StoryboardShot, kind: ShotDrag.Kind, frames: Int) -> Int {
    let reach = max(1, Int((10 / scale).rounded()))
    let targets = model.shots.filter { $0.id != shot.id }.flatMap { [$0.start, $0.end] } + [model.frame, model.start]
    let edges: [Int] = switch kind {
      case .move: [shot.start, shot.end]
      case .left: [shot.start]
      case .right: [shot.end]
    }
    var best: (delta: Int, target: Int)?
    for edge in edges {
      for target in targets {
        let delta = target - (edge + frames)
        if abs(delta) <= reach, best.map({ abs(delta) < abs($0.delta) }) ?? true { best = (delta, target) }
      }
    }
    let target = best?.target
    if target != snappedTo {
      snappedTo = target
      if target != nil { Haptics.selection() }
    }
    return frames + (best?.delta ?? 0)
  }

  /** Blender's strip color tags; none is the scene strip's own color. */
  private func tagColor(_ tag: Int) -> Color {
    switch tag {
      case 1: .red
      case 2: .orange
      case 3: .yellow
      case 4: .green
      case 5: .blue
      case 6: .purple
      case 7: .pink
      case 8: .brown
      case 9: .gray
      default: Color(red: 0.55, green: 0.7, blue: 0.55)
    }
  }
}

/** A pinch measured along each axis: how far apart the fingers are across and up and down,
 * against where they began. Fingers close together along an axis leave it unchanged. */
private struct AxisPinch: UIGestureRecognizerRepresentable {
  /** How far apart across and up and down, against where they began, and where between them. */
  let changed: (CGSize, CGPoint) -> Void
  let ended: () -> Void

  /** Alongside the scroll view's own panning, which stops as two fingers pinch. */
  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var start = CGSize.zero

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
  }

  func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

  func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer {
    let recognizer = UIPinchGestureRecognizer()
    recognizer.delegate = context.coordinator
    return recognizer
  }

  private func spread(_ recognizer: UIPinchGestureRecognizer) -> CGSize? {
    guard recognizer.numberOfTouches >= 2 else { return nil }
    let a = recognizer.location(ofTouch: 0, in: recognizer.view)
    let b = recognizer.location(ofTouch: 1, in: recognizer.view)
    return CGSize(width: abs(a.x - b.x), height: abs(a.y - b.y))
  }

  func handleUIGestureRecognizerAction(_ recognizer: UIPinchGestureRecognizer, context: Context) {
    switch recognizer.state {
      case .began:
        context.coordinator.start = spread(recognizer) ?? .zero
      case .changed:
        guard let now = spread(recognizer) else { return }
        let start = context.coordinator.start
        /* Under a finger's width apart, that axis is not being pinched. */
        let across = start.width > 40 ? now.width / start.width : 1
        let up = start.height > 40 ? now.height / start.height : 1
        changed(CGSize(width: across, height: up), context.converter.localLocation)
      default:
        ended()
    }
  }
}

/** A hold that picks up what is under the finger and then follows it, as lifting an item to drag
 * it does everywhere else. Away from a shot it lets go at once, leaving the scroll view to pan. */
private struct LaneHold: UIGestureRecognizerRepresentable {
  /** Whether there was something to pick up, asked as the hold takes. */
  let changed: (UIGestureRecognizer.State, CGPoint) -> Bool

  func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
    let recognizer = UILongPressGestureRecognizer()
    recognizer.minimumPressDuration = 0.2
    recognizer.allowableMovement = 10
    return recognizer
  }

  func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
    let location = context.converter.localLocation
    if !changed(recognizer.state, location), recognizer.state == .began {
      /* Nothing there: let go, so the next touch is free. */
      recognizer.isEnabled = false
      recognizer.isEnabled = true
    }
  }
}

/** \} */

/** Shows the system's edit menu over its view each time `request` changes, as a selected item
 * does when tapped again. */
private struct EditMenuHost: UIViewRepresentable {
  let request: Int
  let menu: () -> UIMenu

  final class Coordinator: NSObject, UIEditMenuInteractionDelegate {
    var menu: () -> UIMenu = { UIMenu(children: []) }
    var shown = 0

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
      menu()
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.isUserInteractionEnabled = false
    view.addInteraction(UIEditMenuInteraction(delegate: context.coordinator))
    context.coordinator.shown = request
    return view
  }

  func updateUIView(_ view: UIView, context: Context) {
    context.coordinator.menu = menu
    guard request != context.coordinator.shown, request > 0 else { return }
    context.coordinator.shown = request
    guard let interaction = view.interactions.compactMap({ $0 as? UIEditMenuInteraction }).first else { return }
    let point = CGPoint(x: view.bounds.midX, y: view.bounds.minY)
    interaction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
  }
}
