// SPDX-FileCopyrightText: 2026 Blender Authors
//
// SPDX-License-Identifier: GPL-2.0-or-later

// Generated from native_ui.fbs by native_ui_schema.py: edit the schema, then run
// `python3 source/blender/windowmanager/native_ui/native_ui_schema.py generate`.

@file:Suppress("unused")

package org.blender.nativeui

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull

/** Blender writes some flags as 0 and 1, others as false and true. */
object Flag : KSerializer<Boolean> {
  override val descriptor = PrimitiveSerialDescriptor("Flag", PrimitiveKind.BOOLEAN)

  override fun deserialize(decoder: Decoder): Boolean {
    val element = (decoder as JsonDecoder).decodeJsonElement() as JsonPrimitive
    return element.booleanOrNull ?: ((element.intOrNull ?: 0) != 0)
  }

  override fun serialize(encoder: Encoder, value: Boolean) = encoder.encodeBoolean(value)
}

/** The 3D viewport's shading. */
@Serializable
enum class Shading {
  @SerialName("wireframe") wireframe,
  @SerialName("solid") solid,
  @SerialName("material") material,
  @SerialName("rendered") rendered,
}

/** An object's mode, as `Object.mode` names it. */
@Serializable
enum class ObjectMode {
  @SerialName("OBJECT") OBJECT,
  @SerialName("EDIT") EDIT,
  @SerialName("POSE") POSE,
  @SerialName("SCULPT") SCULPT,
  @SerialName("VERTEX_PAINT") VERTEX_PAINT,
  @SerialName("WEIGHT_PAINT") WEIGHT_PAINT,
  @SerialName("TEXTURE_PAINT") TEXTURE_PAINT,
  @SerialName("PARTICLE_EDIT") PARTICLE_EDIT,
  @SerialName("EDIT_GPENCIL") EDIT_GPENCIL,
  @SerialName("SCULPT_CURVES") SCULPT_CURVES,
  @SerialName("PAINT_GREASE_PENCIL") PAINT_GREASE_PENCIL,
  @SerialName("SCULPT_GREASE_PENCIL") SCULPT_GREASE_PENCIL,
  @SerialName("WEIGHT_GREASE_PENCIL") WEIGHT_GREASE_PENCIL,
  @SerialName("VERTEX_GREASE_PENCIL") VERTEX_GREASE_PENCIL,
}

/** What edit mode selects on a mesh. */
@Serializable
enum class MeshSelectMode {
  @SerialName("VERT") VERT,
  @SerialName("EDGE") EDGE,
  @SerialName("FACE") FACE,
}

@Serializable
enum class Orientation {
  @SerialName("global") global,
  @SerialName("local") local,
  @SerialName("normal") normal,
  @SerialName("gimbal") gimbal,
  @SerialName("view") view,
  @SerialName("cursor") cursor,
  @SerialName("parent") parent,
  @SerialName("custom") custom,
}

@Serializable
enum class Pivot {
  @SerialName("bounds") bounds,
  @SerialName("cursor") cursor,
  @SerialName("individual") individual,
  @SerialName("median") median,
  @SerialName("active") active,
}

@Serializable
enum class Snap {
  @SerialName("off") off,
  @SerialName("increment") increment,
  @SerialName("grid") grid,
  @SerialName("vertex") vertex,
  @SerialName("edge") edge,
  @SerialName("face") face,
  @SerialName("volume") volume,
  /** Several elements snapped to at once. */
  @SerialName("mixed") mixed,
}

@Serializable
enum class Proportional {
  @SerialName("off") off,
  @SerialName("on") on,
  @SerialName("connected") connected,
  @SerialName("projected") projected,
}

@Serializable
enum class Toggle {
  @SerialName("off") off,
  @SerialName("on") on,
}

/** A mode the active object can switch to. */
@Serializable
data class ModeItem(
  @SerialName("id") val id: String? = null,
  @SerialName("label") val label: String? = null,
  @SerialName("icon") val icon: String? = null,
)

/** A tool in the toolbar, or a group of them shown as its active member. */
@Serializable
data class Tool(
  @SerialName("id") val id: String? = null,
  @SerialName("title") val title: String? = null,
  /** Blender's icon for the tool. */
  @SerialName("icon") val icon: String? = null,
  /** A system symbol to show instead, when there is one. */
  @SerialName("symbol") val symbol: String? = null,
  /** Blender's tooltip for it, for interfaces that name tools without hover. */
  @SerialName("description") val description: String? = null,
  /** The group's first tool, which names the group. */
  @SerialName("group") val group: String? = null,
  /** The group's members, with nulls between sets of them. */
  @SerialName("children") val children: List<Tool?> = emptyList(),
)

/** Transform settings in the top bar. */
@Serializable
data class TransformSettings(
  @SerialName("orientation") val orientation: Orientation = Orientation.global,
  @SerialName("pivot") val pivot: Pivot = Pivot.median,
  @SerialName("snap") val snap: Snap = Snap.off,
  @SerialName("proportional") val proportional: Proportional = Proportional.off,
  /** The axes the active object can mirror on, such as `XYZ`, when it can. */
  @SerialName("mirror_axes") val mirrorAxes: String? = null,
  /** Those of them it mirrors on. */
  @SerialName("mirror") val mirror: String? = null,
  @SerialName("mirror_topology") val mirrorTopology: Toggle? = null,
)

/** What a held + or - does to the brush: its direction. */
@Serializable
data class BrushDirection(
  /** The brush has no direction to show. */
  @SerialName("hidden") @Serializable(with = Flag::class) val hidden: Boolean = false,
  /** A brush is active at all. */
  @SerialName("brush") @Serializable(with = Flag::class) val brush: Boolean = false,
  @SerialName("inverted") @Serializable(with = Flag::class) val inverted: Boolean = false,
  /** The names and symbols of the two directions. */
  @SerialName("add") val add: String? = null,
  @SerialName("subtract") val subtract: String? = null,
  @SerialName("addSymbol") val addSymbol: String? = null,
  @SerialName("subtractSymbol") val subtractSymbol: String? = null,
  /** Holding both smooths, as in Sculpt Mode. */
  @SerialName("smooth") @Serializable(with = Flag::class) val smooth: Boolean = false,
)

/** A hint shown while dragging, such as how to snap. */
@Serializable
data class DragHint(
  @SerialName("text") val text: String? = null,
  /** The drag ended. */
  @SerialName("done") @Serializable(with = Flag::class) val done: Boolean = false,
)

/** A quick action for the mode, tool and selection. */
@Serializable
data class Action(
  @SerialName("title") val title: String? = null,
  /** The action's own name, from `bl_ui.native_actions`. */
  @SerialName("action") val action: String? = null,
  /** The operator it runs, with one property set from `property` and `value`. */
  @SerialName("operator") val operator: String? = null,
  @SerialName("property") val property: String? = null,
  @SerialName("value") val value: String? = null,
  @SerialName("icon") val icon: String? = null,
  @SerialName("symbol") val symbol: String? = null,
  /** A key that runs it. */
  @SerialName("key") val key: String? = null,
  /** It is on, for actions that toggle. */
  @SerialName("selected") @Serializable(with = Flag::class) val selected: Boolean = false,
)

/**
 * The tools, modes, tool settings and active object: what the interface around the viewport
 * shows. Sent with every change, see `WM_native_ui_toolbar_take_json`.
 */
@Serializable
data class Toolbar(
  /** Blender's context mode, such as `objectmode` or `edit_mesh`. */
  @SerialName("mode") val mode: String? = null,
  @SerialName("shading") val shading: Shading = Shading.solid,
  /** Blender's own interface shows instead. */
  @SerialName("desktop") @Serializable(with = Flag::class) val desktop: Boolean = false,
  /**
   * The name Rename Active starts from: the active bone in an armature's modes, otherwise the
   * active object's.
   */
  @SerialName("activeName") val activeName: String? = null,
  @SerialName("objectMode") val objectMode: ObjectMode = ObjectMode.OBJECT,
  @SerialName("modes") val modes: List<ModeItem> = emptyList(),
  /** In a mesh's Edit Mode, otherwise empty. */
  @SerialName("meshSelectMode") val meshSelectMode: String? = null,
  /** The active tool. */
  @SerialName("active") val active: String? = null,
  @SerialName("canUndo") @Serializable(with = Flag::class) val canUndo: Boolean = false,
  @SerialName("canRedo") @Serializable(with = Flag::class) val canRedo: Boolean = false,
  /** The active undo step: menus are asked for again when it changes, and only then. */
  @SerialName("menuState") val menuState: String? = null,
  @SerialName("settings") val settings: TransformSettings? = null,
  /** The last operator's properties, for Adjust Last Operation. */
  @SerialName("redo") val redo: JsonElement? = null,
  /** An operator's properties asked for before it runs, in place of Blender's dialog. */
  @SerialName("dialog") val dialog: JsonElement? = null,
  /** The text object being edited, with its fonts and style. */
  @SerialName("textObject") val textObject: JsonElement? = null,
  /** The navigation gizmo's center and radius, as fractions of the window from the top left. */
  @SerialName("navigationGizmo") val navigationGizmo: List<Float> = emptyList(),
  /** The color the viewport is cleared to, in display space. */
  @SerialName("viewportBackground") val viewportBackground: List<Float> = emptyList(),
  /** The toolbar, with nulls between its sets of tools. */
  @SerialName("tools") val tools: List<Tool?> = emptyList(),
  /** The brushes the mode offers. */
  @SerialName("brushes") val brushes: JsonElement? = null,
  /** The active brush's settings. */
  @SerialName("brush") val brush: JsonElement? = null,
  @SerialName("direction") val direction: BrushDirection? = null,
  /** Moving, turning or scaling: held buttons snap and slow down then. */
  @SerialName("transforming") @Serializable(with = Flag::class) val transforming: Boolean = false,
  @SerialName("dragHint") val dragHint: DragHint? = null,
  /** A render in progress, or its result. */
  @SerialName("render") val render: JsonElement? = null,
  /** The viewport's options. */
  @SerialName("viewport") val viewport: JsonElement? = null,
  @SerialName("preferences") val preferences: JsonElement? = null,
  @SerialName("actions") val actions: List<Action> = emptyList(),
)
