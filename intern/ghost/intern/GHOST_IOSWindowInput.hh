/* SPDX-FileCopyrightText: 2025 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup GHOST
 *
 * The iOS window's input: touches, the Pencil and gestures, turned into Blender's events.
 */

#pragma once

#include "GHOST_ContextIOS.hh"
#include "GHOST_Debug.hh"
#include "GHOST_EventButton.hh"
#include "GHOST_EventCursor.hh"
#include "GHOST_EventDragnDrop.hh"
#include "GHOST_EventKey.hh"
#include "GHOST_EventTouch.hh"
#include "GHOST_EventTrackpad.hh"
#include "GHOST_EventWheel.hh"
#include "GHOST_IOSNativeInterface.hh"
#import "GHOST_IOSPencilMenu.hh"
#import "GHOST_IOSPlatform.hh"
#include "GHOST_IOSRuntime.hh"
#include "GHOST_SystemIOS.hh"
#include "GHOST_WindowIOS.hh"
#import <GameController/GameController.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <UIKit/UIPencilInteraction.h>
#import <objc/runtime.h>
#include <unordered_map>
// #define IOS_INPUT_LOGGING
#if defined(IOS_INPUT_LOGGING)
#  define IOS_INPUT_LOG(...) NSLog(__VA_ARGS__)
#else
#  define IOS_INPUT_LOG(...)
#endif
// #define IOS_WINDOW_LOGGING
#if defined(IOS_WINDOW_LOGGING)
#  define IOS_WINDOW_LOG(...) NSLog(__VA_ARGS__)
#else
#  define IOS_WINDOW_LOG(...)
#endif

/** Blender's main window, which shows the open document over the launcher. */
extern UIWindow *document_window;

struct TouchData {
  CGPoint pos;
  bool part_of_multitouch = false;
};

typedef struct UserInputEvent {
  enum EventTypes {
    CURSOR_MOVE,
    ORBIT_GESTURE,
    PAN_GESTURE,
    PAN_GESTURE_TWO_FINGERS,
    PINCH_GESTURE,
    LEFT_BUTTON_DOWN,
    LEFT_BUTTON_UP,
    CANCEL_TOOL,
  };
  EventTypes event_list[10];
  int num_events;
  CGPoint location;
  CGPoint translation;
  CGFloat distance;
  bool pencil_used;
  uint64_t gesture_id = 0;
  /** An orbit that began on the navigation gizmo (ROUND5 12A). */
  bool from_gizmo = false;

  UserInputEvent(CGPoint *loc, CGPoint *tran, CGFloat *dist, bool pencil)
  {
    num_events = 0;
    location = loc ? *loc : CGPointMake(-1.0f, -1.0f);
    translation = tran ? *tran : CGPointMake(0.0f, 0.0f);
    distance = dist ? *dist : 0.0f;
    pencil_used = pencil;
  }

  void add_event(EventTypes event_type)
  {
    GHOST_ASSERT(num_events <= sizeof(event_list) / sizeof(*event_list),
                 "add_event: Failed to add event");
    event_list[num_events] = event_type;
    num_events++;
  }

  NSString *getEventTypeDesc(EventTypes event_type) const
  {
    switch (event_type) {
      case CURSOR_MOVE:
        return @"CM";
      case ORBIT_GESTURE:
        return @"ORBIT";
      case PAN_GESTURE:
        return @"PAN";
      case PAN_GESTURE_TWO_FINGERS:
        return @"PAN2F";
      case PINCH_GESTURE:
        return @"PINCH";
      case LEFT_BUTTON_DOWN:
        return @"LB-DOWN";
      case LEFT_BUTTON_UP:
        return @"LB-UP";
      case CANCEL_TOOL:
        return @"CANCEL";
    }
    BLI_assert_unreachable();
    return @"Event undefined";
  }

} UserInputEvent;

@interface GHOSTUITapGestureRecognizer : UITapGestureRecognizer

- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window;

@end
/* GHOSTUITapGesture interface for capturing taps. */
@interface GHOSTUIPanGestureRecognizer : UIPanGestureRecognizer
{
  CGPoint cached_translation;
}
- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window;
- (CGPoint)getScaledTranslation:(GHOST_WindowIOS *)window;

- (void)setCachedTranslation:(CGPoint)translation;
- (CGPoint)getCachedTranslation;
@end
@interface GHOSTUIHoverGestureRecognizer : UIHoverGestureRecognizer
- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window;
@end
@interface GHOSTUIPinchGestureRecognizer : UIPinchGestureRecognizer
{
  CGFloat cached_distance;
}
- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window touch_id:(int)touch_id;
- (CGFloat)getScaledDistance:(GHOST_WindowIOS *)window;
- (CGPoint)getPinchMidpoint:(GHOST_WindowIOS *)window;
- (void)setCachedDistance:(CGFloat)distance;
- (CGFloat)getCachedDistance;
@end

/* GHOSTUIWindow interface. */
#if defined(APPLE_TARGET_VISIONOS)
@interface GHOSTUIWindow : UIWindow <UIGestureRecognizerDelegate, GHOST_IOSInputWindow>
#else
@interface GHOSTUIWindow : UIWindow <UIGestureRecognizerDelegate,
                                      UIPencilInteractionDelegate,
                                      UIPointerInteractionDelegate,
                                      GHOST_IOSInputWindow>
#endif
{
  GHOST_SystemIOS *system;
  GHOST_WindowIOS *window;

  GHOSTUITapGestureRecognizer *tap_gesture_recognizer;
  GHOSTUITapGestureRecognizer *tap2f_gesture_recognizer;
  GHOSTUITapGestureRecognizer *tap3f_gesture_recognizer;
  GHOSTUITapGestureRecognizer *tap4f_gesture_recognizer;
  GHOSTUIPanGestureRecognizer *pan_gesture_recognizer;
  GHOSTUIPanGestureRecognizer *pan2f_gesture_recognizer;
  GHOSTUIPinchGestureRecognizer *zoom_gesture_recognizer;
  UIRotationGestureRecognizer *rotation_gesture_recognizer;
  GHOSTUIHoverGestureRecognizer *hover_gesture_recognizer;
#if !defined(APPLE_TARGET_VISIONOS)
  UIPencilInteraction *pencil_interaction;
#endif
  // GHOSTUILongPressGestureRecognizer *long_press_gesture_recognizer;

  /* A mouse or trackpad: the pointer, its buttons, scrolling and trackpad gestures. On Apple
   * Vision Pro too, without the pointer's own shapes. */
#if !defined(APPLE_TARGET_VISIONOS)
  UIPointerInteraction *pointer_interaction;
#endif
  UIHoverGestureRecognizer *pointer_hover_recognizer;
  UIPanGestureRecognizer *trackpad_scroll_recognizer;
  UIPanGestureRecognizer *wheel_scroll_recognizer;
  UIPinchGestureRecognizer *trackpad_pinch_recognizer;
  UIRotationGestureRecognizer *trackpad_rotation_recognizer;
  UITouch *pointer_touch;
  UIEventButtonMask pointer_buttons;
  CGPoint scroll_translation;
  /* The gate (ROUND5 9G.1): where a pointer was last seen, in the window's points, which scroll
   * and transform events, having no place of their own, are checked at; whether Blender's cursor
   * was moved off the view to clear its hover highlight while something is presented; when each
   * kind of input arriving behind something presented was last logged. */
  CGPoint pointer_location;
  bool pointer_location_known;
  bool pointer_parked;
  NSMutableDictionary<NSString *, NSDate *> *behind_logged;

  /* Data from the Apple pencil */
  UITouch *current_pencil_touch;
  GHOST_TabletData tablet_data;
  bool pencil_button_active;
  bool pencil_navigation_pending;
  /** The Pencil's drag from the navigation gizmo is the orbit (ROUND5 12A.4): where it was
   * recognised, where it was last and when, for the spin after it lifts. */
  bool pencil_gizmo_orbit;
  CGPoint pencil_gizmo_start;
  CGPoint pencil_gizmo_last;
  CGPoint pencil_gizmo_velocity;
  CFTimeInterval pencil_gizmo_time;
  CGPoint pencil_navigation_start;
  bool last_tap_with_pencil;
  bool finger_tool_enabled;
  /* Pencil Only (ROUND6 TOUCH-1): a finger that landed alone on a 3D View with no operator waiting
   * put Blender's cursor there, so a gizmo's handle under it lights up; where it landed, in the
   * view's points; and whether its drag is that handle's (pressed, the moves, the release) rather
   * than the orbit. */
  bool view_finger_hovered;
  CGPoint view_finger_start;
  bool view_gizmo_drag;
  /* Pencil and Fingers (ROUND6 TOUCH-2): the finger on the tool presses nothing until it is told
   * apart (moved past the slop: the press where it began, then the moves; lifted inside it: a
   * click; a second finger first: nothing, it is navigation). Where it began, in the view's points;
   * whether an operator was already waiting as it landed; whether its press began a drag of the
   * tool's own (only that is undone with Escape when a second finger lands). A check script's
   * `finger` step holds the state instead of a touch. */
  /* The pointer events sent now are a finger's (ROUND6 TOUCH-4): marked as one, so Blender
   * measures them with a finger's distances. */
  bool pointer_finger;
  bool finger_pending;
  bool finger_scripted;
  CGPoint finger_start;
  bool finger_landed_modal;
  bool finger_drag_owned;
  /* The current tool touch is the Pencil's, and when a Pencil last lifted: a palm's touches,
   * landing while it is down or just after, are kept from everything (ROUND6 TOUCH-2). */
  bool pencil_touch_is_pencil;
  CFTimeInterval pencil_lifted_at;
  NSMutableSet<UITouch *> *palm_touches;
  /* Fingers moving objects with the Tweak tool, see #GHOST_IOSNativeInterface::finger_tweak_touch,
   * and whether one held an object since the gesture began: navigation waits for all to lift. */
  NSMutableSet<UITouch *> *finger_tweak_touches;
  bool finger_tweak_held;
  UIView<GHOSTIOSPencilMenu> *pencil_context_menu;

  CADisplayLink *orbit_display_link;
  CGPoint orbit_velocity;
  CGPoint orbit_location;
  CGPoint orbit_remainder;
  CFTimeInterval orbit_timestamp;
  uint64_t orbit_gesture_id;
  /** The orbit under way began on the navigation gizmo (ROUND5 12A). */
  bool orbit_from_gizmo;
  /** The gizmo's drag: its translation last stepped, in the view's points, and where it turns. */
  bool gizmo_orbit_active;
  CGPoint gizmo_orbit_translation;
  CGPoint gizmo_orbit_location;
  /* A finger or the Pencil that began on a navigation gizmo's button, given to Blender as a pointer
   * (ROUND5 12D): the touch, which part it began on, and where it began and is, in the view's
   * points. A script's step drives the same state without a touch. */
  UITouch *navigation_button_touch;
  bool navigation_button_active;
  int navigation_button_part;
  CGPoint navigation_button_start;
  CGPoint navigation_button_last;
  /* A finger on Blender's own interface (ROUND5 13B, decisions 81-83), told apart before it acts:
   * pending (nothing pressed yet), scrolling, or pressed (the control's). Where it began and was
   * last, in the view's points; what Blender said is there; its speed, for the run-on. While a
   * gesture began on interface, one-finger navigation and taps take none of its fingers. */
  UITouch *interface_touch;
  /** A check script's `touch` step holds the state instead of a touch. */
  bool interface_scripted;
  int interface_state;
  CGPoint interface_start;
  CGPoint interface_last;
  CFTimeInterval interface_time;
  CGPoint interface_velocity;
  GHOST_IOSTouchAnswer interface_answer;
  NSTimer *interface_hold_timer;
  bool interface_gesture;
  NSMutableDictionary<NSString *, NSDate *> *interface_logged;
  /* What a navigation drag began over (a #GHOST_IOSPlace): over interface or another canvas it
   * scrolls, as a trackpad's two fingers do (13B.3, 13B.4). */
  int navigation_place;
  /* A scroll's run-on after a flick: the same integrator as the orbit's spin (13B.2). */
  CADisplayLink *scroll_display_link;
  CGPoint scroll_velocity;
  CGPoint scroll_remainder;
  CGPoint scroll_location;
  CFTimeInterval scroll_timestamp;
  /* How many fingers a navigation drag had at its last update: it orbits or pans by their count,
   * and goes on from where it is when that changes. */
  NSUInteger navigation_touches;
  bool navigation_orbits;
  /* The drag began orbiting with one finger: it goes on from orbit to pan and back as fingers
   * come and go, without pinch or twist ever taking part, until every finger has lifted. */
  bool navigation_from_orbit;
  /* The pinch or twist lost its second finger: the next one starts it afresh, not jumping. */
  bool zoom_restart;
  /* What a pinch began over (a #GHOST_IOSPlace): over Blender's interface it zooms nothing, the
   * fingers scroll it (ROUND6 DESK-4, H15). */
  int zoom_place;
  bool rotation_restart;

  /* Keyboard handling. */
  UITextField *text_field;
  /** Where Blender's field is, in the window: #text_field lies there, or above the keyboard. */
  CGRect text_field_place;
  /** The software keyboard's frame in the window, empty while none shows. */
  CGRect keyboard_frame;
  /* The software keyboard that types into Blender as key events (ROUND6 DESK-3): its view, which
   * becomes the first responder, and who wants it: what was pressed takes text from keys, or the
   * shell's button keeps it. */
  UIView *key_input_view;
  bool key_input_focus;
  bool key_input_kept;
  NSString *original_text;
  bool onscreen_keyboard_active;
  /** A copy of the edited text, which Blender reads after the text field is cleared. */
  char *text_field_string;
  GHOST_KeyboardProperties current_keyboard_properties;
  bool external_keyboard_connected;

  /* Toolbar */
  bool toolbar_enabled;
  UIToolbar *toolbar;
  UIBarButtonItem *toolbar_tip_item;
  UIBarButtonItem *toolbar_live_text_item;
  UIBarButtonItem *toolbar_done_editing_item;
  UIBarButtonItem *toolbar_cancel_editing_item;
}

- (void)setSystemAndWindowIOS:(GHOST_SystemIOS *)sysCocoa windowIOS:(GHOST_WindowIOS *)winCocoa;
- (void)setPencilContextMenu:(UIView<GHOSTIOSPencilMenu> *)menu;
- (void)setFingerToolEnabled:(BOOL)enabled;
- (void)detachBlender;

/* Blender event generation. */
- (void)generateUserInputEvents:(const UserInputEvent &)event_info;
- (void)cancelPencilStroke;
- (void)handleNavigationTap:(UITapGestureRecognizer *)gesture;

/* Gesture recognizers. */
- (void)registerGestureRecognizers;
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer;
- (void)handleTap:(GHOSTUITapGestureRecognizer *)sender;
- (void)handlePan:(GHOSTUIPanGestureRecognizer *)sender;
- (void)stopOrbitMomentum;
/* The gate (ROUND5 9G.1, decision 66). */
- (NSString *)blockedReason;
- (NSString *)blockedAt:(CGPoint)point;
- (BOOL)blenderTakesPointerAt:(CGPoint)point;
- (void)updateOrbitMomentum:(CADisplayLink *)display_link;
- (void)applicationWillResignActive:(NSNotification *)notification;
- (void)handlePan2f:(GHOSTUIPanGestureRecognizer *)sender;
- (void)handleZoom:(GHOSTUIPinchGestureRecognizer *)sender;
- (void)handleRotation:(UIRotationGestureRecognizer *)sender;

/* On screen keyboard handling */
- (UITextField *)getUITextField;
- (const GHOST_TabletData)getTabletData;
- (void)updateTabletDataFromPencilTouch:(UITouch *)touch;
- (CGPoint)getScaledPencilPoint:(UITouch *)touch;
- (void)sendPencilCursorEvent:(UITouch *)touch;
- (void)sendPencilButtonEvent:(UITouch *)touch isDown:(BOOL)isDown;
- (void)cancelPencilStroke;
- (BOOL)touchBeganInBlenderViewport:(UITouch *)touch;
- (BOOL)isBlenderPencilInputView:(UIView *)view;
- (GHOST_TSuccess)popupOnscreenKeyboard:(const GHOST_KeyboardProperties &)keyboard_properties;
- (GHOST_TSuccess)hideOnscreenKeyboard;
- (const char *)getLastKeyboardString;
@end
