/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * The bridge to a platform's own interface as Blender's code sees it: running what the interface
 * sent on Blender's loop, and where the interface covers Blender's window. The interface's side is
 * `WM_native_ui.h`. Only built with `WITH_NATIVE_UI`.
 */

#pragma once

#include <string>

namespace blender {

struct ARegion;
struct bContext;
struct wmKeyMapItem;
struct wmOperator;
struct wmOperatorType;
struct wmNotifier;
struct wmWindow;

/* -------------------------------------------------------------------- */
/** \name Blender's Loop
 * \{ */

/** Views whose data a notifier says changed are built again, see `WM_native_ui_views.hh`. */
void WM_native_ui_views_notify(const wmNotifier &note);
/**
 * Take subscriptions and commands, and send updates of views that changed, on each pass of
 * Blender's loop, with the window and its 3D View current, see #WM_native_ui_flush_commands.
 */
void WM_native_ui_views_flush(bContext *C);
/** How long Blender's loop may sleep before a view waiting to be built is due. */
double WM_native_ui_views_idle_seconds();
/** Add the views of the interface around the viewport, at startup. */
void WM_native_ui_views_register();

/** Run the commands the interface queued, on each pass of Blender's loop. */
void WM_native_ui_flush_commands(bContext *C);
/** Something in Blender changed (notifiers were sent): describe it to the interface. */
void WM_native_ui_tag_changed();
/** Lay out Blender's window for the interface, as a file opens. */
void WM_native_ui_ensure_layout(bContext *C);
void WM_native_ui_storyboard_draw(bContext *C);
void WM_native_ui_image_update(bContext *C);
/** How long Blender's loop may sleep before the interface needs it again. */
double WM_native_ui_engine_idle_seconds(bContext *C);
/** Whether a stroke or other modal operator runs, holding data half changed. */
bool WM_native_ui_engine_busy(bContext *C);
/**
 * A value the interface changed while a stroke or other operator runs: its undo step waits for
 * the operator to end. True when the step was deferred.
 */
bool WM_native_ui_undo_push_defer(bContext *C, const char *name);
/**
 * Register the bundled "Starter" asset library, or refresh its path, since the app's install
 * location may change with every install. Call after loading the preferences.
 */
void WM_native_ui_starter_library_ensure();

/**
 * Whether Blender's own interface shows instead of the platform's, as on a desktop computer. Also
 * true when no platform interface is registered.
 */
bool WM_native_ui_desktop_mode();

/**
 * Say something to the person in the interface's own way, briefly and without stopping them: what
 * a report says, or why a command did not run. \a level is a report type, #RPT_INFO or
 * #RPT_WARNING. \a button names something the interface offers beside it, or is empty.
 */
void WM_native_ui_notice(int level, const char *text, const char *button = "");
/**
 * A line of the session's log, a text file in the temporary folder that says what was run and
 * shown, for finding out afterwards what happened on a device. Written in both interfaces.
 */
void WM_native_ui_session_log(const char *kind, const char *text);
/** Write what the session's log holds: at once with \a force, as the app goes to the background
 * or ends, otherwise only when it last wrote ten seconds ago. */
void WM_native_ui_session_log_flush(bool force);
/** How many times the log was written, for tests. */
int WM_native_ui_session_log_writes();
/** An operator finished, see #wmNativeInterface::operator_finished. */
void WM_native_ui_operator_finished(bContext *C, wmOperator *op);

/** \} */

/* -------------------------------------------------------------------- */
/** \name Input
 * \{ */

/**
 * What Blender's interface is drawn at, as a factor of its DPI, see
 * #wmNativeInterface::interface_scale: the platform's own setting while Blender's own interface
 * shows, 1 while the platform's shows (its viewport keeps its size).
 */
float WM_native_ui_interface_scale();

/** Whether a stylus hovers over the viewport. */
bool WM_native_ui_stylus_hover_active();
/** The barrel roll and tilt of a stylus touching the screen, false with none down. */
bool WM_native_ui_stylus_roll(float *r_angle, float r_tilt[2]);
/** What a drag with the Tweak tool does, see #wmNativeInterface::tweak_drag. */
void WM_native_ui_tweak_drag(bool *r_move, bool *r_roll, bool *r_tilt);
/** Held + and - buttons make a selection add or subtract, see #wmNativeInterface. */
void WM_native_ui_operator_input_adjust(bContext *C, wmOperator *op);

/**
 * What a key-map item's key does while the platform's interface shows (ROUND5 9A): never nothing.
 * It runs as on the desktop, and what it opens shows natively, or it is kept from Blender, as it
 * would show Blender's own interface over the platform's: then the interface does its own version
 * of the command, or says where the command is.
 */
struct WMNativeKeyAnswer {
  enum class Kind {
    /** As on the desktop. */
    Runs,
    /** A menu or pie, drawn natively, see `bridge_menu_popup`. */
    Menu,
    /** An operator's choice of its enum items, see `bridge_enum_popup`. */
    Choice,
    /** An operator's properties: asked in a native dialog, or adjusted after it runs. */
    Dialog,
    /** Rename Active Item's field (F2), see `bridge_panel_popup`. */
    Rename,
    /** Kept from Blender: the interface's own version of the command, #command. */
    StandIn,
    /** Kept from Blender: the interface says so, #text. */
    Says,
    /**
     * A file command (ROUND5 9D.4): the document's own route, see #wmDocumentCommand, named by
     * #command (`new`, `open`, `revert`, `save`, `save_as`, `quit`). An operator runs and its
     * invoke takes the route; File › New's and Open Recent's menus are kept from Blender (#kept)
     * and the route is taken at once; the File context menu (F4) shows, #menu, every file command
     * in it taking the route (`menu`).
     */
    Document,
  };
  Kind kind = Kind::Runs;
  /** A stand-in's command, one of `release/ios/key_stand_ins.txt`. */
  std::string command;
  /** What is said, for #Kind::Says, when asked with a context. */
  std::string text;
  /** The menu a #Kind::Menu item opens. */
  std::string menu;
  /** A #Kind::Document item kept from Blender, the route taken instead. */
  bool kept = false;

  bool hidden() const
  {
    return kind == Kind::StandIn || kind == Kind::Says || (kind == Kind::Document && kept);
  }
};

/**
 * What \a kmi's key does in the platform's interface. \a C may be null, when only whether it is
 * kept from Blender matters: the said text is then left empty. In Blender's own interface every
 * key runs.
 */
WMNativeKeyAnswer WM_native_ui_keymap_item_answer(bContext *C, const wmKeyMapItem *kmi);
/** Whether \a idname is a file command, which a document window takes its own route for
 * (ROUND5 9D): run it through its invoke, never its exec, so the route is taken. */
bool WM_native_ui_is_document_command(const char *idname);
/** Whether a key or mouse button skips \a kmi, see #wmNativeInterface::keymap_item_hidden. */
bool WM_native_ui_keymap_item_hidden(const wmKeyMapItem *kmi);
/** A key press matched only items kept from Blender, \a kmi first: do or say what it answers,
 * see #wmNativeInterface::keymap_item_skipped. */
void WM_native_ui_keymap_item_skipped(bContext *C, const wmKeyMapItem *kmi);

/** \} */

/* -------------------------------------------------------------------- */
/** \name Where the Interface Covers the Window
 * \{ */

/** Window pixels a panel covers at the bottom and right, which the 3D views leave out. */
float WM_native_ui_viewport_cover();
float WM_native_ui_viewport_trailing_cover();
/** See #WM_native_ui_viewport_insets_set: from the window's left, and from the 3D View's right. */
float WM_native_ui_viewport_leading_inset();
float WM_native_ui_viewport_trailing_inset();
/** The sidebars' insets as they apply to \a region, in its own pixels: only a 3D View's main
 * region, in the iPad interface, while a fifth of it at least is left showing. False when none. */
bool WM_native_ui_view3d_insets(const ARegion *region, int *r_leading, int *r_trailing);
/** What framing keeps clear of in \a region (ROUND5 9G.4, 9G.5): the sidebars, as
 * #WM_native_ui_view3d_insets, the top bar, as the navigation gizmo does
 * (#WM_native_ui_top_bar_ymax), and the band the controls along the bottom stand in
 * (#WM_native_ui_bottom_controls_set). True for a 3D View's main region in the iPad interface, with
 * no insets too; false in the Desktop Interface and for any other region. */
bool WM_native_ui_view3d_frame_insets(const wmWindow *win,
                                      const ARegion *region,
                                      int *r_leading,
                                      int *r_trailing,
                                      int *r_top,
                                      int *r_bottom);
/** The lowest and highest region pixels the navigation gizmo may use, clear of the interface. */
int WM_native_ui_bottom_tray_ymin(const wmWindow *win, const ARegion *region);
int WM_native_ui_top_bar_ymax(const wmWindow *win, const ARegion *region);
/** The navigation gizmo's corner of the viewport. */
bool WM_native_ui_navigation_top();
/** The touch interface's minimal navigation gizmo (dots that grow under a hover, no letters, no
 * buttons beside it) rather than Blender's own, as on the desktop. */
bool WM_native_ui_navigation_minimal();
bool WM_native_ui_navigation_left();
/**
 * Note where every navigation gizmo's parts were placed in the windows' last draw (ROUND5 12D),
 * and what a finger would meet anywhere in them (13A), for #WM_native_ui_touch_at. On Blender's
 * loop, after drawing.
 */
void WM_native_ui_navigation_parts_update(bContext *C);

/** What lies under a point of a window, for a finger (ROUND5 13A, decision 84). */
enum class NativeTouchKind : int8_t {
  /** Nothing of Blender's: outside every area. */
  None = 0,
  /** A 3D View's main region: the app's navigation and the touch setting, unchanged (T5). */
  View3D = 1,
  /** Another editor's main region (Image, UV, nodes, curves, the timeline, ...): a canvas (T5). */
  Canvas = 2,
  /** Blender's interface: a header, a toolbar, a sidebar, Properties, Preferences, a menu (T1-T3). */
  Interface = 3,
  /** A part of a navigation gizmo (12D): given to Blender as a pointer. */
  Navigation = 4,
};
struct NativeTouchAnswer {
  NativeTouchKind kind = NativeTouchKind::None;
  /** For #NativeTouchKind::Navigation: a #NavigationGizmoPart. */
  int navigation_part = 0;
  /** Whether what is under the point scrolls along x and along y now: its content is longer than
   * the region, or the menu longer than the room it has. */
  bool scroll_x = false;
  bool scroll_y = false;
  /** Which directions the control under the point takes for itself, see #ui::TouchTakes. */
  int8_t takes = 0;
  /** The control's #ButtonType, or -1 where there is none. */
  int8_t button_type = -1;
  /** The editor and region, for the session log: `PROPERTIES WINDOW`, `TOPBAR HEADER`, `MENU`. */
  char where[40] = "";
};
/**
 * What a finger meets at \a x, \a y in the GHOST window's client pixels (the window as a
 * `GHOST_IWindow *`), as of its last draw: a navigation gizmo's part first, then a popup or menu on
 * top, then the area's region where Blender would send an event there. False where the window has
 * not been drawn. Safe from any thread: the window asks it on the main thread as a touch begins.
 */
bool WM_native_ui_touch_at(const void *ghost_window, int x, int y, NativeTouchAnswer *r_answer);
/**
 * Where a check script finds a place to touch (ROUND5 13B, check 3): the centre of the region
 * \a where (as #NativeTouchAnswer::where names it) with \a button_type -1, or of its first (or
 * \a last) button of that #ButtonType, in the GHOST window's client pixels. False when there is
 * none.
 */
bool WM_native_ui_touch_find(
    const void *ghost_window, const char *where, int button_type, bool last, int r_client_xy[2]);
/** Whether a pointer hovers over the navigation gizmo, which then grows its axes. */
bool WM_native_ui_navigation_hover_active();
/** Redraw the navigation gizmo while its axes animate. */
void WM_native_ui_navigation_redraw_request();

/** \} */

/* -------------------------------------------------------------------- */
/** \name Operators
 * \{ */

/** Switch between the platform's interface and Blender's own, as on a desktop computer. */
void WM_OT_native_interface_toggle(wmOperatorType *ot);
/** The size of Blender's own interface, the platform's setting, see #WM_native_ui_interface_scale. */
void WM_OT_native_interface_scale(wmOperatorType *ot);
/** Open a web page in the platform's browser, see #wmNativeInterface::web_url_open. */
void WM_OT_native_url_open(wmOperatorType *ot);

/** \} */

}  // namespace blender
