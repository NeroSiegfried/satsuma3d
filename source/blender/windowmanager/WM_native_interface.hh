/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * A platform's own interface in place of parts of Blender's, such as the native iPad and Apple
 * Vision Pro interface: file selection, confirmation, the Adjust Last Operation panel, and input
 * without a hovering pointer. The platform registers it at startup; every member is optional,
 * and without one Blender's own interface is used.
 */

#pragma once

#include <cstdint>
#include <functional>
#include <optional>
#include <string>

#include "BLI_vector.hh"

#include "WM_types.hh"

namespace blender {

namespace ui {
enum class AlertIcon : int8_t;
}

struct PropertyRNA;
struct ReportList;
struct bContext;
struct wmKeyConfig;
struct wmKeyMapItem;
struct wmOperator;
struct wmWindow;

/** An alert as a platform shows it natively, in place of a popup of Blender's. */
struct wmNativeAlert {
  enum class Role { Default, Cancel, Destructive };
  struct Action {
    std::string title;
    Role role = Role::Default;
  };
  struct Toggle {
    std::string title;
    bool selected = false;
  };
  std::string title;
  std::string message;
  Vector<Action> actions;
  Vector<Toggle> toggles;
  /** The action Return chooses, or -1. */
  int preferred_action = -1;
};

/** The chosen action and the toggles as bits, in the order of #wmNativeAlert::toggles. */
using wmNativeAlertComplete = std::function<void(bContext *C, int action, uint64_t toggles)>;
using wmNativeAlertCancel = std::function<void(bContext *C)>;

struct wmNativeInterface {
  /** Notifiers were sent: whatever the native interface shows may have changed. */
  void (*state_changed)() = nullptr;
  /** Reports added to the window manager, at least `minimum_type`, for the interface to show. */
  void (*reports_added)(wmWindow *win, ReportList *reports, int minimum_type) = nullptr;

  /**
   * The interface shows the last operation's properties itself: operators are registered for
   * redo, and Blender's Adjust Last Operation region never opens. False while Blender's own
   * interface is shown instead.
   */
  bool (*replaces_redo_panel)() = nullptr;
  void (*operator_registered)(bContext *C, wmOperator *op) = nullptr;
  void (*operator_freed)(wmOperator *op) = nullptr;
  void (*redo_cleared)() = nullptr;
  /** Adjust Last Operation was asked for (F9, the Edit menu): opens the interface's own. */
  void (*redo_show)(bContext *C) = nullptr;

  /** Select files with the platform's own browser; true when it took over the operator. */
  bool (*fileselect_begin)(bContext *C, wmOperator *op) = nullptr;
  bool (*fileselect_active)(wmOperator *op) = nullptr;
  wmOperatorStatus (*fileselect_exec)(bContext *C, wmOperator *op) = nullptr;
  void (*fileselect_cancel)(wmOperator *op) = nullptr;

  /**
   * Show an alert natively. `key` names it, so the same alert does not open twice. False when it
   * could not be shown, and Blender's own popup should be used.
   */
  bool (*alert)(bContext *C,
                const wmNativeAlert &alert,
                wmNativeAlertComplete complete,
                wmNativeAlertCancel cancel,
                const char *key) = nullptr;

  /** Confirm an operator with a native alert, see #WM_operator_confirm_ex. */
  std::optional<wmOperatorStatus> (*confirm)(bContext *C,
                                             wmOperator *op,
                                             const char *title,
                                             const char *message,
                                             const char *confirm_text,
                                             ui::AlertIcon icon,
                                             bool cancel_default) = nullptr;

  /**
   * Touch has no hover: a pointer is only over the view while something hovers, such as an
   * Apple Pencil. Paint cursors and the circle select outline show only then.
   */
  bool (*pointer_hovering)() = nullptr;
  /** Absolute pointer presses (a Pencil landing) activate the gizmo under them directly. */
  bool direct_gizmo_press = false;
  /** Gizmos show no tooltips, as nothing hovers long over them. */
  bool hide_gizmo_tooltips = false;

  /**
   * An operator starts from input: the interface may change its properties first, as the iPad's
   * held + and - buttons make a selection add or subtract, or a brush stroke go either way.
   */
  void (*operator_input_adjust)(bContext *C, wmOperator *op) = nullptr;

  /**
   * Show one of Blender's menus, by its name, natively in place of Blender's popup, where the
   * pointer is. False to show Blender's own.
   */
  bool (*menu_popup)(bContext *C, const char *menu) = nullptr;
  /**
   * Choose one of an operator's enum items natively, in place of Blender's popup menu of them,
   * where the pointer is; the choice runs the operator anew. False to show Blender's own.
   */
  bool (*enum_popup)(bContext *C, wmOperator *op, PropertyRNA *prop) = nullptr;
  /**
   * Ask for an operator's properties natively, in place of Blender's dialog, before running it.
   * The interface owns the operator from here: it runs it on OK, frees it on Cancel. False to show
   * Blender's own.
   */
  bool (*props_dialog)(bContext *C,
                       wmOperator *op,
                       const std::string &title,
                       const std::string &confirm,
                       const std::string &message) = nullptr;
  /** Show one of Blender's panels natively, such as Rename Active Item's. False for Blender's. */
  bool (*panel_popup)(bContext *C, const char *panel) = nullptr;

  /**
   * The barrel roll of a Pencil touching the screen, in radians, for moving things to turn them
   * too. False with no Pencil down.
   */
  bool (*pencil_roll)(float *r_angle, float r_tilt[2]) = nullptr;

  /**
   * What a drag with the Tweak tool does, as its settings in the top bar have it: move things, and
   * turn them as the Pencil rolls or tilts. Null to do all of these.
   */
  void (*tweak_drag)(bool *r_move, bool *r_roll, bool *r_tilt) = nullptr;

  /** Ensure the platform's own items in the default key configuration. */
  void (*keyconfig_default_ensure)(wmKeyConfig *keyconf) = nullptr;
  /**
   * Whether a key or mouse button skips a key-map item: its operator would show Blender's own
   * interface, such as a menu, pie, popup or sidebar, which the native interface shows its own
   * way.
   */
  bool (*keymap_item_hidden)(const wmKeyMapItem *kmi) = nullptr;
};

/** The registered native interface, or null for Blender's own. */
const wmNativeInterface *WM_native_interface();
void WM_native_interface_set(const wmNativeInterface *native);

}  // namespace blender
