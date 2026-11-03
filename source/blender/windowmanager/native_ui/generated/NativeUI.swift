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

  /// The 3D viewport's shading.
  enum Shading: String, Equatable, Sendable {
    case wireframe = "wireframe"
    case solid = "solid"
    case material = "material"
    case rendered = "rendered"
    /// A value from a newer Blender than this interface knows.
    case unknown
  }

  /// An object's mode, as `Object.mode` names it.
  enum ObjectMode: String, Equatable, Sendable {
    case object = "OBJECT"
    case edit = "EDIT"
    case pose = "POSE"
    case sculpt = "SCULPT"
    case vertexPaint = "VERTEX_PAINT"
    case weightPaint = "WEIGHT_PAINT"
    case texturePaint = "TEXTURE_PAINT"
    case particleEdit = "PARTICLE_EDIT"
    case editGpencil = "EDIT_GPENCIL"
    case sculptCurves = "SCULPT_CURVES"
    case paintGreasePencil = "PAINT_GREASE_PENCIL"
    case sculptGreasePencil = "SCULPT_GREASE_PENCIL"
    case weightGreasePencil = "WEIGHT_GREASE_PENCIL"
    case vertexGreasePencil = "VERTEX_GREASE_PENCIL"
    /// A value from a newer Blender than this interface knows.
    case unknown
  }

  /// What edit mode selects on a mesh.
  enum MeshSelectMode: String, Equatable, Sendable {
    case vert = "VERT"
    case edge = "EDGE"
    case face = "FACE"
    /// A value from a newer Blender than this interface knows.
    case unknown
  }

  enum Orientation: String, Equatable, Sendable {
    case global = "global"
    case local = "local"
    case normal = "normal"
    case gimbal = "gimbal"
    case view = "view"
    case cursor = "cursor"
    case parent = "parent"
    case custom = "custom"
    /// A value from a newer Blender than this interface knows.
    case unknown
  }

  enum Pivot: String, Equatable, Sendable {
    case bounds = "bounds"
    case cursor = "cursor"
    case individual = "individual"
    case median = "median"
    case active = "active"
    /// A value from a newer Blender than this interface knows.
    case unknown
  }

  enum Snap: String, Equatable, Sendable {
    case off = "off"
    case increment = "increment"
    case grid = "grid"
    case vertex = "vertex"
    case edge = "edge"
    case face = "face"
    case volume = "volume"
    /// Several elements snapped to at once.
    case mixed = "mixed"
    /// A value from a newer Blender than this interface knows.
    case unknown
  }

  enum Proportional: String, Equatable, Sendable {
    case off = "off"
    case on = "on"
    case connected = "connected"
    case projected = "projected"
    /// A value from a newer Blender than this interface knows.
    case unknown
  }

  enum Toggle: String, Equatable, Sendable {
    case off = "off"
    case on = "on"
    /// A value from a newer Blender than this interface knows.
    case unknown
  }

  /// A mode the active object can switch to.
  struct ModeItem: Equatable, @unchecked Sendable {
    var id: String
    var label: String?
    var icon: String?

    /// From the snapshot as `JSONSerialization` reads it. Nil without its required fields.
    init?(json: [String: Any]) {
      guard let id = json["id"] as? String else {
        return nil
      }
      self.id = id
      label = json["label"] as? String
      icon = json["icon"] as? String
    }
  }

  /// A tool in the toolbar, or a group of them shown as its active member.
  struct Tool: Equatable, @unchecked Sendable {
    var id: String
    var title: String?
    /// Blender's icon for the tool.
    var icon: String?
    /// A system symbol to show instead, when there is one.
    var symbol: String?
    /// Blender's tooltip for it, for interfaces that name tools without hover.
    var description: String?
    /// The group's first tool, which names the group.
    var group: String?
    /// The group's members, with nulls between sets of them.
    var children: [Tool?]

    /// From the snapshot as `JSONSerialization` reads it. Nil without its required fields.
    init?(json: [String: Any]) {
      guard let id = json["id"] as? String else {
        return nil
      }
      self.id = id
      title = json["title"] as? String
      icon = json["icon"] as? String
      symbol = json["symbol"] as? String
      description = json["description"] as? String
      group = json["group"] as? String
      children = (json["children"] as? [Any])?.map { $0 is NSNull ? nil : ($0 as? [String: Any]).flatMap(Tool.init(json:)) } ?? []
    }
  }

  /// Transform settings in the top bar.
  struct TransformSettings: Equatable, @unchecked Sendable {
    var orientation: Orientation
    var pivot: Pivot
    var snap: Snap
    var proportional: Proportional
    /// The axes the active object can mirror on, such as `XYZ`, when it can.
    var mirrorAxes: String?
    /// Those of them it mirrors on.
    var mirror: String?
    var mirrorTopology: Toggle?

    /// From the snapshot as `JSONSerialization` reads it.
    init(json: [String: Any]) {
      orientation = (json["orientation"] as? String).map { Orientation(rawValue: $0) ?? .unknown } ?? .global
      pivot = (json["pivot"] as? String).map { Pivot(rawValue: $0) ?? .unknown } ?? .median
      snap = (json["snap"] as? String).map { Snap(rawValue: $0) ?? .unknown } ?? .off
      proportional = (json["proportional"] as? String).map { Proportional(rawValue: $0) ?? .unknown } ?? .off
      mirrorAxes = json["mirror_axes"] as? String
      mirror = json["mirror"] as? String
      mirrorTopology = (json["mirror_topology"] as? String).map { Toggle(rawValue: $0) ?? .unknown }
    }
  }

  /// What a held + or - does to the brush: its direction.
  struct BrushDirection: Equatable, @unchecked Sendable {
    /// The brush has no direction to show.
    var hidden: Bool
    /// A brush is active at all.
    var brush: Bool
    var inverted: Bool
    /// The names and symbols of the two directions.
    var add: String?
    var subtract: String?
    var addSymbol: String?
    var subtractSymbol: String?
    /// Holding both smooths, as in Sculpt Mode.
    var smooth: Bool

    /// From the snapshot as `JSONSerialization` reads it.
    init(json: [String: Any]) {
      hidden = flag(json["hidden"]) ?? false
      brush = flag(json["brush"]) ?? false
      inverted = flag(json["inverted"]) ?? false
      add = json["add"] as? String
      subtract = json["subtract"] as? String
      addSymbol = json["addSymbol"] as? String
      subtractSymbol = json["subtractSymbol"] as? String
      smooth = flag(json["smooth"]) ?? false
    }
  }

  /// A hint shown while dragging, such as how to snap.
  struct DragHint: Equatable, @unchecked Sendable {
    var text: String
    /// The drag ended.
    var done: Bool

    /// From the snapshot as `JSONSerialization` reads it. Nil without its required fields.
    init?(json: [String: Any]) {
      guard let text = json["text"] as? String else {
        return nil
      }
      self.text = text
      done = flag(json["done"]) ?? false
    }
  }

  /// A quick action for the mode, tool and selection.
  struct Action: Equatable, @unchecked Sendable {
    var title: String
    /// The action's own name, from `bl_ui.native_actions`.
    var action: String?
    /// The operator it runs, with one property set from `property` and `value`.
    var `operator`: String?
    var property: String?
    var value: String?
    var icon: String?
    var symbol: String?
    /// A key that runs it.
    var key: String?
    /// It is on, for actions that toggle.
    var selected: Bool

    /// From the snapshot as `JSONSerialization` reads it. Nil without its required fields.
    init?(json: [String: Any]) {
      guard let title = json["title"] as? String else {
        return nil
      }
      self.title = title
      action = json["action"] as? String
      `operator` = json["operator"] as? String
      property = json["property"] as? String
      value = json["value"] as? String
      icon = json["icon"] as? String
      symbol = json["symbol"] as? String
      key = json["key"] as? String
      selected = flag(json["selected"]) ?? false
    }
  }

  /// The tools, modes, tool settings and active object: what the interface around the viewport
  /// shows. Sent with every change, see `WM_native_ui_toolbar_take_json`.
  struct Toolbar: Equatable, @unchecked Sendable {
    /// Blender's context mode, such as `objectmode` or `edit_mesh`.
    var mode: String
    var shading: Shading
    /// Blender's own interface shows instead.
    var desktop: Bool
    /// The name Rename Active starts from: the active bone in an armature's modes, otherwise the
    /// active object's.
    var activeName: String?
    var objectMode: ObjectMode
    var modes: [ModeItem]
    /// In a mesh's Edit Mode, otherwise empty.
    var meshSelectMode: String?
    /// The active tool.
    var active: String?
    var canUndo: Bool
    var canRedo: Bool
    /// The active undo step: menus are asked for again when it changes, and only then.
    var menuState: String?
    var settings: TransformSettings?
    /// The last operator's properties, for Adjust Last Operation.
    var redo: Open
    /// An operator's properties asked for before it runs, in place of Blender's dialog.
    var dialog: Open
    /// The text object being edited, with its fonts and style.
    var textObject: Open
    /// The navigation gizmo's center and radius, as fractions of the window from the top left.
    var navigationGizmo: [Float]
    /// The color the viewport is cleared to, in display space.
    var viewportBackground: [Float]
    /// The toolbar, with nulls between its sets of tools.
    var tools: [Tool?]
    /// The brushes the mode offers.
    var brushes: Open
    /// The active brush's settings.
    var brush: Open
    var direction: BrushDirection?
    /// Moving, turning or scaling: held buttons snap and slow down then.
    var transforming: Bool
    var dragHint: DragHint?
    /// A render in progress, or its result.
    var render: Open
    /// The viewport's options.
    var viewport: Open
    var preferences: Open
    var actions: [Action]

    /// From the snapshot as `JSONSerialization` reads it. Nil without its required fields.
    init?(json: [String: Any]) {
      guard let mode = json["mode"] as? String else {
        return nil
      }
      self.mode = mode
      shading = (json["shading"] as? String).map { Shading(rawValue: $0) ?? .unknown } ?? .solid
      desktop = flag(json["desktop"]) ?? false
      activeName = json["activeName"] as? String
      objectMode = (json["objectMode"] as? String).map { ObjectMode(rawValue: $0) ?? .unknown } ?? .object
      modes = (json["modes"] as? [Any])?.compactMap { ($0 as? [String: Any]).flatMap(ModeItem.init(json:)) } ?? []
      meshSelectMode = json["meshSelectMode"] as? String
      active = json["active"] as? String
      canUndo = flag(json["canUndo"]) ?? false
      canRedo = flag(json["canRedo"]) ?? false
      menuState = json["menuState"] as? String
      settings = (json["settings"] as? [String: Any]).flatMap(TransformSettings.init(json:))
      redo = Open(json["redo"])
      dialog = Open(json["dialog"])
      textObject = Open(json["textObject"])
      navigationGizmo = (json["navigationGizmo"] as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue } ?? []
      viewportBackground = (json["viewportBackground"] as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue } ?? []
      tools = (json["tools"] as? [Any])?.map { $0 is NSNull ? nil : ($0 as? [String: Any]).flatMap(Tool.init(json:)) } ?? []
      brushes = Open(json["brushes"])
      brush = Open(json["brush"])
      direction = (json["direction"] as? [String: Any]).flatMap(BrushDirection.init(json:))
      transforming = flag(json["transforming"]) ?? false
      dragHint = (json["dragHint"] as? [String: Any]).flatMap(DragHint.init(json:))
      render = Open(json["render"])
      viewport = Open(json["viewport"])
      preferences = Open(json["preferences"])
      actions = (json["actions"] as? [Any])?.compactMap { ($0 as? [String: Any]).flatMap(Action.init(json:)) } ?? []
    }
  }
}
