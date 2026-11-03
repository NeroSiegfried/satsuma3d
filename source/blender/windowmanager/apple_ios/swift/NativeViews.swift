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
  /** What it is subscribed with, again when resumed. */
  @ObservationIgnored var params: [String: NativeValue]
  /** Subscribed: Blender keeps it up to date. */
  @ObservationIgnored fileprivate(set) var subscription: UInt32 = 0
  /** The view's top node, once it arrived. */
  private(set) var top: NativeNode?
  @ObservationIgnored private var nodes: [String: NativeNode] = [:]
  @ObservationIgnored private var version: UInt32 = 0
  /** Counts the updates applied, to tell whether anything changed since. */
  @ObservationIgnored private(set) var revision = 0
  /** Why its latest command failed, until another works. */
  private(set) var error: String?
  /** Commands Blender has yet to answer. */
  @ObservationIgnored fileprivate var unanswered = 0
  /** Called once Blender answered every command sent, and the view shows what they did. */
  @ObservationIgnored var settled: (() -> Void)?

  fileprivate init(name: String, params: [String: NativeValue]) {
    self.name = name
    self.params = params
  }

  func node(_ key: String) -> NativeNode? { nodes[key] }

  /** The nodes under `node`, in order. */
  func children(of node: NativeNode) -> [NativeNode] { node.children.compactMap { nodes[$0] } }

  fileprivate func answered(_ failure: String?) {
    if error != failure { error = failure }
    unanswered = max(0, unanswered - 1)
    if unanswered == 0 { settled?() }
  }

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
    revision += 1
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

/** A canvas's records as Foundation values, as JSON would read them, see `records_add`: a record
 * as a dictionary of its values and its children by their labels, a group as a list, data as its
 * value. */
extension NativeView {
  func foundation(_ node: NativeNode) -> Any {
    switch node.kind {
      case .record:
        var result: [String: Any] = [:]
        if let record = node.content(Blender_NativeUI_Record.self) {
          for index in 0..<record.paramsCount {
            guard let param = record.params(at: index), let key = param.key else { continue }
            result[key] = Self.foundation(param)
          }
        }
        for child in children(of: node) { result[child.label] = foundation(child) }
        return result
      case .group:
        return children(of: node).map(foundation)
      default:
        guard let data = node.content(Blender_NativeUI_Data.self) else { return NSNull() }
        return Self.foundation(data) ?? NSNull()
    }
  }

  private static func foundation(_ holder: some NativeValueHolder) -> Any? {
    switch holder.valueType {
      case .boolvalue: return holder.value(type: Blender_NativeUI_BoolValue.self).map { NSNumber(value: $0.value) }
      case .intvalue: return holder.value(type: Blender_NativeUI_IntValue.self).map { NSNumber(value: $0.value) }
      case .floatvalue: return holder.value(type: Blender_NativeUI_FloatValue.self).map { NSNumber(value: $0.value) }
      case .textvalue: return holder.value(type: Blender_NativeUI_TextValue.self)?.value ?? ""
      case .floatsvalue:
        guard let values = holder.value(type: Blender_NativeUI_FloatsValue.self) else { return nil }
        return (0..<values.valueCount).map { NSNumber(value: values.value(at: $0)) }
      case .intsvalue:
        guard let values = holder.value(type: Blender_NativeUI_IntsValue.self) else { return nil }
        return (0..<values.valueCount).map { NSNumber(value: values.value(at: $0)) }
      case .textsvalue:
        guard let values = holder.value(type: Blender_NativeUI_TextsValue.self) else { return nil }
        return (0..<values.valueCount).compactMap { values.value(at: $0) }
      default: return nil
    }
  }
}

/** What holds a value: a parameter, or a node of data. */
protocol NativeValueHolder {
  var valueType: Blender_NativeUI_Value { get }
  func value<T: FlatbuffersInitializable>(type: T.Type) -> T?
}
extension Blender_NativeUI_Param: NativeValueHolder {}
extension Blender_NativeUI_Data: NativeValueHolder {}

/** A value for a view's parameter or a command. */
enum NativeValue {
  case bool(Bool)
  case int(Int64)
  case float(Double)
  case text(String)
  case floats([Double])
  case ints([Int64])
  case texts([String])

  /** A Foundation value, such as JSON reads: a number, a text, or a list of them. */
  init?(foundation value: Any) {
    switch value {
      case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): self = .bool(number.boolValue)
      case let number as NSNumber where CFNumberIsFloatType(number): self = .float(number.doubleValue)
      case let number as NSNumber: self = .int(number.int64Value)
      case let text as String: self = .text(text)
      case let texts as [String]: self = .texts(texts)
      case let numbers as [NSNumber] where numbers.allSatisfy({ !CFNumberIsFloatType($0) }):
        self = .ints(numbers.map(\.int64Value))
      case let numbers as [NSNumber]: self = .floats(numbers.map(\.doubleValue))
      default: return nil
    }
  }

  /** A dictionary of Foundation values as parameters, those of a dictionary in it named by both,
   * as `properties.type`, see `params_dictionary`. */
  static func params(_ dictionary: [String: Any], prefix: String = "") -> [String: NativeValue] {
    var result: [String: NativeValue] = [:]
    for (key, value) in dictionary {
      if let nested = value as? [String: Any] {
        result.merge(params(nested, prefix: prefix + key + ".")) { $1 }
      }
      else if let value = NativeValue(foundation: value) {
        result[prefix + key] = value
      }
    }
    return result
  }

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
      case .ints(let values):
        let vector = builder.createVector(values)
        return (.intsvalue, Blender_NativeUI_IntsValue.createIntsValue(&builder, valueVectorOffset: vector))
      case .texts(let values):
        let vector = builder.createVector(ofStrings: values)
        return (.textsvalue, Blender_NativeUI_TextsValue.createTextsValue(&builder, valueVectorOffset: vector))
    }
  }
}

/** The views this interface shows, and the commands it sends. */
@MainActor
final class NativeViews {
  static let shared = NativeViews()

  private var views: [UInt32: NativeView] = [:]
  private var lastCommand: UInt32 = 0
  /** The view each unanswered command was sent to. */
  private var sentTo: [UInt32: NativeView] = [:]
  /** Views written as text, see `checkViews`. */
  fileprivate var checked: [(String, NativeView)] = []
  /** Commands still to send to the first checked view, and how many were sent. */
  fileprivate var script: [(view: String?, target: String, op: Blender_NativeUI_Op, value: NativeValue?,
                            params: [String: NativeValue])] = []
  /** Views commands of the script were aimed at, besides the checked ones. */
  fileprivate var scriptViews: [String: NativeView] = [:]
  fileprivate var scriptSent = 0
  /** What a command answered, by its number, until taken with `outcome(of:)`. */
  private var acks: [UInt32: String?] = [:]
  /** Commands whose answers are kept for `outcome(of:)`. */
  private var answers = Set<UInt32>()

  /** Show a view: it fills in as Blender sends it. */
  func subscribe(_ name: String, params: [String: NativeValue] = [:]) -> NativeView {
    let view = NativeView(name: name, params: params)
    view.subscription = request(name, params: params)
    views[view.subscription] = view
    return view
  }

  func unsubscribe(_ view: NativeView) { pause(view) }

  fileprivate func resubscribe(_ view: NativeView) {
    pause(view)
    resume(view)
  }

  /** Stop Blender building a view while it is hidden; it keeps what it showed. */
  func pause(_ view: NativeView) {
    guard view.subscription != 0 else { return }
    views[view.subscription] = nil
    WM_native_ui_unsubscribe(view.subscription)
    view.subscription = 0
  }

  /** Have Blender build a paused view again, sent whole. */
  func resume(_ view: NativeView) {
    guard view.subscription == 0 else { return }
    view.subscription = request(view.name, params: view.params)
    views[view.subscription] = view
  }

  private static func write(_ params: [String: NativeValue], _ builder: inout FlatBufferBuilder) -> Offset {
    let offsets = params.map { key, value in
      let keyOffset = builder.create(string: key)
      let (type, valueOffset) = value.write(&builder)
      return Blender_NativeUI_Param.createParam(&builder, keyOffset: keyOffset, valueType: type, valueOffset: valueOffset)
    }
    return builder.createVector(ofOffsets: offsets)
  }

  private func request(_ name: String, params: [String: NativeValue]) -> UInt32 {
    var builder = FlatBufferBuilder(initialSize: 128)
    let paramsVector = Self.write(params, &builder)
    let viewOffset = builder.create(string: name)
    let subscribe = Blender_NativeUI_Subscribe.createSubscribe(&builder, viewOffset: viewOffset,
                                                               paramsVectorOffset: paramsVector)
    builder.finish(offset: subscribe)
    return builder.sizedByteArray.withUnsafeBufferPointer { bytes in
      WM_native_ui_subscribe(bytes.baseAddress!, bytes.count)
    }
  }

  /**
   * Send a command aimed at a node of `view`. Its number, for `outcome(of:)` when `answer`; the
   * view hears how it went either way.
   */
  @discardableResult
  func send(_ view: NativeView, target: String, op: Blender_NativeUI_Op = .set_, value: NativeValue? = nil,
            phase: Blender_NativeUI_Phase = .once, params: [String: NativeValue] = [:],
            answer: Bool = false) -> UInt32
  {
    lastCommand += 1
    let id = lastCommand
    sentTo[id] = view
    view.unanswered += 1
    if answer { answers.insert(id) }
    var builder = FlatBufferBuilder(initialSize: 128)
    let targetOffset = builder.create(string: target)
    let (valueType, valueOffset) = value?.write(&builder) ?? (.none_, Offset())
    let paramsVector = params.isEmpty ? Offset() : Self.write(params, &builder)
    let command = Blender_NativeUI_Command.createCommand(&builder, id: id, subscription: view.subscription,
                                                         targetOffset: targetOffset, op: op, valueType: valueType,
                                                         valueOffset: valueOffset, phase: phase,
                                                         paramsVectorOffset: paramsVector)
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
        sentTo.removeValue(forKey: ack.command)?.answered(ack.error)
        if answers.remove(ack.command) != nil { acks[ack.command] = .some(ack.error) }
      }
      writeCheckedViews()
    }
  }
}

/**
 * A canvas Blender sends as records while it shows, such as the curve editor, see
 * `bridge_canvas_command`: what it shows as JSON would read it, its state, and its edits.
 */
@MainActor
final class NativeCanvas {
  let view: NativeView
  private var taken = -1

  init(_ name: String) {
    view = NativeViews.shared.subscribe(name)
    NativeViews.shared.pause(view)
  }

  /** Blender reads it only while it shows. */
  func setShown(_ shown: Bool) {
    if shown { NativeViews.shared.resume(view) } else { NativeViews.shared.pause(view) }
  }

  /** What to show, as the canvas's query takes it. */
  func setState(_ state: [String: Any]) {
    NativeViews.shared.send(view, target: "state", params: NativeValue.params(state))
  }

  func edit(_ request: [String: Any]) {
    NativeViews.shared.send(view, target: "edit", op: .invoke, params: NativeValue.params(request))
  }

  /** What Blender shows now as JSON, if it changed since last taken. */
  func take() -> JSON? {
    guard let top = view.top, view.revision != taken else { return nil }
    taken = view.revision
    return view.foundation(top) as? JSON
  }
}

/** Blender's operators, run by name, from the `operators` view. */
@MainActor
enum Operators {
  private static let view = NativeViews.shared.subscribe("operators")

  /** Run an operator, such as `VIEW3D_OT_view_axis` or `view3d.view_axis`, with properties set, as
   * a button runs it. */
  static func run(_ name: String, _ properties: [String: NativeValue] = [:]) {
    NativeViews.shared.send(view, target: name, op: .invoke, params: properties)
  }
}

/** The scene as 3D geometry, for Apple Vision Pro and the AR preview: what is done to it, through
 * the `volume` view; its geometry comes apart, see `wm_apple_ios_volume.cc`. */
@MainActor
enum BlenderVolume {
  private static let view = NativeViews.shared.subscribe("volume")

  /** Blender gathers the geometry only while it shows. */
  static func setShown(_ shown: Bool) {
    NativeViews.shared.send(view, target: "", value: .bool(shown))
  }

  /** Select an object by its name only. */
  static func select(_ name: String) {
    NativeViews.shared.send(view, target: name, op: .activate)
  }

  /** Move an object by an offset in world space from where the move began. */
  static func move(_ name: String, by delta: SIMD3<Float>, phase: NativePhase) {
    NativeViews.shared.send(view, target: name, op: .move,
                            value: .floats([Double(delta.x), Double(delta.y), Double(delta.z)]), phase: phase)
  }
}

/** The interface's settings Blender keeps, from the `settings` view. */
@MainActor
enum BlenderSettings {
  private static let view = NativeViews.shared.subscribe("settings")

  static func set(_ name: String, _ value: NativeValue) {
    NativeViews.shared.send(view, target: name, op: .set_, value: value)
  }

  private static func node(_ key: String) -> NativeNode? {
    guard let top = view.top else { return nil }
    _ = top.children
    return view.node(key)
  }

  /** Blender's own interface shows, as on a desktop computer. */
  static var desktop: Bool { node("desktop")?.toggle?.value ?? false }
  static var keymap: String? { node("keymap")?.choice?.value }
}

/* -------------------------------------------------------------------- */
/** \name Checking views
 *
 * With `BLENDER_NATIVE_UI_VIEWS` in the environment, such as `properties:OBJECT,properties:TOOL`
 * (a view and its tab, a parameter as `preferences_list:list=addons`, or `menu:VIEW3D_MT_add` for
 * a menu by its name),
 * those views are shown to no one but written as text to `native_ui_record/views/` in the
 * temporary folder whenever they change, to check what Blender sends.
 *
 * With `BLENDER_NATIVE_UI_COMMANDS` too, such as `panel:OBJECT_PT_relations open;tabs set
 * MODIFIERS`, those commands are sent to the first of them one at a time, each once Blender
 * answered the one before: the view as it is after each is written as `<view>.<number>.txt`.
 * \{ */

extension NativeViews {
  /** Subscribe to the views to check, if any. */
  func checkViews() {
    guard let names = ProcessInfo.processInfo.environment["BLENDER_NATIVE_UI_VIEWS"] else { return }
    for entry in names.split(separator: ",") {
      let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
      /* A tab, or for a menu its name. */
      var params: [String: NativeValue] = parts.count > 1 ? ["tab": .text(parts[1])] : [:]
      if parts[0] == "menu", parts.count > 1 { params = ["route": .text(BlenderMenus.route(parts[1]))] }
      else if parts.count > 1, let equals = parts[1].firstIndex(of: "=") {
        params = [String(parts[1][..<equals]): .text(String(parts[1][parts[1].index(after: equals)...]))]
      }
      checked.append((String(entry), subscribe(parts[0], params: params)))
    }
    let ops: [String: Blender_NativeUI_Op] = [
      "set": .set_, "invoke": .invoke, "open": .open_, "close": .close, "activate": .activate,
      "rename": .rename, "move": .move, "add": .add, "remove": .remove,
      "keyframe_insert": .keyframeinsert, "keyframe_delete": .keyframedelete, "keyframes_clear": .keyframesclear,
    ]
    for command in (ProcessInfo.processInfo.environment["BLENDER_NATIVE_UI_COMMANDS"] ?? "").split(separator: ";") {
      let words = command.split(separator: " ", maxSplits: 2).map(String.init)
      guard words.count >= 2, let op = ops[words[1]] else { continue }
      /* Aimed at another view as `view>target`; parameters as `key=value,key=value`. */
      let aim = words[0].split(separator: ">", maxSplits: 1).map(String.init)
      var value: NativeValue?
      var params: [String: NativeValue] = [:]
      if words.count > 2 {
        if words[2].contains("=") {
          for pair in words[2].split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { params[parts[0]] = Self.value(parts[1]) }
          }
        }
        else {
          value = Self.value(words[2])
        }
      }
      script.append((aim.count == 2 ? aim[0] : nil, aim.last!, op, value, params))
    }
  }

  private static func value(_ text: String) -> NativeValue {
    if text == "true" || text == "false" { return .bool(text == "true") }
    if let number = Double(text) { return .float(number) }
    return .text(text)
  }

  /** Send the next command once Blender answered the one before, and wrote the view as it left it. */
  private func continueScript(_ name: String, _ view: NativeView, lines: [String]) {
    guard view.unanswered == 0, scriptSent <= script.count else { return }
    if scriptSent > 0 {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native_ui_record/views")
      let error = view.error.map { ["error: " + $0] } ?? []
      try? (error + lines).joined(separator: "\n").write(
        to: folder.appendingPathComponent("\(name).\(scriptSent).txt"), atomically: true, encoding: .utf8)
    }
    guard scriptSent < script.count else {
      scriptSent += 1
      return
    }
    let command = script[scriptSent]
    scriptSent += 1
    var target = view
    if let name = command.view {
      /* The checked view waits for it to be answered, and for what it changed. */
      let other = scriptViews[name] ?? subscribe(name)
      scriptViews[name] = other
      target = other
      view.unanswered += 1
      func wait() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          guard other.unanswered == 0 else { return wait() }
          /* Its error shows as the checked view's. */
          view.answered(other.error)
          self.writeCheckedViews()
        }
      }
      wait()
    }
    send(target, target: command.target, op: command.op, value: command.value, params: command.params)
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
      if !script.isEmpty && view === checked.first?.1 { continueScript(name, view, lines: lines) }
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
      case .data: line += " = \(view.foundation(node))"
      case .record:
        /* Its values, briefly. */
        let values = (view.foundation(node) as? JSON ?? [:]).filter { !($0.value is JSON || $0.value is [Any]) }
        line += " " + values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: " ").prefix(200)
      default: break
    }
    if !content.enabled { line += " [disabled]" }
    if content.role != .none_ { line += " [\(content.role)]" }
    if content.mixed { line += " [mixed]" }
    if content.animation != .none_ { line += " [\(content.animation)]" }
    lines.append(line)
    for child in view.children(of: node) {
      describe(child, in: view, depth: depth + 1, into: &lines)
    }
  }
}

/** \} */
