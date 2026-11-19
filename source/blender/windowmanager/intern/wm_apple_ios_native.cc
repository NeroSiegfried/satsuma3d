/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * The native iPad and Apple Vision Pro interface, as Blender's window manager sees it: what it
 * shows in place of Blender's own, see #wmNativeInterface.
 */

#if defined(WITH_APPLE_CROSSPLATFORM) && APPLE_TARGET_IOS

#  include <cstring>

#  include "BLI_listbase.h"
#  include "BLI_string.h"

#  include "BLT_translation.hh"

#  include "DNA_space_types.h"
#  include "DNA_windowmanager_types.h"

#  include "RNA_access.hh"

#  include "ED_screen.hh"

#  include "GHOST_IOSNativeInterface.hh"
#  include "wm_apple_ios_alerts.hh"

#  include "UI_interface_c.hh"
#  include "UI_interface_icons.hh"

#  include "WM_api.hh"
#  include "WM_apple_ios.hh"
#  include "WM_keymap.hh"
#  include "WM_native_ui.h"
#  include "WM_native_ui.hh"
#  include "WM_native_interface.hh"
#  include "WM_types.hh"

#  include "wm_apple_ios_file.hh"
#  include "wm_draw.hh"
#  include "wm_event_system.hh"
#  include "wm_window.hh"

namespace blender {

extern "C" void wm_apple_ios_open_web_url(const char *url);
bool bridge_menu_popup(bContext *C, const char *menu);
bool bridge_enum_popup(bContext *C, wmOperator *op, PropertyRNA *prop);
bool bridge_panel_popup(bContext *C, const char *panel);

namespace ui {
bool native_operator_dialog_begin(bContext *C,
                                  wmOperator *op,
                                  const std::string &title,
                                  const std::string &confirm,
                                  const std::string &message);
void native_redo_operator_register(bContext *C, wmOperator *op);
void native_redo_operator_free(wmOperator *op);
void native_redo_operator_clear();
void native_redo_show(bContext *C);
}  // namespace ui

namespace {

bool alert(bContext *C,
           const wmNativeAlert &alert,
           wmNativeAlertComplete complete,
           wmNativeAlertCancel cancel,
           const char *key)
{
  wmIOSDialog dialog;
  dialog.title = alert.title;
  dialog.message = alert.message;
  for (const wmNativeAlert::Action &action : alert.actions) {
    dialog.actions.push_back(
        {action.title,
         action.role == wmNativeAlert::Role::Cancel      ? wmIOSDialogRole::Cancel :
         action.role == wmNativeAlert::Role::Destructive ? wmIOSDialogRole::Destructive :
                                                           wmIOSDialogRole::Default});
  }
  for (const wmNativeAlert::Toggle &toggle : alert.toggles) {
    dialog.toggles.push_back({toggle.title, toggle.selected});
  }
  dialog.preferred_action = alert.preferred_action;
  return WM_apple_ios_dialog_begin(C, dialog, std::move(complete), std::move(cancel), key);
}

/**
 * A native alert for #WM_operator_confirm_ex. Its confirm button is destructive, red, when it
 * says it deletes, removes or reverts, or Blender warns about it, as iOS marks such actions.
 */
std::optional<wmOperatorStatus> confirm(bContext *C,
                                        wmOperator *op,
                                        const char *title,
                                        const char *message,
                                        const char *confirm_text,
                                        const ui::AlertIcon icon,
                                        const bool cancel_default)
{
  wmNativeAlert dialog;
  dialog.title = title ? title : WM_operatortype_name(op->type, op->ptr);
  dialog.message = message ? message : "";
  const char *confirm_label = confirm_text ? confirm_text : IFACE_("OK");
  const bool destructive = ELEM(icon, ui::AlertIcon::Warning, ui::AlertIcon::Error) ||
                           STREQ(confirm_label, IFACE_("Delete")) ||
                           STREQ(confirm_label, IFACE_("Remove")) ||
                           STREQ(confirm_label, IFACE_("Revert"));
  dialog.actions = {
      {IFACE_("Cancel"), wmNativeAlert::Role::Cancel},
      {confirm_label,
       destructive ? wmNativeAlert::Role::Destructive : wmNativeAlert::Role::Default}};
  dialog.preferred_action = cancel_default || destructive ? 0 : 1;
  auto cancel = [op](bContext *context) {
    if (op->type->cancel) {
      op->type->cancel(context, op);
    }
    WM_operator_free(op);
  };
  if (alert(
          C,
          dialog,
          [op, cancel](bContext *context, int action, uint64_t) {
            if (action == 1) {
              WM_operator_call_ex(context, op, true);
            }
            else {
              cancel(context);
            }
          },
          cancel,
          ""))
  {
    return OPERATOR_RUNNING_MODAL;
  }
  return OPERATOR_CANCELLED;
}

/** An operator's dialog, natively: its properties above OK and Cancel, see `OperatorDialog.swift`. */
bool props_dialog(bContext *C,
                  wmOperator *op,
                  const std::string &title,
                  const std::string &confirm,
                  const std::string &message)
{
  if (WM_native_ui_desktop_mode()) {
    return false;
  }
  return ui::native_operator_dialog_begin(C, op, title, confirm, message);
}

/** Two fingers move the view; Blender's own keymaps have no touch gestures. */
void keyconfig_default_ensure(wmKeyConfig *keyconf)
{
  wmKeyMap *keymap = WM_keymap_ensure(
      keyconf, "3D View iPad Gestures", SPACE_VIEW3D, RGN_TYPE_WINDOW);
  if (BLI_listbase_is_empty(&keymap->items)) {
    const KeyMapItem_Params params = {MOUSEPAN, KM_ANY, KM_ANY, 0, KM_ANY};
    WM_keymap_add_item(keymap, "VIEW3D_OT_move", &params);
  }
}

wmNativeInterface native_interface_create()
{
  wmNativeInterface native;
  native.state_changed = WM_native_ui_tag_changed;
  native.reports_added = WM_apple_ios_reports;
  native.report_added = WM_apple_ios_report;
  native.operator_finished = WM_native_ui_operator_finished;
  native.replaces_redo_panel = [] { return !WM_native_ui_desktop_mode(); };
  /* A touch screen with no hover, in either interface (ROUND6 TOUCH-6). */
  native.touch_screen = [] { return true; };
  native.operator_registered = ui::native_redo_operator_register;
  native.operator_freed = ui::native_redo_operator_free;
  native.redo_cleared = ui::native_redo_operator_clear;
  native.redo_show = ui::native_redo_show;
  native.fileselect_begin = WM_apple_ios_fileselect_begin;
  native.fileselect_active = WM_apple_ios_fileselect_active;
  native.fileselect_exec = WM_apple_ios_fileselect_exec;
  native.fileselect_cancel = WM_apple_ios_fileselect_cancel;
  native.alert = alert;
  native.confirm = confirm;
  native.pointer_hovering = WM_native_ui_stylus_hover_active;
  native.pencil_roll = WM_native_ui_stylus_roll;
  native.tweak_drag = WM_native_ui_tweak_drag;
  native.direct_gizmo_press = true;
  native.hide_gizmo_tooltips = true;
  native.operator_input_adjust = WM_native_ui_operator_input_adjust;
  native.keyconfig_default_ensure = keyconfig_default_ensure;
  /* What each key does here is decided with the Mac build too, see
   * #WM_native_ui_keymap_item_answer. */
  native.keymap_item_hidden = WM_native_ui_keymap_item_hidden;
  native.keymap_item_skipped = WM_native_ui_keymap_item_skipped;
  native.menu_popup = bridge_menu_popup;
  native.enum_popup = bridge_enum_popup;
  native.panel_popup = bridge_panel_popup;
  native.props_dialog = props_dialog;
  native.web_url_open = wm_apple_ios_open_web_url;
  native.interface_scale = WM_native_ui_interface_scale;
  /* The document's front door (ROUND5 9D.2): keys that open File › New and Open Recent. */
  native.document_command = WM_apple_ios_document_command;
  native.about_show = WM_apple_ios_about_show;
  native.app_name = WM_apple_ios_app_name;
  return native;
}

/** One pass of Blender's loop, run by GHOST on its engine thread, see #WM_main_loop_body. */
void engine_step(bContext *C)
{
  WM_native_ui_flush_commands(C);
  WM_apple_ios_finger_tweak_flush(C);
  wm_window_events_process(C);
  wm_event_do_handlers(C);
  wm_event_do_notifiers(C);
  WM_native_ui_image_update(C);
  /* Input is always taken, but drawing waits for the GPU to catch up: the next frame then shows
   * all input since, instead of queuing behind frames still to be rendered. GHOST wakes this loop
   * as a frame completes. */
  if (GHOST_ios_gpu_ready()) {
    WM_native_ui_storyboard_draw(C);
    wm_draw_update(C);
  }
}

/** Blender's answer about a point, for GHOST (ROUND5 13A). */
bool wm_apple_ios_touch_at(const void *window, const int x, const int y, GHOST_IOSTouchAnswer *r)
{
  NativeTouchAnswer answer;
  const bool found = WM_native_ui_touch_at(window, x, y, &answer);
  *r = GHOST_IOSTouchAnswer();
  r->place = int(answer.kind);
  r->navigation_part = answer.navigation_part;
  r->scroll_x = answer.scroll_x;
  r->scroll_y = answer.scroll_y;
  r->takes = answer.takes;
  r->modal = answer.modal;
  r->gizmo = answer.gizmo;
  STRNCPY(r->where, answer.where);
  return found;
}

GHOST_IOSNativeInterface ghost_interface_create()
{
  GHOST_IOSNativeInterface native;
  native.engine_step = engine_step;
  native.engine_idle_seconds = WM_native_ui_engine_idle_seconds;
  native.autosave_now = [](bContext *C) {
    /* Going to the background, where iOS may end the app: the session's log too. */
    WM_native_ui_session_log_flush(true);
    WM_apple_ios_autosave_now(C);
  };
  native.engine_busy = WM_native_ui_engine_busy;
  native.finger_point_pixels = wm_event_finger_point_pixels_set;
  native.pencil_hover = WM_native_ui_stylus_hover_set;
  native.pencil_roll = WM_native_ui_stylus_roll_set;
  native.navigation_hover = WM_native_ui_navigation_hover_set;
  native.view_roll = WM_native_ui_view_roll_enqueue;
  native.finger_tweak_active = WM_apple_ios_finger_tweak_active;
  native.finger_tweak_touch = WM_apple_ios_finger_tweak_touch;
  native.finger_tweak_holding = WM_apple_ios_finger_tweak_holding;
  native.touch_at = wm_apple_ios_touch_at;
  static_assert(int(NavigationGizmoPart::CameraLock) == GHOST_kIOSNavigationCameraLock &&
                int(NavigationGizmoPart::Axes) == GHOST_kIOSNavigationAxes);
  static_assert(int(NativeTouchKind::Navigation) == GHOST_kIOSPlaceNavigation &&
                int(NativeTouchKind::Interface) == GHOST_kIOSPlaceInterface &&
                int(NativeTouchKind::Canvas) == GHOST_kIOSPlaceCanvas &&
                int(NativeTouchKind::View3D) == GHOST_kIOSPlaceView3D);
  static_assert(int(ui::TouchTakes::Both) == GHOST_kIOSTakesBoth &&
                int(ui::TouchTakes::X) == GHOST_kIOSTakesX);
  native.launcher_controller = WM_apple_ios_launcher_controller;
  native.window_controller = WM_apple_ios_window_controller;
  native.document_window_changed = WM_apple_ios_document_window_changed;
  native.document_modified = WM_apple_ios_document_set_modified;
  native.open_url = WM_apple_ios_open_url;
  native.log = WM_native_ui_log;
  return native;
}

}  // namespace

void WM_apple_ios_native_interface_register()
{
  static const GHOST_IOSNativeInterface ghost = ghost_interface_create();
  GHOST_ios_native_interface_set(&ghost);
  static const wmNativeInterface native = native_interface_create();
  WM_native_interface_set(&native);
}

}  // namespace blender

#endif
