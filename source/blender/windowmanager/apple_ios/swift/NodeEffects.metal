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
 * A ring of water running out from `origin`, as a node lands on the canvas: each point is
 * pushed along the ring's direction as the wave passes it, then settles. Returns where to read
 * the canvas from for `position`.
 *
 * \param time: Seconds since the node landed.
 * \param amplitude: How far the wave pushes, in points.
 * \param frequency: How quickly a point swings back and forth.
 * \param decay: How quickly the swinging dies out.
 * \param speed: How fast the ring travels outward, in points per second.
 */
[[stitchable]] float2 node_ripple(float2 position,
                                  float2 origin,
                                  float time,
                                  float amplitude,
                                  float frequency,
                                  float decay,
                                  float speed)
{
  const float2 offset = position - origin;
  const float distance = length(offset);
  if (distance < 0.001) {
    return position;
  }
  /* The wave reaches farther points later. */
  const float local = max(0.0, time - distance / speed);
  const float push = amplitude * sin(frequency * local) * exp(-decay * local) *
                     /* Fading with distance, so the ring stays around the node. */
                     exp(-distance / 600.0);
  return position + push * (offset / distance);
}
