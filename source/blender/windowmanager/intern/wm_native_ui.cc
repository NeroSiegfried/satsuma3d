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
#include <atomic>
#include <chrono>
#include <cmath>
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

#include <fmt/format.h>

namespace blender::ui::native {
void menu_write(bContext *C, StringRef route, wm::native_ui::ViewBuilder &builder);
void menu_run(bContext *C, StringRef route);
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

static CLG_LogRef LOG = {"wm.native"};

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
/** Changed preferences are saved shortly after, as the iPad may end the app without warning. */
bool bridge_preferences_save_pending = false;
std::chrono::steady_clock::time_point bridge_preferences_save_at;
/** The native image editor's state: the image chosen and whether UVs show over it. */
std::shared_ptr<const io::serialize::DictionaryValue> bridge_image_state;
/* An interface shows the image editor, see #bridge_image_view_shown. */
bool bridge_image_shown = false;
/** Its picture and UVs, taken by the native editor when they change. */
GHOST_Latest<ed::image::NativeImagePixels> bridge_image_pixels;
GHOST_Latest<std::vector<float>> bridge_image_uvs;
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
struct BridgePencilHoverRequest {
  bool active = false;
  int x = 0, y = 0;
};
GHOST_Latest<BridgePencilHoverRequest> bridge_hover_requests;
/* Window coordinates of the asset drag in progress. */
int2 bridge_asset_drag_xy(0);
BridgePencilHoverRequest bridge_hover_request;

std::string bridge_json_escape(const std::string &value);
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
#ifdef WITH_PYTHON
  if (command.setting == "keymap") {
    /* From the iPad's Settings, see `bl_ui.native_settings`. */
    const char *imports[] = {"bpy", "bl_ui", nullptr};
    const std::string expression = "bl_ui.native_settings.keymap_set(bpy.context, \"" +
                                   bridge_json_escape(command.value) + "\")";
    BPY_run_string_eval(C, imports, expression.c_str());
    return;
  }
  if (command.setting == "native_addon" || command.setting == "native_keymap_item_active") {
    /* Add-ons and keymap items, which Settings lists in its own way, see `bl_ui.native_settings`. */
    const char *imports[] = {"bpy", "bl_ui", nullptr};
    const std::string expression = "bl_ui.native_settings.command(bpy.context, \"" +
                                   command.setting.substr(strlen("native_")) + "\", \"" +
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
#endif

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

/** A JSON value a Python expression gives, or null. */
std::shared_ptr<io::serialize::Value> bridge_python_value(bContext *C,
                                                         const char *part,
                                                         const char *expression)
{
#ifdef WITH_PYTHON
  std::string json;
  if (!bridge_python(C, part, expression, json)) {
    return nullptr;
  }
  std::istringstream stream(json);
  return io::serialize::JsonFormatter().deserialize(stream);
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

/** The tools of the mode, as `native_toolbar_json` lists them: a choice for each, of the tools
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
      C, "tools", "bl_ui.space_toolsystem_common.native_toolbar_json(bpy.context)");
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
      C, "brush", "bl_ui.native_brush.brush_json(bpy.context)");
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
  std::optional<BridgeMirror> mirror = bridge_mirror(ob, mode);
  if (!mirror) {
    return;
  }
  /* The axes there are, and which of them mirror, separated by commas. */
  builder.add(top, "mirror", [&](ViewBuffer &buffer, NodeFields &fields) {
    fields.label = IFACE_("Mirror");
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

/** Quick actions for the mode, tool and selection, as `bl_ui.native_actions` chooses them; or
 * the axes a move, turn or scale running is constrained to. */
void bridge_actions_build(bContext *C, const char *tool, views::ViewBuilder &builder, const NodeId top)
{
  using namespace io::serialize;
  const NodeId row = builder.add(top, "actions", [](ViewBuffer &buffer, NodeFields & /*fields*/) {
    return views::protocol::CreateGroup(buffer, views::protocol::Layout::Row);
  });
  if (wmOperator *op = bridge_constraint_operator(CTX_wm_window(C))) {
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
    return;
  }
  const std::string expression = "bl_ui.native_actions.actions_json(bpy.context, \"" +
                                 bridge_json_escape(tool ? tool : "") + "\")";
  const std::shared_ptr<Value> actions = bridge_python_value(C, "actions", expression.c_str());
  const ArrayValue *array = actions ? actions->as_array_value() : nullptr;
  if (array == nullptr) {
    return;
  }
  for (const std::shared_ptr<Value> &item : array->elements()) {
    const DictionaryValue *action = item->as_dictionary_value();
    if (action == nullptr) {
      continue;
    }
    builder.add(row,
                "action:" + std::string(bridge_text(*action, "action")),
                [&](ViewBuffer &buffer, NodeFields &fields) {
                  fields.label = bridge_text(*action, "title");
                  fields.icon = bridge_text(*action, "icon");
                  return views::protocol::CreateButtonDirect(
                      buffer,
                      views::protocol::ButtonStyle::Normal,
                      bridge_text(*action, "operator").data(),
                      nullptr,
                      nullptr,
                      bridge_flag(*action, "selected"));
                });
  }
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
  if (const char *drag_hint = bridge_drag_hint(CTX_wm_window(C), &drag_done)) {
    /* A command waiting for a drag in the view, and whether it ends with Done. */
    builder.add(top, "drag_hint", [&](ViewBuffer &buffer, NodeFields &fields) {
      fields.label = IFACE_(drag_hint);
      return bridge_data(buffer, drag_done);
    });
  }
  if (has_view3d) {
    bridge_actions_build(C, active_tool_id, builder, top);
    bridge_text_object_build(C, builder, top);
  }

  if (has_view3d) {
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
      /* As `view3d_gizmo_navigate.cc` places it, over the part of the window a panel leaves
       * showing, in whichever corner Settings has it: its center and radius as fractions of the
       * window's width and height from the top left. */
      const float cover = std::min(bridge_viewport_cover.load(), height * 0.9f);
      const float x = bridge_navigation_left ? visible.xmin + inset : visible.xmax - inset;
      const float y = bridge_navigation_top ? visible.ymax - inset : visible.ymin + inset;
      const double gizmo[3] = {(region->winrct.xmin + x) / width,
                               1.0 - (region->winrct.ymin + y - cover) / (height - cover),
                               radius / width};
      data("navigation_gizmo", Span<double>(gizmo, 3));
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
    /* The viewport's options, see `bl_ui.native_render.viewport_json`. */
    using namespace io::serialize;
    const std::shared_ptr<Value> viewport = bridge_python_value(
        C, "viewport", "bl_ui.native_render.viewport_json(bpy.context)");
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
  if (set && ELEM(target, "orientation", "pivot", "snap", "proportional")) {
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
    return setting("native_brush",
                   "{\"key\":\"" + std::string(target.substr(6)) + "\",\"value\":" + value +
                       ",\"commit\":" + (commit ? "true" : "false") + "}");
  }
  if (set && StringRef(target).startswith("viewport:")) {
    return setting("viewport_toggle", std::string(target.substr(9)));
  }
  if (invoke && ELEM(target, "undo", "redo")) {
    const char *op_name = target == "undo" ? "ED_OT_undo" : "ED_OT_redo";
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
         target == "direction" || target.startswith("brush:") || target.startswith("axis:");
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
      C, "timeline.keys", "bl_ui.native_timeline.keys_json(bpy.context)");
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
        C, "preferences.addons", "bl_ui.native_settings.addons_json(bpy.context)");
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
    /* What to list, as `keymaps_json` takes it. */
    DictionaryValue state;
    state.append_str("search", std::string(params.text("search").value_or("")));
    auto expanded = state.append_array("expanded");
    if (const views::protocol::Param *param = params.find("expanded")) {
      if (const views::protocol::TextsValue *names = param->value_as_TextsValue()) {
        for (const flatbuffers::String *name : *names->value()) {
          expanded->append_str(name->str());
        }
      }
    }
    std::ostringstream state_stream;
    JsonFormatter().serialize(state_stream, state);
    const std::string expression = "bl_ui.native_settings.keymaps_json(bpy.context, \"" +
                                   bridge_json_escape(state_stream.str()) + "\")";
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
  DictionaryValue value;
  std::string name;
  if (StringRef(target).endswith(":enabled")) {
    name = "addon";
    value.append_str("module", target.substr(0, target.size() - strlen(":enabled")));
    value.append("enable", std::make_shared<BooleanValue>(on->value()));
  }
  else if (StringRef(target).endswith(":active")) {
    const std::string item = target.substr(0, target.size() - strlen(":active"));
    const size_t slash = item.rfind('/');
    if (slash == std::string::npos) {
      r_error = "No such keymap item";
      return views::CommandResult::Failed;
    }
    name = "keymap_item_active";
    value.append_str("keymap", item.substr(0, slash));
    value.append_int("id", std::atoll(item.c_str() + slash + 1));
    value.append("active", std::make_shared<BooleanValue>(on->value()));
  }
  else {
    r_error = "Not something the Preferences' lists do";
    return views::CommandResult::Failed;
  }
  std::ostringstream stream;
  JsonFormatter().serialize(stream, value);
  bridge_setting_execute(C, BridgeSettingCommand{"native_" + name, stream.str()});
  return views::CommandResult::Done;
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name The Outliner View
 *
 * The scene's collections and objects, as `bl_ui.native_panels.hierarchy_json` lists them: the
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
      C, "outliner", "bl_ui.native_panels.hierarchy_json(bpy.context)");
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
  /* Blender's own interface, as on a desktop computer. */
  toggle("desktop", "Desktop Interface", bridge_desktop_ui.load());
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
  else if (target == "hover_highlight" && on) {
    bridge_hover_highlight = on->value();
  }
  else if (target == "keymap") {
    bridge_setting_execute(C, BridgeSettingCommand{"keymap", text});
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

/** The render's state, as `bl_ui.native_render.status_json` gives it: a node of data for each of
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
      C, "render", "bl_ui.native_render.status_json(bpy.context)");
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
  BridgePopup popup;
  popup.menu = menu;
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

bool bridge_panel_popup(bContext *C, const char *panel)
{
  if (WM_native_ui_desktop_mode() || !STREQ(panel, "TOPBAR_PT_name")) {
    return false;
  }
  BridgePopup popup;
  popup.rename = true;
  bridge_popup_show(C, std::move(popup));
  return true;
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

  bridge_changed = false;
  bridge_volume_build(C);
  {
    /* Views are built as Blender's own editors draw: in the window, its 3D View current. */
    const BridgeContextStore context_store = bridge_context_push_view3d(C);
    WM_native_ui_views_flush(C);
    bridge_context_pop(C, context_store);
  }
}

}  // namespace blender
