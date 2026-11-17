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

namespace blender {

struct ARegion;
struct bContext;
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
 * shown, for finding out afterwards what happened on a device. Written only while the platform's
 * interface shows, or with `PLATYPUS_SESSION_LOG` in the environment.
 */
void WM_native_ui_session_log(const char *kind, const char *text);
/** An operator finished, see #wmNativeInterface::operator_finished. */
void WM_native_ui_operator_finished(bContext *C, wmOperator *op);

/** \} */

/* -------------------------------------------------------------------- */
/** \name Input
 * \{ */

/** Whether a stylus hovers over the viewport. */
bool WM_native_ui_stylus_hover_active();
/** The barrel roll and tilt of a stylus touching the screen, false with none down. */
bool WM_native_ui_stylus_roll(float *r_angle, float r_tilt[2]);
/** What a drag with the Tweak tool does, see #wmNativeInterface::tweak_drag. */
void WM_native_ui_tweak_drag(bool *r_move, bool *r_roll, bool *r_tilt);
/** Held + and - buttons make a selection add or subtract, see #wmNativeInterface. */
void WM_native_ui_operator_input_adjust(bContext *C, wmOperator *op);

/** \} */

/* -------------------------------------------------------------------- */
/** \name Where the Interface Covers the Window
 * \{ */

/** Window pixels a panel covers at the bottom and right, which the 3D views leave out. */
float WM_native_ui_viewport_cover();
float WM_native_ui_viewport_trailing_cover();
/** The lowest and highest region pixels the navigation gizmo may use, clear of the interface. */
int WM_native_ui_bottom_tray_ymin(const wmWindow *win, const ARegion *region);
int WM_native_ui_top_bar_ymax(const wmWindow *win, const ARegion *region);
/** The navigation gizmo's corner of the viewport. */
bool WM_native_ui_navigation_top();
/** The touch interface's minimal navigation gizmo (dots that grow under a hover, no letters, no
 * buttons beside it) rather than Blender's own, as on the desktop. */
bool WM_native_ui_navigation_minimal();
bool WM_native_ui_navigation_left();
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
/** Open a web page in the platform's browser, see #wmNativeInterface::web_url_open. */
void WM_OT_native_url_open(wmOperatorType *ot);

/** \} */

}  // namespace blender
