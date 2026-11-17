/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Blender's Tool Settings bar, as a row of its own under the header, as on the desktop: in Object
 * and Edit Mode the transform settings (orientation, pivot, snapping, proportional editing and
 * mirror) whatever the tool, then the active tool's own settings. Hidden while it has nothing.
 * Every control keeps 8 points from the row's edge. A narrow window keeps the tool settings in
 * the header's popover instead.
 */

import SwiftUI

struct ToolSettingsRow: View {
  let model: ShellModel
  let shell: ShellPanels

  /** The modes whose header has the transform settings in Blender. */
  private var transformMode: Bool {
    model.mode == "objectmode" || model.mode.hasPrefix("edit_") || model.mode.hasSuffix("_edit") ||
      model.mode == "pose"
  }

  var hasContent: Bool { transformMode || shell.panels.tools.hasToolSettings }

  var body: some View {
    if hasContent {
      ScrollView(.horizontal) {
        HStack(spacing: 4) {
          if transformMode {
            ToolSettingsTransformItems(model: model)
          }
          if transformMode && shell.panels.tools.hasToolSettings {
            Rectangle()
              .fill(Color.primary.opacity(0.2))
              .frame(width: 1, height: 22)
              .padding(.horizontal, 4)
          }
          if shell.panels.tools.hasToolSettings {
            ToolSettingsItems(model: shell.panels.tools)
          }
        }
        .labelStyle(.titleAndIcon)
        /* Blender's text colour, not the system's blue. */
        .tint(Color.primary)
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 8)
        .frame(height: 44)
      }
      .shellScrollEdge(.horizontal)
      .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
      .fixedSize(horizontal: false, vertical: true)
      .panelGlass(in: ShellShape(glassRadius: 22))
      .layoutZone("tool settings")
      .accessibilityIdentifier("blender.tool-settings")
    }
    else {
      /* Nothing to show: no height, which the header's bottom follows. */
      Color.clear.frame(height: 0)
    }
  }
}
