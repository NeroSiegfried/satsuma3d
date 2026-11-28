/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#import <UIKit/UIKit.h>

#include "GHOST_IOSNativeInterface.hh"
#include "wm_apple_ios_alerts.hh"
#include "WM_native_ui.h"
#import "wm_apple_ios_blend_document.hh"
#import "wm_apple_ios_launcher.hh"

@class WMIOSDialogRequest;

/* The sheet for dialogs with options, drawn in SwiftUI
 * (`source/blender/windowmanager/apple_ios/swift/DialogSheet.swift`). */
@interface UIViewController (WMIOSSwiftDialogSheet)
- (instancetype)initWithTitle:(NSString *)title
                      message:(NSString *)message
                      toggles:(NSArray<NSString *> *)toggles
                     selected:(NSArray<NSNumber *> *)selected
                      actions:(NSArray<NSString *> *)actions
                        roles:(NSArray<NSNumber *> *)roles
                    preferred:(NSInteger)preferred
                       choose:(void (^)(NSInteger action, uint64_t toggles))choose;
@end
static NSMutableArray<WMIOSDialogRequest *> *dialog_queue;
static NSTimer *dialog_timer;

@interface WMIOSDialogRequest : NSObject <UIAdaptivePresentationControllerDelegate>
{
 @public
  wmIOSDialog model;
  std::shared_ptr<std::atomic<bool>> alive;
}
@property(nonatomic) uint64_t identifier;
@property(nonatomic) wmIOSDialogCompletion completion;
@property(nonatomic, retain) UIWindow *window;
@property(nonatomic, retain) UIViewController *controller;
@property(nonatomic) BOOL finished;
/* The options chosen in the sheet, one bit per toggle. */
@property(nonatomic) uint64_t chosenToggles;
- (void)finish:(int)action;
- (void)presentFrom:(UIViewController *)presenter;
@end

static NSString *dialogString(const std::string &text)
{
  return [NSString stringWithUTF8String:text.c_str()] ?: @"";
}

static void dialogPump()
{
  WMIOSDialogRequest *request = dialog_queue.firstObject;
  if (!request) {
    [dialog_timer invalidate];
    [dialog_timer release];
    dialog_timer = nil;
    return;
  }
  if (!request->alive->load()) {
    [request finish:-1];
    return;
  }
  if (request.controller || request.finished) {
    return;
  }
  UIViewController *presenter = request.window.rootViewController;
  while (presenter.presentedViewController) {
    if (presenter.isBeingDismissed || presenter.presentedViewController.isBeingDismissed ||
        [presenter.presentedViewController isKindOfClass:UIAlertController.class])
    {
      return;
    }
    presenter = presenter.presentedViewController;
  }
  if (!presenter.view.window || presenter.isBeingPresented || presenter.isBeingDismissed) {
    return;
  }
  [request presentFrom:presenter];
}

@implementation WMIOSDialogRequest
- (void)dealloc
{
  [_controller release];
  [_window release];
  [super dealloc];
}

- (void)finish:(int)action
{
  if (self.finished) {
    return;
  }
  self.finished = YES;
  const uint64_t toggles = self.chosenToggles;
  /* Resolve only after dismissal so the next action can present a file picker. */
  void (^complete)(void) = ^{
    wmIOSDialogCompletion callback = self.completion;
    self.completion = nullptr;
    self.controller = nil;
    [dialog_queue removeObject:self];
    if (callback) {
      callback(self.identifier, action, toggles);
    }
    dialogPump();
  };
  if (self.controller.presentingViewController) {
    [self.controller dismissViewControllerAnimated:YES completion:complete];
  }
  else {
    [[self retain] autorelease];
    complete();
  }
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)controller
{
  [self finish:-1];
}

- (void)presentFrom:(UIViewController *)presenter
{
  if (model.toggles.empty()) {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:dialogString(model.title)
                         message:dialogString(model.message)
                  preferredStyle:UIAlertControllerStyleAlert];
    alert.view.accessibilityIdentifier = @"blender.nativeDialog";
    for (size_t i = 0; i < model.actions.size(); i++) {
      const wmIOSDialogAction &item = model.actions[i];
      UIAlertActionStyle style = item.role == wmIOSDialogRole::Cancel ?
                                     UIAlertActionStyleCancel :
                                 item.role == wmIOSDialogRole::Destructive ?
                                     UIAlertActionStyleDestructive :
                                     UIAlertActionStyleDefault;
      UIAlertAction *action = [UIAlertAction actionWithTitle:dialogString(item.title)
                                                       style:style
                                                     handler:^(UIAlertAction *) {
                                                       [self finish:int(i)];
                                                     }];
      [alert addAction:action];
      if (int(i) == model.preferred_action) {
        alert.preferredAction = action;
      }
    }
    self.controller = alert;
  }
  else {
    Class sheet_class = NSClassFromString(@"WMIOSSwiftDialogSheet");
    NSCAssert(sheet_class, @"The SwiftUI dialog sheet is missing");
    NSMutableArray *toggles = [NSMutableArray array], *selected = [NSMutableArray array];
    for (const wmIOSDialogToggle &option : model.toggles) {
      [toggles addObject:dialogString(option.title)];
      [selected addObject:@(option.selected)];
    }
    NSMutableArray *actions = [NSMutableArray array], *roles = [NSMutableArray array];
    for (const wmIOSDialogAction &action : model.actions) {
      [actions addObject:dialogString(action.title)];
      [roles addObject:@(action.role == wmIOSDialogRole::Cancel      ? 1 :
                         action.role == wmIOSDialogRole::Destructive ? 2 :
                                                                       0)];
    }
    __block WMIOSDialogRequest *owner = self;
    UIViewController *sheet = [[[sheet_class alloc]
        initWithTitle:dialogString(model.title)
              message:dialogString(model.message)
              toggles:toggles
             selected:selected
              actions:actions
                roles:roles
            preferred:model.preferred_action
               choose:^(NSInteger action, uint64_t chosen) {
                 owner.chosenToggles = chosen;
                 [owner finish:int(action)];
               }] autorelease];
    sheet.modalPresentationStyle = UIModalPresentationFormSheet;
    sheet.preferredContentSize = CGSizeMake(520, 600);
    self.controller = sheet;
  }
  wm_apple_ios_present_alert(presenter, self.controller);
  if (![self.controller isKindOfClass:UIAlertController.class]) {
    self.controller.presentationController.delegate = self;
  }
}
@end

bool wm_apple_ios_dialog_begin(void *window,
                               uint64_t identifier,
                               const wmIOSDialog &dialog,
                               wmIOSDialogCompletion completion)
{
  if (!window || dialog.actions.empty() || dialog.toggles.size() > 64) {
    return false;
  }
  GHOST_WindowIOS *ghost = static_cast<GHOST_WindowIOS *>(window);
  UIWindow *native_window = GHOST_ios_window_native(ghost);
  auto token = GHOST_ios_window_alive(ghost);
  wmIOSDialog owned = dialog;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!token->load()) {
      if (completion) {
        completion(identifier, -1, 0);
      }
      return;
    }
    if (!dialog_queue) {
      dialog_queue = [[NSMutableArray alloc] init];
    }
    /* Reports can arrive through both the operator popup and global report log. */
    if (!completion) {
      for (WMIOSDialogRequest *request in dialog_queue) {
        if (!request.completion && request.window == native_window &&
            request->model.title == owned.title && request->model.message == owned.message)
        {
          return;
        }
      }
    }
    WMIOSDialogRequest *request = [[[WMIOSDialogRequest alloc] init] autorelease];
    request->model = owned;
    request->alive = token;
    request.identifier = identifier;
    request.completion = completion;
    request.window = native_window;
    [dialog_queue addObject:request];
    if (!dialog_timer) {
      /* Owned: this file is built without ARC. */
      dialog_timer = [[NSTimer timerWithTimeInterval:0.05
                                             repeats:YES
                                               block:^(NSTimer *) {
                                                 dialogPump();
                                               }] retain];
      [NSRunLoop.mainRunLoop addTimer:dialog_timer forMode:NSRunLoopCommonModes];
    }
    dialogPump();
  });
  return true;
}

void wm_apple_ios_dialog_cancel(uint64_t identifier)
{
  dispatch_async(dispatch_get_main_queue(), ^{
    for (WMIOSDialogRequest *request in [[dialog_queue copy] autorelease]) {
      if (request.identifier == identifier) {
        request.completion = nullptr;
        [request finish:-1];
        break;
      }
    }
  });
}

/** The handlers of the Cancel actions #wm_apple_ios_cancel_action made, by action (weak). */
static NSMapTable<UIAlertAction *, id> *cancel_handlers()
{
  static NSMapTable<UIAlertAction *, id> *table = [[NSMapTable weakToStrongObjectsMapTable] retain];
  return table;
}

UIAlertAction *wm_apple_ios_cancel_action(NSString *title, void (^handler)(UIAlertAction *action))
{
  UIAlertAction *action = [UIAlertAction actionWithTitle:title
                                                   style:UIAlertActionStyleCancel
                                                 handler:handler];
  [cancel_handlers() setObject:handler ? [[handler copy] autorelease] : (id)[NSNull null]
                        forKey:action];
  return action;
}

/** The app's own alerts on screen, outside the dialog queue (the document's, the launcher's,
 * the shell's), each as its Cancel: dismissed, then its Cancel's handler run, as UIKit does for a
 * tap. One whose Cancel is not known is dismissed and said, never left up without a word. */
static int alerts_cancel_all(NSSet<UIViewController *> *queued)
{
  NSMutableArray<UIAlertController *> *alerts = [NSMutableArray array];
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) {
      continue;
    }
    for (UIWindow *window in ((UIWindowScene *)scene).windows) {
      for (UIViewController *top = window.rootViewController.presentedViewController; top;
           top = top.presentedViewController)
      {
        if ([top isKindOfClass:UIAlertController.class] && !top.isBeingDismissed &&
            ![queued containsObject:top])
        {
          [alerts addObject:(UIAlertController *)top];
        }
      }
    }
  }
  /* The top one first, as a person would answer them. */
  for (UIAlertController *alert in alerts.reverseObjectEnumerator) {
    UIAlertAction *cancel = nil;
    for (UIAlertAction *action in alert.actions) {
      if (action.style == UIAlertActionStyleCancel) {
        cancel = action;
      }
    }
    id handler = cancel ? [cancel_handlers() objectForKey:cancel] : nil;
    NSString *title = alert.title ?: @"(untitled)";
    if (cancel && handler) {
      WM_native_ui_log("snapshot", [@"dialog cancel: alert " stringByAppendingString:title].UTF8String);
    }
    else if (cancel) {
      /* A Cancel made elsewhere (Swift's `UIAlertAction(…, style: .cancel)` with no handler):
       * dismissing it is all its Cancel does when it has none, which cannot be read here. */
      WM_native_ui_log("snapshot", [@"dialog cancel: alert dismissed, its Cancel not known: "
                                       stringByAppendingString:title]
                                       .UTF8String);
    }
    else {
      WM_native_ui_log("snapshot", [@"dialog cancel: alert with no Cancel dismissed: "
                                       stringByAppendingString:title]
                                       .UTF8String);
    }
    [cancel retain];
    [handler retain];
    [alert.presentingViewController dismissViewControllerAnimated:NO
                                                       completion:^{
                                                         if (handler && handler != [NSNull null]) {
                                                           ((void (^)(UIAlertAction *))handler)(
                                                               cancel);
                                                         }
                                                         [handler release];
                                                         [cancel release];
                                                       }];
  }
  return int(alerts.count);
}

extern "C" int wm_apple_ios_dialogs_cancel_all(void)
{
  int count = 0;
  NSMutableSet<UIViewController *> *queued = [NSMutableSet set];
  for (WMIOSDialogRequest *request in [[dialog_queue copy] autorelease]) {
    if (request.controller) {
      [queued addObject:request.controller];
    }
    /* As Cancel: Blender is told, unlike #wm_apple_ios_dialog_cancel, which Blender asks. */
    [request finish:-1];
    count++;
  }
  /* The document's and the launcher's own alerts too (device round: `dialog cancel` left them). */
  return count + alerts_cancel_all(queued);
}
