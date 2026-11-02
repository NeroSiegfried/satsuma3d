/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The document window's toolbar: back to the documents, the sidebar menu,
 * the editing mode, adding to the scene and the mesh selection mode; the active tool's settings in
 * the middle; then viewport shading, Properties, and Undo with Share and More. A phone keeps the
 * most used items and puts the rest in one menu.
 */

import SwiftUI
import UIKit

/** What the toolbar's menus do outside the window: presenting sheets, sharing and saving. */
@MainActor
final class ShellCommands {
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
  }

  func setFingerUsesTool(_ useTool: Bool) {
    model.fingerUsesTool = useTool
    wm_apple_ios_window_set_finger_tool(model.window, useTool)
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
    /* Save a copy wherever the person picks, as Files apps do for Save As. */
    document.save(to: document.fileURL, for: .forOverwriting) { [weak self] _ in
      let picker = UIDocumentPickerViewController(forExporting: [document.fileURL], asCopy: true)
      self?.presenter?.present(picker, animated: true)
    }
  }

  func shareDocument() {
    guard let document = wm_apple_ios_open_document() else { return }
    /* Share the file as it is now. */
    document.save(to: document.fileURL, for: .forOverwriting) { [weak self] _ in
      let activity = UIActivityViewController(activityItems: [document.fileURL], applicationActivities: nil)
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
    .onChange(of: drag, initial: true) { _, drag in Engine.setting("tweak_drag", drag) }
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
}

private struct TransformSetting {
  let key: String
  let title: String
  let symbol: String
  let options: [SettingOption]

  static let all = [
    TransformSetting(key: "orientation", title: "Transform Orientation", symbol: "rotate.3d", options: [
      SettingOption(title: "Global", symbol: "globe", value: "global"),
      SettingOption(title: "Local", symbol: "cube", value: "local"),
      SettingOption(title: "Normal", symbol: "arrow.up.forward", value: "normal"),
      SettingOption(title: "Gimbal", symbol: "gyroscope", value: "gimbal"),
      SettingOption(title: "View", symbol: "eye", value: "view"),
      SettingOption(title: "Cursor", symbol: "scope", value: "cursor"),
      SettingOption(title: "Parent", symbol: "arrow.triangle.branch", value: "parent"),
    ]),
    TransformSetting(key: "pivot", title: "Pivot Point", symbol: "viewfinder", options: [
      SettingOption(title: "Median Point", symbol: "circle.grid.cross", value: "median"),
      SettingOption(title: "Bounding Box Center", symbol: "square.dashed", value: "bounds"),
      SettingOption(title: "3D Cursor", symbol: "scope", value: "cursor"),
      SettingOption(title: "Individual Origins", symbol: "circle.grid.2x2", value: "individual"),
      SettingOption(title: "Active Element", symbol: "record.circle", value: "active"),
    ]),
    TransformSetting(key: "snap", title: "Snapping", symbol: "magnet", options: [
      SettingOption(title: "Off", symbol: "magnet", value: "off"),
      SettingOption(title: "Increment", symbol: "grid", value: "increment"),
      SettingOption(title: "Grid", symbol: "square.grid.3x3", value: "grid"),
      SettingOption(title: "Vertex", symbol: "point.topleft.down.curvedto.point.bottomright.up", value: "vertex"),
      SettingOption(title: "Edge", symbol: "line.diagonal", value: "edge"),
      SettingOption(title: "Face", symbol: "square", value: "face"),
      SettingOption(title: "Volume", symbol: "cube.transparent", value: "volume"),
    ]),
    TransformSetting(key: "proportional", title: "Proportional Editing", symbol: "circle.circle", options: [
      SettingOption(title: "Off", symbol: "circle", value: "off"),
      SettingOption(title: "On", symbol: "largecircle.fill.circle", value: "on"),
      SettingOption(title: "Connected Only", symbol: "link.circle", value: "connected"),
      SettingOption(title: "Projected", symbol: "square.3.layers.3d", value: "projected"),
    ]),
  ]

  func image(_ option: SettingOption) -> UIImage? {
    wm_apple_ios_icon("setting.\(key).\(option.value)", option.symbol)
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
  @Binding var stripWidth: CGFloat
  @AppStorage(FaceControl.shownKey) private var faceControlShown = false

  var body: some ToolbarContent {
    if model.documentsAvailable {
      /* Back to the documents is navigation, not a tool: its own glass, as the system's back
       * button. */
      ToolbarItem(placement: .topBarLeading) {
        Button("Documents", systemImage: "chevron.backward") { wm_apple_ios_show_documents(nil) }
          .accessibilityIdentifier("blender.documents")
      }
#if !os(visionOS)
      ToolbarSpacer(.fixed, placement: .topBarLeading)
#endif
    }
    if !model.compact {
      ToolbarItem(placement: .topBarLeading) { sidebarMenu }
#if !os(visionOS)
      ToolbarSpacer(.fixed, placement: .topBarLeading)
#endif
    }
    ToolbarItemGroup(placement: .topBarLeading) {
      modeMenu
      Button("Add", systemImage: "plus") { shell.assets.toggle() }
        .accessibilityIdentifier("blender.assets")
    }
    if model.mode == "mesh_edit" && !model.compact {
#if os(visionOS)
      ToolbarItem(placement: .topBarLeading) { meshSelection }
#else
      ToolbarSpacer(.fixed, placement: .topBarLeading)
      ToolbarItem(placement: .topBarLeading) { meshSelection }
        .sharedBackgroundVisibility(.hidden)
#endif
    }
    if model.compact {
      /* Undo stays in reach on a phone, beside the items above. */
#if !os(visionOS)
      ToolbarSpacer(.fixed, placement: .topBarLeading)
#endif
      ToolbarItem(placement: .topBarLeading) { undoButton }
    }
    if model.compact {
      /* Everything else in one menu, as nothing else fits beside the most used items. */
      ToolbarItem(placement: .topBarTrailing) {
        Menu("More", systemImage: "ellipsis") { compactMenu }
          .background(ShareSource(commands: commands))
          .prefetchingBlenderMenu(Self.importRoute)
          .prefetchingBlenderMenu(Self.exportRoute)
          .shadingPopover(model: model, shell: shell)
          .popover(isPresented: $model.toolSettingsOpen) {
            shell.panels.toolSettingsContent { model.toolSettingsOpen = false }
          }
          .accessibilityIdentifier("blender.actions")
      }
    }
    else {
      regularTrailing
    }
  }

  @ToolbarContentBuilder
  private var regularTrailing: some ToolbarContent {
    ToolbarItemGroup(placement: .secondaryAction) { centerItems }
    ToolbarItem(placement: .topBarTrailing) { shadingButton }
#if !os(visionOS)
    ToolbarSpacer(.fixed, placement: .topBarTrailing)
#endif
    /* Properties slides in from the window's trailing edge. */
    ToolbarItem(placement: .topBarTrailing) {
      panelToggle("Properties", image: BlenderIcon.image("PROPERTIES"), isOn: model.inspectorShown,
                  identifier: "blender.inspector") { shell.panels.toggleInspector() }
    }
#if !os(visionOS)
    ToolbarSpacer(.fixed, placement: .topBarTrailing)
#endif
    /* Undo, Share and More together. */
    ToolbarItemGroup(placement: .topBarTrailing) {
      undoButton
      Menu("Share", systemImage: "square.and.arrow.up") { shareMenu }
        .background(ShareSource(commands: commands))
        .prefetchingBlenderMenu(Self.importRoute)
        .prefetchingBlenderMenu(Self.exportRoute)
        .accessibilityIdentifier("blender.share")
      Menu("More", systemImage: "ellipsis") { moreMenu }
        .accessibilityIdentifier("blender.actions")
    }
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
    Button { Engine.operatorCall("ED_OT_undo") } label: {
      Label { Text("Undo") } icon: { iconImage(wm_apple_ios_icon("operator.ED_OT_undo", "arrow.uturn.backward")) }
    }
    .disabled(!model.canUndo)
    .accessibilityIdentifier("blender.undo")
  }

  /** The node editors, each opening the node editor on its tree, docked along the bottom, and the
   * Image Editor beside the viewport. */
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
      sidebarToggle("Image Editor", icon: BlenderIcon.image("IMAGE"), isOn: model.imageShown) {
        shell.panels.image.setShown($0)
      }
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

  /** Share: what leaves the document. Documents save themselves, so
   * there is no Save; going back to the documents keeps the work. */
  @ViewBuilder
  private var shareMenu: some View {
    Section {
      Button("Share…", systemImage: "square.and.arrow.up") { commands.shareDocument() }
      Button("Save As…", systemImage: "doc.on.doc") { commands.saveDocumentAs() }
    }
    /* Blender's own Import and Export menus, so every format it and its add-ons support is
     * listed. Their file browsers open the system's document picker. */
    Section {
      Menu { BlenderMenuItems(route: Self.importRoute) } label: { blenderLabel("Import", "IMPORT") }
      Menu { BlenderMenuItems(route: Self.exportRoute) } label: { blenderLabel("Export", "EXPORT") }
    }
    Section {
      Button("Render Image", systemImage: "photo") { commands.render?.renderAnimation(false) }
      Button("Render Animation", systemImage: "film") { commands.render?.renderAnimation(true) }
      /* Every earlier render, in the render sheet's film strip. */
      Button("Renders", systemImage: "photo.stack") { commands.render?.showRenders() }
    }
    Button("Save as Template…", systemImage: "square.on.square") { commands.saveAsTemplate() }
  }

  private func blenderLabel(_ title: String, _ icon: String) -> some View {
    Label { Text(title) } icon: { iconImage(BlenderIcon.image(icon)) }
  }

  /** A narrow window's one menu: the panels, the view, One Finger, the selection mode and tool
   * settings, then Share and More. */
  @ViewBuilder
  private var compactMenu: some View {
    Section {
      sidebarToggle("Outliner", icon: BlenderIcon.image("OUTLINER"), isOn: model.hierarchyShown) {
        shell.panels.toggleHierarchy()
      }
      sidebarToggle("Timeline", icon: UIImage(named: "blender.time")?.withRenderingMode(.alwaysTemplate),
                    isOn: model.timelineShown) { shell.timeline.setVisible($0) }
      sidebarToggle("Properties", icon: BlenderIcon.image("PROPERTIES"), isOn: model.inspectorShown) {
        shell.panels.toggleInspector()
      }
    }
    nodeEditorToggles
    Section {
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
      Menu {
        ForEach(ViewCommand.pie(locked: model.viewport?.bool("lock_camera") == true,
                                kept: model.viewport?.bool("keep_camera_view") == true,
                                camera: model.viewport?.bool("camera_view") == true), id: \.title) { command in
          Button { command.run() } label: { Label { Text(command.title) } icon: { iconImage(command.image) } }
        }
      } label: {
        Label("View", systemImage: "eye")
      }
      Menu {
        sidebarToggle("Use Tool", icon: wm_apple_ios_icon("control.finger_tool", "cursorarrow"),
                      isOn: model.fingerUsesTool) { commands.setFingerUsesTool(true) }
        sidebarToggle("Orbit View", icon: wm_apple_ios_icon("operator.VIEW3D_OT_rotate", "rotate.3d"),
                      isOn: !model.fingerUsesTool) { commands.setFingerUsesTool(false) }
      } label: {
        Label("One Finger", systemImage: "hand.point.up")
      }
    }
    Section {
      if model.mode == "mesh_edit" {
        Menu {
          ForEach([("VERT", "Vertex Select", "circle.fill"), ("EDGE", "Edge Select", "line.diagonal"),
                   ("FACE", "Face Select", "square.fill")], id: \.0) { value, title, symbol in
            sidebarToggle(title, icon: wm_apple_ios_icon("mesh.\(value)", symbol),
                          isOn: model.meshSelectMode == value) { Engine.setting("mesh_select_mode", value) }
          }
        } label: {
          Label { Text("Select Mode") } icon: { iconImage(wm_apple_ios_icon("mesh.VERT", "circle.fill")) }
        }
      }
      if transformTools.contains(model.activeTool) {
        ForEach(TransformSetting.all, id: \.key) { setting in
          Menu {
            ForEach(setting.options, id: \.value) { option in
              sidebarToggle(option.title, icon: setting.image(option),
                            isOn: model.transformSettings[setting.key] == option.value) {
                Engine.setting(setting.key, option.value)
              }
            }
          } label: {
            Label { Text(setting.title) } icon: {
              iconImage(wm_apple_ios_icon("control.\(setting.title)", setting.symbol))
            }
          }
        }
        if hasMirror {
          Menu { mirrorToggles } label: {
            Label { Text("Mirror") } icon: { iconImage(BlenderIcon.image("MOD_MIRROR")) }
          }
        }
      }
      else if model.toolSettingsShown {
        Button("Tool Settings", systemImage: "slider.horizontal.3") { model.toolSettingsOpen = true }
      }
    }
    Menu { shareMenu } label: { Label("Share", systemImage: "square.and.arrow.up") }
    moreMenu
  }

  /** More: smaller things, with viewport options showing their current state. */
  @ViewBuilder
  private var moreMenu: some View {
    Button("New…", systemImage: "doc.badge.plus") {
      if let presenter = commands.presenter { wm_apple_ios_new_document(presenter) }
    }
#if !os(visionOS)
    if faceControlShown, model.brush?.dict("size") != nil || model.brush?.dict("strength") != nil {
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
                      isOn: model.viewport?.bool(toggle.name) == true) {
          Engine.setting("viewport_toggle", toggle.name)
        }
        .disabled(model.viewport == nil)
      }
    }
    Section {
      Button("Hide Interface", systemImage: "arrow.up.left.and.arrow.down.right") {
        commands.setInterfaceHidden(true)
      }
      Button("Switch to Desktop Interface", systemImage: "macwindow") { Engine.setting("interface", "desktop") }
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
        set: { Engine.setting("object_mode", $0) })) {
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
    { Engine.setting("mesh_select_mode", $0) }
      .frame(width: 144, height: 36)
      .accessibilityIdentifier("blender.mesh-selection")
  }

  /* -------------------------------------------------------------------- */
  /* Tool settings */

  /** The tool's settings as the bar's middle items, see #ToolSettingsItems: the transform tools'
   * orientation, pivot, snapping and proportional editing, or the active tool's own. */
  @ViewBuilder
  private var centerItems: some View {
    if transformTools.contains(model.activeTool) {
      if model.activeTool == "builtin.select" {
        TweakDragMenu()
      }
      ForEach(TransformSetting.all, id: \.key) { setting in
        let value = model.transformSettings[setting.key]
        let selected = setting.options.first { $0.value == value }
        Menu {
          Picker(setting.title, selection: Binding(
            get: { value ?? "" },
            set: { Engine.setting(setting.key, $0) })) {
            ForEach(setting.options, id: \.value) { option in
              Label { Text(option.title) } icon: { iconImage(setting.image(option)) }
                .tag(option.value)
            }
          }
        } label: {
          Label {
            Text(setting.title)
          } icon: {
            iconImage(selected.flatMap { setting.image($0) } ??
                      (setting.key == "snap" && value == "mixed" ? wm_apple_ios_icon("control.Snapping", "magnet") :
                       wm_apple_ios_icon("control.\(setting.title)", setting.symbol)))
          }
        }
        .accessibilityValue(selected?.title ?? "")
        .accessibilityIdentifier("blender.setting.\(setting.title)")
      }
      if hasMirror {
        Menu { mirrorToggles } label: {
          Label { Text("Mirror") } icon: { iconImage(BlenderIcon.image("MOD_MIRROR")) }
        }
        .accessibilityIdentifier("blender.setting.Mirror")
      }
    }
    else if model.toolSettingsShown {
      ToolSettingsItems(store: shell.panels.toolStripStore, popouts: shell.panels.toolPopoverStore)
    }
  }

  @ViewBuilder
  private var centerSettings: some View {
    if transformTools.contains(model.activeTool) {
      transformSettings
    }
    else if model.toolSettingsShown && model.toolStripRoom < 160 {
      /* No room for the strip beside the other items: all the settings in a popover. */
      Button("Tool Settings", systemImage: "slider.horizontal.3") { model.toolSettingsOpen = true }
        .labelStyle(.iconOnly)
        .frame(width: 44, height: 44)
        .panelGlass(in: Circle())
        .popover(isPresented: $model.toolSettingsOpen) {
          shell.panels.toolSettingsContent { model.toolSettingsOpen = false }
        }
        .background(ToolStripMarker { model.toolStripRoom = $0 })
        .accessibilityIdentifier("blender.tool-settings.more")
    }
    else if model.toolSettingsShown {
      toolSettings
    }
  }

  /** The mode's mirror axes, as Blender's header has them in a popover; none outside modes that
   * mirror. */
  private var hasMirror: Bool { !(model.transformSettings["mirror_axes"] ?? "").isEmpty }

  @ViewBuilder
  private var mirrorToggles: some View {
    let on = model.transformSettings["mirror"] ?? ""
    ForEach(Array(model.transformSettings["mirror_axes"] ?? ""), id: \.self) { axis in
      Toggle(axis.uppercased(), isOn: Binding(get: { on.contains(axis) },
                                             set: { _ in Engine.setting("mirror", String(axis)) }))
    }
    if let topology = model.transformSettings["mirror_topology"] {
      Section {
        Toggle("Topology Mirror", isOn: Binding(get: { topology == "on" },
                                               set: { _ in Engine.setting("mirror_topology", "") }))
      }
    }
  }

  private var transformSettings: some View {
    HStack(spacing: 0) {
      if model.activeTool == "builtin.select" {
        TweakDragMenu()
      }
      ForEach(TransformSetting.all, id: \.key) { setting in
        let value = model.transformSettings[setting.key]
        let selected = setting.options.first { $0.value == value }
        Menu {
          Picker(setting.title, selection: Binding(
            get: { value ?? "" },
            set: { Engine.setting(setting.key, $0) })) {
            ForEach(setting.options, id: \.value) { option in
              Label { Text(option.title) } icon: { iconImage(setting.image(option)) }
                .tag(option.value)
            }
          }
        } label: {
          iconImage(selected.flatMap { setting.image($0) } ??
                    (setting.key == "snap" && value == "mixed" ? wm_apple_ios_icon("control.Snapping", "magnet") :
                     wm_apple_ios_icon("control.\(setting.title)", setting.symbol)))
            .frame(width: 44, height: 44)
        }
        .accessibilityLabel(setting.title)
        .accessibilityValue(selected?.title ?? (setting.key == "orientation" && value == "custom" ?
                                                  "Custom Orientation" : "Multiple or Other Elements"))
        .accessibilityIdentifier("blender.setting.\(setting.title)")
      }
      if hasMirror {
        Menu { mirrorToggles } label: {
          iconImage(BlenderIcon.image("MOD_MIRROR"))
            .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Mirror")
        .accessibilityValue((model.transformSettings["mirror"] ?? "").uppercased())
        .accessibilityIdentifier("blender.setting.Mirror")
      }
    }
    .padding(.horizontal, 4)
    /* One glass group, as the bar's other groups. */
    .panelGlass(in: Capsule())
  }

  /** The tool's settings as a strip in the room the bar leaves between its other items; when they
   * do not all fit they scroll, and all of them are in a popover. */
  private var toolSettings: some View {
    /* The room less the capsule's padding, and the overflow button when it is shown. */
    let room = model.toolStripRoom - 24
    let overflow = stripWidth > room + 0.5
    let strip = ToolStrip(store: shell.panels.toolStripStore, popouts: shell.panels.toolPopoverStore)
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stripWidth = $0 }
    return HStack(spacing: 4) {
      if overflow {
        ScrollView(.horizontal, showsIndicators: false) { strip }
          .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
          .frame(width: max(1, room - 36))
      }
      else {
        /* At its own width, which the bar reads as it places the item: a width measured only
         * after layout leaves the bar's item as narrow as it first was, and taps outside it
         * do not reach the strip. */
        strip.fixedSize()
      }
      if overflow {
        Button("More Tool Settings", systemImage: "ellipsis") { model.toolSettingsOpen = true }
          .labelStyle(.iconOnly)
          .foregroundStyle(PanelStyle.tint)
          .frame(width: 32)
          .accessibilityIdentifier("blender.tool-settings.more")
      }
    }
    .popover(isPresented: $model.toolSettingsOpen) {
      shell.panels.toolSettingsContent { model.toolSettingsOpen = false }
    }
    .tint(PanelStyle.tint)
    .padding(.horizontal, 12)
    .frame(height: 44)
    /* Its own glass, as the bar's other groups have. */
    .panelGlass(in: Capsule())
    .background(ToolStripMarker { model.toolStripRoom = $0 })
  }

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
    let commands: [String: (Int32, String, String)] = [
      "wireframe": (20, "Wireframe", "circle.dashed"), "solid": (21, "Solid", "cube"),
      "material": (22, "Material Preview", "circle.lefthalf.filled"), "rendered": (23, "Rendered", "camera.aperture"),
    ]
    let current = commands[model.shading] ?? commands["solid"]!
    return Button {
      shell.panels.showShadingTab("SHADING")
      model.shadingOpen = true
    } label: {
      Label { Text("Viewport Shading") } icon: { iconImage(wm_apple_ios_command_icon(current.0, current.2)) }
    }
    .accessibilityValue(current.1)
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
    }
    .onChange(of: model.shadingOpen) { _, shown in shell.panels.setShadingShown(shown) }
  }
}

/**
 * Measures the room the navigation bar leaves for the tool settings strip it centers: twice the
 * distance from the bar's middle to the nearest control on either side, not counting the strip.
 * SwiftUI's frames of toolbar items are each in their own hosting view, so this asks UIKit.
 */
struct ToolStripMarker: UIViewRepresentable {
  let changed: (CGFloat) -> Void

  final class Marker: UIView {
    var changed: ((CGFloat) -> Void)?
    private var pending = false
    private var lastRoom: CGFloat = 0

    override func didMoveToWindow() {
      super.didMoveToWindow()
      remeasure()
      /* The bar brings its other items in with an animation: measure again once they are in. */
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.remeasure() }
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      remeasure()
    }

    func remeasure() {
      if pending || window == nil { return }
      pending = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        pending = false
        guard let room = measure(), abs(room - lastRoom) > 0.5 else { return }
        lastRoom = room
        changed?(room)
      }
    }

    private func measure() -> CGFloat? {
      var bar: UIView? = superview
      while let view = bar, !(view is UINavigationBar) { bar = view.superview }
      guard let bar else { return nil }
      /* The strip sits behind its own controls: skip what is inside it. */
      let strip = convert(bounds, to: bar).insetBy(dx: -1, dy: -1)
      let center = bar.bounds.midX
      var left: CGFloat?
      var right: CGFloat?
      var pending: [UIView] = [bar]
      while let view = pending.popLast() {
        if view.isHidden || view.alpha < 0.01 { continue }
        if view !== bar, isDescendant(of: view) {
          if view is UIControl { continue }
          pending.append(contentsOf: view.subviews)
          continue
        }
        let other = view.convert(view.bounds, to: bar)
        if strip.contains(other) { continue }
        if view is UIControl && other.width < bar.bounds.width / 2 {
          if other.midX < center { left = max(left ?? other.maxX, other.maxX) }
          else { right = min(right ?? other.minX, other.minX) }
          continue
        }
        pending.append(contentsOf: view.subviews)
      }
      /* Until the items on both sides are in, keep the last room: a strip measured too wide makes
       * the bar give up centering it. */
      guard let left, let right else { return nil }
      return max(80, 2 * min(center - left, right - center) - 32)
    }
  }

  func makeUIView(context: Context) -> Marker {
    let marker = Marker()
    marker.isUserInteractionEnabled = false
    marker.changed = changed
    return marker
  }

  func updateUIView(_ marker: Marker, context: Context) {
    marker.changed = changed
    marker.remeasure()
    /* The bar's items change with an animation: measure again once they are in. */
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak marker] in marker?.remeasure() }
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
