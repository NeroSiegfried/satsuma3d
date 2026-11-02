// SPDX-FileCopyrightText: 2026 Blender Authors
//
// SPDX-License-Identifier: GPL-2.0-or-later

// Generated from native_ui.fbs by native_ui_schema.py: edit the schema, then run
// `python3 source/blender/windowmanager/native_ui/native_ui_schema.py generate`.

import Foundation

fileprivate extension KeyedDecodingContainer {
  /// Blender writes some flags as 0 and 1, others as false and true.
  func decodeFlagIfPresent(forKey key: Key) throws -> Bool? {
    if let value = try? decodeIfPresent(Bool.self, forKey: key) {
      return value
    }
    return try decodeIfPresent(Int.self, forKey: key).map { $0 != 0 }
  }
}

enum NativeUI {
  /// A value the schema leaves open: any JSON, for parts of a snapshot still to be described.
  enum Value: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([Value])
    case object([String: Value])

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if container.decodeNil() {
        self = .null
      }
      else if let value = try? container.decode(Bool.self) {
        self = .bool(value)
      }
      else if let value = try? container.decode(Double.self) {
        self = .number(value)
      }
      else if let value = try? container.decode(String.self) {
        self = .string(value)
      }
      else if let value = try? container.decode([Value].self) {
        self = .array(value)
      }
      else {
        self = .object(try container.decode([String: Value].self))
      }
    }

    /// As `JSONSerialization` gives it, for code that reads snapshots untyped.
    var foundation: Any {
      switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.foundation)
        case .object(let value): return value.mapValues(\.foundation)
      }
    }
  }

  /// The 3D viewport's shading.
  enum Shading: String, Decodable, Equatable, Sendable {
    case wireframe = "wireframe"
    case solid = "solid"
    case material = "material"
    case rendered = "rendered"
    /// A value from a newer Blender than this interface knows.
    case unknown

    init(from decoder: Decoder) throws {
      self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
  }

  /// An object's mode, as `Object.mode` names it.
  enum ObjectMode: String, Decodable, Equatable, Sendable {
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

    init(from decoder: Decoder) throws {
      self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
  }

  /// What edit mode selects on a mesh.
  enum MeshSelectMode: String, Decodable, Equatable, Sendable {
    case vert = "VERT"
    case edge = "EDGE"
    case face = "FACE"
    /// A value from a newer Blender than this interface knows.
    case unknown

    init(from decoder: Decoder) throws {
      self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
  }

  enum Orientation: String, Decodable, Equatable, Sendable {
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

    init(from decoder: Decoder) throws {
      self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
  }

  enum Pivot: String, Decodable, Equatable, Sendable {
    case bounds = "bounds"
    case cursor = "cursor"
    case individual = "individual"
    case median = "median"
    case active = "active"
    /// A value from a newer Blender than this interface knows.
    case unknown

    init(from decoder: Decoder) throws {
      self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
  }

  enum Snap: String, Decodable, Equatable, Sendable {
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

    init(from decoder: Decoder) throws {
      self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
  }

  enum Proportional: String, Decodable, Equatable, Sendable {
    case off = "off"
    case on = "on"
    case connected = "connected"
    case projected = "projected"
    /// A value from a newer Blender than this interface knows.
    case unknown

    init(from decoder: Decoder) throws {
      self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
  }

  enum Toggle: String, Decodable, Equatable, Sendable {
    case off = "off"
    case on = "on"
    /// A value from a newer Blender than this interface knows.
    case unknown

    init(from decoder: Decoder) throws {
      self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
  }

  /// A mode the active object can switch to.
  struct ModeItem: Decodable, Equatable, Sendable {
    var id: String
    var label: String?
    var icon: String?

    enum CodingKeys: String, CodingKey {
      case id = "id"
      case label = "label"
      case icon = "icon"
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      guard let id = try container.decodeIfPresent(String.self, forKey: .id) else {
        throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: container.codingPath, debugDescription: "Required by the schema"))
      }
      self.id = id
      label = try container.decodeIfPresent(String.self, forKey: .label)
      icon = try container.decodeIfPresent(String.self, forKey: .icon)
    }
  }

  /// A tool in the toolbar, or a group of them shown as its active member.
  struct Tool: Decodable, Equatable, Sendable {
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

    enum CodingKeys: String, CodingKey {
      case id = "id"
      case title = "title"
      case icon = "icon"
      case symbol = "symbol"
      case description = "description"
      case group = "group"
      case children = "children"
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      guard let id = try container.decodeIfPresent(String.self, forKey: .id) else {
        throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: container.codingPath, debugDescription: "Required by the schema"))
      }
      self.id = id
      title = try container.decodeIfPresent(String.self, forKey: .title)
      icon = try container.decodeIfPresent(String.self, forKey: .icon)
      symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
      description = try container.decodeIfPresent(String.self, forKey: .description)
      group = try container.decodeIfPresent(String.self, forKey: .group)
      children = try container.decodeIfPresent([Tool?].self, forKey: .children) ?? []
    }
  }

  /// Transform settings in the top bar.
  struct TransformSettings: Decodable, Equatable, Sendable {
    var orientation: Orientation
    var pivot: Pivot
    var snap: Snap
    var proportional: Proportional
    /// The axes the active object can mirror on, such as `XYZ`, when it can.
    var mirrorAxes: String?
    /// Those of them it mirrors on.
    var mirror: String?
    var mirrorTopology: Toggle?

    enum CodingKeys: String, CodingKey {
      case orientation = "orientation"
      case pivot = "pivot"
      case snap = "snap"
      case proportional = "proportional"
      case mirrorAxes = "mirror_axes"
      case mirror = "mirror"
      case mirrorTopology = "mirror_topology"
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      orientation = try container.decodeIfPresent(Orientation.self, forKey: .orientation) ?? .global
      pivot = try container.decodeIfPresent(Pivot.self, forKey: .pivot) ?? .median
      snap = try container.decodeIfPresent(Snap.self, forKey: .snap) ?? .off
      proportional = try container.decodeIfPresent(Proportional.self, forKey: .proportional) ?? .off
      mirrorAxes = try container.decodeIfPresent(String.self, forKey: .mirrorAxes)
      mirror = try container.decodeIfPresent(String.self, forKey: .mirror)
      mirrorTopology = try container.decodeIfPresent(Toggle.self, forKey: .mirrorTopology)
    }
  }

  /// What a held + or - does to the brush: its direction.
  struct BrushDirection: Decodable, Equatable, Sendable {
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

    enum CodingKeys: String, CodingKey {
      case hidden = "hidden"
      case brush = "brush"
      case inverted = "inverted"
      case add = "add"
      case subtract = "subtract"
      case addSymbol = "addSymbol"
      case subtractSymbol = "subtractSymbol"
      case smooth = "smooth"
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      hidden = try container.decodeFlagIfPresent(forKey: .hidden) ?? false
      brush = try container.decodeFlagIfPresent(forKey: .brush) ?? false
      inverted = try container.decodeFlagIfPresent(forKey: .inverted) ?? false
      add = try container.decodeIfPresent(String.self, forKey: .add)
      subtract = try container.decodeIfPresent(String.self, forKey: .subtract)
      addSymbol = try container.decodeIfPresent(String.self, forKey: .addSymbol)
      subtractSymbol = try container.decodeIfPresent(String.self, forKey: .subtractSymbol)
      smooth = try container.decodeFlagIfPresent(forKey: .smooth) ?? false
    }
  }

  /// A hint shown while dragging, such as how to snap.
  struct DragHint: Decodable, Equatable, Sendable {
    var text: String
    /// The drag ended.
    var done: Bool

    enum CodingKeys: String, CodingKey {
      case text = "text"
      case done = "done"
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      guard let text = try container.decodeIfPresent(String.self, forKey: .text) else {
        throw DecodingError.keyNotFound(CodingKeys.text, .init(codingPath: container.codingPath, debugDescription: "Required by the schema"))
      }
      self.text = text
      done = try container.decodeFlagIfPresent(forKey: .done) ?? false
    }
  }

  /// A quick action for the mode, tool and selection.
  struct Action: Decodable, Equatable, Sendable {
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

    enum CodingKeys: String, CodingKey {
      case title = "title"
      case action = "action"
      case `operator` = "operator"
      case property = "property"
      case value = "value"
      case icon = "icon"
      case symbol = "symbol"
      case key = "key"
      case selected = "selected"
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      guard let title = try container.decodeIfPresent(String.self, forKey: .title) else {
        throw DecodingError.keyNotFound(CodingKeys.title, .init(codingPath: container.codingPath, debugDescription: "Required by the schema"))
      }
      self.title = title
      action = try container.decodeIfPresent(String.self, forKey: .action)
      `operator` = try container.decodeIfPresent(String.self, forKey: .operator)
      property = try container.decodeIfPresent(String.self, forKey: .property)
      value = try container.decodeIfPresent(String.self, forKey: .value)
      icon = try container.decodeIfPresent(String.self, forKey: .icon)
      symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
      key = try container.decodeIfPresent(String.self, forKey: .key)
      selected = try container.decodeFlagIfPresent(forKey: .selected) ?? false
    }
  }

  /// The tools, modes, tool settings and active object: what the interface around the viewport
  /// shows. Sent with every change, see `WM_native_ui_toolbar_take_json`.
  struct Toolbar: Decodable, Equatable, Sendable {
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
    /// The Tool tab of Properties, as the inspector describes it.
    var toolSettings: Value?
    /// The last panel of Properties the interface changed: its edits have arrived.
    var propertiesAck: Int
    /// The last operator's properties, for Adjust Last Operation.
    var redo: Value?
    /// An operator's properties asked for before it runs, in place of Blender's dialog.
    var dialog: Value?
    /// The text object being edited, with its fonts and style.
    var textObject: Value?
    /// The navigation gizmo's center and radius, as fractions of the window from the top left.
    var navigationGizmo: [Float]
    /// The color the viewport is cleared to, in display space.
    var viewportBackground: [Float]
    /// The toolbar, with nulls between its sets of tools.
    var tools: [Tool?]
    /// The brushes the mode offers.
    var brushes: Value?
    /// The active brush's settings.
    var brush: Value?
    var direction: BrushDirection?
    /// Moving, turning or scaling: held buttons snap and slow down then.
    var transforming: Bool
    var dragHint: DragHint?
    /// A render in progress, or its result.
    var render: Value?
    /// The viewport's options.
    var viewport: Value?
    var preferences: Value?
    var actions: [Action]

    enum CodingKeys: String, CodingKey {
      case mode = "mode"
      case shading = "shading"
      case desktop = "desktop"
      case activeName = "activeName"
      case objectMode = "objectMode"
      case modes = "modes"
      case meshSelectMode = "meshSelectMode"
      case active = "active"
      case canUndo = "canUndo"
      case canRedo = "canRedo"
      case menuState = "menuState"
      case settings = "settings"
      case toolSettings = "toolSettings"
      case propertiesAck = "propertiesAck"
      case redo = "redo"
      case dialog = "dialog"
      case textObject = "textObject"
      case navigationGizmo = "navigationGizmo"
      case viewportBackground = "viewportBackground"
      case tools = "tools"
      case brushes = "brushes"
      case brush = "brush"
      case direction = "direction"
      case transforming = "transforming"
      case dragHint = "dragHint"
      case render = "render"
      case viewport = "viewport"
      case preferences = "preferences"
      case actions = "actions"
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      guard let mode = try container.decodeIfPresent(String.self, forKey: .mode) else {
        throw DecodingError.keyNotFound(CodingKeys.mode, .init(codingPath: container.codingPath, debugDescription: "Required by the schema"))
      }
      self.mode = mode
      shading = try container.decodeIfPresent(Shading.self, forKey: .shading) ?? .solid
      desktop = try container.decodeFlagIfPresent(forKey: .desktop) ?? false
      activeName = try container.decodeIfPresent(String.self, forKey: .activeName)
      objectMode = try container.decodeIfPresent(ObjectMode.self, forKey: .objectMode) ?? .object
      modes = try container.decodeIfPresent([ModeItem].self, forKey: .modes) ?? []
      meshSelectMode = try container.decodeIfPresent(String.self, forKey: .meshSelectMode)
      active = try container.decodeIfPresent(String.self, forKey: .active)
      canUndo = try container.decodeFlagIfPresent(forKey: .canUndo) ?? false
      canRedo = try container.decodeFlagIfPresent(forKey: .canRedo) ?? false
      menuState = try container.decodeIfPresent(String.self, forKey: .menuState)
      settings = try container.decodeIfPresent(TransformSettings.self, forKey: .settings)
      toolSettings = try container.decodeIfPresent(Value.self, forKey: .toolSettings)
      propertiesAck = try container.decodeIfPresent(Int.self, forKey: .propertiesAck) ?? 0
      redo = try container.decodeIfPresent(Value.self, forKey: .redo)
      dialog = try container.decodeIfPresent(Value.self, forKey: .dialog)
      textObject = try container.decodeIfPresent(Value.self, forKey: .textObject)
      navigationGizmo = try container.decodeIfPresent([Float].self, forKey: .navigationGizmo) ?? []
      viewportBackground = try container.decodeIfPresent([Float].self, forKey: .viewportBackground) ?? []
      tools = try container.decodeIfPresent([Tool?].self, forKey: .tools) ?? []
      brushes = try container.decodeIfPresent(Value.self, forKey: .brushes)
      brush = try container.decodeIfPresent(Value.self, forKey: .brush)
      direction = try container.decodeIfPresent(BrushDirection.self, forKey: .direction)
      transforming = try container.decodeFlagIfPresent(forKey: .transforming) ?? false
      dragHint = try container.decodeIfPresent(DragHint.self, forKey: .dragHint)
      render = try container.decodeIfPresent(Value.self, forKey: .render)
      viewport = try container.decodeIfPresent(Value.self, forKey: .viewport)
      preferences = try container.decodeIfPresent(Value.self, forKey: .preferences)
      actions = try container.decodeIfPresent([Action].self, forKey: .actions) ?? []
    }
  }
}
