/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * An operation's settings: the last one's, from the `redo` view, which the actions row shows on a
 * strip above the bottom edge, folded into a pill beside the actions until opened; and one's asked
 * for before it runs, from the `dialog` view, as a sheet in place of Blender's dialog.
 */

import SwiftUI
import UIKit

extension PanelsModel {
  /** The operation shown, or none. */
  var operation: Blender_NativeUI_Operator? {
    view.top?.kind == .operator_ ? view.top?.content(Blender_NativeUI_Operator.self) : nil
  }

  /** Which operation: another one starts its controls again. */
  var operationKey: String? { operation == nil ? nil : view.top?.key }

  /** Its settings, as the strip shows them: a vector or a row of toggles whole, see
   * #BlenderSettingItem. */
  var operationColumns: [NativeNode] {
    guard let top = view.top else { return [] }
    return children(of: top)
  }

  /** Dismiss the last operation's settings, or confirm or cancel a dialog. */
  func finishOperation(_ action: String) {
    guard let top = view.top, operation != nil else { return }
    send(top, .invoke, .text(action))
  }
}

/** Short titles for the folded pill, only where Blender's are too long for it: otherwise the pill
 * reads Blender's name, which the strip it opens into is titled with (decision 27). */
let operationShortNames = [
  "TRANSFORM_OT_rotate": "Rotate", "MESH_OT_extrude_region_move": "Extrude",
  "MESH_OT_extrude_context_move": "Extrude", "MESH_OT_extrude_faces_move": "Extrude",
  "MESH_OT_duplicate_move": "Duplicate", "OBJECT_OT_duplicate_move": "Duplicate",
  "OBJECT_OT_duplicate_move_linked": "Duplicate Linked",
]

/* -------------------------------------------------------------------- */
/** \name Dialog
 * \{ */

/**
 * An operator's settings, asked for before it runs, in place of Blender's dialog: a sheet with
 * its settings as a form, Cancel and the operator's own confirm button.
 */
struct OperatorDialog: View {
  let model: PanelsModel

  var body: some View {
    NavigationStack {
      Form {
        if let message = model.operation?.message, !message.isEmpty {
          Text(message)
        }
        if let top = model.view.top {
          ForEach(model.children(of: top)) { ControlRow(model: model, node: $0) }
        }
      }
      .navigationTitle(model.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", role: .cancel) { model.finishOperation("cancel") }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(model.operation?.confirm.flatMap { $0.isEmpty ? nil : $0 } ?? "OK") {
            model.finishOperation("confirm")
          }
          .accessibilityIdentifier("blender.dialog.confirm")
        }
      }
    }
    .tint(Color(uiColor: .systemBlue))
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Strip
 * \{ */

struct RedoContent: View {
  let model: PanelsModel
  let close: () -> Void
  /** The strip's whole width, which it hugs: its circles, title and settings. */
  var widthChanged: (CGFloat) -> Void = { _ in }
  @State private var titleWidth: CGFloat = 0
  @State private var settingsWidth: CGFloat = 0
  @AppStorage(ShellStyle.key) private var style = ShellStyle.blender.rawValue
  @Environment(\.colorScheme) private var colorScheme

  /** The circles at either end with their margins, and the two separators. */
  private static let chrome: CGFloat = 2 * (4 + ShellMetrics.barCircle) + 2 * 9

  private func report() { widthChanged(Self.chrome + titleWidth + settingsWidth) }

  var body: some View {
    /* As the actions bar below it: ✕, the operation's name, its settings with Blender's widgets
     * (as the tool settings row draws them), and Repeat at the end. */
    HStack(spacing: 0) {
      BarCircleButton(systemImage: "xmark", label: "Collapse Last Operation", action: close)
        .padding(.leading, 4)
        .accessibilityIdentifier("blender.redo.done")
        .accessibilityHint(model.operation?.error ?? "")
      Text(model.title)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleWidth = $0; report() }
        .accessibilityIdentifier("blender.redo.title")
      BlenderWidgetSeparator()
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          ForEach(model.operationColumns) { BlenderSettingItem(model: model, node: $0) }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { settingsWidth = $0; report() }
      }
      .softHorizontalScrollEdge()
      BlenderWidgetSeparator()
      /* Do it again, as Shift+R. */
      BarCircleButton(systemImage: "repeat", label: ShellModel.current?.repeatTitle ?? "Repeat Last") {
        ShellModel.current?.send("repeat", .invoke)
      }
      .disabled(!(ShellModel.current?.canRepeat ?? false))
      .padding(.trailing, 4)
      .accessibilityIdentifier("blender.redo.repeat")
    }
    .labelStyle(.titleAndIcon)
    /* Blender's text colour, not the system's blue, as the tool settings row. */
    .tint(Color.primary)
    .foregroundStyle(Color.primary)
    /* Blender's regions are dark whatever the system's appearance. */
    .environment(\.colorScheme, style == ShellStyle.glass.rawValue ? colorScheme : .dark)
    /* Another operation's controls start again, dropping what was being typed. */
    .id(model.operationKey)
  }
}

/** \} */
