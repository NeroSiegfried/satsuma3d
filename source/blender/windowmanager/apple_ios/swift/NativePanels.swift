/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Blender's panels as SwiftUI: the Properties editor's, from the `properties` view (see
 * `interface_native_view.cc`). Each panel is a section that collapses from its header, its
 * controls in a card below; a value set here shows at once, until Blender's view has it too.
 */

import SwiftUI
import UIKit

typealias NativeOp = Blender_NativeUI_Op
typealias NativePhase = Blender_NativeUI_Phase

/* -------------------------------------------------------------------- */
/** \name Reading Nodes
 * \{ */

extension NativeNode {
  var label: String { node.label ?? "" }
  /** The label where space is tight. */
  var shortLabel: String { node.shortLabel ?? label }
  var icon: String? { node.icon }
  var enabled: Bool { node.enabled }
  var kind: Blender_NativeUI_Content { node.contentType }
  var role: Blender_NativeUI_Role { node.role }

  /** Its content, should it be of that kind: read as another, its fields would point anywhere. */
  func content<T: NativeContent>(_ type: T.Type) -> T? { kind == T.kind ? node.content(type: type) : nil }

  var panel: Blender_NativeUI_Panel? { content(Blender_NativeUI_Panel.self) }
  var toggle: Blender_NativeUI_Toggle? { content(Blender_NativeUI_Toggle.self) }
  var number: Blender_NativeUI_Number? { content(Blender_NativeUI_Number.self) }
  var choice: Blender_NativeUI_Choice? { content(Blender_NativeUI_Choice.self) }
  var reference: Blender_NativeUI_Reference? { content(Blender_NativeUI_Reference.self) }
  var list: Blender_NativeUI_List? { content(Blender_NativeUI_List.self) }
  var row: Blender_NativeUI_Row? { content(Blender_NativeUI_Row.self) }
  var group: Blender_NativeUI_Group? { content(Blender_NativeUI_Group.self) }

  /** Drawn in the header of the panel it is in. */
  var inHeader: Bool { role == .name || role == .visibility || role == .header }
}

/** A node's content of one kind. */
protocol NativeContent: FlatBufferObject {
  static var kind: Blender_NativeUI_Content { get }
}

extension Blender_NativeUI_Group: NativeContent { static var kind: Blender_NativeUI_Content { .group } }
extension Blender_NativeUI_Panel: NativeContent { static var kind: Blender_NativeUI_Content { .panel } }
extension Blender_NativeUI_Toggle: NativeContent { static var kind: Blender_NativeUI_Content { .toggle } }
extension Blender_NativeUI_Number: NativeContent { static var kind: Blender_NativeUI_Content { .number } }
extension Blender_NativeUI_TextField: NativeContent { static var kind: Blender_NativeUI_Content { .textfield } }
extension Blender_NativeUI_Choice: NativeContent { static var kind: Blender_NativeUI_Content { .choice } }
extension Blender_NativeUI_Color: NativeContent { static var kind: Blender_NativeUI_Content { .color } }
extension Blender_NativeUI_Reference: NativeContent { static var kind: Blender_NativeUI_Content { .reference } }
extension Blender_NativeUI_Button: NativeContent { static var kind: Blender_NativeUI_Content { .button } }
extension Blender_NativeUI_MenuButton: NativeContent { static var kind: Blender_NativeUI_Content { .menubutton } }
extension Blender_NativeUI_Label: NativeContent { static var kind: Blender_NativeUI_Content { .label } }
extension Blender_NativeUI_Separator: NativeContent { static var kind: Blender_NativeUI_Content { .separator } }
extension Blender_NativeUI_List: NativeContent { static var kind: Blender_NativeUI_Content { .list } }
extension Blender_NativeUI_Row: NativeContent { static var kind: Blender_NativeUI_Content { .row } }
extension Blender_NativeUI_Picture: NativeContent { static var kind: Blender_NativeUI_Content { .picture } }
extension Blender_NativeUI_Menu: NativeContent { static var kind: Blender_NativeUI_Content { .menu } }
extension Blender_NativeUI_Operator: NativeContent { static var kind: Blender_NativeUI_Content { .operator_ } }
extension Blender_NativeUI_Data: NativeContent { static var kind: Blender_NativeUI_Content { .data } }
extension Blender_NativeUI_Asset: NativeContent { static var kind: Blender_NativeUI_Content { .asset } }
extension Blender_NativeUI_Record: NativeContent { static var kind: Blender_NativeUI_Content { .record } }
extension Blender_NativeUI_Ramp: NativeContent { static var kind: Blender_NativeUI_Content { .ramp } }
extension Blender_NativeUI_Curve: NativeContent { static var kind: Blender_NativeUI_Content { .curve } }

extension Blender_NativeUI_Choice {
  var allOptions: [Blender_NativeUI_Option] { (0..<optionsCount).compactMap { options(at: $0) } }
}

extension Blender_NativeUI_Reference {
  var allOptions: [Blender_NativeUI_Option] { (0..<optionsCount).compactMap { options(at: $0) } }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Panels
 * \{ */

/** A value set here, observed per control so an edit redraws only its own control. */
@MainActor
@Observable
final class PendingNativeValue {
  var value: NativeValue?
}

/** Blender's panels of one kind, as the `properties` view sends them, and the edits made to them. */
@MainActor
@Observable
final class PanelsModel {
  enum Mode {
    /** The Properties editor, with its tabs. */
    case properties
    /** The viewport shading popover. */
    case shading
    /** Tool settings in the top bar, as one compact strip. */
    case toolStrip
    /** Blender's Preferences, a section at a time, in Settings. */
    case preferences
    /** The last operation's settings, to adjust it. */
    case redo
    /** An operation's settings, asked for before it runs. */
    case dialog
    /** Controls of a canvas, such as the node editor's nodes'. */
    case canvas
    /** A popover a panel's button opens, such as its header's presets (ROUND6 PANEL-8). */
    case popover
  }

  let mode: Mode
  let view: NativeView
  /** A tab chosen here, until Blender shows it. */
  private(set) var chosenTab: String?
  /** Panels opened or closed here, until Blender has them so. */
  private var expanding: [String: Bool] = [:]
  @ObservationIgnored private var pending: [String: PendingNativeValue] = [:]

  /** The controls of a view subscribed to apart, such as a canvas's. */
  init(view: NativeView) {
    mode = .canvas
    self.view = view
    view.settled = { [weak self] in self?.settle() }
  }

  init(mode: Mode, tab: String? = nil) {
    self.mode = mode
    var params: [String: NativeValue] = [:]
    if let tab { params["tab"] = .text(tab) }
    /* Properties' own Tool tab, not the toolbar's tool settings. */
    if mode == .properties { params["properties"] = .bool(true) }
    let name = switch mode {
      /* The tool's settings follow a change of tool at once. */
      case .toolStrip: "tool_settings"
      case .redo: "redo"
      case .dialog: "dialog"
      default: "properties"
    }
    view = NativeViews.shared.subscribe(name, params: params)
    view.settled = { [weak self] in self?.settle() }
  }

  /** Blender builds the view only while it shows. */
  func setShown(_ shown: Bool) {
    if shown {
      /* On the tab it showed. */
      if let tab = shownTab { view.params["tab"] = .text(tab) }
      NativeViews.shared.resume(view)
    }
    else {
      NativeViews.shared.pause(view)
    }
  }

  /** What the panels show, such as an object: controls drop their editing state when it changes. */
  var identity: String { view.top?.node.property ?? "" }
  var title: String { view.top?.label ?? "" }
  var loaded: Bool { view.top != nil }
  var hasContent: Bool { !identity.isEmpty || !panels.isEmpty }
  var status: String { view.error ?? "" }

  /** \name Tabs
   * \{ */

  var tabsNode: NativeNode? { view.node("tabs") }
  var tabs: [Blender_NativeUI_Option] { tabsNode?.choice?.allOptions ?? [] }
  var tabItems: [PanelTab] {
    tabs.map { PanelTab(id: $0.value ?? "", title: $0.label ?? "", icon: $0.icon ?? "", group: Int($0.group),
                        external: $0.external) }
  }
  /** The tab Blender shows. */
  var shownTab: String? { tabsNode?.choice?.value }
  var currentTab: String {
    if let tab = chosenTab ?? shownTab { return tab }
    if case .text(let tab)? = view.params["tab"] { return tab }
    return "OBJECT"
  }

  /** The tab's name, as Blender's Properties editor is titled by its tab ("Material"). */
  var tabTitle: String? {
    tabs.first { $0.value == currentTab }?.label.flatMap { $0.isEmpty ? nil : $0 }
  }

  /** Blender's context path under the tabs, such as the object and its material: each a label
   * with its type's icon (ROUND5 7B). None on the Tool tab and the sidebar's. */
  var pathItems: [NativeNode] {
    guard let path = view.node("path") else { return [] }
    return view.children(of: path)
  }

  /** The Properties tab of the active tool, first of the 3D view sidebar's group. */
  static let toolTab = "TOOL"
  /** One of the 3D view sidebar's categories (Item, View, add-ons'), which the bridge sends as
   * tabs named `SIDEBAR:<category>` (`interface_native_properties.cc`). */
  static func isSidebarCategory(_ tab: String) -> Bool { tab.hasPrefix("SIDEBAR:") }
  /** The Tool tab or one of the sidebar's: the group whose strip of words shows (decision 41). */
  static func inSidebarGroup(_ tab: String) -> Bool { tab == toolTab || isSidebarCategory(tab) }

  func selectTab(_ tab: String) {
    guard tab != currentTab else { return }
    chosenTab = tab
    /* Shown again on it. */
    view.params["tab"] = .text(tab)
    NativeViews.shared.send(view, target: "tabs", op: .set_, value: .text(tab))
  }

  /** \} */

  /** \name Panels and rows
   * \{ */

  var panels: [NativeNode] {
    guard let top = view.top else { return [] }
    return view.children(of: top).filter { $0.kind == .panel }
  }

  /** With several objects selected, which of them an edit goes to, and the switch for all of
   * them (decision R6-10, ROUND6 PANEL-6). */
  var editSelected: NativeNode? { view.node("edit_selected") }

  /** What the tab could not show, such as a whole panel, said at its foot (ROUND6 PANEL-1). */
  var elsewhere: NativeNode? {
    guard let top = view.top else { return nil }
    return view.children(of: top).first { $0.role == .elsewhere }
  }

  func isOpen(_ panel: NativeNode) -> Bool {
    guard let content = panel.panel else { return true }
    return content.fixed || (expanding[panel.key] ?? content.expanded)
  }

  func setOpen(_ panel: NativeNode, _ open: Bool) {
    withMotion { expanding[panel.key] = open }
    /* Blender sends its controls once it is open: they slide out, and what is below moves down. */
    if open { view.animatesNext = true }
    send(panel, open ? .open_ : .close)
  }

  /** A panel's children drawn in its body, rather than its header. */
  func body(of node: NativeNode) -> [NativeNode] {
    view.children(of: node).filter { node.kind != .panel || !$0.inHeader }
  }

  func header(of panel: NativeNode) -> [NativeNode] { view.children(of: panel).filter(\.inHeader) }

  func children(of node: NativeNode) -> [NativeNode] { view.children(of: node) }

  /** Every node under \a node, depth first. */
  func children(ofAll node: NativeNode) -> [NativeNode] {
    view.children(of: node).flatMap { [$0] + children(ofAll: $0) }
  }

  /** A child of \a node with \a role, such as a component's lock. */
  func attached(_ node: NativeNode, _ role: Blender_NativeUI_Role) -> NativeNode? {
    view.children(of: node).first { $0.role == role }
  }

  /** Every row of a panel's body: its controls, and its sub-panels' headings and, while open, their
   * rows below them. */
  func rows(of panel: NativeNode) -> [PanelRow] {
    var rows: [PanelRow] = []
    func walk(_ node: NativeNode, depth: Int) {
      for child in body(of: node) {
        if child.kind == .panel {
          rows.append(PanelRow(node: child, depth: depth, heading: true))
          if isOpen(child) { walk(child, depth: depth + 1) }
        }
        else {
          rows.append(PanelRow(node: child, depth: depth, heading: false))
        }
      }
    }
    walk(panel, depth: 0)
    return rows
  }

  /** \} */

  /** \name Values and edits
   * \{ */

  private func pendingValue(_ key: String) -> PendingNativeValue {
    if let existing = pending[key] { return existing }
    let created = PendingNativeValue()
    pending[key] = created
    return created
  }

  /** A value set here that Blender has yet to show. */
  func pending(_ node: NativeNode) -> NativeValue? { pendingValue(node.key).value }

  /** The selected items' values differ, until an edit gives them all one. */
  func isMixed(_ node: NativeNode) -> Bool { node.node.mixed && pending(node) == nil }

  func bool(_ node: NativeNode) -> Bool {
    if case .bool(let value)? = pending(node) { return value }
    return node.toggle?.value ?? false
  }

  func number(_ node: NativeNode) -> Double {
    switch pending(node) {
      case .float(let value)?: return value
      case .int(let value)?: return Double(value)
      default: return node.number?.value ?? 0
    }
  }

  func text(_ node: NativeNode) -> String {
    if case .text(let value)? = pending(node) { return value }
    switch node.kind {
      case .choice: return node.choice?.value ?? ""
      case .textfield: return node.content(Blender_NativeUI_TextField.self)?.value ?? ""
      case .label: return node.content(Blender_NativeUI_Label.self)?.value ?? ""
      default: return ""
    }
  }

  func floats(_ node: NativeNode) -> [Double] {
    if case .floats(let values)? = pending(node) { return values }
    guard let color = node.content(Blender_NativeUI_Color.self) else { return [] }
    return (0..<color.valueCount).map { color.value(at: $0) }
  }

  /** Set a node's value, shown at once. A drag sends its updates and its end as phases, which
   * Blender makes one undo step of. */
  func set(_ node: NativeNode, _ value: NativeValue, phase: NativePhase = .once) {
    let shown = pendingValue(node.key)
    shown.value = value
    send(node, .set_, value, phase: phase)
  }

  func send(_ node: NativeNode, _ op: NativeOp, _ value: NativeValue? = nil, phase: NativePhase = .once) {
    NativeViews.shared.send(view, target: node.key, op: op, value: value, phase: phase)
  }

  /** Blender answered every edit: its view shows them now. */
  private func settle() {
    for value in pending.values where value.value != nil { value.value = nil }
    if chosenTab != nil { chosenTab = nil }
    if !expanding.isEmpty { expanding.removeAll() }
  }

  /** \} */

  /** A text object's style, as the Text section reads it. */
  var textStyle: JSON? {
    guard let style = view.node("text_style") else { return nil }
    var result: JSON = [:]
    for child in view.children(of: style) {
      let name = String(child.key.dropFirst("text_style:".count))
      switch child.kind {
        case .toggle: result[name] = NSNumber(value: child.toggle?.value == true ? 1 : 0)
        case .number: result[name] = NSNumber(value: child.number?.value ?? 0)
        default: result[name] = text(child)
      }
    }
    return result
  }
}

/** A tab of the panels, as Settings lists the Preferences' sections. */
struct PanelTab: Identifiable, Equatable {
  let id: String
  let title: String
  let icon: String
  /** Tabs Blender lists apart, as the Preferences' sections. */
  var group = 0
  /** A Preferences section only Blender's own Preferences show. */
  var external = false
}

/** A row of a panel's card: a control, or a sub-panel's heading. */
struct PanelRow: Identifiable {
  let node: NativeNode
  let depth: Int
  let heading: Bool
  var id: String { node.key }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Properties
 * \{ */

/**
 * Blender's Properties editor (ROUND5 7B, decision 28): its tabs in a column at the leading edge,
 * the active tab's name as the title, Blender's context path under it, and the tab's panels, each
 * one box. The 3D Viewport sidebar's tabs, which have names and no icons, are a strip of words
 * above the panels only while the Tool tab or one of them is open, reading Tool · Item · View ·
 * …, the open one lit (ROUND5 7E/E1, decision 41); Properties' own tabs have no strip.
 */
struct PropertiesPanel: View {
  let model: PanelsModel
  let close: () -> Void
  @AppStorage(ShellStyle.key) private var style = ShellStyle.blender.rawValue

  var body: some View {
    /* The sidebar's group: the Tool tab, which has an icon, and the sidebar's categories. */
    let strip = PanelsModel.inSidebarGroup(model.currentTab) &&
      model.tabItems.contains { PanelsModel.isSidebarCategory($0.id) }
    VStack(spacing: 0) {
      PanelHeader(title: model.tabTitle ?? "Properties", close: close) { EmptyView() }
      HStack(alignment: .top, spacing: 0) {
        PropertiesTabColumn(model: model)
          .zIndex(1)
        VStack(spacing: 0) {
          if strip {
            PanelsTabs(model: model, namedOnly: true)
              .padding(.horizontal, 8)
              .frame(height: 40)
          }
          PropertiesContextPath(model: model)
          /* The Tool tab as Blender's: the active tool and the mode's Tool panels, brush and all. */
          PanelsForm(model: model)
        }
      }
    }
    .tint(PanelStyle.tint)
  }
}

/**
 * The Properties editor's tabs as Blender draws them: a column of icons at its leading edge, in
 * Blender's order with a gap between its groups, on Blender's darker navigation-bar grey, the
 * active one in the editor's grey joining the content beside it (the accent in glass). The column scrolls where the tabs do not
 * fit, and brings the active tab into view when it appears and whenever the tab or the tabs
 * change (ROUND5 7B, report 28). A hold names a tab.
 */
struct PropertiesTabColumn: View {
  let model: PanelsModel
  @AppStorage(ShellStyle.key) private var style = ShellStyle.blender.rawValue
  /** The tab held, named beside it. */
  @State private var held: String?
  @State private var heldToName = false

  static let width: CGFloat = 40

  var body: some View {
    let tabs = model.tabItems.filter { BlenderIcon.image($0.icon) != nil }
    let glass = style == ShellStyle.glass.rawValue
    ScrollViewReader { reader in
      ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 2) {
          ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
            if index > 0 && tab.group != tabs[index - 1].group {
              /* Blender's gap between its groups of tabs. */
              Color.clear.frame(height: 8)
            }
            cell(tab, glass: glass)
          }
        }
        .padding(.vertical, 4)
      }
      .scrollClipDisabled()
      .onChange(of: model.currentTab + "|" + tabs.map(\.id).joined(separator: ","), initial: true) { _, _ in
        /* On a tab chosen before the column existed too, such as by a reveal. */
        let tab = model.currentTab
        DispatchQueue.main.async { withMotion { reader.scrollTo(tab, anchor: .center) } }
      }
    }
    .frame(width: Self.width)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(glass ? Color.clear : ShellStyle.navigationBar)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Tabs")
  }

  private func cell(_ tab: PanelTab, glass: Bool) -> some View {
    /* The Tool tab stays lit while one of the sidebar's tabs is open: they are one group, its
     * strip of words above the panels (decision 41). */
    let selected = tab.id == model.currentTab ||
      tab.id == PanelsModel.toolTab && PanelsModel.isSidebarCategory(model.currentTab)
    /* Rounded on its leading side; the active one reaches the column's trailing edge, where the
     * content begins. */
    let shape = UnevenRoundedRectangle(topLeadingRadius: glass ? 8 : ShellStyle.radius,
                                       bottomLeadingRadius: glass ? 8 : ShellStyle.radius,
                                       bottomTrailingRadius: glass ? 8 : 0, topTrailingRadius: glass ? 8 : 0,
                                       style: .continuous)
    return Button {
      if heldToName {
        heldToName = false
        return
      }
      model.selectTab(tab.id)
      Haptics.selection()
    } label: {
      Group {
        if let image = BlenderIcon.image(tab.icon, themed: !(glass && selected)) {
          Image(uiImage: image).resizable().scaledToFit().frame(width: 20, height: 20)
        }
      }
      .foregroundStyle(selected && glass ? Color.white : .primary)
      .frame(width: 36, height: 36)
      .background(selected ? (glass ? Color.accentColor : ShellStyle.region) : .clear, in: shape)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(width: Self.width, alignment: glass ? .center : .trailing)
    .overlay(alignment: .leading) {
      if held == tab.id {
        ShellNameLabel(text: tab.title)
          .offset(x: Self.width + 6)
          .transition(.opacity)
      }
    }
    .simultaneousGesture(
      LongPressGesture(minimumDuration: 0.4, maximumDistance: 12)
        .onEnded { _ in
          Haptics.selection()
          heldToName = true
          withAnimation(.easeOut(duration: 0.12)) { held = tab.id }
        }
        .sequenced(before: DragGesture(minimumDistance: 0))
        .onEnded { _ in
          withAnimation(.easeOut(duration: 0.12)) { held = nil }
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { heldToName = false }
        })
    .id(tab.id)
    .zIndex(held == tab.id ? 1 : 0)
    .accessibilityLabel(tab.title)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier(tab.id)
    .help(tab.title)
  }
}

/**
 * Blender's context path under the Properties editor's title (`buttons_panel_context_draw`): each
 * element's icon and name, Blender's small arrow between them, the last one in semibold, such as
 * `▣ Cube › ● Shirt`. It scrolls sideways when long; no name is cut. Blender's pin is left out:
 * the detached editor Properties is built from keeps no pinned data-block between requests.
 */
struct PropertiesContextPath: View {
  let model: PanelsModel

  var body: some View {
    let items = model.pathItems
    if !items.isEmpty {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
          ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if index > 0 {
              IconView(name: "RIGHTARROW", symbol: "chevron.right", size: 12)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
              IconView(name: item.icon, size: 16)
              if !item.label.isEmpty {
                Text(item.label)
                  .font(.subheadline.weight(index == items.count - 1 ? .semibold : .regular))
                  .lineLimit(1)
                  .fixedSize()
              }
            }
            .foregroundStyle(.primary)
            .accessibilityElement(children: .combine)
          }
        }
        .padding(.horizontal, 12)
      }
      .softHorizontalScrollEdge()
      .frame(height: 30)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Context")
      .accessibilityIdentifier("blender.properties.path")
    }
  }
}

struct PanelsTabs: View {
  let model: PanelsModel
  /** Only the 3D view sidebar's group (Tool, Item, View, …) as words, beside the Properties
   * editor's column while one of them is open (decision 41). */
  var namedOnly = false
  /** Whether more tabs lie past the leading and trailing edges, which fade there. */
  @State private var more = (leading: false, trailing: false)
  @State private var content = CGRect.zero
  @State private var container: CGFloat = 0

  private func updateMore() {
    let next = (leading: content.minX < -1, trailing: content.maxX > container + 1)
    if next != more {
      withAnimation(.easeOut(duration: 0.15)) { more = next }
    }
  }

  var body: some View {
    /* Beside the column: the sidebar's group, Tool first, all as words (decision 41). */
    let tabs = model.tabs.filter { !namedOnly || PanelsModel.inSidebarGroup($0.value ?? "") }
    ScrollViewReader { reader in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 2) {
          ForEach(tabs, id: \.value) { tab in
            let id = tab.value ?? ""
            let selected = id == model.currentTab
            Button {
              model.selectTab(id)
              Haptics.selection()
            } label: {
              Group {
                /* Selected tabs draw a white glyph on the blue highlight, as iOS does. */
                if !namedOnly, let image = BlenderIcon.image(tab.icon, themed: !selected) {
                  Image(uiImage: image).resizable().scaledToFit().frame(width: 22, height: 22)
                }
                else {
                  /* The 3D Viewport sidebar's tabs, add-ons' among them, are named as Blender's
                   * sidebar names them: they have no icons. */
                  Text(tab.label ?? "")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                }
              }
              .foregroundStyle(selected ? Color.white : .secondary)
              .frame(minWidth: 42, minHeight: 42, maxHeight: 42)
              .background(selected ? (ShellStyle.current == .glass ? Color.accentColor : ShellStyle.selection) : .clear,
                          in: RoundedRectangle(cornerRadius: ShellStyle.current == .glass ? 8 : ShellStyle.radius,
                                               style: .continuous))
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(id)
            .accessibilityLabel(tab.label ?? "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier(id)
            .help(tab.label ?? "")
          }
        }
        /* Where the tabs are in the strip, as they scroll. */
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("tabs")) } action: { frame in
          content = frame
          updateMore()
        }
      }
      .coordinateSpace(.named("tabs"))
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
        container = width
        updateMore()
      }
      .mask {
        /* Wide and eased, so tabs clearly run on past the edge. */
        let fade = Gradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.25), location: 0.35),
                                    .init(color: .black, location: 1)])
        HStack(spacing: 0) {
          LinearGradient(gradient: fade, startPoint: .leading, endPoint: .trailing)
            .frame(width: more.leading ? 64 : 0)
          Color.black
          LinearGradient(gradient: fade, startPoint: .trailing, endPoint: .leading)
            .frame(width: more.trailing ? 64 : 0)
        }
        .animation(.easeOut(duration: 0.2), value: more.leading)
        .animation(.easeOut(duration: 0.2), value: more.trailing)
      }
      .onChange(of: model.currentTab) { _, tab in
        withMotion { reader.scrollTo(tab, anchor: .center) }
      }
    }
  }
}

struct PanelsForm: View {
  let model: PanelsModel
  /** False to measure the form's natural height. */
  var scrolls = true

  var body: some View {
    if scrolls {
      ScrollView { content }
        .dismissesKeyboardOnScroll(interactively: true)
        .overlay {
          if model.loaded && !model.hasContent && model.mode == .properties {
            ContentUnavailableView("No Active Object", systemImage: "cube.transparent")
          }
          else if !model.loaded && (model.mode == .shading || model.mode == .preferences) {
            ProgressView()
          }
        }
    }
    else {
      content.fixedSize(horizontal: false, vertical: true)
    }
  }

  private var content: some View {
    /* Not lazy: lazy stacks stay empty when they first appear in a hidden, unsized panel. A
     * column exactly as wide as the form, so no row can widen it past its panel (ROUND5 7A). */
    /* Blender's panels: boxes 8 points from the editor's edges and 6 apart (ROUND5 7B). */
    PanelColumn(spacing: 6) {
      let style = model.textStyle
      let first = model.panels.first?.key
      if let editSelected = model.editSelected {
        PanelBox {
          EditSelectedRow(model: model, node: editSelected)
            .padding(8)
        }
      }
      ForEach(model.panels) { panel in
        if let style, panel.key == "panel:DATA_PT_font" {
          /* A text object's font, styles and spacing together; Blender's Font panel stays below
           * for the rest, such as its bold and italic fonts and text on a curve. */
          PanelBox {
            Text("Text")
              .font(.subheadline.weight(.semibold))
              .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
              .padding(.leading, 8)
            TextStyleSection(style: style)
              .padding([.horizontal, .bottom], 8)
          }
          PanelSection(model: model, panel: panel, title: "More Font Options")
        }
        else if style != nil && panel.key == "panel:DATA_PT_paragraph" {
          /* Its alignment and spacing are in the Text section. */
          EmptyView()
        }
        else {
          PanelSection(model: model, panel: panel, shadingHint: panel.key == first && model.mode == .properties)
        }
      }
      if let elsewhere = model.elsewhere {
        PanelBox {
          ElsewhereRow(model: model, node: elsewhere)
            .padding(8)
        }
      }
      if !model.status.isEmpty {
        Text(model.status)
          .font(.footnote)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
          .transition(.opacity)
      }
    }
    .padding(.horizontal, 8)
    .padding(.top, 4)
    .padding(.bottom, 16)
  }
}

/**
 * A column exactly as wide as it is offered (ROUND5 7A, class "content wider than what holds it"):
 * each child is laid out at that width, one below the other, so no child can widen the column
 * and push the form past its panel, as a `VStack` does for a child wider than it. A child that
 * needs more width than it has is still laid out in what there is; with \a overflow, such as
 * `properties MATERIAL panel:…`, that is logged as `layout <overflow> needs W of P`.
 */
struct PanelColumn: Layout {
  var spacing: CGFloat = 0
  /** What to log a row needing more width than the column has as; nothing when nil. */
  var overflow: String? = nil

  private func width(_ proposal: ProposedViewSize) -> CGFloat? {
    proposal.width.flatMap { $0.isFinite ? $0 : nil }
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = width(proposal)
    var height: CGFloat = 0
    var widest: CGFloat = 0
    for (index, subview) in subviews.enumerated() {
      let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
      widest = max(widest, size.width)
      height += size.height + (index > 0 ? spacing : 0)
    }
    if let width, width > 0, widest > width + 1, let overflow {
      /* Not while laying out: the checker may show a message. */
      let line = "\(overflow) needs \(Int(widest.rounded(.up))) of \(Int(width))"
      DispatchQueue.main.async {
        MainActor.assumeIsolated { LayoutChecker.shared.overflow(overflow, line) }
      }
    }
    return CGSize(width: width ?? widest, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for subview in subviews {
      let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
      subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: height))
      y += height + spacing
    }
  }
}

extension NativeNode: Identifiable {
  nonisolated var id: String { key }
}

/**
 * A panel as Blender draws it (ROUND5 7B, decision 28): one box holding its header and its body,
 * the panels' grey on the editor's, no lines between rows. The header is Blender's triangle, the
 * panel's icon, its name, its own controls and, in a stack that can be reordered, the grip; a tap
 * opens or closes it, and the body slides out from under the header, clipped by the box. A
 * sub-panel is a header inside its parent's body, its own body on a darker ground. A panel
 * without a header, such as a material's slots, is a box with its body alone.
 */
struct PanelSection: View {
  let model: PanelsModel
  let panel: NativeNode
  var title: String?
  /** Its controls alone, without its header or box, as in a popover of its own. */
  var bare = false
  /** The first panel of a Properties tab: it ends saying what the viewport's shading hides of
   * the tab, see #ShadingHint. */
  var shadingHint = false
  /** Another of the stack's panels dragged over this one, which takes its place. */
  @State private var dropping = false

  private var content: Blender_NativeUI_Panel? { panel.panel }
  private var position: Int? { content.flatMap { $0.position >= 0 ? Int($0.position) : nil } }

  /** A row of its body needing more width than the body has: logged, at most once a minute, as
   * `layout properties <tab> <panel> needs W of P` (ROUND5 7A). */
  private var overflow: String { "properties \(model.currentTab) \(panel.key)" }

  var body: some View {
    let fixed = content?.fixed ?? false
    let expanded = model.isOpen(panel)
    let nodes = model.body(of: panel)
    Group {
      if bare {
        PanelBody(model: model, panel: panel, overflow: overflow)
      }
      else if let single = barePicker(nodes) {
        /* The shading mode picker is already a pill: a box around it would nest the shape. */
        ControlRow(model: model, node: single)
      }
      else {
        PanelBox {
          if !fixed {
            draggableHeader(expanded: expanded)
          }
          /* The body slides out from under its header: the box clips it as its height animates,
           * so it never passes over the header or the panel above. */
          if expanded && !nodes.isEmpty {
            PanelBody(model: model, panel: panel, overflow: overflow, shadingHint: shadingHint)
              .padding(.horizontal, 8)
              .padding(.top, fixed ? 8 : 0)
              .padding(.bottom, 8)
              .transition(.opacity.combined(with: .move(edge: .top)))
          }
        }
      }
    }
    .overlay(alignment: .top) {
      if dropping {
        Capsule().fill(Color.accentColor).frame(height: 3).offset(y: -2)
      }
    }
    .onDrop(of: [.plainText], isTargeted: position == nil ? .constant(false) : $dropping) { providers in
      guard let target = position, let provider = providers.first else { return false }
      _ = provider.loadObject(ofClass: NSString.self) { payload, _ in
        guard let payload = payload as? String, payload.hasPrefix(Self.dragPrefix) else { return }
        let dragged = String(payload.dropFirst(Self.dragPrefix.count))
        DispatchQueue.main.async {
          guard dragged != panel.key, let node = model.view.node(dragged) else { return }
          model.send(node, .move, .text(String(target)))
          Haptics.impact()
        }
      }
      return true
    }
  }

  /** A dragged panel, as text naming it, which only the stack reads. */
  static let dragPrefix = "blender.panel\n"

  /** A stack's panel drags by its header to another place, as in Blender. */
  @ViewBuilder
  private func draggableHeader(expanded: Bool) -> some View {
    if position != nil {
      header(expanded: expanded)
        .onDrag { NSItemProvider(object: (Self.dragPrefix + panel.key) as NSString) } preview: {
          Label(title ?? panel.label, systemImage: "line.3.horizontal")
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
        }
    }
    else {
      header(expanded: expanded)
    }
  }

  /** The viewport shading's mode picker, alone in its panel. */
  private func barePicker(_ nodes: [NativeNode]) -> NativeNode? {
    guard model.mode == .shading, nodes.count == 1, let choice = nodes[0].choice,
          nodes[0].node.property == "type", choice.style != .actions else { return nil }
    return nodes[0]
  }

  private func header(expanded: Bool) -> some View {
    /* A physics that is off is only its switch. */
    let switchOnly = !(content?.openable ?? true)
    let active = content?.active ?? false
    let id = String(panel.key.dropFirst("panel:".count))
    return HStack(spacing: 6) {
      Button {
        guard !switchOnly else { return }
        model.setOpen(panel, !expanded)
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .frame(width: 12, height: 12)
            .opacity(switchOnly ? 0 : 1)
          if let icon = BlenderIcon.image(panel.icon) {
            Image(uiImage: icon).resizable().scaledToFit().frame(width: 16, height: 16)
          }
          /* Blender's panel name: wraps rather than being cut. */
          Text(title ?? panel.label)
            .font(.subheadline.weight(.semibold))
            .lineLimit(2)
            .foregroundStyle(active ? PanelStyle.tint : .primary)
          Spacer(minLength: 0)
        }
        .frame(minHeight: 32)
        /* Blender's 32 point header, touched across 44 points. */
        .contentShape(.interaction, Rectangle().inset(by: -6))
      }
      .buttonStyle(.plain)
      .disabled(switchOnly)
      .accessibilityValue((expanded ? "Expanded" : "Collapsed") + (active ? ", Active" : ""))
      .accessibilityIdentifier("blender.section." + id)
      PanelHeaderControls(model: model, controls: model.header(of: panel))
      if position != nil {
        /* Blender's grip: the panel drags by its header. */
        Image(systemName: "line.3.horizontal")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 20, height: 32)
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, 8)
  }
}

/** A panel's box: Blender's panel grey (or the glass's card) with Blender's rounding, clipping
 * what is in it. */
struct PanelBox<Content: View>: View {
  @ViewBuilder let content: Content
  @AppStorage(ShellStyle.key) private var style = ShellStyle.blender.rawValue

  var body: some View {
    let glass = style == ShellStyle.glass.rawValue
    let shape = RoundedRectangle(cornerRadius: glass ? 14 : ShellStyle.radius, style: .continuous)
    PanelColumn(spacing: 0) { content }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .background(glass ? PanelStyle.card : ShellStyle.panel, in: shape)
      .clipShape(shape)
  }
}

/** A panel's body: a modifier's or constraint's name first, then its rows and sub-panels, each
 * laid out at the body's width (ROUND5 7A). */
struct PanelBody: View {
  let model: PanelsModel
  let panel: NativeNode
  var overflow: String? = nil
  /** Ends saying what the viewport's shading hides of the tab, see #ShadingHint. */
  var shadingHint = false

  var body: some View {
    let nodes = model.body(of: panel)
    /* Where a data-block is linked from joins its row, as Blender draws a material slot's Link. */
    let reference = nodes.first { $0.kind == .reference }
    let link = reference == nil ? nil : nodes.first { $0.role == .link }
    PanelColumn(spacing: 4, overflow: overflow) {
      /* A modifier's or constraint's name and the rest of where it applies, open. */
      let header = model.header(of: panel)
      if panel.kind == .panel, let name = header.first(where: { $0.role == .name }) {
        PanelStackOptions(model: model, name: name, toggles: PanelStackOptions.secondary(header))
      }
      ForEach(Self.runs(nodes.filter { $0 !== link }), id: \.first!.key) { run in
        if run.count > 1 {
          /* Buttons side by side, as Assign, Select and Deselect: joined (ROUND5 7C). */
          NativeButtonRow(model: model, buttons: run)
        }
        else if run[0].kind == .panel {
          SubPanel(model: model, panel: run[0])
        }
        else if run[0] === reference {
          ControlRow(model: model, node: run[0], link: link)
        }
        else if run[0].role == .elsewhere {
          ElsewhereRow(model: model, node: run[0])
        }
        else {
          ControlRow(model: model, node: run[0])
          if let note = Self.assignNote(model, run[0]) {
            PanelNote(text: note)
          }
        }
      }
      if shadingHint, let shell = ShellModel.current,
         let entry = ShadingHint.entry(tab: model.currentTab, shading: shell.shading,
                                       path: model.pathItems.map { $0.icon ?? "" })
      {
        ShadingHintRow(entry: entry)
      }
    }
  }

  /** Under a material's slots outside Edit Mode, with more than one slot: where faces are given
   * one (ROUND5 7D.5). In Edit Mode, Assign, Select and Deselect are under the slots. */
  static func assignNote(_ model: PanelsModel, _ node: NativeNode) -> String? {
    guard node.kind == .list, node.key.contains("active_material_index"),
          model.children(of: node).filter({ $0.kind == .row }).count > 1,
          let mode = ShellModel.current?.mode, !mode.contains("edit") else { return nil }
    return "Assign to faces in Edit Mode."
  }

  /** The body's nodes, one to a row, but for buttons that follow one another with text of their
   * own, which Blender lays out in one row (two to four of them). */
  static func runs(_ nodes: [NativeNode]) -> [[NativeNode]] {
    var runs: [[NativeNode]] = []
    func joinable(_ node: NativeNode) -> Bool {
      node.kind == .button && node.role == .none_ && node.content(Blender_NativeUI_Button.self)?.iconOnly != true
        && !node.label.isEmpty
    }
    for node in nodes {
      if joinable(node), let last = runs.last, last.count < 4, last.allSatisfy(joinable) {
        runs[runs.count - 1].append(node)
      }
      else {
        runs.append([node])
      }
    }
    return runs
  }
}

/** A line of explanation under a panel's rows, in the secondary colour with Blender's info icon. */
struct PanelNote: View {
  let text: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      IconView(name: "INFO", symbol: "info.circle", size: 14)
        .foregroundStyle(.secondary)
      Text(text)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }
}

/** With several objects selected (decision R6-10, ROUND6 PANEL-6): Blender's line saying which
 * of them an edit goes to, "Editing the active object of 3 selected" or "Editing 3 objects", and
 * the switch between the two, as the desktop's Alt. */
struct EditSelectedRow: View {
  let model: PanelsModel
  let node: NativeNode

  var body: some View {
    let on = model.bool(node)
    Toggle(isOn: Binding(get: { on }, set: { model.set(node, .bool($0)); Haptics.selection() })) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Edit All Selected")
          .font(.subheadline)
        Text(node.label)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .disabled(!node.enabled)
    .accessibilityIdentifier("blender.edit-selected")
  }
}

/** What a panel, or the tab, could not show, and the way to where Blender draws all of it (ROUND6
 * PANEL-1, decision R6-9): the bridge's line, such as "2 controls of this panel are only in the
 * Desktop Interface.", and a button there. */
struct ElsewhereRow: View {
  let model: PanelsModel
  let node: NativeNode

  var body: some View {
    PanelColumn(spacing: 4) {
      PanelNote(text: node.label)
      Button {
        model.send(node, .invoke)
        Haptics.selection()
      } label: {
        BlenderWidgetFace(icon: BlenderIcon.image(node.icon), text: "Show in Desktop Interface", on: false, fills: true)
      }
      .buttonStyle(.plain)
      .disabled(!node.enabled)
      .accessibilityIdentifier("blender.elsewhere")
    }
  }
}

/** What the viewport's shading hides of the tab, and the button that shows it (#ShadingHint). */
struct ShadingHintRow: View {
  let entry: ShadingHint.Entry

  var body: some View {
    PanelColumn(spacing: 4) {
      PanelNote(text: entry.text)
      Button {
        ShadingHint.apply(entry)
        Haptics.selection()
      } label: {
        BlenderWidgetFace(icon: BlenderIcon.image(entry.shading == "MATERIAL" ? "SHADING_TEXTURE" : "SHADING_RENDERED"),
                          text: entry.button, on: false, fills: true)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("blender.shading-hint")
    }
  }
}

/** A sub-panel, as Blender draws one inside its parent: its header row, and its body on a darker
 * ground below it while open. */
struct SubPanel: View {
  let model: PanelsModel
  let panel: NativeNode

  var body: some View {
    let open = model.isOpen(panel)
    let id = String(panel.key.dropFirst("panel:".count))
    PanelColumn(spacing: 0) {
      HStack(spacing: 6) {
        Button {
          model.setOpen(panel, !open)
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "chevron.right")
              .font(.system(size: 9, weight: .bold))
              .rotationEffect(.degrees(open ? 90 : 0))
              .frame(width: 12, height: 12)
            Text(panel.label)
              .font(.subheadline)
              .lineLimit(2)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(minHeight: 32)
          .contentShape(.interaction, Rectangle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("blender.subpanel." + id)
        PanelHeaderControls(model: model, controls: model.header(of: panel))
      }
      if open && !model.body(of: panel).isEmpty {
        /* Blender's `panel_sub_back`: the sub-panel's body a shade darker than its parent's. */
        AnyView(PanelBody(model: model, panel: panel))
          .padding(8)
          .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: ShellStyle.radius, style: .continuous))
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .clipped()
  }
}

/** A modifier's or constraint's name, which a tap renames, and the switches for where else it
 * applies, such as Edit Mode, On Cage and Render, in the first row of its open panel. Its header
 * keeps the main one, as Blender's does. */
struct PanelStackOptions: View {
  let model: PanelsModel
  let name: NativeNode
  let toggles: [NativeNode]
  @State private var rename: RenameRequest?

  /** The switch the header shows: the viewport's, or a constraint's only one. */
  static func primary(_ controls: [NativeNode]) -> NativeNode? {
    let cluster = controls.filter { $0.role == .visibility }
    return cluster.first { $0.node.property == "show_viewport" } ?? cluster.first
  }

  static func secondary(_ controls: [NativeNode]) -> [NativeNode] {
    let main = primary(controls)
    return controls.filter { $0.role == .visibility && $0 !== main }
  }

  var body: some View {
    let current = model.text(name)
    HStack(spacing: 8) {
      Button {
        rename = RenameRequest(title: "Rename", name: current) { text in
          model.set(name, .text(text))
        }
      } label: {
        HStack(spacing: 6) {
          Text(current)
            .lineLimit(1)
            .truncationMode(.middle)
          Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!name.enabled)
      .accessibilityLabel("Name")
      .accessibilityValue(current)
      .accessibilityHint("Renames it.")
      ForEach(toggles) { toggle in
        switchButton(toggle)
      }
    }
    .renamePrompt($rename)
  }

  private func switchButton(_ toggle: NativeNode) -> some View {
    let on = model.bool(toggle)
    return Button {
      model.set(toggle, .bool(!on))
      Haptics.selection()
    } label: {
      Group {
        if let icon = BlenderIcon.image(toggle.icon) {
          Image(uiImage: icon).resizable().renderingMode(.template).scaledToFit().frame(width: 18, height: 18)
        }
        else {
          Image(systemName: on ? "checkmark.circle.fill" : "circle")
        }
      }
      .foregroundStyle(on ? AnyShapeStyle(PanelStyle.tint) : AnyShapeStyle(.tertiary))
      .frame(width: 36, height: 36)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!toggle.enabled)
    .controlActions(model, toggle)
    .accessibilityLabel(toggle.label)
    .accessibilityAddTraits(on ? .isSelected : [])
  }
}

/** A panel header's own switches and buttons, such as a modifier's visibility and Remove. */
struct PanelHeaderControls: View {
  let model: PanelsModel
  let controls: [NativeNode]

  var body: some View {
    HStack(spacing: 8) {
      /* A modifier or constraint keeps its main switch here; its name and other switches are in
       * its open panel. */
      let main = PanelStackOptions.primary(controls)
      let shown = controls.filter { $0.role != .name && ($0.role != .visibility || $0 === main) }
      ForEach(shown) { control in
        Group {
          switch control.kind {
            case .toggle:
              /* As Blender's header draws it (ROUND5 7C: one way to draw a setting): its own icon
               * as a toggle button, else a checkbox; the panel's name is the label. */
              PanelHeaderToggle(model: model, node: control)
            case .button:
              HeaderButton(model: model, node: control)
            case .menubutton:
              HeaderMenuButton(model: model, node: control)
            default:
              EmptyView()
          }
        }
        .controlActions(model, control)
        .fixedSize()
      }
    }
  }
}

/** A toggle in a panel's header: Blender's icon toggle, or its checkbox without a name. */
struct PanelHeaderToggle: View {
  let model: PanelsModel
  let node: NativeNode

  var body: some View {
    let on = model.bool(node)
    let mixed = model.isMixed(node)
    let icon = node.icon.flatMap { $0.isEmpty || $0.hasPrefix("CHECKBOX") ? nil : BlenderIcon.image($0) }
    Group {
      if let icon {
        BlenderToggleButton(name: node.label, icon: icon, isOn: on && !mixed) { model.set(node, .bool(!on)) }
      }
      else {
        Toggle(isOn: Binding(get: { on && !mixed }, set: { model.set(node, .bool($0)) })) { EmptyView() }
          .toggleStyle(BlenderCheckboxStyle())
          .accessibilityLabel(node.label)
      }
    }
    .disabled(!node.enabled)
    .accessibilityValue(mixed ? "Mixed" : "")
  }
}

/** \} */
