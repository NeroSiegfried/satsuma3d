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
  private var menuBarItems: NSArray = []
  private var menuBarRequested = false
  /** What Blender asks to show where the pointer is, in place of its own popup: from its `popup`
   * view, each once. */
  private let popupView = NativeViews.shared.subscribe("popup")
  private var popupShown: String?
  private var menuBarMode: String?
  /** The size of Blender's own interface Blender last reported, see #desktopScaleChanged. */
  private var desktopScaleSeen: Double?
  private var menuBarTime = Date.distantPast
  private var touchSettingsApplied = false

  @objc(initWithMetalView:window:)
  public init(metalView: MTKView, window: UnsafeMutableRawPointer) {
    let model = ShellModel(window: window)
    let shell = ShellPanels(model: model)
    let commands = ShellCommands(model: model, shell: shell)
#if !os(visionOS)
    SqueezePalette.shared.showSettings = { [weak commands] in commands?.settings?.present() }
#endif
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
    /* Blender's own keymap is the default, as on the desktop: a keyboard attached does what a
     * Blender user expects. Switched once (also on iPads that were set to Industry Compatible by
     * the first launch of earlier builds), then the choice in Settings is respected. */
    if !UserDefaults.standard.bool(forKey: "BlenderKeymapDefaultedBlender") {
      UserDefaults.standard.set(true, forKey: "BlenderKeymapDefaultedBlender")
      BlenderSettings.set("keymap", .text("Blender"))
    }
    if UserDefaults.standard.object(forKey: SettingsModel.hoverHighlightKey) as? Bool == false {
      BlenderSettings.set("hover_highlight", .bool(false))
    }
    SettingsModel.applyNavigationCorner()
    SettingsModel.applyNavigationStyle()
    /* Blender's own interface's size first, so it opens at it. */
    SettingsModel.applyDesktopScale()
    if UserDefaults.standard.bool(forKey: "BlenderDesktopInterface") {
      /* Start in the interface the person left; Blender follows from its inbox. */
      BlenderSettings.set("desktop", .bool(true))
    }
    pencilMenu?.delegate = pencilSource
    wm_apple_ios_window_set_pencil_menu(window, pencilMenu)
    /* Assets dragged out of the pane drop onto the viewport; files from other apps too, see
     * #FileDrop. */
    viewport.addInteraction(shell.assets.dropInteraction)
    installContextMenu()
    /* Siri's phrases name Blender's commands, which Blender can list now. */
    BlenderShortcuts.updateAppShortcutParameters()

    NotificationCenter.default.addObserver(self, selector: #selector(snapshotsPublished),
                                           name: Notification.Name("BlenderSnapshotsPublished"),
                                           object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(templatePresentation(_:)),
                                           name: Notification.Name("BlenderTemplatePresentation"),
                                           object: nil)
    observeScene()
    shell.pullViews()
    NativeViews.shared.checkViews()
    ShellSnapshots.start()
    SoakProbe.start(model: model, shell: shell)
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
    NativeViews.shared.pull()
    commands.render?.updateStatus(BlenderRender.status)
    commands.settings?.updatePreferences(keymap: BlenderSettings.keymap)
    shell.pullViews()
    SoakProbe.shared?.snapshotsPublished()
    pullMenuPopup()
    if desktop != model.desktop { desktopChanged() }
    desktopScaleChanged()
    refreshMenuBar()
  }

  /** Blender's own Window menu changes its interface's size too (Interface Size): kept as Settings
   * keeps it, except in a check launch, as #desktopChanged. The first value seen is only noted, as
   * Blender may report its default before the stored size reaches it. */
  private func desktopScaleChanged() {
    guard let scale = BlenderSettings.desktopScale else { return }
    defer { desktopScaleSeen = scale }
    guard let seen = desktopScaleSeen, abs(seen - scale) > 1e-4,
          ProcessInfo.processInfo.environment["PLATYPUS_SCRATCH_DOCUMENT"] == nil,
          abs(SettingsModel.desktopScale - scale) > 1e-4 else { return }
    UserDefaults.standard.set(scale, forKey: SettingsModel.desktopScaleKey)
  }

  /** Blender's own Window menu can switch to its desktop interface too. */
  private func desktopChanged() {
    let desktop = model.desktop
    /* A check launch (`PLATYPUS_SCRATCH_DOCUMENT`) works in a copy of the General template, which
     * opens in the iPad interface: storing that turned a person's Desktop Interface off
     * (2026-11-18). A check stores none of the person's settings, see #ShellSnapshots. */
    if ProcessInfo.processInfo.environment["PLATYPUS_SCRATCH_DOCUMENT"] == nil {
      UserDefaults.standard.set(desktop, forKey: "BlenderDesktopInterface")
    }
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
    let scale = max(1, view.window?.traitCollection.displayScale ?? traitCollection.displayScale)
    if model.pointScale != scale { model.pointScale = scale }
    noteWindow()
    if model.toolRowChanged == nil {
      model.toolRowChanged = { [weak self] in self?.updateTopBarBottom() }
    }
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
    var header: UINavigationBar?
    while let current = pending.popLast() {
      if let bar = current as? UINavigationBar {
        if !bar.isHidden, bar.alpha > 0.01 {
          bottom = max(bottom, bar.convert(bar.bounds, to: view).maxY)
          header = bar
        }
        continue
      }
      pending.append(contentsOf: current.subviews)
    }
    if model.navigationBarBottom != bottom { model.navigationBarBottom = bottom }
    /* The tool settings row hangs under the header: flush in Blender's style, 6 points below in
     * glass, see #ToolSettingsRow.gap. */
    if bottom > 0 && model.toolRowHeight > 0 { bottom += model.toolRowHeight + ToolSettingsRow.gap }
    if model.topBarBottom != bottom { model.topBarBottom = bottom }
    /* Blender keeps the navigation gizmo below it: in window pixels, sent on every layout (an
     * atomic store, which redraws only on a change), so a resize can never leave it stale. */
    WM_native_ui_top_bar_set(Float(bottom * model.pointScale))
    /* On a new width, and on a new state of the header at the same width (another mode's
     * menus), once it has settled. */
    let state = "\(model.headerRung) \(model.headerMenus) \(model.mode)"
    if let header, header.bounds.width != headerCheckedWidth || state != headerCheckedState {
      headerCheckedWidth = header.bounds.width
      headerCheckedState = state
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak header, weak self] in
        guard let header, let self else { return }
        Self.checkHeaderClipping(header)
        self.checkHeaderSpare(header)
      }
    }
  }

  private var headerCheckedWidth: CGFloat = 0
  private var headerCheckedState = ""

  /** The reverse of the clipping check (ROUND5 7E/E2): a header folded below its widest with
   * more room left between its sides than the next wider state needs by #HeaderLadder's
   * estimate, and more than 48 points, logs `layout: … header spare N at rung R`: an estimate
   * too cautious is caught as a clipped one is. The room is measured between the leading
   * items' end and the trailing items' start, less the 16 points the estimate keeps there. */
  private func checkHeaderSpare(_ bar: UINavigationBar) {
    guard let extra = model.headerNextExtra else { return }
    var leadingEnd: CGFloat = 0
    var trailingStart = bar.bounds.width
    var pending: [UIView] = bar.subviews
    while let current = pending.popLast() {
      guard !current.isHidden, current.alpha > 0.01 else { continue }
      let frame = current.convert(current.bounds, to: bar)
      /* The bar's own backgrounds span it; an item is narrower than half of it. */
      if frame.width > 1, frame.width < bar.bounds.width / 2, frame.height > 1 {
        if frame.midX < bar.bounds.midX { leadingEnd = max(leadingEnd, frame.maxX) }
        else { trailingStart = min(trailingStart, frame.minX) }
      }
      pending.append(contentsOf: current.subviews)
    }
    let spare = trailingStart - leadingEnd - 16
    guard spare > 48, spare > extra else { return }
    let menus = model.headerMenus == Int.max ? "all" : "\(model.headerMenus)"
    LayoutChecker.shared.report("header spare", "\(LayoutChecker.shared.conditions) header spare \(Int(spare)) " +
                                  "at rung \(model.headerRung), menus \(menus), next needs \(Int(extra)) more")
  }

  /** Any of the header's controls cut by its edges, logged as `layout: … header clipped`: the
   * header ladder's width estimates (#HeaderLadder) must keep this from happening. */
  private static func checkHeaderClipping(_ bar: UINavigationBar) {
    var pending: [UIView] = bar.subviews
    var clipped: [String] = []
    while let current = pending.popLast() {
      guard !current.isHidden, current.alpha > 0.01 else { continue }
      if current is UIControl {
        let frame = current.convert(current.bounds, to: bar)
        if frame.width > 1, frame.minX < -1 || frame.maxX > bar.bounds.width + 1 {
          clipped.append(current.accessibilityIdentifier ?? current.accessibilityLabel ?? "\(type(of: current))")
        }
        continue
      }
      pending.append(contentsOf: current.subviews)
    }
    if !clipped.isEmpty {
      LayoutChecker.shared.report("header clipped", "\(LayoutChecker.shared.conditions) header clipped at " +
                                    "\(Int(bar.bounds.width)): " + clipped.joined(separator: ", "))
    }
  }

  /* -------------------------------------------------------------------- */
  /* The window's size, for the layout's evidence */

  private var windowLine = ""

  /** The window's size, width class and style, on every change, as a `window` line once it
   * settles, and as the conditions of the layout checker's lines. */
  private func noteWindow() {
    let size = view.bounds.size
    LayoutChecker.shared.bounds = CGRect(origin: .zero, size: size)
    let style = ShellStyle.current == .glass ? "glass" : "blender"
    let line = "\(Int(size.width))x\(Int(size.height)) \(model.widthClass.name) rung \(model.headerRung) \(style)"
    guard line != windowLine else { return }
    windowLine = line
    LayoutChecker.shared.conditions = line
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self, self.windowLine == line else { return }
      WM_native_ui_log("window", line)
    }
  }

  override public func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
    super.viewWillTransition(to: size, with: coordinator)
    LayoutChecker.shared.resizing = true
    /* With the scene's state: the system resizes a window it is photographing as it leaves the
     * front (ROUND5 10A). */
    WM_native_ui_log("window", "resize begin \(Int(size.width))x\(Int(size.height)) \(sceneState)")
    coordinator.animate(alongsideTransition: nil) { [weak self] _ in
      LayoutChecker.shared.resizing = false
      WM_native_ui_log("window", "resize end \(Int(size.width))x\(Int(size.height)) \(self?.sceneState ?? "")")
      self?.noteWindow()
    }
  }

  private var sceneState: String { (view.window?.windowScene?.activationState ?? .unattached).name }

  /** The scene's comings and goings, as `scene` lines, so a resize can be read against them. */
  private func observeScene() {
    let names: [(Notification.Name, String)] = [
      (UIScene.willDeactivateNotification, "inactive"), (UIScene.didEnterBackgroundNotification, "background"),
      (UIScene.willEnterForegroundNotification, "foreground"), (UIScene.didActivateNotification, "active"),
    ]
    for (name, line) in names {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        MainActor.assumeIsolated {
          guard let self, let scene = note.object as? UIScene, scene === self.view.window?.windowScene else { return }
          WM_native_ui_log("scene", line)
        }
      }
    }
  }

  /* -------------------------------------------------------------------- */
  /* The menu bar */

  /** Projecting all of Blender's menus is costly and they change with the mode, rarely
   * otherwise: ask again when the mode changes, and every few seconds for the rest. */
  private func refreshMenuBar() {
    guard !menuBarRequested,
          menuBarMode != model.objectMode || Date().timeIntervalSince(menuBarTime) >= 3 else { return }
    menuBarTime = Date()
    menuBarMode = model.objectMode
    menuBarRequested = true
    wm_apple_ios_menu_bar_request { [weak self] items in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.menuBarRequested = false
        guard let items, !(items as NSArray).isEqual(to: self.menuBarItems as! [Any]) else { return }
        self.menuBarItems = items as NSArray
        UIMenuSystem.main.setNeedsRebuild()
      }
    }
  }

  override public func buildMenu(with builder: any UIMenuBuilder) {
    super.buildMenu(with: builder)
    wm_apple_ios_build_menu_bar(builder, menuBarItems as! [Any])
    guard builder.system == .main else { return }
    /* Blender's splash and About popups are left out of the menu bar (`hidden_from_menu_bar`); the
     * app's own About takes their place (ROUND5 8A.6, decision 35). */
    let about = UIAction(title: "About \(AppIdentity.name)", image: UIImage(systemName: "info.circle")) { [weak self] _ in
      guard let self else { return }
      SwiftAbout.present(from: self)
    }
    let group = UIMenu(title: "", options: .displayInline, children: [about])
    if builder.menu(for: .about) != nil {
      builder.replace(menu: .about, with: group)
    }
    else if builder.menu(for: .application) != nil {
      builder.insertChild(group, atStartOfMenu: .application)
    }
  }

  @objc public func newDocument(_ sender: Any?) {
    wm_apple_ios_new_document(self)
  }
}

/* Holding a finger on the viewport opens Blender's context menu there. */
extension DocumentController: UIGestureRecognizerDelegate {
  private func installContextMenu() {
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
    guard let top = popupView.top, top.key != popupShown else { return }
    let first = popupShown == nil
    popupShown = top.key
    /* What was asked before this window opened is not shown. */
    guard !first, top.key != "popup:0" else { return }
    let children = popupView.children(of: top)
    func node(_ key: String) -> NativeNode? { children.first { $0.key == key } }
    func data(_ key: String) -> Blender_NativeUI_Data? { node(key)?.content(Blender_NativeUI_Data.self) }
    let bounds = metalView.bounds
    var point = CGPoint(x: bounds.midX, y: bounds.midY)
    if let position = data("position")?.value(type: Blender_NativeUI_FloatsValue.self), position.valueCount == 2 {
      point = CGPoint(x: bounds.width * position.value(at: 0), y: bounds.height * position.value(at: 1))
    }
    if node("rename") != nil {
      BlenderMenus.presentRename(from: self, title: "Rename Active Item", current: model.activeName)
      return
    }
    if let choice = node("choice") {
      let request = EnumChoice(node: choice) { [popupView] value in
        NativeViews.shared.send(popupView, target: "choice", value: .text(value))
      }
      if request.sections.contains(where: { !$0.heading.isEmpty }) {
        /* A long list with headings: a popover keeps them, at the same place a menu would be. */
        var top: UIViewController = self
        while let presented = top.presentedViewController { top = presented }
        weak var list: UIViewController?
        let host = UIHostingController(rootView: EnumChoiceList(request: request) { list?.dismiss(animated: true) })
        list = host
        host.modalPresentationStyle = .popover
        host.preferredContentSize = CGSize(width: 340, height: 520)
        host.popoverPresentationController?.sourceView = metalView
        host.popoverPresentationController?.sourceRect = popupAnchor(point)
        top.present(host, animated: true)
      }
      else if let menu = BlenderMenus.enumMenu(request) {
        ShellMenuPresenter.shared.present(menu, at: popupAnchor(point), in: metalView, kind: "choice " + request.title)
      }
      return
    }
    if let command = data("command")?.value(type: Blender_NativeUI_TextValue.self)?.value {
      runStandIn(command, at: popupAnchor(point))
      return
    }
    guard let menu = data("menu")?.value(type: Blender_NativeUI_TextValue.self)?.value else {
      WM_native_ui_log("menu", "popup \(top.key) asked for nothing this interface knows")
      return
    }
    /* Its title, as Blender's popup has: "UV Mapping", "Delete". */
    let title = top.label.isEmpty ? menu : top.label
    let anchor = popupAnchor(point)
    Task { @MainActor in
      /* An empty answer is said, never dropped (ROUND5 9A.3). */
      guard let items = await BlenderMenus.shared.fetch(BlenderMenus.route(menu)), !items.isEmpty else {
        model.messages.say("\(title) has nothing to show here")
        WM_native_ui_log("menu", "\(menu) empty")
        return
      }
      ShellMenuPresenter.shared.present(BlenderMenus.uiMenu(items, title: title), at: anchor,
                                        in: metalView, kind: "menu " + menu)
    }
  }

  /**
   * The interface's own version of a command a key asked for, which Blender's own interface would
   * show (ROUND5 9A.6): only what a button here already does. The commands are listed in
   * `release/ios/key_stand_ins.txt`, which `bl_native_shell_sources.py` checks against this.
   */
  private func runStandIn(_ command: String, at anchor: CGRect) {
    switch command {
      case "search":
        model.searchOpen = true
      case "settings":
        commands.settings?.present()
      case "properties":
        shell.panels.toggleInspector()
      case "interface":
        commands.setInterfaceHidden(!model.interfaceHidden)
      case "context":
        /* As a long press on the viewport shows it, see #contextMenuPress (ROUND5 9E.2). */
        let menu = wm_apple_ios_context_menu()
        guard !menu.children.isEmpty else {
          model.messages.say("Nothing to show here")
          WM_native_ui_log("menu", "stand-in context empty")
          return
        }
        ShellMenuPresenter.shared.present(menu, at: anchor, in: metalView, kind: "context menu")
      default:
        model.messages.say("This key's command is not in the iPad interface", level: "warning")
        WM_native_ui_log("menu", "stand-in \(command) unknown")
        return
    }
    WM_native_ui_log("menu", "stand-in \(command)")
  }

  @objc private func contextMenuPress(_ press: UILongPressGestureRecognizer) {
    /* Blender's own interface has its own context menus. */
    guard press.state == .began, !model.desktop else { return }
    let point = press.location(in: metalView)
    let menu = wm_apple_ios_context_menu()
    guard !menu.children.isEmpty else { return }
    ShellMenuPresenter.shared.present(menu, at: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                                      in: metalView, kind: "context menu")
  }

  /** Where a menu Blender pops up by itself is shown: at the control just tapped, which asked for
   * it, or else where Blender's pointer is, in the viewport's points. */
  private func popupAnchor(_ point: CGPoint) -> CGRect {
    if let window = metalView.window, let tapped = ShellMenuPresenter.shared.recentTap() {
      return metalView.convert(tapped, from: window.coordinateSpace)
    }
    return CGRect(origin: point, size: CGSize(width: 1, height: 1))
  }

  public func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    /* Only a press or click that starts on the viewport itself, not on a control above it. */
    (touch.type == .direct || touch.type == .indirectPointer) && touch.view === metalView
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Viewport
 * \{ */

/** Holds GHOST's Metal view, sized to the window at the display's full resolution, less what a
 * panel covers at the bottom or the right so the view centers on what can be seen. */
final class ViewportContainer: UIView {
  let metalView: MTKView
  /** Set while the panel's handle is dragged: the cover is followed at once. */
  var live = false
  var bottomCover: CGFloat = 0 {
    didSet {
      if bottomCover != oldValue { animateCover() }
    }
  }
  /** What the Image Editor beside the viewport covers. */
  var trailingCover: CGFloat = 0 {
    didSet {
      if trailingCover != oldValue { animateCover() }
    }
  }
  /** The covers as the viewport is shaped now, eased toward the set ones alongside the panel. */
  private var shownCover: CGFloat = 0
  private var shownTrailingCover: CGFloat = 0
  private var coverAnimation: (from: CGFloat, fromTrailing: CGFloat, start: CFTimeInterval)?
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
      shownTrailingCover = trailingCover
      setNeedsLayout()
      return
    }
    coverAnimation = (shownCover, shownTrailingCover, CACurrentMediaTime())
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
    shownTrailingCover = animation.fromTrailing + (trailingCover - animation.fromTrailing) * eased
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
    WM_native_ui_viewport_cover_set(Float((shownCover * scale).rounded()))
    WM_native_ui_viewport_trailing_cover_set(Float((shownTrailingCover * scale).rounded()))
    if metalView.drawableSize != size {
      noteDrawable(size, from: metalView.drawableSize)
      metalView.drawableSize = size
    }
  }

  /** The window's size when the drawable last changed, to tell a window's resize from the
   * interface's. */
  private var drawableWindowSize = CGSize.zero

  /** Every change of the drawable's size, with its cause, as a `viewport drawable` line (ROUND5
   * 10A): `window` when the window's size changed with it, `layout` when only the interface
   * around the viewport did, `first` for the first size; and the scene's state unless it is in
   * front. */
  private func noteDrawable(_ size: CGSize, from old: CGSize) {
    let windowSize = window?.bounds.size ?? .zero
    defer { drawableWindowSize = windowSize }
    let cause = old.width <= 1 || old.height <= 1 ? "first" : windowSize != drawableWindowSize ? "window" : "layout"
    let state = window?.windowScene?.activationState ?? .unattached
    WM_native_ui_log("viewport", "drawable \(Int(size.width))x\(Int(size.height)) <- " +
                     "\(Int(old.width))x\(Int(old.height)) (\(cause)\(state == .foregroundActive ? "" : ", " + state.name))")
  }
}

extension UIScene.ActivationState {
  /** As the session log writes it. */
  var name: String {
    switch self {
      case .foregroundActive: "active"
      case .foregroundInactive: "inactive"
      case .background: "background"
      case .unattached: "unattached"
      @unknown default: "unknown"
    }
  }
}

struct ViewportView: UIViewRepresentable {
  let container: ViewportContainer
  var bottomCover: CGFloat = 0
  var trailingCover: CGFloat = 0
  var live = false

  func makeUIView(context: Context) -> ViewportContainer { container }
  func updateUIView(_ view: ViewportContainer, context: Context) {
    view.live = live
    view.bottomCover = bottomCover
    view.trailingCover = trailingCover
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
  /** The viewport's size, with the Image Editor's beside or below it. */
  @State private var layersSize = CGSize.zero
  /** How much of that the 3D viewport has, the Image Editor the rest. */
  @AppStorage("BlenderImageSplit") private var imageSplit = 0.5
  /** The Image Editor below the 3D viewport rather than beside it. */
  @AppStorage("BlenderImageSplitAcross") private var imageSplitAcross = false
  /** The split as the divider is dragged, kept once it is let go. */
  @State private var imageSplitDrag: Double?
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage(ShellStyle.key) private var interfaceStyle = ShellStyle.blender.rawValue

  /** The native controls are hidden in full screen, and over Blender's own interface. */
  private var controlsShown: Bool { !model.desktop && !model.interfaceHidden }
  /** The editors docked along the bottom, such as the timeline, Story and nodes: work, not
   * controls, so they stay as the interface hides. */
  private var editorsShown: Bool { !model.desktop }

  /** The Outliner is the sidebar, which slides in and pushes the viewport over, and
   * Properties the inspector on the other side. A phone shows both as sheets. On Apple Vision Pro
   * they are windows of their own. */
  public var body: some View {
    window
#if !os(visionOS)
      /* The palette a Pencil's squeeze shows, over everything; its commands follow the context. */
      .overlay { SqueezePaletteLayer() }
#endif
      .environment(\.blenderMenuContext, model.menuContext)
      /* An operator's settings, asked for before it runs, in place of Blender's dialog. */
      .sheet(isPresented: Binding(get: { shell.panels.dialog.operation != nil && !model.desktop }, set: { shown in
        /* Swiped away: as Cancel. */
        if !shown { shell.panels.dialog.finishOperation("cancel") }
      })) {
        OperatorDialog(model: shell.panels.dialog)
          .presentationDetents([.medium, .large])
      }
#if !os(visionOS)
      /* The scene in the room, through the camera. */
      .fullScreenCover(isPresented: Bindable(ARPreviewState.shared).shown) { ARPreview() }
      /* Over the bars too, which it dims while a Pencil rolls through it. */
      .overlay { RollDialLayer() }
      .overlay { ColorRollLayer() }
#endif
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
          PropertiesPanel(model: shell.panels.properties) { shell.panels.setInspectorShown(false) }
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
          DocumentToolbar(model: model, shell: shell, commands: commands)
        }
        .toolbar(controlsShown ? .visible : .hidden, for: .navigationBar)
        .toolbarTitleDisplayMode(.inline)
        .headerSurface(interfaceStyle)
        /* No editor role: the system would move a whole side into its own overflow at once. The
         * header folds one rung at a time instead, see #HeaderLadder. */
    }
    .headerLadder(model)
  }

  private var columnLayout: some View {
    /* The sidebars end above the editors docked along the bottom, which keep the window's whole
     * width: opening one does not narrow the node editor, the Story or the timeline. */
    /* Under their rounded top, as the viewport is. */
    let docked = viewportCover
    let hierarchy = model.hierarchyShown && controlsShown
    let inspector = model.inspectorShown && controlsShown
    return ZStack(alignment: .bottom) {
      HStack(spacing: 0) {
        if hierarchy {
          HierarchyPanel(store: shell.panels.hierarchy) { shell.panels.setHierarchyShown(false) }
            .environment(\.panelInWindow, true)
            .frame(width: Self.hierarchyWidth)
            .background(Color(uiColor: .secondarySystemBackground).ignoresSafeArea(edges: .vertical))
            .padding(.bottom, docked)
            .transition(.move(edge: .leading))
            .accessibilityIdentifier("blender.hierarchy.panel")
        }
        layers(bottom: false)
        if inspector {
          PropertiesPanel(model: shell.panels.properties) { shell.panels.setInspectorShown(false) }
            .environment(\.panelInWindow, true)
            .frame(width: Self.inspectorWidth)
            /* Blender's editor grey and light text in its style, as the tool settings row
             * (ROUND5 7B); the system's grouped background in glass. */
            .background((interfaceStyle == ShellStyle.glass.rawValue ? Color(uiColor: .secondarySystemBackground) :
                          ShellStyle.region).ignoresSafeArea(edges: .vertical))
            .environment(\.colorScheme, interfaceStyle == ShellStyle.glass.rawValue ? colorScheme : .dark)
            .padding(.bottom, docked)
            .transition(.move(edge: .trailing))
            .accessibilityIdentifier("blender.inspector.panel")
        }
      }
      bottomLayers(leading: hierarchy ? Self.hierarchyWidth : 0, trailing: inspector ? Self.inspectorWidth : 0)
    }
    .animation(.easeOut(duration: 0.42), value: docked)
    .onChange(of: model.widthClass, initial: true) { _, width in shell.panels.narrow = width < .wide }
  }

  static let hierarchyWidth: CGFloat = 320
  static let inspectorWidth: CGFloat = 336
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
          DocumentToolbar(model: model, shell: shell, commands: commands)
        }
        .toolbar(controlsShown ? .visible : .hidden, for: .navigationBar)
        .toolbarTitleDisplayMode(.inline)
        .headerSurface(interfaceStyle)
        .headerLadder(model)
#if os(visionOS)
        .visionOrnaments(model: model, shown: controlsShown && model.windowVisible)
#endif
    }
  }

  /** The viewport and the controls over it, then Properties and the Outliner, which keep below the
   * toolbar. */
  private var layers: some View { layers(bottom: true) }

  /** \a bottom: the editors along the bottom in the viewport's column too, as on a phone. */
  private func layers(bottom: Bool) -> some View {
    ZStack {
      /* Under the bars, but beside the sidebar and inspector, which are the side safe areas: the
       * viewport and its controls move with the columns as they slide. */
      viewportLayers(bottom: bottom)
        .ignoresSafeArea(edges: .vertical)
      CompileIndicator(progress: shell.compile)
    }
  }

  /** The timeline, assets and node editor along the bottom. Docked, they span the window; floating,
   * they keep over the viewport, beside the sidebars \a leading and \a trailing wide. */
  private func bottomLayers(leading: CGFloat = 0, trailing: CGFloat = 0) -> some View {
    let docked = shell.timeline.store.editorShown && shell.timeline.store.visible
    return ZStack {
      BottomTrayLayer(model: model, timeline: shell.timeline.store, assets: shell.assets.store, shown: editorsShown)
        .padding(.leading, docked ? 0 : leading)
        .padding(.trailing, docked ? 0 : trailing)
#if !os(visionOS) /* A window of its own there. */
      if editorsShown && model.nodesShown {
        DockedEditorLayer(model: model, cover: Bindable(model).nodesCover, resizeLabel: "Resize Node Editor") {
          NodeEditorPanel(model: shell.panels.nodes)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
#endif
    }
    .ignoresSafeArea(edges: .vertical)
  }

  /** How much of the window's bottom the viewport leaves to the node editor. */
  private var viewportCover: CGFloat {
    editorsShown ? max(model.nodesShown ? model.nodesCover : 0, model.curvesCover) : 0
  }

  /** The Image Editor, a viewport of its own: beside the 3D one, or over it on a phone. */
  private var imageViewportShown: Bool {
#if os(visionOS) /* A window of its own there. */
    false
#else
    editorsShown && model.imageShown
#endif
  }

  /** Along the split: the width beside each other, the height one above the other. */
  private var layersLength: CGFloat { imageSplitAcross ? layersSize.height : layersSize.width }

  /** The Image Editor's width beside the 3D viewport, or its height below it, leaving each room
   * to work in. */
  private var imageLength: CGFloat {
    guard imageViewportShown, sizeClass != .compact, layersLength > 0 else { return 0 }
    let least = imageLeast
    return min(max(layersLength * (1 - (imageSplitDrag ?? imageSplit)), least), layersLength - least)
  }

  private var imageLeast: CGFloat { min(320, layersLength / 3) }

  /** How far the divider goes: the 3D viewport's share, each side keeping room to work in. */
  private var imageSplitRange: ClosedRange<Double> {
    guard layersLength > 0 else { return 0.15...0.85 }
    let least = Double(imageLeast / layersLength)
    return max(0.15, least)...min(0.85, 1 - least)
  }

  private func viewportLayers(bottom: Bool) -> some View {
    let beside = imageLength > 0
    let across = imageSplitAcross
    let split = across ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
    /* The Image Editor lies over the 3D viewport, which keeps its size and is told what is
     * covered: resizing its drawable as the divider moves would drop frames. */
    let covered = beside ? imageLength + ImageSplitHandle.width : 0
    return ZStack {
      ZStack {
        /* Edge to edge, under a phone's toolbar column too; above the Image Editor, what is
         * docked below covers it no more. */
        ViewportView(container: viewport, bottomCover: beside && across ? covered : viewportCover,
                     trailingCover: beside && !across ? covered : 0,
                     live: model.nodesCoverDragging || imageSplitDrag != nil)
          .ignoresSafeArea()
          .onDrop(of: [.data, .image], delegate: FileDrop(model: model) { shell.assets.store.dragged != nil })
        if !model.viewportReady {
          ProgressView()
            .controlSize(.large)
            .accessibilityLabel("Loading Viewport")
            .accessibilityIdentifier("blender.viewport.loading")
            .allowsHitTesting(false)
            .padding(across ? .bottom : .trailing, covered)
        }
      }
      if beside {
        split {
          ImageSplitHandle(fraction: $imageSplit, dragged: $imageSplitDrag, across: $imageSplitAcross,
                           length: layersLength, range: imageSplitRange)
          imageViewport
            .frame(width: across ? nil : imageLength, height: across ? imageLength : nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: across ? .bottom : .trailing)
        .transition(.move(edge: across ? .bottom : .trailing))
      }
      if imageViewportShown && !beside {
        imageViewport
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
      if controlsShown {
        /* Over the viewport, which ends above the node editor. */
        ZStack {
          /* The 3D viewport's own, beside the Image Editor. */
          ZStack {
#if !os(visionOS) /* Ornaments there. */
            QuickActionsRow(model: model, redo: shell.panels.redo, item: shell.panels.item)
              /* The Pencil's dial takes over while it shows. */
              .opacity(RollDial.shared.showing ? 0 : 1)
              .animation(.easeOut(duration: 0.18), value: RollDial.shared.showing)
#endif
            ViewGizmoLayer(model: model)
            /* Blender's Tool Settings bar, under the header, unless the window is compact: flush
             * and full width in Blender's style, as its tool header; a capsule hugging its items,
             * a little below, in glass. */
            if !model.compact && !model.desktop {
              let glass = interfaceStyle == ShellStyle.glass.rawValue
              GeometryReader { proxy in
                ToolSettingsRow(model: model, shell: shell)
                  .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.toolRowHeight = $0 }
                  .onDisappear { model.toolRowHeight = 0 }
                  .padding(.leading, glass ? model.sideInsets.left + 14 : 0)
                  .padding(.trailing, glass ? model.sideInsets.right + 14 : 0)
                  .frame(width: proxy.size.width, alignment: .leading)
                  .offset(y: model.navigationBarBottom - proxy.frame(in: .global).minY + ToolSettingsRow.gap)
              }
              .ignoresSafeArea()
            }
            TextObjectKeyboard(model: model)
          }
          .padding(across ? .bottom : .trailing,
                   beside ? max(0, imageLength + ImageSplitHandle.width - (across ? viewportCover : 0)) : 0)
          .opacity(imageViewportShown && !beside ? 0 : 1)
#if !os(visionOS)
          /* Across both: the tools and sliders on one side, the brushes on the other, painting on
           * either, as Blender's Texture Paint workspace has them. */
          ToolRails(model: model, gizmoShown: !imageViewportShown)
#endif
        }
        .padding(.bottom, viewportCover)
      }
      if bottom {
        bottomLayers()
      }
      if let pencilMenu {
        /* Frontmost; it passes touches through while it is closed. */
        PencilMenuView(menu: pencilMenu)
          .ignoresSafeArea(edges: .vertical)
      }
      if model.interfaceHidden {
        showInterfaceButton
      }
    }
    .onGeometryChange(for: CGSize.self) { $0.size } action: { layersSize = $0 }
    .animation(.easeOut(duration: 0.42), value: imageViewportShown)
    .animation(.spring(response: 0.42, dampingFraction: 0.86), value: imageSplitAcross)
  }

  /** The Image Editor, fitting its image clear of the bar, the brushes and what is docked below. */
  private var imageViewport: some View {
    ImageEditorPanel(model: shell.panels.image,
                     obscured: EdgeInsets(top: model.topBarBottom + 60, leading: 0,
                                          bottom: model.safeAreaInsets.bottom + 12,
                                          trailing: controlsShown ? 84 : 0))
      .padding(.bottom, viewportCover)
      .accessibilityIdentifier("blender.image.viewport")
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

/** Between the 3D viewport and the Image Editor: dragged, it gives one more room and the other
 * less, where it stays, drawn into the middle, the thirds and the quarters as it nears them; held,
 * it turns the split, the Image Editor below the 3D viewport rather than beside it, or back. */
struct ImageSplitHandle: View {
  static let width: CGFloat = 1
  /** The 3D viewport's share, kept. */
  @Binding var fraction: Double
  /** The share as it is dragged, followed at once, kept in `fraction` once let go. */
  @Binding var dragged: Double?
  @Binding var across: Bool
  /** The split's length, along which it is dragged. */
  let length: CGFloat
  let range: ClosedRange<Double>
  @State private var start: Double?
  /** Held still a moment: the split turns, and the touch does nothing more. */
  @State private var hold: DispatchWorkItem?
  @State private var turned = false
  @State private var detent: Double?

  private static let detents: [Double] = [1 / 4, 1 / 3, 1 / 2, 2 / 3, 3 / 4]
  /** The grabber's length, and while it is held. */
  private static let grabber: CGFloat = 36
  private static let grabberLifted: CGFloat = 48

  /** How near a detent, in points, starts drawing the divider in: never past halfway to the
   * next. */
  private var reach: Double { min(32, Double(length) / 24 * 0.9) }

  private func nearest(_ value: Double) -> Double? {
    Self.detents.filter { range.contains($0) }.min { abs($0 - value) < abs($1 - value) }
  }

  /** Where the divider shows for the finger at \a value: the finger's own place, but drawn into
   * a detent within reach, gently at first, so it settles there and eases back out without a
   * jump. The second value is the detent it rests on. */
  private func drawn(_ value: Double) -> (Double, Double?) {
    guard length > 0, let near = nearest(value) else { return (value, nil) }
    let off = (value - near) * Double(length)
    let x = abs(off) / reach
    guard x < 1 else { return (value, nil) }
    /* Flat at the detent, meeting the finger's own pace at the edge of reach. */
    let pulled = reach * (2 * x * x - x * x * x)
    return (near + (off < 0 ? -pulled : pulled) / Double(length), x < 0.4 ? near : nil)
  }

  var body: some View {
    let lifted = start != nil && !turned
    let long = lifted ? Self.grabberLifted : Self.grabber
    /* The line stops short of the grabber rather than running through it. */
    let gap = long + 16
    ZStack {
      Rectangle()
        .fill(Color.black)
        .mask {
          Rectangle()
            .overlay {
              Capsule()
                .frame(width: across ? gap : nil, height: across ? nil : gap)
                .blendMode(.destinationOut)
            }
            .compositingGroup()
        }
    }
    .frame(width: across ? nil : Self.width, height: across ? Self.width : nil)
    .ignoresSafeArea()
    .overlay {
      Capsule()
        .fill(.white.opacity(lifted ? 0.95 : 0.7))
        .shadow(color: .black.opacity(0.35), radius: 3)
        .frame(width: across ? long : 6, height: across ? 6 : long)
        .frame(width: across ? 120 : 44, height: across ? 44 : 120)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
          .onChanged { value in
            if start == nil {
              Haptics.selection()
              start = fraction
              dragged = fraction
              turned = false
              detent = nil
              let item = DispatchWorkItem {
                turned = true
                dragged = nil
                Haptics.impact(.medium)
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { across.toggle() }
              }
              hold = item
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
            }
            let moved = across ? value.translation.height : value.translation.width
            if abs(moved) > 6 || abs(across ? value.translation.width : value.translation.height) > 6 {
              hold?.cancel()
            }
            guard !turned, let from = start, length > 0 else { return }
            let finger = min(range.upperBound, max(range.lowerBound, from + Double(moved / length)))
            let (shown, at) = drawn(finger)
            if at != detent {
              if at != nil { Haptics.selection() }
              detent = at
            }
            /* Not animated: the divider stays under the finger. */
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { dragged = shown }
          }
          .onEnded { _ in
            hold?.cancel()
            hold = nil
            if !turned, let shown = dragged {
              /* Settles into a detent it was drawn toward. */
              let rest = nearest(shown).flatMap { abs($0 - shown) * Double(length) < reach ? $0 : nil } ?? shown
              fraction = shown
              dragged = nil
              withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { fraction = rest }
            }
            else {
              dragged = nil
            }
            start = nil
            detent = nil
          })
        .hoverEffect(.highlight)
        .accessibilityElement()
        .accessibilityLabel("Resize Image Editor")
        .accessibilityAdjustableAction { direction in
          fraction = min(range.upperBound, max(range.lowerBound, fraction + (direction == .increment ? 0.1 : -0.1)))
        }
        .accessibilityAction(named: across ? "Image Editor Beside" : "Image Editor Below") {
          across.toggle()
        }
    }
    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: lifted)
    .zIndex(1)
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
    shown && timeline.visible && timeline.editorShown
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
      WM_native_ui_bottom_tray_set(0)
      return
    }
    /* Blender keeps its own overlays, such as the navigation gizmo, above the tray. */
    let top = height - model.safeAreaInsets.bottom - 6 - (tray > 0 ? tray - 8 : 0)
    /* In window pixels from the bottom: a fraction of the height is wrong once the window is
     * resized. */
    WM_native_ui_bottom_tray_set(tray > 0 ? Float((height - top) * model.pointScale) : 0)
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
