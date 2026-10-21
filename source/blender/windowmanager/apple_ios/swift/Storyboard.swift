/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The storyboard grown out of the timeline: the shots of the workspace's sequencer scene, each a
 * scene strip shown with a picture of its first frame, along the edit's time. Shots are dragged to
 * move them, their edges to make them longer or shorter, and a new one is added after the
 * selected one. Moving the playhead over a shot shows its scene to draw in, as Blender's
 * Storyboarding workspace does. See `sequencer_native.cc` for Blender's side.
 */

import SwiftUI
import UIKit

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
  var thumbnail: String

  var id: String { name }
  var length: Int { max(1, end - start) }

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
    thumbnail = json.string("thumbnail") ?? ""
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
  /** The scene the window shows: the shot being drawn in. */
  private(set) var shownScene = ""
  @ObservationIgnored private var raw: NSDictionary?
  @ObservationIgnored private var sequence: UInt64 = 0
  /** While a finger moves the playhead, Blender's frame waits. */
  @ObservationIgnored var scrubbing = false
  @ObservationIgnored private var lastFrameSent = Date.distantPast

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
    shownScene = snapshot.string("shown") ?? ""
    if !scrubbing, let frame = snapshot.int("frame"), frame != self.frame { self.frame = frame }
    let next = snapshot.array("strips").map(StoryboardShot.init)
    if next != shots { shots = next }
  }

  /** The edit's frame from the timeline's snapshot, which playback updates every frame. */
  func follow(frame: Int) {
    if !scrubbing, frame != self.frame { self.frame = frame }
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

  /* Each edit shows at once; Blender's snapshot confirms it. */
  func select(_ shot: StoryboardShot) {
    shots = shots.map { var other = $0; other.selected = $0.id == shot.id; other.active = other.selected; return other }
    send("select", ["name": shot.name])
  }

  func move(_ shot: StoryboardShot, start: Int, channel: Int) {
    guard start != shot.start || channel != shot.channel else { return }
    if let index = shots.firstIndex(where: { $0.id == shot.id }) {
      shots[index].end += start - shots[index].start
      shots[index].start = start
      shots[index].channel = channel
    }
    send("move", ["name": shot.name, "start": start, "channel": channel])
  }

  func trim(_ shot: StoryboardShot, left: Bool, frame: Int) {
    if let index = shots.firstIndex(where: { $0.id == shot.id }) {
      if left { shots[index].start = min(frame, shots[index].end - 1) }
      else { shots[index].end = max(frame, shots[index].start + 1) }
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
  static var cache: [String: UIImage] = [:]

  static func image(_ path: String) -> UIImage? {
    guard !path.isEmpty else { return nil }
    if let image = cache[path] { return image }
    guard let image = UIImage(contentsOfFile: path) else { return nil }
    if cache.count > 200 { cache.removeAll() }
    cache[path] = image
    return image
  }
}

private let rulerHeight: CGFloat = 26
private let edgeWidth: CGFloat = 16

struct StoryboardView: View {
  let model: StoryboardModel
  /** Points per frame, pinched to zoom. */
  @State private var scale: CGFloat = 4
  @State private var pinchStart: CGFloat?
  @State private var fitted = false
  /** A shot being moved or trimmed: by how many frames, and lanes. */
  @State private var drag: ShotDrag?
  @State private var renaming: StoryboardShot?
  @State private var newName = ""

  private struct ShotDrag: Equatable {
    enum Kind { case move, left, right }
    var name: String
    var kind: Kind
    var frames: Int
    var channels: Int
  }

  var body: some View {
    GeometryReader { proxy in
      let lanes = model.channels + (drag?.kind == .move ? 1 : 0)
      let laneHeight = max(56, min(110, (proxy.size.height - rulerHeight - 8) / CGFloat(max(1, model.channels))))
      let width = max(proxy.size.width, x(model.end + 1) + 120)
      ScrollViewReader { scroller in
        ScrollView(.horizontal) {
          ZStack(alignment: .topLeading) {
            ruler(width: width)
            ForEach(model.shots) { shot in
              shotView(shot, laneHeight: laneHeight, lanes: lanes)
            }
            addTile(laneHeight: laneHeight)
            playhead(height: rulerHeight + CGFloat(lanes) * laneHeight)
              .id("playhead")
          }
          .frame(width: width, height: rulerHeight + CGFloat(lanes) * laneHeight, alignment: .topLeading)
          .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .onChange(of: model.frame) { _, _ in
          /* Playback keeps the playhead in view. */
          if model.playing { withAnimation(.linear(duration: 0.2)) { scroller.scrollTo("playhead", anchor: .center) } }
        }
      }
      .simultaneousGesture(MagnifyGesture()
        .onChanged { value in
          let base = pinchStart ?? scale
          pinchStart = base
          scale = min(40, max(0.5, base * value.magnification))
        }
        .onEnded { _ in pinchStart = nil })
      .onChange(of: model.shots.isEmpty, initial: true) { _, empty in
        /* The shots in view to begin with, the new shot's panel after them. */
        guard !empty, !fitted else { return }
        fitted = true
        let last = model.shots.map(\.end).max() ?? model.end
        let frames = CGFloat(max(1, last - model.start))
        scale = min(40, max(0.5, (proxy.size.width - 140) / frames))
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

  private func x(_ frame: Int) -> CGFloat { 12 + CGFloat(frame - model.start) * scale }
  private func frame(at x: CGFloat) -> Int { model.start + Int(((x - 12) / scale).rounded()) }

  /* -------------------------------------------------------------------- */
  /* Ruler and playhead */

  private func ruler(width: CGFloat) -> some View {
    let step = rulerStep
    return Canvas { context, size in
      var frame = (model.start / step) * step
      while x(frame) < size.width {
        let px = x(frame)
        if frame >= model.start {
          context.fill(Path(CGRect(x: px, y: rulerHeight - 8, width: 1, height: 8)), with: .color(.secondary.opacity(0.6)))
          context.draw(Text(verbatim: String(frame)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
                       at: CGPoint(x: px + 3, y: 9), anchor: .leading)
        }
        frame += step
      }
      /* The edit's range. */
      context.fill(Path(CGRect(x: x(model.start), y: rulerHeight - 2, width: x(model.end + 1) - x(model.start), height: 2)),
                   with: .color(.secondary.opacity(0.35)))
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
    .offset(x: x(model.frame) + scale / 2 - 1)
    .allowsHitTesting(false)
  }

  /* -------------------------------------------------------------------- */
  /* Shots */

  private func shotView(_ shot: StoryboardShot, laneHeight: CGFloat, lanes: Int) -> some View {
    let moving = drag?.name == shot.name ? drag : nil
    var start = shot.start, end = shot.end, channel = shot.channel
    if let moving {
      switch moving.kind {
        case .move:
          start += moving.frames
          end += moving.frames
          channel = max(1, min(lanes, shot.channel + moving.channels))
        case .left: start = min(end - 1, start + moving.frames)
        case .right: end = max(start + 1, end + moving.frames)
      }
    }
    let width = max(8, x(end) - x(start) - 2)
    /* Channel 1 at the bottom, as in the Sequencer. */
    let top = rulerHeight + CGFloat(lanes - channel) * laneHeight
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    return ZStack(alignment: .bottomLeading) {
      shape.fill(tagColor(shot.color).opacity(0.35))
      if let image = ShotPictures.image(shot.thumbnail) {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: width, height: laneHeight - 6)
          .clipped()
      }
      Text(shot.name)
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(5)
        .frame(maxWidth: width, alignment: .leading)
      if shot.selected {
        HStack {
          edgeGrip
          Spacer(minLength: 0)
          edgeGrip
        }
        .frame(maxHeight: .infinity)
      }
    }
    .frame(width: width, height: laneHeight - 6)
    .clipShape(shape)
    .overlay(shape.strokeBorder(shot.selected ? PanelStyle.selection : Color.white.opacity(0.15),
                                lineWidth: shot.selected ? 3 : 1))
    .opacity(shot.muted ? 0.45 : 1)
    .scaleEffect(moving?.kind == .move ? 1.03 : 1)
    .shadow(color: .black.opacity(moving?.kind == .move ? 0.35 : 0), radius: 8, y: 4)
    .zIndex(moving != nil ? 1 : 0)
    .contentShape(shape)
    .onTapGesture {
      /* Choosing a shot shows it, to draw in. */
      model.select(shot)
      model.setFrame(shot.start, final: true)
    }
    .gesture(shotDrag(shot, laneHeight: laneHeight, width: width))
    .contextMenu {
      Button("Show", systemImage: "eye") {
        model.select(shot)
        model.setFrame(shot.start, final: true)
      }
      Button("Duplicate", systemImage: "plus.square.on.square") { model.send("duplicate", ["name": shot.name]) }
      Button("Rename…", systemImage: "pencil") {
        newName = shot.name
        renaming = shot
      }
      Divider()
      Button("Delete", systemImage: "trash", role: .destructive) { model.send("delete", ["name": shot.name]) }
    }
    .offset(x: x(start) + 1, y: top + 3)
    .animation(drag == nil ? .spring(response: 0.3, dampingFraction: 0.85) : nil, value: shot)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(shot.name)
    .accessibilityValue("Frames \(shot.start) to \(shot.end - 1)")
    .accessibilityAddTraits(shot.selected ? [.isSelected, .isButton] : .isButton)
  }

  private var edgeGrip: some View {
    Capsule()
      .fill(.white)
      .shadow(color: .black.opacity(0.4), radius: 1)
      .frame(width: 4, height: 26)
      .padding(.horizontal, 5)
  }

  /** Dragged from an edge of the selected shot, it is trimmed; from anywhere else, moved, to
   * other frames and other lanes. Edges snap to the other shots' and to the playhead. */
  private func shotDrag(_ shot: StoryboardShot, laneHeight: CGFloat, width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 6)
      .onChanged { value in
        if drag == nil {
          let edge = shot.selected && width > edgeWidth * 3
          let kind: ShotDrag.Kind = edge && value.startLocation.x < edgeWidth ? .left :
            edge && value.startLocation.x > width - edgeWidth ? .right : .move
          drag = ShotDrag(name: shot.name, kind: kind, frames: 0, channels: 0)
          Haptics.selection()
          if !shot.selected { model.select(shot) }
        }
        guard var current = drag else { return }
        var frames = Int((value.translation.width / scale).rounded())
        frames = snapped(shot, kind: current.kind, frames: frames)
        let channels = current.kind == .move ? -Int((value.translation.height / laneHeight).rounded()) : 0
        if frames != current.frames || channels != current.channels {
          current.frames = frames
          current.channels = channels
          drag = current
        }
      }
      .onEnded { _ in
        guard let current = drag else { return }
        switch current.kind {
          case .move:
            model.move(shot, start: shot.start + current.frames,
                       channel: max(1, shot.channel + current.channels))
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
    var best: Int?
    for edge in edges {
      for target in targets {
        let delta = target - (edge + frames)
        if abs(delta) <= reach, best.map({ abs(delta) < abs($0) }) ?? true { best = delta }
      }
    }
    if let best, best != 0 { Haptics.selection() }
    return frames + (best ?? 0)
  }

  /** A blank panel after the last shot: tapped, a new shot after the selected one. */
  private func addTile(laneHeight: CGFloat) -> some View {
    let last = model.shots.filter { $0.channel == 1 }.map(\.end).max() ?? model.start
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    return Button {
      model.send("add")
      Haptics.impact(.light)
    } label: {
      Image(systemName: "plus")
        .font(.title2.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 84, height: laneHeight - 6)
        .background(PanelStyle.card, in: shape)
        .overlay(shape.strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(.secondary.opacity(0.6)))
    }
    .buttonStyle(.plain)
    .hoverEffect(.highlight)
    .offset(x: x(last) + 8, y: rulerHeight + CGFloat(model.channels - 1) * laneHeight + 3)
    .accessibilityLabel("New Shot")
    .accessibilityIdentifier("blender.storyboard.add")
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

/** \} */
