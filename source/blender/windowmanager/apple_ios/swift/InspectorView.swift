/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The Properties panel: Blender's Properties tabs along the top, then each panel as a section
 * that collapses from its header, with the panel's header switches beside its title.
 */

import SwiftUI
import UIKit

/** Whether a panel fills a window of its own, as Properties and the Outliner do on visionOS. */
extension EnvironmentValues {
  @Entry var panelInWindow = false
}

struct PanelHeader<Trailing: View>: View {
  @Environment(\.panelInWindow) private var inWindow
  let title: String
  let close: () -> Void
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(spacing: 0) {
      Text(title)
        .font(.headline)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 8)
      trailing
      /* A panel in a window of its own closes with the window. */
      if !inWindow {
        Button(action: close) {
          Image(systemName: "xmark")
            .font(.body.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close \(title)")
      .keyboardShortcut(.cancelAction)
      }
    }
    .padding(.leading, 16)
    .padding(.trailing, 5)
    .padding(.top, 5)
  }
}

struct InspectorPanel: View {
  let store: InspectorStore
  let close: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      PanelHeader(title: store.hasInspector ? store.title : "Properties", close: close) { EmptyView() }
      PropertiesTabs(store: store)
        .padding(.horizontal, 8)
        .frame(height: 44)
      if store.selectedTab == "TOOL", let tool = SwiftScenePanels.current?.toolPopoverStore {
        /* The active tool's settings in full, as the toolbar's popover has them, which Blender
         * sends for the tool as it changes. */
        InspectorForm(store: tool)
          .padding(.top, 4)
      }
      else {
        InspectorForm(store: store)
          .padding(.top, 4)
      }
    }
    .tint(PanelStyle.tint)
  }
}

struct PropertiesTabs: View {
  let store: InspectorStore
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
          ForEach(store.tabs) { tab in
            let selected = tab.id == store.selectedTab
            Button {
              store.selectTab(tab.id)
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
            .id(tab.id)
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier(tab.id)
            .help(tab.title)
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
        HStack(spacing: 0) {
          LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
            .frame(width: more.leading ? 28 : 0)
          Color.black
          LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
            .frame(width: more.trailing ? 28 : 0)
        }
      }
      .onChange(of: store.selectedTab) { _, tab in
        if let tab { withMotion { reader.scrollTo(tab, anchor: .center) } }
      }
    }
  }
}

struct InspectorForm: View {
  let store: InspectorStore
  /** False to measure the form's natural height. */
  var scrolls = true

  var body: some View {
    if scrolls {
      ScrollView { content }
        .dismissesKeyboardOnScroll(interactively: true)
        .overlay {
          if store.loaded && !store.hasInspector && store.mode == .properties {
            ContentUnavailableView("No Active Object", systemImage: "cube.transparent")
          }
          else if !store.loaded && (store.mode == .shading || store.mode == .preferences) {
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
      ForEach(store.sections) { section in
        if let style = store.textStyle, section.id == "DATA_PT_font" {
          /* A text object's font, styles and spacing together; Blender's Font panel stays below for the
           * rest, such as its bold and italic fonts and text on a curve. */
          VStack(alignment: .leading, spacing: 0) {
            Text("Text")
              .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
              .padding(.leading, 12)
            TextStyleSection(style: style)
          }
          SectionView(store: store, section: section.titled("More Font Options"))
            .equatable()
        }
        else if store.textStyle != nil && section.id == "DATA_PT_paragraph" {
          /* Its alignment and spacing are in the Text section. */
          EmptyView()
        }
        else {
          SectionView(store: store, section: section)
            .equatable()
        }
      }
      if !store.status.isEmpty {
        Text(store.status)
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

/** Equatable, so a snapshot that leaves the section as it was skips it entirely. */
struct SectionView: View, Equatable {
  let store: InspectorStore
  let section: InspectorSection
  /** Another of the stack's panels dragged over this one, which takes its place. */
  @State private var dropping = false

  static func == (a: SectionView, b: SectionView) -> Bool {
    a.store === b.store && a.section == b.section
  }

  var body: some View {
    let expanded = section.headerHidden || store.isExpanded(section.id)
    VStack(alignment: .leading, spacing: 0) {
      if !section.headerHidden {
        draggableHeader(expanded: expanded)
      }
      let rows = store.visibleRows(section)
      /* The card slides out from under its header: the container clips it as its height animates,
       * so it never passes over the header or the section above. */
      VStack(spacing: 0) {
        if expanded && !rows.isEmpty {
          Group {
            if bare(rows) {
              rowView(rows[0])
            }
            else {
              VStack(alignment: .leading, spacing: 0) {
                /* A modifier's or constraint's name and the rest of where it applies, open. */
                if let name = section.headerControls.first(where: { $0.bool("header_name") }) {
                  StackItemOptions(store: store, name: name,
                                   toggles: StackItemOptions.secondary(section.headerControls))
                    .padding(.vertical, 2)
                  Divider()
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { position, row in
                  if position > 0 { Divider() }
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
    .padding(.top, section.headerHidden ? 8 : 0)
    .overlay(alignment: .top) {
      if dropping {
        Capsule().fill(Color.accentColor).frame(height: 3).offset(y: -2)
      }
    }
    .onDrop(of: [.plainText], isTargeted: section.stackIndex == nil ? .constant(false) : $dropping) { providers in
      guard let target = section.stackIndex, let provider = providers.first else { return false }
      _ = provider.loadObject(ofClass: NSString.self) { payload, _ in
        guard let payload = payload as? String, payload.hasPrefix(Self.dragPrefix) else { return }
        let dragged = String(payload.dropFirst(Self.dragPrefix.count))
        DispatchQueue.main.async { store.moveSection(dragged, to: target) }
      }
      return true
    }
  }

  /** A dragged panel, as text naming it, which only the stack reads. */
  static let dragPrefix = "blender.panel\n"

  /** A stack's panel drags by its header to another place, as in Blender. */
  @ViewBuilder
  private func draggableHeader(expanded: Bool) -> some View {
    if section.stackIndex != nil {
      header(expanded: expanded)
        .onDrag { NSItemProvider(object: (Self.dragPrefix + section.id) as NSString) } preview: {
          Label(section.title, systemImage: "line.3.horizontal")
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
  private func bare(_ rows: [InspectorRow]) -> Bool {
    guard store.mode == .shading, rows.count == 1, case .property(let property) = rows[0].kind else {
      return false
    }
    return property.string("property") == "type" && property.string("type") == "ENUM"
  }

  private func header(expanded: Bool) -> some View {
    HStack(spacing: 8) {
      Button {
        guard !section.switchOnly else { return }
        store.toggleSection(section.id)
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .frame(width: 14, height: 14)
            .opacity(section.switchOnly ? 0 : 1)
          if let icon = BlenderIcon.image(section.icon) {
            Image(uiImage: icon).resizable().scaledToFit().frame(width: 18, height: 18)
          }
          Text(section.title)
            .lineLimit(1)
            .foregroundStyle(section.active ? PanelStyle.tint : .primary)
          Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(section.switchOnly)
      .accessibilityValue((expanded ? "Expanded" : "Collapsed") + (section.active ? ", Active" : ""))
      .accessibilityIdentifier("blender.section." + section.id)
      HeaderControls(store: store, controls: section.headerControls)
        .equatable()
    }
    .padding(.leading, 12)
    .padding(.trailing, 4)
  }

  @ViewBuilder
  private func rowView(_ row: InspectorRow) -> some View {
    switch row.kind {
      case .heading(let title, let subpanel, let disclosure, let reported, let depth, let controls):
        let open = store.subpanelOpen(subpanel, reported: reported)
        HStack(spacing: 8) {
          if disclosure {
            Button {
              store.toggleSubpanel(subpanel, currentlyOpen: open)
            } label: {
              HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                  .font(.system(size: 10, weight: .semibold))
                  .rotationEffect(.degrees(open ? 90 : 0))
                  .frame(width: 12)
                Text(title)
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
          }
          else {
            Text(title)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
          }
          HeaderControls(store: store, controls: controls)
            .equatable()
        }
        .padding(.leading, CGFloat(12 * depth))
      case .property(let property):
        PropertyRow(store: store, property: property)
          .equatable()
      case .vector(let title, let items):
        VectorRow(store: store, title: title, items: items)
          .equatable()
      case .toggles(let caption, let items):
        ToggleGroupRow(store: store, caption: caption, items: items)
          .equatable()
      case .composite(let property):
        CompositeRow(store: store, property: property)
          .equatable()
          .padding(.vertical, 4)
    }
  }
}

/** A modifier's or constraint's name, which a tap renames, and the switches for where else it
 * applies, such as Edit Mode, On Cage and Render, in the first row of its open panel. Its header
 * keeps the main one, as Blender's does. */
struct StackItemOptions: View {
  let store: InspectorStore
  let name: JSON
  let toggles: [JSON]
  @State private var rename: RenameRequest?

  /** The switch the header shows: the viewport's, or a constraint's only one. */
  static func primary(_ controls: [JSON]) -> JSON? {
    let cluster = controls.filter { $0.bool("header_cluster") }
    return cluster.first { $0.string("property") == "show_viewport" } ?? cluster.first
  }

  static func secondary(_ controls: [JSON]) -> [JSON] {
    let main = primary(controls)
    return controls.filter { $0.bool("header_cluster") && !jsonDictEqual($0, main ?? [:]) }
  }

  var body: some View {
    HStack(spacing: 8) {
      Button {
        rename = RenameRequest(title: "Rename", name: store.value(name) as? String ?? "") { text in
          store.edit(name, value: text)
        }
      } label: {
        HStack(spacing: 6) {
          Text(store.value(name) as? String ?? "")
            .lineLimit(1)
            .truncationMode(.middle)
          Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!name.bool("editable"))
      .accessibilityLabel("Name")
      .accessibilityValue(store.value(name) as? String ?? "")
      .accessibilityHint("Renames it.")
      ForEach(Array(toggles.enumerated()), id: \.offset) { _, toggle in
        switchButton(toggle)
      }
    }
    .renamePrompt($rename)
  }

  private func switchButton(_ toggle: JSON) -> some View {
    let on = store.value(toggle) as? Bool ?? (numericValue(store.value(toggle)) != 0)
    return Button {
      store.edit(toggle, value: !on)
      Haptics.selection()
    } label: {
      Group {
        if let icon = BlenderIcon.image(toggle.string("icon")) {
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
    .disabled(!toggle.bool("editable"))
    .propertyActions(store, toggle)
    .accessibilityLabel(propertyLabel(toggle))
    .accessibilityAddTraits(on ? .isSelected : [])
  }
}

/** A panel header's own switches and operators, such as a modifier's visibility and Remove. */
struct HeaderControls: View, Equatable {
  let store: InspectorStore
  let controls: [JSON]

  static func == (a: HeaderControls, b: HeaderControls) -> Bool {
    a.store === b.store && jsonListEqual(a.controls, b.controls)
  }

  var body: some View {
    /* A row of their own: through `equatable()` the header would not lay them out side by side. */
    HStack(spacing: 8) {
      /* A modifier or constraint keeps its main switch here; its name and other switches are in
       * its open panel. */
      let main = StackItemOptions.primary(controls)
      let shown = controls.filter {
        !$0.bool("header_name") && (!$0.bool("header_cluster") || jsonDictEqual($0, main ?? [:]))
      }
      ForEach(Array(shown.enumerated()), id: \.offset) { _, control in
        Group {
          switch control.string("type") {
            case "BOOLEAN":
              PropertyToggle(store: store, property: control)
            case "OPERATOR" where control.bool("checkbox"):
              OperatorToggle(store: store, property: control)
            case "OPERATOR":
              HeaderOperatorButton(store: store, property: control)
            default:
              EmptyView()
          }
        }
        .propertyActions(store, control)
        .fixedSize()
      }
    }
  }
}

/* -------------------------------------------------------------------- */
/** \name Tool settings strip
 *
 * The active tool's settings in the top bar: compact columns, a caption over each control. The
 * strip scrolls sideways when the bar is narrow, and a trailing button opens them all.
 * \{ */

struct ToolStrip: View {
  let store: InspectorStore
  /** Where a pop-out section's controls come from, laid out in full. */
  var popouts: InspectorStore?

  var body: some View {
    HStack(spacing: 6) {
      ForEach(store.sections) { section in
        if section.id.hasSuffix("_popout_settings") {
          /* A group of settings that would crowd the strip, such as Remesh: one control here,
           * its options popping out. */
          StripPopout(store: popouts ?? store, section: section)
        }
        else {
        ForEach(section.rows) { row in
          switch row.kind {
            case .property(let property):
              StripColumn(store: store, property: property)
                .equatable()
            case .toggles(let caption, let items):
              ToggleGroupRow(store: store, caption: caption, items: items, compact: true)
                .equatable()
            default:
              EmptyView()
          }
        }
        }
      }
    }
    .frame(height: 40)
    .tint(PanelStyle.tint)
    .accessibilityIdentifier("blender.tool-settings.strip")
    .modifier(PencilToolDialHold())
  }
}

/**
 * The tool's settings as the top bar's own items, each a system control: as many as there is room
 * for show in the bar, and the system puts the rest in its overflow menu, each as a menu item
 * there. Choices are pickers, switches toggles, Blender's menus menus; values to drag or type, a
 * color and groups of settings such as Remesh open in a popover.
 */
struct ToolSettingsItems: View {
  let store: InspectorStore
  /** Where a pop-out section's controls come from, laid out in full. */
  var popouts: InspectorStore?

  var body: some View {
    ForEach(store.sections) { section in
      if section.id.hasSuffix("_popout_settings") {
        ToolSettingPopover(title: section.title, icon: section.icon, systemImage: "slider.horizontal.3") {
          let full = (popouts ?? store).sections.first { $0.id == section.id } ?? section
          SectionView(store: popouts ?? store, section: InspectorSection(
            id: full.id, title: full.title, active: full.active, headerHidden: true, icon: full.icon,
            switchOnly: full.switchOnly, headerControls: full.headerControls, rows: full.rows))
        }
      }
      else {
        ForEach(section.rows) { row in
          switch row.kind {
            case .property(let property):
              ToolSettingItem(store: store, property: property)
            case .toggles(let caption, let items):
              /* A row of toggles, such as Mirror's axes: a menu of them, with its icon, that stays
               * open while they are set. */
              Menu {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                  Toggle(isOn: Binding(
                    get: { (store.value(item) as? NSNumber)?.boolValue ?? false },
                    set: { store.edit(item, value: $0) }))
                  {
                    Text(item.string("toolbar_label") ?? item.string("label") ?? "")
                  }
                }
              } label: {
                Label {
                  Text(caption)
                } icon: {
                  if caption == "Mirror" { IconView(name: "MOD_MIRROR") }
                }
              }
              .menuActionDismissBehavior(.disabled)
              /* Highlighted while any of them is on, as a toggle in the bar is. */
              .modifier(ProminentWhen(on: items.contains { (store.value($0) as? NSNumber)?.boolValue == true }))
            default:
              EmptyView()
          }
        }
      }
    }
  }
}

/** One of the tool's settings as a top bar item, see #ToolSettingsItems. */
struct ToolSettingItem: View {
  let store: InspectorStore
  let property: JSON

  private var type: String { property.string("type") ?? "" }
  private var title: String { property.string("toolbar_label") ?? propertyLabel(property) }

  var body: some View {
    switch type {
      /* A switch beside its name in the bar; a checkmark item in its overflow menu. */
      case "BOOLEAN" where property.string("icon").map { !$0.hasPrefix("CHECKBOX") && BlenderIcon.image($0) != nil } ?? false:
        /* With an icon of its own, as Onion Skin: a button lit while on, as the bar's toggles are. */
        Toggle(isOn: Binding(
          get: { (store.value(property) as? NSNumber)?.boolValue ?? false },
          set: { store.edit(property, value: $0) }))
        {
          Label { Text(title) } icon: { IconView(name: property.string("icon")) }
        }
        .toggleStyle(.button)
        .disabled(!property.bool("editable"))
      case "BOOLEAN":
        Toggle(isOn: Binding(
          get: { (store.value(property) as? NSNumber)?.boolValue ?? false },
          set: { store.edit(property, value: $0) }))
        {
          Text(title)
        }
        .toggleStyle(.switch)
        .fixedSize()
        .disabled(!property.bool("editable"))
      case "OPERATOR" where property.bool("checkbox"):
        Toggle(isOn: Binding(get: { property.bool("value") }, set: { _ in store.runOperator(property) })) {
          Text(title)
        }
        .toggleStyle(.switch)
        .fixedSize()
        .disabled(!property.bool("editable"))
      case "OPERATOR":
        Button { store.runOperator(property) } label: { label(systemImage: "play") }
          .disabled(!property.bool("editable"))
      case "MENU":
        if let menu = property.string("menu") {
          /* The 3D Viewport's menus, such as Sculpt Mode's Mask: run there, not in Properties. */
          let route = BlenderMenus.route(menu)
          Menu {
            BlenderMenuItems(route: route)
          } label: {
            label(systemImage: "ellipsis.circle")
          }
          .prefetchingBlenderMenu(route)
          .disabled(!property.bool("editable"))
        }
      case "ENUM" where property.bool("expand") && (2...4).contains(property.array("options").count):
        /* A few choices laid out side by side, as Grease Pencil's Material or Color Attribute: a
         * segmented switch. */
        Picker(title, selection: Binding(
          get: { store.value(property) as? String ?? "" },
          set: { store.edit(property, value: $0) }))
        {
          ForEach(Array(property.array("options").enumerated()), id: \.offset) { _, option in
            Text(option.string("label") ?? option.string("name") ?? "")
              .tag(option.string("value") ?? "")
          }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .disabled(!property.bool("editable"))
      case "ENUM":
        let options = property.array("options")
        Menu {
          Picker(title, selection: Binding(
            get: { store.value(property) as? String ?? "" },
            set: { store.edit(property, value: $0) }))
          {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
              Label {
                Text(option.string("label") ?? option.string("name") ?? "")
              } icon: {
                optionIcon(option)
              }
              .tag(option.string("value") ?? "")
            }
          }
        } label: {
          /* The choice made, as the bar has room to name it, with its preview where it has one,
           * as a material's. */
          let current = options.first { jsonEqual($0["value"], store.value(property)) }
          let name = current.flatMap { $0.string("label") ?? $0.string("name") } ?? title
          if let current, current.string("preview") != nil {
            /* A preview names its choice too, as a material's: it alone would not say which. */
            HStack(spacing: 6) {
              optionIcon(current)
              Text(name).lineLimit(1)
            }
          }
          else {
            Label {
              Text(name)
            } icon: {
              IconView(name: current?.string("icon") ?? property.string("icon"))
            }
          }
        }
        .disabled(!property.bool("editable"))
      case "INT", "FLOAT":
        /* A number typed in place, beside its name unless the layout gives none, as Dyntopo's
         * Detail, which the switch beside it names. */
        HStack(spacing: 6) {
          if !title.isEmpty { Text(title) }
          TextField(propertyLabel(property), value: Binding(
            get: { (store.value(property) as? NSNumber)?.doubleValue ?? 0 },
            set: { store.edit(property, value: type == "INT" ? NSNumber(value: Int($0.rounded())) : NSNumber(value: $0)) }),
            format: .number.precision(.fractionLength(0...(type == "INT" ? 0 : 3))))
            .keyboardType(type == "INT" ? .numberPad : .decimalPad)
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.roundedBorder)
            .frame(width: 64)
          if let suffix = property.string("unit_suffix"), !suffix.isEmpty {
            Text(suffix).foregroundStyle(.secondary)
          }
        }
        .fixedSize()
        .disabled(!property.bool("editable"))
      default:
        /* A color, or a value of another kind: named with its value, set in a popover. */
        ToolSettingPopover(title: valueTitle, icon: property.string("icon"),
                           systemImage: type == "COLOR" ? "paintpalette" : "slider.horizontal.below.rectangle")
        {
          PropertyRow(store: store, property: property)
        }
        .disabled(!property.bool("editable"))
    }
  }

  /** An option's picture: its preview, as a material's swatch, or else its icon. */
  @ViewBuilder
  private func optionIcon(_ option: JSON) -> some View {
    if let path = option.string("preview"), let image = UIImage(contentsOfFile: path) {
      Image(uiImage: image)
        .resizable()
        .scaledToFill()
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
    else {
      IconView(name: option.string("icon"))
    }
  }

  private var valueTitle: String {
    guard type == "INT" || type == "FLOAT", let value = store.value(property) as? NSNumber else { return title }
    let number = type == "INT" ? String(value.intValue) : String(format: "%.3g", value.doubleValue)
    return "\(title) \(number)\(property.string("unit_suffix") ?? "")"
  }

  /** Blender's icon where it has one, as the bar shows icons; otherwise the name, as a text item. */
  @ViewBuilder
  private func label(systemImage: String) -> some View {
    /* A checkbox is what Blender draws a toggle with, which the bar's toggle shows itself. */
    if let icon = property.string("icon"), !icon.hasPrefix("CHECKBOX"), BlenderIcon.image(icon) != nil {
      Label { Text(title) } icon: { IconView(name: icon) }
    }
    else {
      Text(title)
    }
  }
}

private struct ProminentWhen: ViewModifier {
  let on: Bool

  func body(content: Content) -> some View {
    if on { content.buttonStyle(.borderedProminent) } else { content }
  }
}

/** A top bar item that opens a popover with controls: the bar names it, its overflow menu too. */
struct ToolSettingPopover<Content: View>: View {
  let title: String
  let icon: String?
  let systemImage: String
  @ViewBuilder let content: () -> Content
  @State private var open = false

  var body: some View {
    Button {
      open = true
    } label: {
      if let icon, BlenderIcon.image(icon) != nil {
        Label { Text(title) } icon: { IconView(name: icon) }
      }
      else {
        Text(title)
      }
    }
    .popover(isPresented: $open) {
      ScrollView { content().padding() }
        .frame(idealWidth: 320, idealHeight: 380)
        .presentationCompactAdaptation(.popover)
        .tint(PanelStyle.tint)
    }
  }
}

/** A compact capsule naming what it opens, with a chevron: the strip's menus and pop-outs. */
struct StripCapsuleLabel: View {
  let title: String
  var icon: String?

  var body: some View {
    HStack(spacing: 4) {
      if let image = BlenderIcon.image(icon ?? "") {
        Image(uiImage: image).resizable().scaledToFit().frame(width: 18, height: 18)
      }
      Text(title).font(.caption).lineLimit(1).fixedSize()
      Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
    }
    .foregroundStyle(.primary)
    .padding(.horizontal, 10)
    .frame(height: 30)
    .panelGlass(in: Capsule())
    .contentShape(Capsule())
  }
}

/** One of the strip's sections as a single control, its settings in a popover. */
struct StripPopout: View {
  let store: InspectorStore
  let section: InspectorSection
  @State private var open = false

  var body: some View {
    Button {
      open = true
    } label: {
      StripCapsuleLabel(title: section.title, icon: section.icon)
    }
    .buttonStyle(.plain)
    .frame(height: 40)
    .popover(isPresented: $open) {
      /* The same panel from the full tool settings, which keep its values in step. */
      let full = store.sections.first { $0.id == section.id } ?? section
      ScrollView {
        SectionView(store: store, section: InspectorSection(
          id: full.id, title: full.title, active: full.active, headerHidden: true, icon: full.icon,
          switchOnly: full.switchOnly, headerControls: full.headerControls, rows: full.rows))
          .padding()
      }
      .frame(idealWidth: 320, idealHeight: 340)
      .presentationCompactAdaptation(.popover)
    }
    .accessibilityLabel(section.title)
  }
}

struct StripColumn: View, Equatable {
  let store: InspectorStore
  let property: JSON

  static func == (a: StripColumn, b: StripColumn) -> Bool {
    a.store === b.store && jsonDictEqual(a.property, b.property)
  }

  private var type: String { property.string("type") ?? "" }

  private var width: CGFloat {
    if type == "COLOR" { return 52 }
    if type == "BOOLEAN" || (type == "OPERATOR" && property.bool("checkbox")) { return 72 }
    if type == "ENUM" {
      /* A preview and its name. */
      if property.array("options").contains(where: { !($0.string("preview") ?? "").isEmpty }) { return 150 }
      let options = property.array("options").count
      if property.bool("expand") && (2...6).contains(options) && EnumControl.segmentsFit(property) {
        return CGFloat(options) * 42 + 8  /* A segmented control. */
      }
      return 108
    }
    if type == "OPERATOR" { return 96 }
    return 104
  }

  var body: some View {
    if type == "MENU", let menu = property.string("menu") {
      /* One of Blender's menus, such as Sculpt Mode's Mask and Face Sets: a compact capsule that
       * names itself, as the strip's pop-outs do. */
      Menu {
        BlenderMenuItems(route: BlenderMenus.route(menu, tab: property.string("tab")))
      } label: {
        StripCapsuleLabel(title: property.string("label") ?? "", icon: property.string("icon"))
      }
      .prefetchingBlenderMenu(BlenderMenus.route(menu, tab: property.string("tab")))
      .buttonStyle(.plain)
      .disabled(!property.bool("editable"))
      .frame(height: 40)
    }
    else {
      VStack(spacing: 0) {
        Text(property.string("toolbar_label") ?? property.string("label") ?? "")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        control
          .frame(height: 26)
      }
      .frame(width: width, height: 40)
      .propertyActions(store, property)
    }
  }

  @ViewBuilder
  private var control: some View {
    switch type {
      /* A switch, not the button the toolbar would make of a toggle. */
      case "BOOLEAN":
        PropertyToggle(store: store, property: property)
          .toggleStyle(.switch)
          .scaleEffect(0.7)
          .frame(width: 40, height: 24)
      case "OPERATOR" where property.bool("checkbox"):
        OperatorToggle(store: store, property: property)
          .toggleStyle(.switch)
          .scaleEffect(0.7)
          .frame(width: 40, height: 24)
      case "OPERATOR":
        OperatorButton(store: store, property: property, compact: true)
      case "MENU":
        BlenderMenuButton(property: property)
      case "ENUM":
        EnumControl(store: store, property: property, compact: true)
          .frame(width: width - 8)
      case "COLOR":
        ColorSwatch(store: store, property: property)
          .scaleEffect(0.8)
      case "INT", "FLOAT":
        if property.has("slider") {
          PropertySlider(store: store, property: property)
            .controlSize(.mini)
            .frame(width: width - 8)
        }
        else {
          NumberField(store: store, property: property, compact: true)
            .frame(width: width - 8)
        }
      default:
        EmptyView()
    }
  }
}

/** \} */

