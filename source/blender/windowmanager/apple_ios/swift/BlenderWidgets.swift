/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Blender's widgets as its headers draw them, for every bar (the tool settings row, the last
 * operation's strip, the Item card): a dropdown (icon, value, ▾), a toggle lit while on, a number
 * field, a vector of joined number fields, and either joined into one piece as Blender's
 * `row(align=True)` joins them, such as Snapping's magnet and its target. #BlenderSettingItem draws
 * any setting in a bar with them. In Blender's style they take the default theme's colours
 * (`wcol_menu`, `wcol_toggle`, `wcol_num`, `wcol_numslider` in `userdef_default_theme.c`); in
 * Liquid Glass the same faces sit lightly on the glass.
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
  /** `wcol_num`: a number field's inside, and while it is dragged or typed into. */
  static let numInner = Color(red: 0x54 / 255, green: 0x54 / 255, blue: 0x54 / 255)
  static let numInnerActive = Color(red: 0x22 / 255, green: 0x22 / 255, blue: 0x22 / 255)
  /** `wcol_numslider`: a slider's filled part. */
  static let sliderFill = Color(red: 0x47 / 255, green: 0x72 / 255, blue: 0xb3 / 255)
}

/** Where the widget at \a index of \a count joined ones sits. */
func widgetJoin(_ index: Int, _ count: Int) -> WidgetJoin {
  count <= 1 ? .alone : index == 0 ? .first : index == count - 1 ? .last : .middle
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

/* -------------------------------------------------------------------- */
/** \name Settings in a bar
 * \{ */

/** A vector's components as Blender draws them in a row: joined number fields, each named inside
 * (X, Y, Z). */
struct BlenderVectorField: View {
  let model: PanelsModel
  let group: NativeNode

  var body: some View {
    let items = model.children(of: group).filter { $0.role == .none_ && $0.number != nil }
    HStack(spacing: 1) {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        NativeNumberField(model: model, node: item, widget: widgetJoin(index, items.count), inlineLabel: item.shortLabel)
          .frame(width: 84)
          .controlActions(model, item, component: true)
          .accessibilityLabel("\(group.label) \(item.label)")
      }
    }
    .fixedSize()
  }
}

/** An option's picture: its preview, as a material's swatch, or else its icon. */
struct BlenderOptionIcon: View {
  let option: Blender_NativeUI_Option

  var body: some View {
    if let path = option.preview, let image = UIImage(contentsOfFile: path) {
      Image(uiImage: image)
        .resizable()
        .scaledToFill()
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
    else {
      IconView(name: option.icon)
    }
  }
}

/**
 * A choice as Blender's header draws it: its name, then a dropdown with the value
 * ("Orientation  ⌖ Global ▾"); a choice Blender draws expanded, of two to six short options, as
 * joined toggles, as Mirror's X Y Z.
 */
struct BlenderChoiceWidget: View {
  let model: PanelsModel
  let node: NativeNode
  @Environment(\.widgetsNamed) private var named

  private var title: String { node.shortLabel }
  private var options: [Blender_NativeUI_Option] { node.choice?.allOptions.filter { $0.value != nil } ?? [] }

  private func isChecked(_ option: Blender_NativeUI_Option) -> Bool {
    guard !model.isMixed(node), let value = option.value else { return false }
    let current = model.text(node)
    if node.choice?.multiple == true { return current.split(separator: ",").contains { $0 == value } }
    return value == current
  }

  private var allIcons: Bool { options.allSatisfy { BlenderIcon.image($0.icon) != nil } }

  private var expanded: Bool {
    node.choice?.style == .expanded && (2...6).contains(options.count) &&
      (allIcons || options.allSatisfy { ($0.label ?? "").count <= 5 }) &&
      !options.contains { !($0.preview ?? "").isEmpty }
  }

  var body: some View {
    Group {
      if expanded {
        HStack(spacing: 6) {
          if named {
            Text(title).font(.subheadline).foregroundStyle(.secondary).fixedSize()
          }
          HStack(spacing: 1) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
              BlenderToggleButton(name: option.label ?? "", icon: allIcons ? BlenderIcon.image(option.icon) : nil,
                                  text: allIcons ? nil : option.label, isOn: isChecked(option),
                                  join: widgetJoin(index, options.count), minWidth: 30) {
                model.set(node, .text(option.value ?? ""))
                Haptics.selection()
              }
            }
          }
        }
      }
      else {
        dropdown
      }
    }
    .help(title)
    .disabled(!node.enabled)
  }

  private var dropdown: some View {
    let value = model.text(node)
    return Menu {
      Picker(title, selection: Binding(get: { value }, set: { model.set(node, .text($0)) })) {
        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
          Label { Text(option.label ?? "") } icon: { BlenderOptionIcon(option: option) }
            .tag(option.value ?? "")
        }
      }
    } label: {
      /* The choice made, as the bar has room to name it, with its preview where it has one,
       * as a material's: it alone would not say which. */
      let current = options.first { $0.value == value }
      let name = model.isMixed(node) ? "—" : current?.label ?? title
      if let current, !(current.preview ?? "").isEmpty {
        HStack(spacing: 6) {
          BlenderOptionIcon(option: current)
          /* A data-block's name, the person's own: shortened in the middle if it must be. */
          Text(name).lineLimit(1).truncationMode(.middle)
        }
      }
      else {
        /* As Blender's `prop()` in its header: the setting's name, then a dropdown with the
         * value, so a value such as Default is never alone. */
        HStack(spacing: 6) {
          if title != name && named {
            Text(title).font(.subheadline).foregroundStyle(.secondary).fixedSize()
          }
          BlenderWidgetFace(icon: BlenderIcon.image(current?.icon ?? node.icon), text: name, arrow: true)
        }
      }
    }
    .menuIndicator(.hidden)
  }
}

/**
 * Any setting in a bar, by kind, with Blender's widgets: a number as its name and a field; a
 * vector as its name once and joined fields; a row of toggles (Constraint Axis) as its name and
 * joined toggles; a choice as #BlenderChoiceWidget; a toggle as Blender's checkbox with its name
 * beside it, or lit with its own icon; a button, a colour, one of Blender's menus. Held, each
 * offers Copy Value, Reset and keyframing. Names are never cut: the bar scrolls instead.
 */
struct BlenderSettingItem: View {
  let model: PanelsModel
  let node: NativeNode

  private var name: String { node.shortLabel }
  /** Blender's own icon for it, not the checkbox it draws a toggle with. */
  private var ownIcon: UIImage? {
    guard let icon = node.icon, !icon.isEmpty, !icon.hasPrefix("CHECKBOX") else { return nil }
    return BlenderIcon.image(icon)
  }

  var body: some View {
    content
      .fixedSize()
      .disabled(!node.enabled)
  }

  private func caption(_ text: String) -> some View {
    Text(text)
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .fixedSize()
  }

  @ViewBuilder
  private var content: some View {
    switch node.kind {
      case .group:
        let items = model.children(of: node).filter { $0.role == .none_ }
        if !items.isEmpty && items.allSatisfy({ $0.kind == .toggle }) {
          HStack(spacing: 6) {
            caption(node.label)
            HStack(spacing: 1) {
              ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let on = !model.isMixed(item) && model.bool(item)
                BlenderToggleButton(name: "\(node.label) \(item.label)", icon: nil, text: item.shortLabel, isOn: on,
                                    join: widgetJoin(index, items.count), minWidth: 30) {
                  model.set(item, .bool(!on))
                  Haptics.selection()
                }
                .disabled(!item.enabled)
                .controlActions(model, item)
              }
            }
          }
        }
        else if !items.isEmpty && items.allSatisfy({ $0.kind == .number }) {
          HStack(spacing: 6) {
            caption(node.label)
            BlenderVectorField(model: model, group: node)
          }
        }
        else {
          HStack(spacing: 12) {
            ForEach(items) { BlenderSettingItem(model: model, node: $0) }
          }
        }
      case .number:
        HStack(spacing: 6) {
          caption(name)
          NativeNumberField(model: model, node: node, widget: .alone)
            .frame(width: 84)
        }
        .controlActions(model, node)
      case .choice:
        BlenderChoiceWidget(model: model, node: node)
          .controlActions(model, node)
      case .toggle where ownIcon != nil:
        let on = model.bool(node)
        BlenderToggleButton(name: name, icon: ownIcon, text: name, isOn: on) { model.set(node, .bool(!on)) }
          .controlActions(model, node)
      case .toggle:
        Toggle(isOn: Binding(get: { model.bool(node) }, set: { model.set(node, .bool($0)) })) {
          Text(name).font(.subheadline)
        }
        .toggleStyle(BlenderCheckboxStyle())
        .controlActions(model, node)
      case .button:
        Button { model.send(node, .invoke) } label: {
          BlenderWidgetFace(icon: ownIcon, text: name)
        }
        .buttonStyle(.plain)
        .controlActions(model, node)
      case .color:
        HStack(spacing: 6) {
          caption(name)
          NativeColorPicker(model: model, node: node)
            .frame(width: 32, height: 22)
            .clipShape(WidgetShape(join: .alone, glass: false))
            .overlay(WidgetShape(join: .alone, glass: false).strokeBorder(BlenderWidgetColors.outline, lineWidth: 1))
            .accessibilityLabel(node.label)
        }
        .controlActions(model, node)
      case .menubutton:
        /* One of Blender's menus, such as Sculpt Mode's Mask and Face Sets. */
        let route = BlenderMenus.route(menuName(node), tab: model.currentTab)
        BlenderDropdown(name: node.label, icon: ownIcon, text: node.label) {
          BlenderMenuItems(route: route)
        }
        .prefetchingBlenderMenu(route)
      default:
        EmptyView()
    }
  }
}

/** \} */
