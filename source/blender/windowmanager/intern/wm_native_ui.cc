/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * The bridge between Blender and a platform's own interface, such as the iPad's SwiftUI one: the
 * commands it sends, run on Blender's loop, and snapshots of Blender for it to show, as JSON. The
 * interface calls in through `WM_native_ui.h`; Blender's own code through `WM_native_ui.hh`.
 */

#include "AS_asset_catalog.hh"
#include "AS_asset_library.hh"
#include "AS_asset_representation.hh"

#include "BKE_armature.hh"
#include "BKE_appdir.hh"
#include "BKE_asset.hh"
#include "BKE_context.hh"
#include "BKE_global.hh"
#include "BKE_idprop.hh"
#include "BKE_idtype.hh"
#include "BKE_lib_id.hh"
#include "BKE_main.hh"
#include "BKE_packedFile.hh"
#include "BKE_paint.hh"
#include "BKE_preferences.h"
#include "BKE_preview_image.hh"
#include "BKE_scene.hh"
#include "BKE_screen.hh"
#include "BKE_undo_system.hh"
#include "BKE_vfont.hh"
#include "DNA_vfont_types.h"
#include "BKE_wm_runtime.hh"
#include "BLT_translation.hh"
#include "ED_render.hh"

#include "BLI_fileops.h"
#include "BLI_listbase.h"
#include "BLI_math_vector.h"
#include "BLI_path_utils.hh"
#include "BLI_serialize.hh"
#include "BLI_time.h"
#include "BLI_timer.h"
#include "DNA_view3d_types.h"

#include "BLI_math_color.h"
#include "CLG_log.h"
#include "GHOST_Mailbox.hh"

#include "DEG_depsgraph.hh"

#include "DNA_action_types.h"
#include "DNA_asset_types.h"
#include "DNA_brush_types.h"
#include "DNA_node_types.h"
#include "DNA_object_types.h"
#include "DNA_scene_types.h"
#include "DNA_screen_types.h"
#include "DNA_space_types.h"
#include "DNA_userdef_types.h"
#include "DNA_windowmanager_types.h"
#include "DNA_workspace_types.h"

#include "../asset/ED_asset_shelf.hh"
#include "ED_asset.hh"
#include "ED_asset_menu_utils.hh"
#include "ED_image_native.hh"
#include "ED_object.hh"
#include "ED_screen.hh"
#include "ED_sequencer.hh"
#include "ED_transform.hh"
#include "ED_undo.hh"
#include "ED_view3d.hh"
#include "ED_view3d_pencil_hover.hh"

#include "IMB_imbuf.hh"
#include "IMB_imbuf_types.hh"

#include "MEM_guardedalloc.h"

#include "RNA_access.hh"

#include "SEQ_sequencer.hh"
#include "RNA_define.hh"

#include "RNA_enum_types.hh"
#include "RNA_prototypes.hh"
#include "UI_resources.hh"

#ifdef WITH_PYTHON
#  include "BPY_extern_run.hh"
#  include "MEM_guardedalloc.h"
#endif

#include "WM_api.hh"
#include "WM_gizmo_api.hh"
#include "WM_native_interface.hh"
#include "WM_native_ui.h"
#include "wm_native_ui_timing.hh"
#include "WM_native_ui.hh"
#include "WM_toolsystem.hh"
#include "WM_types.hh"

#include "wm_event_system.hh"
#include "wm_gizmo_wmapi.hh"
#include "wm_window.hh"

#if defined(WITH_APPLE_CROSSPLATFORM) && APPLE_TARGET_IOS
#  include "WM_apple_ios.hh"
#  include "wm_apple_ios_file.hh"
#endif

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <map>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <type_traits>
#include <variant>
#include <vector>

namespace blender::ui {
std::string native_menu_query(bContext *C, const std::string &request, bool execute);
std::string native_properties_query(bContext *C, const std::string &request, bool execute);
std::string native_nodes_query(bContext *C, const std::string &request, bool execute);
std::string native_nodes_identity(bContext *C, const std::string &request);
void native_nodes_compositor_job(bContext *C);
}  // namespace blender::ui
namespace blender::ed::graph {
std::string native_graph_query(bContext *C, const std::string &request, bool execute);
}  // namespace blender::ed::graph
namespace blender::ui {
std::string native_operator_redo_query(bContext *C, const std::string &request, bool execute);
std::string native_operator_dialog_query(bContext *C, const std::string &request, bool execute);
void native_properties_interaction_finish(bContext *C);
std::string native_properties_menu_query(bContext *C, const std::string &request, bool execute);
}  // namespace blender::ui

namespace blender {

static CLG_LogRef LOG = {"wm.native"};

/**
 * With `BLENDER_NATIVE_UI_RECORD` in the environment, snapshots are also written to
 * `native_ui_record/<table>/` in the temporary folder, named after the table of `native_ui.fbs`
 * they fit, for `tests/python/native_ui_schema_test.py --snapshots` to validate. The first few
 * hundred of each. Called on Blender's loop.
 */
static void bridge_record(const char *table, const std::string &json)
{
  static const bool record = getenv("BLENDER_NATIVE_UI_RECORD") != nullptr;
  if (!record) {
    return;
  }
  static std::map<std::string, int> counts;
  int &count = counts[table];
  if (count >= 500) {
    return;
  }
  char directory[FILE_MAX];
  BLI_path_join(directory, sizeof(directory), BKE_tempdir_base(), "native_ui_record", table);
  BLI_dir_create_recursive(directory);
  char path[FILE_MAX];
  BLI_path_join(path, sizeof(path), directory, (std::to_string(count++) + ".json").c_str());
  if (FILE *file = BLI_fopen(path, "wb")) {
    fwrite(json.data(), 1, json.size(), file);
    fclose(file);
  }
}

#ifdef WITH_PYTHON
/** Run a Python expression giving a string, for a part of a snapshot. */
static bool bridge_python(bContext *C, const char *part, const char *expression, std::string &r_result)
{
  BridgeTimer timer(part);
  const char *imports[] = {"bpy", "bl_ui", nullptr};
  char *result = nullptr;
  if (!BPY_run_string_as_string(C, imports, expression, nullptr, &result)) {
    return false;
  }
  r_result = result;
  MEM_delete(result);
  return true;
}
#endif

/* The scene as 3D geometry for a volumetric window, see `wm_apple_ios_volume.cc`. */
void bridge_volume_build(bContext *C);
bool bridge_volume_command(bContext *C, StringRef setting, StringRef value);

void bridge_interface_set(bContext *C, bool desktop);

namespace {

enum class BridgeCommand {
  SetModeObject = 0,
  SetModeEdit = 1,
  SetModeSculpt = 2,
  SetModeVertexPaint = 3,
  SetModeWeightPaint = 4,
  SetModeTexturePaint = 5,
  SelectToolSelectBox = 6,
  SelectToolCursor = 7,
  SelectToolMove = 8,
  SelectToolRotate = 9,
  SelectToolScale = 10,
  SelectToolTransform = 11,
  SelectToolAnnotate = 12,
  SelectToolMeasure = 13,
  FrameSelected = 14,
  ResetView = 15,
  OrbitLeft = 16,
  OrbitRight = 17,
  OrbitUp = 18,
  OrbitDown = 19,
  SetViewportWireframe = 20,
  SetViewportSolid = 21,
  SetViewportMaterial = 22,
  SetViewportRendered = 23,
  ViewAll = 24,
  ViewLocal = 25,
  ViewCamera = 26,
  ViewPerspOrtho = 27,
  ViewFront = 28,
  ViewBack = 29,
  ViewRight = 30,
  ViewLeft = 31,
  ViewTop = 32,
  ViewBottom = 33,
};
static_assert(int(BridgeCommand::SetModeObject) == int(WM_NATIVE_UI_COMMAND_SET_MODE_OBJECT) &&
                  int(BridgeCommand::ViewBottom) == int(WM_NATIVE_UI_COMMAND_VIEW_BOTTOM),
              "Commands as WM_native_ui.h numbers them");

struct BridgeOperatorPropertyCommand {
  std::string op_name;
  std::string prop_name;
  std::string prop_value;
};

struct BridgeOperatorCommand {
  std::string op_name;
};

struct BridgeSettingCommand {
  std::string setting;
  std::string value;
};

struct BridgeBrushCommand {
  std::string key;
};

/** Native asset pane drags; see #bridge_asset_drag. */
enum BridgeAssetDragPhase {
  BRIDGE_ASSET_DRAG_BEGIN,
  BRIDGE_ASSET_DRAG_MOVE,
  BRIDGE_ASSET_DRAG_DROP,
  BRIDGE_ASSET_DRAG_CANCEL,
  /** Drop at the 3D cursor, or onto the active object for materials and node groups. */
  BRIDGE_ASSET_ADD,
  /** Internal second step of #BRIDGE_ASSET_ADD: release at window coordinates. */
  BRIDGE_ASSET_ADD_RELEASE,
};
static_assert(int(BRIDGE_ASSET_DRAG_BEGIN) == int(WM_NATIVE_UI_ASSET_DRAG_BEGIN) &&
                  int(BRIDGE_ASSET_ADD) == int(WM_NATIVE_UI_ASSET_ADD),
              "Asset drags as WM_native_ui.h numbers them");

struct BridgeAssetDragCommand {
  int phase = BRIDGE_ASSET_DRAG_MOVE;
  std::string key;
  int x = 0, y = 0;
};

struct BridgeMenuRequest {
  uint64_t identifier;
  std::string route;
  bool execute;
  bool has_position = false;
  int x = 0, y = 0;
  int retries = 0;
};
using BridgeMessage = std::variant<BridgeCommand,
                                  BridgeOperatorCommand,
                                  BridgeOperatorPropertyCommand,
                                  BridgeSettingCommand,
                                  std::string,
                                  float,
                                  BridgeMenuRequest,
                                  BridgeBrushCommand,
                                  BridgeAssetDragCommand>;
/* A single inbox preserves ordering across tools, settings, operators and menus. */
GHOST_MessageQueue<BridgeMessage> bridge_messages;
GHOST_MessageQueue<std::pair<uint64_t, std::string>> bridge_menu_completed;
/* Results the native interface has yet to take. */
std::map<uint64_t, std::string> bridge_menu_results;
std::atomic<uint64_t> bridge_menu_next_identifier{0};
bool bridge_layout_ready = false;
bool bridge_gizmo_refresh_pending = true;
/** Blender's own interface instead of the native one: normal screens, no native controls. */
std::atomic<bool> bridge_desktop_ui{false};
int bridge_panels_visible = 0;
std::chrono::steady_clock::time_point bridge_panels_next_snapshot;
/* The last panels snapshot the native interface was given; cleared when it asks for different panels. */
std::string bridge_panels_published;
std::string bridge_panels_json = "null";
std::string bridge_properties_state = "{\"tab\":\"OBJECT\"}";
/** Blender's Preferences, a section at a time, in the iPad's Settings, see `SettingsSheet.swift`. */
std::string bridge_preferences_state = "{\"tab\":\"PREFERENCES_INTERFACE\"}";
/** The keymaps Settings shows with their items and what it searches for, as JSON. */
std::string bridge_keymaps_state = "{}";
/** Changed preferences are saved shortly after, as the iPad may end the app without warning. */
bool bridge_preferences_save_pending = false;
std::chrono::steady_clock::time_point bridge_preferences_save_at;
/** The node tree the native node editor shows: its kind and the groups entered. */
std::string bridge_nodes_state = "{\"tree\":\"SHADER\"}";
/** The tree last read, to read it again at once when another is chosen. */
std::string bridge_nodes_identity;
/* The node tree read last, read again only when something may have changed it: notifiers, the
 * editor's own commands, or a slow check. Reading a large tree takes a while. */
bool bridge_nodes_dirty = true;
/** Composite once the tree is read, for a compositor backdrop just shown. */
bool bridge_nodes_composite = false;
std::string bridge_nodes_json;
std::chrono::steady_clock::time_point bridge_nodes_next_check;
/** The tree the Add Node list was sent for, sent again only for another. */
std::string bridge_nodes_add_for;
/** The native curve editor's state, curves and whether they need reading again. */
std::string bridge_graph_state = "{}";
bool bridge_graph_dirty = true;
std::string bridge_graph_json;
std::chrono::steady_clock::time_point bridge_graph_next_check;
/** The native image editor's state: the image chosen and whether UVs show over it. */
std::string bridge_image_state = "{}";
bool bridge_image_dirty = true;
std::string bridge_image_json;
std::chrono::steady_clock::time_point bridge_image_next_check;
/** Its picture and UVs, taken by the native editor when they change. */
GHOST_Latest<ed::image::NativeImagePixels> bridge_image_pixels;
GHOST_Latest<std::vector<float>> bridge_image_uvs;
/** The picture changed since it was last sent, which waits a little while painting. */
bool bridge_image_pixels_pending = true;
bool bridge_image_uvs_pending = true;
/* The storyboard: the sequencer scene's shots, see `sequencer_native.cc`. */
bool bridge_storyboard_dirty = true;
/* How the native storyboard shows the shots: the frames between their pictures, and their size. */
std::string bridge_storyboard_state = "{}";
/* Pictures of shots were still to draw at the last look, or it has not looked yet. */
bool bridge_storyboard_pending = true;
std::string bridge_storyboard_json;
std::chrono::steady_clock::time_point bridge_storyboard_next_check;
std::string bridge_properties_error;
int64_t bridge_panels_sequence = 0;
std::atomic<bool> bridge_navigation_hover_active{false};
std::atomic<bool> bridge_navigation_redraw_pending{false};
/** Height of the native bottom tray (the asset pane) as a fraction of the window height. */
std::atomic<float> bridge_bottom_tray{0.0f};
/** Window pixels a native panel covers at the bottom, which the 3D views leave out. */
std::atomic<float> bridge_viewport_cover{0.0f};
/** Window pixels a native panel covers at the right, such as the Image Editor beside the 3D view. */
std::atomic<float> bridge_viewport_trailing_cover{0.0f};
std::atomic<bool> bridge_viewport_cover_changed{false};
struct BridgePencilHoverRequest {
  bool active = false;
  int x = 0, y = 0;
};
GHOST_Latest<BridgePencilHoverRequest> bridge_hover_requests;
GHOST_Latest<std::string> bridge_hover_snapshot;
/* Window coordinates of the asset drag in progress. */
int2 bridge_asset_drag_xy(0);
BridgePencilHoverRequest bridge_hover_request;

struct BridgeActionItem {
  const char *title;
  const char *op_name;
  const char *symbol;
  const char *prop_name = "";
  const char *prop_value = "";
  const char *key = "";
  bool selected = false;
};

GHOST_Latest<std::string> bridge_toolbar_snapshot;
/** One of Blender's menus to show natively where the pointer is, see #bridge_menu_popup. */
GHOST_Latest<std::string> bridge_menu_popup_snapshot;
GHOST_Latest<std::string> bridge_panels_snapshot;
GHOST_Latest<std::string> bridge_timeline_snapshot;
std::string bridge_timeline_json;
/* Keyframes shown on the timeline, refreshed on the native cadence while it is open. */
bool bridge_timeline_visible = false;
std::string bridge_timeline_keys_json = "[]";
std::chrono::steady_clock::time_point bridge_timeline_next_keys;
/* Native asset pane: listed only while shown. */
bool bridge_assets_visible = false;
std::string bridge_assets_json;
std::chrono::steady_clock::time_point bridge_assets_next_snapshot;
GHOST_Latest<std::string> bridge_assets_snapshot;
std::string bridge_toolbar_json =
    "{\"mode\":\"objectmode\",\"active\":\"builtin.select_box\",\"tools\":[]}";

std::string bridge_json_escape(const std::string &value);
void bridge_brush_direction_set(bContext *C, bool add);

void bridge_action_add_key(std::vector<BridgeActionItem> &items,
                        const char *title,
                        const char *symbol,
                        const char *key)
{
  items.push_back({title, "", symbol, "", "", key});
}

wmOperator *bridge_constraint_operator(wmWindow *win)
{
  if (win == nullptr) {
    return nullptr;
  }

  for (wmEventHandler &handler_base_item : win->runtime->modalhandlers) {
    wmEventHandler *handler_base = &handler_base_item;
    if (handler_base->type != WM_HANDLER_TYPE_OP) {
      continue;
    }
    wmEventHandler_Op *handler = reinterpret_cast<wmEventHandler_Op *>(handler_base);
    int axes;
    if (blender::ed::transform::modal_constraint_get(handler->op, axes)) {
      return handler->op;
    }
  }
  return nullptr;
}

/**
 * What to do for a command that waits for a drag in the view before it starts, as Box Select does
 * when chosen from the menu bar: there is no pointer to show it, so the iPad says so. Null when
 * nothing waits, or a tool's own drag already runs. `done` says it ends with Done rather than
 * after one drag.
 */
static const char *bridge_drag_hint(wmWindow *win, bool *r_done)
{
  *r_done = false;
  if (win == nullptr) {
    return nullptr;
  }
  static const std::map<std::string_view, const char *> hints = {
      {"VIEW3D_OT_select_box", "Drag across the view to select"},
      {"VIEW3D_OT_select_circle", "Brush over what to select"},
      {"VIEW3D_OT_select_lasso", "Draw around what to select"},
      {"VIEW3D_OT_zoom_border", "Drag across the view to zoom to it"},
      {"VIEW3D_OT_clip_border", "Drag across the view to clip it"},
      {"VIEW3D_OT_render_border", "Drag across the view to render only that"},
      {"VIEW3D_OT_dolly", "Drag up or down to dolly the view"},
  };
  for (wmEventHandler &handler_base : win->runtime->modalhandlers) {
    if (handler_base.type != WM_HANDLER_TYPE_OP) {
      continue;
    }
    const wmOperator *op = reinterpret_cast<wmEventHandler_Op &>(handler_base).op;
    const auto hint = op ? hints.find(op->type->idname) : hints.end();
    if (hint == hints.end()) {
      continue;
    }
    if (STREQ(op->type->idname, "VIEW3D_OT_dolly")) {
      return hint->second;
    }
    /* A gesture waiting for its drag, not one a tool started with it. */
    for (const wmGesture &gesture : win->runtime->gesture) {
      if (gesture.wait_for_input || STREQ(op->type->idname, "VIEW3D_OT_select_circle")) {
        *r_done = STREQ(op->type->idname, "VIEW3D_OT_select_circle") && gesture.wait_for_input;
        return gesture.is_active && !*r_done ? nullptr : hint->second;
      }
    }
  }
  return nullptr;
}

std::vector<BridgeActionItem> bridge_action_items_for_tool(bContext *C,
                                                     const eContextObjectMode mode,
                                                     const char *active_tool_id)
{
  std::vector<BridgeActionItem> items;

  if (wmOperator *op = bridge_constraint_operator(CTX_wm_window(C))) {
    int axes;
    blender::ed::transform::modal_constraint_get(op, axes);
    for (int axis = 0; axis < 3; axis++) {
      const char *name = axis == 0 ? "X" : axis == 1 ? "Y" : "Z";
      bridge_action_add_key(items, name, "", name);
      items.back().selected = (axes & (1 << axis)) != 0;
    }
    return items;
  }

  /* Everything else comes from `bl_ui.native_actions`, queried with the toolbar snapshot. */
  UNUSED_VARS(mode, active_tool_id);
  return items;
}

ScrArea *bridge_find_view3d_area(bScreen *screen)
{
  if (screen == nullptr) {
    return nullptr;
  }

  ScrArea *best_area = nullptr;
  int best_area_size = -1;
  for (ScrArea &area_item : screen->areabase) {
    ScrArea *area = &area_item;
    if (area->spacetype != SPACE_VIEW3D) {
      continue;
    }
    const int area_size = int(area->winx) * int(area->winy);
    if (area_size > best_area_size) {
      best_area = area;
      best_area_size = area_size;
    }
  }
  return best_area;
}

ARegion *bridge_find_window_region(ScrArea *area)
{
  if (area == nullptr) {
    return nullptr;
  }

  for (ARegion &region_item : area->regionbase) {
    ARegion *region = &region_item;
    if (region->regiontype == RGN_TYPE_WINDOW) {
      return region;
    }
  }
  return nullptr;
}

wmWindow *bridge_active_window(bContext *C)
{
  wmWindow *win = CTX_wm_window(C);
  if (win != nullptr) {
    return win;
  }

  wmWindowManager *wm = CTX_wm_manager(C);
  if (wm == nullptr) {
    return nullptr;
  }
  return static_cast<wmWindow *>(wm->windows.first);
}

struct BridgeContextStore {
  wmWindow *win;
  bScreen *screen;
  ScrArea *area;
  ARegion *region;
};

BridgeContextStore bridge_context_push_view3d(bContext *C)
{
  BridgeContextStore store = {CTX_wm_window(C), CTX_wm_screen(C), CTX_wm_area(C), CTX_wm_region(C)};

  wmWindow *win = bridge_active_window(C);
  bScreen *screen = win ? WM_window_get_active_screen(win) : CTX_wm_screen(C);
  ScrArea *area = bridge_find_view3d_area(screen);
  ARegion *region = bridge_find_window_region(area);

  CTX_wm_window_set(C, win);
  CTX_wm_screen_set(C, screen);
  CTX_wm_area_set(C, area);
  CTX_wm_region_set(C, region);

  return store;
}

void bridge_context_pop(bContext *C, const BridgeContextStore &store)
{
  if (bridge_layout_ready) {
    wmWindow *win = bridge_active_window(C);
    bScreen *screen = win ? WM_window_get_active_screen(win) : store.screen;
    ScrArea *area = bridge_find_view3d_area(screen);
    ARegion *region = bridge_find_window_region(area);

    CTX_wm_window_set(C, win);
    CTX_wm_screen_set(C, screen);
    CTX_wm_area_set(C, area);
    CTX_wm_region_set(C, region);
    return;
  }

  CTX_wm_window_set(C, store.win);
  CTX_wm_screen_set(C, store.screen);
  CTX_wm_area_set(C, store.area);
  CTX_wm_region_set(C, store.region);
}

void bridge_operator_call(bContext *C, const char *op_name, PointerRNA *props = nullptr)
{
  if (WM_operator_name_poll(C, op_name)) {
    /* Smooth view uses OP_IS_INVOKE, including for operators with only an exec callback.
     * Keep non-navigation quick actions on their existing execution path. */
    const bool smooth_view = ELEM(std::string_view(op_name),
                                  "VIEW3D_OT_view_selected",
                                  "VIEW3D_OT_view_all",
                                  "VIEW3D_OT_localview",
                                  "VIEW3D_OT_view_camera",
                                  "VIEW3D_OT_view_persportho",
                                  "VIEW3D_OT_view_axis",
                                  "VIEW3D_OT_view_orbit");
    WM_operator_name_call(C,
                          op_name,
                          smooth_view ? blender::wm::OpCallContext::InvokeRegionWin :
                                        blender::wm::OpCallContext::ExecRegionWin,
                          props,
                          nullptr);
  }
}

bool bridge_undo_available(bContext *C, const char *op_name = "ED_OT_undo")
{
  wmWindow *win = CTX_wm_window(C);
  if (win == nullptr) {
    return false;
  }
  /* Undo must not invalidate data owned by an in-progress tool or navigation operation. */
  for (wmEventHandler &handler_item : win->runtime->modalhandlers) {
    wmEventHandler *handler = &handler_item;
    if (handler->type == WM_HANDLER_TYPE_OP) {
      return false;
    }
  }
  return WM_operator_name_poll(C, op_name);
}

void bridge_operator_invoke(bContext *C, const char *op_name)
{
  if ((STREQ(op_name, "ED_OT_undo") || STREQ(op_name, "ED_OT_redo")) &&
      !bridge_undo_available(C, op_name))
  {
    return;
  }
  if (WM_operator_name_poll(C, op_name)) {
    WM_operator_name_call(
        C, op_name, blender::wm::OpCallContext::InvokeRegionWin, nullptr, nullptr);
  }
}

void bridge_operator_call_with_enum_property(bContext *C,
                                          const char *op_name,
                                          const char *prop_name,
                                          const char *prop_value)
{
  if (op_name == nullptr || prop_name == nullptr || prop_value == nullptr ||
      prop_name[0] == '\0' || prop_value[0] == '\0')
  {
    bridge_operator_call(C, op_name);
    return;
  }

  wmOperatorType *ot = WM_operatortype_find(op_name, false);
  if (ot == nullptr) {
    return;
  }

  PointerRNA props = WM_operator_properties_create_ptr(ot);
  RNA_enum_set_identifier(C, &props, prop_name, prop_value);
  bridge_operator_call(C, op_name, &props);
  WM_operator_properties_free(&props);
}

PropertyRNA *bridge_rna_boolean_set(bContext *C,
                                 PointerRNA &ptr,
                                 const char *identifier,
                                 bool value);
void bridge_rna_undo_push(bContext *C, PropertyRNA *prop);

/** The text object being edited, if one is. */
static Curve *bridge_text_object_edited(bContext *C)
{
  Object *object = CTX_data_edit_object(C);
  if (object == nullptr || object->type != OB_FONT) {
    return nullptr;
  }
  Curve *curve = id_cast<Curve *>(object->data);
  return curve->editfont ? curve : nullptr;
}

/** The text object being edited, else the active one, for its style, font and alignment. */
static Curve *bridge_text_object_active(bContext *C)
{
  if (Curve *curve = bridge_text_object_edited(C)) {
    return curve;
  }
  Object *object = CTX_data_active_object(C);
  return object && object->type == OB_FONT ? id_cast<Curve *>(object->data) : nullptr;
}

/** The style the system's formatting panel shows: the selection's, else what typing adds. */
static std::string bridge_text_object_json(bContext *C)
{
  Curve *curve = bridge_text_object_edited(C);
  if (curve == nullptr) {
    return "null";
  }
  int selection_start, selection_end;
  const short flag = BKE_vfont_select_get(curve, &selection_start, &selection_end) ?
                         curve->editfont->textbufinfo[selection_start].flag :
                         curve->curinfo.flag;
  PointerRNA curve_ptr = RNA_id_pointer_create(&curve->id);
  PropertyRNA *align_prop = RNA_struct_find_property(&curve_ptr, "align_x");
  const char *align = "";
  RNA_property_enum_identifier(
      C, &curve_ptr, align_prop, RNA_property_enum_get(&curve_ptr, align_prop), &align);
  std::string json = "{";
  json += std::string("\"bold\":") + ((flag & CU_CHINFO_BOLD) ? "true" : "false");
  json += std::string(",\"italic\":") + ((flag & CU_CHINFO_ITALIC) ? "true" : "false");
  json += std::string(",\"underline\":") + ((flag & CU_CHINFO_UNDERLINE) ? "true" : "false");
  json += ",\"align\":\"" + std::string(align) + "\"";
  json += ",\"font_file\":\"" +
          bridge_json_escape(curve->vfont ? curve->vfont->filepath : "") + "\"";
  json += "}";
  return json;
}

/**
 * Sets a style on the selection and on what typing adds next, as Blender's Font panel does; out
 * of Edit Mode, on all of the text, as a text box is styled.
 */
static void bridge_text_object_style(bContext *C, const std::string &style, const bool on)
{
  Curve *curve = bridge_text_object_active(C);
  const struct {
    const char *name;
    const char *format_prop;
    short flag;
  } styles[] = {{"BOLD", "use_bold", CU_CHINFO_BOLD},
                {"ITALIC", "use_italic", CU_CHINFO_ITALIC},
                {"UNDERLINE", "use_underline", CU_CHINFO_UNDERLINE},
                {"SMALL_CAPS", "use_small_caps", CU_CHINFO_SMALLCAPS}};
  const auto *found = std::find_if(
      std::begin(styles), std::end(styles), [&](const auto &item) { return style == item.name; });
  if (curve == nullptr || found == std::end(styles)) {
    return;
  }
  if (curve->editfont == nullptr) {
    for (int i = 0; i < curve->len_char32; i++) {
      SET_FLAG_FROM_TEST(curve->strinfo[i].flag, on, found->flag);
    }
    SET_FLAG_FROM_TEST(curve->curinfo.flag, on, found->flag);
    DEG_id_tag_update(&curve->id, ID_RECALC_GEOMETRY);
    WM_event_add_notifier(C, NC_GEOM | ND_DATA, curve);
    ED_undo_push(C, "Set Style");
    return;
  }
  int selection_start, selection_end;
  if (BKE_vfont_select_get(curve, &selection_start, &selection_end)) {
    wmOperatorType *ot = WM_operatortype_find("FONT_OT_style_set", false);
    PointerRNA props = WM_operator_properties_create_ptr(ot);
    RNA_enum_set_identifier(C, &props, "style", style.c_str());
    RNA_boolean_set(&props, "clear", !on);
    bridge_operator_call(C, "FONT_OT_style_set", &props);
    WM_operator_properties_free(&props);
  }
  PointerRNA curve_ptr = RNA_id_pointer_create(&curve->id);
  PointerRNA format = RNA_pointer_get(&curve_ptr, "edit_format");
  bridge_rna_boolean_set(C, format, found->format_prop, on);
  ED_undo_push(C, "Set Style");
}

/** Fonts the system's formatting panel picked, as `slot=path` lines: written font files, which
 * are packed, as they are only a cache. */
static void bridge_text_object_fonts(bContext *C, const std::string &lines)
{
  Curve *curve = bridge_text_object_active(C);
  if (curve == nullptr) {
    return;
  }
  Main *bmain = CTX_data_main(C);
  PointerRNA curve_ptr = RNA_id_pointer_create(&curve->id);
  size_t start = 0;
  while (start < lines.size()) {
    size_t end = lines.find('\n', start);
    if (end == std::string::npos) {
      end = lines.size();
    }
    const std::string line = lines.substr(start, end - start);
    start = end + 1;
    const size_t equals = line.find('=');
    if (equals == std::string::npos) {
      continue;
    }
    const std::string slot = line.substr(0, equals);
    PropertyRNA *prop = RNA_struct_find_property(&curve_ptr, slot.c_str());
    if (prop == nullptr || RNA_property_type(prop) != PROP_POINTER) {
      continue;
    }
    VFont *font = BKE_vfont_load_exists(bmain, line.substr(equals + 1).c_str());
    if (font == nullptr) {
      continue;
    }
    /* Loading counts a user, as does assigning it. */
    id_us_min(&font->id);
    if (!font->packedfile) {
      font->packedfile = BKE_packedfile_new(nullptr, font->filepath, BKE_main_blendfile_path(bmain));
    }
    PointerRNA font_ptr = RNA_id_pointer_create(&font->id);
    RNA_property_pointer_set(&curve_ptr, prop, font_ptr, nullptr);
    RNA_property_update(C, &curve_ptr, prop);
  }
  ED_undo_push(C, "Choose Font");
}

/**
 * Typing into a text object in Edit Mode from the system keyboard, as Blender's keys do, and the
 * system's text formatting: `insert:<text>`, `delete`, `line_break`, `move:<FONT_OT_move type>`,
 * `style:<BOLD|ITALIC|UNDERLINE|SMALL_CAPS>:<0|1>`, `align:<align_x>` or `font:<slot=path lines>`.
 */
void bridge_text_object_edit(bContext *C, const std::string &command)
{
  const size_t colon = command.find(':');
  const std::string action = command.substr(0, colon);
  const std::string argument = colon == std::string::npos ? "" : command.substr(colon + 1);
  if (action == "insert" && !argument.empty()) {
    wmOperatorType *ot = WM_operatortype_find("FONT_OT_text_insert", false);
    if (ot == nullptr) {
      return;
    }
    PointerRNA props = WM_operator_properties_create_ptr(ot);
    RNA_string_set(&props, "text", argument.c_str());
    bridge_operator_call(C, "FONT_OT_text_insert", &props);
    WM_operator_properties_free(&props);
  }
  else if (action == "delete") {
    bridge_operator_call_with_enum_property(C, "FONT_OT_delete", "type", "PREVIOUS_OR_SELECTION");
  }
  else if (action == "line_break") {
    bridge_operator_call(C, "FONT_OT_line_break");
  }
  else if (action == "move") {
    bridge_operator_call_with_enum_property(C, "FONT_OT_move", "type", argument.c_str());
  }
  else if (action == "style") {
    const size_t separator = argument.find(':');
    bridge_text_object_style(
        C, argument.substr(0, separator), separator != std::string::npos && argument.substr(separator + 1) == "1");
  }
  else if (action == "align") {
    if (Curve *curve = bridge_text_object_active(C)) {
      PointerRNA curve_ptr = RNA_id_pointer_create(&curve->id);
      if (PropertyRNA *prop = RNA_struct_find_property(&curve_ptr, "align_x")) {
        RNA_enum_set_identifier(C, &curve_ptr, "align_x", argument.c_str());
        RNA_property_update(C, &curve_ptr, prop);
        bridge_rna_undo_push(C, prop);
      }
    }
  }
  else if (action == "font") {
    bridge_text_object_fonts(C, argument);
  }
  else if (action == "align_y" || action == "value") {
    /* `align_y:<enum>`, or `value:<size|space_line|space_character|space_word>:<number>`. */
    Curve *curve = bridge_text_object_active(C);
    if (curve == nullptr) {
      return;
    }
    PointerRNA curve_ptr = RNA_id_pointer_create(&curve->id);
    const size_t separator = argument.find(':');
    const std::string name = action == "align_y" ? "align_y" : argument.substr(0, separator);
    PropertyRNA *prop = RNA_struct_find_property(&curve_ptr, name.c_str());
    if (prop == nullptr || !ELEM(name, "align_y", "size", "space_line", "space_character", "space_word")) {
      return;
    }
    if (action == "align_y") {
      RNA_enum_set_identifier(C, &curve_ptr, "align_y", argument.c_str());
    }
    else if (separator != std::string::npos) {
      float minimum, maximum;
      RNA_property_float_range(&curve_ptr, prop, &minimum, &maximum);
      const double value = std::atof(argument.c_str() + separator + 1);
      RNA_property_float_set(&curve_ptr, prop, std::clamp(float(value), minimum, maximum));
    }
    RNA_property_update(C, &curve_ptr, prop);
    bridge_rna_undo_push(C, prop);
  }
}

void bridge_mode_set(bContext *C, const char *mode)
{
  wmOperatorType *ot = WM_operatortype_find("OBJECT_OT_mode_set", false);
  if (ot == nullptr) {
    return;
  }

  PointerRNA props = WM_operator_properties_create_ptr(ot);
  RNA_enum_set_identifier(C, &props, "mode", mode);
  RNA_boolean_set(&props, "toggle", false);
  if (WM_operator_name_poll(C, "OBJECT_OT_mode_set")) {
    WM_operator_name_call_ptr(C, ot, blender::wm::OpCallContext::ExecRegionWin, &props, nullptr);
  }
  WM_operator_properties_free(&props);
}

/** Modes the active object supports, as listed by Blender's own header mode menu.
 * Filter directly: `OBJECT_OT_mode_set` items read through owner-less operator properties
 * are resolved without context, which lists every mode for every object type. */
std::string bridge_object_modes_json(bContext *C)
{
  const Object *active = CTX_data_active_object(C);
  std::string json = "[";
  for (const EnumPropertyItem *item = rna_enum_object_mode_items; item->identifier; item++) {
    if (!item->identifier[0] ||
        !(active ? ed::object::mode_compat_test(active, eObjectMode(item->value)) :
                   item->value == OB_MODE_OBJECT))
    {
      continue;
    }
    const char *icon = nullptr;
    RNA_enum_identifier(rna_enum_icon_items, item->icon, &icon);
    json += json.size() > 1 ? "," : "";
    json += "{\"id\":\"" + bridge_json_escape(item->identifier) + "\",\"label\":\"" +
            bridge_json_escape(item->name ? item->name : item->identifier) + "\",\"icon\":\"" +
            bridge_json_escape(icon ? icon : "") + "\"}";
  }
  return json + "]";
}

void bridge_view_axis(bContext *C, const char *axis_type)
{
  wmOperatorType *ot = WM_operatortype_find("VIEW3D_OT_view_axis", false);
  if (ot == nullptr) {
    return;
  }

  PointerRNA props = WM_operator_properties_create_ptr(ot);
  RNA_enum_set_identifier(C, &props, "type", axis_type);
  RNA_boolean_set(&props, "align_active", false);
  RNA_boolean_set(&props, "relative", false);
  bridge_operator_call(C, "VIEW3D_OT_view_axis", &props);
  WM_operator_properties_free(&props);
}

void bridge_view_orbit(bContext *C, const char *direction)
{
  wmOperatorType *ot = WM_operatortype_find("VIEW3D_OT_view_orbit", false);
  if (ot == nullptr) {
    return;
  }

  PointerRNA props = WM_operator_properties_create_ptr(ot);
  RNA_enum_set_identifier(C, &props, "type", direction);
  bridge_operator_call(C, "VIEW3D_OT_view_orbit", &props);
  WM_operator_properties_free(&props);
}

void bridge_view_roll_angle(bContext *C, const float angle)
{
  wmOperatorType *ot = WM_operatortype_find("VIEW3D_OT_view_roll", false);
  if (ot == nullptr) {
    return;
  }

  PointerRNA props = WM_operator_properties_create_ptr(ot);
  RNA_enum_set_identifier(C, &props, "type", "ANGLE");
  RNA_float_set(&props, "angle", angle);
  if (WM_operator_name_poll(C, "VIEW3D_OT_view_roll")) {
    WM_operator_name_call_ptr(C, ot, blender::wm::OpCallContext::ExecRegionWin, &props, nullptr);
  }
  WM_operator_properties_free(&props);
}

void bridge_viewport_shading_set(bContext *C, const int shading_type)
{
  Main *bmain = CTX_data_main(C);
  ScrArea *area = CTX_wm_area(C);
  View3D *v3d = area ? static_cast<View3D *>(area->spacedata.first) : nullptr;
  if (bmain == nullptr || area == nullptr || v3d == nullptr || area->spacetype != SPACE_VIEW3D) {
    return;
  }

  if (v3d->shading.type == shading_type) {
    return;
  }

  if (shading_type == OB_WIRE) {
    v3d->shading.prev_type_wire = v3d->shading.type;
  }
  else {
    v3d->shading.prev_type = v3d->shading.type;
  }
  v3d->shading.type = shading_type;
  ED_view3d_shade_update(bmain, v3d, area);
  WM_event_add_notifier(C, NC_SPACE | ND_SPACE_VIEW3D | NS_VIEW3D_SHADING, v3d);
}

int bridge_orientation_value_for_id(const std::string &value)
{
  if (value == "local") {
    return V3D_ORIENT_LOCAL;
  }
  if (value == "normal") {
    return V3D_ORIENT_NORMAL;
  }
  if (value == "gimbal") {
    return V3D_ORIENT_GIMBAL;
  }
  if (value == "view") {
    return V3D_ORIENT_VIEW;
  }
  if (value == "cursor") {
    return V3D_ORIENT_CURSOR;
  }
  if (value == "parent") {
    return V3D_ORIENT_PARENT;
  }
  return V3D_ORIENT_GLOBAL;
}

int bridge_pivot_value_for_id(const std::string &value)
{
  if (value == "bounds") {
    return V3D_AROUND_CENTER_BOUNDS;
  }
  if (value == "cursor") {
    return V3D_AROUND_CURSOR;
  }
  if (value == "individual") {
    return V3D_AROUND_LOCAL_ORIGINS;
  }
  if (value == "active") {
    return V3D_AROUND_ACTIVE;
  }
  return V3D_AROUND_CENTER_MEDIAN;
}

eSnapMode bridge_snap_mode_for_id(const std::string &value)
{
  if (value == "grid") {
    return SCE_SNAP_TO_GRID;
  }
  if (value == "vertex") {
    return eSnapMode(SCE_SNAP_TO_POINT | SCE_SNAP_TO_EDGE_ENDPOINT);
  }
  if (value == "edge") {
    return SCE_SNAP_TO_EDGE;
  }
  if (value == "face") {
    return SCE_SNAP_TO_FACE;
  }
  if (value == "volume") {
    return SCE_SNAP_TO_VOLUME;
  }
  return SCE_SNAP_TO_INCREMENT;
}

const char *bridge_orientation_id(const int orientation)
{
  switch (orientation) {
    case V3D_ORIENT_GLOBAL:
      return "global";
    case V3D_ORIENT_LOCAL:
      return "local";
    case V3D_ORIENT_NORMAL:
      return "normal";
    case V3D_ORIENT_GIMBAL:
      return "gimbal";
    case V3D_ORIENT_VIEW:
      return "view";
    case V3D_ORIENT_CURSOR:
      return "cursor";
    case V3D_ORIENT_PARENT:
      return "parent";
    default:
      return "custom";
  }
}

const char *bridge_pivot_id(const int pivot)
{
  switch (pivot) {
    case V3D_AROUND_CENTER_BOUNDS:
      return "bounds";
    case V3D_AROUND_CURSOR:
      return "cursor";
    case V3D_AROUND_LOCAL_ORIGINS:
      return "individual";
    case V3D_AROUND_ACTIVE:
      return "active";
    default:
      return "median";
  }
}

const char *bridge_snap_id(const ToolSettings *settings)
{
  if (!(settings->snap_flag & SCE_SNAP)) {
    return "off";
  }
  for (const char *id : {"increment", "grid", "vertex", "edge", "face", "volume"}) {
    if (settings->snap_mode == bridge_snap_mode_for_id(id)) {
      return id;
    }
  }
  return "mixed";
}

const char *bridge_proportional_id(const ToolSettings *settings, const eContextObjectMode mode)
{
  const bool enabled = mode == CTX_MODE_OBJECT ?
                           settings->proportional_objects :
                           (settings->proportional_edit & PROP_EDIT_USE) != 0;
  if (!enabled) {
    return "off";
  }
  if (settings->proportional_edit & PROP_EDIT_CONNECTED) {
    return "connected";
  }
  if (settings->proportional_edit & PROP_EDIT_PROJECTED) {
    return "projected";
  }
  return "on";
}

/** The mode's mirror options, as its header's Mirror popover shows them. */
struct BridgeMirror {
  /** What has the axes, named `prefix` and the axis: `use_mesh_mirror_x`. */
  PointerRNA axes;
  const char *prefix;
  /** The axes there are. */
  const char *letters;
  /** The mesh, for Topology Mirror, in Edit Mode only. */
  std::optional<PointerRNA> topology;
};

static std::optional<BridgeMirror> bridge_mirror(Object *ob, const eContextObjectMode mode)
{
  if (ob == nullptr || ob->data == nullptr) {
    return std::nullopt;
  }
  switch (mode) {
    case CTX_MODE_EDIT_MESH:
      return BridgeMirror{RNA_id_pointer_create(&ob->id),
                       "use_mesh_mirror_",
                       "xyz",
                       RNA_id_pointer_create(static_cast<ID *>(ob->data))};
    case CTX_MODE_EDIT_ARMATURE:
      return BridgeMirror{
          RNA_id_pointer_create(static_cast<ID *>(ob->data)), "use_mirror_", "x", std::nullopt};
    case CTX_MODE_POSE:
      if (ob->pose == nullptr) {
        return std::nullopt;
      }
      return BridgeMirror{RNA_pointer_create_discrete(&ob->id, RNA_Pose, ob->pose),
                       "use_mirror_",
                       "x",
                       std::nullopt};
    default:
      return std::nullopt;
  }
}

std::string bridge_transform_settings_json(const Scene *scene,
                                        Object *ob,
                                        const eContextObjectMode mode)
{
  if (!scene || !scene->toolsettings) {
    return "{}";
  }
  const ToolSettings *settings = scene->toolsettings;
  const int orientation = BKE_scene_orientation_slot_get_index(
      &scene->orientation_slots[SCE_ORIENT_DEFAULT]);
  std::string json = "{\"orientation\":\"";
  json += bridge_orientation_id(orientation);
  json += "\",\"pivot\":\"";
  json += bridge_pivot_id(settings->transform_pivot_point);
  json += "\",\"snap\":\"";
  json += bridge_snap_id(settings);
  json += "\",\"proportional\":\"";
  json += bridge_proportional_id(settings, mode);
  json += "\"";
  if (std::optional<BridgeMirror> mirror = bridge_mirror(ob, mode)) {
    /* The axes there are, and which of them mirror. */
    json += ",\"mirror_axes\":\"";
    json += mirror->letters;
    json += "\",\"mirror\":\"";
    for (const char *axis = mirror->letters; *axis; axis++) {
      if (RNA_boolean_get(&mirror->axes, (std::string(mirror->prefix) + *axis).c_str())) {
        json += *axis;
      }
    }
    json += "\"";
    if (mirror->topology) {
      json += ",\"mirror_topology\":\"";
      json += RNA_boolean_get(&*mirror->topology, "use_mirror_topology") ? "on" : "off";
      json += "\"";
    }
  }
  json += "}";
  return json;
}

std::string bridge_mesh_select_mode_string(const ToolSettings *tool_settings)
{
  if (tool_settings == nullptr) {
    return "VERT";
  }
  if (tool_settings->selectmode & SCE_SELECT_FACE) {
    return "FACE";
  }
  if (tool_settings->selectmode & SCE_SELECT_EDGE) {
    return "EDGE";
  }
  return "VERT";
}

void bridge_mesh_select_mode_set(bContext *C, const std::string &value)
{
  wmOperatorType *ot = WM_operatortype_find("MESH_OT_select_mode", false);
  if (ot == nullptr) {
    return;
  }

  PointerRNA props = WM_operator_properties_create_ptr(ot);
  RNA_enum_set_identifier(C, &props, "type", value.c_str());
  RNA_enum_set_identifier(C, &props, "action", "ENABLE");
  RNA_boolean_set(&props, "use_extend", false);
  RNA_boolean_set(&props, "use_expand", false);
  if (WM_operator_name_poll(C, "MESH_OT_select_mode")) {
    WM_operator_name_call_ptr(C, ot, blender::wm::OpCallContext::ExecRegionWin, &props, nullptr);
  }
  WM_operator_properties_free(&props);
}

/**
 * Set a property as Blender's own header buttons do: through RNA, so its update runs and
 * notifiers are sent. Returns the property, or null when it does not exist.
 */
PropertyRNA *bridge_rna_enum_set(bContext *C,
                              PointerRNA &ptr,
                              const char *identifier,
                              const int value)
{
  PropertyRNA *prop = RNA_struct_find_property(&ptr, identifier);
  if (prop == nullptr) {
    return nullptr;
  }
  RNA_property_enum_set(&ptr, prop, value);
  RNA_property_update(C, &ptr, prop);
  return prop;
}

PropertyRNA *bridge_rna_boolean_set(bContext *C,
                                 PointerRNA &ptr,
                                 const char *identifier,
                                 const bool value)
{
  PropertyRNA *prop = RNA_struct_find_property(&ptr, identifier);
  if (prop == nullptr) {
    return nullptr;
  }
  RNA_property_boolean_set(&ptr, prop, value);
  RNA_property_update(C, &ptr, prop);
  return prop;
}

/** One undo step for a tool setting, named after it as the header's buttons name theirs. */
void bridge_rna_undo_push(bContext *C, PropertyRNA *prop)
{
  if (prop != nullptr) {
    ED_undo_push(C, RNA_property_ui_name(prop));
  }
}

/** The active tool, with the area's tool synced to the mode first: the snapshot is read right
 * after operators, which can change the mode (as adding an object from Sculpt Mode does), before
 * Blender's own update syncs it. */
static bToolRef *bridge_active_tool(bContext *C)
{
  if (ScrArea *area = CTX_wm_area(C)) {
    if (WorkSpace *workspace = CTX_wm_workspace(C)) {
      WM_toolsystem_refresh_screen_area(
          workspace, CTX_data_scene(C), CTX_data_view_layer(C), area);
    }
  }
  return WM_toolsystem_ref_from_context(C);
}

/** Save the preferences, when changed, as Blender does on quit unless that is turned off. */
static void bridge_preferences_save(bContext *C)
{
  bridge_preferences_save_pending = false;
  if (U.runtime.is_dirty && (U.pref_flag & USER_PREF_FLAG_SAVE) &&
      (G.f & G_FLAG_USERPREF_NO_SAVE_ON_EXIT) == 0)
  {
    WM_operator_name_call(
        C, "WM_OT_save_userpref", blender::wm::OpCallContext::ExecDefault, nullptr, nullptr);
  }
}

/** While Settings shows them, preferences are saved a second after they last changed. */
static void bridge_preferences_save_when_changed(bContext *C,
                                              const std::chrono::steady_clock::time_point now)
{
  if (!U.runtime.is_dirty) {
    bridge_preferences_save_pending = false;
  }
  else if (!bridge_preferences_save_pending) {
    bridge_preferences_save_pending = true;
    bridge_preferences_save_at = now + std::chrono::seconds(1);
  }
  else if (now >= bridge_preferences_save_at) {
    bridge_preferences_save(C);
  }
}

/* What a drag with Tweak does, from the top bar's Drag menu: move, roll, tilt. */
static std::atomic<bool> bridge_tweak_move = true;
static std::atomic<bool> bridge_tweak_roll = true;
static std::atomic<bool> bridge_tweak_tilt = true;

/* Whether what the Pencil or pointer hovers over is highlighted, from the iPad's Settings. */
static bool bridge_hover_highlight = true;

/* The navigation gizmo's corner of the viewport, from the iPad's Settings, and mirrored for the
 * left hand. */
static std::atomic<bool> bridge_navigation_top = false;
static std::atomic<bool> bridge_navigation_left = false;

void bridge_setting_execute(bContext *C, const BridgeSettingCommand &command)
{
  if (command.setting == "navigation_corner") {
    bridge_navigation_top = command.value.starts_with("top");
    bridge_navigation_left = command.value.ends_with("left");
    WM_main_add_notifier(NC_SPACE | ND_SPACE_VIEW3D, nullptr);
    return;
  }
  if (command.setting == "hover_highlight") {
    bridge_hover_highlight = command.value == "1";
    return;
  }
  if (command.setting == "tweak_drag") {
    /* The letters of what is on: "m" move, "r" roll, "t" tilt. */
    bridge_tweak_move = command.value.find('m') != std::string::npos;
    bridge_tweak_roll = command.value.find('r') != std::string::npos;
    bridge_tweak_tilt = command.value.find('t') != std::string::npos;
    return;
  }
  bool preview = false;
  if (bridge_volume_command(C, command.setting, command.value)) {
    return;
  }
  if (command.setting == "native_redo_edit") {
    ui::native_operator_redo_query(C, command.value, true);
    return;
  }
  if (command.setting == "native_dialog_edit") {
    ui::native_operator_dialog_query(C, command.value, true);
    return;
  }
  if (command.setting == "interface") {
    bridge_interface_set(C, command.value == "desktop");
    return;
  }
  if (command.setting == "native_preferences_state") {
    bridge_preferences_state = command.value;
    bridge_panels_next_snapshot = {};
    bridge_panels_published.clear();
    return;
  }
  if (command.setting == "native_preferences_visible") {
    bridge_panels_visible = (bridge_panels_visible & ~32) | (command.value == "1" ? 32 : 0);
    bridge_panels_next_snapshot = {};
    bridge_panels_published.clear();
    if (command.value != "1") {
      bridge_preferences_save(C);
    }
    return;
  }
  if (command.setting == "native_nodes_state") {
    bridge_nodes_dirty = true;
    bridge_nodes_composite = command.value.find("COMPOSITOR") != std::string::npos;
    bridge_nodes_state = command.value;
    bridge_panels_next_snapshot = {};
    bridge_panels_published.clear();
    return;
  }
  if (command.setting == "native_nodes_visible") {
    bridge_nodes_dirty = true;
    bridge_panels_visible = (bridge_panels_visible & ~8) | (command.value == "1" ? 8 : 0);
    bridge_panels_next_snapshot = {};
    bridge_panels_published.clear();
    return;
  }
  if (command.setting == "native_nodes_edit") {
    bridge_nodes_dirty = true;
    std::istringstream stream(command.value);
    auto value = io::serialize::JsonFormatter().deserialize(stream);
    if (const auto *request = value ? value->as_dictionary_value() : nullptr) {
      bridge_panels_sequence = request->lookup_int("sequence").value_or(bridge_panels_sequence);
      preview = request->lookup_str("phase").value_or("") == "update";
    }
    if (!preview) {
      bridge_panels_next_snapshot = {};
    }
    bridge_properties_error = ui::native_nodes_query(C, command.value, true);
    return;
  }
  if (command.setting == "native_image_state") {
    bridge_image_dirty = true;
    bridge_image_pixels_pending = true;
    bridge_image_uvs_pending = true;
    bridge_image_state = command.value;
    bridge_panels_next_snapshot = {};
    return;
  }
  if (command.setting == "native_image_visible") {
    bridge_image_dirty = true;
    bridge_image_pixels_pending = true;
    bridge_image_uvs_pending = true;
    bridge_panels_visible = (bridge_panels_visible & ~128) | (command.value == "1" ? 128 : 0);
    bridge_panels_next_snapshot = {};
    bridge_panels_published.clear();
    return;
  }
  if (command.setting == "native_image_edit") {
    bridge_image_dirty = true;
    bridge_image_pixels_pending = true;
    std::istringstream stream(command.value);
    auto value = io::serialize::JsonFormatter().deserialize(stream);
    if (const auto *request = value ? value->as_dictionary_value() : nullptr) {
      bridge_panels_sequence = request->lookup_int("sequence").value_or(bridge_panels_sequence);
    }
    bridge_panels_next_snapshot = {};
    bridge_properties_error = ed::image::native_image_query(C, command.value, true);
    return;
  }
  if (command.setting == "native_graph_state") {
    bridge_graph_dirty = true;
    bridge_graph_state = command.value;
    bridge_panels_next_snapshot = {};
    bridge_panels_published.clear();
    return;
  }
  if (command.setting == "native_graph_visible") {
    bridge_graph_dirty = true;
    bridge_panels_visible = (bridge_panels_visible & ~16) | (command.value == "1" ? 16 : 0);
    bridge_panels_next_snapshot = {};
    bridge_panels_published.clear();
    return;
  }
  if (command.setting == "native_storyboard_visible") {
    bridge_storyboard_dirty = true;
    bridge_panels_visible = (bridge_panels_visible & ~64) | (command.value == "1" ? 64 : 0);
    bridge_panels_next_snapshot = {};
    bridge_panels_published.clear();
    return;
  }
  if (command.setting == "native_storyboard_state") {
    bridge_storyboard_dirty = true;
    bridge_storyboard_state = command.value;
    bridge_panels_next_snapshot = {};
    return;
  }
  if (command.setting == "native_storyboard_edit") {
    bridge_storyboard_dirty = true;
    std::istringstream stream(command.value);
    auto value = io::serialize::JsonFormatter().deserialize(stream);
    if (const auto *request = value ? value->as_dictionary_value() : nullptr) {
      bridge_panels_sequence = request->lookup_int("sequence").value_or(bridge_panels_sequence);
    }
    bridge_panels_next_snapshot = {};
    bridge_properties_error = ed::vse::native_storyboard_query(C, command.value, true);
    return;
  }
  if (command.setting == "native_graph_edit") {
    bridge_graph_dirty = true;
    std::istringstream stream(command.value);
    auto value = io::serialize::JsonFormatter().deserialize(stream);
    if (const auto *request = value ? value->as_dictionary_value() : nullptr) {
      bridge_panels_sequence = request->lookup_int("sequence").value_or(bridge_panels_sequence);
    }
    bridge_panels_next_snapshot = {};
    bridge_properties_error = ed::graph::native_graph_query(C, command.value, true);
    return;
  }
  if (command.setting == "native_nodes_create") {
    bridge_nodes_dirty = true;
    bridge_nodes_add_for.clear();
    /* A material, Geometry Nodes or compositor nodes for the node editor to show, as their own
     * buttons make them. */
    const char *imports[] = {"bpy", nullptr};
    std::string script;
    if (command.value == "SHADER") {
      script =
          "ob = bpy.context.active_object\n"
          "if ob is not None:\n"
          "    m = bpy.data.materials.new('Material')\n"
          "    if len(ob.material_slots) and ob.material_slots[ob.active_material_index].material is None:\n"
          "        ob.active_material = m\n"
          "    else:\n"
          "        ob.data.materials.append(m)\n"
          "        ob.active_material_index = len(ob.material_slots) - 1\n";
    }
    else if (command.value == "GEOMETRY") {
      /* A Geometry Nodes modifier without a node group gets one, rather than another modifier. */
      script =
          "ob = bpy.context.active_object\n"
          "md = ob.modifiers.active if ob is not None else None\n"
          "if md is not None and md.type == 'NODES' and md.node_group is None:\n"
          "    bpy.ops.node.new_geometry_node_group_assign()\n"
          "else:\n"
          "    bpy.ops.node.new_geometry_nodes_modifier()\n";
    }
    else if (command.value == "COMPOSITOR") {
      script =
          "before = set(bpy.data.node_groups)\n"
          "bpy.ops.node.new_compositing_node_group(name='Compositor Nodes')\n"
          "made = [g for g in bpy.data.node_groups if g not in before]\n"
          "if made:\n"
          "    bpy.context.scene.compositing_node_group = made[0]\n";
    }
#ifdef WITH_PYTHON
    if (!script.empty()) {
      BPY_run_string_exec(C, imports, script.c_str());
      ED_undo_push(C, "New Node Tree");
      WM_main_add_notifier(NC_NODE | NA_ADDED, nullptr);
    }
#else
    UNUSED_VARS(imports);
#endif
    bridge_panels_next_snapshot = {};
    return;
  }
  if (command.setting == "native_properties_state") {
    bridge_properties_state = command.value;
    bridge_panels_next_snapshot = {};
    bridge_panels_published.clear();
    return;
  }
  if (command.setting == "native_properties_edit" || command.setting == "native_panel_edit") {
    std::istringstream stream(command.value);
    auto value = io::serialize::JsonFormatter().deserialize(stream);
    if (const auto *request = value ? value->as_dictionary_value() : nullptr) {
      bridge_panels_sequence = request->lookup_int("sequence").value_or(bridge_panels_sequence);
      preview = request->lookup_str("phase").value_or("") == "update";
    }
    bridge_properties_error.clear();
  }
  if (command.setting == "native_properties_edit") {
    /* Local controls already show the drag value. Keep expensive full-panel snapshots
     * on their normal cadence while evaluation and viewport redraw run live. */
    if (!preview) {
      bridge_panels_next_snapshot = {};
    }
    /* While a stroke or other operator runs, only values arrive here, see #bridge_message_live;
     * their undo steps wait for it to end. */
#if defined(WITH_APPLE_CROSSPLATFORM) && APPLE_TARGET_IOS
    if (WM_apple_ios_dialog_active(CTX_wm_window(C))) {
      bridge_properties_error = "Finish the current dialog before editing properties.";
      return;
    }
#endif
    bridge_properties_error = ui::native_properties_query(C, command.value, true);
    CLOG_DEBUG(&LOG,
               "Properties edit %s -> %s",
               command.value.substr(0, 200).c_str(), bridge_properties_error.c_str());
    return;
  }
  if (command.setting == "native_panels") {
    bridge_panels_next_snapshot = {};
    bridge_panels_published.clear();
    /* Settings, open over the window, stays as it is. */
    bridge_panels_visible = (bridge_panels_visible & (32 | 64 | 128)) | (command.value == "3" ? 3 :
                                                     command.value == "2" ? 2 :
                                                     command.value == "1" ? 1 :
                                                                            0);
    return;
  }
#ifdef WITH_PYTHON
  if (command.setting == "keymap") {
    /* From the iPad's Settings, see `bl_ui.native_settings`. */
    const char *imports[] = {"bpy", "bl_ui", nullptr};
    const std::string expression = "bl_ui.native_settings.keymap_set(bpy.context, \"" +
                                   bridge_json_escape(command.value) + "\")";
    BPY_run_string_eval(C, imports, expression.c_str());
    return;
  }
  if (command.setting == "native_keymaps_state") {
    bridge_keymaps_state = command.value;
    bridge_panels_next_snapshot = {};
    return;
  }
  if (command.setting == "native_addon" || command.setting == "native_keymap_item_active") {
    /* Add-ons and keymap items, which Settings lists in its own way, see `bl_ui.native_settings`. */
    const char *imports[] = {"bpy", "bl_ui", nullptr};
    const std::string expression = "bl_ui.native_settings.command(bpy.context, \"" +
                                   command.setting.substr(strlen("native_")) + "\", \"" +
                                   bridge_json_escape(command.value) + "\")";
    BPY_run_string_eval(C, imports, expression.c_str());
    bridge_panels_next_snapshot = {};
    return;
  }
  if (command.setting == "render" || command.setting == "viewport_toggle") {
    /* Rendering and viewport options from the iPad's Share and More menus, see
     * `bl_ui.native_render`. */
    const BridgeContextStore context_store = bridge_context_push_view3d(C);
    const char *imports[] = {"bpy", "bl_ui", nullptr};
    std::string expression;
    if (command.setting == "viewport_toggle") {
      expression = "bl_ui.native_render.viewport_toggle(bpy.context, \"" +
                   bridge_json_escape(command.value) + "\")";
    }
    else if (command.value == "cancel") {
      WM_jobs_kill_type(CTX_wm_manager(C), nullptr, WM_JOB_TYPE_RENDER);
      expression = "bl_ui.native_render.cancel(bpy.context)";
    }
    else if (command.value == "clear") {
      expression = "bl_ui.native_render.clear(bpy.context)";
    }
    else {
      expression = std::string("bl_ui.native_render.start(bpy.context, ") +
                   (command.value == "animation" ? "True" : "False") + ")";
    }
    BPY_run_string_eval(C, imports, expression.c_str());
    bridge_context_pop(C, context_store);
    return;
  }
  if (command.setting == "native_brush") {
    /* The sidebar's size and strength, and the color well, see `bl_ui.native_brush`. A drag
     * sends many values and one undo step as it ends. */
    const BridgeContextStore context_store = bridge_context_push_view3d(C);
    const char *imports[] = {"bpy", "bl_ui", nullptr};
    const std::string expression = "bl_ui.native_brush.brush_set(bpy.context, \"" +
                                   bridge_json_escape(command.value) + "\")";
    BPY_run_string_eval(C, imports, expression.c_str());
    if (command.value.find("\"commit\":true") != std::string::npos) {
      ED_undo_push(C, "Brush Setting");
    }
    WM_main_add_notifier(NC_BRUSH | NA_EDITED, nullptr);
    bridge_context_pop(C, context_store);
    return;
  }
  if (command.setting == "rename_active") {
    /* Rename Active from the native interface, which asks for the name itself rather than
     * Blender's popup; see `bl_ui.native_actions.rename_active`. */
    const BridgeContextStore context_store = bridge_context_push_view3d(C);
    const char *imports[] = {"bpy", "bl_ui", nullptr};
    const std::string expression = "bl_ui.native_actions.rename_active(bpy.context, \"" +
                                   bridge_json_escape(command.value) + "\")";
    BPY_run_string_eval(C, imports, expression.c_str());
    ED_undo_push(C, "Rename");
    WM_main_add_notifier(NC_ID | NA_RENAME, nullptr);
    bridge_context_pop(C, context_store);
    return;
  }
  if (command.setting == "native_action") {
    /* The button may predate a context change; `run` checks the action still applies. */
    const bToolRef *tool = bridge_active_tool(C);
    const char *imports[] = {"bpy", "bl_ui", nullptr};
    const std::string expression = "bl_ui.native_actions.run(bpy.context, \"" +
                                   bridge_json_escape(command.value) + "\", \"" +
                                   bridge_json_escape(tool ? tool->idname : "") + "\")";
    BPY_run_string_eval(C, imports, expression.c_str());
    return;
  }
  if (command.setting == "native_panel_edit") {
    bridge_panels_next_snapshot = {};
    const char *imports[] = {"bpy", "bl_ui", nullptr};
    bool blocked = false;
#  if defined(WITH_APPLE_CROSSPLATFORM) && APPLE_TARGET_IOS
    blocked = WM_apple_ios_dialog_active(CTX_wm_window(C));
#  endif
    const std::string expression = "bl_ui.native_panels.apply_json(bpy.context, \"" +
                                   bridge_json_escape(command.value) + "\", " +
                                   (blocked ? "True" : "False") + ")";
    BPY_run_string_eval(C, imports, expression.c_str());
    return;
  }
#endif
  if (command.setting == "text_object_edit") {
    bridge_text_object_edit(C, command.value);
    return;
  }
  if (command.setting == "object_mode") {
    bridge_mode_set(C, command.value.c_str());
    return;
  }
  if (command.setting == "brush_direction") {
    bridge_brush_direction_set(C, command.value == "add");
    return;
  }
  if (command.setting == "constraint_axis") {
    const int axis = command.value == "X" ? 0 :
                     command.value == "Y" ? 1 :
                     command.value == "Z" ? 2 :
                                            -1;
    blender::ed::transform::modal_constraint_toggle(
        C, bridge_constraint_operator(CTX_wm_window(C)), axis);
    return;
  }
  Scene *scene = CTX_data_scene(C);
  ToolSettings *tool_settings = scene ? scene->toolsettings : nullptr;
  if (scene == nullptr || tool_settings == nullptr) {
    return;
  }

  /* The transform settings menus: Blender's own tool settings properties, set through RNA with
   * an undo step, as from the 3D Viewport's header. */
  PointerRNA tool_settings_ptr = RNA_pointer_create_discrete(
      &scene->id, RNA_ToolSettings, tool_settings);

  if (command.setting == "orientation") {
    PointerRNA slot_ptr = RNA_pointer_create_discrete(
        &scene->id, RNA_TransformOrientationSlot, &scene->orientation_slots[SCE_ORIENT_DEFAULT]);
    bridge_rna_undo_push(
        C, bridge_rna_enum_set(C, slot_ptr, "type", bridge_orientation_value_for_id(command.value)));
    return;
  }

  if (command.setting == "pivot") {
    bridge_rna_undo_push(
        C,
        bridge_rna_enum_set(
            C, tool_settings_ptr, "transform_pivot_point", bridge_pivot_value_for_id(command.value)));
    return;
  }

  if (command.setting == "snap") {
    if (command.value != "off") {
      bridge_rna_enum_set(C, tool_settings_ptr, "snap_elements", bridge_snap_mode_for_id(command.value));
    }
    bridge_rna_undo_push(
        C, bridge_rna_boolean_set(C, tool_settings_ptr, "use_snap", command.value != "off"));
    return;
  }

  if (command.setting == "mirror" || command.setting == "mirror_topology") {
    /* An axis, as the letter, or Topology Mirror: each a toggle, as in the Mirror popover. */
    std::optional<BridgeMirror> mirror = bridge_mirror(CTX_data_active_object(C), CTX_data_mode_enum(C));
    if (!mirror) {
      return;
    }
    if (command.setting == "mirror_topology") {
      if (mirror->topology) {
        PointerRNA &mesh = *mirror->topology;
        bridge_rna_undo_push(
            C,
            bridge_rna_boolean_set(
                C, mesh, "use_mirror_topology", !RNA_boolean_get(&mesh, "use_mirror_topology")));
      }
      return;
    }
    if (command.value.size() == 1 && strchr(mirror->letters, command.value[0])) {
      const std::string name = mirror->prefix + command.value;
      bridge_rna_undo_push(
          C,
          bridge_rna_boolean_set(
              C, mirror->axes, name.c_str(), !RNA_boolean_get(&mirror->axes, name.c_str())));
    }
    return;
  }

  if (command.setting == "proportional") {
    const bool enabled = command.value != "off";
    bridge_rna_boolean_set(C,
                        tool_settings_ptr,
                        CTX_data_mode_enum(C) == CTX_MODE_OBJECT ?
                            "use_proportional_edit_objects" :
                            "use_proportional_edit",
                        enabled);
    bridge_rna_boolean_set(
        C, tool_settings_ptr, "use_proportional_connected", command.value == "connected");
    bridge_rna_undo_push(
        C,
        bridge_rna_boolean_set(
            C, tool_settings_ptr, "use_proportional_projected", command.value == "projected"));
    return;
  }

  if (command.setting == "mesh_select_mode") {
    /* MESH_OT_select_mode notifies and pushes its own undo step. */
    bridge_mesh_select_mode_set(C, command.value);
    return;
  }

  if (command.setting == "assets") {
    /* The pane is listed only while shown; showing it publishes a fresh list. */
    bridge_assets_visible = command.value == "show";
    bridge_assets_json.clear();
    bridge_assets_next_snapshot = {};
    return;
  }

  if (command.setting == "timeline_visible") {
    bridge_timeline_visible = command.value == "1";
    bridge_timeline_next_keys = {};
    return;
  }

#ifdef WITH_PYTHON
  if (command.setting == "timeline_key_select" || command.setting == "timeline_key_move" ||
      command.setting == "timeline_key_delete")
  {
    /* Select "frames|extend" (frames comma separated), move the selected keys by a delta, or
     * delete the selected keys. Values are parsed here so nothing but numbers reaches Python. */
    std::string expression;
    if (command.setting == "timeline_key_select") {
      const size_t bar = command.value.find('|');
      std::string frames;
      const std::string list = command.value.substr(0, bar);
      for (size_t begin = 0; begin < list.size();) {
        const size_t comma = std::min(list.find(',', begin), list.size());
        if (comma > begin) {
          frames += (frames.empty() ? "" : ",") +
                    std::to_string(std::atoi(list.substr(begin, comma - begin).c_str()));
        }
        begin = comma + 1;
      }
      const bool extend = bar != std::string::npos && command.value.substr(bar + 1) == "1";
      expression = "bpy.ops.anim.native_key_select(frames=\"" + frames +
                   "\", extend=" + (extend ? "True" : "False") + ")";
    }
    else if (command.setting == "timeline_key_move") {
      expression = "bpy.ops.anim.native_key_move(delta=" +
                   std::to_string(std::atoi(command.value.c_str())) + ")";
    }
    else {
      expression = "bpy.ops.anim.native_key_delete()";
    }
    const char *imports[] = {"bpy", nullptr};
    BPY_run_string_eval(C, imports, expression.c_str());
    bridge_timeline_next_keys = {};
    return;
  }
#endif

  if (command.setting == "timeline_frame") {
    /* Scene.frame_current, as the timeline's own playhead sets it: its update clamps, moves the
     * sound and redraws. Like scrubbing in Blender, changing frames adds no undo step. */
    PointerRNA scene_ptr = RNA_id_pointer_create(&scene->id);
    PropertyRNA *prop = RNA_struct_find_property(&scene_ptr, "frame_current");
    RNA_property_int_set(&scene_ptr, prop, std::atoi(command.value.c_str()));
    RNA_property_update(C, &scene_ptr, prop);
    ED_areas_do_frame_follow(C, false);
    return;
  }

  if (command.setting == "timeline") {
    if (command.value == "autokey") {
      /* The timeline's record button: Blender's Auto Keying toggle. */
      Scene *scene = CTX_data_scene(C);
      if (scene == nullptr) {
        return;
      }
      PointerRNA ptr = RNA_pointer_create_discrete(
          &scene->id, RNA_ToolSettings, scene->toolsettings);
      PropertyRNA *prop = RNA_struct_find_property(&ptr, "use_keyframe_insert_auto");
      RNA_property_boolean_set(&ptr, prop, !RNA_property_boolean_get(&ptr, prop));
      RNA_property_update(C, &ptr, prop);
      bridge_rna_undo_push(C, prop);
      return;
    }
    if (command.value == "play") {
      bridge_operator_call(C, "SCREEN_OT_animation_play");
      return;
    }
    const bool jump = command.value == "start" || command.value == "end";
    const char *op_name = jump ? "SCREEN_OT_frame_jump" : "SCREEN_OT_keyframe_jump";
    wmOperatorType *ot = WM_operatortype_find(op_name, false);
    if (ot == nullptr || (!jump && command.value != "prev_key" && command.value != "next_key")) {
      return;
    }
    PointerRNA props = WM_operator_properties_create_ptr(ot);
    RNA_boolean_set(
        &props, jump ? "end" : "next", command.value == "end" || command.value == "next_key");
    bridge_operator_call(C, op_name, &props);
    WM_operator_properties_free(&props);
  }
}

void bridge_command_execute(bContext *C, BridgeCommand command)
{
  const BridgeContextStore context_store = bridge_context_push_view3d(C);
  if (CTX_wm_window(C) == nullptr || CTX_wm_area(C) == nullptr || CTX_wm_region(C) == nullptr) {
    bridge_context_pop(C, context_store);
    return;
  }

  switch (command) {
    case BridgeCommand::SetModeObject:
      bridge_mode_set(C, "OBJECT");
      break;
    case BridgeCommand::SetModeEdit:
      bridge_mode_set(C, "EDIT");
      break;
    case BridgeCommand::SetModeSculpt:
      bridge_mode_set(C, "SCULPT");
      break;
    case BridgeCommand::SetModeVertexPaint:
      bridge_mode_set(C, "VERTEX_PAINT");
      break;
    case BridgeCommand::SetModeWeightPaint:
      bridge_mode_set(C, "WEIGHT_PAINT");
      break;
    case BridgeCommand::SetModeTexturePaint:
      bridge_mode_set(C, "TEXTURE_PAINT");
      break;
    case BridgeCommand::SelectToolSelectBox:
      WM_toolsystem_ref_set_by_id(C, "builtin.select_box");
      break;
    case BridgeCommand::SelectToolCursor:
      WM_toolsystem_ref_set_by_id(C, "builtin.cursor");
      break;
    case BridgeCommand::SelectToolMove:
      WM_toolsystem_ref_set_by_id(C, "builtin.move");
      break;
    case BridgeCommand::SelectToolRotate:
      WM_toolsystem_ref_set_by_id(C, "builtin.rotate");
      break;
    case BridgeCommand::SelectToolScale:
      WM_toolsystem_ref_set_by_id(C, "builtin.scale");
      break;
    case BridgeCommand::SelectToolTransform:
      WM_toolsystem_ref_set_by_id(C, "builtin.transform");
      break;
    case BridgeCommand::SelectToolAnnotate:
      WM_toolsystem_ref_set_by_id(C, "builtin.annotate");
      break;
    case BridgeCommand::SelectToolMeasure:
      WM_toolsystem_ref_set_by_id(C, "builtin.measure");
      break;
    case BridgeCommand::FrameSelected:
      bridge_operator_call(C, "VIEW3D_OT_view_selected");
      break;
    case BridgeCommand::ResetView:
      bridge_view_axis(C, "FRONT");
      break;
    case BridgeCommand::OrbitLeft:
      bridge_view_orbit(C, "ORBITLEFT");
      break;
    case BridgeCommand::OrbitRight:
      bridge_view_orbit(C, "ORBITRIGHT");
      break;
    case BridgeCommand::OrbitUp:
      bridge_view_orbit(C, "ORBITUP");
      break;
    case BridgeCommand::OrbitDown:
      bridge_view_orbit(C, "ORBITDOWN");
      break;
    case BridgeCommand::SetViewportWireframe:
      bridge_viewport_shading_set(C, OB_WIRE);
      break;
    case BridgeCommand::SetViewportSolid:
      bridge_viewport_shading_set(C, OB_SOLID);
      break;
    case BridgeCommand::SetViewportMaterial:
      bridge_viewport_shading_set(C, OB_MATERIAL);
      break;
    case BridgeCommand::SetViewportRendered:
      bridge_viewport_shading_set(C, OB_RENDER);
      break;
    case BridgeCommand::ViewAll:
      bridge_operator_call(C, "VIEW3D_OT_view_all");
      break;
    case BridgeCommand::ViewLocal:
      bridge_operator_call(C, "VIEW3D_OT_localview");
      break;
    case BridgeCommand::ViewCamera:
      bridge_operator_call(C, "VIEW3D_OT_view_camera");
      break;
    case BridgeCommand::ViewPerspOrtho:
      bridge_operator_call(C, "VIEW3D_OT_view_persportho");
      break;
    case BridgeCommand::ViewFront:
      bridge_view_axis(C, "FRONT");
      break;
    case BridgeCommand::ViewBack:
      bridge_view_axis(C, "BACK");
      break;
    case BridgeCommand::ViewRight:
      bridge_view_axis(C, "RIGHT");
      break;
    case BridgeCommand::ViewLeft:
      bridge_view_axis(C, "LEFT");
      break;
    case BridgeCommand::ViewTop:
      bridge_view_axis(C, "TOP");
      break;
    case BridgeCommand::ViewBottom:
      bridge_view_axis(C, "BOTTOM");
      break;
  }

  bridge_context_pop(C, context_store);
}

void bridge_tool_set_by_id(bContext *C, const std::string &tool_id)
{
  if (tool_id.empty()) {
    return;
  }

  const BridgeContextStore context_store = bridge_context_push_view3d(C);
  if (CTX_wm_window(C) != nullptr && CTX_wm_area(C) != nullptr && CTX_wm_region(C) != nullptr) {
    WM_toolsystem_ref_set_by_id(C, tool_id.c_str());
  }
  bridge_context_pop(C, context_store);
}

/* -------------------------------------------------------------------- */
/** \name Native Brush Rail
 *
 * Projects the brush asset shelf of the current paint mode. Filtering, ordering of the asset
 * list, the active brush and activation all go through the shelf type, so the native rail lists
 * the same brushes as Blender's own asset shelf popup (without its per-tool filter).
 * \{ */

std::string bridge_brushes_json = "null";
std::chrono::steady_clock::time_point bridge_brushes_next_snapshot;
/* Session-lifetime PNG copies of brush previews, keyed like #bridge_brush_key(). An empty path means
 * the asset has no usable preview. */
std::map<std::string, std::string> bridge_brush_preview_paths;

const AssetShelfType *bridge_brush_shelf_type(const eContextObjectMode mode)
{
  /* The brush shelves of `space_view3d.py`, one for each mode that paints with brushes. */
  const char *idname = nullptr;
  switch (mode) {
    case CTX_MODE_SCULPT:
      idname = "VIEW3D_AST_brush_sculpt";
      break;
    case CTX_MODE_SCULPT_CURVES:
      idname = "VIEW3D_AST_brush_sculpt_curves";
      break;
    case CTX_MODE_PAINT_VERTEX:
      idname = "VIEW3D_AST_brush_vertex_paint";
      break;
    case CTX_MODE_PAINT_WEIGHT:
      idname = "VIEW3D_AST_brush_weight_paint";
      break;
    case CTX_MODE_PAINT_TEXTURE:
      idname = "VIEW3D_AST_brush_texture_paint";
      break;
    case CTX_MODE_PAINT_GREASE_PENCIL:
      idname = "VIEW3D_AST_brush_gpencil_paint";
      break;
    case CTX_MODE_SCULPT_GREASE_PENCIL:
      idname = "VIEW3D_AST_brush_gpencil_sculpt";
      break;
    case CTX_MODE_VERTEX_GREASE_PENCIL:
      idname = "VIEW3D_AST_brush_gpencil_vertex";
      break;
    case CTX_MODE_WEIGHT_GREASE_PENCIL:
      idname = "VIEW3D_AST_brush_gpencil_weight";
      break;
    default:
      return nullptr;
  }
  return ed::asset::shelf::type_find_from_idname(idname);
}

std::string bridge_brush_key(const AssetWeakReference &reference)
{
  std::string key = std::to_string(reference.asset_library_type);
  key += ":";
  key += reference.asset_library_identifier ? reference.asset_library_identifier : "";
  key += ":";
  key += reference.relative_asset_identifier ? reference.relative_asset_identifier : "";
  return key;
}

/**
 * Write the asset's preview to a PNG the native interface can load, or nothing yet while it loads. Previews of
 * assets in other files load in the background as in the Asset Browser: reading one opens its
 * whole file, too slow for the thread Blender runs on.
 */
std::optional<std::string> bridge_brush_preview_write(const bContext *C,
                                                   asset_system::AssetRepresentation &asset,
                                                   const std::string &key)
{
  asset.ensure_previewable();
  PreviewImage *preview = asset.get_preview();
  if (preview == nullptr || BKE_previewimg_is_invalid(preview, ICON_SIZE_PREVIEW)) {
    return "";
  }
  if (BKE_previewimg_is_rendering(preview, ICON_SIZE_PREVIEW)) {
    return std::nullopt;
  }
  if (!preview->rect[ICON_SIZE_PREVIEW]) {
    if (!preview->runtime->deferred_loading_data) {
      return "";
    }
    ED_preview_icon_job(C, preview, nullptr, ICON_SIZE_PREVIEW, false);
    return std::nullopt;
  }
  const uint8_t *pixels = reinterpret_cast<const uint8_t *>(preview->rect[ICON_SIZE_PREVIEW]);
  const unsigned int width = preview->w[ICON_SIZE_PREVIEW];
  const unsigned int height = preview->h[ICON_SIZE_PREVIEW];
  if (pixels == nullptr || width == 0 || height == 0) {
    return "";
  }

  char directory[FILE_MAX];
  BLI_path_join(directory, sizeof(directory), BKE_tempdir_session(), "brush_previews");
  if (!BLI_dir_create_recursive(directory)) {
    return "";
  }
  char filepath[FILE_MAX];
  const std::string filename = std::to_string(std::hash<std::string>{}(key)) + ".png";
  BLI_path_join(filepath, sizeof(filepath), directory, filename.c_str());

  ImBuf *ibuf = IMB_allocFromBuffer(pixels, nullptr, width, height, 4);
  if (ibuf == nullptr) {
    return "";
  }
  /* Previews are premultiplied, PNG is not. */
  IMB_unpremultiply_alpha(ibuf);
  ibuf->ftype = IMB_FTYPE_PNG;
  ibuf->planes = 32;
  const bool saved = IMB_save_image(ibuf, filepath, IB_byte_data);
  IMB_freeImBuf(ibuf);
  return saved ? filepath : "";
}

std::string bridge_brushes_build_json(bContext *C, const eContextObjectMode mode)
{
  const AssetShelfType *shelf_type = bridge_brush_shelf_type(mode);
  Paint *paint = BKE_paint_get_active_from_context(C);
  if (shelf_type == nullptr || paint == nullptr) {
    return "null";
  }

  const AssetLibraryReference library_ref = asset_system::all_library_reference();
  ed::asset::list::storage_fetch(&library_ref, C);
  if (!ed::asset::list::is_loaded(&library_ref)) {
    /* Keep the previous list while the asset libraries are (re)loading. */
    return bridge_brushes_json == "null" ? "{\"loading\":true,\"items\":[]}" : bridge_brushes_json;
  }

  struct BrushItem {
    std::string key;
    std::string name;
    std::string catalog;
    std::string preview;
  };
  std::vector<BrushItem> items;
  /* Previews load in the background; writing their PNGs is spread over several snapshots. */
  int preview_budget = 8;
  bool previews_missing = false;
  ed::asset::list::iterate(library_ref, [&](asset_system::AssetRepresentation &asset) {
    if (!ed::asset::shelf::type_asset_poll(*shelf_type, asset)) {
      return true;
    }
    BrushItem item;
    item.key = bridge_brush_key(asset.make_weak_reference());
    item.name = asset.get_name();
    if (const asset_system::AssetCatalog *catalog =
            asset.owner_asset_library().catalog_service().find_catalog(
                asset.get_metadata().catalog_id))
    {
      item.catalog = catalog->path.str();
    }
    auto preview = bridge_brush_preview_paths.find(item.key);
    if (preview == bridge_brush_preview_paths.end() && preview_budget > 0) {
      preview_budget--;
      if (std::optional<std::string> path = bridge_brush_preview_write(C, asset, item.key)) {
        preview = bridge_brush_preview_paths.emplace(item.key, *path).first;
      }
    }
    if (preview != bridge_brush_preview_paths.end()) {
      item.preview = preview->second;
    }
    else {
      previews_missing = true;
    }
    items.push_back(std::move(item));
    return true;
  });
  /* Group by catalog like the shelf's catalog tabs; uncatalogued brushes go last. */
  std::stable_sort(items.begin(), items.end(), [](const BrushItem &a, const BrushItem &b) {
    if (a.catalog.empty() != b.catalog.empty()) {
      return b.catalog.empty();
    }
    return a.catalog < b.catalog;
  });

  const std::string active = paint->brush_asset_reference ?
                                 bridge_brush_key(*paint->brush_asset_reference) :
                                 "";
  std::string json = "{\"shelf\":\"";
  json += bridge_json_escape(shelf_type->idname);
  json += "\",\"active\":\"";
  json += bridge_json_escape(active);
  json += "\",\"pending\":";
  json += previews_missing ? "true" : "false";
  json += ",\"items\":[";
  for (size_t i = 0; i < items.size(); i++) {
    const BrushItem &item = items[i];
    if (i > 0) {
      json += ",";
    }
    const std::string catalog_name = item.catalog.substr(item.catalog.rfind('/') + 1);
    json += "{\"id\":\"" + bridge_json_escape(item.key) + "\",\"title\":\"" +
            bridge_json_escape(item.name) + "\",\"catalog\":\"" + bridge_json_escape(catalog_name) +
            "\",\"preview\":\"" + bridge_json_escape(item.preview) + "\"}";
  }
  json += "]}";
  return json;
}

/** Modes that stroke brushes, where the + and - pill picks the stroke's direction. */
bool bridge_mode_strokes(const eContextObjectMode mode)
{
  return ELEM(mode,
              CTX_MODE_SCULPT,
              CTX_MODE_PAINT_WEIGHT,
              CTX_MODE_PAINT_VERTEX,
              CTX_MODE_PAINT_TEXTURE,
              CTX_MODE_SCULPT_CURVES,
              CTX_MODE_SCULPT_GREASE_PENCIL,
              CTX_MODE_WEIGHT_GREASE_PENCIL,
              CTX_MODE_VERTEX_GREASE_PENCIL);
}

/** The active brush's Direction, for sculpt brushes that have one. */
std::optional<PointerRNA> bridge_brush_direction_ptr(bContext *C)
{
  if (CTX_data_mode_enum(C) != CTX_MODE_SCULPT) {
    return std::nullopt;
  }
  Paint *paint = BKE_paint_get_active_from_context(C);
  Brush *brush = paint ? BKE_paint_brush(paint) : nullptr;
  if (brush == nullptr) {
    return std::nullopt;
  }
  PointerRNA brush_ptr = RNA_id_pointer_create(&brush->id);
  PointerRNA capabilities = RNA_pointer_get(&brush_ptr, "sculpt_capabilities");
  if (!RNA_boolean_get(&capabilities, "has_direction")) {
    return std::nullopt;
  }
  return brush_ptr;
}

/** Symbols for a brush's two Direction choices, by their untranslated names, one mirroring the
 * other. Up and down for a pair without its own. */
static std::pair<const char *, const char *> bridge_brush_direction_symbols(const char *add,
                                                                         const char *subtract)
{
  struct Pair {
    const char *add, *subtract, *add_symbol, *subtract_symbol;
  };
  static const Pair pairs[] = {
      {"Smooth", "Enhance Details", "drop.halffull", "sparkles"},
      {"Sharpen", "Soften", "sparkles", "drop.halffull"},
      {"Magnify",
       "Pinch",
       "arrow.left.and.line.vertical.and.arrow.right",
       "arrow.right.and.line.vertical.and.arrow.left"},
      {"Pinch",
       "Inflate",
       "arrow.right.and.line.vertical.and.arrow.left",
       "arrow.left.and.line.vertical.and.arrow.right"},
      {"Inflate", "Deflate", "largecircle.fill.circle", "smallcircle.filled.circle"},
      {"Counter-Clockwise", "Clockwise", "arrow.counterclockwise", "arrow.clockwise"},
  };
  for (const Pair &pair : pairs) {
    if (STREQ(add, pair.add) && STREQ(subtract, pair.subtract)) {
      return {pair.add_symbol, pair.subtract_symbol};
    }
  }
  return {"arrowshape.up", "arrowshape.down"};
}

/**
 * The + and - pill in modes that stroke brushes: which way strokes go, and for brushes with a
 * Direction, its two choices' names (such as Inflate and Deflate) and symbols. Painting colors
 * has no two ways to go, and hides it, as do drawing Grease Pencil strokes and tools that never
 * select. Null elsewhere, where the pill adds to or subtracts from the selection. In Sculpt
 * Mode, "smooth" adds a Smooth button to hold, as Shift is with a keyboard.
 */
std::string bridge_direction_json(bContext *C, const eContextObjectMode mode)
{
  if (!bridge_mode_strokes(mode)) {
    /* Drawing Grease Pencil strokes, and the tools that never select, such as the 3D Cursor,
     * have nothing to add to or subtract from: no pill. */
    const bToolRef *tref = WM_toolsystem_ref_from_context(C);
    const StringRef tool = tref ? StringRef(tref->idname) : StringRef();
    if (mode == CTX_MODE_PAINT_GREASE_PENCIL ||
        ELEM(tool, "builtin.cursor", "builtin.measure") || tool.startswith("builtin.annotate") ||
        tool.startswith("builtin.primitive_"))
    {
      return "{\"hidden\":true}";
    }
    return "null";
  }
  std::optional<PointerRNA> brush_ptr = bridge_brush_direction_ptr(C);
  if (!brush_ptr) {
    const bool colors = ELEM(mode,
                             CTX_MODE_SCULPT,
                             CTX_MODE_PAINT_TEXTURE,
                             CTX_MODE_PAINT_VERTEX,
                             CTX_MODE_VERTEX_GREASE_PENCIL);
    if (mode == CTX_MODE_SCULPT) {
      return "{\"hidden\":true,\"smooth\":true}";
    }
    return colors ? "{\"hidden\":true}" : "{\"brush\":false}";
  }
  PropertyRNA *prop = RNA_struct_find_property(&*brush_ptr, "direction");
  const EnumPropertyItem *items = nullptr;
  int count = 0;
  bool free = false;
  RNA_property_enum_items_gettexted(C, &*brush_ptr, prop, &items, &count, &free);
  std::string names[2];
  for (int i = 0, n = 0; i < count && n < 2; i++) {
    if (items[i].identifier[0] != '\0') {
      names[n++] = items[i].name;
    }
  }
  if (free) {
    MEM_delete(items);
  }
  /* Symbols go by the untranslated names. */
  const char *untranslated[2] = {"", ""};
  RNA_property_enum_items(C, &*brush_ptr, prop, &items, &count, &free);
  for (int i = 0, n = 0; i < count && n < 2; i++) {
    if (items[i].identifier[0] != '\0') {
      untranslated[n++] = items[i].name;
    }
  }
  auto [add_symbol, subtract_symbol] = bridge_brush_direction_symbols(untranslated[0],
                                                                   untranslated[1]);
  if (free) {
    MEM_delete(items);
  }
  const Brush *brush = static_cast<const Brush *>(brush_ptr->data);
  /* Sculpting adds to the surface or carves into it, drawn by the app as a bulge out or in. */
  if (mode == CTX_MODE_SCULPT && brush->sculpt_brush_type != SCULPT_BRUSH_TYPE_MASK &&
      STREQ(untranslated[0], "Add") && STREQ(untranslated[1], "Subtract"))
  {
    add_symbol = "bulge.out";
    subtract_symbol = "bulge.in";
  }
  return "{\"brush\":true,\"inverted\":" +
         std::string((brush->flag & BRUSH_DIR_IN) ? "true" : "false") + ",\"add\":\"" +
         bridge_json_escape(names[0]) + "\",\"subtract\":\"" + bridge_json_escape(names[1]) +
         "\",\"addSymbol\":\"" + add_symbol + "\",\"subtractSymbol\":\"" + subtract_symbol +
         "\",\"smooth\":" + (mode == CTX_MODE_SCULPT ? "true" : "false") + "}";
}

/** Set the active brush's Direction to its first (\a add) or second choice. */
void bridge_brush_direction_set(bContext *C, const bool add)
{
  const BridgeContextStore context_store = bridge_context_push_view3d(C);
  std::optional<PointerRNA> brush_ptr = bridge_brush_direction_ptr(C);
  if (!brush_ptr) {
    return;
  }
  PropertyRNA *prop = RNA_struct_find_property(&*brush_ptr, "direction");
  const EnumPropertyItem *items = nullptr;
  int count = 0;
  bool free = false;
  RNA_property_enum_items(C, &*brush_ptr, prop, &items, &count, &free);
  int values[2] = {0, 0};
  for (int i = 0, n = 0; i < count && n < 2; i++) {
    if (items[i].identifier[0] != '\0') {
      values[n++] = items[i].value;
    }
  }
  if (free) {
    MEM_delete(items);
  }
  bridge_rna_undo_push(C, bridge_rna_enum_set(C, *brush_ptr, "direction", values[add ? 0 : 1]));
}

void bridge_brush_activate(bContext *C, const std::string &key)
{
  const BridgeContextStore context_store = bridge_context_push_view3d(C);
  const AssetShelfType *shelf_type = CTX_wm_area(C) && CTX_wm_region(C) ?
                                         bridge_brush_shelf_type(CTX_data_mode_enum(C)) :
                                         nullptr;
  wmOperatorType *ot = shelf_type ?
                           WM_operatortype_find(shelf_type->activate_operator.c_str(), true) :
                           nullptr;
  if (ot) {
    const AssetLibraryReference library_ref = asset_system::all_library_reference();
    ed::asset::list::iterate(library_ref, [&](asset_system::AssetRepresentation &asset) {
      if (bridge_brush_key(asset.make_weak_reference()) != key) {
        return true;
      }
      /* Same call as activating an item of the asset shelf. */
      PointerRNA props = WM_operator_properties_create_ptr(ot);
      ed::asset::operator_asset_reference_props_set(asset, props);
      WM_operator_name_call_ptr(C, ot, wm::OpCallContext::InvokeRegionWin, &props, nullptr);
      WM_operator_properties_free(&props);
      return false;
    });
  }
  bridge_context_pop(C, context_store);
  /* Publish the new active brush with the next snapshot. */
  bridge_brushes_next_snapshot = {};
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Native Asset Pane
 *
 * Projects the assets of every library for the native asset pane. Dropping an asset into the
 * viewport goes through Blender's own drag and drop: a native drag starts a regular asset drag
 * and feeds it pointer moves and the release, so the viewport's drop boxes preview, snap, import
 * and add the asset exactly as dragging it from Blender's Asset Browser does.
 * \{ */

/**
 * Assets the viewport accepts as drops. Brushes have their own rail. Node groups are listed only
 * when they are Geometry Nodes modifiers, the same check as Blender's Add Modifier menu.
 */
bool bridge_asset_listed(const asset_system::AssetRepresentation &asset)
{
  const ID_Type type = asset.get_id_type();
  if (ELEM(type, ID_OB, ID_GR, ID_MA, ID_WO)) {
    return true;
  }
  if (type != ID_NT) {
    return false;
  }
  const AssetMetaData &metadata = asset.get_metadata();
  const IDProperty *tree_type = BKE_asset_metadata_idprop_find(&metadata, "type");
  const IDProperty *traits = BKE_asset_metadata_idprop_find(&metadata,
                                                            "geometry_node_asset_traits_flag");
  return tree_type && IDP_int_get(tree_type) == NTREE_GEOMETRY && traits &&
         (IDP_int_get(traits) & GEO_NODE_ASSET_MODIFIER);
}

/** The pane's type name: listed node groups are modifiers. */
const char *bridge_asset_type_name(const ID_Type type)
{
  return type == ID_NT ? "Modifier" : BKE_idtype_idcode_to_name(type);
}

std::string bridge_asset_library_name(asset_system::AssetLibrary &library)
{
  switch (library.library_type()) {
    case ASSET_LIBRARY_LOCAL:
      return "Current File";
    case ASSET_LIBRARY_ESSENTIALS:
      return "Essentials";
    default:
      return library.name();
  }
}

std::string bridge_assets_build_json(bContext *C)
{
  const AssetLibraryReference library_ref = asset_system::all_library_reference();
  ed::asset::list::storage_fetch(&library_ref, C);
  if (!ed::asset::list::is_loaded(&library_ref)) {
    /* Keep the previous list while the asset libraries are (re)loading. */
    return bridge_assets_json.empty() ? "{\"loading\":true,\"items\":[]}" : bridge_assets_json;
  }

  std::string items;
  /* Previews load in the background; writing their PNGs is spread over several snapshots. */
  int preview_budget = 8;
  bool previews_missing = false;
  ed::asset::list::iterate(library_ref, [&](asset_system::AssetRepresentation &asset) {
    if (!bridge_asset_listed(asset)) {
      return true;
    }
    const ID_Type type = asset.get_id_type();
    const std::string key = bridge_brush_key(asset.make_weak_reference());
    const AssetMetaData &metadata = asset.get_metadata();
    asset_system::AssetLibrary &library = asset.owner_asset_library();
    std::string catalog;
    if (const asset_system::AssetCatalog *found = library.catalog_service().find_catalog(
            metadata.catalog_id))
    {
      catalog = found->path.str();
    }
    auto preview = bridge_brush_preview_paths.find(key);
    if (preview == bridge_brush_preview_paths.end() && preview_budget > 0) {
      preview_budget--;
      if (std::optional<std::string> path = bridge_brush_preview_write(C, asset, key)) {
        preview = bridge_brush_preview_paths.emplace(key, *path).first;
      }
    }
    if (preview == bridge_brush_preview_paths.end()) {
      previews_missing = true;
    }
    std::string tags;
    for (const AssetTag &tag : metadata.tags) {
      tags += tags.empty() ? "\"" : ",\"";
      tags += bridge_json_escape(tag.name) + "\"";
    }
    items += items.empty() ? "{" : ",{";
    items += "\"id\":\"" + bridge_json_escape(key) + "\",\"name\":\"" +
             bridge_json_escape(asset.get_name()) + "\",\"type\":\"" +
             bridge_json_escape(bridge_asset_type_name(type)) + "\",\"library\":\"" +
             bridge_json_escape(bridge_asset_library_name(library)) + "\",\"catalog\":\"" +
             bridge_json_escape(catalog) + "\",\"description\":\"" +
             bridge_json_escape(metadata.description ? metadata.description : "") +
             "\",\"author\":\"" + bridge_json_escape(metadata.author ? metadata.author : "") +
             "\",\"tags\":[" + tags + "],\"preview\":\"" +
             bridge_json_escape(preview != bridge_brush_preview_paths.end() ? preview->second : "") +
             "\"}";
    return true;
  });
  return std::string("{\"pending\":") + (previews_missing ? "true" : "false") + ",\"items\":[" +
         items + "]}";
}

void bridge_assets_build(bContext *C)
{
  if (!bridge_assets_visible) {
    return;
  }
  const auto now = std::chrono::steady_clock::now();
  if (now < bridge_assets_next_snapshot) {
    return;
  }
  /* Asset lists change rarely; keep loading previews quickly while some are missing. */
  std::string json = bridge_assets_build_json(C);
  const bool busy = json.find("\"pending\":true") != std::string::npos ||
                    json.find("\"loading\":true") != std::string::npos;
  bridge_assets_next_snapshot = now + std::chrono::milliseconds(busy ? 40 : 500);
  if (json != bridge_assets_json) {
    bridge_assets_json = json;
    bridge_record("Assets", json);
    bridge_assets_snapshot.publish(std::move(json));
  }
}

asset_system::AssetRepresentation *bridge_asset_find(const std::string &key)
{
  asset_system::AssetRepresentation *result = nullptr;
  ed::asset::list::iterate(asset_system::all_library_reference(),
                           [&](asset_system::AssetRepresentation &asset) {
                             if (bridge_brush_key(asset.make_weak_reference()) != key) {
                               return true;
                             }
                             result = &asset;
                             return false;
                           });
  return result;
}

/** Start a drag of \a asset, as the Asset Browser and asset shelf do. */
void bridge_asset_drag_start(bContext *C, asset_system::AssetRepresentation &asset)
{
  if (ID *local_id = asset.local_id()) {
    WM_event_start_drag(C, ICON_NONE, WM_DRAG_ID, local_id, WM_DRAG_NOP);
    return;
  }
  eAssetImportMethod import_method = asset.get_import_method().value_or(ASSET_IMPORT_PACK);
  if (U.experimental.no_data_block_packing && import_method == ASSET_IMPORT_PACK) {
    import_method = ASSET_IMPORT_APPEND_REUSE;
  }
  AssetImportSettings import_settings{};
  import_settings.method = import_method;
  import_settings.use_instance_collections = false;
  WM_event_start_drag(C,
                      ICON_NONE,
                      WM_DRAG_ASSET,
                      WM_drag_create_asset_data(&asset, import_settings),
                      WM_DRAG_FREE_DATA);
}

/** Queue a pointer event at window coordinates \a xy, after the events already queued. */
void bridge_asset_drag_event(wmWindow *win, const int xy[2], const wmEventType type, const short val)
{
  wmEvent event = *win->runtime->eventstate;
  event.type = type;
  event.val = val;
  event.flag = eWM_EventFlag(0);
  event.custom = 0;
  event.customdata = nullptr;
  event.customdata_free = false;
  copy_v2_v2_int(event.prev_xy, win->runtime->eventstate->xy);
  copy_v2_v2_int(event.xy, xy);
  copy_v2_v2_int(win->runtime->eventstate->xy, xy);
  WM_event_add(win, &event);
}

/** Where tapping an asset adds it: the 3D cursor, or the active object for data it takes. */
bool bridge_asset_add_location(bContext *C, const ID_Type type, int r_xy[2])
{
  ARegion *region = CTX_wm_region(C);
  Scene *scene = CTX_data_scene(C);
  if (!region || region->regiontype != RGN_TYPE_WINDOW || !scene) {
    return false;
  }
  float3 location = scene->cursor.location;
  if (ELEM(type, ID_MA, ID_NT)) {
    Object *object = CTX_data_active_object(C);
    if (!object) {
      WM_global_report(RPT_WARNING,
                       type == ID_MA ? "Select an object to apply the material to" :
                                       "Select an object to add the modifier to");
      return false;
    }
    location = object->object_to_world().location();
  }
  float2 region_xy;
  if (ED_view3d_project_float_global(region, location, region_xy, V3D_PROJ_TEST_NOP) !=
      V3D_PROJ_RET_OK)
  {
    region_xy = float2(region->winx, region->winy) * 0.5f;
  }
  r_xy[0] = region->winrct.xmin + int(region_xy.x);
  r_xy[1] = region->winrct.ymin + int(region_xy.y);
  return true;
}

/** Name of the bundled library of starter assets, in `datafiles/starter_assets`. */
constexpr const char *BRIDGE_STARTER_LIBRARY_NAME = "Starter";

/**
 * Bring the drop's snap target up to date at window coordinates \a xy. Drops place objects with
 * the snap data the viewport computes while drawing; a quick drag or a tap can be released before
 * the viewport has drawn at that point.
 */
void bridge_asset_drop_snap_update(bContext *C, const int xy[2])
{
  ARegion *region = CTX_wm_region(C);
  if (!region || region->regiontype != RGN_TYPE_WINDOW || !CTX_wm_view3d(C)) {
    return;
  }
  V3DSnapCursorState *state = ED_view3d_cursor_snap_state_active_get();
  if (!state) {
    return;
  }
  const int2 mval(xy[0] - region->winrct.xmin, xy[1] - region->winrct.ymin);
  ED_view3d_cursor_snap_data_update(state, C, region, mval);
}

void bridge_asset_drag(bContext *C, const BridgeAssetDragCommand &command)
{
  const BridgeContextStore context_store = bridge_context_push_view3d(C);
  wmWindowManager *wm = CTX_wm_manager(C);
  wmWindow *win = CTX_wm_window(C);
  if (!win || !win->runtime->eventstate) {
    bridge_context_pop(C, context_store);
    return;
  }
  const bool dragging = !BLI_listbase_is_empty(&wm->runtime->drags);
  int xy[2] = {command.x, command.y};
  if (!ELEM(command.phase, BRIDGE_ASSET_ADD, BRIDGE_ASSET_ADD_RELEASE)) {
    wm_cursor_position_from_ghost_client_coords(win, &xy[0], &xy[1]);
  }

  switch (command.phase) {
    case BRIDGE_ASSET_DRAG_BEGIN:
    case BRIDGE_ASSET_ADD: {
      asset_system::AssetRepresentation *asset = bridge_asset_find(command.key);
      if (!asset || dragging ||
          (command.phase == BRIDGE_ASSET_ADD && !bridge_asset_add_location(C, asset->get_id_type(), xy)))
      {
        break;
      }
      bridge_asset_drag_start(C, *asset);
      bridge_asset_drag_xy = int2(xy[0], xy[1]);
      bridge_asset_drag_event(win, xy, MOUSEMOVE, KM_NOTHING);
      if (command.phase == BRIDGE_ASSET_ADD) {
        /* Release on the next update, once the move has entered the drop box and its snap
         * target exists, as when a finger lifts after a drag. */
        bridge_messages.push(BridgeAssetDragCommand{BRIDGE_ASSET_ADD_RELEASE, "", xy[0], xy[1]});
      }
      break;
    }
    case BRIDGE_ASSET_ADD_RELEASE:
      if (dragging) {
        bridge_asset_drop_snap_update(C, xy);
        bridge_asset_drag_event(win, xy, LEFTMOUSE, KM_RELEASE);
      }
      break;
    case BRIDGE_ASSET_DRAG_MOVE:
      if (dragging) {
        bridge_asset_drag_xy = int2(xy[0], xy[1]);
        bridge_asset_drag_event(win, xy, MOUSEMOVE, KM_NOTHING);
      }
      break;
    case BRIDGE_ASSET_DRAG_DROP:
      if (dragging) {
        /* The release over a drop box becomes #EVT_DROP, as when releasing a dragged button. */
        bridge_asset_drop_snap_update(C, xy);
        bridge_asset_drag_event(win, xy, MOUSEMOVE, KM_NOTHING);
        bridge_asset_drag_event(win, xy, LEFTMOUSE, KM_RELEASE);
      }
      break;
    case BRIDGE_ASSET_DRAG_CANCEL:
      if (dragging) {
        /* Escape cancels a drag; queued, it also follows any pending moves. */
        bridge_asset_drag_event(win, win->runtime->eventstate->xy, EVT_ESCKEY, KM_PRESS);
      }
      break;
  }
  bridge_context_pop(C, context_store);
}

/** \} */

std::string bridge_toolbar_build_json_for_context(bContext *C)
{
  const BridgeContextStore context_store = bridge_context_push_view3d(C);
  const bool has_view3d_context = CTX_wm_window(C) != nullptr && CTX_wm_area(C) != nullptr &&
                                  CTX_wm_region(C) != nullptr;
  Scene *scene = has_view3d_context ? CTX_data_scene(C) : nullptr;
  ToolSettings *tool_settings = scene ? scene->toolsettings : nullptr;
  const eContextObjectMode mode = has_view3d_context ? CTX_data_mode_enum(C) : CTX_MODE_OBJECT;
  const char *mode_string = has_view3d_context ? CTX_data_mode_string(C) : "objectmode";
  const View3D *view3d = has_view3d_context ? CTX_wm_view3d(C) : nullptr;
  const char *shading = "solid";
  if (view3d) {
    switch (view3d->shading.type) {
      case OB_WIRE:
        shading = "wireframe";
        break;
      case OB_MATERIAL:
        shading = "material";
        break;
      case OB_RENDER:
        shading = "rendered";
        break;
      default:
        break;
    }
  }
  std::string object_modes_json = "[]";
  const char *object_mode = "OBJECT";
  /* What Rename Active renames, for the native field to start from: the active bone in an
   * armature's modes, otherwise the active object. */
  std::string active_name;
  if (has_view3d_context) {
    object_modes_json = bridge_object_modes_json(C);
    if (const Object *active = CTX_data_active_object(C)) {
      RNA_enum_identifier(rna_enum_object_mode_items, active->mode, &object_mode);
      active_name = active->id.name + 2;
    }
    if (mode == CTX_MODE_POSE) {
      if (const bPoseChannel *pchan = CTX_data_active_pose_bone(C)) {
        active_name = pchan->name;
      }
    }
    else if (mode == CTX_MODE_EDIT_ARMATURE) {
      if (const EditBone *ebone = CTX_data_active_bone(C)) {
        active_name = ebone->name;
      }
    }
  }
  const std::string mesh_select_mode = mode == CTX_MODE_EDIT_MESH ?
                                           bridge_mesh_select_mode_string(tool_settings) :
                                           "";
  bToolRef *active_tool = has_view3d_context ? bridge_active_tool(C) : nullptr;
  const char *active_tool_id = active_tool ? active_tool->idname : "builtin.select_box";
  std::string tools_json = "[]";
  std::string panels_json = "null";
  std::string render_json = "null";
  std::string viewport_json = "null";
  std::string preferences_json = "null";
  std::string brush_json = "null";
  std::string quick_actions_json;
#ifdef WITH_PYTHON
  if (has_view3d_context) {
    const char *imports[] = {"bpy", "bl_ui", nullptr};
    /* Dragging with Move and the like selects rather than tweaking, see the function. */
    BPY_run_string_eval(
        C, imports, "bl_ui.space_toolsystem_common.native_select_fallback_keep(bpy.context)");
    bridge_python(C,
                  "tools",
                  "bl_ui.space_toolsystem_common.native_toolbar_json(bpy.context)",
                  tools_json);
    bridge_python(C, "render", "bl_ui.native_render.status_json(bpy.context)", render_json);
    bridge_python(C, "viewport", "bl_ui.native_render.viewport_json(bpy.context)", viewport_json);
    bridge_python(
        C, "preferences", "bl_ui.native_settings.preferences_json(bpy.context)", preferences_json);
    bridge_python(C, "brush", "bl_ui.native_brush.brush_json(bpy.context)", brush_json);
    if (!bridge_constraint_operator(CTX_wm_window(C))) {
      /* Quick actions for the mode, tool and selection, chosen by `bl_ui.native_actions`. */
      const std::string expression = "bl_ui.native_actions.actions_json(bpy.context, \"" +
                                     bridge_json_escape(active_tool_id ? active_tool_id : "") + "\")";
      bridge_python(C, "actions", expression.c_str(), quick_actions_json);
    }
    const auto now = std::chrono::steady_clock::now();
    if (bridge_panels_visible && now >= bridge_panels_next_snapshot) {
      /* Scene projection follows the native refresh cadence, not the viewport frame rate. */
      bridge_panels_next_snapshot = now + std::chrono::milliseconds(250);
      BridgeTimer panels_timer("panels");
      const std::string expression = "bl_ui.native_panels.snapshot_json(bpy.context, " +
                                     std::to_string(bridge_panels_visible & 2) + ")";
      bridge_python(C, "panels.hierarchy", expression.c_str(), bridge_panels_json);
      using namespace io::serialize;
      std::istringstream base_stream(bridge_panels_json);
      auto base = JsonFormatter().deserialize(base_stream);
      DictionaryValue merged;
      if (const auto *dictionary = base ? base->as_dictionary_value() : nullptr) {
        for (const auto &item : dictionary->elements()) {
          if (item.first != "ack" && (item.first != "error" || bridge_properties_error.empty())) {
            merged.append(item.first, item.second);
          }
        }
      }
      merged.append_int("ack", bridge_panels_sequence);
      if (!bridge_properties_error.empty()) {
        merged.append_str("error", bridge_properties_error);
      }
      if (bridge_panels_visible & 1) {
        std::istringstream properties_stream(bridge_timed("panels.inspector", [&] {
          return ui::native_properties_query(C, bridge_properties_state, false);
        }));
        auto properties = JsonFormatter().deserialize(properties_stream);
        if (properties) {
          merged.append("inspector", std::move(properties));
        }
      }
      if (bridge_panels_visible & 8) {
        /* Another object, material or modifier chosen anywhere shows straight away. */
        std::string identity = ui::native_nodes_identity(C, bridge_nodes_state);
        if (identity != bridge_nodes_identity) {
          bridge_nodes_identity = std::move(identity);
          bridge_nodes_dirty = true;
        }
        if (bridge_nodes_dirty || now >= bridge_nodes_next_check) {
          bridge_nodes_dirty = false;
          bridge_nodes_next_check = now + std::chrono::seconds(2);
          std::string state = bridge_nodes_state;
          const bool with_add = state != bridge_nodes_add_for;
          if (with_add) {
            /* The nodes it can add, once for each tree. */
            state.insert(state.size() - 1, ",\"with_add\":1");
          }
          const auto diag_start = std::chrono::steady_clock::now();
          bridge_nodes_json = bridge_timed(
              "panels.nodes", [&] { return ui::native_nodes_query(C, state, false); });
          /* With no tree there is nothing to add to: offered again once there is one. */
          const bool has_tree = bridge_nodes_json.find("\"nodes\"") != std::string::npos;
          bridge_nodes_add_for = has_tree ? (with_add ? bridge_nodes_state : bridge_nodes_add_for) : "";
          CLOG_DEBUG(&LOG,
                     "Nodes read in %lld ms, %zu bytes: %s",
                 (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
                     std::chrono::steady_clock::now() - diag_start)
                     .count(),
                 bridge_nodes_json.size(), bridge_nodes_json.substr(0, 160).c_str());
          if (bridge_nodes_composite) {
            bridge_nodes_composite = false;
            ui::native_nodes_compositor_job(C);
          }
        }
        /* Spliced in as it is below, rather than read and written again: it is large. */
        merged.append_str("nodes", "@native_nodes_json@");
      }
      if (bridge_panels_visible & 16) {
        if (bridge_graph_dirty || now >= bridge_graph_next_check) {
          bridge_graph_dirty = false;
          bridge_graph_next_check = now + std::chrono::seconds(2);
          bridge_graph_json = bridge_timed("panels.graph", [&] {
            return ed::graph::native_graph_query(C, bridge_graph_state, false);
          });
        }
        merged.append_str("graph", "@native_graph_json@");
      }
      if (bridge_panels_visible & 128) {
        if (bridge_image_dirty || now >= bridge_image_next_check) {
          bridge_image_dirty = false;
          bridge_image_next_check = now + std::chrono::seconds(2);
          bridge_image_json = bridge_timed("panels.image", [&] {
            return ed::image::native_image_query(C, bridge_image_state, false);
          });
        }
        std::istringstream image_stream(bridge_image_json);
        if (auto image = JsonFormatter().deserialize(image_stream)) {
          merged.append("image", std::move(image));
        }
      }
      if (bridge_panels_visible & 64) {
        /* Soon again while shots still need their pictures drawn, one at a time. */
        if (bridge_storyboard_dirty || now >= bridge_storyboard_next_check) {
          bridge_storyboard_dirty = false;
          /* Only what is there: the pictures still to draw are drawn as the window draws, see
           * #WM_native_ui_storyboard_draw. */
          bridge_storyboard_json = bridge_timed("panels.storyboard", [&] {
            return ed::vse::native_storyboard_query(C, bridge_storyboard_state, false);
          });
          const bool pending = bridge_storyboard_json.find("\"pending\":1") != std::string::npos;
          bridge_storyboard_pending = pending;
          bridge_storyboard_next_check = now + std::chrono::milliseconds(pending ? 100 : 1000);
          if (pending) {
            /* The pictures still to draw arrive a few at a time, sooner than other changes. */
            bridge_panels_next_snapshot = std::min(bridge_panels_next_snapshot,
                                                now + std::chrono::milliseconds(100));
          }
        }
        merged.append_str("storyboard", "@native_storyboard_json@");
      }
      if (bridge_panels_visible & 32) {
        bridge_preferences_save_when_changed(C, now);
        /* The Preferences' panels are a view of their own: only the sections drawn with lists of
         * their own, which Settings lists in its own way, come with the panels. */
        std::istringstream state_stream(bridge_preferences_state);
        const auto state = JsonFormatter().deserialize(state_stream);
        const DictionaryValue *state_dictionary = state ? state->as_dictionary_value() : nullptr;
        auto preferences = std::make_shared<DictionaryValue>();
        {
          DictionaryValue *dictionary = preferences.get();
          const std::string tab = state_dictionary ?
                                      std::string(state_dictionary->lookup_str("tab").value_or("")) :
                                      std::string();
          dictionary->append_str("tab", tab);
          std::string expression;
          if (tab == "PREFERENCES_ADDONS") {
            expression = "bl_ui.native_settings.addons_json(bpy.context)";
          }
          else if (tab == "PREFERENCES_KEYMAP") {
            expression = "bl_ui.native_settings.keymaps_json(bpy.context, \"" +
                         bridge_json_escape(bridge_keymaps_state) + "\")";
          }
          std::string list_json;
          if (!expression.empty() &&
              bridge_python(C, "panels.preferences.list", expression.c_str(), list_json))
          {
            std::istringstream list_stream(list_json);
            if (auto list = JsonFormatter().deserialize(list_stream)) {
              dictionary->append(tab == "PREFERENCES_ADDONS" ? "addons" : "keymaps",
                                 std::move(list));
            }
          }
        }
        merged.append("preferences", std::move(preferences));
      }
      std::ostringstream merged_stream;
      JsonFormatter().serialize(merged_stream, merged);
      bridge_panels_json = merged_stream.str();
      if (bridge_panels_visible & 16) {
        const std::string placeholder = "\"@native_graph_json@\"";
        if (const size_t at = bridge_panels_json.find(placeholder); at != std::string::npos) {
          bridge_panels_json.replace(at, placeholder.size(), bridge_graph_json.empty() ? "null" : bridge_graph_json);
        }
      }
      if (bridge_panels_visible & 64) {
        const std::string placeholder = "\"@native_storyboard_json@\"";
        if (const size_t at = bridge_panels_json.find(placeholder); at != std::string::npos) {
          bridge_panels_json.replace(at, placeholder.size(),
                                  bridge_storyboard_json.empty() ? "null" : bridge_storyboard_json);
        }
      }
      if (bridge_panels_visible & 8) {
        const std::string placeholder = "\"@native_nodes_json@\"";
        if (const size_t at = bridge_panels_json.find(placeholder); at != std::string::npos) {
          bridge_panels_json.replace(at, placeholder.size(), bridge_nodes_json.empty() ? "null" : bridge_nodes_json);
        }
      }
      /* Published when it changes: every snapshot wakes the native interface. */
      if (bridge_panels_json != bridge_panels_published) {
        bridge_panels_published = bridge_panels_json;
        bridge_record("Panels", bridge_panels_json);
        bridge_panels_snapshot.publish(bridge_panels_json);
      }
    }
  }
#endif
  const std::vector<BridgeActionItem> actions = has_view3d_context ? bridge_action_items_for_tool(
                                                                      C, mode, active_tool_id) :
                                                                  std::vector<BridgeActionItem>();
  const bool can_undo = has_view3d_context && bridge_undo_available(C);
  const bool can_redo = has_view3d_context && bridge_undo_available(C, "ED_OT_redo");
  const std::string settings_json = bridge_transform_settings_json(
      scene, CTX_data_active_object(C), mode);
  std::string navigation_json = "null";
  if (has_view3d_context) {
    const wmWindow *win = CTX_wm_window(C);
    ARegion *region = CTX_wm_region(C);
    rcti visible = *ED_region_visible_rect(region);
    visible.ymin = std::max(visible.ymin, WM_native_ui_bottom_tray_ymin(win, region));
    visible.ymax = std::min(visible.ymax, WM_native_ui_top_bar_ymax(win, region));
    const float width = WM_window_native_pixel_x(win);
    const float height = WM_window_native_pixel_y(win);
    const float radius = U.gizmo_size_navigate_v3d * 0.5f * U.scale_factor;
    const float inset = radius + 10.0f * U.scale_factor;
    if (width > 0 && height > 0) {
      /* Match view3d_gizmo_navigate.cc, in normalized window coordinates from the top left.
       * The native shell can follow the last frame during asynchronous resizing. */
      /* Over the part of the window a native panel leaves showing, as the native controls
       * that follow the gizmo are laid out. */
      const float cover = std::min(bridge_viewport_cover.load(), height * 0.9f);
      /* In whichever corner Settings has it. */
      const float x = bridge_navigation_left ? visible.xmin + inset : visible.xmax - inset;
      const float y = bridge_navigation_top ? visible.ymax - inset : visible.ymin + inset;
      navigation_json = "[" + std::to_string((region->winrct.xmin + x) / width) + "," +
                        std::to_string(1.0f - (region->winrct.ymin + y - cover) / (height - cover)) +
                        "," + std::to_string(radius / width) + "]";
    }
  }
  const std::string redo_json = has_view3d_context ? bridge_timed("redo", [&] {
    return ui::native_operator_redo_query(C, "", false);
  }) :
                                                     "null";
  /* An operator's properties asked for before it runs, in place of Blender's dialog. */
  const std::string dialog_json = bridge_timed(
      "dialog", [&] { return ui::native_operator_dialog_query(C, "", false); });
  if (!has_view3d_context) {
    bridge_brushes_json = "null";
  }
  else if (const auto now = std::chrono::steady_clock::now(); now >= bridge_brushes_next_snapshot) {
    /* Asset polling runs Python per brush, so follow the native refresh cadence. */
    bridge_brushes_next_snapshot = now + std::chrono::milliseconds(250);
    bridge_brushes_json = bridge_timed("brushes",
                                       [&] { return bridge_brushes_build_json(C, mode); });
    if (bridge_brushes_json.find("\"pending\":true") != std::string::npos ||
        bridge_brushes_json.find("\"loading\":true") != std::string::npos)
    {
      /* Keep loading previews without waiting for the native cadence. */
      bridge_brushes_next_snapshot = now + std::chrono::milliseconds(30);
    }
  }
  bridge_context_pop(C, context_store);

  std::string json = "{\"mode\":\"";
  json += bridge_json_escape(mode_string ? mode_string : "objectmode");
  json += "\",\"shading\":\"";
  json += shading;
  json += "\",\"desktop\":";
  json += bridge_desktop_ui ? "true" : "false";
  json += ",\"activeName\":\"";
  json += bridge_json_escape(active_name);
  json += "\",\"objectMode\":\"";
  json += bridge_json_escape(object_mode);
  json += "\",\"modes\":";
  json += object_modes_json;
  json += ",\"meshSelectMode\":\"";
  json += bridge_json_escape(mesh_select_mode);
  json += "\",\"active\":\"";
  json += bridge_json_escape(active_tool_id ? active_tool_id : "");
  json += "\",\"canUndo\":";
  json += can_undo ? "true" : "false";
  json += ",\"canRedo\":";
  json += can_redo ? "true" : "false";
  /* Which undo step is active: it moves with every change an operator makes, and with undo and
   * redo, once per action rather than during one. Menus are built from the scene, so the interface
   * asks for them again when this changes, and only then. */
  json += ",\"menuState\":\"";
  if (const wmWindowManager *wm = CTX_wm_manager(C); wm && wm->runtime->undo_stack) {
    const UndoStack *stack = wm->runtime->undo_stack;
    json += std::to_string(uintptr_t(stack->step_active)) + ":" +
            std::to_string(BLI_listbase_count(&stack->steps));
  }
  json += "\"";
  json += ",\"settings\":";
  json += settings_json;
  json += ",\"redo\":";
  json += redo_json;
  json += ",\"dialog\":";
  json += dialog_json;
  json += ",\"textObject\":";
  json += has_view3d_context ? bridge_text_object_json(C) : "null";
  json += ",\"navigationGizmo\":";
  json += navigation_json;
  if (view3d && scene) {
    /* The color the viewport is cleared to, in display space, for chrome that should blend in
     * with it, such as the Mac window's toolbar. */
    float background[3];
    ED_view3d_background_color_get(scene, view3d, background);
    if (view3d->shading.background_type == V3D_SHADING_BACKGROUND_WORLD && scene->world) {
      linearrgb_to_srgb_v3_v3(background, background);
    }
    json += ",\"viewportBackground\":[" + std::to_string(background[0]) + "," +
            std::to_string(background[1]) + "," + std::to_string(background[2]) + "]";
  }
  json += ",\"tools\":";
  json += tools_json;
  json += ",\"brushes\":";
  json += bridge_brushes_json;
  json += ",\"brush\":";
  json += brush_json;
  json += ",\"direction\":";
  json += has_view3d_context ? bridge_direction_json(C, mode) : "null";
  /* Moving, turning or scaling: the held buttons are Snap and Precision then. */
  json += ",\"transforming\":";
  json += bridge_constraint_operator(CTX_wm_window(C)) ? "true" : "false";
  bool drag_done = false;
  if (const char *drag_hint = bridge_drag_hint(CTX_wm_window(C), &drag_done)) {
    json += ",\"dragHint\":{\"text\":\"" + bridge_json_escape(IFACE_(drag_hint)) + "\",\"done\":" +
            (drag_done ? "true" : "false") + "}";
  }
  json += ",\"panels\":";
  json += panels_json;
  json += ",\"render\":";
  json += render_json;
  json += ",\"viewport\":";
  json += viewport_json;
  json += ",\"preferences\":";
  json += preferences_json;
  if (actions.empty() && !quick_actions_json.empty()) {
    json += ",\"actions\":" + quick_actions_json + "}";
    return json;
  }
  json += ",\"actions\":[";

  bool needs_comma = false;
  for (const BridgeActionItem &action : actions) {
    if (needs_comma) {
      json += ",";
    }
    needs_comma = true;
    json += "{\"title\":\"";
    json += bridge_json_escape(action.title);
    json += "\",\"operator\":\"";
    json += bridge_json_escape(action.op_name);
    json += "\",\"symbol\":\"";
    json += bridge_json_escape(action.symbol);
    json += "\",\"property\":\"";
    json += bridge_json_escape(action.prop_name ? action.prop_name : "");
    json += "\",\"value\":\"";
    json += bridge_json_escape(action.prop_value ? action.prop_value : "");
    json += "\",\"key\":\"";
    json += bridge_json_escape(action.key ? action.key : "");
    json += "\",\"selected\":";
    json += action.selected ? "true" : "false";
    json += "}";
  }
  json += "]}";
  return json;
}

void bridge_timeline_build(bContext *C)
{
  const Scene *scene = CTX_data_scene(C);
  const wmWindowManager *wm = CTX_wm_manager(C);
  if (scene == nullptr || wm == nullptr) {
    return;
  }
#ifdef WITH_PYTHON
  if (const auto now = std::chrono::steady_clock::now();
      bridge_timeline_visible && now >= bridge_timeline_next_keys)
  {
    bridge_timeline_next_keys = now + std::chrono::milliseconds(250);
    bridge_python(C,
                  "timeline.keys",
                  "bl_ui.native_timeline.keys_json(bpy.context)",
                  bridge_timeline_keys_json);
  }
#endif
  /* A storyboard: the workspace's sequencer scene has shots, the window following the one under
   * its playhead. Its frame too, which playback moves. */
  const Scene *sequencer_scene = CTX_data_sequencer_scene(C);
  const WorkSpace *workspace = CTX_wm_workspace(C);
  const bool storyboard = sequencer_scene && workspace &&
                          (workspace->flags & WORKSPACE_SYNC_SCENE_TIME) &&
                          sequencer_scene->ed &&
                          !BLI_listbase_is_empty(seq::active_seqbase_get(sequencer_scene->ed));
  /* Playback changes the frame every redraw; publish only what the native interface has not seen. */
  std::string json = "{\"keys\":" + (bridge_timeline_visible ? bridge_timeline_keys_json : "[]") +
                     ",\"storyboard\":" + (storyboard ? "true" : "false") +
                     ",\"edit_frame\":" +
                     std::to_string(sequencer_scene ? sequencer_scene->r.cfra : 0) +
                     ",\"edit_start\":" +
                     std::to_string(sequencer_scene ? sequencer_scene->r.sfra : 0) +
                     ",\"edit_end\":" +
                     std::to_string(sequencer_scene ? sequencer_scene->r.efra : 0) +
                     ",\"frame\":" + std::to_string(scene->r.cfra) +
                     ",\"start\":" + std::to_string(PSFRA) + ",\"end\":" + std::to_string(PEFRA) +
                     ",\"preview\":" + ((scene->r.flag & SCER_PRV_RANGE) ? "true" : "false") +
                     ",\"playing\":" + (ED_screen_animation_playing(wm) ? "true" : "false") +
                     ",\"autokey\":" +
                     ((scene->toolsettings && (scene->toolsettings->autokey_mode & AUTOKEY_ON)) ?
                          "true" :
                          "false") +
                     "}";
  if (json != bridge_timeline_json) {
    bridge_timeline_json = json;
    bridge_record("Timeline", json);
    bridge_timeline_snapshot.publish(std::move(json));
  }
}

/** Set when Blender sent notifiers, see #WM_native_ui_tag_changed. */
bool bridge_changed = true;

void bridge_toolbar_build(bContext *C, const bool handled_commands)
{
  /* Describing the toolbar runs Python and is costly. Do it only when something may have changed:
   * a native command ran or Blender sent notifiers, as it does for any change of state; or
   * Properties asks while open. A slow check covers anything that changes without notifiers.
   * The native toolbar is told about a new description at once and only when it differs.
   * Continuous changes, such as playback changing the frame, describe it ten times a second. */
  static std::chrono::steady_clock::time_point next_check, last_build;
  static std::string published;
  const auto now = std::chrono::steady_clock::now();
  const bool wanted = handled_commands || bridge_changed || now >= next_check ||
                      (bridge_panels_visible && now >= bridge_panels_next_snapshot);
  if (wanted && (handled_commands || now - last_build >= std::chrono::milliseconds(100))) {
    bridge_changed = false;
    last_build = now;
    next_check = now + std::chrono::seconds(1);
#if defined(WITH_APPLE_CROSSPLATFORM) && APPLE_TARGET_IOS
    WM_apple_ios_finger_tweak_mode_update(C);
#endif
    std::string json = bridge_timed("toolbar",
                                    [&] { return bridge_toolbar_build_json_for_context(C); });
    if (json != published) {
      published = json;
      bridge_record("Toolbar", json);
      bridge_toolbar_snapshot.publish(std::move(json));
    }
  }
  bridge_timed("timeline", [&] { bridge_timeline_build(C); });
  bridge_timed("assets", [&] { bridge_assets_build(C); });
}

std::string bridge_json_escape(const std::string &value)
{
  std::string escaped;
  escaped.reserve(value.size() + 8);
  for (const char c : value) {
    switch (c) {
      case '"':
        escaped += "\\\"";
        break;
      case '\\':
        escaped += "\\\\";
        break;
      case '\n':
        escaped += "\\n";
        break;
      case '\r':
        escaped += "\\r";
        break;
      case '\t':
        escaped += "\\t";
        break;
      default:
        escaped += c;
        break;
    }
  }
  return escaped;
}

}  // namespace

void WM_native_ui_starter_library_ensure()
{
  const std::optional<std::string> path = BKE_appdir_folder_id(BLENDER_DATAFILES,
                                                               "starter_assets");
  if (!path) {
    return;
  }
  bUserAssetLibrary *library = BKE_preferences_asset_library_find_by_name(
      &U, BRIDGE_STARTER_LIBRARY_NAME);
  if (library == nullptr) {
    library = BKE_preferences_asset_library_add(&U, BRIDGE_STARTER_LIBRARY_NAME, path->c_str());
  }
  else if (!STREQ(library->dirpath, path->c_str())) {
    /* The app's install location changes with every install and update. */
    BKE_preferences_asset_library_path_set(library, path->c_str());
  }
  /* Dropping the same material twice reuses it rather than adding a copy. */
  library->import_method = ASSET_IMPORT_APPEND_REUSE;
}

extern "C" void WM_native_ui_command_enqueue(int command)
{
  if (command < int(BridgeCommand::SetModeObject) || command > int(BridgeCommand::ViewBottom)) {
    return;
  }

  bridge_messages.push(BridgeCommand(command));
}

extern "C" void WM_native_ui_stylus_hover_set(bool active, int x, int y)
{
  bridge_hover_requests.publish({active, x, y});
}

bool WM_native_ui_stylus_hover_active()
{
  return bridge_hover_request.active;
}

/* The barrel roll of a Pencil on the screen, set from the native interface's thread. */
static std::atomic<bool> bridge_pencil_roll_down = false;
static std::atomic<float> bridge_pencil_roll_angle = 0.0f;
static std::atomic<float> bridge_pencil_tilt_x = 0.0f;
static std::atomic<float> bridge_pencil_tilt_y = 0.0f;

extern "C" void WM_native_ui_stylus_roll_set(bool down, float angle, float tilt_x, float tilt_y)
{
  bridge_pencil_roll_angle = angle;
  bridge_pencil_tilt_x = tilt_x;
  bridge_pencil_tilt_y = tilt_y;
  bridge_pencil_roll_down = down;
}

void WM_native_ui_tweak_drag(bool *r_move, bool *r_roll, bool *r_tilt)
{
  *r_move = bridge_tweak_move;
  *r_roll = bridge_tweak_roll;
  *r_tilt = bridge_tweak_tilt;
}

bool WM_native_ui_stylus_roll(float *r_angle, float r_tilt[2])
{
  *r_angle = bridge_pencil_roll_angle;
  r_tilt[0] = bridge_pencil_tilt_x;
  r_tilt[1] = bridge_pencil_tilt_y;
  return bridge_pencil_roll_down;
}

extern "C" char *WM_native_ui_stylus_hover_copy_json()
{
  static std::string snapshot = "{}";
  bridge_hover_snapshot.take(snapshot);
  return strdup(snapshot.c_str());
}

extern "C" void WM_native_ui_operator_enqueue(const char *op_name)
{
  if (op_name == nullptr || op_name[0] == '\0') {
    return;
  }

  bridge_messages.push(BridgeOperatorCommand{op_name});
}

extern "C" void WM_native_ui_operator_enum_enqueue(const char *op_name,
                                                      const char *prop_name,
                                                      const char *prop_value)
{
  if (op_name == nullptr || op_name[0] == '\0') {
    return;
  }

  bridge_messages.push(BridgeOperatorPropertyCommand{
      op_name, prop_name ? prop_name : "", prop_value ? prop_value : ""});
}

extern "C" void WM_native_ui_setting_enqueue(const char *setting, const char *value)
{
  if (setting == nullptr || setting[0] == '\0' || value == nullptr || value[0] == '\0') {
    return;
  }

  bridge_messages.push(BridgeSettingCommand{setting, value});
}

extern "C" void WM_native_ui_tool_set_by_id(const char *tool_id)
{
  if (tool_id == nullptr || tool_id[0] == '\0') {
    return;
  }

  bridge_messages.push(std::string(tool_id));
}

extern "C" void WM_native_ui_brush_activate(const char *brush_id)
{
  if (brush_id == nullptr || brush_id[0] == '\0') {
    return;
  }

  bridge_messages.push(BridgeBrushCommand{brush_id});
}

/* -------------------------------------------------------------------- */
/** \name Held + and -
 *
 * The buttons beside the toolbar, held or locked while selecting or painting, as Shift and Ctrl
 * would be on a keyboard. Rather than modifier keys, which each editor's key map reads its own
 * way, they set what the operator a tap or drag starts does: add to or subtract from the
 * selection, for taps as well as box, lasso and circle selection, or stroke a brush either way.
 * \{ */

/* Smooth: brush strokes smooth instead, as with Shift, while the Smooth button is held. */
enum class BridgeSelectIntent { None = 0, Add = 1, Subtract = 2, Smooth = 3 };
static_assert(int(BridgeSelectIntent::Smooth) == int(WM_NATIVE_UI_SELECT_INTENT_SMOOTH),
              "Intents as WM_native_ui.h numbers them");

static std::atomic<int> bridge_select_intent = int(BridgeSelectIntent::None);

/** \a intent is an #BridgeSelectIntent. Called from the main thread. */
extern "C" void WM_native_ui_select_intent_set(int intent)
{
  bridge_select_intent = intent;
}

static bool operator_enum_has(bContext *C, PointerRNA *ptr, PropertyRNA *prop, const char *id)
{
  int value;
  return RNA_property_enum_value(C, ptr, prop, id, &value);
}

static void operator_bool_set(PointerRNA *ptr, const char *name, const bool value)
{
  if (PropertyRNA *prop = RNA_struct_find_property(ptr, name)) {
    if (RNA_property_type(prop) == PROP_BOOLEAN) {
      RNA_property_boolean_set(ptr, prop, value);
    }
  }
}

void WM_native_ui_operator_input_adjust(bContext *C, wmOperator *op)
{
  const BridgeSelectIntent intent = BridgeSelectIntent(bridge_select_intent.load());
  if (intent == BridgeSelectIntent::None) {
    return;
  }
  const bool add = intent == BridgeSelectIntent::Add;
  PointerRNA *ptr = op->ptr;

  if (intent == BridgeSelectIntent::Smooth) {
    /* The stroke's temporary brush, as Shift sets it; operators without one smooth by mode. */
    for (const char *name : {"brush_toggle", "mode"}) {
      PropertyRNA *prop = RNA_struct_find_property(ptr, name);
      int value;
      if (prop && RNA_property_type(prop) == PROP_ENUM &&
          RNA_property_enum_value(C, ptr, prop, "SMOOTH", &value))
      {
        RNA_property_enum_set(ptr, prop, value);
        break;
      }
    }
    return;
  }

  if (PropertyRNA *mode = RNA_struct_find_property(ptr, "mode");
      mode && RNA_property_type(mode) == PROP_ENUM)
  {
    /* Box, lasso and circle selection, in every editor. */
    int value;
    if (operator_enum_has(C, ptr, mode, "ADD") &&
        RNA_property_enum_value(C, ptr, mode, add ? "ADD" : "SUB", &value))
    {
      RNA_property_enum_set(ptr, mode, value);
      return;
    }
    /* Brush strokes: + strokes the way the brush's direction says, as without a modifier key,
     * and - the other way, as with Ctrl. Brushes set to their second direction (such as
     * Subtract or Deflate) swap them, so + always adds, inflates or pinches. */
    if (operator_enum_has(C, ptr, mode, "NORMAL") && operator_enum_has(C, ptr, mode, "INVERT")) {
      Paint *paint = BKE_paint_get_active_from_context(C);
      const Brush *brush = paint ? BKE_paint_brush(paint) : nullptr;
      const bool second_direction = brush && (brush->flag & BRUSH_DIR_IN);
      if (RNA_property_enum_value(
              C, ptr, mode, add != second_direction ? "NORMAL" : "INVERT", &value))
      {
        RNA_property_enum_set(ptr, mode, value);
      }
      return;
    }
  }

  /* Picking with a tap. */
  const bool extends = RNA_struct_find_property(ptr, "extend") != nullptr;
  const bool deselects = RNA_struct_find_property(ptr, "deselect") != nullptr;
  if (!extends && !deselects) {
    return;
  }
  operator_bool_set(ptr, "extend", add);
  operator_bool_set(ptr, "deselect", !add);
  operator_bool_set(ptr, "toggle", false);
  operator_bool_set(ptr, "deselect_all", false);
}

/** \} */

/**
 * Native asset pane drag: \a phase is a #BridgeAssetDragPhase, \a x and \a y are GHOST client
 * coordinates. \a asset_id is only needed to begin a drag or add an asset.
 */
extern "C" void WM_native_ui_asset_drag(int phase, const char *asset_id, int x, int y)
{
  bridge_messages.push(BridgeAssetDragCommand{phase, asset_id ? asset_id : "", x, y});
}

extern "C" void WM_native_ui_view_roll_enqueue(float angle)
{
  if (angle == 0.0f) {
    return;
  }

  bridge_messages.push(angle);
}

void WM_native_ui_tag_changed()
{
  bridge_nodes_dirty = true;
  bridge_graph_dirty = true;
  bridge_image_dirty = true;
  bridge_image_pixels_pending = true;
  bridge_image_uvs_pending = true;
  bridge_changed = true;
}

extern "C" char *WM_native_ui_toolbar_take_json()
{
  /* Only a description that changed since the native interface last took one. */
  if (!bridge_toolbar_snapshot.take(bridge_toolbar_json)) {
    return nullptr;
  }
  char *json_copy = static_cast<char *>(std::malloc(bridge_toolbar_json.size() + 1));
  if (json_copy != nullptr) {
    std::memcpy(json_copy, bridge_toolbar_json.c_str(), bridge_toolbar_json.size() + 1);
  }
  return json_copy;
}

extern "C" char *WM_native_ui_toolbar_copy_json()
{
  bridge_toolbar_snapshot.take(bridge_toolbar_json);

  char *json_copy = static_cast<char *>(std::malloc(bridge_toolbar_json.size() + 1));
  if (json_copy == nullptr) {
    return nullptr;
  }
  std::memcpy(json_copy, bridge_toolbar_json.c_str(), bridge_toolbar_json.size() + 1);
  return json_copy;
}


/**
 * One of Blender's menus, which a key or mouse button would open (a right-click's context menu,
 * Shift-A's Add menu, a pie), shown natively where the pointer is, as on a Mac. The native side
 * shows it from Blender's menu projection, see `BlenderMenus.swift`, and runs what is chosen.
 */
bool bridge_menu_popup(bContext *C, const char *menu)
{
  if (WM_native_ui_desktop_mode() || WM_menutype_find(menu, true) == nullptr) {
    return false;
  }
  /* Where the pointer is, as fractions of the window from its top left. */
  float x = 0.5f, y = 0.5f;
  wmWindow *win = CTX_wm_window(C);
  if (win && win->runtime->eventstate) {
    const float width = WM_window_native_pixel_x(win);
    const float height = WM_window_native_pixel_y(win);
    if (width > 0 && height > 0) {
      x = win->runtime->eventstate->xy[0] / width;
      y = 1.0f - win->runtime->eventstate->xy[1] / height;
    }
  }
  bridge_menu_popup_snapshot.publish("{\"menu\":\"" + bridge_json_escape(menu) + "\",\"x\":" +
                                  std::to_string(x) + ",\"y\":" + std::to_string(y) + "}");
  return true;
}

/** Where the pointer is, as fractions of the window from its top left, for a popup there. */
static std::string bridge_popup_position(bContext *C)
{
  float x = 0.5f, y = 0.5f;
  wmWindow *win = CTX_wm_window(C);
  if (win && win->runtime->eventstate) {
    const float width = WM_window_native_pixel_x(win);
    const float height = WM_window_native_pixel_y(win);
    if (width > 0 && height > 0) {
      x = win->runtime->eventstate->xy[0] / width;
      y = 1.0f - win->runtime->eventstate->xy[1] / height;
    }
  }
  return "\"x\":" + std::to_string(x) + ",\"y\":" + std::to_string(y);
}

/**
 * An operator's choice of its enum items, such as Add Constraint's, shown natively where the
 * pointer is in place of Blender's popup menu, its headings as sections. The native side runs the
 * operator with the one chosen.
 */
bool bridge_enum_popup(bContext *C, wmOperator *op, PropertyRNA *prop)
{
  if (WM_native_ui_desktop_mode()) {
    return false;
  }
  const EnumPropertyItem *items = nullptr;
  int count = 0;
  bool free = false;
  RNA_property_enum_items_gettexted(C, op->ptr, prop, &items, &count, &free);
  if (!items || count == 0) {
    return false;
  }
  std::string json = "{\"title\":\"" + bridge_json_escape(WM_operatortype_name(op->type, op->ptr)) +
                     "\",\"operator\":\"" + bridge_json_escape(op->type->idname) +
                     "\",\"property\":\"" + bridge_json_escape(RNA_property_identifier(prop)) +
                     "\",\"items\":[";
  bool first = true;
  for (int i = 0; i < count; i++) {
    const EnumPropertyItem &item = items[i];
    if (!item.name && !item.identifier[0]) {
      continue;
    }
    const char *icon = nullptr;
    if (item.icon) {
      RNA_enum_identifier(rna_enum_icon_items, item.icon, &icon);
    }
    json += std::string(first ? "" : ",") + "{\"title\":\"" + bridge_json_escape(item.name ? item.name : "") +
            "\",\"value\":\"" + bridge_json_escape(item.identifier) + "\",\"heading\":" +
            (item.identifier[0] ? "0" : "1") + ",\"icon\":\"" + bridge_json_escape(icon ? icon : "") +
            "\"}";
    first = false;
  }
  if (free) {
    MEM_delete(items);
  }
  bridge_menu_popup_snapshot.publish(json + "]," + bridge_popup_position(C) + "}");
  return true;
}

/** Rename Active Item's panel, as a native field; the other panels are Blender's own. */
bool bridge_panel_popup(bContext *C, const char *panel)
{
  if (WM_native_ui_desktop_mode() || !STREQ(panel, "TOPBAR_PT_name")) {
    return false;
  }
  bridge_menu_popup_snapshot.publish("{\"rename\":1," + bridge_popup_position(C) + "}");
  return true;
}

extern "C" char *WM_native_ui_menu_popup_take_json()
{
  std::string json;
  if (!bridge_menu_popup_snapshot.take(json)) {
    return nullptr;
  }
  return strdup(json.c_str());
}

extern "C" char *WM_native_ui_panels_take_json()
{
  std::string json;
  if (!bridge_panels_snapshot.take(json)) {
    return nullptr;
  }
  char *copy = static_cast<char *>(std::malloc(json.size() + 1));
  if (copy) {
    std::memcpy(copy, json.c_str(), json.size() + 1);
  }
  return copy;
}

extern "C" char *WM_native_ui_timeline_take_json()
{
  std::string json;
  if (!bridge_timeline_snapshot.take(json)) {
    return nullptr;
  }
  char *copy = static_cast<char *>(std::malloc(json.size() + 1));
  if (copy) {
    std::memcpy(copy, json.c_str(), json.size() + 1);
  }
  return copy;
}

extern "C" char *WM_native_ui_assets_take_json()
{
  std::string json;
  if (!bridge_assets_snapshot.take(json)) {
    return nullptr;
  }
  char *copy = static_cast<char *>(std::malloc(json.size() + 1));
  if (copy) {
    std::memcpy(copy, json.c_str(), json.size() + 1);
  }
  return copy;
}

extern "C" void WM_native_ui_json_free(char *json)
{
  std::free(json);
}

void bridge_apply_viewport_preferences(bContext *C)
{
  if (C == nullptr) {
    return;
  }

  bool refresh_gizmo_map = bridge_gizmo_refresh_pending;

  /* Keep taps (including Pencil jitter) on Blender's click-selection path, which
   * also sets the active object. Real tool drags start after a small movement,
   * with no hold delay; pressure strokes still receive every motion event. */
  U.drag_threshold_mouse = 3;
  U.drag_threshold_tablet = 3;
  U.drag_threshold = 0;
  U.move_threshold = 0;
  U.flag &= ~USER_TOOLTIPS;

  if ((U.uiflag & USER_SHOW_GIZMO_NAVIGATE) == 0) {
    U.uiflag |= USER_SHOW_GIZMO_NAVIGATE;
    refresh_gizmo_map = true;
  }
  if ((U.gizmo_flag & USER_GIZMO_DRAW) == 0) {
    U.gizmo_flag |= USER_GIZMO_DRAW;
    refresh_gizmo_map = true;
  }
  if (U.mini_axis_type != USER_MINI_AXIS_TYPE_GIZMO) {
    U.mini_axis_type = USER_MINI_AXIS_TYPE_GIZMO;
    refresh_gizmo_map = true;
  }
  if (U.gizmo_size_navigate_v3d == 0) {
    U.gizmo_size_navigate_v3d = 80;
    refresh_gizmo_map = true;
  }

  const BridgeContextStore context_store = bridge_context_push_view3d(C);
  ScrArea *area = CTX_wm_area(C);

  if (area != nullptr && area->spacetype == SPACE_VIEW3D) {
    View3D *v3d = static_cast<View3D *>(area->spacedata.first);
    if (v3d != nullptr) {
      if (v3d->gizmo_flag & (V3D_GIZMO_HIDE | V3D_GIZMO_HIDE_NAVIGATE)) {
        refresh_gizmo_map = true;
      }
      v3d->gizmo_flag &= ~(V3D_GIZMO_HIDE | V3D_GIZMO_HIDE_NAVIGATE);
    }
    /* Brushes are picked from the native brush rail. The shelf shows itself again whenever a
     * brush mode creates its shelf (`DEFAULT_VISIBLE`), so keep it hidden here. */
    for (ARegion &shelf_region : area->regionbase) {
      if (ELEM(shelf_region.regiontype, RGN_TYPE_ASSET_SHELF, RGN_TYPE_ASSET_SHELF_HEADER) &&
          !(shelf_region.flag & RGN_FLAG_HIDDEN))
      {
        shelf_region.flag |= RGN_FLAG_HIDDEN;
        ED_region_visibility_change_update(C, area, &shelf_region);
      }
    }
    ARegion *region = bridge_find_window_region(area);
    if (refresh_gizmo_map && region != nullptr && region->runtime->gizmo_map != nullptr) {
      WM_gizmomap_reinit(region->runtime->gizmo_map);
      WM_gizmomap_tag_refresh(region->runtime->gizmo_map);
      ED_region_tag_redraw(region);
    }
  }

  bridge_gizmo_refresh_pending = false;
  bridge_context_pop(C, context_store);
}

/** Name the toggle by where it goes. Menus show the operator's registered name, as they have no
 * properties to ask #wmOperatorType::get_name with. */
static void bridge_interface_toggle_name_update()
{
  wmOperatorType *ot = WM_operatortype_find("WM_OT_native_interface_toggle", false);
  if (ot == nullptr) {
    return;
  }
  ot->name = bridge_desktop_ui ? "Return to iPad Interface" : "Switch to Desktop Interface";
  RNA_def_struct_ui_text(ot->srna, ot->name, ot->description);
}

/** Switch between the native interface and Blender's own, as on a Mac. */
void bridge_interface_set(bContext *C, const bool desktop)
{
  if (bridge_desktop_ui == desktop) {
    return;
  }
  bridge_desktop_ui = desktop;
  bridge_interface_toggle_name_update();
  const BridgeContextStore context_store = bridge_context_push_view3d(C);
  wmWindow *win = CTX_wm_window(C);
  bScreen *screen = CTX_wm_screen(C);
  ScrArea *area = CTX_wm_area(C);
  if (desktop && win != nullptr && screen != nullptr && area != nullptr &&
      screen->state == SCREENFULL)
  {
    /* Leave the full-screen 3D View for the screen's editors, headers and toolbars. */
    ED_screen_state_toggle(C, win, area, SCREENFULL);
    area = bridge_find_view3d_area(WM_window_get_active_screen(win));
  }
  /* The navigation gizmo moves between the native bottom-right and Blender's top-right. */
  if (ARegion *region = bridge_find_window_region(area)) {
    if (region->runtime->gizmo_map != nullptr) {
      WM_gizmomap_reinit(region->runtime->gizmo_map);
      WM_gizmomap_tag_refresh(region->runtime->gizmo_map);
    }
    ED_region_tag_redraw(region);
  }
  bridge_gizmo_refresh_pending = true;
  bridge_context_pop(C, context_store);
  if (win != nullptr) {
    WM_event_add_notifier(C, NC_WINDOW, nullptr);
  }
}

static wmOperatorStatus bridge_interface_toggle_exec(bContext *C, wmOperator * /*op*/)
{
  bridge_interface_set(C, !bridge_desktop_ui);
  return OPERATOR_FINISHED;
}

static std::string bridge_interface_toggle_get_name(wmOperatorType * /*ot*/, PointerRNA * /*ptr*/)
{
  return bridge_desktop_ui ? IFACE_("Return to iPad Interface") :
                          IFACE_("Switch to Desktop Interface");
}

void WM_OT_native_interface_toggle(wmOperatorType *ot)
{
  ot->name = "Switch to Desktop Interface";
  ot->idname = "WM_OT_native_interface_toggle";
  ot->description =
      "Switch between the iPad interface and Blender's own interface, as on a desktop computer";
  ot->exec = bridge_interface_toggle_exec;
  ot->get_name = bridge_interface_toggle_get_name;
}

static wmOperatorStatus bridge_url_open_exec(bContext * /*C*/, wmOperator *op)
{
  char url[1024];
  RNA_string_get(op->ptr, "url", url);
  const wmNativeInterface *native = WM_native_interface();
  if (!url[0] || !native || !native->web_url_open) {
    return OPERATOR_CANCELLED;
  }
  native->web_url_open(url);
  return OPERATOR_FINISHED;
}

void WM_OT_native_url_open(wmOperatorType *ot)
{
  ot->name = "Open URL";
  ot->idname = "WM_OT_native_url_open";
  ot->description = "Open a web page in the browser";
  ot->exec = bridge_url_open_exec;
  ot->flag = OPTYPE_INTERNAL;
  RNA_def_string(ot->srna, "url", nullptr, 1024, "URL", "");
}

bool WM_native_ui_desktop_mode()
{
  /* Without a platform interface registered, Blender's own is all there is. */
  return bridge_desktop_ui || WM_native_interface() == nullptr;
}

void WM_native_ui_ensure_layout(bContext *C)
{
  if (C == nullptr) {
    return;
  }

  if (bridge_desktop_ui) {
    /* Blender's own interface keeps whatever screens the files bring. */
    return;
  }

  /* The native interface shows the 3D View full screen. Every new or opened file brings its own
   * screen with Blender's editors, so check on every update, not only at startup. */
  const BridgeContextStore context_store = bridge_context_push_view3d(C);
  wmWindow *win = CTX_wm_window(C);
  bScreen *screen = CTX_wm_screen(C);
  ScrArea *area = CTX_wm_area(C);
  if (win != nullptr && screen != nullptr && area != nullptr && screen->state == SCREENNORMAL) {
    ED_screen_state_toggle(C, win, area, SCREENFULL);
    bridge_gizmo_refresh_pending = true;
  }
  else if (win != nullptr && screen != nullptr && area != nullptr && screen->state == SCREENFULL) {
    /* A file saved on the iPad reopens already full screen, but with the 3D View's headers and
     * tool settings shown again. Hide them as entering full screen does. */
    bool changed = false;
    for (ARegion &region : area->regionbase) {
      if (ELEM(region.regiontype,
               RGN_TYPE_UI,
               RGN_TYPE_HEADER,
               RGN_TYPE_TOOL_HEADER,
               RGN_TYPE_FOOTER,
               RGN_TYPE_TOOLS,
               RGN_TYPE_NAV_BAR,
               RGN_TYPE_EXECUTE,
               RGN_TYPE_ASSET_SHELF) &&
          !(region.flag & RGN_FLAG_HIDDEN))
      {
        region.flag |= RGN_FLAG_HIDDEN;
        changed = true;
      }
    }
    if (changed) {
      ED_area_init(C, win, area);
      ED_area_tag_redraw(area);
    }
  }
  bridge_layout_ready = true;
  bridge_context_pop(C, context_store);

  bridge_apply_viewport_preferences(C);
}

extern "C" uint64_t WM_native_ui_menu_request(const char *route, bool execute)
{
  const uint64_t identifier = ++bridge_menu_next_identifier;
  bridge_messages.push(BridgeMenuRequest{identifier, route ? route : "{}", execute});
  return identifier;
}

extern "C" uint64_t WM_native_ui_menu_at_position_request(const char *route,
                                                             bool execute,
                                                             int x,
                                                             int y)
{
  const uint64_t identifier = ++bridge_menu_next_identifier;
  bridge_messages.push(BridgeMenuRequest{identifier, route ? route : "{}", execute, true, x, y});
  return identifier;
}

/* The native interface only exchanges owned JSON with the engine, never live Blender UI pointers. */
extern "C" char *WM_native_ui_menu_take_result(uint64_t identifier)
{
  for (auto &result : bridge_menu_completed.take()) {
    bridge_menu_results.emplace(result.first, std::move(result.second));
  }
  while (bridge_menu_results.size() > 128) {
    bridge_menu_results.erase(bridge_menu_results.begin());
  }
  const auto found = bridge_menu_results.find(identifier);
  if (found == bridge_menu_results.end()) {
    return nullptr;
  }
  char *result = strdup(found->second.c_str());
  bridge_menu_results.erase(found);
  return result;
}

extern "C" void WM_native_ui_navigation_hover_set(bool active)
{
  if (bridge_navigation_hover_active.exchange(active) != active) {
    bridge_navigation_redraw_pending.store(true);
  }
}

bool WM_native_ui_navigation_hover_active()
{
  return bridge_navigation_hover_active.load();
}

void WM_native_ui_navigation_redraw_request()
{
  bridge_navigation_redraw_pending.store(true);
}

/* How much of the window's height, from the top, the native top bar covers. */
static std::atomic<float> bridge_top_bar = 0.0f;

extern "C" void WM_native_ui_top_bar_set(const float fraction)
{
  if (bridge_top_bar.exchange(fraction) != fraction) {
    bridge_navigation_redraw_pending.store(true);
  }
}

int WM_native_ui_top_bar_ymax(const wmWindow *win, const ARegion *region)
{
  /* The navigation gizmo sits below the top bar, in region pixels. */
  return int((1.0f - bridge_top_bar.load()) * WM_window_native_pixel_y(win)) - region->winrct.ymin;
}

extern "C" void WM_native_ui_bottom_tray_set(const float fraction)
{
  if (bridge_bottom_tray.exchange(fraction) != fraction) {
    bridge_navigation_redraw_pending.store(true);
  }
}

/* Set from the native interface: telling Blender a message waits wakes its loop. */
extern "C" void WM_native_ui_viewport_cover_set(const float pixels)
{
  if (bridge_viewport_cover.exchange(pixels) != pixels) {
    bridge_viewport_cover_changed.store(true);
    GHOST_mailbox_published();
  }
}

float WM_native_ui_viewport_cover()
{
  return bridge_viewport_cover.load();
}

extern "C" void WM_native_ui_viewport_trailing_cover_set(const float pixels)
{
  if (bridge_viewport_trailing_cover.exchange(pixels) != pixels) {
    bridge_viewport_cover_changed.store(true);
    GHOST_mailbox_published();
  }
}

float WM_native_ui_viewport_trailing_cover()
{
  return bridge_viewport_trailing_cover.load();
}

bool WM_native_ui_navigation_top()
{
  return bridge_navigation_top.load();
}

bool WM_native_ui_navigation_left()
{
  return bridge_navigation_left.load();
}

int WM_native_ui_bottom_tray_ymin(const wmWindow *win, const ARegion *region)
{
  /* The navigation gizmo sits above the tray, in region pixels. */
  return int(bridge_bottom_tray.load() * WM_window_native_pixel_y(win)) - region->winrct.ymin;
}

static void bridge_dispatch_operator(bContext *C, BridgeOperatorCommand &command)
{
  const BridgeContextStore context_store = bridge_context_push_view3d(C);
  wmWindow *win = CTX_wm_window(C);
  if (win && CTX_wm_area(C) && CTX_wm_region(C)) {
    bridge_operator_invoke(C, command.op_name.c_str());
  }
  bridge_context_pop(C, context_store);
}

static void bridge_dispatch_menu(bContext *C, BridgeMenuRequest &request)
{
  const BridgeContextStore context_store = bridge_context_push_view3d(C);
  std::string result = "[]";
  wmWindow *win = CTX_wm_window(C);
  bool ready = true;
  if (win && request.has_position) {
    for (wmEventHandler &handler_item : win->runtime->modalhandlers) {
      wmEventHandler *handler = &handler_item;
      if (handler->type == WM_HANDLER_TYPE_OP) {
        ready = false;
        break;
      }
    }
    if (!ready && request.retries++ < 2) {
      bridge_messages.push(request);
      bridge_context_pop(C, context_store);
      return;
    }
    if (ready && win->runtime->eventstate) {
      int x = request.x, y = request.y;
      wm_cursor_position_from_ghost_client_coords(win, &x, &y);
      win->runtime->eventstate->xy[0] = x;
      win->runtime->eventstate->xy[1] = y;
    }
  }
  if (ready && win && CTX_wm_area(C) && CTX_wm_region(C)) {
    result = blender::ui::native_properties_menu_query(C, request.route, request.execute);
  }
  bridge_context_pop(C, context_store);
  if (!request.execute) {
    bridge_menu_completed.push({request.identifier, std::move(result)});
  }
}

static void bridge_dispatch(bContext *C, BridgeMessage &message)
{
#if defined(WITH_APPLE_CROSSPLATFORM) && APPLE_TARGET_IOS
  const auto *setting = std::get_if<BridgeSettingCommand>(&message);
  const auto *menu = std::get_if<BridgeMenuRequest>(&message);
  if ((!menu || menu->execute) && (!setting || (setting->setting != "native_properties_edit" &&
                                                setting->setting != "native_properties_state" &&
                                                setting->setting != "native_panels" &&
                                                setting->setting != "native_nodes_state" &&
                                                setting->setting != "native_nodes_visible" &&
                                                setting->setting != "native_nodes_edit" &&
                                                setting->setting != "native_graph_state" &&
                                                setting->setting != "native_graph_visible" &&
                                                setting->setting != "native_graph_edit" &&
                                                setting->setting != "native_image_state" &&
                                                setting->setting != "native_image_visible" &&
                                                setting->setting != "native_image_edit" &&
                                                setting->setting != "native_storyboard_visible" &&
                                                setting->setting != "native_storyboard_edit" &&
                                                setting->setting != "native_storyboard_state")))
  {
    const BridgeContextStore context_store = bridge_context_push_view3d(C);
    ui::native_properties_interaction_finish(C);
    bridge_context_pop(C, context_store);
  }
  const bool panel_message = setting && (setting->setting == "native_panels" ||
                                         setting->setting == "native_panel_edit" ||
                                         setting->setting == "native_properties_state" ||
                                         setting->setting == "native_properties_edit" ||
                                         setting->setting == "native_nodes_state" ||
                                         setting->setting == "native_nodes_visible" ||
                                         setting->setting == "native_nodes_edit" ||
                                         setting->setting == "native_graph_state" ||
                                         setting->setting == "native_graph_visible" ||
                                         setting->setting == "native_graph_edit" ||
                                         setting->setting == "native_image_state" ||
                                         setting->setting == "native_image_visible" ||
                                         setting->setting == "native_image_edit" ||
                                         setting->setting == "native_storyboard_visible" ||
                                         setting->setting == "native_storyboard_edit" ||
                                         setting->setting == "native_storyboard_state");
  if (WM_apple_ios_dialog_active(CTX_wm_window(C)) && !panel_message) {
    if (const auto *request = std::get_if<BridgeMenuRequest>(&message)) {
      if (!request->execute) {
        bridge_menu_completed.push({request->identifier, "[]"});
      }
    }
    return;
  }
#endif
  std::visit(
      [&](auto &command) {
        using T = std::decay_t<decltype(command)>;
        if constexpr (std::is_same_v<T, BridgeCommand>) {
          bridge_command_execute(C, command);
        }
        else if constexpr (std::is_same_v<T, std::string>) {
          bridge_tool_set_by_id(C, command);
        }
        else if constexpr (std::is_same_v<T, BridgeOperatorCommand>) {
          bridge_dispatch_operator(C, command);
        }
        else if constexpr (std::is_same_v<T, BridgeMenuRequest>) {
          bridge_dispatch_menu(C, command);
        }
        else if constexpr (std::is_same_v<T, BridgeBrushCommand>) {
          bridge_brush_activate(C, command.key);
        }
        else if constexpr (std::is_same_v<T, BridgeAssetDragCommand>) {
          bridge_asset_drag(C, command);
        }
        else {
          const BridgeContextStore context_store = bridge_context_push_view3d(C);
          if (CTX_wm_window(C) && CTX_wm_area(C) && CTX_wm_region(C)) {
            if constexpr (std::is_same_v<T, BridgeSettingCommand>) {
              bridge_setting_execute(C, command);
            }
            else if constexpr (std::is_same_v<T, float>) {
              bridge_view_roll_angle(C, command);
            }
            else if constexpr (std::is_same_v<T, BridgeOperatorPropertyCommand>) {
              bridge_operator_call_with_enum_property(C,
                                                   command.op_name.c_str(),
                                                   command.prop_name.c_str(),
                                                   command.prop_value.c_str());
            }
          }
          bridge_context_pop(C, context_store);
        }
      },
      message);
}

void WM_native_ui_storyboard_draw(bContext *C)
{
  /* Just before the window draws, with its GPU context: the window is then drawn whole, so
   * nothing the pictures' drawing leaves behind is ever shown. */
  wmWindowManager *wm = CTX_wm_manager(C);
  if (!(bridge_panels_visible & 64) || !bridge_storyboard_pending || !wm) {
    return;
  }
  /* In the window's context, as the storyboard's snapshot is read. */
  const BridgeContextStore context_store = bridge_context_push_view3d(C);
  wmWindow *win = CTX_wm_window(C);
  if (win) {
    wm_window_make_drawable(wm, win);
    bridge_storyboard_pending = ed::vse::native_storyboard_draw(C, bridge_storyboard_state);
    if (bScreen *screen = WM_window_get_active_screen(win)) {
      screen->do_draw = true;
    }
  }
  bridge_context_pop(C, context_store);
  /* The new pictures, to the native interface at once. */
  bridge_storyboard_dirty = true;
  bridge_panels_next_snapshot = {};
}

void WM_native_ui_image_update(bContext *C)
{
  /* The image editor's picture follows painting closely, not at the panels' slower pace: each
   * time Blender changes something, though no closer together than the last one took to make. */
  static std::chrono::steady_clock::time_point next_pixels;
  if (!(bridge_panels_visible & 128) || !(bridge_image_pixels_pending || bridge_image_uvs_pending)) {
    return;
  }
  const auto now = std::chrono::steady_clock::now();
  const BridgeContextStore context_store = bridge_context_push_view3d(C);
  if (bridge_image_pixels_pending && now >= next_pixels) {
    bridge_image_pixels_pending = false;
    ed::image::NativeImagePixels pixels;
    if (ed::image::native_image_pixels(C, bridge_image_state, pixels)) {
      bridge_image_pixels.publish(std::move(pixels));
    }
    const auto took = std::chrono::steady_clock::now() - now;
    next_pixels = now + std::max<std::chrono::steady_clock::duration>(
                            std::chrono::milliseconds(33), took * 2);
  }
  if (bridge_image_uvs_pending) {
    static std::vector<float> sent;
    static bool sent_any = false;
    bridge_image_uvs_pending = false;
    std::vector<float> uvs = ed::image::native_image_uvs(C);
    if (!sent_any || uvs != sent) {
      sent_any = true;
      sent = uvs;
      bridge_image_uvs.publish(std::move(uvs));
    }
  }
  bridge_context_pop(C, context_store);
}

extern "C" bool WM_native_ui_image_take_pixels(char **r_name,
                                                  uint8_t **r_rgba,
                                                  int *r_width,
                                                  int *r_height,
                                                  int *r_full_width,
                                                  int *r_full_height)
{
  ed::image::NativeImagePixels pixels;
  if (!bridge_image_pixels.take(pixels)) {
    return false;
  }
  *r_name = strdup(pixels.name.c_str());
  *r_rgba = nullptr;
  if (!pixels.rgba.empty()) {
    *r_rgba = static_cast<uint8_t *>(std::malloc(pixels.rgba.size()));
    if (*r_rgba) {
      std::memcpy(*r_rgba, pixels.rgba.data(), pixels.rgba.size());
    }
  }
  *r_width = *r_rgba ? pixels.width : 0;
  *r_height = *r_rgba ? pixels.height : 0;
  *r_full_width = pixels.full_width;
  *r_full_height = pixels.full_height;
  return true;
}

extern "C" bool WM_native_ui_image_take_uvs(float **r_segments, int *r_count)
{
  std::vector<float> uvs;
  if (!bridge_image_uvs.take(uvs)) {
    return false;
  }
  *r_count = int(uvs.size());
  *r_segments = nullptr;
  if (!uvs.empty()) {
    *r_segments = static_cast<float *>(std::malloc(uvs.size() * sizeof(float)));
    if (*r_segments) {
      std::memcpy(*r_segments, uvs.data(), uvs.size() * sizeof(float));
    }
    else {
      *r_count = 0;
    }
  }
  return true;
}

double WM_native_ui_engine_idle_seconds(bContext *C)
{
  /* How long Blender's loop has nothing to do: no events, notifiers or redraws pending, until
   * its next timer. The loop then sleeps, waking at once for input, instead of running every
   * frame. A rendered viewport is polled every frame, its engine draws on its own thread. */
  wmWindowManager *wm = CTX_wm_manager(C);
  if (wm == nullptr || bridge_changed || !BLI_listbase_is_empty(&wm->runtime->notifier_queue)) {
    return 0.0;
  }
  if ((bridge_panels_visible & 64) && bridge_storyboard_pending) {
    /* The storyboard's pictures still to draw, a few each pass. */
    return 0.1;
  }
  if ((bridge_panels_visible & 128) && (bridge_image_pixels_pending || bridge_image_uvs_pending)) {
    /* The image editor's picture, held back while painting changes it quickly. */
    return 0.03;
  }
  for (wmWindow &win : wm->windows) {
    bScreen *screen = WM_window_get_active_screen(&win);
    if (!BLI_listbase_is_empty(&win.runtime->event_queue) || screen == nullptr ||
        screen->do_draw || screen->do_refresh || screen->do_draw_gesture ||
        screen->do_draw_paintcursor || screen->do_draw_drag)
    {
      return 0.0;
    }
    for (ARegion &region : screen->regionbase) {
      if (region.runtime->do_draw) {
        return 0.0;
      }
    }
    ED_screen_areas_iter (&win, screen, area) {
      if (area->spacetype == SPACE_VIEW3D) {
        const View3D *v3d = static_cast<const View3D *>(area->spacedata.first);
        if (v3d && ELEM(v3d->shading.type, OB_MATERIAL, OB_RENDER)) {
          return 0.0;
        }
      }
      for (ARegion &region : area->regionbase) {
        if (region.runtime->do_draw) {
          return 0.0;
        }
      }
    }
  }
  double next = BLI_timer_next_time();
  for (const wmTimer &timer : wm->runtime->timers) {
    if (!timer.sleep && !(timer.flags & WM_TIMER_TAGGED_FOR_REMOVAL)) {
      next = std::min(next, timer.time_next);
    }
  }
  /* Views waiting for their interval are built as it ends. */
  return std::min(std::clamp(next - BLI_time_now_seconds(), 0.0, 0.1),
                  WM_native_ui_views_idle_seconds());
}

/* While a stroke or another modal operator runs, one hand can keep changing things with the
 * other: the native controls are not blocked as Blender's own buttons are. Values change live;
 * what would change Blender's data under the operator waits for it to end, see
 * #bridge_message_live. */
static Vector<BridgeMessage> bridge_messages_waiting;
/* Set while a native control is handled, so its undo steps wait for the operator too. */
static bool bridge_dispatching = false;
/* The undo step held back, pushed when the operator ends; see #WM_native_ui_undo_push_defer. */
static std::optional<std::string> bridge_undo_pending;

/* Whether a stroke or another modal operator is running. The file browser waits for the system's
 * picker, holding no data half changed. */
static bool bridge_modal_operator_running(bContext *C)
{
  wmWindowManager *wm = CTX_wm_manager(C);
  if (wm->runtime->undo_stack && wm->runtime->undo_stack->step_init) {
    return true;
  }
  for (wmWindow &win : wm->windows) {
    for (wmEventHandler &handler : win.runtime->modalhandlers) {
      if (handler.type == WM_HANDLER_TYPE_OP &&
          !reinterpret_cast<wmEventHandler_Op &>(handler).is_fileselect)
      {
        return true;
      }
    }
  }
  return false;
}

/* A panel's edit that only sets a value, not a button, list, menu or operator. */
static bool bridge_edit_sets_value(const std::string &json)
{
  std::istringstream stream(json);
  auto value = io::serialize::JsonFormatter().deserialize(stream);
  const auto *request = value ? value->as_dictionary_value() : nullptr;
  if (request == nullptr || request->lookup_str("action").value_or("") != "property" ||
      request->lookup("value") == nullptr)
  {
    return false;
  }
  for (const char *key : {"operator", "list_action", "id_action", "panel_action",
                          "animation_action"})
  {
    if (request->lookup(key)) {
      return false;
    }
  }
  return true;
}

/**
 * Whether a message can be handled while a stroke or other modal operator runs: values, what is
 * shown and the view. Modes, tools, brushes, operators, undo, frames and assets change data the
 * operator holds, and wait for it to end.
 */
static bool bridge_message_live(const BridgeMessage &message)
{
  if (const auto *command = std::get_if<BridgeCommand>(&message)) {
    /* The view and its shading; not Local View, which hides objects. */
    return *command >= BridgeCommand::FrameSelected && *command <= BridgeCommand::ViewBottom &&
           *command != BridgeCommand::ViewLocal;
  }
  if (std::holds_alternative<float>(message)) {
    return true;
  }
  if (const auto *menu = std::get_if<BridgeMenuRequest>(&message)) {
    return !menu->execute;
  }
  const auto *setting = std::get_if<BridgeSettingCommand>(&message);
  if (setting == nullptr) {
    return false;
  }
  const StringRef name = setting->setting;
  if (name.endswith("_state") || name.endswith("_visible")) {
    return true;
  }
  if (ELEM(name,
           "native_brush",
           "brush_direction",
           "constraint_axis",
           "snap",
           "proportional",
           "pivot",
           "orientation",
           "mirror",
           "mirror_topology",
           "native_panels",
           "hover_highlight",
           "navigation_corner",
           "tweak_drag"))
  {
    return true;
  }
  if (ELEM(name, "native_properties_edit", "native_panel_edit", "native_nodes_edit")) {
    return bridge_edit_sets_value(setting->value);
  }
  return false;
}

static void bridge_undo_push_pending(bContext *C)
{
  if (!bridge_undo_pending) {
    return;
  }
  const std::string name = std::move(*bridge_undo_pending);
  bridge_undo_pending.reset();
  const BridgeContextStore context_store = bridge_context_push_view3d(C);
  ED_undo_push(C, name.empty() ? nullptr : name.c_str());
  bridge_context_pop(C, context_store);
}

/**
 * An undo step from a native control while a stroke or other modal operator runs: pushed then, it
 * would close the operator's own step half way, and the stroke crashes as it goes on. It is
 * pushed once the operator ends instead. Blender's own pushes, as an operator finishing, go ahead.
 */
bool WM_native_ui_undo_push_defer(bContext *C, const char *name)
{
  if (!bridge_dispatching || !bridge_modal_operator_running(C)) {
    return false;
  }
  bridge_undo_pending = name ? name : "";
  return true;
}

bool WM_native_ui_engine_busy(bContext *C)
{
  return bridge_modal_operator_running(C);
}

void WM_native_ui_flush_commands(bContext *C)
{
  if (C == nullptr) {
    return;
  }

#if defined(WITH_APPLE_CROSSPLATFORM) && APPLE_TARGET_IOS
  WM_apple_ios_dialog_flush(C);
  WM_apple_ios_fileselect_flush(C);
#endif
  WM_native_ui_ensure_layout(C);

  if (bridge_viewport_cover_changed.exchange(false)) {
    /* The 3D views are shortened to the part a panel leaves showing, see #area_calc_totrct. */
    for (wmWindow &win : CTX_wm_manager(C)->windows) {
      bScreen *screen = WM_window_get_active_screen(&win);
      for (ScrArea &area : screen->areabase) {
        if (area.spacetype == SPACE_VIEW3D) {
          area.flag |= AREA_FLAG_REGION_SIZE_UPDATE;
          ED_area_tag_redraw(&area);
        }
      }
    }
    bridge_navigation_redraw_pending.store(true);
  }
  if (bridge_navigation_redraw_pending.exchange(false)) {
    const BridgeContextStore context_store = bridge_context_push_view3d(C);
    if (ARegion *region = CTX_wm_region(C)) {
      ED_region_tag_redraw_editor_overlays(region);
    }
    bridge_context_pop(C, context_store);
  }

  auto supersedes_preview = [](const BridgeMessage &previous, const BridgeMessage &next) {
    const auto *a = std::get_if<BridgeSettingCommand>(&previous);
    const auto *b = std::get_if<BridgeSettingCommand>(&next);
    if (a && b && a->setting == "timeline_frame" && b->setting == "timeline_frame") {
      return true;
    }
    /* A brush slider's newer value, unless the older one ended its drag. */
    if (a && b && a->setting == "native_brush" && b->setting == "native_brush" &&
        a->value.find("\"commit\":true") == std::string::npos &&
        a->value.substr(0, a->value.find(',')) == b->value.substr(0, b->value.find(',')))
    {
      return true;
    }
    const auto *drag_a = std::get_if<BridgeAssetDragCommand>(&previous);
    const auto *drag_b = std::get_if<BridgeAssetDragCommand>(&next);
    if (drag_a && drag_b && drag_a->phase == BRIDGE_ASSET_DRAG_MOVE &&
        drag_b->phase == BRIDGE_ASSET_DRAG_MOVE)
    {
      return true;
    }
    if (!a || !b || a->setting != b->setting ||
        (a->setting != "native_properties_edit" && a->setting != "native_redo_edit" &&
         a->setting != "native_dialog_edit"))
    {
      return false;
    }
    std::istringstream a_stream(a->value), b_stream(b->value);
    auto a_value = io::serialize::JsonFormatter().deserialize(a_stream);
    auto b_value = io::serialize::JsonFormatter().deserialize(b_stream);
    const auto *a_request = a_value ? a_value->as_dictionary_value() : nullptr;
    const auto *b_request = b_value ? b_value->as_dictionary_value() : nullptr;
    return a_request && b_request && a_request->lookup_str("phase").value_or("") == "update" &&
           !a_request->lookup_str("interaction").value_or("").is_empty() &&
           a_request->lookup_str("interaction") == b_request->lookup_str("interaction") &&
           a_request->lookup_str("id") == b_request->lookup_str("id") &&
           a_request->lookup_str("key") == b_request->lookup_str("key");
  };
  bool handled_commands = false;
  /* Waiting messages first, in the order they came; a stroke or move may start or end between
   * any two of them. Live messages go ahead of any still waiting. */
  Vector<BridgeMessage> messages = std::move(bridge_messages_waiting);
  bridge_messages_waiting.clear();
  for (BridgeMessage &message : bridge_messages.take_coalesced(supersedes_preview)) {
    messages.append(std::move(message));
  }
  for (BridgeMessage &message : messages) {
    const bool running = bridge_modal_operator_running(C);
    if (!running) {
      bridge_undo_push_pending(C);
    }
    if ((running || !bridge_messages_waiting.is_empty()) && !bridge_message_live(message)) {
      bridge_messages_waiting.append(std::move(message));
      continue;
    }
    bridge_dispatching = true;
    bridge_dispatch(C, message);
    bridge_dispatching = false;
    handled_commands = true;
  }
  if (!bridge_modal_operator_running(C)) {
    bridge_undo_push_pending(C);
  }

  const bool hover_changed = bridge_hover_requests.take(bridge_hover_request);
  {
    const BridgeContextStore context_store = bridge_context_push_view3d(C);
    ARegion *region = CTX_wm_region(C);
    wmWindow *window = CTX_wm_window(C);
    if (hover_changed && window) {
      /* Removing a cursor needs a frame even when no mesh hover target changed. */
      WM_paint_cursor_tag_redraw(window, region);
      if (bScreen *screen = WM_window_get_active_screen(window)) {
        screen->do_draw_gesture = true;
      }
    }
    bool active = bridge_hover_request.active && bridge_hover_highlight && window && region;
    if (active) {
      for (wmEventHandler &handler : window->runtime->modalhandlers) {
        if (handler.type == WM_HANDLER_TYPE_OP || handler.type == WM_HANDLER_TYPE_UI) {
          active = false;
          break;
        }
      }
      if (region->runtime->gizmo_map && wm_gizmomap_highlight_get(region->runtime->gizmo_map)) {
        active = false;
      }
    }
    int mval[2] = {bridge_hover_request.x, bridge_hover_request.y};
    if (window && region) {
      wm_cursor_position_from_ghost_client_coords(window, &mval[0], &mval[1]);
      mval[0] -= region->winrct.xmin;
      mval[1] -= region->winrct.ymin;
    }
    /* Dragging a material or a modifier, the object it would drop on is highlighted as Pencil
     * hover highlights it. */
    const wmDrag *drag = window ?
                             static_cast<const wmDrag *>(CTX_wm_manager(C)->runtime->drags.first) :
                             nullptr;
    const bool drag_to_object = drag && region &&
                                (WM_drag_is_ID_type(drag, ID_MA) ||
                                 WM_drag_is_ID_type(drag, ID_NT));
    if (drag_to_object) {
      active = true;
      mval[0] = bridge_asset_drag_xy.x - region->winrct.xmin;
      mval[1] = bridge_asset_drag_xy.y - region->winrct.ymin;
    }
    ED_view3d_pencil_hover_update(C, active, mval, drag_to_object);
    const View3DPencilHover hit = ED_view3d_pencil_hover_get(region);
    /* Published when it changes: every snapshot wakes the native interface. */
    static std::string hover_published;
    std::string hover = "{\"object\":" + std::to_string(hit.object_uid) +
                        ",\"kind\":" + std::to_string(hit.kind) +
                        ",\"index\":" + std::to_string(hit.index) +
                        ",\"cursorVisible\":" + (bridge_hover_request.active ? "true" : "false") +
                        "}";
    if (hover != hover_published) {
      hover_published = hover;
      bridge_hover_snapshot.publish(std::move(hover));
    }
    bridge_context_pop(C, context_store);
  }

  bridge_toolbar_build(C, handled_commands);
  bridge_volume_build(C);
  {
    /* Views are built as Blender's own editors draw: in the window, its 3D View current. */
    const BridgeContextStore context_store = bridge_context_push_view3d(C);
    WM_native_ui_views_flush(C);
    bridge_context_pop(C, context_store);
  }
}

}  // namespace blender
