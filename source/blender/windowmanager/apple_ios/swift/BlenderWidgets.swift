/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Blender's widgets as its headers draw them, for the tool settings row and later bars: a
 * dropdown (icon, value, ▾), a toggle lit while on, and either joined into one piece as
 * Blender's `row(align=True)` joins them, such as Snapping's magnet and its target. In Blender's
 * style they take the default theme's colours (`wcol_menu`, `wcol_toggle` in
 * `userdef_default_theme.c`); in Liquid Glass the same faces sit lightly on the glass.
 */

import SwiftUI

extension EnvironmentValues {
  /** Whether the bar's dropdowns name their value, or show the icon alone, as Blender's header
   * does when there is no room. */
  @Entry var widgetsNamed = true
}

/** Where a widget sits in a joined group: only the group's outer corners are rounded. */
enum WidgetJoin {
  case alone, first, middle, last
}

/** Blender's default theme colours for its widgets. */
enum BlenderWidgetColors {
  /** `wcol_menu`: a dropdown's inside, outline and text, and its arrow. */
  static let menuInner = Color(red: 0x28 / 255, green: 0x28 / 255, blue: 0x28 / 255)
  static let outline = Color(red: 0x3d / 255, green: 0x3d / 255, blue: 0x3d / 255)
  static let text = Color(red: 0xe6 / 255, green: 0xe6 / 255, blue: 0xe6 / 255)
  static let arrow = Color(red: 0xd9 / 255, green: 0xd9 / 255, blue: 0xd9 / 255)
  /** `wcol_toggle`: off and on. */
  static let toggleInner = ShellStyle.widget
  static let toggleOn = ShellStyle.selection
}

/** A widget's outline: Blender's 6-point rounding, or a capsule in glass; joined edges square. */
struct WidgetShape: Shape {
  let join: WidgetJoin
  let glass: Bool

  func path(in rect: CGRect) -> Path {
    let r = glass ? rect.height / 2 : ShellStyle.radius
    let lead = join == .alone || join == .first ? r : 0
    let trail = join == .alone || join == .last ? r : 0
    return UnevenRoundedRectangle(topLeadingRadius: lead, bottomLeadingRadius: lead, bottomTrailingRadius: trail,
                                  topTrailingRadius: trail, style: .continuous).path(in: rect)
  }
}

/** What a widget shows: its icon, its text where it has one, and ▾ for a dropdown. 32 points
 * tall, with a 44-point hit area. */
struct BlenderWidgetFace: View {
  let icon: UIImage?
  var text: String? = nil
  var arrow = false
  /** A toggle's state; nil for a dropdown. */
  var on: Bool? = nil
  var join = WidgetJoin.alone
  /** Shown but not in effect, as a dropdown beside a toggle that is off. */
  var dimmed = false
  var minWidth: CGFloat = 32
  @AppStorage(ShellStyle.key) private var style = ShellStyle.blender.rawValue

  private var glass: Bool { style == ShellStyle.glass.rawValue }

  private var fill: Color {
    if glass {
      return on == true ? Color.accentColor : Color.primary.opacity(0.08)
    }
    if let on { return on ? BlenderWidgetColors.toggleOn : BlenderWidgetColors.toggleInner }
    return BlenderWidgetColors.menuInner
  }

  private var foreground: Color {
    glass ? (on == true ? .white : .primary) : (on == true ? .white : BlenderWidgetColors.text)
  }

  var body: some View {
    HStack(spacing: 4) {
      if let icon {
        Image(uiImage: icon)
          .renderingMode(icon.renderingMode == .alwaysOriginal ? .original : .template)
          .resizable()
          .scaledToFit()
          .frame(width: 18, height: 18)
      }
      if let text, !text.isEmpty {
        Text(text)
          .font(.subheadline)
          .lineLimit(1)
          .fixedSize()
      }
      if arrow {
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(glass ? AnyShapeStyle(.secondary) : AnyShapeStyle(BlenderWidgetColors.arrow))
      }
    }
    .foregroundStyle(foreground)
    .padding(.horizontal, 8)
    .frame(minWidth: minWidth, minHeight: 32)
    .background(WidgetShape(join: join, glass: glass).fill(fill))
    .overlay {
      if !glass {
        WidgetShape(join: join, glass: false).strokeBorder(BlenderWidgetColors.outline, lineWidth: 1)
      }
    }
    .opacity(dimmed ? 0.5 : 1)
    /* The hit area is 44 points tall; the face stays Blender's size. */
    .padding(.vertical, 6)
    .contentShape(Rectangle())
  }
}

extension WidgetShape: InsettableShape {
  func inset(by amount: CGFloat) -> InsetWidgetShape { InsetWidgetShape(base: self, amount: amount) }
}

struct InsetWidgetShape: InsettableShape {
  let base: WidgetShape
  let amount: CGFloat

  func path(in rect: CGRect) -> Path { base.path(in: rect.insetBy(dx: amount, dy: amount)) }
  func inset(by more: CGFloat) -> InsetWidgetShape { InsetWidgetShape(base: base, amount: amount + more) }
}

/** A dropdown: the value's icon, its name where there is room, and ▾; the menu at the widget. */
struct BlenderDropdown<Items: View>: View {
  /** Its name, said when held and to VoiceOver. */
  let name: String
  let icon: UIImage?
  var text: String? = nil
  var join = WidgetJoin.alone
  var dimmed = false
  @ViewBuilder let items: () -> Items
  @Environment(\.widgetsNamed) private var named

  var body: some View {
    Menu {
      items()
    } label: {
      BlenderWidgetFace(icon: icon, text: named || icon == nil ? text : nil, arrow: true, join: join, dimmed: dimmed)
    }
    .menuIndicator(.hidden)
    .menuStyle(.button)
    .buttonStyle(.plain)
    .help(name)
    .accessibilityLabel(name)
    .accessibilityValue(text ?? "")
  }
}

/** A toggle lit while on, as Blender's icon toggles in its header. */
struct BlenderToggleButton: View {
  let name: String
  let icon: UIImage?
  var text: String? = nil
  let isOn: Bool
  var join = WidgetJoin.alone
  var minWidth: CGFloat = 32
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      BlenderWidgetFace(icon: icon, text: text, on: isOn, join: join, minWidth: minWidth)
    }
    .buttonStyle(.plain)
    .help(name)
    .accessibilityLabel(name)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

/** A separator between the bar's groups, as Blender's header spaces them. */
struct BlenderWidgetSeparator: View {
  var body: some View {
    Rectangle()
      .fill(Color.primary.opacity(0.2))
      .frame(width: 1, height: 22)
      .padding(.horizontal, 4)
  }
}
