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

/**
 * What the interface around the viewport shows that is not in the `toolbar` view yet. Sent with
 * every change, see `WM_native_ui_toolbar_take_json`.
 */
@Serializable
data class Toolbar(
  /** Blender's context mode, such as `objectmode` or `edit_mesh`. */
  @SerialName("mode") val mode: String? = null,
  /** The text object being edited, with its fonts and style. */
  @SerialName("textObject") val textObject: JsonElement? = null,
  /** The brushes the mode offers. */
  @SerialName("brushes") val brushes: JsonElement? = null,
  /** A render in progress, or its result. */
  @SerialName("render") val render: JsonElement? = null,
  @SerialName("preferences") val preferences: JsonElement? = null,
)
