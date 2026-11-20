/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Controls of a view that hold more than a value: data-block pickers, lists such as shape keys
 * and vertex groups, rows of an item's toggles and the material preview.
 */

import SwiftUI
import UIKit

/* -------------------------------------------------------------------- */
/** \name Data-block picker
 * \{ */

/**
 * The data-block in use. In Properties, Blender's `template_ID` as one joined row (ROUND5 7D): the
 * picture and ▾ browse the data-blocks, the name is a text field that renames, the users count
 * (a tap makes it single-user), the fake user's shield, New (Blender's duplicate icon once one is
 * chosen) and ✕ to unlink; with nothing chosen, the browser and ＋ New. Where it is linked from,
 * such as a material slot's Object or Data, is an icon dropdown at the row's end (\a link). On a
 * toolbar (\a compact), a small preview and the name, with the rest in a menu.
 */
struct ReferenceRow: View {
  let model: PanelsModel
  let node: NativeNode
  /** On one line, for a toolbar: a small preview and the name. */
  var compact = false
  /** Where it is linked from, drawn at the row's end, see `Role.link`. */
  var link: NativeNode? = nil
  @State private var browsing = false
  @State private var rename: RenameRequest?

  private var reference: Blender_NativeUI_Reference? { node.reference }
  private var has: Bool { !(reference?.value ?? "").isEmpty }
  private var type: String { reference?.type ?? "" }
  private var name: String { reference?.name ?? "" }
  private var users: String {
    var parts: [String] = []
    let users = Int(reference?.users ?? 0)
    if users > 1 { parts.append("\(users) users") }
    if reference?.linked == true { parts.append("Linked") }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    if reference?.font == true {
      /* Fonts by family name, from the system's font picker. */
      NativeFontSlotRow(model: model, node: node)
    }
    else if compact {
      picker
    }
    else {
      templateID
    }
  }

  /** The parts of Blender's `template_ID` this data-block has, in its order. */
  private enum Part: Hashable { case browse, name, users, fakeUser, new, unlink }

  private var parts: [Part] {
    guard let reference else { return [.browse] }
    var parts: [Part] = [.browse]
    if has {
      parts.append(.name)
      if reference.users > 1 && reference.canSingleUser { parts.append(.users) }
      if reference.canFakeUser { parts.append(.fakeUser) }
      if reference.canNew { parts.append(.new) }
      if reference.canUnlink { parts.append(.unlink) }
    }
    else if reference.canNew {
      parts.append(.new)
    }
    return parts
  }

  private var templateID: some View {
    let parts = self.parts
    return HStack(spacing: 4) {
      HStack(spacing: 1) {
        ForEach(Array(parts.enumerated()), id: \.element) { index, part in
          self.part(part, join: widgetJoin(index, parts.count))
        }
      }
      if let link {
        ReferenceLinkDropdown(model: model, node: link)
      }
    }
    .frame(minHeight: 32)
  }

  private static func icon(_ blender: String, _ symbol: String) -> UIImage? {
    BlenderIcon.image(blender) ?? UIImage(systemName: symbol)
  }

  @ViewBuilder
  private func part(_ part: Part, join: WidgetJoin) -> some View {
    let reference = self.reference
    switch part {
      case .browse:
        Button {
          browsing = true
        } label: {
          BlenderWidgetFace(icon: PreviewCache.image(reference?.preview)?.withRenderingMode(.alwaysOriginal) ?? BlenderIcon.image(node.icon), arrow: true,
                            join: join)
        }
        .buttonStyle(.plain)
        .disabled(!node.enabled || (reference?.optionsCount ?? 0) == 0)
        .accessibilityLabel("Browse \(type)")
        .accessibilityValue(has ? name : "None")
        .help("Browse \(type)")
        .popover(isPresented: $browsing) {
          ReferenceBrowser(model: model, node: node) { browsing = false }
            .frame(minWidth: 380, minHeight: min(560, 150 + 60 * CGFloat(reference?.optionsCount ?? 0)))
        }
      case .name:
        ReferenceNameField(model: model, node: node, name: name, join: join,
                           editable: node.enabled && reference?.linked != true)
          .layoutPriority(1)
      case .users:
        let users = Int(reference?.users ?? 0)
        Button {
          model.send(node, .invoke, .text("single_user"))
        } label: {
          BlenderWidgetFace(icon: nil, text: "\(users)", join: join)
        }
        .buttonStyle(.plain)
        .disabled(!node.enabled)
        .accessibilityLabel("Make Single User")
        .accessibilityValue("\(users) users")
        .help("\(users) users: make single user")
      case .fakeUser:
        let on = reference?.fakeUser == true
        BlenderToggleButton(name: "Fake User", icon: Self.icon(on ? "FAKE_USER_ON" : "FAKE_USER_OFF",
                                                               on ? "shield.fill" : "shield"),
                            isOn: on, join: join) {
          model.send(node, .invoke, .text("fake_user"))
        }
        .disabled(!node.enabled)
      case .new:
        Button {
          model.send(node, .add)
          Haptics.selection()
        } label: {
          if has {
            BlenderWidgetFace(icon: Self.icon("DUPLICATE", "plus.square.on.square"), join: join)
          }
          else {
            BlenderWidgetFace(icon: Self.icon("ADD", "plus"), text: "New", join: join, fills: true)
          }
        }
        .buttonStyle(.plain)
        .disabled(!node.enabled)
        .accessibilityLabel(has ? "New \(type) (a copy)" : "New \(type)")
        .help(has ? "New \(type), a copy of this one" : "New \(type)")
      case .unlink:
        Button {
          model.send(node, .remove)
        } label: {
          BlenderWidgetFace(icon: Self.icon("X", "xmark"), join: join)
        }
        .buttonStyle(.plain)
        .disabled(!node.enabled)
        .accessibilityLabel("Unlink \(type)")
        .help("Unlink \(type)")
    }
  }

  private var picker: some View {
    HStack(spacing: 6) {
      Button {
        browsing = true
      } label: {
        HStack(spacing: compact ? 8 : 12) {
          PreviewThumbnail(path: reference?.preview, fallback: BlenderIcon.image(node.icon), size: compact ? 26 : 52)
          VStack(alignment: .leading, spacing: 2) {
            Text(has ? name : "No \(type)")
              .font(compact ? .subheadline.weight(.medium) : .headline)
              .lineLimit(1)
              .truncationMode(.middle)
              .foregroundStyle(has ? .primary : .secondary)
            /* With nothing chosen, the New button beside it says what to do. */
            if !compact && (has || reference?.canNew != true) {
              Text(has ? (users.isEmpty ? type : users) : "Choose or create one")
                .font(.subheadline)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            }
          }
          if !compact { Spacer(minLength: 0) }
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!node.enabled || (reference?.optionsCount ?? 0) == 0)
      .accessibilityLabel("\(type), \(has ? name : "None")")
      .accessibilityHint("Shows the data-blocks to choose from.")
      .popover(isPresented: $browsing) {
        ReferenceBrowser(model: model, node: node) { browsing = false }
          .frame(minWidth: 380, minHeight: min(560, 150 + 60 * CGFloat(reference?.optionsCount ?? 0)))
      }

      if !has && reference?.canNew == true {
        Button {
          model.send(node, .add)
        } label: {
          Label("New", systemImage: "plus")
            .fixedSize()
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .disabled(!node.enabled)
        .accessibilityLabel("New \(type)")
      }

      actionsMenu
    }
    .frame(minHeight: compact ? 36 : 64)
    .renamePrompt($rename)
  }

  @ViewBuilder
  private var actionsMenu: some View {
    let reference = self.reference
    let canNew = reference?.canNew == true
    /* A file opened as a new one, as the template's Open does (ROUND6 PANEL-10). */
    let canOpen = reference?.canOpen == true
    let canRename = has && reference?.linked != true
    let any = canNew || canOpen || canRename || reference?.canFakeUser == true || reference?.canSingleUser == true ||
      reference?.canUnlink == true
    if any {
      Menu {
        Section {
          if canNew {
            Button {
              model.send(node, .add)
            } label: {
              Label(has ? "Duplicate" : "New \(type)", systemImage: has ? "plus.square.on.square" : "plus")
            }
          }
          if canOpen {
            Button {
              model.send(node, .invoke, .text("open"))
            } label: {
              Label("Open…", systemImage: "folder")
            }
          }
          if canRename {
            Button {
              rename = RenameRequest(title: "Rename \(type)", name: name) { name in
                model.send(node, .rename, .text(name))
              }
            } label: {
              Label("Rename…", systemImage: "pencil")
            }
          }
        }
        Section {
          if reference?.canFakeUser == true {
            Toggle(isOn: Binding(get: { reference?.fakeUser == true },
                                 set: { _ in model.send(node, .invoke, .text("fake_user")) }))
            {
              Label("Fake User", systemImage: "shield")
              Text("Keep even when nothing uses it")
            }
          }
          if reference?.canSingleUser == true {
            Button {
              model.send(node, .invoke, .text("single_user"))
            } label: {
              Label("Make Single User", systemImage: "person")
              Text("Used by \(Int(reference?.users ?? 1) - 1) others")
            }
          }
        }
        if reference?.canUnlink == true {
          Section {
            Button {
              model.send(node, .remove)
            } label: {
              Label("Unlink", systemImage: "xmark.circle")
            }
          }
        }
      } label: {
        Image(systemName: "ellipsis.circle")
          .font(compact ? .body : .title3)
          .frame(width: compact ? 32 : 40, height: compact ? 36 : 44)
      }
      .tint(.primary)
      .disabled(!node.enabled)
      .accessibilityLabel("\(type) Actions")
    }
  }
}

/** A data-block's name in Blender's text widget: typing a new one renames it. */
struct ReferenceNameField: View {
  let model: PanelsModel
  let node: NativeNode
  let name: String
  let join: WidgetJoin
  let editable: Bool
  @State private var text = ""
  @FocusState private var focused: Bool
  @AppStorage(ShellStyle.key) private var style = ShellStyle.blender.rawValue

  var body: some View {
    let glass = style == ShellStyle.glass.rawValue
    let shape = WidgetShape(join: join, glass: glass)
    TextField("Name", text: $text)
      .font(.subheadline)
      .lineLimit(1)
      .autocorrectionDisabled()
      .textInputAutocapitalization(.never)
      .focused($focused)
      .selectsAllOnFocus(focused)
      .liftsAboveKeyboard(focused)
      .submitLabel(.done)
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, minHeight: 32)
      .background(glass ? Color.primary.opacity(focused ? 0.18 : 0.08) : BlenderWidgetColors.textInner, in: shape)
      .overlay { if !glass { shape.strokeBorder(BlenderWidgetColors.outline, lineWidth: 1) } }
      .disabled(!editable)
      .onAppear { text = name }
      .onChange(of: name) { _, newValue in if !focused { text = newValue } }
      .onSubmit { commit() }
      .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
      .accessibilityLabel("Name")
  }

  private func commit() {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed != name else {
      text = name
      return
    }
    model.send(node, .rename, .text(trimmed))
  }
}

/** Where a data-block is linked from, such as a material slot's Object or Data, as Blender draws
 * it at the end of the data-block's row: the icon and ▾, its menu titled Link with Blender's
 * names and descriptions. */
struct ReferenceLinkDropdown: View {
  let model: PanelsModel
  let node: NativeNode

  var body: some View {
    let options = node.choice?.allOptions.filter { $0.value != nil } ?? []
    let value = model.text(node)
    let current = options.first { $0.value == value }
    let title = node.label.isEmpty ? "Link" : node.label
    Menu {
      Section(title) {
        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
          Toggle(isOn: Binding(get: { option.value == value }, set: { _ in model.set(node, .text(option.value ?? "")) })) {
            Text(option.label ?? "")
            if let description = option.description, !description.isEmpty { Text(description) }
          }
        }
      }
    } label: {
      BlenderWidgetFace(icon: BlenderIcon.image(current?.icon ?? node.icon), arrow: true)
    }
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .disabled(!node.enabled)
    .help(title)
    .accessibilityLabel(title)
    .accessibilityValue(current?.label ?? "")
  }
}

/** Choose a data-block, like Blender's ID search popup: searchable, with previews. */
struct ReferenceBrowser: View {
  let model: PanelsModel
  let node: NativeNode
  let done: () -> Void
  @State private var query = ""

  var body: some View {
    let reference = node.reference
    let type = reference?.type ?? ""
    let value = reference?.value
    let options = (reference?.allOptions ?? []).filter {
      query.isEmpty || ($0.label ?? "").localizedStandardContains(query)
    }
    NavigationStack {
      ScrollViewReader { reader in
        List(Array(options.enumerated()), id: \.offset) { index, option in
          let current = option.value == value
          Button {
            model.send(node, .set_, .text(option.value ?? ""))
            done()
          } label: {
            HStack(spacing: 12) {
              PreviewThumbnail(path: option.preview, fallback: BlenderIcon.image(node.icon), size: 44)
              VStack(alignment: .leading) {
                Text(option.label ?? "").foregroundStyle(.primary)
                if let users = option.description, !users.isEmpty {
                  Text(users).font(.caption).foregroundStyle(.secondary)
                }
              }
              Spacer()
              if current { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
          }
          .id(index)
          .accessibilityAddTraits(current ? .isSelected : [])
        }
        .groupedListStyle()
        .scrollContentBackground(.hidden)
        .onAppear {
          if let index = options.firstIndex(where: { $0.value == value }) {
            reader.scrollTo(index, anchor: .center)
          }
        }
      }
      .searchableInBar(text: $query)
      .navigationTitle(type)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if reference?.canNew == true {
          ToolbarItem(placement: .primaryAction) {
            Button {
              model.send(node, .add)
              done()
            } label: {
              Image(systemName: "plus")
            }
            .accessibilityLabel("New \(type)")
          }
        }
      }
    }
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Lists
 *
 * Shape keys, vertex groups, UV maps, material slots and Blender's other lists, as small
 * outliners: tap to make an item active, tap the active item's name to rename it, drag the
 * handle to reorder, touch and hold for its actions. What Blender draws beside an item's name,
 * such as a shape key's value or a vertex group's lock, stays on its row.
 * \{ */

/** Lists longer than this show the rows around the active one and a page with all of them. */
private let inlineRows = 40

/**
 * A list as Blender's `template_list` draws it (ROUND5 7D): its rows in a box, the active one in
 * Blender's selection blue, and at its side a column of Blender's buttons: ＋, −, ▾ for the list's
 * menu and, where it can be reordered, ▲ ▼ to move the active row. Long lists show the rows
 * around the active one and Show All.
 */
struct NativeList: View {
  let model: PanelsModel
  let node: NativeNode
  @State private var showingAll = false

  var body: some View {
    let rows = model.children(of: node).filter { $0.kind == .row }
    PanelColumn(spacing: 4) {
      HStack(alignment: .top, spacing: 4) {
        NativeListBox(minHeight: NativeListSideColumn.height(model, node, rows: rows)) {
          if rows.isEmpty {
            Text("None")
              .font(.subheadline)
              .foregroundStyle(.tertiary)
              .frame(maxWidth: .infinity, minHeight: NativeListRows.rowHeight, alignment: .leading)
              .padding(.leading, 8)
          }
          else {
            NativeListRows(model: model, node: node, rows: shown(rows))
          }
        }
        NativeListSideColumn(model: model, node: node, rows: rows)
      }
      if rows.count > inlineRows {
        Button {
          showingAll = true
        } label: {
          Label("Show All \(rows.count)", systemImage: "list.bullet")
            .font(.subheadline)
            .frame(minHeight: 32)
        }
        .buttonStyle(.borderless)
        .sheet(isPresented: $showingAll) { NativeListPage(model: model, node: node) }
      }
    }
  }

  /** The rows around the active one, so the active item is always visible. */
  private func shown(_ rows: [NativeNode]) -> [NativeNode] {
    guard rows.count > inlineRows else { return rows }
    let position = rows.firstIndex { $0.row?.selected == true } ?? 0
    let start = max(0, min(rows.count - inlineRows, position - inlineRows / 2))
    return Array(rows[start..<start + inlineRows])
  }
}

/** Blender's list box: darker than the panel, inside the widget outline. */
struct NativeListBox<Content: View>: View {
  var minHeight: CGFloat = 0
  @ViewBuilder let content: Content
  @AppStorage(ShellStyle.key) private var style = ShellStyle.blender.rawValue

  static var fill: Color { Color(red: 0x2d / 255, green: 0x2d / 255, blue: 0x2d / 255) }

  var body: some View {
    let glass = style == ShellStyle.glass.rawValue
    let shape = RoundedRectangle(cornerRadius: glass ? 10 : ShellStyle.radius, style: .continuous)
    content
      .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
      .background(glass ? Color.primary.opacity(0.06) : Self.fill, in: shape)
      .clipShape(shape)
      .overlay { if !glass { shape.strokeBorder(BlenderWidgetColors.outline, lineWidth: 1) } }
  }
}

/** A list's buttons in a column at its side, as Blender's: ＋ and − joined, ▾ for the list's menu
 * (its extra buttons and Blender's specials menu), and ▲ ▼ joined where it can be reordered. */
struct NativeListSideColumn: View {
  let model: PanelsModel
  let node: NativeNode
  let rows: [NativeNode]

  static let width: CGFloat = 32

  private static func reorders(_ node: NativeNode, _ rows: [NativeNode]) -> Bool {
    node.list?.canReorder == true && node.enabled && rows.count > 1
  }

  private static func extras(_ model: PanelsModel, _ node: NativeNode) -> [NativeNode] {
    model.children(of: node).filter { $0.kind == .button && $0.role != .duplicate }
  }

  /** How tall the column is, which the list's box is at least. */
  static func height(_ model: PanelsModel, _ node: NativeNode, rows: [NativeNode]) -> CGFloat {
    let list = node.list
    var groups: [Int] = []
    let addRemove = (list?.canAdd == true ? 1 : 0) + (list?.canRemove == true ? 1 : 0)
    if addRemove > 0 { groups.append(addRemove) }
    if !extras(model, node).isEmpty || !(list?.menu ?? "").isEmpty { groups.append(1) }
    if reorders(node, rows) { groups.append(2) }
    guard !groups.isEmpty else { return 0 }
    return groups.reduce(0) { $0 + CGFloat($1) * 32 + CGFloat($1 - 1) } + CGFloat(groups.count - 1) * 8
  }

  var body: some View {
    let list = node.list
    let extras = Self.extras(model, node)
    let menu = list?.menu ?? ""
    let canAdd = list?.canAdd == true, canRemove = list?.canRemove == true
    VStack(spacing: 8) {
      if canAdd || canRemove {
        VStack(spacing: 1) {
          if canAdd { button("ADD", "plus", "Add", .add, join: widgetJoin(0, canRemove ? 2 : 1)) }
          if canRemove { button("REMOVE", "minus", "Remove", .remove, join: widgetJoin(canAdd ? 1 : 0, canAdd ? 2 : 1)) }
        }
      }
      if !extras.isEmpty || !menu.isEmpty {
        Menu {
          ForEach(extras) { button in
            let destructive = button.content(Blender_NativeUI_Button.self)?.style == .destructive
            Button(role: destructive ? .destructive : nil) {
              model.send(button, .invoke)
            } label: {
              Label {
                Text(button.label)
              } icon: {
                if destructive { Image(systemName: "trash") }
                else if let image = BlenderIcon.image(button.icon) { Image(uiImage: image) }
              }
            }
          }
          if !menu.isEmpty {
            Section { BlenderMenuItems(route: BlenderMenus.route(menu, tab: model.currentTab)) }
          }
        } label: {
          BlenderWidgetFace(icon: BlenderIcon.image("DOWNARROW_HLT") ?? UIImage(systemName: "chevron.down"))
            .padding(.vertical, -6)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .prefetchingBlenderMenu(BlenderMenus.route(menu, tab: model.currentTab))
        .disabled(!node.enabled)
        .accessibilityLabel("More")
        .help("More")
      }
      if Self.reorders(node, rows) {
        VStack(spacing: 1) {
          moveButton("TRIA_UP", "chevron.up", "Move Up", by: -1, join: .first)
          moveButton("TRIA_DOWN", "chevron.down", "Move Down", by: 1, join: .last)
        }
      }
    }
    .frame(width: Self.width)
  }

  private func face(_ blender: String, _ symbol: String, join: WidgetJoin) -> some View {
    BlenderWidgetFace(icon: BlenderIcon.image(blender) ?? UIImage(systemName: symbol), join: join, vertical: true)
      /* Stacked 32 point widgets: the face's own 44 point hit area would overlap its neighbour's. */
      .padding(.vertical, -6)
  }

  private func button(_ blender: String, _ symbol: String, _ title: String, _ op: NativeOp, join: WidgetJoin)
    -> some View
  {
    Button {
      model.send(node, op)
      Haptics.selection()
    } label: {
      face(blender, symbol, join: join)
    }
    .buttonStyle(.plain)
    .disabled(!node.enabled)
    .accessibilityLabel(title)
    .help(title)
  }

  /** Move the active row one place, as Blender's ▲ ▼ do: before the row now after its new place. */
  private func moveButton(_ blender: String, _ symbol: String, _ title: String, by offset: Int, join: WidgetJoin)
    -> some View
  {
    let order = rows.map(\.key)
    let from = rows.firstIndex { $0.row?.selected == true }
    let to = from.map { $0 + offset }
    let possible = from != nil && to.map { order.indices.contains($0) } == true
    return Button {
      guard let from, let to, order.indices.contains(to) else { return }
      var moved = order
      let key = moved.remove(at: from)
      moved.insert(key, at: to)
      guard let row = model.view.node(key) else { return }
      model.send(row, .move, to + 1 < moved.count ? .text(moved[to + 1]) : nil)
      Haptics.impact()
    } label: {
      face(blender, symbol, join: join)
    }
    .buttonStyle(.plain)
    .disabled(!node.enabled || !possible)
    .accessibilityLabel(title)
    .help(title)
  }
}

struct NativeListRows: View {
  let model: PanelsModel
  let node: NativeNode
  let rows: [NativeNode]
  /** The rows' order after a move, by key, shown until Blender's list has it too. */
  @State private var pending: [String]?
  @State private var renaming: String?
  @State private var renameText = ""
  @FocusState private var renameFocused: Bool
  @AppStorage(ShellStyle.key) private var style = ShellStyle.blender.rawValue

  private var glass: Bool { style == ShellStyle.glass.rawValue }

  /** Each row's height, Blender's: the list is as tall as its rows, inside the scrolling form. */
  static let rowHeight: CGFloat = 32

  private var editable: Bool { node.enabled }
  private var reorder: Bool { node.list?.canReorder == true && editable && rows.count > 1 }
  private var duplicate: NativeNode? { model.attached(node, .duplicate) }

  /** A change shown at once, which the list's own animations leave alone too. */
  private static var instant: Transaction {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    return transaction
  }

  /** The rows as they show: in a dropped row's new place until Blender's list follows. */
  private var shown: [NativeNode] {
    guard let pending, pending.count == rows.count else { return rows }
    let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0) })
    let ordered = pending.compactMap { byKey[$0] }
    return ordered.count == rows.count ? ordered : rows
  }

  /**
   * The system's own list, so its rows reorder and swipe as every list's do: touch and hold, then
   * drag, to move a row; swipe for its actions. It doesn't scroll: the form around it does.
   */
  var body: some View {
    List {
      ForEach(Array(zip(Self.identities(shown), shown).enumerated()), id: \.element.0) { position, entry in
        let row = entry.1
        rowView(row, position: position)
          .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 2))
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .swipeActions(edge: .trailing, allowsFullSwipe: true) { trailingActions(row) }
          .swipeActions(edge: .leading) { leadingActions(row) }
      }
      .onMove(perform: reorder ? moveRows : nil)
    }
    .listStyle(.plain)
    .scrollDisabled(true)
    .scrollContentBackground(.hidden)
    .environment(\.defaultMinListRowHeight, Self.rowHeight)
    .frame(height: CGFloat(shown.count) * Self.rowHeight)
    /* Items added or deleted slide in and out: the list animates the change. */
    .animation(UIAccessibility.isReduceMotionEnabled ? nil : .smooth(duration: 0.3), value: Self.identities(shown))
    /* Blender's list has changed: show it as it is. */
    .onChange(of: rows.map { "\($0.key)|\($0.label)" }) {
      withTransaction(Self.instant) { pending = nil }
    }
  }

  /** Each row's identity, which stays as rows come, go and move: its name, numbered where names
   * repeat (such as empty material slots). */
  static func identities(_ rows: [NativeNode]) -> [String] {
    var seen: [String: Int] = [:]
    return rows.map { row in
      let count = seen[row.label, default: 0]
      seen[row.label] = count + 1
      return "\(row.label)#\(count)"
    }
  }

  /** A row moved in the list: shown in its new place at once, and moved in Blender. */
  private func moveRows(_ source: IndexSet, _ destination: Int) {
    guard let from = source.first else { return }
    let to = destination > from ? destination - 1 : destination
    guard from != to else { return }
    var order = shown.map(\.key)
    let moved = order[from]
    order.move(fromOffsets: source, toOffset: destination)
    pending = order
    move(moved, to: to, in: order)
    /* Should Blender not move it after all, its own order comes back. */
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      if pending == order { withMotion { pending = nil } }
    }
  }

  /** Move \a key to \a position: before the row now after it there, or to the end. */
  private func move(_ key: String, to position: Int, in order: [String]) {
    guard let row = model.view.node(key) else { return }
    let before = position + 1 < order.count ? order[position + 1] : nil
    model.send(row, .move, before.map { .text($0) })
    Haptics.impact()
  }

  private func moveRow(_ row: NativeNode, by offset: Int, toEnd: Bool = false) {
    var order = shown.map(\.key)
    guard let from = order.firstIndex(of: row.key) else { return }
    let to = toEnd ? (offset < 0 ? 0 : order.count - 1) : from + offset
    guard order.indices.contains(to), to != from else { return }
    order.remove(at: from)
    order.insert(row.key, at: to)
    move(row.key, to: to, in: order)
  }

  @ViewBuilder
  private func trailingActions(_ row: NativeNode) -> some View {
    if editable && node.list?.canRemove == true {
      /* Icons only: the panel is narrow, and a titled action slides the row's name out of view. */
      Button(role: .destructive) { delete(row) } label: {
        Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
      }
      /* The system's red, whatever the form's tint. */
      .tint(.red)
    }
  }

  @ViewBuilder
  private func leadingActions(_ row: NativeNode) -> some View {
    if editable, let duplicate {
      Button { run(duplicate, on: row) } label: {
        Label("Duplicate", systemImage: "plus.square.on.square").labelStyle(.iconOnly)
      }
      .tint(.blue)
    }
    if editable && row.row?.renamable == true {
      Button { startRename(row) } label: {
        Label("Rename", systemImage: "pencil").labelStyle(.iconOnly)
      }
      .tint(.gray)
    }
  }

  @ViewBuilder
  private func rowView(_ row: NativeNode, position: Int) -> some View {
    let isActive = row.row?.selected == true
    /* An item with no name, such as a material slot with no material yet, as Blender leaves blank. */
    let empty = row.label.isEmpty
    let label = empty ? "Empty" : row.label
    HStack(spacing: 8) {
      Group {
        if let preview = PreviewCache.image(row.row?.preview) {
          Image(uiImage: preview).resizable().scaledToFill()
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        else if let icon = BlenderIcon.image(row.icon) {
          Image(uiImage: icon).resizable().scaledToFit().frame(width: 18, height: 18)
            .foregroundStyle(.primary)
        }
      }
      if renaming == row.key {
        TextField("Name", text: $renameText)
          .focused($renameFocused)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .submitLabel(.done)
          .onSubmit { commitRename(row) }
          .onChange(of: renameFocused) { _, focused in if !focused { commitRename(row) } }
      }
      else {
        Text(label)
          .font(.subheadline)
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(isActive && !glass ? Color.white : empty ? Color.secondary : Color.primary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .layoutPriority(1)
          .contentShape(Rectangle())
          .pointerHighlight()
          .onTapGesture { tap(row, isActive: isActive) }
      }
      ForEach(model.children(of: row)) { control in
        NativeRowControl(model: model, node: control)
      }
    }
    /* Nested items (bone collections, layer groups) are indented under their parent. */
    .padding(.leading, 6 + CGFloat(row.row?.depth ?? 0) * 16)
    .padding(.trailing, 6)
    .frame(maxWidth: .infinity, minHeight: Self.rowHeight - 2, maxHeight: Self.rowHeight - 2)
    .background {
      /* Blender's active row: its selection blue (the system's in glass). */
      RoundedRectangle(cornerRadius: glass ? 6 : 3, style: .continuous)
        .fill(isActive ? (glass ? PanelStyle.activeRow : ShellStyle.selection) : .clear)
    }
    .contextMenuPreviewShape(RoundedRectangle(cornerRadius: 6))
    .contextMenu { rowMenu(row, position: position) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(label)
    .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
    .accessibilityAction { tap(row, isActive: false) }
  }

  @ViewBuilder
  private func rowMenu(_ row: NativeNode, position: Int) -> some View {
    if row.row?.renamable == true {
      Button { startRename(row) } label: { Label("Rename", systemImage: "pencil") }
    }
    if let duplicate, editable {
      Button { run(duplicate, on: row) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
    }
    if reorder {
      Section {
        if position > 0 {
          Button { moveRow(row, by: -1, toEnd: true) } label: { Label("Move to Top", systemImage: "arrow.up.to.line") }
          Button { moveRow(row, by: -1) } label: { Label("Move Up", systemImage: "arrow.up") }
        }
        if position < shown.count - 1 {
          Button { moveRow(row, by: 1) } label: { Label("Move Down", systemImage: "arrow.down") }
          Button { moveRow(row, by: 1, toEnd: true) } label: {
            Label("Move to Bottom", systemImage: "arrow.down.to.line")
          }
        }
      }
    }
    if node.list?.canRemove == true, editable {
      Section {
        Button(role: .destructive) { delete(row) } label: { Label("Delete", systemImage: "trash") }
      }
    }
  }

  /** Blender's list operators act on the active item, so make it active first. */
  private func select(_ row: NativeNode) {
    if row.row?.selected != true { model.send(row, .activate) }
  }

  private func delete(_ row: NativeNode) {
    select(row)
    model.send(node, .remove)
    Haptics.impact()
  }

  private func run(_ button: NativeNode, on row: NativeNode) {
    select(row)
    model.send(button, .invoke)
    Haptics.selection()
  }

  private func tap(_ row: NativeNode, isActive: Bool) {
    guard editable else { return }
    if isActive {
      if row.row?.renamable == true { startRename(row) }
      return
    }
    model.send(row, .activate)
    Haptics.selection()
  }

  private func startRename(_ row: NativeNode) {
    renameText = row.label
    renaming = row.key
    renameFocused = true
  }

  private func commitRename(_ row: NativeNode) {
    guard renaming == row.key else { return }
    renaming = nil
    let name = renameText.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, name != row.label else { return }
    model.send(row, .rename, .text(name))
  }
}

/** A control drawn on a list's row: an icon toggle (mute, lock) or a compact value. */
struct NativeRowControl: View {
  let model: PanelsModel
  let node: NativeNode

  var body: some View {
    switch node.kind {
      case .toggle:
        let on = model.bool(node)
        Button {
          model.set(node, .bool(!on))
          Haptics.selection()
        } label: {
          toggleImage(shown: shownOn(on))
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!node.enabled)
        .accessibilityLabel(node.label.isEmpty ? node.node.property ?? "" : node.label)
        .accessibilityValue(shownOn(on) ? "On" : "Off")
      case .number:
        NativeNumberField(model: model, node: node, compact: true)
          .frame(width: 56)
      case .choice:
        NativeChoice(model: model, node: node, compact: true)
      case .button:
        Button {
          model.send(node, .invoke)
          Haptics.selection()
        } label: {
          Group {
            if let image = BlenderIcon.image(node.icon) {
              Image(uiImage: image).resizable().scaledToFit().frame(width: 16, height: 16)
            }
          }
          .frame(width: 32, height: 32)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!node.enabled)
        .accessibilityLabel(node.label)
        .help(node.label)
      default:
        EmptyView()
    }
  }

  /** Blender draws some toggles inverted (a shape key's checkbox is on while it is not muted):
   * the icon Blender sent says how its value looks, a pending edit flips it. */
  private func shownOn(_ on: Bool) -> Bool {
    let reported = node.toggle?.value ?? false
    let drawnOn: Bool
    switch node.icon ?? "" {
      case "CHECKBOX_HLT", "LOCKED", "RESTRICT_RENDER_OFF", "RESTRICT_VIEW_OFF", "HIDE_OFF", "RESTRICT_SELECT_OFF":
        drawnOn = true
      case "CHECKBOX_DEHLT", "UNLOCKED", "RESTRICT_RENDER_ON", "RESTRICT_VIEW_ON", "HIDE_ON", "RESTRICT_SELECT_ON":
        drawnOn = false
      default:
        drawnOn = reported
    }
    return on == reported ? drawnOn : !drawnOn
  }

  /** Blender's checkbox becomes a checkmark; other icons show their on and off states. */
  @ViewBuilder
  private func toggleImage(shown: Bool) -> some View {
    let icon = node.icon ?? ""
    if icon.isEmpty || icon == "NONE" || icon.hasPrefix("CHECKBOX") {
      Image(systemName: shown ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(shown ? PanelStyle.tint : .secondary)
    }
    else if let image = BlenderIcon.image(shownIcon(icon, shown)) {
      Image(uiImage: image)
        .resizable()
        .scaledToFit()
        .frame(width: 16, height: 16)
        .foregroundStyle(shown ? .primary : .tertiary)
    }
  }

  /** The icon for the state shown, so a pending toggle shows its new icon at once. */
  private func shownIcon(_ icon: String, _ shown: Bool) -> String {
    let pairs = [("LOCKED", "UNLOCKED"), ("RESTRICT_RENDER_OFF", "RESTRICT_RENDER_ON"),
                 ("RESTRICT_VIEW_OFF", "RESTRICT_VIEW_ON"), ("HIDE_OFF", "HIDE_ON"),
                 ("RESTRICT_SELECT_OFF", "RESTRICT_SELECT_ON")]
    for (on, off) in pairs where icon == on || icon == off { return shown ? on : off }
    return icon
  }
}

/** Every item of a long list, searchable. */
struct NativeListPage: View {
  let model: PanelsModel
  let node: NativeNode
  @State private var query = ""

  var body: some View {
    let all = model.children(of: node).filter { $0.kind == .row }
    let rows = all.filter { query.isEmpty || $0.label.localizedStandardContains(query) }
    NavigationStack {
      ScrollView {
        HStack(alignment: .top, spacing: 4) {
          NativeListBox(minHeight: NativeListSideColumn.height(model, node, rows: all)) {
            NativeListRows(model: model, node: node, rows: rows)
          }
          NativeListSideColumn(model: model, node: node, rows: all)
        }
        .padding(16)
      }
      .searchableInBar(text: $query)
      .navigationTitle("\(all.count) Items")
      .navigationBarTitleDisplayMode(.inline)
    }
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Items and pictures
 * \{ */

/** A name with the toggles and buttons Blender draws beside it, such as a bone's collection with
 * its visibility and solo: a row like a list's, without one to select in. */
struct ItemRowView: View {
  let model: PanelsModel
  let node: NativeNode

  var body: some View {
    HStack(spacing: 10) {
      if let icon = BlenderIcon.image(node.icon) {
        Image(uiImage: icon).resizable().scaledToFit().frame(width: 22, height: 22)
      }
      Text(node.label)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
      ForEach(model.children(of: node)) { control in
        NativeRowControl(model: model, node: control)
      }
    }
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, minHeight: NativeListRows.rowHeight - 2)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(node.label)
  }
}

/** The Preview panel's render, floating in the section, with its shapes on a glass capsule. */
struct PictureRow: View {
  let model: PanelsModel
  let node: NativeNode

  var body: some View {
    VStack(spacing: 0) {
      Group {
        if let image = PreviewCache.image(node.content(Blender_NativeUI_Picture.self)?.image) {
          Image(uiImage: image).resizable().scaledToFit()
        }
        else {
          ProgressView()
        }
      }
      .frame(width: 250, height: 250)
      .accessibilityLabel("Preview of \(node.label)")
      if let shape = model.attached(node, .shape), let choice = shape.choice {
        let value = model.text(shape)
        HStack(spacing: 2) {
          ForEach(Array(choice.allOptions.enumerated()), id: \.offset) { _, option in
            let selected = option.value == value
            Button {
              model.set(shape, .text(option.value ?? ""))
              Haptics.selection()
            } label: {
              Group {
                if let image = BlenderIcon.image(option.icon) {
                  Image(uiImage: image).resizable().scaledToFit().frame(width: 18, height: 18)
                }
                else {
                  Text(option.label ?? "")
                }
              }
              .foregroundStyle(selected ? PanelStyle.tint : .secondary)
              .frame(width: 36, height: 34)
              .background(selected ? Color.accentColor.opacity(0.2) : .clear, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!shape.enabled)
            .accessibilityLabel(option.label ?? "")
            .help(option.label ?? "")
          }
        }
        .padding(5)
        .panelGlass(in: Capsule())
      }
    }
    .frame(maxWidth: .infinity)
  }
}

/** \} */
