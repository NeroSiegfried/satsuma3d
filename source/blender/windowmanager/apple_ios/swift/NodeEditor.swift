/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Node editors drawn natively: a material's shader nodes, an object's Geometry Nodes and the
 * scene's compositor nodes. Blender publishes the tree, its nodes, sockets, controls and links;
 * the canvas draws them as cards and wires, and sends back what the person does to them: select,
 * move, connect, add, delete, mute and change values, each an undoable change to the tree.
 */

import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/* -------------------------------------------------------------------- */
/** \name Model
 * \{ */

@MainActor
@Observable
final class NodeEditorModel {
  enum Kind: String, CaseIterable, Identifiable {
    case shader = "SHADER", geometry = "GEOMETRY", compositor = "COMPOSITOR"
    var id: String { rawValue }
    var title: String {
      switch self {
        case .shader: return "Shader Editor"
        case .geometry: return "Geometry Nodes"
        case .compositor: return "Compositor"
      }
    }
  }

  private(set) var kind: Kind = .shader
  /** The group nodes entered, by name, outermost first. */
  private(set) var path: [String] = []
  private(set) var snapshot: JSON?
  /** The snapshot as Blender sent it, to tell a new one from the same. */
  @ObservationIgnored private var raw: JSON?
  private(set) var shown = false
  /** Bumped to fit the view to the tree, as when another tree shows. */
  private(set) var fitRequest = 0
  /** The controls on the nodes, which edit through the same store as Properties' controls. */
  let store = InspectorStore(mode: .nodes)
  @ObservationIgnored var shownChanged: (Bool) -> Void = { _ in }

  var nodes: [JSON] { snapshot?.array("nodes") ?? [] }
  var links: [JSON] { snapshot?.array("links") ?? [] }
  var addItems: [JSON] { snapshot?.array("add") ?? [] }

  /** The compositor's result behind the nodes, as Blender's backdrop. */
  var backdrop = UserDefaults.standard.object(forKey: "BlenderNodeBackdrop") as? Bool ?? true {
    didSet {
      UserDefaults.standard.set(backdrop, forKey: "BlenderNodeBackdrop")
      sendState()
    }
  }
  /** How long each node took, above it, as Blender's Timings overlay. */
  var timings = UserDefaults.standard.bool(forKey: "BlenderNodeTimings") {
    didSet { UserDefaults.standard.set(timings, forKey: "BlenderNodeTimings") }
  }
  /** Blender's keymap asked for the Add menu. */
  var addRequested = 0
  @ObservationIgnored private var keyRequestSeen: Int?

  private var context: JSON {
    ["tree": kind.rawValue, "path": path, "backdrop": backdrop ? 1 : 0, "previews": 1]
  }

  func setShown(_ shown: Bool) {
    guard shown != self.shown else { return }
    self.shown = shown
    if shown {
      sendState()
      fitRequest += 1
    }
    Engine.setting("native_nodes_visible", shown ? "1" : "0")
    shownChanged(shown)
  }

  func toggle() { setShown(!shown) }

  func setKind(_ kind: Kind) {
    guard kind != self.kind else { return }
    self.kind = kind
    path = []
    snapshot = nil
    raw = nil
    sendState()
    fitRequest += 1
  }

  func enter(group node: String) {
    path.append(node)
    snapshot = nil
    raw = nil
    sendState()
    fitRequest += 1
  }

  /** Back out to `depth` groups deep, 0 for the tree itself. */
  func exit(to depth: Int) {
    guard depth < path.count else { return }
    path = Array(path.prefix(depth))
    snapshot = nil
    raw = nil
    sendState()
    fitRequest += 1
  }

  private func sendState() {
    store.requestContext = context
    Engine.setting("native_nodes_state", json: context)
  }

  func update(_ next: JSON, ack: UInt64) {
    guard next.string("tree") == kind.rawValue else { return }
    /* A group that is gone leaves the path where it still reaches. */
    let reached = next.array("path").count
    if next["nodes"] != nil, reached < path.count {
      path = Array(path.prefix(reached))
      store.requestContext = context
    }
    store.clearPendingValues(ack: ack)
    /* What a key asked of the editor itself, once. */
    if let request = next.dict("key_request"), let sequence = request.int("sequence") {
      if let seen = keyRequestSeen, sequence > seen {
        switch request.string("action") {
          case "add": addRequested += 1
          case "enter": if let node = request.string("node") { enter(group: node) }
          case "exit": exit(to: max(0, path.count - 1))
          default: break
        }
      }
      keyRequestSeen = sequence
    }
    /* The nodes it can add come once for each tree. */
    var next = next
    if next["add"] == nil, let add = snapshot?["add"], next["nodes"] != nil { next["add"] = add }
    if let raw, (raw as NSDictionary).isEqual(next as NSDictionary) { return }
    raw = next
    /* Another tree, as when another object or material is chosen, is framed as the first was:
     * where the last one was viewed from it may be out of sight. */
    let tree = { (snapshot: JSON?) in
      [snapshot?.string("name"), snapshot?.string("owner"), snapshot?.string("empty")].map { $0 ?? "" }
    }
    let another = snapshot == nil || tree(snapshot) != tree(next)
    snapshot = Self.resolvingSharedMenus(next)
    if another { fitRequest += 1 }
  }

  /** Menus several nodes share come once, by reference: each field gets its own copy back. */
  private static func resolvingSharedMenus(_ snapshot: JSON) -> JSON {
    guard let sets = snapshot.dict("option_sets"), !sets.isEmpty else { return snapshot }
    var resolved = snapshot
    resolved["nodes"] = snapshot.array("nodes").map { node -> JSON in
      var node = node
      node["fields"] = node.array("fields").map { field -> JSON in
        guard let ref = field.string("options_ref"), let options = sets[ref] else { return field }
        var field = field
        field["options"] = options
        return field
      }
      return node
    }
    return resolved
  }

  /** A hardware key, run as Blender's node editor keymap has it. */
  func sendKey(_ key: String, shift: Bool, ctrl: Bool, alt: Bool, oskey: Bool) {
    send("key", ["key": key, "shift": shift ? 1 : 0, "ctrl": ctrl ? 1 : 0, "alt": alt ? 1 : 0,
                 "oskey": oskey ? 1 : 0])
  }

  func send(_ action: String, _ extra: JSON = [:]) {
    var request: JSON = ["action": action]
    request.merge(extra) { $1 }
    store.send(request)
  }

  func requestFit() { fitRequest += 1 }

  func createTree() {
    Engine.setting("native_nodes_create", kind.rawValue)
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Layout
 *
 * Where each socket and node is on the canvas, as they lay out, for the wires and for dropping a
 * wire on a socket.
 * \{ */

@MainActor
@Observable
final class NodeCanvasLayout {
  var sockets: [String: CGPoint] = [:]
  var nodes: [String: CGRect] = [:]

  static func socketKey(_ node: String, output: Bool, _ socket: String) -> String {
    "\(node)\u{1}\(output ? "o" : "i")\u{1}\(socket)"
  }

  func set(socket key: String, _ point: CGPoint) {
    if sockets[key] != point { sockets[key] = point }
  }

  func set(node name: String, _ frame: CGRect) {
    if nodes[name] != frame { nodes[name] = frame }
  }

  /** Nodes no longer in the tree, and their sockets. */
  func forget(_ names: Set<String>) {
    for name in names { nodes[name] = nil }
    sockets = sockets.filter { key, _ in
      !names.contains(String(key.prefix { $0 != "\u{1}" }))
    }
  }
}

/** Canvas points per unit of Blender's node space. */
private let nodeScale: CGFloat = 1.6

private func nodeColor(_ node: JSON) -> Color {
  if let color = node["color"] as? [NSNumber], color.count >= 3 {
    return Color(red: color[0].doubleValue, green: color[1].doubleValue, blue: color[2].doubleValue)
  }
  switch node.string("class") ?? "" {
    case "INPUT", "OUTPUT", "INTERFACE": return Color(red: 0.78, green: 0.24, blue: 0.3)
    case "SHADER": return Color(red: 0.16, green: 0.6, blue: 0.36)
    case "TEXTURE", "PATTERN": return Color(red: 0.88, green: 0.46, blue: 0.2)
    case "COLOR": return Color(red: 0.72, green: 0.62, blue: 0.22)
    case "VECTOR": return Color(red: 0.42, green: 0.36, blue: 0.82)
    case "CONVERTER": return Color(red: 0.2, green: 0.55, blue: 0.88)
    case "GEOMETRY": return Color(red: 0.0, green: 0.62, blue: 0.54)
    case "ATTRIBUTE": return Color(red: 0.26, green: 0.32, blue: 0.72)
    case "GROUP": return Color(red: 0.3, green: 0.5, blue: 0.12)
    case "FILTER": return Color(red: 0.5, green: 0.34, blue: 0.62)
    case "MATTE": return Color(red: 0.6, green: 0.42, blue: 0.42)
    case "DISTORT": return Color(red: 0.28, green: 0.58, blue: 0.6)
    default: return Color(white: 0.45)
  }
}

private func socketColor(_ socket: JSON) -> Color {
  let c = (socket["color"] as? [NSNumber])?.map(\.doubleValue) ?? [0.6, 0.6, 0.6, 1]
  return Color(red: c[0], green: c[1], blue: c[2])
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Editor
 * \{ */

/** The node editor over the bottom of the viewport: which tree, its path, and the canvas. */
struct NodeEditorPanel: View {
  let model: NodeEditorModel
  @State private var adding: NodeAddRequest?
  @State private var editingInterface = false

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      ZStack {
        if let snapshot = model.snapshot, snapshot["nodes"] == nil {
          ContentUnavailableView {
            Label(snapshot.string("empty") ?? "No Nodes", systemImage: "point.3.connected.trianglepath.dotted")
          } actions: {
            if let create = snapshot.string("create"), !create.isEmpty {
              Button(create) { model.createTree() }
                .buttonStyle(.borderedProminent)
            }
          }
        }
        else if model.snapshot != nil {
          NodeCanvas(model: model, adding: $adding)
        }
        else {
          ProgressView()
        }
        NodeTypingField()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      /* Square: the panel's own corners are rounded, not the canvas's inside it. */
      .containerShape(Rectangle())
    }
    .background(NodeKeyCapture(model: model))
    .onChange(of: model.addRequested) { _, _ in
      adding = NodeAddRequest(location: NodeCanvas.lastCenter, connect: nil)
    }
    .sheet(isPresented: $editingInterface) {
      NodeInterfaceSheet(model: model)
        .presentationDetents([.medium, .large])
    }
    .sheet(item: $adding) { request in
      NodeAddSheet(items: model.addItems) { item in
        var extra: JSON = ["idname": item.string("idname") ?? "",
                           "x": Double(request.location.x), "y": Double(request.location.y)]
        if let group = item.string("group") { extra["group"] = group }
        if let connect = request.connect { extra["connect"] = connect }
        model.send("add", extra)
        adding = nil
      }
      .presentationDetents([.medium, .large])
    }
  }

  private var toolbar: some View {
    HStack(spacing: 12) {
      Text(model.kind.title)
        .font(.headline)
      breadcrumbs
      Spacer(minLength: 0)
      Menu {
        Button("Select All", systemImage: "checkmark.circle") { model.send("select_all", ["value": 1]) }
        Button("Deselect All", systemImage: "circle") { model.send("select_all", ["value": 0]) }
        Divider()
        Button("Show All", systemImage: "arrow.up.left.and.arrow.down.right") { model.requestFit() }
        Section {
          if model.snapshot?.bool("can_backdrop") == true {
            Toggle(isOn: Binding(get: { model.backdrop }, set: { model.backdrop = $0 })) {
              Label("Backdrop", systemImage: "photo")
            }
          }
          if model.kind != .shader {
            Toggle(isOn: Binding(get: { model.timings }, set: { model.timings = $0 })) {
              Label("Timings", systemImage: "timer")
            }
          }
          if model.snapshot?["interface"] != nil {
            Button("Group Inputs & Outputs…", systemImage: "list.bullet.indent") { editingInterface = true }
          }
        }
        Divider()
        let anySelected = model.nodes.contains { $0.bool("selected") }
        Button("Duplicate Selected", systemImage: "plus.square.on.square") {
          model.send("operator", ["operator": "NODE_OT_duplicate"])
        }
        .disabled(!anySelected)
        Button("Group Selected", systemImage: "square.on.square.dashed") {
          model.send("operator", ["operator": "NODE_OT_group_make"])
        }
        .disabled(!anySelected)
        Button("Frame Selected", systemImage: "rectangle.dashed") {
          model.send("operator", ["operator": "NODE_OT_join"])
        }
        .disabled(!anySelected)
        Divider()
        Button("Delete Selected", systemImage: "trash", role: .destructive) {
          model.send("delete", ["nodes": model.nodes.filter { $0.bool("selected") }.compactMap { $0.string("name") }])
        }
        .disabled(!model.nodes.contains { $0.bool("selected") })
      } label: {
        Label("More", systemImage: "ellipsis")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.bordered)
      .buttonBorderShape(.circle)
      .disabled(model.snapshot?["nodes"] == nil)
      Button {
        adding = NodeAddRequest(location: NodeCanvas.lastCenter, connect: nil)
      } label: {
        Label("Add Node", systemImage: "plus")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.bordered)
      .buttonBorderShape(.circle)
      .disabled(model.snapshot?["nodes"] == nil)
      Button {
        model.setShown(false)
      } label: {
        Label("Close", systemImage: "xmark")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.bordered)
      .buttonBorderShape(.circle)
    }
    .padding(.horizontal, 14)
    .frame(height: 52)
  }

  /** The tree's owner, then each group entered, to back out to. */
  private var breadcrumbs: some View {
    let path = model.snapshot?.array("path") ?? []
    return ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 4) {
        /* The tree's data-block, chosen as in Properties, while no group is entered. */
        if path.isEmpty, let header = model.snapshot?.array("header_ids").first {
          DataPicker(store: model.store, property: header, compact: true)
        }
        else {
          Button(model.snapshot?.string("owner") ?? model.snapshot?.string("name") ?? "") { model.exit(to: 0) }
            .buttonStyle(.plain)
            .foregroundStyle(path.isEmpty ? .primary : .secondary)
        }
        ForEach(Array(path.enumerated()), id: \.offset) { index, item in
          Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
          Button(item.string("title") ?? "") { model.exit(to: index + 1) }
            .buttonStyle(.plain)
            .foregroundStyle(index == path.count - 1 ? .primary : .secondary)
        }
      }
      .font(.subheadline.weight(.medium))
      .lineLimit(1)
    }
  }
}

/** Where a new node goes, in node space, and the socket to connect it to. */
struct NodeAddRequest: Identifiable {
  let id = UUID()
  let location: CGPoint
  let connect: JSON?
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Canvas
 * \{ */

/** A wire being pulled out of a socket. */
private struct PendingWire {
  let node: String
  let socket: String
  let output: Bool
  let color: Color
  var end: CGPoint
  /** An input's existing wire, picked up to move it to another input or drop it. */
  var detached: JSON?
  /** The socket the loose end has snapped to, which letting go connects. */
  var target: (node: String, socket: String)?
}

/** The cables' slack: a weight at each cable's middle on a spring. A cable hangs taut until
 * one of its ends moves; then it slackens and dangles, lagging and swaying behind, and once its
 * ends rest it draws tight again, as patch cables do. Kept in canvas points, so panning and
 * zooming leave the cables still. */
final class CableMotion {
  static let pending = "\u{1}pending"

  static func key(_ link: [String: Any]) -> String {
    ["from_node", "from_socket", "to_node", "to_socket"].map { link[$0] as? String ?? "" }.joined(separator: "\u{1}")
  }

  private struct Weight {
    var position: CGPoint
    var velocity: CGVector
    /** How slack the cable hangs, from taut (0) to dangling (1). */
    var slack: CGFloat
    var from: CGPoint
    var to: CGPoint
    /** When an end last moved. */
    var moved: Date
    var seen: Date
  }

  private var weights: [String: Weight] = [:]
  private var last: Date?

  /** Where a cable's middle hangs: between its ends when taut, below them when slack, the more
   * the longer it is. */
  static func rest(from: CGPoint, to: CGPoint, slack: CGFloat) -> CGPoint {
    let length = hypot(to.x - from.x, to.y - from.y)
    return CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 + slack * min(110, 8 + length * 0.14))
  }

  /** Moves every weight on to `date`; true when all hang still. A `held` cable, being pulled,
   * stays slack. */
  func step(to date: Date, ends: [(key: String, from: CGPoint, to: CGPoint, held: Bool)]) -> Bool {
    let elapsed = min(1.0 / 30, max(0, date.timeIntervalSince(last ?? date)))
    last = date
    let calm = UIAccessibility.isReduceMotionEnabled
    var still = true
    for end in ends {
      guard var weight = weights[end.key], !calm else {
        weights[end.key] = Weight(position: Self.rest(from: end.from, to: end.to, slack: 0), velocity: .zero,
                                  slack: 0, from: end.from, to: end.to, moved: .distantPast, seen: date)
        continue
      }
      /* Only one end moving against the other sets it swinging: both moving alike, as panning
       * or a re-layout does, and it hangs as it was. */
      let fromMoved = CGVector(dx: end.from.x - weight.from.x, dy: end.from.y - weight.from.y)
      let toMoved = CGVector(dx: end.to.x - weight.to.x, dy: end.to.y - weight.to.y)
      if end.held || hypot(fromMoved.dx - toMoved.dx, fromMoved.dy - toMoved.dy) > 0.5 {
        weight.moved = date
      }
      else {
        /* Carried along, it keeps its shape. */
        weight.position.x += (fromMoved.dx + toMoved.dx) / 2
        weight.position.y += (fromMoved.dy + toMoved.dy) / 2
      }
      weight.from = end.from
      weight.to = end.to
      /* Slackens quickly as an end moves, and draws tight gently a moment after they rest. */
      let resting = date.timeIntervalSince(weight.moved) > 0.18
      let target: CGFloat = resting ? 0 : 1
      let rate: CGFloat = resting ? 3.2 : 9
      weight.slack += (target - weight.slack) * min(1, rate * elapsed)
      if resting && weight.slack < 0.002 { weight.slack = 0 }
      let rest = Self.rest(from: end.from, to: end.to, slack: weight.slack)
      /* Springy and lightly damped, in small steps so it stays steady. */
      let steps = 4
      let dt = elapsed / Double(steps)
      for _ in 0..<steps {
        let ax = 120 * (rest.x - weight.position.x) - 8 * weight.velocity.dx
        let ay = 120 * (rest.y - weight.position.y) - 8 * weight.velocity.dy
        weight.velocity.dx += ax * dt
        weight.velocity.dy += ay * dt
        weight.position.x += weight.velocity.dx * dt
        weight.position.y += weight.velocity.dy * dt
      }
      weight.seen = date
      if weight.slack > 0 || hypot(weight.velocity.dx, weight.velocity.dy) > 2 ||
         hypot(rest.x - weight.position.x, rest.y - weight.position.y) > 0.5
      {
        still = false
      }
      else {
        weight.position = rest
        weight.velocity = .zero
      }
      weights[end.key] = weight
    }
    /* A cable just connected keeps its sway until Blender's tree has the link. */
    weights = weights.filter { date.timeIntervalSince($0.value.seen) < 1.5 }
    return still
  }

  func slack(_ key: String, from: CGPoint, to: CGPoint) -> CGPoint {
    weights[key]?.position ?? Self.rest(from: from, to: to, slack: 0)
  }

  /** A cable's middle and ends, as the next frame draws it, for finding the cable under a point. */
  func shape(_ key: String) -> (from: CGPoint, slack: CGPoint, to: CGPoint)? {
    weights[key].map { ($0.from, $0.position, $0.to) }
  }

  func kick(_ key: String, by velocity: CGVector) {
    weights[key]?.velocity.dx += velocity.dx
    weights[key]?.velocity.dy += velocity.dy
    weights[key]?.moved = Date()
  }

  /** The loose cable, connected, carries on as the link's own. */
  func adopt(_ key: String, as link: String) {
    if let weight = weights.removeValue(forKey: key) { weights[link] = weight }
  }

  func forget(_ key: String) {
    weights.removeValue(forKey: key)
  }
}

/** Cables let go away from any socket. Each snaps as a stretched cord does: the broken end
 * whips back and the cord reels into the socket it hangs from, swinging under its own weight,
 * while sparks fly from where it broke. A rope of points, in canvas points. */
final class CableSnaps {
  static let duration: TimeInterval = 0.7
  /** How long the reeling cord takes to vanish into its socket. */
  static let reel: TimeInterval = 0.5

  struct Spark {
    var position: CGPoint
    var velocity: CGVector
  }

  struct Snap {
    let color: Color
    let start: Date
    var points: [CGPoint]
    var previous: [CGPoint]
    let segment: CGFloat
    var sparks: [Spark]
  }

  private(set) var snaps: [Snap] = []
  private var last: Date?
  private static let step: CGFloat = 1.0 / 120

  var isEmpty: Bool { snaps.isEmpty }

  /** `curve` runs from the socket the cord hangs from to where it broke. */
  func snap(along curve: [CGPoint], color: Color) {
    guard curve.count > 2 else { return }
    var length: CGFloat = 0
    for i in 1..<curve.count { length += hypot(curve[i].x - curve[i - 1].x, curve[i].y - curve[i - 1].y) }
    /* The stretched cord springs back along itself, hardest at the break. */
    var previous = curve
    for i in 1..<curve.count {
      let t = CGFloat(i) / CGFloat(curve.count - 1)
      let dx = curve[i - 1].x - curve[i].x, dy = curve[i - 1].y - curve[i].y
      let d = max(0.001, hypot(dx, dy))
      let speed = (300 + min(900, length * 1.6)) * t * t * Self.step
      previous[i] = CGPoint(x: curve[i].x - dx / d * speed, y: curve[i].y - dy / d * speed)
    }
    let tip = curve[curve.count - 1]
    let sparks = (0..<14).map { _ -> Spark in
      let angle = CGFloat.random(in: 0..<(2 * .pi))
      let speed = CGFloat.random(in: 140...520)
      return Spark(position: tip, velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed - 160))
    }
    snaps.append(Snap(color: color, start: Date(), points: curve, previous: previous,
                      segment: length / CGFloat(curve.count - 1), sparks: sparks))
  }

  /** Moves every snapping cord on to `date`, dropping those done. */
  func advance(to date: Date) {
    let elapsed = min(1.0 / 20, max(0, date.timeIntervalSince(last ?? date)))
    last = snaps.isEmpty ? nil : date
    snaps.removeAll { date.timeIntervalSince($0.start) > Self.duration }
    let steps = Int((CGFloat(elapsed) / Self.step).rounded(.up))
    for index in snaps.indices {
      var snap = snaps[index]
      let anchor = snap.points[0]
      let t = CGFloat(date.timeIntervalSince(snap.start) / Self.reel)
      /* Reeled in, faster and faster, as a tape measure's blade. */
      let rest = snap.segment * max(0.01, 1 - min(1, t) * min(1, t))
      for _ in 0..<steps {
        for i in 1..<snap.points.count {
          let p = snap.points[i], q = snap.previous[i]
          snap.previous[i] = p
          snap.points[i] = CGPoint(x: p.x + (p.x - q.x) * 0.985,
                                   y: p.y + (p.y - q.y) * 0.985 + 900 * Self.step * Self.step)
        }
        for _ in 0..<6 {
          snap.points[0] = anchor
          for i in 1..<snap.points.count {
            let a = snap.points[i - 1], b = snap.points[i]
            let dx = b.x - a.x, dy = b.y - a.y
            let d = max(0.001, hypot(dx, dy))
            let push = (d - rest) / d
            if i == 1 {
              snap.points[i] = CGPoint(x: b.x - dx * push, y: b.y - dy * push)
            }
            else {
              snap.points[i - 1] = CGPoint(x: a.x + dx * push * 0.5, y: a.y + dy * push * 0.5)
              snap.points[i] = CGPoint(x: b.x - dx * push * 0.5, y: b.y - dy * push * 0.5)
            }
          }
        }
      }
      for i in snap.sparks.indices {
        snap.sparks[i].velocity.dy += 1100 * CGFloat(elapsed)
        snap.sparks[i].velocity.dx *= 0.97
        snap.sparks[i].position.x += snap.sparks[i].velocity.dx * CGFloat(elapsed)
        snap.sparks[i].position.y += snap.sparks[i].velocity.dy * CGFloat(elapsed)
      }
      snaps[index] = snap
    }
  }
}

/** A socket just plugged into. */
private struct CablePlug: Identifiable {
  static let duration = 0.45
  /** How long light takes to run along a cable just connected. */
  static let flash = 0.5
  let id = UUID()
  let point: CGPoint
  let color: Color
  let start: Date
}

/** Clicks as a cable snaps to a socket and plugs in. An iPad gives them through the Pencil and
 * a trackpad that can, a phone through its own haptics. */
@MainActor enum CableFeedback {
  private static var canvasFeedback: UICanvasFeedbackGenerator? = {
    guard let view = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
    else { return nil }
    return UICanvasFeedbackGenerator(view: view)
  }()

  /** Readies the haptics as a cable is picked up, so the first click isn't late. */
  static func prepare() {
    _ = canvasFeedback
    impact.prepare()
    selection.prepare()
  }

  private static let impact = UIImpactFeedbackGenerator(style: .rigid)
  private static let soft = UIImpactFeedbackGenerator(style: .soft)
  private static let selection = UISelectionFeedbackGenerator()

  static func snapped(at point: CGPoint) {
    canvasFeedback?.alignmentOccurred(at: point)
    selection.selectionChanged()
    selection.prepare()
  }

  /** A cable snapping: a sharp crack, then the cord's whip. */
  static func broke(at point: CGPoint) {
    impact.impactOccurred(intensity: 1)
    soft.prepare()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      soft.impactOccurred(intensity: 0.5)
    }
  }

  /** The snapped cord reeled into its socket. */
  static func reeled(at point: CGPoint) {
    canvasFeedback?.alignmentOccurred(at: point)
    soft.impactOccurred(intensity: 0.7)
  }

  static func connected(at point: CGPoint) {
    canvasFeedback?.pathCompleted(at: point)
    impact.impactOccurred()
    soft.prepare()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
      soft.impactOccurred(intensity: 0.6)
    }
  }
}

struct NodeCanvas: View {
  let model: NodeEditorModel
  @Binding var adding: NodeAddRequest?
  @State private var layout = NodeCanvasLayout()
  @State private var zoom: CGFloat = 0.7
  @State private var pan: CGSize = .zero
  /** The zoom and pan a pinch started from. */
  @State private var gestureZoom: (zoom: CGFloat, pan: CGSize)?
  /** True while a pinch or a pan goes on: the system resets it however the gesture ends, also
   * when cancelled, which `onEnded` misses. */
  @GestureState private var pinching = false
  @GestureState private var panning = false
  /** The pan a drag started from, and how far it had gone then, so a drag can pick up again
   * after a pinch without jumping. */
  @State private var panStart: (pan: CGSize, translation: CGSize)?
  @State private var viewSize: CGSize = .zero
  /** Nodes being dragged, and how far, in canvas points. */
  @State private var drag: (nodes: Set<String>, offset: CGSize)?
  /** Moves sent, shown until Blender's snapshot has them. */
  @State private var moved: [String: CGSize] = [:]
  @State private var wire: PendingWire?
  @State private var renaming: (node: String, label: String)?
  /** The node whose color is being chosen. */
  @State private var coloring: JSON?
  /** The selection box being drawn, in view points. */
  @State private var box: CGRect?
  /** The cables' slack, swaying as their ends move. */
  @State private var cables = CableMotion()
  /** Cables just let go, snapping back into their sockets. */
  @State private var snaps = CableSnaps()
  /** Links just taken out, not drawn while Blender's tree still has them. */
  @State private var unlinked: [String: Date] = [:]
  /** While one snaps, frames are drawn. */
  @State private var snapping = false
  /** While a cable still sways, frames are drawn. */
  @State private var cablesMoving = false
  /** Nodes already on the canvas, to tell a node just added or removed. */
  @State private var knownNodes: Set<String> = []
  /** The nodes as they were last drawn, for those just deleted to vanish from. */
  @State private var lastNodes: [String: JSON] = [:]
  /** The links as they were then, for those of deleted nodes to break. */
  @State private var lastLinks: [JSON] = []
  /** A frame just made, drawing itself in. */
  @State private var framing: (name: String, start: Date)?
  /** Nodes just deleted, drawn a moment longer as they are sucked away. */
  @State private var vanishing: [NodeVanish] = []
  /** Where a node just landed, in view points, when, and the canvas as it was then, for the
   * ripple it sends out. */
  @State private var ripple: NodeRipple?
  /** The node just plugged into, bouncing. */
  @State private var bounced: String?
  /** Links just made, a flash of light running along them. */
  @State private var flashes: [String: Date] = [:]
  /** Shows a node's actions as the system's edit menu. */
  @State private var menus = NodeMenuPresenter()
  /** A tap on a selected node shows its menu, unless a second tap enters it. */
  @State private var pendingMenu: DispatchWorkItem?
  /** The link the node being dragged would be put in. */
  @State private var insertion: (key: String, link: JSON)?
  /** Rings sent out by sockets just connected. */
  @State private var plugs: [CablePlug] = []
  /** Where the canvas is in the window, for feedback at a point. */
  @State private var canvasFrame: CGRect = .zero

  /** The middle of the view in node space, where the Add button puts nodes. */
  static var lastCenter = CGPoint.zero

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .topLeading) {
        /* As a node lands, the canvas around it ripples; the node itself rests on top. */
        ZStack(alignment: .topLeading) {
        background
        if model.backdrop, let path = model.snapshot?.string("backdrop"), let image = NodeImages.image(path) {
          /* The compositor's Viewer, behind the nodes, as Blender's backdrop. */
          Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: proxy.size.width, height: proxy.size.height)
            .allowsHitTesting(false)
            .accessibilityLabel("Compositor Result")
        }
        wires
        }
        /* Beneath the nodes: their controls are the system's, which an effect over them would
         * not draw. */
        .modifier(NodeRippleEffect(ripple: ripple, rect: ripple.map(landedRect)))
        content
          .scaleEffect(zoom, anchor: .topLeading)
          .offset(pan)
        if !vanishing.isEmpty {
          /* Deleted nodes, sucked away into their middle. */
          TimelineView(.animation) { timeline in
            ZStack(alignment: .topLeading) {
              ForEach(vanishing) { gone in
                /* A void opens where it was and swallows it: the node spins and shrinks into its
                 * dark middle, losing its colour, then the void closes. */
                let t = min(1, timeline.date.timeIntervalSince(gone.start) / NodeVanish.duration)
                let pull = t * t * (3 - 2 * t)
                let size = gone.size
                let hole = min(max(size.width, size.height) * 0.75, 260) * sin(.pi * min(1, t * 1.15))
                Circle()
                  .fill(RadialGradient(colors: [.black.opacity(0.85), .black.opacity(0.45), .clear],
                                       center: .center, startRadius: 0, endRadius: max(hole / 2, 1)))
                  .frame(width: max(hole, 1), height: max(hole, 1))
                  .blur(radius: 6)
                  .position(gone.center)
                /* In a box of its own where it was, turning and shrinking about its middle, so it
                 * goes where it stood. */
                nodeView(gone.node, native: false, placed: false)
                  .offset(x: size.width / 2 - gone.center.x, y: size.height / 2 - gone.center.y)
                  .frame(width: size.width, height: size.height, alignment: .topLeading)
                  .saturation(1 - t)
                  .brightness(-0.35 * pull)
                  .blur(radius: 6 * pull)
                  .rotationEffect(.degrees(140 * pull))
                  .scaleEffect(max(0.001, 1 - pull))
                  .opacity(1 - pow(t, 2.2))
                  .position(gone.center)
              }
            }
            .frame(width: 1, height: 1, alignment: .topLeading)
            .coordinateSpace(.named("nodes"))
            .allowsHitTesting(false)
          }
          .frame(width: 1, height: 1, alignment: .topLeading)
          .scaleEffect(zoom, anchor: .topLeading)
          .offset(pan)
        }
        plugRings
        snapLayer
        minimap
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
          .padding(14)

      }
      .background { NodeMenuAnchor(presenter: menus) }
      .clipped()
      .simultaneousGesture(magnify)
      .modifier(scrolling)
      .onAppear {
        viewSize = proxy.size
        canvasFrame = proxy.frame(in: .global)
        fit()
      }
      .onChange(of: proxy.frame(in: .global)) { _, frame in canvasFrame = frame }
      .onChange(of: proxy.size) { _, size in viewSize = size }
      .onChange(of: model.fitRequest) { _, _ in
        DispatchQueue.main.async { fit() }
      }
      .onChange(of: positions) { _, _ in moved.removeAll() }
      .onChange(of: model.nodes.map(\.nodeName), initial: true) { _, names in landed(Set(names)) }
      .onChange(of: model.links.map(CableMotion.key)) { _, _ in
        /* Linked and unlinked with the same nodes: the links to break, should one go. */
        if Set(model.nodes.map(\.nodeName)) == knownNodes { lastLinks = model.links }
      }
      .onChange(of: pan) { _, _ in
        rememberCenter()
        /* A value being typed is done once the canvas moves from under it. */
        NodeTyping.shared.commit()
      }
      .onChange(of: pinching) { _, active in if !active { gestureZoom = nil } }
      .onChange(of: panning) { _, active in if !active { panStart = nil } }
      .onChange(of: zoom) { _, _ in
        rememberCenter()
        NodeTyping.shared.commit()
      }
    }
    .sheet(isPresented: Binding(get: { coloring != nil }, set: { if !$0 { coloring = nil } })) {
      if let node = coloring {
        NodeColorSheet(model: model, node: node)
          .presentationDetents([.height(220)])
      }
    }
    .alert("Rename Node", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
      TextField("Label", text: Binding(get: { renaming?.label ?? "" }, set: { renaming?.label = $0 }))
      Button("Rename") {
        if let renaming { model.send("rename", ["node": renaming.node, "value": renaming.label]) }
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  /** Nodes' places, to drop moves Blender has applied. */
  private var positions: [String] {
    model.nodes.map { "\($0.string("name") ?? ""):\($0["x"] ?? 0):\($0["y"] ?? 0)" }
  }

  /** A node's top left corner on the canvas, with any move in progress. */
  private func origin(_ node: JSON) -> CGPoint {
    let name = node.string("name") ?? ""
    var point = CGPoint(x: (node.double("x") ?? 0) * nodeScale, y: -(node.double("y") ?? 0) * nodeScale)
    if let offset = moved[name] {
      point.x += offset.width
      point.y += offset.height
    }
    if let drag, drag.nodes.contains(name) || ancestorDragged(node, drag.nodes) {
      point.x += drag.offset.width
      point.y += drag.offset.height
    }
    return point
  }

  private func ancestorDragged(_ node: JSON, _ dragged: Set<String>) -> Bool {
    var parent = node.string("parent")
    while let name = parent {
      if dragged.contains(name) { return true }
      parent = model.nodes.first { $0.string("name") == name }?.string("parent")
    }
    return false
  }

  private func toView(_ point: CGPoint) -> CGPoint {
    CGPoint(x: point.x * zoom + pan.width, y: point.y * zoom + pan.height)
  }

  private func toCanvas(_ point: CGPoint) -> CGPoint {
    CGPoint(x: (point.x - pan.width) / zoom, y: (point.y - pan.height) / zoom)
  }

  private func rememberCenter() {
    let center = toCanvas(CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
    Self.lastCenter = CGPoint(x: center.x / nodeScale - 80, y: -center.y / nodeScale + 60)
  }

  /** Zoomed and placed so the whole tree shows. */
  private func fit() {
    let nodes = model.nodes.filter { $0.string("kind") != "FRAME" }
    guard !nodes.isEmpty, viewSize.width > 0 else { return }
    var bounds = CGRect.null
    for node in nodes {
      let point = origin(node)
      let size = layout.nodes[node.string("name") ?? ""]?.size ??
        CGSize(width: cardWidth(node), height: 160)
      bounds = bounds.union(CGRect(origin: point, size: size))
    }
    let margin: CGFloat = 40
    let scale = min((viewSize.width - margin * 2) / max(bounds.width, 1),
                    (viewSize.height - margin * 2) / max(bounds.height, 1))
    /* As far out as pinching goes, so a large tree fits. */
    zoom = min(1.2, max(0.15, scale))
    pan = CGSize(width: viewSize.width / 2 - bounds.midX * zoom,
                 height: viewSize.height / 2 - bounds.midY * zoom)
  }

  /** Where the node a ripple runs from is, in view points, as it lays out. */
  private func landedRect(_ ripple: NodeRipple) -> CGRect {
    guard let node = model.nodes.first(where: { $0.string("name") == ripple.name }) else { return .zero }
    let corner = origin(node)
    let size = layout.nodes[ripple.name]?.size ?? CGSize(width: cardWidth(node), height: 120)
    let a = toView(corner), b = toView(CGPoint(x: corner.x + size.width, y: corner.y + size.height))
    return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
  }

  /** The canvas shown, in canvas points, with a margin so nodes are ready as they pan in. */
  private var visibleArea: CGRect {
    let a = toCanvas(.zero), b = toCanvas(CGPoint(x: viewSize.width, y: viewSize.height))
    return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y).insetBy(dx: -300, dy: -300)
  }

  /** Whether a node is in or near the view; one not yet measured, or being worked on, is kept. */
  private func onScreen(_ node: JSON, _ visible: CGRect) -> Bool {
    guard viewSize.width > 0, let name = node.string("name") else { return true }
    if node.bool("selected") || drag?.nodes.contains(name) == true { return true }
    let corner = origin(node)
    let size = layout.nodes[name]?.size ?? CGSize(width: cardWidth(node), height: 200)
    return visible.intersects(CGRect(origin: corner, size: size))
  }

  /** A node seen from far: its color, title and outline at the size it lays out at. */
  private func overviewCard(_ node: JSON) -> some View {
    let name = node.string("name") ?? ""
    let point = origin(node)
    let size = layout.nodes[name]?.size ?? CGSize(width: cardWidth(node), height: 120)
    let card = RoundedRectangle(cornerRadius: 14, style: .continuous)
    /* Colored as the node close up is, see #NodeCard. */
    return card.fill(NodeCard.background)
      .overlay(alignment: .top) {
        nodeColor(node).opacity(0.92).frame(height: 40)
          .overlay(Text(node.string("title") ?? "").font(.title3.weight(.semibold)).foregroundStyle(.white)
            .lineLimit(1).padding(.horizontal, 12), alignment: .leading)
      }
      .clipShape(card)
      .overlay(card.strokeBorder(node.bool("active") ? Color.accentColor :
                                   node.bool("selected") ? Color.accentColor.opacity(0.6) : .black.opacity(0.15),
                                 lineWidth: node.bool("selected") ? 4 : 1))
      .opacity(node.bool("muted") ? 0.55 : 1)
      .frame(width: size.width, height: size.height)
      .offset(x: point.x, y: point.y)
      .onTapGesture { model.send("select", ["node": name]) }
      .gesture(moveGesture(name))
  }

  private func cardWidth(_ node: JSON) -> CGFloat {
    max(200, CGFloat(node.double("width") ?? 140) * nodeScale)
  }

  /* -------------------------------------------------------------------- */
  /* Minimap */

  /** The whole tree small in a corner, with the part in view outlined: tap or drag to go there. */
  @ViewBuilder
  private var minimap: some View {
    let rects = model.nodes.compactMap { node -> (CGRect, Color)? in
      guard let rect = layout.nodes[node.string("name") ?? ""] else { return nil }
      return (rect, node.string("kind") == "FRAME" ? Color.secondary.opacity(0.3) : nodeColor(node))
    }
    let visible = CGRect(origin: toCanvas(.zero), size: CGSize(width: viewSize.width / zoom, height: viewSize.height / zoom))
    if rects.count > 1 || !(rects.first.map { visible.contains($0.0) } ?? true) {
      /* Scaled to the tree alone, so it holds still while the view moves over it. */
      let bounds = rects.map(\.0).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -60, dy: -60)
      let size = CGSize(width: 180, height: max(60, min(140, 180 * bounds.height / max(bounds.width, 1))))
      let scale = min(size.width / bounds.width, size.height / bounds.height)
      let place = { (rect: CGRect) in
        CGRect(x: (rect.minX - bounds.minX) * scale, y: (rect.minY - bounds.minY) * scale,
               width: rect.width * scale, height: rect.height * scale)
      }
      Canvas { context, _ in
        for (rect, color) in rects {
          context.fill(Path(roundedRect: place(rect), cornerRadius: 2), with: .color(color.opacity(0.8)))
        }
        context.fill(Path(roundedRect: place(visible), cornerRadius: 3), with: .color(.accentColor.opacity(0.08)))
        context.stroke(Path(roundedRect: place(visible), cornerRadius: 3), with: .color(.accentColor), lineWidth: 1.5)
      }
      .frame(width: size.width, height: size.height)
      .clipped()
      .padding(6)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
      .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            /* The point under the finger, centred in view. */
            let point = CGPoint(x: (value.location.x - 6) / scale + bounds.minX,
                                y: (value.location.y - 6) / scale + bounds.minY)
            pan = CGSize(width: viewSize.width / 2 - point.x * zoom, height: viewSize.height / 2 - point.y * zoom)
          })
      .accessibilityLabel("Minimap")
      .accessibilityHint("Drag to move around the node tree.")
    }
  }

  /* -------------------------------------------------------------------- */
  /* Background, panning and zooming */

  private var background: some View {
    Canvas { context, size in
      /* A dot grid, as Blender's node editor has. */
      let spacing = 40 * zoom
      guard spacing > 6 else { return }
      let start = CGPoint(x: pan.width.truncatingRemainder(dividingBy: spacing),
                          y: pan.height.truncatingRemainder(dividingBy: spacing))
      var dots = Path()
      var x = start.x
      while x < size.width {
        var y = start.y
        while y < size.height {
          dots.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
          y += spacing
        }
        x += spacing
      }
      context.fill(dots, with: .color(.secondary.opacity(0.35)))
    }
    .background(Color(uiColor: .secondarySystemBackground))
    .contentShape(Rectangle())
#if os(visionOS)
    .gesture(
      DragGesture(minimumDistance: 4)
        .updating($panning) { _, state, _ in state = true }
        .onChanged { value in panBy(value.translation) })
#else
    /* As canvas apps go: a finger pans, or draws a selection box once held still; a pointer or
     * the Pencil draws the box right away. */
    .gesture(NodeCanvasDrag(kind: .finger) { state, start, location in
      if state == .ended || state == .cancelled || state == .failed {
        panStart = nil
      }
      else {
        panBy(CGSize(width: location.x - start.x, height: location.y - start.y))
      }
    })
    .gesture(NodeCanvasDrag(kind: .hold) { state, start, location in selectBox(state, start, location) })
    .gesture(NodeCanvasDrag(kind: .pointer) { state, start, location in selectBox(state, start, location) })
#endif
    .overlay(alignment: .topLeading) {
      if let box {
        Rectangle()
          .fill(Color.accentColor.opacity(0.12))
          .overlay(Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [5, 3])))
          .frame(width: box.width, height: box.height)
          .offset(x: box.minX, y: box.minY)
          .allowsHitTesting(false)
      }
    }
    .onTapGesture { model.send("select", ["node": ""]) }
    .accessibilityLabel("Node Canvas")
  }

  /** A trackpad's or mouse wheel's scrolling pans, over the nodes too. */
  private var scrolling: NodeCanvasScrolling {
    NodeCanvasScrolling { state, translation in
      if state == .ended || state == .cancelled || state == .failed {
        panStart = nil
      }
      else {
        panBy(translation)
      }
    }
  }

  private func panBy(_ translation: CGSize) {
    /* A pinch moves the view itself; a finger left down pans on from where it ends. */
    guard gestureZoom == nil else {
      panStart = nil
      return
    }
    let start = panStart ?? (pan, translation)
    panStart = start
    pan = CGSize(width: start.pan.width + translation.width - start.translation.width,
                 height: start.pan.height + translation.height - start.translation.height)
  }

  /** The nodes the box touches are added to the selection when it is let go. */
  private func selectBox(_ state: UIGestureRecognizer.State, _ start: CGPoint, _ location: CGPoint) {
    switch state {
      case .began, .changed:
        box = CGRect(x: min(start.x, location.x), y: min(start.y, location.y),
                     width: abs(location.x - start.x), height: abs(location.y - start.y))
      case .ended:
        guard let rect = box else { return }
        box = nil
        let a = toCanvas(rect.origin)
        let b = toCanvas(CGPoint(x: rect.maxX, y: rect.maxY))
        let area = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        let names = model.nodes.compactMap { node -> String? in
          guard let name = node.string("name"), node.string("kind") != "FRAME",
                let frame = layout.nodes[name], frame.intersects(area) else { return nil }
          return name
        }
        model.send("select_nodes", ["nodes": names])
      default:
        box = nil
    }
  }

  private var magnify: some Gesture {
    MagnifyGesture()
      .updating($pinching) { _, state, _ in state = true }
      .onChanged { value in
        let start = gestureZoom ?? (zoom, pan)
        gestureZoom = start
        let next = min(2.5, max(0.15, start.zoom * value.magnification))
        let anchor = value.startLocation
        pan = CGSize(width: anchor.x - (anchor.x - start.pan.width) * next / start.zoom,
                     height: anchor.y - (anchor.y - start.pan.height) * next / start.zoom)
        zoom = next
      }
  }

  /* -------------------------------------------------------------------- */
  /* Wires */

  private var wires: some View {
    TimelineView(.animation(paused: !cablesMoving)) { timeline in
      Canvas { context, _ in drawCables(&context, at: timeline.date) }
    }
    .allowsHitTesting(false)
  }

  /** The cables, each hanging and swaying from where its ends are now. */
  private func drawCables(_ context: inout GraphicsContext, at date: Date) {
    let outputs = Dictionary(model.nodes.flatMap { node in
      node.array("outputs").map { (NodeCanvasLayout.socketKey(node.string("name") ?? "", output: true, $0.string("id") ?? ""), socketColor($0)) }
    }, uniquingKeysWith: { a, _ in a })
    var cablesNow: [(key: String, from: CGPoint, to: CGPoint, color: Color, muted: Bool)] = []
    var heldKey: String?
    for link in model.links {
      if let detached = wire?.detached, jsonEqual(detached as NSDictionary, link as NSDictionary) { continue }
      if let gone = unlinked[CableMotion.key(link)], date.timeIntervalSince(gone) < 1.5 { continue }
      let fromKey = NodeCanvasLayout.socketKey(link.string("from_node") ?? "", output: true, link.string("from_socket") ?? "")
      let toKey = NodeCanvasLayout.socketKey(link.string("to_node") ?? "", output: false, link.string("to_socket") ?? "")
      guard let from = layout.sockets[fromKey], let to = layout.sockets[toKey] else { continue }
      cablesNow.append((CableMotion.key(link), from, to,
                        link.bool("valid") ? (outputs[fromKey] ?? .gray) : .red, link.bool("muted")))
    }
    if let wire {
      let key = NodeCanvasLayout.socketKey(wire.node, output: wire.output, wire.socket)
      if let start = layout.sockets[key] {
        let a = start, b = wire.end
        cablesNow.append((CableMotion.pending, wire.output ? a : b, wire.output ? b : a, wire.color, false))
        heldKey = CableMotion.pending
      }
    }
    var still = cables.step(to: date, ends: cablesNow.map { ($0.key, $0.from, $0.to, $0.key == heldKey) })
    for cable in cablesNow {
      let slack = cables.slack(cable.key, from: cable.from, to: cable.to)
      draw(&context, from: cable.from, to: cable.to, slack: slack, color: cable.color, muted: cable.muted,
           lit: cable.key == insertion?.key)
      /* Light running from the source to the socket just plugged into. */
      if let start = flashes[cable.key] {
        let t = date.timeIntervalSince(start) / CablePlug.flash
        if t < 1 {
          still = false
          let controls = Self.controls(from: cable.from, to: cable.to, slack: slack)
          var path = Path()
          path.move(to: toView(cable.from))
          path.addCurve(to: toView(cable.to), control1: toView(controls.0), control2: toView(controls.1))
          let head = min(1, t * 1.3), tail = max(0, head - 0.35)
          let glow = path.trimmedPath(from: tail, to: head)
          let width = max(1.5, 3 * zoom)
          context.stroke(glow, with: .color(cable.color.opacity(0.45 * (1 - t))),
                         style: StrokeStyle(lineWidth: width + 9, lineCap: .round))
          context.stroke(glow, with: .color(.white.opacity(0.95 * (1 - t * t))),
                         style: StrokeStyle(lineWidth: width + 1, lineCap: .round))
        }
      }
    }
    /* Frames stop once every cable hangs still, and start again when one is moved. */
    if still == cablesMoving {
      DispatchQueue.main.async { cablesMoving = !still }
    }
  }

  /** A cable from one socket to another in canvas points, leaving and entering its sockets
   * sideways and passing through its slack. */
  private func draw(_ context: inout GraphicsContext, from: CGPoint, to: CGPoint, slack: CGPoint, color: Color,
                    muted: Bool, lit: Bool = false)
  {
    let controls = Self.controls(from: from, to: to, slack: slack)
    var path = Path()
    path.move(to: toView(from))
    path.addCurve(to: toView(to), control1: toView(controls.0), control2: toView(controls.1))
    let style = StrokeStyle(lineWidth: max(1.5, 3 * zoom), lineCap: .round, dash: muted ? [6, 6] : [])
    if lit {
      /* The link a dragged node would be put in. */
      context.stroke(path, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: style.lineWidth + 7, lineCap: .round))
    }
    context.stroke(path, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: style.lineWidth + 2, lineCap: .round))
    context.stroke(path, with: .color(color), style: lit ? StrokeStyle(lineWidth: style.lineWidth + 1.5, lineCap: .round) : style)
  }

  /** A cable's curve, leaving and entering its sockets sideways and passing through its slack. */
  private static func controls(from: CGPoint, to: CGPoint, slack: CGPoint) -> (CGPoint, CGPoint) {
    let reach = max(40, abs(to.x - from.x) * 0.5)
    let middle = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
    /* A cubic passes its middle at three quarters of its control points' shift. */
    let shift = CGPoint(x: (slack.x - middle.x) / 0.75, y: (slack.y - middle.y) / 0.75)
    return (CGPoint(x: from.x + reach + shift.x, y: from.y + shift.y),
            CGPoint(x: to.x - reach + shift.x, y: to.y + shift.y))
  }

  /** The link a node dragged alone would be put in: one passing under it, when the node has no
   * links of its own, as Blender's editor offers. */
  private func insertionLink(for name: String, offset: CGSize) -> (key: String, link: JSON)? {
    guard let node = model.nodes.first(where: { $0.string("name") == name }), node.string("kind") != "FRAME",
          !node.array("inputs").isEmpty, !node.array("outputs").isEmpty,
          !model.links.contains(where: { $0.string("from_node") == name || $0.string("to_node") == name }),
          var rect = layout.nodes[name]
    else { return nil }
    if let moved = moved[name] { rect = rect.offsetBy(dx: moved.width, dy: moved.height) }
    rect = rect.offsetBy(dx: offset.width, dy: offset.height)
    let center = CGPoint(x: rect.midX, y: rect.midY)
    var best: (String, JSON, CGFloat)?
    for link in model.links {
      let key = CableMotion.key(link)
      guard let shape = cables.shape(key) else { continue }
      let controls = Self.controls(from: shape.from, to: shape.to, slack: shape.slack)
      for step in 1..<24 {
        let t = CGFloat(step) / 24, u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        let point = CGPoint(x: a * shape.from.x + b * controls.0.x + c * controls.1.x + d * shape.to.x,
                            y: a * shape.from.y + b * controls.0.y + c * controls.1.y + d * shape.to.y)
        guard rect.contains(point) else { continue }
        let distance = hypot(point.x - center.x, point.y - center.y)
        if distance < (best?.2 ?? .infinity) { best = (key, link, distance) }
      }
    }
    return best.map { ($0.0, $0.1) }
  }

  /** A ring going out from each socket just plugged into. */
  private var plugRings: some View {
    TimelineView(.animation(paused: plugs.isEmpty && wire?.target == nil)) { timeline in
      Canvas { context, _ in
        /* The socket the loose cable has found breathes, ready to take it. */
        if let wire, wire.target != nil {
          let center = toView(wire.end)
          let breath = 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 9)
          let radius = (13 + 4 * breath) * max(zoom, 0.5)
          let halo = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
          context.fill(halo, with: .color(wire.color.opacity(0.18 + 0.12 * breath)))
          context.stroke(halo, with: .color(wire.color.opacity(0.9)), lineWidth: 2)
        }
        for plug in plugs {
          let t = timeline.date.timeIntervalSince(plug.start) / CablePlug.duration
          guard t >= 0, t < 1 else { continue }
          let eased = 1 - pow(1 - t, 3)
          let center = toView(plug.point)
          let radius = (6 + 22 * eased) * max(zoom, 0.5)
          let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
          context.stroke(ring, with: .color(plug.color.opacity(1 - t)), lineWidth: 3 * (1 - t) + 1)
          let dot = 5 * (1 + 0.6 * sin(.pi * min(1, t * 2))) * max(zoom, 0.5)
          context.fill(Path(ellipseIn: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2)),
                       with: .color(plug.color.opacity(1 - t)))
        }
      }
    }
    .allowsHitTesting(false)
  }

  /** Cables snapping back into their sockets, and their sparks. */
  private var snapLayer: some View {
    TimelineView(.animation(paused: !snapping)) { timeline in
      Canvas { context, _ in
        let date = timeline.date
        snaps.advance(to: date)
        for snap in snaps.snaps {
          let age = date.timeIntervalSince(snap.start)
          let fade = 1 - max(0, (age - CableSnaps.reel) / (CableSnaps.duration - CableSnaps.reel))
          let points = snap.points.map(toView)
          var path = Path()
          path.move(to: points[0])
          for i in 1..<points.count - 1 {
            let middle = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: middle, control: points[i])
          }
          path.addLine(to: points[points.count - 1])
          let width = max(1.5, 3 * zoom)
          context.stroke(path, with: .color(.black.opacity(0.35 * fade)),
                         style: StrokeStyle(lineWidth: width + 2, lineCap: .round, lineJoin: .round))
          context.stroke(path, with: .color(snap.color.opacity(fade)),
                         style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
          /* The broken end glows white-hot a moment. */
          let heat = max(0, 1 - age / 0.25)
          if heat > 0, let tip = points.last {
            let r = (4 + 6 * heat) * max(zoom, 0.5)
            context.fill(Path(ellipseIn: CGRect(x: tip.x - r, y: tip.y - r, width: r * 2, height: r * 2)),
                         with: .color(.white.opacity(0.85 * heat)))
          }
          /* Sparks: short streaks along their flight, cooling from white to the cable's color. */
          let life = max(0, 1 - age / 0.45)
          guard life > 0 else { continue }
          for spark in snap.sparks {
            let head = toView(spark.position)
            let tail = toView(CGPoint(x: spark.position.x - spark.velocity.dx * 0.025,
                                      y: spark.position.y - spark.velocity.dy * 0.025))
            var streak = Path()
            streak.move(to: tail)
            streak.addLine(to: head)
            context.stroke(streak, with: .color(snap.color.opacity(0.8 * life)),
                           style: StrokeStyle(lineWidth: 3 * max(zoom, 0.5), lineCap: .round))
            context.stroke(streak, with: .color(.white.opacity(life * life)),
                           style: StrokeStyle(lineWidth: 1.2 * max(zoom, 0.5), lineCap: .round))
          }
        }
        if snaps.isEmpty && snapping {
          DispatchQueue.main.async { snapping = false }
        }
      }
    }
    .allowsHitTesting(false)
  }

  /** The cable let go away from any socket snaps from the socket it hangs from. */
  private func snapCable(_ wire: PendingWire) {
    guard let anchor = layout.sockets[NodeCanvasLayout.socketKey(wire.node, output: wire.output, wire.socket)] else {
      return
    }
    snapCord(from: anchor, broken: wire.end, output: wire.output, color: wire.color, motion: CableMotion.pending)
  }

  /** A cord hanging from \a anchor, an output's socket or an input's, breaks at \a broken and
   * reels into its socket. \a motion is the cable's sway, for its shape as it broke. */
  private func snapCord(from anchor: CGPoint, broken: CGPoint, output: Bool, color: Color, motion: String,
                        felt: Bool = true)
  {
    let from = output ? anchor : broken, to = output ? broken : anchor
    let slack = cables.slack(motion, from: from, to: to)
    let controls = Self.controls(from: from, to: to, slack: slack)
    var curve: [CGPoint] = (0...28).map { step in
      let t = CGFloat(step) / 28, u = 1 - t
      let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
      return CGPoint(x: a * from.x + b * controls.0.x + c * controls.1.x + d * to.x,
                     y: a * from.y + b * controls.0.y + c * controls.1.y + d * to.y)
    }
    if !output { curve.reverse() }
    snaps.snap(along: curve, color: color)
    snapping = true
    if felt { CableFeedback.broke(at: windowPoint(broken)) }
    /* The cord whips into its socket, which takes it with a small ring. */
    DispatchQueue.main.asyncAfter(deadline: .now() + CableSnaps.reel * 0.85) {
      let plug = CablePlug(point: anchor, color: color, start: Date())
      plugs.append(plug)
      DispatchQueue.main.asyncAfter(deadline: .now() + CablePlug.duration) {
        plugs.removeAll { $0.id == plug.id }
      }
      if felt { CableFeedback.reeled(at: windowPoint(anchor)) }
    }
  }

  /** Cables from deleted nodes to those left break at the deleted end, each reeling into the
   * socket it still hangs from. Read before the deleted nodes' sockets are forgotten. */
  private func snapCables(of removed: Set<String>) {
    var felt = true
    for link in lastLinks {
      let fromNode = link.string("from_node") ?? "", toNode = link.string("to_node") ?? ""
      let fromGone = removed.contains(fromNode), toGone = removed.contains(toNode)
      /* Both ends gone, the cable goes with them. */
      guard fromGone != toGone else { continue }
      let fromSocket = link.string("from_socket") ?? "", toSocket = link.string("to_socket") ?? ""
      guard let from = layout.sockets[NodeCanvasLayout.socketKey(fromNode, output: true, fromSocket)],
            let to = layout.sockets[NodeCanvasLayout.socketKey(toNode, output: false, toSocket)]
      else { continue }
      let source = lastNodes[fromNode]?.array("outputs").first { $0.string("id") == fromSocket }
      let color = link.bool("valid") ? source.map(socketColor) ?? .gray : .red
      snapCord(from: fromGone ? to : from, broken: fromGone ? from : to, output: !fromGone, color: color,
               motion: CableMotion.key(link), felt: felt)
      felt = false
    }
  }

  /** The cable just dropped onto a socket: it springs up and settles, the socket sends out a
   * ring, and the Pencil or trackpad gives a click. */
  private func plugged(into point: CGPoint, node: String, color: Color, link: [String: String]) {
    cables.adopt(CableMotion.pending, as: CableMotion.key(link))
    cables.kick(CableMotion.key(link), by: CGVector(dx: 0, dy: -420))
    flashes[CableMotion.key(link)] = Date()
    DispatchQueue.main.asyncAfter(deadline: .now() + CablePlug.flash) {
      flashes = flashes.filter { Date().timeIntervalSince($0.value) < CablePlug.flash }
    }
    bounce(node)
    cablesMoving = true
    let plug = CablePlug(point: point, color: color, start: Date())
    plugs.append(plug)
    DispatchQueue.main.asyncAfter(deadline: .now() + CablePlug.duration) {
      plugs.removeAll { $0.id == plug.id }
    }
    CableFeedback.connected(at: windowPoint(point))
  }

  /** A canvas point in the window, where feedback is given. */
  private func windowPoint(_ point: CGPoint) -> CGPoint {
    let view = toView(point)
    return CGPoint(x: canvasFrame.minX + view.x, y: canvasFrame.minY + view.y)
  }

  /* -------------------------------------------------------------------- */
  /* Nodes */

  private var content: some View {
    ZStack(alignment: .topLeading) {
      ForEach(model.nodes.filter { $0.string("kind") == "FRAME" }, id: \.nodeName) { frame in
        frameView(frame)
      }
      ForEach(Array((model.snapshot?.array("zones") ?? []).enumerated()), id: \.offset) { _, zone in
        zoneView(zone)
      }
      /* Only the nodes in view are built, so a tree of hundreds of nodes stays quick; zoomed far
       * out, they are drawn as plain cards. */
      let visible = visibleArea
      ForEach(model.nodes.filter { $0.string("kind") != "FRAME" && onScreen($0, visible) },
              id: \.nodeName) { node in
        if zoom < NodeCard.nativeZoom && drag == nil {
          overviewCard(node)
        }
        else {
          /* Wherever values show, they are the system's controls; further out, plain cards keep a
           * large tree quick as it zooms. */
          nodeView(node, native: true, landed: node.nodeName == ripple?.name ? ripple?.start : nil)
        }
      }
    }
    .frame(width: 1, height: 1, alignment: .topLeading)
    .coordinateSpace(.named("nodes"))
  }

  @ViewBuilder
  /** \a placed false for a node already deleted, which leaves no place on the canvas. */
  private func nodeView(_ node: JSON, native: Bool, landed: Date? = nil, placed: Bool = true) -> some View {
    let name = node.string("name") ?? ""
    let point = origin(node)
    Group {
      if node.string("kind") == "REROUTE" {
        rerouteView(node)
      }
      else {
        NodeCard(model: model, layout: layout, node: node, width: cardWidth(node), native: native,
                 wire: wireGesture,
                 move: AnyGesture(moveGesture(name)))
          .equatable()
          .overlay(alignment: .topLeading) {
            if model.timings, let time = node.double("time_ms") {
              /* Above the node, as Blender's Timings overlay. */
              Text(time < 1 ? String(format: "%.2f ms", time) : String(format: "%.1f ms", time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                /* Readable over the compositor's backdrop too. */
                .background(.regularMaterial, in: Capsule())
                .fixedSize()
                .offset(y: -24)
                .allowsHitTesting(false)
            }
          }
          .frame(width: cardWidth(node))
          /* Bobbing on its own waves as it lands: the node itself, so it can be dragged at once. */
          .modifier(NodeBob(start: landed))
          .scaleEffect(bounced == name ? 1.035 : 1)
          /* Selected at once; tapped again, or held, its actions show above it, as objects on a
           * canvas do. */
          .onTapGesture { tapped(node) }
          .simultaneousGesture(TapGesture(count: 2).onEnded {
            pendingMenu?.cancel()
            if node.string("kind") == "GROUP" { model.enter(group: name) }
          })
          .onLongPressGesture(minimumDuration: 0.45) { showMenu(node) }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("nodes")) } action: { frame in
      guard placed else { return }
      /* Recorded without a move in progress, which the wires add themselves. */
      var rest = frame
      if let drag, drag.nodes.contains(name) || ancestorDragged(node, drag.nodes) {
        rest = rest.offsetBy(dx: -drag.offset.width, dy: -drag.offset.height)
      }
      layout.set(node: name, rest)
    }
    .offset(x: point.x, y: point.y)
  }

  private func rerouteView(_ node: JSON) -> some View {
    let name = node.string("name") ?? ""
    let color = node.array("inputs").first.map(socketColor) ?? .gray
    let selected = node.bool("selected")
    let card = RoundedRectangle(cornerRadius: 10, style: .continuous)
    /* A small card of its own, as plain to see as any node, its cables meeting in its middle. */
    return Circle()
      .fill(color)
      .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1.5))
      .frame(width: 14, height: 14)
      .frame(width: 36, height: 26)
      .background(Color(uiColor: .systemBackground), in: card)
      .overlay(card.strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.18), lineWidth: selected ? 2.5 : 1))
      .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
      .frame(width: 44, height: 34)
      .contentShape(Rectangle())
      .onGeometryChange(for: CGPoint.self) { geometry in
        let frame = geometry.frame(in: .named("nodes"))
        return CGPoint(x: frame.midX, y: frame.midY)
      } action: { center in
        /* Where it is drawn, with any move in progress, as a card's sockets record. */
        for socket in node.array("inputs") {
          layout.set(socket: NodeCanvasLayout.socketKey(name, output: false, socket.string("id") ?? ""), center)
        }
        for socket in node.array("outputs") {
          layout.set(socket: NodeCanvasLayout.socketKey(name, output: true, socket.string("id") ?? ""), center)
        }
      }
      .onTapGesture { tapped(node) }
      .onLongPressGesture(minimumDuration: 0.45) { showMenu(node) }
      .gesture(moveGesture(name))
      .offset(x: -22, y: -17)
      .accessibilityLabel("Reroute")
  }

  /** A zone: a tinted region around its input, output and the nodes between, as Blender draws. */
  @ViewBuilder
  private func zoneView(_ zone: JSON) -> some View {
    let names = (zone["nodes"] as? [String]) ?? []
    let rects = names.compactMap { name -> CGRect? in
      guard var rect = layout.nodes[name] else { return nil }
      if let offset = moved[name] { rect = rect.offsetBy(dx: offset.width, dy: offset.height) }
      if let drag, drag.nodes.contains(name) { rect = rect.offsetBy(dx: drag.offset.width, dy: drag.offset.height) }
      return rect
    }
    if let first = rects.first {
      let depth = CGFloat(zone.int("depth") ?? 0)
      let rect = rects.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -18 + depth * 6, dy: -18 + depth * 6)
      let tint = (zone.string("kind") ?? "").contains("Simulation") ? Color.pink :
        (zone.string("kind") ?? "").contains("Repeat") ? Color.purple : Color.teal
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(tint.opacity(0.12))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(tint.opacity(0.4), lineWidth: 1.5))
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
        .allowsHitTesting(false)
    }
  }

  private func frameView(_ frame: JSON) -> some View {
    let name = frame.string("name") ?? ""
    let children = model.nodes.filter { $0.string("parent") == name }
    var rect = CGRect.null
    for child in children {
      if let childRect = layout.nodes[child.string("name") ?? ""] {
        rect = rect.union(childRect.offsetBy(dx: moved[child.string("name") ?? ""]?.width ?? 0,
                                             dy: moved[child.string("name") ?? ""]?.height ?? 0))
      }
    }
    if rect.isNull {
      let point = origin(frame)
      rect = CGRect(x: point.x, y: point.y, width: CGFloat(frame.double("width") ?? 200) * nodeScale,
                    height: CGFloat(frame.double("height") ?? 100) * nodeScale)
    }
    else {
      rect = rect.insetBy(dx: -24, dy: -24)
      rect.origin.y -= 24
      rect.size.height += 24
      if let drag, drag.nodes.contains(name) {
        rect = rect.offsetBy(dx: drag.offset.width, dy: drag.offset.height)
      }
    }
    let tint = frame["color"] != nil ? nodeColor(frame) : Color.secondary
    let drawing = framing?.name == name ? framing?.start : nil
    return TimelineView(.animation(paused: drawing == nil)) { timeline in
      /* A frame just made: its outline traces round from the top, meeting at the bottom, then
       * its tint fills in. */
      let t = drawing.map { min(1, timeline.date.timeIntervalSince($0) / 0.55) } ?? 1
      let trace = 1 - pow(1 - min(1, t / 0.75), 3)
      let fill = max(0, (t - 0.55) / 0.45)
      let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
      shape.fill(tint.opacity(0.18 * (drawing == nil ? 1 : fill)))
        .overlay {
          if drawing == nil {
            shape.strokeBorder(frame.bool("selected") ? Color.accentColor : tint.opacity(0.35), lineWidth: 1.5)
          }
          else {
            ZStack {
              shape.trim(from: 0, to: trace / 2).stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
              shape.trim(from: 1 - trace / 2, to: 1).stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            /* Paths start at the right edge's middle; turned so they start at the top. */
            .rotationEffect(.degrees(-90))
            .opacity(1 - 0.5 * fill)
          }
        }
        .scaleEffect(drawing == nil ? 1 : 1 + 0.03 * (1 - fill))
    }
      .overlay(alignment: .topLeading) {
        Text(frame.string("title") ?? "")
          .font(.headline)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 14)
          .padding(.top, 10)
      }
      .frame(width: rect.width, height: rect.height)
      .contentShape(RoundedRectangle(cornerRadius: 18))
      .onTapGesture { tapped(frame, in: rect) }
      .onLongPressGesture(minimumDuration: 0.45) { showMenu(frame, in: rect) }
      .gesture(moveGesture(name))
      .offset(x: rect.minX, y: rect.minY)
  }

  private func tapped(_ node: JSON, in frame: CGRect? = nil) {
    let name = node.string("name") ?? ""
    guard node.bool("selected") else {
      model.send("select", ["node": name])
      return
    }
    pendingMenu?.cancel()
    let work = DispatchWorkItem { showMenu(node, in: frame) }
    pendingMenu = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
  }

  /** The node's actions as the system's edit menu, above the node. */
  private func showMenu(_ node: JSON, in frame: CGRect? = nil) {
    let name = node.string("name") ?? ""
    guard var rect = frame ?? layout.nodes[name] else { return }
    if frame == nil, let offset = moved[name] { rect = rect.offsetBy(dx: offset.width, dy: offset.height) }
    if !node.bool("selected") { model.send("select", ["node": name]) }
    let a = toView(rect.origin), b = toView(CGPoint(x: rect.maxX, y: rect.maxY))
    menus.present(uiMenu(node), around: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y))
  }

  /** The same actions as `menu`, for the edit menu. */
  private func uiMenu(_ node: JSON) -> UIMenu {
    let name = node.string("name") ?? ""
    let targets = [name]
    let kind = node.string("kind") ?? ""
    func action(_ title: String, _ image: String, destructive: Bool = false, _ run: @escaping () -> Void) -> UIAction {
      UIAction(title: title, image: UIImage(systemName: image), attributes: destructive ? .destructive : []) { _ in run() }
    }
    var first: [UIMenuElement] = []
    if kind == "GROUP" {
      first.append(action("Enter Group", "arrow.down.right.square") { model.enter(group: name) })
    }
    first.append(action("Duplicate", "plus.square.on.square") { runOnSelection(name, "NODE_OT_duplicate") })
    first.append(action("Rename…", "pencil") { renaming = (name, node.string("title") ?? "") })
    first.append(action(node.bool("muted") ? "Unmute" : "Mute", node.bool("muted") ? "speaker.wave.2" : "speaker.slash") {
      model.send("mute", ["nodes": targets])
    })
    if kind == "NODE" || kind == "GROUP" {
      first.append(action(node.bool("collapsed") ? "Expand" : "Collapse",
                          node.bool("collapsed") ? "rectangle.expand.vertical" : "rectangle.compress.vertical") {
        model.send("collapse", ["nodes": targets])
      })
    }
    var more: [UIMenuElement] = []
    if kind != "FRAME" && !node.array("outputs").isEmpty {
      more.append(action("Connect to Viewer", "eye") { model.send("viewer", ["node": name]) })
    }
    if node.bool("can_preview") {
      more.append(action(node.bool("preview_on") ? "Hide Preview" : "Show Preview", "photo") {
        model.send("preview", ["node": name])
      })
    }
    more.append(action("Color…", "paintpalette") { coloring = node })
    if node["color"] != nil {
      more.append(action("Default Color", "paintpalette.fill") { model.send("color", ["node": name]) })
    }
    if kind == "NODE" || kind == "GROUP" {
      more.append(action("Show Hidden Sockets", "circle.dotted") { model.send("sockets_show", ["node": name]) })
    }
    more.append(action("Make Group", "square.on.square.dashed") { runOnSelection(name, "NODE_OT_group_make") })
    if kind == "GROUP" {
      more.append(action("Ungroup", "square.dashed") { runOnSelection(name, "NODE_OT_group_ungroup") })
    }
    more.append(action("Frame Selected", "rectangle.dashed") { runOnSelection(name, "NODE_OT_join") })
    if node.string("parent") != nil {
      more.append(action("Remove from Frame", "rectangle.portrait.and.arrow.right") {
        runOnSelection(name, "NODE_OT_parent_clear")
      })
    }
    return UIMenu(children: first + [UIMenu(title: "More", image: UIImage(systemName: "ellipsis.circle"), children: more),
                                     action("Delete", "trash", destructive: true) { model.send("delete", ["nodes": targets]) }])
  }

  /** A node new to the tree, other than when another tree shows, sends a ripple across the
   * canvas from where it landed. */
  private func landed(_ names: Set<String>) {
    let added = names.subtracting(knownNodes)
    let removed = knownNodes.subtracting(names)
    /* Another tree shown, not every node deleted. */
    let fresh = knownNodes.isEmpty || (!names.isEmpty && knownNodes.isDisjoint(with: names))
    knownNodes = names
    /* Their cables break and reel in; then gone nodes leave no place behind, for wires or
     * touches to find. */
    if !removed.isEmpty {
      if !fresh, !UIAccessibility.isReduceMotionEnabled { snapCables(of: removed) }
      layout.forget(removed)
    }
    if !fresh, !removed.isEmpty, !UIAccessibility.isReduceMotionEnabled {
      let now = Date()
      let gone = removed.prefix(24).compactMap { name -> NodeVanish? in
        guard let node = lastNodes[name], node.string("kind") != "FRAME" else { return nil }
        let corner = origin(node)
        let size = layout.nodes[name]?.size ?? CGSize(width: cardWidth(node), height: 120)
        return NodeVanish(node: node, center: CGPoint(x: corner.x + size.width / 2, y: corner.y + size.height / 2),
                          size: size, start: now)
      }
      if !gone.isEmpty {
        vanishing += gone
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.8)
        DispatchQueue.main.asyncAfter(deadline: .now() + NodeVanish.duration) {
          vanishing.removeAll { Date().timeIntervalSince($0.start) >= NodeVanish.duration }
          /* What drawing them as they went placed again, unless they came back, as undoing does. */
          layout.forget(removed.subtracting(knownNodes))
        }
      }
    }
    lastNodes = Dictionary(model.nodes.map { ($0.nodeName, $0) }, uniquingKeysWith: { a, _ in a })
    lastLinks = model.links
    guard !fresh, let name = added.first, let node = model.nodes.first(where: { $0.string("name") == name })
    else { return }
    /* A new frame draws its outline around what it holds instead. */
    if node.string("kind") == "FRAME" {
      if !UIAccessibility.isReduceMotionEnabled {
        framing = (name, Date())
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { if framing?.name == name { framing = nil } }
      }
      return
    }
    guard !UIAccessibility.isReduceMotionEnabled, NodeRippleEffect.library != nil else { return }
    let landing = NodeRipple(name: name, start: Date())
    ripple = landing
    DispatchQueue.main.asyncAfter(deadline: .now() + NodeRippleEffect.duration) {
      if ripple?.id == landing.id { ripple = nil }
    }
  }

  /** The node bounces, as it takes a cable. */
  private func bounce(_ name: String) {
    withAnimation(.spring(response: 0.16, dampingFraction: 0.5)) { bounced = name }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
      withAnimation(.spring(response: 0.35, dampingFraction: 0.45)) { bounced = nil }
    }
  }

  /** Runs a Blender operator on the node a menu was opened on, alone. */
  private func runOnSelection(_ name: String, _ idname: String) {
    model.send("select", ["node": name])
    model.send("operator", ["operator": idname])
  }

  /** The selected nodes when `name` is among them, else `name` alone. */
  private func selection(including name: String) -> [String] {
    let selected = model.nodes.filter { $0.bool("selected") }.compactMap { $0.string("name") }
    return selected.contains(name) ? selected : [name]
  }

  private func moveGesture(_ name: String) -> some Gesture<DragGesture.Value> {
    DragGesture(minimumDistance: 6, coordinateSpace: .named("nodes"))
      .onChanged { value in
        if drag == nil {
          let nodes = Set(selection(including: name))
          if !model.nodes.contains(where: { $0.string("name") == name && $0.bool("selected") }) {
            model.send("select", ["node": name])
          }
          drag = (nodes, .zero)
        }
        drag?.offset = value.translation
        /* Over a link it could go in, the link lights up, with a tick. */
        let next = drag?.nodes.count == 1 ? insertionLink(for: name, offset: value.translation) : nil
        if next?.key != insertion?.key {
          if let next, let rect = layout.nodes[name] {
            CableFeedback.snapped(at: windowPoint(CGPoint(x: rect.midX + value.translation.width,
                                                          y: rect.midY + value.translation.height)))
            cables.kick(next.key, by: CGVector(dx: 0, dy: 160))
          }
          insertion = next
        }
      }
      .onEnded { value in
        guard let current = drag else { return }
        /* Held where they were let go until Blender's tree has them there, with what a frame
         * holds. */
        for node in model.nodes where current.nodes.contains(node.nodeName) || ancestorDragged(node, current.nodes) {
          moved[node.nodeName] = value.translation
        }
        drag = nil
        var request: JSON = ["nodes": Array(current.nodes),
                             "dx": Double(value.translation.width / nodeScale),
                             "dy": Double(-value.translation.height / nodeScale)]
        if let insertion {
          for field in ["from_node", "from_socket", "to_node", "to_socket"] {
            request["insert_" + field] = insertion.link.string(field) ?? ""
          }
          if let rect = layout.nodes[name] {
            let point = CGPoint(x: rect.midX + value.translation.width, y: rect.midY + value.translation.height)
            cables.forget(insertion.key)
            CableFeedback.connected(at: windowPoint(point))
            bounce(name)
          }
          self.insertion = nil
        }
        model.send("move", request)
      }
  }

  /* -------------------------------------------------------------------- */
  /* Connecting */

  /** Pulling a wire out of a socket: onto another socket connects them; into empty space offers
   * a node to add there, connected to it. */
  private func wireGesture(node: JSON, socket: JSON, output: Bool) -> AnyGesture<DragGesture.Value> {
    let nodeName = node.string("name") ?? ""
    let socketID = socket.string("id") ?? ""
    return AnyGesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("nodes"))
      .onChanged { value in
        if wire == nil {
          CableFeedback.prepare()
          if !output, let existing = model.links.first(where: { $0.string("to_node") == nodeName && $0.string("to_socket") == socketID }) {
            /* An input's wire is picked up from its source, to plug in elsewhere. */
            let source = model.nodes.first { $0.string("name") == existing.string("from_node") }
            let sourceSocket = source?.array("outputs").first { $0.string("id") == existing.string("from_socket") }
            wire = PendingWire(node: existing.string("from_node") ?? "", socket: existing.string("from_socket") ?? "",
                               output: true, color: sourceSocket.map(socketColor) ?? .gray,
                               end: value.location, detached: existing)
          }
          else {
            wire = PendingWire(node: nodeName, socket: socketID, output: output, color: socketColor(socket),
                               end: value.location, detached: nil)
          }
        }
        /* Near a socket the loose end snaps onto it, with a tick. */
        let output = wire?.output ?? output
        let from = wire?.node ?? nodeName
        if let target = nearestSocket(to: value.location, output: !output), target.node != from,
           let place = layout.sockets[NodeCanvasLayout.socketKey(target.node, output: !output, target.socket)]
        {
          if wire?.target?.node != target.node || wire?.target?.socket != target.socket {
            CableFeedback.snapped(at: windowPoint(place))
          }
          wire?.target = target
          wire?.end = place
        }
        else {
          wire?.target = nil
          wire?.end = value.location
        }
      }
      .onEnded { value in
        guard let current = wire else { return }
        wire = nil
        if let target = current.target ?? nearestSocket(to: value.location, output: !current.output),
           target.node != current.node
        {
          if let detached = current.detached {
            unlink(detached)
          }
          let link = current.output ?
            ["from_node": current.node, "from_socket": current.socket, "to_node": target.node, "to_socket": target.socket] :
            ["from_node": target.node, "from_socket": target.socket, "to_node": current.node, "to_socket": current.socket]
          model.send("link", link)
          unlinked[CableMotion.key(link)] = nil
          if let place = layout.sockets[NodeCanvasLayout.socketKey(target.node, output: !current.output, target.socket)] {
            plugged(into: place, node: target.node, color: current.color, link: link)
          }
          return
        }
        if let detached = current.detached {
          /* Dropped away from any socket: disconnected, and the loose cable snaps. */
          snapCable(current)
          cables.forget(CableMotion.pending)
          unlink(detached)
          return
        }
        let location = CGPoint(x: value.location.x / nodeScale, y: -value.location.y / nodeScale)
        adding = NodeAddRequest(location: current.output ? location : CGPoint(x: location.x - 160, y: location.y),
                                connect: ["node": current.node, "socket": current.socket, "output": current.output ? 1 : 0])
      })
  }

  /** Takes a link out, no longer drawn from now on rather than once Blender's tree has lost it. */
  private func unlink(_ link: JSON) {
    unlinked[CableMotion.key(link)] = Date()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
      unlinked = unlinked.filter { Date().timeIntervalSince($0.value) < 1.5 }
    }
    model.send("unlink", ["to_node": link.string("to_node") ?? "", "to_socket": link.string("to_socket") ?? "",
                          "from_node": link.string("from_node") ?? "", "from_socket": link.string("from_socket") ?? ""])
  }

  /** The socket of the other direction nearest a point, within reach of a finger. */
  private func nearestSocket(to point: CGPoint, output: Bool) -> (node: String, socket: String)? {
    let marker = output ? "\u{1}o\u{1}" : "\u{1}i\u{1}"
    var best: (String, CGFloat)?
    for (key, position) in layout.sockets where key.contains(marker) {
      let distance = hypot(position.x - point.x, position.y - point.y)
      if distance < 36 / max(zoom, 0.3), distance < (best?.1 ?? .infinity) {
        best = (key, distance)
      }
    }
    guard let key = best?.0 else { return nil }
    let parts = key.components(separatedBy: "\u{1}")
    guard parts.count == 3 else { return nil }
    return (parts[0], parts[2])
  }
}

private extension Dictionary where Key == String, Value == Any {
  var nodeName: String { string("name") ?? "" }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Node Cards
 * \{ */

/** Equatable by what it shows, so panning and zooming, which rebuild the canvas, leave the cards
 * and their controls alone. Its gestures read the canvas's state as it is when they run. */
struct NodeCard: View, Equatable {
  static func == (a: NodeCard, b: NodeCard) -> Bool {
    a.model === b.model && a.width == b.width && a.native == b.native && jsonDictEqual(a.node, b.node)
  }

  let model: NodeEditorModel
  let layout: NodeCanvasLayout
  let node: JSON
  let width: CGFloat
  /** The system's controls for its values, or stand-ins drawn alike inside an effect, which the
   * system's controls can't be drawn into. */
  let native: Bool
  let wire: (JSON, JSON, Bool) -> AnyGesture<DragGesture.Value>

  /** The zoom from which nodes show their values, in the system's controls; further out they are
   * plain cards. */
  static let nativeZoom: CGFloat = 0.33
  /** Dragging the header moves the node, and the other selected nodes with it. */
  let move: AnyGesture<DragGesture.Value>

  private var name: String { node.string("name") ?? "" }
  private var fields: [JSON] { node.array("fields") }

  /** A node's body: raised from the canvas in either appearance. */
  static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .tertiarySystemBackground : .systemBackground })

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      if let path = node.string("preview"), let image = NodeImages.image(path) {
        /* The node's result, as Blender previews it. */
        Image(uiImage: image)
          .resizable()
          .interpolation(.medium)
          .scaledToFit()
          .frame(maxWidth: .infinity)
          .background(Color.black.opacity(0.05))
          .accessibilityLabel("Preview")
      }
      if !node.bool("collapsed") {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(node.array("outputs"), id: \.socketID) { socket in
            HStack {
              Spacer(minLength: 0)
              Text(socket.string("name") ?? "")
                .font(.callout)
                .lineLimit(1)
            }
            .frame(minHeight: 30)
            .padding(.horizontal, 14)
            .overlay(alignment: .trailing) { dot(socket, output: true).offset(x: 10) }
          }
          let own = fields.filter { $0.string("socket") == nil }
          if !own.isEmpty {
            NodeCanvasFields(store: model.store, fields: own, native: native)
              .padding(.horizontal, 12)
              .padding(.vertical, 4)
          }
          ForEach(Array(inputGroups.enumerated()), id: \.offset) { _, group in
            if let panel = group.panel {
              panelHeader(panel, sockets: group.sockets)
              if !panel.bool("collapsed") {
                ForEach(group.sockets, id: \.socketID) { socket in input(socket) }
              }
            }
            else {
              ForEach(group.sockets, id: \.socketID) { socket in input(socket) }
            }
          }
        }
        .padding(.vertical, 6)
      }
    }
    /* Raised from the canvas in either appearance. */
    /* The outline under the contents, so the socket dots on the edge cover it. */
    .background {
      let card = RoundedRectangle(cornerRadius: 14, style: .continuous)
      card.fill(Self.background)
        .overlay {
          card.strokeBorder(node.bool("active") ? Color.accentColor : node.bool("selected") ? Color.accentColor.opacity(0.6) : Color.black.opacity(0.15),
                            lineWidth: node.bool("selected") ? 2.5 : 1)
        }
    }
    /* Faded as one layer, so the outline doesn't show through the dots. */
    .compositingGroup()
    .opacity(node.bool("muted") ? 0.55 : 1)
    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    .overlay(alignment: .topLeading) {
      if node.bool("collapsed") {
        /* Collapsed, its sockets gather at the header's ends. */
        ZStack {
          ForEach(node.array("inputs"), id: \.socketID) { socket in dot(socket, output: false) }
        }
        .frame(height: 40)
        .offset(x: -10)
      }
    }
    .overlay(alignment: .topTrailing) {
      if node.bool("collapsed") {
        ZStack {
          ForEach(node.array("outputs"), id: \.socketID) { socket in dot(socket, output: true) }
        }
        .frame(height: 40)
        .offset(x: 10)
      }
    }
  }

  private var header: some View {
    HStack(spacing: 6) {
      if node.string("kind") == "GROUP" {
        Image(systemName: "square.on.square")
      }
      Text(node.string("title") ?? "")
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
      Spacer(minLength: 0)
      if node.bool("muted") {
        Image(systemName: "speaker.slash.fill").font(.caption)
      }
      if !node.array("warnings").isEmpty {
        NodeWarningsButton(warnings: node.array("warnings"))
      }
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 12)
    .frame(height: 40)
    .background(nodeColor(node).opacity(0.92), in: UnevenRoundedRectangle(
      topLeadingRadius: 14, bottomLeadingRadius: node.bool("collapsed") ? 14 : 0,
      bottomTrailingRadius: node.bool("collapsed") ? 14 : 0, topTrailingRadius: 14, style: .continuous))
    .contentShape(Rectangle())
    .highPriorityGesture(move)
  }

  /** Inputs in their panels, in order: runs of sockets in the same panel, or in none. */
  private var inputGroups: [(panel: JSON?, sockets: [JSON])] {
    let panels = Dictionary(node.array("panels").compactMap { panel in panel.int("id").map { ($0, panel) } },
                            uniquingKeysWith: { a, _ in a })
    var groups: [(panel: JSON?, sockets: [JSON])] = []
    var current: Int?? = .none
    for socket in node.array("inputs") {
      let id = socket.int("panel")
      if case .some(let last) = current, last == id {
        groups[groups.count - 1].sockets.append(socket)
      }
      else {
        groups.append((id.flatMap { panels[$0] }, [socket]))
        current = .some(id)
      }
    }
    return groups
  }

  /** A panel's header, which opens and closes it; closed, its wired sockets sit on it. */
  private func panelHeader(_ panel: JSON, sockets: [JSON]) -> some View {
    let collapsed = panel.bool("collapsed")
    return Button {
      model.send("panel", ["node": name, "panel": panel.int("id") ?? -1])
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .rotationEffect(.degrees(collapsed ? 0 : 90))
        Text(panel.string("name") ?? "")
          .font(.callout.weight(.medium))
        Spacer(minLength: 0)
      }
      .foregroundStyle(.secondary)
      .frame(minHeight: 32)
      .padding(.horizontal, 12)
      .padding(.leading, panel["parent"] != nil ? 12 : 0)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .overlay(alignment: .leading) {
      if collapsed {
        ZStack {
          ForEach(sockets.filter { $0.bool("linked") }, id: \.socketID) { socket in
            dot(socket, output: false)
          }
        }
        .offset(x: -10)
      }
    }
    .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
  }

  /** An input: its value's controls when nothing links it, else its name. */
  @ViewBuilder
  private func input(_ socket: JSON) -> some View {
    let id = socket.string("id") ?? ""
    let values = socket.bool("linked") ? [] : fields.filter { $0.string("socket") == id }
    Group {
      if values.isEmpty {
        Text(socket.string("name") ?? "")
          .font(.callout)
          .lineLimit(1)
          .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
          .padding(.horizontal, 14)
          .overlay(alignment: .leading) { dot(socket, output: false).offset(x: -10) }
      }
      else {
        NodeCanvasFields(store: model.store, fields: values, native: native)
          .padding(.horizontal, 12)
          .overlay(alignment: .topLeading) { dot(socket, output: false).offset(x: -10, y: 12) }
      }
    }
  }

  /** A socket: a dot on the card's edge, which wires start from and end at. */
  private func dot(_ socket: JSON, output: Bool) -> some View {
    let key = NodeCanvasLayout.socketKey(name, output: output, socket.string("id") ?? "")
    let shape = socket.string("shape") == "DIAMOND"
    return ZStack {
      if shape {
        Rectangle()
          .fill(socketColor(socket))
          .frame(width: 10, height: 10)
          .rotationEffect(.degrees(45))
      }
      else {
        Circle().fill(socketColor(socket)).frame(width: 13, height: 13)
      }
    }
    .overlay {
      if !shape { Circle().strokeBorder(.black.opacity(0.45), lineWidth: 1).frame(width: 13, height: 13) }
    }
    .frame(width: 20, height: 20)
    .contentShape(Circle().inset(by: -8))
    .onGeometryChange(for: CGPoint.self) { geometry in
      let frame = geometry.frame(in: .named("nodes"))
      return CGPoint(x: frame.midX, y: frame.midY)
    } action: { center in
      layout.set(socket: key, center)
    }
    .highPriorityGesture(wire(node, socket, output))
    .contextMenu {
      if !socket.bool("linked") {
        /* As Blender's sidebar hides a socket of a node. */
        Button("Hide Socket", systemImage: "eye.slash") {
          model.send("socket_hide", ["node": name, "socket": socket.string("id") ?? "", "output": output ? 1 : 0])
        }
      }
    }
    .accessibilityLabel((output ? "Output " : "Input ") + (socket.string("name") ?? ""))
  }
}

private extension Dictionary where Key == String, Value == Any {
  var socketID: String { string("id") ?? "" }
}

/** A node's controls, laid out as Properties lays out a panel's. */
/** A node's values, drawn wholly by SwiftUI: light enough for trees of hundreds of nodes, and
 * bent along with the canvas by its effects, which system controls can't be. Numbers scrub
 * sideways and take a typed value from a tap, switches flip, menus list their choices, and
 * anything else opens its Properties control above the node. */
struct NodeCanvasFields: View {
  let store: InspectorStore
  let fields: [JSON]
  var native = true

  var body: some View {
    if native {
      /* The Properties editor's own controls, as Blender's node editor uses its buttons. */
      NodeFieldRows(store: store, fields: fields)
    }
    else {
      standIns
    }
  }

  /** Drawn alike, without the system's controls, for a node inside an effect. */
  private var standIns: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(NodeFieldRows.rows(fields)) { row in
        switch row.kind {
          case .property(let property):
            NodeCanvasField(store: store, property: property)
          case .vector(let title, let items):
            NodeCanvasVector(store: store, title: title, items: items)
          case .toggles(let caption, let items):
            if !caption.isEmpty {
              Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
              NodeCanvasField(store: store, property: item)
            }
          case .composite(let property):
            NodeCanvasField(store: store, property: property)
          case .heading:
            EmptyView()
        }
      }
    }
  }
}

/** One value on a node: its name, and the value drawn as a field would show it. */
struct NodeCanvasField: View, Equatable {
  let store: InspectorStore
  let property: JSON
  @State private var editing = false
  /** Where the color picker points from; kept across redraws, which the picker outlives. */
  @State private var anchor = AnchorBox()

  static func == (a: NodeCanvasField, b: NodeCanvasField) -> Bool {
    a.store === b.store && jsonDictEqual(a.property, b.property)
  }

  private var type: String { property.string("type") ?? "" }
  private var editable: Bool { property.bool("editable") || type == "ID" }

  var body: some View {
    Group {
      switch type {
        case "LABEL":
          Text(propertyLabel(property)).font(.callout).foregroundStyle(.secondary)
        case "BOOLEAN":
          labeled { NodeCanvasSwitch(on: store.value(property) as? Bool ?? (numericValue(store.value(property)) != 0)) }
            .contentShape(Rectangle())
            .onTapGesture {
              guard editable else { return }
              let on = store.value(property) as? Bool ?? (numericValue(store.value(property)) != 0)
              store.edit(property, value: !on)
            }
        case "INT", "FLOAT":
          labeled { NodeCanvasNumber(store: store, property: property) }
        case "STRING":
          labeled { NodeCanvasText(store: store, property: property) }
        case "ENUM":
          labeled { valueText(enumLabel, chevron: true) }
            .contentShape(Rectangle())
            .onTapGesture { if editable { editing = true } }
        case "COLOR":
          labeled {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
              .fill(Color(uiColor: blenderColor(store.value(property))))
              .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
              .frame(width: 44, height: 20)
              /* Its place on screen: the canvas's effects leave no UIKit view to point from. */
              .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchor.windowRect = $0 }
          }
          .contentShape(Rectangle())
          /* The system's color picker, straight away. */
          .onTapGesture {
            guard editable else { return }
            ColorPickerSession(property: property, store: store)
              .present(from: anchor, color: blenderColor(store.value(property)))
          }
          /* A color well: its color drags out, and a color dropped on it is taken. */
          .onDrag { NSItemProvider(object: blenderColor(store.value(property))) }
          .onDrop(of: [.data], isTargeted: nil) { providers in
            guard editable, let provider = providers.first(where: { $0.canLoadObject(ofClass: UIColor.self) })
            else { return false }
            _ = provider.loadObject(ofClass: UIColor.self) { color, _ in
              guard let color = color as? UIColor,
                    let components = colorComponents(color, alpha: property.bool("alpha")) else { return }
              DispatchQueue.main.async { store.edit(property, value: components) }
            }
            return true
          }
        default:
          labeled { valueText(summary, chevron: type == "ID" || type == "MENU" || type == "OPERATOR_MENU") }
            .contentShape(Rectangle())
            .onTapGesture { if editable { editing = true } }
      }
    }
    .frame(minHeight: 28)
    .opacity(editable ? 1 : 0.5)
    .popover(isPresented: $editing) { editor }
  }

  /** Where the value is changed in full: the Properties control, or the choices of a menu. */
  @ViewBuilder
  private var editor: some View {
    if type == "ENUM" {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(property.array("options").enumerated()), id: \.offset) { _, option in
            Button {
              store.edit(property, value: option["value"] ?? "")
              editing = false
            } label: {
              HStack {
                Text(option.string("label") ?? "")
                Spacer(minLength: 16)
                if jsonEqual(option["value"], store.value(property)) {
                  Image(systemName: "checkmark").foregroundStyle(.tint)
                }
              }
              .padding(.horizontal, 16)
              .frame(minHeight: 44)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.vertical, 6)
      }
      .frame(minWidth: 240, maxHeight: 420)
      .presentationCompactAdaptation(.popover)
    }
    else if type == "ID" {
      DataBrowser(store: store, property: property) { editing = false }
        .frame(minWidth: 360, minHeight: min(520, 150 + 60 * CGFloat(property.array("options").count)))
    }
    else {
      VStack(alignment: .leading) {
        switch type {
          case "LIST", "PREVIEW", "OPERATOR_MENU":
            CompositeRow(store: store, property: property)
          default:
            PropertyRow(store: store, property: property)
        }
      }
      .padding(16)
      .frame(minWidth: 320)
      .presentationCompactAdaptation(.popover)
    }
  }

  private func labeled<Control: View>(@ViewBuilder _ control: () -> Control) -> some View {
    HStack(spacing: 8) {
      Text(propertyLabel(property))
        .font(.callout)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
      control()
    }
  }

  private func valueText(_ text: String, chevron: Bool) -> some View {
    HStack(spacing: 3) {
      Text(text).lineLimit(1)
      if chevron {
        Image(systemName: "chevron.up.chevron.down").font(.caption2)
      }
    }
    .font(.callout)
    .foregroundStyle(Color.accentColor)
  }

  private var enumLabel: String {
    property.array("options").first { jsonEqual($0["value"], store.value(property)) }?.string("label") ?? ""
  }

  private var summary: String {
    switch type {
      case "ID": return property.string("name") ?? "None"
      case "STRING": return (store.value(property) as? String).map { $0.isEmpty ? "—" : $0 } ?? "—"
      default: return property.string("value_label") ?? ""
    }
  }
}

/** A switch drawn as one, which flips with a tap on its row. */
struct NodeCanvasSwitch: View {
  let on: Bool

  var body: some View {
    Capsule()
      .fill(on ? Color.green : Color(uiColor: .systemFill))
      .frame(width: 38, height: 23)
      .overlay(alignment: on ? .trailing : .leading) {
        Circle().fill(.white).shadow(color: .black.opacity(0.2), radius: 1, y: 1).padding(2)
      }
      .animation(.spring(response: 0.25, dampingFraction: 0.8), value: on)
      .accessibilityRepresentation { Toggle("", isOn: .constant(on)) }
  }
}

/** A number on a node: dragged sideways it scrubs, tapped it takes a typed value, as the
 * Properties field does; a slider's share of its range shows as a fill. */
struct NodeCanvasNumber: View {
  let store: InspectorStore
  let property: JSON
  var width: CGFloat = 72
  @State private var scrub: (start: Double, value: Double, interaction: String, last: CFTimeInterval)?
  /** Its place on screen, where the field typed in shows over it. */
  @State private var anchor = AnchorBox()
  private var typing: Bool { NodeTyping.shared.isTyping(property) }

  private var value: Double { scrub?.value ?? numericValue(store.value(property)) }

  var body: some View {
    let box = RoundedRectangle(cornerRadius: 6, style: .continuous)
    ZStack(alignment: .leading) {
      box.fill(Color(uiColor: .tertiarySystemFill))
      if property.has("slider") {
        GeometryReader { proxy in
          box.fill(Color.accentColor.opacity(0.35))
            .frame(width: proxy.size.width * SliderScale(property).fraction(value))
        }
      }
      Text(formatNumber(value, property: property, significant: 5))
        .font(.callout.monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 6)
        .opacity(typing ? 0 : 1)
    }
    .frame(width: width, height: 24)
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchor.windowRect = $0 }
    .contentShape(Rectangle())
    .onTapGesture { beginTyping() }
    .gesture(
      DragGesture(minimumDistance: 4)
        .onChanged { drag in
          guard property.bool("editable"), !typing else { return }
          var current = scrub ?? (numericValue(store.value(property)), numericValue(store.value(property)),
                                  UUID().uuidString, 0)
          let integer = property.string("type") == "INT"
          var step = property.double("dragStep") ?? (integer ? 0.5 : 0.01)
          if property.bool("angle") { step *= 10 * .pi / 180 }
          var next = current.start + drag.translation.width * scrubSensitivity(drag.translation.height) * step
          next = min(property.double("max") ?? .greatestFiniteMagnitude,
                     max(property.double("min") ?? -.greatestFiniteMagnitude, next))
          if integer { next = next.rounded() }
          current.value = next
          if CACurrentMediaTime() - current.last >= 1.0 / 60.0 {
            store.preview(property, value: next, interaction: current.interaction, phase: "update")
            current.last = CACurrentMediaTime()
          }
          scrub = current
        }
        .onEnded { _ in
          guard let current = scrub else { return }
          store.preview(property, value: current.value, interaction: current.interaction,
                        phase: current.value == current.start ? "cancel" : "end")
          scrub = nil
        })
    .accessibilityElement()
    .accessibilityLabel(propertyLabel(property))
    .accessibilityValue(formatNumber(value, property: property, significant: 5))
  }

  private func beginTyping() {
    guard property.bool("editable"), scrub == nil else { return }
    NodeTyping.shared.begin(store: store, property: property, frame: anchor.windowRect ?? .zero,
                            text: formatNumber(numericValue(store.value(property)), property: property,
                                               significant: 6))
  }
}

/** Text on a node, typed where it shows. */
struct NodeCanvasText: View {
  let store: InspectorStore
  let property: JSON
  @State private var anchor = AnchorBox()

  private var stored: String { store.value(property) as? String ?? "" }

  var body: some View {
    Text(stored)
      .font(.callout)
      .lineLimit(1)
      .frame(minWidth: 72, maxWidth: 160, minHeight: 24, alignment: .trailing)
      .padding(.horizontal, 6)
      .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .opacity(NodeTyping.shared.isTyping(property) ? 0 : 1)
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchor.windowRect = $0 }
      .contentShape(Rectangle())
      .onTapGesture {
        guard property.bool("editable") else { return }
        NodeTyping.shared.begin(store: store, property: property, frame: anchor.windowRect ?? .zero, text: stored)
      }
  }
}

/**
 * A value on a node being typed: the canvas draws through its effects, which a system text field
 * can't be part of, so the field shows above the canvas, over the value, at its size.
 */
@MainActor
@Observable
final class NodeTyping {
  static let shared = NodeTyping()

  private(set) var property: JSON?
  @ObservationIgnored private(set) var store: InspectorStore?
  private(set) var frame: CGRect = .zero
  var text = ""

  var numeric: Bool { ["INT", "FLOAT"].contains(property?.string("type") ?? "") }

  func isTyping(_ property: JSON) -> Bool {
    guard let current = self.property else { return false }
    return propertyKey(current) == propertyKey(property)
  }

  func begin(store: InspectorStore, property: JSON, frame: CGRect, text: String) {
    commit()
    self.store = store
    self.property = property
    self.frame = frame
    self.text = text
  }

  /** The typed value set, as a field's own is when it's done. */
  func commit() {
    guard let property, let store else { return }
    let numeric = self.numeric
    self.property = nil
    self.store = nil
    if numeric {
      let shown = formatNumber(numericValue(store.value(property)), property: property, significant: 6)
      guard text != shown else { return }
      guard let number = parseNumber(text, property: property) else {
        store.showStatus("Enter a valid number.")
        return
      }
      store.edit(property, value: property.string("type") == "INT" ? number.rounded() : number)
    }
    else if text != store.value(property) as? String ?? "" {
      store.edit(property, value: text)
    }
  }
}

/** The field a node's value is typed in, over the value, scaled as the canvas is. */
struct NodeTypingField: View {
  let typing = NodeTyping.shared
  @FocusState private var focused: Bool

  var body: some View {
    GeometryReader { proxy in
      if typing.property != nil {
        let origin = proxy.frame(in: .global).origin
        let frame = typing.frame
        let scale = max(0.5, frame.height / 24)
        TextField("", text: Binding(get: { typing.text }, set: { typing.text = $0 }))
          .font(.system(size: 15 * scale).monospacedDigit())
          .multilineTextAlignment(.trailing)
          .keyboardType(typing.numeric ? .numbersAndPunctuation : .default)
          .submitLabel(.done)
          .focused($focused)
          .onSubmit { typing.commit() }
          .padding(.horizontal, 6 * scale)
          .frame(width: max(frame.width, typing.numeric ? 0 : 120 * scale), height: frame.height)
          .background(Color(uiColor: .systemBackground),
                      in: RoundedRectangle(cornerRadius: 6 * scale, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 1.5))
          .position(x: frame.maxX - origin.x - max(frame.width, typing.numeric ? 0 : 120 * scale) / 2,
                    y: frame.midY - origin.y)
          .onAppear {
            focused = true
            DispatchQueue.main.async {
              UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
            }
          }
          .onChange(of: focused) { _, isFocused in if !isFocused { typing.commit() } }
      }
    }
  }
}

/** A vector's components side by side under its name. */
struct NodeCanvasVector: View {
  let store: InspectorStore
  let title: String
  let items: [JSON]

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      if !title.isEmpty {
        Text(title).font(.caption).foregroundStyle(.secondary)
      }
      HStack(spacing: 4) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          NodeCanvasNumber(store: store, property: item, width: 54)
        }
      }
    }
    .padding(.vertical, 2)
  }
}

struct NodeFieldRows: View {
  let store: InspectorStore
  let fields: [JSON]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Self.rows(fields)) { row in
        switch row.kind {
          case .property(let property):
            PropertyRow(store: store, property: property)
              .equatable()
          case .vector(let title, let items):
            VectorRow(store: store, title: title, items: items)
              .equatable()
          case .toggles(let caption, let items):
            ToggleGroupRow(store: store, caption: caption, items: items)
              .equatable()
          case .composite(let property):
            CompositeRow(store: store, property: property)
              .equatable()
          case .heading:
            EmptyView()
        }
      }
    }
  }

  /** Fields to rows: a vector's components together under its name. */
  static func rows(_ fields: [JSON]) -> [InspectorRow] {
    var rows: [InspectorRow] = []
    var vectors: [String: Int] = [:]
    for field in fields {
      let key = propertyKey(field)
      if ["ID", "LIST", "PREVIEW", "OPERATOR_MENU"].contains(field.string("type") ?? "") {
        rows.append(InspectorRow(id: "composite:" + key, kind: .composite(field)))
        continue
      }
      if let group = field.string("group"), !group.isEmpty {
        let groupKey = field.string("group_key") ?? group
        if let index = vectors[groupKey], case .vector(let title, var items) = rows[index].kind {
          items.append(field)
          rows[index].kind = .vector(title: title, items: items)
        }
        else {
          rows.append(InspectorRow(id: "vector:" + groupKey, kind: .vector(title: group, items: [field])))
          vectors[groupKey] = rows.count - 1
        }
        continue
      }
      rows.append(InspectorRow(id: "property:" + key, kind: .property(field)))
    }
    return rows
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Adding Nodes
 * \{ */

/** The nodes the tree can have, by category, with search, as Blender's Add menu offers them. */
/** A node's input or output types at a glance, as their socket colors, in a column of one width
 * across the add list; `leading` packs them against the name on its right. */
struct NodeSocketDots: View {
  let colors: [Any]
  let leading: Bool
  /** Room for five types, the most shown. */
  static let width: CGFloat = 5 * 9 + 4 * 2

  var body: some View {
    HStack(spacing: 2) {
      ForEach(Array(colors.enumerated()), id: \.offset) { _, value in
        let c = (value as? [NSNumber])?.map(\.doubleValue) ?? [0.6, 0.6, 0.6]
        Circle()
          .fill(Color(red: c[0], green: c[1], blue: c[2]))
          .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 0.5))
          .frame(width: 9, height: 9)
      }
    }
    .frame(width: Self.width, alignment: leading ? .leading : .trailing)
    .accessibilityHidden(true)
  }
}

/** A node the Add sheet offers, read once as it opens, with what search matches against. */
struct NodeAddEntry: Identifiable {
  let id: String
  let name: String
  let description: String
  let category: String
  let inputs: [Any]
  let outputs: [Any]
  let item: JSON
  /** The name and description in lower case, matched as typed. */
  let search: String

  init(_ item: JSON, index: Int) {
    self.item = item
    name = item.string("name") ?? ""
    description = item.string("description") ?? ""
    category = item.string("category") ?? "Other"
    inputs = item["inputs"] as? [Any] ?? []
    outputs = item["outputs"] as? [Any] ?? []
    /* A node group's entry shares its node type with the other groups. */
    id = (item.string("idname") ?? "") + "|" + (item.string("group") ?? "") + "|\(index)"
    search = (name + "\n" + description).lowercased()
  }
}

struct NodeAddSheet: View {
  let items: [JSON]
  let pick: (JSON) -> Void
  @State private var query = ""
  /** Read once as the sheet opens: the tree's updates while it is open leave it alone. */
  @State private var entries: [NodeAddEntry]?
  /** Typed in at once, without first tapping the field. */
  @FocusState private var searching: Bool

  private static let order = ["Input", "Output", "Shader", "Texture", "Color", "Vector", "Converter", "Geometry",
                              "Attribute", "Filter", "Matte", "Distort", "Pattern", "Group", "Layout", "Interface",
                              "Script", "Other"]

  private static func prepared(_ items: [JSON]) -> [NodeAddEntry] {
    items.enumerated().map { NodeAddEntry($0.element, index: $0.offset) }.sorted {
      let a = order.firstIndex(of: $0.category) ?? 99, b = order.firstIndex(of: $1.category) ?? 99
      return a != b ? a < b : $0.category != $1.category ? $0.category < $1.category : $0.name < $1.name
    }
  }

  private var categories: [(String, [NodeAddEntry])] {
    let all = entries ?? Self.prepared(items)
    let words = query.lowercased().split(separator: " ")
    let filtered = words.isEmpty ? all : all.filter { entry in words.allSatisfy { entry.search.contains($0) } }
    var result: [(String, [NodeAddEntry])] = []
    for entry in filtered {
      if result.last?.0 == entry.category { result[result.count - 1].1.append(entry) }
      else { result.append((entry.category, [entry])) }
    }
    return result
  }

  var body: some View {
    NavigationStack {
      List {
        ForEach(categories, id: \.0) { category, entries in
          Section(category) {
            ForEach(entries) { entry in
              Button {
                pick(entry.item)
              } label: {
                /* Inputs to the left and outputs to the right, in columns of one width, so the
                 * names line up whatever goes in and out. */
                HStack(spacing: 10) {
                  NodeSocketDots(colors: entry.inputs, leading: false)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).foregroundStyle(.primary)
                    if !entry.description.isEmpty {
                      Text(entry.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                  NodeSocketDots(colors: entry.outputs, leading: true)
                }
              }
            }
          }
        }
      }
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
      .searchFocused($searching)
      .onAppear {
        if entries == nil { entries = Self.prepared(items) }
        searching = true
      }
      .navigationTitle("Add Node")
      .navigationBarTitleDisplayMode(.inline)
    }
  }
}

/** \} */

/** Shows a node's actions as the system's edit menu, above the node, as a selected object on a
 * canvas shows its own. */
@MainActor
final class NodeMenuPresenter: NSObject, UIEditMenuInteractionDelegate {
  private weak var view: UIView?
  private var interaction: UIEditMenuInteraction?
  private var menu: UIMenu?
  private var target: CGRect = .zero

  func attach(to view: UIView) {
    guard self.view !== view else { return }
    let interaction = UIEditMenuInteraction(delegate: self)
    view.addInteraction(interaction)
    self.view = view
    self.interaction = interaction
  }

  /** `around` is the node, in the canvas view's points. */
  func present(_ menu: UIMenu, around rect: CGRect) {
    guard let interaction else { return }
    self.menu = menu
    target = rect
    let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.minY))
    configuration.preferredArrowDirection = .down
    interaction.presentEditMenu(with: configuration)
  }

  func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                           suggestedActions: [UIMenuElement]) -> UIMenu?
  {
    menu
  }

  func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                           targetRectFor configuration: UIEditMenuConfiguration) -> CGRect
  {
    target
  }
}

/** The view the node menus are shown from, filling the canvas. */
struct NodeMenuAnchor: UIViewRepresentable {
  let presenter: NodeMenuPresenter

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.isUserInteractionEnabled = false
    presenter.attach(to: view)
    return view
  }

  func updateUIView(_ view: UIView, context: Context) {
    presenter.attach(to: view)
  }
}

/** A node just deleted: as it was, where its middle was on the canvas, and when. */
struct NodeVanish: Identifiable {
  static let duration: TimeInterval = 0.6
  let id = UUID()
  let node: JSON
  let center: CGPoint
  let size: CGSize
  let start: Date
}

/** A node landing: where and when. */
struct NodeRipple: Identifiable {
  let id = UUID()
  let name: String
  let start: Date
}

/** Water rippling out from a node as it lands, as widgets once did when dropped: rings run
 * outward over the live canvas, bending it and catching the light, and calm within a moment. */
struct NodeRippleEffect: ViewModifier {
  static let duration: TimeInterval = 2.6
  /** The shaders, built with the app, see `NodeEffects.metal`. */
  static let library: ShaderLibrary? = Bundle.main.url(forResource: "NodeEffects", withExtension: "metallib")
    .map { ShaderLibrary(url: $0) }

  /** The new node's size as it floats on its waves `time` seconds after landing. */
  static func bob(_ time: TimeInterval) -> CGFloat {
    guard time >= 0, time < duration, !UIAccessibility.isReduceMotionEnabled else { return 1 }
    return 1 - 0.06 * exp(-2.4 * time) * cos(2 * .pi * 1.6 * time)
  }

  let ripple: NodeRipple?
  /** The node it runs from, in view points. */
  let rect: CGRect?

  func body(content: Content) -> some View {
    TimelineView(.animation(paused: ripple == nil)) { timeline in
      let time = ripple.map { Float(timeline.date.timeIntervalSince($0.start)) } ?? 0
      let r = rect ?? .zero
      content.layerEffect(
        (Self.library ?? ShaderLibrary.default).node_ripple(
          .float4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)), .float(14), .float(time),
          .float(7), .float(56), .float(210), .float(0.6)),
        maxSampleOffset: CGSize(width: 8, height: 8),
        isEnabled: ripple != nil && Self.library != nil && time < Float(Self.duration))
    }
  }
}

/** A node dipping as it lands, then rising and settling. The same views throughout, landed or
 * not, so a drag already on the node carries on as the bob ends. */
struct NodeBob: ViewModifier {
  let start: Date?

  func body(content: Content) -> some View {
    TimelineView(.animation(paused: start == nil)) { timeline in
      content.scaleEffect(start.map { NodeRippleEffect.bob(timeline.date.timeIntervalSince($0)) } ?? 1)
    }
  }
}

struct NodeCanvasScrolling: ViewModifier {
  let action: (_ state: UIGestureRecognizer.State, _ translation: CGSize) -> Void

  func body(content: Content) -> some View {
#if os(visionOS)
    content
#else
    content.gesture(NodeCanvasDrag(kind: .scroll) { state, _, location in
      action(state, CGSize(width: location.x, height: location.y))
    })
#endif
  }
}

#if !os(visionOS)
/** A pan that remembers where its first touch came down: a pan begins only once the touch has
 * moved, and its translation may not count that first movement, so a drag from a node or key
 * would start some way past it. */
final class TouchDownPan: UIPanGestureRecognizer {
  private(set) var touchDown: CGPoint?

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    if touchDown == nil, let touch = touches.first { touchDown = touch.location(in: view) }
    super.touchesBegan(touches, with: event)
  }

  override func reset() {
    super.reset()
    touchDown = nil
  }

  /** Where the first touch came down, in the space `location` is measured in. */
  func start(_ location: CGPoint) -> CGPoint {
    guard let touchDown else {
      let translation = translation(in: view)
      return CGPoint(x: location.x - translation.x, y: location.y - translation.y)
    }
    let here = self.location(in: view)
    return CGPoint(x: location.x - here.x + touchDown.x, y: location.y - here.y + touchDown.y)
  }
}

/** One of the canvas's drags, told apart by what makes it, which SwiftUI's own drag can't do.
 * It reports where it started and where it is, in the view's own points. */
struct NodeCanvasDrag: UIGestureRecognizerRepresentable {
  enum Kind {
    /** A finger dragging. */
    case finger
    /** A finger held still, then dragging. */
    case hold
    /** A pointer or the Pencil dragging. */
    case pointer
    /** A trackpad's or mouse wheel's scrolling. */
    case scroll
  }

  let kind: Kind
  /** Where locations are measured, when not in the view the gesture is on. */
  var space: NamedCoordinateSpace?
  let action: (_ state: UIGestureRecognizer.State, _ start: CGPoint, _ location: CGPoint) -> Void

  final class Coordinator {
    var start = CGPoint.zero
  }

  func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

  func makeUIGestureRecognizer(context: Context) -> UIGestureRecognizer {
    let touches = { (types: [UITouch.TouchType]) in types.map { NSNumber(value: $0.rawValue) } }
    switch kind {
      case .finger:
        let pan = TouchDownPan()
        pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = touches([.direct])
        return pan
      case .hold:
        let hold = UILongPressGestureRecognizer()
        hold.minimumPressDuration = 0.35
        hold.allowedTouchTypes = touches([.direct])
        return hold
      case .pointer:
        let pan = TouchDownPan()
        pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = touches([.indirectPointer, .pencil])
        return pan
      case .scroll:
        let pan = UIPanGestureRecognizer()
        pan.allowedTouchTypes = []
        pan.allowedScrollTypesMask = .all
        return pan
    }
  }

  func handleUIGestureRecognizerAction(_ recognizer: UIGestureRecognizer, context: Context) {
    let location = space.map { context.converter.location(in: $0) } ?? context.converter.localLocation
    if let pan = recognizer as? UIPanGestureRecognizer {
      /* From where the drag started, before it moved far enough to begin. */
      let translation = pan.translation(in: pan.view)
      if kind == .scroll {
        /* Scrolling has no location to follow, only how far it has gone. */
        action(recognizer.state, .zero, translation)
        return
      }
      if recognizer.state == .began {
        context.coordinator.start = (pan as? TouchDownPan)?.start(location) ??
          CGPoint(x: location.x - translation.x, y: location.y - translation.y)
      }
    }
    else if recognizer.state == .began {
      context.coordinator.start = location
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    action(recognizer.state, context.coordinator.start, location)
  }
}
#endif

/* -------------------------------------------------------------------- */
/** \name Layer
 * \{ */

/** The node editor over the bottom of the viewport, its top edge dragged to make it taller. */
struct NodeEditorLayer: View {
  let model: ShellModel
  let nodes: NodeEditorModel
  @AppStorage("BlenderNodeEditorFraction") private var fraction = 0.5
  @State private var dragStart: Double?

  var body: some View {
    GeometryReader { proxy in
      VStack(spacing: 0) {
        Spacer(minLength: 0)
        VStack(spacing: 0) {
          Capsule()
            .fill(.secondary.opacity(0.5))
            .frame(width: 44, height: 5)
            .frame(maxWidth: .infinity, minHeight: 18)
            .contentShape(Rectangle())
            .gesture(
              /* Measured in the window: the handle moves with the drag, and measuring from it
               * would make the panel jitter between two heights. */
              DragGesture(coordinateSpace: .global)
                .onChanged { value in
                  let start = dragStart ?? fraction
                  dragStart = start
                  fraction = min(0.9, max(0.25, start - value.translation.height / max(proxy.size.height, 1)))
                  /* The viewport follows the handle as it moves. */
                  model.nodesCoverDragging = true
                  cover(proxy.size.height, live: true)
                }
                .onEnded { _ in
                  dragStart = nil
                  cover(proxy.size.height, live: true)
                  model.nodesCoverDragging = false
                })
            .accessibilityLabel("Resize Node Editor")
          NodeEditorPanel(model: nodes)
        }
        .frame(height: proxy.size.height * fraction)
        .background(PanelStyle.docked, in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24,
                                                                  style: .continuous))
        .padding(.leading, model.sideInsets.left)
        .padding(.trailing, model.sideInsets.right)
      }
      .onChange(of: proxy.size.height, initial: true) { _, height in cover(height) }
    }
    .ignoresSafeArea(edges: .bottom)
    .onDisappear { withAnimation(.easeOut(duration: 0.42)) { model.nodesCover = 0 } }
  }

  /** The viewport ends under the panel's rounded corners, and changes size once a drag ends
   * rather than on every step of it. */
  private func cover(_ height: CGFloat, live: Bool = false) {
    /* Eased as the viewport itself is, see `ViewportContainer`. */
    let cover = max(0, height * fraction - 24)
    if cover != model.nodesCover {
      if live {
        model.nodesCover = cover
      }
      else {
        withAnimation(.easeOut(duration: 0.42)) { model.nodesCover = cover }
      }
    }
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Hardware Keys
 *
 * While the node editor was touched last, a hardware keyboard's keys go to it rather than to the
 * viewport, and run as Blender's node editor keymap has them: whichever keymap is chosen, with
 * the user's changes. Touching anywhere else gives the keys back.
 * \{ */

/** An editor that takes a hardware keyboard's keys while it was touched last. */
@MainActor
protocol HardwareKeyTarget: AnyObject {
  var takesKeys: Bool { get }
  func sendKey(_ key: String, shift: Bool, ctrl: Bool, alt: Bool, oskey: Bool)
}

extension NodeEditorModel: HardwareKeyTarget {
  var takesKeys: Bool { shown }
}

struct NodeKeyCapture: UIViewRepresentable {
  let model: any HardwareKeyTarget

  func makeUIView(context: Context) -> NodeKeyCaptureView {
    let view = NodeKeyCaptureView()
    view.model = model
    return view
  }

  func updateUIView(_ view: NodeKeyCaptureView, context: Context) {
    view.model = model
    if !model.takesKeys, view.isFirstResponder {
      DispatchQueue.main.async { _ = view.resignFirstResponder() }
    }
  }
}

final class NodeKeyCaptureView: UIView, UIKeyInput {
  weak var model: (any HardwareKeyTarget)?
  private var observer: TouchObserver?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if let observer { observer.view?.removeGestureRecognizer(observer) }
    observer = nil
    guard let window else { return }
    /* Sees every touch in the window without taking any, to tell where focus went. */
    let touches = TouchObserver { [weak self] point in self?.touched(at: point) }
    window.addGestureRecognizer(touches)
    observer = touches
  }

  /** The editor's panel: this view's superview's bounds, as it fills the panel. */
  private func touched(at point: CGPoint) {
    guard let panel = superview, let window else { return }
    let inside = panel.convert(panel.bounds, to: window).contains(point)
    if inside, !isFirstResponder, model?.takesKeys == true { _ = becomeFirstResponder() }
    else if !inside, isFirstResponder { _ = resignFirstResponder() }
  }

  override var canBecomeFirstResponder: Bool { model?.takesKeys == true }

  /* No on-screen keyboard or shortcuts bar: only hardware keys are wanted. */
  override var inputView: UIView? { UIView(frame: .zero) }
#if !os(visionOS) /* No shortcuts bar there. */
  override var inputAssistantItem: UITextInputAssistantItem {
    let item = super.inputAssistantItem
    item.leadingBarButtonGroups = []
    item.trailingBarButtonGroups = []
    return item
  }
#endif

  var hasText: Bool { false }
  func insertText(_ text: String) {}
  func deleteBackward() {}

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    var handled = false
    for press in presses {
      guard let key = press.key, let name = Self.blenderKey(key) else { continue }
      if key.keyCode == .keyboardEscape { continue }
      let flags = key.modifierFlags
      model?.sendKey(name, shift: flags.contains(.shift), ctrl: flags.contains(.control),
                     alt: flags.contains(.alternate), oskey: flags.contains(.command))
      handled = true
    }
    if !handled { super.pressesBegan(presses, with: event) }
  }

  /** The key as Blender's event types name it. */
  static func blenderKey(_ key: UIKey) -> String? {
    let usage = key.keyCode.rawValue
    switch usage {
      case 4...29: return String(UnicodeScalar(UInt8(65 + usage - 4)))
      case 30...38:
        return ["ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE"][usage - 30]
      case 39: return "ZERO"
      case 40: return "RET"
      case 42: return "BACK_SPACE"
      case 43: return "TAB"
      case 44: return "SPACE"
      case 45: return "MINUS"
      case 46: return "EQUAL"
      case 47: return "LEFT_BRACKET"
      case 48: return "RIGHT_BRACKET"
      case 49: return "BACK_SLASH"
      case 51: return "SEMI_COLON"
      case 52: return "QUOTE"
      case 53: return "ACCENT_GRAVE"
      case 54: return "COMMA"
      case 55: return "PERIOD"
      case 56: return "SLASH"
      case 58...69: return "F\(usage - 57)"
      case 74: return "HOME"
      case 75: return "PAGE_UP"
      case 76: return "DEL"
      case 77: return "END"
      case 78: return "PAGE_DOWN"
      case 79: return "RIGHT_ARROW"
      case 80: return "LEFT_ARROW"
      case 81: return "DOWN_ARROW"
      case 82: return "UP_ARROW"
      default: return nil
    }
  }
}

/** Reports each touch's start in the window, then fails, so the touch goes on as it would. */
private final class TouchObserver: UIGestureRecognizer {
  private let began: (CGPoint) -> Void

  init(began: @escaping (CGPoint) -> Void) {
    self.began = began
    super.init(target: nil, action: nil)
    cancelsTouchesInView = false
    delaysTouchesBegan = false
    delaysTouchesEnded = false
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    if let touch = touches.first, let view { began(touch.location(in: view)) }
    state = .failed
  }

  override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
  override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Node Details
 * \{ */

/** Images Blender wrote for previews and the backdrop, read once each. */
enum NodeImages {
  private static let cache = NSCache<NSString, UIImage>()

  static func image(_ path: String) -> UIImage? {
    if let cached = cache.object(forKey: path as NSString) { return cached }
    guard let image = UIImage(contentsOfFile: path) else { return nil }
    cache.setObject(image, forKey: path as NSString)
    return image
  }
}

/** A node's errors and warnings from its last evaluation, behind an icon in its header. */
struct NodeWarningsButton: View {
  let warnings: [JSON]
  @State private var shown = false

  private var worst: String {
    warnings.contains { $0.string("type") == "ERROR" } ? "ERROR" :
      warnings.contains { $0.string("type") == "WARNING" } ? "WARNING" : "INFO"
  }

  var body: some View {
    Button {
      shown = true
    } label: {
      Image(systemName: worst == "INFO" ? "info.circle.fill" : "exclamationmark.triangle.fill")
        .font(.caption)
        .symbolRenderingMode(.multicolor)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(worst == "ERROR" ? "Errors" : worst == "WARNING" ? "Warnings" : "Information")
    .popover(isPresented: $shown) {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
          Label {
            Text(warning.string("message") ?? "")
          } icon: {
            Image(systemName: warning.string("type") == "ERROR" ? "xmark.octagon.fill" :
                    warning.string("type") == "WARNING" ? "exclamationmark.triangle.fill" : "info.circle.fill")
              .foregroundStyle(warning.string("type") == "ERROR" ? .red :
                                 warning.string("type") == "WARNING" ? .orange : .blue)
          }
        }
      }
      .padding()
      .frame(minWidth: 260, maxWidth: 400)
      .presentationCompactAdaptation(.popover)
    }
  }
}

/** A node's own color, chosen with the system's color picker. */
struct NodeColorSheet: View {
  let model: NodeEditorModel
  let node: JSON
  @Environment(\.dismiss) private var dismiss
  @State private var color: Color = .gray

  var body: some View {
    NavigationStack {
      Form {
        ColorPicker("Color", selection: $color, supportsOpacity: false)
        Button("Default Color") {
          model.send("color", ["node": node.string("name") ?? ""])
          dismiss()
        }
      }
      .navigationTitle(node.string("title") ?? "Node Color")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            model.send("color", ["node": node.string("name") ?? "", "value": [red, green, blue].map(Double.init)])
            dismiss()
          }
        }
      }
    }
    .onAppear {
      if let rgb = node["color"] as? [NSNumber], rgb.count >= 3 {
        color = Color(red: rgb[0].doubleValue, green: rgb[1].doubleValue, blue: rgb[2].doubleValue)
      }
    }
  }
}

/** A group's inputs and outputs: renamed, reordered, added and removed, as Blender's Group panel. */
struct NodeInterfaceSheet: View {
  let model: NodeEditorModel
  @Environment(\.dismiss) private var dismiss

  private var items: [JSON] { model.snapshot?.array("interface") ?? [] }
  private var types: [JSON] { model.snapshot?.array("socket_types") ?? [] }

  var body: some View {
    NavigationStack {
      List {
        section("Inputs", output: false)
        section("Outputs", output: true)
      }
      .environment(\.editMode, .constant(.active))
      .navigationTitle("Group Inputs & Outputs")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }
  }

  private func section(_ title: String, output: Bool) -> some View {
    let entries = items.filter { $0.bool("output") == output }
    return Section {
      ForEach(entries, id: \.interfaceID) { item in
        NodeInterfaceRow(model: model, item: item)
      }
      .onDelete { offsets in
        for offset in offsets {
          model.send("interface_remove", ["identifier": entries[offset].string("identifier") ?? ""])
        }
      }
      .onMove { source, destination in
        /* Positions count the whole list, inputs and outputs together, as Blender's do. */
        guard let from = source.first, let item = entries[safe: from],
              let base = items.firstIndex(where: { $0.interfaceID == entries.first?.interfaceID })
        else { return }
        let target = destination > from ? destination - 1 : destination
        model.send("interface_move", ["identifier": item.string("identifier") ?? "", "position": base + target])
      }
      Menu {
        ForEach(types, id: \.interfaceType) { type in
          Button(type.string("name") ?? "") {
            model.send("interface_add", ["output": output ? 1 : 0, "type": type.string("idname") ?? "",
                                         "name": type.string("name") ?? (output ? "Output" : "Input")])
          }
        }
      } label: {
        Label(output ? "Add Output" : "Add Input", systemImage: "plus.circle.fill")
      }
    } header: {
      Text(title)
    }
  }
}

private struct NodeInterfaceRow: View {
  let model: NodeEditorModel
  let item: JSON
  @State private var name = ""

  var body: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(colorOf(item))
        .frame(width: 10, height: 10)
      TextField("Name", text: $name)
        .onSubmit {
          model.send("interface_rename", ["identifier": item.string("identifier") ?? "", "name": name])
        }
      Text(item.string("type")?.replacingOccurrences(of: "NodeSocket", with: "") ?? "")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .onAppear { name = item.string("name") ?? "" }
    .onChange(of: item.string("name") ?? "") { _, newValue in name = newValue }
  }

  private func colorOf(_ item: JSON) -> Color {
    let c = (item["color"] as? [NSNumber])?.map(\.doubleValue) ?? [0.6, 0.6, 0.6]
    return Color(red: c[0], green: c[1], blue: c[2])
  }
}

private extension Dictionary where Key == String, Value == Any {
  var interfaceID: String { string("identifier") ?? "" }
  var interfaceType: String { string("idname") ?? "" }
}

private extension Array {
  subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/** \} */
