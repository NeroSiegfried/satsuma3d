/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Siri and Shortcuts. Blender is generic underneath, commands (operators) and settings (RNA
 * properties), and so are its intents: one runs any command, two read and change any setting, one
 * describes the scene. People say what they want in their own words, "subdivide the cube twice",
 * "make this red", "how many objects are in my scene", and Siri finds the command or setting by
 * its name, description and synonyms, which Blender lists when asked. Blender reads options and
 * values in plain words against the command's or setting's own definition, and answers with a
 * sentence to speak, see `bl_ui.native_intents`.
 */

import AppIntents
import Foundation
import UIKit

/* -------------------------------------------------------------------- */
/** \name Blender
 * \{ */

enum IntentEngine {
  static let noDocument = "Open a document in \(AppIdentity.name) first."
  static let noAnswer = "\(AppIdentity.name) didn't answer. Try again in a moment."

  /** Ask Blender and wait for its answer without holding up the interface; nil when it has none
   * in time, as while a long render or file holds the engine up. */
  static func ask(_ intent: String, _ arguments: JSON = [:]) async -> JSON? {
    var request = arguments
    request["intent"] = intent
    guard let data = try? JSONSerialization.data(withJSONObject: request),
          let text = String(data: data, encoding: .utf8)
    else { return nil }
    return await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        let once = Once(continuation)
        wm_apple_ios_intent_perform(text) { answer in
          let json = answer?.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? JSON
          }
          once.resume(json)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { once.resume(nil) }
      }
    }
  }

  /** The answer's sentence, to show and speak. */
  static func sentence(_ answer: JSON?) -> String {
    answer?.string("sentence") ?? noAnswer
  }

  /** Blender has a document open, and has finished loading it. */
  @MainActor static var documentOpen: Bool {
    guard let document = wm_apple_ios_open_document() else { return false }
    return !document.documentState.contains(.closed)
  }

  /** Whether the document is open, waiting for one the app is still opening: when Siri starts
   * the app, it continues in the document that was open when it was left. */
  @MainActor static func waitForDocument() async -> Bool {
    if documentOpen { return true }
    let reopening = wm_apple_ios_open_document() != nil ||
      UserDefaults.standard.data(forKey: "BlenderOpenDocument") != nil
    guard reopening else { return false }
    for _ in 0..<120 {
      try? await Task.sleep(for: .milliseconds(250))
      if documentOpen { return true }
    }
    return false
  }
}

/** Resumes a continuation once, with Blender's answer or after waiting too long, whichever comes
 * first. Both arrive on the main queue. */
private final class Once {
  private var continuation: CheckedContinuation<JSON?, Never>?

  init(_ continuation: CheckedContinuation<JSON?, Never>) {
    self.continuation = continuation
  }

  func resume(_ value: JSON?) {
    continuation?.resume(returning: value)
    continuation = nil
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Commands
 * \{ */

/** One of Blender's commands that can run in the open document, such as Subdivide, Shade Smooth
 * or Add Cube. */
struct CommandEntity: AppEntity {
  static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Action", synonyms: ["Command", "Operation", "Tool"])
  static let defaultQuery = CommandQuery()

  var id: String
  var title: String
  var subtitle: String
  var synonyms: [String]
  /** Throws work away, such as Delete, so it asks first. */
  var destructive: Bool

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)",
                          synonyms: synonyms.map { "\($0)" })
  }

  init?(_ json: JSON) {
    guard let id = json.string("id"), let title = json.string("title") else { return nil }
    self.id = id
    self.title = title
    subtitle = json.string("subtitle") ?? ""
    synonyms = json.strings("synonyms")
    destructive = json.bool("destructive")
  }
}

/** Commands as Blender lists them when asked: those that can run now matching what was said, or
 * the common ones. */
struct CommandQuery: EntityStringQuery {
  func entities(for identifiers: [String]) async throws -> [CommandEntity] {
    await commands(["ids": identifiers])
  }

  func entities(matching string: String) async throws -> [CommandEntity] {
    await commands(["query": string, "document": await IntentEngine.documentOpen])
  }

  func suggestedEntities() async throws -> [CommandEntity] {
    await commands(["query": ""])
  }

  private func commands(_ arguments: JSON) async -> [CommandEntity] {
    let answer = await IntentEngine.ask("commands", arguments)
    return answer?.array("commands").compactMap(CommandEntity.init) ?? []
  }
}

/** Run any of Blender's commands on the open document, with options in plain words. */
struct RunCommandIntent: AppIntent {
  static let title: LocalizedStringResource = "Run Action"
  static let description = IntentDescription(
    "Runs any action, such as Subdivide or Shade Smooth, with optional settings in plain words, such as \"levels 2\" or \"size 3 m\".",
    categoryName: "Editing",
    searchKeywords: ["command", "operator", "action", "model", "edit"])
  /** Changes to the document happen where they can be seen, and undone. */
  static var supportedModes: IntentModes { .foreground(.immediate) }

  @Parameter(title: "Action",
             description: "The action to run, such as Subdivide, Shade Smooth or Add Cube.",
             requestValueDialog: "Which action should run?")
  var command: CommandEntity

  @Parameter(title: "Options",
             description: "Settings for the action in plain words, such as \"levels 2\", \"4 cuts\" or \"size 3 m\".")
  var options: String?

  static var parameterSummary: some ParameterSummary {
    Summary("Do \(\.$command)") {
      \.$options
    }
  }

  init() {}

  init(command: CommandEntity, options: String? = nil) {
    self.command = command
    self.options = options
  }

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    guard await IntentEngine.waitForDocument() else {
      return .result(value: IntentEngine.noDocument, dialog: "\(IntentEngine.noDocument)")
    }
    var request: JSON = ["command": command.id, "options": options ?? ""]
    var answer = await IntentEngine.ask("run", request)
    if let question = answer?.string("confirm") {
      try await requestConfirmation(
        actionName: .custom(acceptLabel: "\(command.title)", acceptAlternatives: [],
                            denyLabel: "Cancel", denyAlternatives: [], destructive: true),
        dialog: "\(question)")
      request["confirmed"] = true
      answer = await IntentEngine.ask("run", request)
    }
    let sentence = IntentEngine.sentence(answer)
    return .result(value: sentence, dialog: "\(sentence)")
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Settings
 * \{ */

/** A setting in the open document: of the active object, its material, the scene, the render
 * settings, the tool settings or the brush, such as "Cube › Base Color". */
struct SettingEntity: AppEntity {
  static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Setting", synonyms: ["Property", "Value", "Option"])
  static let defaultQuery = SettingQuery()

  var id: String
  var title: String
  var subtitle: String
  var synonyms: [String]

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)",
                          synonyms: synonyms.map { "\($0)" })
  }

  init?(_ json: JSON) {
    guard let id = json.string("id"), let title = json.string("title") else { return nil }
    self.id = id
    self.title = title
    subtitle = json.string("subtitle") ?? ""
    synonyms = json.strings("synonyms")
  }
}

/** Settings as Blender lists them for the open document, matching what was said. */
struct SettingQuery: EntityStringQuery {
  func entities(for identifiers: [String]) async throws -> [SettingEntity] {
    await settings(["ids": identifiers])
  }

  func entities(matching string: String) async throws -> [SettingEntity] {
    await settings(["query": string])
  }

  func suggestedEntities() async throws -> [SettingEntity] {
    await settings(["query": ""])
  }

  private func settings(_ arguments: JSON) async -> [SettingEntity] {
    guard await IntentEngine.documentOpen else { return [] }
    let answer = await IntentEngine.ask("settings", arguments)
    return answer?.array("settings").compactMap(SettingEntity.init) ?? []
  }
}

/** Tell the value of any setting in the open document. */
struct GetSettingIntent: AppIntent {
  static let title: LocalizedStringResource = "Get Setting"
  static let description = IntentDescription(
    "Tells the value of any setting in the open document, such as an object's location, its material's base color or the scene's end frame.",
    categoryName: "Settings",
    searchKeywords: ["property", "value", "read", "check"])
  static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

  @Parameter(title: "Setting", requestValueDialog: "Which setting?")
  var setting: SettingEntity

  static var parameterSummary: some ParameterSummary {
    Summary("Get \(\.$setting)")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    guard await IntentEngine.waitForDocument() else {
      return .result(value: IntentEngine.noDocument, dialog: "\(IntentEngine.noDocument)")
    }
    let answer = await IntentEngine.ask("get", ["setting": setting.id])
    let sentence = IntentEngine.sentence(answer)
    return .result(value: answer?.string("value") ?? sentence, dialog: "\(sentence)")
  }
}

/** Change any setting in the open document to a value in plain words. */
struct SetSettingIntent: AppIntent {
  static let title: LocalizedStringResource = "Change Setting"
  static let description = IntentDescription(
    "Changes any setting in the open document, such as a material's color, an object's size or the end frame, to a value in plain words: \"red\", \"2 m\", \"45 degrees\", \"on\".",
    categoryName: "Settings",
    searchKeywords: ["property", "value", "set", "make", "color"])
  static var supportedModes: IntentModes { .foreground(.immediate) }

  @Parameter(title: "Setting", requestValueDialog: "Which setting?")
  var setting: SettingEntity

  @Parameter(title: "Value",
             description: "The new value in plain words, such as \"red\", \"2 m\", \"x 1 z 3\" or \"on\".",
             requestValueDialog: "What should it be?")
  var value: String

  static var parameterSummary: some ParameterSummary {
    Summary("Set \(\.$setting) to \(\.$value)")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    guard await IntentEngine.waitForDocument() else {
      return .result(value: IntentEngine.noDocument, dialog: "\(IntentEngine.noDocument)")
    }
    let answer = await IntentEngine.ask("set", ["setting": setting.id, "value": value])
    let sentence = IntentEngine.sentence(answer)
    return .result(value: sentence, dialog: "\(sentence)")
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Scene
 * \{ */

/** The open document's scene as facts Siri can reason over and answer questions from. */
struct DescribeSceneIntent: AppIntent {
  static let title: LocalizedStringResource = "Describe Scene"
  static let description = IntentDescription(
    "Tells what is in the open document's scene: how many objects of each type and their names, what is selected, the active object and its size, the mode and the frame.",
    categoryName: "Scene",
    searchKeywords: ["objects", "count", "selection", "what", "summary"])
  static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    guard await IntentEngine.waitForDocument() else {
      return .result(value: IntentEngine.noDocument, dialog: "\(IntentEngine.noDocument)")
    }
    let sentence = IntentEngine.sentence(await IntentEngine.ask("describe"))
    return .result(value: sentence, dialog: "\(sentence)")
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Phrases
 * \{ */

/** What people can say to Siri without setting anything up. The command phrases name Blender's
 * common commands ("Shade Smooth in Blender"), refreshed once Blender can list them. Settings
 * belong to a document's objects, so their phrases name none. */
struct BlenderShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: RunCommandIntent(),
      phrases: [
        "\(\.$command) in \(.applicationName)",
        "Use \(.applicationName) to \(\.$command)",
        "Do something in \(.applicationName)",
        "Run a command in \(.applicationName)",
      ],
      shortTitle: "Run Action",
      systemImageName: "wand.and.stars")
    AppShortcut(
      intent: DescribeSceneIntent(),
      phrases: [
        "What's in my \(.applicationName) scene",
        "Describe my \(.applicationName) scene",
        "How many objects are in my \(.applicationName) scene",
        "What is selected in \(.applicationName)",
      ],
      shortTitle: "Describe Scene",
      systemImageName: "cube")
    AppShortcut(
      intent: SetSettingIntent(),
      phrases: [
        "Change a setting in \(.applicationName)",
        "Set something in \(.applicationName)",
      ],
      shortTitle: "Change Setting",
      systemImageName: "slider.horizontal.3")
    AppShortcut(
      intent: GetSettingIntent(),
      phrases: [
        "Check a setting in \(.applicationName)",
        "Get a setting from \(.applicationName)",
      ],
      shortTitle: "Get Setting",
      systemImageName: "eye")
  }
}

/** \} */
