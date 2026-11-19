/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Search, as Blender's F3: every command there is, by typing part of its name. The quick actions
 * of the registry come first, dimmed with the reason where they cannot run; then every item of
 * Blender's menus for the mode (the header's, the context menu, Import and Export), each with the
 * path to it ("Mesh › Clean Up › Merge by Distance"). The menus are walked once a mode, when
 * Search first opens. Recent commands lead an empty search, and any result can be pinned to the
 * action bar, as Blender's Quick Favourites.
 */

import SwiftUI

@MainActor
@Observable
final class CommandSearch {
  static let shared = CommandSearch()

  struct Entry: Identifiable, Hashable {
    /** `action:<id>` for a registry action, `menu:<route>` for a menu item. */
    let id: String
    let title: String
    /** Where it is: the group or the menus leading to it. */
    let path: String
    let icon: String
    let enabled: Bool
    let why: String
  }

  private(set) var menuEntries: [Entry] = []
  private(set) var walking = false
  @ObservationIgnored private var walked: String?
  @ObservationIgnored private var menuItems: [String: BlenderMenuItem] = [:]
  /** The registry's palette, from the `actions` view, while Search shows. */
  let palette: NativeView = {
    let view = NativeViews.shared.subscribe("actions", params: ["surface": .text("palette")])
    NativeViews.shared.pause(view)
    return view
  }()

  static let recentKey = "BlenderRecentCommands"
  static let pinnedKey = "BlenderPinnedCommands"

  /* -------------------------------------------------------------------- */
  /* Entries */

  var actionEntries: [Entry] {
    guard let top = palette.top else { return [] }
    var result: [Entry] = []
    func visit(_ node: NativeNode, path: String) {
      for child in palette.children(of: node) {
        if child.key.hasPrefix("action:") {
          result.append(Entry(id: child.key, title: child.label, path: path, icon: child.icon ?? "",
                              enabled: child.enabled, why: child.node.description ?? ""))
        }
        else {
          visit(child, path: child.label.isEmpty ? path : child.label)
        }
      }
    }
    visit(top, path: "")
    return result
  }

  /** Walk Blender's menus for \a context, once, to depth 4. */
  func walk(context: String) {
    guard walked != context, !walking else { return }
    walked = context
    walking = true
    Task { @MainActor in
      var entries: [Entry] = []
      var items: [String: BlenderMenuItem] = [:]
      var roots: [(route: String, path: String)] = []
      if let header = await BlenderMenus.shared.fetch(EditorMenus.route) {
        roots += header.filter { $0.submenu }.map { ($0.route, $0.title) }
      }
      roots.append((BlenderMenus.contextRoute, "Context Menu"))
      /* Blender's File menu, its Import, Export and housekeeping with it (ROUND6 FILES-7); what
       * the menu bar hides it hides too. */
      roots.append((BlenderMenus.route("TOPBAR_MT_file"), "File"))
      var queue = roots.map { ($0.route, $0.path, 1) }
      var seen = Set<String>()
      while !queue.isEmpty {
        let (route, path, depth) = queue.removeFirst()
        guard seen.insert(route).inserted, let list = await BlenderMenus.shared.fetch(route) else { continue }
        for item in list {
          if item.submenu {
            if depth < 4 && !item.disabled { queue.append((item.route, path + " › " + item.title, depth + 1)) }
            continue
          }
          items[item.route] = item
          entries.append(Entry(id: "menu:" + item.route, title: item.title, path: path,
                               icon: item.destructive ? "TRASH" : item.icon, enabled: !item.disabled, why: ""))
        }
      }
      menuEntries = entries
      menuItems = items
      walking = false
    }
  }

  func results(_ query: String) -> [Entry] {
    let all = actionEntries + menuEntries
    let words = query.lowercased().split(separator: " ").map(String.init)
    guard !words.isEmpty else { return [] }
    let matches = all.filter { entry in
      let haystack = (entry.title + " " + entry.path).lowercased()
      return words.allSatisfy { haystack.contains($0) }
    }
    /* Names that start with what was typed first, then those that can run, then shorter paths. */
    return matches.sorted { a, b in
      let ap = a.title.lowercased().hasPrefix(words[0]), bp = b.title.lowercased().hasPrefix(words[0])
      if ap != bp { return ap }
      if a.enabled != b.enabled { return a.enabled }
      return a.path.count < b.path.count
    }
  }

  /* -------------------------------------------------------------------- */
  /* Running, recents and pins */

  func run(_ entry: Entry) {
    run(id: entry.id)
    var recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
    recent.removeAll { $0 == entry.id }
    recent.insert(entry.id, at: 0)
    UserDefaults.standard.set(Array(recent.prefix(8)), forKey: Self.recentKey)
    remember(entry)
  }

  func run(id: String) {
    if id.hasPrefix("action:") {
      ShellModel.current?.send(id, .invoke)
    }
    else if id.hasPrefix("menu:") {
      let route = String(id.dropFirst("menu:".count))
      if let item = menuItems[route] {
        BlenderMenus.shared.run(item)
      }
      else {
        ShellModel.current?.messages.say("That command is not in this mode's menus", level: "warning")
      }
    }
  }

  /** Entries by id as last seen, for recents and pins across modes. */
  @ObservationIgnored private var known: [String: Entry] = [:]

  private func remember(_ entry: Entry) {
    known[entry.id] = entry
  }

  var recent: [Entry] {
    let all = Dictionary((actionEntries + menuEntries).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    return (UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []).compactMap { all[$0] ?? known[$0] }
  }

  /** Pinned: id, title and icon, so the action bar shows them without asking Blender. */
  private(set) var pinned: [[String]] = UserDefaults.standard.array(forKey: CommandSearch.pinnedKey) as? [[String]] ?? []

  func isPinned(_ id: String) -> Bool { pinned.contains { $0.first == id } }

  func togglePin(_ entry: Entry) {
    if isPinned(entry.id) {
      pinned.removeAll { $0.first == entry.id }
    }
    else {
      pinned.append([entry.id, entry.title, entry.icon])
    }
    UserDefaults.standard.set(pinned, forKey: Self.pinnedKey)
  }

  /** The pinned commands as quick actions, after the registry's. */
  var pinnedActions: [QuickAction] {
    pinned.compactMap { pin in
      guard pin.count >= 3 else { return nil }
      return QuickAction(id: "pin:" + pin[0], title: pin[1], operatorName: "", key: "", icon: pin[2], selected: false)
    }
  }
}

/** The Search sheet. */
struct CommandSearchSheet: View {
  let model: ShellModel
  let dismiss: () -> Void
  @State private var query = ""
  private let search = CommandSearch.shared

  var body: some View {
    NavigationStack {
      List {
        if query.isEmpty {
          if !search.recent.isEmpty {
            Section("Recent") { ForEach(search.recent) { row($0) } }
          }
          if !search.actionEntries.isEmpty {
            Section("Actions") { ForEach(search.actionEntries) { row($0) } }
          }
        }
        else {
          let results = search.results(query)
          if results.isEmpty && !search.walking {
            Text("No commands match “\(query)”").foregroundStyle(.secondary)
          }
          ForEach(results) { row($0) }
        }
        if search.walking {
          HStack {
            ProgressView()
            Text("Reading the menus…").foregroundStyle(.secondary)
          }
        }
      }
      .searchableInBar(text: $query)
      .navigationTitle("Search")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done", action: dismiss) }
      }
    }
    .onAppear {
      NativeViews.shared.resume(search.palette)
      search.walk(context: model.menuContext)
    }
    .onDisappear { NativeViews.shared.pause(search.palette) }
  }

  private func row(_ entry: CommandSearch.Entry) -> some View {
    Button {
      guard entry.enabled else { return }
      search.run(entry)
      dismiss()
    } label: {
      HStack(spacing: 12) {
        Group {
          if let image = BlenderIcon.image(entry.icon) {
            Image(uiImage: image).resizable().scaledToFit()
          }
          else {
            Color.clear
          }
        }
        .frame(width: 22, height: 22)
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.title)
            .foregroundStyle(entry.enabled ? Color.primary : Color.secondary)
          if !entry.path.isEmpty || !entry.why.isEmpty {
            Text(entry.enabled ? entry.path : (entry.why.isEmpty ? entry.path : entry.why))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 0)
        if search.isPinned(entry.id) {
          Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button(search.isPinned(entry.id) ? "Unpin from Action Bar" : "Pin to Action Bar",
             systemImage: search.isPinned(entry.id) ? "pin.slash" : "pin") {
        search.togglePin(entry)
      }
    }
    .swipeActions {
      Button(search.isPinned(entry.id) ? "Unpin" : "Pin", systemImage: "pin") { search.togglePin(entry) }
        .tint(.blue)
    }
  }
}
