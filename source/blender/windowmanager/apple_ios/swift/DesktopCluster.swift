/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The Desktop Interface's cluster (ROUND6 DESK-1, decision R6-6, findings H1, H3, H12, C1, C10).
 *
 * Over Blender's own interface the app draws nothing else. A touch there has no Escape, no Return,
 * no Tab and no right button, so an operation that only a key ends (Circle Select from a menu in
 * the UV Editor, a Knife cut) would hold the window for good, and Focus Mode hides every bar, the
 * way back included. This one small cluster is always on screen, whatever Blender's screen shows:
 * back to the iPad interface, Undo and Redo, Shift, Ctrl and Alt (TOUCH-8), Escape, Tab and Return,
 * the keyboard (DESK-3), Confirm and Cancel with the waiting operation's own keys (TOUCH-5), the
 * running jobs (BUSY-1), what one finger does, and the app's messages. It folds to one button, and
 * is dragged, or moved from its menu, to any corner. It looks like Blender's own regions.
 */

import SwiftUI
import UIKit

/** Where the cluster stands. Kept as the person left it. */
enum DesktopClusterCorner: String, CaseIterable {
  case topLeading, topTrailing, bottomLeading, bottomTrailing

  var alignment: Alignment {
    switch self {
      case .topLeading: .topLeading
      case .topTrailing: .topTrailing
      case .bottomLeading: .bottomLeading
      case .bottomTrailing: .bottomTrailing
    }
  }

  var top: Bool { self == .topLeading || self == .topTrailing }
  var leading: Bool { self == .topLeading || self == .bottomLeading }

  var title: String {
    switch self {
      case .topLeading: "Top Left"
      case .topTrailing: "Top Right"
      case .bottomLeading: "Bottom Left"
      case .bottomTrailing: "Bottom Right"
    }
  }

  /** The corner nearest \a point in a window \a size big. */
  static func nearest(_ point: CGPoint, in size: CGSize) -> DesktopClusterCorner {
    let left = point.x < size.width / 2
    let up = point.y < size.height / 2
    return up ? (left ? .topLeading : .topTrailing) : (left ? .bottomLeading : .bottomTrailing)
  }
}

/** The cluster over the whole window, standing in its corner; only the cluster takes touches. */
struct DesktopClusterLayer: View {
  let model: ShellModel
  let commands: ShellCommands
  let compile: CompileProgress
  static let cornerKey = "DesktopClusterCorner"
  static let foldedKey = "DesktopClusterFolded"
  @AppStorage(DesktopClusterLayer.cornerKey) private var cornerName = DesktopClusterCorner.bottomLeading.rawValue
  @State private var size = CGSize.zero
  /** While the cluster is dragged to another corner. */
  @State private var drag = CGSize.zero

  private var corner: DesktopClusterCorner { DesktopClusterCorner(rawValue: cornerName) ?? .bottomLeading }

  var body: some View {
    ZStack(alignment: corner.alignment) {
      Color.clear
        .allowsHitTesting(false)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
      DesktopCluster(model: model, commands: commands, compile: compile, corner: corner,
                     moveTo: { cornerName = $0.rawValue }) { value in
        drag = value.translation
      } dragEnded: { value in
        /* Where the corner it stood in went with the drag: the nearest corner takes it. */
        let start = CGPoint(x: corner.leading ? 0 : size.width, y: corner.top ? 0 : size.height)
        let end = CGPoint(x: start.x + value.predictedEndTranslation.width,
                          y: start.y + value.predictedEndTranslation.height)
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .spring(response: 0.32, dampingFraction: 0.86)) {
          cornerName = DesktopClusterCorner.nearest(end, in: size).rawValue
          drag = .zero
        }
      }
      .offset(drag)
      /* Clear of Blender's top bar and status bar, which keep their own controls. */
      .padding(.horizontal, 12)
      .padding(.top, 40)
      .padding(.bottom, 34)
    }
    .onChange(of: model.notices, initial: true) { _, notices in
      /* The iPad interface's messages take Blender's notices there; here the cluster does, so
       * what the app says (a refused Undo, a file it cannot open) is never lost (ROUND6 DESK-1). */
      model.messages.take(notices)
    }
  }
}

/** The cluster itself: a row of controls, Shift, Ctrl and Alt, and what waits or runs. */
struct DesktopCluster: View {
  let model: ShellModel
  let commands: ShellCommands
  let compile: CompileProgress
  let corner: DesktopClusterCorner
  let moveTo: (DesktopClusterCorner) -> Void
  let dragChanged: (DragGesture.Value) -> Void
  let dragEnded: (DragGesture.Value) -> Void
  @AppStorage(DesktopClusterLayer.foldedKey) private var folded = false

  /** Blender's regions: a dark grey with a darker outline, light text, a little rounding. */
  private static let surface = RoundedRectangle(cornerRadius: ShellStyle.radius, style: .continuous)

  var body: some View {
    VStack(alignment: corner.leading ? .leading : .trailing, spacing: 6) {
      if corner.top {
        panel
        waiting
        jobs
        messages
      }
      else {
        messages
        jobs
        waiting
        panel
      }
    }
    .environment(\.colorScheme, .dark)
    .animation(UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.18), value: folded)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("blender.desktop-cluster")
  }

  /* -------------------------------------------------------------------- */
  /* The controls */

  @ViewBuilder
  private var panel: some View {
    if folded {
      grip(button: true)
        .background(ShellStyle.region, in: Self.surface)
        .overlay(Self.surface.stroke(ShellStyle.outline, lineWidth: 1))
    }
    else {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 2) {
          grip(button: false)
          key("iPad Interface", symbol: "ipad", identifier: "ipad") {
            BlenderSettings.set("desktop", .bool(false))
          }
          divider
          key("Undo", symbol: "arrow.uturn.backward", identifier: "undo") {
            /* Through the one gate the iPad interface's Undo passes: refused with a word while an
             * operation waits (ROUND6 TOUCH-3). */
            Operators.run("ED_OT_undo")
          }
          key("Redo", symbol: "arrow.uturn.forward", identifier: "redo") { Operators.run("ED_OT_redo") }
          divider
          key("Esc", text: "Esc", identifier: "esc") { wm_apple_ios_window_send_key(model.window, "ESC") }
          key("Tab", text: "Tab", identifier: "tab") { wm_apple_ios_window_send_key(model.window, "TAB") }
          key("Return", symbol: "return", identifier: "return") { wm_apple_ios_window_send_key(model.window, "RET") }
          divider
          fingerMenu
          moreMenu
        }
        StickyModifierKeys(model: model, embedded: true)
          .padding(.leading, 2)
      }
      .padding(4)
      .background(ShellStyle.region, in: Self.surface)
      .overlay(Self.surface.stroke(ShellStyle.outline, lineWidth: 1))
      .transition(.opacity)
    }
  }

  private var divider: some View {
    Rectangle()
      .fill(ShellStyle.text.opacity(0.18))
      .frame(width: 1, height: 22)
      .padding(.horizontal, 2)
  }

  /** Dragged, the cluster goes to the nearest corner; tapped, it folds or unfolds. */
  private func grip(button: Bool) -> some View {
    Image(systemName: button ? "rectangle.grid.2x2" : "chevron.compact.left")
      .font(.system(size: button ? 17 : 15, weight: .semibold))
      .foregroundStyle(ShellStyle.text)
      .frame(width: button ? 44 : 26, height: 44)
      .contentShape(Rectangle())
      .onTapGesture {
        Haptics.selection()
        folded.toggle()
      }
      .gesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
        .onChanged(dragChanged)
        .onEnded(dragEnded))
      .accessibilityElement()
      .accessibilityLabel(folded ? "Show the App's Controls" : "Fold the App's Controls")
      .accessibilityHint("Drag to move to another corner")
      .accessibilityAddTraits(.isButton)
      .accessibilityIdentifier("blender.desktop-cluster.fold")
  }

  /** A key of the cluster, in Blender's button style: a symbol, or short text. */
  private func key(_ title: String, symbol: String? = nil, text: String? = nil, identifier: String,
                   action: @escaping () -> Void) -> some View
  {
    Button {
      Haptics.selection()
      action()
    } label: {
      Group {
        if let symbol {
          Image(systemName: symbol).font(.system(size: 16, weight: .medium))
        }
        else {
          Text(text ?? title).font(.system(size: 13, weight: .medium))
        }
      }
      .foregroundStyle(ShellStyle.text)
      .frame(minWidth: 40, minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(DesktopClusterKeyStyle())
    .help(title)
    .accessibilityLabel(title)
    .accessibilityIdentifier("blender.desktop-cluster.\(identifier)")
  }

  /** What one finger does, the same choice as Settings' and the iPad header's (ROUND6 TOUCH-1, H8):
   * the Desktop Interface has neither, and a finger that moves the view cannot draw in a canvas. */
  private var fingerMenu: some View {
    Menu {
      Section("One Finger") {
        Button {
          commands.chooseFingerUsesTool(true)
        } label: {
          Label("Use Tool", systemImage: model.fingerUsesTool ? "checkmark" : "cursorarrow")
        }
        Button {
          commands.chooseFingerUsesTool(false)
        } label: {
          Label("Move the View", systemImage: model.fingerUsesTool ? "hand.draw" : "checkmark")
        }
      }
    } label: {
      Image(systemName: "hand.point.up")
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(ShellStyle.text)
        .frame(minWidth: 40, minHeight: 44)
        .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(DesktopClusterKeyStyle())
    .accessibilityLabel("One Finger")
    .accessibilityValue(model.fingerUsesTool ? "Uses Tool" : "Moves the View")
    .accessibilityIdentifier("blender.desktop-cluster.fingers")
  }

  private var moreMenu: some View {
    Menu {
      Section("Move To") {
        ForEach(DesktopClusterCorner.allCases, id: \.self) { place in
          Button {
            moveTo(place)
          } label: {
            Label(place.title, systemImage: place == corner ? "checkmark" : "square.dashed")
          }
          .disabled(place == corner)
        }
      }
      Button {
        folded = true
      } label: {
        Label("Fold to One Button", systemImage: "rectangle.compress.vertical")
      }
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(ShellStyle.text)
        .frame(minWidth: 36, minHeight: 44)
        .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(DesktopClusterKeyStyle())
    .accessibilityLabel("More")
    .accessibilityIdentifier("blender.desktop-cluster.more")
  }

  /* -------------------------------------------------------------------- */
  /* What waits and what runs */

  /** The waiting operation's ends, folded or not: Confirm and Cancel with its own keys, or the
   * waiting gesture's Done or Cancel (ROUND6 TOUCH-5). Nothing in Blender's interface sends them. */
  @ViewBuilder
  private var waiting: some View {
    let bar = QuickAction.list(model.actions).filter { $0.modalKey || $0.axis || $0.id.hasPrefix("modalkey:") }
    if let hint = model.dragHint {
      HStack(spacing: 8) {
        Text(hint.text)
          .font(.footnote.weight(.medium))
          .foregroundStyle(ShellStyle.text)
          .lineLimit(2)
        Button(hint.done ? "Done" : "Cancel") {
          Haptics.selection()
          wm_apple_ios_window_send_key(model.window, "ESC")
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(ShellStyle.text)
        .frame(minWidth: 60, minHeight: 44)
        .background(hint.done ? ShellStyle.selection : ShellStyle.widget, in: Self.surface)
        .buttonStyle(.plain)
        .accessibilityIdentifier("blender.desktop-cluster.hint-end")
      }
      .padding(.leading, 10)
      .padding(4)
      .frame(maxWidth: 420, alignment: .leading)
      .background(ShellStyle.region, in: Self.surface)
      .overlay(Self.surface.stroke(ShellStyle.outline, lineWidth: 1))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("blender.desktop-cluster.hint")
    }
    else if bar.contains(where: \.modalKey) {
      let ends = bar.filter { $0.modalKey }
      let axes = bar.filter { $0.axis }
      let keys = bar.filter { $0.id.hasPrefix("modalkey:") }
      HStack(spacing: 4) {
        ForEach(axes) { action in
          modalButton(action, fill: action.selected ? action.axisColor : ShellStyle.widget)
        }
        if !keys.isEmpty {
          /* The operation's own keys, named as its key map names them. */
          Menu {
            ForEach(keys) { action in
              Button(action.title) { action.run(in: model) }
            }
          } label: {
            Label("Keys", systemImage: "keyboard")
              .font(.footnote.weight(.medium))
              .foregroundStyle(ShellStyle.text)
              .padding(.horizontal, 10)
              .frame(minHeight: 44)
              .background(ShellStyle.widget, in: Self.surface)
          }
          .menuStyle(.button)
          .buttonStyle(.plain)
          .accessibilityIdentifier("blender.desktop-cluster.modal-keys")
        }
        ForEach(ends) { action in
          modalButton(action, fill: action.key == "RET" ? ShellStyle.selection : ShellStyle.widget)
        }
      }
      .padding(4)
      .background(ShellStyle.region, in: Self.surface)
      .overlay(Self.surface.stroke(ShellStyle.outline, lineWidth: 1))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("blender.desktop-cluster.modal")
    }
  }

  private func modalButton(_ action: QuickAction, fill: Color) -> some View {
    Button {
      Haptics.selection()
      action.run(in: model)
    } label: {
      Text(action.axis ? action.key : action.title)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(action.axis && action.selected ? Color.black : ShellStyle.text)
        .padding(.horizontal, 12)
        .frame(minWidth: 44, minHeight: 44)
        .background(fill, in: Self.surface)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(action.axis ? "\(action.key) axis constraint" : action.title)
    .accessibilityIdentifier(action.id == "modal:confirm" ? "blender.desktop-cluster.confirm" :
                               action.id == "modal:cancel" ? "blender.desktop-cluster.cancel" :
                               "blender.desktop-cluster.\(action.id)")
  }

  /** The running jobs, each with its progress and Stop, and shader compilation (ROUND6 BUSY-1). */
  private var jobs: some View {
    CompileIndicator(progress: compile, inCluster: true)
  }

  /** What the app says: a refused command, a file it cannot open. Blender's own reports also stay
   * in its status bar. */
  @ViewBuilder
  private var messages: some View {
    if !model.messages.shown.isEmpty {
      ShellMessagesView(messages: model.messages) { model.perform($0) }
        .frame(maxWidth: 420)
    }
  }
}

/** A key of the cluster pressed: Blender's pressed-button shade. */
struct DesktopClusterKeyStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(RoundedRectangle(cornerRadius: ShellStyle.radius, style: .continuous)
        .fill(configuration.isPressed ? ShellStyle.selection : Color.clear))
  }
}
