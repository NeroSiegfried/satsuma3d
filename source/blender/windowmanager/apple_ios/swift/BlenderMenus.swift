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
   * tab, after a tab character. */
  static func route(_ menu: String, tab: String? = nil) -> String {
    guard let tab, !tab.isEmpty else { return menu }
    return menu + "\t" + tab
  }

  /** The context menu for what is selected. */
  static let contextRoute = route("context")

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
  static func enumMenu(_ request: EnumChoice) -> UIMenu? {
    let sections = request.sections.map { section in
      UIMenu(title: section.heading, options: .displayInline, children: section.items.map { item in
        let image = ["", "NONE", "BLANK1"].contains(item.icon) ? nil : BlenderIcon.image(item.icon)
        return UIAction(title: item.title, image: image) { _ in request.choose(item.value) }
      })
    }
    return sections.isEmpty ? nil : UIMenu(title: request.title, children: sections)
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
      guard let name = alert?.textFields?.first?.text, !name.isEmpty else { return }
      ShellModel.current?.send("active_name", .set_, .text(name))
    })
    top.present(alert, animated: true)
  }


  /** Ask Blender for a menu: its `menu` view, built once, read as it arrives. */
  private static func request(_ route: String) async -> [BlenderMenuItem]? {
    await menu(route).map { items($0.nodes) }
  }

  /** A menu's nodes as Blender built them, with Blender's cursor at a window position in pixels
   * for menus that list what is there, and its heading. */
  static func menu(_ route: String, at position: CGPoint? = nil) async -> (heading: String, nodes: [NativeNode])? {
    var params: [String: NativeValue] = ["route": .text(route)]
    if let position {
      params["x"] = .float(Double(position.x))
      params["y"] = .float(Double(position.y))
    }
    let view = NativeViews.shared.subscribe("menu", params: params)
    defer { NativeViews.shared.unsubscribe(view) }
    /* Blender answers between frames; it may be busy for a while, as when compiling shaders. */
    for _ in 0..<2400 {
      if let top = view.top { return (top.label, view.children(of: top)) }
      try? await Task.sleep(for: .milliseconds(25))
    }
    return nil
  }

  private static func items(_ nodes: [NativeNode]) -> [BlenderMenuItem] {
    var result: [BlenderMenuItem] = []
    var sectionStart = false
    for node in nodes {
      if node.kind == .separator {
        sectionStart = !result.isEmpty
        continue
      }
      guard !node.label.isEmpty else { continue }
      let button = node.content(Blender_NativeUI_Button.self)
      result.append(BlenderMenuItem(title: node.label, icon: node.icon ?? "", route: node.key,
                                    submenu: node.kind == .menubutton, disabled: !node.enabled,
                                    checked: button?.pressed ?? false, sectionStart: sectionStart,
                                    destructive: isDestructive(operator: button?.operator_, title: node.label)))
      sectionStart = false
    }
    return result
  }

  /** Where items are run, by their routes. */
  @ObservationIgnored private let runner = NativeViews.shared.subscribe("menu")

  /** Run an item in Blender, with its cursor at a window position in pixels, for operators that
   * follow the pointer from there, such as Bevel. */
  func run(_ item: BlenderMenuItem, at position: CGPoint? = nil) {
    var params: [String: NativeValue] = [:]
    if let position {
      params = ["x": .float(Double(position.x)), "y": .float(Double(position.y))]
    }
    NativeViews.shared.send(runner, target: item.route, op: .invoke, params: params)
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
/** An operator's choice of its enum items, from the `choice` of Blender's `popup` view. */
struct EnumChoice {
  struct Item {
    let title: String
    let value: String
    let icon: String
  }

  let title: String
  /** Its items, a heading before each group of them. */
  var sections: [(heading: String, items: [Item])] = []
  let choose: (String) -> Void

  @MainActor
  init(node: NativeNode, choose: @escaping (String) -> Void) {
    title = node.label
    self.choose = choose
    var heading = ""
    var items: [Item] = []
    for option in node.choice?.allOptions ?? [] {
      guard let value = option.value else {
        if !items.isEmpty { sections.append((heading, items)) }
        heading = option.label ?? ""
        items = []
        continue
      }
      if let label = option.label, !label.isEmpty { items.append(Item(title: label, value: value, icon: option.icon ?? "")) }
    }
    if !items.isEmpty { sections.append((heading, items)) }
  }
}

struct EnumChoiceList: View {
  let request: EnumChoice
  let dismiss: () -> Void

  var body: some View {
    NavigationStack {
      List {
        ForEach(Array(request.sections.enumerated()), id: \.offset) { _, section in
          Section(section.heading) {
            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
              Button {
                request.choose(item.value)
                dismiss()
              } label: {
                Label {
                  Text(item.title)
                } icon: {
                  if !["", "NONE", "BLANK1"].contains(item.icon), let image = BlenderIcon.image(item.icon) {
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
      .navigationTitle(request.title)
      .navigationBarTitleDisplayMode(.inline)
    }
    .frame(idealWidth: 340, idealHeight: 520)
  }
}

/**
 * Blender's menus for the window's Objective-C code, which builds the menu bar, the viewport's
 * context menu and the Pencil's radial menu from them: each item as a dictionary of its `title`,
 * `route`, `icon`, whether it is a `submenu` (and of which `menu`), an `action`, `disabled` or
 * `checked`, its `operator` and shortcut `key`; or a `separator`, or the menu's `heading`.
 */
@MainActor
@objc(WMIOSSwiftMenus)
final class SwiftMenus: NSObject {
  /** The menu at a route, or nil should Blender not answer; with `positioned`, with Blender's
   * cursor at \a x, \a y in the window's pixels. */
  @objc static func items(route: String, x: Double, y: Double, positioned: Bool,
                          completion: @escaping ([NSDictionary]?) -> Void)
  {
    Task { @MainActor in
      guard let menu = await BlenderMenus.menu(route, at: positioned ? CGPoint(x: x, y: y) : nil) else {
        completion(nil)
        return
      }
      var result: [NSDictionary] = menu.heading.isEmpty ? [] : [["heading": menu.heading]]
      result += menu.nodes.compactMap(dictionary)
      completion(result)
    }
  }

  /** Run the item at a route, with Blender's cursor at \a x, \a y with `positioned`. */
  @objc static func run(route: String, x: Double, y: Double, positioned: Bool) {
    BlenderMenus.shared.run(BlenderMenuItem(title: "", icon: "", route: route, submenu: false, disabled: false,
                                            checked: false, sectionStart: false, destructive: false),
                            at: positioned ? CGPoint(x: x, y: y) : nil)
  }

  private static func dictionary(_ node: NativeNode) -> NSDictionary? {
    if node.kind == .separator { return ["separator": 1] }
    let item: NSMutableDictionary = [
      "title": node.label, "route": node.key, "icon": node.icon ?? "",
      "disabled": node.enabled ? 0 : 1, "submenu": node.kind == .menubutton ? 1 : 0,
      "action": node.kind == .button ? 1 : 0,
    ]
    if let button = node.content(Blender_NativeUI_Button.self) {
      item["checked"] = button.pressed ? 1 : 0
      item["operator"] = button.operator_ ?? ""
      if let key = button.key, !key.isEmpty {
        /* Modifiers before the key, joined by `+`, as Blender writes them. */
        var parts = key.split(separator: "+").map(String.init)
        let type = parts.removeLast()
        item["key"] = ["type": type, "ctrl": parts.contains("ctrl") ? 1 : 0, "alt": parts.contains("alt") ? 1 : 0,
                       "shift": parts.contains("shift") ? 1 : 0, "oskey": parts.contains("oskey") ? 1 : 0]
      }
    }
    if let button = node.content(Blender_NativeUI_MenuButton.self) {
      let menu = (0..<button.paramsCount).compactMap { button.params(at: $0) }
        .first { $0.key == "menu" }?.value(type: Blender_NativeUI_TextValue.self)?.value
      if let menu, !menu.isEmpty { item["menu"] = menu }
    }
    return item
  }
}
