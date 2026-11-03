/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Edits of the controls Blender describes as JSON, which the node editor's nodes still are (see
 * `interface_native_properties.cc`), sent through the engine inbox. Panels elsewhere are views,
 * see `NativePanels.swift`.
 *
 * Edits carry a sequence number. Snapshots acknowledging an older sequence are ignored, so a
 * control never jumps back to a stale value while Blender is still applying an edit.
 */

import SwiftUI
import UIKit

func propertyKey(_ property: JSON) -> String {
  if let key = property.string("key") { return key }
  let index = property["index"].map { "\($0)" } ?? ""
  return "\(property["owner"] ?? "").\(property["property"] ?? "").\(index)"
}

func propertyLabel(_ property: JSON) -> String {
  let label = property.string("label") ?? ""
  if let group = property.string("group"), !group.isEmpty { return "\(group) \(label)" }
  return label
}

/** Snapshots arrive as new dictionaries even when nothing changed; compare their contents. */
func jsonListEqual(_ a: [JSON], _ b: [JSON]) -> Bool {
  a.count == b.count && zip(a, b).allSatisfy { ($0 as NSDictionary).isEqual($1 as NSDictionary) }
}

func jsonDictEqual(_ a: JSON, _ b: JSON) -> Bool {
  (a as NSDictionary).isEqual(b as NSDictionary)
}

/** A row of a section. Rows are identified by meaning, so updates animate only what changed. */
/** A row of a section. Rows are identified by meaning, so updates animate only what changed. */
struct InspectorRow: Identifiable, Equatable {
  enum Kind: Equatable {
    /** A sub-panel's heading: a disclosure when it can collapse, with its header controls. */
    case heading(title: String, subpanel: String, disclosure: Bool, open: Bool, depth: Int,
                 controls: [JSON])
    case property(JSON)
    /** A vector such as Location: one caption over its components. */
    case vector(title: String, items: [JSON])
    /** Toggles shown together, such as Mirror X Y Z. */
    case toggles(caption: String, items: [JSON])
    /** Data-block pickers, lists, previews and operator menus. */
    case composite(JSON)

    static func == (a: Kind, b: Kind) -> Bool {
      switch (a, b) {
        case let (.heading(title, subpanel, disclosure, open, depth, controls),
                  .heading(title2, subpanel2, disclosure2, open2, depth2, controls2)):
          return title == title2 && subpanel == subpanel2 && disclosure == disclosure2 && open == open2 &&
            depth == depth2 && jsonListEqual(controls, controls2)
        case let (.property(property), .property(property2)):
          return jsonDictEqual(property, property2)
        case let (.vector(title, items), .vector(title2, items2)):
          return title == title2 && jsonListEqual(items, items2)
        case let (.toggles(caption, items), .toggles(caption2, items2)):
          return caption == caption2 && jsonListEqual(items, items2)
        case let (.composite(property), .composite(property2)):
          return jsonDictEqual(property, property2)
        default:
          return false
      }
    }
  }

  let id: String
  var kind: Kind
}

/** A value the user just set, observed per property so an edit redraws only its own control. */
@MainActor
@Observable
final class PendingValue {
  var value: Any?
}

/** Edits of JSON controls, and their values until Blender shows them. */
@MainActor
@Observable
final class InspectorStore {
  private(set) var status = ""
  /** Values the user just set, shown until Blender acknowledges them. Kept once made, so the
   * controls reading them keep observing the same value. */
  @ObservationIgnored private var pendingValues: [String: PendingValue] = [:]
  /** Bumped when controls must drop local editing state, e.g. on selection change. */
  private(set) var generation = 0

  /** Sent with every edit: for nodes, which tree the edit is in. */
  @ObservationIgnored var requestContext: JSON = [:]
  @ObservationIgnored private(set) var sequence: UInt64 = 0
  private static var nextSequence: UInt64 = 0
  /** Where edits go: the node editor's canvas. */
  private let sender: (JSON) -> Void

  init(send: @escaping (JSON) -> Void) {
    sender = send
  }

  private func pendingValue(_ key: String) -> PendingValue {
    if let existing = pendingValues[key] { return existing }
    let created = PendingValue()
    pendingValues[key] = created
    return created
  }

  private func setPending(_ property: JSON, _ value: Any) {
    let pending = pendingValue(propertyKey(property))
    if !jsonEqual(pending.value, value) { pending.value = value }
  }

  func send(_ request: JSON) {
    InspectorStore.nextSequence += 1
    sequence = InspectorStore.nextSequence
    var payload = request
    payload.merge(requestContext) { $1 }
    payload["sequence"] = NSNumber(value: sequence)
    sender(payload)
  }

  func edit(_ property: JSON, value: Any) {
    var request = property
    request["action"] = "property"
    request["id"] = ""
    request["value"] = value
    setPending(property, value)
    send(request)
  }

  /** Continuous edits (sliders, scrubbing, color) share one interaction and one undo step. */
  func preview(_ property: JSON, value: Any, interaction: String, phase: String) {
    var request = property
    request["action"] = "property"
    request["id"] = ""
    request["value"] = value
    request["interaction"] = interaction
    request["phase"] = phase
    setPending(property, value)
    send(request)
  }

  /** Requests for pickers, lists, menus and operators, keyed by the button in its panel. */
  func request(_ property: JSON, extra: JSON) {
    var request: JSON = [
      "action": "property", "id": "", "native": 1,
      "key": property.string("key") ?? "", "panel": property.string("panel") ?? "",
      "tab": property.string("tab") ?? "",
    ]
    /* A node's picker names its node. */
    if let node = property.string("node") { request["node"] = node }
    if property.bool("header") { request["header"] = 1 }
    request.merge(extra) { $1 }
    send(request)
  }

  func runOperator(_ property: JSON) {
    var request = property
    request["id"] = ""
    send(request)
  }

  func animate(_ property: JSON, action: String) {
    var request = property
    request["action"] = "animation"
    request["animation_action"] = action
    request["id"] = ""
    send(request)
  }

  func showStatus(_ message: String) {
    guard message != status else { return }
    withMotion { status = message }
  }

  func value(_ property: JSON) -> Any? {
    pendingValue(propertyKey(property)).value ?? property["value"]
  }

  /** A new snapshot: what was set is shown by it now. */
  func clearPendingValues(ack: UInt64) {
    guard ack >= sequence else { return }
    for pending in pendingValues.values where pending.value != nil { pending.value = nil }
  }

  /** The selected items' values differ, until an edit gives them all one. */
  func isMixed(_ property: JSON) -> Bool {
    property.bool("mixed") && pendingValue(propertyKey(property)).value == nil
  }
}
