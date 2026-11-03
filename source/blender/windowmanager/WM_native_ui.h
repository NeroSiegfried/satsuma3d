/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * The bridge as a platform's own interface sees it, such as the iPad's SwiftUI one: commands it
 * sends Blender, and snapshots of Blender, as JSON, for it to show. Plain C, so any language can
 * call it: Swift through its bridging header, Kotlin or Java through JNI.
 *
 * The interface runs on its own thread. These functions only queue work for Blender's loop or
 * take the latest snapshot it published; none waits for Blender. Blender's loop runs the queued
 * work and publishes new snapshots, then tells the interface through `GHOST_mailbox_published`.
 *
 * Snapshots and menu results are returned as strings the caller owns, freed with
 * #WM_native_ui_json_free.
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
/** \name Commands
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
  /** Add without dragging: at the 3D cursor, or onto the active object for materials and node
   * groups. */
  WM_NATIVE_UI_ASSET_ADD = 4,
};

/** Change one of the interface's settings in Blender, see `bridge_setting_execute`. */
void WM_native_ui_setting_enqueue(const char *setting, const char *value);
/** A #WMNativeUISelectIntent, while the buttons are held. */
void WM_native_ui_select_intent_set(int intent);
/** A #WMNativeUIAssetDragPhase, at \a x, \a y in the window's pixels. \a asset_id is only needed
 * to begin a drag or add an asset. */
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
/** What the hovering stylus is over, as JSON. */
char *WM_native_ui_stylus_hover_copy_json(void);
/** A pointer hovers over the navigation gizmo, or stopped. */
void WM_native_ui_navigation_hover_set(bool active);

/** \} */

/* -------------------------------------------------------------------- */
/** \name Layout
 *
 * How much of Blender's window the interface covers, which Blender keeps its views and gizmos out
 * of.
 * \{ */

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
/** \name Snapshots
 *
 * The `take` functions return the latest snapshot once, and null while it is unchanged.
 * \{ */

/** Properties, the Outliner, and the editors the interface shows natively. */
char *WM_NATIVE_UI_NULLABLE WM_native_ui_panels_take_json(void);
/** One of Blender's menus to show where the pointer is: its name and place. */
char *WM_NATIVE_UI_NULLABLE WM_native_ui_menu_popup_take_json(void);
/** Free a snapshot or menu result. */
void WM_native_ui_json_free(char *WM_NATIVE_UI_NULLABLE json);

/** The Image Editor's picture when it changed: its image's name, straight RGBA top row first, as
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

/* -------------------------------------------------------------------- */
/** \name Menus
 * \{ */

/** Ask for one of Blender's menus by its JSON route, or run its item when \a execute; the answer
 * is taken with #WM_native_ui_menu_take_result. */
uint64_t WM_native_ui_menu_request(const char *route, bool execute);
/** As #WM_native_ui_menu_request, with Blender's cursor at \a x, \a y in the window's pixels,
 * for operators that follow the pointer from there, such as Bevel. */
uint64_t WM_native_ui_menu_at_position_request(const char *route, bool execute, int x, int y);
/** The menu as JSON once Blender answered the request, until then null. */
char *WM_NATIVE_UI_NULLABLE WM_native_ui_menu_take_result(uint64_t identifier);

/** \} */

#ifdef __clang__
#  pragma clang assume_nonnull end
#endif

#ifdef __cplusplus
}
#endif
