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

  func isOpen(_ panel: NativeNode) -> Bool {
    guard let content = panel.panel else { return true }
    return content.fixed || (expanding[panel.key] ?? content.expanded)
  }

  func setOpen(_ panel: NativeNode, _ open: Bool) {
    withMotion { expanding[panel.key] = open }
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

struct PropertiesPanel: View {
  let model: PanelsModel
  let close: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      PanelHeader(title: model.hasContent ? model.title : "Properties", close: close) { EmptyView() }
      PanelsTabs(model: model)
        .padding(.horizontal, 8)
        .frame(height: 44)
      /* The Tool tab as Blender's: the active tool and the mode's Tool panels, brush and all. */
      PanelsForm(model: model)
        .padding(.top, 4)
    }
    .tint(PanelStyle.tint)
  }
}

struct PanelsTabs: View {
  let model: PanelsModel
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
    ScrollViewReader { reader in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 2) {
          ForEach(model.tabs, id: \.value) { tab in
            let id = tab.value ?? ""
            let selected = id == model.currentTab
            Button {
              model.selectTab(id)
              Haptics.selection()
            } label: {
              Group {
                /* Selected tabs draw a white glyph on the blue highlight, as iOS does. */
                if let image = BlenderIcon.image(tab.icon, themed: !selected) {
                  Image(uiImage: image).resizable().scaledToFit().frame(width: 22, height: 22)
                }
              }
              .foregroundStyle(selected ? Color.white : .secondary)
              .frame(width: 42, height: 42)
              .background(selected ? Color.accentColor : .clear,
                          in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    /* Not lazy: lazy stacks stay empty when they first appear in a hidden, unsized panel. */
    /* Spaced like an inset grouped table: a 44 point header right above its card. */
    VStack(alignment: .leading, spacing: 17) {
      let style = model.textStyle
      ForEach(model.panels) { panel in
        if let style, panel.key == "panel:DATA_PT_font" {
          /* A text object's font, styles and spacing together; Blender's Font panel stays below
           * for the rest, such as its bold and italic fonts and text on a curve. */
          VStack(alignment: .leading, spacing: 0) {
            Text("Text")
              .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
              .padding(.leading, 12)
            TextStyleSection(style: style)
          }
          PanelSection(model: model, panel: panel, title: "More Font Options")
        }
        else if style != nil && panel.key == "panel:DATA_PT_paragraph" {
          /* Its alignment and spacing are in the Text section. */
          EmptyView()
        }
        else {
          PanelSection(model: model, panel: panel)
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
    .padding(.horizontal, 16)
    .padding(.top, 3)
    .padding(.bottom, 16)
  }
}

extension NativeNode: Identifiable {
  nonisolated var id: String { key }
}

/** A panel: its header, and its controls in a card that slides out from under it. */
struct PanelSection: View {
  let model: PanelsModel
  let panel: NativeNode
  var title: String?
  /** Its controls alone, without its header, as in a popover of its own. */
  var bare = false
  /** Another of the stack's panels dragged over this one, which takes its place. */
  @State private var dropping = false

  private var content: Blender_NativeUI_Panel? { panel.panel }
  private var position: Int? { content.flatMap { $0.position >= 0 ? Int($0.position) : nil } }

  var body: some View {
    let fixed = bare || (content?.fixed ?? false)
    let expanded = bare || model.isOpen(panel)
    VStack(alignment: .leading, spacing: 0) {
      if !fixed {
        draggableHeader(expanded: expanded)
      }
      let rows = model.rows(of: panel)
      /* The card slides out from under its header: the container clips it as its height animates,
       * so it never passes over the header or the section above. */
      VStack(spacing: 0) {
        if expanded && !rows.isEmpty {
          Group {
            if bare(rows) {
              ControlRow(model: model, node: rows[0].node)
            }
            else {
              VStack(alignment: .leading, spacing: 0) {
                /* A modifier's or constraint's name and the rest of where it applies, open. */
                let header = model.header(of: panel)
                if let name = header.first(where: { $0.role == .name }) {
                  PanelStackOptions(model: model, name: name, toggles: PanelStackOptions.secondary(header))
                    .padding(.vertical, 2)
                  Divider()
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                  if index > 0 { Divider() }
                  rowView(row)
                    .padding(.vertical, 2)
                }
              }
              .padding(.horizontal, 12)
              .background(PanelStyle.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
          }
          .transition(.opacity.combined(with: .move(edge: .top)))
        }
      }
      .frame(maxWidth: .infinity, alignment: .top)
      .clipped()
    }
    .padding(.top, fixed ? 8 : 0)
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

  /** The shading mode picker is already a pill; a card around it nests the shape. */
  private func bare(_ rows: [PanelRow]) -> Bool {
    guard model.mode == .shading, rows.count == 1, let choice = rows[0].node.choice else { return false }
    return rows[0].node.node.property == "type" && choice.style != .actions
  }

  private func header(expanded: Bool) -> some View {
    /* A physics that is off is only its switch. */
    let switchOnly = !(content?.openable ?? true)
    let active = content?.active ?? false
    let id = String(panel.key.dropFirst("panel:".count))
    return HStack(spacing: 8) {
      Button {
        guard !switchOnly else { return }
        model.setOpen(panel, !expanded)
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .frame(width: 14, height: 14)
            .opacity(switchOnly ? 0 : 1)
          if let icon = BlenderIcon.image(panel.icon) {
            Image(uiImage: icon).resizable().scaledToFit().frame(width: 18, height: 18)
          }
          Text(title ?? panel.label)
            .lineLimit(1)
            .foregroundStyle(active ? PanelStyle.tint : .primary)
          Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(switchOnly)
      .accessibilityValue((expanded ? "Expanded" : "Collapsed") + (active ? ", Active" : ""))
      .accessibilityIdentifier("blender.section." + id)
      PanelHeaderControls(model: model, controls: model.header(of: panel))
    }
    .padding(.leading, 12)
    .padding(.trailing, 4)
  }

  @ViewBuilder
  private func rowView(_ row: PanelRow) -> some View {
    if row.heading {
      let open = model.isOpen(row.node)
      let subpanel = String(row.node.key.dropFirst("panel:".count))
      HStack(spacing: 8) {
        Button {
          model.setOpen(row.node, !open)
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "chevron.right")
              .font(.system(size: 10, weight: .semibold))
              .rotationEffect(.degrees(open ? 90 : 0))
              .frame(width: 12)
            Text(row.node.label)
              .font(.subheadline)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .foregroundStyle(.secondary)
          .frame(minHeight: 36)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("blender.subpanel." + subpanel)
        PanelHeaderControls(model: model, controls: model.header(of: row.node))
      }
      .padding(.leading, CGFloat(12 * row.depth))
    }
    else {
      ControlRow(model: model, node: row.node)
    }
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
              NativeSwitch(model: model, node: control)
            case .button:
              HeaderButton(model: model, node: control)
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

/** \} */
