/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#if defined(WITH_APPLE_CROSSPLATFORM) && APPLE_TARGET_IOS

#  include "wm_apple_ios_file.hh"
#  include "wm_apple_ios_file_mode.hh"

#  include "BKE_context.hh"
#  include "BKE_file_handler.hh"
#  include "BKE_image.hh"
#  include "IMB_imbuf_types.hh"
#  include "BKE_main.hh"
#  include "BKE_report.hh"
#  include "BLI_listbase.h"
#  include "BKE_screen.hh"
#  include "BLI_path_utils.hh"
#  include "BLI_string.h"
#  include "DNA_space_types.h"
#  include "DNA_windowmanager_types.h"
#  include "GHOST_IOSDocumentPicker.hh"
#  include "GHOST_Mailbox.hh"
#  include "RNA_access.hh"
#  include "BLT_translation.hh"
#  include "WM_api.hh"
#  include "WM_native_ui.hh"
#  include "WM_apple_ios.hh"
#  include "wm_event_system.hh"
#  include "wm_event_types.hh"

#  include <fmt/format.h>
#  include <map>
#  include <string>
#  include <vector>

namespace blender {
namespace {
struct Request {
  wmOperator *op;
  GHOST_IOSDocumentMode mode;
  std::string path;
  wmWindow *window = nullptr;
  /** Its options are being asked for; the picker comes after (ROUND6 FILES-2). */
  bool options = false;
};
struct Result {
  uint64_t id;
  std::vector<std::string> paths;
  std::string error;
};
std::map<uint64_t, Request> requests;
uint64_t next_request = 0;
GHOST_MessageQueue<Result> results;

bool boolean(wmOperator *op, const char *name)
{
  return RNA_struct_find_property(op->ptr, name) && RNA_boolean_get(op->ptr, name);
}

std::string string(wmOperator *op, const char *name)
{
  PropertyRNA *prop = RNA_struct_find_property(op->ptr, name);
  return prop ? RNA_property_string_get(op->ptr, prop) : "";
}

void completed(uint64_t id, const char *const *paths, int count, const char *error)
{
  Result result{id, {}, error ? error : ""};
  for (int i = 0; i < count; i++) {
    result.paths.emplace_back(paths[i]);
  }
  results.push(std::move(result));
}

/**
 * Selectors that browse inside a `.blend` (Link, Append, Relocate) are handed to the native
 * `wm.native_link_append` (`bl_ui/native_files.py`, ROUND6 FILES-4): the system picker for the
 * `.blend`, then a list of its data-blocks, then Blender's own operator. Every operator whose
 * selector browses inside a `.blend` is listed (`script_native_file_modes` fails on one that is
 * not).
 */
const struct {
  const char *idname;
  const char *mode;
} LIBRARY_ROUTES[] = {
    {"WM_OT_link", "LINK"},
    {"WM_OT_append", "APPEND"},
    {"WM_OT_id_linked_relocate", "RELOCATE"},
};
/** Desktop's options those carry, copied over. */
const char *const LIBRARY_OPTIONS[] = {"autoselect",
                                       "active_collection",
                                       "instance_collections",
                                       "instance_object_data",
                                       "do_reuse_local_id",
                                       "clear_asset_data"};

/** A route waiting for the next pass: the original selector is cancelled first, so the native
 * one does not open its selector from inside the original's handler. */
struct LibraryRoute {
  std::string mode;
  std::string filepath;
  std::vector<std::pair<std::string, bool>> options;
  int id_session_uid = 0;
  wmWindow *window = nullptr;
  ScrArea *area = nullptr;
  ARegion *region = nullptr;
};
std::vector<LibraryRoute> library_routes;

/** Puts a picked path in the operator's path properties. A picked folder is its own directory;
 * as a `filepath` (an output path that names a folder) it keeps Blender's trailing separator. */
void set_operator_path(bContext *C, wmOperator *op, const char *path, const bool folder)
{
  char directory[FILE_MAX];
  STRNCPY(directory, path);
  if (!folder) {
    BLI_path_parent_dir(directory);
  }
  BLI_path_slash_ensure(directory, sizeof(directory));
  if (RNA_struct_find_property(op->ptr, "filepath")) {
    char filepath[FILE_MAX];
    STRNCPY(filepath, path);
    if (folder) {
      BLI_path_slash_ensure(filepath, sizeof(filepath));
    }
    if (boolean(op, "relative_path")) {
      BLI_path_rel(filepath, BKE_main_blendfile_path(CTX_data_main(C)));
    }
    RNA_string_set(op->ptr, "filepath", filepath);
  }
  if (RNA_struct_find_property(op->ptr, "directory")) {
    RNA_string_set(op->ptr, "directory", directory);
  }
  if (RNA_struct_find_property(op->ptr, "filename")) {
    RNA_string_set(op->ptr, "filename", folder ? "" : BLI_path_basename(path));
  }
}

bool operator_is_live(bContext *C, const wmOperator *op)
{
  for (wmWindow &win_item : CTX_wm_manager(C)->windows) {
    wmWindow *win = &win_item;
    for (wmEventHandler &base_item : win->runtime->modalhandlers) {
      wmEventHandler *base = &base_item;
      if (base->type == WM_HANDLER_TYPE_OP) {
        auto *handler = reinterpret_cast<wmEventHandler_Op *>(base);
        if (handler->is_fileselect && handler->op == op) {
          return true;
        }
      }
    }
  }
  return false;
}
}  // namespace

namespace {

/** Where the selector starts: the operator's path as it stands, made absolute. */
std::string initial_path(bContext *C, wmOperator *op)
{
  std::string initial = string(op, "filepath");
  if (initial.empty()) {
    char path[FILE_MAX];
    BLI_path_join(
        path, sizeof(path), string(op, "directory").c_str(), string(op, "filename").c_str());
    initial = path;
  }
  if (!initial.empty()) {
    char path[FILE_MAX];
    STRNCPY(path, initial.c_str());
    BLI_path_abs(path, BKE_main_blendfile_path(CTX_data_main(C)));
    initial = path;
  }
  return initial;
}

wm::apple_ios::FileSelectFacts facts_of(wmOperator *op)
{
  wm::apple_ios::FileSelectFacts facts;
  facts.filepath = RNA_struct_find_property(op->ptr, "filepath");
  facts.directory = RNA_struct_find_property(op->ptr, "directory");
  facts.filename = RNA_struct_find_property(op->ptr, "filename");
  facts.files = RNA_struct_find_property(op->ptr, "files");
  facts.has_check_existing = RNA_struct_find_property(op->ptr, "check_existing");
  /* The value the operator's invoke left, as Blender's own browser reads it. */
  facts.check_existing = boolean(op, "check_existing");
  facts.blenlib = boolean(op, "filter_blenlib") ||
                  (RNA_struct_find_property(op->ptr, "filemode") &&
                   RNA_int_get(op->ptr, "filemode") == FILE_LOADLIB);
  /* `buttons.file_browse` sets `check_existing` at invoke exactly when its property is an output
   * path (`PROP_PATH_OUTPUT`): the render output, File Output nodes. */
  facts.output_path = STREQ(op->type->idname, "BUTTONS_OT_file_browse") && facts.check_existing;
  const std::string path = string(op, facts.filepath ? "filepath" : "directory");
  facts.path_is_folder = path.empty() || BLI_path_slash_is_native_compat(path.back());
  facts.name = op->type->name ? op->type->name : "";
  facts.hide_props_region = boolean(op, "hide_props_region");
  /* What Blender's side panel would show (`uiTemplateOperatorPropertyButs` skips hidden ones). */
  RNA_STRUCT_BEGIN (op->ptr, prop) {
    const char *identifier = RNA_property_identifier(prop);
    if ((RNA_property_flag(prop) & PROP_HIDDEN) || STREQ(identifier, "rna_type") ||
        STR_ELEM(identifier, "filepath", "directory", "filename", "files", "relative_path"))
    {
      continue;
    }
    facts.options++;
  }
  RNA_STRUCT_END;
  return facts;
}

/** Show the system picker for request \a id, from the operator's properties as they are now. */
void picker_begin(bContext *C, const uint64_t id)
{
  auto it = requests.find(id);
  if (it == requests.end()) {
    return;
  }
  wmOperator *op = it->second.op;
  wmWindow *win = it->second.window;
  if (!win || BLI_findindex(&CTX_wm_manager(C)->windows, win) == -1 ||
      !win->runtime->ghostwin)
  {
    win = CTX_wm_window(C);
  }
  const std::string initial = initial_path(C, op);
  std::string types;
  const struct {
    const char *property;
    const char *type;
  } filters[] = {
      {"filter_blender", "org.blenderfoundation.blender.file"},
      {"filter_backup", "public.data"},
      {"filter_image", "public.image"},
      {"filter_movie", "public.movie"},
      {"filter_sound", "public.audio"},
      {"filter_font", "public.font"},
      {"filter_text", "public.text"},
      {"filter_python", "public.python-script"},
      {"filter_archive", "public.archive"},
  };
  for (const auto &filter : filters) {
    if (boolean(op, filter.property)) {
      types += std::string(filter.type) + ";";
    }
  }
  const GHOST_IOSDocumentMode mode = it->second.mode;
  if (!win || !GHOST_ios_document_picker_begin(win->runtime->ghostwin,
                                               id,
                                               mode,
                                               op->type->name,
                                               initial.c_str(),
                                               types.c_str(),
                                               string(op, "filter_glob").c_str(),
                                               mode == GHOST_IOSDocumentMode::Open &&
                                                   RNA_struct_find_property(op->ptr, "files"),
                                               completed))
  {
    WM_global_report(RPT_ERROR, "Unable to present the iOS document picker");
    WM_event_fileselect_event(CTX_wm_manager(C), op, EVT_FILESELECT_CANCEL);
  }
}

/** The options were answered: on to the picker, or the selection is cancelled. */
void options_answered(bContext *C, const uint64_t id, const bool confirmed)
{
  auto it = requests.find(id);
  if (it == requests.end()) {
    return; /* The operator went while its options were shown. */
  }
  it->second.options = false;
  wmOperator *op = it->second.op;
  if (!operator_is_live(C, op)) {
    requests.erase(it);
    return;
  }
  if (!confirmed) {
    WM_event_fileselect_event(CTX_wm_manager(C), op, EVT_FILESELECT_CANCEL);
    return;
  }
  /* As the browser does after each change: the name's extension follows the chosen format. */
  if (op->type->check) {
    op->type->check(C, op);
  }
  picker_begin(C, id);
}

}  // namespace

bool WM_apple_ios_fileselect_begin(bContext *C, wmOperator *op)
{
  using namespace wm::apple_ios;
  const FileSelectFacts facts = facts_of(op);
  const FileSelectKind kind = file_select_kind(facts);
  if (kind == FileSelectKind::Browser) {
    return false;
  }
  /* Linking/appending browses data-blocks inside .blend files: handed to the native list. */
  if (kind == FileSelectKind::Library) {
    for (const auto &route : LIBRARY_ROUTES) {
      if (!STREQ(op->type->idname, route.idname)) {
        continue;
      }
      LibraryRoute pending;
      pending.mode = route.mode;
      pending.filepath = string(op, "filepath");
      if (pending.filepath.empty()) {
        pending.filepath = string(op, "directory");
      }
      for (const char *option : LIBRARY_OPTIONS) {
        if (RNA_struct_find_property(op->ptr, option)) {
          pending.options.emplace_back(option, RNA_boolean_get(op->ptr, option));
        }
      }
      if (RNA_struct_find_property(op->ptr, "id_session_uid")) {
        pending.id_session_uid = RNA_int_get(op->ptr, "id_session_uid");
      }
      pending.window = CTX_wm_window(C);
      pending.area = CTX_wm_area(C);
      pending.region = CTX_wm_region(C);
      library_routes.push_back(std::move(pending));
      WM_event_fileselect_event(CTX_wm_manager(C), op, EVT_FILESELECT_CANCEL);
      return true;
    }
    return false;
  }
  const GHOST_IOSDocumentMode mode = kind == FileSelectKind::Directory ?
                                         GHOST_IOSDocumentMode::Directory :
                                     kind == FileSelectKind::Save ? GHOST_IOSDocumentMode::Save :
                                                                    GHOST_IOSDocumentMode::Open;
  const uint64_t id = ++next_request;
  requests.emplace(id, Request{op, mode, "", CTX_wm_window(C), false});
  if (file_select_shows_options(facts)) {
    /* Desktop shows these in the File Browser's side panel; here they come first, in the
     * interface's own dialog, then the picker (ROUND6 FILES-2, finding F6). */
    const std::string title = WM_operatortype_name(op->type, op->ptr);
    const std::string confirm = mode == GHOST_IOSDocumentMode::Save ? IFACE_("Choose Location") :
                                mode == GHOST_IOSDocumentMode::Directory ?
                                                                      IFACE_("Choose Folder") :
                                                                      IFACE_("Choose File");
    auto then = [id](bContext *context, const bool confirmed) {
      options_answered(context, id, confirmed);
    };
    requests[id].options = true;
    if (WM_native_ui_desktop_mode()) {
      WM_apple_ios_options_dialog(C, op, title, confirm, then);
      return true;
    }
    if (ui::native_operator_dialog_handback(C, op, title, confirm, then)) {
      return true;
    }
    /* Another operator's dialog is open: the picker alone, as before. */
    requests[id].options = false;
  }
  picker_begin(C, id);
  return true;
}

bool WM_apple_ios_fileselect_active(wmOperator *op)
{
  for (const auto &item : requests) {
    if (item.second.op == op) {
      return true;
    }
  }
  return false;
}

void WM_apple_ios_fileselect_cancel(wmOperator *op)
{
  for (auto it = requests.begin(); it != requests.end();) {
    if (it->second.op == op) {
      if (it->second.options) {
        ui::native_operator_dialog_abandon(op);
      }
      GHOST_ios_document_picker_cancel(it->first);
      it = requests.erase(it);
    }
    else {
      ++it;
    }
  }
}

void WM_apple_ios_fileselect_flush(bContext *C)
{
  if (!library_routes.empty()) {
    std::vector<LibraryRoute> routes = std::move(library_routes);
    library_routes.clear();
    wmWindowManager *wm = CTX_wm_manager(C);
    for (const LibraryRoute &route : routes) {
      if (!route.window || BLI_findindex(&wm->windows, route.window) == -1) {
        continue;
      }
      wmWindow *previous_window = CTX_wm_window(C);
      ScrArea *previous_area = CTX_wm_area(C);
      ARegion *previous_region = CTX_wm_region(C);
      CTX_wm_window_set(C, route.window);
      bScreen *screen = WM_window_get_active_screen(route.window);
      ScrArea *area = screen && BLI_findindex(&screen->areabase, route.area) != -1 ? route.area :
                                                                                     nullptr;
      CTX_wm_area_set(C, area);
      CTX_wm_region_set(
          C, area && BLI_findindex(&area->regionbase, route.region) != -1 ? route.region : nullptr);
      PointerRNA props = WM_operator_properties_create("WM_OT_native_link_append");
      RNA_enum_set_identifier(C, &props, "mode", route.mode.c_str());
      RNA_string_set(&props, "filepath", route.filepath.c_str());
      for (const auto &[option, value] : route.options) {
        RNA_boolean_set(&props, option.c_str(), value);
      }
      RNA_int_set(&props, "id_session_uid", route.id_session_uid);
      wmOperatorType *ot = WM_operatortype_find("WM_OT_native_link_append", false);
      if (ot) {
        WM_operator_name_call_ptr(C, ot, wm::OpCallContext::InvokeDefault, &props, nullptr);
      }
      else {
        WM_global_report(RPT_ERROR, "Link and Append are not available: their list is missing");
      }
      WM_operator_properties_free(&props);
      CTX_wm_window_set(C, previous_window);
      CTX_wm_area_set(C, previous_area);
      CTX_wm_region_set(C, previous_region);
    }
  }
  auto ready = results.take();
  for (const Result &result : ready) {
    auto it = requests.find(result.id);
    if (it == requests.end()) {
      continue;
    }
    wmOperator *op = it->second.op;
    if (!operator_is_live(C, op)) {
      WM_apple_ios_fileselect_cancel(op);
      continue;
    }
    if (!result.error.empty()) {
      WM_global_report(RPT_ERROR, result.error.c_str());
    }
    if (result.paths.empty() || !result.error.empty()) {
      WM_event_fileselect_event(CTX_wm_manager(C), op, EVT_FILESELECT_CANCEL);
      continue;
    }
    const std::string &path = result.paths.front();
    if (path.size() >= FILE_MAX) {
      WM_global_report(RPT_ERROR, "The selected path is too long");
      WM_event_fileselect_event(CTX_wm_manager(C), op, EVT_FILESELECT_CANCEL);
      continue;
    }
    it->second.path = path;
    set_operator_path(C, op, path.c_str(), it->second.mode == GHOST_IOSDocumentMode::Directory);
    if (PropertyRNA *files = RNA_struct_find_property(op->ptr, "files")) {
      RNA_property_collection_clear(op->ptr, files);
      for (const std::string &selected : result.paths) {
        PointerRNA entry;
        RNA_property_collection_add(op->ptr, files, &entry);
        RNA_string_set(&entry, "name", BLI_path_basename(selected.c_str()));
      }
    }
    WM_event_fileselect_event(CTX_wm_manager(C), op, EVT_FILESELECT_EXEC);
  }
}

wmOperatorStatus WM_apple_ios_fileselect_exec(bContext *C, wmOperator *op)
{
  for (const auto &item : requests) {
    if (item.second.op != op || item.second.path.empty()) {
      continue;
    }
    Request request = item.second; /* Loading a file can invalidate the request map. */
    /* The file-select handler has restored the invoking editor's context here. */
    if (op->type->check) {
      op->type->check(C, op);
    }
    if (RNA_struct_find_property(op->ptr, "filepath")) {
      char checked[FILE_MAX];
      RNA_string_get(op->ptr, "filepath", checked);
      BLI_path_abs(checked, BKE_main_blendfile_path(CTX_data_main(C)));
      request.path = checked;
    }
    /* .blend writes are coordinated in wm_files, including subsequent ordinary Saves. */
    if (request.mode == GHOST_IOSDocumentMode::Save &&
        (STREQ(op->type->idname, "WM_OT_save_mainfile") ||
         STREQ(op->type->idname, "WM_OT_save_as_mainfile")))
    {
      return op->type->exec(C, op);
    }
    struct Execution {
      bContext *C;
      wmOperator *op;
      bool folder;
      wmOperatorStatus status = OPERATOR_CANCELLED;
    } execution{C, op, request.mode == GHOST_IOSDocumentMode::Directory};
    char error[1024] = {};
    const bool ok = GHOST_ios_document_coordinate(
        request.path.c_str(),
        request.mode == GHOST_IOSDocumentMode::Save,
        [](void *data, const char *path) {
          auto &execution = *static_cast<Execution *>(data);
          set_operator_path(execution.C, execution.op, path, execution.folder);
          execution.status = execution.op->type->exec(execution.C, execution.op);
        },
        &execution,
        error,
        sizeof(error));
    if (!ok) {
      BKE_report(op->reports, RPT_ERROR, error);
    }
    if (execution.status & OPERATOR_RUNNING_MODAL) {
      /* Its `exec` handed it on (a dialog of its own, as Link and Append's list does): the
       * selection is over, and the request must not outlive it. */
      for (auto it = requests.begin(); it != requests.end();) {
        it = it->second.op == op ? requests.erase(it) : std::next(it);
      }
    }
    return execution.status;
  }
  return op->type->exec(C, op);
}

/* -------------------------------------------------------------------- */
/** \name Files sent to the app (ROUND6 FILES-8, finding F14)
 *
 * A model or an image opened in the app from Files, the share sheet or AirDrop is imported into
 * the open document, as a drop on its 3D View would be: its file handler's importer, with its
 * options. With no document open it waits for the next one.
 * \{ */

static std::vector<std::string> import_pending;

void WM_apple_ios_import_pending_add(const char *path)
{
  import_pending.emplace_back(path);
}

bool WM_apple_ios_import_file(bContext *C, const char *path)
{
  wmWindowManager *wm = CTX_wm_manager(C);
  wmWindow *win = wm ? static_cast<wmWindow *>(wm->windows.first) : nullptr;
  bScreen *screen = win ? WM_window_get_active_screen(win) : nullptr;
  ScrArea *area = screen ? BKE_screen_find_big_area(screen, SPACE_VIEW3D, 0) : nullptr;
  ARegion *region = area ? BKE_area_find_region_type(area, RGN_TYPE_WINDOW) : nullptr;
  wmWindow *previous_window = CTX_wm_window(C);
  ScrArea *previous_area = CTX_wm_area(C);
  ARegion *previous_region = CTX_wm_region(C);
  CTX_wm_window_set(C, win);
  CTX_wm_area_set(C, area);
  CTX_wm_region_set(C, region);
  const std::string name = BLI_path_basename(path);
  bool imported = false;
  const Vector<bke::FileHandlerType *> handlers = bke::file_handlers_poll_file_drop(
      C, Span<std::string>({std::string(path)}));
  if (!handlers.is_empty()) {
    if (wmOperatorType *ot = WM_operatortype_find(handlers.first()->import_operator, false)) {
      PointerRNA props = WM_operator_properties_create_ptr(ot);
      char directory[FILE_MAX];
      BLI_path_split_dir_part(path, directory, sizeof(directory));
      if (RNA_struct_find_property(&props, "filepath")) {
        RNA_string_set(&props, "filepath", path);
      }
      if (RNA_struct_find_property(&props, "directory")) {
        RNA_string_set(&props, "directory", directory);
      }
      if (PropertyRNA *files = RNA_struct_find_property(&props, "files")) {
        PointerRNA entry;
        RNA_property_collection_add(&props, files, &entry);
        RNA_string_set(&entry, "name", name.c_str());
      }
      /* As a drop: the importer's options first (`filesel_drop_import_invoke`). */
      WM_operator_name_call_ptr(C, ot, wm::OpCallContext::InvokeDefault, &props, nullptr);
      WM_operator_properties_free(&props);
      imported = true;
    }
  }
  else if (BLI_path_extension_check_array(path, imb_ext_image) &&
           BKE_image_load_exists(CTX_data_main(C), path))
  {
    /* An image: one of the document's images, packed as it is next written (FILES-5). */
    WM_native_ui_notice(
        RPT_INFO,
        fmt::format(fmt::runtime(IFACE_("“{}” was added to the document's images.")), name)
            .c_str());
    imported = true;
  }
  if (!imported) {
    const char *app = WM_apple_ios_app_name();
    WM_native_ui_notice(
        RPT_WARNING,
        fmt::format(fmt::runtime(IFACE_("{} cannot open this kind of file: “{}”.")),
                    app && app[0] ? app : IFACE_("This app"),
                    name)
            .c_str());
  }
  WM_native_ui_session_log(
      "document",
      fmt::format("sent to the app: {} {}", name, imported ? "imported" : "not openable").c_str());
  CTX_wm_window_set(C, previous_window);
  CTX_wm_area_set(C, previous_area);
  CTX_wm_region_set(C, previous_region);
  return imported;
}

void WM_apple_ios_import_pending_run(bContext *C)
{
  std::vector<std::string> paths = std::move(import_pending);
  import_pending.clear();
  for (const std::string &path : paths) {
    WM_apple_ios_import_file(C, path.c_str());
  }
}

/** \} */

}  // namespace blender

#endif
