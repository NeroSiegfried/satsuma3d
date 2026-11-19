/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * iOS documents: where auto-saves are kept, writing through file coordination, opening and
 * saving documents for the document browser, and the previews they show there.
 */

#if defined(WITH_APPLE_CROSSPLATFORM) && APPLE_TARGET_IOS

#  include <cstring>
#  include <fcntl.h>
#  include <ctime>
#  include <fmt/format.h>
#  include <optional>
#  include <variant>
#  include <vector>
#  include <string>

#  include "BKE_appdir.hh"
#  include "BKE_blender_version.h"
#  include "BKE_context.hh"
#  include "BKE_global.hh"
#  include "BKE_image.hh"
#  include "BKE_layer.hh"
#  include "BKE_main.hh"
#  include "BKE_object.hh"
#  include "BKE_report.hh"
#  include "BLI_fileops.h"
#  include "BLI_fileops_types.h"
#  include "BLI_filereader.h"
#  include "BLI_listbase.h"
#  include "BLI_listbase_iterator.hh"
#  include "BLI_math_matrix.hh"
#  include "BLI_math_vector.h"
#  include "BLI_math_vector.hh"
#  include "BLI_path_utils.hh"
#  include "BLI_string.h"
#  include "BLI_string_ref.hh"
#  include "BLT_translation.hh"
#  include "BLO_core_blend_header.hh"
#  include "BLO_core_file_reader.hh"
#  include "DEG_depsgraph_query.hh"
#  include "DNA_image_types.h"
#  include "DNA_object_types.h"
#  include "DNA_scene_types.h"
#  include "DNA_space_types.h"
#  include "DNA_userdef_types.h"
#  include "DNA_view3d_types.h"
#  include "DNA_windowmanager_types.h"
#  include "ED_view3d.hh"
#  include "ED_view3d_offscreen.hh"
#  include "GHOST_IOSDocumentPicker.hh"
#  include "IMB_imbuf.hh"
#  include "IMB_imbuf_types.hh"
#  include "IMB_thumbs.hh"
#  include "MEM_guardedalloc.h"
#  include "RNA_access.hh"
#  include "WM_api.hh"
#  include "WM_apple_ios.hh"
#  include "WM_document_command.hh"
#  include "WM_native_interface.hh"
#  include "WM_native_ui.hh"
#  include "WM_types.hh"
#  include "wm_event_system.hh"

#  ifdef WITH_PYTHON
#    include "BPY_extern_run.hh"
#  endif

#  include "wm.hh"
#  include "wm_apple_ios_document.hh"
#  include "wm_files.hh"
#  include "wm_window.hh"

namespace blender {

/** Documents on iOS preview their scene framed whole, as the 3D View's Frame All shows it. */
static bool preview_frame_all = false;

/**
 * Render the 3D View's angle onto everything visible, framed as Frame All does. Lights, cameras
 * and empties are left out of the framing, so a far light does not shrink the scene.
 */
ImBuf *wm_apple_ios_thumb_frame_all(const bContext *C,
                                    Depsgraph *depsgraph,
                                    Scene *scene,
                                    View3D *v3d,
                                    ARegion *region,
                                    char err_out[256])
{
  if (!preview_frame_all || v3d == nullptr || region == nullptr) {
    return nullptr;
  }
  ViewLayer *view_layer = CTX_data_view_layer(C);
  RegionView3D *rv3d = static_cast<RegionView3D *>(region->regiondata);
  if (view_layer == nullptr || rv3d == nullptr) {
    return nullptr;
  }
  float3 min(FLT_MAX), max(-FLT_MAX);
  bool found = false;
  BKE_view_layer_synced_ensure(scene, view_layer);
  for (Base &base : *BKE_view_layer_object_bases_get(view_layer)) {
    Object *ob = base.object;
    if (!BKE_base_is_visible(v3d, &base) ||
        ELEM(ob->type, OB_CAMERA, OB_LAMP, OB_LIGHTPROBE, OB_EMPTY, OB_SPEAKER))
    {
      continue;
    }
    const Object *ob_eval = DEG_get_evaluated(depsgraph, ob);
    const std::optional<Bounds<float3>> bounds = BKE_object_boundbox_get(ob_eval);
    if (!bounds) {
      continue;
    }
    const float4x4 &matrix = ob_eval->object_to_world();
    for (int i = 0; i < 8; i++) {
      const float3 corner((i & 1) ? bounds->max.x : bounds->min.x,
                          (i & 2) ? bounds->max.y : bounds->min.y,
                          (i & 4) ? bounds->max.z : bounds->min.z);
      const float3 world = math::transform_point(matrix, corner);
      min = math::min(min, world);
      max = math::max(max, world);
    }
    found = true;
  }
  if (!found) {
    return nullptr;
  }

  /* Frame the bounds from the view's angle; restore the view afterwards. */
  const float3 ofs_old(rv3d->ofs);
  const float dist_old = rv3d->dist;
  const char persp_old = rv3d->persp;
  const short flag2_old = v3d->flag2;
  if (rv3d->persp == RV3D_CAMOB) {
    rv3d->persp = RV3D_PERSP;
  }
  const float radius = math::max(math::distance(min, max) / 2.0f, 0.01f);
  copy_v3_v3(rv3d->ofs, -math::midpoint(min, max));
  rv3d->dist = ED_view3d_radius_to_dist(v3d, region, depsgraph, rv3d->persp, false, radius * 1.1f);
  /* Just the scene, without the grid, outlines and other overlays. */
  v3d->flag2 |= V3D_HIDE_OVERLAYS;
  const eDrawType drawtype = v3d->shading.type == OB_RENDER ? OB_MATERIAL :
                                                              eDrawType(v3d->shading.type);
  ImBuf *ibuf = ED_view3d_draw_offscreen_imbuf(depsgraph,
                                               scene,
                                               drawtype,
                                               v3d,
                                               region,
                                               PREVIEW_RENDER_LARGE_HEIGHT * 2,
                                               PREVIEW_RENDER_LARGE_HEIGHT * 2,
                                               IB_byte_data,
                                               R_ALPHAPREMUL,
                                               nullptr,
                                               true,
                                               nullptr,
                                               nullptr,
                                               false,
                                               err_out);
  v3d->flag2 = flag2_old;
  copy_v3_v3(rv3d->ofs, ofs_old);
  rv3d->dist = dist_old;
  rv3d->persp = persp_old;
  return ibuf;
}

/**
 * iOS may purge temporary files and ends apps in the background without warning. Keep auto-saves
 * where they survive, one per document rather than per process, so work continues on the next
 * launch. The name carries a hash of the document's full path, as two documents in different
 * folders can share a name.
 */
bool wm_apple_ios_autosave_location(const char *blendfile_path, char filepath[FILE_MAX])
{
  const std::optional<std::string> folder = BKE_appdir_folder_id_create(BLENDER_USER_DATAFILES,
                                                                        "autosave");
  if (!folder) {
    return false;
  }
  char filename[FILE_MAX];
  if (blendfile_path && (blendfile_path[0] != '\0')) {
    /* Inside the app's own folder, of the path within it: the folder moves when the app is
     * updated or reinstalled, and its name changes with it. */
    const char *hashed = blendfile_path;
    if (const char *home = BLI_getenv("HOME")) {
      const char *container = BLI_path_basename(home);
      if (container[0] != '\0') {
        if (const char *inside = strstr(blendfile_path, container)) {
          hashed = inside + strlen(container);
        }
      }
    }
    uint32_t hash = 2166136261u; /* FNV-1a: stable across launches and app versions. */
    for (const char *c = hashed; *c; c++) {
      hash = (hash ^ uint8_t(*c)) * 16777619u;
    }
    const char *basename = BLI_path_basename(blendfile_path);
    SNPRINTF(filename, "%.*s_%08x_autosave.blend", int(strlen(basename)) - 6, basename, hash);
  }
  else {
    STRNCPY(filename, "untitled_autosave.blend");
  }
  BLI_path_join(filepath, FILE_MAX, folder->c_str(), filename);
  return true;
}

void wm_apple_ios_autosave_remove(const char *blendfile_path)
{
  char filepath[FILE_MAX];
  if (wm_apple_ios_autosave_location(blendfile_path, filepath) && BLI_exists(filepath)) {
    BLI_delete(filepath, false, false);
  }
}

bool wm_apple_ios_autosave_newer(const char *filepath, char r_autosave[FILE_MAX])
{
  BLI_stat_t autosave_stat, file_stat;
  return wm_apple_ios_autosave_location(filepath, r_autosave) &&
         BLI_stat(r_autosave, &autosave_stat) == 0 && BLI_stat(filepath, &file_stat) == 0 &&
         autosave_stat.st_mtime > file_stat.st_mtime;
}

bool wm_apple_ios_file_write(bContext *C,
                             char *filepath,
                             const int fileflags,
                             const eBLO_WritePathRemap remap_mode,
                             const bool use_save_as_copy,
                             ReportList *reports)
{
  /* Saving where iOS may be syncing or providing the file, such as iCloud Drive, goes through
   * file coordination, which can hand back another path to write to. */
  struct Write {
    bContext *C;
    int flags;
    eBLO_WritePathRemap remap;
    bool copy;
    ReportList *reports;
    char *filepath;
    bool success = false;
  } write{C, fileflags, remap_mode, use_save_as_copy, reports, filepath};
  char coordination_error[1024] = {};
  const bool coordinated = GHOST_ios_document_coordinate(
      filepath,
      true,
      [](void *data, const char *path) {
        auto &write = *static_cast<Write *>(data);
        BLI_strncpy(write.filepath, path, FILE_MAX);
        write.success = wm_file_write(
            write.C, path, write.flags, write.remap, write.copy, write.reports);
      },
      &write,
      coordination_error,
      sizeof(coordination_error));
  if (!coordinated) {
    BKE_report(reports, RPT_ERROR, coordination_error);
  }
  return write.success;
}

/** Auto-saves of documents left alone for a month are not worth keeping. */
static void wm_autosave_prune()
{
  const std::optional<std::string> folder = BKE_appdir_folder_id(BLENDER_USER_DATAFILES,
                                                                 "autosave");
  if (!folder) {
    return;
  }
  direntry *entries = nullptr;
  const uint count = BLI_filelist_dir_contents(folder->c_str(), &entries);
  const int64_t month_ago = int64_t(time(nullptr)) - 30 * 24 * 60 * 60;
  for (uint i = 0; i < count; i++) {
    if (!S_ISDIR(entries[i].type) && StringRef(entries[i].relname).endswith("_autosave.blend") &&
        entries[i].s.st_mtime < month_ago)
    {
      BLI_delete(entries[i].path, false, false);
    }
  }
  BLI_filelist_free(entries, count);
}

void WM_apple_ios_autosave_ensure()
{
  /* iOS ends apps without warning, so auto-save is always on. */
  U.flag |= USER_AUTOSAVE;
  if (U.savetime <= 0) {
    U.savetime = 2;
  }
  wm_autosave_prune();
}

void WM_apple_ios_autosave_now(bContext *C)
{
  /* Unlike the timer, write in any mode: this may be the last chance before iOS ends the app. */
  wmWindowManager *wm = CTX_wm_manager(C);
  Main *bmain = CTX_data_main(C);
  /* A recovered document has unsaved work even before it is edited again. */
  if (wm == nullptr || bmain == nullptr || (wm->file_saved && !bmain->recovered)) {
    return;
  }
  WM_autosave_write(wm, bmain);
}

/**
 * Run an operator on the first window, as when the system opens a file, see
 * #GHOST_kEventOpenMainFile. Documents are opened and created from outside Blender's event loop.
 */
static bool wm_document_operator(bContext *C,
                                 const char *idname,
                                 PointerRNA *props,
                                 ReportList *reports)
{
  wmWindowManager *wm = CTX_wm_manager(C);
  wmWindow *win = wm ? static_cast<wmWindow *>(wm->windows.first) : nullptr;
  if (win == nullptr) {
    return false;
  }
  wmWindow *win_prev = CTX_wm_window(C);
  CTX_wm_window_set(C, win);
  /* Its reports kept, so what Blender says about a file it could not open reaches the person
   * (ROUND6 SAFE-2). */
  const wmOperatorStatus status = WM_operator_call_py(
      C, WM_operatortype_find(idname, false), wm::OpCallContext::ExecDefault, props, reports, false);
  CTX_wm_window_set(C, win_prev);
  return status & OPERATOR_FINISHED;
}

/**
 * The Blender version that wrote the file at \a filepath, from its header (compressed or not),
 * or 0. For a document that continued from its auto-save, which this Blender wrote: the file's
 * own version is what decides whether it may be written over.
 */
static int blend_file_version(const char *filepath)
{
  const int filedes = BLI_open(filepath, O_BINARY | O_RDONLY, 0);
  if (filedes == -1) {
    return 0;
  }
  FileReader *file = BLO_file_reader_uncompressed_from_descriptor(filedes);
  if (file == nullptr) {
    return 0;
  }
  const BlenderHeaderVariant header = BLO_readfile_blender_header_decode(file);
  file->close(file);
  if (const BlenderHeader *blender = std::get_if<BlenderHeader>(&header)) {
    return blender->file_version;
  }
  return 0;
}

/**
 * Why the open document must not be written before the person answers (ROUND6 SAFE-2, decision
 * R6-2): each of what Blender's Save asks about before overwriting, see
 * #BKE_main_needs_overwrite_confirm, which the document's direct write never runs. A flag added
 * there needs its words here (`tests/ios/test_document_safety.py`).
 */
static void document_hold(const Main *bmain, const char *filepath, wmDocumentOpened &r_opened)
{
  std::vector<std::string> titles, reasons;
  /* A document that continued from its auto-save was loaded from a file this Blender wrote: the
   * document's own file says whether it came from a newer Blender. */
  int writer_version = bmain->versionfile;
  int writer_subversion = bmain->subversionfile;
  bool newer = bmain->has_forward_compatibility_issues;
  if (r_opened.recovered) {
    const int file_version = blend_file_version(filepath);
    if (file_version > BLENDER_FILE_VERSION) {
      newer = true;
      writer_version = file_version;
      writer_subversion = -1;
    }
  }
  if (newer) {
    char version[16];
    BKE_blender_version_blendfile_string_from_values(
        version,
        sizeof(version),
        short(writer_version),
        short(writer_version == BLENDER_FILE_VERSION ? writer_subversion : -1));
    titles.push_back(fmt::format("Saved by a newer Blender ({})", version));
    reasons.push_back(
        fmt::format("This file was saved by a newer Blender ({}). Saving it here can lose what "
                    "this version does not know.",
                    version));
  }
  if (bmain->is_asset_edit_file) {
    titles.push_back("Managed by the asset system");
    reasons.push_back(
        "This file is managed by Blender's asset system. It can only be saved as a new, regular "
        "file.");
    r_opened.hold_copy_only = true;
  }
  if (bmain->colorspace.is_missing_opencolorio_config) {
    titles.push_back("Color spaces changed");
    reasons.push_back(
        "Displays, views or color spaces in this file were missing and have been changed. Saving "
        "it here can lose them.");
  }
  if (titles.empty()) {
    return;
  }
  r_opened.hold_title = titles.front();
  for (const std::string &reason : reasons) {
    r_opened.hold_reason += (r_opened.hold_reason.empty() ? "" : "\n\n") + reason;
  }
}

/**
 * What the open document loaded, by #WM_file_read_count once its open finished, and the file it
 * opened (ROUND5 9D.1, decision 62). Blender may load another file afterwards, in many ways: a
 * script, an add-on, a command the front door does not know. The document then refuses to write,
 * as writing would replace it with that other file. Compared by the count rather than by path:
 * a document opens from its own path, from iCloud through a coordinated read or from its newer
 * auto-save, and each of these loads one file the same way.
 */
static uint64_t document_read = UINT64_MAX;
static std::string document_path;

bool WM_apple_ios_document_is_loaded()
{
  return document_read != UINT64_MAX && document_read == WM_file_read_count();
}

bool WM_apple_ios_document_open(bContext *C,
                                const char *filepath,
                                const bool template_document,
                                wmDocumentOpened &r_opened)
{
  r_opened = {};
  /* A document that failed to open has loaded nothing of its own. */
  document_read = UINT64_MAX;
  document_path.clear();
  PointerRNA props = WM_operator_properties_create("WM_OT_open_mainfile");
  RNA_string_set(&props, "filepath", filepath);
  RNA_boolean_set(&props, "display_file_selector", false);
  if (template_document) {
    RNA_boolean_set(&props, "use_scripts", false);
  }
  ReportList reports;
  BKE_reports_init(&reports, RPT_STORE);
  const bool success = wm_document_operator(C, "WM_OT_open_mainfile", &props, &reports);
  WM_operator_properties_free(&props);
  if (!success) {
    /* Blender's own words, for the launcher to show (ROUND6 SAFE-2, F5). */
    std::string error;
    for (const Report &report : reports.list) {
      if (report.type >= RPT_ERROR && report.message && report.message[0]) {
        error = report.message;
        break;
      }
    }
    r_opened.error = error.empty() ? std::string("Blender could not read this file.") : error;
  }
  else {
    /* What a file loaded with warnings says, as Blender's status bar would. */
    for (const Report &report : reports.list) {
      if (report.type >= RPT_WARNING && report.message) {
        WM_native_ui_session_log("document", fmt::format("open: {}", report.message).c_str());
      }
    }
  }
  /* Shown as Blender shows an operator's reports. */
  if (wmWindowManager *wm = CTX_wm_manager(C)) {
    WM_reports_from_reports_move(wm, &reports);
  }
  BKE_reports_free(&reports);
  /* Opening continues from the auto-save when it is newer, see #wm_apple_ios_autosave_newer. */
  r_opened.recovered = success && CTX_data_main(C)->recovered;
  if (success) {
    document_read = WM_file_read_count();
    document_path = filepath;
    document_hold(CTX_data_main(C), filepath, r_opened);
  }
  WM_native_ui_session_log(
      "document",
      fmt::format("{} {}{}{}",
                  success ? "opened" : "could not open",
                  BLI_path_basename(filepath),
                  r_opened.recovered ? " (from its newer auto-save)" : "",
                  success ? (r_opened.hold_title.empty() ? "" : ", held: " + r_opened.hold_title) :
                            ": " + r_opened.error)
          .c_str());
  return success;
}

/**
 * The reason Blender gave for a write it could not make: its first error, else its first warning.
 * Blender's own words, which the document shows; never dropped unread (ROUND6 SAFE-1).
 */
static std::string write_reason(const ReportList &reports)
{
  std::string warning;
  for (const Report &report : reports.list) {
    if (report.type >= RPT_ERROR && report.message && report.message[0]) {
      return report.message;
    }
    if (report.type >= RPT_WARNING && warning.empty() && report.message) {
      warning = report.message;
    }
  }
  return warning.empty() ? std::string(RPT_("Blender could not write the file.")) : warning;
}

/**
 * Write the open file for a document, with its preview: in the window, as saving from Blender
 * does, which a preview of the 3D View or the scene's camera needs. `r_error`: why it was not
 * written, in Blender's words.
 */
static bool wm_document_write(bContext *C,
                              const char *filepath,
                              const bool preview,
                              std::string &r_error)
{
  wmWindowManager *wm = CTX_wm_manager(C);
  wmWindow *win = wm ? static_cast<wmWindow *>(wm->windows.first) : nullptr;
  wmWindow *win_prev = CTX_wm_window(C);
  if (win) {
    CTX_wm_window_set(C, win);
    /* Saving from Blender happens while its window is the drawing target, which the preview's
     * drawing relies on. iOS asks between frames, when something else may draw, such as the
     * native interface's previews: make the window the target again. */
    if (preview && win->runtime->ghostwin) {
      wm_window_clear_drawable(wm);
      wm_window_make_drawable(wm, win);
    }
  }
  /* Painted images are kept in the document, as Pack does: it saves itself, with no moment to
   * save them on their own, and their pixels would otherwise be lost. */
  for (Image &image : CTX_data_main(C)->images) {
    if (!ID_IS_LINKED(&image) && ELEM(image.source, IMA_SRC_FILE, IMA_SRC_GENERATED, IMA_SRC_TILED) &&
        BKE_image_is_dirty(&image))
    {
      BKE_image_memorypack(&image);
    }
  }
  ReportList reports;
  BKE_reports_init(&reports, RPT_STORE);
  const char preview_type = U.file_preview_type;
  /* A Frame All view of the scene, see #wm_apple_ios_thumb_frame_all. */
  U.file_preview_type = preview ? USER_FILE_PREVIEW_CAMERA : USER_FILE_PREVIEW_NONE;
  preview_frame_all = true;
  const bool success = wm_file_write(
      C, filepath, G.fileflags, BLO_WRITE_PATH_REMAP_NONE, true, &reports);
  U.file_preview_type = preview_type;
  preview_frame_all = false;
  r_error = success ? std::string() : write_reason(reports);
  BKE_reports_free(&reports);
  CTX_wm_window_set(C, win_prev);
  if (!success) {
    WM_native_ui_session_log(
        "document",
        fmt::format("could not write {}: {}", BLI_path_basename(filepath), r_error).c_str());
  }
  return success;
}

wmDocumentWrite WM_apple_ios_document_write(bContext *C,
                                            const char *filepath,
                                            const bool preview,
                                            const bool when_idle,
                                            std::string &r_error)
{
  r_error.clear();
  /* The backstop (ROUND5 9D.1, decision 62): Blender has loaded another file since the document
   * opened. Writing would replace the document with it, so nothing is written; the document says
   * so and offers to save a copy of what is loaded. */
  if (!WM_apple_ios_document_is_loaded()) {
    WM_native_ui_session_log("document",
                             "write refused: the loaded file is not this document");
    return wmDocumentWrite::Refused;
  }
  /* Saving along the way waits for a stroke or other modal operator to finish, as Blender's
   * auto-save does: its data is not in a state to write until then. */
  if (when_idle) {
    if (wmWindowManager *wm = CTX_wm_manager(C)) {
      for (wmWindow &win : wm->windows) {
        for (wmEventHandler &handler : win.runtime->modalhandlers) {
          if (handler.type == WM_HANDLER_TYPE_OP &&
              reinterpret_cast<wmEventHandler_Op &>(handler).op)
          {
            return wmDocumentWrite::Deferred;
          }
        }
      }
    }
  }
  /* A copy for iOS to move into place: paths stay relative to the document, and the file being
   * replaced keeps no `.blend1` backup, iOS keeps versions of documents itself. */
  if (!wm_document_write(C, filepath, preview, r_error)) {
    return wmDocumentWrite::Failed;
  }
  /* The document is saved, as when saving it in Blender. */
  wm_apple_ios_autosave_remove(BKE_main_blendfile_path_from_global());
  WM_event_add_notifier(C, NC_WM | ND_FILESAVE, nullptr);
  if (wmWindowManager *wm = CTX_wm_manager(C)) {
    wm_autosave_timer_end(wm);
    wm_autosave_timer_begin(wm);
    wm->autosave_scheduled = false;
  }
  return wmDocumentWrite::Written;
}

bool WM_apple_ios_document_copy_write(bContext *C, const char *filepath, std::string &r_error)
{
  const bool success = wm_document_write(C, filepath, true, r_error);
  WM_native_ui_session_log(
      "document",
      fmt::format("{} {}", success ? "copy written" : "copy could not be written",
                  BLI_path_basename(filepath))
          .c_str());
  return success;
}

static const char *document_command_name(const wmDocumentCommand command)
{
  switch (command) {
    case wmDocumentCommand::New:
      return "new";
    case wmDocumentCommand::Open:
      return "open";
    case wmDocumentCommand::Revert:
      return "revert";
    case wmDocumentCommand::Save:
      return "save";
    case wmDocumentCommand::SaveAs:
      return "save as";
    case wmDocumentCommand::Quit:
      return "quit";
  }
  return "?";
}

bool WM_apple_ios_document_command(bContext * /*C*/,
                                   const wmDocumentCommand command,
                                   const char *argument)
{
  if (G.background) {
    return false;
  }
  const std::string value = argument ? argument : "";
  WM_native_ui_session_log("document",
                           fmt::format("route {}{}{}",
                                       document_command_name(command),
                                       value.empty() ? "" : " ",
                                       command == wmDocumentCommand::Open ?
                                           BLI_path_basename(value.c_str()) :
                                           value.c_str())
                               .c_str());
  if (command == wmDocumentCommand::Revert && !document_path.empty()) {
    /* What was saved, not the work since: opening the document would continue from its newer
     * auto-save, see #wm_apple_ios_autosave_newer. */
    wm_apple_ios_autosave_remove(document_path.c_str());
  }
  WM_apple_ios_launcher_document_command(command, value);
  return true;
}

std::string WM_apple_ios_document_check_step(bContext *C, const std::string &step)
{
  std::string answer;
  if (BLI_getenv("PLATYPUS_SCRATCH_DOCUMENT") == nullptr) {
    answer = "refused: not a check launch";
  }
#  ifdef WITH_PYTHON
  else {
    const char *imports[] = {"bpy", nullptr};
    const char *loaded = BLI_path_basename(BKE_main_blendfile_path(CTX_data_main(C)));
    if (step == "marker") {
      /* In the file, as any edit is, and marked edited so the document saves it. */
      const bool set = BPY_run_string_exec(
          C, imports, "bpy.context.scene['satsuma_document_marker'] = 'ROUND5 9D'");
      WM_file_tag_modified();
      answer = fmt::format("marker {} in {}", set ? "set" : "not set", loaded);
    }
    else if (step == "check") {
      intptr_t present = 0;
      const bool asked = BPY_run_string_as_intptr(
          C,
          imports,
          "int(any(scene.get('satsuma_document_marker') == 'ROUND5 9D' for scene in bpy.data.scenes))",
          nullptr,
          &present);
      answer = fmt::format("marker {} in {} ({} the document's own file)",
                           !asked ? "unknown" : present ? "present" : "missing",
                           loaded[0] ? loaded : "an unsaved file",
                           WM_apple_ios_document_is_loaded() ? "is" : "is not");
    }
    else if (StringRef(step).startswith("python ")) {
      const std::string code = step.substr(7);
      const bool ran = BPY_run_string_exec(C, imports, code.c_str());
      answer = fmt::format("python {}: {}", ran ? "ran" : "failed", code);
    }
    else {
      answer = "unknown step: " + step;
    }
  }
#  else
  else {
    UNUSED_VARS(C, step);
    answer = "needs Python";
  }
#  endif
  WM_native_ui_session_log("document", answer.c_str());
  return answer;
}

std::string WM_apple_ios_document_template_write(bContext *C,
                                                 const char *filepath,
                                                 const char *preview,
                                                 std::string &attribution)
{
#  ifdef WITH_PYTHON
  const char *imports[] = {"bpy", "bl_ui", "bl_ui.native_templates", nullptr};
  char *error = nullptr;
  if (!BPY_run_string_as_string(
          C, imports, "bl_ui.native_templates.export_error()", nullptr, &error))
  {
    return "Could not validate the template's resources.";
  }
  const std::string message = error ? error : "";
  if (error) {
    MEM_delete(error);
  }
  if (!message.empty()) {
    return message;
  }
  char *credit = nullptr;
  if (!BPY_run_string_as_string(
          C, imports, "bl_ui.native_templates.attribution_json()", nullptr, &credit))
  {
    return "Could not preserve the template's asset attribution.";
  }
  attribution = credit ? credit : "{}";
  if (credit) {
    MEM_delete(credit);
  }
  /* Save a copy without acknowledging or clearing the open document's unsaved work. */
  std::string write_error;
  if (!wm_document_write(C, filepath, true, write_error)) {
    return "Could not save the template: " + write_error;
  }
  ImBuf *image = IMB_thumb_manage(filepath, THB_LARGE, THB_SOURCE_BLEND);
  if (!image) {
    return "Could not create the template preview.";
  }
  image->ftype = IMB_FTYPE_PNG;
  const bool saved = IMB_save_image(image, preview, IB_byte_data);
  IMB_freeImBuf(image);
  return saved ? "" : "Could not save the template preview.";
#  else
  return "Template export requires Python support.";
#  endif
}

}  // namespace blender

#endif
