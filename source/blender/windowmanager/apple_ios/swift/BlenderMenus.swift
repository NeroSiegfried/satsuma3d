/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Blender's own menus, such as Add, a modifier's or the context menu, as SwiftUI menus. Their
 * items come from Blender, which builds them from the scene, so they are asked for ahead of time,
 * a few levels deep, and again only when Blender says what they show may have changed. A menu
 * whose items come back the same is left alone, and items keep their identity, so a change
 * updates only the items that changed. Choosing an item runs it in Blender.
 */

import SwiftUI
import UIKit

struct BlenderMenuItem: Identifiable, Equatable {
  /** Its place in Blender's menus, which stays the same as the menu changes around it. */
  var id: String { route }
  let title: String
  let icon: String
  /** Where the item is in Blender's menus, to open it as a submenu or run it. */
  let route: String
  let submenu: Bool
  let disabled: Bool
  let checked: Bool
  /** A new section starts at this item. */
  let sectionStart: Bool
  /** Deletes or removes something: shown in red with a bin, as the system's menus do. */
  let destructive: Bool
}

/** Whether a command deletes or removes, by its operator, such as `OBJECT_OT_delete` or
 * `OBJECT_OT_material_slot_remove`, or by its title where it has none, such as a Delete submenu. */
func isDestructive(operator idname: String?, title: String) -> Bool {
  if let idname, let range = idname.range(of: "_OT_") {
    let words = idname[range.upperBound...].split(separator: "_")
    return words.contains("delete") || words.last == "remove"
  }
  return title.hasPrefix("Delete") || title.hasPrefix("Remove")
}

@MainActor
@Observable
final class BlenderMenus {
  static let shared = BlenderMenus()

  /** Each menu's items, by its route. */
  private(set) var items: [String: [BlenderMenuItem]] = [:]
  @ObservationIgnored private var loading = Set<String>()
  /** What the menus were last asked for with: other modes and selections list other items. */
  @ObservationIgnored private var context: String?

  /** The route of a menu by Blender's name, such as `VIEW3D_MT_add`, optionally in a Properties
   * tab. */
  static func route(_ menu: String, tab: String? = nil) -> String {
    var route: [String: Any] = ["root": menu, "path": []]
    if let tab, !tab.isEmpty { route["propertiesTab"] = tab }
    return encode(route)
  }

  /** The context menu for what is selected. */
  static let contextRoute = route("context")

  private static func encode(_ route: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: route, options: .sortedKeys) else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  /** Ask Blender for a menu and the submenus under it, `depth` levels deep, unless they are known
   * for `context` already. */
  func prefetch(_ route: String, depth: Int = 3, context: String) {
    if context != self.context {
      self.context = context
      /* Keep showing the last items until the new ones arrive. */
      loading.removeAll()
      stale = Set(items.keys)
    }
    load(route, depth: depth)
  }

  @ObservationIgnored private var stale = Set<String>()

  private func load(_ route: String, depth: Int) {
    guard depth > 0, !loading.contains(route), items[route] == nil || stale.contains(route) else {
      for item in items[route] ?? [] where item.submenu && !item.disabled { load(item.route, depth: depth - 1) }
      return
    }
    loading.insert(route)
    Task {
      let list = await Self.request(route)
      loading.remove(route)
      stale.remove(route)
      guard let list else { return }
      if items[route] != list { items[route] = list }
      for item in list where item.submenu && !item.disabled { load(item.route, depth: depth - 1) }
    }
  }

  /** A menu's items as they are now, asked of Blender afresh. */
  func fetch(_ route: String) async -> [BlenderMenuItem]? {
    let list = await Self.request(route)
    if let list, items[route] != list { items[route] = list }
    return list
  }

  /** Items as the system's menu, each submenu filled as it opens. */
  static func uiMenu(_ items: [BlenderMenuItem], title: String = "") -> UIMenu {
    var sections: [[UIMenuElement]] = []
    for item in items {
      if item.sectionStart || sections.isEmpty { sections.append([]) }
      sections[sections.count - 1].append(element(item))
    }
    return UIMenu(title: title, children: sections.map { UIMenu(options: .displayInline, children: $0) })
  }

  private static func element(_ item: BlenderMenuItem) -> UIMenuElement {
    let image = item.destructive ? UIImage(systemName: "trash") :
      ["", "NONE", "BLANK1"].contains(item.icon) ? nil : BlenderIcon.image(item.icon)
    if item.submenu && !item.disabled {
      return UIMenu(title: item.title, image: image, children: [UIDeferredMenuElement.uncached { completion in
        Task { @MainActor in
          completion(uiMenu(await shared.fetch(item.route) ?? []).children)
        }
      }])
    }
    var attributes: UIMenuElement.Attributes = []
    if item.destructive { attributes.insert(.destructive) }
    if item.disabled { attributes.insert(.disabled) }
    return UIAction(title: item.title, image: image, attributes: attributes, state: item.checked ? .on : .off) { _ in
      shared.run(item)
    }
  }

  /**
   * An operator's choice of its enum items, as Blender would show in a popup menu: its headings
   * begin sections, and choosing one runs the operator with it, see `bridge_enum_popup`.
   */
  static func enumMenu(_ request: JSON) -> UIMenu? {
    guard let op = request.string("operator"), let property = request.string("property") else { return nil }
    var sections: [UIMenu] = []
    var children: [UIMenuElement] = []
    var heading = ""
    func flush() {
      if !children.isEmpty { sections.append(UIMenu(title: heading, options: .displayInline, children: children)) }
      children = []
    }
    for item in request.array("items") {
      let title = item.string("title") ?? ""
      if item.bool("heading") {
        flush()
        heading = title
        continue
      }
      guard let value = item.string("value"), !title.isEmpty else { continue }
      let icon = item.string("icon") ?? ""
      let image = ["", "NONE", "BLANK1"].contains(icon) ? nil : BlenderIcon.image(icon)
      children.append(UIAction(title: title, image: image) { _ in
        WM_native_ui_operator_enum_enqueue(op, property, value)
      })
    }
    flush()
    return sections.isEmpty ? nil : UIMenu(title: request.string("title") ?? "", children: sections)
  }

  /** An enum choice's sections, as `enumMenu` reads them: a heading, then its choices. */
  static func enumSections(_ request: JSON) -> [(heading: String, items: [JSON])] {
    var sections: [(heading: String, items: [JSON])] = []
    var heading = ""
    var items: [JSON] = []
    for item in request.array("items") {
      if item.bool("heading") {
        if !items.isEmpty { sections.append((heading, items)) }
        heading = item.string("title") ?? ""
        items = []
      }
      else if item.string("value") != nil, !(item.string("title") ?? "").isEmpty {
        items.append(item)
      }
    }
    if !items.isEmpty { sections.append((heading, items)) }
    return sections
  }

  /** Rename Active Item: the active object's name, or the active bone's, in a native field. */
  static func presentRename(from presenter: UIViewController, title: String, current: String) {
    var top = presenter
    while let presented = top.presentedViewController { top = presented }
    let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
    alert.addTextField { field in
      field.text = current
      field.clearButtonMode = .whileEditing
      field.autocapitalizationType = .none
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak alert] _ in
      guard let name = alert?.textFields?.first?.text, !name.isEmpty,
            let data = try? JSONSerialization.data(withJSONObject: name, options: .fragmentsAllowed),
            let json = String(data: data, encoding: .utf8)
      else { return }
      Engine.setting("rename_active", json)
    })
    top.present(alert, animated: true)
  }

  /** Run an item in Blender. */
  func run(_ item: BlenderMenuItem) {
    _ = item.route.withCString { WM_native_ui_menu_request($0, true) }
  }

  private static func request(_ route: String) async -> [BlenderMenuItem]? {
    let request = route.withCString { WM_native_ui_menu_request($0, false) }
    /* Blender answers between frames; it may be busy for a while, as when compiling shaders. */
    for _ in 0..<2400 {
      if let json = WM_native_ui_menu_take_result(request) {
        let data = Data(bytes: json, count: strlen(json))
        free(json)
        let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any] ?? []
        return parse(list)
      }
      try? await Task.sleep(for: .milliseconds(25))
    }
    return nil
  }

  private static func parse(_ list: [Any]) -> [BlenderMenuItem] {
    var result: [BlenderMenuItem] = []
    var sectionStart = false
    for entry in list {
      guard let item = entry as? JSON else { continue }
      if item.bool("separator") {
        sectionStart = !result.isEmpty
        continue
      }
      guard let title = item.string("title"), !title.isEmpty, let route = item["route"] as? JSON else { continue }
      result.append(BlenderMenuItem(title: title, icon: item.string("icon") ?? "",
                                    route: encode(route), submenu: item.bool("submenu"),
                                    disabled: item.bool("disabled"), checked: item.bool("checked"),
                                    sectionStart: sectionStart,
                                    destructive: isDestructive(operator: item.string("operator").flatMap { $0.isEmpty ? nil : $0 },
                                                               title: title)))
      sectionStart = false
    }
    return result
  }
}

/** Changes when what Blender's menus show may have, from the toolbar snapshot. */
extension EnvironmentValues {
  @Entry var blenderMenuContext = ""
}

/** A Blender menu's items, in sections as Blender separates them. */
struct BlenderMenuItems: View {
  let route: String
  private let menus = BlenderMenus.shared

  var body: some View {
    if let items = menus.items[route] {
      if items.isEmpty {
        Button("No Available Commands") {}.disabled(true)
      }
      ForEach(sections(items), id: \.first?.id) { section in
        Section {
          ForEach(section) { item in entry(item) }
        }
      }
    }
    else {
      Button("Loading…") {}.disabled(true)
    }
  }

  private func sections(_ items: [BlenderMenuItem]) -> [[BlenderMenuItem]] {
    var result: [[BlenderMenuItem]] = []
    for item in items {
      if item.sectionStart || result.isEmpty { result.append([item]) }
      else { result[result.count - 1].append(item) }
    }
    return result
  }

  @ViewBuilder
  private func entry(_ item: BlenderMenuItem) -> some View {
    if item.submenu && !item.disabled {
      Menu {
        BlenderMenuItems(route: item.route)
      } label: {
        label(item)
      }
    }
    else if item.checked {
      Toggle(isOn: Binding(get: { true }, set: { _ in menus.run(item) })) { label(item) }
        .disabled(item.disabled)
    }
    else {
      Button(role: item.destructive ? .destructive : nil) { menus.run(item) } label: { label(item) }
        .disabled(item.disabled)
    }
  }

  private func label(_ item: BlenderMenuItem) -> some View {
    Label {
      Text(item.title)
    } icon: {
      if item.destructive {
        Image(systemName: "trash")
      }
      else if !item.icon.isEmpty, item.icon != "NONE", item.icon != "BLANK1", let image = BlenderIcon.image(item.icon) {
        Image(uiImage: image)
      }
    }
  }
}

extension View {
  /** Ask for the menu at `route` ahead of time, again as the mode or selection changes. */
  func prefetchingBlenderMenu(_ route: String) -> some View {
    modifier(BlenderMenuPrefetch(route: route))
  }
}

private struct BlenderMenuPrefetch: ViewModifier {
  let route: String
  @Environment(\.blenderMenuContext) private var context

  func body(content: Content) -> some View {
    content.onChange(of: context, initial: true) { _, context in
      BlenderMenus.shared.prefetch(route, context: context)
    }
  }
}

/** A property's menu, such as Add Modifier or a material slot's, with its title and icon. */
struct BlenderMenuButton: View {
  let property: JSON

  var body: some View {
    let route = BlenderMenus.route(property.string("menu") ?? "", tab: property.string("tab"))
    Menu {
      BlenderMenuItems(route: route)
    } label: {
      Label {
        Text(property.string("label") ?? "")
      } icon: {
        if let image = BlenderIcon.image(property.string("icon")) { Image(uiImage: image) }
      }
    }
    .disabled(!property.bool("editable"))
    .prefetchingBlenderMenu(route)
  }
}

/** Every action for what is selected, as Blender's right-click menu lists them. */
struct ContextMenuButton: View {
  var systemImage = "ellipsis"
  var size: CGFloat = 44

  var body: some View {
    Menu {
      BlenderMenuItems(route: BlenderMenus.contextRoute)
    } label: {
      Image(systemName: systemImage)
        .frame(width: size, height: size)
        .contentShape(Rectangle())
    }
    .tint(.primary)
    .prefetchingBlenderMenu(BlenderMenus.contextRoute)
    .accessibilityLabel("Actions")
    .accessibilityIdentifier("blender.context-menu")
  }
}

/**
 * A long enum choice with headings, such as Add Constraint's, as a popover list where the pointer
 * is: an edit menu's horizontal strip leaves out section titles.
 */
struct EnumChoiceList: View {
  let request: JSON
  let dismiss: () -> Void

  var body: some View {
    let op = request.string("operator") ?? "", property = request.string("property") ?? ""
    NavigationStack {
      List {
        ForEach(Array(BlenderMenus.enumSections(request).enumerated()), id: \.offset) { _, section in
          Section(section.heading) {
            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
              Button {
                WM_native_ui_operator_enum_enqueue(op, property, item.string("value") ?? "")
                dismiss()
              } label: {
                Label {
                  Text(item.string("title") ?? "")
                } icon: {
                  let icon = item.string("icon") ?? ""
                  if !["", "NONE", "BLANK1"].contains(icon), let image = BlenderIcon.image(icon) {
                    Image(uiImage: image)
                  }
                }
              }
              .foregroundStyle(.primary)
            }
          }
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle(request.string("title") ?? "")
      .navigationBarTitleDisplayMode(.inline)
    }
    .frame(idealWidth: 340, idealHeight: 520)
  }
}
