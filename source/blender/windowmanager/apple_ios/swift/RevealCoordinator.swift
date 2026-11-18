/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The one place that opens something because of what Blender did. After each command,
 * `bl_ui.native_reveal` names where its result lives and the bridge sends it as the toolbar's
 * `reveal`: the operation's settings, a Properties tab, an editor, a message, or nothing. This
 * acts on it, as the person set it to in Settings. It never closes what the person opened, never
 * changes the Properties tab while a field is being typed into, and in a narrow window offers a
 * message with a Show button instead of covering the viewport with Properties.
 */

import SwiftUI

@MainActor
@Observable
final class RevealCoordinator {
  static let shared = RevealCoordinator()

  /** Settings › Show Settings Automatically. */
  enum Level: String, CaseIterable {
    case all, operation, off

    var title: String {
      switch self {
        case .all: "All"
        case .operation: "Operation Only"
        case .off: "Off"
      }
    }
  }

  nonisolated static let levelKey = "BlenderShowSettingsAutomatically"

  nonisolated static var level: Level {
    if let raw = UserDefaults.standard.string(forKey: levelKey), let level = Level(rawValue: raw) { return level }
    /* Round 4's switch, `SettingsModel.redoOpensKey`, carried over. */
    if UserDefaults.standard.object(forKey: "BlenderRedoOpensItself") as? Bool == false { return .off }
    return .all
  }

  /** The operator whose settings should open, and a count that moves with each request, which the
   * operation strip follows. */
  private(set) var operationOperator = ""
  private(set) var operationRequests = 0

  /** The last reveal acted on: each once; what was decided before the window opened is not. */
  @ObservationIgnored private var last: Int?
  @ObservationIgnored private var said = Set<String>()

  /** Whether the operation strip should open for \a idname, as just decided. */
  func opensOperation(_ idname: String?) -> Bool {
    guard let idname, !idname.isEmpty, Self.level != .off else { return false }
    return idname == operationOperator
  }

  func take(_ json: String, model: ShellModel) {
    guard let data = json.data(using: .utf8),
          let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let number = entry["number"] as? Int else { return }
    guard let seen = last else {
      last = number
      return
    }
    guard number > seen else { return }
    last = number
    let idname = entry["operator"] as? String ?? ""
    let show = entry["show"] as? String ?? "none"
    let text = entry["text"] as? String ?? ""
    let button = entry["button"] as? String ?? ""
    let level = entry["level"] as? String ?? ""
    /* A hint said once is not said again this session. */
    if entry["focus"] as? String == "once" {
      guard !said.contains(text) else { return }
      said.insert(text)
    }
    act(show, idname: idname, text: text, button: button, level: level, model: model)
  }

  private func act(_ show: String, idname: String, text: String, button: String, level messageLevel: String = "",
                   model: ShellModel) {
    let level = Self.level
    var done = "nothing"
    defer { WM_native_ui_log("reveal", "\(idname): \(show) -> \(done)") }
    if level == .off && messageLevel != "warning" {
      done = "off in Settings"
      return
    }
    let parts = show.split(separator: ":", maxSplits: 1).map(String.init)
    let kind = parts[0]
    let target = parts.count > 1 ? parts[1] : ""
    switch kind {
      case "operation":
        requestOperation(idname)
        done = "operation"
      case "properties", "properties_if_open":
        requestOperation(idname)
        done = "operation"
        guard level == .all, let panels = SwiftScenePanels.current else { return }
        if kind == "properties_if_open" && !panels.inspectorShown { return }
        if KeyboardLift.shared.overlap > 0 {
          done += ", tab kept while typing"
          return
        }
        if model.compact && !panels.inspectorShown {
          model.messages.say(propertiesMessage(target), button: "Show", target: "show:properties:" + target)
          done = "message offering " + target
          return
        }
        open(properties: target)
        done = "properties " + target
      case "editor":
        /* The operation's settings too, as for Properties: Unwrap's Method and Margin stand in the
         * strip while the layout shows above (ROUND5 9B.4). */
        requestOperation(idname)
        done = "operation"
        guard level == .all, let panels = SwiftScenePanels.current else { return }
        if target == "uv" && model.compact && !panels.image.shown {
          /* A narrow window keeps the viewport, as for Properties: the UV Editor on request. */
          model.messages.say("The UVs are in the UV Editor", button: "Show", target: "editor:uv")
          done = "message offering the UV Editor"
          return
        }
        open(editor: target)
        done = "editor " + target
      case "message":
        /* A warning says a command did nothing, which no setting silences. */
        guard level == .all || messageLevel == "warning", !text.isEmpty else { return }
        let pieces = button.split(separator: "\t", maxSplits: 1).map(String.init)
        model.messages.say(text, level: messageLevel.isEmpty ? "info" : messageLevel, button: pieces.first,
                           target: pieces.count > 1 ? pieces[1] : nil)
        done = "message"
      default:
        done = "nothing"
    }
  }

  private func requestOperation(_ idname: String) {
    operationOperator = idname
    operationRequests += 1
  }

  private func propertiesMessage(_ tab: String) -> String {
    let names = ["MODIFIER": "Modifiers", "PHYSICS": "Physics", "CONSTRAINT": "Constraints",
                 "BONE_CONSTRAINT": "Bone Constraints", "MATERIAL": "Material", "DATA": "Data",
                 "PARTICLES": "Particles", "WORLD": "World", "TEXTURE": "Texture", "SHADERFX": "Effects",
                 "SCENE": "Scene"]
    return "Its settings are in Properties › \(names[tab] ?? tab.capitalized)"
  }

  /** Properties on \a tab, opened if closed. */
  func open(properties tab: String) {
    guard let panels = SwiftScenePanels.current else { return }
    panels.setInspectorShown(true, by: "reveal")
    if !tab.isEmpty { panels.properties.selectTab(tab) }
  }

  func open(editor name: String) {
    guard let panels = SwiftScenePanels.current else { return }
    switch name {
      case "geometry_nodes":
        panels.nodes.setKind(.geometry)
        panels.nodes.setShown(true)
      case "shader":
        panels.nodes.setKind(.shader)
        panels.nodes.setShown(true)
      case "uv":
        /* As the UV Editor, unless the panel already shows: never switched away from what the
         * person opened, an image among them (decision 54). */
        if !panels.image.shown { panels.image.show(.uv, true) }
      case "image":
        if !panels.image.shown { panels.image.mode = .image }
        panels.image.setShown(true)
      case "timeline":
        ShellPanels.current?.timeline.setVisible(true)
      default:
        break
    }
  }

  /** A message's button: `show:properties:<TAB>` or `editor:<name>`. */
  func perform(_ target: String) -> Bool {
    if target.hasPrefix("show:properties:") {
      open(properties: String(target.dropFirst("show:properties:".count)))
      return true
    }
    if target.hasPrefix("editor:") {
      open(editor: String(target.dropFirst("editor:".count)))
      return true
    }
    return false
  }
}

/* -------------------------------------------------------------------- */
/** \name What the viewport's shading hides
 *
 * Where the 3D view's shading does not show what a Properties tab edits, the tab says so in one
 * line with a button that switches the shading (ROUND5 7D.4, decision 30): Solid view draws a
 * material's Viewport Display colour, never its Base Color, and no world at all. Desktop Blender
 * says nothing here; this is an addition. A third case is one more entry in #table.
 * \{ */

enum ShadingHint {
  struct Entry: Equatable {
    /** The shadings, as `ShellModel.shading` names them, that hide what the tab edits. */
    let hiddenIn: Set<String>
    let text: String
    /** The button's title, and the shading it switches to, as Blender's shading type names it. */
    let button: String
    let shading: String
    /** The data-block the line is about, by the icon of its type in Blender's context path: no
     * line while there is none, such as a material slot left empty (ROUND5 7E/E6). */
    let needs: Set<String>
  }

  /** By Properties tab. */
  static let table: [String: Entry] = [
    "MATERIAL": Entry(hiddenIn: ["solid", "wireframe"], text: "Solid view shows Viewport Display colours, not this material.",
                      button: "Material Preview", shading: "MATERIAL", needs: ["MATERIAL_DATA", "MATERIAL"]),
    "WORLD": Entry(hiddenIn: ["solid", "wireframe"], text: "Solid view does not show the world.", button: "Rendered",
                   shading: "RENDERED", needs: ["WORLD_DATA", "WORLD"]),
  ]

  /** What to say on \a tab while the viewport shows \a shading, if anything: only while the
   * context path (\a path, its elements' icons, as `MATERIAL_DATA`, the type's RNA icon) holds what the line is about. */
  static func entry(tab: String, shading: String, path: [String]) -> Entry? {
    guard let entry = table[tab], entry.hiddenIn.contains(shading), !entry.needs.isDisjoint(with: path) else { return nil }
    return entry
  }

  /** Switch the 3D view's shading, as Blender's shading buttons and its Z pie do. */
  @MainActor
  static func apply(_ entry: Entry) {
    Operators.run("VIEW3D_OT_toggle_shading", ["type": .text(entry.shading)])
  }
}

/** \} */
