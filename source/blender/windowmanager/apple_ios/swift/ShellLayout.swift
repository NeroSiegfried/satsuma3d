/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Where the window's controls go, as pure functions of the window's state, so that no control is
 * placed from another control's measured frame (ROUND5 Stage 5):
 *
 * - #WidthClass: the one notion of a narrow window;
 * - #HeaderLadder: which of the header's items show at a width, folding the least essential into
 *   More one rung at a time, rather than the system's overflow taking a whole side at once;
 * - #RailFrames: where the rails' layout (#RailLayout) put them, in the window;
 * - #ShellLayout.band: the row along the bottom, from the rails and the navigation gizmo;
 * - #ShellLayout.selfTest: every layout over a grid of windows, logging any two zones that
 *   overlap (`PLATYPUS_LAYOUT_SELFTEST=1`).
 */

import SwiftUI
import UIKit

/* -------------------------------------------------------------------- */
/** \name Width class
 * \{ */

/** How wide the window is, for everything that changes with it. */
enum WidthClass: Int, Comparable {
  /** A phone, or a window under 500 points: one menu, the tool settings in it. */
  case compact
  /** 500 to 700 points: the tool settings without their names. */
  case narrow
  /** 700 to 1000 points: only one of Properties and the Outliner beside the viewport. */
  case regular
  case wide

  static func < (a: WidthClass, b: WidthClass) -> Bool { a.rawValue < b.rawValue }

  var name: String { ["compact", "narrow", "regular", "wide"][rawValue] }

  private static func of(_ width: CGFloat) -> WidthClass {
    width >= 1000 ? .wide : width >= 700 ? .regular : width >= 500 ? .narrow : .compact
  }

  /** The class of a window \a width wide; it changes only 16 points past a threshold, so a window
   * dragged along one does not flicker between two. */
  static func of(width: CGFloat, phone: Bool, previous: WidthClass) -> WidthClass {
    guard !phone else { return .compact }
    let wider = of(width - 16), narrower = of(width + 16)
    if wider > previous { return wider }
    if narrower < previous { return narrower }
    return previous
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Header ladder
 * \{ */

/** Which of the header's items show at a width. From the widest rung down, each moves the least
 * essential items into More: Share; File and Edit; the editor's menus fold into one Menus button;
 * the sidebar menu and Repeat; Menus and viewport shading; Properties and the selection mode.
 * Mode, Assets, Search, Undo, Redo and More never leave. */
enum HeaderLadder {
  static let widest = 6

  struct Shown: Equatable {
    var share: Bool
    var fileEdit: Bool
    /** View, Select, Add, Object… side by side. */
    var menusExpanded: Bool
    /** The editor's menus in one Menus button. */
    var menusButton: Bool
    var sidebar: Bool
    var repeatLast: Bool
    var shading: Bool
    var properties: Bool
    var selectMode: Bool
  }

  static func shows(_ rung: Int) -> Shown {
    Shown(share: rung >= 6, fileEdit: rung >= 5, menusExpanded: rung >= 4, menusButton: rung == 2 || rung == 3,
          sidebar: rung >= 3, repeatLast: rung >= 3, shading: rung >= 2, properties: rung >= 1,
          selectMode: rung >= 1)
  }

  private static func text(_ title: String) -> CGFloat {
    ceil((title as NSString).size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .body)]).width) + 24
  }

  /** The width the header needs at \a rung: each item as it draws, and the spacers between the
   * groups. An estimate, which the header check (`layout: … header clipped`) keeps honest. */
  static func need(_ rung: Int, modeTitle: String, menus: [String], editMesh: Bool, documents: Bool) -> CGFloat {
    let shown = shows(rung)
    let icon: CGFloat = 52, spacer: CGFloat = 16, group: CGFloat = 8
    var width: CGFloat = 32 + 24 /* margins, slack */
    if documents { width += icon + spacer }
    if shown.fileEdit { width += text("File") + text("Edit") + group + spacer }
    if shown.sidebar { width += icon + spacer }
    width += 30 + text(modeTitle) + icon + group /* mode and Assets */
    if shown.menusExpanded { width += menus.reduce(0) { $0 + text($1) } + group }
    else if shown.menusButton { width += text("Menus") + group }
    width += icon + group /* Search */
    if shown.selectMode && editMesh { width += 152 + spacer }
    width += spacer /* between the sides */
    if shown.shading { width += icon + spacer }
    if shown.properties { width += icon + spacer }
    width += icon * 2 + group /* Undo, Redo */
    if shown.repeatLast { width += icon }
    if shown.share { width += icon }
    width += icon /* More */
    return width
  }

  /** The widest rung that fits \a width; a wider one only once it fits with 16 points to spare. */
  static func rung(width: CGFloat, phone: Bool, previous: Int, modeTitle: String, menus: [String], editMesh: Bool,
                   documents: Bool) -> Int
  {
    guard !phone else { return 0 }
    for rung in stride(from: widest, to: 0, by: -1) {
      let need = need(rung, modeTitle: modeTitle, menus: menus, editMesh: editMesh, documents: documents)
      if width >= need + (rung > previous ? 16 : 0) { return rung }
    }
    return 0
  }
}

/** Keeps the model's width class and header rung for the window's width, the mode and its menus. */
struct HeaderLadderTracker: ViewModifier {
  let model: ShellModel
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var width: CGFloat = 0

  private var menus: [String] {
    (BlenderMenus.shared.items[EditorMenus.route] ?? []).filter { $0.submenu && !$0.disabled }.map(\.title)
  }

  private func update() {
    guard width > 0 else { return }
    let phone = UIDevice.current.userInterfaceIdiom == .phone || sizeClass == .compact && width < 500
    let widthClass = WidthClass.of(width: width, phone: phone, previous: model.widthClass)
    let modeTitle = model.modes.first { $0.id == model.objectMode }?.label ?? "Object Mode"
    let rung = widthClass == .compact ? 0 :
      HeaderLadder.rung(width: width, phone: phone, previous: model.headerRung, modeTitle: modeTitle, menus: menus,
                        editMesh: model.mode == "mesh_edit", documents: true)
    if model.widthClass != widthClass { model.widthClass = widthClass }
    if model.headerRung != rung { model.headerRung = rung }
  }

  func body(content: Content) -> some View {
    content
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0; update() }
      .onChange(of: sizeClass) { _, _ in update() }
      .onChange(of: model.mode) { _, _ in update() }
      .onChange(of: model.objectMode) { _, _ in update() }
      .onChange(of: menus) { _, _ in update() }
  }
}

extension View {
  func headerLadder(_ model: ShellModel) -> some View { modifier(HeaderLadderTracker(model: model)) }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Rails and the bottom band
 * \{ */

/** Where #RailLayout put the rails, as computed: what the controls along the bottom keep clear of. */
struct RailFrames: Equatable {
  /** The widest column on the leading and the trailing edge, 0 for none. */
  var leadingCorner: CGFloat = 64
  var trailingCorner: CGFloat = 0
  /** A row of rails along the bottom, with its gap: what the controls along the bottom rise above. */
  var bottomRow: CGFloat = 0

  init() {}

  init(_ layout: RailLayout) {
    leadingCorner = layout.leadingCorner
    trailingCorner = layout.trailingCorner
    bottomRow = layout.bottomRow
  }
}

@MainActor
enum ShellLayout {
  /** The lane the row along the bottom has, and how far its bottom edge is from the view's. */
  struct Band: Equatable {
    var laneLeading: CGFloat
    var laneWidth: CGFloat
    /** From the bottom of the view to the bottom of the row. */
    var rowBottom: CGFloat
  }

  /**
   * The row along the bottom of a view \a size large: between the tool rail and the navigation
   * gizmo, across the whole viewport as Blender places the gizmo, beside the window's sides, and
   * above a row of rails, the tray and the keyboard where a field in it is typed into. \a gizmo is
   * Blender's circle and \a footprint the gizmo with its buttons, both in the view's coordinates.
   */
  static func band(size: CGSize, sideInsets: UIEdgeInsets, safeBottom: CGFloat, tray: CGFloat, rails: RailFrames,
                   gizmo: CGRect?, footprint: CGRect?, keyboardLift: CGFloat) -> Band
  {
    let width = size.width
    let gizmoBottom = footprint.map { $0.midY > size.height / 2 } ?? true
    let gizmoLeft = footprint.map { $0.midX < width / 2 } ?? false
    /* The touch hotspot around the gizmo reaches further than the gizmo. */
    let reach = gizmo.map { max(44, $0.width / 2 + 10) } ?? 0
    let reachLeft = min(footprint?.minX ?? width, gizmo.map { $0.midX - reach } ?? width)
    let reachRight = max(footprint?.maxX ?? 0, gizmo.map { $0.midX + reach } ?? 0)
    let laneLeading = max(sideInsets.left + (rails.leadingCorner > 0 ? ShellMetrics.railLeading + rails.leadingCorner : 0) + 12,
                          gizmoBottom && gizmoLeft ? reachRight + 12 : 0)
    let hotspot = min(!gizmoBottom || gizmoLeft ? width :
                        footprint != nil ? reachLeft : width - ShellMetrics.gizmoReserve,
                      width - sideInsets.right -
                        (rails.trailingCorner > 0 ? ShellMetrics.railLeading + rails.trailingCorner : 0))
    let rowBottom = max(safeBottom + ShellMetrics.rowBottom + tray + rails.bottomRow, keyboardLift + 8)
    return Band(laneLeading: laneLeading, laneWidth: max(0, hotspot - 12 - laneLeading), rowBottom: rowBottom)
  }

  /** The gizmo and its buttons in the top trailing corner below \a top, before Blender reports
   * where they are: Blender's default size and its four buttons below it. */
  static func predictedGizmo(size: CGSize, top: CGFloat, leading: Bool, bottom: Bool, sideInsets: UIEdgeInsets)
    -> (gizmo: CGRect, footprint: CGRect)
  {
    let radius: CGFloat = 40, inset: CGFloat = radius + 7
    let cx = leading ? sideInsets.left + inset : size.width - sideInsets.right - inset
    let cy = bottom ? size.height - inset : top + inset
    let gizmo = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
    let column: CGFloat = 4 * 31 + 20
    let footprint = CGRect(x: gizmo.minX - 8, y: bottom ? gizmo.minY - column : gizmo.minY,
                           width: gizmo.width + 16, height: gizmo.height + column)
    return (gizmo, footprint)
  }

  /** \} */

  /* -------------------------------------------------------------------- */
  /** \name Self-test
   * \{ */

  /**
   * Every layout over a grid: seven widths and a short window, the tool rail on each edge, open
   * and closed, the gizmo top or bottom, the actions folded or open, the Item card off or open;
   * any two zones that overlap are logged as `selftest:`, then the count. Nothing on screen
   * changes; it runs once at launch when `PLATYPUS_LAYOUT_SELFTEST=1`.
   */
  static func selfTest() {
    guard ProcessInfo.processInfo.environment["PLATYPUS_LAYOUT_SELFTEST"] == "1" else { return }
    let sizes = [CGSize(width: 1366, height: 1024), CGSize(width: 1100, height: 1024), CGSize(width: 910, height: 1024),
                 CGSize(width: 797, height: 1024), CGSize(width: 683, height: 1024), CGSize(width: 560, height: 1024),
                 CGSize(width: 440, height: 1024), CGSize(width: 797, height: 600)]
    let header: CGFloat = 74, toolRow: CGFloat = 44, safeBottom: CGFloat = 20
    var layouts = 0, overlaps = 0
    var seen = Set<String>()
    for size in sizes {
      let widthClass = WidthClass.of(width: size.width, phone: false, previous: .wide)
      let rowShown = widthClass != .compact
      let top = header + (rowShown ? toolRow + 6 : 0)
      for edge in [RailEdge.leading, .trailing, .top, .bottom] {
        for open in [false, true] {
          for gizmoBottom in [false, true] {
            for actionsOpen in [false, true] {
              for itemRows in [0, 2] {
                layouts += 1
                let tools = RailState()
                tools.docked = open
                let predicted = predictedGizmo(size: size, top: top, leading: false, bottom: gizmoBottom,
                                               sideInsets: .zero)
                let safe = CGRect(origin: .zero, size: size).inset(by: UIEdgeInsets(
                  top: top, left: 0, bottom: safeBottom, right: 0))
                let content = SidebarContent(brush: nil, buttons: true, selecting: true)
                let rail = RailLayout(safe: safe, tray: 0, tools: tools, toolCount: 18, brushes: nil, brushCount: 0,
                                      sidebar: content, leftHanded: false, gizmo: predicted.footprint, toolEdge: edge)
                let lane = Self.band(size: size, sideInsets: .zero, safeBottom: safeBottom, tray: 0,
                                rails: RailFrames(rail), gizmo: predicted.gizmo, footprint: predicted.footprint,
                                keyboardLift: 0)
                var zones: [(String, CGRect)] = [("gizmo", predicted.footprint)]
                zones.append(("header", CGRect(x: 0, y: 0, width: size.width, height: header)))
                if rowShown {
                  zones.append(("tool settings", CGRect(x: 14, y: header + 6, width: size.width - 28, height: toolRow)))
                }
                zones.append(("tools", CGRect(x: rail.toolCenter.x - rail.toolWidth / 2,
                                              y: rail.toolCenter.y - rail.toolHeight / 2,
                                              width: rail.toolWidth, height: rail.toolHeight)))
                if !content.isEmpty && !rail.sidebarTucked {
                  let sidebar = rail.sidebarRow != nil ?
                    CGSize(width: content.height, height: PaintSidebar.rowThickness) :
                    CGSize(width: PaintSidebar.width, height: content.height)
                  zones.append(("sidebar", CGRect(x: rail.sidebarCenter.x - sidebar.width / 2,
                                                  y: rail.sidebarCenter.y - sidebar.height / 2,
                                                  width: sidebar.width, height: sidebar.height)))
                }
                let rowY = size.height - lane.rowBottom - ShellMetrics.rowHeight
                let barWidth = actionsOpen ? min(lane.laneWidth, 600) : ShellMetrics.actionsPillWidth
                let barX = actionsOpen ? min(max(size.width / 2 - barWidth / 2, lane.laneLeading),
                                             lane.laneLeading + lane.laneWidth - barWidth) : lane.laneLeading
                let barHeight = actionsOpen ? ShellMetrics.barHeight : ShellMetrics.buttonHeight
                zones.append(("actions", CGRect(x: barX, y: rowY + (ShellMetrics.rowHeight - barHeight) / 2,
                                                width: barWidth, height: barHeight)))
                if itemRows > 0 {
                  let height = 48 + CGFloat(itemRows) * 38
                  zones.append(("item", CGRect(x: lane.laneLeading, y: rowY - 8 - height,
                                               width: min(lane.laneWidth, 420), height: height)))
                }
                for (i, a) in zones.enumerated() {
                  for b in zones[(i + 1)...] {
                    let overlap = a.1.intersection(b.1)
                    guard !overlap.isNull, overlap.width > 1, overlap.height > 1 else { continue }
                    overlaps += 1
                    let key = "\(Int(size.width))x\(Int(size.height)) \(edge.rawValue)\(open ? " open" : "") " +
                      "gizmo \(gizmoBottom ? "bottom" : "top")\(actionsOpen ? " actions" : "")" +
                      "\(itemRows > 0 ? " item" : ""): \(a.0) ∩ \(b.0)"
                    if seen.insert(key).inserted {
                      WM_native_ui_log("selftest", "\(key) \(Int(overlap.width))x\(Int(overlap.height))")
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    WM_native_ui_log("selftest", "\(layouts) layouts, \(overlaps) overlaps")
  }

  /** \} */
}
