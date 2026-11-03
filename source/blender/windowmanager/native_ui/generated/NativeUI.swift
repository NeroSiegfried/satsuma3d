// SPDX-FileCopyrightText: 2026 Blender Authors
//
// SPDX-License-Identifier: GPL-2.0-or-later

// Generated from native_ui.fbs by native_ui_schema.py: edit the schema, then run
// `python3 source/blender/windowmanager/native_ui/native_ui_schema.py generate`.

import Foundation

/// Blender writes some flags as 0 and 1, others as false and true.
private func flag(_ value: Any?) -> Bool? {
  (value as? NSNumber)?.boolValue
}

enum NativeUI {
  /// A part of a snapshot the schema leaves open, as `JSONSerialization` read it: any JSON, for parts
  /// still to be described. Nil for JSON's null.
  struct Open: Equatable, @unchecked Sendable {
    let value: Any?

    init(_ value: Any?) {
      self.value = value is NSNull ? nil : value
    }

    var dictionary: [String: Any]? { value as? [String: Any] }

    static func == (a: Open, b: Open) -> Bool {
      switch (a.value, b.value) {
        case (nil, nil): return true
        case let (x as NSObject, y as NSObject): return x.isEqual(y)
        default: return false
      }
    }
  }

  /// What the interface around the viewport shows that is not in the `toolbar` view yet. Sent with
  /// every change, see `WM_native_ui_toolbar_take_json`.
  struct Toolbar: Equatable, @unchecked Sendable {
    /// Blender's context mode, such as `objectmode` or `edit_mesh`.
    var mode: String
    /// A render in progress, or its result.
    var render: Open
    var preferences: Open

    /// From the snapshot as `JSONSerialization` reads it. Nil without its required fields.
    init?(json: [String: Any]) {
      guard let mode = json["mode"] as? String else {
        return nil
      }
      self.mode = mode
      render = Open(json["render"])
      preferences = Open(json["preferences"])
    }
  }
}
