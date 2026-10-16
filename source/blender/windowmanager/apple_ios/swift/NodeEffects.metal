/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Effects for the native node editor's canvas, used through SwiftUI's shader effects.
 */

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

/** How far `p` lies outside a rectangle with rounded corners, or 0 inside it. */
static float outside_rounded_rect(float2 p, float4 rect, float radius)
{
  const float2 half_size = rect.zw * 0.5;
  const float2 center = rect.xy + half_size;
  const float2 q = abs(p - center) - half_size + radius;
  return max(length(max(q, 0.0)) - radius, 0.0);
}

/**
 * Water rippling out from a node as it lands on the canvas: rings shaped like the node travel
 * outward from its edges, bending the picture under them like a water surface and catching the
 * light on their crests, then calm.
 *
 * \param rect: The node, as x, y, width and height in points.
 * \param radius: The node's corner radius, in points.
 * \param time: Seconds since the node landed.
 * \param amplitude: How far the rings bend the picture, in points.
 * \param wavelength: The distance between rings, in points.
 * \param speed: How fast the rings travel outward, in points per second.
 * \param decay: How quickly the water calms, per second, besides spreading out.
 */
[[stitchable]] half4 node_ripple(float2 position,
                                 SwiftUI::Layer layer,
                                 float4 rect,
                                 float radius,
                                 float time,
                                 float amplitude,
                                 float wavelength,
                                 float speed,
                                 float decay)
{
  const float distance = outside_rounded_rect(position, rect, radius);
  /* A packet of a few rings leaves the node's edge and travels outward: strongest where the
   * packet is, fading as it spreads over a wider ring, and calming toward the end. */
  const float front = speed * time;
  const float packet = (distance - front) / (wavelength * 1.1);
  const float envelope = exp(-packet * packet) * smoothstep(0.0, wavelength * 0.35, distance) /
                         (1.0 + distance / 180.0) * exp(-decay * time);
  if (envelope < 0.002) {
    return layer.sample(position);
  }
  /* Outward from the nearest edge, found from how the distance changes. */
  const float2 direction = normalize(float2(outside_rounded_rect(position + float2(1, 0), rect, radius) -
                                                distance,
                                            outside_rounded_rect(position + float2(0, 1), rect, radius) -
                                                distance) +
                                     1e-5);
  const float phase = 2.0 * M_PI_F / wavelength * (distance - front);
  /* The surface's slope bends the picture outward and inward across each ring. */
  half4 color = layer.sample(position - direction * amplitude * cos(phase) * envelope);
  /* Crests catch the light and troughs shade, as on water. */
  color.rgb = clamp(color.rgb + half(sin(phase + 0.9) * envelope * 0.07), half(0.0), color.a);
  return color;
}
