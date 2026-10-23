/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The rails along the document window's leading edge: Blender's tools, and in paint and sculpt
 * modes the brushes above them, sharing one column.
 *
 * A rail shows only its active item until opened. A tap opens it, wide with titles, and picking
 * closes it again; holding an item opens it the same way to slide to an item and release. Dragged
 * up, a rail docks open at the middle of the window, where it stays until its handle closes it.
 * Tools in a group show the others in a menu while the list is open. A label beside the rail
 * names an item while a pointer or the Pencil hovers it, and briefly after choosing one.
 *
 * Dragged away from its edge, a rail comes loose and follows the finger, and lands on the edge
 * nearest where it is let go: either side, or along the top or the bottom as a row.
 */

#if !os(visionOS)
import PencilKit
#endif
import SwiftUI
import UIKit

/* -------------------------------------------------------------------- */
/** \name Items
 * \{ */

/** A tool or brush on a rail. */
struct RailItem: Identifiable {
  /** A brush's preview on its rail, in points. */
  static let brushPreviewSize: CGFloat = 46

  let id: String
  let title: String
  let image: UIImage?
  /** Shown while chosen, with the list open; Blender has white artwork for some tools. */
  let selectedImage: UIImage?
  /** A gap before it, between two groups of tools or catalogs of brushes. */
  let gapBefore: Bool
  /** The other tools of its group, to choose from a menu. */
  let group: [RailItem]
  /** Where a group's menu separates its sections, by index into `group`. */
  let groupBreaks: Set<Int>
  /** What it does, as Blender's tooltip says, where nothing hovers to show one. */
  var detail = ""

  var grouped: Bool { group.count > 1 }

  @MainActor
  static func tools(_ tools: [JSON?], mode: String) -> [RailItem] {
    var items: [RailItem] = []
    var gap = false
    for tool in tools {
      guard let tool else {
        gap = !items.isEmpty
        continue
      }
      guard let item = makeTool(tool, mode: mode, gapBefore: gap) else { continue }
      items.append(item)
      gap = false
    }
    return items
  }

  @MainActor
  private static func makeTool(_ tool: JSON, mode: String, gapBefore: Bool) -> RailItem? {
    guard let id = tool.string("id"), !id.isEmpty, let title = tool.string("title"), !title.isEmpty,
          tool.string("symbol") != nil
    else { return nil }
    var group: [RailItem] = []
    var breaks: Set<Int> = []
    for child in (tool["children"] as? [Any]) ?? [] {
      guard let child = child as? JSON else {
        breaks.insert(group.count)
        continue
      }
      if let item = makeTool(child, mode: mode, gapBefore: false) { group.append(item) }
    }
    return RailItem(id: id, title: title, image: toolImage(tool, mode: mode, selected: false),
                    selectedImage: toolImage(tool, mode: mode, selected: true), gapBefore: gapBefore,
                    group: group, groupBreaks: breaks, detail: tool.string("description") ?? "")
  }

  /** Blender's colored tool artwork, or its monochrome icon, or a symbol. */
  @MainActor
  static func toolImage(_ tool: JSON, mode: String, selected: Bool) -> UIImage? {
    if let icon = tool.string("icon") {
      if let colored = UIImage(named: (selected ? "blender.tool.selected." : "blender.tool.color.") + icon) {
        return colored.withRenderingMode(.alwaysOriginal)
      }
      if let image = UIImage(named: "blender.tool." + icon) {
        return image.withRenderingMode(.alwaysTemplate)
      }
    }
    let id = tool.string("id") ?? ""
    let prefix = selected ? "selected.tool." : "tool."
    if let image = wm_apple_ios_icon("\(prefix)\(mode).\(id)", nil) { return image }
    let symbol = tool.string("symbol") ?? ""
    return wm_apple_ios_icon(prefix + id, symbol.isEmpty ? nil : symbol) ??
      UIImage(systemName: "questionmark.circle")
  }

  @MainActor
  static func brushes(_ brushes: JSON?) -> [RailItem] {
    var items: [RailItem] = []
    var catalog: String?
    for brush in brushes?.array("items") ?? [] {
      guard let id = brush.string("id"), !id.isEmpty, let title = brush.string("title") else { continue }
      /* Catalogs are separated the way the tool rail separates groups. */
      let brushCatalog = brush.string("catalog") ?? ""
      let image = wm_apple_ios_brush_image(brush.string("preview") ?? "", brushPreviewSize)
      items.append(RailItem(id: id, title: title, image: image, selectedImage: image,
                            gapBefore: catalog != nil && catalog != brushCatalog, group: [],
                            groupBreaks: []))
      catalog = brushCatalog
    }
    return items
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name State
 * \{ */

/** The window edge a rail sits along. */
enum RailEdge: String {
  case leading, trailing, top, bottom

  /** Along the top or the bottom: a row rather than a column. */
  var horizontal: Bool { self == .top || self == .bottom }
}

@MainActor
@Observable
final class RailState {
  /** Opened by a tap or a hold: wide, with titles, until an item is picked. */
  var expanded = false
  /** Docked open at the middle of the window. */
  var docked = false
  /** Closed, the brushes rest at the top of their edge rather than above the navigation gizmo. */
  var restsAtTop = false
  /** Holding an item to slide to another and release. */
  var pressSelecting = false
  /** Held with a Pencil: rolling it turns a dial of the items instead. */
  var dialing = false
  /** The item under the finger while sliding. */
  var hovered: String?
  /** The rail following a drag, before it docks. */
  var dragOffset: CGFloat = 0
  /** Dragged away from its edge, the rail follows the finger to another. */
  var moving = false
  var moveOffset = CGSize.zero
  /** A hold ended over an item: its tap, which ends with it, is not one. */
  @ObservationIgnored var suppressTap = false
  /** Chosen here, until Blender's snapshot shows it. */
  var pending: String?
  @ObservationIgnored var pendingUntil = Date.distantPast
  /** Each item's frame in the window, to tell which one is under a finger and to place the label
   * beside it. */
  private(set) var frames: [String: CGRect] = [:]

  func setFrame(_ frame: CGRect?, for id: String) {
    if frames[id] != frame { frames[id] = frame }
  }

  var listVisible: Bool { expanded || docked }

  func active(_ blender: String) -> String {
    if let pending, pending != blender, Date() < pendingUntil { return pending }
    return blender
  }

  func choose(_ id: String) {
    pending = id
    pendingUntil = Date().addingTimeInterval(1)
  }

  func item(at point: CGPoint) -> String? {
    frames.first { $0.value.insetBy(dx: -10, dy: -6).contains(point) }?.key
  }
}

/** The label beside the rails naming an item. */
@MainActor
@Observable
final class RailLabel {
  var text: String?
  /** The item it names, and its rail, which it stays beside as the rail opens and closes. */
  private(set) var item = ""
  private(set) weak var rail: RailState?
  /** Shown after choosing, rather than while hovering, and hiding by itself. */
  private(set) var transient = false
  @ObservationIgnored private var generation = 0

  var anchor: CGRect { rail?.frames[item] ?? .zero }

  func show(_ text: String, item: String, rail: RailState, transient: Bool) {
    generation += 1
    self.text = text
    self.item = item
    self.rail = rail
    self.transient = transient
    guard transient else { return }
    let current = generation
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
      guard let self, self.generation == current else { return }
      self.hide()
    }
  }

  func hide() {
    generation += 1
    text = nil
    transient = false
  }

  /** The pointer left an item: only a hover label goes. */
  func hoverEnded() {
    if !transient { hide() }
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name A rail
 * \{ */

struct RailItemView: View {
  let item: RailItem
  let selected: Bool
  let emphasized: Bool
  let showsTitle: Bool
  /** In a row along the top or the bottom, as wide as it is tall. */
  var inRow = false
  /** Brushes' previews sit closer to the edges than tool icons. */
  let brush: Bool
  let namespace: Namespace.ID

  var body: some View {
    let image = selected ? item.selectedImage ?? item.image : item.image
    HStack(spacing: showsTitle ? 10 : 0) {
      if let image {
        if brush {
          /* A brush's stroke, large enough to tell from the others at a glance. */
          Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: RailItem.brushPreviewSize, height: RailItem.brushPreviewSize)
        }
        else {
          Image(uiImage: image)
            .renderingMode(image.renderingMode == .alwaysOriginal ? .original : .template)
            .font(.system(size: 20))
        }
      }
      if showsTitle {
        Text(item.title)
          .font(.system(size: 17))
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 0)
      }
    }
    .foregroundStyle(selected ? Color.white : Color.primary)
    .padding(.leading, showsTitle ? (brush ? 4 : 12) : (brush ? 3 : 8))
    .padding(.trailing, showsTitle ? 14 : (brush ? 3 : 8))
    .frame(minWidth: inRow ? 52 : nil, maxWidth: inRow ? 52 : .infinity, minHeight: 52, maxHeight: 52)
    .background {
      if selected {
        /* The selection slides from item to item. */
        Capsule()
          .fill(.clear)
          .panelGlass(.tinted(.blue), in: Capsule())
          .matchedGeometryEffect(id: "selection", in: namespace)
      }
      else if emphasized {
        Capsule().fill(.clear).panelGlass(in: Capsule())
      }
    }
    .overlay(alignment: .bottomTrailing) {
      if item.grouped {
        Image(systemName: "arrowtriangle.down.fill")
          .resizable()
          .frame(width: 7, height: 7)
          .foregroundStyle(selected ? Color.white : Color.secondary)
          .padding(6)
          .accessibilityHidden(true)
      }
    }
    .contentShape(Capsule())
  }
}

struct Rail: View {
  let items: [RailItem]
  let active: String
  let state: RailState
  let label: RailLabel
  let width: CGFloat
  let height: CGFloat
  /** Brushes rather than tools. */
  let brush: Bool
  let edge: RailEdge
  /** Where the rail would rest at the middle and at the bottom, to dock it by its drag. */
  let dockDistance: CGFloat
  /** The closed brushes' other places, from where they rest: docked open halfway down their
   * edge, and their other resting place, at the top or the bottom. */
  var brushStops: (middle: CGFloat, other: CGFloat) = (0, 0)
  /** Let go away from its edge, at this point in the window: the rail moves to the nearest. */
  let move: (CGPoint) -> Void
  let choose: (RailItem) -> Void
  @Namespace private var namespace
  @State private var railFrame = CGRect.zero

  /** Where an item sits on the rail: in the open list, its own place; closed, the one shown,
   * which becomes it. */
  private var landing: (RailItem) -> CGRect? {
    let state = state, active = active
    return { item in state.frames[item.id] ?? state.frames[active] }
  }

  private func updateZone() {
    let state = state, label = label, choose = choose, animation = animation
    /* Only the closed rail, its one button: an open list is tapped instead. */
    RollDial.shared.setZone(brush ? "brushes" : "tools", RollDial.Zone(
      frame: state.listVisible ? .null : railFrame, items: items, active: active, landing: landing) { item in
        state.choose(item.id)
        choose(item)
        if state.expanded { withAnimation(animation) { state.expanded = false } }
        label.show(item.title, item: item.id, rail: state, transient: true)
      })
  }

  private var animation: Animation? {
    UIAccessibility.isReduceMotionEnabled ? nil : .spring(response: 0.32, dampingFraction: 0.84)
  }

  private var lifted: Bool { state.moving || state.dragOffset != 0 }

  /** The compact rail shows the active item, or the first while none is active. */
  private var shown: [RailItem] {
    if state.listVisible { return items }
    return [items.first { $0.id == active } ?? items.first].compactMap { $0 }
  }

  var body: some View {
    let stack = edge.horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
    stack {
      if state.listVisible {
        handle
      }
      ScrollViewReader { scroller in
        ScrollView(edge.horizontal ? .horizontal : .vertical, showsIndicators: false) {
          /* Evenly spaced, as wide apart as the gaps between groups. */
          let items = edge.horizontal ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
          items {
            ForEach(shown) { item in
              itemView(item)
                .id(item.id)
            }
          }
          .padding(6)
          /* The selection slides to a new tool or brush, however it was chosen. */
          .animation(animation, value: active)
        }
        /* Not while a hold slides along it: the scroll view would take the finger. */
        .scrollDisabled(!state.listVisible || state.pressSelecting || state.moving)
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: state.listVisible) { _, visible in
          if visible { scroller.scrollTo(active, anchor: .center) }
        }
      }
    }
    .frame(width: width, height: height)
    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
    .panelGlass(in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    /* Lifted off the window while dragged, to move or to dock it. */
    .scaleEffect(lifted ? 1.06 : 1)
    .shadow(color: .black.opacity(lifted ? 0.32 : 0), radius: lifted ? 20 : 0, y: lifted ? 12 : 0)
    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: lifted)
    .offset(x: state.moveOffset.width, y: state.moveOffset.height + (edge.horizontal ? 0 : state.dragOffset))
    /* The finger on the rail: dragging the closed rail up or down docks it, and holding an item
     * slides to another. An open list scrolls instead. */
    /* Only on the closed rail: on an open list, even a drag that does nothing takes the finger
     * from the scroll view, which then cannot scroll. */
    .simultaneousGesture(dockDrag, including: state.listVisible && !state.pressSelecting ? .subviews : .all)
    /* Pulled off its edge from anywhere on it, open or closed, held first or not. */
    .gesture(RailMoveGesture(horizontal: edge.horizontal,
                             allowed: { [state] in !state.pressSelecting && !RollDial.shared.showing }) { translation in
      if !state.moving { beginMove() }
      state.moveOffset = translation
    } ended: { point in
      endMove(at: point)
    })
    /* A Pencil on the rail turns its dial as soon as it rolls. */
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
      railFrame = frame
      updateZone()
    }
    .onChange(of: items.map(\.id)) { _, _ in updateZone() }
    .onChange(of: active) { _, _ in updateZone() }
    .onChange(of: state.listVisible) { _, _ in updateZone() }
    .onDisappear { RollDial.shared.setZone(brush ? "brushes" : "tools", nil) }
    /* The dial ended as the Pencil lifted, whether or not the hold here saw it end. */
    .onChange(of: RollDial.shared.showing) { _, showing in
      if !showing && state.dialing {
        state.dialing = false
        state.pressSelecting = false
      }
    }
    .accessibilityIdentifier(brush ? "blender.brushbar" : "blender.toolbar")
  }

  private func itemView(_ item: RailItem) -> some View {
    let selected = state.listVisible && item.id == active
    return RailItemView(item: item, selected: selected,
                        emphasized: state.listVisible && state.hovered == item.id,
                        showsTitle: state.expanded && !edge.horizontal, inRow: edge.horizontal, brush: brush,
                        namespace: namespace)
      .onTapGesture { tap(item) }
      /* Kept while a hold slides on: the list opening under the finger would otherwise end it. */
      .simultaneousGesture(pressSelect(item), including: state.listVisible && !state.pressSelecting ? .subviews : .all)
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { tap(item) }
    /* The system's own highlight under a hovering Pencil or pointer. */
    .hoverHighlight(Capsule())
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.setFrame($0, for: item.id) }
    .onDisappear { state.setFrame(nil, for: item.id) }
    .onHover { inside in
      if inside { label.show(item.title, item: item.id, rail: state, transient: false) }
      else { label.hoverEnded() }
    }
    .contextMenu {
      if item.grouped && state.listVisible && !state.pressSelecting { groupMenu(item) }
    }
    .accessibilityLabel(item.title)
    .accessibilityIdentifier(item.id)
    .accessibilityAddTraits(item.id == active ? .isSelected : [])
    .accessibilityHint(item.grouped ? "Touch and hold for related tools" :
                       brush ? "Touch and hold to choose from all brushes" : "")
  }

  /** A group's tools, while the list is open; an empty menu is not shown. */
  @ViewBuilder
  private func groupMenu(_ item: RailItem) -> some View {
    ForEach(Array(groupSections(item).enumerated()), id: \.offset) { _, section in
      Section {
        ForEach(section) { child in
          Button {
            pick(child, closing: false)
          } label: {
            Label {
              Text(child.title)
            } icon: {
              if let image = child.image { Image(uiImage: image) }
            }
          }
        }
      }
    }
  }

  private func groupSections(_ item: RailItem) -> [[RailItem]] {
    var sections: [[RailItem]] = [[]]
    for (index, child) in item.group.enumerated() {
      if item.groupBreaks.contains(index) && !sections[sections.count - 1].isEmpty { sections.append([]) }
      sections[sections.count - 1].append(child)
    }
    return sections
  }

  /* -------------------------------------------------------------------- */
  /* Choosing */

  private func pick(_ item: RailItem, closing: Bool) {
    state.choose(item.id)
    choose(item)
    if closing && state.expanded {
      withAnimation(animation) { state.expanded = false }
    }
    /* The label names it, beside where it ends up. */
    label.show(item.title, item: item.id, rail: state, transient: true)
  }

  private func tap(_ item: RailItem) {
    /* The Pencil lifting from a dial it rolled here. */
    if RollDial.shared.justClosed { return }
    if state.suppressTap {
      state.suppressTap = false
      return
    }
    if !state.listVisible {
      /* A tap on the closed rail opens it to pick another; the brushes open docked, as they
       * start. */
      label.hide()
      withAnimation(animation) {
        if brush || edge.horizontal { state.docked = true } else { state.expanded = true }
      }
      return
    }
    /* Opened by a tap, picking closes it again; a docked list stays open. */
    pick(item, closing: state.expanded && !state.docked)
  }

  /** A hold opens the closed rail to slide to another item. An open list scrolls instead, and
   * a group's own menu takes the hold there. */
  private func canBeginPress(on item: RailItem) -> Bool {
    !state.listVisible
  }

  /** Holding an item opens the rail; the finger slides to another and chooses it on release. */
  private func pressSelect(_ item: RailItem) -> some Gesture {
    LongPressGesture(minimumDuration: 0.22, maximumDistance: 10)
      .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
      .onChanged { value in
        guard case .second(true, let drag) = value else { return }
        if !state.pressSelecting {
          guard canBeginPress(on: item) else { return }
          state.pressSelecting = true
          state.dragOffset = 0
          label.hide()
          if PencilRoll.shared.down, let frame = state.frames[item.id] {
            /* A Pencil holds it: the items fan out around it, to roll the Pencil through. */
            state.dialing = true
            RollDial.shared.begin(items: items, active: active, at: CGPoint(x: frame.midX, y: frame.midY),
                                  landing: landing) { pick($0, closing: true) }
            return
          }
          state.hovered = item.id
          withAnimation(animation) { state.expanded = true }
        }
        if state.dialing { return }
        if let drag, let id = state.item(at: drag.location) { state.hovered = id }
      }
      .onEnded { value in
        guard state.pressSelecting, case .second(true, let drag) = value else { return }
        if state.dialing {
          state.dialing = false
          state.pressSelecting = false
          state.suppressTap = true
          DispatchQueue.main.async { state.suppressTap = false }
          RollDial.shared.end()
          return
        }
        pressEnded(at: drag?.location)
      }
  }

  private func pressEnded(at point: CGPoint?) {
    state.pressSelecting = false
    /* The item's tap ends with the hold: it is not one. */
    state.suppressTap = true
    DispatchQueue.main.async { state.suppressTap = false }
    let id = point.flatMap { state.item(at: $0) } ?? state.hovered
    state.hovered = nil
    if let item = items.first(where: { $0.id == id }) {
      pick(item, closing: true)
    }
    else {
      withAnimation(animation) { state.expanded = false }
    }
  }

  /* -------------------------------------------------------------------- */
  /* Moving to another edge */

  /** The rail comes loose. */
  private func beginMove() {
    Haptics.selection()
    label.hide()
    state.hovered = nil
    state.dragOffset = 0
    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { state.moving = true }
  }

  /** Lands the rail on the edge nearest \a point, carried on by a flick, or back on its own. */
  private func endMove(at point: CGPoint?) {
    guard state.moving else { return }
    state.suppressTap = true
    DispatchQueue.main.async { state.suppressTap = false }
    withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
      if let point { move(point) }
      state.moving = false
      state.moveOffset = .zero
      state.dragOffset = 0
    }
  }

  /* -------------------------------------------------------------------- */
  /* Docking */

  private func collapse() {
    label.hide()
    state.pressSelecting = false
    state.hovered = nil
    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
      state.expanded = false
      state.docked = false
      state.dragOffset = 0
    }
  }

  private func dock(_ docked: Bool) {
    label.hide()
    state.pressSelecting = false
    state.hovered = nil
    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
      state.expanded = false
      state.docked = docked
      state.dragOffset = 0
    }
  }

  private var dockDrag: some Gesture {
    DragGesture(minimumDistance: 10, coordinateSpace: .global)
      .onChanged { value in
        /* Not while the Pencil rolls the dial; a Pencil that may be about to roll moves the rail
         * only once it clearly drags. */
        if RollDial.shared.showing {
          if state.dragOffset != 0 { state.dragOffset = 0 }
          return
        }
        /* Once docking, it stays a dock drag, wherever the finger then wanders. */
        guard !state.moving, !state.listVisible, !state.pressSelecting, !edge.horizontal,
              state.dragOffset != 0 || RailMoveGesture.isAlong(value.translation, horizontal: false),
              !PencilRoll.shared.down || abs(value.translation.height) > 30
        else { return }
        state.dragOffset = value.translation.height
      }
      .onEnded { value in
        if RollDial.shared.showing || RollDial.shared.justClosed {
          state.dragOffset = 0
          endMove(at: nil)
          return
        }
        guard !state.moving, !state.listVisible, !state.pressSelecting, state.dragOffset != 0 else { return }
        state.suppressTap = true
        DispatchQueue.main.async { state.suppressTap = false }
        let velocity = value.velocity.height
        if brush {
          /* The closed brushes go to whichever place is nearest where they are let go, carried
           * on by a flick: docked open halfway down, or resting at the top or the bottom. */
          let landing = value.translation.height + velocity * 0.15
          let stops: [CGFloat] = [0, brushStops.middle, brushStops.other]
          let nearest = stops.min { abs($0 - landing) < abs($1 - landing) } ?? 0
          if nearest == brushStops.middle {
            dock(true)
            return
          }
          withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            if nearest == brushStops.other { state.restsAtTop.toggle() }
            state.dragOffset = 0
          }
          return
        }
        /* Whichever resting place is nearer. */
        var docked = abs(value.translation.height + dockDistance) < abs(value.translation.height)
        if velocity < -520 { docked = true }
        else if velocity > 520 { docked = false }
        dock(docked)
      }
  }

  /** At the top of an open list: tap or pull it down to close the list; pull a temporarily
   * opened tool list up to dock it. */
  private var handle: some View {
    Button(action: collapse) {
      if edge.horizontal {
        Capsule()
          .fill(Color.secondary)
          .frame(width: 5, height: 28)
          .frame(maxHeight: .infinity)
          .frame(width: 44)
          .contentShape(Rectangle())
      }
      else {
        Capsule()
          .fill(Color.secondary)
          .frame(width: 28, height: 5)
          .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
          .contentShape(Rectangle())
      }
    }
    .buttonStyle(.plain)
    .help(brush ? "Collapse Brushes" : "Collapse Toolbar")
    .accessibilityLabel(brush ? "Collapse Brushes" : "Collapse Toolbar")
    .accessibilityIdentifier(brush ? "blender.brushbar.handle" : "blender.toolbar.handle")
    .highPriorityGesture(
      DragGesture(minimumDistance: 8, coordinateSpace: .global)
        .onChanged { value in
          guard !state.moving, !edge.horizontal,
                state.dragOffset != 0 || RailMoveGesture.isAlong(value.translation, horizontal: false)
          else { return }
          let y = value.translation.height
          let canRaise = !brush && !state.docked
          state.dragOffset = y < 0 && canRaise ? max(-dockDistance, y) : min(32, max(0, y * 0.3))
        }
        .onEnded { value in
          guard !state.moving, !edge.horizontal else { return }
          let y = value.translation.height
          let velocity = value.velocity.height
          if !brush && !state.docked && dockDistance > 0 &&
            (-y > dockDistance * 0.5 || (y < -8 && velocity < -420))
          {
            /* Keep the list open, now docked rather than a temporary peek. */
            dock(true)
          }
          else if y > 36 || (y > 8 && velocity > 420) {
            collapse()
          }
          else {
            withAnimation(.easeOut(duration: 0.2)) { state.dragOffset = 0 }
          }
        })
  }
}

/** \} */

/** A pan that begins only across the rail's edge, beside the list's own scrolling along it. Which
 * way a drag first goes decides once what it does: across, it moves the rail; along, it docks or
 * closes it as before; after a hold, it slides between items. Reports the translation, then where
 * it was let go, carried on by a flick, in the window; nothing if cancelled. */
struct RailMoveGesture: UIGestureRecognizerRepresentable {
  let horizontal: Bool
  /** Not while a hold slides between items, or the Pencil rolls the dial. */
  let allowed: () -> Bool
  let changed: (CGSize) -> Void
  let ended: (CGPoint?) -> Void

  func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

  func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
    let pan = UIPanGestureRecognizer()
    pan.delegate = context.coordinator
    pan.maximumNumberOfTouches = 1
    return pan
  }

  func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
    context.coordinator.horizontal = horizontal
    context.coordinator.allowed = allowed
  }

  /** Along the rail's edge rather than across it: the other gestures' drags, never a move. */
  static func isAlong(_ translation: CGSize, horizontal: Bool) -> Bool {
    let along = abs(horizontal ? translation.width : translation.height)
    let across = abs(horizontal ? translation.height : translation.width)
    return across < along * 0.7
  }

  func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
    switch recognizer.state {
      case .began, .changed:
        let translation = recognizer.translation(in: nil)
        changed(CGSize(width: translation.x, height: translation.y))
      case .ended:
        let point = recognizer.location(in: nil), velocity = recognizer.velocity(in: nil)
        ended(CGPoint(x: point.x + velocity.x * 0.15, y: point.y + velocity.y * 0.15))
      case .cancelled, .failed:
        ended(nil)
      default:
        break
    }
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var horizontal = false
    var allowed: () -> Bool = { true }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
      guard let pan = recognizer as? UIPanGestureRecognizer, allowed() else { return false }
      let translation = pan.translation(in: nil)
      /* Diagonally counts: towards a corner is towards another edge. */
      return !RailMoveGesture.isAlong(CGSize(width: translation.x, height: translation.y), horizontal: horizontal)
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool
    {
      true
    }
  }
}

/* -------------------------------------------------------------------- */
/** \name The column
 * \{ */

/** Mirrors the controls held while drawing to the right, and the brushes to the left, for
 * drawing with the left hand. */
let leftHandedInterfaceKey = "BlenderLeftHandedInterface"

struct ToolRails: View {
  let model: ShellModel
  @State private var tools = RailState()
  /** The brushes start docked open, halfway down their edge. */
  @State private var brushes: RailState = {
    let state = RailState()
    state.docked = true
    return state
  }()
  @State private var label = RailLabel()
  @State private var intent = SelectIntentState()
  /** While asset libraries reload, the brush rail stays rather than flickering away. */
  @State private var brushesAvailable = false
  /** The sliders pinched into dials. */
  @AppStorage("BlenderSidebarDials") private var sidebarDials = false
  @AppStorage(leftHandedInterfaceKey) private var leftHanded = false
  /** Where the sidebar was moved along its edge, from the top of its travel (0) to the bottom
   * (1); below 0 it rests halfway down. */
  @AppStorage("BlenderSidebarPosition") private var sidebarPosition = -1.0
  /** The sidebar's top edge as its handle was picked up. */
  @State private var sidebarDragStart: CGFloat?
  /** The edges the rails were moved to; the brushes' empty until moved, to follow the hand. */
  @AppStorage("BlenderToolRailEdge") private var toolEdge = RailEdge.leading
  @AppStorage("BlenderBrushRailEdge") private var brushEdgeName = ""

  /** The edge of \a safe nearest \a point, both in the window. */
  private static func nearestEdge(to point: CGPoint, in safe: CGRect) -> RailEdge {
    let distances: [(RailEdge, CGFloat)] = [(.leading, point.x - safe.minX), (.trailing, safe.maxX - point.x),
                                            (.top, point.y - safe.minY), (.bottom, safe.maxY - point.y)]
    return distances.min { $0.1 < $1.1 }?.0 ?? .leading
  }

  var body: some View {
    GeometryReader { proxy in
      /* Below the top bar, which the window's safe area does not include. */
      let top = max(model.safeAreaInsets.top, model.topBarBottom - proxy.frame(in: .global).minY)
      let insets = UIEdgeInsets(top: top, left: 0, bottom: model.safeAreaInsets.bottom, right: 0)
      let safe = CGRect(origin: .zero, size: proxy.size).inset(by: insets)
      let toolItems = RailItem.tools(model.tools, mode: model.mode)
      let brushItems = RailItem.brushes(model.brushes)
      let color = (model.brush?["color"] as? [NSNumber])?.map(\.doubleValue)
      let gizmo = model.navigationGizmo
      let gizmoTop = gizmo.count == 3 ? CGFloat(gizmo[1]) * proxy.size.height - CGFloat(gizmo[2]) * proxy.size.width :
                                        safe.maxY - 100
      let arrange = { (dial: Bool) -> (SidebarContent, RailLayout) in
        let content = SidebarContent(brush: model.brush,
                                     buttons: model.direction?.bool("hidden") != true || model.transforming,
                                     smooth: model.direction?.bool("smooth") == true && !model.transforming,
                                     dial: dial)
        return (content, RailLayout(safe: safe, tray: model.bottomTray, tools: tools, toolCount: toolItems.count,
                                    brushes: brushesAvailable ? brushes : nil, brushCount: brushItems.count,
                                    sidebar: content,
                                    sidebarPosition: sidebarPosition >= 0 ? sidebarPosition : nil,
                                    colorWell: color != nil, leftHanded: leftHanded, gizmoTop: gizmoTop,
                                    toolEdge: toolEdge, brushEdge: RailEdge(rawValue: brushEdgeName)))
      }
      /* Where the sliders do not fit beside the tools, they become dials. */
      let (content, layout) = { () -> (SidebarContent, RailLayout) in
        let full = arrange(sidebarDials)
        guard !sidebarDials, full.1.sidebarTucked || (tools.listVisible && full.1.toolsCompact) else { return full }
        return arrange(true)
      }()
      /* Where a rail is let go, from the window's coordinates, which may be scaled, as on the Mac. */
      let frame = proxy.frame(in: .global)
      let local = { (point: CGPoint) -> CGPoint in
        frame.width > 0 && frame.height > 0 ?
          CGPoint(x: (point.x - frame.minX) * proxy.size.width / frame.width,
                  y: (point.y - frame.minY) * proxy.size.height / frame.height) : point
      }
      ZStack(alignment: .topLeading) {
        if let color {
          BrushColorWell(color: color)
            .position(layout.colorCenter)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
        if brushesAvailable {
          Rail(items: brushItems, active: brushes.active(model.brushes?.string("active") ?? ""),
               state: brushes, label: label, width: layout.brushWidth, height: layout.brushHeight,
               brush: true, edge: layout.brushEdge, dockDistance: 0, brushStops: layout.brushStops,
               move: { brushEdgeName = Self.nearestEdge(to: local($0), in: safe).rawValue }) { item in
            WM_apple_ios_ui_brush_activate(item.id)
          }
          .position(layout.brushCenter)
          .transition(.opacity)
        }
        Rail(items: toolItems, active: tools.active(model.activeTool), state: tools, label: label,
             width: layout.toolWidth, height: layout.toolHeight, brush: false, edge: layout.toolEdge,
             dockDistance: layout.dockDistance,
             move: { toolEdge = Self.nearestEdge(to: local($0), in: safe) }) { item in
          WM_apple_ios_ui_tool_set_by_id(item.id)
        }
        .position(layout.toolCenter)
        .onChange(of: layout.toolsCompact) { _, compact in
          /* No room beside the sliders for the open list: closed, the active tool alone. */
          guard compact else { return }
          withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            tools.expanded = false
            tools.docked = false
          }
        }
        if !content.isEmpty {
          PaintSidebar(state: intent, direction: model.direction, brush: model.brush, content: content,
                       leading: layout.sidebarLeading, transforming: model.transforming, window: model.window)
            .overlay(alignment: .top) {
              if !content.buttonsOnly { sidebarHandle(layout, content: content) }
            }
            /* Pinched in, the sliders become dials; pinched out, sliders again. */
            .simultaneousGesture(MagnifyGesture().onEnded { value in
              guard content.size || content.strength else { return }
              let dials = value.magnification < 0.85 ? true : value.magnification > 1.18 ? false : sidebarDials
              guard dials != sidebarDials else { return }
              Haptics.selection()
              withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) { sidebarDials = dials }
            })
            /* Lifted off the window while its handle moves it, as the rails are. */
            .scaleEffect(sidebarDragStart != nil ? 1.06 : 1)
            .shadow(color: .black.opacity(sidebarDragStart != nil ? 0.32 : 0),
                    radius: sidebarDragStart != nil ? 20 : 0, y: sidebarDragStart != nil ? 12 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: sidebarDragStart != nil)
            .position(layout.sidebarCenter)
            /* An open tool list takes the edge: the sidebar steps aside until it closes. */
            .offset(x: layout.sidebarTucked ? (layout.sidebarLeading ? -96 : 96) : 0)
            .opacity(layout.sidebarTucked ? 0 : 1)
            .allowsHitTesting(!layout.sidebarTucked)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
        railLabel(safe: safe, layout: layout, frame: proxy.frame(in: .global), size: proxy.size)
#if !os(visionOS)
        if FaceControl.shared.running {
          /* Below the bar, while the face plays the brush. */
          FaceControlBadge()
            .position(x: safe.midX, y: safe.minY + 34)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
#endif
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
      /* The Pencil's dial shows the items instead, over everything. */
      .opacity(RollDial.shared.showing ? 0 : 1)
      /* Fading as the dial opens; back at once as it lands, where the chosen item meets it. */
      .animation(RollDial.shared.showing ? .easeOut(duration: 0.18) : nil, value: RollDial.shared.showing)
      /* For the Pencil's dial over the tool settings. */
      .onChange(of: toolItems.map(\.id), initial: true) { _, _ in
        RollDial.shared.tools = toolItems
        updateSqueezePalette(toolItems: toolItems, brushItems: brushItems)
      }
      .onChange(of: model.activeTool, initial: true) { _, tool in
        RollDial.shared.activeTool = tools.active(tool)
        updateSqueezePalette(toolItems: toolItems, brushItems: brushItems)
      }
      .onChange(of: brushItems.map(\.id)) { _, _ in
        updateSqueezePalette(toolItems: toolItems, brushItems: brushItems)
      }
      .onChange(of: model.brushes?.string("active")) { _, _ in
        updateSqueezePalette(toolItems: toolItems, brushItems: brushItems)
      }
      .onChange(of: [model.canUndo, model.canRedo]) { _, _ in
        updateSqueezePalette(toolItems: toolItems, brushItems: brushItems)
      }
      .onChange(of: intent.strokes) { _, _ in
        updateSqueezePalette(toolItems: toolItems, brushItems: brushItems)
      }
#if !os(visionOS)
      .onChange(of: model.brush.map { $0 as NSDictionary }, initial: true) { _, brush in
        FaceControl.shared.brush = brush as? JSON
        if #available(iOS 26.0, *) { SqueezePalette.shared.brush = brush as? JSON }
      }
#endif
      /* Following the finger at once while the sidebar is moved. */
      .animation(UIAccessibility.isReduceMotionEnabled || sidebarDragStart != nil ? nil :
                   .spring(response: 0.32, dampingFraction: 0.84),
                 value: layout)
      .onChange(of: layout.leadingCorner, initial: true) { _, width in model.toolRailWidth = width }
      .onChange(of: layout.bottomRow, initial: true) { _, height in model.bottomRailHeight = height }
      .onAppear { PencilRoll.start() }
      .onChange(of: model.brushes.map { $0 as NSDictionary }, initial: true) { _, snapshot in
        let brushes = snapshot as? JSON
        let loading = brushes?.bool("loading") ?? false
        let available = !(brushes?.array("items").isEmpty ?? true) || (loading && brushesAvailable)
        if available != brushesAvailable {
          if !available {
            self.brushes.expanded = false
            self.brushes.pressSelecting = false
            self.brushes.hovered = nil
          }
          withAnimation(.easeInOut(duration: 0.24)) { brushesAvailable = available }
        }
      }
    }
    .ignoresSafeArea(edges: .vertical)
  }

  /** The system's tool palette a Pencil's squeeze shows: the brushes where Blender paints with
   * them, otherwise the tools. */
  private func updateSqueezePalette(toolItems: [RailItem], brushItems: [RailItem]) {
#if !os(visionOS)
    if #available(iOS 26.0, *) {
      RollDial.shared.activeBrush = model.brushes?.string("active")
      SqueezePalette.shared.setUndo(canUndo: model.canUndo, canRedo: model.canRedo)
      let strokes = model.direction?.bool("hidden") == true ? nil : intent.strokes
      SqueezePalette.shared.update(
        tools: toolItems, active: tools.active(model.activeTool),
        direction: strokes.map { .init(inverted: $0.inverted, add: $0.addName, subtract: $0.subtractName,
                                      addSymbol: $0.addSymbol, subtractSymbol: $0.subtractSymbol) },
        chooseTool: { WM_apple_ios_ui_tool_set_by_id($0.id) },
        setDirection: { [intent] inverted in intent.choose(inverted ? .subtract : .add) })
      let tools = tools, brushes = brushes
      let animation: Animation? = UIAccessibility.isReduceMotionEnabled ? nil :
        .spring(response: 0.32, dampingFraction: 0.84)
      SqueezePalette.shared.showAll = {
        withAnimation(animation) {
          if brushItems.isEmpty { tools.expanded = true } else { brushes.docked = true }
        }
      }
      if !brushItems.isEmpty {
        SqueezePalette.shared.brush = model.brush
        SqueezePalette.shared.update(items: brushItems, active: model.brushes?.string("active") ?? "",
                                     brushes: true) { item in
          WM_apple_ios_ui_brush_activate(item.id)
        }
      }
      else {
        SqueezePalette.shared.update(items: toolItems, active: tools.active(model.activeTool),
                                     brushes: false) { item in
          WM_apple_ios_ui_tool_set_by_id(item.id)
        }
      }
    }
#endif
  }

  /** A small grabber at the top of the sidebar, as the rails have: dragged, it moves the sidebar
   * up or down its edge, where it stays. */
  private func sidebarHandle(_ layout: RailLayout, content: SidebarContent) -> some View {
    Capsule()
      .fill(Color.secondary)
      .frame(width: 24, height: 5)
      .frame(width: PaintSidebar.width, height: 6 + content.handle)
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
        .onChanged { value in
          let start = sidebarDragStart ?? layout.sidebarCenter.y - content.height / 2
          if sidebarDragStart == nil { Haptics.selection() }
          sidebarDragStart = start
          let travel = layout.sidebarTravel
          let y = min(max(start + value.translation.height, travel.lowerBound), travel.upperBound)
          let span = travel.upperBound - travel.lowerBound
          sidebarPosition = span > 0 ? Double((y - travel.lowerBound) / span) : 0.5
        }
        .onEnded { _ in sidebarDragStart = nil })
      .hoverEffect(.highlight)
      .accessibilityLabel("Move Sidebar")
      .accessibilityAdjustableAction { direction in
        sidebarPosition = min(1, max(0, (sidebarPosition >= 0 ? sidebarPosition : 0.5) +
                                       (direction == .increment ? -0.1 : 0.1)))
      }
  }

  @ViewBuilder
  private func railLabel(safe: CGRect, layout: RailLayout, frame: CGRect, size: CGSize) -> some View {
    if let text = label.text {
      /* Items' frames are in the window's coordinates; these controls may sit lower and drawn
       * smaller, as on the Mac. */
      let itemY = frame.height > 0 ? (label.anchor.midY - frame.minY) * size.height / frame.height :
                                     label.anchor.midY
      let bounds = safe.insetBy(dx: 8, dy: 8)
      /* Beside the rail, towards the viewport, level with the item, within the window. */
      let brush = label.rail === brushes
      let railEdge = brush ? layout.brushEdge : layout.toolEdge
      if railEdge.horizontal {
        /* Below a row along the top, above one along the bottom, centered on the item. */
        let itemX = frame.width > 0 ? (label.anchor.midX - frame.minX) * size.width / frame.width : label.anchor.midX
        let center = brush ? layout.brushCenter : layout.toolCenter
        let toward: CGFloat = railEdge == .top ? 1 : -1
        Text(text)
          .font(.subheadline)
          .foregroundStyle(.primary)
          .lineLimit(1)
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .panelGlass(in: Capsule())
          .fixedSize()
          .position(x: min(max(itemX, bounds.minX + 60), bounds.maxX - 60), y: center.y + toward * (32 + 10 + 18))
          .allowsHitTesting(false)
          .accessibilityIdentifier("blender.toolbar.tool-name")
          .transition(.opacity.combined(with: .offset(y: -5 * toward)))
      }
      else {
        let toward = railEdge == .trailing ? -1.0 : 1.0
        let edge = brush ? layout.brushCenter.x + toward * layout.brushWidth / 2 :
                           layout.toolCenter.x + toward * layout.toolWidth / 2
        let x = edge + toward * 10
        let width = max(44, toward > 0 ? bounds.maxX - x : x - bounds.minX)
        Text(text)
          .font(.subheadline)
          .foregroundStyle(.primary)
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .panelGlass(in: Capsule())
          .frame(maxWidth: width, alignment: toward > 0 ? .leading : .trailing)
          .frame(width: width, alignment: toward > 0 ? .leading : .trailing)
          .position(x: x + toward * width / 2, y: min(max(itemY, bounds.minY + 18), bounds.maxY - 18))
          .allowsHitTesting(false)
          .accessibilityIdentifier("blender.toolbar.tool-name")
          .transition(.opacity.combined(with: .offset(x: -5 * toward)))
      }
    }
  }
}

/* -------------------------------------------------------------------- */
/** \name Held + and -
 *
 * Held while tapping or dragging with the Pencil, as Shift and Ctrl would be. Where Blender
 * selects, + adds to the selection and - subtracts from it while held, for taps as well as box,
 * lasso and circle selection, and neither is on at rest.
 * Where Blender strokes brushes, they are the stroke's direction instead, and one is always on: a
 * tap picks it (the brush's own Direction, such as Inflate or Deflate, where it has one) and
 * holding the other strokes the other way while held.
 * \{ */

/** Symbols for which way strokes go: SF Symbols, or the app's own where the system has none, such as
 * "bulge.out" and "bulge.in", sculpting adding to the surface or carving into it. */
enum DirectionSymbol {
  static func image(_ name: String) -> UIImage? { UIImage(systemName: name) ?? UIImage(named: name) }

  static func view(_ name: String) -> Image {
    UIImage(systemName: name) == nil ? Image(name) : Image(systemName: name)
  }
}

enum SelectIntent: Int {
  case none = 0, add = 1, subtract = 2
}

@MainActor
@Observable
final class SelectIntentState {
  /** Blender's stroke direction in modes that paint with brushes, or none where it selects. */
  struct Strokes: Equatable {
    /** The brush has a Direction of its own, which taps set. */
    var brush: Bool
    var inverted: Bool
    var addName: String
    var subtractName: String
    var addSymbol: String
    var subtractSymbol: String
  }

  /** The one shown on. */
  private(set) var active: SelectIntent = .none
  /** The Smooth button is held: strokes smooth, as with Shift, until it is let go. */
  var smoothing = false {
    didSet { if smoothing != oldValue { apply() } }
  }
  private(set) var strokes: Strokes?
  @ObservationIgnored private var held: SelectIntent = .none
  @ObservationIgnored private var pressed = Date.distantPast
  /** Without a Direction of its own, strokes go the other way while this is set. */
  @ObservationIgnored private var strokesInverted = false
  /** A direction just tapped, shown until Blender's brush follows. */
  @ObservationIgnored private var pendingInverted: (value: Bool, until: Date)?

  func update(strokes json: JSON?) {
    let next = json.map {
      Strokes(brush: $0.bool("brush"), inverted: $0.bool("inverted"),
              addName: $0.string("add") ?? "Add", subtractName: $0.string("subtract") ?? "Subtract",
              addSymbol: $0.string("addSymbol") ?? "arrowshape.up",
              subtractSymbol: $0.string("subtractSymbol") ?? "arrowshape.down")
    }
    if let pending = pendingInverted, next?.inverted == pending.value || Date() > pending.until {
      pendingInverted = nil
    }
    if (next == nil) != (strokes == nil) {
      /* Selecting and stroking each start at rest. */
      held = .none
      strokesInverted = false
      pendingInverted = nil
    }
    guard next != strokes else { return }
    strokes = next
    apply()
  }

  func press(_ intent: SelectIntent) {
    held = intent
    pressed = Date()
    apply()
    Haptics.impact(.light)
  }

  func release(_ intent: SelectIntent) {
    guard held == intent else { return }
    held = .none
    if strokes != nil && Date().timeIntervalSince(pressed) < 0.3 {
      choose(intent)
    }
    apply()
  }

  /** What a tap does when stroking: pick the direction. */
  func choose(_ intent: SelectIntent) {
    if let strokes {
      let inverted = intent == .subtract
      if strokes.brush {
        pendingInverted = (inverted, Date().addingTimeInterval(1))
        Engine.setting("brush_direction", inverted ? "subtract" : "add")
      }
      else {
        strokesInverted = inverted
      }
    }
    apply()
  }

  func clear() {
    held = .none
    strokesInverted = false
    apply()
  }

  private func apply() {
    let intent: SelectIntent
    if let strokes {
      let inverted = strokes.brush ? (pendingInverted?.value ?? strokes.inverted) : strokesInverted
      let resting: SelectIntent = inverted ? .subtract : .add
      active = held == .none ? resting : held
      /* The brush strokes its own way at rest, once it has the direction just tapped. */
      if held != .none { intent = held }
      else if strokes.brush { intent = pendingInverted == nil ? .none : resting }
      else { intent = strokesInverted ? .subtract : .none }
    }
    else {
      active = held
      intent = held
    }
    WM_apple_ios_ui_select_intent_set(smoothing ? 3 : Int32(intent.rawValue))
  }
}

#if !os(visionOS)
/** What squeezing Apple Pencil Pro shows, see the iPad page of Settings: the system's tool palette
 * by the Pencil, as drawing apps have it, or the Pencil's radial menu. GHOST reads it too. */
enum PencilSqueeze {
  static let key = "BlenderPencilSqueeze"
  static var showsPalette: Bool { UserDefaults.standard.string(forKey: key) != "menu" }
}

/** The system's tool palette, which a squeeze of Apple Pencil Pro shows by the Pencil anywhere in
 * the window, with Blender's brushes or tools as its items: choosing one makes it active. */
@available(iOS 26.0, *)
@MainActor
final class SqueezePalette: NSObject, PKToolPickerObserver {
  static let shared = SqueezePalette()

  private var picker: PKToolPicker?
  private var ids: [String] = []
  private var choose: ((RailItem) -> Void)?
  private var items: [RailItem] = []
  /** Set here from Blender, not chosen in the palette. */
  private var following = false
  /** When the palette was last made: a new one selects its first item by itself, which is not a
   * choice, and reports it a moment later. */
  private var builtAt = Date.distantPast
  private var observer: NSObjectProtocol?

  private override init() {
    super.init()
    observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                      object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { SqueezePalette.shared.attach() }
    }
  }


  /** The brush's values from Blender, which the palette's width, opacity and color set: its size,
   * strength and color. Null where Blender selects with tools rather than painting with brushes. */
  var brush: JSON? {
    didSet {
      SqueezeBrushState.shared.brush = brush
      /* A brush that paints with a color now, or no longer: the palette offers it, or not. */
      if (brush?["color"] != nil) != paints { rebuild?() }
      followBrush()
    }
  }
  /** The last update again, for the brush's color to come or go. */
  private var rebuild: (() -> Void)?
  /** The palette's widths, the brush sizes it offers, in pixels. */
  private static let widths: [CGFloat] = [8, 20, 40, 80, 160]
  /** Its items are brushes, with their options. */
  private var brushes = false
  private var builtForBrushes = false

  /** The active one and the two used before it, as few as the palette's arc holds without
   * crowding; its button beside them shows all of them. */
  private static let capacity = 3
  /** Opens the rail with all of them. */
  var showAll: (() -> Void)?
  /** Presents Blender's settings. */
  var showSettings: (() -> Void)?

  /** The palette's More button: all the brushes or tools, Blender's commands for what is
   * selected, as its context menu lists them, and Settings. */
  private func moreMenu() -> UIMenu {
    /* The tools, and the stroke's direction, as rows of icons at the top, as of the moment it
     * opens. */
    let current = UIDeferredMenuElement.uncached { completion in
      MainActor.assumeIsolated { completion(SqueezePalette.shared.toolRows()) }
    }
    let all = UIAction(title: brushes ? "All Tools and Brushes" : "All Tools",
                       image: UIImage(systemName: "square.grid.2x2")) { _ in
      MainActor.assumeIsolated { SqueezePalette.shared.expand() }
    }
    let commands = UIDeferredMenuElement.uncached { completion in
      Task { @MainActor in
        let items = await BlenderMenus.shared.fetch(BlenderMenus.contextRoute) ?? []
        completion(items.isEmpty ? [] : [BlenderMenus.uiMenu(items)])
      }
    }
    let settings = UIAction(title: "Settings", image: UIImage(systemName: "gearshape")) { _ in
      MainActor.assumeIsolated { SqueezePalette.shared.showSettings?() }
    }
    return UIMenu(children: [current, UIMenu(options: .displayInline, children: [all]), commands,
                             UIMenu(options: .displayInline, children: [settings])])
  }

  private func toolRows() -> [UIMenuElement] {
    var rows: [UIMenuElement] = []
    if brushes, !tools.isEmpty {
      rows.append(UIMenu(title: "Tools", options: [.displayInline, .displayAsPalette], children: tools.map { tool in
        UIAction(title: tool.title, image: tool.image.map { Self.fitted($0, side: 26) },
                 state: tool.id == activeTool ? .on : .off) { _ in
          MainActor.assumeIsolated { SqueezePalette.shared.chooseTool?(tool) }
        }
      }))
    }
    if let direction {
      let choice = { (inverted: Bool, title: String, symbol: String) in
        UIAction(title: title, image: DirectionSymbol.image(symbol),
                 state: direction.inverted == inverted ? .on : .off) { _ in
          MainActor.assumeIsolated { SqueezePalette.shared.setDirection?(inverted) }
        }
      }
      rows.append(UIMenu(title: "Direction", options: [.displayInline, .displayAsPalette], children: [
        choice(false, direction.add, direction.addSymbol), choice(true, direction.subtract, direction.subtractSymbol),
      ]))
    }
    return rows
  }

  /** Blender's undo, for the palette's own Undo and Redo buttons, which use the first
   * responder's undo manager. */
  private final class BlenderUndo: UndoManager {
    var undoable = false
    var redoable = false
    override var canUndo: Bool { undoable }
    override var canRedo: Bool { redoable }
    override func undo() { Engine.operatorCall("ED_OT_undo") }
    override func redo() { Engine.operatorCall("ED_OT_redo") }
  }
  private let undo = BlenderUndo()

  func setUndo(canUndo: Bool, canRedo: Bool) {
    guard canUndo != undo.undoable || canRedo != undo.redoable else { return }
    undo.undoable = canUndo
    undo.redoable = canRedo
    /* The palette checks again when told the undo manager changed. */
    NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: undo)
  }
  /** The brushes or tools used last, most recent first. */
  private var recent: [String] {
    get { UserDefaults.standard.stringArray(forKey: "BlenderSqueezeRecent." + (brushes ? "brushes" : "tools")) ?? [] }
    set { UserDefaults.standard.set(Array(newValue.prefix(Self.capacity)),
                                    forKey: "BlenderSqueezeRecent." + (brushes ? "brushes" : "tools")) }
  }

  /** The tool items' identifiers, apart from the brushes'. */
  private static let toolPrefix = "tool:"
  /** The item that opens every tool and brush. */
  private static let allID = "show:all"
  /** Where it holds brushes, how many of the tools used last it shows beside them. */
  private static let toolCapacity = 2

  /** The tools used last, most recent first, kept beside the brushes. */
  private static var recentTools: [String] {
    get { UserDefaults.standard.stringArray(forKey: "BlenderSqueezeRecentTools") ?? [] }
    set { UserDefaults.standard.set(Array(newValue.prefix(4)), forKey: "BlenderSqueezeRecentTools") }
  }

  /** Every tool and brush, opened from the palette itself. */
  private func allItem() -> PKToolPickerItem {
    var configuration = PKToolPickerCustomItem.Configuration(identifier: Self.allID,
                                                            name: brushes ? "All Tools and Brushes" : "All Tools")
    let image = UIImage(systemName: "square.grid.2x2")!
    configuration.imageProvider = { _ in image }
    configuration.allowsColorSelection = false
    configuration.toolAttributeControls = []
    return PKToolPickerCustomItem(configuration: configuration)
  }
  /** Every brush, from which the recent are taken and which All shows. */
  private var allItems: [RailItem] = []
  /** Whether the brushes paint with a color, which the palette then offers. */
  private var paints = false

  func update(items all: [RailItem], active: String, brushes: Bool, choose: @escaping (RailItem) -> Void) {
    self.brushes = brushes
    allItems = all
    rebuild = { [weak self] in self?.update(items: all, active: active, brushes: brushes, choose: choose) }
    if !active.isEmpty, recent.first != active {
      recent = [active] + recent.filter { $0 != active }
    }
    /* The active one and those used last, then the first ones to fill, in the rail's order so
     * each keeps its place in the arc. */
    var chosen = Set(recent.filter { id in all.contains { $0.id == id } }.prefix(Self.capacity))
    for item in all where chosen.count < Self.capacity { chosen.insert(item.id) }
    let items = all.filter { chosen.contains($0.id) }
    self.items = items
    self.choose = choose
    /* Painting, the tools used last too, the active one first, before the brushes: both shown,
     * as the rails show them; then the item that shows all. */
    let toolIDs = brushes ? ([activeTool] + Self.recentTools.filter { $0 != activeTool }) : []
    let shownTools = toolIDs.compactMap { id in tools.first { $0.id == id } }.prefix(Self.toolCapacity)
    let ids = shownTools.map { Self.toolPrefix + $0.id } + items.map(\.id) + [Self.allID]
    /* The color is a list of its channels. */
    let paints = brush?["color"] != nil
    if ids != self.ids || picker == nil || brushes != builtForBrushes || paints != self.paints {
      self.ids = ids
      builtForBrushes = brushes
      self.paints = paints
      picker?.removeObserver(self)
      let toolItems = shownTools.map { toolItem($0) } +
        items.map { brushes ? brushItem($0) : toolItem($0, prefixed: false) } + [allItem()]
      guard !toolItems.isEmpty else { return }
      let picker = PKToolPicker(toolItems: toolItems)
      builtAt = Date()
      picker.accessoryItem = UIBarButtonItem(title: "More", image: nil, menu: moreMenu())
      picker.showsDrawingPolicyControls = false
      picker.addObserver(self)
      self.picker = picker
    }
    followSelection()
    followBrush()
    followTool()
    attach()
  }

  /** A brush in the palette: tapped again, its size, strength, direction and color. */
  private func brushItem(_ item: RailItem) -> PKToolPickerItem {
    var configuration = PKToolPickerCustomItem.Configuration(identifier: item.id, name: item.title)
    let image = item.image ?? UIImage(systemName: "circle")!
    configuration.imageProvider = { _ in image }
    configuration.widthVariants = Self.widthVariants(image)
    configuration.defaultWidth = Self.widths[2]
    /* Blender's own options above the system's, which then show only the color, where the
     * brush paints with one. */
    configuration.toolAttributeControls = []
    configuration.allowsColorSelection = paints
    configuration.defaultColor = paints ? .black : .label
    configuration.viewControllerProvider = { _ in
      MainActor.assumeIsolated {
        let options = UIHostingController(rootView: SqueezeBrushOptions())
        options.sizingOptions = .preferredContentSize
        options.view.backgroundColor = .clear
        return options
      }
    }
    return PKToolPickerCustomItem(configuration: configuration)
  }

  /** A tool in the palette, as the tool rail shows it. */
  private func toolItem(_ item: RailItem, prefixed: Bool = true) -> PKToolPickerItem {
    var configuration = PKToolPickerCustomItem.Configuration(
      identifier: (prefixed ? Self.toolPrefix : "") + item.id, name: item.title)
    let image = item.image ?? UIImage(systemName: "circle")!
    configuration.imageProvider = { _ in image }
    configuration.allowsColorSelection = false
    configuration.toolAttributeControls = []
    return PKToolPickerCustomItem(configuration: configuration)
  }

  /** The palette on what Blender has: the brush while the tool paints with brushes, or else the
   * tool. */
  private func followSelection() {
    let tool = ids.contains(Self.toolPrefix + activeTool)
    let selected = brushes && !activeTool.contains("brush") && tool ? Self.toolPrefix + activeTool :
      (brushes ? RollDial.shared.activeBrush ?? "" : activeTool)
    guard let picker, ids.contains(selected), picker.selectedToolItemIdentifier != selected else { return }
    following = true
    picker.selectedToolItemIdentifier = selected
    following = false
  }

  /** Every tool, those of each group too, and every brush, in a sheet: the palette's arc holds
   * only a few. */
  private func expand() {
    guard let window = holder.window, var top = window.rootViewController else { return }
    while let presented = top.presentedViewController { top = presented }
    guard !(top is UIHostingController<SqueezeAllView>) else { return }
    /* Each tool of a group, as its menu on the rail lists them. */
    var seen = Set<String>()
    let everyTool = tools.flatMap { $0.grouped ? $0.group : [$0] }.filter { seen.insert($0.id).inserted }
    let brushItems = brushes ? allItems : []
    let view = SqueezeAllView(
      tools: brushes ? everyTool : allItems.flatMap { $0.grouped ? $0.group : [$0] },
      brushes: brushItems, activeTool: activeTool, activeBrush: brushes ? RollDial.shared.activeBrush : nil,
      chooseTool: { [weak self] tool in
        guard let self else { return }
        if brushes { chooseTool?(tool) } else { choose?(tool) }
      },
      chooseBrush: { [weak self] brush in self?.choose?(brush) })
    let sheet = UIHostingController(rootView: view)
    sheet.modalPresentationStyle = .formSheet
    if let controller = sheet.sheetPresentationController {
      controller.detents = [.medium(), .large()]
      controller.prefersGrabberVisible = true
    }
    top.present(sheet, animated: true)
  }

  /** Where the palette holds brushes, the tool they paint with, to see and change beside them,
   * and which way they stroke. */
  private var tools: [RailItem] = []
  private var activeTool = ""
  private var chooseTool: ((RailItem) -> Void)?
  struct Direction: Equatable {
    var inverted: Bool
    var add: String
    var subtract: String
    var addSymbol: String
    var subtractSymbol: String
  }
  private var direction: Direction?
  private var setDirection: ((Bool) -> Void)?

  func update(tools: [RailItem], active: String, direction: Direction?,
              chooseTool: @escaping (RailItem) -> Void, setDirection: @escaping (Bool) -> Void) {
    self.tools = tools
    activeTool = active
    if !active.isEmpty {
      let recent = Self.recentTools
      if recent.first != active { Self.recentTools = [active] + recent.filter { $0 != active } }
    }
    self.direction = direction
    self.chooseTool = chooseTool
    self.setDirection = setDirection
    SqueezeBrushState.shared.direction = direction
    SqueezeBrushState.shared.setDirection = setDirection
    followTool()
  }

  /** The palette's button shows the active tool where its items are brushes, or More. */
  private func followTool() {
    guard let accessory = picker?.accessoryItem else { return }
    let tool = brushes ? tools.first { $0.id == activeTool } : nil
    let image = tool?.image.map { Self.fitted($0, side: 26) } ?? Self.more
    if accessory.image !== image { accessory.image = image }
    accessory.accessibilityLabel = tool?.title ?? "More"
  }

  private static let more = UIImage(systemName: "ellipsis.circle")
  private static var fittedCache: [ObjectIdentifier: UIImage] = [:]
  private static func fitted(_ image: UIImage, side: CGFloat) -> UIImage {
    if let cached = fittedCache[ObjectIdentifier(image)] { return cached }
    let result = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
      image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
    }.withRenderingMode(image.renderingMode)
    fittedCache[ObjectIdentifier(image)] = result
    return result
  }

  /** The palette shows an item by its width's image, and its width choices by theirs: the
   * brush's own preview for each, smaller for the thinner ones. */
  private static func widthVariants(_ image: UIImage) -> [CGFloat: UIImage] {
    let side = max(image.size.width, image.size.height, 1)
    return Dictionary(uniqueKeysWithValues: widths.enumerated().map { index, width in
      let scale = 0.6 + 0.4 * CGFloat(index) / CGFloat(widths.count - 1)
      let inset = side * (1 - scale) / 2
      let variant = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
        image.draw(in: CGRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset))
      }
      return (width, variant)
    })
  }

  /** The palette's item showing the brush as Blender has it: its size as the nearest width, its
   * strength as opacity, and its color. */
  private func followBrush() {
    guard brushes, let item = picker?.selectedToolItem as? PKToolPickerCustomItem else { return }
    following = true
    defer { following = false }
    if let json = brush?.dict("size"), let size = json.double("value") {
      let width: CGFloat
      if json.bool("pixels") {
        width = Self.widths.min { abs(Double($0) - size) < abs(Double($1) - size) } ?? Self.widths[2]
      }
      else {
        /* A size in the scene, such as Grease Pencil's: its place along its range. */
        let low = max(1e-4, json.double("min") ?? 1e-3), high = max(low * 1.01, json.double("max") ?? 1)
        let t = min(1, max(0, log(max(size, low) / low) / log(high / low)))
        width = Self.widths[Int((t * Double(Self.widths.count - 1)).rounded())]
      }
      if item.width != width { item.width = width }
    }
    var color = item.color
    if let rgb = (brush?["color"] as? [NSNumber])?.map({ CGFloat($0.doubleValue) }), rgb.count >= 3 {
      color = UIColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
    }
    color = color.withAlphaComponent(1)
    /* Only a real change: setting it again as Blender echoes what the palette sent would reset
     * its width and opacity controls while they are being used. */
    if !Self.same(item.color, color) { item.color = color }
  }

  private static func same(_ a: UIColor, _ b: UIColor) -> Bool {
    func rgba(_ color: UIColor) -> [CGFloat] {
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
      color.getRed(&r, green: &g, blue: &b, alpha: &alpha)
      return [r, g, b, alpha]
    }
    return zip(rgba(a), rgba(b)).allSatisfy { abs($0 - $1) < 0.01 }
  }

  /** The system finds the palette from the first responder, which nothing else in the window is
   * while no text is typed, and shows it for a squeeze through PencilKit's own canvas: this
   * empty, invisible canvas behind everything is both, holding the palette, hidden until a
   * squeeze shows it, while Settings has the palette for squeezing. It never draws or takes a
   * touch. */
  private final class Holder: PKCanvasView {
    var blenderUndo: UndoManager?
    override var canBecomeFirstResponder: Bool { true }
    override var undoManager: UndoManager? { blenderUndo }
  }
  private lazy var holder: Holder = {
    let view = Holder(frame: .zero)
    view.blenderUndo = undo
    /* Enabled, for its Pencil interaction, but behind all of Blender's views, which take every
     * touch. */
    view.isOpaque = false
    view.backgroundColor = .clear
    view.drawingPolicy = .pencilOnly
    view.isScrollEnabled = false
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    return view
  }()
  private var keyboardObserver: NSObjectProtocol?

  func attach() {
    guard let window = UIApplication.shared.connectedScenes
      .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
    else { return }
    if holder.window !== window {
      holder.removeFromSuperview()
      holder.frame = window.bounds
      window.insertSubview(holder, at: 0)
    }
    if keyboardObserver == nil {
      /* Back as the first responder once typing ends. */
      keyboardObserver = NotificationCenter.default.addObserver(
        forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { _ in
          MainActor.assumeIsolated { SqueezePalette.shared.attach() }
        }
    }
    let state = holder.pencilKitResponderState
    if PencilSqueeze.showsPalette, let picker {
      if state.activeToolPicker !== picker { state.activeToolPicker = picker }
      state.toolPickerVisibility = ProcessInfo.processInfo.environment["DEBUGPALETTE"] != nil ? .visible : .hidden
      if !holder.isFirstResponder && !Self.typing(in: window) { holder.becomeFirstResponder() }
    }
    else {
      state.toolPickerVisibility = .inactive
      state.activeToolPicker = nil
      if holder.isFirstResponder { holder.resignFirstResponder() }
    }
  }

  /** A text field or view has the keyboard, which the palette must not take. */
  private static func typing(in view: UIView) -> Bool {
    if view.isFirstResponder && view is UIKeyInput { return true }
    return view.subviews.contains { typing(in: $0) }
  }

  nonisolated func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
    MainActor.assumeIsolated {
      guard !following, let id = toolPicker.selectedToolItem.identifier as String? else { return }
      /* Only what is picked in it, never what a palette selects on its own: a new one picks its
       * first item while out of sight, which would change the tool picked in Blender. Back to
       * Blender's then. */
      guard toolPicker === picker, toolPicker.isVisible, Date().timeIntervalSince(builtAt) > 0.3 else {
        followSelection()
        return
      }
      if id == Self.allID {
        /* Not a tool: the palette back on what was picked, and every tool and brush open. */
        followSelection()
        holder.pencilKitResponderState.toolPickerVisibility = .hidden
        expand()
        return
      }
      if id.hasPrefix(Self.toolPrefix) {
        let toolID = String(id.dropFirst(Self.toolPrefix.count))
        if toolID != activeTool, let tool = tools.first(where: { $0.id == toolID }) { chooseTool?(tool) }
        return
      }
      guard let item = allItems.first(where: { $0.id == id }) else { return }
      let active = brushes ? brush.flatMap { _ in RollDial.shared.activeBrush } : nil
      if !brushes || active != id {
        choose?(item)
        return
      }
      /* The same brush with its color changed in the palette; its size and strength are set in
       * Blender's own options above it. */
      guard let custom = toolPicker.selectedToolItem as? PKToolPickerCustomItem, brush?["color"] != nil else { return }
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
      custom.color.getRed(&r, green: &g, blue: &b, alpha: &a)
      sendBrushValue("color", [r, g, b].map { min(1, max(0, Double($0))) }, commit: true)
    }
  }
}
#endif

#if !os(visionOS)
/** The brush as the squeeze palette's options show it, following Blender. */
@available(iOS 26.0, *)
@MainActor
@Observable
final class SqueezeBrushState {
  static let shared = SqueezeBrushState()
  var brush: JSON?
  var direction: SqueezePalette.Direction?
  @ObservationIgnored var setDirection: ((Bool) -> Void)?
}

/** Tapping the brush in use in the squeeze palette: its size and strength, and in modes that
 * stroke both ways, Add or Subtract, above the palette's own color. */
@available(iOS 26.0, *)
struct SqueezeBrushOptions: View {
  private var state: SqueezeBrushState { SqueezeBrushState.shared }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if let size = state.brush?.dict("size") {
        let pixels = size.bool("pixels")
        OptionSlider(title: size.string("label") ?? "Radius", key: "size", json: size, logarithmic: true) {
          pixels ? "\(Int($0.rounded())) px" : String(format: "%.3g m", $0)
        }
      }
      if let strength = state.brush?.dict("strength") {
        OptionSlider(title: "Strength", key: "strength", json: strength, logarithmic: false) {
          "\(Int(($0 * 100).rounded()))%"
        }
      }
      if let direction = state.direction {
        Picker("Direction", selection: Binding(get: { direction.inverted }, set: { state.setDirection?($0) })) {
          Label { Text(direction.add) } icon: { DirectionSymbol.view(direction.addSymbol) }.tag(false)
          Label { Text(direction.subtract) } icon: { DirectionSymbol.view(direction.subtractSymbol) }.tag(true)
        }
        .pickerStyle(.segmented)
      }
    }
    .padding(16)
    .frame(width: 300)
  }
}

/** Every tool and brush, from the squeeze palette, whose arc holds only a few: tapped, one is
 * picked and the sheet closes. */
@available(iOS 26.0, *)
struct SqueezeAllView: View {
  let tools: [RailItem]
  let brushes: [RailItem]
  let activeTool: String
  let activeBrush: String?
  let chooseTool: (RailItem) -> Void
  let chooseBrush: (RailItem) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if !tools.isEmpty {
            section(brushes.isEmpty ? nil : "Tools", items: tools, brush: false) { item in
              item.id == activeTool
            } choose: { chooseTool($0) }
          }
          /* The brushes by catalog, as the rail separates them. */
          ForEach(Array(catalogs.enumerated()), id: \.offset) { index, catalog in
            section(index == 0 ? "Brushes" : nil, items: catalog, brush: true) { $0.id == activeBrush } choose: {
              chooseBrush($0)
            }
          }
        }
        .padding(20)
      }
      .navigationTitle(brushes.isEmpty ? "Tools" : "Tools and Brushes")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", systemImage: "checkmark") { dismiss() }
        }
      }
    }
  }

  private var catalogs: [[RailItem]] {
    var result: [[RailItem]] = []
    for brush in brushes {
      if brush.gapBefore || result.isEmpty { result.append([]) }
      result[result.count - 1].append(brush)
    }
    return result
  }

  private func section(_ title: String?, items: [RailItem], brush: Bool, selected: @escaping (RailItem) -> Bool,
                       choose: @escaping (RailItem) -> Void) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if let title {
        Text(title).font(.headline)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
        ForEach(items) { item in
          let on = selected(item)
          Button {
            choose(item)
            Haptics.selection()
            dismiss()
          } label: {
            VStack(spacing: 6) {
              if let image = on ? item.selectedImage ?? item.image : item.image {
                Image(uiImage: image)
                  .renderingMode(image.renderingMode == .alwaysOriginal || brush ? .original : .template)
                  .resizable()
                  .scaledToFit()
                  .frame(width: brush ? 48 : 30, height: brush ? 48 : 30)
                  .frame(height: 48)
              }
              Text(item.title)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
              if on {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)
              }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(on ? .isSelected : [])
        }
      }
    }
  }
}

/** One of the brush's values: dragged, Blender follows at once; let go, one undo step. */
@available(iOS 26.0, *)
private struct OptionSlider: View {
  let title: String
  let key: String
  let json: JSON
  let logarithmic: Bool
  let format: (Double) -> String
  @State private var dragging: Double?

  private var low: Double { max(logarithmic ? 0.001 : 0, json.double("min") ?? 0) }
  private var high: Double { max(low + 0.001, min(logarithmic ? 1000 : 1, json.double("max") ?? 1)) }

  private func position(_ value: Double) -> Double {
    logarithmic ? log(max(low, value) / low) / log(high / low) : (value - low) / (high - low)
  }

  private func value(_ position: Double) -> Double {
    logarithmic ? low * pow(high / low, position) : low + (high - low) * position
  }

  var body: some View {
    let current = dragging ?? json.double("value") ?? low
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title).font(.subheadline)
        Spacer()
        Text(format(current)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
      }
      Slider(value: Binding(get: { position(current) }, set: { position in
        let next = value(position)
        dragging = next
        sendBrushValue(key, next, commit: false)
      }), in: 0...1) { editing in
        if !editing, let dragging {
          sendBrushValue(key, dragging, commit: true)
          self.dragging = nil
        }
      }
    }
  }
}
#endif

/** The barrel roll of a Pencil on the screen, anywhere in the window, for dials to turn with. */
@MainActor
@Observable
final class PencilRoll {
  static let shared = PencilRoll()

  /** A Pencil touches the screen. */
  private(set) var down = false
  /** How far it has rolled since it touched down, in radians, past a half turn too. */
  private(set) var turned: Double = 0
  /** Where it touches, in the window; only the color dial reads it, while it shows. */
  private(set) var point = CGPoint.zero
  @ObservationIgnored private var last: Double?
  @ObservationIgnored private var observer: NSObjectProtocol?

  private init() {
    observer = NotificationCenter.default.addObserver(forName: Notification.Name("BlenderPencilRoll"),
                                                      object: nil, queue: .main) { note in
      let info = note.userInfo
      let down = (info?["down"] as? Bool) ?? false
      let began = (info?["began"] as? Bool) ?? false
      let angle = (info?["angle"] as? Double) ?? 0
      let point = CGPoint(x: (info?["x"] as? Double) ?? 0, y: (info?["y"] as? Double) ?? 0)
      MainActor.assumeIsolated {
        PencilRoll.shared.update(down: down, began: began, angle: angle, point: point)
      }
    }
  }

  /** Started early, so the first Pencil touch is seen. */
  static func start() { _ = shared }

  private func update(down: Bool, began: Bool, angle: Double, point: CGPoint) {
    defer {
      if down {
        if self.point != point { self.point = point }
        RollDial.shared.pencilMoved(to: point, began: began)
        ColorRoll.shared.pencilMoved(to: point, began: began)
      }
    }
    guard down else {
      /* The roll stays as it was: whatever ends with the lift still reads where it got to. */
      if self.down {
        self.down = false
        RollDial.shared.pencilLifted()
        ColorRoll.shared.pencilLifted()
      }
      last = nil
      return
    }
    if let last {
      let delta = atan2(sin(angle - last), cos(angle - last))
      if delta != 0 { turned += delta }
    }
    last = angle
    if !self.down { self.down = true }
  }
}

/** Items fanned out around a Pencil holding a rail or the tool settings: rolling the Pencil turns
 * the fan through them, and lifting it chooses the one in front. */
@MainActor
@Observable
final class RollDial {
  static let shared = RollDial()
  /** The roll from one item to the next. */
  static let step = Double.pi / 9

  /** Tools of the active mode, and the active one, for the dial over the tool settings; the active
   * brush too. */
  @ObservationIgnored var tools: [RailItem] = []
  @ObservationIgnored var activeTool = ""
  @ObservationIgnored var activeBrush: String?

  /** A rail a Pencil can roll on at once, without holding first. */
  struct Zone {
    var frame: CGRect
    var items: [RailItem]
    var active: String
    /** Where a chosen item sits on the rail, for the dial to land there. */
    var landing: (RailItem) -> CGRect?
    var choose: (RailItem) -> Void
  }
  @ObservationIgnored private var zones: [String: Zone] = [:]
  /** A Pencil came down on a rail: rolling a little opens its dial; moving away or lifting first
   * leaves it a tap or a scroll. */
  @ObservationIgnored private var armed: (zone: Zone, point: CGPoint, roll: Double)?
  /** Just closed: the tap the Pencil's lift makes on the rail is not one. */
  @ObservationIgnored private var closedAt = Date.distantPast
  /** How far a Pencil on a rail rolls before its dial opens. */
  static let openingRoll = Double.pi / 45

  func setZone(_ id: String, _ zone: Zone?) { zones[id] = zone }

  var justClosed: Bool { Date().timeIntervalSince(closedAt) < 0.6 }

  func pencilMoved(to point: CGPoint, began: Bool) {
    if center != nil {
      /* Open: a Pencil that can't roll turns it by moving along it instead. */
      drag(to: point)
      return
    }
    if began {
      armed = nil
      guard center == nil, let zone = zones.values.first(where: { $0.frame.contains(point) }) else { return }
      armed = (zone, point, PencilRoll.shared.turned)
      return
    }
    guard let armed, center == nil else { return }
    /* A Pencil drifts a little as it rolls: only a clear move is a scroll or a slide. */
    if hypot(point.x - armed.point.x, point.y - armed.point.y) > 24 {
      /* Moving: a scroll or a slide along the rail, not a roll. */
      self.armed = nil
      return
    }
    if abs(PencilRoll.shared.turned - armed.roll) > Self.openingRoll {
      self.armed = nil
      begin(items: armed.zone.items, active: armed.zone.active, at: armed.point,
            landing: armed.zone.landing, choose: armed.zone.choose)
      origin = armed.roll
    }
  }

  private(set) var items: [RailItem] = []
  /** Where the Pencil holds it, in the window, while it shows. */
  private(set) var center: CGPoint?
  private(set) var start = 0
  /** The roll as the dial opened. */
  @ObservationIgnored private(set) var origin: Double = 0
  @ObservationIgnored private var choose: ((RailItem) -> Void)?
  /** Chosen as the Pencil lifted: shown a moment, then the dial goes. */
  private(set) var confirmed: Int?
  /** Grown out of the button the Pencil holds, to its full size. */
  private(set) var grown = false
  /** Where the chosen item lands as the dial folds into what it came from, in the window. */
  private(set) var landed: CGRect?
  @ObservationIgnored private var landingFrame: ((RailItem) -> CGRect?)?

  /** How far the fan has been turned by moving along it, a Pencil or a finger, in items. */
  private(set) var dragged: Double = 0
  @ObservationIgnored private var lastDrag: CGPoint?
  /** Along the fan from one item to the next, in points, as the layer spaces them. */
  static let dragStep: CGFloat = 63

  /** Toward the middle of the window, where the fan opens, from its center. */
  var toward: Double {
    guard let center, let window = UIApplication.shared.connectedScenes
      .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
    else { return 0 }
    return atan2(Double(window.bounds.midY - center.y), Double(window.bounds.midX - center.x))
  }

  /** A Pencil or finger moved to \a point: along the fan, pulling the next item to the front. */
  func drag(to point: CGPoint) {
    guard center != nil, confirmed == nil else { return }
    if let lastDrag {
      let toward = self.toward
      /* Along the fan's track where it is in front; items further round come toward it. */
      let along = Double(point.x - lastDrag.x) * -sin(toward) + Double(point.y - lastDrag.y) * cos(toward)
      dragged -= along / Double(Self.dragStep)
    }
    lastDrag = point
  }

  func dragEnded() { lastDrag = nil }

  /** Where the fan has turned to, between items while rolling or dragged. */
  var position: Double {
    guard !items.isEmpty else { return 0 }
    if let confirmed { return Double(confirmed) }
    let turned = (PencilRoll.shared.turned - origin) / Self.step + dragged
    return min(Double(items.count - 1), max(0, Double(start) + turned))
  }

  /** The position as the fan shows it: held at each item until the roll is well on its way to the
   * next, then turning there quickly, so it clicks from one to the next. */
  var shownPosition: Double {
    let position = self.position
    let nearest = position.rounded()
    let off = position - nearest
    return nearest + 4 * off * off * off
  }

  var selected: Int { Int(position.rounded()) }

  func begin(items: [RailItem], active: String, at point: CGPoint,
             landing: ((RailItem) -> CGRect?)? = nil, choose: @escaping (RailItem) -> Void)
  {
    guard !items.isEmpty, center == nil else { return }
    self.items = items
    self.landingFrame = landing
    confirmed = nil
    landed = nil
    start = items.firstIndex { $0.id == active } ?? 0
    origin = PencilRoll.shared.turned
    dragged = 0
    lastDrag = nil
    self.choose = choose
    Haptics.impact(.light)
    /* Out of the button the Pencil holds: there first, then grown to its size. */
    grown = false
    center = point
    DispatchQueue.main.async {
      withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) { self.grown = true }
    }
  }

  /** Felt through the Pencil itself, as it clicks from one item to the next, and as one is
   * chosen; through the device too where it has haptics. */
  @ObservationIgnored private lazy var pencilFeedback: UICanvasFeedbackGenerator? = {
    guard let window = UIApplication.shared.connectedScenes
      .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
    else { return nil }
    return UICanvasFeedbackGenerator(view: window)
  }()

  func clicked() {
    if let center { pencilFeedback?.alignmentOccurred(at: center) }
    Haptics.selection()
  }

  /** A step felt through the Pencil at \a point in the window, such as a slider turned by rolling. */
  func pencilTick(at point: CGPoint) {
    pencilFeedback?.alignmentOccurred(at: point)
  }

  private func finish() {
    guard center == nil else { return }
    confirmed = nil
    landed = nil
  }

  /** The tools around a Pencil holding the tool settings. */
  func beginTools(at point: CGPoint) {
    begin(items: tools, active: activeTool, at: point) { item in
      WM_apple_ios_ui_tool_set_by_id(item.id)
    }
  }

  var showing: Bool { center != nil }

  /** The Pencil lifted: what held the dial may not see its hold end, as the rail beneath has
   * hidden, so the dial ends itself too. */
  func pencilLifted() {
    armed = nil
    guard center != nil, confirmed == nil else { return }
    DispatchQueue.main.async { self.end() }
  }

  func end() {
    guard center != nil, confirmed == nil else { return }
    let index = selected
    /* Where it will sit, read before choosing it changes the rail. */
    let target = items.indices.contains(index) ? landingFrame?(items[index]) : nil
    /* Chosen for real, as a tap on it would. */
    if items.indices.contains(index), index != start { choose?(items[index]) }
    choose = nil
    landingFrame = nil
    closedAt = Date()
    if let center { pencilFeedback?.pathCompleted(at: center) }
    Haptics.impact(.medium)
    withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) { confirmed = index }
    /* Then it folds into the rail: the chosen item flies to its place there, the rest after it,
     * and the rail shows again under it as it lands. */
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
      guard let target else {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) { self.center = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.finish() }
        return
      }
      withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) { self.landed = target }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { self.center = nil }
        self.finish()
      }
    }
  }
}

/** The fan of items around the Pencil, over the whole window, which dims behind it: the one in
 * front, large and named, is chosen on lifting. */
struct RollDialLayer: View {
  private var dial: RollDial { RollDial.shared }
  @State private var lastSelected = -1

  var body: some View {
    GeometryReader { proxy in
      let origin = proxy.frame(in: .global).origin
      ZStack {
        if let center = dial.center {
          Color.black.opacity(dial.landed == nil && dial.grown ? 0.18 : 0)
            .transition(.opacity)
          dialBody(local: CGPoint(x: center.x - origin.x, y: center.y - origin.y), size: proxy.size,
                   origin: origin)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .ignoresSafeArea()
    /* Open, a finger turns it too, dragged along it. */
    .contentShape(Rectangle())
    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
      .onChanged { dial.drag(to: $0.location) }
      .onEnded { _ in dial.dragEnded() })
    .allowsHitTesting(dial.showing)
    .onChange(of: dial.showing ? dial.selected : -1) { _, selected in
      if selected >= 0 && lastSelected >= 0 && selected != lastSelected { dial.clicked() }
      lastSelected = selected
    }
    .accessibilityHidden(true)
  }

  private func dialBody(local: CGPoint, size: CGSize, origin: CGPoint) -> some View {
    /* Fanned towards the middle of the window, so it stays on screen from a corner, a side or the
     * tool settings at the top. Items run clockwise from the one in front. */
    let toward = atan2(Double(size.height / 2 - local.y), Double(size.width / 2 - local.x))
    let position = dial.shownPosition
    let radius: CGFloat = 176
    /* Items 0.36 radians apart on it: RollDial.dragStep points along it. */
    /* Folding into the rail: everything goes to where the chosen item sits there. */
    let landing = dial.landed.map { CGPoint(x: $0.midX - origin.x, y: $0.midY - origin.y) }
    let landingScale = dial.landed.map { min($0.width, $0.height) / 60 } ?? 1
    let spacing = 0.36
    return ZStack {
      /* The dial's track, which the items turn along. */
      Circle()
        .stroke(.thinMaterial, lineWidth: 76)
        .frame(width: radius * 2, height: radius * 2)
        .shadow(color: .black.opacity(0.12), radius: 12)
        .scaleEffect(landing == nil && dial.grown ? 1 : 0.15)
        .opacity(landing == nil && dial.grown ? 1 : 0)
        .position(landing ?? local)
      /* Where the chosen one sits, still as the items turn under it. */
      Circle()
        .fill(Color.accentColor)
        .frame(width: 66, height: 66)
        .scaleEffect(landing != nil ? landingScale * 0.9 : dial.confirmed != nil ? 1.1 : 1)
        .opacity(landing == nil && dial.grown ? 1 : 0)
        .position(landing ?? (dial.grown ? CGPoint(x: local.x + radius * cos(toward),
                                                   y: local.y + radius * sin(toward)) : local))
      ForEach(Array(dial.items.enumerated()), id: \.element.id) { index, item in
        let offset = Double(index) - position
        if abs(offset) <= 4.5 {
          let angle = toward + offset * spacing
          let front = index == dial.selected
          let place = CGPoint(x: local.x + radius * cos(angle), y: local.y + radius * sin(angle))
          dialItem(item, front: front && landing == nil)
            .scaleEffect(landing != nil ? (front ? landingScale : 0.3) :
                         front ? (dial.confirmed == index ? 1.15 : 1.05) : max(0.75, 1 - abs(offset) * 0.06))
            .animation(.spring(response: 0.24, dampingFraction: 0.78), value: front)
            .opacity(landing != nil && !front ? 0 :
                     dial.grown || front ? max(0, 1 - max(0, abs(offset) - 3) * 0.7) : 0)
            .position(landing ?? (dial.grown ? place : local))
        }
      }
      if dial.items.indices.contains(dial.selected) {
        VStack(spacing: 4) {
          Text(dial.items[dial.selected].title)
            .font(.headline)
          /* What it does, as Blender's tooltip would say. */
          let detail = dial.items[dial.selected].detail
          if !detail.isEmpty {
            Text(detail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
              .frame(maxWidth: 260)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .panelGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .fixedSize()
        .position(x: local.x + (radius + 150) * cos(toward), y: local.y + (radius + 110) * sin(toward))
        .opacity(landing == nil && dial.grown ? 1 : 0)
        .contentTransition(.opacity)
      }
    }
    /* Each click into place settles with a soft spring. */
    .animation(.spring(response: 0.22, dampingFraction: 0.8), value: position)
  }

  private func dialItem(_ item: RailItem, front: Bool) -> some View {
    Group {
      if let image = (front ? item.selectedImage : nil) ?? item.image {
        Image(uiImage: image).resizable().scaledToFit().padding(8)
      }
      else {
        Text(String(item.title.prefix(1))).font(.title3.weight(.semibold))
      }
    }
    .frame(width: 60, height: 60)
    .foregroundStyle(front ? Color.white : Color.primary)
  }
}

/** Held with a Pencil, the tool settings fan out the mode's tools, to roll the Pencil through. */
struct PencilToolDialHold: ViewModifier {
  @State private var press: (start: CGPoint, moved: Bool, id: Int)?
  @State private var holding = false

  func body(content: Content) -> some View {
    content.simultaneousGesture(
      DragGesture(minimumDistance: 0, coordinateSpace: .global)
        .onChanged { value in
          if press == nil {
            guard PencilRoll.shared.down else { return }
            let id = Int.random(in: 0 ..< Int.max)
            press = (value.startLocation, false, id)
            /* A Pencil held still, without moving, rolls: nothing reports it held but time. */
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
              guard let press, press.id == id, !press.moved, PencilRoll.shared.down else { return }
              holding = true
              RollDial.shared.beginTools(at: press.start)
            }
          }
          else if !holding, hypot(value.translation.width, value.translation.height) > 12 {
            press?.moved = true
          }
        }
        .onEnded { _ in
          press = nil
          guard holding else { return }
          holding = false
          RollDial.shared.end()
        })
      .onChange(of: RollDial.shared.showing) { _, showing in
        if !showing {
          holding = false
          press = nil
        }
      }
  }
}

/** What the sidebar beside the viewport holds: the brush's size and strength, the + and -, and in
 * Sculpt Mode, Smooth to hold. Where Blender selects, it is only the + and -. */
struct SidebarContent: Equatable {
  var size = false
  var strength = false
  var buttons = false
  var smooth = false
  /** Face Control, where the front camera tracks faces: the face plays the brush. */
  var face = false

  /** Size and strength as rings, where the edge has no room for sliders or they were pinched in. */
  var dial = false

  init(brush: JSON?, buttons: Bool, smooth: Bool = false, dial: Bool = false) {
    self.dial = dial
    size = brush?.dict("size") != nil
    strength = brush?.dict("strength") != nil
    self.buttons = buttons
    self.smooth = smooth
#if !os(visionOS)
    face = (size || strength) && FaceControl.supported
#endif
  }

  var isEmpty: Bool { !size && !strength && !buttons && !smooth }
  /** Only buttons: small enough to sit above the tool rail. */
  var buttonsOnly: Bool { (buttons || smooth) && !size && !strength }

  var sliderHeight: CGFloat { dial ? 52 : 148 }
  /** The + and -, Smooth and Face Control below them, each 52 high. */
  var buttonsHeight: CGFloat {
    let count = (buttons ? 2 : 0) + (smooth ? 1 : 0) + (face ? 1 : 0)
    return count == 0 ? 0 : CGFloat(count) * 52 + CGFloat(count - 1) * 4
  }

  /** Room at the top for the grabber that moves it, which the + and - alone don't have. */
  var handle: CGFloat { buttonsOnly ? 0 : 16 }

  var height: CGFloat {
    let parts: [CGFloat] = [size ? sliderHeight : 0, strength ? sliderHeight : 0,
                            buttonsHeight].filter { $0 > 0 }
    return parts.isEmpty ? 0 : parts.reduce(0, +) + CGFloat(parts.count - 1) * 8 + 12 + handle
  }
}

/** One control on the side of the viewport, as painting apps have it: size and strength, and the + and -
 * below them, nearest the hand. */
struct PaintSidebar: View {
  let state: SelectIntentState
  let direction: JSON?
  let brush: JSON?
  let content: SidebarContent
  /** On the leading edge: value labels open towards the viewport, on the other side. */
  let leading: Bool
  /** Moving, turning or scaling: the + and - are Snap and Precision, held as Control and Shift
   * are on a keyboard. */
  var transforming = false
  var window: UnsafeMutableRawPointer?
  static let width: CGFloat = 64

  @State private var held: String?

  @State private var pressing: SelectIntent?
  /** One selection between the + and -, sliding from one to the other as the rails' does. */
  @Namespace private var selection

  var body: some View {
    VStack(spacing: 8) {
      if content.size, let size = brush?.dict("size") {
        let pixels = size.bool("pixels")
        SidebarSlider(key: "size", title: size.string("label") ?? "Radius", symbol: "circle.dashed",
                      json: size, logarithmic: true, height: content.sliderHeight, dial: content.dial, leading: leading,
                      unit: pixels ? "px" : "m", preview: .size(pixels: pixels),
                      format: { pixels ? String(Int($0.rounded())) : String(format: "%.3g", $0) })
      }
      if content.strength, let strength = brush?.dict("strength") {
        SidebarSlider(key: "strength", title: "Strength", symbol: "drop.fill", json: strength,
                      logarithmic: false, height: content.sliderHeight, dial: content.dial, leading: leading,
                      unit: "%",
                      preview: .strength, format: { String(Int(($0 * 100).rounded())) })
      }
      if content.buttons || content.smooth || content.face {
        VStack(spacing: 4) {
          if content.buttons && transforming {
            modifierButton("ctrl", symbol: "magnet", label: "Snap")
            modifierButton("shift", symbol: "scope", label: "Precision")
          }
          else if content.buttons, let strokes = state.strokes {
            /* One way or the other, never both: a segmented control, its selection sliding between. */
            VStack(spacing: 4) {
              button(.add, symbol: strokes.addSymbol, marquee: false, label: strokes.addName)
              button(.subtract, symbol: strokes.subtractSymbol, marquee: false, label: strokes.subtractName)
            }
            .background(Capsule().fill(Color.primary.opacity(0.08)))
          }
          else if content.buttons {
            button(.add, symbol: "plus", marquee: true, label: "Add to Selection")
            button(.subtract, symbol: "minus", marquee: true, label: "Subtract from Selection")
          }
          if content.smooth { smoothButton }
#if !os(visionOS)
          if content.face { faceButton }
#endif
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
      }
    }
    .padding(6)
    .padding(.top, content.handle)
    .frame(width: Self.width, height: content.height)
    .panelGlass(in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    .animation(UIAccessibility.isReduceMotionEnabled ? nil : .spring(response: 0.32, dampingFraction: 0.84),
               value: state.active)
    .animation(UIAccessibility.isReduceMotionEnabled ? nil : .spring(response: 0.2, dampingFraction: 0.7),
               value: pressing)
    .onChange(of: direction.map { $0 as NSDictionary }, initial: true) { _, json in
      state.update(strokes: json as? JSON)
    }
    .onChange(of: content.buttons) { _, shown in
      if !shown { state.clear() }
    }
    .onChange(of: content.smooth) { _, shown in
      if !shown { state.smoothing = false }
    }
    .onDisappear { state.clear() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("blender.sidebar")
  }

#if !os(visionOS)
  /** Face Control on or off: the mouth sets the strength, the eyebrows the size, see #FaceControl. */
  private var faceButton: some View {
    let on = FaceControl.shared.running
    return Button {
      FaceControl.shared.toggle()
    } label: {
      Image(systemName: on ? "face.smiling.inverse" : "face.smiling")
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(on ? Color.white : Color.primary)
        .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)
        .background {
          if on { Capsule().fill(.clear).panelGlass(.tinted(.blue), in: Capsule()) }
        }
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .hoverHighlight(Capsule())
    .accessibilityLabel("Face Control")
    .accessibilityHint("Your mouth sets the brush's strength, your eyebrows its size")
    .accessibilityAddTraits(on ? .isSelected : [])
  }
#endif

  /** Held, strokes smooth, as Shift does with a keyboard; let go, the brush is back. Not a brush to
   * choose: a key to hold with one hand while the other strokes. */
  private var smoothButton: some View {
    let on = state.smoothing
    return Image(systemName: "drop.halffull")
      .font(.system(size: 19, weight: .semibold))
      .foregroundStyle(on ? Color.white : Color.primary)
      .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)
      .background {
        if on {
          Capsule().fill(.clear).panelGlass(.tinted(.blue), in: Capsule())
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
      }
      .scaleEffect(on ? 0.94 : 1)
      .animation(UIAccessibility.isReduceMotionEnabled ? nil : .spring(response: 0.2, dampingFraction: 0.7),
                 value: on)
      .contentShape(Capsule())
      .hoverHighlight(Capsule())
      .onLongPressGesture(minimumDuration: .infinity, maximumDistance: .infinity, perform: {}) { down in
        state.smoothing = down
      }
      .onDisappear { state.smoothing = false }
      .accessibilityElement()
      .accessibilityLabel("Smooth")
      .accessibilityHint("Hold to smooth with the brush")
      .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
      .accessibilityIdentifier("blender.select-intent.smooth")
  }

  /** Held while moving, turning or scaling, as a keyboard's key is: Snap snaps, Precision slows
   * it for fine steps; let go, it is free again. */
  private func modifierButton(_ key: String, symbol: String, label: String) -> some View {
    let on = held == key
    return Image(systemName: symbol)
      .font(.system(size: 19, weight: .semibold))
      .foregroundStyle(on ? Color.white : Color.primary)
      .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)
      .background {
        if on {
          Capsule().fill(.clear).panelGlass(.tinted(.blue), in: Capsule())
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
      }
      .scaleEffect(on ? 0.94 : 1)
      .contentShape(Capsule())
      .hoverHighlight(Capsule())
      .onLongPressGesture(minimumDuration: .infinity, maximumDistance: .infinity, perform: {}) { down in
        if down {
          held = key
          Haptics.selection()
        }
        else if held == key {
          held = nil
        }
        wm_apple_ios_window_hold_modifier(window, key, down)
      }
      .onChange(of: transforming) { _, transforming in
        /* The move ended with it held: let go of it too. */
        if !transforming, held == key {
          held = nil
          wm_apple_ios_window_hold_modifier(window, key, false)
        }
      }
      .transition(.opacity.combined(with: .scale(scale: 0.8)))
      .accessibilityElement()
      .accessibilityLabel(label)
      .accessibilityHint(key == "ctrl" ? "Hold to snap" : "Hold for finer steps")
      .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
  }

  /** With \a marquee, \a symbol sits in a dashed square, so + and - for the selection mirror each
   * other: there is no minus.square.dashed to go with plus.square.dashed. */
  private func button(_ intent: SelectIntent, symbol: String, marquee: Bool, label: String) -> some View {
    let on = state.active == intent
    return DirectionSymbol.view(marquee ? "square.dashed" : symbol)
      .font(.system(size: 20, weight: .semibold))
      .overlay {
        if marquee {
          Image(systemName: symbol).font(.system(size: 10, weight: .bold))
        }
      }
      .foregroundStyle(on ? Color.white : Color.primary)
      .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)
      .contentTransition(.symbolEffect(.replace))
      .background {
        if on {
          Capsule()
            .fill(.clear)
            .panelGlass(.tinted(.blue), in: Capsule())
            .matchedGeometryEffect(id: "selection", in: selection)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
      }
      .scaleEffect(pressing == intent ? 0.94 : 1)
      .contentShape(Capsule())
      .hoverHighlight(Capsule())
      /* Never completes, so it reports the finger landing and lifting, however long it stays. */
      .onLongPressGesture(minimumDuration: .infinity, maximumDistance: .infinity, perform: {}) { down in
        pressing = down ? intent : nil
        if down {
          state.press(intent)
        }
        else {
          state.release(intent)
        }
      }
      .accessibilityElement()
      .accessibilityLabel(label)
      .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
      .accessibilityAction { if state.strokes != nil { state.choose(intent) } }
      .accessibilityIdentifier("blender.select-intent.\(intent == .add ? "add" : "subtract")")
  }
}

/** Send one of the brush's values to Blender; \a commit ends a drag with an undo step. */
@MainActor
func sendBrushValue(_ key: String, _ value: Any, commit: Bool = false) {
  let encoded: String
  if let color = value as? [Double] {
    encoded = "[" + color.map { String($0) }.joined(separator: ",") + "]"
  }
  else {
    encoded = String(value as? Double ?? 0)
  }
  /* The key first: Blender keeps only the newest of a drag's values for each key. */
  Engine.setting("native_brush", "{\"key\":\"\(key)\",\"value\":\(encoded),\"commit\":\(commit)}")
}

/**
 * A tall slider in the sidebar. Dragging moves the value from where it is, not to the finger;
 * sliding the finger out sideways while dragging moves it more finely. A tap types a number.
 */
struct SidebarSlider: View {
  let key: String
  let title: String
  let symbol: String
  let json: JSON
  /** Along a curve, so small sizes get as much of the slider as large ones. */
  let logarithmic: Bool
  let height: CGFloat
  /** A ring the value goes around; holding or dragging it brings out a tall slider beside it. */
  var dial = false
  let leading: Bool
  let unit: String
  /** What dragging shows beside the slider, towards the viewport. */
  enum Preview {
    /** The brush at its size on screen, for a size in pixels. */
    case size(pixels: Bool)
    /** A dab filled as strongly as the brush paints. */
    case strength
  }
  let preview: Preview
  let format: (Double) -> String

  @Environment(\.displayScale) private var displayScale

  private struct Drag {
    /** Where the finger has taken the value, past either end while it pulls the slider. */
    var raw: Double
    var position: Double { min(1, max(0, raw)) }
    var lastY: CGFloat
    var moved = false
    /** The Pencil's roll as last seen, to turn the value with it. */
    var roll: Double?
  }

  @State private var drag: Drag?
  @State private var globalFrame = CGRect.zero
  /** The value set here, shown until Blender's snapshot has it. */
  @State private var local: (value: Double, until: Date)?
  @State private var entering = false
  @State private var entry = ""
  /** A dial held still long enough to bring out its slider. */
  @State private var held = false
  @State private var holding: Task<Void, Never>?

  /** The slider a dial brings out, and how far the finger moves the value along it. */
  private static let trackHeight: CGFloat = 220
  private var travel: CGFloat { (dial ? Self.trackHeight : height) - 52 }
  private var trackShown: Bool { dial && (held || drag?.moved == true) }

  private var low: Double { json.double("min") ?? 0 }
  private var high: Double { max(low + 1e-6, json.double("max") ?? 1) }

  private var value: Double {
    let blender = json.double("value") ?? low
    if let local, drag != nil || (Date() < local.until && abs(local.value - blender) > 1e-6) {
      return local.value
    }
    return blender
  }

  private func position(_ value: Double) -> Double {
    let t = logarithmic && low > 0 ? log(max(value, low) / low) / log(high / low) : (value - low) / (high - low)
    return min(1, max(0, t))
  }

  private func value(at position: Double) -> Double {
    logarithmic && low > 0 ? low * pow(high / low, position) : low + (high - low) * position
  }

  /** Points the slider stretches past an end, pulled further than the value goes: less the
   * further it is pulled, as glass gives. */
  private var stretch: CGFloat {
    guard let drag else { return 0 }
    let past = drag.raw > 1 ? drag.raw - 1 : drag.raw < 0 ? drag.raw : 0
    let pulled = CGFloat(past) * travel
    return (pulled < 0 ? -1 : 1) * 16 * (1 - exp(-abs(pulled) / 48))
  }

  /** The value filling a glass capsule from the bottom, level across its top as the system's
   * sliders fill, all the way down at the lowest. The symbol at its top follows the value. */
  private func capsule(height: CGFloat) -> some View {
    let width: CGFloat = 52
    let t = position(value)
    let fill = height * t
    let pulled = stretch
    return ZStack(alignment: .bottom) {
      SliderFill(level: fill)
        .fill(.clear)
        .panelGlass(.tinted(.accentColor.opacity(drag != nil ? 1 : 0.85)), in: SliderFill(level: fill))
      Text(format(value))
        .font(.system(size: 13, weight: .semibold).monospacedDigit())
        .foregroundStyle(fill > 34 ? Color.white : Color.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(width: width - 8, height: width)
    }
    .overlay(alignment: .top) {
      liveSymbol(t)
        .foregroundStyle(fill > height - 30 ? Color.white : Color.primary)
        .frame(height: 16)
        .padding(.top, 12)
        .allowsHitTesting(false)
    }
    .frame(width: width, height: height)
    .background(Capsule().fill(.clear).panelGlass(interactive: true, in: Capsule()))
    /* Pulled past an end, it stretches that way and narrows, springing back when let go. */
    .scaleEffect(x: 1 - abs(pulled) / height * 0.5, y: 1 + abs(pulled) / height,
                 anchor: pulled > 0 ? .bottom : .top)
  }

  /** The slider's symbol drawn as the value: the brush circle growing with the size, the drop
   * filling with the strength. */
  @ViewBuilder
  private func liveSymbol(_ t: Double) -> some View {
    let font = Font.system(size: 13, weight: .semibold)
    switch preview {
      case .size:
        Image(systemName: symbol)
          .font(font)
          .scaleEffect(0.5 + 0.75 * t)
      case .strength:
        Image(systemName: symbol.replacingOccurrences(of: ".fill", with: ""))
          .font(font)
          .overlay {
            Image(systemName: symbol)
              .font(font)
              .mask {
                GeometryReader { proxy in
                  Rectangle()
                    .frame(height: proxy.size.height * t)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
              }
          }
    }
  }

  /** The value going around a ring, with the number inside. */
  private var ring: some View {
    ZStack {
      Circle().fill(Color.primary.opacity(drag != nil ? 0.14 : 0.08))
      Circle()
        .stroke(Color.primary.opacity(0.12), lineWidth: 4)
        .padding(5)
      Circle()
        .trim(from: 0, to: max(0.001, position(value)))
        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .padding(5)
      Text(format(value))
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .padding(.horizontal, 11)
    }
    .frame(width: 52, height: 52)
  }

  /** The setting, and below it the brush as it will paint. */
  private var readout: some View {
    VStack(spacing: 12) {
      VStack(spacing: 2) {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("\(format(value)) \(unit)")
          .font(.headline.monospacedDigit())
      }
      previewDab
    }
    .padding(16)
    .frame(minWidth: 112, minHeight: 112)
    .panelGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    .fixedSize()
  }

  var body: some View {
    let width: CGFloat = 52
    let t = position(value)
    Group {
      if dial { ring }
      else { capsule(height: height) }
    }
    .overlay(alignment: leading ? .leading : .trailing) {
      if trackShown {
        /* Held, the dial brings out a slider towards the viewport, and the readout beside it. */
        HStack(spacing: 14) {
          if !leading, drag?.moved == true { readout }
          capsule(height: Self.trackHeight)
          if leading, drag?.moved == true { readout }
        }
        .fixedSize()
        .offset(x: (leading ? 1 : -1) * (width + 14))
        .allowsHitTesting(false)
        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: leading ? .leading : .trailing)))
      }
      else if drag?.moved == true {
        readout
          .offset(x: (leading ? 1 : -1) * (width + 18))
          .allowsHitTesting(false)
          .transition(.opacity.combined(with: .scale(scale: 0.92)))
      }
    }
    .contentShape(dial ? AnyShape(Circle()) : AnyShape(Capsule()))
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { gesture in
          if drag == nil, dial {
            holding = Task {
              try? await Task.sleep(for: .milliseconds(250))
              guard !Task.isCancelled, drag != nil else { return }
              Haptics.selection()
              held = true
            }
          }
          var current = drag ?? Drag(raw: position(value), lastY: gesture.startLocation.y)
          /* A tap types a value instead; the slightest drag moves it, from where the finger
           * landed, so no movement is lost to telling the two apart. */
          if !current.moved, abs(gesture.translation.height) + abs(gesture.translation.width) > 2 {
            current.moved = true
          }
          guard current.moved else {
            drag = current
            return
          }
          let dy = gesture.location.y - current.lastY
          current.lastY = gesture.location.y
          /* Out to the side, the finger moves the value more finely. */
          let side = max(0, abs(gesture.location.x - width / 2) - width)
          let fine = 1 / (1 + Double(side) / 60)
          let before = current.position
          /* Turning back from past an end, the value moves again at once. */
          if current.raw > 1, dy > 0 { current.raw = 1 }
          if current.raw < 0, dy < 0 { current.raw = 0 }
          current.raw -= Double(dy / travel) * fine
          drag = current
          tick(from: before, to: current.position)
          let next = value(at: current.position)
          local = (next, .distantFuture)
          sendBrushValue(key, next)
        }
        .onEnded { _ in
          let moved = drag?.moved == true
          let wasHeld = held
          holding?.cancel()
          holding = nil
          held = false
          drag = nil
          if moved, let local {
            self.local = (local.value, Date().addingTimeInterval(1))
            sendBrushValue(key, local.value, commit: true)
          }
          else if !wasHeld {
            entry = format(value)
            entering = true
          }
        })
    .animation(.easeOut(duration: 0.15), value: drag?.moved == true)
    .animation(.spring(response: 0.35, dampingFraction: 0.55), value: drag == nil)
    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: trackShown)
    /* Held with a Pencil, rolling it turns the value: half a turn from one end to the other.
     * Only read while held, so the Pencil's roll elsewhere does not redraw the slider. */
    .onChange(of: drag != nil ? PencilRoll.shared.turned : 0) { _, turned in
      guard var current = drag, PencilRoll.shared.down else { return }
      guard let last = current.roll else {
        current.roll = turned
        drag = current
        return
      }
      current.roll = turned
      let before = current.position
      current.raw = min(1, max(0, current.position + (turned - last) / .pi))
      current.moved = true
      drag = current
      tick(from: before, to: current.position)
      /* Felt through the Pencil every twentieth of the way. */
      if Int(before * 20) != Int(current.position * 20) {
        RollDial.shared.pencilTick(at: CGPoint(x: globalFrame.midX, y: globalFrame.midY))
      }
      let next = value(at: current.position)
      local = (next, .distantFuture)
      sendBrushValue(key, next)
    }
    .alert(title, isPresented: $entering) {
      TextField(title, text: $entry)
        .keyboardType(.decimalPad)
      Button("Cancel", role: .cancel) {}
      Button("Set") { setTyped() }
    } message: {
      Text(unit.isEmpty ? "" : "In \(unit == "%" ? "percent" : unit == "px" ? "pixels" : "meters").")
    }
    .accessibilityElement()
    .accessibilityLabel(title)
    .accessibilityValue("\(format(value)) \(unit)")
    .accessibilityAdjustableAction { direction in
      let step = direction == .increment ? 0.05 : -0.05
      let next = value(at: min(1, max(0, t + step)))
      local = (next, Date().addingTimeInterval(1))
      sendBrushValue(key, next, commit: true)
    }
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { globalFrame = $0 }
    .accessibilityIdentifier("blender.sidebar.\(key)")
  }

  /** The brush as it will paint: its size on screen, or how strongly. */
  @ViewBuilder
  private var previewDab: some View {
    switch preview {
      case .size(let pixels):
        if pixels {
          /* Blender's pixels are the screen's; very large brushes are shown as large as fits. */
          let diameter = min(320, max(4, CGFloat(value) / displayScale))
          ZStack {
            Circle().fill(Color.white.opacity(0.18))
            Circle().stroke(Color.black.opacity(0.5), lineWidth: 3)
            Circle().stroke(Color.white, lineWidth: 1.5)
          }
          .frame(width: diameter, height: diameter)
        }
      case .strength:
        ZStack {
          Circle().fill(Color.white.opacity(0.05 + 0.85 * min(1, value)))
          Circle().stroke(Color.black.opacity(0.5), lineWidth: 3)
          Circle().stroke(Color.white, lineWidth: 1.5)
        }
        .frame(width: 48, height: 48)
    }
  }

  /** A tick at either end and passing the default. */
  private func tick(from before: Double, to after: Double) {
    let marks = [0, 1, json.double("default").map(position)].compactMap { $0 }
    if marks.contains(where: { ($0 - before) * ($0 - after) < 0 || ($0 == after && before != after) }) {
      Haptics.selection()
    }
  }

  private func setTyped() {
    guard var typed = Double(entry.replacingOccurrences(of: ",", with: ".")) else { return }
    if unit == "%" { typed /= 100 }
    let hard = json.double("max").map { max($0, typed) } ?? typed
    typed = max(low, min(hard, typed))
    local = (typed, Date().addingTimeInterval(1))
    sendBrushValue(key, typed, commit: true)
  }
}

/** A capsule standing upright, filled from the bottom to \a level, level across its top. */
struct SliderFill: Shape {
  var level: CGFloat

  var animatableData: CGFloat {
    get { level }
    set { level = newValue }
  }

  func path(in rect: CGRect) -> Path {
    let level = min(max(0, level), rect.height)
    guard level > 0 else { return Path() }
    let below = CGRect(x: rect.minX, y: rect.maxY - level, width: rect.width, height: level)
    return Capsule().path(in: rect).intersection(Path(below))
  }
}

/** The brush's color, above the brushes, in modes that paint colors. */
struct BrushColorWell: View {
  let color: [Double]
  static let size: CGFloat = 64
  @State private var anchor = AnchorBox()

  private var uiColor: UIColor {
    UIColor(red: color.count > 0 ? color[0] : 0, green: color.count > 1 ? color[1] : 0,
            blue: color.count > 2 ? color[2] : 0, alpha: 1)
  }

  var body: some View {
    /* A tap opens the system's color picker; rolling a Pencil on it opens the color dial. */
    Button {
      guard !ColorRoll.shared.showing, !ColorRoll.shared.justClosed else { return }
      BrushColorPicker.shared.present(from: anchor, color: uiColor)
    } label: {
      Circle()
        .fill(Color(uiColor))
        .frame(width: 36, height: 36)
        .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2.5))
        .shadow(color: .black.opacity(0.2), radius: 2)
        .frame(width: Self.size, height: Self.size)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .background(PresentationAnchor(anchor: anchor))
    .panelGlass(.clear, in: Circle())
    .opacity(ColorRoll.shared.showing ? 0 : 1)
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
      ColorRoll.shared.wellFrame = frame
    }
    .onChange(of: color, initial: true) { _, color in ColorRoll.shared.brushColor = color }
    .onDisappear { ColorRoll.shared.wellFrame = .null }
    .accessibilityLabel("Brush Color")
    .accessibilityIdentifier("blender.brush-color")
  }
}

/** The system color picker for the brush color: changes show as they are made, and one undo step
 * is kept as it closes. */
@MainActor
final class BrushColorPicker: NSObject, UIColorPickerViewControllerDelegate,
  UIPopoverPresentationControllerDelegate
{
  static let shared = BrushColorPicker()
  private var picker: UIColorPickerViewController?
  private var pending: [Double]?
  private var lastSent: CFTimeInterval = 0

  func present(from anchor: AnchorBox, color: UIColor) {
    let picker = UIColorPickerViewController()
    picker.title = "Brush Color"
    picker.supportsAlpha = false
    picker.selectedColor = color
    picker.delegate = self
    self.picker = picker
    anchor.present(picker)
    picker.popoverPresentationController?.delegate = self
  }

  func colorPickerViewController(_ picker: UIColorPickerViewController, didSelect color: UIColor,
                                 continuously: Bool)
  {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    let rgb = [r, g, b].map { min(1, max(0, Double($0))) }
    pending = rgb
    if !continuously {
      commit()
    }
    else if CACurrentMediaTime() - lastSent > 1.0 / 30 {
      lastSent = CACurrentMediaTime()
      sendBrushValue("color", rgb)
    }
  }

  private func commit() {
    guard let pending else { return }
    self.pending = nil
    sendBrushValue("color", pending, commit: true)
  }

  func colorPickerViewControllerDidFinish(_ picker: UIColorPickerViewController) { commit() }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { commit() }
}

/** The brush color, turned by rolling a Pencil held on the color well: the roll goes around the
 * hue wheel. Moving the Pencil in or out sets saturation, from white at the middle to full at the
 * rim, and moving it around the wheel sets brightness. Lifting keeps it. */
@MainActor
@Observable
final class ColorRoll {
  static let shared = ColorRoll()
  /** The wheel's radius, and how far the Pencil moves around it from black to full brightness. */
  static let radius: CGFloat = 150
  /** The ring's inner edge, just outside the color well it grows from. */
  static let innerRadius: CGFloat = 46

  @ObservationIgnored var wellFrame = CGRect.null
  @ObservationIgnored var brushColor: [Double] = [0, 0, 0]

  /** The color well's middle, in the window, while the dial shows: it grows out from there. */
  private(set) var origin: CGPoint?
  /** Grown out to its place. */
  private(set) var open = false
  private(set) var hue: Double = 0
  private(set) var saturation: Double = 0
  private(set) var brightness: Double = 0
  /** The direction, on screen, the current hue faces: towards the middle of the window, so the
   * color stays in view as the ring turns under it from a well at the edge. */
  private(set) var facing: Double = 0
  @ObservationIgnored private var armed: (point: CGPoint, roll: Double)?
  @ObservationIgnored private var start: (hue: Double, saturation: Double, brightness: Double,
                                          roll: Double, point: CGPoint)?
  @ObservationIgnored private var closedAt = Date.distantPast
  @ObservationIgnored private var lastSent = Date.distantPast
  @ObservationIgnored private var lastSegment = 0

  var showing: Bool { origin != nil }
  var justClosed: Bool { Date().timeIntervalSince(closedAt) < 0.6 }

  var rgb: [Double] {
    let color = UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    return [Double(r), Double(g), Double(b)]
  }

  func pencilMoved(to point: CGPoint, began: Bool) {
    if began {
      armed = wellFrame.insetBy(dx: -6, dy: -6).contains(point) && origin == nil ?
        (point, PencilRoll.shared.turned) : nil
      if armed != nil {
        /* Held still, it opens without rolling too. */
        let token = point
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
          if let armed = self.armed, armed.point == token, PencilRoll.shared.down { self.begin(armed) }
        }
      }
      return
    }
    if let armed, origin == nil {
      if abs(PencilRoll.shared.turned - armed.roll) > RollDial.openingRoll { begin(armed) }
      else if hypot(point.x - armed.point.x, point.y - armed.point.y) > 24 { self.armed = nil }
      return
    }
    guard let start, origin != nil else { return }
    /* Rolling turns the hue, once around for a full turn of the Pencil. */
    let turned = (PencilRoll.shared.turned - start.roll) / (2 * .pi)
    var nextHue = (start.hue + turned).truncatingRemainder(dividingBy: 1)
    if nextHue < 0 { nextHue += 1 }
    hue = nextHue
    /* Out from the well towards the color, or back: saturation. Across: brightness. */
    let move = CGVector(dx: point.x - start.point.x, dy: point.y - start.point.y)
    let out = CGVector(dx: cos(facing), dy: sin(facing))
    let radial = Double(move.dx * out.dx + move.dy * out.dy)
    let around = Double(move.dx * -out.dy + move.dy * out.dx)
    saturation = min(1, max(0, start.saturation + radial / Double(Self.radius - Self.innerRadius)))
    brightness = min(1, max(0, start.brightness + around / Double(Self.radius * 1.5)))
    /* Felt at each of the twelve hues around the wheel. */
    let segment = Int((hue * 12).rounded())
    if segment != lastSegment {
      lastSegment = segment
      RollDial.shared.pencilTick(at: point)
    }
    if Date().timeIntervalSince(lastSent) > 1.0 / 30 {
      lastSent = Date()
      sendBrushValue("color", rgb)
    }
  }

  private func begin(_ armed: (point: CGPoint, roll: Double)) {
    self.armed = nil
    guard origin == nil, !wellFrame.isNull else { return }
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(red: brushColor.count > 0 ? brushColor[0] : 0, green: brushColor.count > 1 ? brushColor[1] : 0,
            blue: brushColor.count > 2 ? brushColor[2] : 0, alpha: 1)
      .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    hue = Double(h)
    saturation = Double(s)
    brightness = Double(b)
    lastSegment = Int((hue * 12).rounded())
    if let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
      facing = atan2(Double(window.bounds.midY - wellFrame.midY), Double(window.bounds.midX - wellFrame.midX))
    }
    start = (hue, saturation, brightness, armed.roll, PencilRoll.shared.point)
    Haptics.impact(.light)
    open = false
    origin = CGPoint(x: wellFrame.midX, y: wellFrame.midY)
    /* Grown out of the well, from where the Pencil holds it. */
    DispatchQueue.main.async {
      withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) { self.open = true }
    }
  }

  func pencilLifted() {
    armed = nil
    guard origin != nil else { return }
    sendBrushValue("color", rgb, commit: true)
    start = nil
    closedAt = Date()
    RollDial.shared.pencilTick(at: origin ?? .zero)
    /* Back into the well, which then shows the color. */
    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { open = false }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
      var instant = Transaction()
      instant.disablesAnimations = true
      withTransaction(instant) { self.origin = nil }
    }
  }
}

/** The color dial over the whole window while a Pencil rolls the color: a hue wheel, white in the
 * middle, with the color on it where it is, and a rim in the color itself. */
struct ColorRollLayer: View {
  private var roll: ColorRoll { ColorRoll.shared }

  var body: some View {
    GeometryReader { proxy in
      let frame = proxy.frame(in: .global)
      ZStack {
        if let origin = roll.origin {
          Color.black.opacity(roll.open ? 0.12 : 0)
          /* Around the color well itself, fanned out from it. */
          wheel
            .scaleEffect(roll.open ? 1 : 0.25)
            .opacity(roll.open ? 1 : 0)
            .position(x: origin.x - frame.minX, y: origin.y - frame.minY)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var wheel: some View {
    let outer = ColorRoll.radius
    let inner = ColorRoll.innerRadius
    let hues = (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) }
    let current = Color(hue: roll.hue, saturation: roll.saturation, brightness: roll.brightness)
    /* The ring turned so the current hue faces where the color sits. */
    let turn = Angle(radians: roll.facing - (roll.hue * 2 * .pi - .pi / 2))
    let out = CGVector(dx: cos(roll.facing), dy: sin(roll.facing))
    let distance = inner + (outer - inner) * roll.saturation
    let knob = CGPoint(x: outer + out.dx * distance, y: outer + out.dy * distance)
    let band = outer - inner
    return ZStack {
      /* The hue ring: hue around, white at its inner edge to full at its outer one, darkened as
       * the color is. */
      Circle()
        .strokeBorder(AngularGradient(colors: hues, center: .center, startAngle: .degrees(-90),
                                      endAngle: .degrees(270)), lineWidth: band)
        .rotationEffect(turn)
      Circle()
        .strokeBorder(RadialGradient(colors: [.white, .white.opacity(0)], center: .center,
                                     startRadius: inner, endRadius: outer), lineWidth: band)
      Circle()
        .strokeBorder(.black.opacity(1 - roll.brightness), lineWidth: band)
      /* Its rim, in the color itself. */
      Circle()
        .strokeBorder(current, lineWidth: 8)
        .padding(-10)
      /* The well in the middle, in the color. */
      Circle()
        .fill(current)
        .frame(width: inner * 2 - 16, height: inner * 2 - 16)
        .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 3))
      /* The color, where it sits on the ring. */
      Circle()
        .fill(current)
        .frame(width: 34, height: 34)
        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
        .shadow(color: .black.opacity(0.35), radius: 3)
        .position(knob)
    }
    .frame(width: outer * 2, height: outer * 2)
    .shadow(color: .black.opacity(0.15), radius: 14)
  }
}


/** \} */

/**
 * Where everything rests around the viewport. The tools sit in the leading bottom corner. The
 * sidebar the other hand holds (the brush's size and strength, and the + and -) sits halfway down
 * the leading edge, or the trailing one for the left hand; where Blender selects it is only the
 * + and -, resting above the tool rail. The color well and brushes run down from the top of the
 * other edge, above the navigation gizmo. Compact rails are 64 points; an open list takes the room
 * its edge has.
 */
struct RailLayout: Equatable {
  var toolWidth: CGFloat
  var toolHeight: CGFloat
  /** No room for the open tool list beside the sliders: the rail is closed. */
  var toolsCompact = false
  var brushWidth: CGFloat
  var brushHeight: CGFloat
  /** The tool rail's top edge, in the window. */
  var toolTop: CGFloat
  /** How far a docked tool rail rises from the bottom resting place. */
  var dockDistance: CGFloat
  var toolCenter: CGPoint
  var brushCenter: CGPoint
  var colorCenter: CGPoint
  var sidebarCenter: CGPoint
  /** How far the sidebar's top edge can be moved along its edge. */
  var sidebarTravel: ClosedRange<CGFloat> = 0...0
  var sidebarLeading: Bool
  /** Out of the way of an open tool list, or without the room to show. */
  var sidebarTucked: Bool
  var toolEdge: RailEdge
  var brushEdge: RailEdge
  var brushLeading: Bool { brushEdge == .leading }
  /** See #Rail.brushStops. */
  var brushStops: (middle: CGFloat, other: CGFloat)
  /** What sits in the bottom left corner, for the quick actions beside it. */
  var leadingCorner: CGFloat = 0
  /** A row along the bottom, which the quick actions rise above. */
  var bottomRow: CGFloat = 0

  static func == (a: RailLayout, b: RailLayout) -> Bool {
    a.toolWidth == b.toolWidth && a.toolHeight == b.toolHeight && a.toolsCompact == b.toolsCompact &&
      a.brushWidth == b.brushWidth &&
      a.brushHeight == b.brushHeight && a.toolTop == b.toolTop && a.dockDistance == b.dockDistance &&
      a.toolCenter == b.toolCenter && a.brushCenter == b.brushCenter && a.colorCenter == b.colorCenter &&
      a.sidebarCenter == b.sidebarCenter && a.sidebarLeading == b.sidebarLeading &&
      a.sidebarTucked == b.sidebarTucked && a.toolEdge == b.toolEdge && a.brushEdge == b.brushEdge &&
      a.brushStops == b.brushStops && a.leadingCorner == b.leadingCorner && a.bottomRow == b.bottomRow
  }

  @MainActor
  init(safe: CGRect, tray: CGFloat, tools: RailState, toolCount: Int, brushes: RailState?, brushCount: Int,
       sidebar: SidebarContent, sidebarPosition: Double? = nil, colorWell: Bool, leftHanded: Bool,
       gizmoTop: CGFloat, toolEdge: RailEdge = .leading, brushEdge: RailEdge? = nil)
  {
    let compact: CGFloat = 64, gap: CGFloat = 10, topInset: CGFloat = 16, bottomInset: CGFloat = 12
    let inset: CGFloat = 14
    self.toolEdge = toolEdge
    toolCenter = .zero
    brushCenter = .zero
    colorCenter = .zero
    let brushEdge = brushEdge ?? (leftHanded ? .leading : .trailing)
    self.brushEdge = brushEdge
    /* The sidebar keeps the hand's side, unless the brushes were moved there. */
    let sidebarLeading = brushEdge == (leftHanded ? .trailing : .leading) ? leftHanded : !leftHanded
    self.sidebarLeading = sidebarLeading
    let sidebarEdge: RailEdge = sidebarLeading ? .leading : .trailing
    let brushLeading = brushEdge == .leading
    /* Leave a usable lane for the quick actions beside the gizmo, even in a narrow window. */
    let expandedWidth = min(240, max(64, safe.width - 284))
    /* Where a column's room ends at the bottom of its edge: above the navigation gizmo on the
     * trailing side. */
    let floorY = { (leading: Bool) -> CGFloat in
      leading ? safe.maxY - tray : min(gizmoTop - gap + bottomInset, safe.maxY - tray)
    }
    let listLength = { (count: Int) -> CGFloat in 44 + 12 + CGFloat(count) * 52 + CGFloat(max(0, count - 1)) * 12 }

    /* The + and - alone join the tool column: above the closed rail, or in the corner below an
     * open or docked one, which rises to make room. */
    let sharesSidebar = toolEdge == sidebarEdge
    let pill = sidebar.buttonsOnly && sharesSidebar
    let below = pill && tools.listVisible
    let reserve = below ? sidebar.height + gap : 0
    let toolFloor = floorY(toolEdge == .leading)
    let span = safe.height - (safe.maxY - tray - toolFloor)
    let height = max(0, toolFloor - safe.minY - reserve)
    /* The size and strength sliders share the tool rail's edge: an open tool list leaves room for
     * them above it rather than pushing them aside, scrolling within what is left. */
    let shareEdge = sharesSidebar && !pill && (sidebar.size || sidebar.strength)
    let sidebarRoom = shareEdge ? sidebar.height + gap : 0
    var maxList = min(max(64, (span - reserve) * 0.58), max(64, span - reserve - 112))
    if shareEdge {
      maxList = max(compact, min(maxList, height - topInset - bottomInset - sidebarRoom))
    }
    /* The sliders come first: with no room left for an open list of tools, the rail stays closed,
     * showing the active tool alone, until there is. */
    toolsCompact = shareEdge && tools.listVisible && maxList < compact * 2 + 12
    let top = safe.minY + topInset
    if toolEdge.horizontal {
      toolWidth = tools.listVisible ? listLength(toolCount) : compact
      toolHeight = compact
      dockDistance = 0
    }
    else {
      toolWidth = tools.expanded && !toolsCompact ? expandedWidth : compact
      /* As tall as its tools (the handle, then 52 points each, 12 apart), as the room allows: a
       * mode with few tools leaves no empty space below them. */
      toolHeight = tools.listVisible && !toolsCompact ? max(compact, min(listLength(toolCount), maxList)) : compact
      /* The middle resting place of a compact tool rail, measured from the bottom one. */
      dockDistance = max(0, (toolFloor - safe.minY - compact) / 2 - bottomInset)
    }
    /* Docking centers the rail, unless the sliders need the room above it; otherwise it rests at
     * the bottom. */
    let centered = tools.docked && !shareEdge
    let bottom = (centered ? max(bottomInset, (height - toolHeight) / 2) : bottomInset) + reserve
    toolTop = toolEdge == .top ? top : toolEdge == .bottom ? safe.maxY - tray - bottomInset - compact :
                                                              toolFloor - bottom - toolHeight
    let edgeX = { (width: CGFloat, leading: Bool) in
      leading ? safe.minX + inset + width / 2 : safe.maxX - inset - width / 2
    }

    /* The color well above the brushes, on their edge between the top bar and the navigation
     * gizmo, or the tool rail when they share its edge: an open list halfway down, closed ones
     * resting above the gizmo, or at the top where they were dragged. In a row, it leads it. */
    let trailingBottom = floorY(false) - bottomInset
    let columnBottom = brushEdge == toolEdge ? toolTop - gap : floorY(brushLeading) - bottomInset
    let colorHeight = colorWell ? BrushColorWell.size + gap : 0
    if brushEdge.horizontal {
      brushWidth = brushes?.listVisible == true ? listLength(brushCount) : compact
      brushHeight = compact
      brushStops = (0, 0)
    }
    else {
      brushWidth = brushes?.expanded == true ? expandedWidth : compact
      let groupTop: CGFloat
      if brushes?.listVisible == true {
        /* As tall as its brushes (the handle, then 52 points each, 12 apart), as the room allows. */
        brushHeight = max(compact, min(listLength(brushCount), columnBottom - top - colorHeight))
        groupTop = top + max(0, (columnBottom - top - colorHeight - brushHeight) / 2)
      }
      else {
        brushHeight = compact
        let group = colorHeight + (brushes != nil ? compact : 0)
        groupTop = brushes?.restsAtTop == true ? top : max(top, columnBottom - group)
      }
      let restTop = top + colorHeight + compact / 2
      let restBottom = max(top, columnBottom - colorHeight - compact) + colorHeight + compact / 2
      let resting = brushes?.restsAtTop == true ? restTop : restBottom
      brushStops = ((top + columnBottom) / 2 - resting,
                    (brushes?.restsAtTop == true ? restBottom : restTop) - resting)
      colorCenter = CGPoint(x: edgeX(compact, brushLeading), y: groupTop + BrushColorWell.size / 2)
      brushCenter = CGPoint(x: edgeX(brushWidth, brushLeading), y: groupTop + colorHeight + brushHeight / 2)
    }

    /* The sidebar, halfway down its edge where it fits, clear of what sits below it. */
    let h = sidebar.height
    let x = edgeX(PaintSidebar.width, sidebarLeading)
    if pill {
      let y = below ? toolFloor - bottomInset - h : max(top, toolTop - gap - h)
      sidebarCenter = CGPoint(x: x, y: y + h / 2)
      sidebarTucked = false
    }
    else {
      let lowest = sharesSidebar ? toolTop - gap : sidebarLeading ? floorY(true) - bottomInset : trailingBottom
      let highest = top
      let travel = highest...max(highest, lowest - h)
      sidebarTravel = travel
      let y = sidebarPosition.map { travel.lowerBound + CGFloat($0) * (travel.upperBound - travel.lowerBound) } ??
        max(top, min(safe.midY - h / 2, lowest - h))
      sidebarCenter = CGPoint(x: x, y: y + h / 2)
      sidebarTucked = lowest - top < h
    }

    /* Rows along the top or the bottom run between the columns on either side, the navigation
     * gizmo's corner left free along the bottom. The tools lead when both share a row. */
    let columnTools = toolWidth, columnBrushes = brushWidth
    let lane = { (leading: Bool) -> CGFloat in
      var widths: [CGFloat] = []
      if !toolEdge.horizontal && (toolEdge == .leading) == leading { widths.append(columnTools) }
      if !brushEdge.horizontal && brushLeading == leading { widths.append(max(columnBrushes, compact)) }
      if !sidebar.isEmpty && sidebarLeading == leading { widths.append(PaintSidebar.width) }
      return widths.max().map { inset + $0 + gap } ?? inset
    }
    var brushRowCenter = CGPoint.zero
    for row in [RailEdge.top, .bottom] {
      let toolsHere = toolEdge == row, brushesHere = brushEdge == row && brushes != nil
      guard toolsHere || brushesHere else { continue }
      let minX = safe.minX + lane(true)
      let maxX = safe.maxX - max(lane(false), row == .bottom ? ShellMetrics.gizmoReserve : 0)
      let room = max(compact, maxX - minX)
      let colorWidth = brushesHere && colorWell ? BrushColorWell.size + gap : 0
      var toolLength = toolsHere ? toolWidth : 0
      var brushLength = brushesHere ? brushWidth : 0
      let gaps = toolsHere && brushesHere ? gap : 0
      if toolLength + brushLength + colorWidth + gaps > room {
        /* Each scrolls within its share of the row. */
        let share = (room - colorWidth - gaps) / (toolsHere && brushesHere ? 2 : 1)
        toolLength = toolsHere ? max(compact, min(toolLength, share)) : 0
        brushLength = brushesHere ? max(compact, min(brushLength, room - colorWidth - gaps - toolLength)) : 0
      }
      let total = toolLength + gaps + colorWidth + brushLength
      let y = row == .top ? top + compact / 2 : safe.maxY - tray - bottomInset - compact / 2
      var cursor = max(minX, min((safe.minX + safe.maxX) / 2 - total / 2, maxX - total))
      if toolsHere {
        toolWidth = toolLength
        toolCenter = CGPoint(x: cursor + toolLength / 2, y: y)
        cursor += toolLength + gaps
      }
      if brushesHere {
        colorCenter = CGPoint(x: cursor + BrushColorWell.size / 2, y: y)
        cursor += colorWidth
        brushWidth = brushLength
        brushRowCenter = CGPoint(x: cursor + brushLength / 2, y: y)
      }
      if row == .bottom { bottomRow = compact + gap }
    }
    if !toolEdge.horizontal {
      toolCenter = CGPoint(x: edgeX(toolWidth, toolEdge == .leading), y: toolTop + toolHeight / 2)
    }
    if brushEdge.horizontal {
      brushCenter = brushRowCenter
    }
    if toolEdge == .leading { leadingCorner = toolWidth }
    else if brushLeading && brushes?.restsAtTop != true { leadingCorner = brushWidth }
  }
}

/** \} */
