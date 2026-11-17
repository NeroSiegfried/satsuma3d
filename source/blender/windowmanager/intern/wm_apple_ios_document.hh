/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * Hooks for `wm_files.cc` into iOS document handling, see `wm_apple_ios_document.cc`.
 */

#pragma once

#include "BLI_path_utils.hh"

#include "BLO_writefile.hh"

#include <optional>
#include <string>

namespace blender {

struct ARegion;
struct Depsgraph;
struct ImBuf;
struct ReportList;
struct Scene;
struct View3D;
struct bContext;

/**
 * The document's preview while iOS saves it: everything visible, framed from the 3D View's
 * angle as Frame All does. Null when saving for anything else, or with nothing to frame.
 */
ImBuf *wm_apple_ios_thumb_frame_all(const bContext *C,
                                    Depsgraph *depsgraph,
                                    Scene *scene,
                                    View3D *v3d,
                                    ARegion *region,
                                    char err_out[256]);

/**
 * iOS may purge temporary files and ends apps in the background without warning. Keep auto-saves
 * where they survive, one per document rather than per process, so work continues on the next
 * launch.
 */
bool wm_apple_ios_autosave_location(const char *blendfile_path, char filepath[FILE_MAX]);
/** Remove the auto-save of a document, once its work is saved. */
void wm_apple_ios_autosave_remove(const char *blendfile_path);
/**
 * An auto-save newer than the document holds changes that were never saved, because Blender was
 * closed or another file was opened: opening the document continues from it.
 */
bool wm_apple_ios_autosave_newer(const char *filepath, char r_autosave[FILE_MAX]);

/** #wm_file_write through iOS file coordination, which may change `filepath`. */
bool wm_apple_ios_file_write(bContext *C,
                             char *filepath,
                             int fileflags,
                             eBLO_WritePathRemap remap_mode,
                             bool use_save_as_copy,
                             ReportList *reports);

/** What to say before a save when the volume is low, see #wm_apple_ios_save_space_warning. */
struct wmIOSSaveSpaceWarning {
  std::string title;
  std::string detail;
  std::string save_anyway;
  std::string cancel;
};

/**
 * Free space before Save and Save As (ROUND5 8I.5, decision 45): the warning to show before
 * writing the file at \a filepath (empty for one never saved) when the volume has less room than
 * the larger of twice the file's last saved size and 200 MB, from `SaveSpace.swift`, the one
 * rule. Nothing when there is room, or when the free space cannot be read, which is logged as
 * `save free space unknown` and lets the save go ahead.
 */
std::optional<wmIOSSaveSpaceWarning> wm_apple_ios_save_space_warning(const char *filepath);

}  // namespace blender
