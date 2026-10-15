/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Effects for the native node editor's canvas, used through SwiftUI's shader effects.
 */

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

/**
 * Water rippling out from `origin` as a node lands on the canvas: rings travel outward from it,
 * bending the picture under them like a water surface and catching the light on their crests,
 * then fade.
 *
 * \param time: Seconds since the node landed.
 * \param amplitude: How far the rings bend the picture, in points.
 * \param wavelength: The distance between rings, in points.
 * \param speed: How fast the rings travel outward, in points per second.
 * \param decay: How quickly the water calms, per second.
 */
[[stitchable]] half4 node_ripple(float2 position,
                                 SwiftUI::Layer layer,
                                 float2 origin,
                                 float time,
                                 float amplitude,
                                 float wavelength,
                                 float speed,
                                 float decay)
{
  const float2 offset = position - origin;
  const float distance = length(offset);
  /* The leading ring: nothing beyond it moves yet, and it softens rather than cuts off. */
  const float front = speed * time;
  const float reached = smoothstep(front, front - wavelength * 0.75, distance);
  /* Calmer with time and farther out, so the rings stay about the node. */
  const float envelope = reached * exp(-decay * time) * exp(-distance / 520.0);
  if (envelope < 0.001 || distance < 0.001) {
    return layer.sample(position);
  }
  const float k = 2.0 * M_PI_F / wavelength;
  const float phase = k * (distance - front);
  /* The surface's slope bends the picture outward and inward across each ring. */
  const float slope = cos(phase) * envelope;
  const float2 direction = offset / distance;
  half4 color = layer.sample(position - direction * amplitude * slope);
  /* Crests catch the light and troughs shade, as on water. */
  const float light = sin(phase + 0.9) * envelope;
  color.rgb = clamp(color.rgb + half(light * 0.16), half(0.0), color.a);
  return color;
}
