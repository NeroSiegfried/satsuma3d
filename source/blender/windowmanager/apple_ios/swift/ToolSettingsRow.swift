/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Blender's Tool Settings bar, as a row of its own under the header: Blender's two header rows
 * folded into one, in Blender's order. The active tool (its icon and name, then its own settings,
 * as `VIEW3D_HT_tool_header.draw_tool_settings`), the transform settings (orientation, pivot,
 * snapping, proportional editing, as `VIEW3D_HT_header.draw_xform_template`), then the mode's
 * settings (mirror or symmetry, Auto Merge, as `draw_mode_settings`). Blender's widgets, see
 * #BlenderWidgets.
 *
 * In Blender's style it is Blender's tool header: full width, flush under the header, its grey.
 * In Liquid Glass it is a capsule hugging its items, a little below the header. A narrow window
 * drops the names and keeps the icons; a compact one keeps the settings in More instead.
 */

import SwiftUI

struct ToolSettingsRow: View {
  let model: ShellModel
  let shell: ShellPanels
  @AppStorage(ShellStyle.key) private var style = ShellStyle.blender.rawValue
  @Environment(\.colorScheme) private var colorScheme

  /** How far below the header the row hangs: flush in Blender's style, as its tool header is. */
  @MainActor static var gap: CGFloat { ShellStyle.current == .glass ? 6 : 0 }

  private var glass: Bool { style == ShellStyle.glass.rawValue }

  /** The modes whose header has the transform settings in Blender, as Blender says (R6 E5). */
  private var transformMode: Bool { model.hasTransformSettings }

  private var modeSettings: Bool {
    MirrorToggles.available(model) || model.transformSettings["automerge"] != nil
  }

  var hasContent: Bool { transformMode || modeSettings || shell.panels.tools.hasToolSettings }

  private var items: some View {
    HStack(spacing: 6) {
      ActiveToolLabel(model: model)
      if shell.panels.tools.hasToolSettings {
        ToolSettingsItems(model: shell.panels.tools)
      }
      if transformMode {
        BlenderWidgetSeparator()
        ToolSettingsTransformItems(model: model)
      }
      /* Mirror, X-Axis Mirror or Symmetry, and Auto Merge, in every mode whose header has them. */
      if modeSettings {
        BlenderWidgetSeparator()
        MirrorInline(model: model)
      }
    }
    .labelStyle(.titleAndIcon)
    /* Blender's text colour, not the system's blue. */
    .tint(Color.primary)
    .foregroundStyle(Color.primary)
    .padding(.horizontal, 8)
    .frame(height: 44)
    .environment(\.widgetsNamed, model.widthClass >= .regular)
  }

  var body: some View {
    if hasContent {
      /* Hugging its items while they fit, scrolling once they do not. */
      ViewThatFits(in: .horizontal) {
        items.fixedSize()
        ScrollView(.horizontal) { items }
          .shellScrollEdge(.horizontal)
          .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: glass ? nil : .infinity, alignment: .leading)
      .background {
        if !glass {
          /* Blender's tool header: the header's grey, with its edge below. */
          Rectangle().fill(ShellStyle.region)
            .overlay(alignment: .bottom) { Rectangle().fill(ShellStyle.outline).frame(height: 1) }
        }
      }
      /* Blender's header is dark whatever the system's appearance. */
      .environment(\.colorScheme, glass ? colorScheme : .dark)
      .panelGlass(glass ? PanelGlass.regular : PanelGlass.none, in: Capsule())
      .layoutZone("tool settings")
      .accessibilityIdentifier("blender.tool-settings")
    }
    else {
      /* Nothing to show: no height, which the header's bottom follows. */
      Color.clear.frame(height: 0)
    }
  }
}

/** The active tool, first in the bar as Blender's tool header has it: its icon, and its name
 * where there is room. */
struct ActiveToolLabel: View {
  let model: ShellModel
  @Environment(\.widgetsNamed) private var named

  private func find(_ items: [RailItem]) -> RailItem? {
    for item in items {
      if item.id == model.activeTool { return item }
      if let found = find(item.group) { return found }
    }
    return nil
  }

  var body: some View {
    if let tool = find(RailItem.tools(model.tools, mode: model.mode)) {
      HStack(spacing: 6) {
        if let image = tool.image {
          Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: 22, height: 22)
        }
        if named {
          Text(tool.title)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
        }
      }
      .help(tool.title)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Active Tool")
      .accessibilityValue(tool.title)
    }
  }
}
