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
 * - #ShellLayout.bottomStack: what stands in that row and above it (the actions, the last
 *   operation, the Item card, the number pad), every frame from what is open;
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
 * essential items into More: Share; File and Edit; then the editor's menus, one at a time from the
 * last, into a button at their end (More Menus), the button alone reading Menus once all are in
 * it (ROUND5 7E/E2, decision 42); the sidebar menu and Repeat; Menus and viewport shading;
 * Properties and the selection mode. Mode, Assets, Search, Undo, Redo and More never leave. */
enum HeaderLadder {
  static let widest = 6

  struct Shown: Equatable {
    var share: Bool
    var fileEdit: Bool
    /** The editor's menus in the header: some side by side (#State.menus) and the rest in one
     * button at their end, or all in that button. */
    var editorMenus: Bool
    var sidebar: Bool
    var repeatLast: Bool
    var shading: Bool
    var properties: Bool
    var selectMode: Bool
  }

  static func shows(_ rung: Int) -> Shown {
    Shown(share: rung >= 6, fileEdit: rung >= 5, editorMenus: rung >= 2, sidebar: rung >= 3, repeatLast: rung >= 3,
          shading: rung >= 2, properties: rung >= 1, selectMode: rung >= 1)
  }

  /** A rung and how many of the editor's menus stand side by side at it, in Blender's order. */
  struct State: Equatable {
    var rung: Int
    var menus: Int
  }

  /** Every state from the widest down, for \a count menus: all of them at rungs 6, 5 and 4, then
   * rung 4 with one fewer at a time down to one, then rungs 3 to 1 with none (the Menus button). */
  static func states(menus count: Int) -> [State] {
    var states = [State(rung: 6, menus: count), State(rung: 5, menus: count)]
    states += stride(from: count, through: min(1, count), by: -1).map { State(rung: 4, menus: $0) }
    states += [3, 2, 1].map { State(rung: $0, menus: 0) }
    return states
  }

  /** A text item's width: its title in the body font and the toolbar's padding around it. */
  static func text(_ title: String) -> CGFloat {
    ceil((title as NSString).size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .body)]).width) + 32
  }

  /**
   * The width the header needs in \a state: each item as it draws. The terms are the iPad's, read
   * from its screenshots at 1366 points (2026-11-17): a button and the gap after it take 56
   * points; a text item its title and 32; a group of text items 12 more; the bar's margins 20.
   * The mode draws as its icon only (a toolbar `Label`), so its name is not counted. Two checks
   * keep this honest on the device: `layout: … header clipped` when it is too small, and
   * `layout: … header spare` when it is too large (#DocumentWindow).
   */
  static func need(_ state: State, menus: [String], editMesh: Bool, documents: Bool) -> CGFloat {
    let shown = shows(state.rung)
    let icon: CGFloat = 56, gap: CGFloat = 12
    var width: CGFloat = 20 /* the bar's margins */
    if documents { width += icon }
    if shown.fileEdit { width += text("File") + text("Edit") + gap }
    if shown.sidebar { width += icon }
    width += icon * 2 /* mode and Assets */
    if shown.editorMenus {
      let side = min(max(state.menus, 0), menus.count)
      if side > 0 {
        width += menus.prefix(side).reduce(0) { $0 + text($1) } + gap
        if side < menus.count { width += icon /* More Menus */ }
      }
      else {
        width += text("Menus") + gap
      }
    }
    width += icon /* Search */
    if shown.selectMode && editMesh { width += 160 }
    width += 16 /* between the sides */
    if shown.shading { width += icon }
    if shown.properties { width += icon }
    width += icon * 2 /* Undo, Redo */
    if shown.repeatLast { width += icon }
    if shown.share { width += icon }
    width += icon /* More */
    return width
  }

  /** The widest state that fits \a width; a wider one than \a previous only once it fits with
   * 16 points to spare, so a window dragged along a threshold does not flicker. */
  static func state(width: CGFloat, phone: Bool, previous: State, menus: [String], editMesh: Bool,
                    documents: Bool) -> State
  {
    guard !phone else { return State(rung: 0, menus: 0) }
    let all = states(menus: menus.count)
    /* A previous state of another mode's menus (or none yet) asks no margin, as the widest. */
    let previousIndex = all.firstIndex(of: previous) ?? 0
    for (index, state) in all.enumerated() {
      let need = need(state, menus: menus, editMesh: editMesh, documents: documents)
      if width >= need + (index < previousIndex ? 16 : 0) { return state }
    }
    return State(rung: 0, menus: 0)
  }

  /** How much more the next wider state than \a state needs, by the estimate; nil at the widest.
   * The header's spare check compares what it measures with it. */
  static func nextExtra(_ state: State, menus: [String], editMesh: Bool, documents: Bool) -> CGFloat? {
    let all = states(menus: menus.count)
    /* Rung 0 is a phone's or a compact window's, chosen by its width class, not by room. */
    guard state.rung > 0, let index = all.firstIndex(of: state), index > 0 else { return nil }
    return need(all[index - 1], menus: menus, editMesh: editMesh, documents: documents) -
      need(state, menus: menus, editMesh: editMesh, documents: documents)
  }
}

/** Keeps the model's width class, header rung and menus side by side for the window's width, the
 * mode and its menus. */
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
    let editMesh = model.hasMeshSelectMode
    let previous = HeaderLadder.State(rung: model.headerRung, menus: model.headerMenus)
    let state = widthClass == .compact ? HeaderLadder.State(rung: 0, menus: 0) :
      HeaderLadder.state(width: width, phone: phone, previous: previous, menus: menus, editMesh: editMesh,
                         documents: true)
    if model.widthClass != widthClass { model.widthClass = widthClass }
    if model.headerRung != state.rung { model.headerRung = state.rung }
    if model.headerMenus != state.menus { model.headerMenus = state.menus }
    let extra = HeaderLadder.nextExtra(state, menus: menus, editMesh: editMesh, documents: true)
    if model.headerNextExtra != extra { model.headerNextExtra = extra }
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

extension View {
  /** Stand in \a rect of a top-leading stack, aligned inside it. */
  func placed(in rect: CGRect, alignment: Alignment = .center) -> some View {
    frame(width: rect.width, height: rect.height, alignment: alignment).offset(x: rect.minX, y: rect.minY)
  }
}

/** What is open in the bottom row, for #ShellLayout.bottomStack. */
struct BottomStackInput: Equatable {
  enum Fold { case none, folded, open }
  /** The row view's width. */
  var width: CGFloat
  /** The lane, from #ShellLayout.band. */
  var laneLeading: CGFloat
  var laneWidth: CGFloat
  /** From the row's top up to 8 points under the top chrome. */
  var headroom: CGFloat
  /** 40 % of the view's height. */
  var itemMaxHeight: CGFloat
  var actions = Fold.none
  /** The open bar hugging its items, before clamping. */
  var actionsWidth: CGFloat = 0
  var operation = Fold.none
  var operationPillWidth: CGFloat = 0
  /** The open strip hugging its settings, before clamping. */
  var operationWidth: CGFloat = 0
  var item = Fold.none
  /** The number pad is shown. */
  var pad = false
}

/** A piece of the bottom stack that can stand in the row as a pill. */
enum BottomStackPill: Hashable {
  case actions, operation, item
}

/** Where each piece of the bottom stack stands, in the row's coordinates: the origin at the
 * top-leading corner of the row, y negative above it. */
struct BottomStackFrames: Equatable {
  /** The Actions pill, or the open bar. */
  var actions: CGRect?
  /** The last operation's pill, or its open strip. */
  var operation: CGRect?
  /** The Item pill; or, when #itemOpen, the slot the card stands in. */
  var item: CGRect?
  var itemOpen = false
  /** The slot the number pad stands in: its keys narrow with it, see #NumberPad. */
  var pad: CGRect?
  /** The held action's name, its centre. */
  var nameY: CGFloat = 0
  /** Pills shown as a circle with their icon alone, the lane being too narrow for their names
   * (rule 9); a hold names them. */
  var iconPills: Set<BottomStackPill> = []
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

  /**
   * Where everything in the bottom row stands (ROUND5 Stage 6A, decision 23). Every rule depends
   * on what is open, never on a measured width, so nothing changes shelf when a bar's content
   * changes:
   *
   * 1. The open strip stands on a shelf above the row when the actions are open too, or the lane
   *    is narrower than #ShellMetrics.wideRow; otherwise it opens in the row.
   * 2. The Item card opens when it is open, the number pad is not shown, and there is room above
   *    for its header and a row; otherwise it is its pill.
   * 3. Pills stand in the row from the lane's leading end, in order: Actions, the operation, Item.
   * 4. The open actions bar is centred on the view, between the pills and the lane's end.
   * 5. The open strip is centred on the view, inside the room it has: after the pills in the row,
   *    the whole lane above it.
   * 6. Shelves above the row, each a gap above the one below: the strip, the number pad, the Item
   *    card. A slot is where a view stands, anchored at its bottom-leading corner.
   * 7. With nothing in the row, the first shelf rests on the row's content line.
   * 8. The held action's name stands above the bar, the strip and the pad.
   * 9. While the pills and their gaps are wider than the lane, or leave the open actions bar
   *    less than #ShellMetrics.barMinWidth, the last named pill becomes a
   *    circle with its icon alone: Item, then the operation, then Actions (decision 31). The
   *    number pad narrows with the lane, and below its narrowest it is centred on the view.
   */
  nonisolated static func bottomStack(_ input: BottomStackInput) -> BottomStackFrames {
    typealias M = ShellMetrics
    let gap = M.stackGap
    let laneEnd = input.laneLeading + input.laneWidth
    var frames = BottomStackFrames()

    /* Rules 1 and 2. */
    let stripAbove = input.operation == .open && (input.actions == .open || input.laneWidth < M.wideRow)
    let shelves = stripAbove ? gap + M.stripHeight : 0
    frames.itemOpen = input.item == .open && !input.pad && input.headroom - shelves - gap >= M.itemMinHeight

    /* Rule 3: the pills, in order; rule 9: named while they fit the lane, else icons, the last
     * first. */
    var pills: [(piece: BottomStackPill, width: CGFloat)] = []
    if input.actions == .folded { pills.append((.actions, M.actionsPillWidth)) }
    if input.operation == .folded { pills.append((.operation, input.operationPillWidth)) }
    if input.item == .folded || (input.item == .open && !frames.itemOpen) { pills.append((.item, M.itemPillWidth)) }
    func pillsWidth() -> CGFloat {
      pills.reduce(0) { $0 + $1.width } + gap * CGFloat(max(0, pills.count - 1))
    }
    /* Also while the open bar beside them would get less than its narrowest. */
    func crowded() -> Bool {
      let width = pillsWidth()
      return width > input.laneWidth ||
        (input.actions == .open && !pills.isEmpty && input.laneWidth - width - gap < M.barMinWidth)
    }
    for piece in [BottomStackPill.item, .operation, .actions] where crowded() {
      guard let index = pills.firstIndex(where: { $0.piece == piece }) else { continue }
      pills[index].width = M.buttonHeight
      frames.iconPills.insert(piece)
    }
    var x = input.laneLeading
    for pill in pills {
      let rect = CGRect(x: x, y: (M.rowHeight - M.buttonHeight) / 2, width: pill.width, height: M.buttonHeight)
      x += pill.width + gap
      switch pill.piece {
        case .actions: frames.actions = rect
        case .operation: frames.operation = rect
        case .item: frames.item = rect
      }
    }
    let pillsEnd = x
    let inRow = pillsEnd > input.laneLeading

    /* Centred on the view, kept between \a start and \a end. */
    func centred(_ width: CGFloat, _ start: CGFloat, _ end: CGFloat) -> CGFloat {
      max(start, min(input.width / 2 - width / 2, end - width))
    }
    let barY = (M.rowHeight - M.barHeight) / 2

    /* Rule 4: the bar. */
    if input.actions == .open {
      let width = max(0, min(input.actionsWidth, laneEnd - pillsEnd))
      frames.actions = CGRect(x: centred(width, pillsEnd, laneEnd), y: barY, width: width, height: M.barHeight)
    }

    /* Rule 5, in the row. */
    if input.operation == .open && !stripAbove {
      let width = max(0, min(input.operationWidth, 1000, laneEnd - pillsEnd))
      frames.operation = CGRect(x: centred(width, pillsEnd, laneEnd), y: barY, width: width, height: M.stripHeight)
    }

    /* Rules 6 and 7: the shelves, from the top of what is in the row. */
    let barInRow = input.actions == .open || (input.operation == .open && !stripAbove)
    var base = barInRow ? barY - gap : inRow ? (M.rowHeight - M.buttonHeight) / 2 - gap : barY + M.barHeight
    if stripAbove {
      let width = max(0, min(input.operationWidth, 1000, input.laneWidth))
      frames.operation = CGRect(x: centred(width, input.laneLeading, laneEnd), y: base - M.stripHeight,
                                width: width, height: M.stripHeight)
      base -= M.stripHeight + gap
    }
    if input.pad {
      /* Rule 9: its keys narrow to the lane, down to their narrowest; below that it is centred on
       * the view, as wide as its narrowest. */
      let width = max(M.padMinWidth, min(M.padSize.width, input.laneWidth))
      let leading = frames.actions.map { input.actions == .open ? $0.minX : input.laneLeading } ?? input.laneLeading
      let padX = input.laneWidth < M.padMinWidth ? max(0, (input.width - width) / 2) :
        max(input.laneLeading, min(leading, laneEnd - width))
      frames.pad = CGRect(x: padX, y: base - M.padSize.height, width: width, height: M.padSize.height)
      base -= M.padSize.height + gap
    }
    if frames.itemOpen {
      /* What is left of the headroom above the shelves below it. */
      let height = max(0, min(input.itemMaxHeight, base + input.headroom))
      frames.item = CGRect(x: input.laneLeading, y: base - height, width: max(0, min(input.laneWidth, 520)),
                           height: height)
    }

    /* Rule 8: above the highest of the bar, the strip and the pad. */
    let top = [frames.actions.flatMap { input.actions == .open ? $0.minY : nil },
               frames.operation.flatMap { input.operation == .open ? $0.minY : nil }, frames.pad?.minY]
      .compactMap { $0 }.min() ?? barY
    frames.nameY = top - 28
    return frames
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

  /** The bottom stack's configurations the self-test covers: (name, input), over a lane. */
  private static func stackCases(width: CGFloat, lane: Band, headroom: CGFloat, itemMaxHeight: CGFloat)
    -> [(name: String, input: BottomStackInput, card: CGSize?)]
  {
    var cases: [(name: String, input: BottomStackInput, card: CGSize?)] = []
    let actions: [(String, BottomStackInput.Fold, CGFloat)] = [
      ("", .none, 0), (" actions", .folded, 0), (" actions open 300", .open, 300), (" actions open 2000", .open, 2000)]
    let operations: [(String, BottomStackInput.Fold, CGFloat)] = [
      ("", .none, 0), (" operation", .folded, 0), (" operation open 420", .open, 420),
      (" operation open 2000", .open, 2000)]
    let items: [(String, BottomStackInput.Fold, CGSize?)] = [
      ("", .none, nil), (" item", .folded, nil), (" item open 86", .open, CGSize(width: 438, height: 86)),
      (" item open 200", .open, CGSize(width: 438, height: 200))]
    for a in actions {
      for pad in a.1 == .open ? [false, true] : [false] {
        for o in operations {
          for i in items {
            var input = BottomStackInput(width: width, laneLeading: lane.laneLeading, laneWidth: lane.laneWidth,
                                         headroom: headroom, itemMaxHeight: itemMaxHeight)
            input.actions = a.1
            input.actionsWidth = a.2
            input.operation = o.1
            input.operationPillWidth = 96
            input.operationWidth = o.2
            input.item = i.1
            input.pad = pad
            cases.append((a.0 + (pad ? " pad" : "") + o.0 + i.0, input, i.2))
          }
        }
      }
    }
    return cases
  }

  /**
   * Every layout over a grid: seven widths and a short window, the tool rail on each edge, open
   * and closed, the gizmo top or bottom, and every configuration of the bottom stack (the
   * actions, the last operation, the Item card, the number pad), placed by #bottomStack, the
   * function the row itself uses. Three checks, each logged as `selftest:`: no two zones overlap;
   * every zone lies inside the window and the stack's below the tool row; an open card's slot
   * is at least #ShellMetrics.itemMinHeight tall. Then the count. Nothing on screen changes; it
   * runs once at launch when `PLATYPUS_LAYOUT_SELFTEST=1`.
   */
  static func selfTest() {
    guard ProcessInfo.processInfo.environment["PLATYPUS_LAYOUT_SELFTEST"] == "1" else { return }
    let sizes = [CGSize(width: 1366, height: 1024), CGSize(width: 1100, height: 1024), CGSize(width: 910, height: 1024),
                 CGSize(width: 797, height: 1024), CGSize(width: 683, height: 1024), CGSize(width: 560, height: 1024),
                 CGSize(width: 440, height: 1024), CGSize(width: 797, height: 600)]
    let header: CGFloat = 74, toolRow: CGFloat = 44, safeBottom: CGFloat = 20
    var layouts = 0, overlaps = 0, outside = 0, short = 0
    var seen = Set<String>()
    func say(_ key: String, _ detail: String) {
      if seen.insert(key).inserted { WM_native_ui_log("selftest", "\(key) \(detail)") }
    }
    for size in sizes {
      let widthClass = WidthClass.of(width: size.width, phone: false, previous: .wide)
      let rowShown = widthClass != .compact
      let top = header + (rowShown ? toolRow + 6 : 0)
      let window = CGRect(origin: .zero, size: size)
      for edge in [RailEdge.leading, .trailing, .top, .bottom] {
        for open in [false, true] {
          for gizmoBottom in [false, true] {
            let tools = RailState()
            tools.docked = open
            let predicted = predictedGizmo(size: size, top: top, leading: false, bottom: gizmoBottom,
                                           sideInsets: .zero)
            let safe = window.inset(by: UIEdgeInsets(top: top, left: 0, bottom: safeBottom, right: 0))
            let content = SidebarContent(brush: nil, buttons: true, selecting: true)
            let rail = RailLayout(safe: safe, tray: 0, tools: tools, toolCount: 18, brushes: nil, brushCount: 0,
                                  sidebar: content, leftHanded: false, gizmo: predicted.footprint, toolEdge: edge)
            let lane = Self.band(size: size, sideInsets: .zero, safeBottom: safeBottom, tray: 0,
                                 rails: RailFrames(rail), gizmo: predicted.gizmo, footprint: predicted.footprint,
                                 keyboardLift: 0)
            var fixed: [(String, CGRect)] = [("gizmo", predicted.footprint)]
            fixed.append(("header", CGRect(x: 0, y: 0, width: size.width, height: header)))
            if rowShown {
              fixed.append(("tool settings", CGRect(x: 14, y: header + 6, width: size.width - 28, height: toolRow)))
            }
            fixed.append(("tools", CGRect(x: rail.toolCenter.x - rail.toolWidth / 2,
                                          y: rail.toolCenter.y - rail.toolHeight / 2,
                                          width: rail.toolWidth, height: rail.toolHeight)))
            if !content.isEmpty && !rail.sidebarTucked {
              let sidebar = rail.sidebarRow != nil ?
                CGSize(width: content.height, height: PaintSidebar.rowThickness) :
                CGSize(width: PaintSidebar.width, height: content.height)
              fixed.append(("sidebar", CGRect(x: rail.sidebarCenter.x - sidebar.width / 2,
                                              y: rail.sidebarCenter.y - sidebar.height / 2,
                                              width: sidebar.width, height: sidebar.height)))
            }
            let rowY = size.height - lane.rowBottom - ShellMetrics.rowHeight
            let headroom = rowY - top - 8
            let condition = "\(Int(size.width))x\(Int(size.height)) \(edge.rawValue)\(open ? " open" : "") " +
              "gizmo \(gizmoBottom ? "bottom" : "top")"
            for stackCase in stackCases(width: size.width, lane: lane, headroom: headroom,
                                        itemMaxHeight: size.height * 0.4)
            {
              layouts += 1
              let frames = bottomStack(stackCase.input)
              func inWindow(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: 0, dy: rowY) }
              /* An open card or the pad: the bottom-leading part of its slot it draws in. */
              func standing(_ slot: CGRect, _ size: CGSize) -> CGRect {
                let width = min(size.width, slot.width), height = min(size.height, slot.height)
                return CGRect(x: slot.minX, y: slot.maxY - height, width: width, height: height)
              }
              var stack: [(String, CGRect)] = []
              if let rect = frames.actions { stack.append(("actions", inWindow(rect))) }
              if let rect = frames.operation { stack.append(("operation", inWindow(rect))) }
              /* The pad is its slot: its keys take the slot's width. */
              if let rect = frames.pad { stack.append(("number pad", inWindow(rect))) }
              if let rect = frames.item {
                stack.append(("item", inWindow(frames.itemOpen ? standing(rect, stackCase.card ?? rect.size) : rect)))
                if frames.itemOpen && rect.height < ShellMetrics.itemMinHeight {
                  short += 1
                  say("\(condition)\(stackCase.name): item slot \(Int(rect.height)) tall",
                      "under \(Int(ShellMetrics.itemMinHeight))")
                }
              }
              let zones = fixed + stack
              for (i, a) in zones.enumerated() {
                for b in zones[(i + 1)...] {
                  let overlap = a.1.intersection(b.1)
                  guard !overlap.isNull, overlap.width > 1, overlap.height > 1 else { continue }
                  overlaps += 1
                  say("\(condition)\(stackCase.name): \(a.0) ∩ \(b.0)", "\(Int(overlap.width))x\(Int(overlap.height))")
                }
              }
              for (zone, rect) in zones {
                let bounds = stack.contains(where: { $0.0 == zone }) ?
                  CGRect(x: 0, y: top, width: size.width, height: size.height - top) : window
                guard !bounds.insetBy(dx: -1, dy: -1).contains(rect) else { continue }
                outside += 1
                say("\(condition)\(stackCase.name): \(zone) outside",
                    "\(Int(rect.width))x\(Int(rect.height)) at \(Int(rect.minX)),\(Int(rect.minY))")
              }
            }
          }
        }
      }
    }
    /* The header at each width, with Object Mode's four editor menus and Edit Mode's eight
     * (ROUND5 7E/E2): the state chosen, and that its estimate fits the window. */
    var headersOver = 0
    let menuSets: [(String, [String], Bool)] = [
      ("object", ["View", "Select", "Add", "Object"], false),
      ("edit", ["View", "Select", "Add", "Mesh", "Vertex", "Edge", "Face", "UV"], true),
    ]
    for size in sizes where WidthClass.of(width: size.width, phone: false, previous: .wide) != .compact {
      for (mode, menus, editMesh) in menuSets {
        let state = HeaderLadder.state(width: size.width, phone: false,
                                       previous: HeaderLadder.State(rung: HeaderLadder.widest, menus: menus.count),
                                       menus: menus, editMesh: editMesh, documents: true)
        let need = HeaderLadder.need(state, menus: menus, editMesh: editMesh, documents: true)
        say("header \(Int(size.width)) \(mode):", "rung \(state.rung), \(state.menus) of \(menus.count) menus, " +
            "needs \(Int(need))")
        if state.rung > 0 && need > size.width {
          headersOver += 1
          say("header \(Int(size.width)) \(mode): outside", "needs \(Int(need))")
        }
      }
    }
    WM_native_ui_log("selftest", "\(layouts) layouts, \(overlaps) overlaps; \(outside) beyond the window, \(short) slots too short; " +
                     "\(headersOver) headers too wide")
  }

  /** \} */
}

/* -------------------------------------------------------------------- */
/** \name A sidebar's slide (ROUND5 14B.1)
 *
 * One curve for a sidebar sliding in or out: SwiftUI animates the panel and the controls over the
 * view with it, and the viewport eases what it tells Blender over it, so what Blender draws at the
 * view's edges (the navigation gizmo, its buttons, the view's text) moves with the panel.
 * \{ */

enum SidebarSlide {
  /** SwiftUI's spring: its response, seconds, and damping fraction. */
  static let response: Double = 0.3
  static let damping: Double = 0.9
  /** By when the spring has settled to well under a pixel. */
  static let duration: TimeInterval = 0.45

  static var animation: Animation? {
    reduceMotion ? nil : .spring(response: response, dampingFraction: damping)
  }

  /** The system's Reduce Motion, or a check script's `motion reduce on` (ROUND5 14C), which lasts
   * until the app quits and is never saved. */
  nonisolated(unsafe) static var reduceMotionForScript = false
  static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled || reduceMotionForScript }

  /** How far the slide has come, 0 to 1, \a time seconds after it began: the same spring's step
   * response (unit mass, stiffness (2π / response)², damping 4π · fraction / response). */
  static func progress(_ time: TimeInterval) -> Double {
    guard time < duration else { return 1 }
    let omega = 2 * Double.pi / response
    let decay = damping * omega
    let damped = omega * (1 - damping * damping).squareRoot()
    return 1 - exp(-decay * time) * (cos(damped * time) + decay / damped * sin(damped * time))
  }
}

extension ShellLayout {
  /** The second bar's band beside a sidebar (ROUND5 14A, decision 85): the tool settings row's
   * height, where the row shows as a bar (Blender's style, not compact, not Blender's own
   * interface); nil where a sidebar's title keeps its own height. */
  static func secondBar(rowHeight: CGFloat, glass: Bool, compact: Bool, desktop: Bool) -> CGFloat? {
    guard !glass, !compact, !desktop, rowHeight > 0 else { return nil }
    return rowHeight
  }
}

extension EnvironmentValues {
  /** The second bar's height, which a sidebar's title strip in a wide window continues (14A). */
  @Entry var secondBarHeight: CGFloat? = nil
}

/** \} */
