/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The document window's state, from the toolbar snapshot Blender publishes: its mode, tools,
 * quick actions, brushes and undo. Each part changes on its own, so the views showing one part
 * do not redraw when another changes. Edits go to Blender's inbox; the next snapshot confirms
 * them.
 */

import SwiftUI
import UIKit

extension NativeUI.TransformSettings {
  /** By the names the top bar's menus look them up by, which are the snapshot's. */
  var byName: [String: String] {
    var names = ["orientation": orientation.rawValue, "pivot": pivot.rawValue, "snap": snap.rawValue,
                 "proportional": proportional.rawValue]
    if let mirrorAxes { names["mirror_axes"] = mirrorAxes }
    if let mirror { names["mirror"] = mirror }
    if let mirrorTopology { names["mirror_topology"] = mirrorTopology.rawValue }
    return names
  }
}

@MainActor
@Observable
final class ShellModel {
  /** Blender's window, `GHOST_WindowIOS *`, until Blender closes it. */
  @ObservationIgnored var window: UnsafeMutableRawPointer?

  /** The editing mode, such as `object`, `mesh_edit` or `sculpt`. */
  private(set) var mode = ""
  /** Blender's tools for the mode, in groups: `nil` separates two groups. */
  private(set) var tools: [NativeUI.Tool?] = []
  private(set) var activeTool = ""
  /** The active object's name, or the active bone's in an armature's modes, as Rename Active has
   * it. */
  private(set) var activeName = ""
  private(set) var actions: [NativeUI.Action] = []
  /** Changes when what Blender's menus show may have: the active undo step moves with every
   * change an operator makes, once per action. */
  private(set) var menuContext = ""
  private(set) var brushes: JSON?
  /** The brush's size, strength and color, and Dyntopo's detail, see `bl_ui.native_brush`. */
  private(set) var brush: JSON?
  /** Which way brushes stroke, in modes that paint with them; none where Blender selects. */
  private(set) var direction: NativeUI.BrushDirection?
  /** Moving, turning or scaling: the sidebar's + and - hold Snap and Precision. */
  private(set) var transforming = false
  /** A command waiting for a drag in the view, as Box Select chosen from the menu bar: what to
   * do, and whether it ends with Done. */
  private(set) var dragHint: NativeUI.DragHint?
  private(set) var canUndo = false
  private(set) var canRedo = false
  /** Adjust Last Operation: the last operator's settings, or none. */
  private(set) var redo: JSON?
  /** An operator's settings, asked for before it runs in place of Blender's dialog, or none. */
  private(set) var dialog: JSON?
  /** The text object being typed into: its style where the cursor is, alignment and font file. */
  private(set) var textObject: JSON?
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
  private(set) var navigationGizmo: [Double] = []
  /** The color the viewport is cleared to, as red, green and blue in display space. */
  private(set) var viewportBackground: [Double] = []
  /** The modes the active object has, as Blender's header lists them, and the current one. */
  private(set) var modes: [NativeUI.ModeItem] = []
  private(set) var objectMode = "OBJECT"
  /** The viewport's shading: `wireframe`, `solid`, `material` or `rendered`. */
  private(set) var shading = "solid"
  /** In mesh edit mode: `VERT`, `EDGE` or `FACE`. */
  private(set) var meshSelectMode = "VERT"
  /** Transform orientation, pivot, snapping and proportional editing. */
  private(set) var transformSettings: [String: String] = [:]
  /** The viewport's overlays, X-Ray, gizmos, statistics and wireframe toggles. */
  private(set) var viewport: JSON?
  /** The active tool's settings, which the top bar shows, and whether it has any. */
  private(set) var toolSettingsShown = false
  /** Blender's own interface is showing, as on a desktop computer. */
  private(set) var desktop = false
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
  /** The bottom of the top bar, in the window: controls along the top edge rest below it. */
  var topBarBottom: CGFloat = 0
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
  /** The room the toolbar leaves for the tool settings strip between its other items. */
  var toolStripRoom: CGFloat = 320
  /** A narrow window, such as a phone's: the toolbar keeps its most used items and puts the rest
   * in one menu. */
  var compact = false
  /** The viewport shading and tool settings popovers are open. */
  var shadingOpen = false
  var toolSettingsOpen = false
  /** One finger uses the active tool rather than orbiting the view. */
  var fingerUsesTool = false

  /** Parts of the snapshot that other objects show: the render sheet, settings and tool settings,
   * which says whether the tool has any. */
  @ObservationIgnored var onRender: ((Any?) -> Void)?
  @ObservationIgnored var onPreferences: ((Any?) -> Void)?
  @ObservationIgnored var onToolSettings: ((JSON, NSNumber) -> Bool)?

  init(window: UnsafeMutableRawPointer?) {
    self.window = window
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

  /** The toolbar snapshot, Blender's latest or a copy of it. */
  func update(toolbar: NativeUI.Toolbar) {
    set(\.mode, toolbar.mode)
    set(\.activeName, toolbar.activeName ?? "")
    set(\.tools, toolbar.tools)
    set(\.activeTool, toolbar.active ?? "")
    set(\.actions, toolbar.actions)
    set(\.brushes, toolbar.brushes.dictionary, equal: { jsonEqual($0, $1) })
    set(\.direction, toolbar.direction)
    set(\.transforming, toolbar.transforming)
    set(\.dragHint, toolbar.dragHint)
    set(\.brush, toolbar.brush.dictionary, equal: { jsonEqual($0, $1) })
    set(\.canUndo, toolbar.canUndo)
    set(\.canRedo, toolbar.canRedo)
    set(\.menuContext, "\(toolbar.objectMode.rawValue)|\(toolbar.menuState ?? "")")
    set(\.redo, toolbar.redo.dictionary, equal: { jsonEqual($0, $1) })
    set(\.dialog, toolbar.dialog.dictionary, equal: { jsonEqual($0, $1) })
    set(\.textObject, toolbar.textObject.dictionary, equal: { jsonEqual($0, $1) })
    if toolbar.navigationGizmo.count == 3 { set(\.navigationGizmo, toolbar.navigationGizmo.map(Double.init)) }
    if toolbar.viewportBackground.count == 3 {
      set(\.viewportBackground, toolbar.viewportBackground.map(Double.init))
    }
    if !toolbar.modes.isEmpty { set(\.modes, toolbar.modes) }
    set(\.objectMode, toolbar.objectMode.rawValue)
    set(\.shading, toolbar.shading.rawValue)
    if let select = toolbar.meshSelectMode { set(\.meshSelectMode, select) }
    if let settings = toolbar.settings { set(\.transformSettings, settings.byName) }
    set(\.viewport, toolbar.viewport.dictionary, equal: { jsonEqual($0, $1) })
    onRender?(toolbar.render.value)
    onPreferences?(toolbar.preferences.value)
    if let settings = onToolSettings?(toolbar.toolSettings.dictionary ?? [:], toolbar.propertiesAck as NSNumber) {
      set(\.toolSettingsShown, settings)
    }
    set(\.desktop, toolbar.desktop)
  }

  /** Take Blender's toolbar snapshot when it changed, or copy it when `copy`. */
  func pullToolbar(copy: Bool = false) {
    guard let json = copy ? WM_native_ui_toolbar_copy_json() : WM_native_ui_toolbar_take_json()
    else { return }
    let data = Data(bytes: json, count: strlen(json))
    WM_native_ui_json_free(json)
    guard let object = try? JSONSerialization.jsonObject(with: data) as? JSON,
          let toolbar = NativeUI.Toolbar(json: object)
    else { return }
    update(toolbar: toolbar)
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
    if let size = model.brush?.dict("size")?.double("value") { line["brushSize"] = size }
    if let strength = model.brush?.dict("strength")?.double("value") { line["brushStrength"] = strength }
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
        WM_native_ui_tool_set_by_id(tool)
        action["tool"] = tool
      case 2:
        let key = next(2) == 0 ? "size" : "strength"
        guard let json = model.brush?.dict(key), let low = json.double("min"), let high = json.double("max") else { return }
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
        Engine.setting("object_mode", mode)
        action["mode"] = mode
    }
    Self.write(action, to: actions)
  }
}

/** \} */
