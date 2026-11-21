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
  /** `wcol_text`: a text field's inside. */
  static let textInner = Color(red: 0x1d / 255, green: 0x1d / 255, blue: 0x1d / 255)
}

/** The rounded corners of a cell in a grid of joined widgets, as Blender's aligned `grid_flow`. */
struct WidgetCorners: Equatable {
  var topLeading = false, topTrailing = false, bottomLeading = false, bottomTrailing = false

  /** The cell at \a index of \a count, filled row by row \a columns to a row: the grid's outer
   * corners are rounded, joined edges square. */
  static func cell(_ index: Int, of count: Int, columns: Int) -> WidgetCorners {
    let rows = (count + columns - 1) / columns
    let row = index / columns, column = index % columns
    let lastInRow = column == columns - 1 || index == count - 1
    /* Nothing below it: the last row, or a cell of the row above past the last row's end. */
    let nothingBelow = row == rows - 1 || index + columns >= count
    return WidgetCorners(topLeading: row == 0 && column == 0, topTrailing: row == 0 && lastInRow,
                         bottomLeading: row == rows - 1 && column == 0, bottomTrailing: nothingBelow && lastInRow)
  }
}

/** Where the widget at \a index of \a count joined ones sits. */
func widgetJoin(_ index: Int, _ count: Int) -> WidgetJoin {
  count <= 1 ? .alone : index == 0 ? .first : index == count - 1 ? .last : .middle
}

/** A widget's outline: Blender's 6-point rounding, or a capsule in glass; joined edges square.
 * Joined side by side, or (\a vertical) stacked, as a vector's fields in Properties. */
struct WidgetShape: Shape {
  let join: WidgetJoin
  let glass: Bool
  var vertical = false
  /** A cell of a grid of joined widgets: which of its corners are the grid's, rounded. */
  var corners: WidgetCorners? = nil

  func path(in rect: CGRect) -> Path {
    if let corners {
      let r = glass ? min(10, rect.height / 2) : ShellStyle.radius
      return UnevenRoundedRectangle(topLeadingRadius: corners.topLeading ? r : 0,
                                    bottomLeadingRadius: corners.bottomLeading ? r : 0,
                                    bottomTrailingRadius: corners.bottomTrailing ? r : 0,
                                    topTrailingRadius: corners.topTrailing ? r : 0, style: .continuous).path(in: rect)
    }
    let r = glass ? (vertical && join != .alone ? min(10, rect.height / 2) : rect.height / 2) : ShellStyle.radius
    let start = join == .alone || join == .first ? r : 0
    let end = join == .alone || join == .last ? r : 0
    if vertical {
      return UnevenRoundedRectangle(topLeadingRadius: start, bottomLeadingRadius: end, bottomTrailingRadius: end,
                                    topTrailingRadius: start, style: .continuous).path(in: rect)
    }
    return UnevenRoundedRectangle(topLeadingRadius: start, bottomLeadingRadius: start, bottomTrailingRadius: end,
                                  topTrailingRadius: end, style: .continuous).path(in: rect)
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
  /** As wide as what holds it, as a widget in Properties' column: the text leading, ▾ trailing. */
  var fills = false
  /** Joined top to bottom rather than side by side. */
  var vertical = false
  /** A cell of a grid of joined widgets, see #WidgetCorners. */
  var corners: WidgetCorners? = nil
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

  /** Space either side of the content. */
  static let padding: CGFloat = 8
  /** How far a name in a widget that fills its space may shrink before it would be cut. */
  static let textShrink: CGFloat = 0.75

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
        if fills {
          /* A value in a column: it shrinks a little before it would be cut. */
          Text(text)
            .font(.subheadline)
            .lineLimit(1)
            .minimumScaleFactor(Self.textShrink)
        }
        else {
          Text(text)
            .font(.subheadline)
            .lineLimit(1)
            .fixedSize()
        }
      }
      if fills && arrow {
        Spacer(minLength: 0)
      }
      if arrow {
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(glass ? AnyShapeStyle(.secondary) : AnyShapeStyle(BlenderWidgetColors.arrow))
      }
    }
    .foregroundStyle(foreground)
    .padding(.horizontal, Self.padding)
    .frame(minWidth: minWidth, maxWidth: fills ? .infinity : nil, minHeight: 32)
    .background(WidgetShape(join: join, glass: glass, vertical: vertical, corners: corners).fill(fill))
    .overlay {
      if !glass {
        WidgetShape(join: join, glass: false, vertical: vertical, corners: corners)
          .strokeBorder(BlenderWidgetColors.outline, lineWidth: 1)
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
  /** Joined top to bottom, as a column of Blender's expanded options. */
  var vertical = false
  /** As wide as what holds it. */
  var fills = false
  /** A cell of a grid of joined options, see #WidgetCorners. */
  var corners: WidgetCorners? = nil
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      BlenderWidgetFace(icon: icon, text: text, on: isOn, join: join, minWidth: minWidth, fills: fills,
                        vertical: vertical, corners: corners)
    }
    .buttonStyle(.plain)
    .help(name)
    .accessibilityLabel(name)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

/** A separator between the bar's groups, as Blender's header spaces them. */
struct BlenderWidgetSeparator: View {
  /** Beside it, on top of the spacing of the row it stands in: none in the tool settings row,
   * whose one spacing stands on either side of it. */
  var padding: CGFloat = 4

  var body: some View {
    Rectangle()
      .fill(Color.primary.opacity(0.2))
      .frame(width: 1, height: 22)
      .padding(.horizontal, padding)
  }
}

/* -------------------------------------------------------------------- */
/** \name Settings in a bar
 * \{ */

/** A vector's components as Blender draws them: joined number fields, each named inside (X, Y,
 * Z); side by side in a bar, stacked top to bottom in Properties (\a axis), where a component's
 * lock stays at its field's end. */
struct BlenderVectorField: View {
  let model: PanelsModel
  let group: NativeNode
  var axis = Axis.horizontal

  var body: some View {
    let items = model.children(of: group).filter { $0.role == .none_ && $0.number != nil }
    if axis == .horizontal {
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
    else {
      VStack(spacing: 1) {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
          HStack(spacing: 2) {
            NativeNumberField(model: model, node: item, widget: widgetJoin(index, items.count), inlineLabel: item.shortLabel,
                              vertical: true)
              .controlActions(model, item, component: true)
              .accessibilityLabel("\(group.label) \(item.label)")
            if let lock = model.attached(item, .lock) {
              BlenderLockButton(model: model, lock: lock, name: "\(group.label) \(item.label)")
            }
          }
        }
      }
    }
  }
}

/** A component's lock at its field's end, as Blender's padlock beside Location's X. */
struct BlenderLockButton: View {
  let model: PanelsModel
  let lock: NativeNode
  let name: String

  var body: some View {
    let locked = model.bool(lock)
    Button {
      model.set(lock, .bool(!locked))
      Haptics.selection()
    } label: {
      Image(systemName: locked ? "lock.fill" : "lock.open")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(locked ? .primary : .secondary)
        .frame(width: 24, height: 32)
        .contentShape(Rectangle().inset(by: -6))
    }
    .buttonStyle(.plain)
    .disabled(!lock.enabled)
    .accessibilityLabel(locked ? "Unlock \(name)" : "Lock \(name)")
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
  /** As wide as its column, its name beside it in Properties' property split rather than in it. */
  var fills = false
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
      else if fills {
        /* In Properties: the value's icon and name, ▾ at the column's end. */
        BlenderWidgetFace(icon: BlenderIcon.image(current?.icon ?? node.icon), text: name, arrow: true, fills: true)
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
          BlenderColorButton(model: model, node: node)
            .frame(width: 32, height: 22)
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

/**
 * Blender's colour button: a bar holding the colour, its alpha shown over a checkerboard in its
 * trailing half, inside the widget outline. A tap opens the system's colour picker, whose changes
 * preview live as one step to undo, see #ColorPickerSession.
 */
struct BlenderColorButton: View {
  let model: PanelsModel
  let node: NativeNode
  @State private var anchor = AnchorBox()
  @AppStorage(ShellStyle.key) private var style = ShellStyle.blender.rawValue

  var body: some View {
    let glass = style == ShellStyle.glass.rawValue
    let shape = WidgetShape(join: .alone, glass: glass)
    let values = model.floats(node)
    let alpha = node.content(Blender_NativeUI_Color.self)?.alpha == true && values.count > 3 ? values[3] : 1
    let color = Color(uiColor: blenderColor(values.map { NSNumber(value: $0) }))
    let mixed = model.isMixed(node)
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        color.opacity(1)
        if alpha < 0.999 {
          /* The colour as it covers what is behind it, as Blender's trailing half shows. */
          HStack(spacing: 0) {
            Color.clear
            ZStack {
              ColorCheckerboard()
              color.opacity(alpha)
            }
            .frame(width: proxy.size.width / 2)
          }
        }
        if mixed {
          Text("—").font(.subheadline.weight(.semibold)).foregroundStyle(.white).frame(maxWidth: .infinity)
        }
      }
    }
    .clipShape(shape)
    .overlay(shape.strokeBorder(glass ? Color.primary.opacity(0.2) : BlenderWidgetColors.outline, lineWidth: 1))
    .contentShape(Rectangle())
    .background(PresentationAnchor(anchor: anchor))
    .onTapGesture {
      guard node.enabled else { return }
      ColorPickerSession(model: model, node: node).present(from: anchor)
    }
    .opacity(node.enabled ? 1 : 0.5)
    .accessibilityElement()
    .accessibilityLabel(node.label)
    .accessibilityValue(mixed ? "Mixed" : "")
    .accessibilityAddTraits(.isButton)
  }
}

/** What shows through a colour that is not opaque. */
struct ColorCheckerboard: View {
  var body: some View {
    Canvas { context, size in
      let cell: CGFloat = 6
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
      for row in 0..<Int(ceil(size.height / cell)) {
        for column in stride(from: row % 2, to: Int(ceil(size.width / cell)), by: 2) {
          context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                       with: .color(.gray.opacity(0.5)))
        }
      }
    }
  }
}

/** \} */
