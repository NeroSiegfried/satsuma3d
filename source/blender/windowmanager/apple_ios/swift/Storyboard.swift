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
  var color: Int
  /** Width over height of its scene's frames. */
  var aspect: Double
  var pictures: [StoryboardPicture]

  var id: String { name }

  init(_ json: JSON) {
    name = json.string("name") ?? ""
    channel = json.int("channel") ?? 1
    start = json.int("start") ?? 0
    end = json.int("end") ?? 0
    scene = json.string("scene") ?? ""
    sceneStrip = json.bool("scene_strip")
    selected = json.bool("selected")
    active = json.bool("active")
    muted = json.bool("muted")
    color = json.int("color") ?? 0
    aspect = json.double("aspect") ?? 16.0 / 9.0
    pictures = ((json["pictures"] as? [Any]) ?? []).compactMap { entry in
      guard let pair = entry as? [Any], pair.count == 2, let frame = (pair[0] as? NSNumber)?.intValue,
            let path = pair[1] as? String else { return nil }
      return StoryboardPicture(frame: frame, path: path)
    }
  }
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
  private(set) var shots: [StoryboardShot] = []
  /** The scenes a shot can show instead. */
  private(set) var scenes: [String] = []
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
    /* The frame comes from the timeline's snapshot, every frame; this one is older. */
    let scenes = (snapshot["scenes"] as? [String]) ?? []
    if scenes != self.scenes { self.scenes = scenes }
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
      }
      shown.start = kept.shot.start
      shown.end = kept.shot.end
      shown.channel = kept.shot.channel
      return shown
    }
    if next != shots { shots = next }
  }

  /** The edit's frame from the timeline's snapshot, which playback updates every frame. */
  func follow(frame: Int) {
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
    let frame = min(end, max(start, frame))
    self.frame = frame
    /* Each frame sent switches scenes as needed: often enough to follow, not every touch. */
    guard final || Date().timeIntervalSince(lastFrameSent) > 1.0 / 30 else { return }
    lastFrameSent = Date()
    send("frame", ["frame": frame])
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

private let headerHeight: CGFloat = 40
private let rulerHeight: CGFloat = 24
private let gripWidth: CGFloat = 18

struct StoryboardView: View {
  let model: StoryboardModel
  /** Points per frame, pinched apart sideways to zoom in time. */
  @State private var scale: CGFloat = 4
  /** How much taller than fits the lanes are, pinched apart up and down. */
  @State private var laneZoom: CGFloat = 1
  @State private var pinchStart: (scale: CGFloat, laneZoom: CGFloat)?
  @State private var fitted = false
  /** A shot being moved or trimmed: by how many frames, and lanes. */
  @State private var drag: ShotDrag?
  /** The snap the drag last made, to tap once as it takes. */
  @State private var snappedTo: Int?
  @State private var renaming: StoryboardShot?
  @State private var newName = ""
  @Environment(\.displayScale) private var displayScale

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
      GeometryReader { proxy in
        /* An empty lane below the shots, to move one into. */
        let lanes = model.channels + 1
        /* All of them in the panel's height, unless pinched taller, then scrolled to. */
        let fit = max(28, min(120, (proxy.size.height - rulerHeight - 4) / CGFloat(lanes)))
        let laneHeight = min(240, fit * laneZoom)
        let width = max(proxy.size.width, x(model.end + 1) + 160)
        ScrollViewReader { scroller in
          ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
              ruler(width: width)
              ForEach(model.shots) { shot in
                shotView(shot, laneHeight: laneHeight, lanes: lanes)
              }
              playhead(height: rulerHeight + CGFloat(lanes) * laneHeight)
                .id("playhead")
            }
            .frame(width: width, height: rulerHeight + CGFloat(lanes) * laneHeight, alignment: .topLeading)
          }
          .scrollIndicators(.hidden)
          .scrollDisabled(drag != nil)
          .clipped()
          .onChange(of: model.frame) { _, _ in
            /* Playback keeps the playhead in view. */
            if model.playing { scroller.scrollTo("playhead", anchor: .center) }
          }
        }
        .gesture(AxisPinch { stretch in
          let base = pinchStart ?? (scale, laneZoom)
          pinchStart = base
          scale = min(40, max(0.5, base.scale * stretch.width))
          laneZoom = min(4, max(1, base.laneZoom * stretch.height))
        } ended: {
          pinchStart = nil
        })
        .onChange(of: model.shots.isEmpty, initial: true) { _, empty in
          /* The shots in view to begin with. */
          guard !empty, !fitted else { return }
          fitted = true
          let last = model.shots.map(\.end).max() ?? model.end
          scale = min(40, max(0.5, (proxy.size.width - 60) / CGFloat(max(1, last - model.start))))
        }
        .onChange(of: PictureRequest(scale: scale, laneHeight: laneHeight), initial: true) { _, request in
          requestPictures(request)
        }
      }
    }
    .alert("Rename Shot", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
      TextField("Name", text: $newName)
      Button("Rename") {
        if let shot = renaming, !newName.isEmpty { model.send("rename", ["name": shot.name, "value": newName]) }
        renaming = nil
      }
      Button("Cancel", role: .cancel) { renaming = nil }
    }
    .accessibilityIdentifier("blender.storyboard")
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

  private func x(_ frame: Int) -> CGFloat { 12 + CGFloat(frame - model.start) * scale }
  private func frame(at x: CGFloat) -> Int { model.start + Int(((x - 12) / scale).rounded(.down)) }

  /* -------------------------------------------------------------------- */
  /* Header, ruler and playhead */

  private var header: some View {
    HStack {
      if let entered = model.entered {
        Button {
          model.leave()
        } label: {
          Label("Storyboard", systemImage: "chevron.backward")
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("blender.storyboard.leave")
        Text(entered)
          .font(.headline)
          .lineLimit(1)
      }
      else {
        Text("Storyboard")
          .font(.headline)
      }
      Spacer()
      Button {
        model.send("add")
        Haptics.impact(.light)
      } label: {
        Label("New Shot", systemImage: "plus")
      }
      .buttonStyle(.bordered)
      .buttonBorderShape(.capsule)
      .controlSize(.small)
      .accessibilityIdentifier("blender.storyboard.add")
    }
    .padding(.horizontal, 12)
    .frame(height: headerHeight)
  }

  private func ruler(width: CGFloat) -> some View {
    let step = rulerStep
    return Canvas { context, size in
      var frame = (model.start / step) * step
      while x(frame) < size.width {
        let px = x(frame)
        if frame >= model.start {
          context.fill(Path(CGRect(x: px, y: rulerHeight - 7, width: 1, height: 7)), with: .color(.secondary.opacity(0.6)))
          context.draw(Text(verbatim: String(frame)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
                       at: CGPoint(x: px + 3, y: 8), anchor: .leading)
        }
        frame += step
      }
    }
    .frame(width: width, height: rulerHeight)
    .contentShape(Rectangle())
    .gesture(DragGesture(minimumDistance: 0)
      .onChanged { value in
        model.scrubbing = true
        model.setFrame(frame(at: value.location.x), final: false)
      }
      .onEnded { value in
        model.setFrame(frame(at: value.location.x), final: true)
        model.scrubbing = false
      })
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
    .offset(x: x(model.frame) - 1)
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

  private func shotView(_ shot: StoryboardShot, laneHeight: CGFloat, lanes: Int) -> some View {
    let place = placement(shot, lanes: lanes)
    let moving = drag?.name == shot.name && drag?.kind == .move
    let width = max(8, x(place.end) - x(place.start) - 2)
    let height = laneHeight - 6
    /* Channel 1 at the top, the lanes going down from it, so taller lanes keep it in view. */
    let top = rulerHeight + CGFloat(place.channel - 1) * laneHeight + 3
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
      /* Choosing a shot shows it, to draw in; another than the one opened goes back to the edit. */
      if model.entered != shot.name { model.leave() }
      model.select(shot)
      if !(shot.start..<shot.end).contains(model.frame) { model.setFrame(shot.start, final: true) }
    }
    /* Twice opens it, to work in its own time. */
    .simultaneousGesture(TapGesture(count: 2).onEnded { model.enter(shot) })
    .gesture(shotDrag(shot, kind: .move, laneHeight: laneHeight))
    .contextMenu {
      Button("Open Shot", systemImage: "arrow.up.forward.square") { model.enter(shot) }
      Button("Duplicate", systemImage: "plus.square.on.square") { model.send("duplicate", ["name": shot.name]) }
      Button("Rename…", systemImage: "pencil") {
        newName = shot.name
        renaming = shot
      }
      Divider()
      Button("Delete", systemImage: "trash", role: .destructive) { model.send("delete", ["name": shot.name]) }
    }
    .offset(x: x(place.start) + 1, y: top)
    .zIndex(drag?.name == shot.name ? 1 : 0)
    .animation(.spring(response: 0.18, dampingFraction: 0.9), value: moving)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(shot.name)
    .accessibilityValue("Frames \(shot.start) to \(shot.end - 1)")
    .accessibilityAddTraits(shot.selected ? [.isSelected, .isButton] : .isButton)
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
    DragGesture(minimumDistance: kind == .move ? 8 : 2, coordinateSpace: .global)
      .onChanged { value in
        if drag == nil {
          drag = ShotDrag(name: shot.name, kind: kind, frames: 0, channels: 0)
          snappedTo = nil
          Haptics.selection()
          model.select(shot)
        }
        guard var current = drag else { return }
        let frames = snapped(shot, kind: kind, frames: Int((value.translation.width / scale).rounded()))
        let channels = kind == .move ? Int((value.translation.height / laneHeight).rounded()) : 0
        if frames != current.frames || channels != current.channels {
          current.frames = frames
          current.channels = channels
          drag = current
        }
      }
      .onEnded { _ in
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
  let changed: (CGSize) -> Void
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
        changed(CGSize(width: across, height: up))
      default:
        ended()
    }
  }
}

/** \} */
