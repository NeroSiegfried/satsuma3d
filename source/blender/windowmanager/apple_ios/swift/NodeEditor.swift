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
  private(set) var shown = false
  /** Bumped to fit the view to the tree, as when another tree shows. */
  private(set) var fitRequest = 0
  /** The controls on the nodes, which edit through the same store as Properties' controls. */
  let store = InspectorStore(mode: .nodes)
  @ObservationIgnored var shownChanged: (Bool) -> Void = { _ in }

  var nodes: [JSON] { snapshot?.array("nodes") ?? [] }
  var links: [JSON] { snapshot?.array("links") ?? [] }
  var addItems: [JSON] { snapshot?.array("add") ?? [] }

  private var context: JSON { ["tree": kind.rawValue, "path": path] }

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
    sendState()
    fitRequest += 1
  }

  func enter(group node: String) {
    path.append(node)
    snapshot = nil
    sendState()
    fitRequest += 1
  }

  /** Back out to `depth` groups deep, 0 for the tree itself. */
  func exit(to depth: Int) {
    guard depth < path.count else { return }
    path = Array(path.prefix(depth))
    snapshot = nil
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
    if let snapshot, (snapshot as NSDictionary).isEqual(next as NSDictionary) { return }
    let first = snapshot == nil
    snapshot = next
    if first { fitRequest += 1 }
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
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        Button(model.snapshot?.string("owner") ?? model.snapshot?.string("name") ?? "") { model.exit(to: 0) }
          .buttonStyle(.plain)
          .foregroundStyle(path.isEmpty ? .primary : .secondary)
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
}

struct NodeCanvas: View {
  let model: NodeEditorModel
  @Binding var adding: NodeAddRequest?
  @State private var layout = NodeCanvasLayout()
  @State private var zoom: CGFloat = 0.7
  @State private var pan: CGSize = .zero
  @State private var gestureZoom: (zoom: CGFloat, pan: CGSize)?
  @State private var panStart: CGSize?
  @State private var viewSize: CGSize = .zero
  /** Nodes being dragged, and how far, in canvas points. */
  @State private var drag: (nodes: Set<String>, offset: CGSize)?
  /** Moves sent, shown until Blender's snapshot has them. */
  @State private var moved: [String: CGSize] = [:]
  @State private var wire: PendingWire?
  @State private var renaming: (node: String, label: String)?

  /** The middle of the view in node space, where the Add button puts nodes. */
  static var lastCenter = CGPoint.zero

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .topLeading) {
        background
        wires
        content
          .scaleEffect(zoom, anchor: .topLeading)
          .offset(pan)
      }
      .clipped()
      .simultaneousGesture(magnify)
      .onAppear {
        viewSize = proxy.size
        fit()
      }
      .onChange(of: proxy.size) { _, size in viewSize = size }
      .onChange(of: model.fitRequest) { _, _ in
        DispatchQueue.main.async { fit() }
      }
      .onChange(of: positions) { _, _ in moved.removeAll() }
      .onChange(of: pan) { _, _ in rememberCenter() }
      .onChange(of: zoom) { _, _ in rememberCenter() }
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
    zoom = min(1.2, max(0.25, scale))
    pan = CGSize(width: viewSize.width / 2 - bounds.midX * zoom,
                 height: viewSize.height / 2 - bounds.midY * zoom)
  }

  private func cardWidth(_ node: JSON) -> CGFloat {
    max(200, CGFloat(node.double("width") ?? 140) * nodeScale)
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
    .gesture(
      DragGesture(minimumDistance: 4)
        .onChanged { value in
          let start = panStart ?? pan
          panStart = start
          pan = CGSize(width: start.width + value.translation.width,
                       height: start.height + value.translation.height)
        }
        .onEnded { _ in panStart = nil })
    .onTapGesture { model.send("select", ["node": ""]) }
    .accessibilityLabel("Node Canvas")
  }

  private var magnify: some Gesture {
    MagnifyGesture()
      .onChanged { value in
        let start = gestureZoom ?? (zoom, pan)
        gestureZoom = start
        let next = min(2.5, max(0.15, start.zoom * value.magnification))
        let anchor = value.startLocation
        pan = CGSize(width: anchor.x - (anchor.x - start.pan.width) * next / start.zoom,
                     height: anchor.y - (anchor.y - start.pan.height) * next / start.zoom)
        zoom = next
      }
      .onEnded { _ in gestureZoom = nil }
  }

  /* -------------------------------------------------------------------- */
  /* Wires */

  private var wires: some View {
    Canvas { context, _ in
      let outputs = Dictionary(model.nodes.flatMap { node in
        node.array("outputs").map { (NodeCanvasLayout.socketKey(node.string("name") ?? "", output: true, $0.string("id") ?? ""), socketColor($0)) }
      }, uniquingKeysWith: { a, _ in a })
      for link in model.links {
        if let detached = wire?.detached, jsonEqual(detached as NSDictionary, link as NSDictionary) { continue }
        let fromKey = NodeCanvasLayout.socketKey(link.string("from_node") ?? "", output: true, link.string("from_socket") ?? "")
        let toKey = NodeCanvasLayout.socketKey(link.string("to_node") ?? "", output: false, link.string("to_socket") ?? "")
        guard let from = layout.sockets[fromKey], let to = layout.sockets[toKey] else { continue }
        let color = link.bool("valid") ? (outputs[fromKey] ?? .gray) : .red
        draw(&context, from: toView(adjusted(from, link.string("from_node"))),
             to: toView(adjusted(to, link.string("to_node"))),
             color: color, muted: link.bool("muted"))
      }
      if let wire {
        let key = NodeCanvasLayout.socketKey(wire.node, output: wire.output, wire.socket)
        if let start = layout.sockets[key] {
          let a = toView(adjusted(start, wire.node)), b = toView(wire.end)
          draw(&context, from: wire.output ? a : b, to: wire.output ? b : a, color: wire.color, muted: false)
        }
      }
    }
    .allowsHitTesting(false)
  }

  /** A socket's place with its node's move in progress, which its recorded place lacks. */
  private func adjusted(_ point: CGPoint, _ node: String?) -> CGPoint {
    guard let name = node, let drag, let item = model.nodes.first(where: { $0.string("name") == name }),
          drag.nodes.contains(name) || ancestorDragged(item, drag.nodes)
    else { return point }
    return CGPoint(x: point.x + drag.offset.width, y: point.y + drag.offset.height)
  }

  private func draw(_ context: inout GraphicsContext, from: CGPoint, to: CGPoint, color: Color, muted: Bool) {
    var path = Path()
    path.move(to: from)
    let bend = max(40 * zoom, abs(to.x - from.x) * 0.5)
    path.addCurve(to: to, control1: CGPoint(x: from.x + bend, y: from.y),
                  control2: CGPoint(x: to.x - bend, y: to.y))
    let style = StrokeStyle(lineWidth: max(1.5, 3 * zoom), lineCap: .round, dash: muted ? [6, 6] : [])
    context.stroke(path, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: style.lineWidth + 2, lineCap: .round))
    context.stroke(path, with: .color(color), style: style)
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
      ForEach(model.nodes.filter { $0.string("kind") != "FRAME" }, id: \.nodeName) { node in
        nodeView(node)
      }
    }
    .frame(width: 1, height: 1, alignment: .topLeading)
    .coordinateSpace(.named("nodes"))
  }

  @ViewBuilder
  private func nodeView(_ node: JSON) -> some View {
    let name = node.string("name") ?? ""
    let point = origin(node)
    Group {
      if node.string("kind") == "REROUTE" {
        rerouteView(node)
      }
      else {
        NodeCard(model: model, layout: layout, node: node, width: cardWidth(node), wire: wireGesture,
                 move: AnyGesture(moveGesture(name)))
          .frame(width: cardWidth(node))
          .contextMenu { menu(node) }
          .onTapGesture(count: 2) {
            if node.string("kind") == "GROUP" { model.enter(group: name) }
          }
          .onTapGesture { model.send("select", ["node": name]) }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("nodes")) } action: { frame in
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
    return Circle()
      .fill(color)
      .overlay(Circle().strokeBorder(node.bool("selected") ? Color.accentColor : .black.opacity(0.4), lineWidth: 2))
      .frame(width: 16, height: 16)
      .frame(width: 32, height: 32)
      .contentShape(Circle())
      .onGeometryChange(for: CGPoint.self) { geometry in
        let frame = geometry.frame(in: .named("nodes"))
        return CGPoint(x: frame.midX, y: frame.midY)
      } action: { center in
        var rest = center
        if let drag, drag.nodes.contains(name) {
          rest = CGPoint(x: rest.x - drag.offset.width, y: rest.y - drag.offset.height)
        }
        for socket in node.array("inputs") {
          layout.set(socket: NodeCanvasLayout.socketKey(name, output: false, socket.string("id") ?? ""), rest)
        }
        for socket in node.array("outputs") {
          layout.set(socket: NodeCanvasLayout.socketKey(name, output: true, socket.string("id") ?? ""), rest)
        }
      }
      .contextMenu { menu(node) }
      .gesture(moveGesture(name))
      .offset(x: -16, y: -16)
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
    return RoundedRectangle(cornerRadius: 18, style: .continuous)
      .fill(tint.opacity(0.18))
      .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(frame.bool("selected") ? Color.accentColor : tint.opacity(0.35), lineWidth: 1.5))
      .overlay(alignment: .topLeading) {
        Text(frame.string("title") ?? "")
          .font(.headline)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 14)
          .padding(.top, 10)
      }
      .frame(width: rect.width, height: rect.height)
      .contentShape(RoundedRectangle(cornerRadius: 18))
      .contextMenu { menu(frame) }
      .gesture(moveGesture(name))
      .onTapGesture { model.send("select", ["node": name]) }
      .offset(x: rect.minX, y: rect.minY)
  }

  @ViewBuilder
  private func menu(_ node: JSON) -> some View {
    let name = node.string("name") ?? ""
    /* The node pressed, as menus act on what they are opened on. */
    let targets = [name]
    if node.string("kind") == "GROUP" {
      Button("Enter Group", systemImage: "arrow.down.right.square") { model.enter(group: name) }
    }
    Button(node.bool("muted") ? "Unmute" : "Mute", systemImage: node.bool("muted") ? "speaker.wave.2" : "speaker.slash") {
      model.send("mute", ["nodes": targets])
    }
    if node.string("kind") == "NODE" || node.string("kind") == "GROUP" {
      Button(node.bool("collapsed") ? "Expand" : "Collapse",
             systemImage: node.bool("collapsed") ? "rectangle.expand.vertical" : "rectangle.compress.vertical") {
        model.send("collapse", ["nodes": targets])
      }
    }
    Button("Rename…", systemImage: "pencil") {
      renaming = (name, node.string("title") ?? "")
    }
    Divider()
    Button("Delete", systemImage: "trash", role: .destructive) {
      model.send("delete", ["nodes": targets])
    }
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
      }
      .onEnded { value in
        guard let current = drag else { return }
        for node in current.nodes { moved[node] = value.translation }
        drag = nil
        model.send("move", ["nodes": Array(current.nodes),
                            "dx": Double(value.translation.width / nodeScale),
                            "dy": Double(-value.translation.height / nodeScale)])
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
        wire?.end = value.location
      }
      .onEnded { value in
        guard let current = wire else { return }
        wire = nil
        if let target = nearestSocket(to: value.location, output: !current.output), target.node != current.node {
          if let detached = current.detached {
            model.send("unlink", ["to_node": detached.string("to_node") ?? "", "to_socket": detached.string("to_socket") ?? "",
                                  "from_node": detached.string("from_node") ?? "", "from_socket": detached.string("from_socket") ?? ""])
          }
          if current.output {
            model.send("link", ["from_node": current.node, "from_socket": current.socket,
                                "to_node": target.node, "to_socket": target.socket])
          }
          else {
            model.send("link", ["from_node": target.node, "from_socket": target.socket,
                                "to_node": current.node, "to_socket": current.socket])
          }
          return
        }
        if let detached = current.detached {
          /* Dropped away from any socket: disconnected. */
          model.send("unlink", ["to_node": detached.string("to_node") ?? "", "to_socket": detached.string("to_socket") ?? "",
                                "from_node": detached.string("from_node") ?? "", "from_socket": detached.string("from_socket") ?? ""])
          return
        }
        let location = CGPoint(x: value.location.x / nodeScale, y: -value.location.y / nodeScale)
        adding = NodeAddRequest(location: current.output ? location : CGPoint(x: location.x - 160, y: location.y),
                                connect: ["node": current.node, "socket": current.socket, "output": current.output ? 1 : 0])
      })
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

struct NodeCard: View {
  let model: NodeEditorModel
  let layout: NodeCanvasLayout
  let node: JSON
  let width: CGFloat
  let wire: (JSON, JSON, Bool) -> AnyGesture<DragGesture.Value>
  /** Dragging the header moves the node, and the other selected nodes with it. */
  let move: AnyGesture<DragGesture.Value>

  private var name: String { node.string("name") ?? "" }
  private var fields: [JSON] { node.array("fields") }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
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
            NodeFieldRows(store: model.store, fields: own)
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
    .background(PanelStyle.card.opacity(1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .background(Color(uiColor: .systemBackground).opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(node.bool("active") ? Color.accentColor : node.bool("selected") ? Color.accentColor.opacity(0.6) : Color.black.opacity(0.15),
                      lineWidth: node.bool("selected") ? 2.5 : 1)
    }
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
        NodeFieldRows(store: model.store, fields: values)
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
    .accessibilityLabel((output ? "Output " : "Input ") + (socket.string("name") ?? ""))
  }
}

private extension Dictionary where Key == String, Value == Any {
  var socketID: String { string("id") ?? "" }
}

/** A node's controls, laid out as Properties lays out a panel's. */
struct NodeFieldRows: View {
  let store: InspectorStore
  let fields: [JSON]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Self.rows(fields)) { row in
        switch row.kind {
          case .property(let property):
            PropertyRow(store: store, property: property)
          case .vector(let title, let items):
            VectorRow(store: store, title: title, items: items)
          case .toggles(let caption, let items):
            ToggleGroupRow(store: store, caption: caption, items: items)
          case .composite(let property):
            CompositeRow(store: store, property: property)
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
struct NodeAddSheet: View {
  let items: [JSON]
  let pick: (JSON) -> Void
  @State private var query = ""

  private var categories: [(String, [JSON])] {
    let filtered = items.filter {
      query.isEmpty || ($0.string("name") ?? "").localizedCaseInsensitiveContains(query) ||
        ($0.string("description") ?? "").localizedCaseInsensitiveContains(query)
    }
    let grouped = Dictionary(grouping: filtered) { $0.string("category") ?? "Other" }
    let order = ["Input", "Output", "Shader", "Texture", "Color", "Vector", "Converter", "Geometry", "Attribute",
                 "Filter", "Matte", "Distort", "Pattern", "Group", "Layout", "Interface", "Script", "Other"]
    return grouped.sorted { (order.firstIndex(of: $0.key) ?? 99, $0.key) < (order.firstIndex(of: $1.key) ?? 99, $1.key) }
      .map { ($0.key, $0.value.sorted { ($0.string("name") ?? "") < ($1.string("name") ?? "") }) }
  }

  var body: some View {
    NavigationStack {
      List {
        ForEach(categories, id: \.0) { category, entries in
          Section(category) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, item in
              Button {
                pick(item)
              } label: {
                VStack(alignment: .leading, spacing: 2) {
                  Text(item.string("name") ?? "").foregroundStyle(.primary)
                  if let description = item.string("description"), !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                  }
                }
              }
            }
          }
        }
      }
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
      .navigationTitle("Add Node")
      .navigationBarTitleDisplayMode(.inline)
    }
  }
}

/** \} */

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
              DragGesture()
                .onChanged { value in
                  let start = dragStart ?? fraction
                  dragStart = start
                  fraction = min(0.9, max(0.25, start - value.translation.height / max(proxy.size.height, 1)))
                }
                .onEnded { _ in dragStart = nil })
            .accessibilityLabel("Resize Node Editor")
          NodeEditorPanel(model: nodes)
        }
        .frame(height: proxy.size.height * fraction)
        .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24,
                                                                  style: .continuous))
        .padding(.leading, model.sideInsets.left)
        .padding(.trailing, model.sideInsets.right)
      }
    }
    .ignoresSafeArea(edges: .bottom)
  }
}

/** \} */
