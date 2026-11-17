/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The document window's state: around the viewport, from the `toolbar` view Blender sends (see
 * `bridge_toolbar_view_build`), its mode, tools, quick actions, brush and undo, each read from its
 * own node, so the views showing one part do not redraw when another changes; and the window's
 * own layout. Edits are commands to the view's nodes.
 */

import SwiftUI
import UIKit

/** A tool of the toolbar, or a group of them shown as the one used last. */
struct ToolItem: Equatable {
  var id: String
  var title: String?
  var icon: String?
  var symbol: String? = ""
  var description: String?
  /** The group's first tool, which names the group. */
  var group: String?
  /** The group's tools, with nils between sets of them. */
  var children: [ToolItem?] = []
}

/** A mode the active object can switch to. */
struct ModeItem: Equatable {
  let id: String
  let label: String?
  let icon: String?
}

/** Which way brushes stroke: their two directions, or none to choose. */
struct BrushDirection: Equatable {
  /** No direction to show. */
  var hidden = false
  /** A brush is active at all. */
  var brush = false
  var inverted = false
  var add: String?
  var subtract: String?
  var addSymbol: String?
  var subtractSymbol: String?
  /** Holding both smooths, as in Sculpt Mode. */
  var smooth = false
}

/** A command waiting for a drag in the view, as Box Select chosen from the menu bar. */
struct DragHint: Equatable {
  let text: String
  /** It ends with Done rather than after one drag. */
  let done: Bool
}

/** The style of a text object's text where the cursor is. */
struct TextObjectStyle: Equatable {
  var bold = false
  var italic = false
  var underline = false
  /** Its alignment, such as `LEFT`. */
  var align = ""
  var fontFile = ""
}

/** One of the brush's values, such as its size. */
struct BrushValue: Equatable {
  var value: Double
  var min: Double
  var max: Double
  var defaultValue: Double
  /** Pixels on screen, rather than a distance in the scene. */
  var pixels: Bool
  var label: String
}

/** The brush's size, strength, weight and color, where it has them. */
struct BrushSettings: Equatable {
  var values: [String: BrushValue] = [:]
  var color: [Double]?

  subscript(_ key: String) -> BrushValue? { values[key] }
}

@MainActor
@Observable
final class ShellModel {
  /** Blender's window, `GHOST_WindowIOS *`, until Blender closes it. */
  @ObservationIgnored var window: UnsafeMutableRawPointer?
  /** Blender's state around the viewport. */
  @ObservationIgnored let toolbar = NativeViews.shared.subscribe("toolbar")

  /** A node of the toolbar, observed as it comes and goes. */
  private func node(_ key: String) -> NativeNode? {
    guard let top = toolbar.top else { return nil }
    _ = top.children
    return toolbar.node(key)
  }

  private func data(_ key: String) -> Blender_NativeUI_Data? { node(key)?.content(Blender_NativeUI_Data.self) }
  private func flag(_ key: String) -> Bool { data(key)?.value(type: Blender_NativeUI_BoolValue.self)?.value ?? false }
  private func text(_ key: String) -> String? { data(key)?.value(type: Blender_NativeUI_TextValue.self)?.value }
  private func floats(_ key: String) -> [Double] {
    guard let value = data(key)?.value(type: Blender_NativeUI_FloatsValue.self) else { return [] }
    return (0..<value.valueCount).map { value.value(at: $0) }
  }

  /** Send a command to one of the toolbar's nodes. */
  func send(_ key: String, _ op: Blender_NativeUI_Op, _ value: NativeValue? = nil, phase: NativePhase = .once) {
    NativeViews.shared.send(toolbar, target: key, op: op, value: value, phase: phase)
  }

  /** The editing mode as Blender's context names it, such as `objectmode`, `mesh_edit` or `sculpt_mode`. */
  var mode: String { toolbar.top?.label ?? "" }
  /** Blender's tools for the mode, in groups: `nil` separates two groups. */
  var tools: [ToolItem?] {
    guard let list = node("tools") else { return [] }
    return toolbar.children(of: list).map { node in
      guard let choice = node.choice else { return nil }
      let options = choice.allOptions
      let item = ToolItem(id: choice.value ?? "", title: node.label, icon: node.icon,
                          description: node.node.description)
      guard node.key.hasPrefix("group:") else { return item }
      var group = item
      group.group = String(node.key.dropFirst("group:".count))
      group.children = options.map { option in
        option.value.map { ToolItem(id: $0, title: option.label, icon: option.icon, description: option.description) }
      }
      return group
    }
  }
  var activeTool: String { text("active_tool") ?? "" }
  /** Use another tool, by its id. */
  func setTool(_ id: String) { send("tools", .set_, .text(id)) }
  /** The active object's name, or the active bone's in an armature's modes, as Rename Active has
   * it. */
  var activeName: String { node("active_name").map { $0.content(Blender_NativeUI_TextField.self)?.value ?? "" } ?? "" }
  /** Quick actions for the mode, tool and selection. */
  var actions: [NativeNode] { node("actions").map { toolbar.children(of: $0) } ?? [] }
  /** Changes when what Blender's menus show may have: the active undo step moves with every
   * change an operator makes, once per action. */
  var menuContext: String { "\(objectMode)|\(text("menu_state") ?? "")" }
  /** The brushes the mode offers, from Blender's `brushes` view: the rows of its list. */
  @ObservationIgnored let brushesView = NativeViews.shared.subscribe("brushes")
  private var brushList: NativeNode? {
    guard let top = brushesView.top else { return nil }
    _ = top.children
    return brushesView.node("brushes")
  }
  var brushes: [NativeNode] { brushList.map { brushesView.children(of: $0) } ?? [] }
  var activeBrush: String { brushList?.list?.active ?? "" }
  /** Their libraries or previews are still loading. */
  var brushesLoading: Bool { brushList?.list?.loading ?? false }
  /** Paint with another brush, by its key. */
  func activateBrush(_ key: String) { NativeViews.shared.send(brushesView, target: key, op: .activate) }
  /** The brush's size, strength, weight and color, see `bl_ui.native_brush`. */
  var brush: BrushSettings? {
    var settings = BrushSettings()
    for name in ["size", "strength", "weight"] {
      guard let number = node("brush:" + name)?.number else { continue }
      settings.values[name] = BrushValue(value: number.value, min: number.softMin, max: number.softMax,
                                         defaultValue: number.defaultValue, pixels: number.unit == "px",
                                         label: node("brush:" + name)?.label ?? "")
    }
    if let color = node("brush:color")?.content(Blender_NativeUI_Color.self) {
      settings.color = (0..<color.valueCount).map { color.value(at: $0) }
    }
    return settings.values.isEmpty && settings.color == nil ? nil : settings
  }
  /** Set one of the brush's values: a drag's updates, then its end. */
  func setBrush(_ key: String, _ value: NativeValue, phase: NativePhase = .once) {
    send("brush:" + key, .set_, value, phase: phase)
  }
  /** Which way brushes stroke, in modes that paint with them; none where Blender selects. */
  var direction: BrushDirection? {
    guard let node = node("direction") else { return nil }
    let options = node.choice?.allOptions ?? []
    var direction = BrushDirection(hidden: !node.enabled, brush: options.count == 2, smooth: flag("smooth"))
    if options.count == 2 {
      direction.inverted = node.choice?.value == options[1].value
      direction.add = options[0].label
      direction.subtract = options[1].label
      direction.addSymbol = options[0].icon
      direction.subtractSymbol = options[1].icon
    }
    return direction
  }
  /** Stroke the other way, or back: the brush's first or second direction. */
  func setDirection(add: Bool) {
    guard let options = node("direction")?.choice?.allOptions, options.count == 2,
          let value = options[add ? 0 : 1].value else { return }
    send("direction", .set_, .text(value))
  }
  /** Moving, turning or scaling: the sidebar's + and - hold Snap and Precision. */
  var transforming: Bool { flag("transforming") }
  /** A command waiting for a drag in the view, as Box Select chosen from the menu bar: what to
   * do, and whether it ends with Done. */
  var dragHint: DragHint? {
    guard let node = node("drag_hint") else { return nil }
    return DragHint(text: node.label, done: node.content(Blender_NativeUI_Data.self)?
      .value(type: Blender_NativeUI_BoolValue.self)?.value ?? false)
  }
  /** Blender's latest short messages, as JSON, see #ShellMessages. */
  var notices: String { text("notices") ?? "" }
  /** The messages showing at the top of the viewport. */
  @ObservationIgnored let messages = ShellMessages()
  /** Run what a message's button names: `mode:<MODE>` or `action:<id>`. */
  /** While an operation waits: its name, or what Blender writes in the header for it. */
  var modalHint: String { text("modal_hint") ?? "" }

  /** What Blender decided shows after the last command, see #RevealCoordinator. */
  var reveal: String { text("reveal") ?? "" }

  func perform(_ target: String) {
    if RevealCoordinator.shared.perform(target) { return }
    if target.hasPrefix("mode:") {
      send("mode", .set_, .text(String(target.dropFirst(5))))
    }
    else if target.hasPrefix("action:") {
      send(target, .invoke)
    }
  }
  var canUndo: Bool { node("undo")?.enabled ?? false }
  var canRedo: Bool { node("redo")?.enabled ?? false }
  /** Repeat Last can run, and what it would repeat: "Repeat Extrude". */
  var canRepeat: Bool { node("repeat")?.enabled ?? false }
  var repeatTitle: String { node("repeat")?.label ?? "Repeat Last" }
  /** The text object being typed into: its style where the cursor is, alignment and font file. */
  var textObject: TextObjectStyle? {
    guard node("text") != nil else { return nil }
    return TextObjectStyle(bold: node("text:bold")?.toggle?.value ?? false,
                           italic: node("text:italic")?.toggle?.value ?? false,
                           underline: node("text:underline")?.toggle?.value ?? false,
                           align: node("text:align")?.choice?.value ?? "",
                           fontFile: data("text:font")?.value(type: Blender_NativeUI_TextValue.self)?.value ?? "")
  }

  /** Type into the text object, a line break for each new line. */
  func typeText(_ text: String) { send("text", .add, .text(text)) }
  /** Delete what is selected, or what is before the cursor. */
  func deleteText() { send("text", .remove) }
  /** Set the text object's style, alignment, spacing or size, by name, such as `bold`, `align` or
   * `size`; or its fonts, each line a face and its file, as `font=<path>`. */
  func setText(_ name: String, _ value: NativeValue) { send("text:" + name, .set_, value) }
  /** The native node editor shows over the bottom of the viewport. */
  var nodesShown = false
  /** How much of the window's bottom the node editor covers, which the viewport leaves out. */
  var nodesCover: CGFloat = 0
  /** While the node editor's handle is dragged, the viewport follows it without easing. */
  var nodesCoverDragging = false
  /** How much of the window's bottom the curve editor covers, likewise. */
  var curvesCover: CGFloat = 0
  /** The native Image Editor shows beside the viewport, a viewport of its own. */
  var imageShown = false
  /** Blender's navigation gizmo: its center and radius, in fractions of the window's width and
   * height (center) and width (radius). */
  var navigationGizmo: [Double] { floats("navigation_gizmo") }
  /** All the navigation gizmo takes with its buttons, as fractions of the window from the top left:
   * left, top, right and bottom. */
  var navigationFootprint: [Double] { floats("navigation_footprint") }

  /** The navigation gizmo and its buttons in a window of \a size, or nil before Blender says. */
  func navigationFrame(in size: CGSize) -> CGRect? {
    let f = navigationFootprint
    guard f.count == 4 else {
      let g = navigationGizmo
      guard g.count == 3 else { return nil }
      let r = g[2] * size.width
      return CGRect(x: g[0] * size.width - r, y: g[1] * size.height - r, width: r * 2, height: r * 2)
    }
    return CGRect(x: f[0] * size.width, y: f[1] * size.height,
                  width: (f[2] - f[0]) * size.width, height: (f[3] - f[1]) * size.height)
  }
  /** The color the viewport is cleared to, as red, green and blue in display space. */
  var viewportBackground: [Double] { floats("viewport_background") }
  /** The modes the active object has, as Blender's header lists them, and the current one. */
  var modes: [ModeItem] {
    node("mode")?.choice?.allOptions.compactMap { option in
      option.value.map { ModeItem(id: $0, label: option.label, icon: option.icon) }
    } ?? []
  }
  var objectMode: String { node("mode")?.choice?.value ?? "OBJECT" }
  /** The viewport's shading: `wireframe`, `solid`, `material` or `rendered`. */
  var shading: String { text("shading") ?? "solid" }
  /** In mesh edit mode: `VERT`, `EDGE` or `FACE`. */
  var meshSelectMode: String { node("select_mode")?.choice?.value ?? "VERT" }
  /** Transform orientation, pivot, snapping and proportional editing, and the mode's mirror axes,
   * by name: `mirror_axes` the axes there are and `mirror` those on, as letters. */
  var transformSettings: [String: String] {
    var settings: [String: String] = [:]
    for name in ["orientation", "pivot", "snap", "proportional"] {
      if let value = node(name)?.choice?.value { settings[name] = value }
    }
    if let mirror = node("mirror")?.choice {
      settings["mirror_axes"] = mirror.allOptions.compactMap(\.value).joined()
      settings["mirror_label"] = node("mirror")?.label ?? "Mirror"
      settings["mirror"] = (mirror.value ?? "").replacingOccurrences(of: ",", with: "")
    }
    if let topology = node("mirror_topology")?.toggle {
      settings["mirror_topology"] = topology.value ? "on" : "off"
    }
    return settings
  }
  /** The viewport's overlays, X-Ray, gizmos, statistics and wireframe toggles, and whether it
   * looks through the camera, by name. */
  func viewportOption(_ name: String) -> Bool { node("viewport:" + name)?.toggle?.value ?? false }
  var viewportOptionsShown: Bool { node("viewport:overlays") != nil }
  /** Blender's own interface is showing, as on a desktop computer. */
  var desktop: Bool { BlenderSettings.desktop }
  /** Blender's viewport has shown its first frame. */
  private(set) var viewportReady = false
  private(set) var documentsAvailable = false
#if os(visionOS)
  /** The window shows, not the launcher: a hidden window's ornaments still show there. */
  private(set) var windowVisible = true
#endif
  /** The window's safe area, without the toolbar's: controls laid out over the whole window,
   * such as the view pie, keep to it. */
  var safeAreaInsets = UIEdgeInsets.zero
  /** The window's sides, such as a phone's toolbar column: the viewport runs under them, and the
   * controls over it keep beside them. */
  var sideInsets = UIEdgeInsets.zero
  /** The bottom of the top bar, with the tool settings row under it, in the window: controls along
   * the top edge rest below it. */
  var topBarBottom: CGFloat = 0
  /** The header's own bottom, which the tool settings row hangs from. */
  var navigationBarBottom: CGFloat = 0
  /** The tool settings row's height, 0 while it is hidden; the window then measures again. */
  var toolRowHeight: CGFloat = 0 {
    didSet { if toolRowHeight != oldValue { toolRowChanged?() } }
  }
  @ObservationIgnored var toolRowChanged: (() -> Void)?
  /** The asset pane and timeline along the bottom: their height, which the controls resting on
   * the bottom edge rise above. */
  var bottomTray: CGFloat = 0
  /** Which panels show. */
  var inspectorShown = false
  var hierarchyShown = false
  var timelineShown = false
  var assetsShown = false
  /** Full screen: everything but the button that brings it back is hidden. */
  var interfaceHidden = false
  /** The tool rail's width, which the controls beside it keep clear of. */
  var toolRailWidth: CGFloat = 64
  /** A tool or brush row along the bottom, which the quick actions rise above. */
  var bottomRailHeight: CGFloat = 0
  /** The tool rail's frame in the window, which the action bar keeps clear of. */
  var toolsFrame: CGRect = .zero
  /** A narrow window, such as a phone's: the toolbar keeps its most used items and puts the rest
   * in one menu. */
  var compact = false
  /** The viewport shading and tool settings popovers are open. */
  var shadingOpen = false
  var toolSettingsOpen = false
  /** Search shows, see #CommandSearchSheet. */
  var searchOpen = false
  /** One finger uses the active tool rather than orbiting the view. */
  var fingerUsesTool = false

  /** The latest window's model, for commands sent from where no window is at hand. */
  static weak var current: ShellModel?

  init(window: UnsafeMutableRawPointer?) {
    self.window = window
    Self.current = self
  }

  /** Assign only a changed value: observers redraw on every assignment. */
  private func set<Value>(_ keyPath: ReferenceWritableKeyPath<ShellModel, Value>, _ value: Value,
                          equal: (Value, Value) -> Bool)
  {
    if !equal(self[keyPath: keyPath], value) { self[keyPath: keyPath] = value }
  }

  private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<ShellModel, Value>,
                                     _ value: Value)
  {
    set(keyPath, value, equal: ==)
  }

  /** Read without waiting for Blender: the presentation mailbox and the launcher. */
  func refreshWindowState() {
    if !viewportReady && wm_apple_ios_window_presented_frame(window) {
      viewportReady = true
    }
    set(\.documentsAvailable, wm_apple_ios_documents_available())
#if os(visionOS)
    set(\.windowVisible, wm_apple_ios_document_window_visible())
#endif
  }
}

/* -------------------------------------------------------------------- */
/** \name Soak testing
 *
 * Long sessions, see `release/ios/soak/run_soak.py`. Started with `BLENDER_SOAK` in the
 * environment, it writes every second what the native interface believes, beside the record
 * Blender keeps of the same things, so the two can be compared once the session ends. With
 * `BLENDER_SOAK_UI` too, it also drives Blender as the interface does: tools, brush values and
 * modes picked through the same calls.
 * \{ */

@MainActor
final class SoakProbe {
  static var shared: SoakProbe?

  private let model: ShellModel
  private let shell: ShellPanels
  private let samples: FileHandle
  private let actions: FileHandle
  private var timer: Timer?
  private var snapshots = 0
  private var lastSnapshot = Date()
  private var random: UInt64
  private var tick = 0
  private let drives: Bool

  static func start(model: ShellModel, shell: ShellPanels) {
    let environment = ProcessInfo.processInfo.environment
    guard shared == nil, environment["BLENDER_SOAK"] != nil else { return }
    let directory = NSTemporaryDirectory() + "soak/"
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    func open(_ name: String) -> FileHandle? {
      let path = directory + name
      FileManager.default.createFile(atPath: path, contents: nil)
      return FileHandle(forWritingAtPath: path)
    }
    guard let samples = open("native.jsonl"), let actions = open("native_actions.jsonl") else { return }
    let seed = UInt64(environment["BLENDER_SOAK_SEED"] ?? "") ?? 1
    let probe = SoakProbe(model: model, shell: shell, samples: samples, actions: actions, seed: seed,
                          drives: environment["BLENDER_SOAK_UI"] != nil)
    shared = probe
    probe.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
      MainActor.assumeIsolated { SoakProbe.shared?.sample() }
    }
  }

  private init(model: ShellModel, shell: ShellPanels, samples: FileHandle, actions: FileHandle, seed: UInt64,
               drives: Bool)
  {
    self.model = model
    self.shell = shell
    self.samples = samples
    self.actions = actions
    random = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    self.drives = drives
  }

  /** Blender published new snapshots, which the interface then took. */
  func snapshotsPublished() {
    snapshots += 1
    lastSnapshot = Date()
  }

  private func next(_ bound: Int) -> Int {
    /* SplitMix64, so a seed replays the same session. */
    random &+= 0x9E37_79B9_7F4A_7C15
    var z = random
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return Int((z ^ (z >> 31)) % UInt64(max(1, bound)))
  }

  private static func write(_ object: [String: Any], to file: FileHandle) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    file.write(data)
    file.write(Data([0x0A]))
  }

  /** The app's memory as the system counts it, in megabytes. */
  private static var footprint: Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
  }

  private func sample() {
    let timeline = shell.timeline.store
    var line: [String: Any] = [
      "t": Date().timeIntervalSince1970,
      "mode": model.mode,
      "objectMode": model.objectMode,
      "activeName": model.activeName,
      "tool": model.activeTool,
      "frame": timeline.frame.blender,
      "timelineVisible": timeline.visible,
      "canUndo": model.canUndo,
      "snapshots": snapshots,
      "snapshotAge": Date().timeIntervalSince(lastSnapshot),
      "memory": Self.footprint,
    ]
    if let size = model.brush?["size"]?.value { line["brushSize"] = size }
    if let strength = model.brush?["strength"]?.value { line["brushStrength"] = strength }
    Self.write(line, to: samples)
    tick += 1
    if drives, tick % 3 == 0 { drive() }
  }

  /** One thing the interface would do: a tool picked, a brush value set, or the mode changed. */
  private func drive() {
    var action: [String: Any] = ["t": Date().timeIntervalSince1970]
    switch next(4) {
      case 0, 1:
        let tools = model.tools.compactMap { $0?.id }
        guard !tools.isEmpty else { return }
        let tool = tools[next(tools.count)]
        model.setTool(tool)
        action["tool"] = tool
      case 2:
        let key = next(2) == 0 ? "size" : "strength"
        guard let setting = model.brush?[key] else { return }
        let low = setting.min, high = setting.max
        /* Within the slider's range, as dragging it gives. */
        let top = key == "size" ? min(high, max(low * 4, 200)) : high
        let value = low + (top - low) * Double(next(1000)) / 1000
        sendBrushValue(key, value, commit: true)
        action["brush"] = key
        action["value"] = value
      default:
        let modes = model.modes.map(\.id)
        guard !modes.isEmpty else { return }
        let mode = modes[next(modes.count)]
        model.send("mode", .set_, .text(mode))
        action["mode"] = mode
    }
    Self.write(action, to: actions)
  }
}

/** \} */
