/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * The bridge as a platform's own interface sees it, such as the iPad's SwiftUI one: the views it
 * shows and the commands it sends, see `native_ui/README.md`; the input it passes on, such as a
 * stylus hovering; and how much of the window it covers. Plain C, so any language can call it:
 * Swift through its bridging header, Kotlin or Java through JNI.
 *
 * The interface runs on its own thread. These functions only queue work for Blender's loop or
 * take what it published; none waits for Blender. Blender's loop runs the queued work and
 * publishes updates, then tells the interface through `GHOST_mailbox_published`.
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef __clang__
#  pragma clang assume_nonnull begin
#  define WM_NATIVE_UI_NULLABLE _Nullable
#  define WM_NATIVE_UI_NONNULL _Nonnull
#else
#  define WM_NATIVE_UI_NULLABLE
#  define WM_NATIVE_UI_NONNULL
#endif

/* -------------------------------------------------------------------- */
/** \name Views
 *
 * What an interface shows, as views it subscribes to: Blender sends each whole once, then only
 * what changed, as FlatBuffers of `protocol.fbs` in `native_ui/`. The interface sends commands
 * aimed at a view's nodes back.
 * \{ */

/** A batch of updates taken by the interface, read in place until freed. */
typedef struct WMNativeUIBuffer WMNativeUIBuffer;

/**
 * Show a view, from a `Subscribe` buffer: its updates carry the number returned, 0 when the
 * buffer is not a `Subscribe`. The buffer is copied.
 */
uint32_t WM_native_ui_subscribe(const uint8_t *request, size_t size);
void WM_native_ui_unsubscribe(uint32_t subscription);
/** Send a `Commands` buffer, which is copied. */
void WM_native_ui_send(const uint8_t *commands, size_t size);
/**
 * The next batch of updates, an `Updates` buffer, or null when none waits. Batches are taken in
 * order, each built on the ones before, by one thread only.
 */
WMNativeUIBuffer *WM_NATIVE_UI_NULLABLE WM_native_ui_take_updates(void);
const uint8_t *WM_native_ui_buffer_data(const WMNativeUIBuffer *buffer, size_t *r_size);
void WM_native_ui_buffer_free(WMNativeUIBuffer *buffer);

/** \} */

/* -------------------------------------------------------------------- */
/** \name Input
 *
 * What the interface's input does to Blender's, beside the views' commands.
 * \{ */

/** What held + and - buttons make the next selection or stroke do, see
 * #WM_native_ui_select_intent_set. */
enum WMNativeUISelectIntent {
  WM_NATIVE_UI_SELECT_INTENT_NONE = 0,
  WM_NATIVE_UI_SELECT_INTENT_ADD = 1,
  WM_NATIVE_UI_SELECT_INTENT_SUBTRACT = 2,
  WM_NATIVE_UI_SELECT_INTENT_SMOOTH = 3,
};

/** How an asset dragged from the interface's asset pane moved, see #WM_native_ui_asset_drag. */
enum WMNativeUIAssetDragPhase {
  WM_NATIVE_UI_ASSET_DRAG_BEGIN = 0,
  WM_NATIVE_UI_ASSET_DRAG_MOVE = 1,
  WM_NATIVE_UI_ASSET_DRAG_DROP = 2,
  WM_NATIVE_UI_ASSET_DRAG_CANCEL = 3,
};

/** A #WMNativeUISelectIntent, while the buttons are held. */
void WM_native_ui_select_intent_set(int intent);
/** An asset dragged from the interface's asset pane, a #WMNativeUIAssetDragPhase, at \a x, \a y
 * in the window's pixels. \a asset_id, its row's key in the `assets` view, is only needed to begin
 * a drag. */
void WM_native_ui_asset_drag(int phase, const char *WM_NATIVE_UI_NULLABLE asset_id, int x, int y);
/** Two fingers twist the view by \a angle, in radians. */
void WM_native_ui_view_roll_enqueue(float angle);

/** \} */

/* -------------------------------------------------------------------- */
/** \name Stylus and Pointer
 * \{ */

/** A stylus hovers over the viewport, at a window position in pixels, or stopped. */
void WM_native_ui_stylus_hover_set(bool active, int x, int y);
/** A stylus touching the screen rolled to \a angle radians, tilted by \a tilt_x and \a tilt_y;
 * \a down is false as it lifts. */
void WM_native_ui_stylus_roll_set(bool down, float angle, float tilt_x, float tilt_y);
/** A pointer hovers over the navigation gizmo, or stopped. */
void WM_native_ui_navigation_hover_set(bool active);

/** \} */

/* -------------------------------------------------------------------- */
/** \name Layout
 *
 * How much of Blender's window the interface covers, which Blender keeps its views and gizmos out
 * of.
 * \{ */

/** A line of the session's log (see `WM_native_ui_session_log`), from the interface's own code:
 * \a kind such as "layout" or "reveal". Safe from any thread. */
void WM_native_ui_log(const char *kind, const char *text);
/** Write the session's log out now and give its file's path in \a path, for About's Share
 * Session Log (ROUND5 8C). False when there is no log to share. */
bool WM_native_ui_session_log_file(char *path, size_t path_size);
/** Input arrived (a key, a touch, the Pencil, a scroll, a click): an `active` line in the session's
 * log, at most once a minute (ROUND5 10E). Safe from any thread. */
void WM_native_ui_session_log_active(void);

/** How much of the window's height, from the top, the interface's top bar covers. */
void WM_native_ui_top_bar_set(float fraction);
/** How much of the window's height, from the bottom, the asset pane and timeline cover. */
void WM_native_ui_bottom_tray_set(float fraction);
/** How many pixels of the window's bottom a panel covers, such as the node editor, which the
 * viewport is shortened by. */
void WM_native_ui_viewport_cover_set(float pixels);
/** How many pixels of the window's right a panel covers, such as the Image Editor. */
void WM_native_ui_viewport_trailing_cover_set(float pixels);

/** \} */

/* -------------------------------------------------------------------- */
/** \name Pictures
 *
 * What a view shows as pixels, too large to send as its nodes: taken once each time it changed.
 * \{ */

/** The Image Editor's picture, while the `image` view shows, when it changed: its image's name, straight RGBA top row first, as
 * sent and as large as the image is. No pixels without an image. Each is freed with `free`. */
bool WM_native_ui_image_take_pixels(char *WM_NATIVE_UI_NULLABLE *WM_NATIVE_UI_NONNULL r_name,
                                    uint8_t *WM_NATIVE_UI_NULLABLE *WM_NATIVE_UI_NONNULL r_rgba,
                                    int *r_width,
                                    int *r_height,
                                    int *r_full_width,
                                    int *r_full_height);
/** The UV edges over it when they changed, two points each, freed with `free`. */
bool WM_native_ui_image_take_uvs(float *WM_NATIVE_UI_NULLABLE *WM_NATIVE_UI_NONNULL r_segments,
                                 int *r_count);

/** \} */

#ifdef __clang__
#  pragma clang assume_nonnull end
#endif

#ifdef __cplusplus
}
#endif
