/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup editors
 *
 * The Timeline a native interface draws its key strip from (`action_native.cc`).
 */

#pragma once

#include <cstdint>
#include <vector>

struct bContext;
struct ScrArea;

namespace blender {

/**
 * The hidden Timeline a native interface's key strip stands for: an area outside any screen, kept
 * for the session, made on first use. Its keys are those of Blender's own Timeline with its
 * default settings (ROUND6 EDIT-6).
 */
ScrArea *ED_action_native_timeline_area(bContext *C);

/** The frames the Timeline draws keys on, rounded to whole frames, and those with a key selected. */
void ED_action_native_timeline_keys(bContext *C,
                                    std::vector<int64_t> &r_frames,
                                    std::vector<int64_t> &r_selected);

/** Frees the hidden Timeline, before Blender's allocator checks for leaks. */
void ED_action_native_exit();

/** The strip's edits, run as the Timeline's own: `ANIM_OT_native_key_select`, `_move`, `_delete`
 * and `_jump`. */
void ED_action_native_operatortypes();

}  // namespace blender
