/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */
#import "wm_apple_ios_blend_document.hh"

#include "BKE_blender_version.h"
#include "GHOST_IOSRuntime.hh"
#include "WM_native_ui.h"
#import "wm_apple_ios_launcher.hh"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>

namespace blender {
/* Implemented in wm_files.cc. */
bool WM_apple_ios_document_open(bContext *C,
                                const char *filepath,
                                bool template_document,
                                bool *r_recovered);
bool WM_apple_ios_document_write(
    bContext *C, const char *filepath, bool preview, bool when_idle, bool *r_refused);
bool WM_apple_ios_document_is_loaded();
bool WM_apple_ios_document_copy_write(bContext *C, const char *filepath);
std::string WM_apple_ios_document_template_write(bContext *C,
                                                 const char *filepath,
                                                 const char *preview,
                                                 std::string &attribution);
}  // namespace blender

/**
 * Run `work` on the engine and wait for it. Documents read and write on UIKit's background queues,
 * inside file coordination, and only finish once Blender has.
 */
static bool engine_wait(std::function<bool(blender::bContext *)> work)
{
  struct Wait {
    std::mutex mutex;
    std::condition_variable condition;
    bool done = false, success = false;
  };
  auto wait = std::make_shared<Wait>();
  GHOST_ios_engine_perform([work = std::move(work), wait](blender::bContext *C) {
    const bool success = C && work(C);
    {
      std::lock_guard lock(wait->mutex);
      wait->done = true;
      wait->success = success;
    }
    wait->condition.notify_all();
  });
  std::unique_lock lock(wait->mutex);
  /* Large scenes take a while; never hold the document's queue forever. */
  if (!wait->condition.wait_for(lock, std::chrono::minutes(5), [&] { return wait->done; })) {
    return false;
  }
  return wait->success;
}

@implementation WMIOSBlendDocument
{
  BOOL _blenderModified;
  BOOL _accessing;
  /** Saving was asked for, rather than UIKit's periodic saving while the document is edited. */
  int _saving;
  /** When the document was last written, for saving along the way, see below. */
  CFTimeInterval _lastWrite;
  /** A save along the way is waiting to run. */
  BOOL _alongTheWayScheduled;
  /** The next write is a save along the way. */
  BOOL _alongTheWay;
  /** The file was last written without its preview, which closing the document renders. */
  BOOL _previewStale;
  /** Blender opened the document's newer auto-save, work the document has yet to save. */
  BOOL _recovered;
  /**
   * A write was refused: Blender has another file loaded than this document (ROUND5 9D.1). The
   * document's file is as it was saved, and nothing of it is left to save: what is loaded is not
   * the document's. Until it is reopened.
   */
  BOOL _refused;
  /** The refusal was said, once until the document is reopened. */
  BOOL _refusalShown;
}

- (BOOL)refused
{
  return _refused;
}

- (void)saveChangesWithCompletionHandler:(void (^)(BOOL success))completionHandler
{
  if (!self.hasUnsavedChanges) {
    if (completionHandler) {
      completionHandler(YES);
    }
    return;
  }
  _saving++;
  [super autosaveWithCompletionHandler:^(BOOL success) {
    _saving--;
    if (completionHandler) {
      completionHandler(success);
    }
  }];
}

- (void)autosaveWithCompletionHandler:(void (^)(BOOL success))completionHandler
{
  /* UIKit saves edited documents every so often. Blender would stop to write the file and render
   * its preview, mid-edit: the document saves along the way on its own terms instead, see below.
   * Closing the document or leaving the app saves at once, with the preview. */
  if (_saving == 0 && !(self.documentState & UIDocumentStateClosed)) {
    if (completionHandler) {
      completionHandler(YES);
    }
    return;
  }
  [super autosaveWithCompletionHandler:completionHandler];
}

/** How soon after an edit the document saves along the way, and how often at most, in seconds. */
static const CFTimeInterval document_save_delay = 15.0;
static const CFTimeInterval document_save_interval = 60.0;

/**
 * Save the edited document in place while it stays open, without its preview and never
 * mid-stroke, so the file is never far behind: Blender's own auto-save is the backup, not the
 * only copy. Saves wait for a stroke to end, and come at most once a minute.
 */
- (void)saveAlongTheWay
{
  if (_alongTheWayScheduled) {
    return;
  }
  _alongTheWayScheduled = YES;
  const CFTimeInterval wait = std::max(
      document_save_delay, document_save_interval - (CACurrentMediaTime() - _lastWrite));
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, int64_t(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        _alongTheWayScheduled = NO;
        if ((self.documentState & UIDocumentStateClosed) ||
            !(_blenderModified || [super hasUnsavedChanges]))
        {
          return;
        }
        if (_saving > 0) {
          [self saveAlongTheWay];
          return;
        }
        _saving++;
        _alongTheWay = YES;
        [super autosaveWithCompletionHandler:^(BOOL success) {
          _saving--;
          /* Edited since, or Blender was mid-stroke. */
          if (_blenderModified || !success) {
            [self saveAlongTheWay];
          }
        }];
      });
}

- (void)openWithCompletionHandler:(void (^)(BOOL success))completionHandler
{
  /* Blender opens the file by its path, outside of the document's coordinated read. */
  _accessing = [self.fileURL startAccessingSecurityScopedResource];
  [super openWithCompletionHandler:^(BOOL success) {
    /* Work recovered from the auto-save goes into the document, as an edit would. */
    if (success && _recovered) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [self updateChangeCount:UIDocumentChangeDone];
        [self saveAlongTheWay];
      });
    }
    if (completionHandler) {
      completionHandler(success);
    }
  }];
}

- (void)closeWithCompletionHandler:(void (^)(BOOL success))completionHandler
{
  /* Closing saves, through autosave. */
  _saving++;
  NSURL *url = self.fileURL;
  const BOOL accessing = _accessing;
  _accessing = NO;
  [super closeWithCompletionHandler:^(BOOL success) {
    _saving--;
    if (accessing) {
      [url stopAccessingSecurityScopedResource];
    }
    if (completionHandler) {
      completionHandler(success);
    }
  }];
}

- (BOOL)readFromURL:(NSURL *)url error:(NSError **)outError
{
  /* Blender loads the file now, so the document opens on its scene. */
  const std::string path = url.path.UTF8String ?: "";
  const bool template_document = self.templateDocument;
  auto recovered = std::make_shared<std::atomic<bool>>(false);
  if (engine_wait([path, template_document, recovered](blender::bContext *C) {
        bool r_recovered = false;
        const bool success = blender::WM_apple_ios_document_open(
            C, path.c_str(), template_document, &r_recovered);
        recovered->store(r_recovered);
        return success;
      }))
  {
    _recovered = recovered->load();
    return YES;
  }
  if (outError) {
    *outError = [NSError errorWithDomain:NSCocoaErrorDomain
                                    code:NSFileReadCorruptFileError
                                userInfo:nil];
  }
  return NO;
}

- (id)contentsForType:(NSString *)typeName error:(NSError **)outError
{
  /* Blender writes the file itself, see below. */
  return [NSData data];
}

- (BOOL)writeContents:(id)contents
                  toURL:(NSURL *)url
       forSaveOperation:(UIDocumentSaveOperation)saveOperation
    originalContentsURL:(NSURL *)originalContentsURL
                  error:(NSError **)outError
{
  /* Blender writes the file where UIKit asks, and UIKit moves it into place, so saving needs
   * access to nothing but the document. */
  const std::string path = url.path.UTF8String ?: "";
  const bool along_the_way = _alongTheWay;
  _alongTheWay = NO;
  /* Rendering the preview needs Blender's window on screen, and the app in front. */
  const bool preview = !along_the_way && !GHOST_ios_app_in_background() &&
                       GHOST_ios_document_window_visible();
  auto refused = std::make_shared<std::atomic<bool>>(false);
  if (engine_wait([path, preview, along_the_way, refused](blender::bContext *C) {
        bool r_refused = false;
        const bool written = blender::WM_apple_ios_document_write(
            C, path.c_str(), preview, along_the_way, &r_refused);
        refused->store(r_refused);
        return written;
      }))
  {
    _lastWrite = CACurrentMediaTime();
    _previewStale = !preview;
    WM_native_ui_log("document",
                     [NSString stringWithFormat:@"written %@%@",
                                                along_the_way ? @"along the way" : @"in full",
                                                preview ? @" with its preview" : @""]
                         .UTF8String);
    return YES;
  }
  if (refused->load()) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self writeRefused];
    });
  }
  if (outError) {
    *outError = [NSError errorWithDomain:NSCocoaErrorDomain
                                    code:NSFileWriteUnknownError
                                userInfo:nil];
  }
  return NO;
}

- (BOOL)hasUnsavedChanges
{
  /* Refused: nothing loaded is the document's to save, see #_refused. */
  if (_refused) {
    return NO;
  }
  return _blenderModified || _previewStale || [super hasUnsavedChanges];
}

/**
 * The backstop said (ROUND5 9D.1, decision 62): what is loaded exists nowhere on disk, so it is
 * never dropped without a word. Save a Copy writes it where the person picks; Reopen Document goes
 * back to the document as it was last saved.
 */
- (void)writeRefused
{
  _refused = YES;
  _blenderModified = NO;
  _previewStale = NO;
  [self updateChangeCount:UIDocumentChangeCleared];
  if (_refusalShown) {
    return;
  }
  _refusalShown = YES;
  NSString *name = self.fileURL.lastPathComponent ?: @"the document";
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"Document Not Saved"
                       message:[NSString
                                   stringWithFormat:
                                       @"Another file was loaded into this window (by a script, an "
                                       @"add-on or a command), so saving would have replaced "
                                       @"“%@” with it. Nothing was written. Save a copy of what "
                                       @"is shown, or reopen the document as it was last saved.",
                                       name]
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"Save a Copy…"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *) {
                                            wm_apple_ios_document_save_as(nil);
                                          }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"Reopen Document"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *) {
                                            [self reopen:NO];
                                          }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"Not Now"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  WM_native_ui_log("document", "refusal shown: Save a Copy, Reopen Document, Not Now");
  [wm_apple_ios_top_presenter() presentViewController:alert animated:YES completion:nil];
}

- (void)reopen:(BOOL)revert
{
  /* Blender loads the document's file again, through the document, as when it opened. */
  WM_native_ui_log("document", revert ? "revert" : "reopen");
  [self revertToContentsOfURL:self.fileURL
            completionHandler:^(BOOL success) {
              if (success) {
                _refused = NO;
                _refusalShown = NO;
                _blenderModified = NO;
              }
              WM_native_ui_log("document",
                               success ? "reopened" : "could not be reopened");
            }];
}

- (void)saveNow
{
  if (!self.hasUnsavedChanges) {
    WM_native_ui_log("document", "save: nothing changed since it was saved");
    return;
  }
  [self saveChangesWithCompletionHandler:^(BOOL success) {
    WM_native_ui_log("document", success ? "saved" : "save failed");
  }];
}

- (void)setBlenderModified:(BOOL)modified
{
  /* Blender reports on the way while it loads the file, before the document is open. */
  if (self.documentState & UIDocumentStateClosed) {
    return;
  }
  const BOOL edited = modified && !_blenderModified;
  _blenderModified = modified;
  if (edited) {
    WM_native_ui_log("document", "edited");
    /* Marks the document edited, as any edit of a document does. */
    [self updateChangeCount:UIDocumentChangeDone];
    [self saveAlongTheWay];
  }
}

@end

/** Present the system's exporter for a copy of \a url, where the person picks. */
static void presentExporter(NSURL *url, UIViewController *presenter)
{
  UIDocumentPickerViewController *picker = [[[UIDocumentPickerViewController alloc]
      initForExportingURLs:@[ url ]
                    asCopy:YES] autorelease];
  WM_native_ui_log("document", "save as: the exporter shown");
  [presenter ?: wm_apple_ios_top_presenter() presentViewController:picker
                                                          animated:YES
                                                        completion:nil];
}

void wm_apple_ios_document_save_as(UIViewController *presenter)
{
  WMIOSBlendDocument *document = (WMIOSBlendDocument *)wm_apple_ios_launcher_document();
  if (![document isKindOfClass:WMIOSBlendDocument.class]) {
    return;
  }
  [presenter retain];
  NSString *name = document.fileURL.lastPathComponent ?: @"Untitled.blend";
  NSURL *documentURL = [[document.fileURL copy] autorelease];
  [document retain];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    /* What is loaded is the document's: save it, then export the file, as Files apps do. Not the
     * document's (refused, ROUND5 9D.1): what is loaded exists nowhere on disk, so write it as a
     * copy and export that, leaving the document as it is. */
    const bool own = engine_wait(
        [](blender::bContext *) { return blender::WM_apple_ios_document_is_loaded(); });
    if (own) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [document saveToURL:documentURL
              forSaveOperation:UIDocumentSaveForOverwriting
             completionHandler:^(BOOL) {
               presentExporter(documentURL, presenter);
               [presenter release];
               [document release];
             }];
      });
      return;
    }
    NSString *folder = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[@"save-copy-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:folder
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    NSURL *copy = [NSURL fileURLWithPath:[folder stringByAppendingPathComponent:name]];
    const std::string path = copy.path.UTF8String;
    const bool written = engine_wait([path](blender::bContext *C) {
      return blender::WM_apple_ios_document_copy_write(C, path.c_str());
    });
    dispatch_async(dispatch_get_main_queue(), ^{
      if (written) {
        presentExporter(copy, presenter);
      }
      else {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Could Not Save a Copy"
                             message:@"Check available storage and try again."
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [presenter ?: wm_apple_ios_top_presenter() presentViewController:alert
                                                                animated:YES
                                                              completion:nil];
      }
      [presenter release];
      [document release];
    });
  });
}

static NSURL *personalTemplatesURL()
{
  NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                        inDomains:NSUserDomainMask]
                       .firstObject;
  return [support URLByAppendingPathComponent:@"BlenderTemplates" isDirectory:YES];
}

static BOOL templateVersionSupported(id minimum)
{
  if (![minimum isKindOfClass:NSArray.class] || [minimum count] != 3) {
    return NO;
  }
  for (id component in minimum) {
    if (![component isKindOfClass:NSNumber.class] || [component integerValue] < 0) {
      return NO;
    }
  }
  /* Blender's version, as compiled: a template needs Blender, and the app's own version
   * (its short version string, ROUND5 8A) is a different number. */
  const NSInteger current[3] = {
      BLENDER_VERSION / 100, BLENDER_VERSION % 100, BLENDER_VERSION_PATCH};
  for (NSUInteger i = 0; i < 3; i++) {
    const NSInteger available = current[i];
    const NSInteger required = [minimum[i] integerValue];
    if (required != available) {
      return required < available;
    }
  }
  return YES;
}

NSArray<NSDictionary *> *wm_apple_ios_document_templates()
{
  NSURL *assets = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Assets"];
  NSArray *versions = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:assets.path
                                                                         error:nil]
      sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
  NSMutableArray *folders = [NSMutableArray array];
  for (NSString *version in versions.reverseObjectEnumerator) {
    [folders addObject:[assets URLByAppendingPathComponent:[version stringByAppendingPathComponent:
                                                                        @"datafiles/templates"]]];
  }
  NSURL *personal = personalTemplatesURL();
  for (NSString *name in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:personal.path
                                                                            error:nil]
           sortedArrayUsingSelector:@selector(localizedStandardCompare:)])
  {
    [folders addObject:[personal URLByAppendingPathComponent:name]];
  }
  NSMutableArray *templates = [NSMutableArray array];
  NSMutableSet *identifiers = [NSMutableSet set];
  for (NSURL *folder in folders) {
    NSData *data = [NSData
        dataWithContentsOfURL:[folder URLByAppendingPathComponent:@"manifest.json"]];
    NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data
                                                                    options:0
                                                                      error:nil] :
                                    nil;
    if (![manifest isKindOfClass:NSDictionary.class] ||
        ![manifest[@"version"] isKindOfClass:NSNumber.class] ||
        [manifest[@"version"] integerValue] != 1 ||
        ![manifest[@"templates"] isKindOfClass:NSArray.class])
    {
      continue;
    }
    for (NSDictionary *item in manifest[@"templates"]) {
      if (![item isKindOfClass:NSDictionary.class]) {
        continue;
      }
      NSString *identifier = item[@"id"], *file = item[@"file"], *preview = item[@"preview"];
      if (![identifier isKindOfClass:NSString.class] || !identifier.length ||
          [identifiers containsObject:identifier] ||
          ![item[@"title"] isKindOfClass:NSString.class] || ![item[@"title"] length] ||
          !templateVersionSupported(item[@"minimumBlender"]) ||
          ![item[@"presentation"] isKindOfClass:NSDictionary.class] ||
          ![item[@"presentation"][@"timeline"] isKindOfClass:NSNumber.class] ||
          ![file isKindOfClass:NSString.class] || ![file isEqual:file.lastPathComponent] ||
          ![file.pathExtension isEqual:@"blend"] || ![preview isKindOfClass:NSString.class] ||
          ![preview isEqual:preview.lastPathComponent] || ![preview.pathExtension isEqual:@"png"])
      {
        continue;
      }
      NSURL *seed = [folder URLByAppendingPathComponent:file];
      NSURL *image = [folder URLByAppendingPathComponent:preview];
      if (![seed checkResourceIsReachableAndReturnError:nil] ||
          ![image checkResourceIsReachableAndReturnError:nil])
      {
        continue;
      }
      NSMutableDictionary *entry = [[item mutableCopy] autorelease];
      NSDictionary *credit = item[@"attribution"];
      BOOL validCredit = [credit isKindOfClass:NSDictionary.class];
      if (validCredit) {
        for (NSString *key in
             @[ @"title", @"author", @"license", @"licenseURL", @"sourceURL", @"changes" ])
        {
          if (![credit[key] isKindOfClass:NSString.class] || ![credit[key] length]) {
            validCredit = NO;
            break;
          }
        }
      }
      if (!validCredit) {
        [entry removeObjectForKey:@"attribution"];
      }
      entry[@"url"] = seed;
      entry[@"previewURL"] = image;
      entry[@"personal"] = @([folder.URLByDeletingLastPathComponent isEqual:personal]);
      [templates addObject:entry];
      [identifiers addObject:identifier];
    }
  }
  return templates;
}

static BOOL writeTemplateManifest(NSDictionary *entry, NSURL *folder)
{
  NSData *data = [NSJSONSerialization dataWithJSONObject:@{
    @"version" : @1,
    @"templates" : @[ entry ]
  }
                                                 options:NSJSONWritingPrettyPrinted
                                                   error:nil];
  return [data writeToURL:[folder URLByAppendingPathComponent:@"manifest.json"]
                  options:NSDataWritingAtomic
                    error:nil];
}

void wm_apple_ios_template_save(NSString *title,
                                NSDictionary *presentation,
                                void (^completion)(NSString *error))
{
  NSString *identifier = [@"user." stringByAppendingString:NSUUID.UUID.UUIDString];
  NSURL *folder = [[personalTemplatesURL() URLByAppendingPathComponent:identifier] retain];
  NSDictionary *entry = [@{
    @"id" : identifier,
    @"title" : title,
    @"file" : @"scene.blend",
    @"preview" : @"preview.png",
    @"minimumBlender" : @[ @5, @1, @0 ],
    @"presentation" : @{@"timeline" : @([presentation[@"timeline"] boolValue])}
  } retain];
  void (^done)(NSString *) = [completion copy];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    struct Result {
      std::mutex mutex;
      std::string error = "Could not save the template.";
      std::string attribution;
    };
    auto result = std::make_shared<Result>();
    const std::string path = [[folder URLByAppendingPathComponent:@"scene.blend"] path].UTF8String;
    const std::string preview =
        [[folder URLByAppendingPathComponent:@"preview.png"] path].UTF8String;
    BOOL success = [NSFileManager.defaultManager createDirectoryAtURL:folder
                                          withIntermediateDirectories:YES
                                                           attributes:nil
                                                                error:nil];
    if (success) {
      success = engine_wait([path, preview, result](blender::bContext *C) {
        std::string credit;
        std::string error = blender::WM_apple_ios_document_template_write(
            C, path.c_str(), preview.c_str(), credit);
        std::lock_guard lock(result->mutex);
        result->error = error;
        result->attribution = credit;
        return error.empty();
      });
    }
    if (success) {
      NSMutableDictionary *metadata = [[entry mutableCopy] autorelease];
      std::string credit;
      {
        std::lock_guard lock(result->mutex);
        credit = result->attribution;
      }
      NSData *data = [NSData dataWithBytes:credit.data() length:credit.size()];
      NSDictionary *attribution = [NSJSONSerialization JSONObjectWithData:data
                                                                  options:0
                                                                    error:nil];
      if ([attribution isKindOfClass:NSDictionary.class] && attribution.count) {
        metadata[@"attribution"] = attribution;
      }
      success = writeTemplateManifest(metadata, folder);
    }
    std::string error;
    {
      std::lock_guard lock(result->mutex);
      error = result->error;
    }
    NSString *message = success       ? nil :
                        error.empty() ? @"Could not save the template." :
                                        [NSString stringWithUTF8String:error.c_str()];
    if (!success) {
      [NSFileManager.defaultManager removeItemAtURL:folder error:nil];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      done(message);
      [done release];
      [entry release];
      [folder release];
    });
  });
}

BOOL wm_apple_ios_template_manage(NSString *identifier, NSString *action, NSString *title)
{
  for (NSDictionary *entry in wm_apple_ios_document_templates()) {
    if (![entry[@"id"] isEqual:identifier]) {
      continue;
    }
    NSURL *folder = [entry[@"url"] URLByDeletingLastPathComponent];
    if ([action isEqual:@"delete"]) {
      return [entry[@"personal"] boolValue] && [NSFileManager.defaultManager removeItemAtURL:folder
                                                                                       error:nil];
    }
    NSMutableDictionary *metadata = [[entry mutableCopy] autorelease];
    [metadata removeObjectsForKeys:@[ @"url", @"previewURL", @"personal" ]];
    if ([action isEqual:@"rename"]) {
      if (![entry[@"personal"] boolValue] || !title.length) {
        return NO;
      }
      metadata[@"title"] = title;
      return writeTemplateManifest(metadata, folder);
    }
    if ([action isEqual:@"duplicate"]) {
      NSString *newID = [@"user." stringByAppendingString:NSUUID.UUID.UUIDString];
      NSURL *destination = [personalTemplatesURL() URLByAppendingPathComponent:newID];
      NSFileManager *files = NSFileManager.defaultManager;
      metadata[@"id"] = newID;
      metadata[@"title"] = [entry[@"title"] stringByAppendingString:@" Copy"];
      BOOL success = [files createDirectoryAtURL:destination
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil] &&
                     [files copyItemAtURL:entry[@"url"]
                                    toURL:[destination URLByAppendingPathComponent:entry[@"file"]]
                                    error:nil] &&
                     [files
                         copyItemAtURL:entry[@"previewURL"]
                                 toURL:[destination URLByAppendingPathComponent:entry[@"preview"]]
                                 error:nil] &&
                     writeTemplateManifest(metadata, destination);
      if (!success) {
        [files removeItemAtURL:destination error:nil];
      }
      return success;
    }
  }
  return NO;
}

void wm_apple_ios_document_create(NSString *identifier, void (^completion)(NSURL *url))
{
  NSDictionary *selected = nil;
  for (NSDictionary *item in wm_apple_ios_document_templates()) {
    if ([item[@"id"] isEqual:identifier.length ? identifier : @"general"]) {
      selected = item;
      break;
    }
  }
  if (!selected) {
    completion(nil);
    return;
  }
  NSURL *seed = [selected[@"url"] retain];
  NSString *folder = [[NSTemporaryDirectory()
      stringByAppendingPathComponent:NSUUID.UUID.UUIDString] copy];
  NSURL *url = [[NSURL fileURLWithPath:[folder stringByAppendingPathComponent:@"Untitled.blend"]]
      retain];
  void (^done)(NSURL *) = [[completion copy] autorelease];
  [done retain];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSFileManager *files = NSFileManager.defaultManager;
    const BOOL success = [files createDirectoryAtPath:folder
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil] &&
                         [files copyItemAtURL:seed toURL:url error:nil];
    if (success) {
      /* A copy keeps the template's dates: date it now, so the new document sorts as the newest
       * in the browser rather than among old files. */
      NSDate *now = [NSDate date];
      [files setAttributes:@{NSFileCreationDate : now, NSFileModificationDate : now}
              ofItemAtPath:url.path
                     error:nil];
    }
    else {
      [files removeItemAtPath:folder error:nil];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      done(success ? url : nil);
      [seed release];
      [folder release];
      [url release];
      [done release];
    });
  });
}
