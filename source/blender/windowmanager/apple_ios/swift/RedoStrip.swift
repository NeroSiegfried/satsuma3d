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

  /** Its settings, as the strip shows them: a vector's components one by one, named with it. */
  var operationColumns: [(node: NativeNode, caption: String)] {
    guard let top = view.top else { return [] }
    return children(of: top).flatMap { node -> [(node: NativeNode, caption: String)] in
      guard node.group?.layout == .row else { return [(node, node.label)] }
      return children(of: node).filter { $0.role == .none_ }.map { ($0, "\(node.label) \($0.label)") }
    }
  }

  /** Dismiss the last operation's settings, or confirm or cancel a dialog. */
  func finishOperation(_ action: String) {
    guard let top = view.top, operation != nil else { return }
    send(top, .invoke, .text(action))
  }
}

/** Short titles for the folded pill, where Blender's are long. */
let operationShortNames = [
  "TRANSFORM_OT_translate": "Move", "TRANSFORM_OT_rotate": "Rotate",
  "TRANSFORM_OT_resize": "Scale", "MESH_OT_extrude_region_move": "Extrude",
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
  /** The width of the title and controls, which the strip hugs. */
  var widthChanged: (CGFloat) -> Void = { _ in }

  var body: some View {
    HStack(spacing: 0) {
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.system(size: 19, weight: .semibold))
          .foregroundStyle(.primary)
          .frame(width: 44, height: 48)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.leading, 4)
      .accessibilityLabel("Collapse Last Operation")
      .accessibilityIdentifier("blender.redo.done")
      .accessibilityHint(model.operation?.error ?? "")
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 14) {
          Text(model.title)
            .font(.subheadline)
            .lineLimit(2)
            .frame(width: 112, alignment: .leading)
            .accessibilityIdentifier("blender.redo.title")
          /* Do it again, as Shift+R: beside its settings, where "again" and "adjust" meet. */
          Button {
            ShellModel.current?.send("repeat", .invoke)
          } label: {
            Image(systemName: "repeat")
              .font(.system(size: 15, weight: .semibold))
              .frame(width: 36, height: 36)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(!(ShellModel.current?.canRepeat ?? false))
          .help("Repeat")
          .accessibilityLabel(ShellModel.current?.repeatTitle ?? "Repeat Last")
          .accessibilityIdentifier("blender.redo.repeat")
          ForEach(model.operationColumns, id: \.node.key) { column in
            if column.node.kind == .group {
              NativeToggleGroup(model: model, group: column.node, compact: true)
            }
            else {
              StripColumn(model: model, node: column.node, caption: column.caption)
            }
          }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widthChanged($0) }
      }
      .softHorizontalScrollEdge()
    }
    .tint(Color(uiColor: .systemBlue))
    /* Another operation's controls start again, dropping what was being typed. */
    .id(model.operationKey)
  }
}

/** \} */
