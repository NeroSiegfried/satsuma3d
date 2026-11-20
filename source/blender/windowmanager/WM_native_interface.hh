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

#include "WM_document_command.hh"

#include "WM_types.hh"

namespace blender {

namespace ui {
enum class AlertIcon : int8_t;
struct Block;
}

struct PropertyRNA;
struct Report;
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

/**
 * A menu an operator built for Blender to pop up, as a native interface lists it (ROUND6 MODE-3):
 * its items in order, a heading where an item has no value.
 */
struct wmNativePopupMenu {
  struct Item {
    std::string label;
    /** What choosing it sends back, empty for a heading or a line of text. */
    std::string value;
    std::string icon;
  };
  /** Its title, as Blender writes it above the items, or empty. */
  std::string title;
  Vector<Item> items;
  /** How many items run something; its lines of text, for a popup that only says something. */
  int actions = 0;
  std::string text;
  /** Items it cannot list: fields, submenus built in place, items that cannot run now. */
  int left_out = 0;
};

/** The chosen action and the toggles as bits, in the order of #wmNativeAlert::toggles. */
using wmNativeAlertComplete = std::function<void(bContext *C, int action, uint64_t toggles)>;
using wmNativeAlertCancel = std::function<void(bContext *C)>;

struct wmNativeInterface {
  /** Notifiers were sent: whatever the native interface shows may have changed. */
  void (*state_changed)() = nullptr;
  /** Reports added to the window manager, at least `minimum_type`, for the interface to show. */
  void (*reports_added)(wmWindow *win, ReportList *reports, int minimum_type) = nullptr;
  /** A report added to the window manager's own list, by other than an operator's reports. */
  void (*report_added)(wmWindow *win, const Report *report) = nullptr;
  /** An operator finished, run by a person or a script rather than by another operator. */
  void (*operator_finished)(bContext *C, wmOperator *op) = nullptr;

  /**
   * The interface shows the last operation's properties itself: operators are registered for
   * redo, and Blender's Adjust Last Operation region never opens. False while Blender's own
   * interface is shown instead.
   */
  bool (*replaces_redo_panel)() = nullptr;
  /**
   * The screen is touched and has no hover (ROUND6 TOUCH-6): until Blender has seen a press, the
   * input is taken to be a touch. After that, the last press says (#WM_event_touch_input).
   */
  bool (*touch_screen)() = nullptr;
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
  /**
   * Whether what was pressed takes typed text from keys rather than from a text field (ROUND6
   * DESK-3): an editor whose key map has an active `TEXTINPUT` item that would run there (the Text
   * Editor, the Python Console, a text object, a sequencer text strip), or a button waiting for a
   * key to capture. A screen without a keyboard raises one that sends key events while it does.
   */
  void (*text_input_focus)(wmWindow *win, bool takes_text) = nullptr;
  /** Absolute pointer presses (a Pencil landing) activate the gizmo under them directly. */
  bool direct_gizmo_press = false;
  /**
   * The platform shows one window: an editor Blender would open in a window of its own opens full
   * screen with Back to Previous instead, for every caller of #WM_window_open_temp (ROUND6 DESK-5).
   */
  bool single_window = false;
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
   * Blender is about to pop up a region of its own (ROUND6 MODE-3): a menu an operator built
   * (`popup_menu_end`: \a block holds its items and title, \a title is empty) or a block a function builds
   * (`popup_block_invoke_ex`, `popup_block_ex`: \a block is null, \a op the operator that owns the
   * popup, if any). True when the interface took it, shown its own way or refused with a message:
   * Blender then opens nothing, and the interface calls \a release once, later, for what the popup
   * would have freed. False for Blender's popup.
   */
  bool (*popup_take)(bContext *C,
                     ui::Block *block,
                     wmOperator *op,
                     const char *title,
                     std::function<void(bContext *C)> release) = nullptr;
  /**
   * Blender created a popup region of its own (any menu, popover, pie or block): what the
   * interface did not take, counted and logged by it (ROUND6 MODE-3). \a what names its kind.
   */
  void (*popup_drawn)(bContext *C, const char *what) = nullptr;

  /**
   * A factor of the DPI Blender's interface is drawn at, see #WM_window_dpi_set_userdef: the
   * platform's own size for Blender's interface, which leaves Blender's Resolution Scale alone.
   */
  float (*interface_scale)() = nullptr;

  /** Open a web page in the platform's browser: Help's links, an add-on's documentation. */
  void (*web_url_open)(const char *url) = nullptr;

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
  /**
   * A key press matched \a kmi, which #keymap_item_hidden kept from Blender, and nothing else
   * handled it: the interface does its own version of the command or says where it is. Called
   * once per press, never for releases, repeats or mouse buttons.
   */
  void (*keymap_item_skipped)(bContext *C, const wmKeyMapItem *kmi) = nullptr;

  /**
   * The document window's route for a file command, see #wmDocumentCommand: the one front door,
   * also called by the commands' operators. True when the platform took the command.
   */
  bool (*document_command)(bContext *C, wmDocumentCommand command, const char *argument) = nullptr;

  /**
   * Show the app's own About, which takes the place of Blender's splash and About popups, also
   * from Blender's own menu in its own interface (ROUND5 9G.2, decision 35): their logo is
   * Blender's, not the app's.
   */
  void (*about_show)() = nullptr;
  /** The app's name, which its About item in Blender's own menu carries. */
  const char *(*app_name)() = nullptr;
  /**
   * Files dropped where nothing took them (ROUND6 FILES-8): said, as a drop that did nothing
   * would otherwise be silent. \a name is the first file's name, \a count how many there were.
   */
  void (*drop_unhandled)(bContext *C, const char *name, int count) = nullptr;
};

/** The registered native interface, or null for Blender's own. */
const wmNativeInterface *WM_native_interface();
void WM_native_interface_set(const wmNativeInterface *native);

/**
 * An operation that follows the pointer, started by \a event, should wait for the first press:
 * when a touch started it (a finger or the Pencil, which have no hover; in either interface) and
 * no button is held down (it came from a menu, a button or a key). That press is where it starts,
 * not a confirmation, and lifting confirms, as for a tool's drag. The event system does this for
 * every such operation (ROUND6 TOUCH-6, `wm_event_system.cc` "Touch Waits for the Press"); with
 * a null \a event, only whether the input is a touch.
 */
bool WM_native_awaits_press(const wmEvent *event);

}  // namespace blender
