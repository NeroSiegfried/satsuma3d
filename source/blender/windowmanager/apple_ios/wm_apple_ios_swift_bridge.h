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
