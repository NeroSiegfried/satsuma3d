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
#  include <os/proc.h>
#  include <sys/sysctl.h>
#  include <ctime>
#  include <fmt/format.h>
#  include <optional>
#  include <set>
#  include <unistd.h>
#  include <variant>
#  include <vector>
#  include <string>

#  include "BKE_appdir.hh"
#  include "BKE_blender_version.h"
#  include "BKE_bpath.hh"
#  include "BKE_cachefile.hh"
#  include "BKE_library.hh"
#  include "BKE_movieclip.hh"
#  include "BKE_vfont.hh"
#  include "BKE_volume.hh"
#  include "DEG_depsgraph.hh"
#  include "DNA_cachefile_types.h"
#  include "DNA_curve_types.h"
#  include "DNA_movieclip_types.h"
#  include "DNA_sequence_types.h"
#  include "DNA_vfont_types.h"
#  include "DNA_volume_types.h"
#  include "BKE_context.hh"
#  include "BKE_global.hh"
#  include "BKE_image.hh"
#  include "BKE_layer.hh"
#  include "BKE_main.hh"
#  include "BKE_object.hh"
#  include "BKE_report.hh"
#  include "BKE_undo_system.hh"
#  include "BLI_fileops.h"
#  include "BLI_fileops_types.h"
#  include "BLI_filereader.h"
#  include "BLI_listbase.h"
#  include "BLI_listbase_iterator.hh"
#  include "BLI_math_matrix.hh"
#  include "BLI_math_vector.h"
#  include "BLI_math_vector.hh"
#  include "BLI_memory_cache.hh"
#  include "BLI_path_utils.hh"
#  include "BLI_string.h"
#  include "BLI_string_ref.hh"
#  include "BLI_time.h"
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
#  include "SEQ_relations.hh"
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
#  include "wm_apple_ios_memory.hh"
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

/**
 * Beside each auto-save, the size and date the document's file had when it was written (ROUND6
 * SAFE-5): an auto-save belongs to that file only, not to another file put at the same path.
 */
static std::string autosave_source_path(const char *autosave)
{
  return std::string(autosave) + ".source";
}

void wm_apple_ios_autosave_written(const char *blendfile_path, const char *autosave)
{
  BLI_stat_t file_stat;
  FILE *file = BLI_fopen(autosave_source_path(autosave).c_str(), "w");
  if (file == nullptr) {
    return;
  }
  if (blendfile_path && blendfile_path[0] && BLI_stat(blendfile_path, &file_stat) == 0) {
    fprintf(file, "%lld %lld\n", (long long)file_stat.st_size, (long long)file_stat.st_mtime);
  }
  fclose(file);
}

void wm_apple_ios_autosave_remove(const char *blendfile_path)
{
  char filepath[FILE_MAX];
  if (wm_apple_ios_autosave_location(blendfile_path, filepath) && BLI_exists(filepath)) {
    BLI_delete(filepath, false, false);
  }
  BLI_delete(autosave_source_path(filepath).c_str(), false, false);
}

bool wm_apple_ios_autosave_set_aside(const char *blendfile_path, const char *why)
{
  char autosave[FILE_MAX];
  if (!wm_apple_ios_autosave_location(blendfile_path, autosave) || !BLI_exists(autosave)) {
    return false;
  }
  /* Renamed, not deleted: listed by the documents as Recovered Work, and no longer continued
   * from when the document opens (ROUND6 SAFE-5, decision R6-4). */
  const std::time_t now = std::time(nullptr);
  std::tm local = {};
  localtime_r(&now, &local);
  char stamp[32];
  std::strftime(stamp, sizeof(stamp), "%Y%m%d-%H%M%S", &local);
  std::string aside(autosave);
  aside.replace(aside.size() - strlen("_autosave.blend"),
                strlen("_autosave.blend"),
                std::string("_recovered_") + stamp + ".blend");
  const bool moved = BLI_rename_overwrite(autosave, aside.c_str()) == 0;
  BLI_delete(autosave_source_path(autosave).c_str(), false, false);
  WM_native_ui_session_log(
      "document",
      fmt::format("auto-save {} ({}): {}", moved ? "set aside" : "could not be set aside", why,
                  BLI_path_basename(aside.c_str()))
          .c_str());
  return moved;
}

bool wm_apple_ios_autosave_newer(const char *filepath, char r_autosave[FILE_MAX])
{
  BLI_stat_t autosave_stat, file_stat;
  if (!(wm_apple_ios_autosave_location(filepath, r_autosave) &&
        BLI_stat(r_autosave, &autosave_stat) == 0 && BLI_stat(filepath, &file_stat) == 0 &&
        autosave_stat.st_mtime > file_stat.st_mtime))
  {
    return false;
  }
  /* The file it was written beside must still be there, unchanged: a file put at the same path
   * since (restored on a Mac, replaced in Files) is not overwritten with an old auto-save. */
  if (FILE *source = BLI_fopen(autosave_source_path(r_autosave).c_str(), "r")) {
    long long size = -1, mtime = -1;
    const int read = fscanf(source, "%lld %lld", &size, &mtime);
    fclose(source);
    if (read == 2 && (size != (long long)file_stat.st_size || mtime != (long long)file_stat.st_mtime))
    {
      wm_apple_ios_autosave_set_aside(filepath, "the file was replaced since it was written");
      return false;
    }
  }
  return true;
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

/** Auto-saves of documents left alone for a month are not worth keeping, nor recovered work set
 * aside a month ago; each is named in the log. */
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
    const StringRef name = entries[i].relname;
    if (!S_ISDIR(entries[i].type) &&
        (name.endswith("_autosave.blend") || name.find("_recovered_") != StringRef::not_found) &&
        name.endswith(".blend") && entries[i].s.st_mtime < month_ago)
    {
      BLI_delete(entries[i].path, false, false);
      BLI_delete(autosave_source_path(entries[i].path).c_str(), false, false);
      WM_native_ui_session_log("document",
                               fmt::format("auto-save older than 30 days removed: {}",
                                           entries[i].relname)
                                   .c_str());
    }
  }
  BLI_filelist_free(entries, count);
}

/**
 * What the app keeps for a while and never needs again (ROUND6 FILES-9, finding F15): Blender's
 * session folders of earlier launches, which only a clean exit removes and iOS does not give one;
 * the app's own temporary copies once their day is over (drops, packed at the next write; fresh
 * copies for Share; images opened in the Image Editor, packed; add-ons being installed). The
 * current session's folder is never touched.
 */
static void wm_temp_prune()
{
  const char *base = BKE_tempdir_base();
  const char *session = BKE_tempdir_session();
  if (!base || !base[0]) {
    return;
  }
  direntry *entries = nullptr;
  const uint count = BLI_filelist_dir_contents(base, &entries);
  const int64_t day_ago = int64_t(time(nullptr)) - 24 * 60 * 60;
  int sessions = 0, copies = 0;
  for (uint i = 0; i < count; i++) {
    const StringRef name = entries[i].relname;
    if (!S_ISDIR(entries[i].type) || ELEM(name, ".", "..")) {
      continue;
    }
    char path[FILE_MAX];
    STRNCPY(path, entries[i].path);
    BLI_path_slash_ensure(path, sizeof(path));
    if (session && BLI_path_cmp(path, session) == 0) {
      continue;
    }
    if (name.startswith("blender_")) {
      BLI_delete(entries[i].path, true, true);
      sessions++;
      continue;
    }
    const bool app_copy = ELEM(name, "Dropped", "OpenedImages", "addon-install") ||
                          name.startswith("save-copy-");
    if (!app_copy) {
      continue;
    }
    /* Inside the app's own folders, only what has not changed for a day. */
    if (name.startswith("save-copy-")) {
      if (entries[i].s.st_mtime < day_ago) {
        BLI_delete(entries[i].path, true, true);
        copies++;
      }
      continue;
    }
    direntry *items = nullptr;
    const uint item_count = BLI_filelist_dir_contents(entries[i].path, &items);
    for (uint j = 0; j < item_count; j++) {
      if (!ELEM(StringRef(items[j].relname), ".", "..") && items[j].s.st_mtime < day_ago) {
        BLI_delete(items[j].path, S_ISDIR(items[j].type), true);
        copies++;
      }
    }
    BLI_filelist_free(items, item_count);
  }
  BLI_filelist_free(entries, count);
  if (sessions || copies) {
    WM_native_ui_session_log(
        "document",
        fmt::format("temporary files: {} earlier sessions' folders and {} old copies removed",
                    sessions,
                    copies)
            .c_str());
  }
}

void WM_apple_ios_autosave_ensure()
{
  wm_temp_prune();
  /* iOS ends apps without warning, so auto-save is always on. */
  U.flag |= USER_AUTOSAVE;
  if (U.savetime <= 0) {
    U.savetime = 2;
  }
  wm_autosave_prune();
}

void WM_apple_ios_memory_defaults()
{
  uint64_t physical = 0;
  size_t size = sizeof(physical);
  if (sysctlbyname("hw.memsize", &physical, &size, nullptr, 0) != 0) {
    physical = 0;
  }
  const uint64_t available = os_proc_available_memory();
  const wm::apple_ios::MemoryCaps caps = wm::apple_ios::memory_caps(available, physical);
  const int undo = U.undomemory, cache = U.memcachelimit, texture = U.glreslimit;
  int texture_limit = U.glreslimit; /* A `short` in the preferences. */
  wm::apple_ios::memory_caps_apply(caps, U.undomemory, U.memcachelimit, texture_limit);
  U.glreslimit = short(texture_limit);
  WM_native_ui_session_log(
      "memory",
      fmt::format("start-up: {} MB available of {} MB; undo memory {} MB (was {}), cache {} MB "
                  "(was {}), texture limit {} (was {})",
                  available / (1024 * 1024),
                  physical / (1024 * 1024),
                  U.undomemory,
                  undo,
                  U.memcachelimit,
                  cache,
                  U.glreslimit,
                  texture)
          .c_str());
}

void WM_apple_ios_memory_low(bContext *C)
{
  wmWindowManager *wm = CTX_wm_manager(C);
  Main *bmain = CTX_data_main(C);
  if (wm == nullptr || bmain == nullptr) {
    return;
  }
  /* The warning and the pressure source often come together: once is enough. */
  static double last = -100.0;
  const double now = BLI_time_now_seconds();
  if (now - last < 10.0) {
    return;
  }
  last = now;
  /* What is not saved is kept first: iOS may end the app next. */
  const bool kept = WM_apple_ios_autosave_now(C);

  /* Caches, which fill again as they are needed: the buffers of images read from files and not
   * changed since, the sequencer's frames, the movie cache and the generic memory cache. Not
   * while a job runs, which may be reading them (a render's textures). */
  int images = 0;
  const bool job_running = WM_jobs_has_running(wm);
  if (!job_running) {
    for (Image &image : bmain->images) {
      if (image.type == IMA_TYPE_IMAGE && image.source != IMA_SRC_GENERATED &&
          !BKE_image_is_dirty(&image))
      {
        BKE_image_free_buffers(&image);
        images++;
      }
    }
    for (Scene &scene : bmain->scenes) {
      if (scene.ed) {
        seq::cache_cleanup(&scene, seq::CacheCleanup::All);
      }
    }
    memory_cache::clear();
  }

  /* The older half of the undo steps; the newest stay, so the last changes can still be undone. */
  int steps_kept = -1;
  if (UndoStack *ustack = wm->runtime->undo_stack) {
    steps_kept = std::max(1, BLI_listbase_count(&ustack->steps) / 2);
    BKE_undosys_stack_limit_steps_and_memory(ustack, steps_kept, 0);
  }
  WM_native_ui_session_log(
      "memory",
      fmt::format("low: auto-save {}; {}; undo kept to {} steps",
                  kept ? "written" : "NOT written",
                  job_running ? std::string("caches kept while a job runs") :
                                fmt::format("{} images' buffers and the caches freed", images),
                  steps_kept)
          .c_str());

  /* Said once a session: after that it would only nag. */
  static bool told = false;
  if (!told) {
    told = true;
    WM_native_ui_notice(RPT_WARNING, IFACE_("Memory is low. Save your work."));
  }
}

bool wm_apple_ios_autosave_write(wmWindowManager *wm,
                                 Main *bmain,
                                 const char *what,
                                 const char *consequence)
{
  /* The cause last told by a background writer, so a timer failing every interval is said once,
   * not every time. */
  static std::string told;
  if (WM_autosave_write(wm, bmain, &wm->runtime->reports)) {
    told.clear();
    return true;
  }
  const Report *report = BKE_reports_last_displayable(&wm->runtime->reports);
  const std::string why = (report && report->message) ? report->message :
                                                        "the auto-save could not be written";
  WM_native_ui_session_log("document",
                           fmt::format("auto-save not written ({}): {}", what, why).c_str());
  const std::string notice = fmt::format("{} ({})", consequence, why);
  /* The background writers (the timer, the last chance before iOS ends the app) say a cause once:
   * every interval would only nag. A person's command (Revert, Open as Last Saved, Restore Version
   * from Opening, Reload with Scripts) that stops says so every time, or a second press would do
   * nothing silently (ROUND7 U4e, seen on the device). */
  const bool background = STREQ(what, "timer") || STREQ(what, "last chance");
  if (!background || notice != told) {
    if (background) {
      told = notice;
    }
    WM_native_ui_notice(RPT_ERROR, notice.c_str());
  }
  return false;
}

bool WM_apple_ios_autosave_now(bContext *C)
{
  /* Unlike the timer, write in any mode: this may be the last chance before iOS ends the app. */
  wmWindowManager *wm = CTX_wm_manager(C);
  Main *bmain = CTX_data_main(C);
  /* A recovered document has unsaved work even before it is edited again. */
  if (wm == nullptr || bmain == nullptr || (wm->file_saved && !bmain->recovered)) {
    return true;
  }
  return wm_apple_ios_autosave_write(
      wm, bmain, "last chance", "Your changes could not be kept in case the app is ended. Save now");
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
/** Files brought in from outside the document's folder, packed (ROUND6 FILES-5). */
int WM_apple_ios_document_pack_brought_in(bContext *C);
/** Files beside the document that cannot be read, see below (ROUND6 FILES-3). */
std::vector<std::string> WM_apple_ios_document_unreadable(Main *bmain, std::string &r_folder);

static uint64_t document_read = UINT64_MAX;
static std::string document_path;
/** The next open of the document runs its scripts: Allow Execution's reload (ROUND6 SAFE-3). */
static bool document_open_with_scripts = false;

bool WM_apple_ios_document_is_loaded()
{
  if (document_read == UINT64_MAX) {
    return false;
  }
  if (document_read == WM_file_read_count()) {
    return true;
  }
  /* Blender read the document's own file again by itself, through an operator's `exec` (a
   * script's `revert_mainfile()`, `open_mainfile()` of the same path): what is loaded is the
   * document's, so it is adopted, not refused as another file (ROUND6 SAFE-3). Another path is
   * still refused. */
  if (!document_path.empty() && G_MAIN &&
      BLI_path_cmp(BKE_main_blendfile_path(G_MAIN), document_path.c_str()) == 0)
  {
    document_read = WM_file_read_count();
    WM_native_ui_session_log("document", "Blender read the document's own file again: adopted");
    return true;
  }
  return false;
}

bool WM_apple_ios_document_set_aside(bContext *C, const char *why)
{
  if (document_path.empty()) {
    return true;
  }
  /* The work as it is now goes into the auto-save first, so what is set aside is all of it. When
   * it cannot be written (no room), nothing is set aside and the caller does not go on: going on
   * would drop the work the person was told is kept (ROUND7 U4d). */
  wmWindowManager *wm = CTX_wm_manager(C);
  Main *bmain = CTX_data_main(C);
  if (wm && bmain && WM_apple_ios_document_is_loaded() && (!wm->file_saved || bmain->recovered) &&
      !wm_apple_ios_autosave_write(wm,
                                   bmain,
                                   why,
                                   "Your changes could not be kept as Recovered Work, so the "
                                   "document was left as it is"))
  {
    return false;
  }
  wm_apple_ios_autosave_set_aside(document_path.c_str(), why);
  return true;
}

void WM_apple_ios_factory_preferences(bContext *C)
{
  WM_native_ui_session_log("launch", "factory preferences, add-ons off, for this session");
  WM_operator_name_call(
      C, "WM_OT_read_factory_userpref", wm::OpCallContext::ExecDefault, nullptr, nullptr);
}

bool WM_apple_ios_document_reload_with_scripts(bContext *C)
{
  if (G.background || document_path.empty() || !WM_apple_ios_document_is_loaded()) {
    return false;
  }
  /* The work since the document was saved, and recovered work, goes into Blender's auto-save
   * first: the reopen continues from it, see #wm_apple_ios_autosave_newer. Reading the file
   * itself, as Blender's own reload does, would drop it. */
  wmWindowManager *wm = CTX_wm_manager(C);
  Main *bmain = CTX_data_main(C);
  if (wm && bmain && (!wm->file_saved || bmain->recovered) &&
      !wm_apple_ios_autosave_write(wm,
                                   bmain,
                                   "reload with scripts",
                                   "Your changes could not be kept first, so the document was not "
                                   "reloaded with scripts"))
  {
    /* Handled: Blender's own reload would read the file and drop the work (ROUND7 U4d). */
    return true;
  }
  document_open_with_scripts = true;
  return WM_apple_ios_document_command(C, wmDocumentCommand::Reload, "");
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
  else if (document_open_with_scripts) {
    RNA_boolean_set(&props, "use_scripts", true);
  }
  document_open_with_scripts = false;
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
    r_opened.error = error.empty() ? std::string("The file could not be read.") : error;
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
  if (r_opened.recovered) {
    char autosave[FILE_MAX];
    BLI_stat_t autosave_stat;
    if (wm_apple_ios_autosave_location(filepath, autosave) && BLI_stat(autosave, &autosave_stat) == 0) {
      r_opened.recovered_time = int64_t(autosave_stat.st_mtime);
    }
  }
  if (success) {
    document_read = WM_file_read_count();
    /* As Blender holds it, to know a later read of the same file, see
     * #WM_apple_ios_document_is_loaded. */
    document_path = BKE_main_blendfile_path(CTX_data_main(C));
    document_hold(CTX_data_main(C), filepath, r_opened);
    /* What it refers to beside itself that cannot be read (ROUND6 FILES-3). */
    r_opened.unreadable = WM_apple_ios_document_unreadable(CTX_data_main(C),
                                                           r_opened.unreadable_folder);
    if (!r_opened.unreadable.empty()) {
      WM_native_ui_session_log(
          "document",
          fmt::format("{} files beside it cannot be read, such as {}",
                      r_opened.unreadable.size(),
                      BLI_path_basename(r_opened.unreadable.front().c_str()))
              .c_str());
    }
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

/* -------------------------------------------------------------------- */
/** \name The files beside a document (ROUND6 FILES-3, finding F8)
 *
 * A document's access covers its one file. What it refers to beside itself, by a relative path
 * or in its folder (textures, linked libraries, caches, movie clips, sequences), cannot be read
 * until the person gives the app its folder, once (a bookmark). These are found as it opens, said
 * once, and read again after the folder is given.
 *
 * Every data-block type whose `IDTypeInfo::foreach_path` lists a path is in this table, with
 * whether a path it lists is a file the document reads, and how it is read again
 * (`tests/ios/test_document_neighbours.py` fails on a type that is not):
 *
 * NEIGHBOURS image: counted; reloaded (`IMA_SIGNAL_RELOAD`)
 * NEIGHBOURS library: counted; reloaded (`WM_lib_reload`)
 * NEIGHBOURS movieclip: counted; reloaded (`BKE_movieclip_reload`)
 * NEIGHBOURS cachefile: counted; reloaded (`BKE_cachefile_reload`)
 * NEIGHBOURS volume: counted; unloaded, read again as it is drawn
 * NEIGHBOURS vfont: counted; its data freed and its text objects evaluated again
 * NEIGHBOURS scene: counted (sequencer strips' media); the strips' images freed, read again
 * NEIGHBOURS sound: not counted: sound is compiled out on the iPad (Audaspace off)
 * NEIGHBOURS camera: not counted: its background images are images and movie clips, above
 * NEIGHBOURS mesh: not counted: external multires data is written by Save External, not read here
 * NEIGHBOURS node: not counted: File Output paths are written, not read; script nodes need OSL,
 * which is off
 * NEIGHBOURS object: not counted: disk caches exist only once baked; the folder's grant serves
 * them, read at each frame
 * NEIGHBOURS text: not counted: a text's content is stored in the document; its path is for
 * Reload and Save only
 * \{ */

static bool neighbour_type_read(const ID *id)
{
  return id && ELEM(GS(id->name), ID_IM, ID_LI, ID_MC, ID_CF, ID_VO, ID_VF, ID_SCE);
}

struct NeighbourScan {
  std::string folder;
  std::string home;
  std::set<std::string> paths;
};

static bool neighbour_scan_path(BPathForeachPathData *bpath_data,
                                char *path_dst,
                                size_t /*path_dst_maxncpy*/,
                                const char *path_src)
{
  NeighbourScan &scan = *static_cast<NeighbourScan *>(bpath_data->user_data);
  if (!neighbour_type_read(bpath_data->owner_id) || !path_src[0]) {
    return false;
  }
  /* The app's own folders are always readable; what is missing there is missing. */
  if (!scan.home.empty() && BLI_path_contains(scan.home.c_str(), path_src)) {
    return false;
  }
  const bool beside = BLI_path_is_rel(path_dst) ||
                      BLI_path_contains(scan.folder.c_str(), path_src);
  if (beside && access(path_src, R_OK) != 0) {
    scan.paths.insert(path_src);
  }
  return false;
}

/** The folder holding both \a a and \a b (each a folder). */
static std::string common_folder(const std::string &a, const std::string &b)
{
  std::string common = a;
  while (!common.empty() && !BLI_path_contains(common.c_str(), b.c_str())) {
    char parent[FILE_MAX];
    STRNCPY(parent, common.c_str());
    if (!BLI_path_parent_dir(parent) || common == parent) {
      return "";
    }
    common = parent;
  }
  return common;
}

std::vector<std::string> WM_apple_ios_document_unreadable(Main *bmain, std::string &r_folder)
{
  r_folder.clear();
  const char *blendfile = BKE_main_blendfile_path(bmain);
  if (!blendfile[0]) {
    return {};
  }
  NeighbourScan scan;
  char folder[FILE_MAX];
  BLI_path_split_dir_part(blendfile, folder, sizeof(folder));
  scan.folder = folder;
  if (const char *home = getenv("HOME")) {
    scan.home = home;
  }
  BPathForeachPathData path_data{};
  path_data.bmain = bmain;
  path_data.callback_function = neighbour_scan_path;
  path_data.flag = BKE_BPATH_FOREACH_PATH_ABSOLUTE | BKE_BPATH_FOREACH_PATH_SKIP_PACKED |
                   BKE_BPATH_FOREACH_PATH_RESOLVE_TOKEN | BKE_BPATH_TRAVERSE_SKIP_WEAK_REFERENCES;
  path_data.user_data = &scan;
  BKE_bpath_foreach_path_main(&path_data);
  /* The folder to ask for holds the document and everything it reaches by "//..". */
  std::string ask = scan.folder;
  for (const std::string &path : scan.paths) {
    char parent[FILE_MAX];
    BLI_path_split_dir_part(path.c_str(), parent, sizeof(parent));
    ask = common_folder(ask, parent);
  }
  r_folder = ask.empty() ? scan.folder : ask;
  return std::vector<std::string>(scan.paths.begin(), scan.paths.end());
}

std::vector<std::string> WM_apple_ios_document_neighbours_reload(
    bContext *C, const std::vector<std::string> &unreadable)
{
  Main *bmain = CTX_data_main(C);
  const std::set<std::string> was(unreadable.begin(), unreadable.end());
  auto listed = [&](const char *path) { return was.count(path) != 0; };
  int reloaded = 0;
  for (Image &image : bmain->images) {
    if (!BKE_image_has_packedfile(&image) &&
        ELEM(image.source, IMA_SRC_FILE, IMA_SRC_SEQUENCE, IMA_SRC_TILED, IMA_SRC_MOVIE))
    {
      BKE_image_signal(bmain, &image, nullptr, IMA_SIGNAL_RELOAD);
      reloaded++;
    }
  }
  std::vector<Library *> libraries;
  for (Library &library : bmain->libraries) {
    if (listed(library.runtime->filepath_abs)) {
      libraries.push_back(&library);
    }
  }
  ReportList reports;
  BKE_reports_init(&reports, RPT_STORE);
  for (Library *library : libraries) {
    WM_lib_reload(library, C, &reports);
    reloaded++;
  }
  BKE_reports_free(&reports);
  for (MovieClip &clip : bmain->movieclips) {
    BKE_movieclip_reload(bmain, &clip);
    reloaded++;
  }
  if (Depsgraph *depsgraph = CTX_data_depsgraph_pointer(C)) {
    for (CacheFile &cache_file : bmain->cachefiles) {
      BKE_cachefile_reload(depsgraph, &cache_file);
      reloaded++;
    }
  }
  for (Volume &volume : bmain->volumes) {
    BKE_volume_unload(&volume);
    DEG_id_tag_update(&volume.id, ID_RECALC_SYNC_TO_EVAL);
    reloaded++;
  }
  std::set<VFont *> fonts;
  for (VFont &vfont : bmain->fonts) {
    if (listed(vfont.filepath) || BLI_path_is_rel(vfont.filepath)) {
      BKE_vfont_data_free(&vfont);
      fonts.insert(&vfont);
    }
  }
  for (Curve &curve : bmain->curves) {
    if (fonts.count(curve.vfont) || fonts.count(curve.vfontb) || fonts.count(curve.vfonti) ||
        fonts.count(curve.vfontbi))
    {
      DEG_id_tag_update(&curve.id, ID_RECALC_GEOMETRY);
      reloaded++;
    }
  }
  for (Scene &scene : bmain->scenes) {
    if (scene.ed) {
      seq::relations_free_imbuf(&scene, &scene.ed->seqbase, false);
      seq::cache_cleanup(&scene, seq::CacheCleanup::All);
    }
  }
  DEG_relations_tag_update(bmain);
  WM_main_add_notifier(NC_WINDOW, nullptr);
  std::string folder;
  std::vector<std::string> remaining = WM_apple_ios_document_unreadable(bmain, folder);
  WM_native_ui_session_log(
      "document",
      fmt::format("neighbours read again: {} of {} still cannot be read ({} data-blocks reloaded)",
                  remaining.size(),
                  unreadable.size(),
                  reloaded)
          .c_str());
  if (remaining.empty()) {
    WM_native_ui_notice(RPT_INFO,
                        fmt::format(fmt::runtime(IFACE_("The {} files beside this document are "
                                                        "read now.")),
                                    unreadable.size())
                            .c_str());
  }
  else {
    WM_native_ui_notice(
        RPT_WARNING,
        fmt::format(fmt::runtime(IFACE_("{} files beside this document still cannot be read, "
                                        "such as “{}”. File › External Data › Report Missing "
                                        "Files lists them.")),
                    remaining.size(),
                    BLI_path_basename(remaining.front().c_str()))
            .c_str());
  }
  return remaining;
}

/** \} */

int WM_apple_ios_document_pack_brought_in(bContext *C)
{
  intptr_t packed = 0;
#  ifdef WITH_PYTHON
  const char *imports[] = {"bl_ui", "bl_ui.native_files", nullptr};
  if (!BPY_run_string_as_intptr(
          C, imports, "len(bl_ui.native_files.pack_brought_in())", nullptr, &packed))
  {
    WM_native_ui_session_log("document", "brought-in files: could not be packed (Python failed)");
    return 0;
  }
  if (packed > 0) {
    WM_native_ui_session_log(
        "document", fmt::format("brought-in files: {} packed into the document", packed).c_str());
  }
#  else
  UNUSED_VARS(C);
#  endif
  return int(packed);
}

std::string WM_apple_ios_document_external(bContext *C)
{
#  ifdef WITH_PYTHON
  const char *imports[] = {"bl_ui", "bl_ui.native_files", nullptr};
  char *summary = nullptr;
  if (BPY_run_string_as_string(
          C, imports, "bl_ui.native_files.external_summary()", nullptr, &summary) &&
      summary)
  {
    std::string result = summary;
    MEM_delete(summary);
    return result;
  }
#  else
  UNUSED_VARS(C);
#  endif
  return "0 0 ";
}

int WM_apple_ios_document_pack_external(bContext *C)
{
  intptr_t packed = 0;
#  ifdef WITH_PYTHON
  const char *imports[] = {"bl_ui", "bl_ui.native_files", nullptr};
  if (BPY_run_string_as_intptr(
          C, imports, "bl_ui.native_files.pack_external()", nullptr, &packed) &&
      packed > 0)
  {
    WM_file_tag_modified();
  }
  WM_native_ui_session_log(
      "document", fmt::format("include external files: {} packed", packed).c_str());
#  else
  UNUSED_VARS(C);
#  endif
  return int(packed);
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
  return warning.empty() ? std::string(RPT_("The file could not be written.")) : warning;
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
  /* One rule for what is brought in (ROUND6 FILES-5, decision R6-14): a file a data-block reads
   * from outside the document's folder (dropped, picked, loaded by a script) is packed into it,
   * so the document never depends on a copy the app keeps or on a grant another device lacks. */
  WM_apple_ios_document_pack_brought_in(C);
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
    case wmDocumentCommand::Reload:
      return "reload with scripts";
    case wmDocumentCommand::Recover:
      return "recovered work";
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
  /* Revert asks first, in the launcher, and then sets the auto-save aside rather than deleting
   * it, see #WM_apple_ios_document_set_aside (ROUND6 SAFE-5). */
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
