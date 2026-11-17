/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Blender's navigation gizmo in the document window, and its pie of views. Blender draws the
 * gizmo; a hotspot over it takes the touches. A tap picks the axis under it, as in Blender; a
 * hold, or a drag out of it, opens the pie, and releasing over a view chooses it. The Pencil's
 * touches on the hotspot go to Blender, which tells them apart by the hotspot's identifier.
 */

import SwiftUI
import UIKit

struct ViewCommand {
  let title: String
  let symbol: String
  /** An operator of Blender's to run in the viewport, with its properties. */
  var operatorName: String?
  var properties: [String: NativeValue] = [:]
  /** Or a viewport option to toggle instead. */
  var toggle: String?

  /** The views, then Lock Camera to View, navigating then moves the camera, and Keep Camera
   * View, navigating then stays in the camera's view without moving the camera. */
  static func pie(locked: Bool, kept: Bool, camera: Bool = false) -> [ViewCommand] {
    /* Looking through the camera: its whole frame filling the view again, and the locks. */
    guard camera else { return views }
    return views + [ViewCommand(title: "Fit Camera View", symbol: "camera.viewfinder",
                                operatorName: "VIEW3D_OT_view_center_camera"),
                    ViewCommand(title: locked ? "Unlock Camera" : "Lock Camera",
                                symbol: locked ? "lock.open" : "lock", toggle: "lock_camera"),
                    ViewCommand(title: kept ? "Free Camera View" : "Keep Camera View",
                                symbol: kept ? "pin.slash" : "pin", toggle: "keep_camera_view")]
  }

  private static func axis(_ title: String, _ symbol: String, _ type: String) -> ViewCommand {
    ViewCommand(title: title, symbol: symbol, operatorName: "VIEW3D_OT_view_axis", properties: ["type": .text(type)])
  }

  static let views = [
    ViewCommand(title: "Frame All", symbol: "rectangle.expand.vertical", operatorName: "VIEW3D_OT_view_all"),
    ViewCommand(title: "Frame Selected", symbol: "viewfinder", operatorName: "VIEW3D_OT_view_selected"),
    ViewCommand(title: "Camera", symbol: "camera", operatorName: "VIEW3D_OT_view_camera"),
    ViewCommand(title: "Perspective", symbol: "cube.transparent", operatorName: "VIEW3D_OT_view_persportho"),
    ViewCommand(title: "Local View", symbol: "scope", operatorName: "VIEW3D_OT_localview"),
    axis("Front", "arrow.up.square", "FRONT"),
    axis("Right", "arrow.right.square", "RIGHT"),
    axis("Top", "arrow.down.to.line.square", "TOP"),
  ]

  /** Blender's icon for the operator, or the symbol. */
  var image: UIImage? {
    guard let operatorName else { return UIImage(systemName: symbol) }
    var value = ""
    if case .text(let type)? = properties["type"] { value = type }
    return wm_apple_ios_action_icon(operatorName, value.isEmpty ? "" : "type", value) ?? UIImage(systemName: symbol)
  }

  @MainActor
  func run() {
    if let toggle {
      ShellModel.current?.send("viewport:" + toggle, .set_, .bool(!(ShellModel.current?.viewportOption(toggle) ?? false)))
    }
    else if let operatorName {
      Operators.run(operatorName, properties)
    }
  }
}

/** Where the gizmo and the pie's buttons are, in the viewport layer's points. */
struct ViewGizmoGeometry {
  var center: CGPoint
  /** Blender's gizmo, and the larger hotspot around it. */
  var radius: CGFloat
  var hotspotRadius: CGFloat
  var buttons: [CGRect]

  var hotspot: CGRect {
    CGRect(x: center.x - hotspotRadius, y: center.y - hotspotRadius,
           width: hotspotRadius * 2, height: hotspotRadius * 2)
  }

  /** \a gizmo: Blender's gizmo, the square around its circle, in the view's coordinates. */
  init(gizmo: CGRect?, window: CGSize, safe: CGRect, pie: [ViewCommand]) {
    radius = gizmo.map { $0.width / 2 } ?? 40
    center = gizmo.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: window.width - 50, y: window.height - 50)
    hotspotRadius = max(44, radius + 10)
    buttons = []
    guard !safe.isEmpty else { return }
    /* A fan around the gizmo, opening toward the middle of the window: two arcs, each button
     * pointing away from the gizmo, the whole fan moved to stay in view. In a window too small for
     * it, a grid. */
    let widths = pie.map { min(180, ViewGizmoGeometry.buttonWidth($0)) }
    if let fan = ViewGizmoGeometry.fan(widths: widths, center: center, inner: hotspotRadius + 10, safe: safe) {
      buttons = fan
      return
    }
    let gridWidth = min(180, (safe.width - 36) / 2)
    let rows = CGFloat((pie.count + 1) / 2)
    let top = max(safe.minY + 12, safe.maxY - 12 - rows * 52)
    for index in pie.indices {
      buttons.append(CGRect(x: safe.minX + 12 + CGFloat(index % 2) * (gridWidth + 12),
                            y: top + CGFloat(index / 2) * 52, width: gridWidth, height: 44))
    }
  }

  /** Buttons of these widths fanned out from the center: a quarter circle around it toward the
   * window's middle, in an inner and an outer arc, rows evenly apart. Nil if they don't fit in
   * the safe area. */
  private static func fan(widths: [CGFloat], center: CGPoint, inner: CGFloat, safe: CGRect) -> [CGRect]? {
    let height: CGFloat = 44
    let row: CGFloat = 52
    let left: CGFloat = center.x > safe.midX ? -1 : 1
    let up: CGFloat = center.y > safe.midY ? -1 : 1
    let arcs = widths.count > 6 ? 2 : 1
    let perArc = (widths.count + arcs - 1) / arcs
    let rise = CGFloat(max(0, perArc - 1)) * row

    var rects = [CGRect](repeating: .zero, count: widths.count)
    /* How far out the arc is at its foot, and at its top. */
    let foot = inner + 110
    let top = inner
    for arc in 0..<arcs {
      let indices = Array(widths.indices.dropFirst(arc * perArc).prefix(perArc))
      for (slot, index) in indices.enumerated() {
        /* On a quarter ellipse around the center: the first beside it, the last above it. */
        let along = rise > 0 ? CGFloat(slot) * row / rise : 0
        let reach = top + (foot - top) * (1 - along * along).squareRoot()
        let rowRise = CGFloat(slot) * row
        /* An outer arc's button snug beside the inner one on its row, following its curve. */
        let previous = arc > 0 && slot < perArc ? rects[(arc - 1) * perArc + slot] : nil
        let near = previous.map { left < 0 ? $0.minX - 8 : $0.maxX + 8 } ?? center.x + left * reach
        let width = widths[index]
        rects[index] = CGRect(x: left < 0 ? near - width : near, y: center.y + up * rowRise - height / 2,
                              width: width, height: height)
      }
    }

    /* Moved as a whole into the safe area, keeping its shape. */
    let bounds = rects.reduce(CGRect.null) { $0.union($1) }
    let area = safe.insetBy(dx: 8, dy: 8)
    guard bounds.width <= area.width, bounds.height <= area.height else { return nil }
    let dx = max(area.minX - bounds.minX, min(0, area.maxX - bounds.maxX))
    let dy = max(area.minY - bounds.minY, min(0, area.maxY - bounds.maxY))
    return rects.map { $0.offsetBy(dx: dx, dy: dy) }
  }

  /** A pie button's natural width: its icon and title between the glass's margins. */
  static func buttonWidth(_ view: ViewCommand) -> CGFloat {
    let title = (view.title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 17)]).width
    return ceil(title) + 24 + 7 + 28
  }

  /** The button under a point, with some slack around each. */
  func button(at point: CGPoint) -> Int? {
    buttons.firstIndex { $0.insetBy(dx: -14, dy: -10).contains(point) }
  }
}

@MainActor
@Observable
final class ViewGizmoState {
  var pieVisible = false
  var hovered: Int?
  var pointerOver = false
  var pressed = false
  @ObservationIgnored var geometry: ViewGizmoGeometry?
  @ObservationIgnored var pie: [ViewCommand] = ViewCommand.pie(locked: false, kept: false)
#if !os(visionOS)
  @ObservationIgnored let selectionFeedback = UISelectionFeedbackGenerator()
  @ObservationIgnored let openFeedback = UIImpactFeedbackGenerator(style: .soft)
#endif

  func hover(at point: CGPoint) {
    let button = geometry?.button(at: point)
    guard button != hovered else { return }
    hovered = button
#if !os(visionOS)
    if button != nil { selectionFeedback.selectionChanged() }
#endif
  }

  /** Choose the view under the point, if any, and close the pie. */
  func release(at point: CGPoint?) {
    if let point, let button = geometry?.button(at: point) {
      if button < pie.count { pie[button].run() }
    }
    pieVisible = false
    hovered = nil
  }
}

/* -------------------------------------------------------------------- */
/** \name Hotspot
 * \{ */

/** A UIKit view, so the Pencil's touches on it reach Blender, which knows it by its identifier. */
final class ViewGizmoHotspot: UIControl {
  override init(frame: CGRect) {
    super.init(frame: frame)
    accessibilityIdentifier = "blender.viewport.navigation"
    accessibilityLabel = "View navigation"
    backgroundColor = .clear
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

struct ViewGizmoHotspotView: UIViewRepresentable {
  let model: ShellModel
  let state: ViewGizmoState

  @MainActor
  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var model: ShellModel
    var state: ViewGizmoState

    init(model: ShellModel, state: ViewGizmoState) {
      self.model = model
      self.state = state
    }

    /** In the layer's points, which the pie's buttons are in: the layer sits beside the
     * window's panels, not at its corner. */
    private func location(_ gesture: UIGestureRecognizer) -> CGPoint {
      let point = gesture.location(in: gesture.view)
      let origin = state.geometry?.hotspot.origin ?? .zero
      return CGPoint(x: point.x + origin.x, y: point.y + origin.y)
    }

    @objc func pressBegan() {
      state.pressed = true
#if !os(visionOS)
      state.openFeedback.prepare()
#endif
    }

    @objc func pressEnded() {
      state.pressed = false
    }

    @objc func hover(_ gesture: UIHoverGestureRecognizer) {
      state.pointerOver = gesture.state == .began || gesture.state == .changed
    }

    @objc func hold(_ gesture: UILongPressGestureRecognizer) {
      switch gesture.state {
        case .began:
          /* Consume the pending Pencil tap before it can become a Blender click. */
          wm_apple_ios_window_cancel_pencil_stroke(model.window)
          state.pieVisible = true
#if !os(visionOS)
          state.openFeedback.impactOccurred()
          state.selectionFeedback.prepare()
#endif
        case .changed: state.hover(at: location(gesture))
        case .ended: state.release(at: location(gesture))
        case .cancelled, .failed: state.release(at: nil)
        default: break
      }
    }

    @objc func drag(_ gesture: UIPanGestureRecognizer) {
      switch gesture.state {
        case .began:
          state.pieVisible = true
          state.hover(at: location(gesture))
        case .changed: state.hover(at: location(gesture))
        case .ended: state.release(at: location(gesture))
        case .cancelled, .failed: state.release(at: nil)
        default: break
      }
    }

    @objc func tap(_ gesture: UITapGestureRecognizer) {
      wm_apple_ios_window_navigation_tap(model.window, gesture)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool
    {
      false
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(model: model, state: state) }

  func makeUIView(context: Context) -> ViewGizmoHotspot {
    let hotspot = ViewGizmoHotspot(frame: .zero)
    let coordinator = context.coordinator
    hotspot.addTarget(coordinator, action: #selector(Coordinator.pressBegan), for: .touchDown)
    hotspot.addTarget(coordinator, action: #selector(Coordinator.pressEnded),
                      for: [.touchUpInside, .touchUpOutside, .touchCancel])
    hotspot.addGestureRecognizer(UIHoverGestureRecognizer(target: coordinator,
                                                          action: #selector(Coordinator.hover(_:))))

    let hold = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.hold(_:)))
    hold.minimumPressDuration = 0.32
    hold.allowableMovement = 10
    hold.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                              NSNumber(value: UITouch.TouchType.pencil.rawValue)]
    hotspot.addGestureRecognizer(hold)

    let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tap(_:)))
    tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    tap.require(toFail: hold)
    hotspot.addGestureRecognizer(tap)

    let drag = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.drag(_:)))
    drag.maximumNumberOfTouches = 1
    drag.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    drag.cancelsTouchesInView = true
    drag.delegate = coordinator
    drag.require(toFail: hold)
    hotspot.addGestureRecognizer(drag)
    return hotspot
  }

  func updateUIView(_ hotspot: ViewGizmoHotspot, context: Context) {
    context.coordinator.model = model
    context.coordinator.state = state
    hotspot.accessibilityValue = state.pieVisible ? "View menu open" : nil
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Gizmo and pie
 * \{ */

struct ViewGizmoLayer: View {
  let model: ShellModel
  @State private var state = ViewGizmoState()

  private var animation: Animation? {
    UIAccessibility.isReduceMotionEnabled ? nil : .spring(response: 0.28, dampingFraction: 0.86)
  }

  var body: some View {
    GeometryReader { proxy in
      /* Over the whole viewport, as Blender places the gizmo, keeping clear of the window's sides. */
      let insets = model.safeAreaInsets
      let safe = CGRect(origin: .zero, size: proxy.size).inset(by: UIEdgeInsets(
        top: insets.top, left: model.sideInsets.left, bottom: insets.bottom, right: model.sideInsets.right))
      let locked = model.viewportOption("lock_camera")
      let kept = model.viewportOption("keep_camera_view")
      let camera = model.viewportOption("camera_view")
      let pie = ViewCommand.pie(locked: locked, kept: kept, camera: camera)
      let origin = proxy.frame(in: .global).origin
      let geometry = ViewGizmoGeometry(gizmo: model.navigationGizmoRect?.offsetBy(dx: -origin.x, dy: -origin.y),
                                       window: proxy.size, safe: safe, pie: pie)
      ZStack(alignment: .topLeading) {
        feedback(geometry)
        ViewGizmoHotspotView(model: model, state: state)
          .frame(width: geometry.hotspot.width, height: geometry.hotspot.height)
          .position(geometry.center)
        /* Only looking through the camera, where they apply. */
        if camera {
          cameraLocks(locked: locked, kept: kept, geometry: geometry)
        }
        ForEach(Array(pie.enumerated()), id: \.offset) { index, view in
          if index < geometry.buttons.count {
            pieButton(view, index: index, frame: geometry.buttons[index], hub: geometry.center)
          }
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
      .onChange(of: proxy.size, initial: true) {
        state.geometry = geometry
        state.pie = pie
      }
      .onChange(of: [locked, kept, camera]) {
        state.geometry = geometry
        state.pie = pie
      }
      .onChange(of: model.navigationGizmo) { state.geometry = geometry }
      .onChange(of: model.pointScale) { state.geometry = geometry }
      .onChange(of: model.safeAreaInsets) { state.geometry = geometry }
      .onChange(of: model.sideInsets) { state.geometry = geometry }
    }
    .ignoresSafeArea()
    .animation(animation, value: state.pieVisible)
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
      state.release(at: nil)
      state.pressed = false
      state.pointerOver = false
    }
  }

  /** The camera's two locks, tiny beside the gizmo, always: lit while on. They are set in its
   * pie. */
  private func cameraLocks(locked: Bool, kept: Bool, geometry: ViewGizmoGeometry) -> some View {
    VStack(spacing: 6) {
      Image(systemName: locked ? "lock.fill" : "lock.open")
        .foregroundStyle(locked ? PanelStyle.selection : Color.white.opacity(0.45))
        .accessibilityLabel(locked ? "Camera Locked to View" : "Camera Not Locked to View")
      Image(systemName: kept ? "pin.fill" : "pin")
        .foregroundStyle(kept ? PanelStyle.selection : Color.white.opacity(0.45))
        .accessibilityLabel(kept ? "Camera View Kept" : "Camera View Not Kept")
    }
    .font(.system(size: 11, weight: .semibold))
    .shadow(color: .black.opacity(0.4), radius: 1)
    .position(x: geometry.center.x - geometry.hotspotRadius - 8, y: geometry.center.y)
    .opacity(state.pieVisible ? 0 : 1)
    .allowsHitTesting(false)
  }

  /** A ring around Blender's gizmo while it is hovered, pressed or showing its pie. */
  private func feedback(_ geometry: ViewGizmoGeometry) -> some View {
    let active = state.pieVisible
    let highlighted = active || state.pointerOver || state.pressed
    return Circle()
      .fill(Color.primary.opacity(active ? 0.12 : 0.05))
      .overlay(Circle().strokeBorder(Color.primary.opacity(active ? 0.5 : 0.2), lineWidth: 1))
      .frame(width: (geometry.radius + 2) * 2, height: (geometry.radius + 2) * 2)
      .scaleEffect(active ? 1.08 : (state.pressed ? 0.94 : 1))
      .opacity(highlighted ? 1 : 0)
      .position(geometry.center)
      .allowsHitTesting(false)
      .animation(UIAccessibility.isReduceMotionEnabled ? nil : .spring(response: 0.22, dampingFraction: 0.78),
                 value: highlighted)
  }

  private func pieButton(_ view: ViewCommand, index: Int, frame: CGRect, hub: CGPoint) -> some View {
    let shown = state.pieVisible
    let hovered = state.hovered == index
    /* Hidden, each button rests a little toward the gizmo, smaller, as if folded into it. */
    let travel: CGFloat = shown ? 0 : 0.18
    return Button {
      state.release(at: CGPoint(x: frame.midX, y: frame.midY))
    } label: {
      HStack(spacing: 7) {
        if let image = view.image {
          /* White on the hovered blue glass, which an icon's own colors would blend into. */
          Image(uiImage: image)
            .renderingMode(hovered || image.renderingMode != .alwaysOriginal ? .template : .original)
            .foregroundStyle(hovered ? Color.white : Color.primary)
            .font(.system(size: 20))
        }
        Text(view.title)
          .font(.system(size: 17))
          .lineLimit(1)
      }
      .foregroundStyle(hovered ? Color.white : Color.primary)
      .padding(.horizontal, 14)
      .frame(width: frame.width, height: frame.height)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .panelGlass(hovered ? .tinted(.blue) : .regular, in: Capsule())
    /* The pills float over the always-dark viewport, whatever the app's appearance. */
    .environment(\.colorScheme, .dark)
    .accessibilityLabel(view.title)
    .scaleEffect(shown ? 1 : 0.82)
    .offset(x: (hub.x - frame.midX) * travel, y: (hub.y - frame.midY) * travel)
    .opacity(shown ? 1 : 0)
    .allowsHitTesting(shown)
    .position(x: frame.midX, y: frame.midY)
  }
}

/** \} */
