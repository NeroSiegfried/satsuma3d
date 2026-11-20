/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The timeline: a floating playback strip with a scrubber whose glass knob shows and sets the
 * frame. Expanded, the scrubber grows a key track where keys are selected by tapping or boxing
 * them and dragged together to other frames.
 */

import SwiftUI
import UIKit

private let collapsedHeight: CGFloat = 56
/* Expanded: a slim row of controls along the bottom, and the full-width scrubber above it with
 * the keys over the knob's band. */
private let controlsRowHeight: CGFloat = 44
private let knobBandHeight: CGFloat = 50
private let keyAreaHeight: CGFloat = 42
/* Small enough that the grabbed knob, scaled up, stays inside its band. */
private let knobSize: CGFloat = 32
private let knobMinWidth: CGFloat = 46

struct TimelineKey: Equatable {
  var frame: Int
  var selected: Bool
}

/** Blender's frame on its own, so playback, which changes little else, redraws only the knob,
 * the playhead and the frame number. */
@MainActor
@Observable
final class TimelineFrame {
  var blender = 1
}

@MainActor
@Observable
final class TimelineStore {
  var start = 1
  var end = 250
  var preview = false
  var playing = false
  var recording = false
  /** A render counts on the frame: the playhead cannot move until it ends (ROUND6 EDIT-2). */
  var rendering = false
  var keys: [TimelineKey] = []
  var visible = false
  var expanded = false
  var compact = false
  /** The curve editor grown out of the timeline, see `FCurveEditor.swift`. */
  var curvesShown = false
  /** The curve editor's height, its top edge dragged to change it. */
  var curvesHeight: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "BlenderCurvesHeight") as? Double ?? 380) {
    didSet { UserDefaults.standard.set(Double(curvesHeight), forKey: "BlenderCurvesHeight") }
  }
  let curves = FCurveEditorModel()
  /** While its handle is dragged; the viewport follows it at once. */
  var curvesDragging = false
  /** The tallest the curve editor may be, leaving some viewport above it. */
  var curvesMaximum: CGFloat = 700
  /** The storyboard grown out of the timeline, see `Storyboard.swift`. */
  var storyboardShown = false
  let storyboard = StoryboardModel()
  /** The workspace has shots, the window following the one under the edit's playhead. */
  var storyboardAvailable = false
  var storyboardHeight: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "BlenderStoryboardHeight") as? Double ?? 300) {
    didSet { UserDefaults.standard.set(Double(storyboardHeight), forKey: "BlenderStoryboardHeight") }
  }
  /** An editor grown out of the timeline, docked to the bottom with it. */
  var editorShown: Bool { curvesShown || storyboardShown }
  /** The timeline shows the storyboard's edit, rather than the scene in the window: its frames,
   * the playhead moving across shots, the small timeline too. Opening a shot shows its own
   * scene's time again, as do the keys and curves of the window's scene. */
  var editTime: Bool {
    storyboardAvailable && !expanded && !curvesShown && !(storyboardShown && storyboard.entered != nil)
  }
  /** Blender's frame; the knob follows it unless a finger holds the knob. */
  let frame = TimelineFrame()
  @ObservationIgnored var toggleExpanded: () -> Void = {}
  @ObservationIgnored var toggleCurves: () -> Void = {}
  @ObservationIgnored var toggleStoryboard: () -> Void = {}
  /** Shows Blender's keys again after an edit drawn ahead of it was refused (ROUND6 EDIT-3). */
  @ObservationIgnored var resync: () -> Void = {}

  /** Observers redraw on every assignment, even of the same value. */
  func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<TimelineStore, Value>, _ value: Value) {
    if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
  }

  /** Blender's timeline: the frame and its range; and its keys, only while it shows them. */
  @ObservationIgnored let view = NativeViews.shared.subscribe("timeline")
  @ObservationIgnored let keysView: NativeView = {
    let view = NativeViews.shared.subscribe("timeline_keys")
    NativeViews.shared.pause(view)
    return view
  }()

  /** Move Blender's playhead, as scrubbing does. */
  func setFrame(_ frame: Int) {
    NativeViews.shared.send(view, target: "frame", value: .float(Double(frame)))
  }

  func setRecording(_ on: Bool) {
    NativeViews.shared.send(view, target: "autokey", value: .bool(on))
  }

  /** A transport button: in the edit's time the edit plays, the window following its shots, and
   * the previous and next buttons go from cut to cut. */
  func transport(_ command: String) {
    guard editTime else {
      switch command {
        case "start", "end": Operators.run("SCREEN_OT_frame_jump", ["end": .bool(command == "end")])
        /* The Timeline's own jump, to the keys the strip draws (ROUND6 EDIT-6). */
        case "prev_key", "next_key": Operators.run("anim.native_key_jump", ["next": .bool(command == "next_key")])
        default: Operators.run("SCREEN_OT_animation_play")
      }
      return
    }
    let board = storyboard
    switch command {
      case "start": board.setFrame(start, final: true)
      case "end": board.setFrame(end, final: true)
      case "prev_key": if let cut = board.cut(after: false) { board.setFrame(cut, final: true) }
      case "next_key": if let cut = board.cut(after: true) { board.setFrame(cut, final: true) }
      default: board.send("play")
    }
  }

  /* Each edit shows at once; Blender's snapshot confirms it. */
  func select(_ frames: [Int]) {
    keys = keys.map { TimelineKey(frame: $0.frame, selected: frames.contains($0.frame)) }
    Operators.run("anim.native_key_select",
                  ["frames": .text(frames.map(String.init).joined(separator: ",")), "extend": .bool(false)],
                  failed: resync)
  }

  func moveSelected(by delta: Int) {
    /* Moved keys replace the unselected keys where they land, as in Blender. */
    var result: [Int: Bool] = [:]
    let moving = { (key: TimelineKey) in key.selected && key.frame >= self.start && key.frame <= self.end }
    for key in keys where !moving(key) && result[key.frame] == nil { result[key.frame] = key.selected }
    for key in keys where moving(key) { result[key.frame + delta] = true }
    keys = result.keys.sorted().map { TimelineKey(frame: $0, selected: result[$0]!) }
    var properties = drawnFrames
    properties["delta"] = .int(Int64(delta))
    Operators.run("anim.native_key_move", properties, failed: resync)
  }

  func deleteSelected() {
    keys = keys.filter { !$0.selected || $0.frame < start || $0.frame > end }
    Operators.run("anim.native_key_delete", drawnFrames, failed: resync)
  }

  /** The frames the strip draws keys in: its edits leave a key selected elsewhere, outside them,
   * alone (ROUND6 EDIT-1). */
  private var drawnFrames: [String: NativeValue] {
    ["frame_start": .int(Int64(start)), "frame_end": .int(Int64(end))]
  }
}

/* -------------------------------------------------------------------- */
/** \name Scrubber
 * \{ */

/** The knob's width for a frame's number. */
private func knobWidth(_ label: String) -> CGFloat {
  max(knobMinWidth, ceil((label as NSString).size(withAttributes: [
    .font: UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .bold)]).width) + 20)
}

/** One frame mapping places the knob, its playhead line and the keys. */
struct FrameMapping: Equatable {
  let start: Int
  let end: Int
  let width: CGFloat

  /** Room for the knob at either end: as wide as the widest frame of the range shows, grown as
   * when held, so it never covers the controls beside the scrubber. */
  private var inset: CGFloat {
    knobWidth(String(max(abs(start), abs(end)))) * 0.6 + 4
  }
  private var cells: CGFloat { CGFloat(max(1, end - start + 1)) }

  /** Frames map to whole-frame cells, inset so the knob stays inside at the first and last frame. */
  func x(_ frame: CGFloat) -> CGFloat {
    inset + (frame - CGFloat(start) + 0.5) / cells * max(1, width - 2 * inset)
  }

  func frame(at x: CGFloat) -> Int {
    let frame = start + Int(floor((x - inset) / max(1, width - 2 * inset) * cells))
    return min(end, max(start, frame))
  }
}

private func diamond(_ center: CGPoint, _ size: CGFloat) -> Path {
  Path { path in
    path.move(to: CGPoint(x: center.x, y: center.y - size / 2))
    path.addLine(to: CGPoint(x: center.x + size / 2, y: center.y))
    path.addLine(to: CGPoint(x: center.x, y: center.y + size / 2))
    path.addLine(to: CGPoint(x: center.x - size / 2, y: center.y))
    path.closeSubpath()
  }
}

private func keyColor(_ selected: Bool) -> Color { selected ? .orange : .primary }

struct Scrubber: View {
  let store: TimelineStore
  @State private var playhead: Int?
  @State private var mode: Mode = .idle
  @State private var grabbed = 0
  @State private var delta = 0
  @State private var boxFrom: CGFloat = 0
  @State private var boxTo: CGFloat = 0
  @State private var sent = Int.min

  enum Mode { case idle, scrubbing, movingKeys, boxing }

  /** For gestures and actions only: the body never reads the frame, so playback redraws just the
   * knob and the playhead, see `TimelineKnob` and `PlayheadLine`. */
  private var shownFrame: Int { playhead ?? store.frame.blender }

  var body: some View {
    /* Read here rather than in the canvases, so changing them redraws the track. */
    let start = store.start
    let end = store.end
    let expanded = store.expanded
    let preview = store.preview
    let keys = store.keys
    let rendering = store.rendering
    GeometryReader { geometry in
      let size = geometry.size
      let mapping = FrameMapping(start: start, end: end, width: size.width)
      let band = expanded ? knobBandHeight : size.height
      let trackY = size.height - band / 2
      ZStack(alignment: .topLeading) {
        Canvas { context, _ in
          drawTrack(context, size: size, mapping: mapping, band: band, trackY: trackY, expanded: expanded,
                    preview: preview, keys: keys)
        }
        if expanded {
          /* The playhead line rises from the knob through the keys. */
          PlayheadLine(frame: store.frame, playhead: playhead, mapping: mapping, trackY: trackY)
          Canvas { context, _ in drawKeys(context, size: size, mapping: mapping, band: band, keys: keys) }
        }
        TimelineKnob(frame: store.frame, playhead: playhead, lifted: mode == .scrubbing, mapping: mapping,
                     trackY: trackY)
      }
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0).onChanged { value in
        changed(value, mapping: mapping, size: size, band: band)
      }.onEnded { value in
        ended(value, mapping: mapping, size: size, band: band)
      })
      /* A render counts on the frame (ROUND6 EDIT-2): the scrubber says so and takes no touch until
       * it ends, as desktop's timeline refuses then. */
      .opacity(rendering ? 0.4 : 1)
      .allowsHitTesting(!rendering)
      .overlay {
        if rendering {
          Text("Rendering").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .allowsHitTesting(false)
        }
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Current Frame")
    .accessibilityHint(rendering ? "Unavailable while rendering" : "")
    .modifier(FrameFollower(frame: store.frame, playhead: $playhead, scrubbing: mode == .scrubbing))
    .accessibilityIdentifier("blender.timeline.scrubber")
    .accessibilityAdjustableAction { direction in
      sent = Int.min
      scrub(to: direction == .increment ? min(store.end, shownFrame + 1) : max(store.start, shownFrame - 1))
    }
  }

  private func inKeyArea(_ point: CGPoint, size: CGSize, band: CGFloat) -> Bool {
    store.expanded && point.y >= 16 && point.y <= size.height - band + 4
  }

  private func key(near point: CGPoint, mapping: FrameMapping, size: CGSize, band: CGFloat) -> Int? {
    guard inKeyArea(point, size: size, band: band) else { return nil }
    var best: Int?
    var distance: CGFloat = 22
    for key in store.keys where key.frame >= store.start && key.frame <= store.end {
      let d = abs(mapping.x(CGFloat(key.frame)) - point.x)
      if d < distance {
        distance = d
        best = key.frame
      }
    }
    return best
  }

  private func scrub(to frame: Int) {
    guard !store.rendering else { return }
    if frame != shownFrame {
      if mode == .scrubbing { Haptics.selection() }
      playhead = frame
    }
    if frame != sent {
      sent = frame
      if store.editTime { store.storyboard.setFrame(frame, final: true) }
      else { store.setFrame(frame) }
    }
  }

  private func changed(_ value: DragGesture.Value, mapping: FrameMapping, size: CGSize, band: CGFloat) {
    let moved = hypot(value.translation.width, value.translation.height) > 2
    if mode == .idle {
      guard moved else { return }
      let origin = value.startLocation
      /* Grabbing a key drags the selection, selecting the key first unless it is already part of
       * it; empty key track draws a selection box; anywhere else scrubs. */
      if let key = key(near: origin, mapping: mapping, size: size, band: band) {
        mode = .movingKeys
        grabbed = key
        delta = 0
        if !(store.keys.first { $0.frame == key }?.selected ?? false) { store.select([key]) }
        Haptics.impact()
      }
      else if inKeyArea(origin, size: size, band: band) {
        mode = .boxing
        boxFrom = origin.x
        boxTo = origin.x
      }
      else {
        mode = .scrubbing
        sent = Int.min
        Haptics.impact()
      }
    }
    switch mode {
      case .movingKeys:
        let next = mapping.frame(at: value.location.x) - grabbed
        if next != delta {
          delta = next
          Haptics.selection()
        }
      case .boxing:
        boxTo = value.location.x
      case .scrubbing:
        scrub(to: mapping.frame(at: value.location.x))
      case .idle:
        break
    }
  }

  private func ended(_ value: DragGesture.Value, mapping: FrameMapping, size: CGSize, band: CGFloat) {
    switch mode {
      case .idle:
        /* A tap: in the key track it selects the key under it, or clears the selection. */
        if inKeyArea(value.location, size: size, band: band) {
          store.select(key(near: value.location, mapping: mapping, size: size, band: band).map { [$0] } ?? [])
        }
        else {
          sent = Int.min
          scrub(to: mapping.frame(at: value.location.x))
        }
      case .movingKeys:
        if delta != 0 { store.moveSelected(by: delta) }
      case .boxing:
        let left = min(boxFrom, boxTo), right = max(boxFrom, boxTo)
        store.select(store.keys.filter {
          $0.frame >= store.start && $0.frame <= store.end &&
            (left...right).contains(mapping.x(CGFloat($0.frame)))
        }.map(\.frame))
      case .scrubbing:
        scrub(to: mapping.frame(at: value.location.x))
    }
    mode = .idle
    delta = 0
  }

  /** The track and, expanded, the ruler: everything under the playhead line. */
  private func drawTrack(_ context: GraphicsContext, size: CGSize, mapping: FrameMapping, band: CGFloat,
                         trackY: CGFloat, expanded: Bool, preview: Bool, keys: [TimelineKey])
  {
    /* Track: the playback range, orange when it is the preview range, as in Blender. */
    let range = preview ? Color.orange : Color(uiColor: .tertiaryLabel)
    let left = mapping.x(CGFloat(mapping.start)) - 2
    context.fill(Path(CGRect(x: left, y: trackY - 1.5,
                             width: mapping.x(CGFloat(mapping.end)) - mapping.x(CGFloat(mapping.start)) + 4,
                             height: 3)),
                 with: .color(range))
    if !expanded {
      /* Keyed frames along the track, behind the knob like the track itself. */
      for key in keys where key.frame >= mapping.start && key.frame <= mapping.end {
        let shape = diamond(CGPoint(x: mapping.x(CGFloat(key.frame)), y: trackY), 9)
        context.fill(shape, with: .color(keyColor(key.selected)))
        context.stroke(shape, with: .color(.black.opacity(0.55)), lineWidth: 1)
      }
      return
    }
    /* Ruler: label every frame step that leaves room for its number. */
    let areaBottom = size.height - band
    let perFrame = max(0.001, mapping.x(CGFloat(mapping.start + 1)) - mapping.x(CGFloat(mapping.start)))
    var step = 1
    for candidate in [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2500, 5000] {
      step = candidate
      if perFrame * CGFloat(candidate) >= 44 { break }
    }
    var frame = Int(ceil(Double(mapping.start) / Double(step))) * step
    while frame <= mapping.end {
      let x = mapping.x(CGFloat(frame))
      context.fill(Path(CGRect(x: x - 0.5, y: 14, width: 1, height: areaBottom - 14)),
                   with: .color(Color.secondary.opacity(0.3)))
      let label = context.resolve(Text("\(frame)").font(.system(size: 10).monospacedDigit())
        .foregroundStyle(.secondary))
      let measured = label.measure(in: size)
      context.draw(label, at: CGPoint(x: min(size.width - measured.width - 2, max(2, x - measured.width / 2)), y: 1),
                   anchor: .topLeading)
      frame += step
    }
  }

  /** The expanded key track: everything over the playhead line. */
  private func drawKeys(_ context: GraphicsContext, size: CGSize, mapping: FrameMapping, band: CGFloat,
                        keys: [TimelineKey])
  {
    let areaBottom = size.height - band
    /* The selection box spans the key track between the fingers' frames. */
    let boxLeft = min(boxFrom, boxTo), boxRight = max(boxFrom, boxTo)
    if mode == .boxing {
      let box = Path(roundedRect: CGRect(x: boxLeft, y: 16, width: boxRight - boxLeft, height: areaBottom - 18),
                     cornerRadius: 6)
      context.fill(box, with: .color(Color(uiColor: .systemBlue).opacity(0.15)))
      context.stroke(box, with: .color(Color(uiColor: .systemBlue).opacity(0.7)), lineWidth: 1)
    }
    /* Keys. Moving, the selected keys show at their new frames and faded at their old ones; boxing,
     * the keys inside the box show as they will be selected. */
    let keysY = 14 + (size.height - band - 14) / 2
    let rim = Color(uiColor: .systemBackground).opacity(0.7)
    for key in keys where key.frame >= mapping.start && key.frame <= mapping.end {
      let x = mapping.x(CGFloat(key.frame))
      let selected = mode == .boxing ? (x >= boxLeft && x <= boxRight) : key.selected
      var color = keyColor(selected)
      if mode == .movingKeys && selected { color = color.opacity(0.3) }
      let shape = diamond(CGPoint(x: x, y: keysY), 16)
      context.fill(shape, with: .color(color))
      context.stroke(shape, with: .color(rim), lineWidth: 1)
    }
    if mode == .movingKeys {
      for key in keys where key.selected && key.frame != grabbed {
        let shape = diamond(CGPoint(x: mapping.x(CGFloat(key.frame + delta)), y: keysY), 16)
        context.fill(shape, with: .color(.orange))
        context.stroke(shape, with: .color(rim), lineWidth: 1)
      }
      let center = CGPoint(x: mapping.x(CGFloat(grabbed + delta)), y: keysY)
      let shape = diamond(center, 20)
      context.fill(shape, with: .color(.orange))
      context.stroke(shape, with: .color(Color(uiColor: .systemBackground)), lineWidth: 1)
      let label = context.resolve(Text("\(grabbed + delta)").font(.system(size: 11, weight: .semibold).monospacedDigit()))
      let measured = label.measure(in: size)
      context.draw(label, at: CGPoint(x: min(size.width - measured.width - 2, max(2, center.x + 12)), y: center.y),
                   anchor: .leading)
    }
  }
}

/** Held, the knob turns to clear glass and swells, as system slider thumbs do; released, it
 * settles back into the playhead's tinted glass. The only part of the scrubber, with the playhead
 * line, that reads Blender's frame. */
private struct TimelineKnob: View {
  let frame: TimelineFrame
  let playhead: Int?
  let lifted: Bool
  let mapping: FrameMapping
  let trackY: CGFloat

  var body: some View {
    let shown = playhead ?? frame.blender
    let label = "\(shown)"
    let width = knobWidth(label)
    Text(label)
      .font(.system(size: 14, weight: .bold).monospacedDigit())
      .minimumScaleFactor(0.7)
      .foregroundStyle(lifted ? Color.primary : .white)
      .frame(width: width, height: knobSize)
      .panelGlass(lifted ? .clear : .tinted(Color(uiColor: .systemBlue)), interactive: true, in: Capsule())
      .scaleEffect(lifted ? 1.2 : 1)
      .animation(UIAccessibility.isReduceMotionEnabled ? nil : .spring(response: 0.35, dampingFraction: 0.6),
                 value: lifted)
      .accessibilityIdentifier("blender.timeline.frame")
      .position(x: mapping.x(CGFloat(shown)), y: trackY)
  }
}

/** The expanded playhead, from the knob up through the keys. */
private struct PlayheadLine: View {
  let frame: TimelineFrame
  let playhead: Int?
  let mapping: FrameMapping
  let trackY: CGFloat

  var body: some View {
    let x = mapping.x(CGFloat(playhead ?? frame.blender))
    Rectangle()
      .fill(Color(uiColor: .systemBlue))
      .frame(width: 2, height: max(0, trackY - knobSize / 2 - 12))
      .offset(x: x - 1, y: 12)
      .allowsHitTesting(false)
  }
}

/** The scrubber's accessibility value, and the knob returning to Blender's frame once Blender
 * moves on, kept out of the scrubber's body so playback doesn't redraw the track. */
private struct FrameFollower: ViewModifier {
  let frame: TimelineFrame
  @Binding var playhead: Int?
  let scrubbing: Bool

  func body(content: Content) -> some View {
    content
      .accessibilityValue("\(playhead ?? frame.blender)")
      .onChange(of: frame.blender) { _, _ in
        if !scrubbing && playhead != nil { playhead = nil }
      }
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Strip
 * \{ */

/** Reads everything but the frame, so playback leaves the buttons alone. One layout for both sizes,
 * each control in it once: opening the key track moves the transport, scrubber and keyframe button
 * to their new places. */
struct TimelineContent: View {
  let store: TimelineStore
  @State private var transportWidth: CGFloat = 0

  var body: some View {
    let expanded = store.expanded
    ZStack {
      /* Collapsed, between the transport and the keyframe button; expanded, across the top. */
      Scrubber(store: store)
        .padding(.leading, expanded ? 8 : 8 + transportWidth + 4)
        .padding(.trailing, expanded ? 8 : 2 + 44 * CGFloat(trailingButtons) + 8)
        .padding(.bottom, expanded ? controlsRowHeight : 0)
      transport
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { transportWidth = $0 }
        .padding(.leading, expanded ? 0 : 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: expanded ? .bottom : .leading)
      if expanded && store.keys.contains(where: \.selected) {
        deleteButton
          .padding(.leading, 8)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
      }
      HStack(spacing: 0) {
        if showsStoryboardButton { storyboardButton }
        curvesButton
        keysButton
      }
      .padding(.trailing, 8)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: expanded ? .bottomTrailing : .trailing)
    }
    .foregroundStyle(.primary)
  }

  private var trailingButtons: Int { showsStoryboardButton ? 3 : 2 }

  private var showsStoryboardButton: Bool {
#if os(visionOS)
    false
#else
    /* Any file can start a storyboard: its first shot makes the sequencer scene. */
    true
#endif
  }

  /** Opens the storyboard out of the timeline, filled while it is open. */
  private var storyboardButton: some View {
    Button(action: store.toggleStoryboard) {
      Image(systemName: "film.stack")
        .symbolVariant(store.storyboardShown ? .fill : .none)
        .foregroundStyle(store.storyboardShown ? PanelStyle.selection : .primary)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Story")
    .accessibilityAddTraits(store.storyboardShown ? .isSelected : [])
    .accessibilityIdentifier("blender.timeline.storyboard-toggle")
  }

  /** Opens the curve editor out of the timeline, filled while it is open. */
  private var curvesButton: some View {
    Button(action: store.toggleCurves) {
      Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
        .symbolVariant(store.curvesShown ? .fill : .none)
        .foregroundStyle(store.curvesShown ? PanelStyle.selection : .primary)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Edit Curves")
    .accessibilityAddTraits(store.curvesShown ? .isSelected : [])
    .accessibilityIdentifier("blender.timeline.curves-toggle")
  }

  private var transport: some View {
    HStack(spacing: 0) {
      Button {
        /* Show the new state at once; Blender's snapshot confirms it. */
        store.recording.toggle()
        store.setRecording(store.recording)
      } label: {
        Image(systemName: store.recording ? "record.circle.fill" : "record.circle")
          .foregroundStyle(store.recording ? Color.red : .primary)
          .frame(width: 44, height: 44)
      }
      .accessibilityLabel("Auto Keying")
      .accessibilityValue(store.recording ? "On" : "Off")
      .accessibilityAddTraits(store.recording ? .isSelected : [])
      .accessibilityIdentifier("blender.timeline.autokey")
      .padding(.trailing, 4)
      if !store.compact {
        transportButton("backward.end.fill", "Jump to Start", "start")
      }
      transportButton("backward.frame.fill", "Previous Keyframe", "prev_key")
      transportButton(store.playing ? "pause.fill" : "play.fill", store.playing ? "Pause" : "Play", "play")
      transportButton("forward.frame.fill", "Next Keyframe", "next_key")
      if !store.compact {
        transportButton("forward.end.fill", "Jump to End", "end")
      }
    }
    .buttonStyle(.plain)
    .font(.system(size: 18))
  }

  private func transportButton(_ symbol: String, _ label: String, _ command: String) -> some View {
    Button {
      store.transport(command)
    } label: {
      Image(systemName: symbol).frame(width: 44, height: 44).contentShape(Rectangle())
    }
    .accessibilityLabel(label)
    .accessibilityIdentifier("blender.timeline." + command)
  }

  private var deleteButton: some View {
    Button {
      store.deleteSelected()
    } label: {
      Image(systemName: "trash").foregroundStyle(.red).frame(width: 44, height: 44)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Delete Keyframes")
    .accessibilityIdentifier("blender.timeline.delete-keys")
  }

  /** Blender's keyframe icon, filled while the key track is open. */
  private var keysButton: some View {
    Button(action: store.toggleExpanded) {
      Group {
        if let image = UIImage(named: store.expanded ? "blender.keyframe_hlt" : "blender.keyframe") {
          Image(uiImage: image.withRenderingMode(.alwaysTemplate))
        }
        else {
          Image(systemName: store.expanded ? "diamond.fill" : "diamond")
        }
      }
      .foregroundStyle(store.expanded ? PanelStyle.selection : .primary)
      .frame(width: 44, height: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Edit Keyframes")
    .accessibilityAddTraits(store.expanded ? .isSelected : [])
    .accessibilityIdentifier("blender.timeline.keys-toggle")
  }
}

/** The timeline along the bottom of a SwiftUI window, in the system's glass. */
struct TimelinePanel: View {
  let store: TimelineStore
  /** With the curve editor open, the panel rests on the window's bottom edge as the node editor
   * does, its controls kept clear of the home indicator by this much. */
  var bottomInset: CGFloat = 0

  static func height(expanded: Bool) -> CGFloat {
    expanded ? controlsRowHeight + knobBandHeight + keyAreaHeight : collapsedHeight
  }

  /** With the curve editor open, it and the timeline's row of controls under it. */
  static func height(_ store: TimelineStore) -> CGFloat {
    store.curvesShown ? store.curvesHeight + collapsedHeight :
      store.storyboardShown ? store.storyboardHeight : height(expanded: store.expanded)
  }

  /** The handle the curve editor is made taller or shorter by, and its height when the drag began. */
  @State private var dragStart: CGFloat?

  var body: some View {
    VStack(spacing: 0) {
      if store.curvesShown {
        Capsule()
          .fill(.secondary.opacity(0.5))
          .frame(width: 44, height: 5)
          .frame(maxWidth: .infinity, minHeight: 16)
          .contentShape(Rectangle())
          .gesture(
            DragGesture(coordinateSpace: .global)
              .onChanged { value in
                let start = dragStart ?? store.curvesHeight
                dragStart = start
                store.curvesDragging = true
                store.curvesHeight = min(store.curvesMaximum, max(220, start - value.translation.height))
              }
              .onEnded { _ in
                dragStart = nil
                store.curvesDragging = false
              })
          .accessibilityLabel("Resize Curve Editor")
        FCurveEditorView(model: store.curves, timeline: store)
          .frame(height: store.curvesHeight - 16)
        Divider()
      }
      if store.storyboardShown {
        Capsule()
          .fill(.secondary.opacity(0.5))
          .frame(width: 44, height: 5)
          .frame(maxWidth: .infinity, minHeight: 16)
          .contentShape(Rectangle())
          .gesture(
            DragGesture(coordinateSpace: .global)
              .onChanged { value in
                let start = dragStart ?? store.storyboardHeight
                dragStart = start
                store.storyboardHeight = min(store.curvesMaximum, max(170, start - value.translation.height))
              }
              .onEnded { _ in dragStart = nil })
          .accessibilityLabel("Resize Story")
        /* Its own controls in its header, and its own scrubber along the bottom, in step with its
         * shots: the timeline's row is not needed. */
        StoryboardView(model: store.storyboard, timeline: store)
          .frame(height: store.storyboardHeight - 16)
      }
      else {
        TimelineContent(store: store)
          .frame(height: store.curvesShown ? collapsedHeight : Self.height(expanded: store.expanded))
      }
    }
    .frame(height: Self.height(store))
    .padding(.bottom, store.editorShown ? bottomInset : 0)
    .onGeometryChange(for: Bool.self) { $0.size.width < 520 } action: { store.set(\.compact, $0) }
    .background(store.editorShown ? AnyShapeStyle(PanelStyle.docked) : AnyShapeStyle(.clear),
                in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .continuous))
    /* No corners with the curve editor open: the glass's shape would round the curves' corners
     * too. */
    .panelGlass(store.editorShown ? .none : .regular,
                in: RoundedRectangle(cornerRadius: store.editorShown ? 0 : store.expanded ? 24 : collapsedHeight / 2,
                                     style: .continuous))
    .accessibilityIdentifier("blender.timeline.panel")
  }
}

/** The timeline's state and Blender's side of it; the window shows #TimelinePanel, or on Apple
 * Vision Pro a window of its own. */
@MainActor
final class SwiftTimeline {
  let store = TimelineStore()
  var visible: Bool { store.visible }
  var visibilityDidChange: (() -> Void)?

  init() {
    store.toggleExpanded = { [weak self] in self?.toggleExpanded() }
    store.toggleCurves = { [weak self] in self?.setCurvesShown(!(self?.store.curvesShown ?? true)) }
    store.toggleStoryboard = { [weak self] in self?.setStoryboardShown(!(self?.store.storyboardShown ?? true)) }
    store.storyboard.enteredChanged = { [weak self] in self?.timeChanged() }
    store.resync = { [weak self] in
      self?.state = nil
      self?.update()
    }
#if os(visionOS)
    Self.current = self
#endif
  }

#if os(visionOS)
  /* On Apple Vision Pro the timeline is a window of its own, placed under the editor's. */
  static weak var current: SwiftTimeline?

  func windowContent() -> AnyView {
    store.set(\.compact, false)
    return AnyView(TimelineContent(store: store))
  }

  func setWindowOpen(_ open: Bool) {
    store.visible = open
    keysShown(open)
    visibilityDidChange?()
  }

  /** The curve editor, in a window of its own beside the timeline's. */
  func curvesWindowContent() -> AnyView {
    AnyView(FCurveEditorView(model: store.curves, timeline: store))
  }
#endif

  var height: CGFloat { TimelinePanel.height(store) }
  /** The curve editor opening, for the node editor to make way. */
  var curvesDidOpen: (() -> Void)?

  /** Blender lists keyframes only while the timeline shows them. */
  private func keysShown(_ shown: Bool) {
    if shown { NativeViews.shared.resume(store.keysView) } else { NativeViews.shared.pause(store.keysView) }
  }

  /** Blender's time, as its timeline views have it. */
  private struct State: Equatable {
    var storyboard = false
    var frame = 1, start = 1, end = 1
    var editFrame: Int?
    var editStart = 0, editEnd = 0
    var preview = false, playing = false, autokey = false, rendering = false
    var keys: [TimelineKey] = []
  }
  private var state: State?

  /** Take what Blender's timeline views show now. */
  func update() {
    let view = store.view
    guard let top = view.top else { return }
    func node(_ key: String) -> NativeNode? {
      _ = top.children
      return view.node(key)
    }
    func flag(_ key: String) -> Bool {
      node(key)?.content(Blender_NativeUI_Data.self)?.value(type: Blender_NativeUI_BoolValue.self)?.value ?? false
    }
    var next = State()
    if let frame = node("frame")?.number {
      next.frame = Int(frame.value)
      next.start = Int(frame.softMin)
      next.end = Int(frame.softMax)
    }
    if let edit = node("edit_frame")?.number {
      next.storyboard = true
      next.editFrame = Int(edit.value)
      next.editStart = Int(edit.softMin)
      next.editEnd = Int(edit.softMax)
    }
    next.preview = flag("preview")
    next.playing = flag("playing")
    next.rendering = flag("rendering")
    next.autokey = node("autokey")?.toggle?.value ?? false
    if store.visible, let keysTop = store.keysView.top {
      func ints(_ key: String) -> [Int] {
        _ = keysTop.children
        guard let value = store.keysView.node(key)?.content(Blender_NativeUI_Data.self)?
          .value(type: Blender_NativeUI_IntsValue.self) else { return [] }
        return (0..<value.valueCount).map { Int(value.value(at: $0)) }
      }
      let selected = Set(ints("selected"))
      next.keys = ints("keys").map { TimelineKey(frame: $0, selected: selected.contains($0)) }
    }
    guard next != state else { return }
    state = next
    apply(next)
  }

  /** Shows the scene's time, or in the storyboard the edit's. */
  private func apply(_ state: State) {
    store.set(\.storyboardAvailable, state.storyboard)
    let edit = store.editTime
    shownEditTime = edit
    /* Playing, usually only the frame changes: leave the rest untouched so nothing else redraws. */
    let start = edit && state.editFrame != nil ? state.editStart : state.start
    store.set(\.start, start)
    store.set(\.end, max(start, edit && state.editFrame != nil ? state.editEnd : state.end))
    store.set(\.preview, !edit && state.preview)
    store.set(\.keys, edit ? [] : state.keys)
    let frame = (edit ? state.editFrame : nil) ?? state.frame
    if store.frame.blender != frame { store.frame.blender = frame }
    store.set(\.playing, state.playing)
    store.set(\.rendering, state.rendering)
    store.set(\.recording, state.autokey)
    if let editFrame = state.editFrame {
      store.storyboard.follow(frame: editFrame, sceneFrame: state.frame)
    }
#if !os(visionOS)
    /* A storyboard opens with its shots showing, once. */
    if state.storyboard && !storyboardOpened {
      storyboardOpened = true
      setVisible(true)
      setStoryboardShown(true)
    }
#endif
  }

  @ObservationIgnored private var storyboardOpened = false
  @ObservationIgnored private var shownEditTime = false

  /** The edit's time or the scene's, as the storyboard opens and closes and shots are opened. */
  func timeChanged() {
    guard store.editTime != shownEditTime, let state else { return }
    apply(state)
  }

  func setStoryboardShown(_ shown: Bool) {
    guard shown != store.storyboardShown else { return }
    withAnimation(Self.animation) {
      store.storyboardShown = shown
      if shown {
        store.expanded = false
        store.curvesShown = false
      }
    }
    if shown { store.curves.setShown(false) }
    store.storyboard.setShown(shown)
    if shown { curvesDidOpen?() }
    timeChanged()
    visibilityDidChange?()
  }

  func toggleExpanded() {
    withAnimation(Self.animation) {
      store.expanded.toggle()
      if store.expanded {
        store.curvesShown = false
        store.storyboardShown = false
      }
    }
    store.curves.setShown(store.curvesShown)
    store.storyboard.setShown(store.storyboardShown)
    timeChanged()
    visibilityDidChange?()
  }

  func setCurvesShown(_ shown: Bool) {
    guard shown != store.curvesShown else { return }
    withAnimation(Self.animation) {
      store.curvesShown = shown
      if shown {
        store.expanded = false
        store.storyboardShown = false
      }
    }
    store.curves.setShown(shown)
    store.storyboard.setShown(store.storyboardShown)
    timeChanged()
    if shown { curvesDidOpen?() }
    visibilityDidChange?()
#if os(visionOS)
    PanelWindows.set(.curves, open: shown)
#endif
  }

  func toggle() {
#if os(visionOS)
    PanelWindows.toggle(.timeline)
    return
#endif
    setVisible(!store.visible)
  }

  func setVisible(_ visible: Bool) {
#if os(visionOS)
    if visible != store.visible { PanelWindows.toggle(.timeline) }
    return
#endif
    guard visible != store.visible else { return }
    withAnimation(Self.animation) { store.visible = visible }
    keysShown(visible)
    visibilityDidChange?()
  }

  /** The timeline and everything resting on it move together. */
  static var animation: Animation? {
    UIAccessibility.isReduceMotionEnabled ? nil : .spring(response: 0.3, dampingFraction: 0.9)
  }
}

/** \} */
