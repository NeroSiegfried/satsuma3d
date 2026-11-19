/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * Blender's window: its controller, the SwiftUI document window in `swift/DocumentWindow.swift`,
 * and GHOST's window functions with C names, which Swift can call.
 */

#import "wm_apple_ios_interface.hh"

#include "WM_native_ui.hh"

#include <algorithm>
#include <string>
#include <utility>

/** Blender's main window, shown over the launcher while a document is open. */
static UIViewController<WMIOSDocumentController> *document_controller = nil;

namespace blender {

void WM_apple_ios_document_window_changed()
{
  [document_controller updateDocumentControls];
}

void *WM_apple_ios_window_controller(void *metal_view, GHOST_WindowIOS *window, void **r_root)
{
  UIViewController<WMIOSDocumentController> *controller = [[blenderIOSSwiftClass(
      @"WMIOSSwiftDocumentController") alloc] initWithMetalView:(MTKView *)metal_view
                                                         window:window];
  document_controller = controller;
  *r_root = controller;
  return controller;
}

void WM_apple_ios_about_show()
{
  /* Blender asks from its own loop; About is presented by UIKit (`SwiftAbout`). */
  dispatch_async(dispatch_get_main_queue(), ^{
    Class about_class = NSClassFromString(@"WMIOSSwiftAbout");
    UIViewController *presenter = wm_apple_ios_top_presenter();
    if (about_class && presenter) {
      [(id)about_class performSelector:@selector(presentFrom:) withObject:presenter];
    }
  });
}

const char *WM_apple_ios_app_name()
{
  static std::string name;
  if (name.empty()) {
    NSString *app = wm_apple_ios_app_name();
    name = app.length ? app.UTF8String : "";
  }
  return name.c_str();
}

}  // namespace blender

extern "C" void wm_apple_ios_document_controller_closed(id controller)
{
  if (document_controller == controller) {
    document_controller = nil;
  }
}

static GHOST_WindowIOS *ghost_window(void *window)
{
  return static_cast<GHOST_WindowIOS *>(window);
}

extern "C" bool wm_apple_ios_window_presented_frame(void *window)
{
  return window && GHOST_ios_window_presented_frame(ghost_window(window));
}

extern "C" CGPoint wm_apple_ios_window_pixels(void *window, CGPoint point)
{
  return window ? GHOST_ios_window_pixels(ghost_window(window), point) : point;
}

extern "C" void wm_apple_ios_window_send_key(void *window, const char *key)
{
  if (!window || !key) {
    return;
  }
  const GHOST_TKey ghost_key = STREQ(key, "X")   ? GHOST_kKeyX :
                               STREQ(key, "Y")   ? GHOST_kKeyY :
                               STREQ(key, "Z")   ? GHOST_kKeyZ :
                               STREQ(key, "ESC") ? GHOST_kKeyEsc :
                               STREQ(key, "RET") ? GHOST_kKeyEnter :
                                                   GHOST_kKeyUnknown;
  if (ghost_key != GHOST_kKeyUnknown) {
    GHOST_ios_window_send_key(ghost_window(window), ghost_key);
  }
}

/** A key by Blender's event type name, as the key-map names it: `U`, `F2`, `SPACE`, `ONE`. */
static GHOST_TKey ghost_key_from_name(const char *name)
{
  const std::string key = name;
  if (key.size() == 1 && key[0] >= 'A' && key[0] <= 'Z') {
    return GHOST_TKey(GHOST_kKeyA + (key[0] - 'A'));
  }
  const auto is_digit = [](const char c) { return c >= '0' && c <= '9'; };
  if (key.size() >= 2 && key.size() <= 3 && key[0] == 'F' &&
      std::all_of(key.begin() + 1, key.end(), is_digit))
  {
    const int number = std::stoi(key.substr(1));
    if (number >= 1 && number <= 24) {
      return GHOST_TKey(GHOST_kKeyF1 + number - 1);
    }
  }
  static const char *digits[] = {
      "ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE"};
  for (int i = 0; i < 10; i++) {
    if (key == digits[i]) {
      return GHOST_TKey(GHOST_kKey0 + i);
    }
  }
  static const std::pair<const char *, GHOST_TKey> named[] = {
      {"SPACE", GHOST_kKeySpace},
      {"ESC", GHOST_kKeyEsc},
      {"RET", GHOST_kKeyEnter},
      {"TAB", GHOST_kKeyTab},
      {"BACK_SPACE", GHOST_kKeyBackSpace},
      {"DEL", GHOST_kKeyDelete},
      {"HOME", GHOST_kKeyHome},
      {"END", GHOST_kKeyEnd},
      {"LEFT_ARROW", GHOST_kKeyLeftArrow},
      {"RIGHT_ARROW", GHOST_kKeyRightArrow},
      {"UP_ARROW", GHOST_kKeyUpArrow},
      {"DOWN_ARROW", GHOST_kKeyDownArrow},
      {"COMMA", GHOST_kKeyComma},
      {"PERIOD", GHOST_kKeyPeriod},
      {"SLASH", GHOST_kKeySlash},
      {"MINUS", GHOST_kKeyMinus},
      {"EQUAL", GHOST_kKeyEqual},
      {"ACCENT_GRAVE", GHOST_kKeyAccentGrave},
      {"LEFT_BRACKET", GHOST_kKeyLeftBracket},
      {"RIGHT_BRACKET", GHOST_kKeyRightBracket},
  };
  for (const auto &[text, ghost] : named) {
    if (key == text) {
      return ghost;
    }
  }
  return GHOST_kKeyUnknown;
}

extern "C" bool wm_apple_ios_window_press_key(
    void *window, const char *key, const bool shift, const bool ctrl, const bool alt)
{
  if (!window || !key) {
    return false;
  }
  const GHOST_TKey ghost_key = ghost_key_from_name(key);
  if (ghost_key == GHOST_kKeyUnknown) {
    return false;
  }
  GHOST_ios_window_press_key(ghost_window(window), ghost_key, shift, ctrl, alt);
  return true;
}

extern "C" NSString *wm_apple_ios_window_gate(void *window, CGPoint fraction)
{
  return window ? GHOST_ios_window_gate(ghost_window(window), fraction) : @"no window";
}

extern "C" void wm_apple_ios_window_hold_modifier(void *window, const char *key, const bool down)
{
  if (!window || !key) {
    return;
  }
  GHOST_ios_window_hold_modifier(
      ghost_window(window), STREQ(key, "shift") ? GHOST_kKeyLeftShift : GHOST_kKeyLeftControl, down);
}

extern "C" void wm_apple_ios_window_sticky_modifier(void *window, const int index, const int action)
{
  if (window) {
    GHOST_ios_window_sticky_modifier(ghost_window(window), index, action);
  }
}

extern "C" unsigned int wm_apple_ios_sticky_modifiers(void)
{
  return GHOST_ios_sticky_modifiers();
}

/** A web page, in the browser: Help's links, an add-on's documentation. */
extern "C" void wm_apple_ios_open_web_url(const char *url)
{
  NSURL *web = [NSURL URLWithString:@(url)];
  if (!web) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [UIApplication.sharedApplication openURL:web options:@{} completionHandler:nil];
  });
}

extern "C" bool wm_apple_ios_documents_available()
{
  return wm_apple_ios_launcher_can_show_documents();
}

extern "C" void wm_apple_ios_show_documents(id sender)
{
  wm_apple_ios_launcher_show_documents(sender);
}

extern "C" bool wm_apple_ios_document_window_visible()
{
  return GHOST_ios_document_window_visible();
}

extern "C" UIImage *wm_apple_ios_action_icon(NSString *op_name,
                                             NSString *property,
                                             NSString *value)
{
  return blenderIOSActionIcon(op_name, property, value);
}

extern "C" UIMenu *wm_apple_ios_context_menu()
{
  /* The same live context menu as Blender's and the Pencil's radial menu, resolved when it opens
   * so UIKit never waits for a busy engine. */
  return blenderIOSNativeSubmenu(
      @{
        @"title" : @"Actions",
        @"route" : @"context",
      },
      nil);
}

extern "C" void wm_apple_ios_window_navigation_tap(void *window, UITapGestureRecognizer *tap)
{
  if (window) {
    [GHOST_ios_window_native(ghost_window(window)) handleNavigationTap:tap];
  }
}

extern "C" bool wm_apple_ios_window_navigation_drag(
    void *window, const int phase, const CGPoint point, const CGPoint translation, const CGPoint velocity)
{
  return window && [GHOST_ios_window_native(ghost_window(window)) navigationGizmoDrag:phase
                                                                                   at:point
                                                                          translation:translation
                                                                             velocity:velocity];
}

extern "C" bool wm_apple_ios_window_navigation_button(void *window,
                                                      const int phase,
                                                      const CGPoint point)
{
  return window && [GHOST_ios_window_native(ghost_window(window)) navigationButtonTouch:phase
                                                                                     at:point];
}

extern "C" bool wm_apple_ios_window_navigation_drawn(void *window,
                                                     CGPoint *r_center,
                                                     CGFloat *r_radius)
{
  float place[3];
  if (!window || !WM_native_ui_navigation_drawn(GHOST_ios_window_handle(ghost_window(window)),
                                                1 /* #NavigationGizmoPart::Axes */,
                                                place))
  {
    return false;
  }
  /* Client pixels to the window's points, the inverse of `scalePointToWindow`. */
  const CGPoint one = GHOST_ios_window_pixels(ghost_window(window), CGPointMake(1, 1));
  const CGFloat scale = one.x > 0 ? one.x : 1;
  *r_center = CGPointMake(place[0] / scale, place[1] / scale);
  *r_radius = place[2] / scale;
  return true;
}

extern "C" bool wm_apple_ios_window_script_view_tap(void *window, const CGPoint point)
{
  return window && [GHOST_ios_window_native(ghost_window(window)) scriptViewTap:point];
}

extern "C" void wm_apple_ios_window_hold_took_touch(void *window)
{
  if (window) {
    [GHOST_ios_window_native(ghost_window(window)) holdTookTouch];
  }
}

extern "C" bool wm_apple_ios_window_script_tool_finger(void *window,
                                                       const int phase,
                                                       const CGPoint point)
{
  return window && [GHOST_ios_window_native(ghost_window(window)) scriptToolFinger:phase
                                                                               at:point];
}

extern "C" bool wm_apple_ios_window_script_touch(void *window, const int phase, const CGPoint point)
{
  return window && [GHOST_ios_window_native(ghost_window(window)) scriptInterfaceTouch:phase
                                                                                   at:point];
}

extern "C" bool wm_apple_ios_window_touch_find(
    void *window, const char *where, const int button_type, const bool last, CGPoint *r_point)
{
  int client[2];
  if (!window || !blender::WM_native_ui_touch_find(GHOST_ios_window_handle(ghost_window(window)),
                                                   where,
                                                   button_type,
                                                   last,
                                                   client))
  {
    return false;
  }
  /* Client pixels to the window's points, the inverse of `scalePointToWindow`. */
  const CGPoint one = GHOST_ios_window_pixels(ghost_window(window), CGPointMake(1, 1));
  const CGFloat scale = one.x > 0 ? one.x : 1;
  *r_point = CGPointMake(client[0] / scale, client[1] / scale);
  return true;
}

extern "C" NSString *wm_apple_ios_window_touch_description(void *window, const CGPoint point)
{
  return window ? [GHOST_ios_window_native(ghost_window(window)) touchDescriptionAt:point] :
                  @"no window";
}

extern "C" void wm_apple_ios_window_cancel_pencil_stroke(void *window)
{
  if (window) {
    [GHOST_ios_window_native(ghost_window(window)) cancelPencilStroke];
  }
}

extern "C" UIImage *wm_apple_ios_icon(NSString *key, NSString *symbol)
{
  return blenderIOSIcon(key, symbol);
}

extern "C" UIImage *wm_apple_ios_brush_image(NSString *preview, CGFloat diameter)
{
  return blenderIOSBrushImage(preview, diameter);
}

extern "C" UIDocument *wm_apple_ios_open_document()
{
  return wm_apple_ios_launcher_document();
}

extern "C" void wm_apple_ios_new_document(UIViewController *presenter)
{
  wm_apple_ios_launcher_new_document(presenter);
}

extern "C" void wm_apple_ios_save_document_as(UIViewController *presenter)
{
  wm_apple_ios_document_save_as(presenter);
}

extern "C" void wm_apple_ios_share_document_file(UIViewController *presenter,
                                                 void (^done)(NSURL *url))
{
  wm_apple_ios_document_file_now(presenter, done);
}

extern "C" void wm_apple_ios_restore_opening_version()
{
  wm_apple_ios_launcher_restore_opening_version();
}

extern "C" NSString *wm_apple_ios_document_status()
{
  WMIOSBlendDocument *document = (WMIOSBlendDocument *)wm_apple_ios_launcher_document();
  return [document isKindOfClass:WMIOSBlendDocument.class] ? document.status : nil;
}

extern "C" void wm_apple_ios_document_status_tapped()
{
  WMIOSBlendDocument *document = (WMIOSBlendDocument *)wm_apple_ios_launcher_document();
  if ([document isKindOfClass:WMIOSBlendDocument.class]) {
    [document statusTapped];
  }
}

extern "C" void wm_apple_ios_document_check(NSString *step, void (^done)(NSString *answer))
{
  wm_apple_ios_document_check_step(step, done);
}

extern "C" void wm_apple_ios_save_template(NSString *title,
                                           NSDictionary *presentation,
                                           void (^completion)(NSString *error))
{
  wm_apple_ios_template_save(title, presentation, completion);
}

extern "C" void wm_apple_ios_window_set_finger_tool(void *window, bool use_tool)
{
  if (window) {
    [GHOST_ios_window_native(ghost_window(window)) setFingerToolEnabled:use_tool];
  }
}

extern "C" void wm_apple_ios_window_set_pencil_menu(void *window, UIView<GHOSTIOSPencilMenu> *menu)
{
  if (window) {
    [GHOST_ios_window_native(ghost_window(window)) setPencilContextMenu:menu];
  }
}

extern "C" void wm_apple_ios_window_drop_files(void *window,
                                               NSArray<NSString *> *paths,
                                               CGPoint point)
{
  if (window) {
    GHOST_ios_window_drop_files(ghost_window(window), paths, point);
  }
}

/* -------------------------------------------------------------------- */
/** \name Blender's Menus in UIKit
 * \{ */

/** Blender's live context menu in the Pencil's radial menu, at the point it opens. */
@interface WMIOSPencilMenuSource : NSObject <GHOSTIOSPencilMenuDelegate>
@property(nonatomic) void *window;
@property(nonatomic, assign) UIView *viewport;
@end

@implementation WMIOSPencilMenuSource

- (NSArray<NSDictionary *> *)radialItems:(NSArray *)sources
{
  NSMutableArray *items = [NSMutableArray array];
  for (NSDictionary *source in sources) {
    if (![source isKindOfClass:NSDictionary.class]) {
      continue;
    }
    if ([source[@"heading"] isKindOfClass:NSString.class]) {
      /* The menu's own name, shown in the radial menu's center. */
      [items addObject:@{@"heading" : source[@"heading"]}];
      continue;
    }
    NSString *op = source[@"operator"];
    NSString *title = source[@"title"];
    if (![title isKindOfClass:NSString.class] || !title.length ||
        ![source[@"route"] isKindOfClass:NSString.class] ||
        (![source[@"action"] boolValue] && ![source[@"submenu"] boolValue]))
    {
      continue;
    }
    /* Keep source order, full titles, and distinct property-bearing routes, even when several
     * entries invoke the same operator (e.g. Set Origin or Delete). */
    NSMutableDictionary *item = [[source mutableCopy] autorelease];
    item[@"destructive"] = @([op isEqual:@"OBJECT_OT_delete"] || [op isEqual:@"MESH_OT_delete"]);
    UIImage *image = blenderIOSMenuIcon(source);
    if (!image && [source[@"submenu"] boolValue]) {
      image = [UIImage systemImageNamed:@"chevron.right"];
    }
    if (image) {
      item[@"image"] = image;
    }
    [items addObject:item];
  }
  return items;
}

- (CGPoint)pixels:(CGPoint)point from:(UIView *)menu
{
  return wm_apple_ios_window_pixels(_window, [menu convertPoint:point toView:_viewport]);
}

- (void)pencilMenu:(UIView<GHOSTIOSPencilMenu> *)menu
    requestItemsForRoute:(NSString *)route
                 atPoint:(CGPoint)point
              completion:(void (^)(NSArray<NSDictionary *> *))completion
{
  if (!_window) {
    completion(@[]);
    return;
  }
  const CGPoint pixels = [self pixels:point from:menu];
  blenderIOSMenuItems(route, &pixels, ^(NSArray *result) {
    completion([self radialItems:result]);
  });
}

- (void)pencilMenu:(UIView<GHOSTIOSPencilMenu> *)menu
     didChooseItem:(NSDictionary *)item
           atPoint:(CGPoint)point
{
  if (!_window || [item[@"disabled"] boolValue] ||
      ![item[@"route"] isKindOfClass:NSString.class])
  {
    return;
  }
  const CGPoint pixels = [self pixels:point from:menu];
  blenderIOSMenuRun(item[@"route"], &pixels);
}

@end

extern "C" NSObject<GHOSTIOSPencilMenuDelegate> *wm_apple_ios_pencil_menu_source(void *window,
                                                                                 UIView *viewport)
{
  WMIOSPencilMenuSource *source = [[[WMIOSPencilMenuSource alloc] init] autorelease];
  source.window = window;
  source.viewport = viewport;
  return source;
}

extern "C" void wm_apple_ios_pencil_menu_source_detach(NSObject *source)
{
  ((WMIOSPencilMenuSource *)source).window = nullptr;
}

/** Blender's menus in the iPadOS menu bar, from the menu bar projection `items`. */
extern "C" void wm_apple_ios_build_menu_bar(id<UIMenuBuilder> builder, NSArray *items)
{
  if (builder.system != UIMenuSystem.mainSystem || !items.count) {
    return;
  }
  NSDictionary *systemIdentifiers = @{
    @"TOPBAR_MT_blender" : UIMenuApplication,
    @"TOPBAR_MT_file" : UIMenuFile,
    @"TOPBAR_MT_edit" : UIMenuEdit,
    @"TOPBAR_MT_window" : UIMenuWindow,
    @"TOPBAR_MT_help" : UIMenuHelp,
    @"VIEW3D_MT_view" : UIMenuView,
  };
  NSMutableArray *commands = [NSMutableArray array];
  for (NSDictionary *item in items) {
    if ([item[@"separator"] boolValue] || ![item[@"title"] length]) {
      continue;
    }
    if (![item[@"submenu"] boolValue]) {
      [commands addObject:item];
      continue;
    }
    NSString *menuName = item[@"menu"];
    NSDictionary *shown = item;
    if ([menuName isEqualToString:@"TOPBAR_MT_blender"]) {
      /* Blender's application menu is this app's: it carries the app's name wherever the system
       * shows it as a menu of its own (ROUND5 8A). */
      NSMutableDictionary *renamed = [[item mutableCopy] autorelease];
      renamed[@"title"] = wm_apple_ios_app_name();
      shown = renamed;
    }
    NSString *systemIdentifier = systemIdentifiers[menuName];
    NSString *identifier = systemIdentifier ?:
                                              [@"org.blender.menu."
                                   stringByAppendingString:menuName ?: item[@"title"]];
    UIMenu *menu = blenderIOSNativeSubmenu(shown, identifier);
    if (systemIdentifier && [builder menuForIdentifier:systemIdentifier]) {
      if ([systemIdentifier isEqualToString:UIMenuApplication] ||
          [systemIdentifier isEqualToString:UIMenuWindow])
      {
        /* Keep iPadOS window-management and application commands available. */
        UIMenu *group = [UIMenu menuWithTitle:@""
                                        image:nil
                                   identifier:nil
                                      options:UIMenuOptionsDisplayInline
                                     children:menu.children];
        [builder insertChildMenu:group atEndOfMenuForIdentifier:systemIdentifier];
      }
      else {
        [builder replaceMenuForIdentifier:systemIdentifier withMenu:menu];
      }
    }
    else if ([builder menuForIdentifier:UIMenuWindow]) {
      [builder insertSiblingMenu:menu beforeMenuForIdentifier:UIMenuWindow];
    }
    else {
      [builder insertChildMenu:menu atEndOfMenuForIdentifier:UIMenuRoot];
    }
  }
  if (commands.count) {
    [builder insertChildMenu:[UIMenu menuWithTitle:@"Commands"
                                          children:blenderIOSNativeMenuElements(commands)]
        atEndOfMenuForIdentifier:UIMenuRoot];
  }
}

/** Ask Blender for its menu bar's menus, given to \a completion once it built them. */
extern "C" void wm_apple_ios_menu_bar_request(void (^completion)(NSArray *_Nullable items))
{
  blenderIOSMenuItems(@"menubar", nullptr, completion);
}

/** \} */

extern "C" bool wm_apple_ios_shader_compilation(int *finished, int *total, double *busy_seconds)
{
  *busy_seconds = GHOST_ios_engine_busy_seconds();
  return GHOST_ios_shader_compilation(finished, total);
}
