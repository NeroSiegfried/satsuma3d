/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Pieces the interface shares that reach into UIKit: number scrubbing, which must arbitrate with
 * scrolling; the color picker, which needs explicit begin and end for one undo step per drag;
 * anchors for presenting UIKit controllers; haptics; and the glass, which visionOS draws its own
 * way.
 */

import SwiftUI
import UIKit

/* -------------------------------------------------------------------- */
/** \name Number scrubbing
 * \{ */

#if os(visionOS)
/** visionOS: a pinch and drag sideways. Only one value scrubs at a time. */
@MainActor
private final class ScrubTracker {
  static let shared = ScrubTracker()
  var active = false
}

struct ScrubGesture: Gesture {
  var enabled: Bool
  var anchor: AnchorBox? = nil
  var began: () -> Void
  var changed: (_ translation: CGPoint) -> Void
  var ended: (_ cancelled: Bool) -> Void

  var body: some Gesture {
    DragGesture(minimumDistance: 8, coordinateSpace: .global)
      .onChanged { value in
        let tracker = ScrubTracker.shared
        let translation = CGPoint(x: value.translation.width, y: value.translation.height)
        if !tracker.active {
          guard enabled, abs(translation.x) > abs(translation.y) * 1.2 else { return }
          tracker.active = true
          began()
        }
        changed(translation)
        if let view = anchor?.view { ScrubIndicator.shared.show(above: view, vertical: translation.y) }
      }
      .onEnded { value in
        let tracker = ScrubTracker.shared
        guard tracker.active else { return }
        tracker.active = false
        changed(CGPoint(x: value.translation.width, y: value.translation.height))
        ended(false)
        ScrubIndicator.shared.hide(for: anchor?.view)
      }
  }
}
#else
/** A horizontal drag that only begins when mostly sideways, so vertical drags still scroll. */
struct ScrubGesture: UIGestureRecognizerRepresentable {
  var enabled: Bool
  /** The field, which the sensitivity indicator floats above while scrubbing. */
  var anchor: AnchorBox? = nil
  var began: () -> Void
  var changed: (_ translation: CGPoint) -> Void
  var ended: (_ cancelled: Bool) -> Void

  func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
    let pan = UIPanGestureRecognizer()
    pan.maximumNumberOfTouches = 1
    pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                             NSNumber(value: UITouch.TouchType.pencil.rawValue),
                             NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
    pan.delegate = context.coordinator
    return pan
  }

  func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

  func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
    context.coordinator.enabled = enabled
  }

  func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
    let translation = recognizer.translation(in: recognizer.view?.window)
    switch recognizer.state {
      case .began:
        began()
        if let view = anchor?.view { ScrubIndicator.shared.show(above: view, vertical: 0) }
      case .changed:
        changed(translation)
        if let view = anchor?.view { ScrubIndicator.shared.show(above: view, vertical: translation.y) }
      case .ended:
        changed(translation)
        ended(false)
        ScrubIndicator.shared.hide(for: anchor?.view)
      case .cancelled, .failed:
        ended(true)
        ScrubIndicator.shared.hide(for: anchor?.view)
      default: break
    }
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var enabled = true

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
      guard enabled, let pan = recognizer as? UIPanGestureRecognizer else { return false }
      let velocity = pan.velocity(in: pan.view)
      return abs(velocity.x) > abs(velocity.y) * 1.2
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
      /* The surrounding scroll view waits for a sideways drag to fail. */
      other.view is UIScrollView
    }
  }
}

#endif

/** Drag sensitivity: dragging further up or down while scrubbing makes changes coarser or finer. */
func scrubSensitivity(_ vertical: Double) -> Double {
  exp2(min(4.0, max(-4.0, -vertical / 80.0)))
}

@MainActor
final class ScrubIndicatorModel: ObservableObject {
  @Published var vertical = 0.0
  @Published var tint = Color.accentColor
}

struct ScrubIndicatorContent: View {
  @ObservedObject var model: ScrubIndicatorModel

  var body: some View {
    /* Same mapping as `scrubSensitivity`: up is faster, down is finer. */
    let octaves = min(4.0, max(-4.0, -model.vertical / 80.0))
    let factor = exp2(octaves)
    let normal = abs(octaves) < 0.15
    HStack(spacing: 8) {
      Image(systemName: "arrow.up.and.down")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
      Group {
        if abs(model.vertical) < 6 {
          Text("Up faster · Down finer")
        }
        else {
          Text((factor >= 1 ? String(format: "×%.3g", factor) : String(format: "×%.2g", factor)) + " " +
               (normal ? "Normal" : octaves > 0 ? "Faster" : "Finer"))
        }
      }
      .font(.system(size: 13, weight: .medium).monospacedDigit())
      .foregroundStyle(.primary)
      /* A small gauge: the dot rises as dragging gets coarser. */
      ZStack {
        Capsule().fill(Color(uiColor: .tertiarySystemFill)).frame(width: 4, height: 24)
        Rectangle().fill(Color(uiColor: .tertiaryLabel)).frame(width: 8, height: 1)
        Circle().fill(normal ? Color.secondary : model.tint).frame(width: 8, height: 8)
          .offset(y: -octaves / 4.0 * (24 - 8) / 2)
      }
      .frame(width: 8, height: 24)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .fixedSize()
  }
}

/** A floating glass pill above a field while it is scrubbed. It tells the user that vertical
 * movement changes the drag speed, then shows the current multiplier on a small gauge. */
@MainActor
final class ScrubIndicator {
  static let shared = ScrubIndicator()

  private let model = ScrubIndicatorModel()
  private lazy var host = UIHostingController(rootView: ScrubIndicatorContent(model: model))
  private lazy var pill: UIVisualEffectView = {
    let pill = UIVisualEffectView(effect: makePanelGlass())
    pill.isUserInteractionEnabled = false
    pill.clipsToBounds = true
    pill.layer.cornerCurve = .continuous
    pill.accessibilityIdentifier = "blender.number.scrub-indicator"
    host.view.backgroundColor = .clear
    host.sizingOptions = []
    host.safeAreaRegions = []
    pill.contentView.addSubview(host.view)
    return pill
  }()
  private weak var field: UIView?

  func show(above field: UIView, vertical: Double) {
    guard let window = field.window else {
      hide(for: self.field)
      return
    }
    model.vertical = vertical
    model.tint = Color(uiColor: field.tintColor)
    let appearing = self.field !== field || pill.superview !== window
    self.field = field
    if pill.superview !== window { window.addSubview(pill) }
    window.bringSubviewToFront(pill)
    var size = host.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    size.width = max(size.width, 120)
    pill.layer.cornerRadius = size.height / 2
    host.view.frame = CGRect(origin: .zero, size: size)
    /* Sit above the field, clear of the hand holding the Pencil; flip below near the top. */
    let anchor = field.convert(field.bounds, to: window)
    let safe = window.safeAreaInsets
    var y = anchor.minY - 10 - size.height
    if y < safe.top + 4 { y = anchor.maxY + 10 }
    var x = anchor.midX - size.width / 2
    x = max(safe.left + 8, min(x, window.bounds.width - safe.right - 8 - size.width))
    if appearing {
      pill.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
      pill.alpha = 0
      pill.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
      UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.18) {
        self.pill.alpha = 1
        self.pill.transform = .identity
      }
    }
    else {
      pill.bounds = CGRect(origin: .zero, size: size)
      pill.center = CGPoint(x: x + size.width / 2, y: y + size.height / 2)
    }
  }

  func hide(for field: UIView?) {
    guard let field, self.field === field else { return }
    self.field = nil
    UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.15) {
      self.pill.alpha = 0
    } completion: { _ in
      if self.field == nil { self.pill.removeFromSuperview() }
    }
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Segmented control
 * \{ */

/**
 * The system's segmented control, for choices Blender draws as a row. It moves its Liquid Glass
 * selection over at once when tapped; Blender's value only arrives a moment later, so the control
 * keeps the choice it made until Blender shows it, instead of jumping back meanwhile.
 */
struct SegmentedControl: View {
  struct Segment: Equatable {
    var value: String
    var title: String
    var image: UIImage?
  }

  var segments: [Segment]
  var selection: String
  var enabled = true
  var accessibilityLabel: String? = nil
  var choose: (String) -> Void

  /** The value chosen here that Blender does not show yet, and until when to wait for it. */
  @State private var pending: String?
  @State private var pendingUntil = Date.distantPast

  private var shown: String {
    if let pending, pending != selection, Date() < pendingUntil { return pending }
    return selection
  }

  var body: some View {
    Picker(accessibilityLabel ?? "", selection: Binding(get: { shown }, set: { value in
      pending = value
      pendingUntil = Date().addingTimeInterval(1.0)
      choose(value)
    })) {
      ForEach(segments, id: \.value) { segment in
        Group {
          if let image = segment.image {
            /* At a symbol's size, as Blender's icons are larger artwork. */
            Image(uiImage: image)
              .renderingMode(image.renderingMode == .alwaysOriginal ? .original : .template)
              .resizable()
              .scaledToFit()
              .frame(width: 18, height: 18)
              .accessibilityLabel(segment.title)
          }
          else {
            Text(segment.title)
          }
        }
        .tag(segment.value)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .disabled(!enabled)
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Presenting UIKit controllers
 * \{ */

/** Captures the UIKit view a SwiftUI control sits in, to anchor popovers on it. */
struct PresentationAnchor: UIViewRepresentable {
  let anchor: AnchorBox

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.isUserInteractionEnabled = false
    view.backgroundColor = .clear
    anchor.view = view
    return view
  }

  func updateUIView(_ view: UIView, context: Context) { anchor.view = view }
}

final class AnchorBox {
  weak var view: UIView?
  /** Where to point from in window points, for SwiftUI drawn where no UIKit view can be, such
   * as under a shader effect. */
  var windowRect: CGRect?

  private var window: UIWindow? {
    view?.window ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
  }

  var presenter: UIViewController? {
    var presenter = window?.rootViewController
    while let next = presenter?.presentedViewController, !next.isBeingDismissed { presenter = next }
    return presenter
  }

  func present(_ controller: UIViewController, preferredSize: CGSize? = nil) {
    guard let presenter else { return }
    controller.modalPresentationStyle = .popover
    if let preferredSize { controller.preferredContentSize = preferredSize }
    if let view, view.window != nil {
      controller.popoverPresentationController?.sourceView = view
      controller.popoverPresentationController?.sourceRect = view.bounds
    }
    else if let window, let windowRect {
      controller.popoverPresentationController?.sourceView = window
      controller.popoverPresentationController?.sourceRect = windowRect
    }
    else {
      return
    }
    presenter.present(controller, animated: true)
  }
}

/** The system color picker for a color control, with Blender's interaction phases: continuous
 * changes are a drag's updates, and the picker closing or a discrete choice ends it, one undo step. */
@MainActor
final class ColorPickerSession: NSObject, UIColorPickerViewControllerDelegate,
  UIPopoverPresentationControllerDelegate, UIAdaptivePresentationControllerDelegate
{
  static var active: ColorPickerSession?

  let model: PanelsModel
  let node: NativeNode
  private let alpha: Bool
  private var dragging = false
  private var lastPreview: CFTimeInterval = 0
  private var pending: [Double]?
  private let picker = UIColorPickerViewController()

  init(model: PanelsModel, node: NativeNode) {
    self.model = model
    self.node = node
    alpha = node.content(Blender_NativeUI_Color.self)?.alpha ?? false
  }

  func present(from anchor: AnchorBox) {
    ColorPickerSession.active?.close()
    picker.title = node.label
    picker.supportsAlpha = alpha
    picker.selectedColor = blenderColor(model.floats(node).map { NSNumber(value: $0) })
    picker.delegate = self
    anchor.present(picker)
    picker.popoverPresentationController?.delegate = self
    picker.presentationController?.delegate = self
    ColorPickerSession.active = self
  }

  func colorPickerViewController(_ picker: UIColorPickerViewController, didSelect color: UIColor,
                                 continuously: Bool)
  {
    guard let components = colorComponents(color, alpha: alpha) else { return }
    pending = components
    if !continuously {
      commit()
      return
    }
    if CACurrentMediaTime() - lastPreview >= 1.0 / 60.0 {
      model.set(node, .floats(components), phase: dragging ? .update : .begin)
      dragging = true
      lastPreview = CACurrentMediaTime()
    }
  }

  private func commit() {
    guard let components = pending else { return }
    pending = nil
    model.set(node, .floats(components), phase: dragging ? .end : .once)
    dragging = false
  }

  func close() {
    commit()
    picker.delegate = nil
    picker.dismiss(animated: true)
    if ColorPickerSession.active === self { ColorPickerSession.active = nil }
  }

  func colorPickerViewControllerDidFinish(_ picker: UIColorPickerViewController) { close() }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    close()
  }
}

func blenderColor(_ value: Any?) -> UIColor {
  guard let components = value as? [NSNumber], components.count == 3 || components.count == 4 else {
    return .clear
  }
  var values = components.map { CGFloat($0.doubleValue) }
  if values.count == 3 { values.append(1) }
  guard let space = CGColorSpace(name: CGColorSpace.extendedSRGB),
        let color = CGColor(colorSpace: space, components: values)
  else { return .clear }
  return UIColor(cgColor: color)
}

func colorComponents(_ color: UIColor, alpha: Bool) -> [Double]? {
  guard let space = CGColorSpace(name: CGColorSpace.extendedSRGB),
        let converted = color.cgColor.converted(to: space, intent: .defaultIntent, options: nil),
        let values = converted.components, values.count == 4
  else { return nil }
  let result = values.map { Double($0) }
  return alpha ? result : Array(result.prefix(3))
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Haptics
 * \{ */

/** Haptics where the device has them; Apple Vision Pro has none. */
#if os(visionOS)
/* No haptics on Apple Vision Pro: the iPad's feedback generators, which the shared views use,
 * do nothing there. */
final class UIImpactFeedbackGenerator {
  enum FeedbackStyle { case light, medium, heavy, soft, rigid }
  init(style: FeedbackStyle = .medium) {}
  func prepare() {}
  func impactOccurred() {}
  func impactOccurred(intensity: CGFloat) {}
}

final class UISelectionFeedbackGenerator {
  func prepare() {}
  func selectionChanged() {}
}

final class UICanvasFeedbackGenerator {
  init(view: UIView) {}
  func alignmentOccurred(at point: CGPoint) {}
  func pathCompleted(at point: CGPoint) {}
}
#endif

enum Haptics {
  enum Impact { case light, medium }

  static func selection() {
#if !os(visionOS)
    UISelectionFeedbackGenerator().selectionChanged()
#endif
  }

  static func impact(_ style: Impact = .light) {
#if !os(visionOS)
    UIImpactFeedbackGenerator(style: style == .medium ? .medium : .light).impactOccurred()
#endif
  }

  static func success() {
#if !os(visionOS)
    UINotificationFeedbackGenerator().notificationOccurred(.success)
#endif
  }

  /** Something could not be done. */
  static func error() {
#if !os(visionOS)
    UINotificationFeedbackGenerator().notificationOccurred(.error)
#endif
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Glass
 *
 * Liquid Glass on iOS. visionOS windows are glass already: panels there use the system's glass
 * material, without tints.
 * \{ */

/** How the shell draws its panels: as Blender's own, the default, so it looks as Blender does on the
 * desktop, or as the iPad's Liquid Glass. Settings chooses. */
enum ShellStyle: String {
  case blender, glass

  static let key = "BlenderInterfaceStyle"

  static var current: ShellStyle {
    ShellStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .blender
  }

  /** Blender's default theme: the regions' and panels' backgrounds, their outline, the selection
   * and the tooltips. */
  static let region = Color(red: 0x30 / 255, green: 0x30 / 255, blue: 0x30 / 255)
  static let panel = Color(red: 0x3d / 255, green: 0x3d / 255, blue: 0x3d / 255)
  /** The Properties editor's tab column (its navigation bar, drawn with the sidebars'
   * `tab_back`, `resources.cc`), darker than the editor so the active tab joins the content. */
  static let navigationBar = Color(red: 0x18 / 255, green: 0x18 / 255, blue: 0x18 / 255)
  static let outline = Color(red: 0x24 / 255, green: 0x24 / 255, blue: 0x24 / 255)
  static let selection = Color(red: 0x47 / 255, green: 0x72 / 255, blue: 0xb3 / 255)
  static let tooltip = Color(red: 0x19 / 255, green: 0x19 / 255, blue: 0x19 / 255)
  static let text = Color(red: 0xe6 / 255, green: 0xe6 / 255, blue: 0xe6 / 255)
  /** A checkbox's or field's inside while off. */
  static let widget = Color(red: 0x54 / 255, green: 0x54 / 255, blue: 0x54 / 255)
  /** Blender rounds its regions and widgets a little, not into capsules. */
  static let radius: CGFloat = 6
}

/** A container's outline in the chosen style: the glass's capsule or large rounding, or Blender's
 * small rounding. Read as it draws, so views observing the style redraw it. */
struct ShellShape: Shape {
  /** The glass style's corner radius; none for a capsule. */
  var glassRadius: CGFloat?

  func path(in rect: CGRect) -> Path {
    if ShellStyle.current == .glass {
      if let glassRadius { return RoundedRectangle(cornerRadius: glassRadius, style: .continuous).path(in: rect) }
      return Capsule().path(in: rect)
    }
    return RoundedRectangle(cornerRadius: ShellStyle.radius, style: .continuous).path(in: rect)
  }
}

/** Blender's checkbox beside its name, as its headers and panels draw a setting that is on or off:
 * padded so it never meets the edge of what holds it. */
struct BlenderCheckboxStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button { configuration.isOn.toggle() } label: {
      HStack(spacing: 6) {
        ZStack {
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(configuration.isOn ? ShellStyle.selection : ShellStyle.widget)
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .strokeBorder(ShellStyle.outline, lineWidth: 1)
          if configuration.isOn {
            Image(systemName: "checkmark")
              .font(.system(size: 10, weight: .bold))
              .foregroundStyle(.white)
          }
        }
        .frame(width: 16, height: 16)
        configuration.label
          .lineLimit(1)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(.isToggle)
    .accessibilityValue(configuration.isOn ? "On" : "Off")
  }
}

/** A popover's surface in the chosen style: Blender's region grey and light text, or the system's. */
private struct PopoverSurface: ViewModifier {
  @AppStorage(ShellStyle.key) private var style = ShellStyle.blender.rawValue

  func body(content: Content) -> some View {
    if style == ShellStyle.glass.rawValue {
      content
    }
    else {
      content
        .presentationBackground(ShellStyle.region)
        .environment(\.colorScheme, .dark)
    }
  }
}

extension View {
  /** On a popover's content, see #PopoverSurface. */
  func popoverSurface() -> some View { modifier(PopoverSurface()) }

  /** The document's top bar in the chosen style: in Blender's, its header, the theme's grey with
   * light items; the system's glass otherwise. */
  func headerSurface(_ style: String) -> some View {
    let blender = style != ShellStyle.glass.rawValue
#if os(visionOS)
    return self
#else
    return self
      .toolbarBackground(ShellStyle.region, for: .navigationBar)
      .toolbarBackgroundVisibility(blender ? .visible : .automatic, for: .navigationBar)
      .toolbarColorScheme(blender ? .dark : nil, for: .navigationBar)
#endif
  }
}

/* -------------------------------------------------------------------- */
/** \name The keyboard
 *
 * The bottom of the viewport holds the operation's settings, where the keyboard opens. While one
 * of their fields is typed into they rise above it, and come back down after. A floating or split
 * keyboard, or a hardware one with only its shortcut bar, covers nothing there: nothing moves.
 * \{ */

@MainActor
@Observable
final class KeyboardLift {
  static let shared = KeyboardLift()

  /** How much of the key window's bottom the docked keyboard covers, in points. */
  private(set) var overlap: CGFloat = 0
  /** A field of the bottom strip is being typed into. */
  var editingInStrip = false

  private init() {
    let center = NotificationCenter.default
    center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { note in
      let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
      MainActor.assumeIsolated { KeyboardLift.shared.update(frame) }
    }
    center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { KeyboardLift.shared.update(nil) }
    }
  }

  private func update(_ screenFrame: CGRect?) {
    var covered: CGFloat = 0
    if let screenFrame,
       let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
    {
      let screen = window.screen.bounds
      /* Docked: along the screen's bottom, its full width, taller than a shortcut bar. */
      let docked = screenFrame.maxY >= screen.maxY - 1 && screenFrame.width >= screen.width - 1 &&
        screenFrame.height > 120
      if docked {
        let frame = window.convert(screenFrame, from: window.screen.coordinateSpace)
        covered = max(0, window.bounds.maxY - frame.minY)
      }
    }
    if covered != overlap {
      withAnimation(.easeOut(duration: 0.25)) { overlap = covered }
    }
  }

  /** How far the strip rises: above the keyboard while its field is typed into. */
  var stripLift: CGFloat { editingInStrip ? overlap : 0 }
}

private struct InOperationStripKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /** Inside the bottom strip of operation settings, which rises above the keyboard. */
  var inOperationStrip: Bool {
    get { self[InOperationStripKey.self] }
    set { self[InOperationStripKey.self] = newValue }
  }
}

/** Tells the strip one of its fields is typed into, so it rises above the keyboard. */
private struct LiftsAboveKeyboard: ViewModifier {
  let focused: Bool
  @Environment(\.inOperationStrip) private var inStrip

  func body(content: Content) -> some View {
    content
      .onChange(of: focused) { _, focused in
        if inStrip { KeyboardLift.shared.editingInStrip = focused }
      }
      .onDisappear {
        if inStrip && focused { KeyboardLift.shared.editingInStrip = false }
      }
  }
}

extension View {
  /** On a field: while focused inside the operation strip, the strip rises above the keyboard. */
  func liftsAboveKeyboard(_ focused: Bool) -> some View { modifier(LiftsAboveKeyboard(focused: focused)) }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Layout checker
 *
 * The controls over the viewport are placed by different views; each new one has collided with
 * another. Each zone reports its frame here, and any two that overlap are written to the session's
 * log as `layout: <a> ∩ <b>`, at most once a minute each, so overlaps nobody has reported yet are
 * found; a development build also shows each as a message, once per launch. It moves nothing on
 * screen, and checks half a second after the frames settle.
 * \{ */

@MainActor
final class LayoutChecker {
  static let shared = LayoutChecker()

  private var frames: [String: CGRect] = [:]
  private var logged: [String: Date] = [:]
  private var scheduled = false
  /** The window's size, width class, header rung and style, written before each line so a line
   * can be reproduced. */
  var conditions = ""
  /** The window, in the coordinates zones report: a zone reaching more than a point outside it is
   * logged as `outside window`. Empty until the window says its size. */
  var bounds = CGRect.null {
    didSet {
      if bounds != oldValue {
        schedule()
        sendBottomBand()
      }
    }
  }
  /** The window is being resized: frames pass through each other for a moment, which is not an
   * overlap anyone sees. Checked once more when it ends. */
  var resizing = false {
    didSet { if !resizing && oldValue { schedule() } }
  }

  /** A development build (its identifier ends in `.dev`) also shows each problem as a message,
   * once per launch, so it is seen and not only logged (ROUND5 Stage 6B, decision 22). */
  private static let development = AppIdentity.isDevelopment
  private var shown = Set<String>()

  /** Log a layout problem: \a key names it (`item ∩ tools`, `item outside`), \a line is the log's. */
  func report(_ key: String, _ line: String) {
    WM_native_ui_log("layout", line)
    guard Self.development, shown.insert(key).inserted else { return }
    ShellModel.current?.messages.say("Layout problem: \(key) (logged)", level: "warning")
  }

  /** Log a layout problem found by a view itself, such as a panel whose rows need more width
   * than it has (ROUND5 7A): at most once a minute per \a key. */
  func overflow(_ key: String, _ line: String) {
    let now = Date()
    if let last = logged[key], now.timeIntervalSince(last) < 60 { return }
    logged[key] = now
    report(key, line)
  }

  func set(_ zone: String, _ frame: CGRect?) {
    let next = frame.flatMap { $0.width >= 1 && $0.height >= 1 ? $0 : nil }
    guard frames[zone] != next else { return }
    frames[zone] = next
    schedule()
    if Self.bottomZones.contains(zone) { sendBottomBand() }
  }

  /* -------------------------------------------------------------------- */
  /* The bottom controls' band (ROUND5 9G.5) */

  /** Zones that are controls along the window's bottom edge while they stand there: the Actions
   * button and bar, the last operation's strip, the tool button or the bottom rail. */
  private static let bottomZones: Set<String> = ["actions", "operation", "tools", "brushes"]
  /** Controls along the bottom that are not checked for overlaps, such as the keyboard's bar. */
  private var bottomOnly: [String: CGRect] = [:]
  private var sentBand: Float = -1

  func setBottomControl(_ zone: String, _ frame: CGRect?) {
    let next = frame.flatMap { $0.width >= 1 && $0.height >= 1 ? $0 : nil }
    guard bottomOnly[zone] != next else { return }
    bottomOnly[zone] = next
    sendBottomBand()
  }

  /** The top of the highest control standing along the window's bottom edge, in window pixels from
   * the bottom, from the same frames the layout checker reads: framing keeps what it frames above
   * it (`WM_native_ui_bottom_controls_set`). The navigation gizmo keeps to the tray, as before. */
  private func sendBottomBand() {
    guard !bounds.isNull, !bounds.isEmpty, let model = ShellModel.current else { return }
    /* Standing along the edge: reaching to within this of the safe area's bottom. */
    let reach = bounds.maxY - model.safeAreaInsets.bottom - 72
    var top = bounds.maxY
    for (zone, frame) in frames where Self.bottomZones.contains(zone) && frame.maxY >= reach {
      /* A rail standing along a side is not a bottom control, even where it reaches down. */
      if ["tools", "brushes"].contains(zone) && frame.width < frame.height * 0.8 { continue }
      top = min(top, frame.minY)
    }
    for frame in bottomOnly.values where frame.maxY >= reach {
      top = min(top, frame.minY)
    }
    let band = Float(max(0, (bounds.maxY - top) * model.pointScale).rounded())
    guard band != sentBand else { return }
    sentBand = band
    WM_native_ui_bottom_controls_set(band)
  }

  private func schedule() {
    guard !scheduled else { return }
    scheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      MainActor.assumeIsolated { self?.check() }
    }
  }

  private func check() {
    scheduled = false
    guard !resizing else { return }
    let zones = frames.keys.sorted()
    let now = Date()
    for (i, a) in zones.enumerated() {
      for b in zones[(i + 1)...] {
        guard let fa = frames[a], let fb = frames[b] else { continue }
        let overlap = fa.intersection(fb)
        guard !overlap.isNull, overlap.width > 1, overlap.height > 1 else { continue }
        let key = "\(a) ∩ \(b)"
        if let last = logged[key], now.timeIntervalSince(last) < 60 { continue }
        logged[key] = now
        report(key, "\(conditions) \(key) \(Int(overlap.width))x\(Int(overlap.height)) at \(Int(overlap.minX)),\(Int(overlap.minY))")
      }
    }
    guard !bounds.isNull, !bounds.isEmpty else { return }
    let window = bounds.insetBy(dx: -1, dy: -1)
    for zone in zones {
      guard let frame = frames[zone], !window.contains(frame) else { continue }
      let key = "\(zone) outside"
      if let last = logged[key], now.timeIntervalSince(last) < 60 { continue }
      logged[key] = now
      report(key, "\(conditions) \(zone) outside window \(Int(bounds.width))x\(Int(bounds.height)) at \(Int(frame.minX)),\(Int(frame.minY))")
    }
  }
}

extension View {
  /** Report this control's frame as one standing along the window's bottom edge, which framing
   * keeps clear of, without checking it for overlaps (ROUND5 9G.5). */
  func bottomControl(_ zone: String) -> some View {
    onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { LayoutChecker.shared.setBottomControl(zone, $0) }
      .onDisappear { LayoutChecker.shared.setBottomControl(zone, nil) }
  }

  /** Report this control's frame, in the window, as one of the zones over the viewport. */
  func layoutZone(_ zone: String) -> some View {
    onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { LayoutChecker.shared.set(zone, $0) }
      .onDisappear { LayoutChecker.shared.set(zone, nil) }
  }
}

/** \} */

/** An item's name, as the tool rail shows it beside the item held: on the panels' surface. */
struct ShellNameLabel: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.subheadline)
      .foregroundStyle(.primary)
      .lineLimit(1)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .panelGlass(in: Capsule())
      .fixedSize()
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

/** Blender's tooltip: light text in a dark box. */
struct BlenderTooltip: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 14))
      .foregroundStyle(ShellStyle.text)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(ShellStyle.tooltip, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
      .fixedSize()
      .allowsHitTesting(false)
  }
}

/** A panel's surface in the chosen style, see #ShellStyle. */
private struct PanelSurface<S: Shape>: ViewModifier {
  let glass: PanelGlass
  let interactive: Bool
  let shape: S
  @AppStorage(ShellStyle.key) private var style = ShellStyle.blender.rawValue

  func body(content: Content) -> some View {
#if os(visionOS)
    switch glass {
      case .tinted(let color): content.background(color, in: shape)
      case .regular, .clear: content.background(.thinMaterial, in: shape)
      case .none: content
    }
#else
    if style == ShellStyle.glass.rawValue {
      /* One effect whose value changes, so iOS morphs between tints. */
      content.glassEffect(glass.liquid(interactive: interactive), in: shape)
    }
    else {
      let rounded = RoundedRectangle(cornerRadius: ShellStyle.radius, style: .continuous)
      switch glass {
        case .none:
          content
        case .tinted(let color):
          /* Blender's selection blue for the system blue the glass would be tinted with. */
          content.background(color == .blue ? ShellStyle.selection : color, in: rounded)
        case .regular, .clear:
          content
            .background(ShellStyle.region.opacity(0.94), in: rounded)
            .overlay(rounded.strokeBorder(ShellStyle.outline, lineWidth: 1))
            .environment(\.colorScheme, .dark)
      }
    }
#endif
  }
}

enum PanelGlass {
  case regular
  case clear
  case tinted(Color)
  /** No glass, keeping the view's identity so changes animate. */
  case none

#if !os(visionOS)
  func liquid(interactive: Bool) -> Glass {
    let glass: Glass
    switch self {
      case .regular: glass = .regular
      case .clear: glass = .clear
      case .tinted(let color): glass = .regular.tint(color)
      case .none: return .identity
    }
    return interactive ? glass.interactive() : glass
  }
#endif
}

extension View {
  @ViewBuilder
  func panelGlass<S: Shape>(_ glass: PanelGlass = .regular, interactive: Bool = false, in shape: S) -> some View {
    self.modifier(PanelSurface(glass: glass, interactive: interactive, shape: shape))
  }
}

extension View {
  /** Lists of choices, grouped as the platform groups its lists. */
  func groupedListStyle() -> some View { self.listStyle(.insetGrouped) }

  /** A search field that stays in the navigation bar. */
  func searchableInBar(text: Binding<String>) -> some View {
    self.searchable(text: text, placement: .navigationBarDrawer(displayMode: .always))
  }

  /** The shape a row lifts in while its context menu shows. */
  func contextMenuPreviewShape<S: Shape>(_ shape: S) -> some View {
    self.contentShape(.contextMenuPreview, shape)
  }

  /** The system's highlight under a hovering Pencil or pointer. */
  func pointerHighlight() -> some View { self.hoverEffect(.highlight) }

  /** The system's highlight under a hovering Pencil or pointer, in `shape`. */
  /** Typing replaces: a field's text is selected as it takes focus, as clicking into a field does
   * in Blender. The selection waits for the field to become the first responder. */
  func selectsAllOnFocus(_ focused: Bool) -> some View {
    onChange(of: focused) { _, isFocused in
      guard isFocused else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
      }
    }
  }

  func hoverHighlight<S: Shape>(_ shape: S) -> some View {
    self.contentShape(.hoverEffect, shape).hoverEffect(.highlight)
  }

  /** A sheet's heights on a phone, where popovers become sheets. */
  func sheetDetents() -> some View { self.presentationDetents([.medium, .large]) }
}

/** Glass shapes that blend and morph into each other as they come and go. */
struct PanelGlassGroup<Content: View>: View {
  var spacing: CGFloat = 8
  @ViewBuilder let content: Content

  var body: some View {
#if os(visionOS)
    content
#else
    GlassEffectContainer(spacing: spacing) { content }
#endif
  }
}

extension View {
  /** A glass button; visionOS draws bordered buttons on glass. */
  @ViewBuilder
  func glassButtonStyle() -> some View {
#if os(visionOS)
    self.buttonStyle(.bordered)
#else
    self.buttonStyle(.glass)
#endif
  }

  /** Scrolling puts the keyboard away; visionOS has no keyboard over the content to put away. */
  @ViewBuilder
  func dismissesKeyboardOnScroll(interactively: Bool) -> some View {
#if os(visionOS)
    self
#else
    self.scrollDismissesKeyboard(interactively ? .interactively : .immediately)
#endif
  }

  /** Controls above the keyboard while a field is edited. visionOS's keyboard floats apart from
   * the window, with no bar of its own. */
  @ViewBuilder
  func keyboardAccessory<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
#if os(visionOS)
    self
#else
    self.toolbar { ToolbarItemGroup(placement: .keyboard) { content() } }
#endif
  }

  /** A soft scroll edge, where the platform has one. */
  @ViewBuilder
  func softHorizontalScrollEdge() -> some View {
    shellScrollEdge(.horizontal)
  }

  /** The edges of the shell's scrolling bars, one way for all of them: plain, as Blender's regions
   * clip, or faded under glass; never the system's indicators, which come and go. An end with more
   * past it shows Blender's small arrow, as Blender's long menus do, until it is reached. */
  func shellScrollEdge(_ axes: Axis.Set) -> some View {
#if os(visionOS)
    self.scrollIndicators(.hidden)
#else
    self.scrollEdgeEffectStyle(ShellStyle.current == .glass ? .soft : .hard, for: axes == .horizontal ? .horizontal : .vertical)
      .scrollIndicators(.hidden)
      .modifier(ScrollMoreMarks(horizontal: axes == .horizontal))
#endif
  }
}

/** Blender's arrow at each end of a bar that has more past it, see `shellScrollEdge`. In Blender's
 * style the arrow has its own ground: a #width strip of the bar's colour, so the content ends
 * before it, as the arrow in Blender's long menus sits on the menu's colour (ROUND5 7E/E3). Under
 * glass it sits on the glass's own soft edge. It takes no touches. */
struct ScrollMoreMarks: ViewModifier {
  let horizontal: Bool
  /** The strip the arrow stands on in Blender's style. */
  static let width: CGFloat = 20
  @State private var before = false
  @State private var after = false
  @AppStorage(ShellStyle.key) private var style = ShellStyle.blender.rawValue

  func body(content: Content) -> some View {
    content
      .onScrollGeometryChange(for: [Bool].self) { geometry in
        let offset = horizontal ? geometry.contentOffset.x + geometry.contentInsets.leading :
          geometry.contentOffset.y + geometry.contentInsets.top
        let length = horizontal ? geometry.contentSize.width : geometry.contentSize.height
        let shown = horizontal ? geometry.containerSize.width - geometry.contentInsets.leading - geometry.contentInsets.trailing :
          geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
        return [offset > 4, offset + shown < length - 4]
      } action: { _, ends in
        withAnimation(.easeOut(duration: 0.15)) {
          before = ends[0]
          after = ends[1]
        }
      }
      .overlay(alignment: horizontal ? .leading : .top) {
        if before { mark(start: true).transition(.opacity) }
      }
      .overlay(alignment: horizontal ? .trailing : .bottom) {
        if after { mark(start: false).transition(.opacity) }
      }
  }

  private func mark(start: Bool) -> some View {
    let icon = horizontal ? (start ? "TRIA_LEFT" : "TRIA_RIGHT") : (start ? "TRIA_UP" : "TRIA_DOWN")
    let symbol = horizontal ? (start ? "chevron.left" : "chevron.right") : (start ? "chevron.up" : "chevron.down")
    let glass = style == ShellStyle.glass.rawValue
    return ZStack {
      /* Blender's style: the bar's own colour, solid, so nothing shows under the arrow. */
      if !glass { ShellStyle.region }
      Group {
        if let image = BlenderIcon.image(icon) {
          Image(uiImage: image).resizable().scaledToFit()
        }
        else {
          Image(systemName: symbol).resizable().scaledToFit().fontWeight(.bold)
        }
      }
      .frame(width: 10, height: 10)
      .foregroundStyle(Color.primary.opacity(0.7))
    }
    .frame(width: horizontal ? (glass ? 28 : Self.width) : nil, height: horizontal ? nil : (glass ? 28 : Self.width))
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/** Glass for a UIKit view, as SwiftUI's `panelGlass` gives a SwiftUI one. */
func makePanelGlass() -> UIVisualEffect {
#if os(visionOS)
  return UIBlurEffect(style: .systemThinMaterial)
#else
  return UIGlassEffect(style: .regular)
#endif
}

/** \} */
