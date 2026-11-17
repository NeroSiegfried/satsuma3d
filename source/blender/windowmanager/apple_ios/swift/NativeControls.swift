/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * A native control for each kind of node a view sends: switches, number fields that scrub
 * sideways or take typed values, sliders, choices, colors and text. Touch and hold for locking
 * and keyframing.
 */

import SwiftUI
import UIKit

/* -------------------------------------------------------------------- */
/** \name Numbers
 * \{ */

extension Blender_NativeUI_Number {
  var isAngle: Bool { kind == .angle }
  /** From Blender's value to what shows: degrees for an angle. */
  var shownFactor: Double { isAngle ? 180.0 / .pi : 1 }

  /** As Blender draws it: exactly the decimals Blender shows for this property and value
   * (`precision`, which the bridge sends from `ui_but_calc_float_precision`), so `1.143` and
   * `1.000`, never a float's noise. */
  func format(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.roundingMode = .halfUp
    let decimals = integer ? 0 : Int(precision)
    formatter.minimumFractionDigits = decimals
    formatter.maximumFractionDigits = decimals
    var shown = value * shownFactor
    if integer { shown = shown.rounded() }
    let text = formatter.string(from: NSNumber(value: shown)) ?? "\(shown)"
    guard let unit, !unit.isEmpty else { return text }
    return text + " " + unit
  }

  /** The value in full, as it is typed into or copied: up to six decimals, trailing zeros dropped,
   * so opening a field and closing it never rounds what was there (decision 26). */
  func editingText(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.maximumFractionDigits = integer ? 0 : 6
    var shown = value * shownFactor
    if integer { shown = shown.rounded() }
    return formatter.string(from: NSNumber(value: shown)) ?? "\(shown)"
  }

  func parse(_ text: String) -> Double? {
    var trimmed = text.trimmingCharacters(in: .whitespaces)
    if let unit, !unit.isEmpty, trimmed.hasSuffix(unit) {
      trimmed = String(trimmed.dropLast(unit.count)).trimmingCharacters(in: .whitespaces)
    }
    let scanner = Scanner(string: trimmed)
    scanner.locale = Locale.current
    var number = scanner.scanDouble()
    if number == nil || !scanner.isAtEnd {
      /* Accept a period even where the locale's decimal separator differs. */
      number = Double(trimmed)
    }
    guard let number, number.isFinite else { return nil }
    return number / shownFactor
  }

  func clamp(_ value: Double) -> Double { Swift.min(max, Swift.max(min, value)) }

  /** The soft range is wide, as Dyntopo's detail: a drag changes it by a ratio. */
  var scalesByRatio: Bool {
    !integer && softMax.isFinite && softMin.isFinite && softMax - softMin > 11 && min > 0
  }
}

/** Numbers as Blender's native fields draw them: 15 point digits that scale with the text size. */
private let numberFont = Font(UIFontMetrics(forTextStyle: .body)
  .scaledFont(for: .monospacedDigitSystemFont(ofSize: 15, weight: .regular)))

/** A number that scrubs with a sideways drag (drag up for coarser, down for finer steps) and
 * takes a typed value on tap, with a stepper above the keyboard. */
struct NativeNumberField: View {
  let model: PanelsModel
  let node: NativeNode
  var compact = false
  /** Taller than the compact size, as in a vector. */
  var height: CGFloat?
  /** Sliders scrub with their track instead. */
  var scrubs = true
  /** Drawn as Blender's number field (`wcol_num`), joined thus in a vector: as every bar draws
   * numbers, see #BlenderSettingItem. */
  var widget: WidgetJoin? = nil
  /** Its name inside the field, leading, as a vector's X, Y and Z. */
  var inlineLabel: String? = nil
  /** Joined top to bottom rather than side by side, as a vector's fields in Properties. */
  var vertical = false

  @AppStorage(ShellStyle.key) private var style = ShellStyle.blender.rawValue
  @State private var editing = false
  @State private var text = ""
  @State private var scrubValue: Double?
  @State private var scrubStart = 0.0
  @State private var lastTranslation = 0.0
  @State private var lastPreview: CFTimeInterval = 0
  @State private var stepperValue = 0.0
  /** Under the pointer, which shows the field can be dragged sideways. */
  @State private var hovering = false
  /** The field's UIKit view, for the drag sensitivity indicator. */
  @State private var scrubAnchor = AnchorBox()
  @FocusState private var focused: Bool

  private var number: Blender_NativeUI_Number? { node.number }
  private var editable: Bool { node.enabled }
  private var draggable: Bool { scrubs && editable && !editing }
  private var value: Double { scrubValue ?? model.number(node) }
  /** The selected items' values differ: a dash, until a drag or a typed value sets them. */
  private var mixed: Bool { scrubValue == nil && model.isMixed(node) }
  private var shown: String {
    mixed ? "—" : number?.format(value) ?? ""
  }
  /** What typing starts from: the value in full. */
  private var editingText: String { number?.editingText(value) ?? "" }

  var body: some View {
    ZStack(alignment: .trailing) {
      if editing {
        TextField("", text: $text, prompt: model.isMixed(node) ? Text("—") : nil)
          .keyboardType(.numbersAndPunctuation)
          .multilineTextAlignment(.trailing)
          .font(numberFont)
          .focused($focused)
          .selectsAllOnFocus(focused)
          .liftsAboveKeyboard(focused)
          .submitLabel(.done)
          .onSubmit { commit() }
          .keyboardAccessory {
            Stepper("Adjust \(node.label)", value: $stepperValue, in: stepperRange, step: stepperStep)
              .labelsHidden()
              .onChange(of: stepperValue) { _, newValue in
                text = formatStepper(newValue)
              }
            Spacer()
            Button("Done") { focused = false }
              .bold()
          }
      }
      else {
        HStack(spacing: 4) {
          if widget != nil, let inlineLabel, !inlineLabel.isEmpty {
            Text(inlineLabel)
              .font(.subheadline)
              .foregroundStyle(Color.primary.opacity(0.6))
              .fixedSize()
          }
          Text(shown)
            .font(numberFont)
            /* New values just show, even when rows around them animate. */
            .contentTransition(.identity)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(editable ? .primary : .tertiary)
            /* Blender centres a number without a name inside its field. */
            .frame(maxWidth: .infinity, alignment: widget != nil && (inlineLabel ?? "").isEmpty ? .center : .trailing)
        }
      }
    }
    .padding(.horizontal, 8)
    .frame(minHeight: widget != nil ? 32 : height ?? (compact ? 30 : 40))
    .background { fieldBackground }
    .overlay {
      /* Arrows at the ends say the number drags sideways: shown under the pointer, and in the
       * tint while dragging, like Blender's own number fields. */
      if scrubValue != nil || (hovering && draggable) {
        HStack {
          Image(systemName: "chevron.left")
          Spacer()
          Image(systemName: "chevron.right")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(scrubValue != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 3)
        .allowsHitTesting(false)
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: 8))
    .pointerHighlight()
    .onHover { hovering = $0 }
    .onTapGesture { beginEditing() }
    .background(PresentationAnchor(anchor: scrubAnchor))
    .gesture(ScrubGesture(enabled: draggable, anchor: scrubAnchor,
                          began: beginScrub, changed: changeScrub, ended: endScrub))
    .onChange(of: focused) { _, isFocused in
      if !isFocused && editing { commit() }
    }
    .onChange(of: model.identity) { _, _ in
      editing = false
      scrubValue = nil
    }
    .accessibilityElement()
    .accessibilityLabel(node.label)
    .accessibilityValue(mixed ? "Mixed" : shown)
    .accessibilityAdjustableAction { direction in
      guard let number else { return }
      let step = stepperStep / number.shownFactor
      model.set(node, .float(number.clamp(value + (direction == .increment ? step : -step))))
    }
  }

  private var glass: Bool { style == ShellStyle.glass.rawValue }

  /** The field's face: the system's rounded field, or Blender's widget with a slider's fill. */
  @ViewBuilder
  private var fieldBackground: some View {
    if let widget {
      let shape = WidgetShape(join: widget, glass: glass, vertical: vertical)
      ZStack(alignment: .leading) {
        shape.fill(widgetFill)
        if let number, number.slider, !mixed {
          /* A slider fills its leading part to the value, as Blender's does. */
          GeometryReader { proxy in
            Rectangle()
              .fill(BlenderWidgetColors.sliderFill.opacity(glass ? 0.7 : 1))
              .frame(width: proxy.size.width * number.fraction(of: value))
          }
          .clipShape(shape)
        }
        if !glass {
          shape.strokeBorder(BlenderWidgetColors.outline, lineWidth: 1)
        }
      }
    }
    else {
      RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background)
    }
  }

  private var widgetFill: Color {
    let active = scrubValue != nil || editing
    if let color = nativeAnimationColor(node.node.animation), !active { return color.opacity(0.35) }
    if glass { return Color.primary.opacity(active ? 0.18 : 0.08) }
    return active ? BlenderWidgetColors.numInnerActive : BlenderWidgetColors.numInner
  }

  private var background: Color {
    if scrubValue != nil || editing { return Color.accentColor.opacity(0.18) }
    if let color = nativeAnimationColor(node.node.animation) { return color.opacity(0.35) }
    return PanelStyle.field
  }

  private var stepperStep: Double { (number?.isAngle ?? false) || (number?.integer ?? false) ? 1 : 0.1 }

  private var stepperRange: ClosedRange<Double> {
    let factor = number?.shownFactor ?? 1
    let low = max(-1e12, (number?.min ?? -1e12) * factor)
    let high = min(1e12, (number?.max ?? 1e12) * factor)
    return low <= high ? low...high : -1e12...1e12
  }

  private func formatStepper(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.maximumFractionDigits = 6
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
  }

  private func beginEditing() {
    guard editable, scrubValue == nil else { return }
    /* The full value, not the rounded one shown: Done without typing changes nothing. */
    text = mixed ? "" : editingText
    stepperValue = value * (number?.shownFactor ?? 1)
    editing = true
    focused = true
  }

  private func commit() {
    guard editing, let number else { return }
    editing = false
    focused = false
    /* A typed value sets every selected item, even one that already has it. */
    if model.isMixed(node) ? text.trimmingCharacters(in: .whitespaces).isEmpty : text == editingText { return }
    guard let parsed = number.parse(text) else {
      return
    }
    model.set(node, .float(number.clamp(number.integer ? parsed.rounded() : parsed)))
  }

  private func beginScrub() {
    guard editable else { return }
    scrubStart = model.number(node)
    scrubValue = scrubStart
    lastTranslation = 0
    lastPreview = 0
    Haptics.selection()
  }

  private func changeScrub(_ translation: CGPoint) {
    guard let current = scrubValue, let number, translation.x.isFinite, translation.y.isFinite else { return }
    var step = number.step > 0 ? number.step : (number.integer ? 0.5 : 0.01)
    if number.isAngle { step *= 10 * .pi / 180 }
    let motion = (translation.x - lastTranslation) * scrubSensitivity(translation.y)
    /* Integrate the horizontal motion, so changing precision never reinterprets earlier motion. */
    var next = current + motion * step
    /* A size or resolution over a wide range changes by a ratio: the same drag scales it alike,
     * small or large. */
    if number.scalesByRatio, current > 0 {
      next = current * exp(motion * 0.01)
    }
    lastTranslation = translation.x
    scrubValue = number.clamp(next)
    if CACurrentMediaTime() - lastPreview >= 1.0 / 60.0, let value = scrubValue {
      model.set(node, .float(rounded(value)), phase: .update)
      lastPreview = CACurrentMediaTime()
    }
  }

  private func endScrub(_ cancelled: Bool) {
    guard let value = scrubValue else { return }
    let result = rounded(value)
    model.set(node, .float(cancelled ? scrubStart : result),
              phase: cancelled || result == scrubStart ? .cancel : .end)
    scrubValue = nil
  }

  private func rounded(_ value: Double) -> Double { number?.integer == true ? value.rounded() : value }
}

/** Blender's color for an animated property's control. */
func nativeAnimationColor(_ animation: Blender_NativeUI_Animation) -> Color? {
  switch animation {
    case .keyed: return animationStateColor("KEYED")
    case .animated: return animationStateColor("ANIMATED")
    case .changed: return animationStateColor("CHANGED")
    case .driven: return animationStateColor("DRIVEN")
    default: return nil
  }
}

extension Blender_NativeUI_Number {
  /** The slider's track, along the soft range, linear, logarithmic or cubic. */
  func value(atFraction fraction: Double) -> Double {
    if scale == .logarithmic && softMin > 0 { return softMin * pow(softMax / softMin, fraction) }
    let linear = softMin + fraction * (softMax - softMin)
    if scale == .cubic {
      return (pow(linear, 3) - pow(softMin, 3)) / (pow(softMax, 3) - pow(softMin, 3)) * (softMax - softMin) + softMin
    }
    return linear
  }

  func fraction(of value: Double) -> Double {
    var fraction = (value - softMin) / (softMax - softMin)
    if scale == .logarithmic && softMin > 0 {
      fraction = value > 0 ? log(value / softMin) / log(softMax / softMin) : 0
    }
    else if scale == .cubic {
      let cube = fraction * (pow(softMax, 3) - pow(softMin, 3)) + pow(softMin, 3)
      fraction = (cbrt(cube) - softMin) / (softMax - softMin)
    }
    return fraction.isFinite ? Swift.min(1, Swift.max(0, fraction)) : 0
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Rows
 * \{ */

/** Value, lock and keyframe actions for a control, shown when touching and holding it: what a
 * pointer over it does on the desktop with Backspace, Ctrl+C and Ctrl+V. */
struct ControlActions: View {
  let model: PanelsModel
  let node: NativeNode
  /** A component of a vector, such as Location's X: keyframes of it alone, or of them all. */
  var component = false

  /** Whether a hold on \a node has anything to offer. */
  static func offered(_ model: PanelsModel, _ node: NativeNode) -> Bool {
    node.number != nil || node.kind == .textfield || node.node.animatable || model.attached(node, .lock) != nil
  }

  /** Its value as text, as copied: what the field shows, without grouping. */
  private var copiedText: String? {
    if let number = node.number {
      return number.editingText(model.number(node))
    }
    return node.kind == .textfield ? model.text(node) : nil
  }

  var body: some View {
    if let copied = copiedText {
      Section {
        if let number = node.number {
          Button {
            model.set(node, .float(number.clamp(number.defaultValue)))
          } label: {
            Label("Reset to Default Value", systemImage: "arrow.counterclockwise")
          }
          .disabled(!node.enabled || model.number(node) == number.defaultValue)
        }
        Button {
          UIPasteboard.general.string = copied
        } label: {
          Label("Copy Value", systemImage: "doc.on.doc")
        }
        Button {
          paste()
        } label: {
          Label("Paste Value", systemImage: "doc.on.clipboard")
        }
        .disabled(!node.enabled || !UIPasteboard.general.hasStrings)
      }
    }
    if let lock = model.attached(node, .lock) {
      let locked = model.bool(lock)
      Button {
        model.set(lock, .bool(!locked))
      } label: {
        Label(locked ? "Unlock" : "Lock", systemImage: locked ? "lock.open" : "lock")
      }
      .disabled(!lock.enabled)
    }
    if node.node.animatable {
      let keyed = node.node.animation == .keyed
      let animated = node.node.animation != .none_
      keyframeButton(keyed ? "Replace" : "Insert", op: .keyframeinsert, icon: "KEY_HLT")
      if keyed { keyframeButton("Delete", op: .keyframedelete, icon: "KEY_DEHLT") }
      if animated { keyframeButton("Clear", op: .keyframesclear, icon: "KEY_DEHLT") }
    }
  }

  @ViewBuilder
  private func keyframeButton(_ verb: String, op: NativeOp, icon: String) -> some View {
    let plural = component || op == .keyframesclear
    entry("\(verb) \(plural ? "Keyframes" : "Keyframe")", icon) { model.send(node, op, .bool(true)) }
    if component {
      entry("\(verb) Single \(op == .keyframesclear ? "Keyframes" : "Keyframe")", icon) {
        model.send(node, op, .bool(false))
      }
    }
  }

  /** Paste: a number as if typed into the field, so its unit and the locale's decimals parse. */
  private func paste() {
    guard let text = UIPasteboard.general.string else { return }
    if let number = node.number {
      guard let value = number.parse(text) else {
        ShellModel.current?.messages.say("The copied text is not a number", level: "warning")
        return
      }
      model.set(node, .float(number.clamp(number.integer ? value.rounded() : value)))
    }
    else {
      model.set(node, .text(text))
    }
  }

  private func entry(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label {
        Text(title)
      } icon: {
        if let image = BlenderIcon.image(icon) { Image(uiImage: image) }
      }
    }
  }
}

extension View {
  @ViewBuilder
  func controlActions(_ model: PanelsModel, _ node: NativeNode, component: Bool = false) -> some View {
    if ControlActions.offered(model, node) {
      self.contextMenu { ControlActions(model: model, node: node, component: component) }
    }
    else {
      self
    }
  }
}

/**
 * A control as a row of Blender's Properties editor (ROUND5 7C, decision 29): Blender's property
 * split, the name right-aligned in the leading 40 % and the widget in the rest, rows 32 points
 * tall, with the widgets every bar uses (#BlenderWidgets): a number is Blender's field, filled to
 * its value when it is a slider; a vector three fields stacked and joined; a toggle Blender's
 * checkbox with its name; a choice Blender's dropdown, or joined toggles where Blender draws it
 * expanded; a colour Blender's colour bar; text Blender's text field; a button Blender's. A name
 * that does not fit wraps; it is never cut.
 */
struct ControlRow: View {
  let model: PanelsModel
  let node: NativeNode
  /** Where a data-block is linked from, drawn at the end of its row (`Role.link`). */
  var link: NativeNode? = nil

  var body: some View {
    Group {
      switch node.kind {
        case .group:
          switch node.group?.layout ?? .column {
            case .row:
              BlenderVectorRow(model: model, group: node)
            case .joined:
              split(node.label) { BlenderJoinedToggles(model: model, group: node) }
            default:
              PanelColumn(spacing: 4) {
                ForEach(model.children(of: node)) { ControlRow(model: model, node: $0) }
              }
          }
        case .toggle:
          split(nil) { BlenderPropertyToggle(model: model, node: node) }
        case .number:
          split(node.label, lock: true) {
            NativeNumberField(model: model, node: node, widget: .alone)
          }
        case .textfield:
          split(node.label) { NativeTextField(model: model, node: node) }
        case .choice:
          BlenderChoiceRow(model: model, node: node)
        case .color:
          split(node.label) {
            BlenderColorButton(model: model, node: node)
              .frame(height: 32)
          }
        case .ramp:
          NativeRamp(model: model, node: node)
            .padding(.vertical, 6)
        case .reference:
          ReferenceRow(model: model, node: node, link: link)
        case .list:
          NativeList(model: model, node: node)
        case .row:
          ItemRowView(model: model, node: node)
            .padding(.vertical, 4)
        case .picture:
          PictureRow(model: model, node: node)
            .padding(.vertical, 4)
        case .menubutton:
          NativeMenuButton(model: model, node: node)
        case .button:
          NativeButton(model: model, node: node)
        case .label:
          split(node.label) {
            Text(model.text(node))
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        default:
          EmptyView()
      }
    }
    .controlActions(model, node)
  }

  private func split<Control: View>(_ name: String?, lock: Bool = false, @ViewBuilder control: @escaping () -> Control)
    -> some View
  {
    BlenderPropertySplit(name: name, icon: node.node.leadingIcon,
                         locked: lock ? model.attached(node, .lock).map { model.bool($0) } ?? false : false,
                         control: control)
  }
}

/** Blender's property split (`use_property_split`): the name right-aligned in the leading 40 %,
 * wrapping rather than being cut, and the widget in the rest, at least 32 points tall. */
struct BlenderPropertySplit<Control: View>: View {
  let name: String?
  var icon: String? = nil
  var locked = false
  @ViewBuilder let control: () -> Control

  var body: some View {
    FractionRow(fraction: 0.6, spacing: 8) {
      BlenderSplitName(name: name, icon: icon, locked: locked)
      control()
        .frame(maxWidth: .infinity, minHeight: 32)
    }
    .frame(minHeight: 32)
  }
}

/** The name column of Blender's property split: right-aligned, wrapping rather than being cut. */
struct BlenderSplitName: View {
  let name: String?
  var icon: String? = nil
  var locked = false

  var body: some View {
    HStack(spacing: 4) {
      Spacer(minLength: 0)
      if let image = BlenderIcon.image(icon) {
        Image(uiImage: image).resizable().scaledToFit().frame(width: 16, height: 16).foregroundStyle(.secondary)
      }
      if let name, !name.isEmpty {
        Text(name)
          .font(.subheadline)
          .foregroundStyle(.primary.opacity(0.8))
          .multilineTextAlignment(.trailing)
          .fixedSize(horizontal: false, vertical: true)
      }
      if locked {
        Image(systemName: "lock.fill")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Locked")
      }
    }
  }
}

/** A vector such as Location, as Blender's Properties draws it: its name beside the first of its
 * fields, the fields stacked and joined, X, Y and Z inside each; its mode, such as Rotation's,
 * below as a dropdown of its own. */
struct BlenderVectorRow: View {
  let model: PanelsModel
  let group: NativeNode

  var body: some View {
    let items = model.children(of: group).filter { $0.role == .none_ }
    let numbers = items.filter { $0.number != nil }
    PanelColumn(spacing: 4) {
      if numbers.count == items.count {
        FractionRow(fraction: 0.6, spacing: 8, aligned: .top) {
          BlenderSplitName(name: group.label)
            .frame(minHeight: 32)
          BlenderVectorField(model: model, group: group, axis: .vertical)
        }
      }
      else {
        /* A row of numbers and toggles, such as a minimum with its switch: each as it is. */
        ForEach(items) { ControlRow(model: model, node: $0) }
      }
      if let mode = model.attached(group, .mode) {
        BlenderPropertySplit(name: mode.label.isEmpty ? "Mode" : mode.label) {
          BlenderChoiceWidget(model: model, node: mode, fills: true)
        }
        .controlActions(model, mode)
      }
    }
  }
}

/** Toggles Blender draws joined, such as Mirror's X Y Z, as its joined toggle buttons. */
struct BlenderJoinedToggles: View {
  let model: PanelsModel
  let group: NativeNode

  var body: some View {
    let items = model.children(of: group)
    HStack(spacing: 1) {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        let mixed = model.isMixed(item)
        let on = !mixed && model.bool(item)
        BlenderToggleButton(name: "\(group.label) \(item.label)", icon: nil, text: item.shortLabel, isOn: on,
                            join: widgetJoin(index, items.count), fills: true) {
          model.set(item, .bool(!on))
          Haptics.selection()
        }
        .disabled(!item.enabled)
        .controlActions(model, item)
        .accessibilityValue(mixed ? "Mixed" : "")
      }
    }
  }
}

/** A toggle as Blender's Properties draws it: its checkbox with its name beside it, in the widget
 * column; with an icon of its own, a toggle button lit while on. */
struct BlenderPropertyToggle: View {
  let model: PanelsModel
  let node: NativeNode

  private var ownIcon: UIImage? {
    guard let icon = node.icon, !icon.isEmpty, !icon.hasPrefix("CHECKBOX") else { return nil }
    return BlenderIcon.image(icon)
  }

  var body: some View {
    let on = model.bool(node)
    let mixed = model.isMixed(node)
    Group {
      if let ownIcon {
        BlenderToggleButton(name: node.label, icon: ownIcon, text: node.label, isOn: on && !mixed, fills: true) {
          model.set(node, .bool(!on))
        }
      }
      else {
        Toggle(isOn: Binding(get: { on && !mixed }, set: { model.set(node, .bool($0)) })) {
          Text(mixed ? "\(node.label) —" : node.label)
            .font(.subheadline)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(BlenderCheckboxStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .disabled(!node.enabled)
    .accessibilityValue(mixed ? "Mixed" : "")
  }
}

/** A choice in Properties, by how Blender draws it: things to do as a menu; a preview grid; the
 * viewport shading's modes as the system's segments; Blender's options side by side, joined while
 * their names fit, else a column of them; otherwise Blender's dropdown in the widget column. */
struct BlenderChoiceRow: View {
  let model: PanelsModel
  let node: NativeNode

  private var options: [Blender_NativeUI_Option] { node.choice?.allOptions.filter { $0.value != nil } ?? [] }

  var body: some View {
    let choice = node.choice
    if choice?.style == .actions || (model.mode == .shading && node.node.property == "type") ||
      options.contains(where: { !($0.preview ?? "").isEmpty })
    {
      NativeChoice(model: model, node: node)
    }
    else if choice?.style == .expanded && options.count >= 2 {
      BlenderPropertySplit(name: node.label) { BlenderExpandedChoice(model: model, node: node) }
    }
    else {
      BlenderPropertySplit(name: node.label) { BlenderChoiceWidget(model: model, node: node, fills: true) }
    }
  }
}

/** A choice Blender draws expanded: its options as joined toggle buttons on one line while their
 * names fit, else Blender's own fallback, a column of them. No name is cut. */
struct BlenderExpandedChoice: View {
  let model: PanelsModel
  let node: NativeNode

  private var options: [Blender_NativeUI_Option] { node.choice?.allOptions.filter { $0.value != nil } ?? [] }

  private func isChecked(_ option: Blender_NativeUI_Option) -> Bool {
    guard !model.isMixed(node), let value = option.value else { return false }
    let current = model.text(node)
    if node.choice?.multiple == true { return current.split(separator: ",").contains { $0 == value } }
    return value == current
  }

  var body: some View {
    let icons = options.allSatisfy { BlenderIcon.image($0.icon) != nil }
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 1) { buttons(icons: icons, vertical: false) }
        .fixedSize(horizontal: true, vertical: false)
      VStack(spacing: 1) { buttons(icons: icons, vertical: true) }
    }
    .disabled(!node.enabled)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(node.label)
  }

  @ViewBuilder
  private func buttons(icons: Bool, vertical: Bool) -> some View {
    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
      BlenderToggleButton(name: option.label ?? "", icon: icons ? BlenderIcon.image(option.icon) : nil,
                          text: icons ? nil : option.label, isOn: isChecked(option),
                          join: widgetJoin(index, options.count), vertical: vertical, fills: vertical) {
        model.set(node, .text(option.value ?? ""))
        Haptics.selection()
      }
    }
  }
}

/** A switch, which also runs a button Blender draws as a checkbox. */
struct NativeSwitch: View {
  let model: PanelsModel
  let node: NativeNode

  var body: some View {
    /* Read here, so the switch follows the value it shows. */
    let on = model.bool(node)
    let mixed = model.isMixed(node)
    HStack(spacing: 8) {
      if mixed {
        /* Switches have no mixed state: off, with the dash the other controls show. */
        Text("—").foregroundStyle(.secondary).accessibilityHidden(true)
      }
      Toggle(node.label, isOn: Binding(
        get: { on && !mixed },
        set: { model.set(node, .bool($0)) }))
        .labelsHidden()
        .tint(nativeAnimationColor(node.node.animation) ?? Color(uiColor: .systemGreen))
        .disabled(!node.enabled)
        .accessibilityValue(mixed ? "Mixed" : "")
    }
  }
}

struct NativeButton: View {
  let model: PanelsModel
  let node: NativeNode
  var join = WidgetJoin.alone

  var body: some View {
    let button = node.content(Blender_NativeUI_Button.self)
    /* Its icon alone where Blender shows only that, its label still read out. */
    let iconOnly = button?.iconOnly == true && BlenderIcon.image(node.icon) != nil
    let destructive = button?.style == .destructive
    Button(role: destructive ? .destructive : nil) {
      model.send(node, .invoke)
    } label: {
      BlenderWidgetFace(icon: BlenderIcon.image(node.icon), text: iconOnly ? nil : node.label, on: false, join: join,
                        fills: !iconOnly)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(node.label)
    .help(node.label)
    .disabled(!node.enabled)
    .opacity(node.enabled ? 1 : 0.5)
  }
}

/** Buttons Blender draws side by side, such as a material slot's Assign, Select and Deselect:
 * joined on one line while their names fit, else stacked. */
struct NativeButtonRow: View {
  let model: PanelsModel
  let buttons: [NativeNode]

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 1) {
        ForEach(Array(buttons.enumerated()), id: \.element.id) { index, node in
          NativeButton(model: model, node: node, join: widgetJoin(index, buttons.count))
        }
      }
      VStack(spacing: 4) {
        ForEach(buttons) { NativeButton(model: model, node: $0) }
      }
    }
  }
}

/** A header's button, such as a modifier's Remove: a compact icon beside the header switches. */
struct HeaderButton: View {
  let model: PanelsModel
  let node: NativeNode

  var body: some View {
    Button {
      model.send(node, .invoke)
    } label: {
      if let symbol = BlenderIcon.symbol(node.icon) {
        Image(systemName: symbol)
          .font(.system(size: 15, weight: .semibold))
          .frame(width: 36, height: 36)
      }
      else if let image = BlenderIcon.image(node.icon) {
        /* At the icon's own size, as a plain button draws it. */
        Image(uiImage: image)
          .frame(width: 36, height: 36)
      }
      else {
        Text(node.label)
      }
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .disabled(!node.enabled)
    .accessibilityLabel(node.label)
    .help(node.label)
  }
}

/** A button opening one of Blender's menus. */
struct NativeMenuButton: View {
  let model: PanelsModel
  let node: NativeNode

  var body: some View {
    /* Blender's menu button, such as a node socket's link: a dropdown the row's width. */
    let route = BlenderMenus.route(menuName(node), tab: model.currentTab)
    Menu {
      BlenderMenuItems(route: route)
    } label: {
      BlenderWidgetFace(icon: BlenderIcon.image(node.icon), text: node.label, arrow: true, fills: true)
    }
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .disabled(!node.enabled)
    .prefetchingBlenderMenu(route)
    .accessibilityLabel(node.label)
  }
}

struct NativeTextField: View {
  let model: PanelsModel
  let node: NativeNode
  @State private var text = ""
  @FocusState private var focused: Bool

  @AppStorage(ShellStyle.key) private var style = ShellStyle.blender.rawValue

  var body: some View {
    /* Blender's text widget (`wcol_text`): dark inside, its outline, the text leading. */
    let glass = style == ShellStyle.glass.rawValue
    let shape = WidgetShape(join: .alone, glass: glass)
    TextField(node.label, text: $text, prompt: model.isMixed(node) ? Text("—") : nil)
      .font(.subheadline)
      .multilineTextAlignment(.leading)
      .autocorrectionDisabled()
      .focused($focused)
      .selectsAllOnFocus(focused)
      .liftsAboveKeyboard(focused)
      .submitLabel(.done)
      .padding(.horizontal, 8)
      .frame(minHeight: 32)
      .background(glass ? Color.primary.opacity(focused ? 0.18 : 0.08) : BlenderWidgetColors.textInner, in: shape)
      .overlay { if !glass { shape.strokeBorder(BlenderWidgetColors.outline, lineWidth: 1) } }
      .disabled(!node.enabled)
      .onAppear { text = shown }
      .onChange(of: shown) { _, newValue in
        if !focused { text = newValue }
      }
      .onSubmit { commit() }
      .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
  }

  /** Empty with a dash where the selected items' texts differ. */
  private var shown: String { model.isMixed(node) ? "" : model.text(node) }

  private func commit() {
    if text != shown { model.set(node, .text(text)) }
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Colors
 * \{ */

/** A color ramp: its colors in a bar, its stops as handles below. A tap on a stop makes it the
 * active one, whose position and color are the controls after it; dragged sideways it moves,
 * pulled well off the bar it goes. A tap on the bar adds a stop there. */
struct NativeRamp: View {
  let model: PanelsModel
  let node: NativeNode
  /** A stop being dragged: the stops as the drag began, the one dragged, where it is now, and
   * whether it is pulled off to remove it. */
  @State private var drag: (stops: [Stop], index: Int, position: Double, off: Bool, last: CFTimeInterval)?

  struct Stop {
    var position: Double
    var color: Color
    var opaque: Bool
  }

  private static let bar: CGFloat = 24
  private static let handle = CGSize(width: 14, height: 18)
  private static let inset: CGFloat = 8

  private var ramp: Blender_NativeUI_Ramp? { node.content(Blender_NativeUI_Ramp.self) }
  private var active: Int { Int(ramp?.active ?? 0) }

  private static func color(_ value: (Int) -> Double, _ at: Int) -> (Color, Bool) {
    let alpha = value(at + 3)
    return (Color(.sRGB, red: value(at), green: value(at + 1), blue: value(at + 2), opacity: alpha), alpha > 0.999)
  }

  private var stops: [Stop] {
    guard let ramp else { return [] }
    var stops = (0..<ramp.stopsCount / 5).map { i -> Stop in
      let (color, opaque) = Self.color({ ramp.stops(at: Int32($0)) }, Int(i) * 5 + 1)
      return Stop(position: ramp.stops(at: i * 5), color: color, opaque: opaque)
    }
    /* Where it was let go, until Blender shows it there. */
    if case .float(let position)? = model.pending(node), stops.indices.contains(active) {
      stops[active].position = position
    }
    return stops
  }

  var body: some View {
    let stops = drag.map(dragged) ?? self.stops
    GeometryReader { proxy in
      let width = max(1, proxy.size.width - 2 * Self.inset)
      ZStack(alignment: .topLeading) {
        bar(stops)
          .frame(width: width, height: Self.bar)
          .offset(x: Self.inset)
          .contentShape(Rectangle())
          .onTapGesture { location in
            guard node.enabled else { return }
            model.send(node, .add, .float(min(1, max(0, location.x / width))))
          }
        ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
          handle(stop, active: drag?.index ?? active == index)
            .opacity(drag?.index == index && drag?.off == true ? 0.3 : 1)
            .position(x: Self.inset + width * stop.position, y: Self.bar + Self.handle.height / 2 + 2)
            .gesture(move(index, width: width))
        }
      }
    }
    .frame(height: Self.bar + Self.handle.height + 4)
    .opacity(node.enabled ? 1 : 0.5)
    .accessibilityElement()
    .accessibilityLabel(node.label)
    .accessibilityValue(stops.indices.contains(active) ? "Stop \(active + 1) of \(stops.count) at \(Int(stops[active].position * 100)) percent" : "")
    .accessibilityAdjustableAction { direction in
      guard stops.indices.contains(active) else { return }
      let step = direction == .increment ? 0.05 : -0.05
      model.set(node, .float(min(1, max(0, stops[active].position + step))))
    }
  }

  /** As the drag shows it: the stop dragged where it is now, or gone when pulled off. */
  private func dragged(_ drag: (stops: [Stop], index: Int, position: Double, off: Bool, last: CFTimeInterval)) -> [Stop] {
    var stops = drag.stops
    if stops.indices.contains(drag.index) { stops[drag.index].position = drag.position }
    return stops
  }

  /** Blender's colors; while a stop is dragged, the stops blended straight, as Blender shows them
   * a moment later. */
  private func bar(_ stops: [Stop]) -> some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    var gradient: [Gradient.Stop] = []
    var opaque = true
    if let drag {
      for (index, stop) in dragged(drag).enumerated() where !(index == drag.index && drag.off) {
        gradient.append(.init(color: stop.color, location: stop.position))
        opaque = opaque && stop.opaque
      }
      gradient.sort { $0.location < $1.location }
    }
    else if let ramp {
      let count = Int(ramp.colorsCount / 4)
      for i in 0..<count {
        let (color, solid) = Self.color({ ramp.colors(at: Int32($0)) }, i * 4)
        gradient.append(.init(color: color, location: Double(i) / Double(max(1, count - 1))))
        opaque = opaque && solid
      }
    }
    return shape
      .fill(LinearGradient(stops: gradient, startPoint: .leading, endPoint: .trailing))
      .background {
        /* What shows through where it is transparent. */
        if !opaque {
          Canvas { context, size in
            let cell: CGFloat = 6
            for row in 0..<Int(ceil(size.height / cell)) {
              for column in stride(from: row % 2, to: Int(ceil(size.width / cell)), by: 2) {
                context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                             with: .color(.gray.opacity(0.35)))
              }
            }
          }
          .clipShape(shape)
        }
      }
      .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
  }

  private func handle(_ stop: Stop, active: Bool) -> some View {
    let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
    return shape
      .fill(stop.color)
      .overlay(shape.strokeBorder(active ? Color.accentColor : .white, lineWidth: active ? 2.5 : 1.5))
      .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
      .frame(width: Self.handle.width, height: Self.handle.height)
      .contentShape(.interaction, Rectangle().inset(by: -10))
      .hoverEffect(.lift)
  }

  /** A tap makes the stop active; a drag moves it, as one step to undo, or removes it. */
  private func move(_ index: Int, width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        guard node.enabled else { return }
        if drag == nil {
          if index != active { model.send(node, .activate, .int(Int64(index))) }
          let stops = self.stops
          guard stops.indices.contains(index) else { return }
          drag = (stops, index, stops[index].position, false, 0)
        }
        guard var current = drag else { return }
        let moved = abs(value.translation.width) >= 4 || abs(value.translation.height) >= 4
        guard moved else { return }
        current.position = min(1, max(0, current.stops[index].position + value.translation.width / width))
        current.off = current.stops.count > 1 && abs(value.translation.height) > 40
        if !current.off, CACurrentMediaTime() - current.last >= 1.0 / 60.0 {
          model.send(node, .set_, .float(current.position), phase: current.last == 0 ? .begin : .update)
          current.last = CACurrentMediaTime()
        }
        drag = current
      }
      .onEnded { _ in
        guard let current = drag else { return }
        drag = nil
        if current.off {
          if current.last != 0 { model.send(node, .set_, .float(current.stops[index].position), phase: .cancel) }
          model.send(node, .remove)
        }
        else if current.last != 0 {
          model.set(node, .float(current.position), phase: .end)
        }
      }
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Choices
 * \{ */

struct NativeChoice: View {
  let model: PanelsModel
  let node: NativeNode
  var compact = false

  private var choice: Blender_NativeUI_Choice? { node.choice }
  private var options: [Blender_NativeUI_Option] { choice?.allOptions.filter { $0.value != nil } ?? [] }
  private var label: String { node.shortLabel }
  private var mixed: Bool { model.isMixed(node) }

  private func isChecked(_ option: Blender_NativeUI_Option) -> Bool {
    guard !mixed, let value = option.value else { return false }
    let current = model.text(node)
    if choice?.multiple == true { return current.split(separator: ",").contains { $0 == value } }
    return value == current
  }

  private var current: Blender_NativeUI_Option? { options.first(where: isChecked) }

  var body: some View {
    if choice?.style == .actions {
      ActionMenuRow(model: model, node: node)
    }
    else if model.mode == .shading && node.node.property == "type" {
      /* Read here, so the picker follows the value it shows. */
      let selection = model.text(node)
      Picker(label, selection: Binding(get: { selection }, set: { model.set(node, .text($0)) })) {
        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
          if let image = BlenderIcon.image(option.icon) {
            Image(uiImage: image).tag(option.value ?? "")
              .accessibilityLabel(option.label ?? "")
          }
          else {
            Text(option.label ?? "").tag(option.value ?? "")
          }
        }
      }
      .pickerStyle(.segmented)
      /* As tall as UIKit makes it under the form's 40 point control minimum. */
      .controlSize(.large)
      .disabled(!node.enabled)
    }
    else if options.contains(where: { !($0.preview ?? "").isEmpty }) {
      PreviewChoiceButton(model: model, node: node, compact: compact)
    }
    else if compact && choice?.style == .expanded && (2...6).contains(options.count) && segmentsFit {
      /* Choices Blender draws as a row, in a list's row: one tap each. */
      segmented.controlSize(.mini)
    }
    else if compact {
      /* A glass button showing the current choice's icon, with the choices in a menu. */
      Menu {
        Picker(label, selection: chosen) { choices }
          .pickerStyle(.inline)
      } label: {
        if let icon = BlenderIcon.image(current?.icon) {
          Image(uiImage: icon).resizable().scaledToFit().frame(width: 20, height: 20)
        }
        else {
          Text(mixed ? "—" : current?.label ?? "—").font(.caption).lineLimit(1)
        }
      }
      .frame(minWidth: 40, minHeight: 26)
      .padding(.horizontal, 6)
      .panelGlass(in: Capsule())
      .disabled(!node.enabled)
      .accessibilityLabel(label)
    }
    else {
      /* A row of Properties: Blender's widgets. */
      BlenderChoiceRow(model: model, node: node)
    }
  }

  /** The choice by its position. */
  private var chosen: Binding<Int> {
    Binding(get: { options.firstIndex(where: isChecked) ?? -1 }, set: { index in
      if options.indices.contains(index) { model.set(node, .text(options[index].value ?? "")) }
    })
  }

  private var choices: some View {
    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
      Label {
        Text(option.label ?? "")
      } icon: {
        if let image = BlenderIcon.image(option.icon) { Image(uiImage: image) }
      }
      .tag(index)
    }
  }

  /** Whether a row of choices fits a narrow strip: as icons, or as short names. Longer ones,
   * such as Material and Color Attribute, are a menu there instead. */
  private var segmentsFit: Bool {
    options.allSatisfy { BlenderIcon.image($0.icon) != nil } || options.allSatisfy { ($0.label ?? "").count <= 5 }
  }

  private var segmented: some View {
    /* Icons only when every choice has one, so none is left as a blank segment. */
    let icons = options.allSatisfy { BlenderIcon.image($0.icon) != nil }
    let segments = options.map { option in
      SegmentedControl.Segment(value: option.value ?? "", title: option.label ?? "",
                               image: icons ? BlenderIcon.image(option.icon) : nil)
    }
    return SegmentedControl(segments: segments, selection: current?.value ?? "",
                            enabled: node.enabled, accessibilityLabel: label) {
      model.set(node, .text($0))
    }
  }
}

/** Choices Blender shows as a large preview (template_icon_view), not a list of names. */
struct PreviewChoiceButton: View {
  let model: PanelsModel
  let node: NativeNode
  /** Small, for the tool settings strip. */
  var compact = false
  @State private var showing = false

  var body: some View {
    let options = node.choice?.allOptions.filter { $0.value != nil } ?? []
    let value = model.text(node)
    let current = options.first { $0.value == value }
    let name = current?.label ?? value
    Button {
      showing = true
    } label: {
      /* The current choice's preview and name, as a plain button. */
      if compact {
        HStack(spacing: 6) {
          PreviewThumbnail(path: current?.preview, size: 20, cornerRadius: 5)
          Text(name).font(.caption).lineLimit(1).truncationMode(.middle).foregroundStyle(.primary)
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .frame(minHeight: 26)
        .panelGlass(in: Capsule())
        .contentShape(Capsule())
      }
      else {
        HStack(spacing: 12) {
          PreviewThumbnail(path: current?.preview, size: 56, cornerRadius: 8)
          Text(name)
            .foregroundStyle(.primary)
          Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .frame(minHeight: 64)
        .contentShape(Rectangle())
      }
    }
    .buttonStyle(.plain)
    .disabled(!node.enabled)
    .accessibilityLabel(node.label)
    .accessibilityValue(current?.label ?? "")
    .accessibilityHint("Shows all choices as previews.")
    .popover(isPresented: $showing) {
      PreviewGrid(title: node.label, options: options, value: value) { option in
        model.set(node, .text(option))
        showing = false
      }
      .frame(minWidth: 400, minHeight: 440)
    }
  }
}

/** Things to do as a menu with Blender's groups, such as Add Object Constraint. */
struct ActionMenuRow: View {
  let model: PanelsModel
  let node: NativeNode

  var body: some View {
    Menu {
      ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
        Section(group.heading) {
          ForEach(Array(group.options.enumerated()), id: \.offset) { _, option in
            Button {
              model.send(node, .set_, .text(option.value ?? ""))
            } label: {
              Label {
                Text(option.label ?? "")
              } icon: {
                if let image = BlenderIcon.image(option.icon) { Image(uiImage: image) }
              }
            }
          }
        }
      }
    } label: {
      BlenderWidgetFace(icon: BlenderIcon.image(node.icon) ?? UIImage(systemName: "plus"), text: node.label,
                        arrow: true, fills: true)
    }
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .disabled(!node.enabled)
  }

  /** Options under their headings: a heading is an option with no value. */
  private var groups: [(heading: String, options: [Blender_NativeUI_Option])] {
    var result: [(heading: String, options: [Blender_NativeUI_Option])] = []
    var heading = ""
    var items: [Blender_NativeUI_Option] = []
    for option in node.choice?.allOptions ?? [] {
      if option.value == nil {
        if !items.isEmpty { result.append((heading, items)) }
        heading = option.label ?? ""
        items = []
        continue
      }
      items.append(option)
    }
    if !items.isEmpty { result.append((heading, items)) }
    return result
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Groups
 * \{ */

/** \} */

/* -------------------------------------------------------------------- */
/** \name Shared
 * \{ */

/** A label beside a control given a fraction of the row's width, as Blender's split rows. */
struct FractionRow: Layout {
  var fraction: CGFloat
  var spacing: CGFloat = 10
  /** Where the two sit against each other: centred, or along their tops. */
  var aligned = VerticalAlignment.center

  private func widths(_ width: CGFloat) -> (lead: CGFloat, control: CGFloat) {
    let control = (width * fraction).rounded()
    return (max(0, width - control - spacing), control)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard subviews.count == 2 else { return .zero }
    let width = proposal.width ?? 320
    let (lead, control) = widths(width)
    let height = max(subviews[0].sizeThatFits(ProposedViewSize(width: lead, height: proposal.height)).height,
                     subviews[1].sizeThatFits(ProposedViewSize(width: control, height: proposal.height)).height)
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard subviews.count == 2 else { return }
    let (lead, control) = widths(bounds.width)
    if aligned == .top {
      subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                        proposal: ProposedViewSize(width: lead, height: nil))
      subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing,
                        proposal: ProposedViewSize(width: control, height: nil))
      return
    }
    subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                      proposal: ProposedViewSize(width: lead, height: bounds.height))
    subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                      proposal: ProposedViewSize(width: control, height: nil))
  }
}

struct PreviewThumbnail: View {
  var path: String?
  var fallback: UIImage? = nil
  var size: CGFloat
  var cornerRadius: CGFloat? = nil

  var body: some View {
    Group {
      if let image = PreviewCache.image(path) {
        Image(uiImage: image).resizable().scaledToFill()
      }
      else {
        ZStack {
          PanelStyle.thumbnail
          if let fallback {
            Image(uiImage: fallback)
              .resizable()
              .scaledToFit()
              .padding(size * 0.26)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.22, style: .continuous))
  }
}

/** A choice's options as a grid of their previews, such as MatCaps. */
struct PreviewGrid: View {
  let title: String
  let options: [Blender_NativeUI_Option]
  let value: String
  let choose: (String) -> Void

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
          ForEach(Array(options.enumerated()), id: \.offset) { _, option in
            let current = option.value == value
            Button {
              choose(option.value ?? "")
            } label: {
              VStack(spacing: 4) {
                PreviewThumbnail(path: option.preview, size: 80)
                Text(option.label ?? "")
                  .font(.caption2)
                  .lineLimit(2)
                  .truncationMode(.middle)
                  .foregroundStyle(current ? PanelStyle.tint : .secondary)
              }
              .padding(4)
              .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(current ? Color.accentColor : .clear, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(option.label ?? "")
            .accessibilityAddTraits(current ? .isSelected : [])
          }
        }
        .padding(16)
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
    }
  }
}

/** A name prompt shared by data-blocks and list items. */
struct RenameRequest: Identifiable {
  let id = UUID()
  let title: String
  let name: String
  let commit: (String) -> Void
}

struct RenamePrompt: ViewModifier {
  @Binding var request: RenameRequest?
  @State private var text = ""

  func body(content: Content) -> some View {
    content.alert(request?.title ?? "Rename", isPresented: Binding(
      get: { request != nil }, set: { if !$0 { request = nil } }))
    {
      TextField("Name", text: $text)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
      Button("Cancel", role: .cancel) { request = nil }
      Button("Rename") {
        let name = text.trimmingCharacters(in: .whitespaces)
        if let request, !name.isEmpty, name != request.name { request.commit(name) }
        request = nil
      }
      .keyboardShortcut(.defaultAction)
    }
    .onChange(of: request?.id) { _, _ in text = request?.name ?? "" }
  }
}

extension View {
  func renamePrompt(_ request: Binding<RenameRequest?>) -> some View {
    modifier(RenamePrompt(request: request))
  }
}

/** \} */
