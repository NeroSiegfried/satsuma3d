/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */
#import "wm_apple_ios_launcher.hh"
#import "wm_apple_ios_blend_document.hh"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "WM_apple_ios.hh"

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
    _base = [CAGradientLayer layer];
    _orange = [CAGradientLayer layer];
    _blue = [CAGradientLayer layer];
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
  NSString *prefix = [launcher_scratch_name stringByAppendingString:@"_"];
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
  NSString *folder = launcherScratchFolder().URLByStandardizingPath.URLByResolvingSymlinksInPath.path;
  NSString *path = url.URLByStandardizingPath.URLByResolvingSymlinksInPath.path;
  return path && [path hasPrefix:[folder stringByAppendingString:@"/"]];
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
    : UIDocumentViewController <UIDocumentBrowserViewControllerDelegate>
- (void)openDocumentAtURL:(NSURL *)url;
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
  if (url == nil && !_scratch) {
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

- (void)dealloc
{
  [NSNotificationCenter.defaultCenter removeObserver:self];
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
  /* One file at a time: the current one saves as it closes. */
  GHOST_ios_document_window_set_visible(false, true);
  [previous closeWithCompletionHandler:^(BOOL success) {
    if (success) {
      self.document = document;
    }
    else {
      self->_opening = NO;
      UIAlertController *alert = [UIAlertController
          alertControllerWithTitle:@"Could Not Save Document"
                           message:
                               @"The current document could not be saved. It has not been "
                               @"replaced."
                    preferredStyle:UIAlertControllerStyleAlert];
      [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                style:UIAlertActionStyleDefault
                                              handler:^(UIAlertAction *) {
                                                GHOST_ios_document_window_set_visible(true, true);
                                              }]];
      [self presentViewController:alert animated:YES completion:nil];
    }
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
    /* Back in the launcher: the next launch starts there too. */
    if (closed) {
      [NSUserDefaults.standardUserDefaults removeObjectForKey:launcher_open_document_key];
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
  /* Blender has loaded the file: show it. */
  GHOST_ios_document_window_set_visible(true, true);
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

- (void)sceneWillDeactivate:(NSNotification *)notification
{
  if ([self.document isKindOfClass:WMIOSBlendDocument.class]) {
    [(WMIOSBlendDocument *)self.document saveChangesWithCompletionHandler:nil];
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

void wm_apple_ios_launcher_show_documents(id sender)
{
  UIDocument *document = launcher_controller.document;
  if ([document isKindOfClass:WMIOSBlendDocument.class] && document.hasUnsavedChanges) {
    /* Save first, while Blender's window is still shown for the preview. */
    [(WMIOSBlendDocument *)document saveChangesWithCompletionHandler:^(BOOL) {
      wm_apple_ios_launcher_show_documents(sender);
    }];
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
  [NSUserDefaults.standardUserDefaults removeObjectForKey:launcher_open_document_key];
}

/** \} */

namespace blender {

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
