/* SPDX-FileCopyrightText: 2025 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#include <algorithm>
#include <os/log.h>
#include "GHOST_IOSNativeInterface.hh"
#import "GHOST_IOSWindowInput.hh"

/* Input the native interface responds to, see #GHOST_IOSNativeInterface. */
static void ios_log(NSString *kind, NSString *text)
{
  const GHOST_IOSNativeInterface *native = GHOST_ios_native_interface();
  if (native && native->log) {
    native->log(kind.UTF8String, text.UTF8String);
  }
}

static void ios_pencil_hover(bool active, int x, int y)
{
  if (const GHOST_IOSNativeInterface *native = GHOST_ios_native_interface()) {
    native->pencil_hover(active, x, y);
  }
}

/**
 * A Pencil's barrel roll while it touches the screen, anywhere in the window: Blender turns what
 * it moves, and the interface around it turns its dials. Pencils that cannot tell report none.
 */
static void ios_pencil_roll(UITouch *touch)
{
#if !defined(APPLE_TARGET_VISIONOS)
  if (touch.type != UITouchTypePencil) {
    return;
  }
  const bool down = touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled;
  float angle = 0.0f;
  if (@available(iOS 17.5, *)) {
    angle = float(touch.rollAngle);
  }
  /* Its tilt too: which way its end leans on screen, across and down, from -1 to 1 lying flat.
   * The azimuth turns from the screen's x axis towards its y axis, down. */
  const CGFloat azimuth = [touch azimuthAngleInView:touch.window];
  const CGFloat lean = cos(touch.altitudeAngle);
  if (const GHOST_IOSNativeInterface *native = GHOST_ios_native_interface()) {
    if (native->pencil_roll) {
      native->pencil_roll(down, angle, float(cos(azimuth) * lean), float(sin(azimuth) * lean));
    }
  }
  /* Where it touches, in the window, so a rail under it can turn its dial at once. */
  const CGPoint point = [touch locationInView:nil];
  [NSNotificationCenter.defaultCenter
      postNotificationName:@"BlenderPencilRoll"
                    object:nil
                  userInfo:@{
                    @"down" : @(down),
                    @"began" : @(touch.phase == UITouchPhaseBegan),
                    @"angle" : @(angle),
                    @"x" : @(point.x),
                    @"y" : @(point.y)
                  }];
#else
  (void)touch;
#endif
}

/**
 * What happens to Apple Pencil Pro squeezes, in the app's caches as `squeeze.log`, to read off
 * the device, as the system log there needs more than the app can ask for.
 */
static void ios_squeeze_log(const char *message)
{
  os_log(OS_LOG_DEFAULT, "%{public}s", message);
  NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory
                                                       inDomains:NSUserDomainMask]
                      .firstObject;
  NSURL *url = [caches URLByAppendingPathComponent:@"squeeze.log"];
  NSString *line = [NSString stringWithFormat:@"%@ %s\n", NSDate.date, message];
  NSFileHandle *file = [NSFileHandle fileHandleForWritingToURL:url error:nil];
  if (!file) {
    [line writeToURL:url atomically:NO encoding:NSUTF8StringEncoding error:nil];
    return;
  }
  [file seekToEndOfFile];
  [file writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
  [file closeFile];
}

static void ios_navigation_hover(bool active)
{
  if (const GHOST_IOSNativeInterface *native = GHOST_ios_native_interface()) {
    native->navigation_hover(active);
  }
}

static void ios_view_roll(float angle)
{
  if (const GHOST_IOSNativeInterface *native = GHOST_ios_native_interface()) {
    native->view_roll(angle);
  }
}

static bool ios_finger_tweak_active()
{
  const GHOST_IOSNativeInterface *native = GHOST_ios_native_interface();
  /* Only while Settings has fingers drag objects: otherwise a finger landing on an object starts
   * an orbit there as on empty space. */
  if (![NSUserDefaults.standardUserDefaults boolForKey:@"BlenderFingerDragsObjects"]) {
    return false;
  }
  return native && native->finger_tweak_active && native->finger_tweak_active();
}

static int ios_finger_tweak_holding(bool *r_landing)
{
  *r_landing = false;
  const GHOST_IOSNativeInterface *native = GHOST_ios_native_interface();
  return native && native->finger_tweak_holding ? native->finger_tweak_holding(r_landing) : 0;
}

static void ios_finger_tweak_touch(UITouch *touch, GHOST_IOSTouchPhase phase, CGPoint point)
{
  if (const GHOST_IOSNativeInterface *native = GHOST_ios_native_interface()) {
    if (native->finger_tweak_touch) {
      native->finger_tweak_touch(
          uint64_t(uintptr_t(touch)), int(phase), int(lround(point.x)), int(lround(point.y)));
    }
  }
}

/* Hardware keys held for Blender, by HID usage: their release goes to Blender too. */
static NSMutableDictionary<NSNumber *, NSNumber *> *held_keys = nil;
/* The key that repeats while held, as on the desktop, and its text. */
static CFTimeInterval key_repeat_next = 0;
static GHOST_TKey key_repeat_key = GHOST_kKeyUnknown;
static char key_repeat_utf8[6] = {0};
static CADisplayLink *key_repeat_link = nil;
/* The first responder, found by #ghost_captureFirstResponder:. */
static UIResponder *found_first_responder = nil;

@implementation UIResponder (GHOSTFirstResponder)
- (void)ghost_captureFirstResponder:(id)sender
{
  UNUSED_VARS(sender);
  found_first_responder = self;
}
@end

static UIResponder *current_first_responder()
{
  found_first_responder = nil;
  [UIApplication.sharedApplication sendAction:@selector(ghost_captureFirstResponder:)
                                           to:nil
                                         from:nil
                                     forEvent:nil];
  return found_first_responder;
}

static bool modifier_from_key(GHOST_TKey key, GHOST_TModifierKey *modifier)
{
  switch (key) {
    case GHOST_kKeyLeftShift:
      *modifier = GHOST_kModifierKeyLeftShift;
      return true;
    case GHOST_kKeyRightShift:
      *modifier = GHOST_kModifierKeyRightShift;
      return true;
    case GHOST_kKeyLeftControl:
      *modifier = GHOST_kModifierKeyLeftControl;
      return true;
    case GHOST_kKeyRightControl:
      *modifier = GHOST_kModifierKeyRightControl;
      return true;
    case GHOST_kKeyLeftAlt:
      *modifier = GHOST_kModifierKeyLeftAlt;
      return true;
    case GHOST_kKeyRightAlt:
      *modifier = GHOST_kModifierKeyRightAlt;
      return true;
    case GHOST_kKeyLeftOS:
      *modifier = GHOST_kModifierKeyLeftOS;
      return true;
    case GHOST_kKeyRightOS:
      *modifier = GHOST_kModifierKeyRightOS;
      return true;
    default:
      return false;
  }
}

/** Blender's main window, which shows the open document over the launcher. */
UIWindow *document_window = nil;

@implementation GHOSTUITapGestureRecognizer

- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window
{
  CGPoint touch_point = [self locationInView:window->getView()];
  return window->scalePointToWindow(touch_point);
}

@end

@implementation GHOSTUIPanGestureRecognizer

- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window
{
  CGPoint touch_point = [self locationInView:window->getView()];
  return window->scalePointToWindow(touch_point);
}

- (CGPoint)getScaledTranslation:(GHOST_WindowIOS *)window
{
  CGPoint translation = [self translationInView:window->getView()];
  return window->scalePointToWindow(translation);
}

- (CGPoint)getRelativeTranslation:(CGPoint)translation
{
  CGPoint relative_translation;
  relative_translation.x = translation.x - cached_translation.x;
  relative_translation.y = translation.y - cached_translation.y;
  return relative_translation;
}

- (void)setCachedTranslation:(CGPoint)translation
{
  cached_translation = translation;
}

- (CGPoint)getCachedTranslation
{
  return cached_translation;
}
@end

@implementation GHOSTUIHoverGestureRecognizer

- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window
{
  CGPoint touch_point = [self locationInView:window->getView()];
  return window->scalePointToWindow(touch_point);
}
@end

@implementation GHOSTUIPinchGestureRecognizer
- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window touch_id:(int)touch_id
{
  CGPoint touch_point = [self locationOfTouch:touch_id inView:window->getView()];
  return window->scalePointToWindow(touch_point);
}

- (CGFloat)getScaledDistance:(GHOST_WindowIOS *)window
{
  CGPoint touch_point0 = [self locationOfTouch:0 inView:window->getView()];
  CGPoint touch_point1 = [self locationOfTouch:1 inView:window->getView()];
  touch_point0 = window->scalePointToWindow(touch_point0);
  touch_point1 = window->scalePointToWindow(touch_point1);
  float dx = touch_point1.x - touch_point0.x;
  float dy = touch_point1.y - touch_point0.y;
  CGFloat point_distance = sqrt(dx * dx + dy * dy);
  return point_distance;
}

- (CGPoint)getPinchMidpoint:(GHOST_WindowIOS *)window
{
  CGPoint touch_point0 = [self locationOfTouch:0 inView:window->getView()];
  CGPoint touch_point1 = [self locationOfTouch:1 inView:window->getView()];
  touch_point0 = window->scalePointToWindow(touch_point0);
  touch_point1 = window->scalePointToWindow(touch_point1);
  CGPoint midPoint = CGPointMake((touch_point0.x + touch_point1.x) / 2.0f,
                                 (touch_point0.y + touch_point1.y) / 2.0f);
  return midPoint;
}

- (void)setCachedDistance:(CGFloat)distance
{
  cached_distance = distance;
}

- (CGFloat)getCachedDistance
{
  return cached_distance;
}
@end

@implementation GHOSTUIWindow
- (void)detachBlender
{
  [self releaseKeys];
  [self releasePointerButtons];
#if !defined(APPLE_TARGET_VISIONOS)
  [window->getView() removeInteraction:pointer_interaction];
#endif
  [self cancelPencilStroke];
  [self cancelFingerTweakTouches];
  [self stopOrbitMomentum];
  [self hideOnscreenKeyboard];
  [NSNotificationCenter.defaultCenter removeObserver:self];
  self.userInteractionEnabled = NO;
  NSArray *recognizers = [window->getView().gestureRecognizers copy];
  for (UIGestureRecognizer *recognizer in recognizers) {
    recognizer.enabled = NO;
    [window->getView() removeGestureRecognizer:recognizer];
  }
  [recognizers release];
  recognizers = [self.gestureRecognizers copy];
  for (UIGestureRecognizer *recognizer in recognizers) {
    recognizer.enabled = NO;
    [self removeGestureRecognizer:recognizer];
  }
  [recognizers release];
  [pencil_context_menu cancel];
  pencil_context_menu = nil;
  window = nullptr;
  system = nullptr;
}

/* Three fingers pan the view rather than undo or copy, as text editing has them. */
- (UIEditingInteractionConfiguration)editingInteractionConfiguration
{
  return UIEditingInteractionConfigurationNone;
}

- (void)setFingerToolEnabled:(BOOL)enabled
{
  [self cancelPencilStroke];
  [self cancelFingerTweakTouches];
  [self stopOrbitMomentum];
  finger_tool_enabled = enabled;
}

- (void)setPencilContextMenu:(UIView<GHOSTIOSPencilMenu> *)menu
{
  pencil_context_menu = menu;
}

- (void)setSystemAndWindowIOS:(GHOST_SystemIOS *)sys windowIOS:(GHOST_WindowIOS *)win
{
  system = sys;
  window = win;
  text_field = nil;
  original_text = nil;
  onscreen_keyboard_active = false;
  free(text_field_string);
  text_field_string = nullptr;
  current_pencil_touch = nil;
  tablet_data = GHOST_TABLET_DATA_NONE;
  pencil_button_active = false;
  toolbar_enabled = true;
  toolbar = nil;
  last_tap_with_pencil = false;
  finger_tool_enabled = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
  [finger_tweak_touches release];
  finger_tweak_touches = [[NSMutableSet alloc] init];
  finger_tweak_held = false;
  orbit_display_link = nil;
  external_keyboard_connected = [GCKeyboard coalescedKeyboard] != nil;

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(applicationWillResignActive:)
                                               name:UIApplicationWillResignActiveNotification
                                             object:nil];

  /* Register for notifications of chnanges to the onscreen keyboard. */
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(keyboardWillChange:)
                                               name:UIKeyboardWillChangeFrameNotification
                                             object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(keyboardWillChange:)
                                               name:UIKeyboardWillShowNotification
                                             object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(keyboardWillChange:)
                                               name:UIKeyboardWillHideNotification
                                             object:nil];

  /* Check whether we've linked the GameController framework. */
  if (&GCKeyboardDidConnectNotification != NULL) {
    /* Register for notifcations an external keyboard has been added/removed. */
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(externalKeyboardChange:)
                                                 name:GCKeyboardDidConnectNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(externalKeyboardChange:)
                                                 name:GCKeyboardDidDisconnectNotification
                                               object:nil];
  }
}

- (void)registerGestureRecognizers
{
  /** Create Gesture recognisers. */
  /* Tap gesture recognizer. */
  tap_gesture_recognizer = [[GHOSTUITapGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleTap:)];
  tap_gesture_recognizer.delegate = self;
  tap_gesture_recognizer.cancelsTouchesInView = false;
  tap_gesture_recognizer.allowedTouchTypes = @[ @(UITouchTypeDirect) ];
  [window->getView() addGestureRecognizer:tap_gesture_recognizer];

  /* Two-finger tap gesture recognizer. */
  tap2f_gesture_recognizer = [[GHOSTUITapGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleTap2F:)];
  tap2f_gesture_recognizer.delegate = self;
  tap2f_gesture_recognizer.cancelsTouchesInView = false;
  tap2f_gesture_recognizer.delaysTouchesBegan = YES;
  tap2f_gesture_recognizer.numberOfTouchesRequired = 2;
  tap2f_gesture_recognizer.allowedTouchTypes = @[ @(UITouchTypeDirect) ];
  [window->getView() addGestureRecognizer:tap2f_gesture_recognizer];

  /* Three-finger tap gesture recognizer. */
  tap3f_gesture_recognizer = [[GHOSTUITapGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleTap3F:)];
  tap3f_gesture_recognizer.delegate = self;
  tap3f_gesture_recognizer.cancelsTouchesInView = false;
  tap3f_gesture_recognizer.delaysTouchesBegan = YES;
  tap3f_gesture_recognizer.numberOfTouchesRequired = 3;
  tap3f_gesture_recognizer.allowedTouchTypes = @[ @(UITouchTypeDirect) ];
  [window->getView() addGestureRecognizer:tap3f_gesture_recognizer];

  /* Four-finger tap gesture recognizer. */
  tap4f_gesture_recognizer = [[GHOSTUITapGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleTap4F:)];
  tap4f_gesture_recognizer.delegate = self;
  tap4f_gesture_recognizer.cancelsTouchesInView = false;
  tap4f_gesture_recognizer.delaysTouchesBegan = YES;
  tap4f_gesture_recognizer.numberOfTouchesRequired = 4;
  tap4f_gesture_recognizer.allowedTouchTypes = @[ @(UITouchTypeDirect) ];
  [window->getView() addGestureRecognizer:tap4f_gesture_recognizer];

  /* Pan gesture recognizer - static UI. */
  pan_gesture_recognizer = [[GHOSTUIPanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handlePan:)];
  pan_gesture_recognizer.delegate = self;
  pan_gesture_recognizer.cancelsTouchesInView = false;
  /* One finger orbits; more pan, going from one to the other as fingers come and go. */
  pan_gesture_recognizer.minimumNumberOfTouches = 1;
  pan_gesture_recognizer.maximumNumberOfTouches = 3;
  pan_gesture_recognizer.allowedTouchTypes = @[ @(UITouchTypeDirect) ];
  [window->getView() addGestureRecognizer:pan_gesture_recognizer];

  /* Pan gesture recognizer - two fingers 3D UI. */
  pan2f_gesture_recognizer = [[GHOSTUIPanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handlePan2f:)];
  pan2f_gesture_recognizer.delegate = self;
  pan2f_gesture_recognizer.cancelsTouchesInView = false;
  /* With one finger on the tool: two orbit, three pan. */
  pan2f_gesture_recognizer.minimumNumberOfTouches = 2;
  pan2f_gesture_recognizer.maximumNumberOfTouches = 3;
  pan2f_gesture_recognizer.allowedTouchTypes = @[ @(UITouchTypeDirect) ];
  [window->getView() addGestureRecognizer:pan2f_gesture_recognizer];


  /* Pinch/Zoom gesture recognizer. */
  zoom_gesture_recognizer = [[GHOSTUIPinchGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleZoom:)];
  zoom_gesture_recognizer.delegate = self;
  zoom_gesture_recognizer.cancelsTouchesInView = false;
  zoom_gesture_recognizer.allowedTouchTypes = @[ @(UITouchTypeDirect) ];
  [window->getView() addGestureRecognizer:zoom_gesture_recognizer];

  /* Twist/roll gesture recognizer. */
  rotation_gesture_recognizer = [[UIRotationGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleRotation:)];
  rotation_gesture_recognizer.delegate = self;
  rotation_gesture_recognizer.cancelsTouchesInView = false;
  rotation_gesture_recognizer.allowedTouchTypes = @[ @(UITouchTypeDirect) ];
  [window->getView() addGestureRecognizer:rotation_gesture_recognizer];

#if !defined(APPLE_TARGET_VISIONOS)
  /* Edge swipe: visionOS windows have no screen edges. */
  edge_swipe_left = [[UIScreenEdgePanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleEdgeSwipe:)];
  edge_swipe_left.edges = UIRectEdgeLeft;
  edge_swipe_left.delegate = self;
  edge_swipe_left.allowedTouchTypes = @[ @(UITouchTypeDirect) ];
  [window->getView() addGestureRecognizer:edge_swipe_left];

  edge_swipe_right = [[UIScreenEdgePanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleEdgeSwipe:)];
  edge_swipe_right.edges = UIRectEdgeRight;
  edge_swipe_right.delegate = self;
  edge_swipe_right.allowedTouchTypes = @[ @(UITouchTypeDirect) ];
  [window->getView() addGestureRecognizer:edge_swipe_right];
#endif

  /* Apple Pencil hover recognizer. */
  hover_gesture_recognizer = [[GHOSTUIHoverGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleHover:)];
  hover_gesture_recognizer.delegate = self;
  hover_gesture_recognizer.allowedTouchTypes = @[ @(UITouchTypePencil) ];
  /* Observe both the viewport and the modal native radial overlay. */
  [self addGestureRecognizer:hover_gesture_recognizer];
  current_pencil_touch = nil;

  /* A mouse or trackpad, as on the desktop: the pointer moves Blender's cursor and shows it. */
#if !defined(APPLE_TARGET_VISIONOS)
  pointer_interaction = [[UIPointerInteraction alloc] initWithDelegate:self];
  [window->getView() addInteraction:pointer_interaction];
#endif

  pointer_hover_recognizer = [[UIHoverGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handlePointerHover:)];
  pointer_hover_recognizer.delegate = self;
  pointer_hover_recognizer.allowedTouchTypes = @[ @(UITouchTypeIndirectPointer) ];
  [self addGestureRecognizer:pointer_hover_recognizer];

  /* Scrolling: a trackpad's two fingers as on a Mac, a mouse wheel's steps as a wheel. */
  trackpad_scroll_recognizer = [[UIPanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleTrackpadScroll:)];
  trackpad_scroll_recognizer.delegate = self;
  trackpad_scroll_recognizer.allowedScrollTypesMask = UIScrollTypeMaskContinuous;
  trackpad_scroll_recognizer.allowedTouchTypes = @[];
  [window->getView() addGestureRecognizer:trackpad_scroll_recognizer];

  wheel_scroll_recognizer = [[UIPanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleWheelScroll:)];
  wheel_scroll_recognizer.delegate = self;
  wheel_scroll_recognizer.allowedScrollTypesMask = UIScrollTypeMaskDiscrete;
  wheel_scroll_recognizer.allowedTouchTypes = @[];
  [window->getView() addGestureRecognizer:wheel_scroll_recognizer];

  /* A trackpad's pinch and twist, apart from fingers on the screen. */
  trackpad_pinch_recognizer = [[UIPinchGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleTrackpadPinch:)];
  trackpad_pinch_recognizer.delegate = self;
  trackpad_pinch_recognizer.allowedTouchTypes = @[ @(UITouchTypeIndirectPointer) ];
  [window->getView() addGestureRecognizer:trackpad_pinch_recognizer];

  trackpad_rotation_recognizer = [[UIRotationGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleTrackpadRotation:)];
  trackpad_rotation_recognizer.delegate = self;
  trackpad_rotation_recognizer.allowedTouchTypes = @[ @(UITouchTypeIndirectPointer) ];
  [window->getView() addGestureRecognizer:trackpad_rotation_recognizer];

#if !defined(APPLE_TARGET_VISIONOS)
  /**  Apple Pencil double-tap. */
  pencil_interaction = [[UIPencilInteraction alloc] init];
  pencil_interaction.delegate = self;
  [window->getView() addInteraction:pencil_interaction];
#endif
}

/* Turn the user inputs into Blender events.
 * We batch up the events rather than send them directly in the gesture
 * recognisers to ensure we don't interleave events if we detect simultaneous
 * inputs. */
- (void)generateUserInputEvents:(const UserInputEvent &)event_info
{
  if (!window || !system) {
    return;
  }
  /* Lock access to ensure all input-events are received sequentially. */
  @synchronized(self) {
    for (int i = 0; i < event_info.num_events; i++) {
      UserInputEvent::EventTypes event_type = event_info.event_list[i];
      IOS_INPUT_LOG(@"%d-%@ %f,%f",
                    i,
                    event_info.getEventTypeDesc(event_type),
                    event_info.location.x,
                    event_info.location.y);

      switch (event_type) {
        case UserInputEvent::EventTypes::CURSOR_MOVE:
          pointer_parked = false;
          window->updatePointerPosition(event_info.location.x, event_info.location.y);
          system->pushEvent(std::make_unique<GHOST_EventCursor>(system->getMilliSeconds(),
                                                                GHOST_kEventCursorMove,
                                                                window,
                                                                event_info.location.x,
                                                                event_info.location.y,
                                                                tablet_data));
          break;
        case UserInputEvent::EventTypes::ORBIT_GESTURE:
          system->pushEvent(std::make_unique<GHOST_EventTrackpad>(system->getMilliSeconds(),
                                                                  window,
                                                                  GHOST_kTrackpadEventRotate,
                                                                  event_info.location.x,
                                                                  event_info.location.y,
                                                                  event_info.translation.x,
                                                                  event_info.translation.y,
                                                                  false,
                                                                  1,
                                                                  event_info.gesture_id,
                                                                  event_info.from_gizmo));
          break;
        case UserInputEvent::EventTypes::PAN_GESTURE:
          system->pushEvent(std::make_unique<GHOST_EventTrackpad>(system->getMilliSeconds(),
                                                                  window,
                                                                  GHOST_kTrackpadEventScroll,
                                                                  event_info.location.x,
                                                                  event_info.location.y,
                                                                  event_info.translation.x,
                                                                  event_info.translation.y,
                                                                  false,
                                                                  1));
          break;
        case UserInputEvent::EventTypes::PAN_GESTURE_TWO_FINGERS:
          system->pushEvent(std::make_unique<GHOST_EventTrackpad>(system->getMilliSeconds(),
                                                                  window,
                                                                  GHOST_kTrackpadEventScroll,
                                                                  event_info.location.x,
                                                                  event_info.location.y,
                                                                  event_info.translation.x,
                                                                  event_info.translation.y,
                                                                  true,
                                                                  2));
          break;
        case UserInputEvent::EventTypes::LEFT_BUTTON_DOWN:
          system->pushEvent(std::make_unique<GHOST_EventButton>(system->getMilliSeconds(),
                                                                GHOST_kEventButtonDown,
                                                                window,
                                                                GHOST_kButtonMaskLeft,
                                                                tablet_data));
          break;
        case UserInputEvent::EventTypes::LEFT_BUTTON_UP:
          system->pushEvent(std::make_unique<GHOST_EventButton>(system->getMilliSeconds(),
                                                                GHOST_kEventButtonUp,
                                                                window,
                                                                GHOST_kButtonMaskLeft,
                                                                tablet_data));
          break;
        case UserInputEvent::EventTypes::PINCH_GESTURE:
          system->pushEvent(std::make_unique<GHOST_EventTrackpad>(system->getMilliSeconds(),
                                                                  window,
                                                                  GHOST_kTrackpadEventMagnify,
                                                                  event_info.location.x,
                                                                  event_info.location.y,
                                                                  event_info.distance,
                                                                  0,
                                                                  false,
                                                                  2));
          break;
        case UserInputEvent::EventTypes::CANCEL_TOOL:
          system->pushEvent(std::make_unique<GHOST_EventKey>(
              system->getMilliSeconds(), GHOST_kEventKeyDown, window, GHOST_kKeyEsc, false));
          system->pushEvent(std::make_unique<GHOST_EventKey>(
              system->getMilliSeconds(), GHOST_kEventKeyUp, window, GHOST_kKeyEsc, false));
          break;
        default:
          GHOST_ASSERT(FALSE, "GHOST_SystemIOS::generateUserInputEvents unsupported event type");
      }
    }
  }
}

/* Pan, pinch, and twist are independent parts of the same two-finger gesture. */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer
{
  if ([gestureRecognizer isKindOfClass:UIHoverGestureRecognizer.class] &&
      [otherGestureRecognizer isKindOfClass:UIHoverGestureRecognizer.class])
  {
    return YES;
  }
  if ((gestureRecognizer == trackpad_pinch_recognizer &&
       otherGestureRecognizer == trackpad_rotation_recognizer) ||
      (gestureRecognizer == trackpad_rotation_recognizer &&
       otherGestureRecognizer == trackpad_pinch_recognizer))
  {
    return YES;
  }
  const BOOL is_navigation = gestureRecognizer == pan_gesture_recognizer ||
                             gestureRecognizer == pan2f_gesture_recognizer ||
                             gestureRecognizer == zoom_gesture_recognizer ||
                             gestureRecognizer == rotation_gesture_recognizer;
  const BOOL other_is_navigation = otherGestureRecognizer == pan_gesture_recognizer ||
                                   otherGestureRecognizer == pan2f_gesture_recognizer ||
                                   otherGestureRecognizer == zoom_gesture_recognizer ||
                                   otherGestureRecognizer == rotation_gesture_recognizer;
  return gestureRecognizer != otherGestureRecognizer && is_navigation && other_is_navigation;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch
{
  /* A touch on a navigation gizmo's button is Blender's pointer alone (ROUND5 12D). */
  if (touch == navigation_button_touch) {
    return NO;
  }
  if (finger_tool_enabled &&
      (gestureRecognizer == pan_gesture_recognizer || gestureRecognizer == tap_gesture_recognizer))
  {
    return NO;
  }
  if (gestureRecognizer == hover_gesture_recognizer && pencil_context_menu.active) {
    return YES;
  }
  if (pencil_context_menu.active && gestureRecognizer != hover_gesture_recognizer) {
    return NO;
  }
  if (gestureRecognizer == tap_gesture_recognizer ||
      gestureRecognizer == tap2f_gesture_recognizer ||
      gestureRecognizer == tap3f_gesture_recognizer ||
      gestureRecognizer == tap4f_gesture_recognizer ||
      gestureRecognizer == pan_gesture_recognizer ||
      gestureRecognizer == pan2f_gesture_recognizer ||
      gestureRecognizer == zoom_gesture_recognizer ||
      gestureRecognizer == rotation_gesture_recognizer ||
#if !defined(APPLE_TARGET_VISIONOS)
      gestureRecognizer == edge_swipe_left || gestureRecognizer == edge_swipe_right ||
#endif
      gestureRecognizer == hover_gesture_recognizer)
  {
    return [self touchBeganInBlenderViewport:touch];
  }
  /* The pointer's hover is followed by its handler, which clears Blender's highlight where the
   * gate closes (ROUND5 9G.1); the trackpad's pinch and twist ask the gate here. */
  if (gestureRecognizer == pointer_hover_recognizer) {
    return YES;
  }
  const CGPoint point = [touch locationInView:self];
  NSString *reason = [self blockedAt:point];
  if (reason != nil) {
    [self inputBehind:(gestureRecognizer == trackpad_rotation_recognizer ? @"trackpad rotation" :
                       gestureRecognizer == trackpad_pinch_recognizer    ? @"trackpad pinch" :
                                                                           @"pointer touch")
               reason:reason
                   at:point];
    return NO;
  }
  return YES;
}

/**
 * Scroll and transform events are no touches: #gestureRecognizer:shouldReceiveTouch: never sees
 * them. They ask the gate where the pointer is (ROUND5 9G.1, decision 66).
 */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveEvent:(UIEvent *)event
{
  if (event.type != UIEventTypeScroll && event.type != UIEventTypeTransform) {
    return YES;
  }
  const CGPoint point = [self pointerLocation];
  NSString *reason = [self blockedAt:point];
  if (reason == nil) {
    return YES;
  }
  NSString *kind = gestureRecognizer == trackpad_scroll_recognizer   ? @"trackpad scroll" :
                   gestureRecognizer == wheel_scroll_recognizer      ? @"wheel" :
                   gestureRecognizer == trackpad_pinch_recognizer    ? @"trackpad pinch" :
                   gestureRecognizer == trackpad_rotation_recognizer ? @"trackpad rotation" :
                                                                       ios_event_kind(event);
  [self inputBehind:kind reason:reason at:point];
  return NO;
}

- (BOOL)touchBeganInBlenderViewport:(UITouch *)touch
{
  /* The gate's first half too (ROUND5 9G.1): a touch that begins while something is presented
   * is never Blender's, whatever it lands on. */
  return (touch.view == window->getView() ||
          (touch.type == UITouchTypePencil && [self isBlenderPencilInputView:touch.view])) &&
         [self blockedReason] == nil;
}

- (BOOL)isBlenderPencilInputView:(UIView *)view
{
  return view == window->getView() ||
         [view.accessibilityIdentifier isEqualToString:@"blender.viewport.navigation"];
}

/**
 * The Pencil's force as Blender's pressure. Drawing hardly ever presses as hard as the Pencil can
 * measure: full pressure comes well before that, and a curve lifts light strokes, as drawing apps
 * have it. How light or firm a touch it wants is a setting, see `SettingsSheet.swift`.
 */
static float pencil_pressure(const CGFloat force, const CGFloat maximum)
{
  if (maximum <= 0.0) {
    return 1.0f;
  }
  /* 0 wants the firmest touch, 1 the lightest; the default is halfway. */
  static NSString *const key = @"BlenderPencilPressureSensitivity";
  NSNumber *setting = [NSUserDefaults.standardUserDefaults objectForKey:key];
  const double sensitivity = setting ? std::clamp(setting.doubleValue, 0.0, 1.0) : 0.5;
  const double full = 0.9 - 0.5 * sensitivity;
  const double exponent = 1.0 - 0.75 * sensitivity;
  const double x = std::clamp(double(force / maximum) / full, 0.0, 1.0);
  return float(pow(x, exponent));
}

- (void)updateTabletDataFromPencilTouch:(UITouch *)touch
{
  if (touch.type == UITouchTypeDirect) {
    tablet_data = GHOST_TABLET_DATA_NONE;
    return;
  }
  /* Preserve absolute Pencil coordinates on navigation gizmos too. Click versus
   * drag is decided by movement, not by disguising a Pencil as a relative mouse. */
  tablet_data.Active = GHOST_kTabletModeStylus;

  tablet_data.Pressure = pencil_pressure(touch.force, touch.maximumPossibleForce);

  CGFloat azimuthAngle = [touch azimuthAngleInView:window->getView()];
  CGFloat altitudeAngle = [touch altitudeAngle];

  /* Calculate the maximum possible tilt (1.0) when altitude is 0. */
  CGFloat maxTilt = cos(0);

  /* Convert to x and y tilt - range -1.0 (left) to +1.0 (right). */
  tablet_data.Xtilt = sin(azimuthAngle) * cos(altitudeAngle) / maxTilt;
  tablet_data.Ytilt = -cos(azimuthAngle) * cos(altitudeAngle) / maxTilt;
  IOS_INPUT_LOG(
      @"TABLET: X:%f,Y:%f,P:%f", tablet_data.Xtilt, tablet_data.Ytilt, tablet_data.Pressure);
}

- (CGPoint)getScaledPencilPoint:(UITouch *)touch
{
  CGPoint touch_point = [touch preciseLocationInView:window->getView()];
  return window->scalePointToWindow(touch_point);
}

- (void)sendPencilCursorEvent:(UITouch *)touch
{
  [self updateTabletDataFromPencilTouch:touch];
  CGPoint touch_point = [self getScaledPencilPoint:touch];
  UserInputEvent event_info(&touch_point, nullptr, nullptr, true);
  event_info.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
  [self generateUserInputEvents:event_info];
}

- (void)sendPencilButtonEvent:(UITouch *)touch isDown:(BOOL)isDown
{
  [self updateTabletDataFromPencilTouch:touch];
  if (!isDown) {
    tablet_data.Pressure = 0.0f;
  }
  CGPoint touch_point = [self getScaledPencilPoint:touch];
  last_tap_with_pencil = true;

  UserInputEvent event_info(&touch_point, nullptr, nullptr, true);
  event_info.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
  event_info.add_event(isDown ? UserInputEvent::EventTypes::LEFT_BUTTON_DOWN :
                                UserInputEvent::EventTypes::LEFT_BUTTON_UP);
  [self generateUserInputEvents:event_info];
}

- (void)cancelPencilStroke
{
  ios_pencil_hover(false, 0, 0);
  if (pencil_button_active) {
    /* Cancel the modal tool before releasing, so interruption does not commit it.
     * Do not dereference UITouch here: UIKit may already have retired the touch. */
    tablet_data.Pressure = 0.0f;
    UserInputEvent event_info(nullptr, nullptr, nullptr, true);
    event_info.add_event(UserInputEvent::EventTypes::CANCEL_TOOL);
    event_info.add_event(UserInputEvent::EventTypes::LEFT_BUTTON_UP);
    [self generateUserInputEvents:event_info];
  }
  if (pencil_gizmo_orbit) {
    pencil_gizmo_orbit = false;
    [self navigationGizmoDrag:3 at:CGPointZero translation:CGPointZero velocity:CGPointZero];
  }
  pencil_button_active = false;
  pencil_navigation_pending = false;
  current_pencil_touch = nil;
  tablet_data = GHOST_TABLET_DATA_NONE;
}

/**
 * With the Tweak tool, a finger landing in the viewport moves the object under it, see
 * #GHOST_IOSNativeInterface::finger_tweak_touch: Blender looks for it, and the finger sends no
 * pointer events. True for such a finger's touches.
 */
- (BOOL)sendFingerTweakTouch:(UITouch *)touch active:(bool)active
{
  GHOST_IOSTouchPhase phase;
  switch (touch.phase) {
    case UITouchPhaseBegan:
      if (!active || ![self touchBeganInBlenderViewport:touch] ||
          [finger_tweak_touches containsObject:touch])
      {
        return [finger_tweak_touches containsObject:touch];
      }
      [finger_tweak_touches addObject:touch];
      phase = GHOST_kIOSTouchBegan;
      break;
    case UITouchPhaseMoved:
      phase = GHOST_kIOSTouchMoved;
      break;
    case UITouchPhaseEnded:
      phase = GHOST_kIOSTouchEnded;
      break;
    case UITouchPhaseCancelled:
      phase = GHOST_kIOSTouchCancelled;
      break;
    default:
      return [finger_tweak_touches containsObject:touch];
  }
  if (![finger_tweak_touches containsObject:touch]) {
    return NO;
  }
  CGPoint point = [touch preciseLocationInView:window->getView()];
  point = window->scalePointToWindow(point);
  ios_finger_tweak_touch(touch, phase, point);
  if (phase == GHOST_kIOSTouchEnded || phase == GHOST_kIOSTouchCancelled) {
    [finger_tweak_touches removeObject:touch];
  }
  return YES;
}

/** Lift the fingers moving objects, putting their objects back. */
- (void)cancelFingerTweakTouches
{
  for (UITouch *touch in finger_tweak_touches) {
    /* Only the identity of the touch is used: UIKit may already have retired it. */
    ios_finger_tweak_touch(touch, GHOST_kIOSTouchCancelled, CGPointZero);
  }
  [finger_tweak_touches removeAllObjects];
  finger_tweak_held = false;
}

/**
 * Whether fingers holding objects keep the view still: navigation gestures and taps of several
 * fingers do nothing then. Once a finger held an object, the view stays still until the gesture
 * ends, so lifting it does not navigate or undo.
 */
- (BOOL)fingerTweakHolds
{
  if (finger_tweak_touches.count == 0) {
    return finger_tweak_held;
  }
  bool landing = false;
  if (ios_finger_tweak_holding(&landing) > 0) {
    finger_tweak_held = true;
  }
  return finger_tweak_held || landing;
}

/** A gesture begins as the first fingers land: whether it holds objects is known again. */
- (void)updateFingerTweakHeld:(UIEvent *)event
{
  bool began = false;
  for (UITouch *touch in event.allTouches) {
    if (touch.type != UITouchTypeDirect) {
      continue;
    }
    if (touch.phase != UITouchPhaseBegan) {
      [self fingerTweakHolds];
      return;
    }
    began = true;
  }
  if (began) {
    finger_tweak_held = false;
  }
}

/* Observe Pencil input before UIKit's responder chain can consume the viewport touches. */
- (void)sendEvent:(UIEvent *)event
{
  if (!window) {
    [super sendEvent:event];
    return;
  }
  /* Where a pointer is, for scroll and transform events, which carry no place (ROUND5 9G.1). */
  for (UITouch *touch in event.allTouches) {
    if (touch.type == UITouchTypeIndirectPointer) {
      pointer_location = [touch locationInView:self];
      pointer_location_known = true;
    }
  }
  /* Which path input takes while something is presented: the session's log says (ROUND5 9G.1,
   * G3). Only noted, never kept from UIKit: what is presented takes it. */
  if (event.type == UIEventTypeScroll || event.type == UIEventTypeTransform ||
      event.type == UIEventTypeHover ||
      (event.type == UIEventTypeTouches &&
       [event.allTouches anyObject].phase == UITouchPhaseBegan))
  {
    if (NSString *reason = [self blockedReason]) {
      /* A touch's own place, not the pointer's last (ROUND5 12C.3). */
      UITouch *touch = event.type == UIEventTypeTouches ? [event.allTouches anyObject] : nil;
      [self inputBehind:[@"event " stringByAppendingString:ios_event_kind(event)]
                 reason:reason
                     at:touch ? [touch locationInView:self] : [self pointerLocation]];
    }
  }
  if (event.type == UIEventTypeTouches) {
    NSUInteger fingers = 0;
    for (UITouch *touch in event.allTouches) {
      if (touch.type == UITouchTypeDirect && touch.phase != UITouchPhaseEnded &&
          touch.phase != UITouchPhaseCancelled && touch != navigation_button_touch &&
          [self touchBeganInBlenderViewport:touch])
      {
        fingers++;
      }
    }
    /* Hand the sequence to two-finger navigation without committing a partial tool drag. */
    if (fingers > 1 && current_pencil_touch.type == UITouchTypeDirect) {
      [self cancelPencilStroke];
    }
    const bool finger_tweak = finger_tool_enabled && ios_finger_tweak_active();
    [self updateFingerTweakHeld:event];
    for (UITouch *touch in event.allTouches) {
      ios_pencil_roll(touch);
      if (touch.phase == UITouchPhaseBegan) {
        ios_pencil_hover(false, 0, 0);
        [self stopOrbitMomentum];
      }
      if (touch.type == UITouchTypeDirect && pencil_context_menu.active) {
        if (touch.phase == UITouchPhaseBegan) {
          [pencil_context_menu cancel];
        }
        continue;
      }
      if (touch.type == UITouchTypeIndirectPointer) {
        [self handlePointerTouch:touch event:event];
        continue;
      }
      /* On a navigation gizmo's button: a pointer's press, moves and release, before any tool,
       * Tweak or navigation can take it (ROUND5 12D). */
      if ((touch.type == UITouchTypeDirect || touch.type == UITouchTypePencil) &&
          [self handleNavigationButtonTouch:touch event:event])
      {
        continue;
      }
      if (touch.type == UITouchTypeDirect && [self sendFingerTweakTouch:touch
                                                                 active:finger_tweak])
      {
        continue;
      }
      if (touch.type != UITouchTypePencil &&
          !(finger_tool_enabled && touch.type == UITouchTypeDirect && fingers <= 1))
      {
        continue;
      }
      if ((pencil_context_menu.active || touch.view == pencil_context_menu ||
           [self touchBeganInBlenderViewport:touch]) &&
          [pencil_context_menu handlePencilTouch:touch])
      {
        continue;
      }

      switch (touch.phase) {
        case UITouchPhaseBegan:
          if (touch == current_pencil_touch || ![self touchBeganInBlenderViewport:touch]) {
            break;
          }
          [self cancelPencilStroke];
          ios_navigation_hover(false);
          current_pencil_touch = touch;
          /* Only the navigation hotspot waits to distinguish a tap from a hold.
           * Viewport tools still receive Pencil-down immediately. */
          pencil_navigation_pending = [touch.view.accessibilityIdentifier
              isEqualToString:@"blender.viewport.navigation"];
          pencil_navigation_start = [touch preciseLocationInView:window->getView()];
          pencil_button_active = !pencil_navigation_pending;
          if (pencil_button_active) {
            [self sendPencilButtonEvent:touch isDown:YES];
          }
          break;
        case UITouchPhaseMoved:
          if (touch == current_pencil_touch && pencil_navigation_pending) {
            CGPoint point = [touch preciseLocationInView:window->getView()];
            if (hypot(point.x - pencil_navigation_start.x, point.y - pencil_navigation_start.y) >
                10.0)
            {
              pencil_navigation_pending = false;
              /* A drag from the gizmo is the app's orbit, as a finger's is (ROUND5 12A.4), not a
               * press on Blender's gizmo, whose orbit passes a tablet's events by. */
              UIView *hotspot = touch.view;
              const CGPoint centre = [hotspot
                  convertPoint:CGPointMake(CGRectGetMidX(hotspot.bounds), CGRectGetMidY(hotspot.bounds))
                        toView:window->getView()];
              if ([self navigationGizmoDrag:0
                                         at:centre
                                translation:CGPointZero
                                   velocity:CGPointZero])
              {
                pencil_gizmo_orbit = true;
                pencil_gizmo_start = point;
                pencil_gizmo_last = point;
                pencil_gizmo_velocity = CGPointZero;
                pencil_gizmo_time = touch.timestamp;
                break;
              }
              pencil_button_active = true;
              [self updateTabletDataFromPencilTouch:touch];
              CGPoint start = window->scalePointToWindow(pencil_navigation_start);
              UserInputEvent down(&start, nullptr, nullptr, true);
              down.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
              down.add_event(UserInputEvent::EventTypes::LEFT_BUTTON_DOWN);
              [self generateUserInputEvents:down];
            }
          }
          if (touch == current_pencil_touch && pencil_gizmo_orbit) {
            const CGPoint point = [touch preciseLocationInView:window->getView()];
            const CFTimeInterval dt = touch.timestamp - pencil_gizmo_time;
            if (dt > 0.0) {
              pencil_gizmo_velocity = CGPointMake((point.x - pencil_gizmo_last.x) / dt,
                                                  (point.y - pencil_gizmo_last.y) / dt);
            }
            pencil_gizmo_last = point;
            pencil_gizmo_time = touch.timestamp;
            [self navigationGizmoDrag:1
                                   at:CGPointZero
                          translation:CGPointMake(point.x - pencil_gizmo_start.x,
                                                  point.y - pencil_gizmo_start.y)
                             velocity:CGPointZero];
            break;
          }
          if (touch == current_pencil_touch && pencil_button_active) {
            NSArray<UITouch *> *samples = [event coalescedTouchesForTouch:touch];
            if (samples.count == 0) {
              samples = @[ touch ];
            }
            for (UITouch *sample in samples) {
              [self sendPencilCursorEvent:sample];
            }
          }
          break;
        case UITouchPhaseEnded:
          if (touch == current_pencil_touch && pencil_gizmo_orbit) {
            pencil_gizmo_orbit = false;
            [self navigationGizmoDrag:2
                                   at:CGPointZero
                          translation:CGPointZero
                             velocity:(touch.timestamp - pencil_gizmo_time < 0.05 ?
                                           pencil_gizmo_velocity :
                                           CGPointZero)];
            pencil_navigation_pending = false;
            current_pencil_touch = nil;
            tablet_data = GHOST_TABLET_DATA_NONE;
            break;
          }
          if (touch == current_pencil_touch) {
            if (pencil_navigation_pending) {
              [self sendPencilButtonEvent:touch isDown:YES];
              pencil_button_active = true;
            }
            if (pencil_button_active) {
              [self sendPencilButtonEvent:touch isDown:NO];
            }
            pencil_button_active = false;
            pencil_navigation_pending = false;
            current_pencil_touch = nil;
            tablet_data = GHOST_TABLET_DATA_NONE;
          }
          break;
        case UITouchPhaseCancelled:
          if (touch == current_pencil_touch) {
            [self cancelPencilStroke];
          }
          break;
        default:
          break;
      }
    }
  }
  [super sendEvent:event];
}

/* -------------------------------------------------------------------- */
/* The gate (ROUND5 9G.1, decision 66)
 *
 * Nothing reaches Blender while something is presented above the viewport: keys, touches, the
 * Pencil, scroll, pinch, rotation and hover all ask the same question. Its first half, whether the
 * document shows with nothing presented above it in any window of the scene, is the keyboard's
 * too (#blenderTakesKeyboard); its second, for a pointer or a touch, whether the view under the
 * point is Blender's: the Metal view or its navigation input. */

/** Why Blender takes no input anywhere now, or nil: the document hidden, or something presented
 * above it (a sheet, an alert, a popover, a menu) in this window or one in front of it. */
- (NSString *)blockedReason
{
  if (!window || !system) {
    return @"no window";
  }
  if (self.hidden || !GHOST_ios_document_window_visible()) {
    return @"document hidden";
  }
  for (UIWindow *other in self.windowScene.windows) {
    /* The launcher's window stays behind this one: what it presents is not seen. */
    if (other.hidden || (other != self && other.windowLevel < self.windowLevel)) {
      continue;
    }
    UIViewController *presented = other.rootViewController.presentedViewController;
    if (presented != nil) {
      while (presented.presentedViewController != nil) {
        presented = presented.presentedViewController;
      }
      return [@"presented " stringByAppendingString:NSStringFromClass(presented.class)];
    }
    /* The system's menus, such as the shell's popup menus (`ShellMenuPresenter`), are no
     * presented controllers: their container lies over the window while one shows. */
    for (UIView *view in other.subviews) {
      NSString *name = NSStringFromClass(view.class);
      if (!view.hidden && view.alpha > 0.01 &&
          ([name containsString:@"ContextMenu"] || [name containsString:@"EditMenu"]))
      {
        return [@"menu " stringByAppendingString:name];
      }
    }
  }
  return nil;
}

/** Why Blender takes no pointer or touch at \a point, in the window's points, or nil. */
- (NSString *)blockedAt:(CGPoint)point
{
  if (NSString *reason = [self blockedReason]) {
    return reason;
  }
  UIView *hit = [self hitTest:point withEvent:nil];
  if (![self isBlenderPencilInputView:hit]) {
    return [@"over " stringByAppendingString:hit ? NSStringFromClass(hit.class) : @"nothing"];
  }
  return nil;
}

- (BOOL)blenderTakesPointerAt:(CGPoint)point
{
  return [self blockedAt:point] == nil;
}

/** The window's point a pointer was last seen at, or the viewport's middle before any. */
- (CGPoint)pointerLocation
{
  if (pointer_location_known || !window) {
    return pointer_location;
  }
  const CGRect bounds = window->getView().bounds;
  return [window->getView() convertPoint:CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds))
                                  toView:self];
}

/**
 * Input of \a kind arrived while something is presented, and Blender is not given it: logged (at
 * most every two seconds for each kind, ROUND5 9G.1, so a session's log says which path delivered
 * it), navigation's momentum stopped, and Blender's hover highlight cleared.
 */
- (void)inputBehind:(NSString *)kind reason:(NSString *)reason at:(CGPoint)point
{
  if (![reason hasPrefix:@"presented"] && ![reason hasPrefix:@"menu"]) {
    return;
  }
  [self stopOrbitMomentum];
  [self parkPointer];
  if (!behind_logged) {
    behind_logged = [[NSMutableDictionary alloc] init];
  }
  NSDate *last = behind_logged[kind];
  if (last && -last.timeIntervalSinceNow < 2.0) {
    return;
  }
  behind_logged[kind] = [NSDate date];
  /* Tested from the window in front, as UIKit delivers it (ROUND5 12C.3): a sheet or menu may be
   * in a window of its own. What is hit belongs to what is presented when it is in another window
   * in front of this one, or in a presented controller's view: the input is on the sheet, which
   * takes it; otherwise it would land behind it. */
  UIView *hit = nil;
  NSArray<UIWindow *> *windows = [self.windowScene.windows
      sortedArrayUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        return a.windowLevel > b.windowLevel ? NSOrderedAscending :
               a.windowLevel < b.windowLevel ? NSOrderedDescending :
                                               NSOrderedSame;
      }];
  for (UIWindow *front in windows.count ? windows : @[ self ]) {
    if (front.hidden || front.alpha < 0.01) {
      continue;
    }
    hit = [front hitTest:[self convertPoint:point toView:front] withEvent:nil];
    if (hit) {
      break;
    }
  }
  bool on_sheet = hit && hit.window != self;
  for (UIViewController *presented = self.rootViewController.presentedViewController;
       presented && hit && !on_sheet;
       presented = presented.presentedViewController)
  {
    on_sheet = [hit isDescendantOfView:presented.view];
  }
  ios_log(@"input",
          [NSString stringWithFormat:@"%@ sheet: %@ at %d,%d, %@, hit %@",
                                     on_sheet ? @"on" : @"behind",
                                     kind,
                                     int(point.x),
                                     int(point.y),
                                     reason,
                                     hit ? NSStringFromClass(hit.class) : @"nothing"]);
}

/** Blender's cursor off the view, which clears what it highlights under it, until the pointer or
 * a key brings it back (#generateUserInputEvents:, #handleKeyboardEvent:keyWindow:). */
- (void)parkPointer
{
  ios_pencil_hover(false, 0, 0);
  ios_navigation_hover(false);
  if (pointer_parked || !window || !system) {
    return;
  }
  pointer_parked = true;
  system->pushEvent(std::make_unique<GHOST_EventCursor>(system->getMilliSeconds(),
                                                        GHOST_kEventCursorMove,
                                                        window,
                                                        -10000,
                                                        -10000,
                                                        GHOST_TABLET_DATA_NONE));
}

/** A recognizer's input of \a kind at its place: true if Blender may have it. Otherwise it is
 * noted and the gesture is cancelled, so none of it reaches Blender. */
- (BOOL)gate:(UIGestureRecognizer *)sender kind:(NSString *)kind
{
  const CGPoint point = [sender locationInView:self];
  NSString *reason = [self blockedAt:point];
  if (reason == nil) {
    return YES;
  }
  [self inputBehind:kind reason:reason at:point];
  if (sender.state == UIGestureRecognizerStateBegan ||
      sender.state == UIGestureRecognizerStateChanged)
  {
    sender.enabled = NO;
    sender.enabled = YES;
  }
  return NO;
}

static NSString *ios_event_kind(UIEvent *event)
{
  switch (event.type) {
    case UIEventTypeTouches:
      return @"touch";
    case UIEventTypeScroll:
      return @"scroll";
    case UIEventTypeHover:
      return @"hover";
    case UIEventTypeTransform:
      return @"transform";
    case UIEventTypePresses:
      return @"key";
    default:
      return [NSString stringWithFormat:@"event %d", int(event.type)];
  }
}

/* -------------------------------------------------------------------- */
/* Hardware keyboard
 *
 * Keys go to Blender's keymap as on the desktop, except while text is typed into a native field
 * or a native sheet or alert shows. Modifier keys and Escape reach UIKit too, so holding Command
 * shows the menu bar's shortcuts; other keys don't, so UIKit's own uses of Tab, Space or arrows
 * can't act on the interface around Blender. */

- (bool)blenderTakesKeyboard
{
  /* The gate's first half, which the pointer's shares (ROUND5 9G.1): the two cannot disagree. */
  if ([self blockedReason] != nil) {
    return false;
  }
  UIResponder *responder = current_first_responder();
  return ![responder conformsToProtocol:@protocol(UIKeyInput)];
}

- (void)pushKey:(GHOST_TKey)key down:(bool)down repeat:(bool)repeat utf8:(const char *)utf8
{
  system->pushEvent(std::make_unique<GHOST_EventKey>(system->getMilliSeconds(),
                                                     down ? GHOST_kEventKeyDown :
                                                            GHOST_kEventKeyUp,
                                                     window,
                                                     key,
                                                     repeat,
                                                     down ? utf8 : nullptr));
}

- (BOOL)handleKeyboardEvent:(UIPressesEvent *)event
{
  return [self handleKeyboardEvent:event keyWindow:YES];
}

/* Modifier keys are followed whichever window has the keyboard, such as another scene's
 * Outliner on Apple Vision Pro, or a search field: holding Shift then still extends a click in
 * the viewport. Other keys only reach Blender from the key window. */
- (BOOL)handleKeyboardEvent:(UIPressesEvent *)event keyWindow:(BOOL)key_window
{
  if (!window || !system) {
    return NO;
  }
  if (!held_keys) {
    held_keys = [[NSMutableDictionary alloc] init];
  }
  bool takes = false;
  bool hide_from_uikit = false;
  for (UIPress *press in event.allPresses) {
    UIKey *ui_key = press.key;
    if (!ui_key) {
      continue;
    }
    NSNumber *usage = @(ui_key.keyCode);
    const bool down = press.phase == UIPressPhaseBegan;
    const bool up = press.phase == UIPressPhaseEnded || press.phase == UIPressPhaseCancelled;
    if (!down && !up) {
      continue;
    }
    GHOST_TKey key;
    if (up) {
      /* A release goes where its press went. */
      NSNumber *held = held_keys[usage];
      if (!held) {
        continue;
      }
      key = GHOST_TKey(held.intValue);
      [held_keys removeObjectForKey:usage];
    }
    else {
      NSString *base = ui_key.charactersIgnoringModifiers;
      key = convertKey(int(ui_key.keyCode), base.length ? [base characterAtIndex:0] : 0);
      if (key == GHOST_kKeyUnknown) {
        continue;
      }
      GHOST_TModifierKey modifier;
      if (!modifier_from_key(key, &modifier) &&
          (!key_window || (!takes && ![self blenderTakesKeyboard])))
      {
        continue;
      }
      held_keys[usage] = @(int(key));
    }
    takes = true;

    /* Keys go to the editor under the pointer, as on the desktop. Without a Pencil, mouse or
     * trackpad there has been none yet: use the middle of the view, the viewport. */
    int32_t pointer_x, pointer_y;
    if (down && window->getPointerPosition(pointer_x, pointer_y) != GHOST_kSuccess) {
      const CGSize size = window->getView().bounds.size;
      CGPoint middle = CGPointMake(size.width / 2, size.height / 2);
      middle = window->scalePointToWindow(middle);
      UserInputEvent move(&middle, nullptr, nullptr, false);
      move.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
      [self generateUserInputEvents:move];
    }
    else if (down && pointer_parked) {
      /* Blender's cursor was moved off the view while something was presented (#parkPointer):
       * the key goes to the editor under the pointer, where it was. */
      CGPoint back = CGPointMake(pointer_x, pointer_y);
      UserInputEvent move(&back, nullptr, nullptr, false);
      move.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
      [self generateUserInputEvents:move];
    }

    GHOST_TModifierKey modifier;
    const bool is_modifier = modifier_from_key(key, &modifier);
    if (is_modifier) {
      GHOST_ios_set_modifier_held(modifier, down);
    }
    else if (key != GHOST_kKeyEsc) {
      /* Escape also closes native panels, such as the Outliner, as their cancel action. */
      hide_from_uikit = true;
    }

    /* Text as on macOS: none for commands, arrows and function keys. */
    char utf8[6] = {0};
    NSString *text = ui_key.characters;
    if (down && !is_modifier && text.length &&
        !(ui_key.modifierFlags & (UIKeyModifierCommand | UIKeyModifierControl)) &&
        !(key >= GHOST_kKeyLeftArrow && key <= GHOST_kKeyDownArrow) &&
        !(key >= GHOST_kKeyF1 && key <= GHOST_kKeyF24))
    {
      const char *bytes = text.UTF8String;
      if (bytes && strlen(bytes) < sizeof(utf8) && uint8_t(bytes[0]) >= 0x20 && bytes[0] != 0x7f)
      {
        strcpy(utf8, bytes);
      }
    }
    [self pushKey:key down:down repeat:false utf8:utf8];

    if (down && !is_modifier) {
      [self startKeyRepeat:key utf8:utf8];
    }
    else if (up && key == key_repeat_key) {
      [self stopKeyRepeat];
    }
  }
  return hide_from_uikit;
}

/** UIKit doesn't repeat hardware keys, Blender expects them to repeat as the desktop does. */
- (void)startKeyRepeat:(GHOST_TKey)key utf8:(const char *)utf8
{
  key_repeat_key = key;
  memcpy(key_repeat_utf8, utf8, sizeof(key_repeat_utf8));
  key_repeat_next = CACurrentMediaTime() + 0.45;
  if (!key_repeat_link) {
    key_repeat_link = [[CADisplayLink displayLinkWithTarget:self
                                                   selector:@selector(repeatKey:)] retain];
    key_repeat_link.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 30);
    [key_repeat_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  }
}

- (void)repeatKey:(CADisplayLink *)link
{
  if (!window || !system) {
    [self stopKeyRepeat];
    return;
  }
  if (link.timestamp < key_repeat_next) {
    return;
  }
  key_repeat_next = link.timestamp + 1.0 / 30.0;
  [self pushKey:key_repeat_key down:true repeat:true utf8:key_repeat_utf8];
}

- (void)stopKeyRepeat
{
  [key_repeat_link invalidate];
  [key_repeat_link release];
  key_repeat_link = nil;
  key_repeat_key = GHOST_kKeyUnknown;
}

/** Release every held key, such as when the app leaves the foreground with keys down. */
- (void)releaseKeys
{
  [self stopKeyRepeat];
  for (NSNumber *held in held_keys.allValues) {
    const GHOST_TKey key = GHOST_TKey(held.intValue);
    GHOST_TModifierKey modifier;
    if (modifier_from_key(key, &modifier)) {
      GHOST_ios_set_modifier_held(modifier, false);
    }
    if (window && system) {
      [self pushKey:key down:false repeat:false utf8:nullptr];
    }
  }
  [held_keys removeAllObjects];
}

/* -------------------------------------------------------------------- */
/* Mouse and trackpad
 *
 * As on the desktop: the pointer moves Blender's cursor and its buttons are mouse buttons, a
 * mouse wheel scrolls in steps, and a trackpad's two-finger scroll, pinch and twist are trackpad
 * gestures as on a Mac. The pointer shows Blender's cursor over the view. */

- (bool)pointerOverViewport:(CGPoint)location_in_window
{
  return [self isBlenderPencilInputView:[self hitTest:location_in_window withEvent:nil]];
}

- (void)sendPointerMove:(CGPoint)location
{
  tablet_data = GHOST_TABLET_DATA_NONE;
  CGPoint point = window->scalePointToWindow(location);
  UserInputEvent event_info(&point, nullptr, nullptr, false);
  event_info.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
  [self generateUserInputEvents:event_info];
}

- (void)handlePointerHover:(UIHoverGestureRecognizer *)sender
{
  if (!window || pointer_touch) {
    return;
  }
  const CGPoint in_window = [sender locationInView:self];
  pointer_location = in_window;
  pointer_location_known = true;
  const bool moving = sender.state == UIGestureRecognizerStateBegan ||
                      sender.state == UIGestureRecognizerStateChanged;
  NSString *reason = moving ? [self blockedAt:in_window] : nil;
  if (reason != nil) {
    /* Behind something presented, Blender's highlight under the pointer is cleared too. */
    [self inputBehind:@"pointer hover" reason:reason at:in_window];
  }
  const bool hovering = moving && reason == nil;
  if (!hovering) {
    /* Paint cursors and hover highlights show while something hovers over the view. */
    ios_pencil_hover(false, 0, 0);
    return;
  }
  const CGPoint location = [sender locationInView:window->getView()];
  [self sendPointerMove:location];
  CGPoint point = location;
  point = window->scalePointToWindow(point);
  ios_pencil_hover(true, point.x, point.y);
}

static GHOST_TButton pointer_button(int index)
{
  switch (index) {
    case 0:
      return GHOST_kButtonMaskLeft;
    case 1:
      return GHOST_kButtonMaskRight;
    case 2:
      return GHOST_kButtonMaskMiddle;
    case 3:
      return GHOST_kButtonMaskButton4;
    default:
      return GHOST_kButtonMaskButton5;
  }
}

- (void)sendPointerButtons:(UIEventButtonMask)buttons
{
  for (int index = 0; index < 5; index++) {
    const UIEventButtonMask mask = UIEventButtonMaskForButtonNumber(index + 1);
    if ((buttons & mask) == (pointer_buttons & mask)) {
      continue;
    }
    system->pushEvent(std::make_unique<GHOST_EventButton>(system->getMilliSeconds(),
                                                          (buttons & mask) ?
                                                              GHOST_kEventButtonDown :
                                                              GHOST_kEventButtonUp,
                                                          window,
                                                          pointer_button(index),
                                                          GHOST_TABLET_DATA_NONE));
  }
  pointer_buttons = buttons;
}

/** A click or drag of the pointer, which began over the view. */
- (void)handlePointerTouch:(UITouch *)touch event:(UIEvent *)event
{
  if (!window || !system) {
    return;
  }
  if (touch.phase == UITouchPhaseBegan) {
    if (pointer_touch || ![self touchBeganInBlenderViewport:touch]) {
      return;
    }
    pointer_touch = touch;
    pointer_buttons = 0;
    ios_pencil_hover(false, 0, 0);
  }
  if (touch != pointer_touch) {
    return;
  }
  const bool released = touch.phase == UITouchPhaseEnded ||
                        touch.phase == UITouchPhaseCancelled;
  if (touch.phase == UITouchPhaseMoved) {
    NSArray<UITouch *> *samples = [event coalescedTouchesForTouch:touch];
    for (UITouch *sample in samples.count ? samples : @[ touch ]) {
      [self sendPointerMove:[sample preciseLocationInView:window->getView()]];
    }
  }
  else {
    [self sendPointerMove:[touch preciseLocationInView:window->getView()]];
  }
  /* A click without a mask, as from a tap on a trackpad, is the primary button. */
  UIEventButtonMask buttons = event.buttonMask ? event.buttonMask : UIEventButtonMaskPrimary;
  [self sendPointerButtons:released ? 0 : buttons];
  if (released) {
    pointer_touch = nil;
  }
}

/** Release the pointer's buttons, as when the app leaves the foreground during a drag. */
- (void)releasePointerButtons
{
  if (window && system) {
    [self sendPointerButtons:0];
  }
  pointer_buttons = 0;
  pointer_touch = nil;
  navigation_button_touch = nil;
  navigation_button_active = false;
}

/* -------------------------------------------------------------------- */
/** \name A navigation gizmo's buttons (ROUND5 12D, decision 78)
 *
 * A finger or the Pencil that begins on one of a navigation gizmo's buttons is given to Blender
 * as a pointer's press, moves and release, for as long as the touch lasts, as a mouse's on the
 * desktop: Blender's own button then zooms, pans or toggles, about the view's centre. No tablet
 * data, no orbit, no pan, no pinch for that touch. Blender says which part is where
 * (#GHOST_IOSNativeInterface::navigation_part_at). The 3D View's axes keep the shell's hotspot in
 * the iPad interface, whose touches never begin on this view; where there is none, as in
 * Blender's own interface, the axes are answered the same way.
 * \{ */

static NSString *ios_navigation_part_name(const int part)
{
  switch (part) {
    case GHOST_kIOSNavigationAxes:
      return @"axes";
    case GHOST_kIOSNavigationZoom:
      return @"zoom";
    case GHOST_kIOSNavigationMove:
      return @"move";
    case GHOST_kIOSNavigationCamera:
      return @"camera";
    case GHOST_kIOSNavigationProjection:
      return @"projection";
    case GHOST_kIOSNavigationCameraLock:
      return @"camera lock";
    default:
      return @"none";
  }
}

- (BOOL)navigationButtonTouch:(int)phase at:(CGPoint)point
{
  if (!window || !system) {
    return NO;
  }
  if (phase == 0) {
    navigation_button_active = false;
    const CGPoint pixels = window->scalePointToWindow(point);
    const GHOST_IOSNativeInterface *native = GHOST_ios_native_interface();
    const int part = native && native->navigation_part_at ?
                         native->navigation_part_at(static_cast<GHOST_IWindow *>(window),
                                                    int(pixels.x),
                                                    int(pixels.y)) :
                         int(GHOST_kIOSNavigationNone);
    if (part == GHOST_kIOSNavigationNone) {
      return NO;
    }
    /* The input gate (ROUND5 9G.1), as every other input asks it. */
    if (NSString *reason = [self blockedReason]) {
      [self inputBehind:@"gizmo button"
                 reason:reason
                     at:[window->getView() convertPoint:point toView:self]];
      return NO;
    }
    [self stopOrbitMomentum];
    ios_pencil_hover(false, 0, 0);
    navigation_button_active = true;
    navigation_button_part = part;
    navigation_button_start = point;
    navigation_button_last = point;
    [self sendPointerMove:point];
    [self sendPointerButtons:UIEventButtonMaskPrimary];
    return YES;
  }
  if (!navigation_button_active) {
    return NO;
  }
  if (phase == 1 || phase == 2) {
    navigation_button_last = point;
    [self sendPointerMove:point];
  }
  if (phase == 1) {
    return YES;
  }
  /* One line a gesture, at its end (ROUND5 12C.1, 12D.6). */
  const CGFloat dx = navigation_button_last.x - navigation_button_start.x;
  const CGFloat dy = navigation_button_last.y - navigation_button_start.y;
  NSString *gesture = hypot(dx, dy) < 10.0 ?
                          @"tap" :
                          [NSString stringWithFormat:@"drag %d,%d pt", int(dx), int(dy)];
  ios_log(@"gizmo",
          [NSString stringWithFormat:@"%@ %@%@",
                                     ios_navigation_part_name(navigation_button_part),
                                     gesture,
                                     phase == 3 ? @" (cancelled)" : @""]);
  if (phase == 3) {
    [self releasePointerButtons];
  }
  else {
    [self sendPointerButtons:0];
  }
  navigation_button_active = false;
  /* Blender's highlight stays under no finger. */
  [self parkPointer];
  return YES;
}

/** A finger or the Pencil on a navigation gizmo's button: true when it is that touch, which
 * nothing else then takes. */
- (BOOL)handleNavigationButtonTouch:(UITouch *)touch event:(UIEvent *)event
{
  if (touch.phase == UITouchPhaseBegan) {
    if (navigation_button_touch != nil || touch.view != window->getView() ||
        ![self touchBeganInBlenderViewport:touch] ||
        ![self navigationButtonTouch:0 at:[touch preciseLocationInView:window->getView()]])
    {
      return NO;
    }
    navigation_button_touch = touch;
    return YES;
  }
  if (touch != navigation_button_touch) {
    return NO;
  }
  switch (touch.phase) {
    case UITouchPhaseMoved: {
      NSArray<UITouch *> *samples = [event coalescedTouchesForTouch:touch];
      for (UITouch *sample in samples.count ? samples : @[ touch ]) {
        [self navigationButtonTouch:1 at:[sample preciseLocationInView:window->getView()]];
      }
      break;
    }
    case UITouchPhaseEnded:
      navigation_button_touch = nil;
      [self navigationButtonTouch:2 at:[touch preciseLocationInView:window->getView()]];
      break;
    case UITouchPhaseCancelled:
      navigation_button_touch = nil;
      [self navigationButtonTouch:3 at:[touch preciseLocationInView:window->getView()]];
      break;
    default:
      break;
  }
  return YES;
}

/** \} */

- (void)handleTrackpadScroll:(UIPanGestureRecognizer *)sender
{
  if (!window || !system || ![self gate:sender kind:@"trackpad scroll"]) {
    return;
  }
  if (sender.state == UIGestureRecognizerStateBegan) {
    scroll_translation = CGPointZero;
  }
  if (sender.state != UIGestureRecognizerStateBegan &&
      sender.state != UIGestureRecognizerStateChanged)
  {
    return;
  }
  CGPoint translation = [sender translationInView:window->getView()];
  CGPoint delta = CGPointMake(translation.x - scroll_translation.x,
                              translation.y - scroll_translation.y);
  scroll_translation = translation;
  delta = window->scalePointToWindow(delta);
  CGPoint location = [sender locationInView:window->getView()];
  location = window->scalePointToWindow(location);
  if (delta.x == 0 && delta.y == 0) {
    return;
  }
  /* The content follows the fingers, as natural scrolling does on a Mac. */
  system->pushEvent(std::make_unique<GHOST_EventTrackpad>(system->getMilliSeconds(),
                                                          window,
                                                          GHOST_kTrackpadEventScroll,
                                                          location.x,
                                                          location.y,
                                                          delta.x,
                                                          delta.y,
                                                          true));
}

- (void)handleWheelScroll:(UIPanGestureRecognizer *)sender
{
  if (!window || !system || ![self gate:sender kind:@"wheel"]) {
    return;
  }
  if (sender.state == UIGestureRecognizerStateBegan) {
    scroll_translation = CGPointZero;
  }
  if (sender.state != UIGestureRecognizerStateBegan &&
      sender.state != UIGestureRecognizerStateChanged)
  {
    return;
  }
  const CGPoint translation = [sender translationInView:window->getView()];
  const CGPoint delta = CGPointMake(translation.x - scroll_translation.x,
                                    translation.y - scroll_translation.y);
  scroll_translation = translation;
  CGPoint location = [sender locationInView:window->getView()];
  [self sendPointerMove:location];
  /* One wheel step for each step, as on a Mac. */
  if (delta.y != 0) {
    system->pushEvent(std::make_unique<GHOST_EventWheel>(
        system->getMilliSeconds(), window, GHOST_kEventWheelAxisVertical, delta.y > 0 ? 1 : -1));
  }
  if (delta.x != 0) {
    system->pushEvent(std::make_unique<GHOST_EventWheel>(system->getMilliSeconds(),
                                                         window,
                                                         GHOST_kEventWheelAxisHorizontal,
                                                         delta.x > 0 ? 1 : -1));
  }
}

/** Trackpad gestures in whole units as a Mac sends them, keeping what doesn't add up to one. */
static int32_t trackpad_units(double value, double *remainder)
{
  const double total = value + *remainder;
  const double units = trunc(total);
  *remainder = total - units;
  return int32_t(units);
}

- (void)handleTrackpadPinch:(UIPinchGestureRecognizer *)sender
{
  static CGFloat last_scale = 1.0;
  static double remainder = 0.0;
  if (!window || !system || ![self gate:sender kind:@"trackpad pinch"]) {
    return;
  }
  if (sender.state == UIGestureRecognizerStateBegan) {
    last_scale = 1.0;
    remainder = 0.0;
  }
  if (sender.state != UIGestureRecognizerStateBegan &&
      sender.state != UIGestureRecognizerStateChanged)
  {
    return;
  }
  /* The change in magnification, scaled as #GHOST_SystemCocoa does. */
  const int32_t delta = trackpad_units((sender.scale - last_scale) * 125.0, &remainder);
  last_scale = sender.scale;
  CGPoint location = [sender locationInView:window->getView()];
  location = window->scalePointToWindow(location);
  if (delta != 0) {
    system->pushEvent(std::make_unique<GHOST_EventTrackpad>(system->getMilliSeconds(),
                                                            window,
                                                            GHOST_kTrackpadEventMagnify,
                                                            location.x,
                                                            location.y,
                                                            delta,
                                                            0,
                                                            false));
  }
}

- (void)handleTrackpadRotation:(UIRotationGestureRecognizer *)sender
{
  static double remainder = 0.0;
  if (!window || !system || ![self gate:sender kind:@"trackpad rotation"]) {
    return;
  }
  if (sender.state == UIGestureRecognizerStateBegan) {
    remainder = 0.0;
  }
  if (sender.state != UIGestureRecognizerStateBegan &&
      sender.state != UIGestureRecognizerStateChanged)
  {
    return;
  }
  /* Degrees, scaled as #GHOST_SystemCocoa does. */
  const int32_t delta = trackpad_units(sender.rotation * 180.0 / M_PI * -5.0, &remainder);
  sender.rotation = 0.0;
  CGPoint location = [sender locationInView:window->getView()];
  location = window->scalePointToWindow(location);
  if (delta != 0) {
    system->pushEvent(std::make_unique<GHOST_EventTrackpad>(system->getMilliSeconds(),
                                                            window,
                                                            GHOST_kTrackpadEventRotate,
                                                            location.x,
                                                            location.y,
                                                            delta,
                                                            0,
                                                            false));
  }
}

/* Shapes for the pointer, around its point. */
#if !defined(APPLE_TARGET_VISIONOS) /* The pointer's shapes; Apple Vision Pro shows its own. */
static UIBezierPath *pointer_crosshair()
{
  UIBezierPath *path = [UIBezierPath bezierPathWithRect:CGRectMake(-9, -0.75, 18, 1.5)];
  [path appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(-0.75, -9, 1.5, 18)]];
  return path;
}

/** A double arrow along x, turned a quarter for y. */
static UIBezierPath *pointer_double_arrow(bool vertical)
{
  UIBezierPath *path = [UIBezierPath bezierPath];
  [path moveToPoint:CGPointMake(-10, 0)];
  [path addLineToPoint:CGPointMake(-5, -5)];
  [path addLineToPoint:CGPointMake(-5, -1.25)];
  [path addLineToPoint:CGPointMake(5, -1.25)];
  [path addLineToPoint:CGPointMake(5, -5)];
  [path addLineToPoint:CGPointMake(10, 0)];
  [path addLineToPoint:CGPointMake(5, 5)];
  [path addLineToPoint:CGPointMake(5, 1.25)];
  [path addLineToPoint:CGPointMake(-5, 1.25)];
  [path addLineToPoint:CGPointMake(-5, 5)];
  [path closePath];
  if (vertical) {
    [path applyTransform:CGAffineTransformMakeRotation(M_PI_2)];
  }
  return path;
}

static UIBezierPath *pointer_move()
{
  UIBezierPath *path = pointer_double_arrow(false);
  [path appendPath:pointer_double_arrow(true)];
  path.usesEvenOddFillRule = NO;
  return path;
}

- (void)refreshPointer
{
  [pointer_interaction invalidate];
}

- (UIPointerRegion *)pointerInteraction:(UIPointerInteraction *)interaction
                       regionForRequest:(UIPointerRegionRequest *)request
                          defaultRegion:(UIPointerRegion *)defaultRegion
{
  UNUSED_VARS(interaction, request);
  return defaultRegion;
}

- (UIPointerStyle *)pointerInteraction:(UIPointerInteraction *)interaction
                        styleForRegion:(UIPointerRegion *)region
{
  UNUSED_VARS(interaction, region);
  if (!window) {
    return nil;
  }
  if (!window->pointer_cursor_visible.load()) {
    return [UIPointerStyle hiddenPointerStyle];
  }
  UIBezierPath *path = nil;
  switch (GHOST_TStandardCursor(window->pointer_cursor.load())) {
    case GHOST_kStandardCursorText:
      return [UIPointerStyle
          styleWithShape:[UIPointerShape beamWithPreferredLength:22 axis:UIAxisVertical]
          constrainedAxes:UIAxisNeither];
    case GHOST_kStandardCursorCrosshair:
    case GHOST_kStandardCursorCrosshairA:
    case GHOST_kStandardCursorCrosshairB:
    case GHOST_kStandardCursorCrosshairC:
    case GHOST_kStandardCursorPencil:
    case GHOST_kStandardCursorEraser:
    case GHOST_kStandardCursorKnife:
    case GHOST_kStandardCursorEyedropper:
    case GHOST_kStandardCursorBlade:
    case GHOST_kStandardCursorCustom:
      path = pointer_crosshair();
      break;
    case GHOST_kStandardCursorMove:
    case GHOST_kStandardCursorNSEWScroll:
      path = pointer_move();
      break;
    case GHOST_kStandardCursorVerticalSplit:
    case GHOST_kStandardCursorLeftRight:
    case GHOST_kStandardCursorEWScroll:
    case GHOST_kStandardCursorLeftSide:
    case GHOST_kStandardCursorRightSide:
    case GHOST_kStandardCursorLeftHandle:
    case GHOST_kStandardCursorRightHandle:
    case GHOST_kStandardCursorBothHandles:
    case GHOST_kStandardCursorSlip:
      path = pointer_double_arrow(false);
      break;
    case GHOST_kStandardCursorHorizontalSplit:
    case GHOST_kStandardCursorUpDown:
    case GHOST_kStandardCursorNSScroll:
    case GHOST_kStandardCursorTopSide:
    case GHOST_kStandardCursorBottomSide:
      path = pointer_double_arrow(true);
      break;
    default:
      /* The iPad's own pointer, for Blender's arrows and the rest. */
      return nil;
  }
  return [UIPointerStyle styleWithShape:[UIPointerShape shapeWithPath:path]
                        constrainedAxes:UIAxisNeither];
}
#endif

- (void)handleNavigationTap:(UITapGestureRecognizer *)gesture
{
  if (!window || gesture.state != UIGestureRecognizerStateEnded) {
    return;
  }
  CGPoint location = [gesture locationInView:window->getView()];
  CGPoint point = window->scalePointToWindow(location);
  tablet_data = GHOST_TABLET_DATA_NONE;
  /* Axis picking needs an absolute event, including a finger tap without hover. */
  tablet_data.Active = GHOST_kTabletModeStylus;
  tablet_data.Pressure = 1.0f;
  UserInputEvent event(&point, nullptr, nullptr, true);
  event.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
  event.add_event(UserInputEvent::EventTypes::LEFT_BUTTON_DOWN);
  [self generateUserInputEvents:event];
  tablet_data.Pressure = 0.0f;
  UserInputEvent up(&point, nullptr, nullptr, true);
  up.add_event(UserInputEvent::EventTypes::LEFT_BUTTON_UP);
  [self generateUserInputEvents:up];
  tablet_data = GHOST_TABLET_DATA_NONE;
}

- (void)handleTap:(GHOSTUITapGestureRecognizer *)sender
{
  if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone &&
      !finger_tool_enabled && sender.state == UIGestureRecognizerStateEnded)
  {
    CGPoint point = [sender getScaledTouchPoint:window];
    tablet_data = GHOST_TABLET_DATA_NONE;
    UserInputEvent event_info(&point, nullptr, nullptr, false);
    event_info.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
    event_info.add_event(UserInputEvent::EventTypes::LEFT_BUTTON_DOWN);
    event_info.add_event(UserInputEvent::EventTypes::LEFT_BUTTON_UP);
    [self generateUserInputEvents:event_info];
  }
  /* Finger taps are reserved for native iPad UI affordances and viewport gestures. Selection and
   * active-tool execution are handled by Apple Pencil instead. */
  UNUSED_VARS(sender);
}

- (void)handleTap2F:(GHOSTUITapGestureRecognizer *)sender
{
  if (sender.state != UIGestureRecognizerStateEnded || [self fingerTweakHolds]) {
    return;
  }

  CGPoint touch_point = [sender locationInView:window->getView()];
  CGFloat scale = [window->getView() contentScaleFactor];
  touch_point.x *= scale;
  touch_point.y *= scale;

  system->pushEvent(
      std::make_unique<GHOST_Event>(system->getMilliSeconds(), GHOST_kEventTwoFingerTap, window));
}

- (void)handleTap3F:(GHOSTUITapGestureRecognizer *)sender
{
  if (sender.state != UIGestureRecognizerStateEnded || [self fingerTweakHolds]) {
    return;
  }

  CGPoint touch_point = [sender locationInView:window->getView()];
  CGFloat scale = [window->getView() contentScaleFactor];
  touch_point.x *= scale;
  touch_point.y *= scale;

  system->pushEvent(std::make_unique<GHOST_Event>(
      system->getMilliSeconds(), GHOST_kEventThreeFingerTap, window));
}

- (void)handleTap4F:(GHOSTUITapGestureRecognizer *)sender
{
  if (sender.state != UIGestureRecognizerStateEnded || [self fingerTweakHolds]) {
    return;
  }

  CGPoint touch_point = [sender locationInView:window->getView()];
  CGFloat scale = [window->getView() contentScaleFactor];
  touch_point.x *= scale;
  touch_point.y *= scale;

  system->pushEvent(
      std::make_unique<GHOST_Event>(system->getMilliSeconds(), GHOST_kEventFourFingerTap, window));
}

- (void)handlePan:(GHOSTUIPanGestureRecognizer *)sender
{
  /* With the Pencil on the tool: one finger orbits, two or three pan. */
  if (finger_tool_enabled) {
    return;
  }
  [self handleNavigationDrag:sender orbitingFingers:1];
}

/**
 * A drag that navigates the view: with `orbiting_fingers` it orbits, with more it pans. A finger
 * coming or going changes which, smoothly: the drag goes on from where it is, without a jump, as
 * the fingers' middle moves when their count changes.
 */
/* -------------------------------------------------------------------- */
/** \name The orbit
 *
 * The app has one orbit (ROUND5 12A, decision 74): a finger's drag on the view and a drag that
 * begins on the navigation gizmo both begin, step and end it here, with the same gesture id, the
 * same steps, the same spin after a flick and the same guards.
 * \{ */

/** A new orbit: its own gesture id, the last one's spin stopped. */
- (void)orbitBegin:(bool)from_gizmo
{
  [self stopOrbitMomentum];
  /* UIKit delivers gestures on the main thread. IDs are unique across windows, and remain
   * attached to queued events even if the next drag has already begun. */
  static uint64_t next_orbit_gesture_id = 0;
  orbit_gesture_id = ++next_orbit_gesture_id;
  orbit_from_gizmo = from_gizmo;
}

/** One step of the orbit by \a relative window pixels, at \a point. Not while a finger holds an
 * object with Tweak. */
- (void)orbitStep:(CGPoint)relative at:(CGPoint)point
{
  if (CGPointEqualToPoint(relative, CGPointMake(0.0f, 0.0f)) || [self fingerTweakHolds]) {
    return;
  }
  UserInputEvent event_info(&point, nullptr, nullptr, false);
  event_info.translation = CGPointMake(-relative.x, -relative.y);
  event_info.add_event(UserInputEvent::EventTypes::ORBIT_GESTURE);
  event_info.gesture_id = orbit_gesture_id;
  event_info.from_gizmo = orbit_from_gizmo;
  [self generateUserInputEvents:event_info];
}

/** The orbit ends at \a point; with \a spin it spins on at \a velocity (the view's points a
 * second), as after a flick. */
- (void)orbitEndAt:(CGPoint)point velocity:(CGPoint)velocity spin:(bool)spin
{
  if (!spin || pencil_button_active || [self fingerTweakHolds]) {
    return;
  }
  const CGFloat speed = hypot(velocity.x, velocity.y);
  if (speed >= 80.0) {
    const CGFloat limit = MIN(1.0, 3000.0 / speed);
    orbit_velocity = CGPointMake(velocity.x * limit, velocity.y * limit);
    orbit_location = point;
    orbit_remainder = CGPointZero;
    orbit_timestamp = CACurrentMediaTime();
    orbit_display_link = [CADisplayLink displayLinkWithTarget:self
                                                     selector:@selector(updateOrbitMomentum:)];
    [orbit_display_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  }
}

- (BOOL)navigationGizmoDrag:(int)phase
                         at:(CGPoint)point
                translation:(CGPoint)translation
                   velocity:(CGPoint)velocity
{
  if (!window) {
    return NO;
  }
  CGPoint location = window->scalePointToWindow(point);
  if (phase == 0) {
    gizmo_orbit_active = false;
    /* The input gate (ROUND5 9G.1), as every other input asks it. */
    NSString *reason = [self blockedReason];
    if (reason != nil) {
      [self inputBehind:@"gizmo drag" reason:reason at:point];
      return NO;
    }
    [self orbitBegin:true];
    gizmo_orbit_active = true;
    /* The first step is measured from where the drag was recognised: no jump at the start. */
    gizmo_orbit_translation = translation;
    gizmo_orbit_location = location;
    return YES;
  }
  if (!gizmo_orbit_active) {
    return NO;
  }
  if (phase == 1) {
    if ([self blockedReason] != nil) {
      gizmo_orbit_active = false;
      return NO;
    }
    CGPoint relative = CGPointMake(translation.x - gizmo_orbit_translation.x,
                                   translation.y - gizmo_orbit_translation.y);
    gizmo_orbit_translation = translation;
    relative = window->scalePointToWindow(relative);
    [self orbitStep:relative at:gizmo_orbit_location];
    return YES;
  }
  gizmo_orbit_active = false;
  [self orbitEndAt:gizmo_orbit_location velocity:velocity spin:(phase == 2)];
  return YES;
}

/**
 * A drag that navigates the view: with `orbiting_fingers` it orbits, with more it pans. A finger
 * coming or going changes which, smoothly: the drag goes on from where it is, without a jump, as
 * the fingers' middle moves when their count changes.
 */
- (void)handleNavigationDrag:(GHOSTUIPanGestureRecognizer *)sender
             orbitingFingers:(NSUInteger)orbiting_fingers
{
  CGPoint touch_point = [sender getScaledTouchPoint:window];
  CGPoint translation = [sender getScaledTranslation:window];
  const NSUInteger touches = sender.numberOfTouches;

  if (sender.state == UIGestureRecognizerStateBegan ||
      sender.state == UIGestureRecognizerStateChanged)
  {
    const bool orbits = touches <= orbiting_fingers;
    if (sender.state == UIGestureRecognizerStateBegan || touches != navigation_touches) {
      [self stopOrbitMomentum];
      if (orbits && (sender.state == UIGestureRecognizerStateBegan || !navigation_orbits)) {
        [self orbitBegin:false];
      }
      [sender setCachedTranslation:translation];
      if (sender.state == UIGestureRecognizerStateBegan) {
        navigation_from_orbit = orbits && orbiting_fingers == 1;
      }
      navigation_touches = touches;
      navigation_orbits = orbits;
    }

    /* Calculate translation change since last begin/change event */
    CGPoint relative_translation = [sender getRelativeTranslation:translation];
    /* Update cached translation */
    [sender setCachedTranslation:translation];

    if (orbits) {
      [self orbitStep:relative_translation at:touch_point];
    }
    /* Not while a finger holds an object with Tweak. */
    else if (!CGPointEqualToPoint(relative_translation, CGPointMake(0.0f, 0.0f)) &&
             ![self fingerTweakHolds])
    {
      UserInputEvent pan(&touch_point, &relative_translation, nullptr, false);
      pan.add_event(UserInputEvent::EventTypes::PAN_GESTURE_TWO_FINGERS);
      [self generateUserInputEvents:pan];
    }
  }
  else if (sender.state == UIGestureRecognizerStateEnded ||
           sender.state == UIGestureRecognizerStateCancelled ||
           sender.state == UIGestureRecognizerStateFailed)
  {
    [sender setCachedTranslation:CGPointMake(0.0f, 0.0f)];
    const bool was_orbiting = navigation_orbits;
    navigation_touches = 0;
    navigation_orbits = false;
    navigation_from_orbit = false;
    /* Spinning on only from an orbit. */
    [self orbitEndAt:touch_point
            velocity:[sender velocityInView:window->getView()]
                spin:(sender.state == UIGestureRecognizerStateEnded && was_orbiting)];
  }
}

/** \} */

- (void)stopOrbitMomentum
{
  [orbit_display_link invalidate];
  orbit_display_link = nil;
}

- (void)applicationWillResignActive:(NSNotification *)notification
{
  UNUSED_VARS(notification);
  [self releaseKeys];
  [self releasePointerButtons];
  [self stopOrbitMomentum];
  [self cancelPencilStroke];
  [self cancelFingerTweakTouches];
  [pencil_context_menu cancel];
  ios_navigation_hover(false);
}

- (void)updateOrbitMomentum:(CADisplayLink *)display_link
{
  if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
      pencil_button_active || [self blockedReason] != nil)
  {
    [self stopOrbitMomentum];
    return;
  }

  const CFTimeInterval elapsed = display_link.timestamp - orbit_timestamp;
  if (elapsed <= 0.0) {
    return;
  }
  orbit_timestamp = display_link.timestamp;
  /* Integrate UIKit's exponential deceleration independently of the display refresh rate. */
  const double decay_rate = -1000.0 * log(UIScrollViewDecelerationRateNormal);
  const double decay = exp(-decay_rate * elapsed);
  const double distance_scale = (1.0 - decay) / decay_rate;
  CGPoint translation = CGPointMake(-orbit_velocity.x * distance_scale,
                                    -orbit_velocity.y * distance_scale);
  translation = window->scalePointToWindow(translation);
  translation.x += orbit_remainder.x;
  translation.y += orbit_remainder.y;
  CGPoint pixels = CGPointMake(trunc(translation.x), trunc(translation.y));
  orbit_remainder = CGPointMake(translation.x - pixels.x, translation.y - pixels.y);
  orbit_velocity.x *= decay;
  orbit_velocity.y *= decay;

  if (!CGPointEqualToPoint(pixels, CGPointZero)) {
    UserInputEvent event_info(&orbit_location, &pixels, nullptr, false);
    event_info.gesture_id = orbit_gesture_id;
    event_info.from_gizmo = orbit_from_gizmo;
    event_info.add_event(UserInputEvent::EventTypes::ORBIT_GESTURE);
    [self generateUserInputEvents:event_info];
  }
  if (hypot(orbit_velocity.x, orbit_velocity.y) < 8.0) {
    [self stopOrbitMomentum];
  }
}

- (void)handlePan2f:(GHOSTUIPanGestureRecognizer *)sender
{
  /* One finger uses the tool: two orbit, as one does with a Pencil, and three pan. Otherwise one
   * finger's drag navigates, with as many fingers as it has, see #handlePan. */
  if (finger_tool_enabled) {
    [self handleNavigationDrag:sender orbitingFingers:2];
  }
}

#if !defined(APPLE_TARGET_VISIONOS)
- (void)handleEdgeSwipe:(UIScreenEdgePanGestureRecognizer *)gesture
{
  if (gesture.state != UIGestureRecognizerStateEnded) {
    return;
  }

  UIView *view = window->getView();
  CGPoint location = [gesture locationInView:view];
  CGSize viewSize = view.bounds.size;

  GHOST_TTouchEventSubTypes ghostEventType;

  if (gesture.edges == UIRectEdgeLeft) {
    ghostEventType = GHOST_kTouchEventEdgeSwipeInLeft;
  }
  else if (gesture.edges == UIRectEdgeRight) {
    ghostEventType = GHOST_kTouchEventEdgeSwipeInRight;
  }
  else {
    /* For now only handle left/right. */
    return;
  }

  system->pushEvent(std::make_unique<GHOST_EventTouch>(
      system->getMilliSeconds(), window, ghostEventType, location.x, location.y));
}
#endif

- (void)handleHover:(GHOSTUIHoverGestureRecognizer *)sender
{
  if (!pencil_context_menu.active && (sender.state == UIGestureRecognizerStateBegan ||
                                     sender.state == UIGestureRecognizerStateChanged))
  {
    /* The gate (ROUND5 9G.1): the same question as every other input. */
    const CGPoint point = [sender locationInView:(UIView *)self];
    if (NSString *reason = [self blockedAt:point]) {
      [self inputBehind:@"pencil hover" reason:reason at:point];
      ios_navigation_hover(false);
      ios_pencil_hover(false, 0, 0);
      return;
    }
  }
  if ([pencil_context_menu handlePencilHover:sender]) {
    ios_navigation_hover(false);
    ios_pencil_hover(false, 0, 0);
    return;
  }
  if (pencil_button_active) {
    ios_pencil_hover(false, 0, 0);
    return;
  }
  if (sender.state == UIGestureRecognizerStateBegan ||
      sender.state == UIGestureRecognizerStateChanged)
  {
    ios_navigation_hover(true);
    /* Tablet needs to be set to stylus mode because we need
     * wmTabletData.is_motion_absolute set to true. */
    tablet_data.Active = GHOST_kTabletModeStylus;
    tablet_data.Pressure = 0.0f;
    CGPoint hover_point = [sender getScaledTouchPoint:window];
    UIView *hit = [self hitTest:[sender locationInView:self] withEvent:nil];
    ios_pencil_hover(![hit.accessibilityIdentifier isEqualToString:@"blender.viewport.navigation"],
                     hover_point.x,
                     hover_point.y);
    /* Add cursor move event. */
    UserInputEvent event_info(&hover_point, nullptr, nullptr, true);
    event_info.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
    [self generateUserInputEvents:event_info];
  }
  else if (sender.state == UIGestureRecognizerStateEnded ||
           sender.state == UIGestureRecognizerStateCancelled ||
           sender.state == UIGestureRecognizerStateFailed)
  {
    ios_navigation_hover(false);
    tablet_data = GHOST_TABLET_DATA_NONE;
    ios_pencil_hover(false, 0, 0);
  }
}

- (void)handleZoom:(GHOSTUIPinchGestureRecognizer *)sender
{
  /* Ignore any calls where don't have two touches to work with. */
  if ([sender numberOfTouches] < 2) {
    zoom_restart = true;
    return;
  }
  /* A one-finger orbit that a second finger turned into a pan: no zoom. */
  if (navigation_from_orbit) {
    zoom_restart = true;
    return;
  }

  /* Pinch/Zoom gestures */
  if (sender.state == UIGestureRecognizerStateBegan || zoom_restart) {
    zoom_restart = false;
    /* Set an initial distance value. */
    CGFloat point_distance = [sender getScaledDistance:window];
    [sender setCachedDistance:point_distance];
  }
  else if (sender.state == UIGestureRecognizerStateChanged) {

    /* Calculate change in distance since last event */
    CGFloat point_distance = [sender getScaledDistance:window];
    CGFloat relative_dist = point_distance - [sender getCachedDistance];

    /* Updated cached distance. */
    [sender setCachedDistance:point_distance];

    /* Send pinch/zoom event. */
    if (fabs(relative_dist) > 0.0 && ![self fingerTweakHolds]) {
      /* Calculate midpoint between the two touch points. */
      CGPoint midPoint = [sender getPinchMidpoint:window];

      UserInputEvent event_info(&midPoint, nullptr, &relative_dist, false);
      event_info.add_event(UserInputEvent::EventTypes::PINCH_GESTURE);
      [self generateUserInputEvents:event_info];
    }
  }
  /* Nothing to do here. */
  else if (sender.state == UIGestureRecognizerStateEnded ||
           sender.state == UIGestureRecognizerStateCancelled ||
           sender.state == UIGestureRecognizerStateFailed)
  {
  }
}

- (void)handleRotation:(UIRotationGestureRecognizer *)sender
{
  if (sender.state == UIGestureRecognizerStateBegan ||
      sender.state == UIGestureRecognizerStateChanged)
  {
    /* Twisting needs two fingers, and not a one-finger orbit's second one. */
    if (sender.numberOfTouches < 2 || navigation_from_orbit) {
      rotation_restart = true;
      sender.rotation = 0.0;
      return;
    }
    if (rotation_restart) {
      rotation_restart = false;
      sender.rotation = 0.0;
      return;
    }
    const CGFloat relative_rotation = sender.rotation;
    sender.rotation = 0.0;

    if (fabs(relative_rotation) > 0.0 && ![self fingerTweakHolds]) {
      ios_view_roll(float(relative_rotation));
    }
  }
  else if (sender.state == UIGestureRecognizerStateEnded ||
           sender.state == UIGestureRecognizerStateCancelled ||
           sender.state == UIGestureRecognizerStateFailed)
  {
    sender.rotation = 0.0;
  }
}

#if !defined(APPLE_TARGET_VISIONOS)
- (void)togglePencilMenuForInteraction:(UIPencilInteraction *)interaction
                             hoverPose:(UIPencilHoverPose *)pose
{
  NSValue *location = nil;
  if (pose) {
    CGPoint point = [interaction.view convertPoint:pose.location toView:self];
    if (!pencil_context_menu.active && ![self isBlenderPencilInputView:[self hitTest:point
                                                                           withEvent:nil]])
    {
      return;
    }
    location = [NSValue valueWithCGPoint:[self convertPoint:point toView:pencil_context_menu]];
  }
  else if (current_pencil_touch) {
    location = [NSValue
        valueWithCGPoint:[current_pencil_touch preciseLocationInView:pencil_context_menu]];
  }
  ios_navigation_hover(false);
  [self stopOrbitMomentum];
  [self cancelPencilStroke];
  [pencil_context_menu toggleWithPencilLocation:location];
}

- (void)pencilInteraction:(UIPencilInteraction *)interaction
            didReceiveTap:(UIPencilInteractionTap *)tap
{
  const UIPencilPreferredAction action = UIPencilInteraction.preferredTapAction;
  if (action != UIPencilPreferredActionIgnore &&
      action != UIPencilPreferredActionRunSystemShortcut)
  {
    [self togglePencilMenuForInteraction:interaction hoverPose:tap.hoverPose];
  }
}

- (void)pencilInteraction:(UIPencilInteraction *)interaction
        didReceiveSqueeze:(UIPencilInteractionSqueeze *)squeeze
{
  const UIPencilPreferredAction action = UIPencilInteraction.preferredSqueezeAction;
  ios_squeeze_log([NSString stringWithFormat:@"Squeeze reached Blender: phase %ld, preferred action %ld",
                                             long(squeeze.phase),
                                             long(action)]
                      .UTF8String);
  if (squeeze.phase != UIPencilInteractionPhaseEnded || action == UIPencilPreferredActionIgnore ||
      action == UIPencilPreferredActionRunSystemShortcut)
  {
    return;
  }
  /* Unless Settings has the radial menu for squeezing, Blender's tool palette opens by the
   * Pencil, see `SqueezePalette.swift`. Not mid-stroke, where a squeeze is most likely a grip. */
  NSString *squeeze_shows = [NSUserDefaults.standardUserDefaults stringForKey:@"BlenderPencilSqueeze"];
  if (![squeeze_shows isEqualToString:@"menu"]) {
    if (current_pencil_touch) {
      return;
    }
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (UIPencilHoverPose *pose = squeeze.hoverPose) {
      const CGPoint point = [interaction.view convertPoint:pose.location toView:nil];
      info[@"x"] = @(point.x);
      info[@"y"] = @(point.y);
      if (@available(iOS 17.5, *)) {
        info[@"roll"] = @(pose.rollAngle);
      }
      /* Which way the Pencil leans over the screen, for the palette to open away from the hand. */
      info[@"azimuth"] = @(pose.azimuthAngle);
      info[@"altitude"] = @(pose.altitudeAngle);
    }
    [NSNotificationCenter.defaultCenter postNotificationName:@"BlenderPencilSqueeze"
                                                      object:self
                                                    userInfo:info];
    return;
  }
  [self togglePencilMenuForInteraction:interaction hoverPose:squeeze.hoverPose];
}
#endif

- (void)beginFrame
{
}

- (void)endFrame
{
}

- (void)initToolbar
{
  /* This gets the current view size */
  UIView *ui_view = window->getView();
  CGSize frame_size = [ui_view sizeThatFits:CGSizeMake(0.0f, 0.0f)];
  /* Create a toolbar the width of the screen. */
  toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, frame_size.width, 44)];
  toolbar.barStyle = UIBarStyleDefault;
  toolbar.translucent = true;
  /* IOS_FIXME - Despite following Apple guidelines this toolbar still
   * appears to apparently violate the view constraints. It displays fine
   * but generates a lot of warning output to the console. */
  toolbar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  toolbar.translatesAutoresizingMaskIntoConstraints = NO;
  [toolbar sizeToFit];

  toolbar_tip_item = [[UIBarButtonItem alloc] initWithTitle:@""
                                                      style:UIBarButtonItemStylePlain
                                                     target:nil
                                                     action:nil];

  toolbar_live_text_item = [[UIBarButtonItem alloc] initWithTitle:@""
                                                            style:UIBarButtonItemStylePlain
                                                           target:nil
                                                           action:nil];

  toolbar_done_editing_item = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                           target:nil
                           action:@selector(handleDoneButton)];

  toolbar_cancel_editing_item = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                           target:nil
                           action:@selector(handleCancelButton)];

  /* Prevents editing of tip and live text fields. */
  toolbar_tip_item.enabled = NO;
  toolbar_live_text_item.enabled = NO;
  toolbar_live_text_item.tintColor = UIColor.blackColor;

  /* Set the live text to a fixed width. */
  /* IOS_FIXME - should this be set dynamically? Need to move out of init if so. */
  toolbar_live_text_item.width = 150.0f;

  toolbar.items = @[
    toolbar_tip_item,
    toolbar_live_text_item,
    toolbar_done_editing_item,
    toolbar_cancel_editing_item
  ];
}

- (void)generateKeyboardReturnEvent
{
  /*
   Only push the event back if the keyboard is active otherwise we may generate new
   spurious events.
   */
  if (onscreen_keyboard_active) {
    /*
     This event should cause ui_textedit_end() to be called which will
     hide the keyboard.
     */
    system->pushEvent(std::make_unique<GHOST_EventKey>(
        system->getMilliSeconds(), GHOST_kEventKeyDown, window, GHOST_kKeyEnter, false, nullptr));
  }
  else {
    IOS_INPUT_LOG(@"Ignoring handleKeyboardReturn %@", text_field.text);
  }
}

- (void)handleKeyboardReturn:(UITextField *)text_field
{
  @synchronized(self) {
    IOS_INPUT_LOG(@"handleKeyboardReturn %@", text_field.text);
    [self generateKeyboardReturnEvent];
  }
}

- (void)handleKeyboardEditChange:(UITextField *)text_field
{
  @synchronized(self) {

    /* Update the text in the tool bar as the edits arrive. */
    if (toolbar_live_text_item) {
      toolbar_live_text_item.title = text_field.text;
      /* Force toolbar to update */
      [toolbar setNeedsLayout];
      [toolbar layoutIfNeeded];
    }
    IOS_INPUT_LOG(@"Keyboard Edit change detected %@", text_field.text);

    /* IOS_FIXME - Enabling this will propogate text changes back into the Blender text field
     as they happen. Since pushing back individual key presses appears to be difficult this
     might be the best we can do. However this currently causes a segmentation fault if you delete
     text as the Blender-side string ends up being NULL in some cases. */
    bool push_edits_back_to_blender = false;

    if (push_edits_back_to_blender) {
      system->pushEvent(std::make_unique<GHOST_EventKey>(system->getMilliSeconds(),
                                                         GHOST_kEventKeyDown,
                                                         window,
                                                         GHOST_kKeyTextEdit,
                                                         false,
                                                         nullptr));
    }
  }
}

- (void)handleKeyboardEditBegin:(UITextField *)text_field
{
  @synchronized(self) {
    IOS_INPUT_LOG(@"Keyboard Edit begin detected %@", text_field.text);
  }
}

- (void)handleKeyboardEditEnd:(UITextField *)text_field
{
  @synchronized(self) {
    /*
     This can get called when the keyboard is minimised
     so send a return keypress to emulate effective end
     of editing. Otherwise Blender's focus will remain
     on the text field.
     */
    IOS_INPUT_LOG(@"Keyboard Edit end detected %@", text_field.text);
    [self generateKeyboardReturnEvent];
  }
}

- (void)handleDoneButton
{
  IOS_INPUT_LOG(@"Keyboard Done button press detected %@", text_field.text);
  [self generateKeyboardReturnEvent];
}

- (void)handleCancelButton
{
  IOS_INPUT_LOG(@"Keyboard Cancel button press detected %@", text_field.text);
  /* Restore the original text and return */
  text_field.text = original_text;
  [self generateKeyboardReturnEvent];
}

/*
 * Add a text field so we can handle input from a popup keyboard and
 * attach it to our root window.
 */
- (void)initUITextField
{
  /* Initialise it if we have not already done so. */
  if (!text_field) {
    text_field = [[UITextField alloc] init];

    text_field.contentScaleFactor = window->getWindowScaleFactor();

#if !defined(APPLE_TARGET_VISIONOS)
    if (toolbar_enabled) {
      [self initToolbar];
      text_field.inputAccessoryView = toolbar;
    }
#endif

    [window->rootWindow addSubview:text_field];

    /* Add a handler for when 'return' is pressed on keyboard. */
    [text_field addTarget:self
                   action:@selector(handleKeyboardReturn:)
         forControlEvents:UIControlEventEditingDidEndOnExit];

    /* Add a handler for when the text field changes. */
    [text_field addTarget:self
                   action:@selector(handleKeyboardEditChange:)
         forControlEvents:UIControlEventEditingChanged];

    /* Add a handler for when user edits a text field. */
    [text_field addTarget:self
                   action:@selector(handleKeyboardEditBegin:)
         forControlEvents:UIControlEventEditingDidBegin];

    /* Add a handler for when user finishes editing a text field. */
    [text_field addTarget:self
                   action:@selector(handleKeyboardEditEnd:)
         forControlEvents:UIControlEventEditingDidEnd];
  }
}

- (void)convertWindowCoordToDisplayCoordWithWindow:(int)windowX
                                           windowY:(int)windowY
                                          displayX:(double *)displayX
                                          displayY:(double *)displayY
                                             flipY:(BOOL)flipY
{
  float pixelScale = window->getWindowScaleFactor();
  CGSize logicalWindowSize = window->getLogicalWindowSize();

  *displayX = (double)windowX / pixelScale;
  *displayY = (double)windowY / pixelScale;

  if (flipY) {
    *displayY = logicalWindowSize.height - *displayY;
  }
}

- (UITextField *)getUITextField
{
  return text_field;
}

- (void)setupKeyboard:(const GHOST_KeyboardProperties &)keyboard_properties
{
  /* Initialise it if we have not already done so */
  if (!text_field) {
    [self initUITextField];
  }

  /* Save this set of keyboard properties */
  current_keyboard_properties = keyboard_properties;

  /* Convert the text box coords to display coords */
  CGRect displayRect;
  [self convertWindowCoordToDisplayCoordWithWindow:keyboard_properties.text_box_origin[0]
                                           windowY:keyboard_properties.text_box_origin[1]
                                          displayX:&displayRect.origin.x
                                          displayY:&displayRect.origin.y
                                             flipY:true];

  [self convertWindowCoordToDisplayCoordWithWindow:keyboard_properties.text_box_size[0]
                                           windowY:keyboard_properties.text_box_size[1]
                                          displayX:&displayRect.size.width
                                          displayY:&displayRect.size.height
                                             flipY:false];

  /* Where to display the text on-screen. */
  text_field.frame = displayRect;

  /* Initialise text with existing string. */
  text_field.text = keyboard_properties.text_string ?
                        [NSString stringWithUTF8String:keyboard_properties.text_string] :
                        @"";
  /* Take a copy of the string so we can restore it if neccessary */
  original_text = keyboard_properties.text_string ?
                      [NSString stringWithUTF8String:keyboard_properties.text_string] :
                      @"";

  /* Set keyboard type and text alignment.
   * NOTE - the keyboard type is only honoured if using an Apple
   * pencil or if the keyboard is floating.
   * Otherwise it will just be the default full screen type. */
  switch (keyboard_properties.keyboard_type) {
    case GHOST_KeyboardProperties::ascii_keyboard_type: {
      text_field.keyboardType = UIKeyboardTypeASCIICapable;
      text_field.textAlignment = NSTextAlignmentLeft;
      break;
    }
    case GHOST_KeyboardProperties::decimal_numpad_keyboard_type: {
      text_field.keyboardType = UIKeyboardTypeDecimalPad;
      text_field.textAlignment = NSTextAlignmentCenter;
      break;
    }
    case GHOST_KeyboardProperties::numpad_keyboard_type: {
      text_field.keyboardType = UIKeyboardTypeNumberPad;
      text_field.textAlignment = NSTextAlignmentCenter;
      break;
    }
    default: {
      /* What's the sensible baviour here? Default? Assert? */
      text_field.keyboardType = UIKeyboardTypeDefault;
      text_field.textAlignment = NSTextAlignmentLeft;
    }
  }
  /* Reset keyboard type to default if not using Apple Pencil
   * or it's not floating. (Need to add floating detection.) */
  if (!last_tap_with_pencil) {
    // text_field.keyboardType = UIKeyboardTypeDefault;
  }

  /* Set light/dark mode or adopt system default. */
  text_field.keyboardAppearance = UIKeyboardAppearanceDefault;

  /* This seems sensible given Blender's typical behaviour. */
  text_field.autocorrectionType = UITextAutocorrectionTypeNo;
  text_field.spellCheckingType = UITextSpellCheckingTypeNo;

  /* Set font size. */
  float fontSize = keyboard_properties.font_size / window->getWindowScaleFactor();
  text_field.font = [UIFont systemFontOfSize:fontSize];

  /* Set font color. */
  text_field.textColor = [UIColor colorWithRed:keyboard_properties.font_color[0]
                                         green:keyboard_properties.font_color[1]
                                          blue:keyboard_properties.font_color[2]
                                         alpha:keyboard_properties.font_color[3]];

  /* Initial highlighting and text-cursor position. */
  switch (keyboard_properties.inital_text_state) {
    case GHOST_KeyboardProperties::select_all_text: {
      [text_field selectAll:nil];
      break;
    }
    case GHOST_KeyboardProperties::select_text_range: {
      UITextPosition *startPosition = [text_field
          positionFromPosition:text_field.beginningOfDocument
                        offset:keyboard_properties.text_select_range[0]];
      UITextPosition *endPosition = [text_field
          positionFromPosition:text_field.beginningOfDocument
                        offset:keyboard_properties.text_select_range[1]];
      text_field.selectedTextRange = [text_field textRangeFromPosition:startPosition
                                                            toPosition:endPosition];
      break;
    }
    case GHOST_KeyboardProperties::move_cursor_to_start: {
      UITextPosition *beginning = text_field.beginningOfDocument;
      text_field.selectedTextRange = [text_field textRangeFromPosition:beginning
                                                            toPosition:beginning];
      break;
    }
    case GHOST_KeyboardProperties::move_cursor_to_end: {
      UITextPosition *end = text_field.endOfDocument;
      text_field.selectedTextRange = [text_field textRangeFromPosition:end toPosition:end];
      break;
    }
    default: {
      GHOST_ASSERT(FALSE, "GHOST_SystemIOS::setupTextField unsupported text select option");
    }
  }

  /* Setup the tool bar if it's enabled. */
  if (toolbar_enabled) {
    toolbar_live_text_item.title = text_field.text;
    toolbar_tip_item.title = keyboard_properties.tip_text ?
                                 [NSString stringWithCString:keyboard_properties.tip_text
                                                    encoding:NSUTF8StringEncoding] :
                                 @"";
  }
}

- (void)externalKeyboardChange:(NSNotification *)notification
{
  external_keyboard_connected = [GCKeyboard coalescedKeyboard] != nil;
  IOS_INPUT_LOG(@"External Keyboard %s",
                external_keyboard_connected ? "Connected" : "Disconnected");
}

/* IOS_FIXME - Not currently used, could be removed. */
- (void)keyboardWillChange:(NSNotification *)notification
{

  CGRect keyboardRect = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
  /* Sometimes we see a zero value for the end-frame value, possibly because... timing? */
  if (keyboardRect.size.width == 0 || keyboardRect.size.height == 0) {
    keyboardRect = [notification.userInfo[UIKeyboardFrameBeginUserInfoKey] CGRectValue];
  }
}

- (const GHOST_TabletData)getTabletData
{
  return tablet_data;
}

- (GHOST_TSuccess)popupOnscreenKeyboard:(const GHOST_KeyboardProperties &)keyboard_properties
{
  @synchronized(self) {
    IOS_INPUT_LOG(@"Keyboard popup request received %@", text_field.text);
    /* With a hardware keyboard Blender edits the text itself from key events, as on the
     * desktop; #getLastKeyboardString then has nothing to replace it with. */
    hardware_text_edit = [GCKeyboard coalescedKeyboard] != nil;
    if (hardware_text_edit) {
      return GHOST_kSuccess;
    }
    [self setupKeyboard:keyboard_properties];

    if (!onscreen_keyboard_active) {
      text_field.userInteractionEnabled = YES;
      if (![text_field becomeFirstResponder]) {
        GHOST_ASSERT(FALSE, "GHOST_SystemIOS::popupOnScreenKeyboard Failed to display keyboard");
      }
      onscreen_keyboard_active = true;
    }
  }
  return GHOST_kSuccess;
}

- (GHOST_TSuccess)hideOnscreenKeyboard
{
  /* Lock access around keyboard handling events. */
  @synchronized(self) {
    IOS_INPUT_LOG(@"Keyboard hide request received %@", text_field.text);

    if (onscreen_keyboard_active) {
      /*
       This must come first so that any of the keyboard event handlers that get
       triggered in response to shutting down the keyboard don't do anything
       (like generating events back to Blender)
       */
      onscreen_keyboard_active = false;

      /* Shut down the keyboard. */
      [text_field resignFirstResponder];
      /*
       IOS_FIXME - Note: This may cause the console to display the warning message:
       "-[UIApplication _touchesEvent] will no longer work as expected. Please stop using it."
       But since this is being generated by Apple OS code there's nothing obvious to fix it right
       now.
       */

      IOS_INPUT_LOG(@"Resigned keyboard responder");
      /*
       This is required to disable any subsequent interactions with the text field that could
       potentially bypass Blender's input handling (since the UITextField is now live
       on the view)
       */
      text_field.userInteractionEnabled = NO;

      /* Save the input to a c-string */
      [self storeKeyboardString:text_field.text];

      /* Delete the text field copy of the string */
      text_field.text = nil;
    }
  }
  IOS_INPUT_LOG(@"Text field value was %s", text_field_string);
  return GHOST_kSuccess;
}

/** Keep a copy: a pointer into the field's text would dangle once the field is cleared, and
 * Blender reads the text later, on its own thread. Renames then committed whatever had reused that
 * memory. */
- (void)storeKeyboardString:(NSString *)text
{
  free(text_field_string);
  text_field_string = text ? strdup(text.UTF8String) : nullptr;
}

- (const char *)getLastKeyboardString
{
  /* Lock access around keyboard handling events */
  @synchronized(self) {
    if (hardware_text_edit) {
      return nullptr;
    }

    /* Update text string if one exists */
    if (text_field.text && ![text_field.text isEqualToString:@""]) {
      /* Save the input to a c-string */
      [self storeKeyboardString:text_field.text];
    }
  }
  return text_field_string;
}

@end

GHOST_WindowIOS::GHOST_WindowIOS(GHOST_SystemIOS *system_ios,
                                 const char *title,
                                 int32_t left,
                                 int32_t bottom,
                                 uint32_t width,
                                 uint32_t height,
                                 GHOST_TWindowState state,
                                 GHOST_TDrawingContextType type,
                                 const GHOST_ContextParams &context_params,
                                 bool is_dialog,
                                 GHOST_WindowIOS *parent_window)
    : GHOST_Window(width, height, state, context_params, false), metal_view_(nil)
{
  full_screen_ = true;
  system_ios_ = system_ios;
  /* Parent window will be the window that focus is returned to upon close. */
  parent_window_ = parent_window;
  window_title_ = nullptr;
  is_dialog_ = is_dialog;
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();

  GHOST_ios_main_sync(^{
    UIWindowScene *window_scene = GHOST_getIOSWindowScene();
    CGRect window_frame = full_screen_ && window_scene ?
                              window_scene.effectiveGeometry.coordinateSpace.bounds :
                              CGRectMake(left, bottom, width, height);

    /* Create MTKView. */
    metal_view_ = [[MTKView alloc] initWithFrame:window_frame];
    metal_view_.device = device;
    metal_view_.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                   UIViewAutoresizingFlexibleHeight;
    GHOST_ASSERT(metal_view_, "metalview not valid");
    metal_view_.multipleTouchEnabled = YES;
    metal_view_.enableSetNeedsDisplay = NO;
    metal_view_.clearColor = MTLClearColorMake(0, 0, 0, 1.0);
    /* MTKView only manages native layout. It must never acquire a drawable on UIKit. */
    metal_view_.paused = YES;
    metal_view_.colorPixelFormat = MTLPixelFormatRGBA16Float;
    metal_view_.autoResizeDrawable = YES;
    metal_view_.contentMode = UIViewContentModeScaleToFill;
    /* Set the refresh rate to the screen's maximum. There may be some value in capping
     * this value to preserve battery life (60fps seems to work well). */
    metal_view_.preferredFramesPerSecond = GHOSTIOSMaximumFramesPerSecond();

    /* Create view controller. */
    UIApplication *app = [UIApplication sharedApplication];
    GHOST_ASSERT(app, "App not valid");
    id<UIApplicationDelegate> app_delegate = [app delegate];
    GHOST_ASSERT(app_delegate, "App not valid");

    GHOSTUIWindow *ghost_rootWindow = nullptr;

    if (full_screen_) {
      /* Init window at native res. */
      ghost_rootWindow = window_scene ? [[GHOSTUIWindow alloc] initWithWindowScene:window_scene] :
                                        [[GHOSTUIWindow alloc] initWithFrame:window_frame];
      /* Ensure fullscreen. */
      ghost_rootWindow.frame = window_frame;
    }
    else {
      /* Init window at specified size. */
      ghost_rootWindow = [[GHOSTUIWindow alloc] initWithWindowScene:window_scene];
      ghost_rootWindow.frame = CGRectMake(left, bottom, width, height);
      [ghost_rootWindow setClipsToBounds:YES];
    }

    rootWindow = (UIWindow *)ghost_rootWindow;
    GHOST_ios_register_window(rootWindow);
    if (document_window == nil) {
      document_window = rootWindow;
    }

    [ghost_rootWindow setSystemAndWindowIOS:system_ios_ windowIOS:this];
    /* Above the launcher's window, which it covers, but below the system's own windows. */
    rootWindow.windowLevel = UIWindowLevelNormal + 1;

    GHOST_ASSERT(rootWindow, "UIWindow not valid");
    /* The native interface's view controller around the Metal view, see
     * #GHOST_IOSNativeInterface::window_controller. */
    const GHOST_IOSNativeInterface *native = GHOST_ios_native_interface();
    GHOST_ASSERT(native && native->window_controller, "No native interface");
    void *root = nullptr;
    uiview_controller_ = (UIViewController *)native->window_controller(metal_view_, this, &root);
    GHOST_ASSERT(uiview_controller_, "UIViewController not valid");
    /* Set presentation style depending on whether main window, dialog or temporary window. */
    uiview_controller_.modalPresentationStyle = full_screen_ ? UIModalPresentationFullScreen :
                                                               UIModalPresentationPageSheet;
    rootWindow.rootViewController = (UIViewController *)root;
    [uiview_controller_ loadViewIfNeeded];

    /* The view that takes Blender's input: the Metal view, wherever the native interface places
     * it in its controller's views. */
    GHOST_ASSERT(width > 0 && height > 0, "invalid wh");
    uiview_ = metal_view_;
    GHOST_ASSERT(uiview_, "uiview not valid");

    /* Enable HDR/EDR Support. */
    CAMetalLayer *metalLayer = (CAMetalLayer *)metal_view_.layer;
    metalLayer.wantsExtendedDynamicRangeContent = YES;
    metalLayer.pixelFormat = MTLPixelFormatRGBA16Float;
    CGColorSpaceRef colorspace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
    metalLayer.colorspace = colorspace;
    CGColorSpaceRelease(colorspace);
    metalLayer.allowsNextDrawableTimeout = YES;
    surface = std::make_shared<GHOST_IOSSurface>(metalLayer);
    publishGeometry(metal_view_.drawableSize);
    metal_renderer_ = [[GHOST_IOSMetalRenderer alloc] initWithWindow:this];
    metal_view_.delegate = metal_renderer_;

    [ghost_rootWindow registerGestureRecognizers];
  });
  [device release];

  setDrawingContextType(type);
  updateDrawingContext();
  activateDrawingContext();

  setTitle(title);

  deferred_swap_buffers_count = 0;

  /* Deactive the parent (if it exists) and activate this one. */
  if (parent_window_) {
    parent_window_->requestToDeactivateWindow();
  }

  /* Engine-owned activation, with native visibility applied on UIKit. */
  if (!system_ios_->current_active_window_) {
    request_to_make_active_ = true;
    makeKeyWindow();
  }
  /* Activate this window at the end of the next draw loop. */
  else {
    requestToActivateWindow();
  }
}

GHOST_WindowIOS::~GHOST_WindowIOS()
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  detachNativeInput();
  if (surface) {
    surface->close();
  }

  releaseNativeHandles();

  /* Restore application control and display to parent window. */
  if (parent_window_) {
    parent_window_->requestToActivateWindow();
    parent_window_ = nil;
  }
  /* We have no choice but to resign, however this seems like it might cause issues. */
  if (system_ios_->current_active_window_ == this) {
    IOS_WINDOW_LOG(@"~GHOST_WindowIOS(): Warning, deactivating the active window %p?", this);
    requestToDeactivateWindow();
    resignKeyWindow();
  }

  GHOST_ios_main_sync(^{
    if (metal_view_) {
      metal_view_.delegate = nil;
      [metal_view_ release];
      metal_view_ = nil;
    }
    if (metal_renderer_) {
      [metal_renderer_ detach];
      [metal_renderer_ release];
      metal_renderer_ = nil;
    }
    if (uiview_) {
      uiview_ = nil;
    }

    /* Release window. */
    if (rootWindow) {
      if (document_window == rootWindow) {
        document_window = nil;
      }
      GHOST_ios_unregister_window(rootWindow);
      rootWindow.hidden = YES;
      rootWindow.rootViewController = nil;
      [rootWindow release];
      rootWindow = nil;
    }
    if (uiview_controller_) {
      [uiview_controller_ release];
      uiview_controller_ = nil;
    }
  });

  if (window_title_) {
    free(window_title_);
    window_title_ = nullptr;
  }

  [pool drain];
}

void GHOST_WindowIOS::detachNativeInput()
{
  GHOST_ios_main_sync(^{
    if (input_alive->exchange(false)) {
      [(GHOSTUIWindow *)rootWindow detachBlender];
      [(UIViewController<GHOST_IOSWindowController> *)uiview_controller_ detachBlender];
      [metal_renderer_ detach];
      metal_view_.delegate = nil;
    }
  });
}

void GHOST_WindowIOS::publishGeometry(CGSize size)
{
  GHOST_ASSERT(NSThread.isMainThread, "Geometry is published by UIKit");
  scale_.store(MAX(1.0, metal_view_.contentScaleFactor));
  const uint64_t packed = (uint64_t(MAX(1.0, size.width)) << 32) | uint32_t(MAX(1.0, size.height));
  if (surface) {
    surface->resize(size);
  }
  if (drawable_size_.exchange(packed) != packed) {
    system_ios_->pushEvent(std::make_unique<GHOST_Event>(
        system_ios_->getMilliSeconds(), GHOST_kEventWindowSize, this));
  }
}

#pragma mark accessors

bool GHOST_WindowIOS::getValid() const
{
  MTKView *view = metal_view_;
  return GHOST_Window::getValid() && uiview_ != NULL && view != NULL;
}

void *GHOST_WindowIOS::getOSWindow() const
{
  return (void *)uiview_;
}

GHOST_TSuccess GHOST_WindowIOS::swapBufferRelease()
{
  deferred_swap_buffers_count = 1;
  return GHOST_kSuccess;
}

void GHOST_WindowIOS::flushDeferredSwapBuffers()
{
  if (deferred_swap_buffers_count) {

    /* These two messages should be made asserts when we've fixed all the issues. */
    if (!getValid()) {
      IOS_WINDOW_LOG(@"Ignoring swap (invalid) con(%p) (win=%p)", getContext(), this);
      return;
    }

    if (!is_active_window_) {
      IOS_WINDOW_LOG(@"Ignoring swap (not active window) con(%p) (win=%p)", getContext(), this);
      return;
    }

    IOS_WINDOW_LOG(@"Swapping (ui_View)%p (mtkView)%p con(%p) (win=%p) (sc=%d)",
                   uiview_,
                   metal_view_,
                   getContext(),
                   this,
                   deferred_swap_buffers_count);

    GHOST_ContextIOS *context = reinterpret_cast<GHOST_ContextIOS *>(getContext());
    if (context->swapBufferRelease() == GHOST_kSuccess) {
      deferred_swap_buffers_count = 0;
    }
  }
}

void GHOST_WindowIOS::beginFrame() {}

void GHOST_WindowIOS::endFrame() {}

void GHOST_WindowIOS::setTitle(const char *title)
{
  if (window_title_) {
    free(window_title_);
    window_title_ = nullptr;
  }
  window_title_ = (char *)malloc(strlen(title) + 1);
  if (!window_title_) {
    GHOST_ASSERT(getValid(), "GHOST_WindowIOS::setTitle(): Failed to alloc mem for window title");
  }
  strcpy(window_title_, title);
  NSString *window_title = [NSString stringWithCString:title encoding:NSUTF8StringEncoding];
#if defined(APPLE_TARGET_VISIONOS)
  /* The window's title bar names the document, as other visionOS apps do, without its path. */
  NSRange path = [window_title rangeOfString:@" ["];
  if (path.location != NSNotFound) {
    window_title = [window_title substringToIndex:path.location];
  }
  if ([window_title hasPrefix:@"* "]) {
    window_title = [window_title substringFromIndex:2];
  }
#endif
  UIViewController *controller = uiview_controller_;
  dispatch_async(dispatch_get_main_queue(), ^{
    controller.title = window_title;
  });
}

std::string GHOST_WindowIOS::getTitle() const
{
  return window_title_;
}

void GHOST_WindowIOS::needsDisplayUpdate()
{
  GHOST_ios_engine_wake();
}

void GHOST_WindowIOS::getWindowBounds(GHOST_Rect &bounds) const
{
  GHOST_ASSERT(getValid(), "GHOST_WindowIOS::getWindowBounds(): window invalid");

  getClientBounds(bounds);
}

void GHOST_WindowIOS::getClientBounds(GHOST_Rect &bounds) const
{
  GHOST_ASSERT(getValid(), "GHOST_WindowIOS::getWindowBounds(): window invalid");

  const uint64_t size = drawable_size_.load();

  bounds.l_ = 0;
  bounds.t_ = 0;
  bounds.r_ = size >> 32;
  bounds.b_ = uint32_t(size);
}

GHOST_TSuccess GHOST_WindowIOS::setClientWidth(uint32_t /*width*/)
{
  /* Ignore on iOS fow now. */
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setClientHeight(uint32_t /*height*/)
{
  /* Ignore on iOS fow now. */
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setClientSize(uint32_t /*width*/, uint32_t /*height*/)
{
  /* Ignore on iOS fow now. */
  return GHOST_kSuccess;
}

GHOST_TWindowState GHOST_WindowIOS::getState() const
{
  /* Out of sight in the background: iOS allows no drawing there. */
  return GHOST_ios_app_in_background() ? GHOST_kWindowStateMinimized : GHOST_kWindowStateNormal;
}

void GHOST_WindowIOS::screenToClient(int32_t inX, int32_t inY, int32_t &outX, int32_t &outY) const
{
  /* Pass through for fullscreen windows.
   * TODO: Support coordinate mapping for sized windows. */
  outX = inX;
  outY = inY;
}

void GHOST_WindowIOS::clientToScreen(int32_t inX, int32_t inY, int32_t &outX, int32_t &outY) const
{
  /* Pass through for fullscreen windows.
   * TODO: Support coordinate mapping for sized windows. */
  outX = inX;
  outY = inY;
}

void GHOST_WindowIOS::screenToClientIntern(int32_t inX,
                                           int32_t inY,
                                           int32_t &outX,
                                           int32_t &outY) const
{
  /* Pass through for fullscreen windows.
   * TODO: Support coordinate mapping for sized windows. */
  outX = inX;
  outY = inY;
}

void GHOST_WindowIOS::clientToScreenIntern(int32_t inX,
                                           int32_t inY,
                                           int32_t &outX,
                                           int32_t &outY) const
{
  /* Pass through for fullscreen windows.
   * TODO: Support coordinate mapping for sized windows. */
  outX = inX;
  outY = inY;
}

/* called for event, when window leaves monitor to another */
void GHOST_WindowIOS::setNativePixelSize(void) {}

/**
 * \note Fullscreen switch is not actual fullscreen with display capture.
 * As this capture removes all OS X window manager features.
 *
 * Instead, the menu bar and the dock are hidden, and the window is made border-less and
 * enlarged. Thus, process switch, exposé, spaces, ... still work in fullscreen mode
 */
GHOST_TSuccess GHOST_WindowIOS::setState(GHOST_TWindowState /*state*/)
{
  // Ignore on iOS?
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setModifiedState(bool isUnsavedChanges)
{
  /* Unsaved changes are what makes the document save itself. */
  dispatch_async(dispatch_get_main_queue(), ^{
    if (const GHOST_IOSNativeInterface *native = GHOST_ios_native_interface()) {
      native->document_modified(isUnsavedChanges);
    }
  });
  return GHOST_Window::setModifiedState(isUnsavedChanges);
}

GHOST_TSuccess GHOST_WindowIOS::setOrder(GHOST_TWindowOrder /*order*/)
{
  /* TODO: Support or deprecate for iOS */
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  GHOST_ASSERT(getValid(), "GHOST_WindowIOS::setOrder(): window invalid");

  [pool drain];
  return GHOST_kSuccess;
}

#pragma mark Drawing context

GHOST_Context *GHOST_WindowIOS::newDrawingContext(GHOST_TDrawingContextType type)
{

  if (type == GHOST_kDrawingContextTypeMetal) {

    GHOST_Context *context = new GHOST_ContextIOS(want_context_params_, surface);

    if (context->initializeDrawingContext())
      return context;
    else
      delete context;
  }

  return NULL;
}

#pragma mark invalidate

GHOST_TSuccess GHOST_WindowIOS::invalidate()
{
  GHOST_ASSERT(getValid(), "GHOST_WindowIOS::invalidate(): window invalid");
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  [pool drain];
  return GHOST_kSuccess;
}

#pragma mark Progress bar

GHOST_TSuccess GHOST_WindowIOS::setProgressBar(float /*progress*/)
{
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::endProgressBar()
{
  return GHOST_kSuccess;
}

#pragma mark Cursor handling

void GHOST_WindowIOS::loadCursor(bool /*visible*/, GHOST_TStandardCursor /*shape*/) const {}

bool GHOST_WindowIOS::isDialog() const
{
  return is_dialog_;
}

/** The pointer takes Blender's cursor over the view, see #GHOSTUIWindow. */
void GHOST_WindowIOS::refreshPointer()
{
#if !defined(APPLE_TARGET_VISIONOS)
  GHOSTUIWindow *ghost_window = (GHOSTUIWindow *)rootWindow;
  std::shared_ptr<std::atomic<bool>> alive = input_alive;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (alive->load()) {
      [ghost_window refreshPointer];
    }
  });
#endif
}

GHOST_TSuccess GHOST_WindowIOS::setWindowCursorVisibility(bool visible)
{
  if (pointer_cursor_visible.exchange(visible) != visible) {
    refreshPointer();
  }
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setWindowCursorGrab(GHOST_TGrabCursorMode /*mode*/)
{
  /* The pointer can't be moved by apps: Blender draws its own cursor while it grabs. */
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setWindowCursorShape(GHOST_TStandardCursor shape)
{
  if (pointer_cursor.exchange(shape) != shape) {
    refreshPointer();
  }
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::hasCursorShape(GHOST_TStandardCursor /*shape*/)
{
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setWindowCustomCursorShape(const uint8_t * /*bitmap*/,
                                                           const uint8_t * /*mask*/,
                                                           const int /*size*/[2],
                                                           const int /*hot_spot*/[2],
                                                           bool /*canInvertColor*/)
{
  /* The pointer can't show a bitmap: it shows a crosshair, as for tools. */
  return setWindowCursorShape(GHOST_kStandardCursorCustom);
}

uint16_t GHOST_WindowIOS::getDPIHint()
{
  return 288;
}

GHOST_TSuccess GHOST_WindowIOS::popupOnscreenKeyboard(
    const GHOST_KeyboardProperties &keyboard_properties)
{
  GHOSTUIWindow *ghost_rootWindow = (GHOSTUIWindow *)rootWindow;
  __block GHOST_TSuccess result;
  GHOST_ios_main_sync(^{
    result = [ghost_rootWindow popupOnscreenKeyboard:keyboard_properties];
  });
  return result;
}

GHOST_TSuccess GHOST_WindowIOS::hideOnscreenKeyboard()
{
  GHOSTUIWindow *ghost_rootWindow = (GHOSTUIWindow *)rootWindow;
  __block GHOST_TSuccess result;
  GHOST_ios_main_sync(^{
    result = [ghost_rootWindow hideOnscreenKeyboard];
  });
  return result;
}

const char *GHOST_WindowIOS::getLastKeyboardString()
{
  GHOSTUIWindow *ghost_rootWindow = (GHOSTUIWindow *)rootWindow;
  GHOST_ios_main_sync(^{
    const char *text = [ghost_rootWindow getLastKeyboardString];
    keyboard_string_ = text ? text : "";
  });
  return keyboard_string_.c_str();
}

const GHOST_TabletData GHOST_WindowIOS::getTabletData()
{
  GHOSTUIWindow *ghost_rootWindow = (GHOSTUIWindow *)rootWindow;
  __block GHOST_TabletData result;
  GHOST_ios_main_sync(^{
    result = [ghost_rootWindow getTabletData];
  });
  return result;
}

/* This is the size of the window pre-scaled */
CGSize GHOST_WindowIOS::getLogicalWindowSize()
{
  CGSize size = getNativeWindowSize();
  float scale = scale_.load();
  return CGSizeMake(size.width / scale, size.height / scale);
}

/* This is the size of the window post-scaled */
CGSize GHOST_WindowIOS::getNativeWindowSize()
{
  const uint64_t size = drawable_size_.load();
  return CGSizeMake(size >> 32, uint32_t(size));
}

float GHOST_WindowIOS::getWindowScaleFactor()
{
  return scale_.load();
}

/* Indicate that we want this window to be the next active one. */
void GHOST_WindowIOS::requestToActivateWindow()
{
  /* Check we're not already active. */
  if (system_ios_->current_active_window_ != this) {
    /* Replace any outstanding requests. */
    if (system_ios_->next_active_window_) {
      system_ios_->next_active_window_->requestToDeactivateWindow();
    }
    request_to_make_active_ = true;
    system_ios_->next_active_window_ = this;
  }
}

void GHOST_WindowIOS::requestToDeactivateWindow()
{
  if (system_ios_->next_active_window_ == this) {
    IOS_WINDOW_LOG(@"requestToDeactivateWindow(): Has something gone wrong? %p", this);
    system_ios_->next_active_window_ = nullptr;
  }
  request_to_make_active_ = false;
}

bool GHOST_WindowIOS::makeKeyWindow()
{
  if (!getValid()) {
    IOS_WINDOW_LOG(@"Failed to activate (invalid) con(%p) (win=%p)", getContext(), this);
    return false;
  }

  GHOST_ContextIOS *context = reinterpret_cast<GHOST_ContextIOS *>(getContext());
  GHOST_ASSERT(rootWindow != nil, "GHOST_WindowIOS::makeKeyWindow() root window required");
  GHOST_ASSERT(context != nullptr, "GHOST_WindowIOS::makeKeyWindow() context required");
  GHOST_ASSERT(request_to_make_active_,
               "GHOST_WindowIOS::makeKeyWindow() must request activation first");

  /* Make window primary visible window. */
  GHOST_ios_main_sync(^{
    /* Over the launcher only while it has a document open. */
    if (GHOST_ios_document_window_visible()) {
      [rootWindow makeKeyAndVisible];
    }
    else {
      rootWindow.hidden = YES;
    }
    /* On screen in the foreground, focused or not, see #ghost_window_on_screen. */
    surface->setVisible(!rootWindow.hidden &&
                        rootWindow.windowScene.activationState != UISceneActivationStateBackground &&
                        rootWindow.windowScene.activationState != UISceneActivationStateUnattached);
  });

  IOS_WINDOW_LOG(@"Key Window: (ui_View)%p (mtkView)%p con(%p) (win=%p)",
                 uiview_,
                 metal_view_,
                 getContext(),
                 this);

  system_ios_->current_active_window_ = this;
  is_active_window_ = true;
  request_to_make_active_ = false;
  return true;
}

void GHOST_WindowIOS::resignKeyWindow()
{
  GHOST_ASSERT(system_ios_->current_active_window_ == this,
               "GHOST_WindowIOS::resignKeyWindow(): Can only resign current active window");
  GHOST_ASSERT(is_active_window_,
               "GHOST_WindowIOS::resignKeyWindow(): Can't resign non active window");
  GHOST_ASSERT(!request_to_make_active_,
               "GHOST_WindowIOS::resignKeyWindow(): activation request outstanding");

  surface->setVisible(false);
  IOS_WINDOW_LOG(@"Resigning Key Window: (ui_View)%p (mtkView)%p con(%p) (win=%p)",
                 uiview_,
                 metal_view_,
                 getContext(),
                 this);
  is_active_window_ = false;
  system_ios_->current_active_window_ = nullptr;
}

CGPoint GHOST_WindowIOS::scalePointToWindow(CGPoint &point)
{
  CGPoint scaled_point;
  scaled_point.x = point.x * getWindowScaleFactor();
  scaled_point.y = point.y * getWindowScaleFactor();
  return scaled_point;
}

#ifdef WITH_INPUT_IME
void GHOST_WindowIOS::beginIME(
    int32_t /*x*/, int32_t /*y*/, int32_t /*w*/, int32_t /*h*/, bool /*completed*/)
{
  /* Passthrough for iOS. */
}

void GHOST_WindowIOS::endIME()
{
  /* Passthrough for iOS. */
}
#endif /* WITH_INPUT_IME */

/* -------------------------------------------------------------------- */
/** \name The Window, for the Native Interface
 * \{ */

std::shared_ptr<std::atomic<bool>> GHOST_ios_window_alive(GHOST_WindowIOS *window)
{
  return window->input_alive;
}

bool GHOST_ios_window_presented_frame(GHOST_WindowIOS *window)
{
  return window->surface && window->surface->hasPresentedFrame();
}

void GHOST_ios_window_send_key(GHOST_WindowIOS *window, GHOST_TKey key)
{
  GHOST_SystemIOS *system = window->getSystem();
  if (system == nullptr) {
    return;
  }
  const uint64_t time = system->getMilliSeconds();
  system->pushEvent(
      std::make_unique<GHOST_EventKey>(time, GHOST_kEventKeyDown, window, key, false, nullptr));
  system->pushEvent(
      std::make_unique<GHOST_EventKey>(time, GHOST_kEventKeyUp, window, key, false, nullptr));
}

void GHOST_ios_window_press_key(GHOST_WindowIOS *window,
                                GHOST_TKey key,
                                const bool shift,
                                const bool ctrl,
                                const bool alt)
{
  GHOST_SystemIOS *system = window->getSystem();
  if (system == nullptr || key == GHOST_kKeyUnknown) {
    return;
  }
  /* The pointer at the middle of the view, the viewport, as a keyboard's first key without a
   * Pencil, mouse or trackpad puts it (#handleKeyboardEvent:keyWindow:). */
  const CGSize size = window->getView().bounds.size;
  CGPoint middle = CGPointMake(size.width / 2, size.height / 2);
  middle = window->scalePointToWindow(middle);
  window->updatePointerPosition(middle.x, middle.y);
  system->pushEvent(std::make_unique<GHOST_EventCursor>(system->getMilliSeconds(),
                                                        GHOST_kEventCursorMove,
                                                        window,
                                                        middle.x,
                                                        middle.y,
                                                        GHOST_TABLET_DATA_NONE));
  const std::pair<bool, std::pair<GHOST_TKey, GHOST_TModifierKey>> modifiers[] = {
      {shift, {GHOST_kKeyLeftShift, GHOST_kModifierKeyLeftShift}},
      {ctrl, {GHOST_kKeyLeftControl, GHOST_kModifierKeyLeftControl}},
      {alt, {GHOST_kKeyLeftAlt, GHOST_kModifierKeyLeftAlt}},
  };
  const auto push = [&](const GHOST_TKey pushed, const bool down) {
    system->pushEvent(std::make_unique<GHOST_EventKey>(system->getMilliSeconds(),
                                                       down ? GHOST_kEventKeyDown :
                                                              GHOST_kEventKeyUp,
                                                       window,
                                                       pushed,
                                                       false,
                                                       nullptr));
  };
  for (const auto &[held, modifier] : modifiers) {
    if (held) {
      GHOST_ios_set_modifier_held(modifier.second, true);
      push(modifier.first, true);
    }
  }
  push(key, true);
  push(key, false);
  for (const auto &[held, modifier] : modifiers) {
    if (held) {
      GHOST_ios_set_modifier_held(modifier.second, false);
      push(modifier.first, false);
    }
  }
}

void GHOST_ios_window_hold_modifier(GHOST_WindowIOS *window, GHOST_TKey key, const bool down)
{
  GHOST_SystemIOS *system = window->getSystem();
  if (system == nullptr) {
    return;
  }
  const GHOST_TModifierKey modifier = key == GHOST_kKeyLeftShift ? GHOST_kModifierKeyLeftShift :
                                                                   GHOST_kModifierKeyLeftControl;
  GHOST_ios_set_modifier_held(modifier, down);
  system->pushEvent(std::make_unique<GHOST_EventKey>(system->getMilliSeconds(),
                                                     down ? GHOST_kEventKeyDown :
                                                            GHOST_kEventKeyUp,
                                                     window,
                                                     key,
                                                     false,
                                                     nullptr));
}

UIWindow<GHOST_IOSInputWindow> *GHOST_ios_window_native(GHOST_WindowIOS *window)
{
  return (GHOSTUIWindow *)window->rootWindow;
}

CGPoint GHOST_ios_window_pixels(GHOST_WindowIOS *window, CGPoint point)
{
  return window->scalePointToWindow(point);
}

NSString *GHOST_ios_window_gate(GHOST_WindowIOS *window, CGPoint fraction)
{
  GHOSTUIWindow *native = (GHOSTUIWindow *)window->rootWindow;
  UIView *view = window->getView();
  if (native == nil || view == nil) {
    return @"no window";
  }
  const CGRect bounds = view.bounds;
  const CGPoint point = [view
      convertPoint:CGPointMake(bounds.size.width * fraction.x, bounds.size.height * fraction.y)
            toView:native];
  return [native blockedAt:point];
}

void GHOST_ios_window_drop_files(GHOST_WindowIOS *window,
                                 NSArray<NSString *> *paths,
                                 CGPoint point)
{
  GHOST_SystemIOS *system = window->getSystem();
  if (system == nullptr) {
    return;
  }
  GHOST_TStringArray *files = static_cast<GHOST_TStringArray *>(
      malloc(sizeof(GHOST_TStringArray)));
  files->count = int(paths.count);
  files->strings = static_cast<uint8_t **>(malloc(paths.count * sizeof(uint8_t *)));
  for (NSUInteger i = 0; i < paths.count; i++) {
    files->strings[i] = reinterpret_cast<uint8_t *>(strdup(paths[i].fileSystemRepresentation));
  }
  const CGPoint client = window->scalePointToWindow(point);
  system->pushEvent(std::make_unique<GHOST_EventDragnDrop>(system->getMilliSeconds(),
                                                           GHOST_kEventDraggingDropDone,
                                                           GHOST_kDragnDropTypeFilenames,
                                                           window,
                                                           int(lround(client.x)),
                                                           int(lround(client.y)),
                                                           files));
}

/** \} */
