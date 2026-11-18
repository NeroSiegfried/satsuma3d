/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup GHOST
 *
 * The native interface on iPadOS and visionOS: the app's windows and controls around Blender's
 * viewport. GHOST runs Blender's loop on its own thread and turns touches and the Pencil into
 * events; the interface provides everything else, through these callbacks, which the window
 * manager registers before the app starts.
 *
 * UIKit types are passed as `void *` in the callbacks, so they can be set from C++.
 */

#pragma once

#include <atomic>
#include <memory>

#include "GHOST_Types.hh"

namespace blender {
struct bContext;
}
class GHOST_WindowIOS;

/** How a touch changed, see #GHOST_IOSNativeInterface::finger_tweak_touch. */
enum GHOST_IOSTouchPhase {
  GHOST_kIOSTouchBegan = 0,
  GHOST_kIOSTouchMoved,
  GHOST_kIOSTouchEnded,
  GHOST_kIOSTouchCancelled,
};

struct GHOST_IOSNativeInterface {
  /** One pass of Blender's main loop, with the interface's queued commands. */
  void (*engine_step)(blender::bContext *C) = nullptr;
  /** How long Blender's loop may sleep before its next timer. */
  double (*engine_idle_seconds)(blender::bContext *C) = nullptr;
  /** Save unsaved work now: iOS may end the app in the background. */
  void (*autosave_now)(blender::bContext *C) = nullptr;
  /**
   * Whether a stroke or other operator is running, holding data half changed: work for documents
   * and shortcuts waits for it to end.
   */
  bool (*engine_busy)(blender::bContext *C) = nullptr;

  /** An Apple Pencil hovers over the viewport, at a window position in pixels, or stopped. */
  void (*pencil_hover)(bool active, int x, int y) = nullptr;
  /** A Pencil touching the screen rolled to \a angle radians; \a down is false as it lifts. */
  void (*pencil_roll)(bool down, float angle, float tilt_x, float tilt_y) = nullptr;
  /** A pointer hovers over the navigation gizmo, or stopped. */
  void (*navigation_hover)(bool active) = nullptr;
  /** Two fingers twist the view by `angle`, in radians. */
  void (*view_roll)(float angle) = nullptr;

  /**
   * Fingers using the tool move objects, one under each finger, instead of sending Blender a
   * pointer: Tweak is the tool, in Object Mode. Their touches in the viewport go to
   * #finger_tweak_touch then.
   */
  bool (*finger_tweak_active)() = nullptr;
  /** A finger's touch \a id, a #GHOST_IOSTouchPhase, at a window position in pixels. */
  void (*finger_tweak_touch)(uint64_t id, int phase, int x, int y) = nullptr;
  /**
   * How many fingers hold objects, which keep other fingers from navigating. `r_landing`: fingers
   * landed that Blender has yet to look under, which may.
   */
  int (*finger_tweak_holding)(bool *r_landing) = nullptr;

  /** `UIViewController *`: the first window's content, before a document opens. */
  void *(*launcher_controller)() = nullptr;
  /**
   * `UIViewController<GHOST_IOSWindowController> *` for a document window, showing its
   * `MTKView *`. `r_root` is the controller to make the window's root, which may contain it.
   */
  void *(*window_controller)(void *metal_view, GHOST_WindowIOS *window, void **r_root) = nullptr;
  /** The document window was shown or hidden, see #GHOST_ios_document_window_set_visible. */
  void (*document_window_changed)() = nullptr;
  /** Blender has unsaved changes, or none: they make the open document save itself. */
  void (*document_modified)(bool modified) = nullptr;
  /** Open the document at an `NSURL *`, which the system handed to the app. */
  void (*open_url)(void *url) = nullptr;
  /** A line in the session's log, such as input arriving while something is presented above the
   * viewport (ROUND5 9G.1). */
  void (*log)(const char *kind, const char *text) = nullptr;
};

/** Register the native interface, before the app starts, see #GHOST_iosmain. */
void GHOST_ios_native_interface_set(const GHOST_IOSNativeInterface *native);
const GHOST_IOSNativeInterface *GHOST_ios_native_interface();

/** Show the document window over the launcher, or the launcher again. */
void GHOST_ios_document_window_set_visible(bool visible, bool animated);
bool GHOST_ios_document_window_visible();
/** `UIView *`: a snapshot of the document window, while it shows, or null. */
void *GHOST_ios_document_window_snapshot();

/** Whether the GPU has caught up with Blender's frames, so it may draw the next. Drawing further
 * ahead only queues frames, which then show late or not at all. */
bool GHOST_ios_gpu_ready();

/** Cleared when the window closes: native work for it, such as a dialog, must stop then. */
std::shared_ptr<std::atomic<bool>> GHOST_ios_window_alive(GHOST_WindowIOS *window);
/** Whether the window's viewport has shown its first frame. Never waits for Blender. */
bool GHOST_ios_window_presented_frame(GHOST_WindowIOS *window);
/** Press and release `key` in the window, as a keyboard would. */
void GHOST_ios_window_send_key(GHOST_WindowIOS *window, GHOST_TKey key);
/**
 * Press and release `key` with the modifiers held, as a hardware keyboard sends them, with the
 * pointer at the middle of the view: a script's `key` step (`Snapshots.swift`).
 */
void GHOST_ios_window_press_key(
    GHOST_WindowIOS *window, GHOST_TKey key, bool shift, bool ctrl, bool alt);
/** Shift or Control held down or let go, as a keyboard's would be. */
void GHOST_ios_window_hold_modifier(GHOST_WindowIOS *window, GHOST_TKey key, bool down);

#ifdef __OBJC__
#  import <UIKit/UIKit.h>

#  import "GHOST_IOSPencilMenu.hh"

/** The window's touch and Pencil input, which the interface adjusts. */
@protocol GHOST_IOSInputWindow <NSObject>
/** The menu the Pencil's squeeze opens, or none. */
- (void)setPencilContextMenu:(UIView<GHOSTIOSPencilMenu> *)menu;
/** A finger uses the active tool like the Pencil does, instead of navigating. */
- (void)setFingerToolEnabled:(BOOL)enabled;
/** End the Pencil's stroke, cancelling its tool, when a control takes the touch. */
- (void)cancelPencilStroke;
/** A tap on the navigation gizmo, which picks the axis under it. */
- (void)handleNavigationTap:(UITapGestureRecognizer *)gesture;
/**
 * A drag that began on the navigation gizmo (ROUND5 12A): the app's one orbit, as a finger's on
 * the view, turning about the view's centre. \a phase: 0 began, 1 moved, 2 ended (spins on with
 * \a velocity), 3 cancelled. \a point: the gizmo's centre; \a translation: the drag's travel since
 * it began; \a velocity: points a second; all in the view's points. Whether it was taken: the
 * input gate may refuse it.
 */
- (BOOL)navigationGizmoDrag:(int)phase
                         at:(CGPoint)point
                translation:(CGPoint)translation
                   velocity:(CGPoint)velocity;
@end

UIWindow<GHOST_IOSInputWindow> *GHOST_ios_window_native(GHOST_WindowIOS *window);
/** A point in the window's view to Blender's window pixels. */
CGPoint GHOST_ios_window_pixels(GHOST_WindowIOS *window, CGPoint point);
/** Files dropped on the window at a point in its view, such as from another app. */
void GHOST_ios_window_drop_files(GHOST_WindowIOS *window,
                                 NSArray<NSString *> *paths,
                                 CGPoint point);
/**
 * The input gate's answer at a point of the view, given as fractions of its width and height
 * (ROUND5 9G.1, decision 66): nil when Blender takes input there, otherwise why it does not, such
 * as "presented UIHostingController". Keys, touches, the Pencil, scroll, pinch, rotation and hover
 * all ask the same question; a check script's `gate` step writes this answer to the log.
 */
NSString *GHOST_ios_window_gate(GHOST_WindowIOS *window, CGPoint fraction);

/** A document window's view controller, see #GHOST_IOSNativeInterface::window_controller. */
@protocol GHOST_IOSWindowController <NSObject>
/** Blender is closing the window: stop calling into it. */
- (void)detachBlender;
@end
#endif
