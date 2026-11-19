/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */
#import "wm_apple_ios_launcher.hh"
#import "wm_apple_ios_blend_document.hh"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "GHOST_IOSRuntime.hh"
#include "WM_apple_ios.hh"
#include "WM_document_command.hh"
#include "WM_native_ui.h"

#include <string>

/* The views drawing Suzanne and the logo are Swift, in the app itself, see
 * `Launcher.swift`. They are found by name, as this library is built without Swift. */
@protocol WMIOSLauncherModelView
- (instancetype)initWithModelURL:(NSURL *)url;
- (void)placeModelWithCenter:(CGPoint)center size:(CGFloat)size;
/** The document browser, in front of the model's lower part, whose touches stay its own. */
@property(nonatomic, weak) UIView *browserView;
@end

@protocol WMIOSLauncherLogoView
- (instancetype)initWithArtworkURL:(NSURL *)url;
@property(nonatomic, readonly) CGFloat aspectRatio;
@end

#if defined(APPLE_TARGET_VISIONOS)
/** Apple Vision Pro: Blender's welcome in an ornament beside the document browser, which is all
 * the system shows of the launcher there. */
@protocol WMIOSLauncherOrnaments
- (instancetype)initWithController:(UIViewController *)controller
                          modelURL:(NSURL *)model_url
                           logoURL:(NSURL *)logo_url
                            choose:(void (^)(void))choose
                             start:(void (^)(void))start;
@property(nonatomic) BOOL shown;
@end
#endif

static UIColor *launcherColor(uint32_t rgb, CGFloat alpha)
{
  return [UIColor colorWithRed:((rgb >> 16) & 0xff) / 255.0
                         green:((rgb >> 8) & 0xff) / 255.0
                          blue:(rgb & 0xff) / 255.0
                         alpha:alpha];
}

static UIColor *launcherDynamicColor(UIColor *light, UIColor *dark)
{
  return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
    return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
  }];
}

/** Blender's brand behind the launcher: charcoal, with the logo's orange and blue as soft light.
 */
@interface WMIOSLauncherBackground : UIView
@end

@implementation WMIOSLauncherBackground
{
  CAGradientLayer *_base, *_orange, *_blue;
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if ((self = [super initWithFrame:frame])) {
    /* Owned: this file is built without ARC. */
    _base = [[CAGradientLayer alloc] init];
    _orange = [[CAGradientLayer alloc] init];
    _blue = [[CAGradientLayer alloc] init];
    _orange.type = _blue.type = kCAGradientLayerRadial;
    for (CALayer *layer in @[ _base, _blue, _orange ]) {
      [self.layer addSublayer:layer];
    }
    [self registerForTraitChanges:@[ UITraitUserInterfaceStyle.class ]
                       withAction:@selector(updateColors)];
    [self updateColors];
  }
  return self;
}

- (void)dealloc
{
  [_base release];
  [_orange release];
  [_blue release];
  [super dealloc];
}

- (void)updateColors
{
  UITraitCollection *traits = self.traitCollection;
  CGColorRef (^resolve)(UIColor *) = ^CGColorRef(UIColor *color) {
    return [color resolvedColorWithTraitCollection:traits].CGColor;
  };
  _base.colors = @[
    (id)resolve(launcherDynamicColor(launcherColor(0xFBF8F4, 1), launcherColor(0x1D1E22, 1))),
    (id)resolve(launcherDynamicColor(launcherColor(0xF1ECE6, 1), launcherColor(0x121316, 1))),
  ];
  UIColor *orange = launcherDynamicColor(launcherColor(0xE87D0D, 0.22),
                                         launcherColor(0xE87D0D, 0.38));
  UIColor *blue = launcherDynamicColor(launcherColor(0x265787, 0.16),
                                       launcherColor(0x265787, 0.55));
  _orange.colors = @[ (id)resolve(orange), (id)resolve([orange colorWithAlphaComponent:0]) ];
  _blue.colors = @[ (id)resolve(blue), (id)resolve([blue colorWithAlphaComponent:0]) ];
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  const CGRect bounds = self.bounds;
  const CGFloat size = MAX(bounds.size.width, bounds.size.height) * 0.9;
  _base.frame = bounds;
  /* The orange glows behind the title, the blue in the top left corner. */
  _orange.frame = CGRectMake(
      bounds.size.width * 0.62 - size / 2, bounds.size.height * 0.22 - size / 2, size, size);
  _blue.frame = CGRectMake(-size * 0.35 / 0.9, -size * 0.45 / 0.9, size, size);
  for (CAGradientLayer *layer in @[ _orange, _blue ]) {
    layer.startPoint = CGPointMake(0.5, 0.5);
    layer.endPoint = CGPointMake(1, 1);
  }
}

@end

/** Suzanne, huge on the right and slanted, behind the launcher's title and browser. */
@interface WMIOSLauncherModelStage : UIView
@end

@implementation WMIOSLauncherModelStage
{
  UIView<WMIOSLauncherModelView> *_model;
}

- (instancetype)initWithModel:(UIView<WMIOSLauncherModelView> *)model
{
  if ((self = [super initWithFrame:CGRectZero])) {
    _model = [model retain];
    model.frame = self.bounds;
    model.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:model];
  }
  return self;
}

- (void)dealloc
{
  [_model release];
  [super dealloc];
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  const CGSize size = self.bounds.size;
  [_model placeModelWithCenter:CGPointMake(size.width * 0.86, size.height * 0.46)
                          size:MAX(size.width, size.height) * 1.05];
}

/* Touches around Suzanne reach the launcher. */
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
  UIView *hit = [super hitTest:point withEvent:event];
  return hit == self ? nil : hit;
}

@end

NSString *wm_apple_ios_app_name()
{
  NSDictionary *info = NSBundle.mainBundle.infoDictionary;
  for (NSString *key in @[ @"CFBundleDisplayName", @"CFBundleName" ]) {
    NSString *name = info[key];
    if ([name isKindOfClass:NSString.class] && name.length) {
      return name;
    }
  }
  return NSProcessInfo.processInfo.processName;
}

static void launcherStyle(UIDocumentViewControllerLaunchOptions *launch)
{
  UIBackgroundConfiguration *background = [UIBackgroundConfiguration clearConfiguration];
  background.customView = [[[WMIOSLauncherBackground alloc] initWithFrame:CGRectZero] autorelease];
  launch.background = background;
  launch.browserViewController.view.tintColor = launcherColor(0xE87D0D, 1);

#if defined(APPLE_TARGET_VISIONOS)
  /* The system shows none of these there: the launcher's ornament has Suzanne and the logo. */
  return;
#endif
  NSBundle *bundle = NSBundle.mainBundle;
  NSURL *model_url = [bundle URLForResource:@"Suzanne" withExtension:@"usdz"];
  Class model_class = NSClassFromString(@"WMIOSLauncherModelView");
  if (model_url && model_class) {
    UIView<WMIOSLauncherModelView> *model = [[[model_class alloc] initWithModelURL:model_url]
        autorelease];
    model.browserView = launch.browserViewController.view;
    launch.backgroundAccessoryView = [[[WMIOSLauncherModelStage alloc] initWithModel:model]
        autorelease];
  }
}

/* -------------------------------------------------------------------- */
/** \name Templates
 * \{ */

static NSArray<NSDictionary *> *launcherTemplates()
{
  return wm_apple_ios_document_templates();
}

/* About and Licences, in SwiftUI (`source/blender/windowmanager/apple_ios/swift/AboutSheet.swift`). */
@interface NSObject (WMIOSSwiftAbout)
+ (void)presentFrom:(UIViewController *)presenter;
@end

/* The device floor (ROUND5 8N), `DeviceFloorNotice` in
 * `source/blender/windowmanager/apple_ios/swift/DeviceFloorNotice.swift`. */
@interface NSObject (WMIOSSwiftDeviceFloor)
+ (void)presentIfNeededFrom:(UIViewController *)presenter;
@end

/* The template chooser in SwiftUI
 * (`source/blender/windowmanager/apple_ios/swift/TemplatePicker.swift`). */
@interface UIViewController (WMIOSSwiftTemplatePicker)
- (instancetype)initWithTemplates:(NSArray<NSDictionary *> * (^)(void))templates
                           manage:(void (^)(NSDictionary *entry,
                                            NSString *action,
                                            NSString *title,
                                            void (^done)(BOOL success)))manage
                       completion:(void (^)(NSString *app_template))completion;
@end

/** \} */

/* -------------------------------------------------------------------- */
/** \name Launcher
 * \{ */

/** Where a document was open when the app was left, to continue there. */
static NSString *const launcher_open_document_key = @"BlenderOpenDocument";

/* -------------------------------------------------------------------- */
/** \name The session marker (ROUND6 SAFE-4, decision R6-3)
 *
 * Set before a document opens (phase `opening`), moved to `open` once its first frame shows, and
 * cleared when the app goes to the background cleanly or the document closes. Still set at the
 * next launch: the app ended while the document was open, perhaps because of it, so the launcher
 * stays where it is and says so instead of opening it again (a document that ends the app
 * would otherwise do so at every launch).
 * \{ */

static NSString *const launcher_marker_key = @"BlenderSessionMarker";
/** How many launches in a row found the marker in phase `opening`. */
static NSString *const launcher_opening_ends_key = @"BlenderSessionOpeningEnds";

/* The launch line and the system's own reasons for earlier exits, `SessionDiagnostics.swift`. */
@interface NSObject (WMIOSSwiftSessionDiagnostics)
+ (void)startWithLastSession:(NSString *)last_session;
@end

static NSString *launcherBuild()
{
  NSDictionary *info = NSBundle.mainBundle.infoDictionary;
  return [NSString stringWithFormat:@"%@ (%@)",
                                    info[@"CFBundleShortVersionString"] ?: @"?",
                                    info[@"CFBundleVersion"] ?: @"?"];
}

static void launcherMarkerSet(NSURL *url, NSString *phase)
{
  NSData *bookmark = [url bookmarkDataWithOptions:0
                   includingResourceValuesForKeys:nil
                                    relativeToURL:nil
                                            error:nil];
  NSMutableDictionary *marker = [NSMutableDictionary dictionary];
  marker[@"name"] = url.lastPathComponent ?: @"";
  marker[@"phase"] = phase;
  marker[@"time"] = [NSDate date];
  marker[@"build"] = launcherBuild();
  if (bookmark) {
    marker[@"bookmark"] = bookmark;
  }
  [NSUserDefaults.standardUserDefaults setObject:marker forKey:launcher_marker_key];
  if ([phase isEqual:@"open"]) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:launcher_opening_ends_key];
  }
  WM_native_ui_log("session", [NSString stringWithFormat:@"marker %@ %@", phase,
                                                         url.lastPathComponent]
                                  .UTF8String);
}

static void launcherMarkerClear(const char *why)
{
  NSDictionary *marker = [NSUserDefaults.standardUserDefaults dictionaryForKey:launcher_marker_key];
  if (marker == nil) {
    return;
  }
  /* A check launch leaves the person's marker for their next launch. */
  if (NSProcessInfo.processInfo.environment[@"PLATYPUS_SCRATCH_DOCUMENT"] != nil &&
      ![marker[@"name"] hasPrefix:@"PlatypusCheck"])
  {
    return;
  }
  [NSUserDefaults.standardUserDefaults removeObjectForKey:launcher_marker_key];
  WM_native_ui_log("session", (std::string("marker cleared: ") + why).c_str());
}

/** \} */
/** Choosing a template before creating a document. */
static UIDocumentCreationIntent const launcher_template_intent = @"template";
static UIDocumentCreationIntent const launcher_general_intent = @"general";

/**
 * A launch for checks (`PLATYPUS_SCRATCH_DOCUMENT` in the environment, set by a developer's
 * scripted launch, see `Snapshots.swift`) works in a fresh copy of the General template in the
 * app's temporary folder, never in the person's document: its scripts edit, and a document saves
 * itself. Its bookmark is not kept, so the next ordinary launch continues in the person's
 * document, and that launch deletes the copy and its auto-save.
 */
static NSString *const launcher_scratch_name = @"PlatypusCheck";

static NSURL *launcherScratchFolder()
{
  return [NSURL fileURLWithPath:[NSTemporaryDirectory()
                                    stringByAppendingPathComponent:@"platypus-scratch"]
                    isDirectory:YES];
}

/** Remove the copy and the auto-saves Blender kept of it (named after it, see
 * #wm_apple_ios_autosave_location). */
static void launcherScratchRemove()
{
  NSFileManager *files = NSFileManager.defaultManager;
  [files removeItemAtURL:launcherScratchFolder() error:nil];
  NSURL *support = [files URLsForDirectory:NSApplicationSupportDirectory
                                 inDomains:NSUserDomainMask]
                       .firstObject;
  NSURL *blender = [support URLByAppendingPathComponent:@"Blender" isDirectory:YES];
  /* Every file a check makes is named after it (`PlatypusCheck New 1.blend`, see
   * #wm_apple_ios_document_check_step), so its auto-saves start with the name too: never another
   * file's. */
  NSString *prefix = launcher_scratch_name;
  for (NSURL *version in [files contentsOfDirectoryAtURL:blender
                              includingPropertiesForKeys:nil
                                                 options:0
                                                   error:nil])
  {
    NSURL *autosave = [version URLByAppendingPathComponent:@"datafiles/autosave" isDirectory:YES];
    for (NSURL *item in [files contentsOfDirectoryAtURL:autosave
                             includingPropertiesForKeys:nil
                                                options:0
                                                  error:nil])
    {
      if ([item.lastPathComponent hasPrefix:prefix]) {
        [files removeItemAtURL:item error:nil];
      }
    }
  }
}

/** What check launches leave in the temporary folder: snapshot pictures (`Snapshots.swift`) and
 * the packaged build's device test with its result (`tests/ios/testflight_device_test.py`).
 * Removed by an ordinary launch, as the scratch copy is, so the person's app keeps none of it. */
static void launcherCheckOutputRemove()
{
  NSFileManager *files = NSFileManager.defaultManager;
  for (NSString *name in @[ @"shots", @"testflight-check", @"testflight_device_test.py" ]) {
    [files removeItemAtPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]
                      error:nil];
  }
}

/** Whether \a url is the check's own copy (or anything else in its folder). */
static BOOL launcherIsScratch(NSURL *url)
{
  /* By its folder, which exists: symbolic links (`/var` and `/private/var`) resolve only in paths
   * that exist, and a file the check is about to make does not yet. */
  NSString *folder = launcherScratchFolder().URLByStandardizingPath.URLByResolvingSymlinksInPath.path;
  NSString *parent = url.URLByStandardizingPath.URLByDeletingLastPathComponent
                         .URLByResolvingSymlinksInPath.path;
  return parent && folder && ([parent isEqualToString:folder] ||
                              [parent hasPrefix:[folder stringByAppendingString:@"/"]]);
}

/** A new copy of the General template, replacing any earlier one, or nil. */
static NSURL *launcherScratchCreate()
{
  launcherScratchRemove();
  NSURL *seed = nil;
  for (NSDictionary *item in wm_apple_ios_document_templates()) {
    if ([item[@"id"] isEqual:@"general"]) {
      seed = item[@"url"];
      break;
    }
  }
  NSFileManager *files = NSFileManager.defaultManager;
  NSURL *folder = launcherScratchFolder();
  NSURL *url = [folder
      URLByAppendingPathComponent:[launcher_scratch_name stringByAppendingString:@".blend"]];
  if (!seed || ![files createDirectoryAtURL:folder
                    withIntermediateDirectories:YES
                                     attributes:nil
                                          error:nil] ||
      ![files copyItemAtURL:seed toURL:url error:nil])
  {
    return nil;
  }
  return url;
}

/**
 * The document launcher, in the app's first window, shown at once on launch while Blender starts
 * behind it. It owns the open document; Blender's window shows only while one is open.
 */
@interface WMIOSLauncherController
    : UIDocumentViewController <UIDocumentBrowserViewControllerDelegate,
                                UIDocumentPickerDelegate>
- (void)openDocumentAtURL:(NSURL *)url;
- (void)openFailed:(UIDocument *)document reason:(NSString *)reason;
- (void)adoptCopy:(NSURL *)copy nextTo:(NSURL *)next_to;
- (void)documentCommand:(blender::wmDocumentCommand)command argument:(NSString *)argument;
- (void)templatePickerDismissed;
- (void)chooseTemplate:(void (^)(NSString *app_template))completion;
- (void)newDocumentFrom:(UIViewController *)presenter;
@end

/**
 * A file in `folders` the browser imported from a copy of `backup`: named like it, the same
 * contents, and created since the backup was.
 */
static NSURL *importedCopy(NSURL *backup, NSArray<NSURL *> *folders)
{
  NSFileManager *files = NSFileManager.defaultManager;
  NSDate *backed_up = nil;
  [backup getResourceValue:&backed_up forKey:NSURLCreationDateKey error:nil];
  NSString *name = backup.URLByDeletingPathExtension.lastPathComponent;
  for (NSURL *folder in folders) {
    for (NSURL *item in [files contentsOfDirectoryAtURL:folder
                             includingPropertiesForKeys:@[ NSURLCreationDateKey ]
                                                options:NSDirectoryEnumerationSkipsHiddenFiles
                                                  error:nil])
    {
      NSDate *created = nil;
      [item getResourceValue:&created forKey:NSURLCreationDateKey error:nil];
      /* The import may keep the date of the file it was given, made just before the backup. */
      if (backed_up && created && [created timeIntervalSinceDate:backed_up] > -2.0 &&
          [item.pathExtension isEqualToString:backup.pathExtension] &&
          [item.lastPathComponent hasPrefix:name] &&
          [files contentsEqualAtPath:item.path andPath:backup.path])
      {
        return item;
      }
    }
  }
  return nil;
}

static WMIOSLauncherController *launcher_controller = nil;
/** A file the system asked to open before the launcher existed. */
static NSURL *launcher_pending_url = nil;

@implementation WMIOSLauncherController
{
  /** The marker found at launch: the app ended while this document was open (ROUND6 SAFE-4). */
  NSDictionary *_endedMarker;
  /** Launches in a row that ended while the document was opening. */
  NSInteger _openingEnds;
  /** A document is being opened: Blender loads one file at a time. */
  BOOL _opening;
  BOOL _creating;
  NSString *_creatingTemplate;
  NSURL *_createdURL;
  NSDictionary *_createdPresentation;
  NSURL *_creationSource;
  /** A copy of the new document, kept until the browser has imported it. */
  NSURL *_creationBackup;
  /** A launch for checks, in a copy of the General template, see #launcher_scratch_name. */
  BOOL _scratch;
#if defined(APPLE_TARGET_VISIONOS)
  NSObject<WMIOSLauncherOrnaments> *_ornaments;
#endif
}

- (void)viewDidLoad
{
  [super viewDidLoad];
  /* The document view, which iOS zooms between the browser and the open document: the 3D
   * viewport's grey, so opening and closing never flash white. */
  self.view.backgroundColor = launcherColor(0x3D3D3D, 1);
#if defined(APPLE_TARGET_VISIONOS)
  /* The window's glass around the browser, as the system's own document windows there. */
  self.view.backgroundColor = UIColor.clearColor;
#endif
  UIDocumentViewControllerLaunchOptions *launch = self.launchOptions;
  launch.title = wm_apple_ios_app_name();
  if (@available(iOS 27.0, visionOS 27.0, *)) {
    launch.subtitle = @"Create a new scene or open one";
  }
  /* Choosing a template first, or starting at once from General. Both create
   * through the browser, which places the document and lists it in Recents. */
  UIAction *choose = [UIDocumentViewControllerLaunchOptions
      createDocumentActionWithIntent:launcher_template_intent];
  choose.title = @"Choose a Template";
  launch.primaryAction = choose;
  UIAction *start = [UIDocumentViewControllerLaunchOptions
      createDocumentActionWithIntent:launcher_general_intent];
  start.title = @"Start Creating";
  launch.secondaryAction = start;
  /* The browser lists, opens and creates Blender files. The launcher's own browser knows no file
   * types: it would list nothing, not even in Recents, and create nothing. */
  /* The type the app declares for `.blend` files, exactly: dragged files carry it, and the
   * browser accepts only drops of its own types. */
  NSArray *document_types = [NSBundle.mainBundle
      objectForInfoDictionaryKey:@"CFBundleDocumentTypes"];
  NSArray *content_types = [document_types.firstObject objectForKey:@"LSItemContentTypes"];
  NSString *blend_identifier = content_types.firstObject;
  UTType *blend_type = (blend_identifier ? [UTType typeWithIdentifier:blend_identifier] : nil) ?:
                           [UTType typeWithFilenameExtension:@"blend" conformingToType:UTTypeData];
  UIDocumentBrowserViewController *browser = [[[UIDocumentBrowserViewController alloc]
      initForOpeningContentTypes:@[ blend_type ]] autorelease];
  browser.delegate = self;
  browser.allowsDocumentCreation = YES;
  /* A Blender file, not a sheet of paper: square, like its previews. Set before the browser first
   * draws: changing the create tile afterwards loses its "+". */
  browser.localizedCreateDocumentActionTitle = @"Create Blender File";
  browser.defaultDocumentAspectRatio = 1.0;
  /* Picking several is what lets the browser select files, to move or share them, as Files does.
   * Opening takes the first: Blender works on one file at a time. */
  browser.allowsPickingMultipleItems = YES;
  /* About and Licences (ROUND5 8C), `SwiftAbout` in `AboutSheet.swift`. */
  Class about_class = NSClassFromString(@"WMIOSSwiftAbout");
  if (about_class) {
    /* Not retained: the browser, which holds the action, is the launcher's own. */
    __block UIViewController *presenter = self;
    UIAction *about = [UIAction
        actionWithTitle:[@"About " stringByAppendingString:wm_apple_ios_app_name()]
                  image:[UIImage systemImageNamed:@"info.circle"]
             identifier:nil
                handler:^(__kindof UIAction *) {
                  [about_class presentFrom:presenter];
                }];
    UIBarButtonItem *item = [[[UIBarButtonItem alloc] initWithPrimaryAction:about] autorelease];
    item.accessibilityLabel = about.title;
    browser.additionalTrailingNavigationBarButtonItems = @[ item ];
  }
  launch.browserViewController = browser;
  launcherStyle(launch);
#if defined(APPLE_TARGET_VISIONOS)
  [self addOrnaments];
#endif

  /* Save before leaving the foreground, while the GPU can still render the file's preview. */
  [NSNotificationCenter.defaultCenter addObserver:self
                                         selector:@selector(sceneWillDeactivate:)
                                             name:@"BlenderSceneInactive"
                                           object:nil];
  /* The session marker: a clean background clears it, coming back sets it again (SAFE-4). */
  [NSNotificationCenter.defaultCenter addObserver:self
                                         selector:@selector(appDidEnterBackground:)
                                             name:UIApplicationDidEnterBackgroundNotification
                                           object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self
                                         selector:@selector(appWillEnterForeground:)
                                             name:UIApplicationWillEnterForegroundNotification
                                           object:nil];

  /* Did the last session end cleanly? Read before anything opens (ROUND6 SAFE-4). */
  NSDictionary *marker = [NSUserDefaults.standardUserDefaults
      dictionaryForKey:launcher_marker_key];
  const BOOL check_launch = NSProcessInfo.processInfo.environment[@"PLATYPUS_SCRATCH_DOCUMENT"] !=
                            nil;
  /* A check launch heeds only a marker of its own copy, and leaves the person's as it is. */
  if (marker && (!check_launch || [marker[@"name"] hasPrefix:launcher_scratch_name])) {
    _endedMarker = [marker copy];
    _openingEnds = [NSUserDefaults.standardUserDefaults integerForKey:launcher_opening_ends_key];
    if ([marker[@"phase"] isEqual:@"opening"]) {
      _openingEnds++;
      [NSUserDefaults.standardUserDefaults setInteger:_openingEnds
                                               forKey:launcher_opening_ends_key];
    }
    [NSUserDefaults.standardUserDefaults removeObjectForKey:launcher_marker_key];
  }
  NSString *last_session = nil;
  if (_endedMarker) {
    NSDateFormatter *format = [[[NSDateFormatter alloc] init] autorelease];
    format.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    last_session = [NSString
        stringWithFormat:@"the last session did not end cleanly: %@ was %@ (%@, build %@)",
                         _endedMarker[@"name"],
                         _endedMarker[@"phase"],
                         [format stringFromDate:_endedMarker[@"time"]] ?: @"?",
                         _endedMarker[@"build"] ?: @"?"];
  }
  Class diagnostics = NSClassFromString(@"WMIOSSessionDiagnostics");
  if (diagnostics) {
    [diagnostics startWithLastSession:last_session];
  }
  else if (last_session) {
    WM_native_ui_log("launch", last_session.UTF8String);
  }

  NSURL *url = [[launcher_pending_url retain] autorelease];
  [launcher_pending_url release];
  launcher_pending_url = nil;
  if (NSProcessInfo.processInfo.environment[@"PLATYPUS_SCRATCH_DOCUMENT"] != nil) {
    /* Never the person's document, not even one the system asked to open: a check works in its
     * own copy, or in nothing. */
    _scratch = YES;
    url = launcherScratchCreate();
    NSLog(@"Platypus: scratch document %@", url.path ?: @"could not be created");
  }
  else {
    launcherScratchRemove();
    launcherCheckOutputRemove();
  }
  if (_endedMarker) {
    /* The app ended while a document was open: stay here and say so, never open it again by
     * itself (ROUND6 SAFE-4). Not even one the system asked to open. */
    WM_native_ui_log("launch", "stayed in the launcher after an unclean end");
    url = nil;
  }
  else if (url == nil && !_scratch) {
    /* Continue in the document that was open when the app was left. */
    NSData *bookmark = [NSUserDefaults.standardUserDefaults dataForKey:launcher_open_document_key];
    BOOL stale = NO;
    url = bookmark ? [NSURL URLByResolvingBookmarkData:bookmark
                                               options:0
                                         relativeToURL:nil
                                   bookmarkDataIsStale:&stale
                                                 error:nil] :
                     nil;
  }
  if (url) {
    [self openDocumentAtURL:url];
  }
}

- (void)viewDidAppear:(BOOL)animated
{
  [super viewDidAppear:animated];
  if (_endedMarker && self.presentedViewController == nil) {
    [self presentEndedSession];
  }
  /* An iPad below the floor is told so, here when the app opens on its documents (ROUND5 8N);
   * once per launch, whichever of this and a document's window asks first. */
  Class floor_class = NSClassFromString(@"WMIOSSwiftDeviceFloor");
  if (floor_class) {
    [floor_class presentIfNeededFrom:self];
  }
}

- (void)dealloc
{
  [NSNotificationCenter.defaultCenter removeObserver:self];
  [_endedMarker release];
  [_creatingTemplate release];
  [_createdURL release];
  [_createdPresentation release];
  [_creationSource release];
  [self discardCreationBackup];
#if defined(APPLE_TARGET_VISIONOS)
  [_ornaments release];
#endif
  [super dealloc];
}

#if defined(APPLE_TARGET_VISIONOS)
/** Blender's welcome beside the browser, with the launch options' title and actions, which the
 * system shows nowhere there. */
- (void)addOrnaments
{
  Class ornaments_class = NSClassFromString(@"WMIOSLauncherOrnaments");
  if (ornaments_class == nil) {
    return;
  }
  NSBundle *bundle = NSBundle.mainBundle;
  _ornaments = [[ornaments_class alloc]
      initWithController:self
                modelURL:[bundle URLForResource:@"Suzanne" withExtension:@"usdz"]
                 logoURL:[bundle URLForResource:@"blender_logo_mono" withExtension:@"svg"]
                  choose:^{
                    [launcher_controller chooseFromLauncher:YES];
                  }
                   start:^{
                     [launcher_controller chooseFromLauncher:NO];
                   }];
  [self updateOrnaments];
}

/** The ornament's buttons: choosing a template first, or starting at once from General, as the
 * launch options' actions do. */
- (void)chooseFromLauncher:(BOOL)choose_template
{
  if (_creating || _opening || self.document) {
    return;
  }
  /* The system presents the browser over the launcher there: present over it. */
  UIViewController *presenter = self;
  while (presenter.presentedViewController) {
    presenter = presenter.presentedViewController;
  }
  if (choose_template) {
    [self newDocumentFrom:presenter];
  }
  else {
    [self createDocumentFromTemplate:@"" presenter:presenter];
  }
}

/** Shown in the launcher only, never over an open document. */
- (void)updateOrnaments
{
  _ornaments.shown = self.document == nil && !GHOST_ios_document_window_visible();
}
#endif

/* The document browser can fail to import into a location it remembers but can no longer reach,
 * such as the app's previous container after a reinstall, and it deletes the file it was given.
 * Keep a copy until the import succeeds, so the new document can go to the app's own Documents
 * folder instead, which the browser always shows. */
- (void)backUpCreation:(NSURL *)source
{
  [self discardCreationBackup];
  NSFileManager *files = NSFileManager.defaultManager;
  NSURL *folder = [NSURL
      fileURLWithPath:[NSTemporaryDirectory()
                          stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
  NSURL *backup = [folder URLByAppendingPathComponent:source.lastPathComponent];
  if ([files createDirectoryAtURL:folder
          withIntermediateDirectories:YES
                           attributes:nil
                                error:nil] &&
      [files copyItemAtURL:source toURL:backup error:nil])
  {
    _creationBackup = [backup copy];
  }
}

- (void)discardCreationBackup
{
  if (_creationBackup) {
    [NSFileManager.defaultManager removeItemAtURL:_creationBackup.URLByDeletingLastPathComponent
                                            error:nil];
    [_creationBackup release];
    _creationBackup = nil;
  }
}

- (NSURL *)keepCreationBackup
{
  NSFileManager *files = NSFileManager.defaultManager;
  NSURL *folder =
      [files URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
  NSURL *source = _creationBackup;
  if (!source || !folder || ![files fileExistsAtPath:source.path]) {
    [self discardCreationBackup];
    return nil;
  }
  /* The browser can report an import as failed although the file arrived, when it cannot look
   * the new file up straight away. Open the file it imported, which it lists in Recents, rather
   * than a second copy it never saw. */
  NSMutableArray<NSURL *> *folders = [NSMutableArray arrayWithObject:folder];
  if (NSURL *current = self.document.fileURL.URLByDeletingLastPathComponent) {
    [folders insertObject:current atIndex:0];
  }
  if (NSURL *imported = importedCopy(source, folders)) {
    [self discardCreationBackup];
    return imported;
  }
  NSString *name = source.URLByDeletingPathExtension.lastPathComponent;
  NSString *extension = source.pathExtension;
  NSURL *destination = [folder URLByAppendingPathComponent:source.lastPathComponent];
  for (NSInteger number = 2; [files fileExistsAtPath:destination.path] && number < 10000; number++)
  {
    destination = [folder URLByAppendingPathComponent:[NSString stringWithFormat:@"%@ %ld.%@",
                                                                                 name,
                                                                                 (long)number,
                                                                                 extension]];
  }
  const BOOL moved = [files moveItemAtURL:source toURL:destination error:nil];
  [self discardCreationBackup];
  return moved ? destination : nil;
}

- (void)creationFailed:(UIViewController *)presenter
{
  _creating = NO;
  [_creatingTemplate release];
  _creatingTemplate = nil;
  [self discardCreationBackup];
  if (_creationSource) {
    [NSFileManager.defaultManager removeItemAtURL:_creationSource.URLByDeletingLastPathComponent
                                            error:nil];
    [_creationSource release];
    _creationSource = nil;
  }
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"Could Not Create Document"
                       message:
                           @"Your current document has not been replaced. Check available storage "
                           @"and try again."
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
  [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)recordCreatedTemplateAtURL:(NSURL *)url
{
  if (!_creatingTemplate) {
    return;
  }
  [_createdURL release];
  _createdURL = [url copy];
  [_createdPresentation release];
  _createdPresentation = nil;
  for (NSDictionary *entry in launcherTemplates()) {
    if ([entry[@"id"] isEqual:_creatingTemplate.length ? _creatingTemplate : @"general"]) {
      _createdPresentation = [entry[@"presentation"] copy];
      break;
    }
  }
  [_creatingTemplate release];
  _creatingTemplate = nil;
  _creating = NO;
}

- (void)newDocumentFrom:(UIViewController *)presenter
{
  if (_creating || _opening || presenter.presentedViewController) {
    return;
  }
  _creating = YES;
  UIViewController *picker = [self templatePicker:^(NSString *identifier) {
    if (!identifier) {
      self->_creating = NO;
      return;
    }
    [self createDocumentFromTemplate:identifier presenter:presenter];
  }];
  [presenter presentViewController:picker animated:YES completion:nil];
}

/** Create a document from a template, empty for General, place it with the browser, which lists
 * it in Recents, and open it. */
- (void)createDocumentFromTemplate:(NSString *)identifier presenter:(UIViewController *)presenter
{
  _creating = YES;
  [_creatingTemplate release];
  _creatingTemplate = [identifier copy];
  wm_apple_ios_document_create(identifier, ^(NSURL *source) {
    if (!source) {
      [self creationFailed:presenter];
      return;
    }
    if (_scratch) {
      /* A check launch makes its new documents in its own folder, never where the browser would
       * place them (ROUND5 9D.5): the person's folders are not touched. */
      NSFileManager *files = NSFileManager.defaultManager;
      NSURL *destination = nil;
      for (NSInteger number = 1; number < 1000; number++) {
        destination = [launcherScratchFolder()
            URLByAppendingPathComponent:[NSString stringWithFormat:@"%@ New %ld.blend",
                                                                   launcher_scratch_name,
                                                                   (long)number]];
        if (![files fileExistsAtPath:destination.path]) {
          break;
        }
      }
      const BOOL moved = [files moveItemAtURL:source toURL:destination error:nil];
      [files removeItemAtURL:source.URLByDeletingLastPathComponent error:nil];
      if (!moved) {
        [self creationFailed:presenter];
        return;
      }
      WM_native_ui_log(
          "document",
          [@"new in the scratch folder: " stringByAppendingString:destination.lastPathComponent]
              .UTF8String);
      [self recordCreatedTemplateAtURL:destination];
      [self openDocumentAtURL:destination];
      return;
    }
    [self backUpCreation:source];
    [self.launchOptions.browserViewController
        importDocumentAtURL:source
        nextToDocumentAtURL:self.document.fileURL
                       mode:UIDocumentBrowserImportModeMove
          completionHandler:^(NSURL *destination, NSError *error) {
            if (!destination || error) {
              destination = [self keepCreationBackup];
            }
            [self discardCreationBackup];
            [NSFileManager.defaultManager removeItemAtURL:source.URLByDeletingLastPathComponent
                                                    error:nil];
            if (!destination) {
              [self creationFailed:presenter];
              return;
            }
            [self recordCreatedTemplateAtURL:destination];
            [self openDocumentAtURL:destination];
          }];
  });
}

- (void)openDocumentAtURL:(NSURL *)url
{
  UIDocument *previous = self.document;
  const BOOL previous_open = previous && !(previous.documentState & UIDocumentStateClosed);
  /* A second tap while a file opens, or opening the file that is open, changes nothing. */
  if (_opening || (previous_open &&
                   [previous.fileURL.URLByStandardizingPath isEqual:url.URLByStandardizingPath]))
  {
    return;
  }
  _opening = YES;
  /* Opening: should it end the app, the next launch says so instead of opening it again
   * (ROUND6 SAFE-4). A check launch marks only its own copies. */
  if (!_scratch || launcherIsScratch(url)) {
    launcherMarkerSet(url, @"opening");
  }
  /* Should iOS never report the document open, don't refuse files from then on. */
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, int64_t(60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        _opening = NO;
      });
  WMIOSBlendDocument *document = [[[WMIOSBlendDocument alloc] initWithFileURL:url] autorelease];
  document.templateDocument = [_createdURL.URLByStandardizingPath
      isEqual:url.URLByStandardizingPath];
  if (!previous_open) {
    self.document = document;
    return;
  }
  /* A held document asks first (ROUND6 SAFE-2): its work is in no file. */
  if ([previous isKindOfClass:WMIOSBlendDocument.class] &&
      ((WMIOSBlendDocument *)previous).needsAnswerBeforeClosing)
  {
    _opening = NO;
    [(WMIOSBlendDocument *)previous presentHold:YES];
    return;
  }
  /* One file at a time: the current one saves as it closes, a save the person asked for: its
   * failure is said (ROUND6 SAFE-1). */
  if ([previous isKindOfClass:WMIOSBlendDocument.class]) {
    [(WMIOSBlendDocument *)previous prepareToSaveForPerson:NO];
  }
  GHOST_ios_document_window_set_visible(false, true);
  [previous closeWithCompletionHandler:^(BOOL success) {
    if (success) {
      self.document = document;
    }
    else if ([previous isKindOfClass:WMIOSBlendDocument.class] &&
             ((WMIOSBlendDocument *)previous).refused)
    {
      /* Its write was refused, which its own alert says (ROUND5 9D.1): stay, so the person
       * chooses. Asked again, the document closes, as nothing of it is left to save. */
      self->_opening = NO;
      GHOST_ios_document_window_set_visible(true, true);
    }
    else {
      /* The failure path said why, with Save a Copy… and Try Again (ROUND6 SAFE-1): stay on the
       * document, which has not been replaced. */
      self->_opening = NO;
      WM_native_ui_log("document", "open another: the current document could not be saved, kept");
      GHOST_ios_document_window_set_visible(true, true);
    }
  }];
}

/** The document could not be opened: back to the documents, saying why (ROUND6 SAFE-2). */
- (void)openFailed:(UIDocument *)document reason:(NSString *)reason
{
  /* Takes files again at once, not after a minute. */
  _opening = NO;
  NSString *name = document.fileURL.lastPathComponent ?: @"the file";
  WM_native_ui_log("document",
                   [NSString stringWithFormat:@"could not open %@: %@", name, reason].UTF8String);
  if (self.document == document) {
    self.document = nil;
  }
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:[NSString stringWithFormat:@"Could Not Open “%@”", name]
                       message:reason
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
  [wm_apple_ios_top_presenter() presentViewController:alert animated:YES completion:nil];
}

/** Move `source` into the app's own Documents folder, which the browser always shows, under a
 * name not taken yet; nil when it could not be moved. */
static NSURL *launcherMoveToDocuments(NSURL *source)
{
  NSFileManager *files = NSFileManager.defaultManager;
  NSURL *folder =
      [files URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
  if (!folder) {
    return nil;
  }
  NSString *name = source.URLByDeletingPathExtension.lastPathComponent;
  NSString *extension = source.pathExtension;
  NSURL *destination = [folder URLByAppendingPathComponent:source.lastPathComponent];
  for (NSInteger number = 2; [files fileExistsAtPath:destination.path] && number < 10000; number++)
  {
    destination = [folder URLByAppendingPathComponent:[NSString stringWithFormat:@"%@ %ld.%@",
                                                                                 name,
                                                                                 (long)number,
                                                                                 extension]];
  }
  return [files moveItemAtURL:source toURL:destination error:nil] ? destination : nil;
}

/** Save a Copy and Work on That (ROUND6 SAFE-2): the copy placed beside the document by the
 * browser, which lists it, then opened in its place. */
- (void)adoptCopy:(NSURL *)copy nextTo:(NSURL *)next_to
{
  NSURL *temporary = copy.URLByDeletingLastPathComponent;
  if (_scratch) {
    /* A check launch keeps to its own folder (ROUND5 9D.5). */
    NSURL *destination = [launcherScratchFolder() URLByAppendingPathComponent:copy.lastPathComponent];
    NSFileManager *files = NSFileManager.defaultManager;
    [files removeItemAtURL:destination error:nil];
    const BOOL moved = [files moveItemAtURL:copy toURL:destination error:nil];
    [files removeItemAtURL:temporary error:nil];
    WM_native_ui_log("document", moved ? "copy to work on: in the scratch folder" :
                                         "copy to work on: could not be placed");
    if (moved) {
      [self openDocumentAtURL:destination];
    }
    return;
  }
  [self.launchOptions.browserViewController
      importDocumentAtURL:copy
      nextToDocumentAtURL:next_to
                     mode:UIDocumentBrowserImportModeMove
        completionHandler:^(NSURL *destination, NSError *error) {
          if (!destination) {
            /* Where the document is may refuse a new file: the app's own folder never does. */
            destination = launcherMoveToDocuments(copy);
          }
          [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
          if (!destination) {
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:@"Could Not Save a Copy"
                                 message:error.localizedDescription ?:
                                             @"Check available storage and try again."
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                      style:UIAlertActionStyleDefault
                                                    handler:nil]];
            [wm_apple_ios_top_presenter() presentViewController:alert
                                                       animated:YES
                                                     completion:nil];
            return;
          }
          WM_native_ui_log("document",
                           [@"copy to work on: " stringByAppendingString:destination.lastPathComponent]
                               .UTF8String);
          [self openDocumentAtURL:destination];
        }];
}

/** Present Blender's templates; `completion` gets the chosen one, or nil. */
- (void)chooseTemplate:(void (^)(NSString *app_template))completion
{
  [self presentViewController:[self templatePicker:completion] animated:YES completion:nil];
}

/** The template chooser (SwiftUI) as a sheet; `completion` gets the chosen template, or nil. */
- (UIViewController *)templatePicker:(void (^)(NSString *app_template))completion
{
  Class swift_class = NSClassFromString(@"WMIOSSwiftTemplatePicker");
  NSCAssert(swift_class, @"The SwiftUI template picker is missing");
  UIViewController *picker = [[[swift_class alloc]
      initWithTemplates:^NSArray<NSDictionary *> * {
        return launcherTemplates();
      }
      manage:^(NSDictionary *entry, NSString *action, NSString *title, void (^done)(BOOL)) {
        void (^finished)(BOOL) = [[done copy] autorelease];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
          const BOOL success = wm_apple_ios_template_manage(entry[@"id"], action, title);
          dispatch_async(dispatch_get_main_queue(), ^{
            finished(success);
          });
        });
      }
      completion:completion] autorelease];
  picker.modalPresentationStyle = UIModalPresentationFormSheet;
  /* Swiping the sheet away cancels, like Cancel. */
  picker.presentationController.delegate = (id<UIAdaptivePresentationControllerDelegate>)picker;
  return picker;
}

- (void)setDocument:(UIDocument *)document
{
  /* A check launch works in its own copy or in nothing, whatever asks for a document: the system
   * restoring the last one included (seen 2026-11-18: a check launch showed the person's file
   * although the launcher opened none). Its scripts edit, and a document saves itself. */
  if (NSProcessInfo.processInfo.environment[@"PLATYPUS_SCRATCH_DOCUMENT"] != nil && document != nil &&
      !launcherIsScratch(document.fileURL))
  {
    NSLog(@"scratch launch: refused to open %@", document.fileURL.lastPathComponent);
    return;
  }
  /* The launcher starts without a document too, before it reopens the last one. */
  const BOOL closed = self.document != nil && document == nil;
  [super setDocument:document];
  if (document == nil) {
    _opening = NO;
    /* Back in the launcher: the next launch starts there too. Not after a check launch, whose
     * scratch document was never the one to continue in. */
    if (closed && !_scratch) {
      [NSUserDefaults.standardUserDefaults removeObjectForKey:launcher_open_document_key];
    }
    if (closed) {
      launcherMarkerClear("closed");
    }
    GHOST_ios_document_window_set_visible(false, true);
  }
#if defined(APPLE_TARGET_VISIONOS)
  [self updateOrnaments];
#endif
}

- (void)documentDidOpen
{
  [super documentDidOpen];
  _opening = NO;
  NSData *bookmark = [self.document.fileURL bookmarkDataWithOptions:0
                                     includingResourceValuesForKeys:nil
                                                      relativeToURL:nil
                                                              error:nil];
  /* A check's copy is never continued in: the next launch opens the person's document. */
  if (bookmark && !_scratch) {
    [NSUserDefaults.standardUserDefaults setObject:bookmark forKey:launcher_open_document_key];
  }
  /* Blender has loaded the file: show it. Its first frames are part of opening: two seconds on,
   * the session marker says open (ROUND6 SAFE-4). */
  GHOST_ios_document_window_set_visible(true, true);
  UIDocument *opened = [[self.document retain] autorelease];
  [opened retain];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(2 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(),
                 ^{
                   [self documentShown:opened];
                   [opened release];
                 });
#if defined(APPLE_TARGET_VISIONOS)
  [self updateOrnaments];
#endif
  if ([_createdURL.URLByStandardizingPath isEqual:self.document.fileURL.URLByStandardizingPath]) {
    [NSNotificationCenter.defaultCenter postNotificationName:@"BlenderTemplatePresentation"
                                                      object:nil
                                                    userInfo:_createdPresentation];
    [_createdURL release];
    _createdURL = nil;
    [_createdPresentation release];
    _createdPresentation = nil;
  }
}

/** The app ended while a document was open (ROUND6 SAFE-4): say so, with ways on. */
- (void)presentEndedSession
{
  NSDictionary *marker = [[_endedMarker retain] autorelease];
  [_endedMarker release];
  _endedMarker = nil;
  NSDateFormatter *format = [[[NSDateFormatter alloc] init] autorelease];
  format.timeStyle = NSDateFormatterShortStyle;
  format.dateStyle = NSDateFormatterNoStyle;
  NSString *name = marker[@"name"] ?: @"a document";
  NSString *message = [NSString
      stringWithFormat:@"%@ closed unexpectedly while “%@” was %@ (%@).",
                       wm_apple_ios_app_name(),
                       name,
                       [marker[@"phase"] isEqual:@"opening"] ? @"opening" : @"open",
                       [format stringFromDate:marker[@"time"]] ?: @"?"];
  BOOL stale = NO;
  NSURL *url = [marker[@"bookmark"] isKindOfClass:NSData.class] ?
                   [NSURL URLByResolvingBookmarkData:marker[@"bookmark"]
                                             options:0
                                       relativeToURL:nil
                                 bookmarkDataIsStale:&stale
                                               error:nil] :
                   nil;
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"Closed Unexpectedly"
                       message:message
                preferredStyle:UIAlertControllerStyleAlert];
  if (url) {
    [alert addAction:[UIAlertAction actionWithTitle:@"Open Again"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *) {
                                              WM_native_ui_log("launch", "after an unclean end: open again");
                                              [self openDocumentAtURL:url];
                                            }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Open a Copy"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *) {
                                              WM_native_ui_log("launch", "after an unclean end: open a copy");
                                              [self openCopyOf:url];
                                            }]];
    if (_openingEnds >= 2) {
      /* Twice in a row while opening: what loads with every document may be the cause. */
      [alert addAction:[UIAlertAction
                           actionWithTitle:@"Start Without Add-ons and Saved Preferences"
                                     style:UIAlertActionStyleDefault
                                   handler:^(UIAlertAction *) {
                                     WM_native_ui_log("launch",
                                                      "after an unclean end: factory preferences");
                                     GHOST_ios_engine_perform([](blender::bContext *C) {
                                       if (C) {
                                         blender::WM_apple_ios_factory_preferences(C);
                                       }
                                     });
                                     [self openDocumentAtURL:url];
                                   }]];
    }
  }
  [alert addAction:[UIAlertAction actionWithTitle:@"Stay Here"
                                            style:UIAlertActionStyleCancel
                                          handler:^(UIAlertAction *) {
                                            WM_native_ui_log("launch", "after an unclean end: stay here");
                                          }]];
  WM_native_ui_log("launch", [@"said: " stringByAppendingString:message].UTF8String);
  [self presentViewController:alert animated:YES completion:nil];
}

/** A copy of the document beside it, opened instead (ROUND6 SAFE-4): what is on disk, without
 * the auto-save that may be what ended the app. */
- (void)openCopyOf:(NSURL *)url
{
  NSFileManager *files = NSFileManager.defaultManager;
  NSURL *folder = [NSURL
      fileURLWithPath:[NSTemporaryDirectory()
                          stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
  NSString *name = [url.URLByDeletingPathExtension.lastPathComponent
      stringByAppendingString:@" copy.blend"];
  NSURL *copy = [folder URLByAppendingPathComponent:name];
  const BOOL accessing = [url startAccessingSecurityScopedResource];
  const BOOL copied = [files createDirectoryAtURL:folder
                      withIntermediateDirectories:YES
                                       attributes:nil
                                            error:nil] &&
                      [files copyItemAtURL:url toURL:copy error:nil];
  if (accessing) {
    [url stopAccessingSecurityScopedResource];
  }
  if (!copied) {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Could Not Copy"
                         message:[NSString stringWithFormat:@"“%@” could not be copied.",
                                                            url.lastPathComponent]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    return;
  }
  [self adoptCopy:copy nextTo:url];
}

- (void)appDidEnterBackground:(NSNotification *)notification
{
  /* iOS may end a background app at any time: that is a clean end, not one to warn about. */
  launcherMarkerClear("in the background");
}

- (void)appWillEnterForeground:(NSNotification *)notification
{
  if (self.document && !(self.document.documentState & UIDocumentStateClosed) &&
      (!_scratch || launcherIsScratch(self.document.fileURL)))
  {
    launcherMarkerSet(self.document.fileURL, @"open");
  }
}

/** The document has shown for a moment: open, no longer opening. */
- (void)documentShown:(UIDocument *)document
{
  if (self.document == document && !(document.documentState & UIDocumentStateClosed) &&
      (!_scratch || launcherIsScratch(document.fileURL)))
  {
    launcherMarkerSet(document.fileURL, @"open");
  }
}

- (void)sceneWillDeactivate:(NSNotification *)notification
{
  if ([self.document isKindOfClass:WMIOSBlendDocument.class]) {
    [(WMIOSBlendDocument *)self.document saveChangesWithCompletionHandler:nil];
  }
}

/* The front door (ROUND5 9D.2, decision 61). */

/** Blender's app templates by the launcher's, for File › New's items. */
static NSString *launcherTemplateForAppTemplate(NSString *app_template)
{
  /* No template asked for (a key, the menu bar's New…): the person chooses. */
  if (app_template.length == 0) {
    return nil;
  }
  NSDictionary *known = @{
    @"General" : @"general",
    @"Sculpting" : @"sculpt",
    @"2D_Animation" : @"animation-2d",
  };
  NSString *identifier = known[app_template ?: @""];
  for (NSDictionary *entry in launcherTemplates()) {
    if ([entry[@"id"] isEqual:identifier]) {
      return identifier;
    }
  }
  return nil;
}

- (void)documentCommand:(blender::wmDocumentCommand)command argument:(NSString *)argument
{
  using blender::wmDocumentCommand;
  UIViewController *presenter = wm_apple_ios_top_presenter();
  WMIOSBlendDocument *document = [self.document isKindOfClass:WMIOSBlendDocument.class] ?
                                     (WMIOSBlendDocument *)self.document :
                                     nil;
  switch (command) {
    case wmDocumentCommand::New: {
      /* As the menu bar's New… does: the current document saves and closes as the new opens. */
      if (_creating || _opening) {
        /* Never silently: one is being made or opened already. */
        WM_native_ui_log("document", "new: not now, a document is already being made or opened");
        break;
      }
      if (NSString *identifier = launcherTemplateForAppTemplate(argument)) {
        [self createDocumentFromTemplate:identifier presenter:presenter];
      }
      else {
        [self newDocumentFrom:presenter];
      }
      break;
    }
    case wmDocumentCommand::Open: {
      if (argument.length == 0) {
        /* The system's picker; the chosen file opens as its own document. */
        UTType *blend = [UTType typeWithFilenameExtension:@"blend" conformingToType:UTTypeData];
        UIDocumentPickerViewController *picker = [[[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:@[ blend ]
                                asCopy:NO] autorelease];
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        WM_native_ui_log("document", "open: the picker shown");
        [presenter presentViewController:picker animated:YES completion:nil];
        break;
      }
      NSURL *url = [NSURL fileURLWithPath:argument];
      if (_scratch && !launcherIsScratch(url)) {
        /* A check launch opens nothing outside its own folder (ROUND5 9D.5). */
        WM_native_ui_log("document",
                         [@"open not carried out outside the scratch folder: "
                             stringByAppendingString:url.lastPathComponent]
                             .UTF8String);
        break;
      }
      if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) {
        WM_native_ui_log("document", "open: no such file");
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Could Not Open File"
                             message:[NSString stringWithFormat:@"“%@” could not be found.",
                                                                url.lastPathComponent]
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
        break;
      }
      [self openDocumentAtURL:url];
      break;
    }
    case wmDocumentCommand::Revert:
      [document reopen:YES];
      break;
    case wmDocumentCommand::Save:
      [document saveNow];
      break;
    case wmDocumentCommand::SaveAs:
      wm_apple_ios_document_save_as(presenter);
      break;
    case wmDocumentCommand::Reload:
      /* Allow Execution (ROUND6 SAFE-3): the document again with its scripts, continuing from the
       * auto-save Blender has just written. */
      [document reopen:NO];
      break;
    case wmDocumentCommand::Quit:
      /* As ‹ does: the document saves and closes, the documents show. The app stays. */
      if (wm_apple_ios_launcher_can_show_documents()) {
        wm_apple_ios_launcher_show_documents(nil);
      }
      break;
  }
}

/** The template chooser went away without a choice, as its Cancel does. */
- (void)templatePickerDismissed
{
  _creating = NO;
  [_creatingTemplate release];
  _creatingTemplate = nil;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
  if (NSURL *url = urls.firstObject) {
    if (_scratch && !launcherIsScratch(url)) {
      WM_native_ui_log("document", "open not carried out outside the scratch folder");
      return;
    }
    [self openDocumentAtURL:url];
  }
}

/* Document browser. */

- (void)documentBrowser:(UIDocumentBrowserViewController *)browser
    didRequestDocumentCreationWithHandler:
        (void (^)(NSURL *, UIDocumentBrowserImportMode))importHandler
{
  void (^create)(NSString *) = ^(NSString *app_template) {
    if (app_template == nil) {
      importHandler(nil, UIDocumentBrowserImportModeNone);
      return;
    }
    [self->_creatingTemplate release];
    self->_creatingTemplate = [app_template copy];
    wm_apple_ios_document_create(app_template, ^(NSURL *url) {
      [self->_creationSource release];
      self->_creationSource = [url copy];
      if (url) {
        [self backUpCreation:url];
      }
      importHandler(url, url ? UIDocumentBrowserImportModeMove : UIDocumentBrowserImportModeNone);
      if (!url) {
        [self creationFailed:self];
      }
    });
  };
  if ([browser.activeDocumentCreationIntent isEqualToString:launcher_general_intent]) {
    create(@"");
    return;
  }
  [self chooseTemplate:create];
}

- (void)documentBrowser:(UIDocumentBrowserViewController *)browser
    didImportDocumentAtURL:(NSURL *)sourceURL
          toDestinationURL:(NSURL *)destinationURL
{
  [self discardCreationBackup];
  if (_creatingTemplate) {
    [self recordCreatedTemplateAtURL:destinationURL];
  }
  if ([_creationSource isEqual:sourceURL]) {
    [NSFileManager.defaultManager removeItemAtURL:sourceURL.URLByDeletingLastPathComponent
                                            error:nil];
    [_creationSource release];
    _creationSource = nil;
  }
  [self openDocumentAtURL:destinationURL];
}

- (void)documentBrowser:(UIDocumentBrowserViewController *)browser
    failedToImportDocumentAtURL:(NSURL *)documentURL
                          error:(NSError *)error
{
  if (NSURL *kept = [self keepCreationBackup]) {
    [_creationSource release];
    _creationSource = nil;
    [self recordCreatedTemplateAtURL:kept];
    [self openDocumentAtURL:kept];
    return;
  }
  [self creationFailed:self];
}

- (void)documentBrowser:(UIDocumentBrowserViewController *)browser
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)documentURLs
{
  if (documentURLs.firstObject) {
    [self openDocumentAtURL:documentURLs.firstObject];
  }
}

@end

void wm_apple_ios_launcher_new_document(UIViewController *presenter)
{
  blender::WM_apple_ios_launcher_controller();
  [launcher_controller newDocumentFrom:presenter];
}

void wm_apple_ios_launcher_open_failed(UIDocument *document, NSString *reason)
{
  [document retain];
  [reason retain];
  dispatch_async(dispatch_get_main_queue(), ^{
    [launcher_controller openFailed:document reason:reason];
    [document release];
    [reason release];
  });
}

void wm_apple_ios_launcher_adopt_copy(NSURL *copy, NSURL *next_to)
{
  [launcher_controller adoptCopy:copy nextTo:next_to];
}

UIDocument *wm_apple_ios_launcher_document()
{
  return launcher_controller.document;
}

extern "C" NSURL *wm_apple_ios_document_url()
{
  return launcher_controller.document.fileURL;
}

bool wm_apple_ios_launcher_can_show_documents()
{
#if defined(APPLE_TARGET_VISIONOS)
  /* No back action there: the launcher closes the document itself. */
  return launcher_controller.document != nil;
#else
  return launcher_controller.document != nil &&
         launcher_controller.navigationItem.backAction != nil;
#endif
}

/** Close the document, saved or not to be saved, and show the documents. */
static void launcher_close_document(id sender);

void wm_apple_ios_launcher_show_documents(id sender)
{
  UIDocument *document = launcher_controller.document;
  /* A held document's work is in no file: it asks first (ROUND6 SAFE-2). */
  if ([document isKindOfClass:WMIOSBlendDocument.class] &&
      ((WMIOSBlendDocument *)document).needsAnswerBeforeClosing)
  {
    [(WMIOSBlendDocument *)document presentHold:YES];
    return;
  }
  if ([document isKindOfClass:WMIOSBlendDocument.class] && document.hasUnsavedChanges) {
    /* Save first, while Blender's window is still shown for the preview. Never again by itself
     * (ROUND6 SAFE-1): refused, its alert offers to save a copy (ROUND5 9D.1), and asked again
     * the document closes, as nothing of it is left to save; failed or busy, the failure path's
     * alert says why and offers Close Without Saving. */
    [(WMIOSBlendDocument *)document saveForPerson:YES
                                       completion:^(BOOL success) {
                                         if (success) {
                                           launcher_close_document(sender);
                                         }
                                       }];
    return;
  }
  launcher_close_document(sender);
}

static void launcher_close_document(id sender)
{
  UIDocument *document = launcher_controller.document;
  if (document == nil) {
    return;
  }
  NSURL *url = [[document.fileURL retain] autorelease];
  /* Swap Blender's window for a picture of it in the document view, which iOS then shrinks into
   * the document's place in the browser. */
  UIView *view = launcher_controller.view;
  if (UIView *snapshot = (UIView *)GHOST_ios_document_window_snapshot()) {
    snapshot.frame = view.bounds;
    snapshot.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [view addSubview:snapshot];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   ^{
                     [snapshot removeFromSuperview];
                   });
  }
  GHOST_ios_document_window_set_visible(false, false);
#if defined(APPLE_TARGET_VISIONOS)
  if (launcher_controller.navigationItem.backAction == nil) {
    /* Close the document, then show the browser again. */
    [document closeWithCompletionHandler:^(BOOL) {
      launcher_controller.document = nil;
      UIDocumentBrowserViewController *browser =
          launcher_controller.launchOptions.browserViewController;
      if (launcher_controller.presentedViewController == nil &&
          browser.presentingViewController == nil)
      {
        [launcher_controller presentViewController:browser animated:YES completion:nil];
      }
    }];
  }
#endif
  /* The system's back action closes the document and shows the launcher. */
  [launcher_controller.navigationItem.backAction performWithSender:sender target:nil];
  /* Show where the document is, in case the browser is elsewhere. */
  if (url) {
    [launcher_controller.launchOptions.browserViewController revealDocumentAtURL:url
                                                                  importIfNeeded:NO
                                                                      completion:nil];
  }
  /* A check launch leaves the person's document to continue in as it was (seen 2026-11-18: Quit
   * in a check launch dropped it). */
  if (NSProcessInfo.processInfo.environment[@"PLATYPUS_SCRATCH_DOCUMENT"] == nil) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:launcher_open_document_key];
  }
}

UIViewController *wm_apple_ios_top_presenter()
{
  /* The shown window a person's tap would reach: the document's when it is open, the launcher's
   * otherwise. */
  UIWindowScene *scene = launcher_controller.view.window.windowScene;
  UIWindow *shown = nil;
  for (UIWindow *window in scene.windows) {
    if (!window.hidden && (shown == nil || window.isKeyWindow)) {
      shown = window;
    }
  }
  UIViewController *top = shown.rootViewController ?: launcher_controller;
  while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) {
    top = top.presentedViewController;
  }
  return top;
}

/**
 * A check launch's `document …` steps (`Snapshots.swift`, ROUND5 9D.5), only in a check launch
 * and only on files in its scratch folder: `copy <name>` (a fresh copy of the General template),
 * `open <name>`, `stat <name>` (size, date and a hash), `list`, `save` (marked edited and saved
 * now), `reopen` (as the refusal's Reopen Document), `back`; `lock` and `unlock` (the scratch
 * folder read-only and back, so the document cannot be written: ROUND6 SAFE-1), `status` (what the
 * header says and the alert shown, if any); `raise <name>` (a file from a newer Blender) and
 * `answer copy|anyway|readonly` (ROUND6 SAFE-2); `ended [opening|open]` (the session marker as an
 * unexpected end leaves it, ROUND6 SAFE-4); `marker`, `check` and `python <code>` run in Blender,
 * see #WM_apple_ios_document_check_step.
 */
void wm_apple_ios_document_check_step(NSString *step, void (^done)(NSString *answer))
{
  void (^finish)(NSString *) = [[done copy] autorelease];
  void (^say)(NSString *) = ^(NSString *answer) {
    WM_native_ui_log("document", answer.UTF8String);
    finish(answer);
  };
  if (NSProcessInfo.processInfo.environment[@"PLATYPUS_SCRATCH_DOCUMENT"] == nil) {
    say(@"check step refused: not a check launch");
    return;
  }
  NSArray<NSString *> *words = [step componentsSeparatedByString:@" "];
  NSString *verb = words.firstObject ?: @"";
  NSString *rest = words.count > 1 ? [step substringFromIndex:verb.length + 1] : @"";
  const BOOL names_file = [@[ @"copy", @"open", @"stat", @"raise" ] containsObject:verb];
  NSFileManager *files = NSFileManager.defaultManager;
  NSURL *file = names_file && rest.length ?
                    [launcherScratchFolder() URLByAppendingPathComponent:rest] :
                    nil;
  WMIOSBlendDocument *document = [launcher_controller.document
                                     isKindOfClass:WMIOSBlendDocument.class] ?
                                     (WMIOSBlendDocument *)launcher_controller.document :
                                     nil;
  /* Named after the check, so cleaning up finds them and their auto-saves, see
   * #launcherScratchRemove. */
  if (names_file && (!file || !launcherIsScratch(file) || ![rest hasPrefix:launcher_scratch_name])) {
    say([@"check step refused outside the scratch folder: " stringByAppendingString:step]);
    return;
  }
  if ([verb isEqual:@"copy"]) {
    NSURL *seed = nil;
    for (NSDictionary *item in wm_apple_ios_document_templates()) {
      if ([item[@"id"] isEqual:@"general"]) {
        seed = item[@"url"];
      }
    }
    [files removeItemAtURL:file error:nil];
    const BOOL copied = seed && [files copyItemAtURL:seed toURL:file error:nil];
    say([NSString stringWithFormat:@"copy %@: %@", rest, copied ? @"made" : @"failed"]);
  }
  else if ([verb isEqual:@"open"]) {
    [launcher_controller openDocumentAtURL:file];
    say([@"open " stringByAppendingString:rest]);
  }
  else if ([verb isEqual:@"stat"]) {
    NSDictionary *attributes = [files attributesOfItemAtPath:file.path error:nil];
    NSData *data = attributes ? [NSData dataWithContentsOfURL:file] : nil;
    if (!data) {
      say([NSString stringWithFormat:@"stat %@: no such file", rest]);
      return;
    }
    /* FNV-1a over the bytes: enough to see whether a file was written again. */
    uint64_t hash = 14695981039346656037ull;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
      hash = (hash ^ bytes[i]) * 1099511628211ull;
    }
    NSDate *date = attributes[NSFileModificationDate];
    say([NSString stringWithFormat:@"stat %@: %lu bytes, modified %.3f, hash %016llx",
                                   rest,
                                   (unsigned long)data.length,
                                   date.timeIntervalSince1970,
                                   (unsigned long long)hash]);
  }
  else if ([verb isEqual:@"list"]) {
    NSArray *names = [[files contentsOfDirectoryAtPath:launcherScratchFolder().path error:nil]
        sortedArrayUsingSelector:@selector(compare:)];
    say([@"scratch folder: " stringByAppendingString:[names componentsJoinedByString:@", "]]);
  }
  else if ([verb isEqual:@"save"]) {
    if (!document) {
      say(@"save: no document open");
      return;
    }
    [document updateChangeCount:UIDocumentChangeDone];
    [document saveChangesWithCompletionHandler:^(BOOL success) {
      say([NSString stringWithFormat:@"save of %@: %@",
                                     document.fileURL.lastPathComponent,
                                     success          ? @"written" :
                                     document.refused ? @"refused" :
                                                        @"failed"]);
    }];
  }
  else if ([verb isEqual:@"reopen"]) {
    /* As the refusal's Reopen Document: its alert goes, the document's file loads again. */
    UIViewController *top = wm_apple_ios_top_presenter();
    if ([top isKindOfClass:UIAlertController.class]) {
      [top dismissViewControllerAnimated:NO completion:nil];
    }
    [document reopen:NO];
    say([@"reopen " stringByAppendingString:document.fileURL.lastPathComponent ?: @"nothing"]);
  }
  else if ([verb isEqual:@"dismiss"]) {
    /* What a route presented (a picker, the exporter, an alert), as Cancel would. */
    UIViewController *top = wm_apple_ios_top_presenter();
    if (top.presentingViewController) {
      [top.presentingViewController dismissViewControllerAnimated:NO completion:nil];
      if ([NSStringFromClass(top.class) containsString:@"TemplatePicker"]) {
        [launcher_controller templatePickerDismissed];
      }
      say([@"dismissed " stringByAppendingString:NSStringFromClass(top.class)]);
    }
    else {
      say(@"dismiss: nothing presented");
    }
  }
  else if ([verb isEqual:@"raise"]) {
    /* A file from a newer Blender (ROUND6 SAFE-2): an uncompressed file's version raised by 98,
     * as `python bpy.ops.wm.save_as_mainfile(filepath=…, copy=True, compress=False)` writes. */
    NSMutableData *data = [NSMutableData dataWithContentsOfURL:file];
    char *bytes = (char *)data.mutableBytes;
    BOOL raised = NO;
    if (data.length > 17 && memcmp(bytes, "BLENDER", 7) == 0) {
      /* `BLENDER17-01v0501` (format 1) or `BLENDER-v501` (format 0). */
      const int at = bytes[7] == '-' ? 9 : 13;
      const int digits = bytes[7] == '-' ? 3 : 4;
      const std::string version(bytes + at, digits);
      char text[8];
      snprintf(text, sizeof(text), "%0*d", digits, atoi(version.c_str()) + 98);
      memcpy(bytes + at, text, digits);
      raised = [data writeToURL:file atomically:YES];
    }
    say([NSString stringWithFormat:@"raise %@: %@", rest, raised ? @"done" : @"not an uncompressed .blend"]);
  }
  else if ([verb isEqual:@"answer"]) {
    /* The held document's question, answered as a tap would: `copy`, `anyway` or `readonly`. */
    UIViewController *top = wm_apple_ios_top_presenter();
    if ([top isKindOfClass:UIAlertController.class]) {
      [top dismissViewControllerAnimated:NO completion:nil];
    }
    if ([rest isEqual:@"copy"]) {
      [document saveCopyAndWorkOnIt];
    }
    else if ([rest isEqual:@"anyway"] || [rest isEqual:@"readonly"]) {
      [document answerHold:[rest isEqual:@"anyway"] ? 1 : 2 closing:NO];
    }
    say([NSString stringWithFormat:@"answer %@: %@", rest, document ? @"given" : @"no document"]);
  }
  else if ([verb isEqual:@"ended"]) {
    /* The marker as an unexpected end leaves it (ROUND6 SAFE-4): end the app now, and the next
     * check launch must stay in the launcher and say so. */
    if (document) {
      launcherMarkerSet(document.fileURL, rest.length ? rest : @"opening");
    }
    say([NSString stringWithFormat:@"ended: marker %@", document ? @"set" : @"not set, no document"]);
  }
  else if ([verb isEqual:@"lock"] || [verb isEqual:@"unlock"]) {
    /* The folder, not the file: iOS writes beside the file and moves the result into place. */
    const BOOL lock = [verb isEqual:@"lock"];
    const BOOL changed = [files setAttributes:@{NSFilePosixPermissions : @(lock ? 0555 : 0755)}
                                 ofItemAtPath:launcherScratchFolder().path
                                        error:nil];
    say([NSString stringWithFormat:@"%@ the scratch folder: %@", verb, changed ? @"done" : @"failed"]);
  }
  else if ([verb isEqual:@"status"]) {
    UIViewController *top = wm_apple_ios_top_presenter();
    NSString *alert = [top isKindOfClass:UIAlertController.class] ? top.title : nil;
    say([NSString stringWithFormat:@"status: %@; held: %@; alert: %@",
                                   document.status ?: @"saved",
                                   document.held ? @"yes" : document.readOnly ? @"read-only" : @"no",
                                   alert ?: @"none"]);
  }
  else if ([verb isEqual:@"back"]) {
    wm_apple_ios_launcher_show_documents(nil);
    say(@"back to the documents");
  }
  else if ([verb isEqual:@"marker"] || [verb isEqual:@"check"] || [verb isEqual:@"python"]) {
    const std::string text = step.UTF8String;
    /* Owned until it is called: the lambda does not retain it. */
    void (^reply)(NSString *) = [finish copy];
    GHOST_ios_engine_perform([text, reply](blender::bContext *C) {
      const std::string answer = C ? blender::WM_apple_ios_document_check_step(C, text) :
                                     std::string("no engine");
      NSString *result = [[NSString alloc] initWithUTF8String:answer.c_str()];
      dispatch_async(dispatch_get_main_queue(), ^{
        reply(result);
        [reply release];
        [result release];
      });
    });
  }
  else {
    say([@"unknown check step: " stringByAppendingString:step]);
  }
}

/** \} */

namespace blender {

void WM_apple_ios_launcher_document_command(const wmDocumentCommand command,
                                            const std::string &argument)
{
  NSString *value = [NSString stringWithUTF8String:argument.c_str()] ?: @"";
  dispatch_async(dispatch_get_main_queue(), ^{
    [(WMIOSLauncherController *)WM_apple_ios_launcher_controller() documentCommand:command
                                                                         argument:value];
  });
}

void *WM_apple_ios_launcher_controller()
{
  if (launcher_controller == nil) {
    launcher_controller = [[WMIOSLauncherController alloc] initWithDocument:nil];
  }
  return launcher_controller;
}

void WM_apple_ios_document_set_modified(bool modified)
{
  if ([launcher_controller.document isKindOfClass:WMIOSBlendDocument.class]) {
    [(WMIOSBlendDocument *)launcher_controller.document setBlenderModified:modified];
  }
}

void WM_apple_ios_open_url(void *url)
{
  if (launcher_controller.isViewLoaded) {
    [launcher_controller openDocumentAtURL:(NSURL *)url];
    return;
  }
  [launcher_pending_url release];
  launcher_pending_url = [(NSURL *)url retain];
}

}  // namespace blender
