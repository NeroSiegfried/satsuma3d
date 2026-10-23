/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Settings: the iPad's own page first, with the keyboard shortcuts, how Apple Pencil and fingers
 * work, and which controls the interface shows, then Blender's Preferences, a page for each of
 * their sections, in a sidebar as the system's Settings has them. Pencil and interface settings
 * belong to the iPad and are kept in its user defaults; the keymap and the Preferences are
 * Blender's. Blender sends a section's panels as it does the Properties', see
 * `interface_native_properties.cc`, and the form is the inspector's.
 */

import SwiftUI
import UIKit

/* -------------------------------------------------------------------- */
/** \name Model
 * \{ */

enum TouchInput: String, CaseIterable, Identifiable {
  case pencilOnly
  case pencilAndFingers
  var id: String { rawValue }
}

@MainActor
final class SettingsModel: ObservableObject {
  static let fingerUsesToolKey = "BlenderFingerUsesTool"
  static let showQuickActionsKey = "BlenderShowQuickActions"
  static let hoverHighlightKey = "BlenderHoverHighlight"

  /** Blender's active keymap preset, from the toolbar snapshot. */
  @Published var keymap = "Industry_Compatible"
  @Published var touchInput: TouchInput {
    didSet {
      guard touchInput != oldValue else { return }
      UserDefaults.standard.set(touchInput == .pencilAndFingers, forKey: Self.fingerUsesToolKey)
      fingerUsesToolChanged?(touchInput == .pencilAndFingers)
    }
  }
  @Published var showQuickActions: Bool {
    didSet {
      guard showQuickActions != oldValue else { return }
      UserDefaults.standard.set(showQuickActions, forKey: Self.showQuickActionsKey)
    }
  }
  /** What the Pencil or pointer hovers over in the viewport is highlighted. */
  @Published var hoverHighlight: Bool {
    didSet {
      guard hoverHighlight != oldValue else { return }
      UserDefaults.standard.set(hoverHighlight, forKey: Self.hoverHighlightKey)
      Engine.setting("hover_highlight", hoverHighlight ? "1" : "0")
    }
  }
  /** The sidebar on the right and the brushes on the left, read by the viewport's controls. */
  @Published var leftHanded: Bool {
    didSet {
      guard leftHanded != oldValue else { return }
      UserDefaults.standard.set(leftHanded, forKey: leftHandedInterfaceKey)
    }
  }

  var fingerUsesToolChanged: ((Bool) -> Void)?
  var done: (() -> Void)?

  init() {
    let defaults = UserDefaults.standard
    touchInput = defaults.bool(forKey: Self.fingerUsesToolKey) ? .pencilAndFingers : .pencilOnly
    showQuickActions = defaults.object(forKey: Self.showQuickActionsKey) as? Bool ?? true
    hoverHighlight = defaults.object(forKey: Self.hoverHighlightKey) as? Bool ?? true
    leftHanded = defaults.bool(forKey: leftHandedInterfaceKey)
  }

  func setKeymap(_ name: String) {
    guard name != keymap else { return }
    keymap = name
    Engine.setting("keymap", name)
  }
}

/** The add-ons and keymaps, which Blender's Preferences draw with lists of their own: Blender
 * sends them with the section's panels, see `bl_ui.native_settings`, and Settings lists them in
 * its own way. */
@MainActor
@Observable
final class PreferencesLists {
  struct Addon: Identifiable, Equatable {
    let id: String
    let name: String
    let category: String
    let description: String
    let warning: String
    var enabled: Bool
  }

  struct KeymapItem: Identifiable, Equatable {
    let id: Int
    let name: String
    let keys: String
    var active: Bool
  }

  struct Keymap: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let title: String
    let depth: Int
    var items: [KeymapItem]?
  }

  private(set) var addons: [Addon] = []
  private(set) var keymaps: [Keymap] = []
  private(set) var expandedKeymaps: Set<String> = []
  /** What the keymaps are searched for. */
  var keymapSearch = "" {
    didSet { if keymapSearch != oldValue { sendKeymapState() } }
  }

  /** The `addons` or `keymaps` the Preferences snapshot carries for their section. */
  func update(_ preferences: JSON) {
    if preferences["addons"] != nil {
      let next = preferences.array("addons").map {
        Addon(id: $0.string("module") ?? "", name: $0.string("name") ?? "",
              category: $0.string("category") ?? "", description: $0.string("description") ?? "",
              warning: $0.string("warning") ?? "", enabled: $0.bool("enabled"))
      }
      if next != addons { addons = next }
    }
    if preferences["keymaps"] != nil {
      let next = preferences.array("keymaps").map { keymap in
        Keymap(name: keymap.string("name") ?? "", title: keymap.string("title") ?? "",
               depth: keymap.int("depth") ?? 0,
               items: keymap["items"] == nil ? nil : keymap.array("items").map {
                 KeymapItem(id: $0.int("id") ?? 0, name: $0.string("name") ?? "",
                            keys: $0.string("keys") ?? "", active: $0.bool("active"))
               })
      }
      if next != keymaps { keymaps = next }
    }
  }

  func setAddon(_ addon: Addon, enabled: Bool) {
    if let index = addons.firstIndex(where: { $0.id == addon.id }) { addons[index].enabled = enabled }
    Engine.setting("native_addon", json: ["module": addon.id, "enable": enabled])
  }

  func setKeymapItem(_ item: KeymapItem, in keymap: Keymap, active: Bool) {
    if let index = keymaps.firstIndex(where: { $0.id == keymap.id }),
       let itemIndex = keymaps[index].items?.firstIndex(where: { $0.id == item.id })
    {
      keymaps[index].items?[itemIndex].active = active
    }
    Engine.setting("native_keymap_item_active", json: ["keymap": keymap.name, "id": item.id, "active": active])
  }

  func setExpanded(_ keymap: Keymap, _ expanded: Bool) {
    if expanded { expandedKeymaps.insert(keymap.name) } else { expandedKeymaps.remove(keymap.name) }
    sendKeymapState()
  }

  private func sendKeymapState() {
    Engine.setting("native_keymaps_state",
                   json: ["expanded": Array(expandedKeymaps), "search": keymapSearch] as JSON)
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name View
 * \{ */

/** A choice with an explanation below its title, as in the system's Settings. */
private struct ChoiceRow: View {
  let title: String
  let detail: String
  let symbol: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Image(systemName: symbol)
          .frame(width: 28)
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).foregroundStyle(.primary)
          Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        if selected {
          Image(systemName: "checkmark")
            .fontWeight(.semibold)
            .foregroundStyle(.tint)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/** The Pencil's pressure response, from a firm touch to a light one, with its curve: the force
 * across, the pressure Blender gets up. See `pencil_pressure` in `GHOST_WindowIOS.mm`. */
private struct PencilPressureControl: View {
  @AppStorage("BlenderPencilPressureSensitivity") private var sensitivity = 0.5

  var body: some View {
    VStack(spacing: 12) {
      Canvas { context, size in
        let full = 0.9 - 0.5 * sensitivity, exponent = 1.0 - 0.75 * sensitivity
        var grid = Path()
        for step in 1..<4 {
          let t = CGFloat(step) / 4
          grid.move(to: CGPoint(x: t * size.width, y: 0))
          grid.addLine(to: CGPoint(x: t * size.width, y: size.height))
          grid.move(to: CGPoint(x: 0, y: t * size.height))
          grid.addLine(to: CGPoint(x: size.width, y: t * size.height))
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
        var curve = Path()
        for step in 0...64 {
          let x = Double(step) / 64
          let y = pow(min(1, x / full), exponent)
          let point = CGPoint(x: CGFloat(x) * size.width, y: size.height * (1 - CGFloat(y)))
          if step == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
        }
        context.stroke(curve, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
      }
      .frame(height: 96)
      .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
      .accessibilityHidden(true)
      Slider(value: $sensitivity, in: 0...1) {
        Text("Pressure")
      } minimumValueLabel: {
        Text("Firm").font(.footnote).foregroundStyle(.secondary)
      } maximumValueLabel: {
        Text("Light").font(.footnote).foregroundStyle(.secondary)
      }
      .accessibilityValue(sensitivity < 0.35 ? "Firm" : sensitivity > 0.65 ? "Light" : "Medium")
    }
    .padding(.vertical, 4)
  }
}

/** The iPad's own settings, the first page. */
private struct IPadSettingsPage: View {
  @ObservedObject var model: SettingsModel
  @AppStorage("BlenderFingerDragsObjects") private var fingerDragsObjects = false
  @AppStorage("BlenderPencilSqueeze") private var squeeze = "palette"
  /** Read as it changes by the app's event handling, see `show_touches` in `GHOST_SystemIOS.mm`. */
  @AppStorage("BlenderShowTouches") private var showTouches = false

  var body: some View {
    Form {
      Section {
        ChoiceRow(title: "Apple Pencil Only",
                  detail: "Fingers move the view. Apple Pencil uses the active tool.",
                  symbol: "applepencil",
                  selected: model.touchInput == .pencilOnly) { model.touchInput = .pencilOnly }
        ChoiceRow(title: "Pencil and Fingers",
                  detail: "One finger uses the active tool. Two fingers orbit and pinch to zoom, three pan.",
                  symbol: "hand.point.up.left",
                  selected: model.touchInput == .pencilAndFingers) {
          model.touchInput = .pencilAndFingers
        }
        if model.touchInput == .pencilAndFingers {
          Toggle(isOn: $fingerDragsObjects) {
            Label("Drag Objects with Fingers", systemImage: "hand.draw")
          }
        }
      } header: {
        Text("Apple Pencil & Touch")
      } footer: {
        if model.touchInput == .pencilAndFingers {
          Text("With Tweak, each finger landing on an object moves it, several at once. Fingers on "
            + "objects then don't orbit the view.")
        }
      }

      Section {
        ChoiceRow(title: "Industry Compatible",
                  detail: "Shortcuts familiar from other 3D apps.",
                  symbol: "keyboard",
                  selected: model.keymap == "Industry_Compatible") {
          model.setKeymap("Industry_Compatible")
        }
        ChoiceRow(title: "Blender",
                  detail: "Blender's own shortcuts, as on a desktop computer.",
                  symbol: "keyboard.badge.ellipsis",
                  selected: model.keymap == "Blender") { model.setKeymap("Blender") }
      } header: {
        Text("Keyboard Shortcuts")
      } footer: {
        Text("Used with a connected keyboard. Touch and Pencil gestures work the same with either.")
      }

      Section {
        PencilPressureControl()
      } header: {
        Text("Pencil Pressure")
      } footer: {
        Text("How hard to press for a full stroke. Lighter reaches full size and strength sooner.")
      }

      Section {
        ChoiceRow(title: "Tool Palette",
                  detail: "The brushes or tools by the Pencil, to choose from with it.",
                  symbol: "pencil.and.scribble",
                  selected: squeeze != "menu") { squeeze = "palette" }
        ChoiceRow(title: "Context Menu",
                  detail: "Blender's context menu around the Pencil.",
                  symbol: "circle.circle",
                  selected: squeeze == "menu") { squeeze = "menu" }
      } header: {
        Text("Squeeze Apple Pencil Pro")
      } footer: {
        Text("Anywhere over the viewport, when squeezing shows the tool palette in the iPad's Apple "
          + "Pencil settings.")
      }

      Section {
        Toggle("Quick Actions", isOn: $model.showQuickActions)
        Toggle("Hover Highlighting", isOn: $model.hoverHighlight)
        Toggle("Show Touches", isOn: $showTouches)
      } header: {
        Text("Interface")
      } footer: {
        Text("Quick Actions are buttons for common actions on the selection, above the bottom of "
          + "the viewport. Hover Highlighting outlines what Apple Pencil or the pointer is over. "
          + "Show Touches draws a circle under each finger, for recordings and demonstrations.")
      }

      Section {
        Picker("Hand", selection: $model.leftHanded) {
          Text("Right-Hand Interface").tag(false)
          Text("Left-Hand Interface").tag(true)
        }
        .pickerStyle(.inline)
        .labelsHidden()
      } header: {
        Text("Drawing Hand")
      } footer: {
        Text("Brush size, strength and + and − sit on the side of the hand not holding the Pencil, the brushes on the other.")
      }
    }
  }
}

/** The add-ons, by category, each turned on and off with a switch. */
private struct AddonsPage: View {
  let lists: PreferencesLists
  @State private var search = ""
  @State private var enabledOnly = false

  private var categories: [(String, [PreferencesLists.Addon])] {
    let query = search.trimmingCharacters(in: .whitespaces)
    let shown = lists.addons.filter { addon in
      (!enabledOnly || addon.enabled) &&
        (query.isEmpty || addon.name.localizedCaseInsensitiveContains(query) ||
         addon.category.localizedCaseInsensitiveContains(query) ||
         addon.description.localizedCaseInsensitiveContains(query))
    }
    return Dictionary(grouping: shown, by: \.category)
      .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
      .map { ($0.key, $0.value) }
  }

  var body: some View {
    Form {
      Section {
        Toggle("Enabled Add-ons Only", isOn: $enabledOnly)
      }
      ForEach(categories, id: \.0) { category, addons in
        Section(category) {
          ForEach(addons) { addon in
            Toggle(isOn: Binding(get: { addon.enabled }, set: { lists.setAddon(addon, enabled: $0) })) {
              VStack(alignment: .leading, spacing: 2) {
                Text(addon.name)
                if !addon.description.isEmpty {
                  Text(addon.description).font(.footnote).foregroundStyle(.secondary)
                }
                if !addon.warning.isEmpty {
                  Label(addon.warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
              }
            }
          }
        }
      }
    }
    .searchable(text: $search, placement: .toolbar, prompt: "Search Add-ons")
    .overlay {
      if lists.addons.isEmpty { ProgressView() }
      else if categories.isEmpty { ContentUnavailableView.search(text: search) }
    }
  }
}

/** The keymaps, in Blender's hierarchy, each opening to its items: what they do and their keys,
 * each turned on and off with a switch. Shown below the Keymap section's panels. */
private struct KeymapList: View {
  let lists: PreferencesLists

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(lists.keymaps) { keymap in
        let searching = !lists.keymapSearch.isEmpty
        DisclosureGroup(isExpanded: Binding(
          get: { searching || lists.expandedKeymaps.contains(keymap.name) },
          set: { lists.setExpanded(keymap, $0) }))
        {
          ForEach(keymap.items ?? []) { item in
            Toggle(isOn: Binding(get: { item.active },
                                 set: { lists.setKeymapItem(item, in: keymap, active: $0) }))
            {
              HStack {
                Text(item.name).lineLimit(1)
                Spacer(minLength: 12)
                Text(item.keys).foregroundStyle(.secondary).lineLimit(1)
              }
            }
            .frame(minHeight: 44)
            .tint(Color(uiColor: .systemGreen))
          }
        } label: {
          Text(keymap.title).frame(minHeight: 44)
        }
        /* Titles in the text color, as the system's own lists have them. */
        .tint(.primary)
        .padding(.leading, CGFloat(keymap.depth) * 16)
        .padding(.horizontal, 16)
        if keymap.id != lists.keymaps.last?.id { Divider().padding(.leading, 16) }
      }
    }
    .background(PanelStyle.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
  }
}

/** The Keymap section: its panels, then the keymaps themselves. */
private struct KeymapPage: View {
  let store: InspectorStore
  @Bindable var lists: PreferencesLists

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 17) {
        InspectorForm(store: store, scrolls: false)
          .tint(PanelStyle.tint)
        KeymapList(lists: lists)
          .padding(.horizontal, 16)
          .padding(.bottom, 16)
      }
    }
    .searchable(text: $lists.keymapSearch, placement: .toolbar, prompt: "Search Keymap")
  }
}

/** A page's icon: a symbol on a colored square, as in the system's Settings. */
private struct SettingsIcon: View {
  let symbol: String
  let color: Color

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: 14, weight: .medium))
      .foregroundStyle(.white)
      .frame(width: 29, height: 29)
      .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
  }
}

/** Symbols and colors for the Preferences' sections, which Blender lists as text only. */
private let preferencesIcons: [String: (symbol: String, color: Color)] = [
  "INTERFACE": ("macwindow", .blue),
  "THEMES": ("paintpalette.fill", .purple),
  "VIEWPORT": ("cube.fill", .orange),
  "LIGHTS": ("lightbulb.fill", .yellow),
  "EDITING": ("pencil", .orange),
  "ANIMATION": ("film.fill", .pink),
  "EXTENSIONS": ("puzzlepiece.extension.fill", .green),
  "ADDONS": ("puzzlepiece.fill", .green),
  "INPUT": ("keyboard.fill", .gray),
  "NAVIGATION": ("move.3d", .teal),
  "KEYMAP": ("command", .gray),
  "SYSTEM": ("gearshape.fill", .gray),
  "SAVE_LOAD": ("square.and.arrow.down.fill", .blue),
  "FILE_PATHS": ("folder.fill", .cyan),
  "DEVELOPER_TOOLS": ("hammer.fill", .gray),
  "EXPERIMENTAL": ("flask.fill", .red),
]

private func preferencesIcon(_ tab: InspectorTab) -> SettingsIcon {
  let icon = preferencesIcons[String(tab.id.dropFirst("PREFERENCES_".count))] ?? ("gearshape.fill", .gray)
  return SettingsIcon(symbol: icon.symbol, color: icon.color)
}

struct SettingsView: View {
  @ObservedObject var model: SettingsModel
  let preferences: InspectorStore
  let lists: PreferencesLists
  @Environment(\.horizontalSizeClass) private var sizeClass
  /** The page shown: the iPad's, or a Preferences section's tab. */
  @State private var page: String? = SettingsView.iPadPage

  static let iPadPage = "IPAD"

  /** The sections as Blender groups them, between its separators. */
  private var groups: [[InspectorTab]] {
    var result: [[InspectorTab]] = []
    for tab in preferences.tabs {
      if let last = result.last?.last, last.group == tab.group { result[result.count - 1].append(tab) }
      else { result.append([tab]) }
    }
    return result
  }

  private var selection: Binding<String?> {
    Binding(get: { page }, set: { tab in
      page = tab
      if let tab, tab != Self.iPadPage { preferences.selectTab(tab) }
    })
  }

  var body: some View {
    NavigationSplitView {
      List(selection: selection) {
        Section {
          Label { Text("iPad") } icon: { SettingsIcon(symbol: "ipad.landscape", color: .blue) }
            .tag(Self.iPadPage)
        }
        if preferences.tabs.isEmpty {
          ProgressView().frame(maxWidth: .infinity)
        }
        ForEach(Array(groups.enumerated()), id: \.offset) { index, tabs in
          Section {
            ForEach(tabs) { tab in
              Label { Text(tab.title) } icon: { preferencesIcon(tab) }
                .tag(tab.id)
            }
          } header: {
            if index == 0 { Text("Blender Preferences") }
          }
        }
      }
      .navigationTitle("Settings")
      .toolbar {
        if sizeClass == .compact { doneButton }
      }
      .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    } detail: {
      NavigationStack {
        Group {
          if page == nil || page == Self.iPadPage {
            IPadSettingsPage(model: model)
              .navigationTitle("iPad")
          }
          else {
            Group {
              switch page {
                case "PREFERENCES_ADDONS": AddonsPage(lists: lists)
                case "PREFERENCES_KEYMAP": KeymapPage(store: preferences, lists: lists)
                default: InspectorForm(store: preferences).tint(PanelStyle.tint)
              }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(preferences.tabs.first { $0.id == page }?.title ?? "")
          }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          if sizeClass != .compact { doneButton }
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .onAppear {
      /* A narrow sheet starts on the list of pages. */
      if sizeClass == .compact { page = nil }
    }
  }

  private var doneButton: some ToolbarContent {
    ToolbarItem(placement: .confirmationAction) {
      Button("Done") { model.done?() }
    }
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Controller
 * \{ */

@MainActor
@objc(WMIOSSwiftSettings)
public final class SwiftSettings: NSObject, UIAdaptivePresentationControllerDelegate {
  private weak var presenter: UIViewController?
  private var sheet: UIViewController?
  private let model = SettingsModel()
  /** Blender's Preferences, which Blender fills along with the window's panels while Settings
   * shows, see `SwiftScenePanels.updateSnapshot`. */
  let preferences: InspectorStore
  let lists: PreferencesLists

  init(presenter: UIViewController, preferences: InspectorStore, lists: PreferencesLists) {
    self.presenter = presenter
    self.preferences = preferences
    self.lists = lists
    super.init()
    model.done = { [weak self] in self?.close() }
  }

  /** Whether one finger uses the active tool, as last chosen. */
  @objc public static var fingerUsesTool: Bool {
    UserDefaults.standard.bool(forKey: SettingsModel.fingerUsesToolKey)
  }

  @objc public var fingerUsesToolChanged: ((Bool) -> Void)? {
    get { model.fingerUsesToolChanged }
    set { model.fingerUsesToolChanged = newValue }
  }

  @objc public func present() {
    guard sheet == nil, let presenter, presenter.presentedViewController == nil else { return }
    let controller = UIHostingController(rootView: SettingsView(model: model, preferences: preferences, lists: lists))
    controller.modalPresentationStyle = .formSheet
    /* Wide enough for the pages beside their list, as in the system's Settings. */
    controller.preferredContentSize = CGSize(width: 860, height: 700)
    controller.presentationController?.delegate = self
    sheet = controller
    Engine.setting("native_preferences_visible", "1")
    preferences.requestProperties()
    presenter.present(controller, animated: true)
  }

  /** The `preferences` entry of the toolbar snapshot. */
  @objc(updatePreferences:)
  public func updatePreferences(_ preferences: Any?) {
    guard let preferences = preferences as? JSON, let keymap = preferences.string("keymap"),
          keymap != model.keymap else { return }
    model.keymap = keymap
  }

  public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    sheet = nil
    preferencesClosed()
  }

  private func close() {
    let sheet = self.sheet
    self.sheet = nil
    sheet?.dismiss(animated: true)
    preferencesClosed()
  }

  /** Blender stops reading the Preferences, and saves them if they changed. */
  private func preferencesClosed() {
    Engine.setting("native_preferences_visible", "0")
  }
}

/** \} */
