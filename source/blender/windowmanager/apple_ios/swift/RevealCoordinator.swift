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
    /* A hint said once is not said again this session. */
    if entry["focus"] as? String == "once" {
      guard !said.contains(text) else { return }
      said.insert(text)
    }
    act(show, idname: idname, text: text, button: button, model: model)
  }

  private func act(_ show: String, idname: String, text: String, button: String, model: ShellModel) {
    let level = Self.level
    var done = "nothing"
    defer { WM_native_ui_log("reveal", "\(idname): \(show) -> \(done)") }
    if level == .off {
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
        guard level == .all else { return }
        open(editor: target)
        done = "editor " + target
      case "message":
        guard level == .all, !text.isEmpty else { return }
        let pieces = button.split(separator: "\t", maxSplits: 1).map(String.init)
        model.messages.say(text, button: pieces.first, target: pieces.count > 1 ? pieces[1] : nil)
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
    panels.setInspectorShown(true)
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
      case "image":
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
