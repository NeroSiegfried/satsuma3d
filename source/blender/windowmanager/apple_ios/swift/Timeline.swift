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
  var storyboardHeight: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "BlenderStoryboardHeight") as? Double ?? 260) {
    didSet { UserDefaults.standard.set(Double(storyboardHeight), forKey: "BlenderStoryboardHeight") }
  }
  /** An editor grown out of the timeline, docked to the bottom with it. */
  var editorShown: Bool { curvesShown || storyboardShown }
  /** The timeline shows the storyboard's edit, rather than the scene in the window: its frames,
   * the playhead moving across shots. Opening a shot shows its own scene's time again. */
  var editTime: Bool { storyboardShown && storyboard.entered == nil }
  /** Blender's frame; the knob follows it unless a finger holds the knob. */
  let frame = TimelineFrame()
  @ObservationIgnored var toggleExpanded: () -> Void = {}
  @ObservationIgnored var toggleCurves: () -> Void = {}
  @ObservationIgnored var toggleStoryboard: () -> Void = {}

  /** Observers redraw on every assignment, even of the same value. */
  func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<TimelineStore, Value>, _ value: Value) {
    if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
  }

  func send(_ setting: String, _ value: String) {
    Engine.setting(setting, value)
  }

  /* Each edit shows at once; Blender's snapshot confirms it. */
  func select(_ frames: [Int]) {
    keys = keys.map { TimelineKey(frame: $0.frame, selected: frames.contains($0.frame)) }
    send("timeline_key_select", frames.map(String.init).joined(separator: ",") + "|0")
  }

  func moveSelected(by delta: Int) {
    /* Moved keys replace the unselected keys where they land, as in Blender. */
    var result: [Int: Bool] = [:]
    for key in keys where !key.selected && result[key.frame] == nil { result[key.frame] = false }
    for key in keys where key.selected { result[key.frame + delta] = true }
    keys = result.keys.sorted().map { TimelineKey(frame: $0, selected: result[$0]!) }
    send("timeline_key_move", "\(delta)")
  }

  func deleteSelected() {
    keys = keys.filter { !$0.selected }
    send("timeline_key_delete", "")
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
    }
    .accessibilityElement()
    .accessibilityLabel("Current Frame")
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
    if frame != shownFrame {
      if mode == .scrubbing { Haptics.selection() }
      playhead = frame
    }
    if frame != sent {
      sent = frame
      if store.editTime { store.storyboard.setFrame(frame, final: true) }
      else { store.send("timeline_frame", "\(frame)") }
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
    store.storyboardAvailable || store.storyboardShown
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
    .accessibilityLabel("Storyboard")
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
        store.send("timeline", "autokey")
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
      /* In the edit's time, the edit plays, the window following its shots, and the previous
       * and next buttons go from cut to cut. */
      if store.editTime {
        let board = store.storyboard
        switch command {
          case "start": board.setFrame(board.start, final: true)
          case "end": board.setFrame(board.end, final: true)
          case "prev_key": if let cut = board.cut(after: false) { board.setFrame(cut, final: true) }
          case "next_key": if let cut = board.cut(after: true) { board.setFrame(cut, final: true) }
          default: board.send("play")
        }
      }
      else {
        store.send("timeline", command)
      }
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
      store.storyboardShown ? store.storyboardHeight + collapsedHeight : height(expanded: store.expanded)
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
                store.storyboardHeight = min(store.curvesMaximum, max(120, start - value.translation.height))
              }
              .onEnded { _ in dragStart = nil })
          .accessibilityLabel("Resize Storyboard")
        StoryboardView(model: store.storyboard)
          .frame(height: store.storyboardHeight - 16)
        Divider()
      }
      TimelineContent(store: store)
        .frame(height: store.editorShown ? collapsedHeight : Self.height(expanded: store.expanded))
    }
    .frame(height: Self.height(store))
    .padding(.bottom, store.editorShown ? bottomInset : 0)
    .onGeometryChange(for: Bool.self) { $0.size.width < 520 } action: { store.set(\.compact, $0) }
    .background(store.editorShown ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear),
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
  private var snapshot: NSDictionary?
  var visible: Bool { store.visible }
  var visibilityDidChange: (() -> Void)?

  init() {
    store.toggleExpanded = { [weak self] in self?.toggleExpanded() }
    store.toggleCurves = { [weak self] in self?.setCurvesShown(!(self?.store.curvesShown ?? true)) }
    store.toggleStoryboard = { [weak self] in self?.setStoryboardShown(!(self?.store.storyboardShown ?? true)) }
    store.storyboard.enteredChanged = { [weak self] in self?.timeChanged() }
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
    Engine.setting("timeline_visible", open ? "1" : "0")
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

  func updateSnapshot(_ snapshot: Any?) {
    guard let snapshot = snapshot as? NSDictionary, !(self.snapshot?.isEqual(snapshot) ?? false),
          let json = snapshot as? JSON else { return }
    self.snapshot = snapshot
    apply(json)
  }

  /** Shows the scene's time, or in the storyboard the edit's, from Blender's snapshot. */
  private func apply(_ json: JSON) {
    let edit = store.editTime
    shownEditTime = edit
    /* Playing, usually only the frame changes: leave the rest untouched so nothing else redraws. */
    let start = (edit ? json.int("edit_start") : nil) ?? json.int("start") ?? 1
    store.set(\.start, start)
    store.set(\.end, max(start, (edit ? json.int("edit_end") : nil) ?? json.int("end") ?? start))
    store.set(\.preview, !edit && json.bool("preview"))
    store.set(\.keys, edit ? [] : json.array("keys").map { TimelineKey(frame: $0.int("f") ?? 0, selected: $0.bool("s")) })
    let frame = (edit ? json.int("edit_frame") : nil) ?? json.int("frame") ?? start
    if store.frame.blender != frame { store.frame.blender = frame }
    store.set(\.playing, json.bool("playing"))
    store.set(\.recording, json.bool("autokey"))
    let storyboard = json.bool("storyboard")
    store.set(\.storyboardAvailable, storyboard)
    if let editFrame = json.int("edit_frame") { store.storyboard.follow(frame: editFrame) }
#if !os(visionOS)
    /* A storyboard opens with its shots showing, once. */
    if storyboard && !storyboardOpened {
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
    guard store.editTime != shownEditTime, let json = snapshot as? JSON else { return }
    apply(json)
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
    /* Blender lists keyframes only while the timeline shows them. */
    Engine.setting("timeline_visible", visible ? "1" : "0")
    visibilityDidChange?()
  }

  /** The timeline and everything resting on it move together. */
  static var animation: Animation? {
    UIAccessibility.isReduceMotionEnabled ? nil : .spring(response: 0.3, dampingFraction: 0.9)
  }
}

/** \} */
