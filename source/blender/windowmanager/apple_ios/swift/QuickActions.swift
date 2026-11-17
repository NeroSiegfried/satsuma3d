/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The row along the bottom of the document window: quick actions for what is selected, Blender's
 * full context menu, and Adjust Last Operation.
 *
 * Folded, the actions are an "Actions" pill. Open, they are a bar like an edit menu, centered on
 * the viewport: a close button, the actions' titles, and a button for the full context menu. The
 * last operation is a pill beside them, opening into a strip of its settings. Only one of the two
 * is open at a time. Each pill grows into what it opens, and folds back into it.
 */

import SwiftUI
import UIKit

/** Sizes shared by the window's controls. */
enum ShellMetrics {
  /** The tool rail's distance from the leading edge. */
  static let railLeading: CGFloat = 14
  /** The navigation gizmo's corner, which the row stays clear of until Blender places it. */
  static let gizmoReserve: CGFloat = 124
  static let rowHeight: CGFloat = 56
  static let buttonHeight: CGFloat = 44
  static let actionsPillWidth: CGFloat = 88
  /** The open quick actions, a capsule with a circle at either end. */
  static let barHeight: CGFloat = 50
  static let barCircle: CGFloat = 42
  /** From the bottom edge of the safe area. */
  static let rowBottom: CGFloat = 6
  /** Wide enough for the strip to open in the row itself, beside the actions. */
  static let wideRow: CGFloat = 700
}

/* -------------------------------------------------------------------- */
/** \name Quick actions
 * \{ */

/** A quick action, a button of the toolbar's `actions`. */
struct QuickAction: Identifiable, Equatable {
  /** Its node's key, which runs it. */
  let id: String
  let title: String
  /** The operator it runs, for its icon. */
  let operatorName: String
  /** An X, Y or Z key while a transform runs, to constrain it to that axis. */
  let key: String
  let icon: String
  let selected: Bool
  /** The Blender menu it opens, such as `VIEW3D_MT_mirror`: shown as a menu at the item. */
  var menu = ""

  var axis: Bool { ["X", "Y", "Z"].contains(key) }

  @MainActor
  static func list(_ nodes: [NativeNode]) -> [QuickAction] {
    nodes.compactMap { node in
      guard let button = node.content(Blender_NativeUI_Button.self), !node.label.isEmpty else { return nil }
      let operatorName = button.operator_ ?? ""
      var menu = ""
      if operatorName == "WM_OT_call_menu" {
        menu = (0..<button.paramsCount).compactMap { button.params(at: $0) }
          .first { $0.key == "name" }?.value(type: Blender_NativeUI_TextValue.self)?.value ?? ""
      }
      return QuickAction(id: node.key, title: node.label, operatorName: operatorName,
                         key: button.key ?? "", icon: node.icon ?? "", selected: button.pressed, menu: menu)
    }
  }

  /** Its menu's route, for `BlenderMenuItems`. */
  @MainActor var menuRoute: String { BlenderMenus.route(menu) }

  var image: UIImage? {
    if key == "RET" { return UIImage(systemName: "checkmark") }
    if key == "ESC" { return UIImage(systemName: "xmark") }
    if !key.isEmpty { return nil }
    if !icon.isEmpty, let image = BlenderIcon.image(icon) { return image }
    return wm_apple_ios_action_icon(operatorName, "", "")
  }

  /** Confirm or Cancel of a move that waits for Enter or Escape. */
  var modalKey: Bool { ["RET", "ESC"].contains(key) }

  @MainActor
  func run(in model: ShellModel) {
    if id == "modal:pad" {
      /* The number pad, for typing a value into the waiting operation. */
      withAnimation(.easeOut(duration: 0.18)) { NumberPadState.shared.shown.toggle() }
      return
    }
    if id.hasPrefix("pin:") {
      /* Pinned from Search: run as Search runs it. */
      CommandSearch.shared.run(id: String(id.dropFirst("pin:".count)))
      return
    }
    if modalKey {
      wm_apple_ios_window_send_key(model.window, key)
      return
    }
    /* What opens afterwards is Blender's to say, see #RevealCoordinator. */
    model.send(id, .invoke)
  }

  var axisColor: Color {
    switch key {
      case "X": .red
      case "Y": .green
      default: .blue
    }
  }
}

struct QuickActionButton: View {
  let action: QuickAction
  let model: ShellModel
  /** On glass of its own, such as an ornament's: plain unless selected. */
  var onGlass = false

  var body: some View {
    Button {
      action.run(in: model)
    } label: {
      label
        .frame(height: ShellMetrics.buttonHeight)
        .frame(minWidth: action.axis ? 60 : nil)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .panelGlass(glass, interactive: true, in: Capsule())
    .accessibilityLabel(action.axis ? "\(action.key) axis constraint" : action.title)
    .accessibilityValue(action.axis ? (action.selected ? "On" : "Off") : "")
    .accessibilityAddTraits(action.selected ? .isSelected : [])
    .accessibilityIdentifier(action.id.hasPrefix("action:") ? "blender.action.\(action.id.dropFirst("action:".count))" :
                               action.operatorName)
  }

  private var glass: PanelGlass {
    if action.selected { return .tinted(action.axis ? action.axisColor : .blue) }
    return onGlass ? .none : .regular
  }

  @ViewBuilder
  private var label: some View {
    if action.axis {
      /* Black lettering stays readable on the bright axis-colored glass. */
      HStack(spacing: action.selected ? 4 : 0) {
        Text(action.key)
          .font(.system(size: 17, weight: .semibold))
        if action.selected {
          Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .bold))
        }
      }
      .foregroundStyle(action.selected ? Color.black : action.axisColor)
      .padding(.horizontal, 8)
    }
    else {
      HStack(spacing: 5) {
        if let image = action.image {
          Image(uiImage: image)
            .renderingMode(image.renderingMode == .alwaysOriginal ? .original : .template)
            .font(.system(size: 20))
        }
        Text(action.title)
          .font(.system(size: 17))
          .lineLimit(1)
      }
      .foregroundStyle(action.selected ? Color.white : Color.primary)
      .padding(.horizontal, 10)
    }
  }
}

/** A quick action in the bar: its icon, which a hold names; its title where it has no icon. */
struct QuickActionBarItem: View {
  let action: QuickAction
  let model: ShellModel
  /** Its name while held, with its middle in the bar, for the bar to show above it; nil after. */
  var name: (String?, CGFloat) -> Void = { _, _ in }
  /** Held long enough to name it: the hold shows its name instead of running it. */
  @State private var heldToName = false
  @State private var midX: CGFloat = 0

  private var destructive: Bool {
    action.icon == "TRASH" || action.operatorName.hasSuffix(".delete")
  }

  /** Shown as its icon, where it has one: axis keys and actions without one keep their text. */
  private var image: UIImage? { action.axis ? nil : action.image }

  /** The item's face, the same whether it runs or opens a menu. */
  private var face: some View {
    label
      .padding(.horizontal, action.axis ? 12 : (image != nil ? 10 : 14))
      .frame(height: ShellMetrics.barCircle)
      .frame(minWidth: action.axis ? 52 : (image != nil ? ShellMetrics.barCircle : nil))
      .background {
        if action.selected {
          Capsule().fill(action.axis ? action.axisColor : Color(uiColor: .systemBlue))
        }
      }
      .contentShape(Capsule())
  }

  var body: some View {
    if action.menu.isEmpty {
      runningItem
    }
    else {
      /* A menu, as every menu of the shell: the system's list at the item, its title on top,
       * which names it as a hold would. */
      Menu {
        Section(action.title) { BlenderMenuItems(route: action.menuRoute) }
      } label: {
        face
      }
      .menuStyle(.button)
      .buttonStyle(QuickActionPressStyle(shape: Capsule()))
      .prefetchingBlenderMenu(action.menuRoute)
      .help(action.title)
      .accessibilityLabel(action.title)
      .accessibilityIdentifier("blender.action.\(action.id.dropFirst("action:".count))")
    }
  }

  private var runningItem: some View {
    Button {
      if heldToName {
        heldToName = false
        return
      }
      action.run(in: model)
    } label: {
      face
    }
    .buttonStyle(QuickActionPressStyle(shape: Capsule()))
    /* A menu Blender opens for it, such as Merge's choices, opens beside it. */
    .anchorsMenus()
    /* A hold names it, in a popover the bar's scrolling cannot clip; lifting the finger ends it. */
    .simultaneousGesture(
      LongPressGesture(minimumDuration: 0.4, maximumDistance: 12)
        .onEnded { _ in
          if action.axis {
            /* Held, an axis locks its plane, as Shift and the axis key do. */
            Haptics.selection()
            heldToName = true
            model.send("modalkey:shift+" + action.key, .invoke)
            return
          }
          guard image != nil else { return }
          Haptics.selection()
          heldToName = true
          name(action.title, midX)
        }
        .sequenced(before: DragGesture(minimumDistance: 0))
        .onEnded { _ in
          name(nil, 0)
          /* The button may or may not see the lift as a tap: either way, the next one is a tap. */
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { heldToName = false }
        })
    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(QuickActionsRow.barSpace)).midX } action: { midX = $0 }
    .help(action.title)
    .accessibilityLabel(action.axis ? "\(action.key) axis constraint" : action.title)
    .accessibilityValue(action.axis ? (action.selected ? "On" : "Off") : "")
    .accessibilityAddTraits(action.selected ? .isSelected : [])
    .accessibilityIdentifier(action.id.hasPrefix("action:") ? "blender.action.\(action.id.dropFirst("action:".count))" :
                               action.operatorName)
  }

  private var tint: Color {
    action.selected ? Color.white : destructive ? Color(uiColor: .systemRed) : Color.primary
  }

  @ViewBuilder
  private var label: some View {
    if action.axis {
      /* Black lettering stays readable on the bright axis color. */
      HStack(spacing: action.selected ? 4 : 0) {
        Text(action.key)
          .font(.system(size: 17, weight: .semibold))
        if action.selected {
          Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .bold))
        }
      }
      .foregroundStyle(action.selected ? Color.black : action.axisColor)
    }
    else if let image {
      Image(uiImage: image)
        .renderingMode(image.renderingMode == .alwaysOriginal ? .original : .template)
        .resizable()
        .scaledToFit()
        .frame(width: 24, height: 24)
        .foregroundStyle(tint)
    }
    else {
      Text(action.title)
        .font(.system(size: 17))
        .lineLimit(1)
        .foregroundStyle(tint)
    }
  }
}

/** Highlights a control on the bar while it is pressed. */
struct QuickActionPressStyle<S: Shape>: ButtonStyle {
  let shape: S

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(shape.fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0)))
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name The row
 * \{ */

struct QuickActionsRow: View {
  static let barSpace = "blender.quick-actions.bar"
  let model: ShellModel
  let redo: PanelsModel
  /** The 3D View's sidebar Item tab, see #ItemCard. */
  let item: PanelsModel
  @State private var itemFolded = false
  @AppStorage(ItemCardTools.shownKey) private var itemCardEnabled = true
  /** The held action's name and its middle in the bar, shown above the bar as Blender's tooltip. */
  @State private var heldName: (text: String, x: CGFloat)?
  @AppStorage(ShellStyle.key) private var style = ShellStyle.blender.rawValue
  @State private var actionsOpen = false
  /** Opened because an operation started waiting, rather than by the person. */
  @State private var openedForModal = false
  /** The operation the user opened the strip for; another operation arrives folded. */
  @State private var redoOpenID: String?
  /** Blender's count of requests to open the strip (F9, the Edit menu), to open it for a new one. */
  @State private var redoShowRequests: UInt32?
  @State private var redoError: String?
  /** The strip hugs its settings, measured as they lay out. */
  @State private var redoContentWidth: CGFloat = 0
  /** The actions' own width in the bar, measured ahead of opening it. */
  @State private var actionItemsWidth: CGFloat = 0
  @AppStorage(SettingsModel.showQuickActionsKey) private var showQuickActions = true

  /** The Item card shows with a transform tool, in Object and Edit Mode. */
  private var itemWanted: Bool {
    itemCardEnabled && ItemCardTools.properties(for: model.activeTool) != nil &&
      ["objectmode", "mesh_edit"].contains(model.mode)
  }

  private var actions: [QuickAction] {
    guard showQuickActions else { return [] }
    let own = QuickAction.list(model.actions)
    /* Pinned commands follow, but not while a move takes keys: then the bar is its keys. */
    guard !own.contains(where: { !$0.key.isEmpty }) else { return own }
    let ids = Set(own.map(\.id))
    /* A pinned action the registry already shows is not shown twice. */
    return own + CommandSearch.shared.pinnedActions.filter { !ids.contains(String($0.id.dropFirst("pin:".count))) }
  }

  /** An operation waits for keys: the bar is its modal bar. */
  private var modalRunning: Bool { actions.contains { $0.modalKey } }

  /** Blender's full context menu follows the actions, but not while a transform takes keys. */
  private var contextMenuAvailable: Bool {
    !actions.isEmpty && !actions.contains { !$0.key.isEmpty }
  }

  private var redoOpen: Bool {
    redoOpenID != nil && redoOpenID == redo.operationKey && !redo.operationColumns.isEmpty
  }

  /** The last operation's short name, while it has settings to adjust. */
  private var redoTitle: String? {
    guard let operation = redo.operation, !redo.operationColumns.isEmpty else { return nil }
    return operationShortNames[operation.idname ?? ""] ?? redo.title
  }

  private var redoPillTitle: String? {
    redoOpen ? nil : redoTitle
  }

  private var animation: Animation? {
    UIAccessibility.isReduceMotionEnabled ? nil : .spring(response: 0.36, dampingFraction: 0.86)
  }

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      /* The lane between the tool rail and the navigation gizmo, above a row of rails, from where
       * their layouts put them, see #ShellLayout.band. */
      let origin = geometry.frame(in: .global).origin
      let band = ShellLayout.band(
        size: geometry.size, sideInsets: model.sideInsets, safeBottom: model.safeAreaInsets.bottom,
        tray: model.bottomTray, rails: model.rails,
        gizmo: model.navigationGizmoRect?.offsetBy(dx: -origin.x, dy: -origin.y),
        footprint: model.navigationFrame?.offsetBy(dx: -origin.x, dy: -origin.y),
        keyboardLift: KeyboardLift.shared.stripLift)
      let laneLeading = band.laneLeading
      let laneWidth = band.laneWidth
      let wide = width >= ShellMetrics.wideRow
      let pillWidth = redoTitle.map(redoPillWidth) ?? 0
      /* With the actions open, the last operation's name and settings sit above them, so neither
       * covers the other; folded, its pill follows the Actions pill in the row. */
      let redoAbove = actionsOpen && !actions.isEmpty
      let pillInRow = redoPillTitle != nil && !redoAbove
      let barWidth = actionsBarWidth(maxWidth: laneWidth)
      let actionsWidth = actions.isEmpty ? 0 : actionsOpen ? barWidth : ShellMetrics.actionsPillWidth
      let rowWidth = actionsWidth + (pillInRow ? (actionsWidth > 0 ? 8 : 0) + pillWidth : 0)
      /* Folded, the pills rest beside the tool rail; open, the row centers on the viewport,
       * staying in the lane. */
      let rowX = actionsOpen ?
        min(max(width / 2 - rowWidth / 2, laneLeading), laneLeading + laneWidth - rowWidth) : laneLeading
      VStack(spacing: 0) {
        Spacer(minLength: 0)
        /* Merging only glass that touches, so neighbouring buttons stay separate capsules. */
        PanelGlassGroup(spacing: 2) {
          ZStack(alignment: .leading) {
            if !actions.isEmpty {
              actionsMorph(frame: CGRect(x: rowX, y: 0, width: actionsWidth,
                                         height: actionsOpen ? ShellMetrics.barHeight : ShellMetrics.buttonHeight),
                           itemsWidth: barWidth - actionsBarChrome)
            }
            if let title = redoTitle {
              redoMorph(title: title, frame: redoOpen ?
                          stripFrame(width: width, laneLeading: laneLeading, laneWidth: laneWidth,
                                     wide: wide && !redoAbove, actionsWidth: actionsWidth) :
                          redoAbove ?
                          CGRect(x: rowX + actionsWidth - pillWidth,
                                 y: -(ShellMetrics.barHeight / 2 + 8 + ShellMetrics.buttonHeight / 2),
                                 width: pillWidth, height: ShellMetrics.buttonHeight) :
                          CGRect(x: rowX + rowWidth - pillWidth, y: 0, width: pillWidth,
                                 height: ShellMetrics.buttonHeight))
            }
            /* The held action's name, as the tool rail names its tools: above everything else in
             * the row, clear of the finger and of the last operation above the bar. */
            if let heldName {
              let above: CGFloat = redoTitle == nil ? 0 : redoOpen ? 60 + 8 : ShellMetrics.buttonHeight + 8
              ShellNameLabel(text: heldName.text)
                .alignmentGuide(.leading) { d in
                  d.width / 2 - min(max(rowX + heldName.x, d.width / 2 + 8), width - d.width / 2 - 8)
                }
                .offset(y: -(ShellMetrics.barHeight / 2 + 10 + above + 18))
                .zIndex(2)
                .transition(.opacity)
            }
          }
          .frame(width: width, height: ShellMetrics.rowHeight, alignment: .leading)
          /* Above the row, as overlays: an overlay never changes the size of what it is over, so
           * the row stays where its padding puts it however tall these are. Placed inside the row's
           * stack, they made it taller and pushed the row down by half their height. */
          .overlay(alignment: .topLeading) {
            /* The selection's transform, above the row and above the last operation's strip
             * when that is above it too. */
            if itemWanted && !ItemCard.rows(item, tool: model.activeTool).isEmpty {
              let stripAbove: CGFloat = redoTitle == nil ? 0 :
                (redoAbove ? ShellMetrics.buttonHeight + 8 : (redoOpen && !wide ? 60 + 8 : 0))
              ItemCard(model: item, tool: model.activeTool, folded: $itemFolded,
                       maxHeight: geometry.size.height * 0.4)
                .frame(maxWidth: min(laneWidth, 520), alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .alignmentGuide(.top) { d in d.height + 8 + stripAbove }
                .offset(x: laneLeading)
                .transition(.opacity)
            }
          }
          .overlay(alignment: .topLeading) {
            /* While an operation waits: its name and what it says, and the number pad, above
             * the bar. */
            if modalRunning {
              VStack(alignment: .leading, spacing: 8) {
                /* The operation's own words (a move's values) are at the top, see #ToolRails. */
                if NumberPadState.shared.shown {
                  NumberPad(model: model)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
              }
              .alignmentGuide(.top) { d in
                d.height + 8 + (ShellMetrics.barHeight - ShellMetrics.rowHeight) / 2
              }
              .offset(x: rowX)
            }
          }
        }
      }
      /* Above the keyboard while one of the strip's fields is typed into; the viewport stays. */
      .padding(.bottom, band.rowBottom)
      .ignoresSafeArea(edges: .bottom)
    }
    .ignoresSafeArea(edges: .horizontal)
    .onChange(of: redo.operationKey) { _, key in
      /* Another operation arrives folded, unless Blender said its settings show. */
      withAnimation(animation) {
        if let key, RevealCoordinator.shared.opensOperation(redo.operation?.idname) {
          redoOpenID = key
        }
        else if redoOpenID != key {
          redoOpenID = nil
        }
      }
    }
    .onChange(of: RevealCoordinator.shared.operationRequests) { _, _ in
      /* The decision may come after the settings: open them for it then. */
      guard let key = redo.operationKey, !redo.operationColumns.isEmpty,
            RevealCoordinator.shared.opensOperation(redo.operation?.idname) else { return }
      withAnimation(animation) { redoOpenID = key }
    }
    .animation(.easeOut(duration: 0.12), value: heldName?.text)
    .onChange(of: itemWanted, initial: true) { _, wanted in item.setShown(wanted) }
    .onChange(of: modalRunning) { _, running in
      /* The waiting operation's bar opens by itself, and folds when it ends if it opened so. */
      withAnimation(animation) {
        if running && !actionsOpen {
          actionsOpen = true
          openedForModal = true
        }
        else if !running {
          if openedForModal { actionsOpen = false }
          openedForModal = false
          NumberPadState.shared.shown = false
        }
      }
    }
    /* Folded for one tool, open again for the next. */
    .onChange(of: model.activeTool) { _, _ in itemFolded = false }
    .onChange(of: redo.operation?.shown, initial: true) { _, requests in
      /* Asked to open (F9, the Edit menu): open for this operation. */
      if let requests, let seen = redoShowRequests, requests > seen, !redo.operationColumns.isEmpty {
        withAnimation(animation) {
          redoOpenID = redo.operationKey
          actionsOpen = false
        }
      }
      redoShowRequests = requests ?? redoShowRequests
    }
    .onChange(of: redo.operation?.error) { _, error in
      if let error, !error.isEmpty { redoError = error }
    }
    .alert("Unable to Adjust Operation", isPresented: Binding(
      get: { redoError != nil }, set: { if !$0 { redoError = nil } })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(redoError ?? "")
    }
  }

  /* -------------------------------------------------------------------- */
  /* Actions */

  /** The bar's circles at either end and their margins, beside the actions. */
  private var actionsBarChrome: CGFloat {
    8 + ShellMetrics.barCircle + (contextMenuAvailable ? ShellMetrics.barCircle : 0)
  }

  /** The bar hugs its actions, which scroll when the lane is narrower. */
  private func actionsBarWidth(maxWidth: CGFloat) -> CGFloat {
    actionsBarChrome + min(ceil(actionItemsWidth), max(0, maxWidth - actionsBarChrome))
  }

  /** The actions: icons, a hold naming each, deleting in red; titles between hairlines where there is no icon. */
  private var actionItems: some View {
    HStack(spacing: 0) {
      ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
        /* Hairlines part titles, as an edit menu's; icons stand apart by themselves. */
        if index > 0 && (action.image == nil || actions[index - 1].image == nil) {
          Rectangle()
            .fill(Color.primary.opacity(0.2))
            .frame(width: 1, height: 22)
        }
        QuickActionBarItem(action: action, model: model) { text, x in
          heldName = text.map { ($0, x) }
        }
      }
    }
  }

  private func toggleActions() {
    /* The strip stays open: it moves above the actions. */
    withAnimation(animation) { actionsOpen.toggle() }
  }

  /**
   * The pill and the bar are one glass capsule: opening grows the pill into the bar, centered on
   * the viewport, and the close button at its leading end folds it back into the pill.
   */
  private func actionsMorph(frame: CGRect, itemsWidth: CGFloat) -> some View {
    ZStack(alignment: .leading) {
      if actionsOpen {
        HStack(spacing: 0) {
          Button(action: toggleActions) {
            Image(systemName: "xmark")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(.primary)
              .frame(width: ShellMetrics.barCircle, height: ShellMetrics.barCircle)
              .background(Circle().fill(Color.primary.opacity(0.1)))
              .contentShape(Circle())
          }
          .buttonStyle(QuickActionPressStyle(shape: Circle()))
          .accessibilityLabel("Hide Quick Actions")
          .accessibilityValue("Expanded")
          .accessibilityIdentifier("blender.quick-actions.toggle")
          .help("Hide Quick Actions")
          ScrollView(.horizontal, showsIndicators: false) {
            actionItems
          }
          .softHorizontalScrollEdge()
          .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
          .frame(width: max(0, itemsWidth))
          if contextMenuAvailable {
            ContextMenuButton(systemImage: "chevron.right", size: ShellMetrics.barCircle)
              .font(.system(size: 17, weight: .semibold))
              .background(Circle().fill(Color.primary.opacity(0.1)))
          }
        }
        .padding(.horizontal, 4)
        .frame(height: frame.height)
        .transition(.opacity)
      }
      else {
        Button(action: toggleActions) {
          Text("Actions")
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(.primary)
            .frame(width: ShellMetrics.actionsPillWidth - 20)
            .padding(.horizontal, 10)
            .frame(height: ShellMetrics.buttonHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show Quick Actions")
        .accessibilityValue("Collapsed")
        .accessibilityIdentifier("blender.quick-actions.toggle")
        .help("Show Quick Actions")
        .transition(.opacity)
      }
    }
    .frame(width: frame.width, height: frame.height, alignment: .leading)
    .background {
      /* Measured ahead of opening, so the bar grows straight to its width. */
      actionItems
        .fixedSize()
        .hidden()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
          if abs(width - actionItemsWidth) > 0.5 { actionItemsWidth = width }
        }
    }
    .coordinateSpace(name: Self.barSpace)
    .clipShape(ShellShape())
    /* Not interactive glass once open, which would take the touches of the actions on it. */
    .panelGlass(interactive: !actionsOpen, in: Capsule())
    .layoutZone("actions")
    .offset(x: frame.minX)
    .animation(animation, value: actions)
  }

  /* -------------------------------------------------------------------- */
  /* Adjust Last Operation */

  /** As wide as the title, from 72 to 136 points with its margins. */
  private func closeRedo() {
    withAnimation(animation) { redoOpenID = nil }
  }

  private func redoWidthChanged(_ width: CGFloat) {
    if abs(width - redoContentWidth) > 0.5 { redoContentWidth = width }
  }

  private func redoPillWidth(_ title: String) -> CGFloat {
    let measured = ceil((title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 17)]).width)
    return min(136 - 24, max(72 - 24, measured)) + 24
  }

  /** The strip hugs its settings, after the close button and its margin. */
  private func stripWidth(maxWidth: CGFloat) -> CGFloat {
    min(max(0, maxWidth), min(1000, ceil(redoContentWidth) + 48))
  }

  /** Where the strip opens, in the row's space, centered on its y. */
  private func stripFrame(width: CGFloat, laneLeading: CGFloat, laneWidth: CGFloat, wide: Bool,
                          actionsWidth: CGFloat) -> CGRect {
    if wide {
      /* Opened in the row, after the Actions pill, centered on the viewport. */
      let start = laneLeading + actionsWidth + (actionsWidth > 0 ? 8 : 0)
      let strip = stripWidth(maxWidth: laneLeading + laneWidth - start)
      return CGRect(x: min(max(width / 2 - strip / 2, start), laneLeading + laneWidth - strip), y: 0,
                    width: strip, height: 60)
    }
    /* Above the row, centered on the window, beside its sides. */
    let strip = stripWidth(maxWidth: laneWidth)
    let x = max(model.sideInsets.left, min((width - strip) / 2, width - model.sideInsets.right - strip))
    return CGRect(x: x, y: -(ShellMetrics.rowHeight / 2 + 8 + 30), width: strip, height: 60)
  }

  /**
   * The pill and the strip are one glass shape, so opening grows the pill's frame into the strip's
   * and closing folds it back, while their contents cross over inside it.
   */
  private func redoMorph(title: String, frame: CGRect) -> some View {
    let shape = RoundedRectangle(cornerRadius: redoOpen ? 20 : ShellMetrics.buttonHeight / 2,
                                 style: .continuous)
    return ZStack(alignment: .leading) {
      if redoOpen {
        RedoContent(model: redo, close: closeRedo, widthChanged: redoWidthChanged)
          .environment(\.inOperationStrip, true)
          .frame(width: frame.width, height: frame.height)
          .layoutZone("operation")
          .accessibilityIdentifier("blender.redo.strip")
          .transition(.opacity)
      }
      else {
        Button {
          withAnimation(animation) { redoOpenID = redo.operationKey }
        } label: {
          Text(title)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.primary)
            .frame(width: frame.width - 24)
            .padding(.horizontal, 12)
            .frame(height: ShellMetrics.buttonHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Adjust \(redo.title)")
        .accessibilityHint("Show last operation controls")
        .accessibilityIdentifier("blender.redo.collapsed")
        .transition(.opacity)
        .background {
          /* Measured ahead of opening, so the strip grows straight to its width. */
          RedoContent(model: redo, close: closeRedo, widthChanged: redoWidthChanged)
            .frame(width: 1, height: 1)
            .hidden()
        }
      }
    }
    .frame(width: frame.width, height: frame.height, alignment: .leading)
    .clipShape(shape)
    /* Not interactive glass once open, which would take the touches of the controls on it. */
    .panelGlass(interactive: !redoOpen, in: shape)
    .offset(x: frame.minX, y: frame.minY)
    .transition(.scale(scale: 0.8, anchor: .leading).combined(with: .opacity))
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Number pad
 * Typing a value into a waiting operation, as "G X 2 Enter" does with a keyboard: each key is
 * sent to it as that key, and the hint above shows what it has read.
 * \{ */

@MainActor
@Observable
final class NumberPadState {
  static let shared = NumberPadState()
  var shown = false
}

struct NumberPad: View {
  let model: ShellModel

  private let rows: [[(String, String)]] = [
    [("7", "SEVEN"), ("8", "EIGHT"), ("9", "NINE"), ("⌫", "BACK_SPACE")],
    [("4", "FOUR"), ("5", "FIVE"), ("6", "SIX"), ("−", "MINUS")],
    [("1", "ONE"), ("2", "TWO"), ("3", "THREE"), ("Tab", "TAB")],
    [("0", "ZERO"), (".", "PERIOD"), ("=", "EQUAL"), ("Done", "RET")],
  ]

  var body: some View {
    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
      ForEach(rows.indices, id: \.self) { row in
        GridRow {
          ForEach(rows[row], id: \.1) { title, key in
            Button {
              Haptics.selection()
              if key == "RET" {
                wm_apple_ios_window_send_key(model.window, "RET")
                NumberPadState.shared.shown = false
              }
              else {
                model.send("modalkey:" + key, .invoke)
              }
            } label: {
              Text(title)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 56, height: 44)
                .background(Color.primary.opacity(0.08), in: ShellShape(glassRadius: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(QuickActionPressStyle(shape: ShellShape(glassRadius: 12)))
            .accessibilityLabel(key == "BACK_SPACE" ? "Delete" : key == "MINUS" ? "Minus" : title)
          }
        }
      }
    }
    .padding(8)
    .panelGlass(in: ShellShape(glassRadius: 20))
    .accessibilityIdentifier("blender.number-pad")
  }
}

/** \} */
