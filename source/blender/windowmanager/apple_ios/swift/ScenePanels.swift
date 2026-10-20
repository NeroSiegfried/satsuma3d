/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Properties and the Outliner, viewport shading and tool settings: their stores, which Blender's
 * snapshots fill, and whether the panels show. The window slides the Outliner and Properties in
 * from its sides, shows them as sheets on a phone, or on Apple Vision Pro opens them as windows of
 * their own.
 */

import SwiftUI
import UIKit

@MainActor
final class SwiftScenePanels {
  let inspector = InspectorStore(mode: .properties)
  /** The native node editor, which Blender's panel snapshots also feed. */
  let nodes = NodeEditorModel()
  /** The curve editor's curves, which the timeline shows. */
  var graphSnapshot: ((JSON) -> Void)?
  private let shading = InspectorStore(mode: .shading, tab: "SHADING")
  private let toolStrip = InspectorStore(mode: .toolStrip, tab: "TOOL")
  private let toolPopover = InspectorStore(mode: .toolPopover, tab: "TOOL")
  private(set) lazy var hierarchy = HierarchyStore { [weak self] request in self?.inspector.send(request) }

  private var showInspector = false
  private var showHierarchy = false
  /** A narrow window, where only one of Properties and the Outliner fits beside the viewport. */
  var narrow = false {
    didSet {
      if narrow && showInspector && showHierarchy { setHierarchyShown(false) }
    }
  }
  private var shadingVisible = false

  init() {
    inspector.visible = false
#if os(visionOS)
    Self.current = self
#endif
  }

  /* -------------------------------------------------------------------- */
  /** \name Panels
   * \{ */

  /** Whether Properties and the Outliner show, and a call when either changes. */
  var inspectorShown: Bool { showInspector }
  var hierarchyShown: Bool { showHierarchy }
  var panelsDidChange: (() -> Void)?

  func toggleInspector() {
#if os(visionOS)
    PanelWindows.toggle(.properties)
#else
    setInspectorShown(!showInspector)
#endif
  }

  func toggleHierarchy() {
#if os(visionOS)
    PanelWindows.toggle(.outliner)
#else
    setHierarchyShown(!showHierarchy)
#endif
  }

  /** Shown or closed, also by the system, as when a sheet is swiped away. */
  func setInspectorShown(_ shown: Bool) {
    guard shown != showInspector else { return }
    showInspector = shown
    if shown && narrow { showHierarchy = false }
    applyVisibility()
  }

  func setHierarchyShown(_ shown: Bool) {
    guard shown != showHierarchy else { return }
    showHierarchy = shown
    if shown && narrow { showInspector = false }
    applyVisibility()
  }

  func dismiss() {
#if os(visionOS)
    /* Windows of their own stay open beside the editor. */
    return
#endif
    showInspector = false
    showHierarchy = false
    applyVisibility()
  }

  private func applyVisibility() {
    if !showInspector { ColorPickerSession.active?.close() }
    inspector.visible = showInspector
    Engine.setting("native_panels", "\((showInspector ? 1 : 0) | (showHierarchy ? 2 : 0))")
    panelsDidChange?()
  }

  func updateSnapshot(_ snapshot: Any?) {
    guard let snapshot = snapshot as? JSON else { return }
    if let shadingSnapshot = snapshot.dict("shading"), shadingVisible {
      shading.update(snapshot: ["ack": snapshot["ack"] ?? 0, "error": snapshot["error"] ?? "",
                                "inspector": shadingSnapshot])
    }
    let ack = (snapshot["ack"] as? NSNumber)?.uint64Value ?? 0
    if let graph = snapshot.dict("graph") { graphSnapshot?(graph) }
    if let nodesSnapshot = snapshot.dict("nodes"), nodes.shown {
      nodes.update(nodesSnapshot, ack: ack)
    }
    if ack < inspector.sequence { return }
    if let nodes = snapshot["hierarchy"] as? [Any] {
      hierarchy.update(nodes: nodes.compactMap { $0 as? JSON }, status: snapshot.string("error") ?? "")
    }
    if showInspector, snapshot["inspector"] != nil {
      inspector.update(snapshot: snapshot)
    }
  }

  /** \} */

#if os(visionOS)
  /* -------------------------------------------------------------------- */
  /** \name Windows of their own
   *
   * On Apple Vision Pro, Properties and the Outliner open as windows beside the editor, which
   * the person can place, resize and keep open, instead of covering the viewport.
   * \{ */

  static weak var current: SwiftScenePanels?

  /** The panel a window shows: the same store as the editor's, so both stay in step. */
  func windowContent(_ kind: PanelWindow) -> AnyView {
    kind == .properties ? AnyView(InspectorPanel(store: inspector) {}) :
                          AnyView(HierarchyPanel(store: hierarchy) {})
  }

  func setWindow(_ kind: PanelWindow, open: Bool) {
    if kind == .properties { showInspector = open }
    else { showHierarchy = open }
    applyVisibility()
  }

  /** \} */
#endif

  /* -------------------------------------------------------------------- */
  /** \name Viewport shading
   * \{ */

  /** Viewport shading as a SwiftUI popover's content shows it: Blender sends its settings while
   * it is open. */
  func shadingContent(done: @escaping () -> Void) -> some View {
    NavigationStack {
      InspectorForm(store: shading)
        .tint(PanelStyle.tint)
        .navigationTitle("Viewport Shading")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) } }
    }
    /* A popover's size; a sheet on a phone, which it fills. */
    .frame(idealWidth: 400, idealHeight: 640)
    .sheetDetents()
  }

  func setShadingShown(_ shown: Bool) {
    guard shown != shadingVisible else { return }
    shadingVisible = shown
    if shown { shading.requestProperties() }
    else { ColorPickerSession.active?.close() }
    Engine.setting("native_shading_visible", shown ? "1" : "0")
  }

  /** \} */

  /* -------------------------------------------------------------------- */
  /** \name Tool settings
   * \{ */

  /** The tool's settings for the toolbar. Returns whether the tool has any. */
  func updateToolSettingsStores(_ settings: JSON, acknowledgement ack: NSNumber) -> Bool {
    let snapshot: JSON = ["inspector": settings, "ack": ack]
    toolStrip.update(snapshot: snapshot)
    toolPopover.update(snapshot: snapshot)
    return !toolStrip.sections.allSatisfy { $0.rows.isEmpty }
  }

  var toolStripStore: InspectorStore { toolStrip }

  /** All the tool's settings, in a popover from the toolbar. */
  func toolSettingsContent(done: @escaping () -> Void) -> some View {
    NavigationStack {
      InspectorForm(store: toolPopover)
        .tint(PanelStyle.tint)
        .navigationTitle("Tool Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) } }
    }
    /* A popover's size; a sheet on a phone, which it fills. */
    .frame(idealWidth: 320, idealHeight: 420)
    .sheetDetents()
  }

  /** \} */
}

#if os(visionOS)
/** The panels that open as windows of their own on Apple Vision Pro. */
enum PanelWindow: String, CaseIterable {
  case properties = "org.blender.window.properties"
  case outliner = "org.blender.window.outliner"
  case timeline = "org.blender.window.timeline"
  case nodes = "org.blender.window.nodes"
  case curves = "org.blender.window.curves"
  /** The scene live in 3D, see `VolumeView.swift`. */
  case volume = "org.blender.window.volume"

  var title: String {
    switch self {
    case .properties: "Properties"
    case .outliner: "Outliner"
    case .timeline: "Timeline"
    case .nodes: "Node Editor"
    case .curves: "Curves"
    case .volume: "3D Volume"
    }
  }
}

@MainActor
enum PanelWindows {
  /** Closes a panel's window, while it is open. */
  static var close: [PanelWindow: () -> Void] = [:]

  static func toggle(_ kind: PanelWindow) {
    if let close = close[kind] {
      close()
      return
    }
    open(kind)
  }

  /** Opens or closes a panel's window to match the editor, which shows or hides it. */
  static func set(_ kind: PanelWindow, open shown: Bool) {
    if shown == (close[kind] != nil) { return }
    if shown { open(kind) } else { close[kind]?() }
  }

  private static func open(_ kind: PanelWindow) {
    guard let request = UISceneSessionActivationRequest(hostingDelegateClass: PanelSceneDelegate.self,
                                                        id: kind.rawValue) else { return }
    UIApplication.shared.activateSceneSession(for: request) { _ in }
  }

  /** What the window shows, from the editor's own stores; nil without a document open. */
  static func content(_ kind: PanelWindow) -> AnyView? {
    switch kind {
      case .timeline: SwiftTimeline.current?.windowContent()
      case .curves: SwiftTimeline.current?.curvesWindowContent()
      default: SwiftScenePanels.current?.windowContent(kind)
    }
  }

  static func setOpen(_ kind: PanelWindow, _ open: Bool) {
    switch kind {
      case .timeline: SwiftTimeline.current?.setWindowOpen(open)
      case .curves: SwiftTimeline.current?.setCurvesShown(open)
      case .nodes: SwiftScenePanels.current?.nodes.setShown(open)
      case .volume: VolumeStore.shared.windowOpened(open)
      default: SwiftScenePanels.current?.setWindow(kind, open: open)
    }
  }
}

/** The panels as SwiftUI windows, which the person places around the editor. */
final class PanelSceneDelegate: NSObject, UIHostingSceneDelegate {
  static var rootScene: some Scene {
    panel(.properties, size: CGSize(width: 420, height: 760))
    panel(.outliner, size: CGSize(width: 360, height: 640))
    /* Wide and low, under the viewport. */
    panel(.timeline, size: CGSize(width: 1100, height: 96))
    /* The editors, wide, to set below or beside the viewport. */
    panel(.nodes, size: CGSize(width: 1100, height: 640))
    panel(.curves, size: CGSize(width: 1100, height: 520))
    /* The scene in 3D, to walk around. */
    Window(PanelWindow.volume.title, id: PanelWindow.volume.rawValue) {
      VolumeView()
    }
    .windowStyle(.volumetric)
    .defaultSize(width: Double(VolumeStore.size), height: Double(VolumeStore.size),
                 depth: Double(VolumeStore.size), in: .meters)
  }

  private static func panel(_ kind: PanelWindow, size: CGSize) -> some Scene {
    Window(kind.title, id: kind.rawValue) {
      PanelWindowContent(kind: kind)
    }
    .defaultSize(size)
    .windowResizability(.contentMinSize)
  }
}

struct PanelWindowContent: View {
  let kind: PanelWindow
  @Environment(\.dismissWindow) private var dismissWindow

  var body: some View {
    Group {
      if let content = PanelWindows.content(kind) {
        content
      }
    }
    .frame(minWidth: kind == .timeline ? 520 : kind == .nodes || kind == .curves ? 600 : 320,
           minHeight: kind == .timeline ? 64 : kind == .curves ? 320 : 420)
    .environment(\.panelInWindow, true)
    .tint(PanelStyle.tint)
    .onAppear {
      guard PanelWindows.content(kind) != nil else {
        /* Restored without a document open: there is nothing to show. */
        dismissWindow(id: kind.rawValue)
        return
      }
      PanelWindows.close[kind] = { dismissWindow(id: kind.rawValue) }
      PanelWindows.setOpen(kind, true)
    }
    .onDisappear {
      PanelWindows.close[kind] = nil
      PanelWindows.setOpen(kind, false)
    }
  }
}
#endif
