/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The Outliner: the scene's collections and objects as a tree. Tap an object to select it, a
 * collection to make it the active one (where new objects go); touch and hold or swipe for
 * actions, Blender's restriction flags among them; drag rows into a collection or onto an object to
 * parent them, and use Select mode to act on several at once, as the system's lists do.
 */

import SwiftUI
import UIKit

@MainActor
final class HierarchyStore: ObservableObject {
  @Published private(set) var nodes: [JSON] = []
  @Published private(set) var byKey: [String: JSON] = [:]
  @Published var query = ""
  @Published var editing = false
  @Published private(set) var status = ""

  let send: (JSON) -> Void

  init(send: @escaping (JSON) -> Void) {
    self.send = send
  }

  func update(nodes incoming: [JSON], status: String) {
    self.status = status
    guard !(incoming as NSArray).isEqual(nodes as NSArray) else { return }
    var keyed: [String: JSON] = [:]
    for node in incoming { if let key = node.string("key") { keyed[key] = node } }
    withMotion(.smooth(duration: 0.22)) {
      nodes = incoming
      byKey = keyed
    }
  }

  /** Whether rows sit under this one. */
  func hasChildren(_ node: JSON) -> Bool {
    let key = node.keyString
    return nodes.contains { $0.string("parent") == key }
  }

  /** Rows in outline order; a search shows the matches and the collections leading to them. */
  var visible: [JSON] {
    var matches: Set<String>?
    if !query.isEmpty {
      var found = Set<String>()
      for node in nodes where (node.string("name") ?? "").localizedStandardContains(query) {
        var key = node.string("key")
        while let current = key, !current.isEmpty, !found.contains(current) {
          found.insert(current)
          key = byKey[current]?.string("parent")
        }
      }
      matches = found
    }
    guard let matches else { return nodes }
    return nodes.filter { matches.contains($0.string("key") ?? "") }
  }

  var selectedObjects: [JSON] {
    var seen = Set<String>()
    return nodes.filter { node in
      guard node.string("kind") == "object", node.bool("selected"), let id = node.string("id") else {
        return false
      }
      return seen.insert(id).inserted
    }
  }

  /** The rows an action is about: the selection when the row is part of it. */
  func targets(_ node: JSON) -> [JSON] {
    let selected = selectedObjects
    if node.string("kind") == "object", selected.contains(where: { jsonEqual($0["id"], node["id"]) }) {
      return selected
    }
    return [node]
  }

  func allow(_ nodes: [JSON], _ action: String) -> Bool {
    !nodes.isEmpty && nodes.allSatisfy { $0.strings("actions").contains(action) }
  }

  func act(_ action: String, _ nodes: [JSON], value: Any? = nil) {
    guard allow(nodes, action) else { return }
    var request: JSON = ["action": action, "kind": nodes.first?.string("kind") ?? "object"]
    if nodes.count == 1 { request["id"] = nodes[0].string("id") ?? "" }
    else { request["ids"] = ids(nodes) }
    if let value { request["value"] = value }
    send(request)
  }

  private func ids(_ nodes: [JSON]) -> [String] {
    var seen = Set<String>()
    return nodes.compactMap { $0.string("id") }.filter { seen.insert($0).inserted }
  }

  /** Whether rows may move into or under `target`: not into themselves or their own children. */
  func canMove(_ moving: [JSON], to target: JSON?) -> Bool {
    guard let target, allow(moving, "move") else { return false }
    let kind = moving.first?.string("kind")
    for node in moving {
      if node.string("kind") != kind || jsonEqual(node["id"], target["id"]) { return false }
      /* Keys are paths of the rows above: a target inside a moved row is one of its children. */
      for row in nodes where jsonEqual(row["id"], node["id"]) {
        if (target.string("key") ?? "").hasPrefix((row.string("key") ?? "") + "/") { return false }
      }
    }
    if target.string("kind") == "collection" { return target.bool("accepts") }
    /* Objects drop onto objects to be parented; collections only into collections. */
    return kind == "object" && target.string("kind") == "object" && target.bool("accepts")
  }

  /** The collection that children go back into when taken out from under their parent: the one
   * they are shown in, which they all share. None when no row has an object for a parent. */
  func unparentTarget(_ moving: [JSON]) -> JSON? {
    guard !moving.isEmpty, moving.allSatisfy({ $0.string("kind") == "object" }),
          moving.contains(where: { byKey[$0.string("parent") ?? ""]?.string("kind") == "object" })
    else { return nil }
    let collections = Set(moving.compactMap { node -> String? in
      var key = node.string("parent")
      while let current = key, let row = byKey[current] {
        if row.string("kind") == "collection" { return current }
        key = row.string("parent")
      }
      return nil
    })
    guard collections.count == 1, let key = collections.first, let target = byKey[key],
          canMove(moving, to: target) else { return nil }
    return target
  }

  func move(_ moving: [JSON], to target: JSON) {
    guard canMove(moving, to: target) else { return }
    send(["action": target.string("kind") == "collection" ? "move" : "parent",
          "kind": moving.first?.string("kind") ?? "object", "ids": ids(moving),
          "target": target.string("id") ?? ""])
    Haptics.impact()
  }
}

struct HierarchyPanel: View {
  @ObservedObject var store: HierarchyStore
  let close: () -> Void
  @State private var rename: RenameRequest?
  @State private var deleting: [JSON] = []
  @State private var naming = false
  @State private var collectionName = "Collection"
  @Environment(\.panelInWindow) private var inWindow
  /** Beside the second bar in a wide window: its height, which the title strip takes (14A). */
  @Environment(\.secondBarHeight) private var bar

  /** Its title with Select and Add, a search field, the outline, and in Select mode the actions on
   * the selection along the bottom, as the system's lists have them. Plain SwiftUI, so the panel
   * sits the same in the window's sidebar, a sheet or a window of its own. */
  var body: some View {
    VStack(spacing: 0) {
      header
      PanelSearchField(text: $store.query, prompt: "Search", identifier: "blender.hierarchy.search")
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
      outline
      /* What Blender's Outliner has and this one does not, said rather than left out silently
       * (ROUND6 EDIT-7, D19). */
      Text("Collections and objects of this view layer. Other display modes, object contents and filters are in the Desktop Interface.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityIdentifier("blender.hierarchy.scope")
      if !store.status.isEmpty {
        Text(store.status)
          .font(.footnote)
          .foregroundStyle(.red)
          .padding(12)
      }
      if store.editing {
        HStack { selectionActions }
          .labelStyle(.iconOnly)
          .font(.title3)
          .padding(.horizontal, 24)
          .frame(height: 50)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .accessibilityIdentifier("blender.hierarchy.selectionBar")
      }
    }
    .renamePrompt($rename)
    .alert(deleteTitle, isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
      Button("Cancel", role: .cancel) { deleting = [] }
      Button("Delete", role: .destructive) {
        store.act("delete", deleting)
        deleting = []
      }
    } message: {
      Text(deleteMessage)
    }
    .alert("New Collection", isPresented: $naming) {
      TextField("Collection name", text: $collectionName)
        .textInputAutocapitalization(.never)
      Button("Cancel", role: .cancel) {}
      Button("Create") {
        store.send(["action": "collection_new", "value": collectionName])
      }
      .disabled(collectionName.trimmingCharacters(in: .whitespaces).isEmpty)
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Button(store.editing ? "Done" : "Select") {
        withMotion { store.editing.toggle() }
      }
      .fontWeight(store.editing ? .semibold : .regular)
      .buttonStyle(.bordered)
      .buttonBorderShape(.capsule)
      .accessibilityIdentifier("blender.hierarchy.select")
      Text("Outliner")
        .font(.headline)
        .frame(maxWidth: .infinity)
      Menu {
        Button("New Collection", systemImage: "folder.badge.plus") {
          collectionName = "Collection"
          naming = true
        }
        /* Blender's Add menu. */
        Menu {
          BlenderMenuItems(route: BlenderMenus.route("VIEW3D_MT_add"))
        } label: {
          Label { Text("Add Object") } icon: { BlenderIcon.image("OBJECT_DATA").map { Image(uiImage: $0) } }
        }
      } label: {
        Label("Add Collection or Object", systemImage: "plus")
          .labelStyle(.iconOnly)
          .frame(width: 32, height: 32)
      }
      .buttonStyle(.bordered)
      .buttonBorderShape(.circle)
      .prefetchingBlenderMenu(BlenderMenus.route("VIEW3D_MT_add"))
      .accessibilityIdentifier("blender.hierarchy.add")
      if !inWindow {
        Button("Close Outliner", systemImage: "xmark", action: close)
          .labelStyle(.iconOnly)
          .buttonStyle(.bordered)
          .buttonBorderShape(.circle)
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, bar == nil ? 8 : 0)
    .frame(height: bar)
    .modifier(SecondBarStrip(shown: bar != nil, zone: "outliner"))
  }

  private var deleteTitle: String {
    if deleting.count > 1 { return "Delete \(deleting.count) Objects?" }
    return "Delete \u{201C}\(deleting.first?.string("name") ?? "")\u{201D}?"
  }

  private var deleteMessage: String {
    if deleting.count == 1 && deleting[0].string("kind") == "collection" {
      return "Its objects and collections move to the parent collection. You can undo this change."
    }
    return deleting.count > 1 ? "They will be removed from this scene. You can undo this change." :
      "The object will be removed from this scene. You can undo this change."
  }

  private var outline: some View {
    OutlineList(store: store, rename: promptRename, delete: { deleting = $0 })
  }

  private func promptRename(_ node: JSON) {
    let collection = node.string("kind") == "collection"
    rename = RenameRequest(title: collection ? "Rename Collection" : "Rename Object",
                           name: node.string("name") ?? "") { name in
      store.act("rename", [node], value: name)
    }
  }

  @ViewBuilder
  private var selectionActions: some View {
    let nodes = store.selectedObjects
    let hidden = !nodes.isEmpty && nodes.allSatisfy { $0.bool("hidden") }
    Button("Duplicate", systemImage: "plus.square.on.square") { store.act("duplicate", nodes) }
      .disabled(!store.allow(nodes, "duplicate"))
    Spacer()
    Button(hidden ? "Show" : "Hide", systemImage: hidden ? "eye" : "eye.slash") {
      store.act("visibility", nodes, value: !hidden)
    }
    .disabled(!store.allow(nodes, "visibility"))
    Spacer()
    Menu("Move to Collection", systemImage: "folder") { MoveToCollectionMenu(store: store, nodes: nodes) }
      .disabled(nodes.isEmpty)
    Spacer()
    Button("Delete", systemImage: "trash", role: .destructive) { deleting = nodes }
      .disabled(!store.allow(nodes, "delete"))
  }
}

/* -------------------------------------------------------------------- */
/** \name Outline
 *
 * The tree as a SwiftUI list: tap to select, Select mode or a two-finger swipe to select several
 * as the system's lists do, swipe and touch and hold for actions, and drag rows into a
 * collection or onto an object.
 * \{ */

struct OutlineList: View {
  @ObservedObject var store: HierarchyStore
  let rename: (JSON) -> Void
  let delete: ([JSON]) -> Void
  /** Shown at once, until Blender's snapshot confirms it. */
  @State private var selection = Set<String>()
  /** The row a drag is over, which takes the dragged rows. */
  @State private var dropTarget: String?
  /** Rows are open until closed, as in Blender's Outliner. */
  @State private var collapsed = Set<String>()
  /** Drops onto rows, which the system's list does not pass to them itself. */
  @State private var dropper = OutlineDropper()

  private static func selected(_ nodes: [JSON]) -> Set<String> {
    Set(nodes.filter { $0.string("kind") == "object" && $0.bool("selected") }.compactMap { $0.string("key") })
  }

  /** Each row's children, in outline order; a search keeps its matches and their parents. */
  private var children: [String: [JSON]] {
    var result: [String: [JSON]] = [:]
    let nodes = store.visible
    let keys = Set(nodes.map(\.keyString))
    for node in nodes {
      let parent = node.string("parent") ?? ""
      result[keys.contains(parent) ? parent : "", default: []].append(node)
    }
    return result
  }

  /** The rows as they show, in outline order: those under a closed row are left out. */
  private func shownRows(_ children: [String: [JSON]]) -> [JSON] {
    var result: [JSON] = []
    func add(_ nodes: [JSON]) {
      for node in nodes {
        result.append(node)
        let key = node.keyString
        if !store.query.isEmpty || !collapsed.contains(key), let rows = children[key] { add(rows) }
      }
    }
    add(children[""] ?? [])
    return result
  }

  /**
   * The system's own list, so its rows swipe as every list's do: the actions uncover as the row
   * slides, and a long swipe runs the outermost.
   */
  var body: some View {
    let rows = shownRows(children)
    dropper.rows = rows.map(\.keyString)
    dropper.store = store
    dropper.target = { key in if dropTarget != key { dropTarget = key } }
    return List {
      ForEach(rows, id: \.keyString) { node in
        row(node)
          .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .swipeActions(edge: .trailing, allowsFullSwipe: true) { swipeButtons(node, ["delete", "visibility"]) }
          .swipeActions(edge: .leading) { swipeButtons(node, ["duplicate", "rename"]) }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .environment(\.defaultMinListRowHeight, 42)
#if !os(visionOS)
    .scrollDismissesKeyboard(.immediately)
#endif
    /* Published before it changes: the new nodes are the value sent. */
    .onReceive(store.$nodes) { nodes in selection = Self.selected(nodes) }
    .accessibilityIdentifier("blender.hierarchy.outline")
  }

  private var animation: Animation? { UIAccessibility.isReduceMotionEnabled ? nil : .smooth(duration: 0.25) }

  /** A tap selects the object; in Select mode, or with Shift or Command held on a keyboard, it adds
   * it to or takes it from the selection. A tap on a collection makes it the active collection, as
   * a click does in Blender's Outliner (ROUND6 EDIT-7, D18). */
  private func tap(_ node: JSON) {
    let key = node.keyString
    if node.string("kind") == "collection" {
      if !node.bool("current"), store.allow([node], "activate") {
        store.act("activate", [node])
        Haptics.selection()
      }
      return
    }
    guard node.string("kind") == "object", node.bool("enabled"), let id = node.string("id") else { return }
    /* Left and right Shift, and left and right Command, as GHOST numbers them. */
    let held = GHOST_ios_held_modifiers()
    let extending = held & (0b11 | 0b11 << 6) != 0
    if store.editing || extending {
      let on = !selection.contains(key)
      if on { selection.insert(key) } else { selection.remove(key) }
      store.send(["action": "select", "id": id, "extend": true, "value": on])
    }
    else {
      selection = [key]
      store.send(["action": "select", "id": id, "extend": false, "value": true])
    }
    Haptics.selection()
  }

  private func toggle(_ key: String) {
    withAnimation(animation) {
      if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }
  }

  private func row(_ node: JSON) -> some View {
    let key = node.keyString
    let collection = node.string("kind") == "collection"
    let enabled = node.bool("enabled")
    /* Select mode marks the selection with its check circles instead. */
    let selected = selection.contains(key) && !store.editing
    /* The active collection, lit softly as in Blender's Outliner. */
    let current = node.bool("current")
    let open = !store.query.isEmpty || !collapsed.contains(key)
    return HStack(spacing: 6) {
      if store.editing {
        Image(systemName: selection.contains(key) ? "checkmark.circle.fill" : "circle")
          .font(.title3)
          .foregroundStyle(selection.contains(key) ? Color.accentColor : .secondary)
          .opacity(!collection && enabled ? 1 : 0)
          .transition(.move(edge: .leading).combined(with: .opacity))
      }
      Color.clear.frame(width: CGFloat(14 * max(0, node.int("depth") ?? 0)), height: 1)
      Group {
        if store.hasChildren(node) {
          Button { toggle(key) } label: {
            Image(systemName: "chevron.right")
              .font(.footnote.weight(.semibold))
              .rotationEffect(.degrees(open ? 90 : 0))
              .frame(width: 22, height: 36)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .foregroundStyle(selected ? Color.white : .secondary)
          .accessibilityLabel(open ? "Collapse" : "Expand")
        }
        else {
          Color.clear
        }
      }
      .frame(width: 22)
      Group {
        if let image = BlenderIcon.image(node.string("icon"), themed: !selected) {
          /* On the selection, in its white, whatever color the artwork has. */
          Image(uiImage: image)
            .renderingMode(selected ? .template : nil)
            .resizable()
            .scaledToFit()
        }
        else {
          Image(systemName: collection ? "folder" : "cube")
        }
      }
      .frame(width: 22, height: 22)
      Text(node.string("name") ?? "")
        .foregroundStyle(selected ? Color.white : enabled ? .primary : .secondary)
        .lineLimit(1)
      Spacer(minLength: 0)
      if node.bool("hidden") {
        Button { store.act("visibility", [node], value: false) } label: {
          Image(systemName: "eye.slash").frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.white : .secondary)
        .accessibilityLabel("Show in viewport")
      }
    }
    .padding(.horizontal, 8)
    .frame(minHeight: 40)
    /* The selection as a rounded rectangle, as in the system's sidebars; a drag's target lit up
     * the same way. */
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(selected ? Color.accentColor : dropTarget == key ? Color.accentColor.opacity(0.3) :
              current ? Color.primary.opacity(0.1) : .clear))
    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .onTapGesture { tap(node) }
    .contextMenu { menu(store.targets(store.byKey[key] ?? node)) }
    /* Touch and hold lifts the row; moving it drags it into a collection or onto an object,
     * which the list's own view takes, see #OutlineDropper. */
    .draggable(startDrag(key, node)) { dragPreview(node) }
    .background(CollectionViewFinder { dropper.install(on: $0) })
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selection.contains(key) || current ? [.isButton, .isSelected] : .isButton)
    .accessibilityValue(current ? "Active collection" : "")
    .accessibilityIdentifier("blender.hierarchy." + (node.string("id") ?? ""))
  }

  /** The rows a drag from this one lifts, as text, or none when Blender cannot move them. */
  private func dragPayload(_ key: String, _ node: JSON) -> String {
    let rows = store.targets(store.byKey[key] ?? node)
    return store.allow(rows, "move") ? DraggedRows.payload(rows) : ""
  }

  /** The payload as a drag begins, kept to tell where its rows can go while it moves. */
  private func startDrag(_ key: String, _ node: JSON) -> String {
    let payload = dragPayload(key, node)
    /* The list asks again for a row beside it as the drag begins: the first is the one lifted. */
    if Date().timeIntervalSince(DraggedRows.since) > 0.5 {
      DraggedRows.current = DraggedRows.keys(payload)
      DraggedRows.since = Date()
    }
    return payload
  }

  /** The row as it looks while dragged, with its own icon. */
  private func dragPreview(_ node: JSON) -> some View {
    HStack(spacing: 8) {
      if let image = BlenderIcon.image(node.string("icon"), themed: true) {
        Image(uiImage: image).resizable().scaledToFit().frame(width: 22, height: 22)
      }
      Text(node.string("name") ?? "")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.regularMaterial, in: Capsule())
  }

  /** The actions a swipe shows, as Blender allows them for the row now, outermost first. */
  @ViewBuilder
  private func swipeButtons(_ node: JSON, _ actions: [String]) -> some View {
    let node = store.byKey[node.keyString] ?? node
    let hidden = node.bool("hidden")
    ForEach(actions.filter { store.allow([node], $0) }, id: \.self) { action in
      switch action {
        case "delete":
          /* Red as a delete is, without the destructive role: the row stays until it is confirmed. */
          Button { delete([node]) } label: { Label("Delete", systemImage: "trash") }
            .tint(.red)
        case "duplicate":
          Button { store.act("duplicate", [node]) } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
          }
          .tint(.blue)
        case "visibility":
          Button { store.act("visibility", [node], value: !hidden) } label: {
            Label(hidden ? "Show" : "Hide", systemImage: hidden ? "eye" : "eye.slash")
          }
          .tint(.gray)
        default:
          Button { rename(node) } label: { Label("Rename", systemImage: "pencil") }
            .tint(.orange)
      }
    }
  }

  @ViewBuilder
  private func menu(_ nodes: [JSON]) -> some View {
    let several = nodes.count > 1
    if !several, nodes.first?.bool("current") == true {
      Button {} label: { Label("Active Collection", systemImage: "checkmark") }
        .disabled(true)
    }
    else if !several && store.allow(nodes, "activate") {
      Button { store.act("activate", nodes) } label: {
        Label("Set Active Collection", systemImage: "folder.badge.plus")
      }
    }
    if !several && store.allow(nodes, "rename") {
      Button { rename(nodes[0]) } label: { Label("Rename", systemImage: "pencil") }
    }
    if store.allow(nodes, "duplicate") {
      Button { store.act("duplicate", nodes) } label: {
        Label(several ? "Duplicate \(nodes.count) Objects" : "Duplicate", systemImage: "plus.square.on.square")
      }
    }
    if store.allow(nodes, "visibility") {
      let hidden = nodes.allSatisfy { $0.bool("hidden") }
      Button { store.act("visibility", nodes, value: !hidden) } label: {
        Label(hidden ? "Show" : "Hide", systemImage: hidden ? "eye" : "eye.slash")
      }
    }
    MoveToCollectionMenu(store: store, nodes: nodes)
    if !several, let node = nodes.first { RestrictionsMenu(store: store, node: node) }
    if let target = store.unparentTarget(nodes) {
      /* Out from under the parent, staying where it is, as dropping it on its collection does. */
      Button { store.move(nodes, to: target) } label: {
        Label("Clear Parent", systemImage: "arrow.uturn.backward")
      }
    }
    if store.allow(nodes, "delete") {
      Divider()
      Button(role: .destructive) { delete(nodes) } label: {
        Label(several ? "Delete \(nodes.count) Objects" : "Delete", systemImage: "trash")
      }
    }
  }
}

/** Rows being dragged, as text naming their keys, which only this list reads. */
enum DraggedRows {
  private static let prefix = "blender.outliner.rows\n"
  /** The rows of the drag now going on, to tell where they can go while it moves. */
  @MainActor static var current: [String] = []
  @MainActor static var since = Date.distantPast

  static func payload(_ nodes: [JSON]) -> String {
    prefix + nodes.compactMap { $0.string("key") }.joined(separator: "\n")
  }

  static func keys(_ payload: String) -> [String] {
    guard payload.hasPrefix(prefix) else { return [] }
    return payload.dropFirst(prefix.count).split(separator: "\n").map(String.init)
  }
}

/** Blender's restriction flags of one row, by their own names and icons, as the Outliner's
 * restriction columns toggle them: what undims a row the Outliner dims (ROUND6 EDIT-7, D19). */
struct RestrictionsMenu: View {
  @ObservedObject var store: HierarchyStore
  let node: JSON

  var body: some View {
    let restrictions = node.array("restrictions")
    if !restrictions.isEmpty && store.allow([node], "restrict") {
      Menu {
        ForEach(restrictions, id: \.keyString) { item in
          Toggle(isOn: Binding(get: { item.bool("value") }, set: { on in
            store.act("restrict", [node], value: ["key": item.keyString, "value": on])
          })) {
            Label { Text(item.string("label") ?? item.keyString) } icon: {
              if let image = BlenderIcon.image(item.string("icon")) { Image(uiImage: image) }
            }
          }
        }
      } label: {
        Label("Restrictions", systemImage: "checklist")
      }
    }
  }
}

/** Collections the rows can move into, indented like the Outliner. */
struct MoveToCollectionMenu: View {
  @ObservedObject var store: HierarchyStore
  let nodes: [JSON]

  var body: some View {
    let targets = store.nodes.filter { $0.string("kind") == "collection" && store.canMove(nodes, to: $0) }
    if !targets.isEmpty {
      Menu {
        ForEach(Array(targets.enumerated()), id: \.offset) { _, target in
          Button {
            store.move(nodes, to: target)
          } label: {
            Label {
              Text(String(repeating: "  ", count: target.int("depth") ?? 0) + (target.string("name") ?? ""))
            } icon: {
              if let image = BlenderIcon.image("OUTLINER_COLLECTION") { Image(uiImage: image) }
            }
          }
        }
      } label: {
        Label("Move to Collection", systemImage: "folder")
      }
    }
  }
}

extension Dictionary where Key == String, Value == Any {
  var keyString: String { self["key"] as? String ?? "" }
}

/** \} */

/**
 * Drops onto the Outliner's rows. The system's list hands drops to no row of its own, so its
 * collection view takes them here and finds the row under the finger, lit while the dragged rows
 * can go into or under it.
 */
@MainActor
final class OutlineDropper: NSObject, UIDropInteractionDelegate {
  var rows: [String] = []
  weak var store: HierarchyStore?
  var target: (String?) -> Void = { _ in }
  private weak var collectionView: UICollectionView?

  func install(on view: UICollectionView) {
    guard collectionView !== view else { return }
    collectionView = view
    view.addInteraction(UIDropInteraction(delegate: self))
  }

  /** The row under the drag, where the dragged rows can go. Away from every row, children go
   * back into their collection, out from under their parent. */
  private func row(_ session: UIDropSession) -> String? {
    guard let view = collectionView, let store else { return nil }
    guard let index = view.indexPathForItem(at: session.location(in: view)), index.item < rows.count else {
      return store.unparentTarget(DraggedRows.current.compactMap { store.byKey[$0] })?.string("key")
    }
    let key = rows[index.item]
    guard let node = store.byKey[key] else { return nil }
    return store.canMove(DraggedRows.current.compactMap { store.byKey[$0] }, to: node) ? key : nil
  }

  func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
    session.localDragSession != nil && !DraggedRows.current.isEmpty
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
    let key = row(session)
    target(key)
    return UIDropProposal(operation: key == nil ? .forbidden : .move)
  }

  func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
    defer { target(nil) }
    guard let key = row(session), let provider = session.items.first?.itemProvider else { return }
    /* The rows the drag itself carries. */
    _ = provider.loadObject(ofClass: NSString.self) { payload, _ in
      guard let payload = payload as? String else { return }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let store = self.store, let node = store.byKey[key] else { return }
          store.move(DraggedRows.keys(payload).compactMap { store.byKey[$0] }, to: node)
        }
      }
    }
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
    target(nil)
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
    target(nil)
    DraggedRows.current = []
    DraggedRows.since = .distantPast
  }
}

/** Hands over the collection view of the list this sits in. */
private struct CollectionViewFinder: UIViewRepresentable {
  let found: (UICollectionView) -> Void

  func makeUIView(context: Context) -> UIView { FinderView(found: found) }
  func updateUIView(_ view: UIView, context: Context) {}

  private final class FinderView: UIView {
    let found: (UICollectionView) -> Void
    init(found: @escaping (UICollectionView) -> Void) {
      self.found = found
      super.init(frame: .zero)
      isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      var view = superview
      while let current = view, !(current is UICollectionView) { view = current.superview }
      if let list = view as? UICollectionView { found(list) }
    }
  }
}
