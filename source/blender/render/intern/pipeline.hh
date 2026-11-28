/* SPDX-FileCopyrightText: 2006 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup render
 */

#pragma once

namespace blender {

struct Render;
struct RenderData;
struct RenderLayer;
struct RenderResult;

RenderLayer *render_get_single_layer(Render *re, RenderResult *rr);
void render_copy_renderdata(RenderData *to, RenderData *from);
/** Keep \a info, the engine's own words about what it does (#RenderStats::infostr), for
 * #RE_engine_status_get. Null or empty forgets them, for a new render. */
void render_engine_status_set(Render *re, const char *info);

}  // namespace blender
