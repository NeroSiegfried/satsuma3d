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
#include "BKE_library.hh"
#include "BKE_lib_id.hh"
#include "BKE_main.hh"
#include "BKE_object.hh"
#include "BKE_packedFile.hh"
#include "BKE_paint.hh"
#include "BKE_preferences.h"
#include "BKE_preview_image.hh"
#include "BKE_scene.hh"
#include "BKE_screen.hh"
#include "BKE_workspace.hh"
#include "BKE_undo_system.hh"
#include "BKE_vfont.hh"
#include "DNA_vfont_types.h"
#include "BKE_wm_runtime.hh"
#include "BLF_api.hh"
#include "BLO_readfile.hh"
#include "BLT_translation.hh"
#include "ED_render.hh"

#include "BLI_fileops.h"
#include "BLI_listbase.h"
#include "BLI_map.hh"
#include "BLI_math_vector.h"
#include "BLI_path_utils.hh"
#include "BLI_string.h"
#include "BLI_serialize.hh"
#include "BLI_set.hh"
#include "BLI_time.h"
#include "BLI_timer.h"
#include "DNA_view3d_types.h"

#include "BLI_math_color.h"
#include "CLG_log.h"
#include "GHOST_IWindow.hh"
#include "GHOST_Mailbox.hh"

#include "DEG_depsgraph.hh"
#include "DEG_depsgraph_build.hh"

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
#include "RNA_path.hh"

#include "SEQ_sequencer.hh"
#include "RNA_define.hh"

#include "RNA_enum_types.hh"
#include "RNA_prototypes.hh"
#include "UI_interface_c.hh"
#include "UI_resources.hh"
#include "UI_view2d.hh"

#ifdef WITH_PYTHON
#  include "BPY_extern_run.hh"
#  include "MEM_guardedalloc.h"
#endif

#include "WM_api.hh"
#include "WM_gizmo_api.hh"
#include "WM_keymap.hh"
#include "WM_native_interface.hh"
#include "WM_native_ui.h"
#include "wm_native_ui_timing.hh"
#include "WM_native_ui.hh"
#include "WM_native_ui_views.hh"
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
#include <cfloat>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <mutex>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <type_traits>
#include <variant>
#include <vector>

#include <fmt/format.h>

namespace blender::ui::native {
void menu_write(bContext *C, StringRef route, wm::native_ui::ViewBuilder &builder);
void menu_run(bContext *C, StringRef route);
bool menu_can_show(bContext *C, StringRef idname);
void menu_popup_asked(StringRef idname);
}  // namespace blender::ui::native
namespace blender::ed::graph {
std::shared_ptr<io::serialize::DictionaryValue> native_graph_read(
    bContext *C, const io::serialize::DictionaryValue &state);
std::string native_graph_edit(bContext *C, const io::serialize::DictionaryValue &edit);
}  // namespace blender::ed::graph
namespace blender::ui {
void native_properties_interaction_finish(bContext *C);
}  // namespace blender::ui

namespace blender {

/** The interface's short messages as JSON, see #WM_native_ui_notice. */
static std::string bridge_notices_json();
/** Why \a ot cannot run in \a C, in words for the person, after its poll failed. */
static std::string bridge_operator_unavailable(bContext *C, wmOperatorType *ot);

static CLG_LogRef LOG = {"wm.native"};

/* The scene as 3D geometry for a volumetric window, see `wm_apple_ios_volume.cc`. */
void bridge_volume_build(bContext *C);
bool bridge_volume_command(bContext *C, StringRef setting, StringRef value);

void bridge_interface_set(bContext *C, bool desktop);
void bridge_desktop_uv_editing(bContext *C);
void bridge_desktop_scale_set(bContext *C, float scale);
void bridge_interface_measure();

namespace {

/** A change the views make as the settings of the same names did, see #bridge_setting_execute. */
struct BridgeSettingCommand {
  std::string setting;
  std::string value;
};

/** Native asset pane drags; see #bridge_asset_drag. */
enum BridgeAssetDragPhase {
  BRIDGE_ASSET_DRAG_BEGIN,
  BRIDGE_ASSET_DRAG_MOVE,
  BRIDGE_ASSET_DRAG_DROP,
  BRIDGE_ASSET_DRAG_CANCEL,
  /** Drop at the 3D cursor, or onto the active object for materials and node groups, as the
   * `assets` view's rows do when invoked. */
  BRIDGE_ASSET_ADD,
  /** Internal second step of #BRIDGE_ASSET_ADD: release at window coordinates. */
  BRIDGE_ASSET_ADD_RELEASE,
};
static_assert(int(BRIDGE_ASSET_DRAG_BEGIN) == int(WM_NATIVE_UI_ASSET_DRAG_BEGIN) &&
                  int(BRIDGE_ASSET_DRAG_CANCEL) == int(WM_NATIVE_UI_ASSET_DRAG_CANCEL),
              "Asset drags as WM_native_ui.h numbers them");

struct BridgeAssetDragCommand {
  int phase = BRIDGE_ASSET_DRAG_MOVE;
  std::string key;
  int x = 0, y = 0;
};

/** Input from the interface that is not a command to a view: two fingers turning the view, by an
 * angle, and an asset dragged into it. */
using BridgeMessage = std::variant<float, BridgeAssetDragCommand>;
/* One inbox, in the order they came. */
GHOST_MessageQueue<BridgeMessage> bridge_messages;
bool bridge_layout_ready = false;
bool bridge_gizmo_refresh_pending = true;
/** Blender's own interface instead of the native one: normal screens, no native controls. */
std::atomic<bool> bridge_desktop_ui{false};
/** The size of Blender's own interface, as the app's own setting (ROUND5 9C, decision 56): a factor
 * of what Blender would draw on the iPad, only while Blender's own interface shows. */
std::atomic<float> bridge_desktop_scale{0.75f};
/** Changed preferences are saved shortly after, as the iPad may end the app without warning. */
bool bridge_preferences_save_pending = false;
std::chrono::steady_clock::time_point bridge_preferences_save_at;
/** The native image editor's state: the image chosen and whether UVs show over it. */
std::shared_ptr<const io::serialize::DictionaryValue> bridge_image_state;
/* An interface shows the image editor, see #bridge_image_view_shown. */
bool bridge_image_shown = false;
/** Its picture and UVs, taken by the native editor when they change. */
GHOST_Latest<ed::image::NativeImagePixels> bridge_image_pixels;
GHOST_Latest<ed::image::NativeImageUVs> bridge_image_uvs;
/** The picture changed since it was last sent, which waits a little while painting. */
bool bridge_image_pixels_pending = true;
bool bridge_image_uvs_pending = true;
/* How the native storyboard shows the shots, see `sequencer_native.cc`: the frames between their
 * pictures, and their size. */
std::shared_ptr<const io::serialize::DictionaryValue> bridge_storyboard_state;
/* Pictures of shots were still to draw when the storyboard was last read. */
bool bridge_storyboard_pending = false;
std::atomic<bool> bridge_navigation_hover_active{false};
std::atomic<bool> bridge_navigation_redraw_pending{false};
/** Height of the native bottom tray (the asset pane) as a fraction of the window height. */
std::atomic<float> bridge_bottom_tray{0.0f};
/** Window pixels a native panel covers at the bottom, which the 3D views leave out. */
std::atomic<float> bridge_viewport_cover{0.0f};
/** Window pixels a native panel covers at the right, such as the Image Editor beside the 3D view. */
std::atomic<float> bridge_viewport_trailing_cover{0.0f};
std::atomic<bool> bridge_viewport_cover_changed{false};
/** Window pixels the sidebars lying over the viewport cover at its sides (ROUND5 10B): the 3D View
 * keeps its size and only keeps what it draws at its edges, and what it frames, clear of them. */
std::atomic<float> bridge_viewport_leading_inset{0.0f};
std::atomic<float> bridge_viewport_trailing_inset{0.0f};
std::atomic<bool> bridge_viewport_insets_changed{false};
struct BridgePencilHoverRequest {
  bool active = false;
  int x = 0, y = 0;
};
GHOST_Latest<BridgePencilHoverRequest> bridge_hover_requests;
/* Window coordinates of the asset drag in progress. */
int2 bridge_asset_drag_xy(0);
BridgePencilHoverRequest bridge_hover_request;

std::string bridge_json_escape(const std::string &value);
/** What shows after the last command, see `bridge_reveal_after`. */
static int bridge_reveal_number = 0;
/* Published from the start, before any command: the shell takes the first number it sees for one
 * decided before its window opened and does not act on it, so without this the first command of a
 * session revealed nothing (ROUND5 10A, 2026-11-18). */
static std::string bridge_reveal_json = "{\"number\":0}";
std::string bridge_json_number(double value);

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
 * The modal operators that get no Confirm and Cancel bar, each with why (ROUND6 TOUCH-5, finding
 * C1): only what has no end to offer there, because the finger or Pencil that drives it ends it as
 * it lifts, or the hint (#bridge_waiting_hint) offers the Cancel. Matched against the idname as a
 * prefix, or anywhere with `contains`; a member of a listed family that does wait for more is named
 * in #bridge_bar_shown_anyway. The harness's `waiting` scenario and the shell's sources test read
 * this list.
 */
struct BridgeBarExclusion {
  const char *pattern;
  bool contains;
  const char *reason;
};
static const BridgeBarExclusion bridge_bar_exclusions[] = {
    {"VIEW3D_OT_", false,
     "the 3D View's navigation and gestures: a drag that ends as the finger lifts, or a command "
     "waiting for its drag, whose hint offers Cancel"},
    {"VIEW2D_OT_", false, "a 2D view's navigation: a drag that ends as the finger lifts"},
    {"IMAGE_OT_view", false, "the Image Editor's navigation: a drag that ends as the finger lifts"},
    {"NODE_OT_view", false, "the Node Editor's navigation: a drag that ends as the finger lifts"},
    {"SCREEN_OT_", false,
     "dragging Blender's own area and region edges: ends as the finger lifts"},
    {"GIZMOGROUP_OT_", false, "a gizmo's drag: ends as the finger lifts"},
    {"stroke", true, "a brush stroke: ends as the finger or Pencil lifts"},
};

/** Members of the excluded families that wait for more than one drag: they get the bar. */
static bool bridge_bar_shown_anyway(const StringRef idname)
{
  return ELEM(idname, "VIEW3D_OT_walk", "VIEW3D_OT_fly") || idname.find("eyedropper") != StringRef::not_found;
}

/** Why \a idname gets no bar, or null when it does (ROUND6 TOUCH-5). */
const char *bridge_bar_excluded(const StringRef idname)
{
  if (bridge_bar_shown_anyway(idname)) {
    return nullptr;
  }
  if (idname.startswith("UI_OT_")) {
    return "a drag of one of Blender's own controls: ends as the finger lifts";
  }
  for (const BridgeBarExclusion &exclusion : bridge_bar_exclusions) {
    if (exclusion.contains ? idname.find(exclusion.pattern) != StringRef::not_found :
                             idname.startswith(exclusion.pattern))
    {
      return exclusion.reason;
    }
  }
  return nullptr;
}

/**
 * The operation a touch waits on: the first operator heading the window's modal handlers, unless
 * #bridge_bar_excluded says it has no end to offer, or it is a drag gesture (box, lasso, circle,
 * line), which ends as the finger lifts and whose wait shows the hint with Cancel. A polyline
 * gesture waits for several taps and gets the bar (ROUND6 TOUCH-5, finding C1).
 */
wmOperator *bridge_waiting_operator(wmWindow *win)
{
  if (win == nullptr) {
    return nullptr;
  }
  for (wmEventHandler &handler_base : win->runtime->modalhandlers) {
    if (handler_base.type != WM_HANDLER_TYPE_OP) {
      continue;
    }
    wmOperator *op = reinterpret_cast<wmEventHandler_Op &>(handler_base).op;
    if (op == nullptr || op->type == nullptr) {
      return nullptr;
    }
    if (bridge_bar_excluded(op->type->idname)) {
      return nullptr;
    }
    for (const wmGesture &gesture : win->runtime->gesture) {
      if (gesture.type != WM_GESTURE_POLYLINE) {
        return nullptr;
      }
    }
    return op;
  }
  return nullptr;
}

/**
 * What to do for a command that waits in the view before it starts (ROUND6 TOUCH-5, finding A3):
 * one state for a command that waits for a click to place it ("Input pending", Rip Vertices, Vertex
 * Slide, Sample Color, ...) and for every gesture that waits for its drag (Box Select chosen from a
 * menu, Bisect, a box mask, ...). Null when nothing waits, or a tool's own drag already runs; the
 * shell shows it with Cancel (Escape), or Done where it ends with one. `done` says it ends with
 * Done rather than after one drag. Into \a r_text, as it may name the operator.
 */
static bool bridge_waiting_hint(wmWindow *win, bool *r_done, std::string &r_text)
{
  *r_done = false;
  if (win == nullptr) {
    return false;
  }
  /* A command waiting for a click to place it. */
  if (const wmOperatorType *ot = WM_event_wait_for_input_operator(win)) {
    r_text = fmt::format(fmt::runtime(IFACE_("Tap where to run {}")),
                         CTX_IFACE_(ot->translation_context, ot->name));
    return true;
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
    if (op == nullptr || op->type == nullptr) {
      continue;
    }
    const auto hint = hints.find(op->type->idname);
    if (STREQ(op->type->idname, "VIEW3D_OT_dolly")) {
      r_text = IFACE_(hint->second);
      return true;
    }
    /* A gesture waiting for its drag, not one a tool started with it. Any operator's: those
     * without words of their own are named. */
    for (const wmGesture &gesture : win->runtime->gesture) {
      const bool circle = gesture.type == WM_GESTURE_CIRCLE;
      /* A straight line waits for its press without `wait_for_input`: not yet active. */
      const bool waits = gesture.wait_for_input || !gesture.is_active;
      if (gesture.type == WM_GESTURE_POLYLINE || !(waits || circle)) {
        continue;
      }
      if (circle && hint == hints.end() && !gesture.wait_for_input) {
        continue;
      }
      *r_done = circle && gesture.wait_for_input;
      if (gesture.is_active && !*r_done) {
        return false;
      }
      r_text = hint != hints.end() ?
                   std::string(IFACE_(hint->second)) :
                   fmt::format(fmt::runtime(IFACE_("Drag in the view to run {}")),
                               WM_operatortype_name(op->type, op->ptr));
      return true;
    }
  }
  return false;
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
  else if (wmOperatorType *ot = WM_operatortype_find(op_name, true)) {
    /* A tap is answered: say why it did nothing. */
    WM_native_ui_notice(RPT_WARNING, bridge_operator_unavailable(C, ot).c_str());
  }
}

/** Run \a ot with \a props as a tap on the interface does, or say why it cannot run. */
static void bridge_operator_call_ptr(bContext *C, wmOperatorType *ot, PointerRNA *props)
{
  if (WM_operator_poll(C, ot)) {
    WM_operator_name_call_ptr(C, ot, blender::wm::OpCallContext::ExecRegionWin, props, nullptr);
  }
  else {
    WM_native_ui_notice(RPT_WARNING, bridge_operator_unavailable(C, ot).c_str());
  }
}

/** The operator Repeat Last would run, as `repeat_last_exec` finds it, if it can run again. */
wmOperator *bridge_repeatable_operator(bContext *C)
{
  wmWindowManager *wm = CTX_wm_manager(C);
  if (wm == nullptr) {
    return nullptr;
  }
  for (wmOperator *op = static_cast<wmOperator *>(wm->runtime->operators.last); op; op = op->prev) {
    if (op->type->flag & OPTYPE_REGISTER) {
      return WM_operator_repeat_check(C, op) ? op : nullptr;
    }
  }
  return nullptr;
}


}  // namespace

bool WM_native_ui_is_undo_command(const std::string_view idname)
{
  return ELEM(idname, "ED_OT_undo", "ED_OT_redo", "ED_OT_undo_history");
}

std::string WM_native_ui_undo_refusal(bContext *C)
{
  wmWindowManager *wm = CTX_wm_manager(C);
  if (wm == nullptr) {
    return "";
  }
  for (wmWindow &win : wm->windows) {
    for (wmEventHandler &handler : win.runtime->modalhandlers) {
      if (handler.type != WM_HANDLER_TYPE_OP) {
        continue;
      }
      const wmEventHandler_Op &op_handler = reinterpret_cast<wmEventHandler_Op &>(handler);
      if (op_handler.is_fileselect || op_handler.op == nullptr) {
        continue;
      }
      const std::string text = fmt::format(
          fmt::runtime(IFACE_("Finish or cancel {} first")),
          WM_operatortype_name(op_handler.op->type, op_handler.op->ptr));
      WM_native_ui_notice(RPT_WARNING, text.c_str());
      return text;
    }
  }
  return "";
}

namespace {

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

/** The active object's data, should it come from a library, so that no mode but Object Mode can
 * edit it, as with an asset just added. */
static ID *bridge_mode_linked_data(bContext *C)
{
  Object *ob = CTX_data_active_object(C);
  ID *data = ob ? static_cast<ID *>(ob->data) : nullptr;
  return data && !ID_IS_EDITABLE(data) ? data : nullptr;
}

void bridge_mode_set(bContext *C, const char *mode)
{
  wmOperatorType *ot = WM_operatortype_find("OBJECT_OT_mode_set", false);
  if (ot == nullptr) {
    return;
  }

  /* Offer to make linked data local, rather than only saying it has to be. */
  const wmNativeInterface *native = WM_native_interface();
  if (ID *data = bridge_mode_linked_data(C); data && !STR_ELEM(mode, "OBJECT", "POSE") &&
                                             native && native->alert)
  {
    wmNativeAlert alert;
    alert.title = RPT_("Make Local?");
    alert.message = std::string("\"") + BKE_id_name(*data) + "\" " +
                    RPT_("is linked from a library, so it cannot be edited. Make it local to "
                         "edit it in this file.");
    alert.actions = {{IFACE_("Cancel"), wmNativeAlert::Role::Cancel}, {IFACE_("Make Local")}};
    alert.preferred_action = 1;
    native->alert(
        C,
        alert,
        [mode = std::string(mode)](bContext *C, const int action, uint64_t) {
          ID *data = bridge_mode_linked_data(C);
          if (action != 1 || !data) {
            return;
          }
          Main *bmain = CTX_data_main(C);
          if (BKE_lib_id_make_local(bmain, data, LIB_ID_MAKELOCAL_ASSET_DATA_CLEAR)) {
            BKE_id_newptr_and_tag_clear(data);
            DEG_relations_tag_update(bmain);
            WM_event_add_notifier(C, NC_WINDOW, nullptr);
            ED_undo_push(C, "Make Local");
          }
          if (!bridge_mode_linked_data(C)) {
            bridge_mode_set(C, mode.c_str());
          }
        },
        {},
        "bridge_make_local");
    return;
  }

  PointerRNA props = WM_operator_properties_create_ptr(ot);
  RNA_enum_set_identifier(C, &props, "mode", mode);
  RNA_boolean_set(&props, "toggle", false);
  bridge_operator_call_ptr(C, ot, &props);
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

/** The element snapping goes to, whether or not snapping is on: "mixed" for several. */
const char *bridge_snap_element_id(const ToolSettings *settings)
{
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
  /** What Blender's header calls it in the mode. */
  const char *label = "Mirror";
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
      return BridgeMirror{RNA_id_pointer_create(static_cast<ID *>(ob->data)),
                          "use_mirror_",
                          "x",
                          std::nullopt,
                          "X-Axis Mirror"};
    case CTX_MODE_POSE:
      if (ob->pose == nullptr) {
        return std::nullopt;
      }
      return BridgeMirror{RNA_pointer_create_discrete(&ob->id, RNA_Pose, ob->pose),
                          "use_mirror_",
                          "x",
                          std::nullopt,
                          "X-Axis Mirror"};
    /* Painting and sculpting mirror across the mesh's own axes, as their headers' Symmetry. */
    case CTX_MODE_SCULPT:
    case CTX_MODE_PAINT_WEIGHT:
    case CTX_MODE_PAINT_VERTEX:
    case CTX_MODE_PAINT_TEXTURE:
      if (ob->type != OB_MESH) {
        return std::nullopt;
      }
      return BridgeMirror{RNA_id_pointer_create(static_cast<ID *>(ob->data)),
                          "use_mirror_",
                          "xyz",
                          mode == CTX_MODE_PAINT_WEIGHT ?
                              std::optional<PointerRNA>(
                                  RNA_id_pointer_create(static_cast<ID *>(ob->data))) :
                              std::nullopt,
                          "Symmetry"};
    case CTX_MODE_SCULPT_CURVES:
      if (ob->type != OB_CURVES) {
        return std::nullopt;
      }
      return BridgeMirror{RNA_id_pointer_create(static_cast<ID *>(ob->data)),
                          "use_mirror_",
                          "xyz",
                          std::nullopt,
                          "Symmetry"};
    default:
      return std::nullopt;
  }
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
  bridge_operator_call_ptr(C, ot, &props);
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
/* Blender's own navigation gizmo unless Settings choose the minimal touch one. */
static std::atomic<bool> bridge_navigation_minimal = false;
static std::atomic<bool> bridge_navigation_left = false;

/**
 * The character a key types, as a US keyboard types it (with \a shift held or not), or 0 for a
 * key that types none. An injected key carries it as the keyboard's would: Blender's numeric
 * input and text fields read typed digits and signs from #wmEvent::utf8_buf, not from the key
 * type (R6 C3).
 */
static char bridge_key_character(const wmEventType type, const bool shift)
{
  if (type >= EVT_ZEROKEY && type <= EVT_NINEKEY) {
    return shift ? ")!@#$%^&*("[type - EVT_ZEROKEY] : char('0' + (type - EVT_ZEROKEY));
  }
  if (type >= EVT_AKEY && type <= EVT_ZKEY) {
    return char((shift ? 'A' : 'a') + (type - EVT_AKEY));
  }
  if (type >= EVT_PAD0 && type <= EVT_PAD9) {
    return char('0' + (type - EVT_PAD0));
  }
  switch (type) {
    case EVT_PADPERIOD:
      return '.';
    case EVT_PADASTERKEY:
      return '*';
    case EVT_PADSLASHKEY:
      return '/';
    case EVT_PADMINUS:
      return '-';
    case EVT_PADPLUSKEY:
      return '+';
    case EVT_SPACEKEY:
      return ' ';
    case EVT_SEMICOLONKEY:
      return shift ? ':' : ';';
    case EVT_PERIODKEY:
      return shift ? '>' : '.';
    case EVT_COMMAKEY:
      return shift ? '<' : ',';
    case EVT_QUOTEKEY:
      return shift ? '"' : '\'';
    case EVT_ACCENTGRAVEKEY:
      return shift ? '~' : '`';
    case EVT_MINUSKEY:
      return shift ? '_' : '-';
    case EVT_SLASHKEY:
      return shift ? '?' : '/';
    case EVT_BACKSLASHKEY:
      return shift ? '|' : '\\';
    case EVT_EQUALKEY:
      return shift ? '+' : '=';
    case EVT_LEFTBRACKETKEY:
      return shift ? '{' : '[';
    case EVT_RIGHTBRACKETKEY:
      return shift ? '}' : ']';
    default:
      return 0;
  }
}

void bridge_setting_execute(bContext *C, const BridgeSettingCommand &command)
{
#ifdef WITH_PYTHON
  if (command.setting == "keymap") {
    /* From the iPad's Settings, see `bl_ui.native_settings`. */
    const char *imports[] = {"bpy", "bl_ui", nullptr};
    const std::string expression = "bl_ui.native_settings.keymap_set(bpy.context, \"" +
                                   bridge_json_escape(command.value) + "\")";
    BPY_run_string_eval(C, imports, expression.c_str());
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
  if (ELEM(command.setting, "native_brush", "native_brush_commit")) {
    /* The sidebar's size and strength, and the color well, see `bl_ui.native_brush`: the value's
     * key and value. A drag sends many values and one undo step as it ends. */
    const BridgeContextStore context_store = bridge_context_push_view3d(C);
    const char *imports[] = {"bpy", "bl_ui", nullptr};
    const std::string expression = "bl_ui.native_brush.brush_set(bpy.context, " + command.value +
                                   ")";
    BPY_run_string_eval(C, imports, expression.c_str());
    if (command.setting == "native_brush_commit") {
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
  if (command.setting == "addon_install") {
    /* A file the person picked in the native interface, installed in-process, see
     * `bl_ui.native_addons.install`: iPadOS runs no helper process for the extensions platform. */
    const char *imports[] = {"bpy", "bl_ui", nullptr};
    const std::string expression = "bl_ui.native_addons.install(bpy.context, \"" +
                                   bridge_json_escape(command.value) + "\")";
    BPY_run_string_eval(C, imports, expression.c_str());
    /* The add-ons list and the menus and panels an add-on brings. */
    wm::native_ui::view_type_dirty("preferences_list");
    WM_main_add_notifier(NC_WINDOW, nullptr);
    return;
  }
  if (command.setting == "native_action") {
    /* The button may predate a context change; `run` checks the action still applies. */
    const bToolRef *tool = bridge_active_tool(C);
    const char *imports[] = {"bpy", "bl_ui", nullptr};
    const std::string expression = "bl_ui.native_actions.run_reported(bpy.context, \"" +
                                   bridge_json_escape(command.value) + "\", \"" +
                                   bridge_json_escape(tool ? tool->idname : "") + "\")";
    /* Why it did not run, when it did not: a tap is answered. */
    char *reason = nullptr;
    if (BPY_run_string_as_string(C, imports, expression.c_str(), nullptr, &reason) && reason) {
      WM_native_ui_notice(RPT_WARNING, reason);
    }
    if (reason) {
      MEM_delete(reason);
    }
    return;
  }
#endif

  if (command.setting == "modal_key") {
    /* A key the waiting operation listens for, pressed and let go, as on a keyboard:
     * `shift+ctrl+B`, by Blender's event type names. */
    wmWindow *win = CTX_wm_window(C);
    if (win == nullptr || win->runtime->eventstate == nullptr) {
      return;
    }
    std::string name = command.value;
    wmEvent event = *win->runtime->eventstate;
    event.modifier = wmEventModifierFlag(0);
    for (const auto &[prefix, flag] : {std::pair{"shift+", KM_SHIFT},
                                       std::pair{"ctrl+", KM_CTRL},
                                       std::pair{"alt+", KM_ALT},
                                       std::pair{"oskey+", KM_OSKEY}})
    {
      if (StringRef(name).startswith(prefix)) {
        event.modifier = wmEventModifierFlag(event.modifier | flag);
        name = name.substr(strlen(prefix));
      }
    }
    int type = 0;
    if (!RNA_enum_value_from_id(rna_enum_event_type_items, name.c_str(), &type)) {
      return;
    }
    event.type = wmEventType(type);
    event.val = KM_PRESS;
    event.flag = eWM_EventFlag(0);
    event.prev_type = EVENT_NONE;
    /* The character the key types, as a keyboard's press carries it; a release carries none. */
    memset(event.utf8_buf, 0, sizeof(event.utf8_buf));
    if ((event.modifier & (KM_CTRL | KM_ALT | KM_OSKEY)) == 0) {
      event.utf8_buf[0] = bridge_key_character(event.type, event.modifier & KM_SHIFT);
    }
    WM_event_add(win, &event);
    if (!ISMOUSE_WHEEL(event.type)) {
      event.val = KM_RELEASE;
      event.utf8_buf[0] = '\0';
      WM_event_add(win, &event);
    }
    WM_event_add_mousemove(win);
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

  /* Blender's header pairs: snapping and proportional editing each a toggle beside a dropdown of
   * what it uses, and Auto Merge. Values are "on" and "off" for the toggles. */
  if (command.setting == "snap_on") {
    bridge_rna_undo_push(
        C, bridge_rna_boolean_set(C, tool_settings_ptr, "use_snap", command.value == "on"));
    return;
  }
  if (command.setting == "snap_element") {
    bridge_rna_undo_push(
        C,
        bridge_rna_enum_set(C, tool_settings_ptr, "snap_elements", bridge_snap_mode_for_id(command.value)));
    return;
  }
  if (command.setting == "proportional_on") {
    bridge_rna_undo_push(C,
                         bridge_rna_boolean_set(C,
                                                tool_settings_ptr,
                                                CTX_data_mode_enum(C) == CTX_MODE_OBJECT ?
                                                    "use_proportional_edit_objects" :
                                                    "use_proportional_edit",
                                                command.value == "on"));
    return;
  }
  if (command.setting == "proportional_falloff") {
    PropertyRNA *prop = RNA_struct_find_property(&tool_settings_ptr, "proportional_edit_falloff");
    int value = 0;
    if (prop && RNA_property_enum_value(C, &tool_settings_ptr, prop, command.value.c_str(), &value)) {
      bridge_rna_undo_push(C, bridge_rna_enum_set(C, tool_settings_ptr, "proportional_edit_falloff", value));
    }
    return;
  }
  if (command.setting == "automerge") {
    bridge_rna_undo_push(
        C, bridge_rna_boolean_set(C, tool_settings_ptr, "use_mesh_automerge", command.value == "on"));
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




}

/* -------------------------------------------------------------------- */
/** \name Native Brush Rail
 *
 * Projects the brush asset shelf of the current paint mode. Filtering, ordering of the asset
 * list, the active brush and activation all go through the shelf type, so the native rail lists
 * the same brushes as Blender's own asset shelf popup (without its per-tool filter).
 * \{ */

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

/**
 * The brushes the mode offers, as its asset shelf lists them, grouped by catalog: `brushes`, a list
 * whose rows are keyed by the brushes' references and `Activate` them. Previews load in the
 * background, their pictures written a few at a time, the list built again soon until all are.
 */
void bridge_brushes_view_build(bContext *C,
                               const wm::native_ui::Params & /*params*/,
                               wm::native_ui::ViewData * /*data*/,
                               wm::native_ui::ViewBuilder &builder)
{
  namespace protocol = wm::native_ui::protocol;
  using wm::native_ui::NodeFields;
  struct BrushItem {
    std::string key;
    std::string name;
    std::string catalog;
    std::string preview;
  };
  /* As last listed, kept while the asset libraries (re)load. */
  static std::vector<BrushItem> items;
  const auto top = builder.top("brushes", [](flatbuffers::FlatBufferBuilder &buffer, NodeFields &) {
    return protocol::CreateGroup(buffer);
  });
  const bool has_view3d = CTX_wm_window(C) && CTX_wm_area(C) && CTX_wm_region(C);
  const AssetShelfType *shelf_type = has_view3d ? bridge_brush_shelf_type(CTX_data_mode_enum(C)) :
                                                  nullptr;
  Paint *paint = has_view3d ? BKE_paint_get_active_from_context(C) : nullptr;
  if (shelf_type == nullptr || paint == nullptr) {
    items.clear();
    return;
  }

  const AssetLibraryReference library_ref = asset_system::all_library_reference();
  ed::asset::list::storage_fetch(&library_ref, C);
  const bool loaded = ed::asset::list::is_loaded(&library_ref);
  bool previews_missing = false;
  if (loaded) {
    items.clear();
    /* Writing previews' pictures is spread over several builds. */
    int preview_budget = 8;
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
    /* Grouped by catalog, as the shelf's catalog tabs; uncatalogued brushes go last. */
    std::stable_sort(items.begin(), items.end(), [](const BrushItem &a, const BrushItem &b) {
      if (a.catalog.empty() != b.catalog.empty()) {
        return b.catalog.empty();
      }
      return a.catalog < b.catalog;
    });
  }

  const std::string active = paint->brush_asset_reference ?
                                 bridge_brush_key(*paint->brush_asset_reference) :
                                 "";
  const bool loading = !loaded || previews_missing;
  const auto list = builder.add(
      top, "brushes", [&](flatbuffers::FlatBufferBuilder &buffer, NodeFields &fields) {
        fields.label = shelf_type->idname;
        return protocol::CreateListDirect(
            buffer, active.c_str(), false, false, false, false, nullptr, loading);
      });
  for (const BrushItem &item : items) {
    builder.add(list, item.key, [&](flatbuffers::FlatBufferBuilder &buffer, NodeFields &fields) {
      fields.label = item.name;
      return protocol::CreateRowDirect(buffer,
                                       0,
                                       item.key == active,
                                       false,
                                       item.preview.empty() ? nullptr : item.preview.c_str(),
                                       item.catalog.substr(item.catalog.rfind('/') + 1).c_str());
    });
  }
  if (loading) {
    /* Again soon, until the libraries are loaded and every preview written. */
    wm::native_ui::view_type_dirty("brushes");
  }
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

/**
 * The `assets` view: the assets the pane offers, `assets`, a list whose rows are keyed by the
 * assets' references, and add an asset to the scene when invoked. Previews are written a few at a
 * time, the list built again soon until all are.
 */
void bridge_assets_view_build(bContext *C,
                              const wm::native_ui::Params & /*params*/,
                              wm::native_ui::ViewData * /*data*/,
                              wm::native_ui::ViewBuilder &builder)
{
  namespace protocol = wm::native_ui::protocol;
  using wm::native_ui::NodeFields;
  const auto top = builder.top("assets", [](flatbuffers::FlatBufferBuilder &buffer, NodeFields &) {
    return protocol::CreateGroup(buffer);
  });
  const AssetLibraryReference library_ref = asset_system::all_library_reference();
  ed::asset::list::storage_fetch(&library_ref, C);
  const bool loaded = ed::asset::list::is_loaded(&library_ref);
  /* Previews load in the background; writing their pictures is spread over several builds. */
  int preview_budget = 8;
  bool previews_missing = false;
  const auto list = builder.add(top, "assets", [&](flatbuffers::FlatBufferBuilder &buffer, NodeFields &) {
    return protocol::CreateListDirect(buffer, nullptr, false, false, false, false, nullptr, !loaded);
  });
  if (loaded) {
    ed::asset::list::iterate(library_ref, [&](asset_system::AssetRepresentation &asset) {
      if (!bridge_asset_listed(asset)) {
        return true;
      }
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
      builder.add(list, key, [&](flatbuffers::FlatBufferBuilder &buffer, NodeFields &fields) {
        fields.label = asset.get_name();
        fields.description = metadata.description ? metadata.description : "";
        std::vector<flatbuffers::Offset<flatbuffers::String>> tags;
        for (const AssetTag &tag : metadata.tags) {
          tags.push_back(buffer.CreateString(tag.name));
        }
        return protocol::CreateAssetDirect(
            buffer,
            bridge_asset_type_name(asset.get_id_type()),
            bridge_asset_library_name(library).c_str(),
            catalog.c_str(),
            metadata.author ? metadata.author : "",
            &tags,
            preview != bridge_brush_preview_paths.end() ? preview->second.c_str() : nullptr);
      });
      return true;
    });
  }
  if (!loaded || previews_missing) {
    /* Again soon, until the libraries are loaded and every preview written. */
    wm::native_ui::view_type_dirty("assets");
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

/**
 * In Edit Mode Blender's Add menu adds a primitive into the mesh being edited. The Starter
 * library's primitives are the same shapes as objects, which Blender only adds in Object Mode: in
 * Edit Mesh they are added as its primitives instead, as the Add menu would.
 */
static const char *bridge_asset_edit_mesh_primitive(asset_system::AssetRepresentation &asset)
{
  if (asset.get_id_type() != ID_OB ||
      asset.owner_asset_library().name() != BRIDGE_STARTER_LIBRARY_NAME)
  {
    return nullptr;
  }
  static const std::pair<StringRef, const char *> primitives[] = {
      {"Plane", "MESH_OT_primitive_plane_add"},
      {"Grid", "MESH_OT_primitive_grid_add"},
      {"Cube", "MESH_OT_primitive_cube_add"},
      {"UV Sphere", "MESH_OT_primitive_uv_sphere_add"},
      {"Ico Sphere", "MESH_OT_primitive_ico_sphere_add"},
      {"Cylinder", "MESH_OT_primitive_cylinder_add"},
      {"Cone", "MESH_OT_primitive_cone_add"},
      {"Torus", "MESH_OT_primitive_torus_add"},
      {"Circle", "MESH_OT_primitive_circle_add"},
  };
  const StringRef name = asset.get_name();
  for (const auto &[asset_name, op_name] : primitives) {
    if (name == asset_name) {
      return op_name;
    }
  }
  return nullptr;
}

/** A primitive dragged from the asset pane in Edit Mesh, added where it is let go. */
static std::string bridge_asset_edit_mesh_pending;

/** Add the mesh primitive \a op_name into the edited mesh, at window position \a xy on the plane
 * of the 3D cursor facing the view, or at the 3D cursor without one. */
static void bridge_asset_edit_mesh_add(bContext *C, const char *op_name, const int *xy)
{
  wmOperatorType *ot = WM_operatortype_find(op_name, true);
  if (ot == nullptr) {
    return;
  }
  PointerRNA props = WM_operator_properties_create_ptr(ot);
  ARegion *region = CTX_wm_region(C);
  View3D *v3d = CTX_wm_view3d(C);
  Scene *scene = CTX_data_scene(C);
  if (xy && region && v3d && scene && region->regiontype == RGN_TYPE_WINDOW) {
    const float mval[2] = {float(xy[0] - region->winrct.xmin), float(xy[1] - region->winrct.ymin)};
    float location[3];
    ED_view3d_win_to_3d(v3d, region, scene->cursor.location, mval, location);
    RNA_float_set_array(&props, "location", location);
  }
  bridge_operator_call_ptr(C, ot, &props);
  WM_operator_properties_free(&props);
}

/**
 * Whether the asset pane's \a asset can be added in the current mode as Blender would add it.
 * Objects and collections are added in Object Mode only, as Blender's own drop does; outside it
 * this says so, offering Object Mode, or adds a Starter primitive into the edited mesh.
 * Returns true when it handled the asset, \a xy being where it was let go, or null for a tap.
 */
static bool bridge_asset_outside_object_mode(bContext *C,
                                             asset_system::AssetRepresentation &asset,
                                             const int *xy,
                                             const bool drag)
{
  if (!ELEM(asset.get_id_type(), ID_OB, ID_GR) || CTX_data_mode_enum(C) == CTX_MODE_OBJECT) {
    return false;
  }
  const char *primitive = CTX_data_mode_enum(C) == CTX_MODE_EDIT_MESH ?
                              bridge_asset_edit_mesh_primitive(asset) :
                              nullptr;
  if (primitive == nullptr) {
    WM_native_ui_notice(RPT_WARNING,
                        IFACE_("Objects are added in Object Mode"),
                        (std::string(IFACE_("Object Mode")) + "\tmode:OBJECT").c_str());
  }
  else if (drag) {
    bridge_asset_edit_mesh_pending = primitive;
  }
  else {
    bridge_asset_edit_mesh_add(C, primitive, xy);
  }
  return true;
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
      bridge_asset_edit_mesh_pending.clear();
      if (asset && !dragging &&
          bridge_asset_outside_object_mode(
              C, *asset, nullptr, command.phase == BRIDGE_ASSET_DRAG_BEGIN))
      {
        break;
      }
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
      if (!bridge_asset_edit_mesh_pending.empty()) {
        const std::string op_name = std::move(bridge_asset_edit_mesh_pending);
        bridge_asset_edit_mesh_pending.clear();
        bridge_asset_edit_mesh_add(C, op_name.c_str(), xy);
        break;
      }
      if (dragging) {
        /* The release over a drop box becomes #EVT_DROP, as when releasing a dragged button. */
        bridge_asset_drop_snap_update(C, xy);
        bridge_asset_drag_event(win, xy, MOUSEMOVE, KM_NOTHING);
        bridge_asset_drag_event(win, xy, LEFTMOUSE, KM_RELEASE);
      }
      break;
    case BRIDGE_ASSET_DRAG_CANCEL:
      bridge_asset_edit_mesh_pending.clear();
      if (dragging) {
        /* Escape cancels a drag; queued, it also follows any pending moves. */
        bridge_asset_drag_event(win, win->runtime->eventstate->xy, EVT_ESCKEY, KM_PRESS);
      }
      break;
  }
  bridge_context_pop(C, context_store);
}

/** \} */

/** Set when Blender sent notifiers, see #WM_native_ui_tag_changed. */
bool bridge_changed = true;

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
        if (uchar(c) < 0x20) {
          /* Any other control character, which JSON only takes escaped. */
          escaped += fmt::format("\\u{:04x}", int(c));
        }
        else {
          escaped += c;
        }
        break;
    }
  }
  return escaped;
}

/** A number as JSON writes it, whatever the locale: shortest, and 0 for one that is not finite. */
std::string bridge_json_number(const double value)
{
  return std::isfinite(value) ? fmt::format("{}", value) : "0";
}

/* -------------------------------------------------------------------- */
/** \name The Toolbar View
 *
 * What the interface shows around the 3D viewport, see `WM_native_ui_views.hh`: the mode, tools,
 * undo, transform settings, the brush's direction and values, quick actions, and where Blender
 * draws what the interface keeps clear of. Nodes keyed as below; their commands run as the
 * settings of the same names did.
 * \{ */

namespace views = wm::native_ui;
using views::NodeFields;
using views::NodeId;
using ViewBuffer = flatbuffers::FlatBufferBuilder;
using OptionOffsets = std::vector<flatbuffers::Offset<views::protocol::Option>>;
/** Values of a choice and their labels. */
using OptionLabels = Span<std::pair<const char *, const char *>>;

/** The value a Python expression gives, or null. */
std::shared_ptr<io::serialize::Value> bridge_python_value(bContext *C,
                                                         const char *part,
                                                         const char *expression)
{
#ifdef WITH_PYTHON
  BridgeTimer timer(part);
  const char *imports[] = {"bpy", "bl_ui", nullptr};
  std::shared_ptr<io::serialize::Value> value = BPY_run_string_as_value(C, imports, expression, nullptr);
  if (!value) {
    /* Python's error goes to the console, which a device does not keep: say it in the session's
     * log, or a whole feature fails without a trace (Stage 2A's reveal rules did, for a day). */
    WM_native_ui_session_log("error", (std::string("python ") + part + " failed: " +
                                       std::string(expression).substr(0, 120))
                                          .c_str());
  }
  return value;
#else
  UNUSED_VARS(C, part, expression);
  return nullptr;
#endif
}

double bridge_number(const io::serialize::DictionaryValue &dictionary,
                     const StringRef key,
                     const double fallback)
{
  if (const std::optional<double> value = dictionary.lookup_double(key)) {
    return *value;
  }
  if (const std::optional<int64_t> value = dictionary.lookup_int(key)) {
    return double(*value);
  }
  return fallback;
}

bool bridge_flag(const io::serialize::DictionaryValue &dictionary, const StringRef key)
{
  const std::shared_ptr<io::serialize::Value> *value = dictionary.lookup(key);
  const io::serialize::BooleanValue *flag = value ? (*value)->as_boolean_value() : nullptr;
  return flag && flag->value();
}

std::string_view bridge_text(const io::serialize::DictionaryValue &dictionary, const StringRef key)
{
  const std::optional<StringRefNull> value = dictionary.lookup_str(key);
  return value ? std::string_view(*value) : std::string_view();
}

flatbuffers::Offset<views::protocol::Data> bridge_data(ViewBuffer &buffer, const bool value)
{
  return views::protocol::CreateData(buffer,
                                     views::protocol::Value::BoolValue,
                                     views::protocol::CreateBoolValue(buffer, value).Union());
}

flatbuffers::Offset<views::protocol::Data> bridge_data(ViewBuffer &buffer, const std::string_view value)
{
  return views::protocol::CreateData(
      buffer,
      views::protocol::Value::TextValue,
      views::protocol::CreateTextValue(buffer, buffer.CreateString(value)).Union());
}

flatbuffers::Offset<views::protocol::Data> bridge_data(ViewBuffer &buffer, const Span<double> values)
{
  return views::protocol::CreateData(
      buffer,
      views::protocol::Value::FloatsValue,
      views::protocol::CreateFloatsValue(buffer, buffer.CreateVector(values.data(), values.size()))
          .Union());
}

/** Options of a choice from a table of values and labels. */
OptionOffsets bridge_options(ViewBuffer &buffer, const OptionLabels items)
{
  OptionOffsets options;
  for (const auto &[value, label] : items) {
    options.push_back(views::protocol::CreateOptionDirect(buffer, value, IFACE_(label)));
  }
  return options;
}

/** The tools of the mode, as `native_toolbar` lists them: a choice for each, of the tools
 * of its group, and lines between sets of them. */
void bridge_tools_build(bContext *C, views::ViewBuilder &builder, const NodeId top)
{
  using namespace io::serialize;
#ifdef WITH_PYTHON
  const char *imports[] = {"bpy", "bl_ui", nullptr};
  /* Dragging with Move and the like selects rather than tweaking, see the function. */
  BPY_run_string_eval(
      C, imports, "bl_ui.space_toolsystem_common.native_select_fallback_keep(bpy.context)");
#endif
  const std::shared_ptr<Value> tools = bridge_python_value(
      C, "tools", "bl_ui.space_toolsystem_common.native_toolbar(bpy.context)");
  const NodeId list = builder.add(top, "tools", [](ViewBuffer &buffer, NodeFields & /*fields*/) {
    return views::protocol::CreateGroup(buffer);
  });
  const ArrayValue *array = tools ? tools->as_array_value() : nullptr;
  if (array == nullptr) {
    return;
  }
  int separators = 0;
  for (const std::shared_ptr<Value> &item : array->elements()) {
    const DictionaryValue *tool = item->as_dictionary_value();
    if (tool == nullptr) {
      builder.add(list,
                  "separator:" + std::to_string(separators++),
                  [](ViewBuffer &buffer, NodeFields & /*fields*/) {
                    return views::protocol::CreateSeparator(buffer);
                  });
      continue;
    }
    const std::string_view group = bridge_text(*tool, "group");
    const std::string key = group.empty() ? "tool:" + std::string(bridge_text(*tool, "id")) :
                                            "group:" + std::string(group);
    builder.add(list, key, [&](ViewBuffer &buffer, NodeFields &fields) {
      fields.label = bridge_text(*tool, "title");
      fields.icon = bridge_text(*tool, "icon");
      fields.description = bridge_text(*tool, "description");
      /* A group's tools, with headings without a value between sets of them; a tool alone is a
       * group of one. */
      OptionOffsets options;
      const ArrayValue *children = tool->lookup_array("children");
      if (children == nullptr) {
        options.push_back(views::protocol::CreateOptionDirect(buffer,
                                                              bridge_text(*tool, "id").data(),
                                                              fields.label.data(),
                                                              fields.icon.data(),
                                                              nullptr,
                                                              fields.description.data()));
      }
      else {
        for (const std::shared_ptr<Value> &child : children->elements()) {
          const DictionaryValue *member = child->as_dictionary_value();
          options.push_back(
              member ? views::protocol::CreateOptionDirect(buffer,
                                                           bridge_text(*member, "id").data(),
                                                           bridge_text(*member, "title").data(),
                                                           bridge_text(*member, "icon").data(),
                                                           nullptr,
                                                           bridge_text(*member, "description").data()) :
                       views::protocol::CreateOptionDirect(buffer));
        }
      }
      return views::protocol::CreateChoiceDirect(buffer, bridge_text(*tool, "id").data(), &options);
    });
  }
}

/** The active brush's values, as `bl_ui.native_brush` reads them: `brush:size` and so on. */
void bridge_brush_build(bContext *C, views::ViewBuilder &builder, const NodeId top)
{
  using namespace io::serialize;
  const std::shared_ptr<Value> value = bridge_python_value(
      C, "brush", "bl_ui.native_brush.brush_values(bpy.context)");
  const DictionaryValue *brush = value ? value->as_dictionary_value() : nullptr;
  if (brush == nullptr) {
    return;
  }
  for (const char *name : {"size", "strength", "weight"}) {
    const DictionaryValue *setting = brush->lookup_dict(name);
    if (setting == nullptr) {
      continue;
    }
    builder.add(top, std::string("brush:") + name, [&](ViewBuffer &buffer, NodeFields &fields) {
      const bool pixels = bridge_flag(*setting, "pixels");
      fields.label = bridge_text(*setting, "label");
      return views::protocol::CreateNumberDirect(
          buffer,
          bridge_number(*setting, "value", 0.0),
          pixels,
          STREQ(name, "size") ? views::protocol::NumberKind::Distance :
                                views::protocol::NumberKind::Factor,
          -std::numeric_limits<double>::infinity(),
          std::numeric_limits<double>::infinity(),
          bridge_number(*setting, "min", 0.0),
          bridge_number(*setting, "max", 1.0),
          0.0,
          3,
          true,
          views::protocol::Scale::Linear,
          pixels ? "px" : nullptr,
          bridge_number(*setting, "default", 0.0));
    });
  }
  if (const ArrayValue *color = brush->lookup_array("color")) {
    builder.add(top, "brush:color", [&](ViewBuffer &buffer, NodeFields &fields) {
      fields.label = IFACE_("Color");
      std::vector<double> values;
      for (const std::shared_ptr<Value> &component : color->elements()) {
        values.push_back(component->as_double_value() ? component->as_double_value()->value() :
                         component->as_int_value()     ? double(component->as_int_value()->value()) :
                                                         0.0);
      }
      return views::protocol::CreateColorDirect(buffer, &values);
    });
  }
}

/** Which way brushes stroke, in modes that stroke them: `direction`, a choice of the brush's
 * Direction, its options' icons symbols for them; without options for a brush that has none, and
 * not enabled where there is nothing to choose, as painting colors. `smooth`: holding both
 * directions smooths, in Sculpt Mode. None where the selection is added to or subtracted from
 * instead. */
void bridge_direction_build(bContext *C,
                            const eContextObjectMode mode,
                            views::ViewBuilder &builder,
                            const NodeId top)
{
  const auto hidden = [&](const bool smooth) {
    builder.add(top, "direction", [](ViewBuffer &buffer, NodeFields &fields) {
      fields.enabled = false;
      return views::protocol::CreateChoiceDirect(buffer);
    });
    if (smooth) {
      builder.add(top, "smooth", [](ViewBuffer &buffer, NodeFields & /*fields*/) {
        return bridge_data(buffer, true);
      });
    }
  };
  if (!bridge_mode_strokes(mode)) {
    /* Drawing Grease Pencil strokes, and the tools that never select, such as the 3D Cursor,
     * have nothing to add to or subtract from. */
    const bToolRef *tref = WM_toolsystem_ref_from_context(C);
    const StringRef tool = tref ? StringRef(tref->idname) : StringRef();
    if (mode == CTX_MODE_PAINT_GREASE_PENCIL ||
        ELEM(tool, "builtin.cursor", "builtin.measure") || tool.startswith("builtin.annotate") ||
        tool.startswith("builtin.primitive_"))
    {
      hidden(false);
    }
    return;
  }
  std::optional<PointerRNA> brush_ptr = bridge_brush_direction_ptr(C);
  if (!brush_ptr) {
    const bool colors = ELEM(mode,
                             CTX_MODE_SCULPT,
                             CTX_MODE_PAINT_TEXTURE,
                             CTX_MODE_PAINT_VERTEX,
                             CTX_MODE_VERTEX_GREASE_PENCIL);
    if (colors) {
      hidden(mode == CTX_MODE_SCULPT);
    }
    else {
      /* No brush to stroke with. */
      builder.add(top, "direction", [](ViewBuffer &buffer, NodeFields & /*fields*/) {
        return views::protocol::CreateChoiceDirect(buffer);
      });
    }
    return;
  }
  const Brush *brush = static_cast<const Brush *>(brush_ptr->data);
  builder.add(top, "direction", [&](ViewBuffer &buffer, NodeFields &fields) {
    PropertyRNA *prop = RNA_struct_find_property(&*brush_ptr, "direction");
    fields.label = IFACE_("Direction");
    /* Its two choices, named as the brush names them (such as Inflate and Deflate), with symbols
     * by their untranslated names, one mirroring the other. */
    const EnumPropertyItem *items = nullptr;
    int count = 0;
    bool free = false;
    std::vector<std::pair<std::string, std::string>> choices;
    RNA_property_enum_items_gettexted(C, &*brush_ptr, prop, &items, &count, &free);
    for (int i = 0; i < count && choices.size() < 2; i++) {
      if (items[i].identifier[0] != '\0') {
        choices.emplace_back(items[i].identifier, items[i].name);
      }
    }
    if (free) {
      MEM_delete(items);
    }
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
    /* Sculpting adds to the surface or carves into it, drawn as a bulge out or in. */
    if (mode == CTX_MODE_SCULPT && brush->sculpt_brush_type != SCULPT_BRUSH_TYPE_MASK &&
        STREQ(untranslated[0], "Add") && STREQ(untranslated[1], "Subtract"))
    {
      add_symbol = "bulge.out";
      subtract_symbol = "bulge.in";
    }
    OptionOffsets options;
    for (size_t i = 0; i < choices.size(); i++) {
      options.push_back(views::protocol::CreateOptionDirect(buffer,
                                                            choices[i].first.c_str(),
                                                            choices[i].second.c_str(),
                                                            i == 0 ? add_symbol : subtract_symbol));
    }
    const char *value = nullptr;
    RNA_property_enum_identifier(
        C, &*brush_ptr, prop, RNA_property_enum_get(&*brush_ptr, prop), &value);
    return views::protocol::CreateChoiceDirect(buffer, value, &options);
  });
  if (mode == CTX_MODE_SCULPT) {
    builder.add(top, "smooth", [](ViewBuffer &buffer, NodeFields & /*fields*/) {
      return bridge_data(buffer, true);
    });
  }
}

/** Transform orientation, pivot, snapping, proportional editing and the mode's mirror axes. */
void bridge_transform_build(const Scene *scene,
                            Object *ob,
                            const eContextObjectMode mode,
                            views::ViewBuilder &builder,
                            const NodeId top)
{
  if (!scene || !scene->toolsettings) {
    return;
  }
  /* The modes whose header has Transform Orientation and Pivot Point, as `draw_xform_template`
   * decides: Object Mode, the edit modes, Pose Mode and Weight Paint on a posed armature. The shell
   * shows its row of transform settings by this, not by mode names of its own (R6 E5). */
  if (mode == CTX_MODE_OBJECT || mode <= CTX_MODE_EDIT_POINTCLOUD || mode == CTX_MODE_POSE ||
      (mode == CTX_MODE_PAINT_WEIGHT && ob && BKE_object_pose_armature_get(ob)))
  {
    builder.add(top, "transform_settings", [](ViewBuffer &buffer, NodeFields & /*fields*/) {
      return bridge_data(buffer, true);
    });
  }
  const ToolSettings *settings = scene->toolsettings;
  const auto choice = [&](const char *key,
                          const char *label,
                          const char *value,
                          const OptionLabels items) {
    builder.add(top, key, [&](ViewBuffer &buffer, NodeFields &fields) {
      fields.label = IFACE_(label);
      OptionOffsets options = bridge_options(buffer, items);
      return views::protocol::CreateChoiceDirect(buffer, value, &options);
    });
  };
  static const std::pair<const char *, const char *> orientations[] = {
      {"global", "Global"},
      {"local", "Local"},
      {"normal", "Normal"},
      {"gimbal", "Gimbal"},
      {"view", "View"},
      {"cursor", "Cursor"},
      {"parent", "Parent"},
      {"custom", "Custom"}};
  static const std::pair<const char *, const char *> pivots[] = {
      {"bounds", "Bounding Box Center"},
      {"cursor", "3D Cursor"},
      {"individual", "Individual Origins"},
      {"median", "Median Point"},
      {"active", "Active Element"}};
  static const std::pair<const char *, const char *> snaps[] = {{"off", "Off"},
                                                                {"increment", "Increment"},
                                                                {"grid", "Grid"},
                                                                {"vertex", "Vertex"},
                                                                {"edge", "Edge"},
                                                                {"face", "Face"},
                                                                {"volume", "Volume"},
                                                                {"mixed", "Mixed"}};
  static const std::pair<const char *, const char *> proportionals[] = {
      {"off", "Off"}, {"on", "On"}, {"connected", "Connected"}, {"projected", "Projected"}};
  choice("orientation",
         "Transform Orientation",
         bridge_orientation_id(BKE_scene_orientation_slot_get_index(
             &scene->orientation_slots[SCE_ORIENT_DEFAULT])),
         OptionLabels(orientations, std::size(orientations)));
  choice("pivot", "Pivot Point", bridge_pivot_id(settings->transform_pivot_point), OptionLabels(pivots, std::size(pivots)));
  choice("snap", "Snapping", bridge_snap_id(settings), OptionLabels(snaps, std::size(snaps)));
  choice("proportional",
         "Proportional Editing",
         bridge_proportional_id(settings, mode),
         OptionLabels(proportionals, std::size(proportionals)));
  /* Blender's header draws snapping and proportional editing as a toggle joined to a dropdown:
   * the toggles and the dropdowns' values on their own, so the shell can draw the same. */
  const auto toggle = [&](const char *key, const char *label, const bool on) {
    builder.add(top, key, [&](ViewBuffer &buffer, NodeFields &fields) {
      fields.label = IFACE_(label);
      return views::protocol::CreateToggle(buffer, on);
    });
  };
  static const std::pair<const char *, const char *> snap_elements[] = {{"increment", "Increment"},
                                                                        {"grid", "Absolute Grid"},
                                                                        {"vertex", "Vertex"},
                                                                        {"edge", "Edge"},
                                                                        {"face", "Face"},
                                                                        {"volume", "Volume"},
                                                                        {"mixed", "Mix"}};
  toggle("snap_on", "Snap", (settings->snap_flag & SCE_SNAP) != 0);
  choice("snap_element",
         "Snap To",
         bridge_snap_element_id(settings),
         OptionLabels(snap_elements, std::size(snap_elements)));
  /* As Blender's header: Object Mode, the edit modes but armatures', particles and Grease
   * Pencil sculpting. */
  if (mode == CTX_MODE_OBJECT || mode == CTX_MODE_PARTICLE || mode == CTX_MODE_SCULPT_GREASE_PENCIL ||
      (mode <= CTX_MODE_EDIT_POINTCLOUD && mode != CTX_MODE_EDIT_ARMATURE))
  {
    toggle("proportional_on",
           "Proportional Editing",
           mode == CTX_MODE_OBJECT ? settings->proportional_objects :
                                     (settings->proportional_edit & PROP_EDIT_USE) != 0);
    static const std::pair<const char *, const char *> falloffs[] = {{"SMOOTH", "Smooth"},
                                                                     {"SPHERE", "Sphere"},
                                                                     {"ROOT", "Root"},
                                                                     {"INVERSE_SQUARE", "Inverse Square"},
                                                                     {"SHARP", "Sharp"},
                                                                     {"LINEAR", "Linear"},
                                                                     {"CONSTANT", "Constant"},
                                                                     {"RANDOM", "Random"}};
    const char *falloff = "SMOOTH";
    RNA_enum_identifier(rna_enum_proportional_falloff_items, settings->prop_mode, &falloff);
    choice("proportional_falloff", "Proportional Falloff", falloff, OptionLabels(falloffs, std::size(falloffs)));
  }
  if (mode == CTX_MODE_EDIT_MESH) {
    toggle("automerge", "Auto Merge Vertices", (settings->automerge & AUTO_MERGE) != 0);
  }

  std::optional<BridgeMirror> mirror = bridge_mirror(ob, mode);
  if (!mirror) {
    return;
  }
  /* The axes there are, and which of them mirror, separated by commas. */
  builder.add(top, "mirror", [&](ViewBuffer &buffer, NodeFields &fields) {
    fields.label = IFACE_(mirror->label);
    OptionOffsets options;
    std::string value;
    for (const char *axis = mirror->letters; *axis; axis++) {
      const char name[2] = {*axis, '\0'};
      const char label[2] = {char(toupper(*axis)), '\0'};
      options.push_back(views::protocol::CreateOptionDirect(buffer, name, label));
      if (RNA_boolean_get(&mirror->axes, (std::string(mirror->prefix) + *axis).c_str())) {
        value += value.empty() ? "" : ",";
        value += *axis;
      }
    }
    return views::protocol::CreateChoiceDirect(
        buffer, value.c_str(), &options, views::protocol::ChoiceStyle::Expanded, true);
  });
  if (mirror->topology) {
    builder.add(top, "mirror_topology", [&](ViewBuffer &buffer, NodeFields &fields) {
      fields.label = IFACE_("Topology Mirror");
      return views::protocol::CreateToggle(
          buffer, RNA_boolean_get(&*mirror->topology, "use_mirror_topology"));
    });
  }
}

/** One context action from `bl_ui.native_actions` as a button keyed `action:<id>`: dimmed when it
 * cannot run, tinted when destructive, pressed while what it toggles is on. One that opens a menu
 * or activates a tool names it as its operator's `name`, `WM_OT_call_menu` or
 * `WM_OT_tool_set_by_id`, so an interface can open the menu natively. */
void bridge_action_add(views::ViewBuilder &builder,
                       const NodeId parent,
                       const io::serialize::DictionaryValue &action)
{
  const std::shared_ptr<io::serialize::Value> *enabled = action.lookup("enabled");
  builder.add(parent,
              "action:" + std::string(bridge_text(action, "action")),
              [&](ViewBuffer &buffer, NodeFields &fields) {
                fields.label = bridge_text(action, "title");
                fields.icon = bridge_text(action, "icon");
                /* Enabled unless it says otherwise, as the strip's items always can run. */
                fields.enabled = enabled == nullptr || bridge_flag(action, "enabled");
                /* A dimmed action says why, as a tooltip would over it. */
                fields.description = bridge_text(action, "why");
                const StringRef menu = bridge_text(action, "menu");
                const StringRef tool = bridge_text(action, "tool");
                const StringRef name = !menu.is_empty() ? menu : tool;
                flatbuffers::Offset<flatbuffers::Vector<flatbuffers::Offset<views::protocol::Param>>>
                    params;
                if (!name.is_empty()) {
                  const flatbuffers::Offset<views::protocol::Param> param =
                      views::protocol::CreateParamDirect(
                          buffer,
                          "name",
                          views::protocol::Value::TextValue,
                          views::protocol::CreateTextValueDirect(buffer, std::string(name).c_str())
                              .Union());
                  params = buffer.CreateVector(&param, 1);
                }
                return views::protocol::CreateButton(
                    buffer,
                    bridge_flag(action, "destructive") ? views::protocol::ButtonStyle::Destructive :
                                                         views::protocol::ButtonStyle::Normal,
                    buffer.CreateString(std::string(bridge_text(action, "operator"))),
                    params,
                    0,
                    bridge_flag(action, "selected"));
              });
}

/** Quick actions for the mode, tool and selection, as `bl_ui.native_actions` chooses them; or
 * the axes a move, turn or scale running is constrained to. */
/** The waiting operation's name and what Blender says of it, which the bar shows above it. */
static std::string bridge_modal_hint;

/**
 * The modal bar, in place of the actions while an operation waits: its axes for a transform,
 * Confirm and Cancel, a number pad, and every key of its modal key map as a button, named as
 * the key map names it, so nothing it listens for needs a keyboard.
 */
static void bridge_modal_bar_build(
    bContext *C, wmOperator *op, const bool axes_shown, views::ViewBuilder &builder, const NodeId row)
{
  if (axes_shown) {
    int axes;
    blender::ed::transform::modal_constraint_get(op, axes);
    for (int axis = 0; axis < 3; axis++) {
      const char *name = axis == 0 ? "X" : axis == 1 ? "Y" : "Z";
      builder.add(row, std::string("axis:") + name, [&](ViewBuffer &buffer, NodeFields &fields) {
        fields.label = name;
        return views::protocol::CreateButtonDirect(buffer,
                                                   views::protocol::ButtonStyle::Normal,
                                                   nullptr,
                                                   nullptr,
                                                   name,
                                                   (axes & (1 << axis)) != 0);
      });
    }
  }
  /* A touch has neither Enter nor Escape: the bar offers them, or nothing could end it. */
  for (const auto &[key, label, icon] : {std::tuple{"modal:confirm", "Confirm", "CHECKMARK"},
                                         std::tuple{"modal:cancel", "Cancel", "CANCEL"}})
  {
    builder.add(row, key, [&](ViewBuffer &buffer, NodeFields &fields) {
      fields.label = IFACE_(label);
      fields.icon = icon;
      return views::protocol::CreateButtonDirect(buffer,
                                                 views::protocol::ButtonStyle::Normal,
                                                 nullptr,
                                                 nullptr,
                                                 STREQ(key, "modal:confirm") ? "RET" : "ESC",
                                                 false);
    });
  }
  /* Typing a value, as "G X 2 Enter": the shell's number pad sends the digits. */
  builder.add(row, "modal:pad", [&](ViewBuffer &buffer, NodeFields &fields) {
    fields.label = "123";
    return views::protocol::CreateButtonDirect(
        buffer, views::protocol::ButtonStyle::Normal, nullptr, nullptr, nullptr, false);
  });

  /* Its own keys, from its modal key map as the person has it. */
  /* Only what Blender writes in the header while it runs, such as a move's values: the
   * operation's name alone says nothing the person does not know, and covered controls. */
  std::string hint;
  wmKeyMap *keymap = op->type->modalkeymap ?
                         WM_keymap_active(CTX_wm_manager(C), op->type->modalkeymap) :
                         nullptr;
  const EnumPropertyItem *items = keymap ? static_cast<const EnumPropertyItem *>(keymap->modal_items) :
                                           nullptr;
  if (keymap && items) {
    Set<int> shown;
    Set<std::string> keys;
    for (wmKeyMapItem &kmi : keymap->items) {
      if ((kmi.flag & KMI_INACTIVE) || kmi.propvalue == 0 || shown.contains(kmi.propvalue)) {
        continue;
      }
      const int type = kmi.type;
      if (ISMOUSE_MOTION(type) || ISMOUSE_BUTTON(type) || ISNDOF(type) || ISTIMER(type) ||
          ELEM(type, EVT_RETKEY, EVT_PADENTER, EVT_ESCKEY))
      {
        continue;
      }
      /* Held while dragging, as the knife's Shift (midpoints) and Ctrl (no snapping), or taking
       * effect on release: a button presses and releases at once, so it would do nothing. */
      if (ISKEYMODIFIER(type) || kmi.val == KM_RELEASE) {
        continue;
      }
      if (keymap->poll_modal_item && !keymap->poll_modal_item(op, kmi.propvalue)) {
        continue;
      }
      const char *name = nullptr;
      for (const EnumPropertyItem *item = items; item->identifier; item++) {
        if (item->value == kmi.propvalue && item->name) {
          name = item->name;
          break;
        }
      }
      const char *event_id = nullptr;
      if (name == nullptr || !RNA_enum_identifier(rna_enum_event_type_items, type, &event_id) ||
          STREQ(name, "Confirm") || STREQ(name, "Cancel"))
      {
        continue;
      }
      shown.add(kmi.propvalue);
      std::string key;
      if (kmi.shift == KM_MOD_HELD) {
        key += "shift+";
      }
      if (kmi.ctrl == KM_MOD_HELD) {
        key += "ctrl+";
      }
      if (kmi.alt == KM_MOD_HELD) {
        key += "alt+";
      }
      if (kmi.oskey == KM_MOD_HELD) {
        key += "oskey+";
      }
      key += event_id;
      /* One button a key: a view's keys are unique. */
      if (!keys.add(key)) {
        continue;
      }
      const std::string label = CTX_IFACE_(BLT_I18NCONTEXT_ID_WINDOWMANAGER, name);
      builder.add(row, "modalkey:" + key, [&](ViewBuffer &buffer, NodeFields &fields) {
        fields.label = label;
        return views::protocol::CreateButtonDirect(
            buffer, views::protocol::ButtonStyle::Normal, nullptr, nullptr, nullptr, false);
      });
    }
  }
  /* What Blender writes in the header while it runs, such as transform's values. */
  if (ScrArea *area = CTX_wm_area(C)) {
    for (ARegion &region : area->regionbase) {
      if (ELEM(region.regiontype, RGN_TYPE_HEADER, RGN_TYPE_TOOL_HEADER) && region.runtime->headerstr &&
          region.runtime->headerstr[0])
      {
        hint = region.runtime->headerstr;
        break;
      }
    }
  }
  bridge_modal_hint = hint;
}

void bridge_actions_build(bContext *C, const char *tool, views::ViewBuilder &builder, const NodeId top)
{
  bridge_modal_hint.clear();
  using namespace io::serialize;
  const NodeId row = builder.add(top, "actions", [](ViewBuffer &buffer, NodeFields & /*fields*/) {
    return views::protocol::CreateGroup(buffer, views::protocol::Layout::Row);
  });
  wmWindow *win = CTX_wm_window(C);
  wmOperator *constraint_op = bridge_constraint_operator(win);
  wmOperator *waiting_op = constraint_op ? constraint_op : bridge_waiting_operator(win);
  if (waiting_op) {
    bridge_modal_bar_build(C, waiting_op, constraint_op != nullptr, builder, row);
    return;
  }
  if (false) {
    wmOperator *op = constraint_op;
    int axes;
    blender::ed::transform::modal_constraint_get(op, axes);
    for (int axis = 0; axis < 3; axis++) {
      const char *name = axis == 0 ? "X" : axis == 1 ? "Y" : "Z";
      builder.add(row, std::string("axis:") + name, [&](ViewBuffer &buffer, NodeFields &fields) {
        fields.label = name;
        return views::protocol::CreateButtonDirect(buffer,
                                                   views::protocol::ButtonStyle::Normal,
                                                   nullptr,
                                                   nullptr,
                                                   name,
                                                   (axes & (1 << axis)) != 0);
      });
    }
    /* A move running from a menu or a key waits for a click, Enter or Escape, as on the desktop:
     * a touch has neither key, so the bar offers them, or nothing could end it. */
    for (const auto &[key, label, icon] : {std::tuple{"modal:confirm", "Confirm", "CHECKMARK"},
                                           std::tuple{"modal:cancel", "Cancel", "CANCEL"}})
    {
      builder.add(row, key, [&](ViewBuffer &buffer, NodeFields &fields) {
        fields.label = IFACE_(label);
        fields.icon = icon;
        return views::protocol::CreateButtonDirect(buffer,
                                                   views::protocol::ButtonStyle::Normal,
                                                   nullptr,
                                                   nullptr,
                                                   STREQ(key, "modal:confirm") ? "RET" : "ESC",
                                                   false);
      });
    }
    return;
  }
  const std::string expression = "bl_ui.native_actions.actions(bpy.context, \"" +
                                 bridge_json_escape(tool ? tool : "") + "\")";
  const std::shared_ptr<Value> actions = bridge_python_value(C, "actions", expression.c_str());
  const ArrayValue *array = actions ? actions->as_array_value() : nullptr;
  if (array == nullptr) {
    return;
  }
  for (const std::shared_ptr<Value> &item : array->elements()) {
    if (const DictionaryValue *action = item->as_dictionary_value()) {
      bridge_action_add(builder, row, *action);
    }
  }
}

/** The surfaces of `bl_ui.native_actions` beyond the strip, which the `actions` view shows. */
constexpr const char *bridge_action_surfaces[] = {"palette", "long_press", "radial"};

/** The `actions` view: one surface of the context actions, by its `surface` parameter, built only
 * while the interface shows it. The palette is a group per action group, in order; the long-press
 * menu is the groups `section:fixed` and `section:actions` and, where the mode has a context menu, a `more`
 * button that opens it; the radial is its slots in order. Invoking `action:<id>` runs one. */
void bridge_actions_view_build(bContext *C,
                               const views::Params &params,
                               views::ViewData * /*data*/,
                               views::ViewBuilder &builder)
{
  using namespace io::serialize;
  const std::string_view surface = params.text("surface").value_or("palette");
  const NodeId top = builder.top("actions", [&](ViewBuffer &buffer, NodeFields &fields) {
    fields.label = surface;
    return views::protocol::CreateGroup(buffer);
  });
  if (std::find_if(std::begin(bridge_action_surfaces), std::end(bridge_action_surfaces), [&](const char *name) {
        return surface == name;
      }) == std::end(bridge_action_surfaces))
  {
    return;
  }
  const BridgeContextStore context_store = bridge_context_push_view3d(C);
  if (CTX_wm_area(C) == nullptr) {
    bridge_context_pop(C, context_store);
    return;
  }
  const bToolRef *tool = bridge_active_tool(C);
  const std::string expression = "bl_ui.native_actions." + std::string(surface) + "(bpy.context, \"" +
                                 bridge_json_escape(tool ? tool->idname : "") + "\")";
  const std::shared_ptr<Value> value = bridge_python_value(C, "actions", expression.c_str());
  bridge_context_pop(C, context_store);
  if (!value) {
    return;
  }
  const auto group_add = [&](const std::string &key, const StringRef label, const ArrayValue &items) {
    const NodeId group = builder.add(top, key, [&](ViewBuffer &buffer, NodeFields &fields) {
      fields.label = label;
      return views::protocol::CreateGroup(buffer, views::protocol::Layout::Column);
    });
    for (const std::shared_ptr<Value> &item : items.elements()) {
      if (const DictionaryValue *action = item->as_dictionary_value()) {
        bridge_action_add(builder, group, *action);
      }
    }
  };
  if (const ArrayValue *array = value->as_array_value()) {
    for (const std::shared_ptr<Value> &item : array->elements()) {
      const DictionaryValue *entry = item->as_dictionary_value();
      if (entry == nullptr) {
        continue;
      }
      const std::shared_ptr<Value> *items = entry->lookup("items");
      const ArrayValue *items_array = items ? (*items)->as_array_value() : nullptr;
      if (items_array) {
        /* A palette group. */
        const StringRef name = bridge_text(*entry, "group");
        group_add("group:" + std::string(name), name, *items_array);
      }
      else {
        /* A radial slot. */
        bridge_action_add(builder, top, *entry);
      }
    }
    return;
  }
  if (const DictionaryValue *menu = value->as_dictionary_value()) {
    for (const char *section : {"fixed", "actions"}) {
      const std::shared_ptr<Value> *items = menu->lookup(section);
      if (const ArrayValue *items_array = items ? (*items)->as_array_value() : nullptr) {
        /* Not keyed by the bare name: `actions` is the view's top node. */
        group_add("section:" + std::string(section), section, *items_array);
      }
    }
    const StringRef more = bridge_text(*menu, "more");
    if (!more.is_empty()) {
      builder.add(top, "more", [&](ViewBuffer &buffer, NodeFields &fields) {
        fields.label = IFACE_("More...");
        const flatbuffers::Offset<views::protocol::Param> param = views::protocol::CreateParamDirect(
            buffer,
            "name",
            views::protocol::Value::TextValue,
            views::protocol::CreateTextValueDirect(buffer, std::string(more).c_str()).Union());
        return views::protocol::CreateButton(buffer,
                                             views::protocol::ButtonStyle::Normal,
                                             buffer.CreateString("WM_OT_call_menu"),
                                             buffer.CreateVector(&param, 1));
      });
    }
  }
}

views::CommandResult bridge_actions_view_command(bContext *C,
                                                 const views::Params & /*params*/,
                                                 views::ViewData * /*data*/,
                                                 const views::protocol::Command &command,
                                                 std::string &r_error)
{
  const std::string_view target = command.target()->string_view();
  if (command.op() != views::protocol::Op::Invoke || !StringRef(target).startswith("action:")) {
    /* `more` and `action:rename` are the interface's own: it opens the menu, or asks for the
     * name, itself. */
    r_error = "Actions are only invoked";
    return views::CommandResult::Failed;
  }
  bridge_setting_execute(C, BridgeSettingCommand{"native_action", std::string(target.substr(7))});
  return views::CommandResult::Done;
}

/** The text object being typed into: `text`, which `Add` types into and `Remove` deletes from, and
 * its style where the cursor is, `text:bold` and so on, `text:align` and `text:font`, its file. */
void bridge_text_object_build(bContext *C, views::ViewBuilder &builder, const NodeId top)
{
  Curve *curve = bridge_text_object_edited(C);
  if (curve == nullptr) {
    return;
  }
  builder.add(top, "text", [&](ViewBuffer &buffer, NodeFields &fields) {
    fields.label = curve->id.name + 2;
    return views::protocol::CreateTextFieldDirect(buffer, "", true);
  });
  int selection_start, selection_end;
  const short flag = BKE_vfont_select_get(curve, &selection_start, &selection_end) ?
                         curve->editfont->textbufinfo[selection_start].flag :
                         curve->curinfo.flag;
  for (const auto &[key, bit, label] : {std::tuple{"text:bold", CU_CHINFO_BOLD, "Bold"},
                                        std::tuple{"text:italic", CU_CHINFO_ITALIC, "Italic"},
                                        std::tuple{"text:underline", CU_CHINFO_UNDERLINE, "Underline"}})
  {
    builder.add(top, key, [&](ViewBuffer &buffer, NodeFields &fields) {
      fields.label = IFACE_(label);
      return views::protocol::CreateToggle(buffer, (flag & bit) != 0);
    });
  }
  PointerRNA curve_ptr = RNA_id_pointer_create(&curve->id);
  PropertyRNA *align_prop = RNA_struct_find_property(&curve_ptr, "align_x");
  const char *align = "";
  RNA_property_enum_identifier(
      C, &curve_ptr, align_prop, RNA_property_enum_get(&curve_ptr, align_prop), &align);
  builder.add(top, "text:align", [&](ViewBuffer &buffer, NodeFields &fields) {
    fields.label = IFACE_("Alignment");
    return views::protocol::CreateChoiceDirect(buffer, align);
  });
  builder.add(top, "text:font", [&](ViewBuffer &buffer, NodeFields &fields) {
    fields.label = IFACE_("Font");
    return bridge_data(buffer, std::string_view(curve->vfont ? curve->vfont->filepath : ""));
  });
}

/** A command to the text object, being typed into or not, see #bridge_text_object_build: as
 * #bridge_text_object_edit takes it. Also its spacing and size, `text:size` and so on, and its
 * vertical alignment, `text:align_y`, which Properties shows. */
std::optional<std::string> bridge_text_object_command(const views::protocol::Command &command)
{
  const std::string_view target = command.target()->string_view();
  const views::protocol::TextValue *text_value = command.value_as_TextValue();
  const std::string text = text_value && text_value->value() ? text_value->value()->str() : "";
  if (target == "text") {
    return command.op() == views::protocol::Op::Add    ? std::optional("insert:" + text) :
           command.op() == views::protocol::Op::Remove ? std::optional<std::string>("delete") :
                                                         std::nullopt;
  }
  if (command.op() != views::protocol::Op::Set || !StringRef(target).startswith("text:")) {
    return std::nullopt;
  }
  const std::string name(target.substr(5));
  if (ELEM(name, "bold", "italic", "underline", "small_caps")) {
    const views::protocol::BoolValue *on = command.value_as_BoolValue();
    std::string style = name;
    std::transform(style.begin(), style.end(), style.begin(), ::toupper);
    return "style:" + style + ":" + (on && on->value() ? "1" : "0");
  }
  if (ELEM(name, "align", "align_y")) {
    return name + ":" + text;
  }
  if (name == "font") {
    const views::protocol::TextsValue *lines = command.value_as_TextsValue();
    std::string joined;
    if (lines && lines->value()) {
      for (const flatbuffers::String *line : *lines->value()) {
        joined += (joined.empty() ? "" : "\n") + line->str();
      }
    }
    return "font:" + joined;
  }
  if (const views::protocol::FloatValue *number = command.value_as_FloatValue()) {
    return "value:" + name + ":" + bridge_json_number(number->value());
  }
  return std::nullopt;
}

void bridge_toolbar_view_build(bContext *C,
                               const views::Params & /*params*/,
                               views::ViewData * /*data*/,
                               views::ViewBuilder &builder)
{
#if defined(WITH_APPLE_CROSSPLATFORM) && APPLE_TARGET_IOS
  WM_apple_ios_finger_tweak_mode_update(C);
#endif
  const bool has_view3d = CTX_wm_window(C) && CTX_wm_area(C) && CTX_wm_region(C);
  Scene *scene = has_view3d ? CTX_data_scene(C) : nullptr;
  ToolSettings *tool_settings = scene ? scene->toolsettings : nullptr;
  const eContextObjectMode mode = has_view3d ? CTX_data_mode_enum(C) : CTX_MODE_OBJECT;
  const char *mode_string = has_view3d ? CTX_data_mode_string(C) : nullptr;
  const View3D *view3d = has_view3d ? CTX_wm_view3d(C) : nullptr;
  Object *active = has_view3d ? CTX_data_active_object(C) : nullptr;

  const NodeId top = builder.top("toolbar", [&](ViewBuffer &buffer, NodeFields &fields) {
    /* Blender's context mode, such as `objectmode` or `edit_mesh`. */
    fields.label = mode_string ? mode_string : "objectmode";
    return views::protocol::CreateGroup(buffer);
  });
  const auto data = [&](const char *key, const auto &value) {
    builder.add(top, key, [&](ViewBuffer &buffer, NodeFields & /*fields*/) {
      return bridge_data(buffer, value);
    });
  };
  {
    const std::string notices = bridge_notices_json();
    data("notices", std::string_view(notices));
    data("reveal", std::string_view(bridge_reveal_json));
  }

  if (has_view3d) {
    /* The modes the active object has, as Blender's header lists them. */
    builder.add(top, "mode", [&](ViewBuffer &buffer, NodeFields &fields) {
      fields.label = IFACE_("Mode");
      const char *current = "OBJECT";
      if (active) {
        RNA_enum_identifier(rna_enum_object_mode_items, active->mode, &current);
      }
      OptionOffsets options;
      for (const EnumPropertyItem *item = rna_enum_object_mode_items; item->identifier; item++) {
        if (!item->identifier[0] ||
            !(active ? ed::object::mode_compat_test(active, eObjectMode(item->value)) :
                       item->value == OB_MODE_OBJECT))
        {
          continue;
        }
        const char *icon = nullptr;
        RNA_enum_identifier(rna_enum_icon_items, item->icon, &icon);
        options.push_back(views::protocol::CreateOptionDirect(
            buffer, item->identifier, IFACE_(item->name), icon));
      }
      return views::protocol::CreateChoiceDirect(buffer, current, &options);
    });
    if (mode == CTX_MODE_EDIT_MESH) {
      builder.add(top, "select_mode", [&](ViewBuffer &buffer, NodeFields &fields) {
        fields.label = IFACE_("Select Mode");
        static const std::pair<const char *, const char *> items[] = {
            {"VERT", "Vertex"}, {"EDGE", "Edge"}, {"FACE", "Face"}};
        OptionOffsets options = bridge_options(buffer, OptionLabels(items, std::size(items)));
        return views::protocol::CreateChoiceDirect(
            buffer,
            bridge_mesh_select_mode_string(tool_settings).c_str(),
            &options,
            views::protocol::ChoiceStyle::Expanded);
      });
    }
    /* What Rename Active renames: the active bone in an armature's modes, otherwise the active
     * object. */
    std::string active_name = active ? active->id.name + 2 : "";
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
    builder.add(top, "active_name", [&](ViewBuffer &buffer, NodeFields &fields) {
      fields.label = IFACE_("Name");
      fields.enabled = active != nullptr;
      return views::protocol::CreateTextFieldDirect(buffer, active_name.c_str());
    });
  }
  if (view3d) {
    static const char *shadings[] = {"wireframe", "solid", "material", "rendered"};
    const int shading = ELEM(view3d->shading.type, OB_WIRE, OB_MATERIAL, OB_RENDER) ?
                            (view3d->shading.type == OB_WIRE     ? 0 :
                             view3d->shading.type == OB_MATERIAL ? 2 :
                                                                   3) :
                            1;
    data("shading", std::string_view(shadings[shading]));
  }

  bToolRef *active_tool = has_view3d ? bridge_active_tool(C) : nullptr;
  const char *active_tool_id = active_tool ? active_tool->idname : "builtin.select_box";
  if (has_view3d) {
    bridge_tools_build(C, builder, top);
  }
  data("active_tool", std::string_view(active_tool_id));

  for (const char *name : {"undo", "redo"}) {
    builder.add(top, name, [&](ViewBuffer &buffer, NodeFields &fields) {
      const char *op_name = STREQ(name, "undo") ? "ED_OT_undo" : "ED_OT_redo";
      fields.label = STREQ(name, "undo") ? IFACE_("Undo") : IFACE_("Redo");
      fields.enabled = has_view3d && bridge_undo_available(C, op_name);
      return views::protocol::CreateButtonDirect(
          buffer, views::protocol::ButtonStyle::Normal, op_name);
    });
  }
  /* Repeat Last, as Shift+R: the last operator kept for redo, named, while it can run again. */
  wmOperator *repeatable = bridge_repeatable_operator(C);
  /* The label is a view of this string, which outlives the node's building. */
  const std::string repeat_label = repeatable ?
                                       std::string(IFACE_("Repeat")) + " " +
                                           std::string(WM_operatortype_name(repeatable->type,
                                                                            repeatable->ptr)) :
                                       std::string(IFACE_("Repeat Last"));
  builder.add(top, "repeat", [&](ViewBuffer &buffer, NodeFields &fields) {
    fields.label = repeat_label;
    fields.enabled = has_view3d && repeatable != nullptr;
    return views::protocol::CreateButtonDirect(
        buffer, views::protocol::ButtonStyle::Normal, "SCREEN_OT_repeat_last");
  });
  /* Which undo step is active: it moves with every change an operator makes, and with undo and
   * redo, once per action rather than during one. Menus are built from the scene, so the
   * interface asks for them again when this changes, and only then. */
  std::string menu_state;
  if (const wmWindowManager *wm = CTX_wm_manager(C); wm && wm->runtime->undo_stack) {
    const UndoStack *stack = wm->runtime->undo_stack;
    menu_state = std::to_string(uintptr_t(stack->step_active)) + ":" +
                 std::to_string(BLI_listbase_count(&stack->steps));
  }
  data("menu_state", std::string_view(menu_state));

  bridge_transform_build(scene, active, mode, builder, top);
  if (has_view3d) {
    bridge_direction_build(C, mode, builder, top);
    bridge_brush_build(C, builder, top);
  }
  /* Moving, turning or scaling: the held buttons are Snap and Precision then. */
  data("transforming", bridge_constraint_operator(CTX_wm_window(C)) != nullptr);
  bool drag_done = false;
  std::string drag_hint;
  if (bridge_waiting_hint(CTX_wm_window(C), &drag_done, drag_hint)) {
    /* A command waiting for a click or a drag in the view, and whether it ends with Done. */
    builder.add(top, "drag_hint", [&](ViewBuffer &buffer, NodeFields &fields) {
      fields.label = drag_hint;
      return bridge_data(buffer, drag_done);
    });
  }
  if (has_view3d) {
    bridge_actions_build(C, active_tool_id, builder, top);
    bridge_text_object_build(C, builder, top);
    if (!bridge_modal_hint.empty()) {
      data("modal_hint", std::string_view(bridge_modal_hint));
    }
  }

  if (has_view3d) {
    const wmWindow *win = CTX_wm_window(C);
    ARegion *region = CTX_wm_region(C);
    const float height = WM_window_native_pixel_y(win);
    /* The navigation gizmo's parts where `view3d_gizmo_navigate.cc` placed them, the one source
     * for where they are (ROUND5 12D, decision 79), in window pixels from the top left, which the
     * shell divides by its scale. None before the view is first drawn, or while the gizmo is
     * hidden: the shell then keeps clear of nothing and puts no hotspot over it. */
    NavigationGizmoPlace parts[NAVIGATION_GIZMO_PARTS_MAX];
    const int count = height > 0 ? ED_view3d_navigate_gizmo_parts(CTX_wm_area(C), region, parts) :
                                   0;
    Vector<double> places;
    double footprint[4] = {DBL_MAX, DBL_MAX, -DBL_MAX, -DBL_MAX};
    for (int i = 0; i < count; i++) {
      const double x = region->winrct.xmin + parts[i].center[0];
      const double y = height - (region->winrct.ymin + parts[i].center[1]);
      const double r = parts[i].radius;
      if (parts[i].part == NavigationGizmoPart::Axes) {
        /* Its centre and radius, for the hotspot over it. */
        const double gizmo[3] = {x, y, r};
        data("navigation_gizmo", Span<double>(gizmo, 3));
      }
      places.extend({double(parts[i].part), x, y, r});
      /* All the gizmo takes, its buttons too where they show, which the native controls keep
       * clear of: left, top, right and bottom. */
      footprint[0] = std::min(footprint[0], x - r);
      footprint[1] = std::min(footprint[1], y - r);
      footprint[2] = std::max(footprint[2], x + r);
      footprint[3] = std::max(footprint[3], y + r);
    }
    if (count > 0) {
      /* Each part, as what it does (#NavigationGizmoPart), its centre and its radius: for the
       * checks, which hold the footprint to them and press the buttons. */
      data("navigation_parts", places.as_span());
      data("navigation_footprint", Span<double>(footprint, 4));
    }
  }
  if (view3d && scene) {
    /* The color the viewport is cleared to, in display space, for chrome that should blend in
     * with it, such as the Mac window's toolbar. */
    float background[3];
    ED_view3d_background_color_get(scene, view3d, background);
    if (view3d->shading.background_type == V3D_SHADING_BACKGROUND_WORLD && scene->world) {
      linearrgb_to_srgb_v3_v3(background, background);
    }
    const double color[3] = {background[0], background[1], background[2]};
    data("viewport_background", Span<double>(color, 3));
  }
  if (has_view3d) {
    /* The viewport's options, see `bl_ui.native_render.viewport_options`. */
    using namespace io::serialize;
    const std::shared_ptr<Value> viewport = bridge_python_value(
        C, "viewport", "bl_ui.native_render.viewport_options(bpy.context)");
    if (const DictionaryValue *options = viewport ? viewport->as_dictionary_value() : nullptr) {
      for (const DictionaryValue::Item &item : options->elements()) {
        const BooleanValue *value = item.second->as_boolean_value();
        if (value == nullptr) {
          continue;
        }
        builder.add(top, "viewport:" + item.first, [&](ViewBuffer &buffer, NodeFields & /*fields*/) {
          return views::protocol::CreateToggle(buffer, value->value());
        });
      }
    }
  }
}

/** Commands to the toolbar's nodes, as the settings of the same names did. */
views::CommandResult bridge_toolbar_view_command(bContext *C,
                                                 const views::Params & /*params*/,
                                                 views::ViewData * /*data*/,
                                                 const views::protocol::Command &command,
                                                 std::string &r_error)
{
  const std::string_view target = command.target()->string_view();
  const views::protocol::TextValue *text_value = command.value_as_TextValue();
  const std::string text = text_value && text_value->value() ? text_value->value()->str() : "";
  const auto setting = [&](const char *name, const std::string &value) {
    bridge_setting_execute(C, BridgeSettingCommand{name, value});
    return views::CommandResult::Done;
  };
  const bool set = command.op() == views::protocol::Op::Set;
  const bool invoke = command.op() == views::protocol::Op::Invoke;
  if (set && target == "mode") {
    bridge_mode_set(C, text.c_str());
    return views::CommandResult::Done;
  }
  if (set && target == "tools") {
    /* A tool, by its id. */
    WM_toolsystem_ref_set_by_id(C, text.c_str());
    return views::CommandResult::Done;
  }
  if (set && target == "select_mode") {
    bridge_mesh_select_mode_set(C, text);
    return views::CommandResult::Done;
  }
  if (set && target == "active_name") {
    return setting("rename_active", "\"" + bridge_json_escape(text) + "\"");
  }
  if (set && ELEM(target,
                  "orientation",
                  "pivot",
                  "snap",
                  "proportional",
                  "snap_on",
                  "snap_element",
                  "proportional_on",
                  "proportional_falloff",
                  "automerge"))
  {
    return setting(std::string(target).c_str(), text);
  }
  if (set && target == "mirror") {
    /* The axes to mirror on, each toggled that is not as asked. */
    std::optional<BridgeMirror> mirror = bridge_mirror(CTX_data_active_object(C),
                                                       CTX_data_mode_enum(C));
    if (!mirror) {
      r_error = "Nothing to mirror";
      return views::CommandResult::Failed;
    }
    for (const char *axis = mirror->letters; *axis; axis++) {
      const std::string name = mirror->prefix + std::string(1, *axis);
      const bool wanted = text.find(*axis) != std::string::npos;
      if (RNA_boolean_get(&mirror->axes, name.c_str()) != wanted) {
        bridge_rna_undo_push(C, bridge_rna_boolean_set(C, mirror->axes, name.c_str(), wanted));
      }
    }
    return views::CommandResult::Done;
  }
  if (set && target == "mirror_topology") {
    return setting("mirror_topology", "");
  }
  if (set && target == "direction") {
    std::optional<PointerRNA> brush_ptr = bridge_brush_direction_ptr(C);
    PropertyRNA *prop = brush_ptr ? RNA_struct_find_property(&*brush_ptr, "direction") : nullptr;
    int value = 0;
    if (prop == nullptr || !RNA_property_enum_value(C, &*brush_ptr, prop, text.c_str(), &value)) {
      r_error = "No such direction";
      return views::CommandResult::Failed;
    }
    RNA_property_enum_set(&*brush_ptr, prop, value);
    RNA_property_update(C, &*brush_ptr, prop);
    return views::CommandResult::Done;
  }
  if (set && StringRef(target).startswith("brush:")) {
    /* A drag sends many values, and one undo step as it ends. */
    std::string value;
    if (const views::protocol::FloatsValue *floats = command.value_as_FloatsValue()) {
      value = "[";
      for (const double component : *floats->value()) {
        value += (value.size() > 1 ? "," : "") + bridge_json_number(component);
      }
      value += "]";
    }
    else if (const views::protocol::FloatValue *number = command.value_as_FloatValue()) {
      value = bridge_json_number(number->value());
    }
    const bool commit = ELEM(command.phase(), views::protocol::Phase::Once, views::protocol::Phase::End);
    return setting(commit ? "native_brush_commit" : "native_brush",
                   "\"" + bridge_json_escape(std::string(target.substr(6))) + "\", " + value);
  }
  if (set && StringRef(target).startswith("viewport:")) {
    return setting("viewport_toggle", std::string(target.substr(9)));
  }
  if (invoke && StringRef(target).startswith("select_menu:")) {
    /* The long-press menu's Select Menu… (ROUND6 TOUCH-4, finding E2): the objects or bones under
     * the point, as Alt-click lists them on the desktop. The point is given as fractions of the
     * window, from the top left. */
    float fraction[2];
    if (sscanf(std::string(target.substr(12)).c_str(), "%f,%f", &fraction[0], &fraction[1]) != 2) {
      r_error = "Not a point";
      return views::CommandResult::Failed;
    }
    wmWindow *win = CTX_wm_window(C);
    const BridgeContextStore context_store = bridge_context_push_view3d(C);
    ARegion *region = CTX_wm_region(C);
    wmOperatorType *ot = WM_operatortype_find("VIEW3D_OT_select", false);
    if (win == nullptr || region == nullptr || ot == nullptr) {
      bridge_context_pop(C, context_store);
      r_error = "No 3D View";
      return views::CommandResult::Failed;
    }
    const int location[2] = {
        int(fraction[0] * WM_window_native_pixel_x(win)) - region->winrct.xmin,
        int((1.0f - fraction[1]) * WM_window_native_pixel_y(win)) - region->winrct.ymin};
    PointerRNA props = WM_operator_properties_create_ptr(ot);
    RNA_boolean_set(&props, "enumerate", true);
    RNA_int_set_array(&props, "location", location);
    WM_operator_name_call_ptr(C, ot, wm::OpCallContext::ExecRegionWin, &props, nullptr);
    WM_operator_properties_free(&props);
    bridge_context_pop(C, context_store);
    return views::CommandResult::Done;
  }
  if (invoke && target == "repeat") {
    if (bridge_repeatable_operator(C) == nullptr) {
      r_error = "Nothing to repeat";
      return views::CommandResult::Failed;
    }
    return views::operator_run(C, "SCREEN_OT_repeat_last", nullptr, r_error) ?
               views::CommandResult::Done :
               views::CommandResult::Failed;
  }
  if (invoke && ELEM(target, "undo", "redo")) {
    const char *op_name = target == "undo" ? "ED_OT_undo" : "ED_OT_redo";
    if (std::string refusal = WM_native_ui_undo_refusal(C); !refusal.empty()) {
      r_error = refusal;
      return views::CommandResult::Failed;
    }
    if (!bridge_undo_available(C, op_name)) {
      r_error = "Nothing to " + std::string(target);
      return views::CommandResult::Failed;
    }
    return views::operator_run(C, op_name, nullptr, r_error) ? views::CommandResult::Done :
                                                               views::CommandResult::Failed;
  }
  if (invoke && StringRef(target).startswith("action:")) {
    return setting("native_action", std::string(target.substr(7)));
  }
  if (invoke && StringRef(target).startswith("axis:")) {
    return setting("constraint_axis", std::string(target.substr(5)));
  }
  if (invoke && StringRef(target).startswith("modalkey:")) {
    return setting("modal_key", std::string(target.substr(9)));
  }
  if (std::optional<std::string> edit = bridge_text_object_command(command)) {
    /* Typed text: each line inserted, and a line break between. */
    if (StringRef(*edit).startswith("insert:")) {
      const std::string typed = edit->substr(7);
      size_t start = 0;
      while (true) {
        const size_t end = typed.find('\n', start);
        const std::string line = typed.substr(start, end - start);
        if (!line.empty()) {
          bridge_text_object_edit(C, "insert:" + line);
        }
        if (end == std::string::npos) {
          break;
        }
        bridge_text_object_edit(C, "line_break");
        start = end + 1;
      }
    }
    else {
      bridge_text_object_edit(C, *edit);
    }
    return views::CommandResult::Done;
  }
  r_error = "Not something the toolbar does";
  return views::CommandResult::Failed;
}

/** Commands that change no data an operator running holds, which go ahead of it. */
bool bridge_toolbar_view_live(const views::protocol::Command &command)
{
  const StringRef target = command.target()->string_view();
  return ELEM(target, "orientation", "pivot", "snap", "proportional", "mirror", "mirror_topology") ||
         ELEM(target, "snap_on", "snap_element", "proportional_on", "proportional_falloff", "automerge") ||
         target == "direction" || target.startswith("brush:") || target.startswith("axis:") ||
         /* Undo and Redo answer at once, refused while an operation waits (ROUND6 TOUCH-3), never
          * held back to run after it, undoing something else. */
         ELEM(target, "undo", "redo") ||
         /* The waiting operation's own keys are for it: held back until it ends, they never
          * reach it (the knife's Undo and Escape did nothing). */
         target.startswith("modalkey:");
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name The Timeline Views
 *
 * `timeline`: the scene's frame, as `frame`, which `Set` moves to as the playhead does, with its
 * range; whether it plays and keys automatically, `autokey`; and in a storyboard the edit's frame,
 * `edit_frame`. `timeline_keys`: the frames with keys, `keys`, and those selected, `selected`, as
 * the timeline shows them, built only while it does.
 * \{ */

void bridge_timeline_view_build(bContext *C,
                                const views::Params & /*params*/,
                                views::ViewData * /*data*/,
                                views::ViewBuilder &builder)
{
  const Scene *scene = CTX_data_scene(C);
  const wmWindowManager *wm = CTX_wm_manager(C);
  const NodeId top = builder.top("timeline", [&](ViewBuffer &buffer, NodeFields &fields) {
    fields.label = scene ? scene->id.name + 2 : "";
    return views::protocol::CreateGroup(buffer);
  });
  if (scene == nullptr || wm == nullptr) {
    return;
  }
  const auto frame = [&](const char *key, const Scene &scene, const int start, const int end) {
    builder.add(top, key, [&](ViewBuffer &buffer, NodeFields &fields) {
      fields.label = IFACE_("Frame");
      return views::protocol::CreateNumber(buffer,
                                           scene.r.cfra,
                                           true,
                                           views::protocol::NumberKind::Frame,
                                           MINAFRAMEF,
                                           MAXFRAMEF,
                                           start,
                                           end,
                                           1.0,
                                           0);
    });
  };
  frame("frame", *scene, PSFRA, PEFRA);
  builder.add(top, "preview", [&](ViewBuffer &buffer, NodeFields & /*fields*/) {
    return bridge_data(buffer, (scene->r.flag & SCER_PRV_RANGE) != 0);
  });
  builder.add(top, "playing", [&](ViewBuffer &buffer, NodeFields & /*fields*/) {
    return bridge_data(buffer, ED_screen_animation_playing(wm) != nullptr);
  });
  builder.add(top, "autokey", [&](ViewBuffer &buffer, NodeFields &fields) {
    fields.label = IFACE_("Auto Keying");
    return views::protocol::CreateToggle(
        buffer, scene->toolsettings && (scene->toolsettings->autokey_mode & AUTOKEY_ON));
  });
  /* A storyboard: the workspace's sequencer scene has shots, the window following the one under
   * its playhead. */
  const Scene *sequencer_scene = CTX_data_sequencer_scene(C);
  const WorkSpace *workspace = CTX_wm_workspace(C);
  if (sequencer_scene && workspace && (workspace->flags & WORKSPACE_SYNC_SCENE_TIME) &&
      sequencer_scene->ed && !BLI_listbase_is_empty(seq::active_seqbase_get(sequencer_scene->ed)))
  {
    frame("edit_frame", *sequencer_scene, sequencer_scene->r.sfra, sequencer_scene->r.efra);
  }
}

views::CommandResult bridge_timeline_view_command(bContext *C,
                                                  const views::Params & /*params*/,
                                                  views::ViewData * /*data*/,
                                                  const views::protocol::Command &command,
                                                  std::string &r_error)
{
  Scene *scene = CTX_data_scene(C);
  const std::string_view target = command.target()->string_view();
  if (scene == nullptr || command.op() != views::protocol::Op::Set) {
    r_error = "Not something the timeline does";
    return views::CommandResult::Failed;
  }
  if (target == "frame") {
    /* As the timeline's own playhead sets it: its update clamps, moves the sound and redraws.
     * Like scrubbing in Blender, changing frames adds no undo step. */
    const views::protocol::FloatValue *value = command.value_as_FloatValue();
    PointerRNA scene_ptr = RNA_id_pointer_create(&scene->id);
    PropertyRNA *prop = RNA_struct_find_property(&scene_ptr, "frame_current");
    RNA_property_int_set(&scene_ptr, prop, value ? int(value->value()) : scene->r.cfra);
    RNA_property_update(C, &scene_ptr, prop);
    ED_areas_do_frame_follow(C, false);
    return views::CommandResult::Done;
  }
  if (target == "autokey") {
    const views::protocol::BoolValue *value = command.value_as_BoolValue();
    PointerRNA ptr = RNA_pointer_create_discrete(&scene->id, RNA_ToolSettings, scene->toolsettings);
    PropertyRNA *prop = RNA_struct_find_property(&ptr, "use_keyframe_insert_auto");
    RNA_property_boolean_set(&ptr, prop, value && value->value());
    RNA_property_update(C, &ptr, prop);
    bridge_rna_undo_push(C, prop);
    return views::CommandResult::Done;
  }
  r_error = "Not something the timeline does";
  return views::CommandResult::Failed;
}

void bridge_timeline_keys_view_build(bContext *C,
                                     const views::Params & /*params*/,
                                     views::ViewData * /*data*/,
                                     views::ViewBuilder &builder)
{
  using namespace io::serialize;
  const NodeId top = builder.top("timeline_keys", [](ViewBuffer &buffer, NodeFields & /*fields*/) {
    return views::protocol::CreateGroup(buffer);
  });
  const std::shared_ptr<Value> keys = bridge_python_value(
      C, "timeline.keys", "bl_ui.native_timeline.keys(bpy.context)");
  std::vector<int64_t> frames, selected;
  if (const ArrayValue *array = keys ? keys->as_array_value() : nullptr) {
    for (const std::shared_ptr<Value> &item : array->elements()) {
      if (const DictionaryValue *key = item->as_dictionary_value()) {
        const int64_t frame = int64_t(bridge_number(*key, "f", 0.0));
        frames.push_back(frame);
        if (bridge_flag(*key, "s")) {
          selected.push_back(frame);
        }
      }
    }
  }
  for (const auto &[key, values] : {std::pair{"keys", &frames}, std::pair{"selected", &selected}}) {
    builder.add(top, key, [&](ViewBuffer &buffer, NodeFields & /*fields*/) {
      return views::protocol::CreateData(
          buffer,
          views::protocol::Value::IntsValue,
          views::protocol::CreateIntsValue(buffer, buffer.CreateVector(*values)).Union());
    });
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name The Menu and Popup Views
 *
 * `menu`: one of Blender's menus, subscribed to with its `route`, see
 * `interface_native_menu.cc`. Its items are keyed by their own routes: buttons, which `Invoke` runs (where the pointer is
 * with `x` and `y` parameters, for operators that follow it from there), and menu buttons, the
 * routes of their submenus. Built once for each subscription: a menu shows what Blender has as
 * it opens.
 *
 * `popup`: what Blender asks the interface to show where the pointer is, in place of its own popup:
 * a menu, an operator's choice of an enum, or Rename Active Item. Keyed by a number that grows
 * with each, so the interface shows each once.
 * \{ */

/** Blender's cursor where the pointer is, at the `x` and `y` of \a params in the window's pixels,
 * for menus that list and operators that follow the pointer from there, as Bevel. */
void bridge_menu_cursor_set(bContext *C, const views::Params &params)
{
  wmWindow *win = CTX_wm_window(C);
  const std::optional<double> x = params.number("x"), y = params.number("y");
  if (win && x && y && win->runtime->eventstate) {
    int position[2] = {int(*x), int(*y)};
    wm_cursor_position_from_ghost_client_coords(win, &position[0], &position[1]);
    win->runtime->eventstate->xy[0] = position[0];
    win->runtime->eventstate->xy[1] = position[1];
  }
}

void bridge_menu_view_build(bContext *C,
                            const views::Params &params,
                            views::ViewData * /*data*/,
                            views::ViewBuilder &builder)
{
  const std::optional<std::string_view> route = params.text("route");
  bridge_menu_cursor_set(C, params);
  if (route && CTX_wm_window(C) && CTX_wm_area(C) && CTX_wm_region(C)) {
    ui::native::menu_write(C, *route, builder);
    return;
  }
  builder.top("menu", [](ViewBuffer &buffer, NodeFields & /*fields*/) {
    return views::protocol::CreateMenu(buffer);
  });
}

views::CommandResult bridge_menu_view_command(bContext *C,
                                              const views::Params & /*params*/,
                                              views::ViewData * /*data*/,
                                              const views::protocol::Command &command,
                                              std::string &r_error)
{
  if (command.op() != views::protocol::Op::Invoke) {
    r_error = "Menu items are only run";
    return views::CommandResult::Failed;
  }
  if (CTX_wm_window(C) == nullptr || CTX_wm_area(C) == nullptr || CTX_wm_region(C) == nullptr) {
    r_error = "No window to run it in";
    return views::CommandResult::Failed;
  }
  bridge_menu_cursor_set(C, views::Params(command.params()));
  ui::native::menu_run(C, command.target()->string_view());
  return views::CommandResult::Done;
}

/** What Blender last asked the interface to show, see #bridge_menu_popup. */
struct BridgePopup {
  uint64_t number = 0;
  std::string menu;
  /** An enum's choice: the operator and its property, its title and items. */
  std::string op_name;
  std::string prop_name;
  std::string title;
  struct Item {
    std::string label, value, icon;
  };
  std::vector<Item> items;
  bool rename = false;
  /** One of the interface's own commands, which a key stands in for, see
   * #WM_native_ui_keymap_item_answer: `search`, `settings`, `properties` or `interface`. */
  std::string command;
  float x = 0.5f, y = 0.5f;
};
BridgePopup bridge_popup;

/** Show \a popup, where the pointer is in \a C's window. */
void bridge_popup_show(bContext *C, BridgePopup popup)
{
  wmWindow *win = CTX_wm_window(C);
  if (win && win->runtime->eventstate) {
    const float width = WM_window_native_pixel_x(win);
    const float height = WM_window_native_pixel_y(win);
    if (width > 0 && height > 0) {
      popup.x = win->runtime->eventstate->xy[0] / width;
      popup.y = 1.0f - win->runtime->eventstate->xy[1] / height;
    }
  }
  popup.number = bridge_popup.number + 1;
  /* What Blender asked for, so a report of a key that did nothing can be read off the log: asked
   * here, then shown (`menu … at`) or empty (`menu … empty`) by the interface. */
  const std::string line = !popup.menu.empty()    ? popup.menu :
                           !popup.op_name.empty() ? "choice " + popup.op_name :
                           popup.rename           ? std::string("rename") :
                           !popup.command.empty() ? "command " + popup.command :
                                                    std::string("nothing");
  WM_native_ui_session_log("popup", line.c_str());
  bridge_popup = std::move(popup);
  views::view_type_dirty("popup");
}

void bridge_popup_view_build(bContext * /*C*/,
                             const views::Params & /*params*/,
                             views::ViewData * /*data*/,
                             views::ViewBuilder &builder)
{
  const BridgePopup &popup = bridge_popup;
  const NodeId top = builder.top("popup:" + std::to_string(popup.number),
                                 [&](ViewBuffer &buffer, NodeFields &fields) {
                                   fields.label = popup.title;
                                   return views::protocol::CreateGroup(buffer);
                                 });
  if (popup.number == 0) {
    return;
  }
  /* Where the pointer is, as fractions of the window from its top left. */
  const double position[2] = {popup.x, popup.y};
  builder.add(top, "position", [&](ViewBuffer &buffer, NodeFields & /*fields*/) {
    return bridge_data(buffer, Span<double>(position, 2));
  });
  if (!popup.menu.empty()) {
    builder.add(top, "menu", [&](ViewBuffer &buffer, NodeFields & /*fields*/) {
      return bridge_data(buffer, std::string_view(popup.menu));
    });
  }
  if (popup.rename) {
    builder.add(top, "rename", [](ViewBuffer &buffer, NodeFields & /*fields*/) {
      return bridge_data(buffer, true);
    });
  }
  if (!popup.command.empty()) {
    builder.add(top, "command", [&](ViewBuffer &buffer, NodeFields & /*fields*/) {
      return bridge_data(buffer, std::string_view(popup.command));
    });
  }
  if (!popup.op_name.empty()) {
    /* Its items, with headings without a value between groups of them. */
    builder.add(top, "choice", [&](ViewBuffer &buffer, NodeFields &fields) {
      fields.label = popup.title;
      OptionOffsets options;
      for (const BridgePopup::Item &item : popup.items) {
        options.push_back(views::protocol::CreateOptionDirect(buffer,
                                                              item.value.empty() ? nullptr :
                                                                                   item.value.c_str(),
                                                              item.label.c_str(),
                                                              item.icon.c_str()));
      }
      return views::protocol::CreateChoiceDirect(
          buffer, nullptr, &options, views::protocol::ChoiceStyle::Actions);
    });
  }
}

views::CommandResult bridge_popup_view_command(bContext *C,
                                               const views::Params & /*params*/,
                                               views::ViewData * /*data*/,
                                               const views::protocol::Command &command,
                                               std::string &r_error)
{
  const views::protocol::TextValue *value = command.value_as_TextValue();
  if (command.target()->string_view() != "choice" || command.op() != views::protocol::Op::Set ||
      value == nullptr || value->value() == nullptr || bridge_popup.op_name.empty())
  {
    r_error = "Not something the popup does";
    return views::CommandResult::Failed;
  }
  bridge_operator_call_with_enum_property(C,
                                          bridge_popup.op_name.c_str(),
                                          bridge_popup.prop_name.c_str(),
                                          value->value()->c_str());
  return views::CommandResult::Done;
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name The Keys View
 *
 * Every item of the key-maps that apply in the 3D View now, in the order the event system tries
 * them (the viewport's, the editor's, then the window's), with what its key does in the native
 * interface, see #WM_native_ui_keymap_item_answer. For the Mac bridge harness's `keys` scenario,
 * which fails when one is left without an answer. Each item is a node keyed
 * `<key-map>\t<index>`, labelled with its key, holding `<operator>\t<answer>`; the answer is
 * `runs`, `menu <name> <poll|no-poll|missing>`, `choice`, `dialog`, `rename`,
 * `stand-in <command>` or `says <text>`.
 * \{ */

static std::string bridge_key_answer_text(bContext *C, const WMNativeKeyAnswer &answer)
{
  using Kind = WMNativeKeyAnswer::Kind;
  switch (answer.kind) {
    case Kind::Runs:
      return "runs";
    case Kind::Menu: {
      MenuType *mt = WM_menutype_find(answer.menu.c_str(), true);
      return "menu " + answer.menu + " " +
             (mt == nullptr ? "missing" : WM_menutype_poll(C, mt) ? "poll" : "no-poll");
    }
    case Kind::Choice:
      return "choice";
    case Kind::Dialog:
      return "dialog";
    case Kind::Rename:
      return "rename";
    case Kind::StandIn:
      return "stand-in " + answer.command;
    case Kind::Says:
      return "says " + answer.text;
    case Kind::Document:
      return "document " + answer.command + (answer.menu.empty() ? "" : " " + answer.menu);
  }
  return "unknown";
}

void bridge_keys_view_build(bContext *C,
                            const views::Params & /*params*/,
                            views::ViewData * /*data*/,
                            views::ViewBuilder &builder)
{
  const NodeId top = builder.top("keys", [](ViewBuffer &buffer, NodeFields & /*fields*/) {
    return views::protocol::CreateGroup(buffer);
  });
  wmWindowManager *wm = CTX_wm_manager(C);
  wmWindow *win = CTX_wm_window(C);
  ScrArea *area = CTX_wm_area(C);
  ARegion *region = area && area->spacetype == SPACE_VIEW3D ?
                        BKE_area_find_region_type(area, RGN_TYPE_WINDOW) :
                        nullptr;
  if (wm == nullptr || win == nullptr || region == nullptr) {
    return;
  }
  ARegion *region_prev = CTX_wm_region(C);
  CTX_wm_region_set(C, region);
  Set<const wmKeyMap *> seen;
  for (ListBaseT<wmEventHandler> *handlers :
       {&region->runtime->handlers, &area->handlers, &win->runtime->handlers})
  {
    for (wmEventHandler &handler_base : *handlers) {
      if (handler_base.type != WM_HANDLER_TYPE_KEYMAP) {
        continue;
      }
      auto *handler = reinterpret_cast<wmEventHandler_Keymap *>(&handler_base);
      wmEventHandler_KeymapResult km_result;
      WM_event_get_keymaps_from_handler(wm, win, handler, &km_result);
      for (int km_index = 0; km_index < km_result.keymaps_len; km_index++) {
        wmKeyMap *keymap = km_result.keymaps[km_index];
        if (keymap == nullptr || !seen.add(keymap) || !WM_keymap_poll(C, keymap)) {
          continue;
        }
        int index = -1;
        for (wmKeyMapItem &kmi : keymap->items) {
          index++;
          if ((kmi.flag & KMI_INACTIVE) || kmi.idname[0] == '\0') {
            continue;
          }
          std::string call = kmi.idname;
          if (kmi.ptr && WM_operatortype_find(kmi.idname, true)) {
            call += "(" +
                    RNA_pointer_as_string_keywords(C, kmi.ptr, false, false, true, 256) + ")";
          }
          const std::string text = call + "\t" +
                                   bridge_key_answer_text(
                                       C, WM_native_ui_keymap_item_answer(C, &kmi));
          const std::string key = WM_keymap_item_to_string(&kmi, false).value_or("");
          builder.add(top,
                      std::string(keymap->idname) + "\t" + std::to_string(index),
                      [&](ViewBuffer &buffer, NodeFields &fields) {
                        fields.label = key;
                        return bridge_data(buffer, std::string_view(text));
                      });
        }
      }
    }
  }
  CTX_wm_region_set(C, region_prev);
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name The Preferences List View
 *
 * The Preferences' lists, which their sections draw with lists of their own and Settings lists in
 * its own way, see `bl_ui.native_settings`: with `list` set to `addons`, the add-ons by module,
 * each with its `<module>:enabled` toggle; with `keymaps`, the keymaps by name, those `expanded`
 * or all matching `search` with their items, `<keymap>/<id>`, each with its `:active` toggle. Its
 * `save` button saves the preferences when they changed, as the interface stops showing them;
 * while it shows, they are saved a moment after each change.
 * \{ */

void bridge_preferences_list_view_build(bContext *C,
                                        const views::Params &params,
                                        views::ViewData * /*data*/,
                                        views::ViewBuilder &builder)
{
  using namespace io::serialize;
  const NodeId top = builder.top("preferences_list", [](ViewBuffer &buffer, NodeFields & /*fields*/) {
    return views::protocol::CreateGroup(buffer);
  });
  builder.add(top, "save", [](ViewBuffer &buffer, NodeFields &fields) {
    fields.label = IFACE_("Save Preferences");
    return views::protocol::CreateButton(buffer);
  });
  bridge_preferences_save_when_changed(C, std::chrono::steady_clock::now());
  if (bridge_preferences_save_pending) {
    /* Saved a moment after the change. */
    views::view_type_dirty("preferences_list");
  }
  const std::string_view list = params.text("list").value_or("");
  const auto toggle = [&](const NodeId parent, const std::string &key, const bool value) {
    builder.add(parent, key, [&](ViewBuffer &buffer, NodeFields & /*fields*/) {
      return views::protocol::CreateToggle(buffer, value);
    });
  };
  if (list == "addons") {
    const std::shared_ptr<Value> addons = bridge_python_value(
        C, "preferences.addons", "bl_ui.native_settings.addons(bpy.context)");
    const NodeId rows = builder.add(top, "addons", [](ViewBuffer &buffer, NodeFields & /*fields*/) {
      return views::protocol::CreateList(buffer);
    });
    for (const std::shared_ptr<Value> &item : addons && addons->as_array_value() ?
                                                   addons->as_array_value()->elements() :
                                                   Span<std::shared_ptr<Value>>())
    {
      const DictionaryValue *addon = item->as_dictionary_value();
      if (addon == nullptr) {
        continue;
      }
      const std::string module(bridge_text(*addon, "module"));
      const NodeId row = builder.add(rows, module, [&](ViewBuffer &buffer, NodeFields &fields) {
        fields.label = bridge_text(*addon, "name");
        fields.description = bridge_text(*addon, "description");
        return views::protocol::CreateRowDirect(
            buffer, 0, false, false, nullptr, bridge_text(*addon, "category").data());
      });
      toggle(row, module + ":enabled", bridge_flag(*addon, "enabled"));
      if (const std::string_view warning = bridge_text(*addon, "warning"); !warning.empty()) {
        builder.add(row, module + ":warning", [&](ViewBuffer &buffer, NodeFields & /*fields*/) {
          return views::protocol::CreateLabelDirect(buffer, std::string(warning).c_str());
        });
      }
    }
  }
  else if (list == "keymaps") {
    /* What to list, as `keymaps` takes it. */
    std::string expression = "bl_ui.native_settings.keymaps(bpy.context, search=\"" +
                             bridge_json_escape(std::string(params.text("search").value_or(""))) +
                             "\", expanded=(";
    if (const views::protocol::Param *param = params.find("expanded")) {
      if (const views::protocol::TextsValue *names = param->value_as_TextsValue()) {
        for (const flatbuffers::String *name : *names->value()) {
          expression += "\"" + bridge_json_escape(name->str()) + "\",";
        }
      }
    }
    expression += "))";
    const std::shared_ptr<Value> keymaps = bridge_python_value(
        C, "preferences.keymaps", expression.c_str());
    const NodeId rows = builder.add(top, "keymaps", [](ViewBuffer &buffer, NodeFields & /*fields*/) {
      return views::protocol::CreateListDirect(buffer, nullptr, false, false, false, true);
    });
    for (const std::shared_ptr<Value> &item : keymaps && keymaps->as_array_value() ?
                                                  keymaps->as_array_value()->elements() :
                                                  Span<std::shared_ptr<Value>>())
    {
      const DictionaryValue *keymap = item->as_dictionary_value();
      if (keymap == nullptr) {
        continue;
      }
      const std::string name(bridge_text(*keymap, "name"));
      const ArrayValue *items = keymap->lookup_array("items");
      const NodeId row = builder.add(rows, name, [&](ViewBuffer &buffer, NodeFields &fields) {
        fields.label = bridge_text(*keymap, "title");
        /* Selected: its items are listed. */
        return views::protocol::CreateRow(
            buffer, int32_t(bridge_number(*keymap, "depth", 0.0)), items != nullptr);
      });
      if (items == nullptr) {
        continue;
      }
      for (const std::shared_ptr<Value> &entry : items->elements()) {
        const DictionaryValue *kmi = entry->as_dictionary_value();
        if (kmi == nullptr) {
          continue;
        }
        const std::string key = name + "/" + std::to_string(int64_t(bridge_number(*kmi, "id", 0.0)));
        const NodeId item_row = builder.add(row, key, [&](ViewBuffer &buffer, NodeFields &fields) {
          fields.label = bridge_text(*kmi, "name");
          /* Its keys, as Blender writes them. */
          fields.description = bridge_text(*kmi, "keys");
          return views::protocol::CreateRow(buffer);
        });
        toggle(item_row, key + ":active", bridge_flag(*kmi, "active"));
      }
    }
  }
}

views::CommandResult bridge_preferences_list_view_command(bContext *C,
                                                          const views::Params & /*params*/,
                                                          views::ViewData * /*data*/,
                                                          const views::protocol::Command &command,
                                                          std::string &r_error)
{
  using namespace io::serialize;
  const std::string target = command.target()->str();
  if (target == "save" && command.op() == views::protocol::Op::Invoke) {
    bridge_preferences_save(C);
    return views::CommandResult::Done;
  }
  const views::protocol::BoolValue *on = command.value_as_BoolValue();
  if (command.op() != views::protocol::Op::Set || on == nullptr) {
    r_error = "Not something the Preferences' lists do";
    return views::CommandResult::Failed;
  }
  /* The change, as `bl_ui.native_settings` makes it. */
  const char *flag = on->value() ? "True" : "False";
  std::string call;
  if (StringRef(target).endswith(":enabled")) {
    call = "addon_enable(bpy.context, \"" +
           bridge_json_escape(target.substr(0, target.size() - strlen(":enabled"))) + "\", " +
           flag + ")";
  }
  else if (StringRef(target).endswith(":active")) {
    const std::string item = target.substr(0, target.size() - strlen(":active"));
    const size_t slash = item.rfind('/');
    if (slash == std::string::npos) {
      r_error = "No such keymap item";
      return views::CommandResult::Failed;
    }
    call = "keymap_item_active(bpy.context, \"" + bridge_json_escape(item.substr(0, slash)) +
           "\", " + std::to_string(std::atoll(item.c_str() + slash + 1)) + ", " + flag + ")";
  }
  else {
    r_error = "Not something the Preferences' lists do";
    return views::CommandResult::Failed;
  }
#ifdef WITH_PYTHON
  const char *imports[] = {"bpy", "bl_ui", nullptr};
  BPY_run_string_eval(C, imports, ("bl_ui.native_settings." + call).c_str());
#endif
  return views::CommandResult::Done;
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name The Outliner View
 *
 * The scene's collections and objects, as `bl_ui.native_panels.hierarchy` lists them: the
 * tree list `outliner`, its rows keyed by their path from the scene's collection, such as
 * `/c12/o34` for an object in a collection, the active object's the list's active row. Each row
 * has its `<key>:hidden` toggle, the `<key>:actions` it allows, and `<key>:accepts`, whether rows
 * may be dropped on it. Edits run `wm.native_panel_edit`.
 * \{ */

void bridge_outliner_view_build(bContext *C,
                                const views::Params & /*params*/,
                                views::ViewData * /*data*/,
                                views::ViewBuilder &builder)
{
  using namespace io::serialize;
  const std::shared_ptr<Value> rows = bridge_python_value(
      C, "outliner", "bl_ui.native_panels.hierarchy(bpy.context)");
  const ArrayValue *array = rows ? rows->as_array_value() : nullptr;
  std::string active;
  if (array) {
    for (const std::shared_ptr<Value> &item : array->elements()) {
      if (const DictionaryValue *row = item->as_dictionary_value(); row && bridge_flag(*row, "active")) {
        active = bridge_text(*row, "key");
      }
    }
  }
  const NodeId top = builder.top("outliner", [](ViewBuffer &buffer, NodeFields & /*fields*/) {
    return views::protocol::CreateGroup(buffer);
  });
  const NodeId list = builder.add(top, "rows", [&](ViewBuffer &buffer, NodeFields & /*fields*/) {
    return views::protocol::CreateListDirect(
        buffer, active.c_str(), false, false, true, true);
  });
  if (array == nullptr) {
    return;
  }
  for (const std::shared_ptr<Value> &item : array->elements()) {
    const DictionaryValue *row = item->as_dictionary_value();
    if (row == nullptr) {
      continue;
    }
    const std::string key(bridge_text(*row, "key"));
    const NodeId node = builder.add(list, key, [&](ViewBuffer &buffer, NodeFields &fields) {
      fields.label = bridge_text(*row, "name");
      fields.icon = bridge_text(*row, "icon");
      fields.enabled = bridge_flag(*row, "enabled");
      return views::protocol::CreateRow(buffer,
                                        int32_t(bridge_number(*row, "depth", 0.0)),
                                        bridge_flag(*row, "selected"),
                                        true);
    });
    builder.add(node, key + ":hidden", [&](ViewBuffer &buffer, NodeFields & /*fields*/) {
      return views::protocol::CreateToggle(buffer, bridge_flag(*row, "hidden"));
    });
    builder.add(node, key + ":actions", [&](ViewBuffer &buffer, NodeFields & /*fields*/) {
      OptionOffsets options;
      if (const ArrayValue *actions = row->lookup_array("actions")) {
        for (const std::shared_ptr<Value> &action : actions->elements()) {
          if (const StringValue *name = action->as_string_value()) {
            options.push_back(views::protocol::CreateOptionDirect(buffer, name->value().c_str()));
          }
        }
      }
      return views::protocol::CreateChoiceDirect(
          buffer, nullptr, &options, views::protocol::ChoiceStyle::Actions);
    });
    builder.add(node, key + ":accepts", [&](ViewBuffer &buffer, NodeFields & /*fields*/) {
      return bridge_data(buffer, bridge_flag(*row, "accepts"));
    });
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name The Volume View
 *
 * Commands to the scene shown as 3D geometry on Apple Vision Pro, whose geometry comes apart, see
 * `wm_apple_ios_volume.cc`: `Set` of `shown`, whether it shows; `Activate` of an object by its
 * name selects it, or with an `extend` parameter toggles it in the selection, and of none
 * deselects all; `Move` of an object by its name moves it by the value's offset in world space,
 * from where the move began, a drag's phases making one undo step.
 * \{ */

void bridge_volume_view_build(bContext * /*C*/,
                              const views::Params & /*params*/,
                              views::ViewData * /*data*/,
                              views::ViewBuilder &builder)
{
  builder.top("volume", [](ViewBuffer &buffer, NodeFields & /*fields*/) {
    return views::protocol::CreateGroup(buffer);
  });
}

views::CommandResult bridge_volume_view_command(bContext *C,
                                                const views::Params & /*params*/,
                                                views::ViewData * /*data*/,
                                                const views::protocol::Command &command,
                                                std::string &r_error)
{
  const std::string target = command.target()->str();
  switch (command.op()) {
    case views::protocol::Op::Set: {
      const views::protocol::BoolValue *shown = command.value_as_BoolValue();
      bridge_volume_command(C, "volume_visible", shown && shown->value() ? "1" : "0");
      return views::CommandResult::Done;
    }
    case views::protocol::Op::Activate:
      bridge_volume_command(
          C, "volume_select", (views::Params(command.params()).flag("extend") ? "+" : "") + target);
      return views::CommandResult::Done;
    case views::protocol::Op::Move: {
      const views::protocol::FloatsValue *delta = command.value_as_FloatsValue();
      const char *phase = command.phase() == views::protocol::Phase::Begin ? "begin" :
                          ELEM(command.phase(),
                               views::protocol::Phase::End,
                               views::protocol::Phase::Once) ?
                                                                  "end" :
                                                                  "move";
      double offset[3] = {0.0, 0.0, 0.0};
      for (int i = 0; delta && delta->value() && i < 3 && i < int(delta->value()->size()); i++) {
        offset[i] = delta->value()->Get(i);
      }
      bridge_volume_command(C,
                            "volume_move",
                            fmt::format("{}|{}|{}|{}|{}", target, phase, offset[0], offset[1], offset[2]));
      return views::CommandResult::Done;
    }
    default:
      r_error = "Not something the volume does";
      return views::CommandResult::Failed;
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Canvas Views
 *
 * Editors an interface draws as canvases of its own, such as the curve editor, read as JSON by
 * their `native_*_query` and sent as records, see #wm::native_ui::records_add: the top record,
 * keyed by the view's name, as the query reads it, with `ack`, the `sequence` of the last edit,
 * and `error`, why it failed. `Set` of `state` with parameters says what to show, as the query
 * takes it; `Invoke` of `edit` with parameters makes an edit, the state added as `state`.
 * \{ */

using CanvasEdit = std::string (*)(bContext *C, const io::serialize::DictionaryValue &edit);

struct CanvasData : views::ViewData {
  /** What it shows, as the interface last set it. */
  std::shared_ptr<io::serialize::DictionaryValue> state =
      std::make_shared<io::serialize::DictionaryValue>();
  int64_t ack = 0;
  std::string error;
};

/** The records of what a canvas \a read, as its view's top. */
void bridge_canvas_records(views::ViewBuilder &builder,
                           const char *name,
                           const io::serialize::DictionaryValue &read,
                           const CanvasData &data)
{
  io::serialize::DictionaryValue root;
  for (const io::serialize::DictionaryValue::Item &item : read.elements()) {
    root.append(item.first, item.second);
  }
  root.append_int("ack", data.ack);
  root.append_str("error", data.error);
  views::records_add(builder, std::nullopt, name, root);
}

std::unique_ptr<views::ViewData> bridge_canvas_create()
{
  return std::make_unique<CanvasData>();
}

/** A command to a canvas view, see above. */
template<CanvasEdit edit>
views::CommandResult bridge_canvas_command(bContext *C,
                                           const views::Params & /*params*/,
                                           views::ViewData *view_data,
                                           const views::protocol::Command &command,
                                           std::string &r_error)
{
  CanvasData &data = static_cast<CanvasData &>(*view_data);
  const std::string_view target = command.target()->string_view();
  if (target == "state" && command.op() == views::protocol::Op::Set) {
    data.state = views::params_dictionary(command.params());
    return views::CommandResult::Done;
  }
  if (target != "edit" || command.op() != views::protocol::Op::Invoke) {
    r_error = "Not something the canvas does";
    return views::CommandResult::Failed;
  }
  std::unique_ptr<io::serialize::DictionaryValue> request = views::params_dictionary(
      command.params());
  data.ack = request->lookup_int("sequence").value_or(data.ack);
  auto state = request->append_dict("state");
  for (const io::serialize::DictionaryValue::Item &item : data.state->elements()) {
    state->append(item.first, item.second);
  }
  data.error = edit(C, *request);
  if (!data.error.empty()) {
    r_error = data.error;
    return views::CommandResult::Failed;
  }
  return views::CommandResult::Done;
}

void bridge_graph_view_build(bContext *C,
                             const views::Params & /*params*/,
                             views::ViewData *view_data,
                             views::ViewBuilder &builder)
{
  const CanvasData &data = static_cast<const CanvasData &>(*view_data);
  bridge_canvas_records(builder, "graph", *ed::graph::native_graph_read(C, *data.state), data);
}

/** The storyboard's shots, as `native_storyboard_read` reads them. Their pictures are drawn as
 * the window draws, a few at a time, see #WM_native_ui_storyboard_draw, which builds it again. */
void bridge_storyboard_view_build(bContext *C,
                                  const views::Params & /*params*/,
                                  views::ViewData *view_data,
                                  views::ViewBuilder &builder)
{
  const CanvasData &data = static_cast<const CanvasData &>(*view_data);
  bridge_storyboard_state = data.state;
  const auto read = ed::vse::native_storyboard_read(C, *data.state);
  bridge_storyboard_pending = read->lookup_int("pending").value_or(0);
  bridge_canvas_records(builder, "storyboard", *read, data);
}

/** The images to show and paint, as `native_image_read` reads them. Its picture and UV edges come
 * apart, see #WM_native_ui_image_update, drawn while an interface shows it. */
void bridge_image_view_build(bContext *C,
                             const views::Params & /*params*/,
                             views::ViewData *view_data,
                             views::ViewBuilder &builder)
{
  const CanvasData &data = static_cast<const CanvasData &>(*view_data);
  if (data.state != bridge_image_state) {
    /* Another image, or its UVs shown or not. */
    bridge_image_state = data.state;
    bridge_image_pixels_pending = true;
    bridge_image_uvs_pending = true;
  }
  bridge_canvas_records(builder, "image", *ed::image::native_image_read(C, *data.state), data);
}

void bridge_image_view_shown(const bool shown)
{
  bridge_image_shown = shown;
  bridge_image_pixels_pending = true;
  bridge_image_uvs_pending = true;
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name The Settings and Render Views
 *
 * `settings`: the interface's own settings that Blender keeps, which it sets as it starts and as
 * they change. `render`: a render started from the interface, see `bl_ui.native_render`.
 * \{ */

void bridge_settings_view_build(bContext * /*C*/,
                                const views::Params & /*params*/,
                                views::ViewData * /*data*/,
                                views::ViewBuilder &builder)
{
  const NodeId top = builder.top("settings", [](ViewBuffer &buffer, NodeFields & /*fields*/) {
    return views::protocol::CreateGroup(buffer);
  });
  const auto toggle = [&](const char *key, const char *label, const bool value) {
    builder.add(top, key, [&](ViewBuffer &buffer, NodeFields &fields) {
      fields.label = IFACE_(label);
      return views::protocol::CreateToggle(buffer, value);
    });
  };
  /* Blender's own interface, as on a desktop computer, and its size. */
  toggle("desktop", "Desktop Interface", bridge_desktop_ui.load());
  builder.add(top, "desktop_scale", [&](ViewBuffer &buffer, NodeFields &fields) {
    fields.label = IFACE_("Desktop Interface Size");
    return views::protocol::CreateNumber(buffer,
                                         bridge_desktop_scale.load(),
                                         false,
                                         views::protocol::NumberKind::Factor,
                                         0.5,
                                         1.25,
                                         0.5,
                                         1.25,
                                         0.05,
                                         2);
  });
  toggle("hover_highlight", "Highlight What the Pencil Hovers Over", bridge_hover_highlight);
  builder.add(top, "keymap", [&](ViewBuffer &buffer, NodeFields &fields) {
    fields.label = IFACE_("Keymap");
    static const std::pair<const char *, const char *> keymaps[] = {
        {"Industry_Compatible", "Industry Compatible"}, {"Blender", "Blender"}};
    OptionOffsets options = bridge_options(buffer, OptionLabels(keymaps, std::size(keymaps)));
    return views::protocol::CreateChoiceDirect(buffer, U.keyconfigstr, &options);
  });
  builder.add(top, "navigation_corner", [&](ViewBuffer &buffer, NodeFields &fields) {
    fields.label = IFACE_("Navigation Gizmo");
    static const std::pair<const char *, const char *> corners[] = {{"top_left", "Top Left"},
                                                                    {"top_right", "Top Right"},
                                                                    {"bottom_left", "Bottom Left"},
                                                                    {"bottom_right", "Bottom Right"}};
    OptionOffsets options = bridge_options(buffer, OptionLabels(corners, std::size(corners)));
    const std::string value = std::string(bridge_navigation_top ? "top" : "bottom") + "_" +
                              (bridge_navigation_left ? "left" : "right");
    return views::protocol::CreateChoiceDirect(buffer, value.c_str(), &options);
  });
  builder.add(top, "navigation_style", [&](ViewBuffer &buffer, NodeFields &fields) {
    fields.label = IFACE_("Navigation Gizmo Style");
    static const std::pair<const char *, const char *> styles[] = {{"blender", "Blender"},
                                                                   {"minimal", "Minimal"}};
    OptionOffsets options = bridge_options(buffer, OptionLabels(styles, std::size(styles)));
    return views::protocol::CreateChoiceDirect(
        buffer, bridge_navigation_minimal ? "minimal" : "blender", &options);
  });
  /* What a drag with the Tweak tool does. */
  builder.add(top, "tweak_drag", [&](ViewBuffer &buffer, NodeFields &fields) {
    fields.label = IFACE_("Tweak");
    static const std::pair<const char *, const char *> parts[] = {
        {"move", "Move"}, {"roll", "Roll"}, {"tilt", "Tilt"}};
    OptionOffsets options = bridge_options(buffer, OptionLabels(parts, std::size(parts)));
    std::string value;
    for (const auto &[on, name] : {std::pair{bridge_tweak_move.load(), "move"},
                                   std::pair{bridge_tweak_roll.load(), "roll"},
                                   std::pair{bridge_tweak_tilt.load(), "tilt"}})
    {
      if (on) {
        value += (value.empty() ? "" : ",") + std::string(name);
      }
    }
    return views::protocol::CreateChoiceDirect(
        buffer, value.c_str(), &options, views::protocol::ChoiceStyle::Expanded, true);
  });
}

views::CommandResult bridge_settings_view_command(bContext *C,
                                                  const views::Params & /*params*/,
                                                  views::ViewData * /*data*/,
                                                  const views::protocol::Command &command,
                                                  std::string &r_error)
{
  const std::string_view target = command.target()->string_view();
  const views::protocol::TextValue *text_value = command.value_as_TextValue();
  const std::string text = text_value && text_value->value() ? text_value->value()->str() : "";
  const views::protocol::BoolValue *on = command.value_as_BoolValue();
  if (command.op() != views::protocol::Op::Set) {
    r_error = "Settings are only set";
    return views::CommandResult::Failed;
  }
  if (target == "desktop" && on) {
    bridge_interface_set(C, on->value());
  }
  else if (target == "desktop_uv_editing" && on && on->value()) {
    bridge_desktop_uv_editing(C);
  }
  else if (target == "interface_measure" && on && on->value()) {
    bridge_interface_measure();
  }
  else if (target == "desktop_scale" && command.value_as_FloatValue()) {
    bridge_desktop_scale_set(C, float(command.value_as_FloatValue()->value()));
  }
  else if (target == "hover_highlight" && on) {
    bridge_hover_highlight = on->value();
  }
  else if (target == "keymap") {
    bridge_setting_execute(C, BridgeSettingCommand{"keymap", text});
  }
  else if (target == "addon_install") {
    bridge_setting_execute(C, BridgeSettingCommand{"addon_install", text});
  }
  else if (target == "navigation_style") {
    bridge_navigation_minimal = text == "minimal";
    WM_main_add_notifier(NC_SPACE | ND_SPACE_VIEW3D, nullptr);
    views::view_type_dirty("toolbar");
  }
  else if (target == "navigation_corner") {
    bridge_navigation_top = text.starts_with("top");
    bridge_navigation_left = text.ends_with("left");
    WM_main_add_notifier(NC_SPACE | ND_SPACE_VIEW3D, nullptr);
    /* The toolbar says where the gizmo is. */
    views::view_type_dirty("toolbar");
  }
  else if (target == "tweak_drag") {
    bridge_tweak_move = text.find("move") != std::string::npos;
    bridge_tweak_roll = text.find("roll") != std::string::npos;
    bridge_tweak_tilt = text.find("tilt") != std::string::npos;
  }
  else {
    r_error = "No such setting";
    return views::CommandResult::Failed;
  }
  return views::CommandResult::Done;
}

/** The render's state, as `bl_ui.native_render.status` gives it: a node of data for each of
 * its values, such as `state`, `done` and `image`. Built again soon while it renders. Buttons:
 * `image` and `animation` render, `cancel` and `clear`. */
void bridge_render_view_build(bContext *C,
                              const views::Params & /*params*/,
                              views::ViewData * /*data*/,
                              views::ViewBuilder &builder)
{
  using namespace io::serialize;
  const NodeId top = builder.top("render", [](ViewBuffer &buffer, NodeFields & /*fields*/) {
    return views::protocol::CreateGroup(buffer);
  });
  for (const char *name : {"image", "animation", "cancel", "clear"}) {
    builder.add(top, name, [](ViewBuffer &buffer, NodeFields & /*fields*/) {
      return views::protocol::CreateButton(buffer);
    });
  }
  const std::shared_ptr<Value> status = bridge_python_value(
      C, "render", "bl_ui.native_render.status(bpy.context)");
  const DictionaryValue *state = status ? status->as_dictionary_value() : nullptr;
  if (state == nullptr) {
    return;
  }
  for (const DictionaryValue::Item &item : state->elements()) {
    const std::string key = "state:" + item.first;
    const Value &value = *item.second;
    builder.add(top, key, [&](ViewBuffer &buffer, NodeFields & /*fields*/) {
      if (const StringValue *text = value.as_string_value()) {
        return bridge_data(buffer, std::string_view(text->value()));
      }
      if (const ArrayValue *array = value.as_array_value()) {
        std::vector<flatbuffers::Offset<flatbuffers::String>> texts;
        for (const std::shared_ptr<Value> &element : array->elements()) {
          const StringValue *text = element->as_string_value();
          texts.push_back(buffer.CreateString(text ? text->value() : ""));
        }
        const auto vector = buffer.CreateVector(texts);
        return views::protocol::CreateData(buffer,
                                           views::protocol::Value::TextsValue,
                                           views::protocol::CreateTextsValue(buffer, vector).Union());
      }
      const double number = value.as_double_value() ? value.as_double_value()->value() :
                            value.as_int_value()    ? double(value.as_int_value()->value()) :
                            value.as_boolean_value() ? double(value.as_boolean_value()->value()) :
                                                      0.0;
      return views::protocol::CreateData(
          buffer,
          views::protocol::Value::FloatValue,
          views::protocol::CreateFloatValue(buffer, number).Union());
    });
  }
  if (bridge_text(*state, "state") == "rendering") {
    /* Its progress, which no notifier tells of. */
    views::view_type_dirty("render");
  }
}

views::CommandResult bridge_render_view_command(bContext *C,
                                                const views::Params & /*params*/,
                                                views::ViewData * /*data*/,
                                                const views::protocol::Command &command,
                                                std::string &r_error)
{
  const std::string_view target = command.target()->string_view();
  if (command.op() != views::protocol::Op::Invoke ||
      !ELEM(target, "image", "animation", "cancel", "clear"))
  {
    r_error = "Not something rendering does";
    return views::CommandResult::Failed;
  }
  bridge_setting_execute(C, BridgeSettingCommand{"render", std::string(target)});
  return views::CommandResult::Done;
}

/** \} */


}  // namespace

void WM_native_ui_views_register()
{
  using namespace wm::native_ui;
  ViewType toolbar;
  toolbar.name = "toolbar";
  /* Describing the tools and quick actions runs Python: on any change, but ten times a second at
   * most, as during playback. */
  toolbar.min_interval = 0.1;
  toolbar.build = bridge_toolbar_view_build;
  toolbar.command = bridge_toolbar_view_command;
  toolbar.live = bridge_toolbar_view_live;
  view_type_add(std::move(toolbar));

  ViewType actions;
  actions.name = "actions";
  /* Runs Python, as the toolbar's strip does: on any change, ten times a second at most. */
  actions.min_interval = 0.1;
  actions.build = bridge_actions_view_build;
  actions.command = bridge_actions_view_command;
  view_type_add(std::move(actions));

  ViewType brushes;
  brushes.name = "brushes";
  /* Previews are written a few at a time, soon after another. */
  brushes.min_interval = 0.03;
  brushes.notifiers = {NC_BRUSH, NC_ASSET, NC_SCENE, NC_WM, NC_WORKSPACE};
  brushes.wants = [](const wmNotifier &note) {
    return note.category != NC_SCENE || ELEM(note.data, ND_MODE, ND_TOOLSETTINGS);
  };
  brushes.build = bridge_brushes_view_build;
  brushes.command = [](bContext *C,
                       const Params & /*params*/,
                       ViewData * /*data*/,
                       const protocol::Command &command,
                       std::string &r_error) {
    if (command.op() != protocol::Op::Activate) {
      r_error = "Brushes are only chosen";
      return CommandResult::Failed;
    }
    bridge_brush_activate(C, command.target()->str());
    return CommandResult::Done;
  };
  view_type_add(std::move(brushes));

  ViewType settings;
  settings.name = "settings";
  settings.notifiers = {NC_WM};
  settings.build = bridge_settings_view_build;
  settings.command = bridge_settings_view_command;
  settings.live = [](const protocol::Command & /*command*/) { return true; };
  view_type_add(std::move(settings));

  ViewType timeline;
  timeline.name = "timeline";
  timeline.notifiers = {NC_SCENE, NC_SCREEN, NC_WM};
  timeline.build = bridge_timeline_view_build;
  timeline.command = bridge_timeline_view_command;
  timeline.live = [](const protocol::Command &command) {
    return command.target()->string_view() == "frame";
  };
  view_type_add(std::move(timeline));

  ViewType timeline_keys;
  timeline_keys.name = "timeline_keys";
  /* Read with Python, four times a second at most. */
  timeline_keys.min_interval = 0.25;
  timeline_keys.notifiers = {NC_ANIMATION, NC_OBJECT, NC_SCENE, NC_GPENCIL, NC_WM, NC_GEOM};
  timeline_keys.wants = [](const wmNotifier &note) {
    /* Not as the frame changes, as during playback. */
    return note.category != NC_SCENE || note.data != ND_FRAME;
  };
  timeline_keys.build = bridge_timeline_keys_view_build;
  view_type_add(std::move(timeline_keys));

  ViewType assets;
  assets.name = "assets";
  /* Previews are written a few at a time, soon after another. */
  assets.min_interval = 0.04;
  assets.notifiers = {NC_ASSET, NC_WM};
  assets.build = bridge_assets_view_build;
  assets.command = [](bContext *C,
                      const Params & /*params*/,
                      ViewData * /*data*/,
                      const protocol::Command &command,
                      std::string &r_error) {
    if (command.op() != protocol::Op::Invoke) {
      r_error = "Assets are only added";
      return CommandResult::Failed;
    }
    /* At the 3D cursor, or onto the active object for materials and node groups. */
    bridge_asset_drag(C, BridgeAssetDragCommand{BRIDGE_ASSET_ADD, command.target()->str(), 0, 0});
    return CommandResult::Done;
  };
  view_type_add(std::move(assets));

  ViewType menu;
  menu.name = "menu";
  /* As it is when it opens: built once. */
  menu.notifiers = {0};
  menu.build = bridge_menu_view_build;
  menu.command = bridge_menu_view_command;
  view_type_add(std::move(menu));

  ViewType popup;
  popup.name = "popup";
  popup.notifiers = {0};
  popup.build = bridge_popup_view_build;
  popup.command = bridge_popup_view_command;
  view_type_add(std::move(popup));

  ViewType keys;
  keys.name = "keys";
  /* Read once, by a test, as the mode it is asked in. */
  keys.notifiers = {0};
  keys.build = bridge_keys_view_build;
  view_type_add(std::move(keys));

  ViewType preferences_list;
  preferences_list.name = "preferences_list";
  /* Listed with Python, four times a second at most. */
  preferences_list.min_interval = 0.25;
  preferences_list.notifiers = {NC_WM, NC_SCREEN, NC_SPACE};
  preferences_list.build = bridge_preferences_list_view_build;
  preferences_list.command = bridge_preferences_list_view_command;
  view_type_add(std::move(preferences_list));

  ViewType outliner;
  outliner.name = "outliner";
  /* Listed with Python, four times a second at most. */
  outliner.min_interval = 0.25;
  outliner.notifiers = {NC_SCENE, NC_OBJECT, NC_ID, NC_WM, NC_SPACE, NC_GEOM};
  outliner.wants = [](const wmNotifier &note) {
    /* Not as the frame changes, as during playback. */
    return note.category != NC_SCENE || note.data != ND_FRAME;
  };
  outliner.build = bridge_outliner_view_build;
  view_type_add(std::move(outliner));

  ViewType volume;
  volume.name = "volume";
  volume.notifiers = {0};
  volume.build = bridge_volume_view_build;
  volume.command = bridge_volume_view_command;
  view_type_add(std::move(volume));

  ViewType graph;
  graph.name = "graph";
  /* Read four times a second at most, as during playback. */
  graph.min_interval = 0.25;
  graph.notifiers = {NC_ANIMATION, NC_OBJECT, NC_SCENE, NC_WM, NC_SPACE};
  graph.create = bridge_canvas_create;
  graph.build = bridge_graph_view_build;
  graph.command = bridge_canvas_command<ed::graph::native_graph_edit>;
  view_type_add(std::move(graph));

  ViewType storyboard;
  storyboard.name = "storyboard";
  storyboard.min_interval = 0.1;
  storyboard.notifiers = {NC_SCENE, NC_SPACE, NC_WM, NC_IMAGE};
  storyboard.create = bridge_canvas_create;
  storyboard.build = bridge_storyboard_view_build;
  storyboard.command = bridge_canvas_command<ed::vse::native_storyboard_edit>;
  view_type_add(std::move(storyboard));

  ViewType image;
  image.name = "image";
  image.min_interval = 0.1;
  image.notifiers = {NC_IMAGE, NC_SCENE, NC_OBJECT, NC_WM, NC_SPACE, NC_BRUSH, NC_GEOM};
  image.create = bridge_canvas_create;
  image.build = bridge_image_view_build;
  image.shown = bridge_image_view_shown;
  image.command = [](bContext *C,
                     const Params &params,
                     ViewData *data,
                     const protocol::Command &command,
                     std::string &r_error) {
    /* What it changed shows in the picture too. */
    bridge_image_pixels_pending = true;
    return bridge_canvas_command<ed::image::native_image_edit>(C, params, data, command, r_error);
  };
  view_type_add(std::move(image));

  ViewType render;
  render.name = "render";
  render.notifiers = {NC_SCENE, NC_WM, NC_IMAGE};
  render.min_interval = 0.25;
  render.build = bridge_render_view_build;
  render.command = bridge_render_view_command;
  /* Stop acts on the render it is meant to stop, which holds a modal handler for as long as it
   * runs; were it to wait for that to end, it would stop nothing (R6 G1). Clear only forgets what
   * was shown. Rendering again still waits for the running render. */
  render.live = [](const protocol::Command &command) {
    return command.op() == protocol::Op::Invoke &&
           ELEM(command.target()->string_view(), "cancel", "clear");
  };
  view_type_add(std::move(render));
}

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
  bridge_image_pixels_pending = true;
  bridge_image_uvs_pending = true;
  bridge_changed = true;
}

/* -------------------------------------------------------------------- */
/** \name Notices and the Session's Log
 *
 * A touch interface has no status bar for Blender's reports, and no pointer under which a
 * disabled item could explain itself. Notices are its short messages: what a report says, why a
 * command did not run. The toolbar view carries the latest few as `notices`.
 * \{ */

struct BridgeNotice {
  int number;
  int level;
  std::string text;
  std::string button;
};
/* A standard vector: it outlives Blender's allocator, freed as the process ends. More than four
 * notices left at quitting were freed after the allocator, which crashed (found by ROUND6
 * TOUCH-3's harness). */
static std::vector<BridgeNotice> bridge_notices;
static int bridge_notice_number = 0;
static double bridge_notice_time = 0.0;

/**
 * The session's log is buffered: a line per write would dirty a page of flash each time, which
 * iOS counts against the app. Operators and reports are written at most once a second (the
 * commands just before an unexpected end must be on disk, ROUND6 SAFE-4), anything else at once,
 * and all of it when the app goes to the background and at exit.
 */
struct SessionLog {
  std::mutex mutex;
  std::vector<std::string> lines;
  /** The last line's kind and operator, and how many times in a row it came. */
  std::string last_key;
  int repeats = 1;
  double last_write = 0.0;
  int writes = 0;
};

static SessionLog &session_log()
{
  static SessionLog log;
  return log;
}

static bool session_log_enabled()
{
  /* In both interfaces (ROUND5 10E, decision 70): a log that stopped in Blender's own interface
   * hid that the app was in use, and a script there seemed never to start (2026-11-18). */
  return true;
}

/** Close the run of repeats on the last line. */
static void session_log_close_run(SessionLog &log)
{
  if (log.repeats > 1 && !log.lines.empty()) {
    log.lines.back() += " \u00d7" + std::to_string(log.repeats);
  }
  log.repeats = 1;
  log.last_key.clear();
}

/** How long an operator's or a report's line may wait to be written, in seconds. */
static constexpr double session_log_delay = 1.0;

/**
 * Where the log is. On iOS in Application Support (`Logs/platypus-session.log`), which iOS keeps:
 * the temporary folder may be emptied, and a log is most needed after the app ended unexpectedly
 * (ROUND6 SAFE-4). Elsewhere in Blender's temporary folder.
 */
static void session_log_path(char *path, const size_t path_size)
{
#if defined(WITH_APPLE_CROSSPLATFORM) && APPLE_TARGET_IOS
  if (const char *home = BLI_getenv("HOME")) {
    char folder[FILE_MAX];
    BLI_path_join(folder, sizeof(folder), home, "Library", "Application Support", "Logs");
    if (BLI_dir_create_recursive(folder)) {
      BLI_path_join(path, path_size, folder, "platypus-session.log");
      return;
    }
  }
#endif
  BLI_path_join(path, path_size, BKE_tempdir_base(), "platypus-session.log");
}

static void session_log_write(SessionLog &log)
{
  session_log_close_run(log);
  log.last_write = BLI_time_now_seconds();
  if (log.lines.empty()) {
    return;
  }
  char path[FILE_MAX];
  session_log_path(path, sizeof(path));
  /* Start again once it is large; the one before is kept beside it. */
  if (BLI_exists(path) && BLI_file_size(path) > 1024 * 1024) {
    const std::string previous = std::string(path) + ".1";
    BLI_rename_overwrite(path, previous.c_str());
  }
  std::string text;
  for (const std::string &line : log.lines) {
    text += line;
    text += '\n';
  }
  log.lines.clear();
  FILE *file = BLI_fopen(path, "a");
  if (file == nullptr) {
    return;
  }
  fwrite(text.data(), 1, text.size(), file);
  fclose(file);
  log.writes++;
}

void WM_native_ui_session_log(const char *kind, const char *text)
{
  if (!session_log_enabled()) {
    return;
  }
  SessionLog &log = session_log();
  /* Blender's thread and the interface's both write. */
  std::scoped_lock lock(log.mutex);
  /* The kind and the operator's name, up to its arguments, if any. */
  const std::string body(text ? text : "");
  const std::string key = std::string(kind) + " " + body.substr(0, body.find('('));
  if (key == log.last_key && !log.lines.empty()) {
    log.repeats++;
  }
  else {
    session_log_close_run(log);
    const std::time_t now = std::time(nullptr);
    std::tm local = {};
    localtime_r(&now, &local);
    char stamp[16] = "";
    std::strftime(stamp, sizeof(stamp), "%H:%M:%S", &local);
    log.lines.push_back(std::string(stamp) + " " + kind + " " + text);
    log.last_key = key;
  }
  const bool routine = STREQ(kind, "op") || STREQ(kind, "info");
  if (!routine || BLI_time_now_seconds() - log.last_write > session_log_delay) {
    session_log_write(log);
  }
}

void WM_native_ui_session_log_flush(const bool force)
{
  if (!session_log_enabled()) {
    return;
  }
  SessionLog &log = session_log();
  std::unique_lock lock(log.mutex, std::try_to_lock);
  if (!lock.owns_lock() || log.lines.empty()) {
    return;
  }
  if (force || BLI_time_now_seconds() - log.last_write > session_log_delay) {
    session_log_write(log);
  }
}

extern "C" void WM_native_ui_session_log_active()
{
  /* Input arrived: a key, a touch, the Pencil, a scroll, a click. Looking around a scene runs no
   * command, so without this someone only looking reads as away (ROUND5 10E). At most once a
   * minute, from any thread. */
  static std::atomic<double> last{-1000.0};
  const double now = BLI_time_now_seconds();
  double seen = last.load();
  if (now - seen < 60.0 || !last.compare_exchange_strong(seen, now)) {
    return;
  }
  WM_native_ui_session_log("active", "input");
}

extern "C" bool WM_native_ui_session_log_file(char *path, const size_t path_size)
{
  {
    SessionLog &log = session_log();
    std::scoped_lock lock(log.mutex);
    session_log_write(log);
  }
  session_log_path(path, path_size);
  return BLI_exists(path);
}

int WM_native_ui_session_log_writes()
{
  return session_log().writes;
}

extern "C" void WM_native_ui_log(const char *kind, const char *text)
{
  if (kind && text) {
    WM_native_ui_session_log(kind, text);
  }
}

void WM_native_ui_notice(const int level, const char *text, const char *button)
{
  if (text == nullptr || text[0] == '\0') {
    return;
  }
  /* What an operator reports can arrive twice, from its popup and from the log: said once. */
  const double now = BLI_time_now_seconds();
  if (!bridge_notices.empty() && bridge_notices.back().text == text &&
      now - bridge_notice_time < 1.0)
  {
    return;
  }
  bridge_notice_time = now;
  bridge_notices.push_back({++bridge_notice_number, level, text, button ? button : ""});
  if (bridge_notices.size() > 6) {
    bridge_notices.erase(bridge_notices.begin());
  }
  wm::native_ui::view_type_dirty("toolbar");
  WM_native_ui_session_log(level >= RPT_WARNING ? "warning" : "info", text);
}

static std::string bridge_notices_json()
{
  std::string json = "[";
  for (const BridgeNotice &notice : bridge_notices) {
    if (json.size() > 1) {
      json += ",";
    }
    json += "{\"number\":" + std::to_string(notice.number) + ",\"level\":\"" +
            (notice.level >= RPT_ERROR ? "error" : notice.level >= RPT_WARNING ? "warning" : "info") +
            "\",\"text\":\"" + bridge_json_escape(notice.text) + "\",\"button\":\"" +
            bridge_json_escape(notice.button) + "\"}";
  }
  return json + "]";
}

static std::string bridge_operator_unavailable(bContext *C, wmOperatorType *ot)
{
  const std::string name = WM_operatortype_name(ot, nullptr);
  bool free_message = false;
  const char *message = CTX_wm_operator_poll_msg_get(C, &free_message);
  std::string text;
  if (message && message[0]) {
    text = name + ": " + message;
  }
  else {
    /* Name the mode as the mode menu does ("Edit Mode"), not as the context enum ("Mesh Edit"). */
    const Object *ob = CTX_data_active_object(C);
    const char *mode = nullptr;
    RNA_enum_name(rna_enum_object_mode_items, ob ? int(ob->mode) : int(OB_MODE_OBJECT), &mode);
    text = name + " is not available" +
           (mode ? std::string(" in ") + IFACE_(mode) : std::string(" here"));
  }
  if (free_message) {
    MEM_delete(message);
  }
  return text;
}

/* -------------------------------------------------------------------- */
/** \name What Shows After a Command
 *
 * After each command, `bl_ui.native_reveal` names what the interface opens: the operation's
 * settings, a Properties tab, an editor, a message, or nothing, with why. The toolbar view carries
 * the latest as `reveal`, numbered so each is acted on once.
 * \{ */

static void bridge_reveal_after(bContext *C, wmOperator *op, const std::string &call)
{
#ifdef WITH_PYTHON
  if (G.background || CTX_wm_window(C) == nullptr) {
    return;
  }
  const std::string expression = "bl_ui.native_reveal.after_operator(bpy.context, \"" +
                                 bridge_json_escape(op->type->idname) + "\", \"" +
                                 bridge_json_escape(call) + "\", \"" +
                                 bridge_json_escape(WM_operatortype_name(op->type, op->ptr)) +
                                 "\")";
  const std::shared_ptr<io::serialize::Value> value = bridge_python_value(
      C, "reveal", expression.c_str());
  const io::serialize::DictionaryValue *answer = value ? value->as_dictionary_value() : nullptr;
  if (answer == nullptr) {
    return;
  }
  const std::string show(bridge_text(*answer, "show"));
  std::string json = "{\"number\":" + std::to_string(++bridge_reveal_number) + ",\"operator\":\"" +
                     bridge_json_escape(op->type->idname) + "\"";
  for (const char *key : {"show", "focus", "text", "button", "why", "level"}) {
    json += std::string(",\"") + key + "\":\"" +
            bridge_json_escape(std::string(bridge_text(*answer, key))) + "\"";
  }
  json += "}";
  bridge_reveal_json = std::move(json);
  wm::native_ui::view_type_dirty("toolbar");
  const std::string why(bridge_text(*answer, "why"));
  WM_native_ui_session_log(
      "reveal",
      (std::string(op->type->idname) + " -> " + show + (why.empty() ? "" : " (" + why + ")")).c_str());
#else
  UNUSED_VARS(C, op, call);
#endif
}

/** \} */

bool bridge_menu_popup(bContext *C, const char *menu);

/** For the Mac bridge harness: install the after-command hook the iPad interface installs, so
 * what is shown after each command can be checked without a device, its menu popups, so a key's
 * menu is asked for as a key asks for it (the `keys` scenario), and the size of Blender's own
 * interface (the `reveal` scenario). Only where no native interface is installed. */
extern "C" void WM_native_ui_test_install_hooks()
{
  static wmNativeInterface hooks;
  if (WM_native_interface() == nullptr) {
    hooks.operator_finished = WM_native_ui_operator_finished;
    hooks.state_changed = WM_native_ui_tag_changed;
    hooks.menu_popup = bridge_menu_popup;
    hooks.interface_scale = WM_native_ui_interface_scale;
    WM_native_interface_set(&hooks);
  }
}

void WM_native_ui_operator_finished(bContext *C, wmOperator *op)
{
  /* What changes the document or is kept for redo: not the view moving many times a second, nor
   * timers. */
  if ((op->type->flag & (OPTYPE_REGISTER | OPTYPE_UNDO)) == 0) {
    return;
  }
  const std::string call = WM_operator_pystring(C, op, false, true);
  bridge_reveal_after(C, op, call);
  std::string line = call;
  if (CTX_wm_window(C) && CTX_data_scene(C)) {
    line += std::string("  [") + CTX_data_mode_string(C);
    if (CTX_wm_area(C) && CTX_wm_workspace(C)) {
      if (const bToolRef *tool = WM_toolsystem_ref_from_context(C)) {
        line += std::string(", ") + tool->idname;
      }
    }
    line += "]";
  }
  WM_native_ui_session_log("op", line.c_str());
}

/** \} */


/**
 * One of Blender's menus, which a key or mouse button would open (a right-click's context menu,
 * Shift-A's Add menu, a pie), shown natively where the pointer is, as on a Mac. The native side
 * shows it from Blender's menu projection, see `BlenderMenus.swift`, and runs what is chosen.
 */
bool bridge_menu_popup(bContext *C, const char *menu)
{
  if (WM_native_ui_desktop_mode()) {
    return false;
  }
  /* Blender asked for it where its key-map matched, so it is what the desktop would draw here.
   * What the interface cannot draw (no such menu, or its poll fails), Blender's own popup draws,
   * or explains, as before the interface existed. */
  ui::native::menu_popup_asked(menu);
  if (!ui::native::menu_can_show(C, menu)) {
    WM_native_ui_session_log("popup", (std::string(menu) + " drawn by Blender").c_str());
    return false;
  }
  BridgePopup popup;
  popup.menu = menu;
  /* Its title, as Blender's popup has: "UV Mapping", "Delete". */
  if (MenuType *mt = WM_menutype_find(menu, true)) {
    popup.title = CTX_IFACE_(mt->translation_context, mt->label);
  }
  bridge_popup_show(C, std::move(popup));
  return true;
}

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
  BridgePopup popup;
  popup.title = WM_operatortype_name(op->type, op->ptr);
  popup.op_name = op->type->idname;
  popup.prop_name = RNA_property_identifier(prop);
  for (int i = 0; i < count; i++) {
    const EnumPropertyItem &item = items[i];
    if (!item.name && !item.identifier[0]) {
      continue;
    }
    const char *icon = nullptr;
    if (item.icon) {
      RNA_enum_identifier(rna_enum_icon_items, item.icon, &icon);
    }
    popup.items.push_back({item.name ? item.name : "", item.identifier, icon ? icon : ""});
  }
  if (free) {
    MEM_delete(items);
  }
  bridge_popup_show(C, std::move(popup));
  return true;
}

/** The panels #bridge_panel_popup shows natively: Rename Active Item's (F2). */
static bool bridge_panel_popup_takes(const StringRef panel)
{
  return panel == "TOPBAR_PT_name";
}

bool bridge_panel_popup(bContext *C, const char *panel)
{
  if (WM_native_ui_desktop_mode() || !bridge_panel_popup_takes(panel)) {
    return false;
  }
  BridgePopup popup;
  popup.rename = true;
  bridge_popup_show(C, std::move(popup));
  return true;
}

/* -------------------------------------------------------------------- */
/** \name What a Key Does in the Native Interface
 *
 * ROUND5 9A, decisions 51 and 52: a key Blender answers on the desktop is never swallowed. Its
 * key-map item runs as there, and what it opens shows natively (a menu, an operator's choice or
 * dialog, the rename field); or it is kept from Blender, as it would show Blender's own interface
 * over the platform's (popovers, search, toolbars, sidebars, the screen's layout), and then the
 * interface does its own version of the command where it has one, a stand-in, or says where the
 * command is. The Mac bridge harness's `keys` scenario reads every item of the 3D View's key-maps
 * through the `keys` view and fails when one is left without an answer.
 * \{ */

/**
 * The interface's own version of a command kept from Blender, by the operator and, where needed,
 * its properties: one of the commands of `release/ios/key_stand_ins.txt`, which the shell carries
 * out (`DocumentWindow.swift`, #pullMenuPopup) and the harness checks against. Only what the shell
 * already does from a button: none is made up for a key. Null where it has none.
 */
static const char *bridge_key_stand_in(const wmKeyMapItem *kmi, const wmOperatorType *ot)
{
  const StringRef idname = ot->idname;
  if (ELEM(idname, "WM_OT_search_menu", "WM_OT_search_operator", "WM_OT_search_single_menu")) {
    return "search";
  }
  if (idname == "SCREEN_OT_userpref_show") {
    return "settings";
  }
  if (idname == "SCREEN_OT_screen_full_area") {
    return "interface";
  }
  if (idname == "WM_OT_context_toggle" && kmi->ptr &&
      RNA_struct_find_property(kmi->ptr, "data_path") &&
      RNA_string_get(kmi->ptr, "data_path") == "space_data.show_region_ui")
  {
    return "properties";
  }
  if (idname == "SCREEN_OT_region_toggle" && kmi->ptr &&
      RNA_struct_find_property(kmi->ptr, "region_type") &&
      RNA_enum_get(kmi->ptr, "region_type") == RGN_TYPE_UI)
  {
    return "properties";
  }
  /* Right-click where the mode's context menu is a panel (Sculpt, the paint modes): what a long
   * press on the viewport shows there (ROUND5 9E.2). */
  if (idname == "WM_OT_call_panel" && kmi->ptr && RNA_struct_find_property(kmi->ptr, "name") &&
      StringRef(RNA_string_get(kmi->ptr, "name")).endswith("_context_menu"))
  {
    return "context";
  }
  return nullptr;
}

/**
 * A command kept from Blender, by the name a person knows it by (ROUND5 9E.3), never a generic
 * operator's ("Call Asset Shelf Popover", "Context Enum Menu"): a sidebar, toolbar or setting by
 * the property \a kmi's key changes, as "Toolbar" (T) or "Stroke Method"; a panel or menu by its
 * label; the asset shelf as "Asset Shelf"; an editor switch by the editor; otherwise the
 * operator's own name, as "Batch Rename".
 */
static std::string bridge_key_command_name(bContext *C, const wmKeyMapItem *kmi, wmOperatorType *ot)
{
  const StringRef idname = ot->idname;
  if (kmi->ptr && RNA_struct_find_property(kmi->ptr, "data_path")) {
    const std::string path = RNA_string_get(kmi->ptr, "data_path");
    if (C && !path.empty()) {
      PointerRNA context = RNA_pointer_create_discrete(nullptr, RNA_Context, C);
      PointerRNA owner;
      PropertyRNA *prop = nullptr;
      if (RNA_path_resolve_property(&context, path.c_str(), &owner, &prop) && prop) {
        const char *name = RNA_property_ui_name(prop);
        if (name && name[0]) {
          return name;
        }
      }
    }
    /* A path that does not resolve here (a key-map pointing at another mode's setting): its last
     * name, as Blender shows a property's identifier, "stroke_method" as "Stroke Method". */
    std::string name = path.substr(path.find_last_of('.') == std::string::npos ?
                                       0 :
                                       path.find_last_of('.') + 1);
    bool word_start = true;
    for (char &c : name) {
      if (c == '_') {
        c = ' ';
        word_start = true;
      }
      else {
        c = word_start ? char(toupper(c)) : c;
        word_start = false;
      }
    }
    if (!name.empty()) {
      return name;
    }
  }
  if (idname == "WM_OT_call_asset_shelf_popover") {
    return IFACE_("Asset Shelf");
  }
  if (idname == "SCREEN_OT_space_type_set_or_cycle" && kmi->ptr &&
      RNA_struct_find_property(kmi->ptr, "space_type"))
  {
    const char *editor = nullptr;
    PropertyRNA *prop = RNA_struct_find_property(kmi->ptr, "space_type");
    if (RNA_property_enum_name_gettexted(
            C, kmi->ptr, prop, RNA_property_enum_get(kmi->ptr, prop), &editor) &&
        editor)
    {
      return fmt::format("Switching this area to the {}", editor);
    }
  }
  return WM_operatortype_name(ot, kmi->ptr);
}

/**
 * The file command an operator is in a document window (ROUND5 9D.2, decision 61): its invoke
 * takes the document's route, see #wmDocumentCommand and `tests/ios/test_document_identity.py`.
 * Null for anything else.
 */
static const char *bridge_document_command(const StringRef idname)
{
  static const Map<StringRef, const char *> commands = {
      {"WM_OT_read_homefile", "new"},
      {"WM_OT_read_factory_settings", "new"},
      {"WM_OT_open_mainfile", "open"},
      {"WM_OT_recover_last_session", "open"},
      {"WM_OT_recover_auto_save", "open"},
      {"WM_OT_revert_mainfile", "revert"},
      {"WM_OT_save_mainfile", "save"},
      {"WM_OT_save_as_mainfile", "save_as"},
      {"WM_OT_quit_blender", "quit"},
  };
  return commands.lookup_default(idname, nullptr);
}

bool WM_native_ui_is_document_command(const char *idname)
{
  return idname && bridge_document_command(idname) != nullptr;
}

/** The file menus a key opens, by the command a document window does instead: File › New and
 * Open Recent take the route at once; the File context menu (F4) shows, its commands routed. */
static const char *bridge_document_menu_command(const StringRef menu)
{
  if (menu == "TOPBAR_MT_file_new") {
    return "new";
  }
  if (menu == "TOPBAR_MT_file_open_recent") {
    return "open";
  }
  if (menu == "TOPBAR_MT_file_context_menu") {
    return "menu";
  }
  return nullptr;
}

WMNativeKeyAnswer WM_native_ui_keymap_item_answer(bContext *C, const wmKeyMapItem *kmi)
{
  using Kind = WMNativeKeyAnswer::Kind;
  WMNativeKeyAnswer answer;
  if (WM_native_ui_desktop_mode() || kmi->idname[0] == '\0') {
    return answer;
  }
  wmOperatorType *ot = WM_operatortype_find(kmi->idname, true);
  if (ot == nullptr) {
    return answer;
  }
  const StringRef idname = ot->idname;
  bool hidden = false;
  if (const char *command = bridge_document_command(idname)) {
    answer.kind = Kind::Document;
    answer.command = command;
    return answer;
  }
  if (idname == "WM_OT_call_menu" && kmi->ptr && RNA_struct_find_property(kmi->ptr, "name")) {
    const std::string menu = RNA_string_get(kmi->ptr, "name");
    if (const char *command = bridge_document_menu_command(menu)) {
      answer.kind = Kind::Document;
      answer.command = command;
      if (answer.command == "menu") {
        answer.menu = menu;
      }
      else {
        answer.kept = true;
      }
      return answer;
    }
  }
  if (ELEM(idname, "WM_OT_call_menu", "WM_OT_call_menu_pie")) {
    answer.kind = Kind::Menu;
    if (kmi->ptr && RNA_struct_find_property(kmi->ptr, "name")) {
      answer.menu = RNA_string_get(kmi->ptr, "name");
    }
    return answer;
  }
  if (idname == "WM_OT_call_panel") {
    /* The panels with a native answer run, as F2's Rename Active Item; other panels would show
     * Blender's popover. */
    const std::string panel = kmi->ptr && RNA_struct_find_property(kmi->ptr, "name") ?
                                  RNA_string_get(kmi->ptr, "name") :
                                  std::string();
    if (bridge_panel_popup_takes(panel)) {
      answer.kind = Kind::Rename;
      return answer;
    }
    hidden = true;
  }
  /* What would show Blender's own interface over the platform's. */
  static const Set<StringRef> shows_interface = {
      "WM_OT_call_asset_shelf_popover",
      "WM_OT_context_menu_enum",
      "WM_OT_context_pie_enum",
      "WM_OT_search_menu",
      "WM_OT_search_operator",
      "WM_OT_search_single_menu",
      "WM_OT_toolbar",
      "WM_OT_toolbar_fallback_pie",
      "WM_OT_toolbar_prompt",
      "WM_OT_batch_rename",
      "SCREEN_OT_region_toggle",
      "SCREEN_OT_region_flip",
      "SCREEN_OT_repeat_history",
      "SCREEN_OT_screen_full_area",
      "SCREEN_OT_space_type_set_or_cycle",
      "SCREEN_OT_workspace_cycle",
      "SCREEN_OT_userpref_show",
      "SCREEN_OT_info_log_show",
  };
  if (shows_interface.contains(idname)) {
    hidden = true;
  }
  /* Sidebars and toolbars, as N and T show them. */
  if (idname == "WM_OT_context_toggle" && kmi->ptr &&
      RNA_struct_find_property(kmi->ptr, "data_path") &&
      StringRef(RNA_string_get(kmi->ptr, "data_path")).startswith("space_data.show_region_"))
  {
    hidden = true;
  }
  /* A search through an enum's items, which has no native form. */
  if (ot->invoke == WM_enum_search_invoke) {
    hidden = true;
  }
  if (!hidden) {
    /* An operator that asks before it runs: its choice shows natively (`bridge_enum_popup`), its
     * properties in the native dialog or the last operation's strip (`props_dialog`,
     * `redo_show`). */
    if (ot->invoke == WM_menu_invoke) {
      answer.kind = Kind::Choice;
    }
    else if (ELEM(ot->invoke,
                  WM_operator_props_popup,
                  WM_operator_props_popup_call,
                  WM_operator_props_popup_confirm))
    {
      answer.kind = Kind::Dialog;
    }
    return answer;
  }
  if (const char *command = bridge_key_stand_in(kmi, ot)) {
    answer.kind = Kind::StandIn;
    answer.command = command;
    return answer;
  }
  answer.kind = Kind::Says;
  if (C) {
    answer.text = fmt::format("{} is not in the iPad interface. It is in the Desktop Interface.",
                              bridge_key_command_name(C, kmi, ot));
  }
  return answer;
}

bool WM_native_ui_keymap_item_hidden(const wmKeyMapItem *kmi)
{
  return WM_native_ui_keymap_item_answer(nullptr, kmi).hidden();
}

void WM_native_ui_keymap_item_skipped(bContext *C, const wmKeyMapItem *kmi)
{
  const WMNativeKeyAnswer answer = WM_native_ui_keymap_item_answer(C, kmi);
  const std::string key = WM_keymap_item_to_string(kmi, false).value_or(std::string("?"));
  if (answer.kind == WMNativeKeyAnswer::Kind::Document) {
    /* File › New's and Open Recent's keys: the document's route (ROUND5 9D.4). */
    WM_native_ui_session_log(
        "key", (key + " document " + answer.command + " " + kmi->idname).c_str());
    const wmNativeInterface *native = WM_native_interface();
    if (native && native->document_command) {
      native->document_command(
          C, answer.command == "new" ? wmDocumentCommand::New : wmDocumentCommand::Open, "");
    }
    return;
  }
  if (answer.kind == WMNativeKeyAnswer::Kind::StandIn) {
    WM_native_ui_session_log(
        "key", (key + " stand-in " + answer.command + " " + kmi->idname).c_str());
    BridgePopup popup;
    popup.command = answer.command;
    bridge_popup_show(C, std::move(popup));
    return;
  }
  /* A key always says something: Says, or a key-map item that changed to run since it matched. */
  WM_native_ui_session_log("key", (key + " hidden " + kmi->idname).c_str());
  WM_native_ui_notice(RPT_INFO,
                      answer.text.empty() ?
                          (std::string(kmi->idname) + " did not run in the iPad interface").c_str() :
                          answer.text.c_str());
}

/** \} */

void bridge_apply_viewport_preferences(bContext *C)
{
  if (C == nullptr) {
    return;
  }

  bool refresh_gizmo_map = bridge_gizmo_refresh_pending;

  /* The person's click, drag and motion thresholds and tooltips are theirs: a finger's distances
   * are chosen where its events are made, in points (ROUND6 TOUCH-4, #WM_event_drag_threshold). */

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

/**
 * Draw Blender's interface at its size now, see #WM_native_ui_interface_scale: what Preferences ›
 * Interface › Resolution Scale does as it changes (`rna_userdef_gpu_update`), without marking the
 * preferences changed, as Blender's own preferences are not.
 */
static void bridge_interface_resize(bContext *C)
{
  if (wmWindow *win = CTX_wm_window(C); win && win->runtime->ghostwin) {
    WM_window_dpi_set_userdef(win);
  }
  /* Fonts are kept for each size: without this many would be loaded. */
  BLF_cache_clear();
  /* Everything drawn again, and the regions' sizes worked out again. */
  WM_main_add_notifier(NC_WINDOW, nullptr);
  WM_main_add_notifier(NC_SCREEN | NA_EDITED, nullptr);
}

/**
 * The interface's size as Blender has it, in the session's log and in
 * `<temp>/interface-measure.txt`, for a script to read off the device (ROUND5 9C.1): the
 * preferences' `system.dpi`, `system.pixel_size` and `view.ui_scale`, and the app's own size.
 */
void bridge_interface_measure()
{
  const std::string line = fmt::format(
      "dpi {} pixel_size {} ui_scale {:.3f} scale_factor {:.3f} desktop {} desktop_size {:.0f} %",
      U.dpi,
      U.pixelsize,
      U.ui_scale,
      U.scale_factor,
      bridge_desktop_ui ? "on" : "off",
      bridge_desktop_scale.load() * 100.0f);
  WM_native_ui_session_log("interface", line.c_str());
  char path[FILE_MAX];
  BLI_path_join(path, sizeof(path), BKE_tempdir_base(), "interface-measure.txt");
  if (FILE *file = BLI_fopen(path, "a")) {
    fprintf(file, "%s\n", line.c_str());
    fclose(file);
  }
}

float WM_native_ui_interface_scale()
{
  /* The native interface's own viewport (gizmos, overlay text) keeps its size. */
  return bridge_desktop_ui ? bridge_desktop_scale.load() : 1.0f;
}

/** Set the size of Blender's own interface, clamped to 50 to 125 %, see #bridge_desktop_scale. */
void bridge_desktop_scale_set(bContext *C, const float scale)
{
  const float clamped = std::clamp(scale, 0.5f, 1.25f);
  if (std::abs(clamped - bridge_desktop_scale.load()) < 1e-4f) {
    return;
  }
  bridge_desktop_scale = clamped;
  WM_native_ui_session_log("interface", fmt::format("desktop size {:.0f} %", clamped * 100.0f).c_str());
  if (bridge_desktop_ui) {
    bridge_interface_resize(C);
  }
  /* The settings view tells the interface, which keeps it, also when the Window menu changed it. */
  WM_event_add_notifier(C, NC_WM | ND_DATACHANGED, nullptr);
  views::view_type_dirty("settings");
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
  /* The settings view tells the interface, also when Blender's own Window menu switched. */
  WM_event_add_notifier(C, NC_WM | ND_DATACHANGED, nullptr);
  /* Blender's own interface has a size of its own (#WM_native_ui_interface_scale). */
  bridge_interface_resize(C);
}

/**
 * The UV Editor's Edit UVs in Desktop Interface (ROUND5 9B.6, decision 55): Blender's own interface
 * on the document's UV Editing workspace, where UVs are selected and moved by hand. Where the
 * document has none, it is added from the startup file, as the desktop's + › General › UV Editing
 * adds it (`WORKSPACE_OT_append_activate`). This changes the document's workspaces, as the
 * desktop's tabs do. Return to iPad Interface comes back as from any workspace.
 */
void bridge_desktop_uv_editing(bContext *C)
{
  bridge_interface_set(C, true);
  wmWindow *win = CTX_wm_window(C);
  if (win == nullptr) {
    return;
  }
  Main *bmain = CTX_data_main(C);
  const char *name = "UV Editing";
  if (WorkSpace *workspace = reinterpret_cast<WorkSpace *>(
          BKE_libblock_find_name(bmain, ID_WS, name, nullptr)))
  {
    /* Changing workspace changes the context: as Blender's tabs do it, once this command ends. */
    WM_event_add_notifier(C, NC_SCREEN | ND_WORKSPACE_SET, workspace);
    WM_native_ui_session_log("interface", "desktop, UV Editing");
    return;
  }
  PointerRNA properties = WM_operator_properties_create("WORKSPACE_OT_append_activate");
  RNA_string_set(&properties, "idname", name);
  RNA_string_set(&properties, "filepath", BLO_EMBEDDED_STARTUP_BLEND);
  const wmOperatorStatus status = WM_operator_name_call(
      C, "WORKSPACE_OT_append_activate", wm::OpCallContext::ExecDefault, &properties, nullptr);
  WM_operator_properties_free(&properties);
  if (status & OPERATOR_FINISHED) {
    WM_native_ui_session_log("interface", "desktop, UV Editing added from the startup file");
  }
  else {
    WM_native_ui_notice(RPT_WARNING, "The UV Editing workspace could not be added");
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

/** Window › Interface Size: its sizes, the current one marked. 67 % is Blender's size on a Mac. */
static const EnumPropertyItem bridge_interface_scale_items[] = {
    {50, "50", ICON_NONE, "50 %", ""},
    {60, "60", ICON_NONE, "60 %", ""},
    {67, "67", ICON_NONE, "67 %", "The size of Blender on a Mac"},
    {75, "75", ICON_NONE, "75 %", ""},
    {85, "85", ICON_NONE, "85 %", ""},
    {100, "100", ICON_NONE, "100 %", ""},
    {125, "125", ICON_NONE, "125 %", ""},
    {0, nullptr, 0, nullptr, nullptr},
};

/** A size as a factor: 67 % is two thirds, as a Mac's 144 of the iPad's 216 DPI. */
static float bridge_interface_scale_factor(const int percent)
{
  return percent == 67 ? 2.0f / 3.0f : float(percent) / 100.0f;
}

static const EnumPropertyItem *bridge_interface_scale_itemf(bContext * /*C*/,
                                                            PointerRNA * /*ptr*/,
                                                            PropertyRNA * /*prop*/,
                                                            bool *r_free)
{
  EnumPropertyItem *items = nullptr;
  int count = 0;
  for (const EnumPropertyItem *item = bridge_interface_scale_items; item->identifier; item++) {
    EnumPropertyItem copy = *item;
    if (std::abs(bridge_interface_scale_factor(item->value) - bridge_desktop_scale.load()) < 1e-3f) {
      copy.icon = ICON_CHECKMARK;
    }
    RNA_enum_item_add(&items, &count, &copy);
  }
  RNA_enum_item_end(&items, &count);
  *r_free = true;
  return items;
}

static wmOperatorStatus bridge_interface_scale_exec(bContext *C, wmOperator *op)
{
  bridge_desktop_scale_set(C, bridge_interface_scale_factor(RNA_enum_get(op->ptr, "scale")));
  return OPERATOR_FINISHED;
}

void WM_OT_native_interface_scale(wmOperatorType *ot)
{
  ot->name = "Interface Size";
  ot->idname = "WM_OT_native_interface_scale";
  ot->description =
      "The size of Blender's own interface on the iPad; the iPad interface keeps its own. Apple "
      "Pencil and a trackpad are not affected by it, a finger may find small sizes hard to tap";
  ot->exec = bridge_interface_scale_exec;
  ot->flag = OPTYPE_INTERNAL;
  PropertyRNA *prop = RNA_def_enum(
      ot->srna, "scale", bridge_interface_scale_items, 75, "Size", "The interface's size");
  RNA_def_enum_funcs(prop, bridge_interface_scale_itemf);
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);
  ot->prop = prop;
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

/**
 * Bring a 3D View to \a win for the native interface to show full screen: out of another
 * editor's full screen, or a maximized one with its headers, which a file may have been saved
 * with, or to a workspace with one. Whether it is ready.
 */
static bool bridge_view3d_ensure(bContext *C, wmWindow *win, bScreen *screen)
{
  const bool found = bridge_find_view3d_area(screen) != nullptr;
  if (found && screen->state != SCREENMAXIMIZED) {
    return true;
  }
  if (screen->state != SCREENNORMAL) {
    for (ScrArea &area : screen->areabase) {
      if (!ED_area_is_global(&area)) {
        ED_screen_full_restore(C, &area);
        break;
      }
    }
    return false;
  }
  /* A workspace in the same mode, as changing to another changes the mode too. */
  const Object *object = CTX_data_active_object(C);
  const int mode = object ? object->mode : OB_MODE_OBJECT;
  Main *bmain = CTX_data_main(C);
  for (WorkSpace &workspace : bmain->workspaces) {
    const WorkSpaceLayout *layout = BKE_workspace_active_layout_for_workspace_get(
        win->workspace_hook, &workspace);
    if (workspace.object_mode == mode && layout &&
        bridge_find_view3d_area(BKE_workspace_layout_screen_get(layout)))
    {
      ED_workspace_change(&workspace, C, CTX_wm_manager(C), win);
      return false;
    }
  }
  /* None has one: the largest editor becomes one. */
  ScrArea *largest = nullptr;
  for (ScrArea &area : screen->areabase) {
    if (!ED_area_is_global(&area) &&
        (largest == nullptr || area.winx * area.winy > largest->winx * largest->winy))
    {
      largest = &area;
    }
  }
  if (largest != nullptr) {
    CTX_wm_area_set(C, largest);
    ED_area_newspace(C, largest, SPACE_VIEW3D, false);
  }
  return false;
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
  if (win != nullptr && screen != nullptr && !bridge_view3d_ensure(C, win, screen))
  {
    /* The screen changed: full screen and its regions follow on the next pass. */
    bridge_context_pop(C, context_store);
    return;
  }
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

/* How far from the window's top the native top bar and the tool settings row reach, in window
 * pixels. Pixels, not a fraction of the height: the window's height changes as it is resized, and
 * the shell and Blender may hold different heights for a few frames while it does. */
static std::atomic<float> bridge_top_bar = 0.0f;

extern "C" void WM_native_ui_top_bar_set(const float pixels)
{
  if (bridge_top_bar.exchange(pixels) != pixels) {
    bridge_navigation_redraw_pending.store(true);
  }
}

int WM_native_ui_top_bar_ymax(const wmWindow *win, const ARegion *region)
{
  /* The navigation gizmo sits below the top bar, in region pixels. */
  return WM_window_native_pixel_y(win) - int(bridge_top_bar.load()) - region->winrct.ymin;
}

/* How far from the window's bottom the native controls along the bottom reach, in window pixels. */
extern "C" void WM_native_ui_bottom_tray_set(const float pixels)
{
  if (bridge_bottom_tray.exchange(pixels) != pixels) {
    bridge_navigation_redraw_pending.store(true);
  }
}

/* The top of the highest control standing along the window's bottom edge, in window pixels from
 * the bottom (ROUND5 9G.5). Framing keeps clear of it; the navigation gizmo keeps to the tray. */
static std::atomic<float> bridge_bottom_controls = 0.0f;

extern "C" void WM_native_ui_bottom_controls_set(const float pixels)
{
  bridge_bottom_controls.store(pixels);
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

/* Where a sidebar's slide ends (ROUND5 14B): framing reads these, never a value on the way. */
static std::atomic<float> bridge_viewport_final_leading_inset{0.0f};
static std::atomic<float> bridge_viewport_final_trailing_inset{0.0f};

extern "C" void WM_native_ui_viewport_insets_step(const float leading,
                                                  const float trailing,
                                                  const float final_leading,
                                                  const float final_trailing)
{
  bridge_viewport_final_leading_inset.store(final_leading);
  bridge_viewport_final_trailing_inset.store(final_trailing);
  const bool changed = bridge_viewport_leading_inset.exchange(leading) != leading;
  if (bridge_viewport_trailing_inset.exchange(trailing) != trailing || changed) {
    bridge_viewport_insets_changed.store(true);
    GHOST_mailbox_published();
  }
}

extern "C" void WM_native_ui_viewport_insets_set(const float leading, const float trailing)
{
  WM_native_ui_viewport_insets_step(leading, trailing, leading, trailing);
}

float WM_native_ui_viewport_leading_inset()
{
  return bridge_viewport_leading_inset.load();
}

float WM_native_ui_viewport_trailing_inset()
{
  return bridge_viewport_trailing_inset.load();
}

/** The area of \a win's screen that holds \a region, or null. */
static ScrArea *bridge_area_of_region(const wmWindow *win, const ARegion *region)
{
  const bScreen *screen = win ? WM_window_get_active_screen(win) : nullptr;
  if (screen == nullptr || region == nullptr) {
    return nullptr;
  }
  ED_screen_areas_iter (win, screen, area) {
    if (BLI_findindex(&area->regionbase, region) != -1) {
      return area;
    }
  }
  return nullptr;
}

/* -------------------------------------------------------------------- */
/** \name The Navigation Gizmos' Parts (ROUND5 12D, decisions 78 and 79)
 *
 * Where each navigation gizmo's parts were placed when its region was last drawn, in GHOST's
 * client pixels of each window, for the window to ask on the main thread which part a touch began
 * on: a finger or the Pencil on a button is given to Blender as a pointer. Written on Blender's
 * loop after each draw, read under the lock.
 * \{ */

struct BridgeNavigationTarget {
  const void *ghost_window;
  NavigationGizmoPart part;
  float x;
  float y;
  float radius;

  bool operator==(const BridgeNavigationTarget &other) const
  {
    return ghost_window == other.ghost_window && part == other.part && x == other.x &&
           y == other.y && radius == other.radius;
  }
};

static std::mutex bridge_navigation_targets_mutex;
/* A standard vector: it outlives Blender's allocator, freed as the process ends. */
static std::vector<BridgeNavigationTarget> bridge_navigation_targets;

/** The navigation gizmo's parts in \a region of \a area, whichever editor it is. */
static int bridge_navigation_parts(const ScrArea *area,
                                   const ARegion *region,
                                   NavigationGizmoPlace r_parts[])
{
  if (area == nullptr) {
    return 0;
  }
  if (area->spacetype == SPACE_VIEW3D) {
    return ED_view3d_navigate_gizmo_parts(area, region, r_parts);
  }
  return ui::UI_view2d_navigate_gizmo_parts(area, region, r_parts);
}

static void bridge_touch_zones_update(wmWindowManager *wm);

void WM_native_ui_navigation_parts_update(bContext *C)
{
  wmWindowManager *wm = CTX_wm_manager(C);
  if (wm == nullptr) {
    return;
  }
  std::vector<BridgeNavigationTarget> targets;
  for (wmWindow &win : wm->windows) {
    const bScreen *screen = WM_window_get_active_screen(&win);
    if (screen == nullptr || win.runtime->ghostwin == nullptr) {
      continue;
    }
    ED_screen_areas_iter (&win, screen, area) {
      for (const ARegion &region : area->regionbase) {
        if (region.regiontype != RGN_TYPE_WINDOW || region.winx <= 1 || region.winy <= 1) {
          continue;
        }
        NavigationGizmoPlace parts[NAVIGATION_GIZMO_PARTS_MAX];
        const int count = bridge_navigation_parts(area, &region, parts);
        for (int i = 0; i < count; i++) {
          /* To GHOST's client pixels, as its touches come, the way the event system turns them
           * back. */
          int xy[2] = {int(roundf(region.winrct.xmin + parts[i].center[0])),
                       int(roundf(region.winrct.ymin + parts[i].center[1]))};
          int edge[2] = {int(roundf(region.winrct.xmin + parts[i].center[0] + parts[i].radius)),
                         xy[1]};
          wm_cursor_position_to_ghost_client_coords(&win, &xy[0], &xy[1]);
          wm_cursor_position_to_ghost_client_coords(&win, &edge[0], &edge[1]);
          targets.push_back({win.runtime->ghostwin,
                          parts[i].part,
                          float(xy[0]),
                          float(xy[1]),
                          float(std::max(1, edge[0] - xy[0]))});
        }
      }
    }
  }
  bool changed = false;
  {
    std::lock_guard lock(bridge_navigation_targets_mutex);
    changed = targets != bridge_navigation_targets;
    if (changed) {
      bridge_navigation_targets = std::move(targets);
    }
  }
  if (changed) {
    /* The toolbar says where the gizmo is, which the shell keeps clear of. */
    views::view_type_dirty("toolbar");
  }
  bridge_touch_zones_update(wm);
}

extern "C" bool WM_native_ui_navigation_drawn(const void *ghost_window,
                                              const int part,
                                              float r_center_radius[3])
{
  std::lock_guard lock(bridge_navigation_targets_mutex);
  for (const BridgeNavigationTarget &target : bridge_navigation_targets) {
    if (target.ghost_window == ghost_window && int(target.part) == part) {
      r_center_radius[0] = target.x;
      r_center_radius[1] = target.y;
      r_center_radius[2] = target.radius;
      return true;
    }
  }
  return false;
}

static int bridge_navigation_part_at(const void *ghost_window, const int x, const int y)
{
  std::lock_guard lock(bridge_navigation_targets_mutex);
  for (const BridgeNavigationTarget &target : bridge_navigation_targets) {
    if (target.ghost_window == ghost_window &&
        (x - target.x) * (x - target.x) + (y - target.y) * (y - target.y) <=
            target.radius * target.radius)
    {
      return int(target.part);
    }
  }
  return int(NavigationGizmoPart::None);
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name What a Finger Meets (ROUND5 13A, decision 84)
 *
 * For each window, after each draw: every place a touch can begin, in the order Blender would
 * send an event there (the popups on top first, the newest first; then each area's overlapping
 * regions, then the others, as #ED_area_find_region_xy_visual looks), with what kind of place it
 * is, whether it scrolls now, and its interactive buttons with the directions each takes for
 * itself. The window asks it on the main thread as a finger lands (#WM_native_ui_touch_at);
 * Blender's own data is never read off its loop.
 * \{ */

#if defined(__clang__)
#  pragma clang diagnostic push
#  pragma clang diagnostic error "-Wswitch"
#elif defined(__GNUC__)
#  pragma GCC diagnostic push
#  pragma GCC diagnostic error "-Wswitch"
#endif

/** The kind of place a region's main area is, by its editor: a closed list, so a new editor fails
 * the build until it is placed (ROUND5 13A.2). */
static NativeTouchKind bridge_touch_main_kind(const eSpace_Type space)
{
  switch (space) {
    case SPACE_VIEW3D:
      return NativeTouchKind::View3D;
    /* Canvases: what a finger draws on, pans or zooms in. */
    case SPACE_IMAGE:
    case SPACE_NODE:
    case SPACE_GRAPH:
    case SPACE_ACTION:
    case SPACE_NLA:
    case SPACE_SEQ:
    case SPACE_CLIP:
      return NativeTouchKind::Canvas;
    /* Buttons, panels, lists and text: interface, which a finger presses and scrolls. */
    case SPACE_PROPERTIES:
    case SPACE_USERPREF:
    case SPACE_TOPBAR:
    case SPACE_STATUSBAR:
    case SPACE_OUTLINER:
    case SPACE_FILE:
    case SPACE_INFO:
    case SPACE_TEXT:
    case SPACE_CONSOLE:
    case SPACE_SPREADSHEET:
    case SPACE_SCRIPT:
    case SPACE_EMPTY:
      return NativeTouchKind::Interface;
  }
  return NativeTouchKind::Interface;
}

/** The kind of place a region is: its editor's main kind for the main region, a canvas for a
 * preview, interface for every region of buttons (ROUND5 13A.2). */
static NativeTouchKind bridge_touch_region_kind(const eSpace_Type space, const eRegion_Type type)
{
  switch (type) {
    case RGN_TYPE_WINDOW:
      return bridge_touch_main_kind(space);
    case RGN_TYPE_PREVIEW:
      return NativeTouchKind::Canvas;
    case RGN_TYPE_HEADER:
    case RGN_TYPE_CHANNELS:
    case RGN_TYPE_TEMPORARY:
    case RGN_TYPE_UI:
    case RGN_TYPE_TOOLS:
    case RGN_TYPE_TOOL_PROPS:
    case RGN_TYPE_HUD:
    case RGN_TYPE_NAV_BAR:
    case RGN_TYPE_EXECUTE:
    case RGN_TYPE_FOOTER:
    case RGN_TYPE_TOOL_HEADER:
    case RGN_TYPE_ASSET_SHELF:
    case RGN_TYPE_ASSET_SHELF_HEADER:
      return NativeTouchKind::Interface;
    case RGN_TYPE_XR:
      return NativeTouchKind::None;
  }
  return NativeTouchKind::None;
}

#if defined(__clang__)
#  pragma clang diagnostic pop
#elif defined(__GNUC__)
#  pragma GCC diagnostic pop
#endif

/** A place a touch can begin, in Blender's window pixels. A standard vector inside: the map
 * outlives Blender's allocator, freed as the process ends. */
struct BridgeTouchZone {
  const void *ghost_window = nullptr;
  /** The window's height and pixel size, to read GHOST's client pixels. */
  int window_height = 0;
  float pixel_size = 1.0f;
  rcti rect = {};
  NativeTouchKind kind = NativeTouchKind::None;
  bool scroll_x = false;
  bool scroll_y = false;
  /** An overlapping header: only where its buttons are (within Blender's margin). */
  bool buttons_only = false;
  /** An overlapping sidebar or toolbar: only over its contents, and its tabs. */
  bool contents_only = false;
  rcti contents = {};
  rcti tabs = {};
  std::vector<ui::TouchButton> buttons;
  std::string where;
};

static std::mutex bridge_touch_mutex;
static std::vector<BridgeTouchZone> bridge_touch_zones;

/**
 * What a finger landing in a window needs to know besides the place (ROUND6 TOUCH-1, TOUCH-2): an
 * operator is waiting there, and a gizmo other than the navigation gizmo is highlighted under
 * Blender's cursor, which is at \a cursor (GHOST's client pixels). Noted on each pass of the loop.
 */
struct BridgeTouchWindow {
  const void *ghost_window = nullptr;
  bool modal = false;
  bool gizmo = false;
  int cursor[2] = {0, 0};
};
static std::vector<BridgeTouchWindow> bridge_touch_windows;

/** A highlighted gizmo of \a win's 3D Views that is not a navigation gizmo's: a handle a finger's
 * drag can take. */
static bool bridge_touch_gizmo_highlighted(wmWindow &win, const bScreen &screen)
{
  ED_screen_areas_iter (&win, &screen, area) {
    if (area->spacetype != SPACE_VIEW3D) {
      continue;
    }
    for (ARegion &region : area->regionbase) {
      if (region.regiontype != RGN_TYPE_WINDOW || region.runtime == nullptr ||
          region.runtime->gizmo_map == nullptr)
      {
        continue;
      }
      const wmGizmo *gz = wm_gizmomap_highlight_get(region.runtime->gizmo_map);
      if (gz && gz->parent_gzgroup && gz->parent_gzgroup->type &&
          !StringRef(gz->parent_gzgroup->type->idname).endswith("GGT_navigate"))
      {
        return true;
      }
    }
  }
  return false;
}

static bool bridge_touch_zone_has(const BridgeTouchZone &zone, const int xy[2])
{
  if (!BLI_rcti_isect_pt_v(&zone.rect, xy)) {
    return false;
  }
  if (zone.buttons_only) {
    rcti near;
    BLI_rcti_init_pt_radius(&near, xy, int(UI_REGION_OVERLAP_MARGIN));
    for (const ui::TouchButton &button : zone.buttons) {
      if (BLI_rcti_isect(&button.rect, &near, nullptr)) {
        return true;
      }
    }
    return false;
  }
  if (zone.contents_only) {
    return BLI_rcti_isect_pt_v(&zone.contents, xy) || BLI_rcti_isect_pt_v(&zone.tabs, xy);
  }
  return true;
}

static void bridge_touch_zone_add(std::vector<BridgeTouchZone> &zones,
                                  const wmWindow &win,
                                  const ScrArea *area,
                                  const ARegion &region)
{
  if (region.runtime == nullptr || !region.runtime->visible || region.winx <= 1 ||
      region.winy <= 1 || (region.flag & RGN_FLAG_HIDDEN))
  {
    return;
  }
  const eSpace_Type space = area ? eSpace_Type(area->spacetype) : SPACE_EMPTY;
  const eRegion_Type type = eRegion_Type(region.regiontype);
  BridgeTouchZone zone;
  zone.ghost_window = win.runtime->ghostwin;
  zone.window_height = win.sizey;
  zone.pixel_size = static_cast<GHOST_IWindow *>(win.runtime->ghostwin)->getNativePixelSize();
  zone.rect = region.winrct;
  zone.kind = area ? bridge_touch_region_kind(space, type) : NativeTouchKind::Interface;
  if (zone.kind == NativeTouchKind::None) {
    return;
  }
  if (area == nullptr) {
    zone.where = "MENU";
    zone.scroll_y = ui::region_popup_scrolls(&region);
  }
  else {
    const char *space_name = "";
    const char *region_name = "";
    RNA_enum_identifier(rna_enum_space_type_items, space, &space_name);
    RNA_enum_identifier(rna_enum_region_type_items, type, &region_name);
    zone.where = std::string(space_name) + " " + region_name;
    /* Scrolls along an axis when its content is longer than the region and the axis is free. */
    const View2D &v2d = region.v2d;
    zone.scroll_x = !(v2d.keepofs & V2D_LOCKOFS_X) &&
                    BLI_rctf_size_x(&v2d.tot) > BLI_rctf_size_x(&v2d.cur) + 1.0f;
    zone.scroll_y = !(v2d.keepofs & V2D_LOCKOFS_Y) &&
                    BLI_rctf_size_y(&v2d.tot) > BLI_rctf_size_y(&v2d.cur) + 1.0f;
  }
  if (zone.kind == NativeTouchKind::Interface) {
    Vector<ui::TouchButton> buttons;
    ui::region_touch_buttons(&region, buttons);
    zone.buttons.assign(buttons.begin(), buttons.end());
  }
  if (area && region.overlap) {
    /* Where an overlapping region lets touches through to the region below, as
     * #ED_region_contains_xy has it. */
    if (region.v2d.keeptot == V2D_KEEPTOT_STRICT) {
      zone.buttons_only = true;
    }
    else {
      zone.contents_only = true;
      rcti contents;
      ui::view2d_view_to_region_rcti(&region.v2d, &region.v2d.tot, &contents);
      BLI_rcti_translate(&contents, region.winrct.xmin, region.winrct.ymin);
      const int alignment = RGN_ALIGN_ENUM_FROM_MASK(region.alignment);
      zone.contents = region.winrct;
      if (ELEM(alignment, RGN_ALIGN_TOP, RGN_ALIGN_BOTTOM)) {
        zone.contents.xmin = contents.xmin - int(UI_REGION_OVERLAP_MARGIN);
        zone.contents.xmax = contents.xmax + int(UI_REGION_OVERLAP_MARGIN);
      }
      else {
        zone.contents.ymin = contents.ymin - int(UI_REGION_OVERLAP_MARGIN);
        zone.contents.ymax = contents.ymax + int(UI_REGION_OVERLAP_MARGIN);
      }
      if (!ED_region_panel_category_gutter_calc_rect(&region, &zone.tabs)) {
        BLI_rcti_init(&zone.tabs, 0, -1, 0, -1);
      }
    }
  }
  zones.push_back(std::move(zone));
}

static void bridge_touch_zones_update(wmWindowManager *wm)
{
  std::vector<BridgeTouchZone> zones;
  for (wmWindow &win : wm->windows) {
    const bScreen *screen = WM_window_get_active_screen(&win);
    if (screen == nullptr || win.runtime->ghostwin == nullptr) {
      continue;
    }
    /* Popups and menus on top, the newest first. */
    Vector<const ARegion *> popups;
    for (const ARegion &region : screen->regionbase) {
      popups.append(&region);
    }
    for (int i = popups.size() - 1; i >= 0; i--) {
      bridge_touch_zone_add(zones, win, nullptr, *popups[i]);
    }
    ED_screen_areas_iter (&win, screen, area) {
      for (const bool overlap : {true, false}) {
        for (const ARegion &region : area->regionbase) {
          if (bool(region.overlap) == overlap) {
            bridge_touch_zone_add(zones, win, area, region);
          }
        }
      }
    }
  }
  /* What waits in each window (ROUND6 TOUCH-5): a command for a click, a gesture for its drag, an
   * operator for its end. These change without a notifier; the toolbar view, which shows the hint
   * and the bar, is built again when they do. */
  static std::string waiting_last;
  std::string waiting;
  for (wmWindow &win : wm->windows) {
    waiting += std::to_string(uintptr_t(WM_event_wait_for_input_operator(&win))) + ":";
    for (const wmGesture &gesture : win.runtime->gesture) {
      waiting += std::to_string(int(gesture.type)) + (gesture.wait_for_input ? "w" : "") +
                 (gesture.is_active ? "a" : "") + ",";
    }
    for (wmEventHandler &handler : win.runtime->modalhandlers) {
      if (handler.type == WM_HANDLER_TYPE_OP) {
        waiting += std::to_string(uintptr_t(reinterpret_cast<wmEventHandler_Op &>(handler).op));
        break;
      }
    }
    waiting += ";";
  }
  if (waiting != waiting_last) {
    waiting_last = std::move(waiting);
    views::view_type_dirty("toolbar");
  }

  std::vector<BridgeTouchWindow> windows;
  for (wmWindow &win : wm->windows) {
    const bScreen *screen = WM_window_get_active_screen(&win);
    if (screen == nullptr || win.runtime->ghostwin == nullptr) {
      continue;
    }
    BridgeTouchWindow state;
    state.ghost_window = win.runtime->ghostwin;
    for (wmEventHandler &handler : win.runtime->modalhandlers) {
      if (handler.type == WM_HANDLER_TYPE_OP &&
          !reinterpret_cast<wmEventHandler_Op &>(handler).is_fileselect)
      {
        state.modal = true;
        break;
      }
    }
    state.gizmo = bridge_touch_gizmo_highlighted(win, *screen);
    if (win.runtime->eventstate) {
      state.cursor[0] = win.runtime->eventstate->xy[0];
      state.cursor[1] = win.runtime->eventstate->xy[1];
      wm_cursor_position_to_ghost_client_coords(&win, &state.cursor[0], &state.cursor[1]);
    }
    windows.push_back(state);
  }
  std::lock_guard lock(bridge_touch_mutex);
  bridge_touch_zones = std::move(zones);
  bridge_touch_windows = std::move(windows);
}

/** The window's state as a finger lands at \a x, \a y (GHOST's client pixels), see
 * #BridgeTouchWindow. Under #bridge_touch_mutex. */
static void bridge_touch_window_answer(const void *ghost_window,
                                       const int x,
                                       const int y,
                                       NativeTouchAnswer *r_answer)
{
  for (const BridgeTouchWindow &state : bridge_touch_windows) {
    if (state.ghost_window != ghost_window) {
      continue;
    }
    r_answer->modal = state.modal;
    /* The cursor was put where the finger landed: within a pixel or two of it, the rounding of
     * the way there and back. */
    r_answer->gizmo = r_answer->kind == NativeTouchKind::View3D && state.gizmo &&
                      abs(state.cursor[0] - x) <= 2 && abs(state.cursor[1] - y) <= 2;
    return;
  }
}

static bool bridge_touch_answer(const std::vector<BridgeTouchZone> &zones,
                                const void *ghost_window,
                                const int xy[2],
                                NativeTouchAnswer *r_answer)
{
  for (const BridgeTouchZone &zone : zones) {
    if ((ghost_window && zone.ghost_window != ghost_window) || !bridge_touch_zone_has(zone, xy)) {
      continue;
    }
    r_answer->kind = zone.kind;
    r_answer->scroll_x = zone.scroll_x;
    r_answer->scroll_y = zone.scroll_y;
    STRNCPY(r_answer->where, zone.where.c_str());
    /* The control on top: the last drawn that holds the point. */
    for (auto button = zone.buttons.rbegin(); button != zone.buttons.rend(); ++button) {
      if (BLI_rcti_isect_pt_v(&button->rect, xy)) {
        r_answer->takes = int8_t(button->takes);
        r_answer->button_type = button->type;
        break;
      }
    }
    return true;
  }
  return false;
}

bool WM_native_ui_touch_at(const void *ghost_window,
                           const int x,
                           const int y,
                           NativeTouchAnswer *r_answer)
{
  *r_answer = NativeTouchAnswer();
  const int part = bridge_navigation_part_at(ghost_window, x, y);
  if (part != int(NavigationGizmoPart::None)) {
    r_answer->kind = NativeTouchKind::Navigation;
    r_answer->navigation_part = part;
    STRNCPY(r_answer->where, "NAVIGATION");
    return true;
  }
  std::lock_guard lock(bridge_touch_mutex);
  for (const BridgeTouchZone &zone : bridge_touch_zones) {
    if (zone.ghost_window != ghost_window) {
      continue;
    }
    /* GHOST's client pixels to Blender's window pixels, as #wm_cursor_position_from_ghost_client_coords. */
    const int xy[2] = {int(x * zone.pixel_size),
                       int(((zone.window_height - 1) - y) * zone.pixel_size)};
    const bool found = bridge_touch_answer(bridge_touch_zones, ghost_window, xy, r_answer);
    bridge_touch_window_answer(ghost_window, x, y, r_answer);
    return found;
  }
  return false;
}

bool WM_native_ui_touch_find(const void *ghost_window,
                             const char *where,
                             const int button_type,
                             const bool last,
                             int r_client_xy[2])
{
  std::lock_guard lock(bridge_touch_mutex);
  bool found = false;
  int xy[2] = {0, 0};
  float pixel_size = 1.0f;
  int height = 0;
  for (const BridgeTouchZone &zone : bridge_touch_zones) {
    if (zone.ghost_window != ghost_window || zone.where != where) {
      continue;
    }
    pixel_size = zone.pixel_size;
    height = zone.window_height;
    if (button_type < 0) {
      xy[0] = BLI_rcti_cent_x(&zone.rect);
      xy[1] = BLI_rcti_cent_y(&zone.rect);
      found = true;
      break;
    }
    for (const ui::TouchButton &button : zone.buttons) {
      if (button.type == button_type) {
        xy[0] = BLI_rcti_cent_x(&button.rect);
        xy[1] = BLI_rcti_cent_y(&button.rect);
        found = true;
        if (!last) {
          break;
        }
      }
    }
    break;
  }
  if (found) {
    /* Blender's window pixels to GHOST's client pixels, as #wm_cursor_position_to_ghost_client_coords. */
    r_client_xy[0] = int(xy[0] / pixel_size);
    r_client_xy[1] = height - int(xy[1] / pixel_size) - 1;
  }
  return found;
}

/**
 * The same question in Blender's window pixels of the first window, for the Mac harness's `touch`
 * scenario (ROUND5 13A, check 2): \a r_values gets the kind, the navigation part, scroll x, scroll
 * y, what the control takes and its button type; \a r_where the editor and region. False where
 * nothing is.
 */
extern "C" bool WM_native_ui_touch_query(const int x,
                                         const int y,
                                         int r_values[6],
                                         char *r_where,
                                         const int where_size)
{
  NativeTouchAnswer answer;
  const int xy[2] = {x, y};
  bool found;
  {
    std::lock_guard lock(bridge_touch_mutex);
    found = bridge_touch_answer(bridge_touch_zones, nullptr, xy, &answer);
  }
  r_values[0] = int(answer.kind);
  r_values[1] = answer.navigation_part;
  r_values[2] = answer.scroll_x;
  r_values[3] = answer.scroll_y;
  r_values[4] = answer.takes;
  r_values[5] = answer.button_type;
  BLI_strncpy(r_where, answer.where, size_t(where_size));
  return found;
}

/**
 * The first window's state for a finger landing (ROUND6 TOUCH-1, TOUCH-2), for the Mac harness's
 * `fingers` scenario: \a r_values gets whether an operator waits, whether a gizmo's handle is
 * highlighted, and Blender's cursor in GHOST's client pixels. False before the first pass.
 */
extern "C" bool WM_native_ui_touch_window_query(int r_values[4])
{
  std::lock_guard lock(bridge_touch_mutex);
  if (bridge_touch_windows.empty()) {
    return false;
  }
  const BridgeTouchWindow &state = bridge_touch_windows.front();
  r_values[0] = state.modal;
  r_values[1] = state.gizmo;
  r_values[2] = state.cursor[0];
  r_values[3] = state.cursor[1];
  return true;
}

/**
 * The class ROUND6 TOUCH-2 is about, for the Mac harness's `fingers` scenario and a device script:
 * every operator whose modal key map (as the person has it) cancels on Escape and also answers the
 * left button, as lines `<idname>|<key map name>`. A second finger's Escape would throw such an
 * operator's work away. The text is the caller's to free with `free`.
 */
extern "C" char *WM_native_ui_escape_cancel_operators()
{
  std::string text;
  wmWindowManager *wm = static_cast<wmWindowManager *>(G_MAIN->wm.first);
  for (wmOperatorType *ot : WM_operatortypes_registered_get()) {
    if (ot->modalkeymap == nullptr || wm == nullptr) {
      continue;
    }
    wmKeyMap *keymap = WM_keymap_active(wm, ot->modalkeymap);
    const EnumPropertyItem *items = keymap ?
                                        static_cast<const EnumPropertyItem *>(keymap->modal_items) :
                                        nullptr;
    if (items == nullptr) {
      continue;
    }
    int cancel = -1;
    for (const EnumPropertyItem *item = items; item->identifier; item++) {
      if (STREQ(item->identifier, "CANCEL")) {
        cancel = item->value;
        break;
      }
    }
    bool escape = false, left = false;
    for (const wmKeyMapItem &kmi : keymap->items) {
      if (kmi.flag & KMI_INACTIVE) {
        continue;
      }
      escape |= kmi.type == EVT_ESCKEY && kmi.propvalue == cancel;
      left |= kmi.type == LEFTMOUSE;
    }
    if (escape && left) {
      text += std::string(ot->idname) + "|" + keymap->idname + "\n";
    }
  }
  char *result = static_cast<char *>(malloc(text.size() + 1));
  memcpy(result, text.c_str(), text.size() + 1);
  return result;
}

/** Simulated mouse events stand for a finger, \a point_pixels window pixels a point, or a mouse
 * again with 0: the Mac harness's `tolerance` scenario (ROUND6 TOUCH-4). */
extern "C" void WM_native_ui_test_simulate_finger(const float point_pixels)
{
  WM_event_simulate_finger(point_pixels);
}

/**
 * The commands that wait for a click to place them when run from a menu (ROUND6 TOUCH-5, finding
 * A3): every operator type that depends on the cursor, as lines of idnames, for the Mac harness's
 * `waiting` scenario. The text is the caller's to free with `free`.
 */
extern "C" char *WM_native_ui_test_cursor_operators()
{
  std::string text;
  for (wmOperatorType *ot : WM_operatortypes_registered_get()) {
    if ((ot->flag & OPTYPE_DEPENDS_ON_CURSOR) || ot->depends_on_cursor) {
      text += std::string(ot->idname) + "\n";
    }
  }
  char *result = static_cast<char *>(malloc(text.size() + 1));
  memcpy(result, text.c_str(), text.size() + 1);
  return result;
}

/** Run \a idname as a native menu item runs it, in the 3D View, for the harness (ROUND6 TOUCH-5):
 * a command that depends on the cursor waits for a click. False when it cannot run here. */
extern "C" bool WM_native_ui_test_menu_call(bContext *C, const char *idname)
{
  wmOperatorType *ot = WM_operatortype_find(idname, false);
  if (ot == nullptr) {
    return false;
  }
  const BridgeContextStore context_store = bridge_context_push_view3d(C);
  bool ran = false;
  if (WM_operator_poll_context(C, ot, wm::OpCallContext::InvokeRegionWin)) {
    WM_operator_name_call_ptr_with_depends_on_cursor(
        C, ot, wm::OpCallContext::InvokeRegionWin, nullptr, nullptr, "");
    ran = true;
  }
  bridge_context_pop(C, context_store);
  return ran;
}

/** Why the bar leaves out \a idname, or an empty text (ROUND6 TOUCH-5), for the harness. */
extern "C" const char *WM_native_ui_test_bar_excluded(const char *idname)
{
  const char *reason = bridge_bar_excluded(idname);
  return reason ? reason : "";
}

/**
 * Every interactive button of the first window's map, as lines `<where>|<type>|<takes>|xmin ymin
 * xmax ymax`, for the harness to find a number field or a panel's place (ROUND5 13A, check 2).
 * The text is the caller's to free with `free`.
 */
extern "C" char *WM_native_ui_touch_map_text()
{
  std::string text;
  std::lock_guard lock(bridge_touch_mutex);
  for (const BridgeTouchZone &zone : bridge_touch_zones) {
    text += zone.where + "|zone|" + std::to_string(int(zone.kind)) + "|" +
            std::to_string(zone.rect.xmin) + " " + std::to_string(zone.rect.ymin) + " " +
            std::to_string(zone.rect.xmax) + " " + std::to_string(zone.rect.ymax) + "\n";
    for (const ui::TouchButton &button : zone.buttons) {
      text += zone.where + "|" + std::to_string(int(button.type)) + "|" +
              ui::touch_takes_name(button.takes) + "|" + std::to_string(button.rect.xmin) + " " +
              std::to_string(button.rect.ymin) + " " + std::to_string(button.rect.xmax) + " " +
              std::to_string(button.rect.ymax) + "\n";
    }
  }
  return strdup(text.c_str());
}

/** \} */

static bool bridge_view3d_insets(const ARegion *region,
                                 const float leading_inset,
                                 const float trailing_inset,
                                 int *r_leading,
                                 int *r_trailing)
{
  *r_leading = 0;
  *r_trailing = 0;
  if (region == nullptr || region->regiontype != RGN_TYPE_WINDOW || WM_native_ui_desktop_mode()) {
    return false;
  }
  const SpaceType *space = BKE_spacetype_from_id(SPACE_VIEW3D);
  if (space == nullptr || region->runtime->type != BKE_regiontype_from_id(space, RGN_TYPE_WINDOW)) {
    return false;
  }
  /* The leading inset is from the window's left, the trailing one from the 3D View's right, as
   * the Image Editor beside the view narrows its area and the sidebar lies beside that. */
  const int leading = std::max(0, int(leading_inset) - region->winrct.xmin);
  const int trailing = std::max(0, int(trailing_inset));
  if (leading + trailing == 0 || region->winx - leading - trailing < region->winx / 5) {
    return false;
  }
  *r_leading = leading;
  *r_trailing = trailing;
  return true;
}

bool WM_native_ui_view3d_insets(const ARegion *region, int *r_leading, int *r_trailing)
{
  return bridge_view3d_insets(region,
                              bridge_viewport_leading_inset.load(),
                              bridge_viewport_trailing_inset.load(),
                              r_leading,
                              r_trailing);
}

bool WM_native_ui_view3d_frame_insets(const wmWindow *win,
                                      const ARegion *region,
                                      int *r_leading,
                                      int *r_trailing,
                                      int *r_top,
                                      int *r_bottom)
{
  *r_top = 0;
  *r_bottom = 0;
  /* The sidebars' insets as they are once a slide has ended (ROUND5 14B.4): framing during a
   * slide lands where it would after it. */
  bridge_view3d_insets(region,
                       bridge_viewport_final_leading_inset.load(),
                       bridge_viewport_final_trailing_inset.load(),
                       r_leading,
                       r_trailing);
  if (win == nullptr || region == nullptr || region->regiontype != RGN_TYPE_WINDOW ||
      WM_native_ui_desktop_mode())
  {
    return false;
  }
  const SpaceType *space = BKE_spacetype_from_id(SPACE_VIEW3D);
  if (space == nullptr || region->runtime->type != BKE_regiontype_from_id(space, RGN_TYPE_WINDOW)) {
    return false;
  }
  /* The navigation gizmo's column of buttons, where it was placed (ROUND5 12D.5, decision 79): its
   * width joins the inset on its side, so nothing framed lies under a button. */
  int column = 0;
  {
    NavigationGizmoPlace parts[NAVIGATION_GIZMO_PARTS_MAX];
    const int count = ED_view3d_navigate_gizmo_parts(
        bridge_area_of_region(win, region), region, parts);
    float xmin = FLT_MAX, xmax = -FLT_MAX;
    for (int i = 0; i < count; i++) {
      if (parts[i].part != NavigationGizmoPart::Axes) {
        xmin = std::min(xmin, parts[i].center[0] - parts[i].radius);
        xmax = std::max(xmax, parts[i].center[0] + parts[i].radius);
      }
    }
    if (xmin < xmax) {
      const bool trailing = (xmin + xmax) * 0.5f > region->winx * 0.5f;
      const int leading_new = trailing ? *r_leading : std::max(*r_leading, int(ceilf(xmax)));
      const int trailing_new = trailing ? std::max(*r_trailing, region->winx - int(floorf(xmin))) :
                                          *r_trailing;
      /* As the sidebars' insets: while a fifth of the view at least is left showing. */
      if (region->winx - leading_new - trailing_new >= region->winx / 5) {
        column = (leading_new - *r_leading) + (trailing_new - *r_trailing);
        *r_leading = leading_new;
        *r_trailing = trailing_new;
      }
    }
  }
  /* The top bar (header and tool settings row), as the navigation gizmo keeps clear of it, and
   * the band the controls along the bottom stand in (ROUND5 9G.5: the Actions button, the tool
   * button or the bottom rail, the action bar, the keyboard's bar), in window pixels from the
   * window's top and bottom; the gizmo's tray when it reaches higher. In the region's own pixels
   * here. */
  const int above_region = WM_window_native_pixel_y(win) - region->winrct.ymax - 1;
  const int band = std::max(int(bridge_bottom_controls.load()), int(bridge_bottom_tray.load()));
  const int top = std::max(0, int(bridge_top_bar.load()) - above_region);
  const int bottom = std::max(0, band - region->winrct.ymin);
  const bool used = top + bottom > 0 && region->winy - top - bottom >= region->winy / 5;
  /* What framing kept clear of, and from what, as a `viewport frame` line (ROUND5 9G.4). */
  const std::string line = fmt::format(
      "frame insets {} {} {} {} of {}x{}: gizmo column {} top bar {} bottom controls {} bottom "
      "tray {} window {} region {}..{}{}",
      *r_leading,
      *r_trailing,
      used ? top : 0,
      used ? bottom : 0,
      region->winx,
      region->winy,
      column,
      int(bridge_top_bar.load()),
      int(bridge_bottom_controls.load()),
      int(bridge_bottom_tray.load()),
      WM_window_native_pixel_y(win),
      region->winrct.ymin,
      region->winrct.ymax,
      used || top + bottom == 0 ? "" : " (top and bottom not used: too little left)");
  WM_native_ui_log("viewport", line.c_str());
  if (used) {
    *r_top = top;
    *r_bottom = bottom;
  }
  /* In the iPad interface always, with no insets too: the corners are fitted there (9G.5). */
  return true;
}

bool WM_native_ui_navigation_top()
{
  return bridge_navigation_top.load();
}

bool WM_native_ui_navigation_minimal()
{
  return bridge_navigation_minimal.load();
}

bool WM_native_ui_navigation_left()
{
  return bridge_navigation_left.load();
}

int WM_native_ui_bottom_tray_ymin(const wmWindow *win, const ARegion *region)
{
  /* The navigation gizmo sits above the tray, in region pixels. */
  return int(bridge_bottom_tray.load()) - region->winrct.ymin;
}

static void bridge_dispatch(bContext *C, BridgeMessage &message)
{
#if defined(WITH_APPLE_CROSSPLATFORM) && APPLE_TARGET_IOS
  if (WM_apple_ios_dialog_active(CTX_wm_window(C))) {
    return;
  }
#endif
  std::visit(
      [&](auto &command) {
        using T = std::decay_t<decltype(command)>;
        if constexpr (std::is_same_v<T, BridgeAssetDragCommand>) {
          bridge_asset_drag(C, command);
        }
        else {
          const BridgeContextStore context_store = bridge_context_push_view3d(C);
          if (CTX_wm_window(C) && CTX_wm_area(C) && CTX_wm_region(C)) {
            bridge_view_roll_angle(C, command);
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
  if (!bridge_storyboard_pending || !bridge_storyboard_state || !wm) {
    return;
  }
  /* In the window's context, as the storyboard's snapshot is read. */
  const BridgeContextStore context_store = bridge_context_push_view3d(C);
  wmWindow *win = CTX_wm_window(C);
  if (win) {
    wm_window_make_drawable(wm, win);
    bridge_storyboard_pending = ed::vse::native_storyboard_draw(C, *bridge_storyboard_state);
    if (bScreen *screen = WM_window_get_active_screen(win)) {
      screen->do_draw = true;
    }
  }
  bridge_context_pop(C, context_store);
  /* The new pictures, to the native interface at once. */
  wm::native_ui::view_type_dirty("storyboard");
}

void WM_native_ui_image_update(bContext *C)
{
  /* The image editor's picture follows painting closely, not at the panels' slower pace: each
   * time Blender changes something, though no closer together than the last one took to make. */
  static std::chrono::steady_clock::time_point next_pixels;
  if (!bridge_image_shown || !(bridge_image_pixels_pending || bridge_image_uvs_pending)) {
    return;
  }
  const auto now = std::chrono::steady_clock::now();
  const BridgeContextStore context_store = bridge_context_push_view3d(C);
  if (bridge_image_pixels_pending && now >= next_pixels) {
    bridge_image_pixels_pending = false;
    ed::image::NativeImagePixels pixels;
    if (bridge_image_state && ed::image::native_image_pixels(C, *bridge_image_state, pixels)) {
      bridge_image_pixels.publish(std::move(pixels));
    }
    const auto took = std::chrono::steady_clock::now() - now;
    next_pixels = now + std::max<std::chrono::steady_clock::duration>(
                            std::chrono::milliseconds(33), took * 2);
  }
  if (bridge_image_uvs_pending) {
    /* Also when only the selection changed (ROUND5 9G.3): it is part of what is sent. */
    static ed::image::NativeImageUVs sent;
    static bool sent_any = false;
    bridge_image_uvs_pending = false;
    ed::image::NativeImageUVs uvs = ed::image::native_image_uvs(C);
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

template<typename T> static T *bridge_malloc_copy(const std::vector<T> &values)
{
  if (values.empty()) {
    return nullptr;
  }
  T *copy = static_cast<T *>(std::malloc(values.size() * sizeof(T)));
  if (copy) {
    std::memcpy(copy, values.data(), values.size() * sizeof(T));
  }
  return copy;
}

extern "C" bool WM_native_ui_image_take_uvs(WMNativeImageUVs *r_uvs)
{
  ed::image::NativeImageUVs uvs;
  if (!bridge_image_uvs.take(uvs)) {
    return false;
  }
  *r_uvs = {};
  r_uvs->edges = bridge_malloc_copy(uvs.edges);
  r_uvs->edge_flags = bridge_malloc_copy(uvs.edge_flags);
  r_uvs->faces = bridge_malloc_copy(uvs.faces);
  r_uvs->face_sizes = bridge_malloc_copy(uvs.face_sizes);
  const bool complete = (r_uvs->edges || uvs.edges.empty()) &&
                        (r_uvs->edge_flags || uvs.edge_flags.empty()) &&
                        (r_uvs->faces || uvs.faces.empty()) &&
                        (r_uvs->face_sizes || uvs.face_sizes.empty());
  if (complete) {
    r_uvs->edge_count = int(uvs.edge_flags.size());
    r_uvs->face_count = int(uvs.face_sizes.size());
    r_uvs->active_face = uvs.active_face;
  }
  r_uvs->capped = uvs.capped;
  return true;
}

extern "C" void WM_native_ui_image_uvs_free(WMNativeImageUVs *uvs)
{
  std::free(uvs->edges);
  std::free(uvs->edge_flags);
  std::free(uvs->faces);
  std::free(uvs->face_sizes);
  *uvs = {};
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
  if (bridge_storyboard_pending) {
    /* The storyboard's pictures still to draw, a few each pass. */
    return 0.1;
  }
  if (bridge_image_shown && (bridge_image_pixels_pending || bridge_image_uvs_pending)) {
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
bool bridge_dispatching = false;
/* The undo step held back, pushed when the operator ends; see #WM_native_ui_undo_push_defer. */
static std::optional<std::string> bridge_undo_pending;

/* Whether a stroke or another modal operator is running. The file browser waits for the system's
 * picker, holding no data half changed. */
static bool bridge_modal_handler_running(bContext *C)
{
  wmWindowManager *wm = CTX_wm_manager(C);
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

/* Or an undo step it began, as a stroke does, is still open. */
static bool bridge_modal_operator_running(bContext *C)
{
  const wmWindowManager *wm = CTX_wm_manager(C);
  return (wm->runtime->undo_stack && wm->runtime->undo_stack->step_init) ||
         bridge_modal_handler_running(C);
}

/**
 * Whether a message can be handled while a stroke or other modal operator runs: values, what is
 * shown and the view. Modes, tools, brushes, operators, undo, frames and assets change data the
 * operator holds, and wait for it to end.
 */
static bool bridge_message_live(const BridgeMessage &message)
{
  /* Turning the view, which changes no data; not an asset dragged in. */
  return std::holds_alternative<float>(message);
}

void bridge_undo_push_pending(bContext *C)
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
  /* An open undo step without a modal operator is one an operator began and ends with this push,
   * as entering Sculpt Mode does: held back, it would wait for itself. */
  if (!bridge_dispatching || !bridge_modal_handler_running(C)) {
    return false;
  }
  bridge_undo_pending = name ? name : "";
  return true;
}

bool WM_native_ui_engine_busy(bContext *C)
{
  return bridge_modal_operator_running(C);
}

/**
 * Every change of a 3D View's region size, with its cause, as a `viewport region` line in the
 * session's log (ROUND5 10A): `window` when Blender's window changed size with it, `cover` when a
 * docked editor's cover changed, `layout` for anything else (Blender's own regions, a split). The
 * sizes are read once per pass of the loop, so a change is logged on the pass after it.
 */
static void bridge_viewport_regions_note(bContext *C)
{
  struct Seen {
    int2 window = int2(0);
    float cover = 0.0f;
    float trailing = 0.0f;
  };
  /* Per 3D View, the region's size as last seen. */
  static Map<const ScrArea *, int2> sizes;
  /* What the window and the covers were when a region last changed. */
  static Seen seen;
  wmWindowManager *wm = CTX_wm_manager(C);
  if (wm == nullptr) {
    return;
  }
  Map<const ScrArea *, int2> now;
  for (wmWindow &win : wm->windows) {
    bScreen *screen = WM_window_get_active_screen(&win);
    if (screen == nullptr) {
      continue;
    }
    const int2 window(WM_window_native_pixel_x(&win), WM_window_native_pixel_y(&win));
    for (ScrArea &area : screen->areabase) {
      if (area.spacetype != SPACE_VIEW3D) {
        continue;
      }
      const ARegion *region = BKE_area_find_region_type(&area, RGN_TYPE_WINDOW);
      if (region == nullptr || region->winx <= 1 || region->winy <= 1) {
        continue;
      }
      const int2 size(region->winx, region->winy);
      now.add(&area, size);
      const int2 *old = sizes.lookup_ptr(&area);
      if (old == nullptr || *old == size) {
        /* A view seen for the first time (a new screen, a workspace) is no change of size. */
        continue;
      }
      const float cover = WM_native_ui_viewport_cover();
      const float trailing = WM_native_ui_viewport_trailing_cover();
      const char *cause = window != seen.window ? "window" :
                          (cover != seen.cover || trailing != seen.trailing) ? "cover" :
                                                                                "layout";
      WM_native_ui_session_log("viewport",
                               fmt::format("region {}x{} <- {}x{} ({})",
                                           size.x,
                                           size.y,
                                           (*old).x,
                                           (*old).y,
                                           cause)
                                   .c_str());
      seen = {window, cover, trailing};
    }
    if (seen.window == int2(0)) {
      seen = {window, WM_native_ui_viewport_cover(), WM_native_ui_viewport_trailing_cover()};
    }
  }
  sizes = std::move(now);
}

void WM_native_ui_flush_commands(bContext *C)
{
  if (C == nullptr) {
    return;
  }
  bridge_viewport_regions_note(C);

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
  if (bridge_viewport_insets_changed.exchange(false)) {
    /* A sidebar showed or hid over the 3D views: their size stays, only what they draw at their
     * edges moves, so the overlays alone are drawn again (ROUND5 10B); the render keeps going. */
    for (wmWindow &win : CTX_wm_manager(C)->windows) {
      bScreen *screen = WM_window_get_active_screen(&win);
      for (ScrArea &area : screen->areabase) {
        if (area.spacetype != SPACE_VIEW3D) {
          continue;
        }
        for (ARegion &region : area.regionbase) {
          if (region.regiontype == RGN_TYPE_WINDOW) {
            region.runtime->visible_rect = rcti{};
            ED_region_tag_redraw_editor_overlays(&region);
          }
        }
      }
    }
    bridge_navigation_redraw_pending.store(true);
  }
  if (bridge_navigation_redraw_pending.exchange(false)) {
    /* The navigation gizmo moved, which the toolbar says where it is. */
    wm::native_ui::view_type_dirty("toolbar");
    const BridgeContextStore context_store = bridge_context_push_view3d(C);
    if (ARegion *region = CTX_wm_region(C)) {
      ED_region_tag_redraw_editor_overlays(region);
    }
    bridge_context_pop(C, context_store);
  }

  /* An asset dragged on: only its newest place. */
  auto supersedes_preview = [](const BridgeMessage &previous, const BridgeMessage &next) {
    const auto *a = std::get_if<BridgeAssetDragCommand>(&previous);
    const auto *b = std::get_if<BridgeAssetDragCommand>(&next);
    return a && b && a->phase == BRIDGE_ASSET_DRAG_MOVE && b->phase == BRIDGE_ASSET_DRAG_MOVE;
  };
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
    bridge_context_pop(C, context_store);
  }

  {
    /* An operator starting or ending a wait for input (the knife, a loop cut, anything modal
     * started from a tool or a menu) sends no notifier, so the toolbar would keep the ordinary
     * actions and offer no way to end it: rebuild it whenever the waiting operator changes. */
    static const wmOperator *waiting_seen = nullptr;
    const wmOperator *waiting = bridge_waiting_operator(CTX_wm_window(C));
    if (waiting != waiting_seen) {
      waiting_seen = waiting;
      wm::native_ui::view_type_dirty("toolbar");
    }
  }
  bridge_changed = false;
  bridge_volume_build(C);
  {
    /* Views are built as Blender's own editors draw: in the window, its 3D View current. */
    const BridgeContextStore context_store = bridge_context_push_view3d(C);
    WM_native_ui_views_flush(C);
    bridge_context_pop(C, context_store);
  }
  WM_native_ui_session_log_flush(false);
}

}  // namespace blender
