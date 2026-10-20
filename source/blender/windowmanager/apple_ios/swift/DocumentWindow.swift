/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The document window: Blender's viewport with the native interface around it, in SwiftUI.
 * Blender draws only the viewport, into GHOST's Metal view at the bottom of the window; touches
 * and the Pencil that reach that view are Blender's, everything above it is SwiftUI.
 *
 * GHOST asks for the window's controller through `WM_apple_ios_window_controller`, in
 * `wm_apple_ios_window.mm`.
 */

import MetalKit
import SwiftUI
import UIKit

/* -------------------------------------------------------------------- */
/** \name Controller
 * \{ */

@MainActor
@objc(WMIOSSwiftDocumentController)
public final class DocumentController: UIHostingController<DocumentWindow> {
  private let model: ShellModel
  private let metalView: MTKView
  private let shell: ShellPanels
  private let commands: ShellCommands
  private let pencilMenu: PencilMenu?
  private let pencilSource: GHOSTIOSPencilMenuDelegate
  private var stateTimer: Timer?
  private var contextMenu: UIEditMenuInteraction?
  /** One of Blender's menus, shown in place of its own popup where the pointer is: the context
   * menu a right-click opens, Shift-A's Add menu, a pie, as on a Mac. */
  private var blenderMenu: UIMenu?
  private var menuBarItems: NSArray = []
  private var menuBarRequest: UInt64 = 0
  private var menuBarMode: String?
  private var menuBarTime = Date.distantPast
  private var touchSettingsApplied = false

  @objc(initWithMetalView:window:)
  public init(metalView: MTKView, window: UnsafeMutableRawPointer) {
    let model = ShellModel(window: window)
    let shell = ShellPanels(model: model)
    let commands = ShellCommands(model: model, shell: shell)
    let viewport = ViewportContainer(metalView: metalView)
#if os(visionOS)
    /* visionOS has no Pencil to bring a radial menu up. */
    pencilMenu = nil
#else
    pencilMenu = SwiftPencilMenu(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
#endif
    pencilSource = wm_apple_ios_pencil_menu_source(window, metalView)
    self.model = model
    self.metalView = metalView
    self.shell = shell
    self.commands = commands
    super.init(rootView: DocumentWindow(model: model, viewport: viewport, shell: shell, commands: commands,
                                        pencilMenu: pencilMenu))
    commands.presenter = self
    commands.render = SwiftRender(presenter: self)
    commands.settings = SwiftSettings(presenter: self, preferences: shell.panels.preferences,
                                      lists: shell.panels.preferenceLists)
    commands.settings?.fingerUsesToolChanged = { [weak commands] useTool in
      commands?.setFingerUsesTool(useTool)
    }
    model.onRender = { [weak commands] status in commands?.render?.updateStatus(status) }
    model.onPreferences = { [weak commands] preferences in commands?.settings?.updatePreferences(preferences) }
    model.onToolSettings = { [weak shell] settings, ack in
      shell?.panels.updateToolSettingsStores(settings, acknowledgement: ack) ?? false
    }
    /* Industry Compatible is the iPad's default keymap; switch once, then respect the choice. */
    if !UserDefaults.standard.bool(forKey: "BlenderKeymapDefaulted") {
      UserDefaults.standard.set(true, forKey: "BlenderKeymapDefaulted")
      Engine.setting("keymap", "Industry_Compatible")
    }
    if UserDefaults.standard.bool(forKey: "BlenderDesktopInterface") {
      /* Start in the interface the person left; Blender follows from its inbox. */
      Engine.setting("interface", "desktop")
    }
    pencilMenu?.delegate = pencilSource
    wm_apple_ios_window_set_pencil_menu(window, pencilMenu)
    /* Assets dragged out of the pane drop onto the viewport; files from other apps too, see
     * #FileDrop. */
    viewport.addInteraction(shell.assets.dropInteraction)
    installContextMenu()

    NotificationCenter.default.addObserver(self, selector: #selector(snapshotsPublished),
                                           name: Notification.Name("BlenderSnapshotsPublished"),
                                           object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(templatePresentation(_:)),
                                           name: Notification.Name("BlenderTemplatePresentation"),
                                           object: nil)
    model.pullToolbar(copy: true)
    shell.pullSnapshots()
    model.refreshWindowState()
    /* Snapshots arrive by notification. Whether the viewport has drawn is read from the
     * presentation mailbox, as a held-up Blender publishes nothing. */
    stateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.model.refreshWindowState()
        self?.shell.compile.refresh()
      }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  @objc private func snapshotsPublished() {
    let desktop = model.desktop
    model.pullToolbar()
    shell.pullSnapshots()
    pullMenuPopup()
    if desktop != model.desktop { desktopChanged() }
    refreshMenuBar()
  }

  /** Blender's own Window menu can switch to its desktop interface too. */
  private func desktopChanged() {
    let desktop = model.desktop
    UserDefaults.standard.set(desktop, forKey: "BlenderDesktopInterface")
    pencilMenu?.cancel()
    if desktop { commands.setInterfaceHidden(false) }
    /* No native controls, radial menu or bottom tray over Blender's own interface. */
    wm_apple_ios_window_set_pencil_menu(model.window, desktop ? nil : pencilMenu)
  }

  @objc private func templatePresentation(_ notification: Notification) {
    shell.panels.dismiss()
    let timeline = (notification.userInfo?["timeline"] as? NSNumber)?.boolValue ?? false
    shell.timeline.setVisible(timeline)
  }

  /** The launcher showed or hid the document window. */
  @objc public func updateDocumentControls() {
    model.refreshWindowState()
  }

  /** Blender is closing the window: stop calling into it. */
  @objc public func detachBlender() {
    stateTimer?.invalidate()
    stateTimer = nil
    NotificationCenter.default.removeObserver(self)
    pencilMenu?.delegate = nil
    wm_apple_ios_pencil_menu_source_detach(pencilSource as! NSObject)
    model.window = nil
    wm_apple_ios_document_controller_closed(self)
  }

  override public var prefersHomeIndicatorAutoHidden: Bool { true }
  override public var prefersStatusBarHidden: Bool { model.interfaceHidden }

  override public func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    /* Most controls keep beside the window's sides through the layout itself; the viewport, and the
     * controls placed by its geometry, run under them. */
    var insets = view.safeAreaInsets
    let sides = UIEdgeInsets(top: 0, left: insets.left, bottom: 0, right: insets.right)
    insets.left = 0
    insets.right = 0
    if model.safeAreaInsets != insets { model.safeAreaInsets = insets }
    if model.sideInsets != sides { model.sideInsets = sides }
  }

  override public func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    updateTopBarBottom()
    if !touchSettingsApplied, view.window != nil {
      /* The iPad's saved Pencil and touch choice; a phone has no Pencil, so its finger starts
       * with the tool. */
      touchSettingsApplied = true
      commands.setFingerUsesTool(UIDevice.current.userInterfaceIdiom == .phone || SwiftSettings.fingerUsesTool)
    }
  }

  /** SwiftUI places the top bar inside the window's safe area: find where it ends. */
  private func updateTopBarBottom() {
    var pending: [UIView] = [view]
    var bottom: CGFloat = 0
    while let current = pending.popLast() {
      if let bar = current as? UINavigationBar {
        if !bar.isHidden, bar.alpha > 0.01 { bottom = max(bottom, bar.convert(bar.bounds, to: view).maxY) }
        continue
      }
      pending.append(contentsOf: current.subviews)
    }
    if model.topBarBottom != bottom { model.topBarBottom = bottom }
  }

  /* -------------------------------------------------------------------- */
  /* The menu bar */

  /** Projecting all of Blender's menus is costly and they change with the mode, rarely
   * otherwise: ask again when the mode changes, and every few seconds for the rest. */
  private func refreshMenuBar() {
    if menuBarRequest != 0 {
      guard let items = wm_apple_ios_menu_result(menuBarRequest) else { return }
      menuBarRequest = 0
      if !(items as NSArray).isEqual(to: menuBarItems as! [Any]) {
        menuBarItems = items as NSArray
        UIMenuSystem.main.setNeedsRebuild()
      }
    }
    if menuBarMode == model.objectMode && Date().timeIntervalSince(menuBarTime) < 3 { return }
    menuBarTime = Date()
    menuBarMode = model.objectMode
    menuBarRequest = wm_apple_ios_menu_bar_request()
  }

  override public func buildMenu(with builder: any UIMenuBuilder) {
    super.buildMenu(with: builder)
    wm_apple_ios_build_menu_bar(builder, menuBarItems as! [Any])
  }

  @objc public func newDocument(_ sender: Any?) {
    wm_apple_ios_new_document(self)
  }
}

/* Holding a finger on the viewport opens Blender's context menu there. */
extension DocumentController: UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {
  private func installContextMenu() {
    let interaction = UIEditMenuInteraction(delegate: self)
    metalView.addInteraction(interaction)
    contextMenu = interaction
    /* A mouse or trackpad's secondary click goes to Blender, as on a Mac: its key-map opens the
     * context menu, which shows natively, see #pullMenuPopup. */
    let press = UILongPressGestureRecognizer(target: self, action: #selector(contextMenuPress(_:)))
    press.minimumPressDuration = 0.42
    press.allowableMovement = 12
    press.cancelsTouchesInView = true
    press.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    press.delegate = self
    /* The phone holds a finger to use the tool. */
    press.isEnabled = UIDevice.current.userInterfaceIdiom != .phone
    metalView.addGestureRecognizer(press)
  }

  private func pullMenuPopup() {
    guard let json = WM_apple_ios_ui_menu_popup_take_json() else { return }
    let data = Data(bytes: json, count: strlen(json))
    free(json)
    guard let request = (try? JSONSerialization.jsonObject(with: data)) as? JSON,
          let menu = request.string("menu") else { return }
    let bounds = metalView.bounds
    let point = CGPoint(x: bounds.width * CGFloat(request.double("x") ?? 0.5),
                        y: bounds.height * CGFloat(request.double("y") ?? 0.5))
    Task { @MainActor in
      guard let items = await BlenderMenus.shared.fetch(BlenderMenus.route(menu)), !items.isEmpty else { return }
      blenderMenu = BlenderMenus.uiMenu(items)
      contextMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }
  }

  @objc private func contextMenuPress(_ press: UILongPressGestureRecognizer) {
    /* Blender's own interface has its own context menus. */
    guard press.state == .began, !model.desktop else { return }
    let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: press.location(in: metalView))
    contextMenu?.presentEditMenu(with: configuration)
  }

  public func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    /* Only a press or click that starts on the viewport itself, not on a control above it. */
    (touch.type == .direct || touch.type == .indirectPointer) && touch.view === metalView
  }

  public func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                                  menuFor configuration: UIEditMenuConfiguration,
                                  suggestedActions: [UIMenuElement]) -> UIMenu?
  {
    if let blenderMenu { return blenderMenu }
    let menu = wm_apple_ios_context_menu()
    return menu.children.isEmpty ? nil : menu
  }

  public func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                                  willDismissMenuFor configuration: UIEditMenuConfiguration,
                                  animator: any UIEditMenuInteractionAnimating)
  {
    blenderMenu = nil
  }

  public func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                                  targetRectFor configuration: UIEditMenuConfiguration) -> CGRect
  {
    CGRect(origin: configuration.sourcePoint, size: CGSize(width: 1, height: 1))
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Viewport
 * \{ */

/** Holds GHOST's Metal view, sized to the window at the display's full resolution, less what a
 * panel covers at the bottom so the view centers on what can be seen. */
final class ViewportContainer: UIView {
  let metalView: MTKView
  /** Set while the panel's handle is dragged: the cover is followed at once. */
  var live = false
  var bottomCover: CGFloat = 0 {
    didSet {
      if bottomCover != oldValue { animateCover() }
    }
  }
  /** The cover as the viewport is shaped now, eased toward `bottomCover` alongside the panel. */
  private var shownCover: CGFloat = 0
  private var coverAnimation: (from: CGFloat, start: CFTimeInterval)?
  private var displayLink: CADisplayLink?
  private static let coverDuration: CFTimeInterval = 0.42

  init(metalView: MTKView) {
    self.metalView = metalView
    super.init(frame: .zero)
    metalView.autoresizingMask = []
    addSubview(metalView)
  }

  private func animateCover() {
    /* Dragging the panel's handle is followed at once, so the viewport keeps up with the
     * finger; the panel opening or closing is eased alongside it. */
    guard window != nil, !UIAccessibility.isReduceMotionEnabled, !live else {
      coverAnimation = nil
      displayLink?.invalidate()
      displayLink = nil
      shownCover = bottomCover
      setNeedsLayout()
      return
    }
    coverAnimation = (shownCover, CACurrentMediaTime())
    if displayLink == nil {
      let link = CADisplayLink(target: self, selector: #selector(stepCover))
      link.add(to: .main, forMode: .common)
      displayLink = link
    }
  }

  @objc private func stepCover(_ link: CADisplayLink) {
    guard let animation = coverAnimation else { return }
    let t = min(1, (CACurrentMediaTime() - animation.start) / Self.coverDuration)
    /* Eased out, as the panel slides. */
    let eased = 1 - pow(1 - t, 3)
    shownCover = animation.from + (bottomCover - animation.from) * eased
    setNeedsLayout()
    layoutIfNeeded()
    if t >= 1 {
      coverAnimation = nil
      link.invalidate()
      displayLink = nil
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    /* Full size always: resizing the drawable as a panel slides would drop frames. Blender is
     * told how much is covered and centers the view on the rest. */
    let frame = bounds
    metalView.frame = frame
    let scale = max(1, window?.traitCollection.displayScale ?? traitCollection.displayScale)
    metalView.contentScaleFactor = scale
    metalView.layer.contentsScale = scale
    let size = CGSize(width: max(1, frame.width * scale), height: max(1, frame.height * scale))
    WM_apple_ios_ui_viewport_cover_set(Float((shownCover * scale).rounded()))
    if metalView.drawableSize != size {
      metalView.drawableSize = size
    }
  }
}

struct ViewportView: UIViewRepresentable {
  let container: ViewportContainer
  var bottomCover: CGFloat = 0
  var live = false

  func makeUIView(context: Context) -> ViewportContainer { container }
  func updateUIView(_ view: ViewportContainer, context: Context) {
    view.live = live
    view.bottomCover = bottomCover
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Window
 * \{ */

public struct DocumentWindow: View {
  let model: ShellModel
  let viewport: ViewportContainer
  let shell: ShellPanels
  let commands: ShellCommands
  let pencilMenu: PencilMenu?
  @State private var stripWidth: CGFloat = 0
  @Environment(\.horizontalSizeClass) private var sizeClass

  /** The native controls are hidden in full screen, and over Blender's own interface. */
  private var controlsShown: Bool { !model.desktop && !model.interfaceHidden }

  /** The Outliner is the sidebar, which slides in and pushes the viewport over, and
   * Properties the inspector on the other side. A phone shows both as sheets. On Apple Vision Pro
   * they are windows of their own. */
  public var body: some View {
    window
      .environment(\.blenderMenuContext, model.menuContext)
  }

  @ViewBuilder
  private var window: some View {
#if os(visionOS)
    editor
#else
    if sizeClass == .compact {
      /* A phone: both are sheets over the viewport. */
      editor
        .sheet(isPresented: hierarchySheet) {
          HierarchyPanel(store: shell.panels.hierarchy) { shell.panels.setHierarchyShown(false) }
            .environment(\.panelInWindow, true)
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: inspector) {
          InspectorPanel(store: shell.panels.inspector) { shell.panels.setInspectorShown(false) }
            .presentationDetents([.medium, .large])
        }
    }
    else {
      columns
    }
#endif
  }

#if !os(visionOS)
  /** The Outliner and Properties slide in from the window's sides and push the viewport over, in
   * one animation with it. Only one fits beside the viewport in a narrow window. */
  private var columns: some View {
    /* The toolbar spans the window and stays put as the columns slide in
     * below it. */
    NavigationStack {
      columnLayout
        .toolbar {
          DocumentToolbar(model: model, shell: shell, commands: commands, stripWidth: $stripWidth)
        }
        .toolbar(controlsShown ? .visible : .hidden, for: .navigationBar)
        .toolbarTitleDisplayMode(.inline)
    }
    .onChange(of: sizeClass, initial: true) { _, size in model.compact = size == .compact }
  }

  private var columnLayout: some View {
    HStack(spacing: 0) {
      if model.hierarchyShown && controlsShown {
        HierarchyPanel(store: shell.panels.hierarchy) { shell.panels.setHierarchyShown(false) }
          .environment(\.panelInWindow, true)
          .frame(width: 320)
          .background(Color(uiColor: .secondarySystemBackground).ignoresSafeArea())
          .transition(.move(edge: .leading))
          .accessibilityIdentifier("blender.hierarchy.panel")
      }
      layers
      if model.inspectorShown && controlsShown {
        InspectorPanel(store: shell.panels.inspector) { shell.panels.setInspectorShown(false) }
          .environment(\.panelInWindow, true)
          .frame(width: 336)
        .background(Color(uiColor: .secondarySystemBackground).ignoresSafeArea())
        .transition(.move(edge: .trailing))
        .accessibilityIdentifier("blender.inspector.panel")
      }
    }
    .onGeometryChange(for: Bool.self) { $0.size.width < 1000 } action: { shell.panels.narrow = $0 }
  }
#endif

  private var hierarchySheet: Binding<Bool> {
    Binding(get: { model.hierarchyShown && controlsShown }, set: { shell.panels.setHierarchyShown($0) })
  }

  private var inspector: Binding<Bool> {
    Binding(get: { model.inspectorShown && controlsShown }, set: { shell.panels.setInspectorShown($0) })
  }

  /** The viewport with its controls and the toolbar. */
  private var editor: some View {
    NavigationStack {
      layers
        .toolbar {
          /* Kept while the bar is hidden: items added again lose the bar's centering of the strip. */
          DocumentToolbar(model: model, shell: shell, commands: commands, stripWidth: $stripWidth)
        }
        .toolbar(controlsShown ? .visible : .hidden, for: .navigationBar)
        .toolbarTitleDisplayMode(.inline)
        .onChange(of: sizeClass, initial: true) { _, size in model.compact = size == .compact }
#if os(visionOS)
        .visionOrnaments(model: model, shown: controlsShown && model.windowVisible)
#endif
    }
  }

  /** The viewport and the controls over it, then Properties and the Outliner, which keep below the
   * toolbar. */
  private var layers: some View {
    ZStack {
      /* Under the bars, but beside the sidebar and inspector, which are the side safe areas: the
       * viewport and its controls move with the columns as they slide. */
      viewportLayers
        .ignoresSafeArea(edges: .vertical)
      CompileIndicator(progress: shell.compile)
    }
  }

  /** How much of the window's bottom the viewport leaves to the node editor. */
  private var viewportCover: CGFloat {
    controlsShown ? max(model.nodesShown ? model.nodesCover : 0, model.curvesCover) : 0
  }

  private var viewportLayers: some View {
    ZStack {
      /* Edge to edge, under a phone's toolbar column too. */
      ViewportView(container: viewport, bottomCover: viewportCover, live: model.nodesCoverDragging)
        .ignoresSafeArea()
        .onDrop(of: [.data, .image], delegate: FileDrop(model: model) { shell.assets.store.dragged != nil })
      if !model.viewportReady {
        ProgressView()
          .controlSize(.large)
          .accessibilityLabel("Loading Viewport")
          .accessibilityIdentifier("blender.viewport.loading")
          .allowsHitTesting(false)
      }
      if controlsShown {
        /* Over the viewport, which ends above the node editor. */
        ZStack {
#if !os(visionOS) /* Ornaments there. */
          QuickActionsRow(model: model)
          ToolRails(model: model)
#endif
          ViewGizmoLayer(model: model)
          TextObjectKeyboard(model: model)
        }
        .padding(.bottom, viewportCover)
      }
      BottomTrayLayer(model: model, timeline: shell.timeline.store, assets: shell.assets.store, shown: controlsShown)
#if !os(visionOS) /* A window of its own there. */
      if controlsShown && model.nodesShown {
        NodeEditorLayer(model: model, nodes: shell.panels.nodes)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
#endif
      if let pencilMenu {
        /* Frontmost; it passes touches through while it is closed. */
        PencilMenuView(menu: pencilMenu)
          .ignoresSafeArea(edges: .vertical)
      }
      if model.interfaceHidden {
        showInterfaceButton
      }
    }
  }

  /** In full screen, faint until a Pencil or pointer comes near, so it does not compete with the
   * work. */
  private var showInterfaceButton: some View {
    VStack {
      HStack {
        Spacer()
        ShowInterfaceButton { commands.setInterfaceHidden(false) }
      }
      Spacer()
    }
    .padding(12)
  }
}

private struct ShowInterfaceButton: View {
  let show: () -> Void
  @State private var near = false

  var body: some View {
    Button(action: show) {
      Image(systemName: "arrow.down.right.and.arrow.up.left")
        .frame(width: 44, height: 44)
    }
    .glassButtonStyle()
    .buttonBorderShape(.circle)
    .opacity(near ? 1 : 0.35)
    .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { near = inside } }
    .accessibilityLabel("Show Interface")
    .accessibilityIdentifier("blender.interface.show")
  }
}

/** The timeline and asset pane along the bottom, the timeline resting on the pane, as far from the
 * window's sides as from its bottom. The controls resting on the bottom edge, and Blender's own
 * overlays such as the navigation gizmo, rise above them. */
struct BottomTrayLayer: View {
  let model: ShellModel
  let timeline: TimelineStore
  @ObservedObject var assets: AssetsStore
  /** Hidden in full screen and over Blender's own interface. */
  let shown: Bool

  private var tray: CGFloat {
    guard shown else { return 0 }
#if os(visionOS)
    let timelineTray: CGFloat = 0 /* A window of its own. */
#else
    let timelineTray = timeline.visible ? TimelinePanel.height(timeline) + 8 : 0
    if docked {
      /* On the bottom edge, as the node editor is. */
      return TimelinePanel.height(timeline) + model.safeAreaInsets.bottom +
        (assets.visible ? AssetsPanel.height(compact: model.compact) + 8 : 0)
    }
#endif
    return timelineTray + (assets.visible ? AssetsPanel.height(compact: model.compact) + 8 : 0)
  }

  /** The curve editor is open: the timeline is docked to the bottom, edge to edge. */
  private var docked: Bool {
#if os(visionOS)
    false
#else
    shown && timeline.visible && timeline.curvesShown
#endif
  }

  var body: some View {
    let safe = model.safeAreaInsets
    let edge = safe.bottom + 6
    let transition = AnyTransition.opacity.combined(with: .offset(y: 14)).combined(with: .scale(scale: 0.98))
    GeometryReader { proxy in
      VStack(spacing: 8) {
        Spacer(minLength: 0)
        if shown {
          if docked && assets.visible {
            /* Floating above the docked timeline. */
            AssetsPanel(store: assets, compact: model.compact)
              .padding(.leading, max(0, max(safe.left, edge) - model.sideInsets.left))
              .padding(.trailing, max(0, max(safe.right, edge) - model.sideInsets.right))
              .transition(transition)
          }
#if !os(visionOS) /* A window of its own there. */
          if timeline.visible {
            TimelinePanel(store: timeline, bottomInset: docked ? safe.bottom : 0)
              .transition(transition)
          }
#endif
          if !docked && assets.visible {
            AssetsPanel(store: assets, compact: model.compact)
              .transition(transition)
          }
        }
      }
      .padding(.leading, docked ? model.sideInsets.left : max(safe.left, edge))
      .padding(.trailing, docked ? model.sideInsets.right : max(safe.right, edge))
      .padding(.bottom, docked ? 0 : edge)
      .onChange(of: [tray, proxy.size.height], initial: true) { _, values in
        trayChanged(values[0], height: values[1])
      }
    }
    .ignoresSafeArea(edges: .vertical)
  }

  private func trayChanged(_ tray: CGFloat, height: CGFloat) {
    /* Under the panel's rounded corners, as with the node editor. */
    let cover = docked ? tray - 24 : 0
    /* With the curve editor open, the controls already rest on the shortened viewport: they only
     * keep clear of the corners reaching over it. */
    let controlsTray = docked ? max(0, tray - cover - model.safeAreaInsets.bottom) : tray
    if abs(controlsTray - model.bottomTray) > 0.5 {
      withAnimation(SwiftTimeline.animation) { model.bottomTray = controlsTray }
    }
    guard height > 0 else { return }
    /* The curve editor shortens the viewport as the node editor does; the tray goes under. */
    timeline.curvesMaximum = max(260, height * 0.82)
    if abs(cover - model.curvesCover) > 0.5 {
      if timeline.curvesDragging {
        model.curvesCover = cover
      }
      else {
        withAnimation(.easeOut(duration: 0.42)) { model.curvesCover = cover }
      }
    }
    model.nodesCoverDragging = timeline.curvesDragging
    if cover > 0 {
      WM_apple_ios_ui_bottom_tray_set(0)
      return
    }
    /* Blender keeps its own overlays, such as the navigation gizmo, above the tray. */
    let top = height - model.safeAreaInsets.bottom - 6 - (tray > 0 ? tray - 8 : 0)
    WM_apple_ios_ui_bottom_tray_set(tray > 0 ? Float((height - top) / height) : 0)
  }
}

/** The Pencil's radial menu, which visionOS does not have. */
typealias PencilMenu = UIView & GHOSTIOSPencilMenu

/** The Pencil's radial menu, over everything else. */
struct PencilMenuView: UIViewRepresentable {
  let menu: PencilMenu

  func makeUIView(context: Context) -> PencilMenu { menu }
  func updateUIView(_ menu: PencilMenu, context: Context) {}
}

/** \} */
