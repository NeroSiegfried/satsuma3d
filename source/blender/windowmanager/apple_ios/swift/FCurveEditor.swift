/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The curve editor: Blender's Graph Editor drawn natively, opened from the timeline, which grows
 * into it. Blender lists the curves and makes every edit, see `graph_native.cc`; this draws them
 * and turns touches into those edits.
 */

import SwiftUI
import UIKit

/* -------------------------------------------------------------------- */
/** \name Model
 * \{ */

/** A key of a curve: its point and handles in shown values, and how it is drawn and joined. */
struct FCurveKey: Equatable {
  var frame: Double
  var value: Double
  var left: CGPoint
  var right: CGPoint
  /** Packed as `graph_native.cc` packs them. */
  var flags: Int

  var selected: Bool { flags & 1 != 0 }
  var leftSelected: Bool { flags & 2 != 0 }
  var rightSelected: Bool { flags & 4 != 0 }
  var interpolation: Int { (flags >> 4) & 0x3F }
  var easing: Int { (flags >> 10) & 0x3 }
  var leftType: Int { (flags >> 12) & 0x7 }
  var rightType: Int { (flags >> 15) & 0x7 }
  var point: CGPoint { CGPoint(x: frame, y: value) }
}

/** Blender's interpolation numbers, see `eBezTriple_Interpolation`. */
enum FCurveInterpolation {
  static let constant = 0
  static let linear = 1
  static let bezier = 2
}

struct FCurve: Equatable, Identifiable {
  let id: Int
  var name: String
  var owner: String
  var color: Color
  var visible: Bool
  var locked: Bool
  var muted: Bool
  var selected: Bool
  var active: Bool
  var keys: [FCurveKey]
  /** 0 constant, 1 linear, as Blender's `extend`. */
  var extrapolation: Int
  /** Evaluated values from `sampleStart` every `sampleStep` frames, for curves the keys alone
   * can't draw: other interpolations and modifiers. */
  var samples: [Double]
  var sampleStart: Double
  var sampleStep: Double

  init(index: Int, json: JSON) {
    id = index
    name = json.string("name") ?? ""
    owner = json.string("owner") ?? ""
    let c = (json["color"] as? [NSNumber])?.map(\.doubleValue) ?? [0.8, 0.8, 0.8]
    color = Color(red: c[0], green: c[1], blue: c[2])
    visible = json.bool("visible")
    locked = json.bool("locked")
    muted = json.bool("muted")
    selected = json.bool("selected")
    active = json.bool("active")
    extrapolation = json.int("extrapolation") ?? 0
    let numbers = (json["keys"] as? [NSNumber])?.map(\.doubleValue) ?? []
    let flags = (json["flags"] as? [NSNumber])?.map(\.intValue) ?? []
    var keys: [FCurveKey] = []
    keys.reserveCapacity(flags.count)
    for (i, flag) in flags.enumerated() where numbers.count >= (i + 1) * 6 {
      let n = i * 6
      keys.append(FCurveKey(frame: numbers[n + 2], value: numbers[n + 3],
                            left: CGPoint(x: numbers[n], y: numbers[n + 1]),
                            right: CGPoint(x: numbers[n + 4], y: numbers[n + 5]), flags: flag))
    }
    self.keys = keys
    let samples = (json["samples"] as? [NSNumber])?.map(\.doubleValue) ?? []
    if samples.count > 2 {
      sampleStart = samples[0]
      sampleStep = samples[1]
      self.samples = Array(samples.dropFirst(2))
    }
    else {
      sampleStart = 0
      sampleStep = 0
      self.samples = []
    }
  }
}

/** A key or one of its handles. */
struct FCurvePick: Equatable, Hashable {
  let curve: Int
  let key: Int
  /** 0 the key, -1 its left handle, 1 its right one. */
  let part: Int
}

@MainActor
@Observable
final class FCurveEditorModel {
  private(set) var curves: [FCurve] = []
  private(set) var frame = 1
  private(set) var received = false
  /** The selected objects' curves alone, as the Graph Editor shows by default. */
  var onlySelected = UserDefaults.standard.object(forKey: "BlenderCurvesOnlySelected") as? Bool ?? true {
    didSet {
      UserDefaults.standard.set(onlySelected, forKey: "BlenderCurvesOnlySelected")
      sendState()
      fitRequest += 1
    }
  }
  /** Each curve scaled to -1 … 1, as the Graph Editor's Normalize. */
  var normalize = false {
    didSet {
      sendState()
      fitRequest += 1
    }
  }
  var channelsShown = UserDefaults.standard.object(forKey: "BlenderCurvesChannels") as? Bool ?? true {
    didSet { UserDefaults.standard.set(channelsShown, forKey: "BlenderCurvesChannels") }
  }
  /** The channel list's width, its edge dragged to change it. */
  var channelsWidth = CGFloat(UserDefaults.standard.object(forKey: "BlenderCurvesChannelsWidth") as? Double ?? 280) {
    didSet { UserDefaults.standard.set(Double(channelsWidth), forKey: "BlenderCurvesChannelsWidth") }
  }
  /** Bumped to fit the view to the curves, or only to the selected keys. */
  private(set) var fitRequest = 0
  @ObservationIgnored private(set) var fitSelected = false
  /** The last of Blender's requests seen, as framing the view from a key. */
  @ObservationIgnored private var keyRequest: Int?
  private(set) var shown = false
  @ObservationIgnored private var raw: NSDictionary?
  @ObservationIgnored private var range: [Double] = [1, 250]
  @ObservationIgnored private var sequence: UInt64 = 0
  @ObservationIgnored private var lastRangeSent = Date.distantPast

  var visibleCurves: [FCurve] { curves.filter(\.visible) }
  var selectedKeys: [(curve: FCurve, key: FCurveKey, index: Int)] {
    curves.flatMap { curve in
      curve.keys.enumerated().compactMap { $0.element.selected ? (curve, $0.element, $0.offset) : nil }
    }
  }

  func setShown(_ shown: Bool) {
    guard shown != self.shown else { return }
    self.shown = shown
    if shown {
      sendState()
      fitRequest += 1
    }
    Engine.setting("native_graph_visible", shown ? "1" : "0")
  }

  /** The frames the canvas shows, where curves that need it are sampled; sent now and then as the
   * view moves, with a margin either side. */
  func showRange(_ from: Double, _ to: Double) {
    let width = max(1, to - from)
    let wanted = [from - width * 0.5, to + width * 0.5]
    let inside = from >= range[0] && to <= range[1] && (range[1] - range[0]) < width * 4
    guard !inside, Date().timeIntervalSince(lastRangeSent) > 0.2 else { return }
    range = wanted
    lastRangeSent = Date()
    sendState()
  }

  private var state: JSON {
    ["only_selected": onlySelected ? 1 : 0, "normalize": normalize ? 1 : 0, "range": range]
  }

  private func sendState() {
    Engine.setting("native_graph_state", json: state)
  }

  func update(_ snapshot: JSON) {
    /* The first snapshot after a drag ends shows where Blender left it, even when the last of
     * the drag's live updates already did. */
    if pendingEnd {
      pendingEnd = false
      endRevision += 1
    }
    let dictionary = snapshot as NSDictionary
    if let raw, raw.isEqual(dictionary) { return }
    raw = dictionary
    frame = snapshot.int("frame") ?? frame
    let request = snapshot.dict("request") ?? [:]
    if let sequence = request.int("sequence"), sequence != keyRequest {
      /* Only requests made since the editor opened. */
      if keyRequest != nil, let action = request.string("action") {
        requestFit(selected: action == "frame_selected")
      }
      keyRequest = sequence
    }
    else if keyRequest == nil {
      keyRequest = 0
    }
    let next = snapshot.array("curves").enumerated().map { FCurve(index: $0.offset, json: $0.element) }
    if next != curves { curves = next }
    if !received {
      received = true
      fitRequest += 1
    }
  }

  /** Set once a drag ends, until Blender's curves show where it left them. */
  private(set) var pendingEnd = false
  /** Counts the drags Blender has answered. */
  private(set) var endRevision = 0

  func send(_ action: String, _ extra: JSON = [:]) {
    sequence += 1
    var request: JSON = ["action": action, "state": state, "sequence": NSNumber(value: sequence)]
    request.merge(extra) { $1 }
    if action == "move", (extra["phase"] as? String) != "update" { pendingEnd = true }
    Engine.setting("native_graph_edit", json: request)
  }

  func runOperator(_ idname: String, _ properties: JSON = [:]) {
    send("operator", ["operator": idname, "properties": properties])
  }

  func requestFit(selected: Bool = false) {
    fitSelected = selected
    fitRequest += 1
  }
}

extension FCurveEditorModel: HardwareKeyTarget {
  var takesKeys: Bool { shown }

  func sendKey(_ key: String, shift: Bool, ctrl: Bool, alt: Bool, oskey: Bool) {
    send("key", ["key": key, "shift": shift ? 1 : 0, "ctrl": ctrl ? 1 : 0, "alt": alt ? 1 : 0,
                 "oskey": oskey ? 1 : 0])
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Drawing
 * \{ */

/** Frames and values to points and back, for a view of `size`. */
struct FCurveMapping: Equatable {
  var frames: ClosedRange<Double>
  var values: ClosedRange<Double>
  var size: CGSize

  func x(_ frame: Double) -> CGFloat {
    CGFloat((frame - frames.lowerBound) / max(1e-6, frames.upperBound - frames.lowerBound)) * size.width
  }

  func y(_ value: Double) -> CGFloat {
    size.height - CGFloat((value - values.lowerBound) / max(1e-9, values.upperBound - values.lowerBound)) *
      size.height
  }

  func point(_ p: CGPoint) -> CGPoint { CGPoint(x: x(p.x), y: y(p.y)) }

  func frame(_ x: CGFloat) -> Double {
    frames.lowerBound + Double(x / max(1, size.width)) * (frames.upperBound - frames.lowerBound)
  }

  func value(_ y: CGFloat) -> Double {
    values.lowerBound + Double((size.height - y) / max(1, size.height)) * (values.upperBound - values.lowerBound)
  }

  var framesPerPoint: Double { (frames.upperBound - frames.lowerBound) / Double(max(1, size.width)) }
  var valuesPerPoint: Double { (values.upperBound - values.lowerBound) / Double(max(1, size.height)) }
}

/** A step for grid lines about `points` apart: 1, 2 or 5 times a power of ten. */
func niceStep(_ span: Double, points: Double, size: Double) -> Double {
  let raw = span * points / max(1, size)
  let power = pow(10, floor(log10(max(raw, 1e-9))))
  for factor in [1.0, 2.0, 5.0, 10.0] where raw <= factor * power { return factor * power }
  return 10 * power
}

enum FCurveDrawing {
  /** A curve's path in view points, as Blender evaluates it between its keys, extrapolated past
   * them to the edges of the view. */
  static func path(_ curve: FCurve, _ m: FCurveMapping, offset: (Int) -> CGSize) -> Path {
    var path = Path()
    let keys = curve.keys.enumerated().map { index, key -> FCurveKey in
      let d = offset(index)
      guard d != .zero else { return key }
      var key = key
      key.frame += d.width
      key.value += d.height
      key.left.x += d.width
      key.left.y += d.height
      key.right.x += d.width
      key.right.y += d.height
      return key
    }
    if !curve.samples.isEmpty && (keys.isEmpty || offset(-1) == .zero) {
      /* Sampled by Blender. */
      for (i, value) in curve.samples.enumerated() {
        let p = CGPoint(x: m.x(curve.sampleStart + Double(i) * curve.sampleStep), y: m.y(value))
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
      }
      return path
    }
    guard let first = keys.first, let last = keys.last else { return path }
    /* Before the first key. */
    let startX = m.frames.lowerBound
    if startX < first.frame {
      path.move(to: m.point(CGPoint(x: startX, y: extrapolated(first, keys.count > 1 ? keys[1] : nil, at: startX,
                                                              before: true, curve))))
      path.addLine(to: m.point(first.point))
    }
    else {
      path.move(to: m.point(first.point))
    }
    /* Only the segments in view: a long curve's others cost time and show nothing. */
    var broken = false
    for i in 0..<(keys.count - 1) {
      let a = keys[i], b = keys[i + 1]
      if b.frame < m.frames.lowerBound || a.frame > m.frames.upperBound {
        broken = true
        continue
      }
      if broken {
        path.move(to: m.point(a.point))
        broken = false
      }
      switch a.interpolation {
        case FCurveInterpolation.constant:
          path.addLine(to: m.point(CGPoint(x: b.frame, y: a.value)))
          path.addLine(to: m.point(b.point))
        case FCurveInterpolation.linear:
          path.addLine(to: m.point(b.point))
        default:
          let (c1, c2) = corrected(a, b)
          path.addCurve(to: m.point(b.point), control1: m.point(c1), control2: m.point(c2))
      }
    }
    let endX = m.frames.upperBound
    if endX > last.frame {
      if broken { path.move(to: m.point(last.point)) }
      path.addLine(to: m.point(CGPoint(x: endX, y: extrapolated(last, keys.count > 1 ? keys[keys.count - 2] : nil,
                                                               at: endX, before: false, curve))))
    }
    return path
  }

  /** Handles pulled in so a segment never runs back in time, as Blender corrects them. */
  static func corrected(_ a: FCurveKey, _ b: FCurveKey) -> (CGPoint, CGPoint) {
    var h1 = CGPoint(x: a.right.x - a.frame, y: a.right.y - a.value)
    var h2 = CGPoint(x: b.left.x - b.frame, y: b.left.y - b.value)
    let length = b.frame - a.frame
    let total = abs(h1.x) + abs(h2.x)
    if total > length && total > 0 {
      let factor = length / total
      h1 = CGPoint(x: h1.x * factor, y: h1.y * factor)
      h2 = CGPoint(x: h2.x * factor, y: h2.y * factor)
    }
    return (CGPoint(x: a.frame + h1.x, y: a.value + h1.y), CGPoint(x: b.frame + h2.x, y: b.value + h2.y))
  }

  /** The value past the curve's ends: held, or continued along the end's slope. */
  static func extrapolated(_ end: FCurveKey, _ neighbour: FCurveKey?, at frame: Double, before: Bool,
                           _ curve: FCurve) -> Double
  {
    guard curve.extrapolation == 1 else { return end.value }
    var slope = 0.0
    if end.interpolation == FCurveInterpolation.bezier || (before && end.interpolation != FCurveInterpolation.linear) {
      let handle = before ? end.left : end.right
      let dx = handle.x - end.frame
      if abs(dx) > 1e-9 { slope = (handle.y - end.value) / dx }
    }
    else if let neighbour, abs(neighbour.frame - end.frame) > 1e-9 {
      slope = (neighbour.value - end.value) / (neighbour.frame - end.frame)
    }
    return end.value + slope * (frame - end.frame)
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Canvas
 * \{ */

struct FCurveCanvas: View {
  /** The curves' own space, which touches are measured in: a gesture's local space need not be
   * the view's, and keys under a finger then went unpicked. */
  static let space = NamedCoordinateSpace.named("FCurveCanvas")

  let model: FCurveEditorModel
  let timeline: TimelineStore
  @State private var frames: ClosedRange<Double> = 0...100
  @State private var values: ClosedRange<Double> = -1...1
  @State private var size: CGSize = .zero
  /** The view a pan or zoom started from. */
  @State private var gestureStart: (frames: ClosedRange<Double>, values: ClosedRange<Double>)?
  /** The frame and value under the fingers when a pinch began. */
  @State private var pinchAnchor: (frame: Double, value: Double)?
  /** Keys or a handle being dragged, and how far, in frames and shown values. */
  @State private var drag: (picks: Set<FCurvePick>, handle: FCurvePick?, delta: CGSize, interaction: String,
                            lastSent: CFTimeInterval)?
  /** Held after a drag until Blender's curves show it. */
  @State private var held: (picks: Set<FCurvePick>, handle: FCurvePick?, delta: CGSize)?
  /** The curves as a drag found them: Blender moves the keys live, so the drag is drawn from
   * where they began rather than adding to where they already are. */
  @State private var base: [FCurve]?
  @State private var box: CGRect?
  @State private var inspecting: FCurvePick?
  @State private var scrubbing = false

  private var mapping: FCurveMapping { FCurveMapping(frames: frames, values: values, size: size) }

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .topLeading) {
        Canvas { context, canvasSize in
          draw(&context, FCurveMapping(frames: frames, values: values, size: canvasSize))
        }
        .background(Color(uiColor: .secondarySystemBackground))
        if let box {
          Rectangle()
            .fill(Color.accentColor.opacity(0.12))
            .overlay(Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [5, 3])))
            .frame(width: box.width, height: box.height)
            .offset(x: box.minX, y: box.minY)
            .allowsHitTesting(false)
        }
        if model.received && model.visibleCurves.allSatisfy(\.keys.isEmpty) {
          ContentUnavailableView(model.onlySelected ? "No Animated Selection" : "No Animation",
                                 systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                 description: Text(model.onlySelected ?
                                   "Keyframe a selected object to edit its curves here." :
                                   "Keyframe something to edit its curves here."))
            .allowsHitTesting(false)
        }
      }
      .contentShape(Rectangle())
      .coordinateSpace(Self.space)
      .onTapGesture(coordinateSpace: Self.space) { location in tapped(at: location) }
      .modifier(FCurveGestures(began: dragBegan, changed: dragChanged, ended: dragEnded,
                               boxed: boxed, pinched: pinched, scrolled: scrolled))
      .popover(isPresented: Binding(get: { inspecting != nil }, set: { if !$0 { inspecting = nil } }),
               attachmentAnchor: .point(inspectorAnchor)) {
        FCurveKeyInspector(model: model)
          .presentationCompactAdaptation(.popover)
      }
      .onAppear {
        size = proxy.size
        fit()
      }
      .onChange(of: proxy.size) { _, next in size = next }
      .onChange(of: model.fitRequest) { _, _ in fit() }
      .onChange(of: model.endRevision) { _, _ in
        held = nil
        if drag == nil { base = nil }
      }
      .onChange(of: frames) { _, next in model.showRange(next.lowerBound, next.upperBound) }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Curves")
    }
  }

  /* -------------------------------------------------------------------- */
  /* Drawing */

  private func offset(_ curve: Int, _ key: Int, _ part: Int) -> CGSize {
    if let drag {
      if let handle = drag.handle {
        return handle == FCurvePick(curve: curve, key: key, part: part) ? drag.delta : .zero
      }
      return drag.picks.contains(FCurvePick(curve: curve, key: key, part: 0)) ? drag.delta : .zero
    }
    if let held {
      if let handle = held.handle {
        return handle == FCurvePick(curve: curve, key: key, part: part) ? held.delta : .zero
      }
      return held.picks.contains(FCurvePick(curve: curve, key: key, part: 0)) ? held.delta : .zero
    }
    return .zero
  }

  private var moving: Bool { drag != nil || held != nil }

  private func draw(_ context: inout GraphicsContext, _ m: FCurveMapping) {
    drawGrid(&context, m)
    let curves = base ?? model.visibleCurves
    /* Unselected curves first, under the selected ones. */
    for curve in curves.sorted(by: { !$0.selected && $1.selected }) {
      let path = FCurveDrawing.path(curve, m) { key in
        key < 0 ? (moving ? CGSize(width: 1, height: 0) : .zero) : offset(curve.id, key, 0)
      }
      let style = StrokeStyle(lineWidth: curve.selected ? 2 : 1.5, lineCap: .round,
                              dash: curve.locked ? [4, 4] : [])
      context.stroke(path, with: .color(curve.color.opacity(curve.selected ? 1 : 0.55)), style: style)
    }
    /* Keys, and the handles of selected ones, as the Graph Editor shows by default. Each kind is
     * one path, so thousands of keys draw as a handful of shapes; keys too close together to
     * tell apart leave out their handles, then themselves. */
    let accent = Color.orange
    var handleLines = Path(), handleDots = Path(), selectedDots = Path()
    var keysShown = Path(), selectedKeys = Path()
    for curve in curves {
      let inView = curve.keys.reduce(0) { $0 + (m.frames.contains($1.frame) ? 1 : 0) }
      let spacing = m.size.width / CGFloat(max(1, inView))
      let showHandles = spacing >= 14, showKeys = spacing >= 4
      guard showKeys else { continue }
      for (index, key) in curve.keys.enumerated() {
        let d = offset(curve.id, index, 0)
        let point = m.point(CGPoint(x: key.frame + d.width, y: key.value + d.height))
        guard point.x > -20 && point.x < m.size.width + 20 else { continue }
        if showHandles, key.selected || key.leftSelected || key.rightSelected,
           key.interpolation == FCurveInterpolation.bezier || (index > 0 && curve.keys[index - 1].interpolation == FCurveInterpolation.bezier)
        {
          for side in [-1, 1] {
            let handle = side < 0 ? key.left : key.right
            let hd = offset(curve.id, index, side) == .zero ? d : offset(curve.id, index, side)
            let h = m.point(CGPoint(x: handle.x + hd.width, y: handle.y + hd.height))
            handleLines.move(to: point)
            handleLines.addLine(to: h)
            let dot = CGRect(x: h.x - 3.5, y: h.y - 3.5, width: 7, height: 7)
            if side < 0 ? key.leftSelected : key.rightSelected {
              selectedDots.addEllipse(in: dot)
            }
            else {
              handleDots.addEllipse(in: dot)
            }
          }
        }
        let size: CGFloat = (key.selected ? 9 : 7) / 2 + 1
        let diamond = Path { p in
          p.move(to: CGPoint(x: point.x, y: point.y - size))
          p.addLine(to: CGPoint(x: point.x + size, y: point.y))
          p.addLine(to: CGPoint(x: point.x, y: point.y + size))
          p.addLine(to: CGPoint(x: point.x - size, y: point.y))
          p.closeSubpath()
        }
        if key.selected {
          selectedKeys.addPath(diamond)
        }
        else {
          keysShown.addPath(diamond)
        }
      }
    }
    context.stroke(handleLines, with: .color(.secondary), lineWidth: 1)
    context.fill(handleDots, with: .color(Color(uiColor: .systemBackground)))
    context.stroke(handleDots, with: .color(.secondary), lineWidth: 1)
    context.fill(selectedDots, with: .color(accent))
    for (shape, color) in [(keysShown, Color(uiColor: .label)), (selectedKeys, accent)] {
      context.fill(shape, with: .color(color))
      context.stroke(shape, with: .color(Color(uiColor: .systemBackground)), lineWidth: 1)
    }
    /* The playhead, the timeline's own up through the curves. */
    let x = m.x(Double(timeline.frame.blender))
    var playhead = Path()
    playhead.move(to: CGPoint(x: x, y: 0))
    playhead.addLine(to: CGPoint(x: x, y: m.size.height))
    context.stroke(playhead, with: .color(.accentColor), lineWidth: 2)
    let label = context.resolve(Text("\(timeline.frame.blender)").font(.caption2.weight(.semibold).monospacedDigit())
      .foregroundStyle(.white))
    let labelSize = label.measure(in: CGSize(width: 80, height: 20))
    let tag = CGRect(x: x - labelSize.width / 2 - 6, y: 2, width: labelSize.width + 12, height: labelSize.height + 4)
    context.fill(Path(roundedRect: tag, cornerRadius: tag.height / 2), with: .color(.accentColor))
    context.draw(label, at: CGPoint(x: tag.midX, y: tag.midY))
  }

  private func drawGrid(_ context: inout GraphicsContext, _ m: FCurveMapping) {
    let frameStep = max(1, niceStep(m.frames.upperBound - m.frames.lowerBound, points: 70, size: m.size.width))
    let valueStep = niceStep(m.values.upperBound - m.values.lowerBound, points: 50, size: m.size.height)
    var lines = Path()
    var f = (m.frames.lowerBound / frameStep).rounded(.down) * frameStep
    while f <= m.frames.upperBound {
      let x = m.x(f)
      lines.move(to: CGPoint(x: x, y: 0))
      lines.addLine(to: CGPoint(x: x, y: m.size.height))
      let text = context.resolve(Text(format(f)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary))
      context.draw(text, at: CGPoint(x: x + 3, y: m.size.height - 3), anchor: .bottomLeading)
      f += frameStep
    }
    var v = (m.values.lowerBound / valueStep).rounded(.down) * valueStep
    while v <= m.values.upperBound {
      let y = m.y(v)
      lines.move(to: CGPoint(x: 0, y: y))
      lines.addLine(to: CGPoint(x: m.size.width, y: y))
      let text = context.resolve(Text(format(v)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary))
      context.draw(text, at: CGPoint(x: 4, y: y - 2), anchor: .bottomLeading)
      v += valueStep
    }
    context.stroke(lines, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
    /* The scene's frame range, lighter outside it. */
    let start = m.x(Double(timeline.start)), end = m.x(Double(timeline.end))
    context.fill(Path(CGRect(x: 0, y: 0, width: max(0, start), height: m.size.height)),
                 with: .color(.black.opacity(0.05)))
    context.fill(Path(CGRect(x: end, y: 0, width: max(0, m.size.width - end), height: m.size.height)),
                 with: .color(.black.opacity(0.05)))
  }

  private func format(_ number: Double) -> String {
    let rounded = (number * 1000).rounded() / 1000
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%g", rounded)
  }

  /* -------------------------------------------------------------------- */
  /* Picking */

  /** The key or handle under a point, within reach of a finger; handles of selected keys first. */
  private func pick(at point: CGPoint) -> FCurvePick? {
    let m = mapping
    var best: (FCurvePick, CGFloat)?
    for curve in model.visibleCurves {
      for (index, key) in curve.keys.enumerated() {
        var candidates: [(Int, CGPoint)] = [(0, key.point)]
        if key.selected || key.leftSelected || key.rightSelected {
          candidates.append((-1, key.left))
          candidates.append((1, key.right))
        }
        for (part, p) in candidates {
          let v = m.point(p)
          let distance = hypot(v.x - point.x, v.y - point.y)
          /* Keys win over handles at the same spot. */
          let score = distance + (part == 0 ? 0 : 4)
          if distance < 24, score < (best?.1 ?? .infinity) {
            best = (FCurvePick(curve: curve.id, key: index, part: part), score)
          }
        }
      }
    }
    return best?.0
  }

  private func isSelected(_ pick: FCurvePick) -> Bool {
    guard let curve = model.curves.first(where: { $0.id == pick.curve }), pick.key < curve.keys.count else {
      return false
    }
    let key = curve.keys[pick.key]
    return pick.part == 0 ? key.selected : pick.part < 0 ? key.leftSelected : key.rightSelected
  }

  private var inspectorAnchor: UnitPoint {
    guard let inspecting, let curve = model.curves.first(where: { $0.id == inspecting.curve }),
          inspecting.key < curve.keys.count, size.width > 0, size.height > 0
    else { return .center }
    let p = mapping.point(curve.keys[inspecting.key].point)
    return UnitPoint(x: p.x / size.width, y: p.y / size.height)
  }

  private func tapped(at location: CGPoint) {
    guard let picked = pick(at: location) else {
      model.send("select_all", ["value": 0])
      return
    }
    if picked.part == 0, isSelected(picked) {
      /* Tapped again, its settings. */
      inspecting = picked
      return
    }
    model.send("select", ["keys": [[picked.curve, picked.key, picked.part]], "extend": 0])
    UISelectionFeedbackGenerator().selectionChanged()
  }

  /* -------------------------------------------------------------------- */
  /* Gestures */

  /** A finger drag: on a key or handle it moves it, with the other selected keys; anywhere else
   * it pans. */
  private func dragBegan(_ start: CGPoint) {
    gestureStart = (frames, values)
    guard let picked = pick(at: start),
          !(model.curves.first(where: { $0.id == picked.curve })?.locked ?? false)
    else { return }
    if !isSelected(picked) {
      model.send("select", ["keys": [[picked.curve, picked.key, picked.part]], "extend": 0])
    }
    var picks: Set<FCurvePick> = []
    if picked.part == 0 {
      for curve in model.curves where !curve.locked {
        for (index, key) in curve.keys.enumerated() where key.selected || (curve.id == picked.curve && index == picked.key) {
          if isSelected(picked) || (curve.id == picked.curve && index == picked.key) {
            picks.insert(FCurvePick(curve: curve.id, key: index, part: 0))
          }
        }
      }
    }
    base = model.visibleCurves
    drag = (picks, picked.part == 0 ? nil : picked, .zero, UUID().uuidString, 0)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

  private func dragChanged(_ start: CGPoint, _ location: CGPoint) {
    if var current = drag {
      let m = mapping
      var dx = (location.x - start.x) * m.framesPerPoint
      let dy = -(location.y - start.y) * m.valuesPerPoint
      /* Keys snap to whole frames, with a tick as they pass each. */
      if current.handle == nil { dx = dx.rounded() }
      if dx != current.delta.width && current.handle == nil { UISelectionFeedbackGenerator().selectionChanged() }
      current.delta = CGSize(width: dx, height: dy)
      if CACurrentMediaTime() - current.lastSent >= 1.0 / 30.0 {
        send(current, phase: "update")
        current.lastSent = CACurrentMediaTime()
      }
      drag = current
      return
    }
    guard let base = gestureStart else { return }
    let m = FCurveMapping(frames: base.frames, values: base.values, size: size)
    let df = Double(location.x - start.x) * m.framesPerPoint
    let dv = Double(location.y - start.y) * m.valuesPerPoint
    frames = (base.frames.lowerBound - df)...(base.frames.upperBound - df)
    values = (base.values.lowerBound + dv)...(base.values.upperBound + dv)
  }

  private func dragEnded(_ cancelled: Bool) {
    gestureStart = nil
    guard let current = drag else { return }
    drag = nil
    if current.delta == .zero && !cancelled {
      base = nil
      return
    }
    send(current, phase: cancelled ? "cancel" : "end")
    if cancelled { base = nil } else { held = (current.picks, current.handle, current.delta) }
  }

  private func send(_ drag: (picks: Set<FCurvePick>, handle: FCurvePick?, delta: CGSize, interaction: String,
                             lastSent: CFTimeInterval), phase: String)
  {
    var request: JSON = ["df": Double(drag.delta.width), "dv": Double(drag.delta.height),
                         "interaction": drag.interaction, "phase": phase]
    if let handle = drag.handle {
      request["curve"] = handle.curve
      request["key"] = handle.key
      request["side"] = handle.part
    }
    model.send("move", request)
  }

  private func boxed(_ state: UIGestureRecognizer.State, _ start: CGPoint, _ location: CGPoint) {
    switch state {
      case .began, .changed:
        box = CGRect(x: min(start.x, location.x), y: min(start.y, location.y),
                     width: abs(location.x - start.x), height: abs(location.y - start.y))
      case .ended:
        guard let rect = box else { return }
        box = nil
        let m = mapping
        model.send("box", ["f0": m.frame(rect.minX), "f1": m.frame(rect.maxX),
                           "v0": m.value(rect.maxY), "v1": m.value(rect.minY), "extend": 1])
      default:
        box = nil
    }
  }

  /** Two fingers: spread sideways to zoom time, up and down to zoom values; the frame and value
   * first under their middle stay under it as they move. */
  private func pinched(_ phase: UIGestureRecognizer.State, _ scale: CGSize, _ center: CGPoint) {
    switch phase {
      case .began:
        gestureStart = (frames, values)
        let m = mapping
        pinchAnchor = (m.frame(center.x), m.value(center.y))
      case .changed:
        guard let base = gestureStart, let anchor = pinchAnchor, size.width > 0, size.height > 0 else { return }
        let sx = max(0.05, Double(scale.width)), sy = max(0.05, Double(scale.height))
        let frameSpan = (base.frames.upperBound - base.frames.lowerBound) / sx
        let valueSpan = (base.values.upperBound - base.values.lowerBound) / sy
        let firstFrame = anchor.frame - Double(center.x / size.width) * frameSpan
        let firstValue = anchor.value - Double((size.height - center.y) / size.height) * valueSpan
        frames = firstFrame...(firstFrame + frameSpan)
        values = firstValue...(firstValue + valueSpan)
      default:
        gestureStart = nil
        pinchAnchor = nil
    }
  }

  private func scrolled(_ translation: CGSize, _ ended: Bool) {
    if ended {
      gestureStart = nil
      return
    }
    if gestureStart == nil { gestureStart = (frames, values) }
    dragChanged(.zero, CGPoint(x: translation.width, y: translation.height))
  }

  /** The visible curves in view, or the scene's range when there are none. */
  private func fit() {
    var minFrame = Double.infinity, maxFrame = -Double.infinity
    var minValue = Double.infinity, maxValue = -Double.infinity
    let selected = model.fitSelected && !model.selectedKeys.isEmpty
    for curve in model.visibleCurves {
      for key in curve.keys where !selected || key.selected {
        minFrame = min(minFrame, key.frame)
        maxFrame = max(maxFrame, key.frame)
        minValue = min(minValue, key.value, key.left.y, key.right.y)
        maxValue = max(maxValue, key.value, key.left.y, key.right.y)
      }
    }
    if !minFrame.isFinite {
      minFrame = Double(timeline.start)
      maxFrame = Double(timeline.end)
      minValue = -1
      maxValue = 1
    }
    if maxFrame - minFrame < 10 {
      minFrame -= 5
      maxFrame += 5
    }
    if maxValue - minValue < 0.1 {
      minValue -= 1
      maxValue += 1
    }
    let fm = (maxFrame - minFrame) * 0.08, vm = (maxValue - minValue) * 0.15
    withAnimation(.easeInOut(duration: 0.25)) {
      frames = (minFrame - fm)...(maxFrame + fm)
      values = (minValue - vm)...(maxValue + vm)
    }
  }
}

/** The canvas's touches: a finger drag (keys or panning), touch-and-hold or a pointer to box
 * select, two fingers to zoom each axis, and a trackpad's scrolling to pan. */
struct FCurveGestures: ViewModifier {
  let began: (CGPoint) -> Void
  let changed: (CGPoint, CGPoint) -> Void
  let ended: (Bool) -> Void
  let boxed: (UIGestureRecognizer.State, CGPoint, CGPoint) -> Void
  let pinched: (UIGestureRecognizer.State, CGSize, CGPoint) -> Void
  let scrolled: (CGSize, Bool) -> Void
#if os(visionOS)
  /** A pinch-drag going on, begun where it started. */
  @State private var dragging = false
  @State private var magnifying = false
#endif

  func body(content: Content) -> some View {
#if os(visionOS)
    /* A pinch and drag moves a key, or the view; both hands pinching zoom about where they began. */
    content
      .gesture(DragGesture(minimumDistance: 4, coordinateSpace: FCurveCanvas.space)
        .onChanged { value in
          if !dragging {
            dragging = true
            began(value.startLocation)
          }
          changed(value.startLocation, value.location)
        }
        .onEnded { _ in
          dragging = false
          ended(false)
        })
      .simultaneousGesture(MagnifyGesture()
        .onChanged { value in
          if !magnifying {
            magnifying = true
            pinched(.began, CGSize(width: 1, height: 1), value.startLocation)
          }
          let scale = CGFloat(value.magnification)
          pinched(.changed, CGSize(width: scale, height: scale), value.startLocation)
        }
        .onEnded { value in
          magnifying = false
          pinched(.ended, CGSize(width: 1, height: 1), value.startLocation)
        })
#else
    content
      .gesture(FCurveFingers(dragged: { state, start, location in
        switch state {
          case .began:
            began(start)
            changed(start, location)
          case .changed: changed(start, location)
          case .ended: ended(false)
          default: ended(true)
        }
      }, pinched: pinched))
      .gesture(NodeCanvasDrag(kind: .hold, space: FCurveCanvas.space) { state, start, location in
        boxed(state, start, location)
      })
      .gesture(NodeCanvasDrag(kind: .pointer, space: FCurveCanvas.space) { state, start, location in
        boxed(state, start, location)
      })
      .gesture(NodeCanvasDrag(kind: .scroll) { state, _, location in
        scrolled(CGSize(width: location.x, height: location.y), state == .ended || state == .cancelled)
      })
#endif
  }
}

#if !os(visionOS)
/** One finger dragging, or two pinching and moving the view: one recognizer for both, so a pinch
 * whose first finger moved a little sooner doesn't turn into a drag. A pan won't do: it waits for
 * the fingers' middle to move, which a pinch hardly does. */
final class FCurveTouches: UIGestureRecognizer {
  private(set) var touches: [UITouch] = []
  /** Where the first finger came down, in the view: the drag starts there, not where it was
   * recognized. */
  private(set) var touchDown: CGPoint?
  private(set) var pinching = false

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesBegan(touches, with: event)
    self.touches.append(contentsOf: touches)
    if touchDown == nil { touchDown = touches.first?.location(in: view) }
    guard self.touches.count >= 2 else { return }
    pinching = true
    state = state == .possible ? .began : .changed
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesMoved(touches, with: event)
    if state != .possible {
      state = .changed
    }
    else if let touchDown, let touch = self.touches.first {
      let point = touch.location(in: view)
      if hypot(point.x - touchDown.x, point.y - touchDown.y) > 8 { state = .began }
    }
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesEnded(touches, with: event)
    lift(touches, cancelled: false)
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesCancelled(touches, with: event)
    lift(touches, cancelled: true)
  }

  private func lift(_ lifted: Set<UITouch>, cancelled: Bool) {
    touches.removeAll { lifted.contains($0) }
    if !touches.isEmpty {
      if state != .possible { state = .changed }
      return
    }
    state = state == .possible ? .failed : cancelled ? .cancelled : .ended
  }

  override func reset() {
    super.reset()
    touches = []
    touchDown = nil
    pinching = false
  }

  /** The fingers' spread along each axis. */
  var span: CGSize {
    guard touches.count >= 2 else { return CGSize(width: 1, height: 1) }
    let a = touches[0].location(in: view), b = touches[1].location(in: view)
    return CGSize(width: abs(a.x - b.x), height: abs(a.y - b.y))
  }
}

struct FCurveFingers: UIGestureRecognizerRepresentable {
  let dragged: (UIGestureRecognizer.State, CGPoint, CGPoint) -> Void
  let pinched: (UIGestureRecognizer.State, CGSize, CGPoint) -> Void

  final class Coordinator {
    var start = CGPoint.zero
    var dragging = false
    var pinching = false
    var startSpan = CGSize(width: 1, height: 1)
  }

  func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

  func makeUIGestureRecognizer(context: Context) -> FCurveTouches {
    let touches = FCurveTouches()
    touches.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    return touches
  }

  func handleUIGestureRecognizerAction(_ recognizer: FCurveTouches, context: Context) {
    let coordinator = context.coordinator
    /* The fingers' middle. */
    let location = context.converter.location(in: FCurveCanvas.space)
    let finished = [.ended, .cancelled, .failed].contains(recognizer.state)
    if recognizer.pinching {
      if coordinator.dragging {
        /* A second finger: what the first was doing gives way to the pinch. */
        coordinator.dragging = false
        dragged(.cancelled, coordinator.start, location)
      }
      if !coordinator.pinching {
        guard !finished, recognizer.touches.count >= 2 else { return }
        coordinator.pinching = true
        coordinator.startSpan = recognizer.span
        pinched(.began, CGSize(width: 1, height: 1), location)
      }
      else if finished || recognizer.touches.count < 2 {
        /* With a finger still down, the rest of the touch does nothing. */
        coordinator.pinching = false
        pinched(.ended, CGSize(width: 1, height: 1), location)
      }
      else {
        pinched(.changed, recognizer.span.scale(from: coordinator.startSpan), location)
      }
      return
    }
    if !coordinator.dragging {
      guard !finished else { return }
      /* From where the finger came down, before it moved far enough to begin. */
      let here = recognizer.location(in: recognizer.view)
      let down = recognizer.touchDown ?? here
      coordinator.start = CGPoint(x: location.x - here.x + down.x, y: location.y - here.y + down.y)
      coordinator.dragging = true
      dragged(.began, coordinator.start, location)
      return
    }
    if finished { coordinator.dragging = false }
    dragged(finished ? recognizer.state : .changed, coordinator.start, location)
  }
}

private extension CGSize {
  /** An axis the fingers hardly span stays as it is. */
  func scale(from start: CGSize) -> CGSize {
    CGSize(width: start.width > 40 ? width / start.width : 1, height: start.height > 40 ? height / start.height : 1)
  }
}
#endif

/** \} */

/* -------------------------------------------------------------------- */
/** \name Key Settings
 * \{ */

/** The selected keys' frame, value and how they join, as the Graph Editor's sidebar and menus
 * set them: system controls, unlike the canvas. */
struct FCurveKeyInspector: View {
  let model: FCurveEditorModel

  private var first: FCurveKey? { model.selectedKeys.first?.key }

  var body: some View {
    NavigationStack {
      Form {
        if let first {
          Section {
            FCurveNumberRow(label: "Frame", value: first.frame) { model.send("set", ["frame": $0]) }
            FCurveNumberRow(label: "Value", value: first.value) { model.send("set", ["value": $0]) }
          }
          Section {
            FCurveMenus(model: model)
          }
        }
        else {
          Text("No keyframes selected").foregroundStyle(.secondary)
        }
      }
      .navigationTitle(model.selectedKeys.count > 1 ? "\(model.selectedKeys.count) Keyframes" : "Keyframe")
      .navigationBarTitleDisplayMode(.inline)
    }
    .frame(minWidth: 340, minHeight: 420)
  }
}

/** A typed number: all of it selected to type over, set when done, and following Blender while
 * not being typed in. */
private struct FCurveNumberRow: View {
  let label: String
  let value: Double
  let commit: (Double) -> Void
  @State private var text = ""
  @FocusState private var focused: Bool

  private var shown: String { String(format: "%g", (value * 1000).rounded() / 1000) }

  var body: some View {
    LabeledContent(label) {
      TextField(label, text: $text)
        .multilineTextAlignment(.trailing)
        .keyboardType(.numbersAndPunctuation)
        .submitLabel(.done)
        .focused($focused)
        .onSubmit { focused = false }
    }
    .onAppear { text = shown }
    .onChange(of: value) { _, _ in if !focused { text = shown } }
    .onChange(of: focused) { _, isFocused in
      if isFocused {
        DispatchQueue.main.async {
          UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
        }
        return
      }
      if text != shown, let number = Double(text.replacingOccurrences(of: ",", with: ".")) {
        commit(number)
      }
      else {
        text = shown
      }
    }
  }
}

/** Interpolation, easing, handles and extrapolation, as the Graph Editor's Key and Channel menus
 * set them on the selected keys and curves. */
struct FCurveMenus: View {
  let model: FCurveEditorModel

  static let interpolations: [(String, String)] = [
    ("CONSTANT", "Constant"), ("LINEAR", "Linear"), ("BEZIER", "Bézier"),
    ("SINE", "Sinusoidal"), ("QUAD", "Quadratic"), ("CUBIC", "Cubic"), ("QUART", "Quartic"),
    ("QUINT", "Quintic"), ("EXPO", "Exponential"), ("CIRC", "Circular"),
    ("BACK", "Back"), ("BOUNCE", "Bounce"), ("ELASTIC", "Elastic"),
  ]
  static let easings: [(String, String)] = [
    ("AUTO", "Automatic"), ("EASE_IN", "Ease In"), ("EASE_OUT", "Ease Out"), ("EASE_IN_OUT", "Ease In and Out"),
  ]
  static let handles: [(String, String)] = [
    ("FREE", "Free"), ("VECTOR", "Vector"), ("ALIGNED", "Aligned"), ("AUTO", "Automatic"),
    ("AUTO_CLAMPED", "Auto Clamped"),
  ]

  var body: some View {
    Menu {
      ForEach(Self.interpolations, id: \.0) { item in
        Button(item.1) { model.runOperator("GRAPH_OT_interpolation_type", ["type": item.0]) }
      }
    } label: {
      Label("Interpolation", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
    }
    Menu {
      ForEach(Self.easings, id: \.0) { item in
        Button(item.1) { model.runOperator("GRAPH_OT_easing_type", ["type": item.0]) }
      }
    } label: {
      Label("Easing", systemImage: "chart.line.uptrend.xyaxis")
    }
    Menu {
      ForEach(Self.handles, id: \.0) { item in
        Button(item.1) { model.runOperator("GRAPH_OT_handle_type", ["type": item.0]) }
      }
    } label: {
      Label("Handle Type", systemImage: "line.diagonal")
    }
    Menu {
      Button("Constant") { model.runOperator("GRAPH_OT_extrapolation_type", ["type": "CONSTANT"]) }
      Button("Linear") { model.runOperator("GRAPH_OT_extrapolation_type", ["type": "LINEAR"]) }
      Button("Make Cyclic") { model.runOperator("GRAPH_OT_extrapolation_type", ["type": "MAKE_CYCLIC"]) }
      Button("Clear Cyclic") { model.runOperator("GRAPH_OT_extrapolation_type", ["type": "CLEAR_CYCLIC"]) }
    } label: {
      Label("Extrapolation", systemImage: "arrow.left.and.right")
    }
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Channels
 * \{ */

/** The curves by owner, each with its color, eye, lock and mute, as the Graph Editor's channel
 * list; tapping one makes it active. */
struct FCurveChannels: View {
  let model: FCurveEditorModel

  var body: some View {
    let owners = Dictionary(grouping: model.curves, by: \.owner)
    let order = model.curves.map(\.owner).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    List {
      ForEach(order, id: \.self) { owner in
        Section(owner) {
          ForEach(owners[owner] ?? []) { curve in
            row(curve)
          }
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .overlay {
      if model.received && model.curves.isEmpty {
        Text("No Channels").foregroundStyle(.secondary)
      }
    }
  }

  private func row(_ curve: FCurve) -> some View {
    HStack(spacing: 8) {
      Circle().fill(curve.color).frame(width: 10, height: 10)
      Text(curve.name)
        .lineLimit(1)
        .foregroundStyle(curve.visible ? .primary : .secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
      settingButton(curve, "visible", on: curve.visible, onImage: "eye", offImage: "eye.slash", label: "Show")
      settingButton(curve, "locked", on: curve.locked, onImage: "lock.fill", offImage: "lock.open", label: "Lock")
      settingButton(curve, "muted", on: curve.muted, onImage: "speaker.slash.fill", offImage: "speaker.wave.2",
                    label: "Mute")
    }
    .font(.subheadline)
    .contentShape(Rectangle())
    .onTapGesture { model.send("channel", ["curve": curve.id, "setting": "active"]) }
    .listRowBackground(curve.active ? Color.accentColor.opacity(0.18) : Color.clear)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(curve.active ? .isSelected : [])
  }

  private func settingButton(_ curve: FCurve, _ setting: String, on: Bool, onImage: String, offImage: String,
                             label: String) -> some View
  {
    Button {
      model.send("channel", ["curve": curve.id, "setting": setting, "value": on ? 0 : 1])
    } label: {
      Image(systemName: on ? onImage : offImage)
        .foregroundStyle(on ? .primary : .tertiary)
        .frame(width: 26, height: 26)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel("\(label) \(curve.name)")
    .accessibilityAddTraits(on ? .isSelected : [])
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Editor
 * \{ */

/** The curve editor over the timeline's controls: its toolbar, the channels and the curves. */
struct FCurveEditorView: View {
  let model: FCurveEditorModel
  let timeline: TimelineStore

  /** The channel list's width when its edge began to be dragged. */
  @State private var resizeStart: CGFloat?

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      GeometryReader { proxy in
        HStack(spacing: 0) {
          if model.channelsShown {
            FCurveChannels(model: model)
              .frame(width: min(model.channelsWidth, maxChannelsWidth(proxy.size.width)))
              .transition(.move(edge: .leading).combined(with: .opacity))
            Divider()
              .overlay { resizeHandle(proxy.size.width) }
          }
          FCurveCanvas(model: model, timeline: timeline)
        }
      }
    }
    /* A hardware keyboard's keys run as the Graph Editor's keymap has them while it was touched last. */
    .background(NodeKeyCapture(model: model))
  }

  private func maxChannelsWidth(_ width: CGFloat) -> CGFloat { max(180, width * 0.6) }

  /** The edge between the channels and the curves, dragged to make the channels wider or
   * narrower; dragged far enough in, they close, as sidebars do. */
  private func resizeHandle(_ width: CGFloat) -> some View {
    Color.clear
      .frame(width: 20)
      .contentShape(Rectangle())
      .gesture(
        /* Measured in the window: the handle moves with the drag. */
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
          .onChanged { value in
            let start = resizeStart ?? min(model.channelsWidth, maxChannelsWidth(width))
            resizeStart = start
            model.channelsWidth = min(maxChannelsWidth(width), max(180, start + value.translation.width))
          }
          .onEnded { value in
            let start = resizeStart ?? model.channelsWidth
            resizeStart = nil
            if start + value.translation.width < 110 {
              withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { model.channelsShown = false }
            }
          })
      .accessibilityLabel("Resize Channels")
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      Button {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { model.channelsShown.toggle() }
      } label: {
        Label("Channels", systemImage: "sidebar.left")
      }
      .labelStyle(.iconOnly)
      .accessibilityAddTraits(model.channelsShown ? .isSelected : [])
      Text("Curves").font(.headline)
      Spacer(minLength: 0)
      Button("Frame All", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { model.requestFit() }
        .labelStyle(.iconOnly)
      Menu {
        FCurveMenus(model: model)
        Section {
          Button("Insert Keyframe", systemImage: "plus.diamond") {
            model.runOperator("GRAPH_OT_keyframe_insert", ["type": "ALL"])
          }
          Button("Duplicate", systemImage: "plus.square.on.square") { model.runOperator("GRAPH_OT_duplicate") }
          Button("Smooth", systemImage: "scribble.variable") { model.runOperator("GRAPH_OT_smooth") }
          Button("Clean", systemImage: "wand.and.stars") { model.runOperator("GRAPH_OT_clean", ["channels": false]) }
          Button("Snap to Nearest Frame", systemImage: "arrow.right.to.line") {
            model.runOperator("GRAPH_OT_snap", ["type": "NEAREST_FRAME"])
          }
          Button("Snap to Playhead", systemImage: "arrow.down.to.line") {
            model.runOperator("GRAPH_OT_snap", ["type": "CFRA"])
          }
          Button("Discontinuity (Euler) Filter", systemImage: "rotate.3d") { model.runOperator("GRAPH_OT_euler_filter") }
        }
        Section {
          Button("Select All", systemImage: "checkmark.circle") { model.send("select_all", ["value": 1]) }
          Button("Deselect All", systemImage: "circle") { model.send("select_all", ["value": 0]) }
        }
        Section {
          Toggle(isOn: Binding(get: { model.onlySelected }, set: { model.onlySelected = $0 })) {
            Label("Only Show Selected", systemImage: "cube")
          }
          Toggle(isOn: Binding(get: { model.normalize }, set: { model.normalize = $0 })) {
            Label("Normalize", systemImage: "arrow.up.and.down.square")
          }
        }
        Section {
          Button("Delete Keyframes", systemImage: "trash", role: .destructive) { model.runOperator("GRAPH_OT_delete") }
        }
      } label: {
        Label("More", systemImage: "ellipsis.circle")
      }
      .labelStyle(.iconOnly)
    }
    .font(.title3)
    .padding(.horizontal, 14)
    .frame(height: 44)
  }
}

/** \} */
