/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The selection's transform where the hand is: Blender's sidebar Item tab, as rows of fields above
 * the actions while a Move, Rotate, Scale or Transform tool is active, so a value can be typed
 * without opening Properties. Only what the tool changes is shown: Location for Move, Rotation
 * for Rotate, Scale and Dimensions for Scale, all of them for Transform; in Edit Mode, the
 * selection's Median. A ↺ clears a row, as Alt+G, Alt+R and Alt+S do. Folded to a pill, it stays
 * folded until the tool changes.
 */

import SwiftUI

/** The transform tools, and what each of them changes. */
enum ItemCardTools {
  static func properties(for tool: String) -> Set<String>? {
    switch tool {
      case "builtin.move": ["location", "native_item_median"]
      case "builtin.rotate": ["rotation_euler", "rotation_quaternion", "rotation_axis_angle", "native_item_median"]
      case "builtin.scale", "builtin.scale_cage": ["scale", "dimensions", "native_item_median"]
      case "builtin.transform": ["location", "rotation_euler", "rotation_quaternion", "rotation_axis_angle", "scale",
                                 "dimensions", "native_item_median"]
      default: nil
    }
  }

  /** Clearing a row, by its property: Blender's Clear Location, Rotation and Scale. */
  static func clearOperator(_ property: String) -> String? {
    switch property {
      case "location": "OBJECT_OT_location_clear"
      case "rotation_euler", "rotation_quaternion", "rotation_axis_angle": "OBJECT_OT_rotation_clear"
      case "scale": "OBJECT_OT_scale_clear"
      default: nil
    }
  }

  static let shownKey = "BlenderItemCardShown"
}

/** A row of the Item tab: a vector's label and its components. */
struct ItemRow: Identifiable {
  var id: String { group.key }
  let group: NativeNode
  let label: String
  let property: String
  let components: [NativeNode]
}

struct ItemCard: View {
  let model: PanelsModel
  let tool: String
  /** Folded by the person for this tool. */
  @Binding var folded: Bool
  /** Shown as its pill: folded, or with no room to open, see #ShellLayout.bottomStack. */
  var pill = false
  /** At most this tall, with its header: the rows scroll beyond it. */
  var maxHeight: CGFloat = 300
  @State private var rowsHeight: CGFloat = 0

  static func rows(_ model: PanelsModel, tool: String) -> [ItemRow] {
    guard let wanted = ItemCardTools.properties(for: tool) else { return [] }
    var rows: [ItemRow] = []
    for panel in model.panels {
      for group in model.children(of: panel) where group.kind == .group {
        let components = model.children(of: group).filter { $0.number != nil }
        guard let property = components.first?.node.property, wanted.contains(property) else { continue }
        rows.append(ItemRow(group: group, label: group.label, property: property, components: components))
      }
    }
    return rows
  }

  var body: some View {
    let rows = Self.rows(model, tool: tool)
    if pill {
      Button {
        if folded {
          withAnimation(.easeOut(duration: 0.18)) { folded = false }
        }
        else {
          /* Open, but without room: say why rather than do nothing. */
          ShellModel.current?.messages.say(NumberPadState.shared.shown ?
            "The Item card opens when the number pad closes" : "No room above the bottom row for the Item card",
            level: "info")
        }
      } label: {
        Label("Item", systemImage: "chevron.up")
          .labelStyle(.titleAndIcon)
          .font(.subheadline)
          .foregroundStyle(.primary)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .frame(width: ShellMetrics.itemPillWidth - 28)
          .padding(.horizontal, 14)
          .frame(height: ShellMetrics.buttonHeight)
          .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .panelGlass(interactive: true, in: Capsule())
      .layoutZone("item")
      .accessibilityIdentifier("blender.item.folded")
    }
    else {
      VStack(alignment: .leading, spacing: 6) {
        /* Blender's panel header: the chevron first, then the name, the whole header folds it. */
        Button {
          withAnimation(.easeOut(duration: 0.18)) { folded = true }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "chevron.down")
              .font(.system(size: 12, weight: .semibold))
            Text("Item")
              .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
          }
          .frame(height: 44)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Fold Item")
        ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in rowView(row) }
          }
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
        }
        /* Below the header (44), its gap (6) and the margins (8). */
        .frame(height: max(0, min(rowsHeight, maxHeight - 58)))
        .shellScrollEdge(.vertical)
        .scrollBounceBehavior(.basedOnSize)
      }
      .padding(.leading, 14)
      .padding(.trailing, 6)
      .padding(.vertical, 4)
      .environment(\.inOperationStrip, true)
      .panelGlass(in: ShellShape(glassRadius: 20))
      .layoutZone("item")
      .accessibilityIdentifier("blender.item")
    }
  }

  private func rowView(_ row: ItemRow) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        caption(row).frame(width: 84, alignment: .leading)
        fields(row)
        clear(row)
      }
      /* Narrow: the label above its fields. */
      VStack(alignment: .leading, spacing: 4) {
        caption(row)
        HStack(spacing: 8) {
          fields(row)
          clear(row)
        }
      }
    }
  }

  private func caption(_ row: ItemRow) -> some View {
    Text(row.label)
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .fixedSize()
  }

  /** The row's components as Blender's joined fields, each named inside. */
  private func fields(_ row: ItemRow) -> some View {
    BlenderVectorField(model: model, group: row.group)
  }

  @ViewBuilder
  private func clear(_ row: ItemRow) -> some View {
    if let op = ItemCardTools.clearOperator(row.property) {
      Button {
        Operators.run(op)
      } label: {
        Image(systemName: "arrow.counterclockwise")
          .font(.system(size: 14, weight: .semibold))
          .frame(width: 32, height: 32)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Clear \(row.label)")
      .accessibilityLabel("Clear \(row.label)")
    }
    else {
      Color.clear.frame(width: 32, height: 1)
    }
  }
}
