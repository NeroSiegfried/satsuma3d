/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Views Blender sends, kept up to date, see `WM_native_ui.h` and `protocol.fbs` in `native_ui/`.
 * The interface subscribes to the views it shows; Blender sends each whole once, then only the
 * nodes that changed. Each node keeps its own small buffer, read in place, and is observed on its
 * own, so a change redraws only the controls showing it.
 */

import Foundation
import Observation

typealias ProtocolNode = Blender_NativeUI_Node

/** A node of a view, with its children's keys. */
@MainActor
@Observable
final class NativeNode {
  let key: String
  /** The node as Blender last sent it. */
  private(set) var node: ProtocolNode
  private(set) var children: [String] = []

  init(key: String, node: ProtocolNode) {
    self.key = key
    self.node = node
  }

  fileprivate func update(_ node: ProtocolNode) {
    self.node = node
  }

  fileprivate func update(children: [String]) {
    if children != self.children { self.children = children }
  }
}

/** A view an interface subscribed to. */
@MainActor
@Observable
final class NativeView {
  let name: String
  @ObservationIgnored fileprivate(set) var subscription: UInt32 = 0
  /** The view's top node, once it arrived. */
  private(set) var top: NativeNode?
  @ObservationIgnored private var nodes: [String: NativeNode] = [:]
  @ObservationIgnored private var version: UInt32 = 0

  fileprivate init(name: String) {
    self.name = name
  }

  func node(_ key: String) -> NativeNode? { nodes[key] }

  /** The nodes under `node`, in order. */
  func children(of node: NativeNode) -> [NativeNode] { node.children.compactMap { nodes[$0] } }

  fileprivate func apply(_ update: Blender_NativeUI_Update) {
    if update.reset {
      nodes.removeAll(keepingCapacity: true)
    }
    else if update.version != version + 1 {
      /* A batch went missing: Blender sends everything again. */
      NativeViews.shared.resubscribe(self)
      return
    }
    version = update.version
    for index in 0..<update.nodesCount {
      guard let buffer = update.nodes(at: index) else { continue }
      /* Copied into a buffer of its own, which outlives the batch it came in. */
      var bytes = ByteBuffer(bytes: buffer.node)
      let node: ProtocolNode = getRoot(byteBuffer: &bytes)
      guard let key = node.key else { continue }
      if let existing = nodes[key] {
        existing.update(node)
      }
      else {
        nodes[key] = NativeNode(key: key, node: node)
      }
    }
    for index in 0..<update.childrenCount {
      guard let children = update.children(at: index), let parent = children.parent else { continue }
      nodes[parent]?.update(children: (0..<children.keysCount).compactMap { children.keys(at: $0) })
    }
    for index in 0..<update.removedCount {
      if let key = update.removed(at: index) { nodes[key] = nil }
    }
    if let topKey = update.top, top?.key != topKey { top = nodes[topKey] }
    else if update.reset, let topKey = top?.key { top = nodes[topKey] }
  }
}

/** A value for a view's parameter or a command. */
enum NativeValue {
  case bool(Bool)
  case int(Int64)
  case float(Double)
  case text(String)
  case floats([Double])

  fileprivate func write(_ builder: inout FlatBufferBuilder) -> (Blender_NativeUI_Value, Offset) {
    switch self {
      case .bool(let value):
        return (.boolvalue, Blender_NativeUI_BoolValue.createBoolValue(&builder, value: value))
      case .int(let value):
        return (.intvalue, Blender_NativeUI_IntValue.createIntValue(&builder, value: value))
      case .float(let value):
        return (.floatvalue, Blender_NativeUI_FloatValue.createFloatValue(&builder, value: value))
      case .text(let value):
        let text = builder.create(string: value)
        return (.textvalue, Blender_NativeUI_TextValue.createTextValue(&builder, valueOffset: text))
      case .floats(let values):
        let vector = builder.createVector(values)
        return (.floatsvalue, Blender_NativeUI_FloatsValue.createFloatsValue(&builder, valueVectorOffset: vector))
    }
  }
}

/** The views this interface shows, and the commands it sends. */
@MainActor
final class NativeViews {
  static let shared = NativeViews()

  private var views: [UInt32: NativeView] = [:]
  private var lastCommand: UInt32 = 0
  /** Views written as text, see `checkViews`. */
  fileprivate var checked: [(String, NativeView)] = []
  /** What a command answered, by its number, until taken with `outcome(of:)`. */
  private var acks: [UInt32: String?] = [:]

  /** Show a view: it fills in as Blender sends it. */
  func subscribe(_ name: String, params: [String: NativeValue] = [:]) -> NativeView {
    let view = NativeView(name: name)
    view.subscription = request(name, params: params)
    views[view.subscription] = view
    return view
  }

  func unsubscribe(_ view: NativeView) {
    views[view.subscription] = nil
    WM_native_ui_unsubscribe(view.subscription)
  }

  fileprivate func resubscribe(_ view: NativeView) {
    views[view.subscription] = nil
    WM_native_ui_unsubscribe(view.subscription)
    view.subscription = request(view.name, params: [:])
    views[view.subscription] = view
  }

  private func request(_ name: String, params: [String: NativeValue]) -> UInt32 {
    var builder = FlatBufferBuilder(initialSize: 128)
    let paramOffsets = params.map { key, value in
      let keyOffset = builder.create(string: key)
      let (type, valueOffset) = value.write(&builder)
      return Blender_NativeUI_Param.createParam(&builder, keyOffset: keyOffset, valueType: type, valueOffset: valueOffset)
    }
    let viewOffset = builder.create(string: name)
    let paramsVector = builder.createVector(ofOffsets: paramOffsets)
    let subscribe = Blender_NativeUI_Subscribe.createSubscribe(&builder, viewOffset: viewOffset,
                                                               paramsVectorOffset: paramsVector)
    builder.finish(offset: subscribe)
    return builder.sizedByteArray.withUnsafeBufferPointer { bytes in
      WM_native_ui_subscribe(bytes.baseAddress!, bytes.count)
    }
  }

  /**
   * Send a command aimed at a node of `view`. Its number, for `outcome(of:)`, when `answer`.
   */
  @discardableResult
  func send(_ view: NativeView, target: String, op: Blender_NativeUI_Op = .set_, value: NativeValue? = nil,
            phase: Blender_NativeUI_Phase = .once, answer: Bool = false) -> UInt32
  {
    var id: UInt32 = 0
    if answer {
      lastCommand += 1
      id = lastCommand
    }
    var builder = FlatBufferBuilder(initialSize: 128)
    let targetOffset = builder.create(string: target)
    let (valueType, valueOffset) = value?.write(&builder) ?? (.none_, Offset())
    let command = Blender_NativeUI_Command.createCommand(&builder, id: id, subscription: view.subscription,
                                                         targetOffset: targetOffset, op: op, valueType: valueType,
                                                         valueOffset: valueOffset, phase: phase)
    let commands = builder.createVector(ofOffsets: [command])
    builder.finish(offset: Blender_NativeUI_Commands.createCommands(&builder, commandsVectorOffset: commands))
    builder.sizedByteArray.withUnsafeBufferPointer { bytes in
      WM_native_ui_send(bytes.baseAddress!, bytes.count)
    }
    return id
  }

  /** How a command went, once Blender answered: nil while it has not, `.some(nil)` when it worked. */
  func outcome(of command: UInt32) -> String?? {
    acks.removeValue(forKey: command)
  }

  /** Apply the updates Blender sent since the last time, in order. */
  func pull() {
    while let batch = WM_native_ui_take_updates() {
      defer { WM_native_ui_buffer_free(batch) }
      var size = 0
      let data = WM_native_ui_buffer_data(batch, &size)
      /* Read in place: nodes kept are copied out, see `NativeView.apply`. */
      var bytes = ByteBuffer(assumingMemoryBound: UnsafeMutableRawPointer(mutating: data), capacity: size)
      let updates: Blender_NativeUI_Updates = getRoot(byteBuffer: &bytes)
      InterfaceTimings.measure("views.apply", bytes: size) {
        for index in 0..<updates.updatesCount {
          guard let update = updates.updates(at: index) else { continue }
          views[update.subscription]?.apply(update)
        }
      }
      for index in 0..<updates.acksCount {
        guard let ack = updates.acks(at: index) else { continue }
        acks[ack.command] = .some(ack.error)
      }
      writeCheckedViews()
    }
  }
}

/* -------------------------------------------------------------------- */
/** \name Checking views
 *
 * With `BLENDER_NATIVE_UI_VIEWS` in the environment, such as `properties:OBJECT,properties:TOOL`,
 * those views are shown to no one but written as text to `native_ui_record/views/` in the
 * temporary folder whenever they change, to check what Blender sends.
 * \{ */

extension NativeViews {
  /** Subscribe to the views to check, if any. */
  func checkViews() {
    guard let names = ProcessInfo.processInfo.environment["BLENDER_NATIVE_UI_VIEWS"] else { return }
    for entry in names.split(separator: ",") {
      let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
      let params: [String: NativeValue] = parts.count > 1 ? ["tab": .text(parts[1])] : [:]
      checked.append((String(entry), subscribe(parts[0], params: params)))
    }
  }

  /** Write the checked views as they are now. */
  func writeCheckedViews() {
    guard !checked.isEmpty else { return }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native_ui_record/views")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (name, view) in checked {
      guard let top = view.top else { continue }
      var lines: [String] = []
      describe(top, in: view, depth: 0, into: &lines)
      try? lines.joined(separator: "\n").write(to: folder.appendingPathComponent(name + ".txt"),
                                                atomically: true, encoding: .utf8)
    }
  }

  private func describe(_ node: NativeNode, in view: NativeView, depth: Int, into lines: inout [String]) {
    let content = node.node
    var line = String(repeating: "  ", count: depth) + "\(content.contentType) \(node.key)"
    if let label = content.label { line += " \"\(label)\"" }
    switch content.contentType {
      case .toggle: line += " = \(content.content(type: Blender_NativeUI_Toggle.self)?.value ?? false)"
      case .number: line += " = \(content.content(type: Blender_NativeUI_Number.self)?.value ?? 0)"
      case .choice: line += " = \(content.content(type: Blender_NativeUI_Choice.self)?.value ?? "")"
      case .textfield: line += " = \(content.content(type: Blender_NativeUI_TextField.self)?.value ?? "")"
      case .reference: line += " = \(content.content(type: Blender_NativeUI_Reference.self)?.name ?? "")"
      case .panel: line += (content.content(type: Blender_NativeUI_Panel.self)?.expanded ?? true) ? " (open)" : " (closed)"
      default: break
    }
    if !content.enabled { line += " [disabled]" }
    lines.append(line)
    for child in view.children(of: node) {
      describe(child, in: view, depth: depth + 1, into: &lines)
    }
  }
}

/** \} */
