/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * What the native interface's Swift code may call outside Swift. The bridge to Blender, shared
 * with any platform's interface, is `WM_native_ui.h`; the rest here is the iPad's own: its
 * windows, documents, icons and menus. None of it waits for Blender, see `release/ios/README.md`.
 */

#pragma once

#import <UIKit/UIKit.h>

#import "GHOST_IOSPencilMenu.hh"
#import "GHOST_IOSRuntime.hh"
#import "../intern/wm_apple_ios_volume.h"
#import "../WM_native_ui.h"

#ifdef __cplusplus
extern "C" {
#endif

/** The open document's file, or nil. */
NSURL *_Nullable wm_apple_ios_document_url(void);

/* Blender's window (`GHOST_WindowIOS`), see `wm_apple_ios_window.mm`. */
bool wm_apple_ios_window_presented_frame(void *_Nullable window);
CGPoint wm_apple_ios_window_pixels(void *_Nullable window, CGPoint point);
void wm_apple_ios_window_send_key(void *_Nullable window, const char *_Nonnull key);
/** A key pressed and let go with the modifiers held, as a keyboard sends it, by Blender's event
 * name (`U`, `F2`, `SPACE`), the pointer at the viewport's middle. False for a key it does not
 * know. */
bool wm_apple_ios_window_press_key(
    void *_Nullable window, const char *_Nonnull key, bool shift, bool ctrl, bool alt);
/** The input gate's answer at a point of the viewport, as fractions of its width and height:
 * nil when Blender takes input there, otherwise why not (ROUND5 9G.1), for a check's `gate`. */
NSString *_Nullable wm_apple_ios_window_gate(void *_Nullable window, CGPoint fraction);
/** Cancel every native dialog and alert shown or waiting, as their Cancel would; how many. For a
 * check's `dialog cancel` step. */
int wm_apple_ios_dialogs_cancel_all(void);
/** "shift" or "ctrl" held down or let go, for an operator running to read. */
void wm_apple_ios_window_hold_modifier(void *_Nullable window, const char *_Nonnull key, bool down);
/** Shift (0), Ctrl (1) or Alt (2) as a finger works the shell's button for it (ROUND6 TOUCH-8):
 * 0 finger down, 1 tapped, 2 lifted after holding, 3 the button went away. */
void wm_apple_ios_window_sticky_modifier(void *_Nullable window, int index, int action);
/** Two bits each for Shift, Ctrl, Alt: 0 off, 1 held, 2 latched, 3 locked. */
unsigned int wm_apple_ios_sticky_modifiers(void);
/** Whether a document is open that the launcher can go back from, and going back. */
bool wm_apple_ios_documents_available(void);
void wm_apple_ios_show_documents(id _Nullable sender);
/** Whether the launcher shows the document window, rather than its document browser. */
bool wm_apple_ios_document_window_visible(void);
/** A quick action's icon: Blender's for the operator, or a symbol, or none. */
UIImage *_Nullable wm_apple_ios_action_icon(NSString *_Nonnull op_name,
                                            NSString *_Nonnull property,
                                            NSString *_Nonnull value);
/** Blender's context menu for the viewport, resolved when it opens. */
UIMenu *_Nonnull wm_apple_ios_context_menu(void);
/** A tap on the navigation gizmo, which picks the axis under it. */
void wm_apple_ios_window_navigation_tap(void *_Nullable window,
                                        UITapGestureRecognizer *_Nonnull tap);
/** A drag that began on the navigation gizmo, the app's one orbit (ROUND5 12A): \a phase 0 began,
 * 1 moved, 2 ended (spins on at \a velocity), 3 cancelled; \a point the gizmo's centre and
 * \a translation the travel since it began, in the window's points. False when the input gate
 * refused it. */
bool wm_apple_ios_window_navigation_drag(void *_Nullable window,
                                         int phase,
                                         CGPoint point,
                                         CGPoint translation,
                                         CGPoint velocity);
/** A touch on one of the navigation gizmo's buttons (ROUND5 12D), given to Blender as a pointer:
 * \a phase 0 began, 1 moved, 2 ended, 3 cancelled, at \a point in the window's points, as the
 * window sends a finger's that begins there. False when no part is there or the input gate
 * refused it. */
bool wm_apple_ios_window_navigation_button(void *_Nullable window, int phase, CGPoint point);
/** Where Blender drew the navigation gizmo's axes in this window's last draw (ROUND5 14C): its
 * centre and radius in the window's points. False before it is drawn, or while it is hidden. */
bool wm_apple_ios_window_navigation_drawn(void *_Nullable window,
                                          CGPoint *_Nonnull r_center,
                                          CGFloat *_Nonnull r_radius);
/** A check script's finger on Blender's interface (ROUND5 13B, check 3): \a phase 0 lands, 1
 * moves, 2 lifts, 3 is cancelled, at \a point in the window's points. False when, as it lands,
 * the point is not interface or the gate is closed. */
bool wm_apple_ios_window_script_touch(void *_Nullable window, int phase, CGPoint point);
/** A check script's finger tap on the view where fingers move it (ROUND6 TOUCH-1). */
bool wm_apple_ios_window_script_view_tap(void *_Nullable window, CGPoint point);
/** The shell's hold on the view took the touch for its menu: the finger presses nothing more
 * (ROUND6 TOUCH-2). */
void wm_apple_ios_window_hold_took_touch(void *_Nullable window);
/** A check script's finger on the tool (ROUND6 TOUCH-2): \a phase 0 lands, 1 moves, 2 lifts, 3 a
 * second finger lands. */
bool wm_apple_ios_window_script_tool_finger(void *_Nullable window, int phase, CGPoint point);
/** Where a check script finds a place to touch (ROUND5 13B): the centre of the region \a where
 * (`TOPBAR HEADER`, `PROPERTIES WINDOW`) with \a button_type -1, or of its first (\a last: last)
 * button of that `ButtonType`, in the window's points. False when there is none. */
bool wm_apple_ios_window_touch_find(void *_Nullable window,
                                    const char *_Nonnull where,
                                    int button_type,
                                    bool last,
                                    CGPoint *_Nonnull r_point);
/** What Blender says is under \a point, in the window's points (ROUND5 13A), for the log. */
NSString *_Nonnull wm_apple_ios_window_touch_description(void *_Nullable window, CGPoint point);
/** End the Pencil's stroke, cancelling its tool, when a control takes the touch. */
void wm_apple_ios_window_cancel_pencil_stroke(void *_Nullable window);
/** One of Blender's icons by key (such as `tool.object.builtin.move`), or the symbol. */
UIImage *_Nullable wm_apple_ios_icon(NSString *_Nonnull key, NSString *_Nullable symbol);
/** A brush's preview, round, at a diameter in points. */
UIImage *_Nullable wm_apple_ios_brush_image(NSString *_Nonnull preview, CGFloat diameter);
/** The modifier keys held on a hardware keyboard, bits by GHOST's #GHOST_TModifierKey, whichever
 * window has the keyboard. */
unsigned int GHOST_ios_held_modifiers(void);
UIDocument *_Nullable wm_apple_ios_open_document(void);
/** Choose a template and create a new document, presented from `presenter`. */
void wm_apple_ios_new_document(UIViewController *_Nonnull presenter);
/** Save As (ROUND5 9D.2): the document saved and a copy exported, or Save a Copy of what is
 * loaded when it is not the document's, see `wm_apple_ios_blend_document.mm`. */
void wm_apple_ios_save_document_as(UIViewController *_Nullable presenter);
/** The document's file as it is now, for Share (ROUND6 SAFE-1): saved in place, or a fresh copy
 * of what is loaded when that cannot be written; nil after an alert saying why. */
void wm_apple_ios_share_document_file(UIViewController *_Nullable presenter,
                                      void (^_Nonnull done)(NSURL *_Nullable url));
/** What the header says about the open document while it is not saved, or nil (ROUND6 SAFE-1,
 * SAFE-2); tapping it says why again, with what can be done. */
NSString *_Nullable wm_apple_ios_document_status(void);
/** File › Restore Version from Opening (ROUND6 SAFE-5): asks, then goes back to the file as it
 * was when the document opened. */
void wm_apple_ios_restore_opening_version(void);
void wm_apple_ios_document_status_tapped(void);
/** A check launch's `document …` snapshot step (ROUND5 9D.5). */
void wm_apple_ios_document_check(NSString *_Nonnull step,
                                 void (^_Nonnull done)(NSString *_Nonnull answer));
void wm_apple_ios_save_template(NSString *_Nonnull title,
                                NSDictionary *_Nonnull presentation,
                                void (^_Nonnull completion)(NSString *_Nullable error));
void wm_apple_ios_window_set_finger_tool(void *_Nullable window, bool use_tool);
void wm_apple_ios_window_set_pencil_menu(void *_Nullable window,
                                         UIView<GHOSTIOSPencilMenu> *_Nullable menu);
/** Files dropped on the viewport, at `point` in its points. */
void wm_apple_ios_window_drop_files(void *_Nullable window,
                                    NSArray<NSString *> *_Nonnull paths,
                                    CGPoint point);
/** Blender's context menu in the Pencil's radial menu, for the window's viewport. */
NSObject<GHOSTIOSPencilMenuDelegate> *_Nonnull wm_apple_ios_pencil_menu_source(
    void *_Nullable window, UIView *_Nonnull viewport);
void wm_apple_ios_pencil_menu_source_detach(NSObject *_Nonnull source);
/** Shader compilation in Blender's current burst of work, and how long Blender has been held up.
 */
bool wm_apple_ios_shader_compilation(int *_Nonnull finished,
                                     int *_Nonnull total,
                                     double *_Nonnull busy_seconds);
/** Blender's menus in the iPadOS menu bar. */
void wm_apple_ios_build_menu_bar(id<UIMenuBuilder> _Nonnull builder, NSArray *_Nonnull items);
void wm_apple_ios_menu_bar_request(void (^_Nonnull completion)(NSArray *_Nullable items));
/** The document window's controller is closing. */
void wm_apple_ios_document_controller_closed(id _Nonnull controller);
/** Ask Blender to carry out one of the app's intents, see `bl_ui.native_intents`: `request` is
 * JSON, and `completion` gets Blender's JSON answer on the main queue, or nil when it had none. */
void wm_apple_ios_intent_perform(const char *_Nonnull request,
                                 void (^_Nonnull completion)(NSString *_Nullable answer));

#ifdef __cplusplus
}
#endif
