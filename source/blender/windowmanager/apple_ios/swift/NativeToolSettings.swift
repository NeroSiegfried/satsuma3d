/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The active tool's settings in the top bar, from the `tool_settings` view: compact columns, a
 * caption over each control, or the bar's own items. Groups of settings that would crowd the bar,
 * such as Remesh, are one control there, their settings popping out.
 */

import SwiftUI
import UIKit

extension PanelsModel {
  /** The controls of a panel in a row, as the bar shows them: rows of components one by one, a
   * row of toggles together; lists, pickers and previews only in the full settings. */
  func stripControls(of panel: NativeNode) -> [NativeNode] {
    var controls: [NativeNode] = []
    func walk(_ node: NativeNode) {
      /* What the panel could not show is said in the full settings, not in the bar. */
      for child in body(of: node) where child.role != .elsewhere {
        switch child.kind {
          case .panel:
            walk(child)
          case .group where child.group?.layout == .row:
            controls += children(of: child).filter { $0.role == .none_ }
          case .group where child.group?.layout == .column:
            walk(child)
          case .list, .reference, .row, .picture, .label, .separator:
            break
          case .choice where child.choice?.style == .actions:
            break
          default:
            controls.append(child)
        }
      }
    }
    walk(panel)
    return controls
  }

  /** A group of settings shown as one control in the bar. */
  func isPopout(_ panel: NativeNode) -> Bool { panel.key.hasSuffix("_popout_settings") }

  /** Whether the tool has settings to show. */
  var hasToolSettings: Bool { panels.contains { isPopout($0) || !stripControls(of: $0).isEmpty } }
}

/**
 * The tool's settings as the top bar's own items, each a system control: as many as there is room
 * for show in the bar, and the system puts the rest in its overflow menu, each as a menu item
 * there. Choices are pickers, switches toggles, Blender's menus menus; values to drag or type, a
 * color and groups of settings such as Remesh open in a popover.
 */
struct ToolSettingsItems: View {
  let model: PanelsModel

  var body: some View {
    ForEach(model.panels) { panel in
      if model.isPopout(panel) {
        ToolSettingPopover(title: panel.label, icon: panel.icon, systemImage: "slider.horizontal.3") {
          PanelSection(model: model, panel: panel, bare: true)
        }
      }
      else {
        ForEach(model.stripControls(of: panel)) { control in
          if control.kind == .group {
            toggles(control)
          }
          else {
            ToolSettingItem(model: model, node: control)
          }
        }
      }
    }
  }

  /** A row of toggles, such as Mirror's axes: a menu of them, with its icon, that stays open while
   * they are set. */
  private func toggles(_ group: NativeNode) -> some View {
    let items = model.children(of: group)
    return Menu {
      ForEach(items) { item in
        Toggle(isOn: Binding(get: { model.bool(item) }, set: { model.set(item, .bool($0)) })) {
          Text(item.shortLabel)
        }
      }
    } label: {
      /* The ones on beside the name, in the tint: kept in the bar's group, where a prominent item
       * would stand apart from it. */
      let on = items.filter { model.bool($0) }.map(\.shortLabel)
      Label {
        Text(on.isEmpty ? group.label : "\(group.label) \(on.joined(separator: " "))")
          .foregroundStyle(on.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
      } icon: {
        if group.label == "Mirror" { IconView(name: "MOD_MIRROR") }
      }
    }
    .menuActionDismissBehavior(.disabled)
  }
}

/** One of the tool's settings as a top bar item, see #ToolSettingsItems. */
struct ToolSettingItem: View {
  let model: PanelsModel
  let node: NativeNode
  @Environment(\.widgetsNamed) private var named

  private var title: String { node.shortLabel }
  /** Blender's own icon for it, not the checkbox it draws a toggle with. */
  private var icon: String? {
    guard let icon = node.icon, !icon.hasPrefix("CHECKBOX"), BlenderIcon.image(icon) != nil else { return nil }
    return icon
  }

  var body: some View {
    switch node.kind {
      case .toggle where icon != nil:
        /* With an icon of its own, as Onion Skin: a button lit while on, as the bar's toggles are. */
        Toggle(isOn: Binding(get: { model.bool(node) }, set: { model.set(node, .bool($0)) })) {
          Label { Text(title) } icon: { IconView(name: icon) }
        }
        .toggleStyle(.button)
        .disabled(!node.enabled)
      case .toggle:
        /* Blender's checkbox beside its name in the bar; a checkmark item in its overflow menu. */
        Toggle(isOn: Binding(get: { model.bool(node) }, set: { model.set(node, .bool($0)) })) {
          Text(title)
        }
        .toggleStyle(BlenderCheckboxStyle())
        .fixedSize()
        .disabled(!node.enabled)
      case .button:
        Button { model.send(node, .invoke) } label: { label }
          .disabled(!node.enabled)
      case .menubutton:
        /* The 3D Viewport's menus, such as Sculpt Mode's Mask: run there, not in Properties. */
        let route = BlenderMenus.route(menuName(node))
        Menu {
          BlenderMenuItems(route: route)
        } label: {
          label
        }
        .prefetchingBlenderMenu(route)
        .disabled(!node.enabled)
      case .choice:
        /* As Blender's `prop()` in its header, see #BlenderChoiceWidget. */
        BlenderChoiceWidget(model: model, node: node)
      case .number:
        /* A number to slide sideways or tap to type, beside a name only where Blender's bar draws
         * one: Dyntopo's Detail is the number alone, the switch beside it names it. */
        HStack(spacing: 6) {
          if let label = node.node.shortLabel, !label.isEmpty { Text(label) }
          NativeNumberField(model: model, node: node, widget: .alone)
            .frame(width: 84)
        }
        .fixedSize()
        .disabled(!node.enabled)
      default:
        /* A color, or a value of another kind: named with its value, set in a popover. */
        ToolSettingPopover(title: title, icon: node.icon,
                           systemImage: node.kind == .color ? "paintpalette" : "slider.horizontal.below.rectangle")
        {
          ControlRow(model: model, node: node)
        }
        .disabled(!node.enabled)
    }
  }

  /** Blender's icon where it has one, as the bar shows icons; otherwise the name, as a text item. */
  @ViewBuilder
  private var label: some View {
    if let icon {
      Label { Text(title) } icon: { IconView(name: icon) }
    }
    else {
      Text(title)
    }
  }
}

/** The name of the menu a button opens. */
@MainActor
func menuName(_ node: NativeNode) -> String {
  guard let button = node.content(Blender_NativeUI_MenuButton.self) else { return "" }
  return (0..<button.paramsCount).compactMap { button.params(at: $0) }
    .first { $0.key == "menu" }?.value(type: Blender_NativeUI_TextValue.self)?.value ?? ""
}
