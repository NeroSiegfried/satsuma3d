/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The document window's toolbar: back to the documents, the sidebar menu,
 * the editing mode, adding to the scene and the mesh selection mode; the active tool's settings in
 * the middle; then viewport shading, Properties, and Undo and Redo with Share and More. A phone keeps the
 * most used items and puts the rest in one menu.
 */

import SwiftUI
import UIKit

/** What the toolbar's menus do outside the window: presenting sheets, sharing and saving. */
@MainActor
final class ShellCommands {
  /** The open document's, for a check script's steps (`Snapshots.swift`). */
  static weak var current: ShellCommands?
  weak var presenter: UIViewController?
  var render: SwiftRender?
  var settings: SwiftSettings?
  let model: ShellModel
  let shell: ShellPanels
  /** Where the Share button is, for the share sheet's popover. */
  weak var shareSource: UIView?

  init(model: ShellModel, shell: ShellPanels) {
    self.model = model
    self.shell = shell
    Self.current = self
  }

  /** What one finger does in this window now, without keeping it as a choice. */
  func setFingerUsesTool(_ useTool: Bool) {
    model.fingerUsesTool = useTool
    wm_apple_ios_window_set_finger_tool(model.window, useTool)
  }

  /** The person chose what one finger does (the header's One Finger, a message's button): kept, as
   * Settings keeps it, so Settings, the Image Editor and the next launch agree (ROUND6 TOUCH-1). */
  func chooseFingerUsesTool(_ useTool: Bool) {
    SettingsModel.chooseFingerUsesTool(useTool)
    setFingerUsesTool(useTool)
  }

  func setInterfaceHidden(_ hidden: Bool) {
    withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.25)) {
      model.interfaceHidden = hidden
    }
#if !os(visionOS)
    presenter?.setNeedsStatusBarAppearanceUpdate()
#endif
  }

  func saveDocumentAs() {
    guard let document = wm_apple_ios_open_document() else { return }
    /* Save a copy wherever the person picks, as Files apps do for Save As: one function with
     * Blender's Save As and the refused write's Save a Copy (ROUND5 9D.2). */
    let save = { [weak self] in
      wm_apple_ios_save_document_as(self?.presenter)
    }
    /* Free space first (ROUND5 8I.5, decision 45): when it is low, the person chooses. */
    let space = SaveSpace.warning(forSavingAt: document.fileURL.path)
    guard space.first == "low", space.count == 5 else {
      if space.first != "room" { WM_native_ui_log("save", "free space unknown") }
      save()
      return
    }
    WM_native_ui_log("save", space[1])
    let alert = UIAlertController(title: space[1], message: space[2], preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: space[4], style: .cancel))
    alert.addAction(UIAlertAction(title: space[3], style: .default) { _ in save() })
    presenter?.present(alert, animated: true)
  }

  func shareDocument() {
    guard wm_apple_ios_open_document() != nil else { return }
    /* Share the file as it is now: saved in place, or a fresh copy of the work when the document
     * cannot be written (ROUND6 SAFE-1), never the file as it was last written. */
    wm_apple_ios_share_document_file(presenter) { [weak self] url in
      guard let url else { return }
      let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      activity.popoverPresentationController?.sourceView = self?.shareSource
      self?.presenter?.present(activity, animated: true)
    }
  }

  func saveAsTemplate() {
    let alert = UIAlertController(title: "Save as Template", message: nil, preferredStyle: .alert)
    alert.addTextField { field in
      field.placeholder = "Template Name"
      field.text = "My Template"
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
      guard let self, let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
      else { return }
      let progress = UIViewController()
      progress.modalPresentationStyle = .formSheet
      progress.isModalInPresentation = true
      progress.preferredContentSize = CGSize(width: 320, height: 180)
      progress.view.backgroundColor = .systemBackground
      var loading = UIContentUnavailableConfiguration.loading()
      loading.text = "Saving Template"
      progress.contentUnavailableConfiguration = loading
      presenter?.present(progress, animated: true) {
        wm_apple_ios_save_template(name, ["timeline": self.model.timelineShown]) { error in
          progress.dismiss(animated: true) {
            let result = UIAlertController(
              title: error == nil ? "Template Saved" : "Could Not Save Template",
              message: error ?? "Available in My Templates when creating a new document.", preferredStyle: .alert)
            result.addAction(UIAlertAction(title: "OK", style: .default))
            self.presenter?.present(result, animated: true)
          }
        }
      }
    })
    presenter?.present(alert, animated: true)
  }
}

/* -------------------------------------------------------------------- */
/** \name Toolbar
 * \{ */

/** The transform tools, whose settings are the orientation, pivot, snapping and proportional
 * editing menus; Tweak moves things as they do. */
private let transformTools: Set<String> = ["builtin.move", "builtin.rotate", "builtin.scale", "builtin.scale_cage",
                                           "builtin.transform", "builtin.shear", "builtin.select"]

/** What a drag with Tweak does, in the transform settings while it is the tool: move things, and
 * turn them as Apple Pencil Pro rolls or tilts. Kept with the iPad's settings, and given to Blender,
 * which reads it as a drag begins. */
private struct TweakDragMenu: View {
  @AppStorage("BlenderTweakDrag") private var drag = "mrt"

  private func binding(_ letter: Character) -> Binding<Bool> {
    Binding(get: { drag.contains(letter) }, set: { on in
      var letters = drag.filter { $0 != letter }
      if on { letters.append(letter) }
      drag = String("mrt".filter { letters.contains($0) })
    })
  }

  var body: some View {
    Menu {
      Section("Dragging with Tweak") {
        Toggle(isOn: binding("m")) { Label("Move", systemImage: "arrow.up.and.down.and.arrow.left.and.right") }
        Toggle(isOn: binding("r")) { Label("Rotate by Rolling", systemImage: "rotate.right") }
        Toggle(isOn: binding("t")) { Label("Turn Over by Tilting", systemImage: "rotate.3d") }
      }
    } label: {
      Image(systemName: "applepencil.tip")
        .font(.system(size: 17, weight: .medium))
        .frame(width: 44, height: 44)
    }
    .onChange(of: drag, initial: true) { _, drag in
      let parts = [("m", "move"), ("r", "roll"), ("t", "tilt")].filter { drag.contains($0.0) }.map(\.1)
      BlenderSettings.set("tweak_drag", .text(parts.joined(separator: ",")))
    }
    .accessibilityLabel("Tweak Drag")
    .accessibilityValue([drag.contains("m") ? "Move" : nil, drag.contains("r") ? "Rotate" : nil,
                         drag.contains("t") ? "Turn Over" : nil].compactMap { $0 }.joined(separator: ", "))
    .accessibilityIdentifier("blender.setting.TweakDrag")
  }
}

private struct SettingOption {
  let title: String
  let symbol: String
  let value: String
  /** Blender's icon for it, as its header draws it. */
  var blender = ""
}

private struct TransformSetting {
  let key: String
  let title: String
  let symbol: String
  let options: [SettingOption]

  static let all = [
    TransformSetting(key: "orientation", title: "Transform Orientation", symbol: "rotate.3d", options: [
      SettingOption(title: "Global", symbol: "globe", value: "global", blender: "ORIENTATION_GLOBAL"),
      SettingOption(title: "Local", symbol: "cube", value: "local", blender: "ORIENTATION_LOCAL"),
      SettingOption(title: "Normal", symbol: "arrow.up.forward", value: "normal", blender: "ORIENTATION_NORMAL"),
      SettingOption(title: "Gimbal", symbol: "gyroscope", value: "gimbal", blender: "ORIENTATION_GIMBAL"),
      SettingOption(title: "View", symbol: "eye", value: "view", blender: "ORIENTATION_VIEW"),
      SettingOption(title: "Cursor", symbol: "scope", value: "cursor", blender: "ORIENTATION_CURSOR"),
      SettingOption(title: "Parent", symbol: "arrow.triangle.branch", value: "parent", blender: "ORIENTATION_PARENT"),
    ]),
    TransformSetting(key: "pivot", title: "Pivot Point", symbol: "viewfinder", options: [
      SettingOption(title: "Median Point", symbol: "circle.grid.cross", value: "median", blender: "PIVOT_MEDIAN"),
      SettingOption(title: "Bounding Box Center", symbol: "square.dashed", value: "bounds", blender: "PIVOT_BOUNDBOX"),
      SettingOption(title: "3D Cursor", symbol: "scope", value: "cursor", blender: "PIVOT_CURSOR"),
      SettingOption(title: "Individual Origins", symbol: "circle.grid.2x2", value: "individual", blender: "PIVOT_INDIVIDUAL"),
      SettingOption(title: "Active Element", symbol: "record.circle", value: "active", blender: "PIVOT_ACTIVE"),
    ]),
    TransformSetting(key: "snap", title: "Snapping", symbol: "magnet", options: [
      SettingOption(title: "Off", symbol: "magnet", value: "off", blender: "SNAP_OFF"),
      SettingOption(title: "Increment", symbol: "grid", value: "increment", blender: "SNAP_INCREMENT"),
      SettingOption(title: "Grid", symbol: "square.grid.3x3", value: "grid", blender: "SNAP_GRID"),
      SettingOption(title: "Vertex", symbol: "point.topleft.down.curvedto.point.bottomright.up", value: "vertex", blender: "SNAP_VERTEX"),
      SettingOption(title: "Edge", symbol: "line.diagonal", value: "edge", blender: "SNAP_EDGE"),
      SettingOption(title: "Face", symbol: "square", value: "face", blender: "SNAP_FACE"),
      SettingOption(title: "Volume", symbol: "cube.transparent", value: "volume", blender: "SNAP_VOLUME"),
    ]),
    TransformSetting(key: "proportional", title: "Proportional Editing", symbol: "circle.circle", options: [
      SettingOption(title: "Off", symbol: "circle", value: "off", blender: "PROP_OFF"),
      SettingOption(title: "On", symbol: "largecircle.fill.circle", value: "on", blender: "PROP_ON"),
      SettingOption(title: "Connected Only", symbol: "link.circle", value: "connected", blender: "PROP_CON"),
      SettingOption(title: "Projected", symbol: "square.3.layers.3d", value: "projected", blender: "PROP_PROJECTED"),
    ]),
  ]

  /** Snapping's targets, as its dropdown lists them beside the magnet. */
  static let snapElements = [
    SettingOption(title: "Increment", symbol: "grid", value: "increment", blender: "SNAP_INCREMENT"),
    SettingOption(title: "Absolute Grid", symbol: "square.grid.3x3", value: "grid", blender: "SNAP_GRID"),
    SettingOption(title: "Vertex", symbol: "smallcircle.filled.circle", value: "vertex", blender: "SNAP_VERTEX"),
    SettingOption(title: "Edge", symbol: "line.diagonal", value: "edge", blender: "SNAP_EDGE"),
    SettingOption(title: "Face", symbol: "square", value: "face", blender: "SNAP_FACE"),
    SettingOption(title: "Volume", symbol: "cube.transparent", value: "volume", blender: "SNAP_VOLUME"),
  ]

  /** Proportional editing's falloffs, as its dropdown lists them beside the circle. */
  static let falloffs = [
    SettingOption(title: "Smooth", symbol: "waveform.path", value: "SMOOTH", blender: "SMOOTHCURVE"),
    SettingOption(title: "Sphere", symbol: "circle", value: "SPHERE", blender: "SPHERECURVE"),
    SettingOption(title: "Root", symbol: "function", value: "ROOT", blender: "ROOTCURVE"),
    SettingOption(title: "Inverse Square", symbol: "function", value: "INVERSE_SQUARE", blender: "INVERSESQUARECURVE"),
    SettingOption(title: "Sharp", symbol: "function", value: "SHARP", blender: "SHARPCURVE"),
    SettingOption(title: "Linear", symbol: "line.diagonal", value: "LINEAR", blender: "LINCURVE"),
    SettingOption(title: "Constant", symbol: "minus", value: "CONSTANT", blender: "NOCURVE"),
    SettingOption(title: "Random", symbol: "dice", value: "RANDOM", blender: "RNDCURVE"),
  ]

  static func blenderImage(_ option: SettingOption) -> UIImage? {
    BlenderIcon.image(option.blender) ?? UIImage(systemName: option.symbol)
  }

  func image(_ option: SettingOption) -> UIImage? {
    BlenderIcon.image(option.blender) ?? wm_apple_ios_icon("setting.\(key).\(option.value)", option.symbol)
  }
}

/** Viewport options in the More menu, by Blender's name. */
struct ViewportToggle {
  let name: String
  let title: String
  /** Blender's icon, as in its viewport header; the symbol only where it has none. */
  let icon: String
  let symbol: String

  static let all = [
    ViewportToggle(name: "overlays", title: "Overlays", icon: "OVERLAY", symbol: "circle.dashed.inset.filled"),
    ViewportToggle(name: "xray", title: "X-Ray", icon: "XRAY", symbol: "square.on.square.intersection.dashed"),
    ViewportToggle(name: "gizmos", title: "Gizmos", icon: "GIZMO", symbol: "move.3d"),
    ViewportToggle(name: "statistics", title: "Statistics", icon: "INFO", symbol: "chart.bar"),
    ViewportToggle(name: "wireframe", title: "Wireframe", icon: "SHADING_WIRE", symbol: "cube"),
  ]
}

/** Blender's icon for an image, or the symbol, as a SwiftUI image. */
private func iconImage(_ image: UIImage?) -> Image {
  image.map { Image(uiImage: $0) } ?? Image(systemName: "questionmark")
}

struct DocumentToolbar: ToolbarContent {
  @Bindable var model: ShellModel
  let shell: ShellPanels
  let commands: ShellCommands
  @AppStorage(FaceControl.shownKey) private var faceControlShown = false
  @AppStorage(ShellStyle.key) private var style = ShellStyle.blender.rawValue

  var body: some ToolbarContent {
#if os(visionOS)
    items
#else
    /* In Blender's style the items sit on its header's grey, as its own header's buttons do,
     * without the system's glass around them. */
    items.sharedBackgroundVisibility(style == ShellStyle.glass.rawValue ? .automatic : .hidden)
#endif
  }

  /** What the header shows at its rung, see #HeaderLadder; the rest is in More. */
  private var shown: HeaderLadder.Shown { HeaderLadder.shows(model.headerRung) }

  @ToolbarContentBuilder
  private var items: some ToolbarContent {
    if model.documentsAvailable {
      /* Back to the documents is navigation, not a tool: its own glass, as the system's back
       * button. */
      ToolbarItem(placement: .topBarLeading) {
        Button("Documents", systemImage: "chevron.backward") {
          /* A move waiting for Enter or Escape would hold the document open: cancel it first. */
          if let model = ShellModel.current, model.transforming { wm_apple_ios_window_send_key(model.window, "ESC") }
          wm_apple_ios_show_documents(nil)
        }
          .accessibilityIdentifier("blender.documents")
      }
#if !os(visionOS)
      ToolbarSpacer(.fixed, placement: .topBarLeading)
#endif
    }
    if !model.documentStatus.isEmpty {
      /* The document is not saved: a standing line until a write succeeds or the person answers
       * (ROUND6 SAFE-1, SAFE-2). Tapping it says why again, with what can be done. */
      ToolbarItem(placement: .topBarLeading) {
        Button {
          wm_apple_ios_document_status_tapped()
        } label: {
          Label(model.documentStatus, systemImage: "exclamationmark.triangle.fill")
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.orange)
        }
          .accessibilityIdentifier("blender.document.status")
      }
    }
    if shown.fileEdit {
      ToolbarItem(placement: .topBarLeading) {
        HStack(spacing: 0) {
          fileButton
          editButton
        }
      }
#if !os(visionOS)
      ToolbarSpacer(.fixed, placement: .topBarLeading)
#endif
    }
    if shown.sidebar {
      ToolbarItem(placement: .topBarLeading) { sidebarMenu }
#if !os(visionOS)
      ToolbarSpacer(.fixed, placement: .topBarLeading)
#endif
    }
    ToolbarItemGroup(placement: .topBarLeading) {
      modeMenu
      Button("Assets", systemImage: "plus") { shell.assets.toggle() }
        .help("Assets")
        .accessibilityIdentifier("blender.assets")
    }
    if shown.editorMenus {
      /* Blender's header menus for the mode, as on the desktop: View, Select, Add, Object, or
       * Mesh, Vertex, Edge, Face and UV; as many as fit, the rest in one button at their end. */
      ToolbarItem(placement: .topBarLeading) { EditorMenus(sideBySide: model.headerMenus) }
    }
    /* Search, as F3: any command by its name. */
    ToolbarItem(placement: .topBarLeading) {
      Button("Search", systemImage: "magnifyingglass") { model.searchOpen = true }
        .help("Search")
        .accessibilityIdentifier("blender.search")
        .sheet(isPresented: $model.searchOpen) {
          CommandSearchSheet(model: model) { model.searchOpen = false }
            .sheetDetents()
        }
    }
    if model.hasMeshSelectMode && shown.selectMode {
#if os(visionOS)
      ToolbarItem(placement: .topBarLeading) { meshSelection }
#else
      ToolbarSpacer(.fixed, placement: .topBarLeading)
      ToolbarItem(placement: .topBarLeading) { meshSelection }
        .sharedBackgroundVisibility(.hidden)
#endif
    }
    trailingItems
  }

  /** The trailing side: shading and Properties, what can fold, then Undo, Redo and More. */
  @ToolbarContentBuilder
  private var trailingItems: some ToolbarContent {
    if shown.shading {
      ToolbarItem(placement: .topBarTrailing) { shadingButton }
#if !os(visionOS)
      ToolbarSpacer(.fixed, placement: .topBarTrailing)
#endif
    }
    if shown.properties {
      /* Properties slides in from the window's trailing edge. */
      ToolbarItem(placement: .topBarTrailing) {
        panelToggle("Properties", image: BlenderIcon.image("PROPERTIES"), isOn: model.inspectorShown,
                    identifier: "blender.inspector") { shell.panels.toggleInspector() }
      }
#if !os(visionOS)
      ToolbarSpacer(.fixed, placement: .topBarTrailing)
#endif
    }
    /* What can fold away comes first, so nothing after it moves when it does. */
    if shown.repeatLast || shown.share {
      ToolbarItemGroup(placement: .topBarTrailing) {
        if shown.repeatLast { repeatButton }
        if shown.share {
          Menu("Share", systemImage: "square.and.arrow.up") { shareMenu }
            .background(ShareSource(commands: commands))
            .accessibilityIdentifier("blender.share")
        }
      }
    }
    /* Undo, Redo and More last, at the window's trailing edge, at every width and in every mode:
     * Undo and Redo are tapped again and again, so they never move. */
    ToolbarItemGroup(placement: .topBarTrailing) {
      undoButton
      redoButton
      moreButton
    }
  }

  /** More: what the header has no room for at its rung, then the smaller things. */
  private var moreButton: some View {
    Menu("More", systemImage: "ellipsis") { overflowMenu }
      /* The share sheet points at More while Share is in it. */
      .background { if !shown.share { ShareSource(commands: commands) } }
      .prefetchingBlenderMenu(EditorMenus.route)
      .prefetchingBlenderMenu(Self.importRoute)
      .prefetchingBlenderMenu(Self.exportRoute)
      .prefetchingBlenderMenu(Self.externalDataRoute)
      .prefetchingBlenderMenu(Self.cleanUpRoute)
      .modifier(MorePopovers(model: model, shell: shell, shading: !shown.shading, toolSettings: model.compact))
      .accessibilityIdentifier("blender.actions")
  }

  /** A panel in the sidebar menu, with Blender's icon for its editor. */
  private func sidebarToggle(_ title: String, icon: UIImage?, isOn: Bool, toggle: @escaping () -> Void) -> some View {
    sidebarToggle(title, icon: icon, isOn: isOn) { (_: Bool) in toggle() }
  }

  /** `set` is given the state asked for, as the menu may show an older one than the panel's. */
  private func sidebarToggle(_ title: String, icon: UIImage?, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
    Toggle(isOn: Binding(get: { isOn }, set: set)) {
      Label { Text(title) } icon: { iconImage(icon) }
    }
  }

  private var undoButton: some View {
    Button { Operators.run("ED_OT_undo") } label: {
      Label { Text("Undo") } icon: { iconImage(wm_apple_ios_icon("operator.ED_OT_undo", "arrow.uturn.backward")) }
    }
    .disabled(!model.canUndo)
    .accessibilityIdentifier("blender.undo")
  }

  /** Blender's Ctrl+Shift+Z, in sight beside Undo: without a keyboard nothing else redoes. */
  private var redoButton: some View {
    Button { Operators.run("ED_OT_redo") } label: {
      Label { Text("Redo") } icon: { iconImage(wm_apple_ios_icon("operator.ED_OT_redo", "arrow.uturn.forward")) }
    }
    .disabled(!model.canRedo)
    .accessibilityIdentifier("blender.redo")
  }

  /** Repeat Last, as Shift+R: the last operation again, such as another copy moved as far. */
  private var repeatButton: some View {
    Button { model.send("repeat", .invoke) } label: {
      Label { Text(model.repeatTitle) } icon: { Image(systemName: "repeat") }
    }
    .disabled(!model.canRepeat)
    .help(model.repeatTitle)
    .accessibilityLabel(model.repeatTitle)
    .accessibilityIdentifier("blender.repeat")
  }

  /** The node editors, each opening the node editor on its tree, docked along the bottom, and the
   * UV Editor and the Image Editor beside the viewport: one panel in two modes, as in Blender, each
   * ticked while the panel shows it (ROUND5 9B.1). */
  @ViewBuilder
  private var nodeEditorToggles: some View {
    Section {
      ForEach([(NodeEditorModel.Kind.shader, "Shader Editor", "NODE_MATERIAL"),
               (.geometry, "Geometry Nodes", "GEOMETRY_NODES"),
               (.compositor, "Compositor", "NODE_COMPOSITING")], id: \.0) { kind, title, icon in
        let nodes = shell.panels.nodes
        sidebarToggle(title, icon: BlenderIcon.image(icon), isOn: model.nodesShown && nodes.kind == kind) {
          if model.nodesShown && nodes.kind == kind {
            nodes.setShown(false)
          }
          else {
            nodes.setKind(kind)
            nodes.setShown(true)
          }
        }
      }
      let image = shell.panels.image
      ForEach(ImageEditorModel.Mode.allCases) { mode in
        sidebarToggle(mode.title, icon: BlenderIcon.image(mode.icon), isOn: model.imageShown && image.mode == mode) {
          image.show(mode, $0)
        }
      }
    }
  }

  /** The editors with no form here (NLA, Drivers, the Text Editor and the rest), each opened in the
   * Desktop Interface full screen, with Back to Previous; Return to iPad Interface comes back to the
   * workspace this was on (ROUND6 EDIT-11, decision R6-15). */
  @ViewBuilder
  private var desktopEditors: some View {
    let editors = BlenderSettings.desktopEditors
    Section {
      Menu {
        ForEach(editors, id: \.value) { editor in
          Button {
            BlenderSettings.set("desktop_open", .text(editor.value ?? ""))
          } label: {
            Label { Text(editor.label ?? editor.value ?? "") } icon: { iconImage(BlenderIcon.image(editor.icon)) }
          }
          .accessibilityIdentifier("blender.desktop_open.\(editor.value ?? "")")
        }
      } label: {
        Label("Open in Desktop Interface", systemImage: "macwindow")
      }
      .disabled(editors.isEmpty)
      .accessibilityIdentifier("blender.desktop_open")
    }
  }

  /** The sidebar: its menu chooses what shows beside and below the viewport. */
  private var sidebarMenu: some View {
    Menu {
      sidebarToggle("Outliner", icon: BlenderIcon.image("OUTLINER"), isOn: model.hierarchyShown) {
        shell.panels.toggleHierarchy()
      }
      sidebarToggle("Timeline", icon: UIImage(named: "blender.time")?.withRenderingMode(.alwaysTemplate),
                    isOn: model.timelineShown) { shell.timeline.setVisible($0) }
      sidebarToggle("Asset Browser", icon: BlenderIcon.image("ASSET_MANAGER"), isOn: model.assetsShown) {
        shell.assets.toggle()
      }
      nodeEditorToggles
      desktopEditors
#if os(visionOS)
      Section {
        sidebarToggle("3D Volume", icon: UIImage(systemName: "cube.transparent"),
                      isOn: VolumeStore.shared.shown) { VolumeStore.shared.setShown($0) }
      }
#endif
    } label: {
      Label("Sidebar", systemImage: "sidebar.leading")
    }
    .accessibilityIdentifier("blender.sidebar")
  }

  static let importRoute = BlenderMenus.route("TOPBAR_MT_file_import")
  static let exportRoute = BlenderMenus.route("TOPBAR_MT_file_export")
  static let externalDataRoute = BlenderMenus.route("TOPBAR_MT_file_external_data")
  static let cleanUpRoute = BlenderMenus.route("TOPBAR_MT_file_cleanup")

  /** File, where a desktop user looks for it: saving a copy, and Blender's own Import and Export.
   * Documents save themselves, so there is no Save; going back to the documents keeps the work. */
  @ViewBuilder
  private var fileMenu: some View {
    Section {
      Button("Save As…", systemImage: "doc.on.doc") { commands.saveDocumentAs() }
      Button("Save as Template…", systemImage: "square.on.square") { commands.saveAsTemplate() }
      /* The file as it was when it was opened (ROUND6 SAFE-5): documents save themselves, so
       * this is the way back from a mistake found later. */
      Button("Restore Version from Opening…", systemImage: "clock.arrow.circlepath") {
        wm_apple_ios_restore_opening_version()
      }
    }
    /* Data-blocks from another .blend (ROUND6 FILES-4): the system picker for the file, then a
     * list of what it holds. Blender's own operators, which the iPad hands to that list. */
    Section {
      Button("Link…", systemImage: "link") { Operators.run("WM_OT_link") }
      Button("Append…", systemImage: "arrow.down.doc") { Operators.run("WM_OT_append") }
    }
    /* Blender's own Import and Export menus, so every format it and its add-ons support is
     * listed. Their file browsers open the system's document picker. */
    Section {
      Menu { BlenderMenuItems(route: Self.importRoute) } label: { blenderLabel("Import", "IMPORT") }
      Menu { BlenderMenuItems(route: Self.exportRoute) } label: { blenderLabel("Export", "EXPORT") }
      Button("Export All Collections", systemImage: "square.and.arrow.up.on.square") {
        Operators.run("WM_OT_collection_export_all")
      }
    }
    /* The File menu's housekeeping, Blender's own (ROUND6 FILES-7): packing and paths, missing
     * files, purging unused data, and going back to the file as last saved. */
    Section {
      Menu { BlenderMenuItems(route: Self.externalDataRoute) } label: { Text("External Data") }
      Menu { BlenderMenuItems(route: Self.cleanUpRoute) } label: { Text("Clean Up") }
      Button("Revert", systemImage: "arrow.counterclockwise") { Operators.run("WM_OT_revert_mainfile") }
    }
  }

  /** The File menu's button, first in the header after the documents, as on the desktop. */
  private var fileButton: some View {
    Menu { fileMenu } label: { Text("File") }
      .prefetchingBlenderMenu(Self.importRoute)
      .prefetchingBlenderMenu(Self.exportRoute)
      .prefetchingBlenderMenu(Self.externalDataRoute)
      .prefetchingBlenderMenu(Self.cleanUpRoute)
      .accessibilityIdentifier("blender.file")
  }

  /** Edit, as Blender's top bar has it, less its search entries (Search is in the header). */
  @ViewBuilder
  private var editMenu: some View {
    Section {
      Button("Undo", systemImage: "arrow.uturn.backward") { Operators.run("ED_OT_undo") }
        .disabled(!model.canUndo)
      Button("Redo", systemImage: "arrow.uturn.forward") { Operators.run("ED_OT_redo") }
        .disabled(!model.canRedo)
      Button("Undo History…", systemImage: "clock.arrow.circlepath") { Operators.run("ED_OT_undo_history") }
    }
    Section {
      Button(model.repeatTitle, systemImage: "repeat") { model.send("repeat", .invoke) }
        .disabled(!model.canRepeat)
      Button("Repeat History…", systemImage: "list.bullet") { Operators.run("SCREEN_OT_repeat_history") }
      Button("Adjust Last Operation…", systemImage: "slider.horizontal.3") { Operators.run("SCREEN_OT_redo_last") }
    }
    Section {
      Button("Rename Active Item…", systemImage: "pencil") {
        Operators.run("WM_OT_call_panel", ["name": .text("TOPBAR_PT_name"), "keep_open": .bool(false)])
      }
      Button("Batch Rename…", systemImage: "pencil.line") { Operators.run("WM_OT_batch_rename") }
    }
    Section {
      Button("Preferences…", systemImage: "gearshape") { commands.settings?.present() }
    }
  }

  private var editButton: some View {
    Menu { editMenu } label: { Text("Edit") }
      .accessibilityIdentifier("blender.edit")
  }

  /** Share: what leaves the document as it is, and its renders. */
  @ViewBuilder
  private var shareMenu: some View {
    Section {
      Button("Share…", systemImage: "square.and.arrow.up") { commands.shareDocument() }
    }
    Section {
      Button("Render Image", systemImage: "photo") { commands.render?.renderAnimation(false) }
      Button("Render Animation", systemImage: "film") { commands.render?.renderAnimation(true) }
      /* Every earlier render, in the render sheet's film strip. */
      Button("Renders", systemImage: "photo.stack") { commands.render?.showRenders() }
    }
  }

  private func blenderLabel(_ title: String, _ icon: String) -> some View {
    Label { Text(title) } icon: { iconImage(BlenderIcon.image(icon)) }
  }

  /** More's first part: every item the header's rung has moved out, in the header's order, so
   * nothing is in two places and nothing is missing; at the last rung also the view and the tool
   * settings, as a phone has no room for them elsewhere; One Finger at every rung. */
  @ViewBuilder
  private var overflowMenu: some View {
    if !shown.editorMenus {
      /* Blender's header menus, as one submenu each. */
      Section {
        ForEach((BlenderMenus.shared.items[EditorMenus.route] ?? []).filter { $0.submenu && !$0.disabled }) { item in
          Menu(item.title) { BlenderMenuItems(route: item.route) }
        }
      }
    }
    if !shown.sidebar || !shown.properties {
      Section {
        if !shown.sidebar {
          sidebarToggle("Outliner", icon: BlenderIcon.image("OUTLINER"), isOn: model.hierarchyShown) {
            shell.panels.toggleHierarchy()
          }
          sidebarToggle("Timeline", icon: UIImage(named: "blender.time")?.withRenderingMode(.alwaysTemplate),
                        isOn: model.timelineShown) { shell.timeline.setVisible($0) }
          sidebarToggle("Asset Browser", icon: BlenderIcon.image("ASSET_MANAGER"), isOn: model.assetsShown) {
            shell.assets.toggle()
          }
        }
        if !shown.properties {
          sidebarToggle("Properties", icon: BlenderIcon.image("PROPERTIES"), isOn: model.inspectorShown) {
            shell.panels.toggleInspector()
          }
        }
      }
      if !shown.sidebar { nodeEditorToggles }
    }
    if !shown.shading || model.headerRung == 0 {
      Section {
        if !shown.shading {
          Button("Viewport Shading", systemImage: "circle.lefthalf.filled") {
            shell.panels.showShadingTab("SHADING")
            model.shadingOpen = true
          }
          Button {
            shell.panels.showShadingTab("OVERLAYS")
            model.shadingOpen = true
          } label: {
            Label { Text("Overlays") } icon: { iconImage(BlenderIcon.image("OVERLAY")) }
          }
        }
        if model.headerRung == 0 {
          Menu {
            ForEach(ViewCommand.pie(locked: model.viewportOption("lock_camera"),
                                    kept: model.viewportOption("keep_camera_view"),
                                    camera: model.viewportOption("camera_view")), id: \.title) { command in
              Button { command.run() } label: { Label { Text(command.title) } icon: { iconImage(command.image) } }
            }
          } label: {
            Label("View", systemImage: "eye")
          }
        }
      }
    }
    /* What one finger does, at every rung (ROUND6 TOUCH-1): the same choice as Settings', kept. */
    Section {
      Menu {
        sidebarToggle("Use Tool", icon: wm_apple_ios_icon("control.finger_tool", "cursorarrow"),
                      isOn: model.fingerUsesTool) { commands.chooseFingerUsesTool(true) }
        sidebarToggle("Orbit View", icon: wm_apple_ios_icon("operator.VIEW3D_OT_rotate", "rotate.3d"),
                      isOn: !model.fingerUsesTool) { commands.chooseFingerUsesTool(false) }
      } label: {
        Label("One Finger", systemImage: "hand.point.up")
      }
    }
    Section {
      if model.hasMeshSelectMode && !shown.selectMode {
        Menu {
          ForEach([("VERT", "Vertex Select", "circle.fill"), ("EDGE", "Edge Select", "line.diagonal"),
                   ("FACE", "Face Select", "square.fill")], id: \.0) { value, title, symbol in
            sidebarToggle(title, icon: wm_apple_ios_icon("mesh.\(value)", symbol),
                          isOn: model.meshSelectMode == value) { model.send("select_mode", .set_, .text(value)) }
          }
        } label: {
          Label { Text("Select Mode") } icon: { iconImage(wm_apple_ios_icon("mesh.VERT", "circle.fill")) }
        }
      }
      /* The tool settings row is hidden in a compact window: its settings are here. */
      if model.compact {
        if transformTools.contains(model.activeTool) {
          /* Those Blender's header has in this mode (ROUND6 MODE-2). */
          ForEach(TransformSetting.all.filter { shell.panels.header.headerHas($0.key) }, id: \.key) { setting in
            Menu {
              ForEach(setting.options, id: \.value) { option in
                sidebarToggle(option.title, icon: setting.image(option),
                              isOn: model.transformSettings[setting.key] == option.value) {
                  model.send(setting.key, .set_, .text(option.value))
                }
              }
            } label: {
              Label { Text(setting.title) } icon: {
                iconImage(wm_apple_ios_icon("control.\(setting.title)", setting.symbol))
              }
            }
          }
        }
        /* The tool's settings, with the rest of Blender's header for the mode (ROUND6 MODE-1):
         * its popovers (Snapping, Selectability & Visibility) whatever the tool. */
        if shell.panels.tools.hasToolSettings || shell.panels.header.hasToolSettings {
          Button("Tool Settings", systemImage: "slider.horizontal.3") { model.toolSettingsOpen = true }
        }
        /* Mirror, X-Axis Mirror or Symmetry, in every mode whose header has it, whatever the tool. */
        if MirrorToggles.available(model) {
          Menu { MirrorToggles(model: model) } label: {
            Label { Text(model.transformSettings["mirror_label"] ?? "Mirror") } icon: {
              iconImage(BlenderIcon.image("MOD_MIRROR"))
            }
          }
          .accessibilityIdentifier("blender.setting.Mirror")
        }
      }
    }
    if !shown.fileEdit {
      Menu { fileMenu } label: { Label("File", systemImage: "doc") }
      Menu { editMenu } label: { Label("Edit", systemImage: "pencil") }
    }
    if !shown.share {
      Menu { shareMenu } label: { Label("Share", systemImage: "square.and.arrow.up") }
    }
    moreMenu
  }

  /** More: smaller things, with viewport options showing their current state. */
  @ViewBuilder
  private var moreMenu: some View {
    Button("New…", systemImage: "doc.badge.plus") {
      if let presenter = commands.presenter { wm_apple_ios_new_document(presenter) }
    }
#if !os(visionOS)
    if faceControlShown, model.brush?["size"] != nil || model.brush?["strength"] != nil {
      Section {
        /* The face plays the brush: the mouth its strength, the eyebrows its size. */
        sidebarToggle("Face Control", icon: UIImage(systemName: "face.smiling"),
                      isOn: FaceControl.shared.running) { FaceControl.shared.toggle() }
          .disabled(!FaceControl.supported)
      } footer: {
        if !FaceControl.supported {
          Text("Needs a front camera that tracks faces, as iPads with Face ID have.")
        }
      }
    }
    if ARPreviewState.supported {
      /* The scene in the room, through the camera. */
      Button("View in AR", systemImage: "arkit") { ARPreviewState.shared.shown = true }
    }
#endif
    Section {
      ForEach(ViewportToggle.all, id: \.name) { toggle in
        sidebarToggle(toggle.title, icon: BlenderIcon.image(toggle.icon) ?? UIImage(systemName: toggle.symbol),
                      isOn: model.viewportOption(toggle.name)) {
          model.send("viewport:" + toggle.name, .set_, .bool(!model.viewportOption(toggle.name)))
        }
        .disabled(!model.viewportOptionsShown)
      }
    }
    Section {
      Button("Hide Interface", systemImage: "arrow.up.left.and.arrow.down.right") {
        commands.setInterfaceHidden(true)
      }
      Button("Switch to Desktop Interface", systemImage: "macwindow") { BlenderSettings.set("desktop", .bool(true)) }
    }
    Button("Settings", systemImage: "gearshape") { commands.settings?.present() }
  }

  /* -------------------------------------------------------------------- */
  /* Mode */

  /** The modes the active object has, as Blender's header lists them. */
  private var modeMenu: some View {
    let current = model.modes.first { $0.id == model.objectMode }
    let title = current?.label ?? "Object Mode"
    return Menu {
      Picker("Mode", selection: Binding(
        get: { model.objectMode },
        set: { model.send("mode", .set_, .text($0)) })) {
        ForEach(Array(model.modes.enumerated()), id: \.offset) { _, mode in
          Label {
            Text(mode.label.flatMap { $0.isEmpty ? nil : $0 } ?? mode.id)
          } icon: {
            iconImage(BlenderIcon.image(mode.icon))
          }
          .tag(mode.id)
        }
      }
    } label: {
      Label {
        Text(title)
      } icon: {
        iconImage(BlenderIcon.image(current?.icon ?? "OBJECT_DATAMODE"))
      }
    }
    .accessibilityLabel("Mode")
    .accessibilityValue(title)
    .accessibilityIdentifier("blender.mode")
  }

  /* -------------------------------------------------------------------- */
  /* Mesh selection mode */

  private var meshSelection: some View {
    let modes = [("VERT", "Vertex Select", "circle.fill"), ("EDGE", "Edge Select", "line.diagonal"),
                 ("FACE", "Face Select", "square.fill")]
    return SegmentedControl(
      segments: modes.map { value, title, symbol in
        SegmentedControl.Segment(value: value, title: title, image: wm_apple_ios_icon("mesh.\(value)", symbol))
      },
      selection: model.meshSelectMode, accessibilityLabel: "Mesh Selection Mode")
    { model.send("select_mode", .set_, .text($0)) }
      .frame(width: 144, height: 36)
      .accessibilityIdentifier("blender.mesh-selection")
  }

  /* -------------------------------------------------------------------- */
  /* Tool settings */

  /* -------------------------------------------------------------------- */
  /* Panels and shading */

  private func panelToggle(_ title: String, image: UIImage?, isOn: Bool, identifier: String,
                           toggle: @escaping () -> Void) -> some View
  {
    Toggle(isOn: Binding(get: { isOn }, set: { _ in toggle() })) {
      Label { Text(title) } icon: { iconImage(image) }
    }
    .toggleStyle(.button)
    .accessibilityIdentifier(identifier)
  }

  private var shadingButton: some View {
    let commands: [String: (String, String)] = [
      "wireframe": ("Wireframe", "circle.dashed"), "solid": ("Solid", "cube"),
      "material": ("Material Preview", "circle.lefthalf.filled"), "rendered": ("Rendered", "camera.aperture"),
    ]
    let shading = commands[model.shading] == nil ? "solid" : model.shading
    let current = commands[shading]!
    return Button {
      shell.panels.showShadingTab("SHADING")
      model.shadingOpen = true
    } label: {
      Label { Text("Viewport Shading") } icon: { iconImage(wm_apple_ios_icon(shading == "solid" ? "control.shading" : "control.shading." + shading, current.1)) }
    }
    .accessibilityValue(current.0)
    .accessibilityIdentifier("blender.shading")
    .shadingPopover(model: model, shell: shell)
  }
}

extension View {
  /** Viewport shading's popover; Blender sends its settings while it is open. */
  func shadingPopover(model: ShellModel, shell: ShellPanels) -> some View {
    @Bindable var model = model
    return popover(isPresented: $model.shadingOpen) {
      shell.panels.shadingContent(model: model) { model.shadingOpen = false }
        .popoverSurface()
    }
    .onChange(of: model.shadingOpen) { _, shown in shell.panels.setShadingShown(shown) }
  }
}

/** Remembers the Share button's view, which the share sheet points at. */
private struct ShareSource: UIViewRepresentable {
  let commands: ShellCommands

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.isUserInteractionEnabled = false
    commands.shareSource = view
    return view
  }

  func updateUIView(_ view: UIView, context: Context) {}
}

/** \} */

/** The transform settings of Blender's header, in Object, Edit and Pose Mode whatever the tool, as
 * `draw_xform_template` draws them: orientation as its icon and name, pivot as its icon, snapping
 * and proportional editing each a toggle joined to a dropdown of what it uses. See #ToolSettingsRow. */
struct ToolSettingsTransformItems: View {
  @Bindable var model: ShellModel
  /** Which of them Blender's header has in this mode (ROUND6 MODE-2). */
  let parts: Set<String>

  private func picker(_ key: String, _ title: String, _ options: [SettingOption]) -> some View {
    let value = model.transformSettings[key]
    return Picker(title, selection: Binding(get: { value ?? "" }, set: { model.send(key, .set_, .text($0)) })) {
      ForEach(options, id: \.value) { option in
        Label { Text(option.title) } icon: { iconImage(TransformSetting.blenderImage(option)) }
          .tag(option.value)
      }
    }
  }

  private func option(_ options: [SettingOption], _ key: String) -> SettingOption? {
    options.first { $0.value == model.transformSettings[key] }
  }

  var body: some View {
    if model.activeTool == "builtin.select" {
      TweakDragMenu()
    }
    let all = TransformSetting.all
    let orientations = all[0].options, pivots = all[1].options
    let orientation = option(orientations, "orientation")
    if parts.contains("orientation") {
      BlenderDropdown(name: "Transform Orientation", icon: orientation.flatMap(TransformSetting.blenderImage),
                      text: orientation?.title ?? "Orientation") {
        picker("orientation", "Transform Orientation", orientations)
      }
      .accessibilityIdentifier("blender.setting.Transform Orientation")
    }
    let pivot = option(pivots, "pivot")
    if parts.contains("pivot") {
      BlenderDropdown(name: "Pivot Point: " + (pivot?.title ?? ""), icon: pivot.flatMap(TransformSetting.blenderImage)) {
        picker("pivot", "Pivot Point", pivots)
      }
      .accessibilityIdentifier("blender.setting.Pivot Point")
    }
    if parts.contains("snap"), let snapOn = model.transformSettings["snap_on"] {
      let on = snapOn == "on"
      let element = option(TransformSetting.snapElements, "snap_element")
      HStack(spacing: 1) {
        BlenderToggleButton(name: "Snap", icon: BlenderIcon.image(on ? "SNAP_ON" : "SNAP_OFF"), isOn: on,
                            join: .first) {
          model.send("snap_on", .set_, .text(on ? "off" : "on"))
        }
        BlenderDropdown(name: "Snap To: " + (element?.title ?? "Mix"),
                        icon: element.flatMap(TransformSetting.blenderImage),
                        text: element == nil ? "Mix" : nil, join: .last) {
          picker("snap_element", "Snap To", TransformSetting.snapElements)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("blender.setting.Snapping")
    }
    if parts.contains("proportional"), let proportionalOn = model.transformSettings["proportional_on"] {
      let on = proportionalOn == "on"
      let kind = model.transformSettings["proportional"] ?? "off"
      let falloff = option(TransformSetting.falloffs, "proportional_falloff")
      HStack(spacing: 1) {
        BlenderToggleButton(name: "Proportional Editing",
                            icon: BlenderIcon.image(!on ? "PROP_OFF" : kind == "connected" ? "PROP_CON" :
                                                      kind == "projected" ? "PROP_PROJECTED" : "PROP_ON"),
                            isOn: on, join: .first) {
          model.send("proportional_on", .set_, .text(on ? "off" : "on"))
        }
        BlenderDropdown(name: "Proportional Editing Falloff: " + (falloff?.title ?? ""),
                        icon: falloff.flatMap(TransformSetting.blenderImage), join: .last, dimmed: !on) {
          picker("proportional_falloff", "Falloff", TransformSetting.falloffs)
          Section {
            Picker("Proportional Editing", selection: Binding(get: { kind == "off" ? "on" : kind }, set: {
              model.send("proportional", .set_, .text($0))
            })) {
              Text("Connected Only").tag("connected")
              Text("Projected from View").tag("projected")
              Text("All").tag("on")
            }
          }
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("blender.setting.Proportional Editing")
    }
  }
}

/** The mode's mirror axes, as Blender's header has them in a popover; none outside modes that
 * mirror. */
struct MirrorToggles: View {
  @Bindable var model: ShellModel

  static func available(_ model: ShellModel) -> Bool { !(model.transformSettings["mirror_axes"] ?? "").isEmpty }

  var body: some View {
    let on = model.transformSettings["mirror"] ?? ""
    ForEach(Array(model.transformSettings["mirror_axes"] ?? ""), id: \.self) { axis in
      Toggle(axis.uppercased(), isOn: Binding(get: { on.contains(axis) }, set: { mirrored in
        /* The axes on, with this one turned on or off. */
        let axes = (model.transformSettings["mirror_axes"] ?? "").filter { $0 == axis ? mirrored : on.contains($0) }
        model.send("mirror", .set_, .text(axes.map(String.init).joined(separator: ",")))
      }))
    }
    if let topology = model.transformSettings["mirror_topology"] {
      Section {
        Toggle("Topology Mirror", isOn: Binding(get: { topology == "on" },
                                               set: { model.send("mirror_topology", .set_, .bool($0)) }))
      }
    }
  }

}

/** Blender's header menus for the 3D View in its mode, from `VIEW3D_MT_editor_menus`: each a text
 * menu, as on the desktop, or all of them in one Menus button where they do not fit. */
struct EditorMenus: View {
  /** A menu by its name is its own route, see `BlenderMenus.route`. */
  static let route = "VIEW3D_MT_editor_menus"
  /** How many stand side by side, in Blender's order; the rest open from one button at their end,
   * which reads Menus when it holds them all (ROUND5 7E/E2, decision 42). */
  var sideBySide = Int.max
  private let menus = BlenderMenus.shared

  var body: some View {
    let items = (menus.items[Self.route] ?? []).filter { $0.submenu && !$0.disabled }
    let shown = min(max(sideBySide, 0), items.count)
    /* Text menus side by side, as the desktop's header. */
    HStack(spacing: 0) {
      ForEach(items.prefix(shown)) { item in
        Menu { BlenderMenuItems(route: item.route) } label: { Text(item.title) }
          .accessibilityIdentifier("blender.menu.\(item.title)")
      }
      if shown < items.count {
        Menu {
          ForEach(items.dropFirst(shown)) { item in
            Menu(item.title) { BlenderMenuItems(route: item.route) }
          }
        } label: {
          if shown == 0 {
            Text("Menus")
          }
          else {
            Image(systemName: "chevron.right.2")
          }
        }
        .accessibilityLabel(shown == 0 ? "Menus" : "More Menus")
        .help(shown == 0 ? "Menus" : "More Menus")
        .accessibilityIdentifier("blender.menus")
      }
    }
    .fixedSize()
    .prefetchingBlenderMenu(Self.route)
  }
}

/** The popovers More opens for what the header has no room for: viewport shading, and the tool
 * settings while their row is hidden. */
private struct MorePopovers: ViewModifier {
  @Bindable var model: ShellModel
  let shell: ShellPanels
  let shading: Bool
  let toolSettings: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if shading {
      settings(content.shadingPopover(model: model, shell: shell))
    }
    else {
      settings(content)
    }
  }

  @ViewBuilder
  private func settings(_ content: some View) -> some View {
    if toolSettings {
      content.popover(isPresented: $model.toolSettingsOpen) {
        shell.panels.toolSettingsContent { model.toolSettingsOpen = false }
      }
    }
    else {
      content
    }
  }
}

/** The mode's mirror axes inline, as Blender's header has them: the butterfly, then a toggle for
 * each axis joined into one piece; Topology Mirror and Auto Merge where the mode has them. The
 * butterfly's name (Mirror, X-Axis Mirror or Symmetry) is said when held, and shown in glass where
 * there is room. */
struct MirrorInline: View {
  @Bindable var model: ShellModel
  @Environment(\.widgetsNamed) private var named
  @AppStorage(ShellStyle.key) private var style = ShellStyle.blender.rawValue

  var body: some View {
    let axes = Array(model.transformSettings["mirror_axes"] ?? "")
    let on = model.transformSettings["mirror"] ?? ""
    let label = model.transformSettings["mirror_label"] ?? "Mirror"
    /* The tool settings row's one spacing between its pieces (#ShellMetrics.headerSpacing). */
    HStack(spacing: ShellMetrics.headerSpacing) {
      if !axes.isEmpty {
        HStack(spacing: 4) {
          iconImage(BlenderIcon.image("MOD_MIRROR"))
          if named && style == ShellStyle.glass.rawValue {
            Text(label).font(.subheadline)
          }
        }
        .help(label)
        HStack(spacing: 1) {
          ForEach(Array(axes.enumerated()), id: \.offset) { index, axis in
            let selected = on.contains(axis)
            BlenderToggleButton(name: "\(label) \(axis.uppercased())", icon: nil, text: axis.uppercased(),
                                isOn: selected,
                                join: axes.count == 1 ? .alone : index == 0 ? .first :
                                  index == axes.count - 1 ? .last : .middle,
                                minWidth: 30) {
              let next = axes.filter { $0 == axis ? !selected : on.contains($0) }
              model.send("mirror", .set_, .text(next.map(String.init).joined(separator: ",")))
            }
          }
        }
        if let topology = model.transformSettings["mirror_topology"] {
          Toggle("Topology", isOn: Binding(get: { topology == "on" },
                                           set: { model.send("mirror_topology", .set_, .bool($0)) }))
            .toggleStyle(BlenderCheckboxStyle())
            .font(.subheadline)
        }
      }
      if let automerge = model.transformSettings["automerge"] {
        let merging = automerge == "on"
        BlenderToggleButton(name: "Auto Merge Vertices", icon: BlenderIcon.image(merging ? "AUTOMERGE_ON" : "AUTOMERGE_OFF"),
                            isOn: merging) {
          model.send("automerge", .set_, .text(merging ? "off" : "on"))
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("blender.setting.Mirror")
  }
}
