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

  var axis: Bool { ["X", "Y", "Z"].contains(key) }

  @MainActor
  static func list(_ nodes: [NativeNode]) -> [QuickAction] {
    nodes.compactMap { node in
      guard let button = node.content(Blender_NativeUI_Button.self), !node.label.isEmpty else { return nil }
      return QuickAction(id: node.key, title: node.label, operatorName: button.operator_ ?? "",
                         key: button.key ?? "", icon: node.icon ?? "", selected: button.pressed)
    }
  }

  var image: UIImage? {
    if !key.isEmpty { return nil }
    if !icon.isEmpty, let image = BlenderIcon.image(icon) { return image }
    return wm_apple_ios_action_icon(operatorName, "", "")
  }

  @MainActor
  func run(in model: ShellModel) {
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
  /** Held long enough to name it: the hold shows its name instead of running it. */
  @State private var naming = false
  @State private var heldToName = false

  private var destructive: Bool {
    action.icon == "TRASH" || action.operatorName.hasSuffix(".delete")
  }

  /** Shown as its icon, where it has one: axis keys and actions without one keep their text. */
  private var image: UIImage? { action.axis ? nil : action.image }

  var body: some View {
    Button {
      if heldToName {
        heldToName = false
        return
      }
      action.run(in: model)
    } label: {
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
    .buttonStyle(QuickActionPressStyle(shape: Capsule()))
    /* A hold names it, in a popover the bar's scrolling cannot clip; lifting the finger ends it. */
    .simultaneousGesture(
      LongPressGesture(minimumDuration: 0.4, maximumDistance: 12)
        .onEnded { _ in
          guard image != nil else { return }
          Haptics.selection()
          heldToName = true
          naming = true
        }
        .sequenced(before: DragGesture(minimumDistance: 0))
        .onEnded { _ in
          naming = false
          /* The button may or may not see the lift as a tap: either way, the next one is a tap. */
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { heldToName = false }
        })
    .popover(isPresented: $naming, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
      Text(action.title)
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .presentationCompactAdaptation(.popover)
    }
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
  let model: ShellModel
  let redo: PanelsModel
  @State private var actionsOpen = false
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

  private var actions: [QuickAction] {
    showQuickActions ? QuickAction.list(model.actions) : []
  }

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
      /* The lane between the tool rail and the navigation gizmo, across the whole viewport, as
       * Blender places the gizmo, but beside the window's sides. */
      /* Clear of the navigation gizmo's hotspot where it is along the bottom, which Blender places
       * in fractions of the viewport: on the right, or the left for the left hand. */
      let gizmo = model.navigationGizmo
      let gizmoBottom = gizmo.count != 3 || gizmo[1] > 0.5
      let gizmoLeft = gizmo.count == 3 && gizmo[0] < 0.5
      let gizmoReach = gizmo.count == 3 ? max(44, gizmo[2] * width + 10) : 0
      let laneLeading = max(model.sideInsets.left + ShellMetrics.railLeading + model.toolRailWidth + 12,
                            gizmoBottom && gizmoLeft ? gizmo[0] * width + gizmoReach + 12 : 0)
      let hotspot = min(!gizmoBottom || gizmoLeft ? width :
                          gizmo.count == 3 ? gizmo[0] * width - gizmoReach : width - ShellMetrics.gizmoReserve,
                        width - model.sideInsets.right)
      let laneWidth = max(0, hotspot - 12 - laneLeading)
      let wide = width >= ShellMetrics.wideRow
      let pillWidth = redoTitle.map(redoPillWidth) ?? 0
      let barWidth = actionsBarWidth(maxWidth: laneWidth - (redoPillTitle != nil ? 8 + pillWidth : 0))
      let actionsWidth = actions.isEmpty ? 0 : actionsOpen ? barWidth : ShellMetrics.actionsPillWidth
      /* The redo pill follows the actions in the row. */
      let rowWidth = actionsWidth + (redoPillTitle != nil ? (actionsWidth > 0 ? 8 : 0) + pillWidth : 0)
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
                          stripFrame(width: width, laneLeading: laneLeading, laneWidth: laneWidth, wide: wide,
                                     actionsWidth: actionsWidth) :
                          CGRect(x: rowX + rowWidth - pillWidth, y: 0, width: pillWidth,
                                 height: ShellMetrics.buttonHeight))
            }
          }
          .frame(width: width, height: ShellMetrics.rowHeight, alignment: .leading)
        }
      }
      .padding(.bottom, model.safeAreaInsets.bottom + ShellMetrics.rowBottom + model.bottomTray +
                        model.bottomRailHeight)
      .ignoresSafeArea(edges: .bottom)
    }
    .ignoresSafeArea(edges: .horizontal)
    .onChange(of: redo.operationKey) { _, key in
      /* Another operation arrives folded. */
      if redoOpenID != key { redoOpenID = nil }
    }
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
        QuickActionBarItem(action: action, model: model)
      }
    }
  }

  private func toggleActions() {
    withAnimation(animation) {
      actionsOpen.toggle()
      /* Only one may be open: the actions fold the strip. */
      if actionsOpen { redoOpenID = nil }
    }
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
    .clipShape(Capsule())
    /* Not interactive glass once open, which would take the touches of the actions on it. */
    .panelGlass(interactive: !actionsOpen, in: Capsule())
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
          .frame(width: frame.width, height: frame.height)
          .accessibilityIdentifier("blender.redo.strip")
          .transition(.opacity)
      }
      else {
        Button {
          withAnimation(animation) {
            redoOpenID = redo.operationKey
            actionsOpen = false
          }
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
