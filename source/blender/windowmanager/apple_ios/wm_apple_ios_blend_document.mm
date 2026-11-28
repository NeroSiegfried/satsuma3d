/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */
#import "wm_apple_ios_blend_document.hh"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "BKE_blender_version.h"
#include "GHOST_IOSDocumentPicker.hh"
#include "GHOST_IOSRuntime.hh"
#include "WM_document_command.hh"
#include "WM_native_ui.h"
#import "wm_apple_ios_launcher.hh"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace blender {
/* Implemented in wm_files.cc. */
bool WM_apple_ios_document_open(bContext *C,
                                const char *filepath,
                                bool template_document,
                                wmDocumentOpened &r_opened);
wmDocumentWrite WM_apple_ios_document_write(
    bContext *C, const char *filepath, bool preview, bool when_idle, std::string &r_error);
bool WM_apple_ios_document_is_loaded();
bool WM_apple_ios_document_set_aside(bContext *C, const char *why);
bool WM_apple_ios_document_copy_write(bContext *C,
                                      const char *filepath,
                                      bool holds_work,
                                      std::string &r_error);
std::string WM_apple_ios_document_template_write(bContext *C,
                                                 const char *filepath,
                                                 const char *preview,
                                                 std::string &attribution);
/* Implemented in wm_apple_ios_document.cc (ROUND6 FILES-3, FILES-5). */
std::string WM_apple_ios_document_external(bContext *C);
int WM_apple_ios_document_pack_external(bContext *C);
void WM_apple_ios_import_pending_run(bContext *C);
std::vector<std::string> WM_apple_ios_document_neighbours_reload(
    bContext *C, const std::vector<std::string> &unreadable);
}  // namespace blender

/**
 * Run `work` on the engine and wait for it. Documents read and write on UIKit's background queues,
 * inside file coordination, and only finish once Blender has. `r_timed_out`: Blender did not get
 * to it in five minutes, busy rather than failed (ROUND6 SAFE-1).
 */
static bool engine_wait(std::function<bool(blender::bContext *)> work, bool *r_timed_out = nullptr)
{
  if (r_timed_out) {
    *r_timed_out = false;
  }
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
    if (r_timed_out) {
      *r_timed_out = true;
    }
    return false;
  }
  return wait->success;
}

bool wm_apple_ios_document_set_aside_wait(const char *why)
{
  const std::string reason = why;
  bool timed_out = false;
  const bool kept = engine_wait(
      [reason](blender::bContext *C) {
        return blender::WM_apple_ios_document_set_aside(C, reason.c_str());
      },
      &timed_out);
  if (timed_out) {
    WM_native_ui_log("document",
                     (std::string("work not set aside (") + reason +
                      "): the engine did not get to it in five minutes")
                         .c_str());
  }
  return kept;
}

static void writeFreshCopy(NSString *name,
                           UIViewController *presenter,
                           BOOL holds_work,
                           void (^done)(NSURL *url));
@class WMIOSBlendDocument;
static void wm_apple_ios_document_file_now_go(WMIOSBlendDocument *document,
                                              NSURL *documentURL,
                                              NSString *name,
                                              UIViewController *presenter,
                                              void (^finish)(NSURL *));

/** One folder pick, for the folder beside a document (ROUND6 FILES-3). */
@interface WMIOSFolderGrant : NSObject <UIDocumentPickerDelegate>
@property(nonatomic, copy) void (^completion)(NSURL *url);
+ (void)chooseFolder:(NSString *)folder completion:(void (^)(NSURL *url))completion;
@end

@implementation WMIOSFolderGrant
static WMIOSFolderGrant *folder_grant_shown = nil;

+ (void)chooseFolder:(NSString *)folder completion:(void (^)(NSURL *url))completion
{
  UIViewController *presenter = wm_apple_ios_top_presenter();
  if (!presenter || folder_grant_shown) {
    completion(nil);
    return;
  }
  WMIOSFolderGrant *grant = [[WMIOSFolderGrant alloc] init];
  grant.completion = completion;
  folder_grant_shown = grant; /* Owned until it finishes. */
  UIDocumentPickerViewController *picker = [[[UIDocumentPickerViewController alloc]
      initForOpeningContentTypes:@[ UTTypeFolder ]
                          asCopy:NO] autorelease];
  picker.delegate = grant;
  picker.directoryURL = [NSURL fileURLWithPath:folder isDirectory:YES];
  [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)finish:(NSURL *)url
{
  void (^completion)(NSURL *) = [[self.completion retain] autorelease];
  self.completion = nil;
  if (folder_grant_shown == self) {
    folder_grant_shown = nil;
    [self autorelease];
  }
  if (completion) {
    completion(url);
  }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
  [self finish:urls.firstObject];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
  [self finish:nil];
}

- (void)dealloc
{
  [_completion release];
  [super dealloc];
}
@end

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
  /**
   * Why the last write failed, in Blender's words; nil once a write succeeds (ROUND6 SAFE-1). The
   * header says "Not saved" meanwhile.
   */
  NSString *_failure;
  /** The failure last said in an alert: saving along the way says each cause once. */
  NSString *_failureShown;
  /** The last write waited five minutes for Blender and gave up: busy, not failed. */
  BOOL _busy;
  /** Saving along the way failed this many times in a row: it waits longer each time. */
  int _failures;
  /** The person asked for this save (Save, Try Again, ‹, opening another): its failure is said
   * every time, not once per cause. */
  BOOL _explicitSave;
  /** ‹ waits on this save: its alert offers to close without saving. */
  BOOL _closeRequested;
  /** The person chose Close Without Saving: nothing is left to save. */
  BOOL _discard;
  /** The outcome of the write in progress was said by #writeContents, not left to #handleError. */
  BOOL _outcomeSaid;
  /** The alert of the failure path, while it shows: one at a time. */
  UIAlertController *_problemAlert;
  /**
   * Why the document is held (ROUND6 SAFE-2, decision R6-2): Blender's Save would ask before
   * overwriting it. Nothing is written until the person answers once. nil when nothing.
   */
  NSString *_holdTitle;
  NSString *_holdReason;
  /** Only a new file may be written. */
  BOOL _holdCopyOnly;
  /** The answer: 0 none yet, 1 Save Here Anyway, 2 Keep Read-Only. */
  int _holdAnswer;
  /** The question was asked at the first edit; then only at Save, closing, or a tap. */
  BOOL _holdAsked;
  UIAlertController *_holdAlert;
  /** Why the file could not be opened, in Blender's words, for the launcher. */
  NSString *_openProblem;
  /** Recovered work not yet taken or declined (ROUND6 SAFE-5): nothing is written meanwhile. */
  BOOL _recoveryPending;
  /** When the recovered auto-save was written. */
  NSDate *_recoveredTime;
  UIAlertController *_recoveryAlert;
  /** Files beside it that could not be read as it opened, and the folder to ask for (ROUND6
   * FILES-3). */
  std::vector<std::string> _unreadable;
  NSString *_unreadableFolder;
  /** Tries left to say so while another question is on screen. */
  int _neighboursTries;
}

- (void)dealloc
{
  [_failure release];
  [_failureShown release];
  [_problemAlert release];
  [_holdTitle release];
  [_holdReason release];
  [_holdAlert release];
  [_openProblem release];
  [_recoveredTime release];
  [_recoveryAlert release];
  [_unreadableFolder release];
  [super dealloc];
}

- (BOOL)refused
{
  return _refused;
}

/* -------------------------------------------------------------------- */
/** \name The failure path (ROUND6 SAFE-1)
 *
 * Every write of the document ends in #writeContents or, for what UIKit does around it (moving
 * the written file into place), in #handleError:userInteractionPermitted:. Both lead here, so
 * no caller can drop a failure: an alert with Blender's reason and a way on, once per cause for
 * saving along the way, every time for a save the person asked for; "Not saved" in the header
 * until a write succeeds.
 * \{ */

- (NSString *)name
{
  return self.fileURL.lastPathComponent ?: @"The document";
}

- (NSString *)status
{
  if (_discard || _refused) {
    return nil;
  }
  if (self.held) {
    return [_holdTitle stringByAppendingString:@": not saved"];
  }
  if (self.readOnly) {
    return @"Read-only: not saved";
  }
  if (_failure) {
    return @"Not saved";
  }
  if (_busy) {
    return @"Not saved yet";
  }
  return nil;
}

- (void)statusTapped
{
  if (self.held || self.readOnly) {
    [self presentHold:NO];
  }
  else if (_failure) {
    [_failureShown release];
    _failureShown = nil;
    _explicitSave = YES;
    [self saveFailed:[[_failure retain] autorelease]];
    _explicitSave = NO;
  }
  else if (_busy) {
    [self saveNow];
  }
}

/** Whether Save As and Share may save the document in place before handing on its file. */
- (BOOL)canWriteInPlace
{
  return !_refused && !_discard && !self.held && !self.readOnly;
}

- (void)prepareToSaveForPerson:(BOOL)closing
{
  _explicitSave = YES;
  _closeRequested = closing;
}

- (void)saveForPerson:(BOOL)closing completion:(void (^)(BOOL success))completion
{
  [self prepareToSaveForPerson:closing];
  void (^done)(BOOL) = [[completion copy] autorelease];
  [self saveChangesWithCompletionHandler:^(BOOL success) {
    /* After the outcome is said, which #writeContents queued before UIKit finished. */
    dispatch_async(dispatch_get_main_queue(), ^{
      _explicitSave = NO;
      if (done) {
        done(success);
      }
    });
  }];
}

- (void)writeSucceeded
{
  if (_failure || _busy) {
    WM_native_ui_log("document", "saved again after a failed save");
  }
  /* What the failure's alert says is no longer true, however the save came about (saving along the
   * way, Save, closing): it goes (device round: it stayed up over a document that had saved). */
  if (_problemAlert.presentingViewController && !_problemAlert.isBeingDismissed) {
    WM_native_ui_log("document", "save problem alert taken down: saved since");
    [_problemAlert.presentingViewController dismissViewControllerAnimated:YES completion:nil];
  }
  [_problemAlert release];
  _problemAlert = nil;
  [_failure release];
  _failure = nil;
  [_failureShown release];
  _failureShown = nil;
  _busy = NO;
  _failures = 0;
}

- (void)writeOutcome:(NSString *)outcome reason:(NSString *)reason
{
  /* Only a write that did not succeed has said all there is: after Blender wrote, UIKit can still
   * fail to move the file into place (a read-only folder; seen on the iPad, a save "failed" with
   * no word), and that failure is #handleError's to say. */
  _outcomeSaid = ![outcome isEqual:@"written"];
  if ([outcome isEqual:@"written"]) {
    [self writeSucceeded];
  }
  else if ([outcome isEqual:@"busy"]) {
    [self saveBusy];
  }
  else if ([outcome isEqual:@"failed"]) {
    [self saveFailed:reason];
  }
  /* Refused: its own alert, see #writeRefused. Deferred: saving along the way waits for the
   * stroke to end, as Blender's auto-save does; not a failure. */
}

- (void)handleError:(NSError *)error userInteractionPermitted:(BOOL)userInteractionPermitted
{
  /* Never UIKit's silence: what it could not do around a write (moving the file into place, a
   * vanished or read-only location) is a failure like any other. Opening has its own path. */
  NSError *problem = [[error retain] autorelease];
  dispatch_async(dispatch_get_main_queue(), ^{
    if ([self isOpenProblem:problem]) {
      return;
    }
    if (_outcomeSaid) {
      _outcomeSaid = NO;
      return;
    }
    NSString *reason = problem.localizedFailureReason ?: problem.localizedDescription;
    WM_native_ui_log("document", [@"save problem from iOS: " stringByAppendingString:reason ?: @"?"]
                                     .UTF8String);
    [self saveFailed:reason];
  });
  [self finishedHandlingError:error recovered:NO];
}

/** An error of reading the file: said where the document opens, not here. */
- (BOOL)isOpenProblem:(NSError *)error
{
  return [error.userInfo[@"WMIOSDocumentOutcome"] isEqual:@"open"];
}

- (void)saveFailed:(NSString *)reason
{
  NSString *text = reason.length ? reason : @"The file could not be written.";
  [_failure release];
  _failure = [text copy];
  _busy = NO;
  WM_native_ui_log("document", [@"save failed: " stringByAppendingString:text].UTF8String);
  if (!_explicitSave && [_failureShown isEqual:text]) {
    /* Said already: saving along the way keeps trying, more slowly, see #saveAlongTheWay. */
    return;
  }
  [_failureShown release];
  _failureShown = [text copy];
  [self presentProblem:[NSString stringWithFormat:@"“%@” could not be saved", self.name]
               message:text
              tryAgain:YES];
}

- (void)saveBusy
{
  _busy = YES;
  WM_native_ui_log("document", "save waited five minutes for the engine: busy, not saved yet");
  if (!_explicitSave) {
    return;
  }
  [self presentProblem:[NSString stringWithFormat:@"%@ is busy, not saved yet",
                                                  wm_apple_ios_app_name()]
               message:[NSString stringWithFormat:@"“%@” is saved when %@ has finished what it "
                                                  @"is doing.",
                                                  self.name,
                                                  wm_apple_ios_app_name()]
              tryAgain:YES];
}

/** The failure path's alert: Save a Copy…, Try Again, Not Now; Close Without Saving when ‹ waits
 * on it. Never a second over the first. */
- (void)presentProblem:(NSString *)title message:(NSString *)message tryAgain:(BOOL)try_again
{
  if (_problemAlert.presentingViewController) {
    WM_native_ui_log("document", "save problem: its alert shows already");
    return;
  }
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:title
                       message:message
                preferredStyle:UIAlertControllerStyleAlert];
  const BOOL closing = _closeRequested;
  [alert addAction:[UIAlertAction actionWithTitle:@"Save a Copy…"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *) {
                                            _closeRequested = NO;
                                            wm_apple_ios_document_save_as(nil);
                                          }]];
  if (try_again) {
    [alert addAction:[UIAlertAction actionWithTitle:@"Try Again"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *) {
                                              if (closing) {
                                                wm_apple_ios_launcher_show_documents(nil);
                                              }
                                              else {
                                                [self saveNow];
                                              }
                                            }]];
  }
  if (closing) {
    [alert addAction:[UIAlertAction actionWithTitle:@"Close Without Saving"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *) {
                                              [self closeWithoutSaving];
                                            }]];
  }
  [alert addAction:wm_apple_ios_cancel_action(@"Not Now", ^(UIAlertAction *) {
    _closeRequested = NO;
  })];
  [_problemAlert release];
  _problemAlert = [alert retain];
  WM_native_ui_log("document",
                   [NSString stringWithFormat:@"save problem shown: %@%@", title,
                                              closing ? @" (with Close Without Saving)" : @""]
                       .UTF8String);
  wm_apple_ios_present_alert(nil, alert);
}

- (void)closeWithoutSaving
{
  /* Blender's auto-save keeps the work, which the next open offers back. */
  WM_native_ui_log("document", "closed without saving, as asked");
  _discard = YES;
  _closeRequested = NO;
  _blenderModified = NO;
  _previewStale = NO;
  [self updateChangeCount:UIDocumentChangeCleared];
  wm_apple_ios_launcher_show_documents(nil);
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Recovered work (ROUND6 SAFE-5, decision R6-4)
 * \{ */

- (void)presentRecovered
{
  if (!_recoveryPending || _recoveryAlert.presentingViewController) {
    return;
  }
  NSDateFormatter *format = [[[NSDateFormatter alloc] init] autorelease];
  format.timeStyle = NSDateFormatterShortStyle;
  format.dateStyle = [NSCalendar.currentCalendar isDateInToday:_recoveredTime] ?
                         NSDateFormatterNoStyle :
                         NSDateFormatterMediumStyle;
  NSString *when = _recoveredTime ? [format stringFromDate:_recoveredTime] : @"the last session";
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:[NSString stringWithFormat:@"Work from %@ was recovered", when]
                       message:[NSString stringWithFormat:@"It was not yet saved in “%@” when the "
                                                          @"app last closed.",
                                                          self.name]
                preferredStyle:UIAlertControllerStyleAlert];
  UIAlertAction *keep = [UIAlertAction
      actionWithTitle:@"Continue from It"
                style:UIAlertActionStyleDefault
              handler:^(UIAlertAction *) {
                WM_native_ui_log("document", "recovered work: continued from it");
                _recoveryPending = NO;
                [self updateChangeCount:UIDocumentChangeDone];
                [self saveAlongTheWay];
                if (self.held && !_holdAsked) {
                  [self presentHold:NO];
                }
              }];
  [alert addAction:keep];
  [alert addAction:[UIAlertAction actionWithTitle:@"Open as Last Saved"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *) {
                                            WM_native_ui_log("document",
                                                             "recovered work: opened as last saved");
                                            _recoveryPending = NO;
                                            [self openAsLastSaved:"declined at open"];
                                          }]];
  alert.preferredAction = keep;
  [_recoveryAlert release];
  _recoveryAlert = [alert retain];
  WM_native_ui_log("document", [@"recovered work said: " stringByAppendingString:alert.title].UTF8String);
  wm_apple_ios_present_alert(nil, alert);
}

- (void)openAsLastSaved:(const char *)why
{
  /* The work is kept aside as Recovered Work, then the file is read again as saved. Off the main
   * queue, to wait for the engine: when the work could not be kept (said by the engine), the file
   * is not read again, which would drop it (ROUND7 U4d). */
  const std::string reason = why;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    const bool kept = wm_apple_ios_document_set_aside_wait(reason.c_str());
    dispatch_async(dispatch_get_main_queue(), ^{
      if (kept) {
        [self reopen:YES];
      }
      else {
        WM_native_ui_log("document", "not reverted: the work could not be kept first");
      }
    });
  });
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name The folder beside the document (ROUND6 FILES-3, finding F8)
 *
 * The document's access covers its one file. Textures by relative path, linked libraries, caches
 * and sequences beside it are read once the person gives the app the folder: asked once as it
 * opens, one folder pick, bookmarked, then what was not read is read again. A folder given before
 * is not asked for again: its files may be iCloud placeholders, which are asked for and read
 * under coordination.
 * \{ */

- (void)presentNeighbours
{
  if (_unreadable.empty() || self.documentState & UIDocumentStateClosed) {
    return;
  }
  NSString *folder = _unreadableFolder.length ? _unreadableFolder :
                                                self.fileURL.path.stringByDeletingLastPathComponent;
  if (GHOST_ios_document_can_write_path(folder.UTF8String)) {
    WM_native_ui_log("document", "neighbours: the folder was given before; reading them again");
    [self readNeighbours];
    return;
  }
  /* After the recovered-work and held-document questions, which come first. */
  UIViewController *presenter = wm_apple_ios_top_presenter();
  if (_recoveryPending || [presenter isKindOfClass:UIAlertController.class] || !presenter) {
    if (_neighboursTries-- > 0) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(1.0 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(),
                     ^{
                       [self presentNeighbours];
                     });
    }
    return;
  }
  const size_t count = _unreadable.size();
  NSString *title = count == 1 ?
                        @"1 file beside this document cannot be read" :
                        [NSString stringWithFormat:@"%zu files beside this document cannot be read",
                                                   count];
  NSString *first = [NSString stringWithUTF8String:_unreadable.front().c_str()].lastPathComponent;
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:title
                       message:[NSString stringWithFormat:@"“%@” uses files from its folder, such "
                                                          @"as “%@”, that the app may not read "
                                                          @"yet. Give access to the folder “%@” "
                                                          @"to read them.",
                                                          self.name,
                                                          first,
                                                          folder.lastPathComponent]
                preferredStyle:UIAlertControllerStyleAlert];
  UIAlertAction *give = [UIAlertAction actionWithTitle:@"Give Access to the Folder"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *) {
                                                 [self chooseNeighbourFolder:folder];
                                               }];
  [alert addAction:give];
  [alert addAction:wm_apple_ios_cancel_action(@"Not Now", ^(UIAlertAction *) {
    WM_native_ui_log("document", "neighbours: not now");
  })];
  alert.preferredAction = give;
  WM_native_ui_log("document", [@"neighbours said: " stringByAppendingString:title].UTF8String);
  wm_apple_ios_present_alert(presenter, alert);
}

- (void)chooseNeighbourFolder:(NSString *)folder
{
  [WMIOSFolderGrant chooseFolder:folder
                      completion:^(NSURL *url) {
                        if (!url) {
                          WM_native_ui_log("document", "neighbours: no folder given");
                          return;
                        }
                        GHOST_ios_document_access_remember_url(url);
                        WM_native_ui_log("document",
                                         [@"neighbours: folder given: "
                                             stringByAppendingString:url.lastPathComponent]
                                             .UTF8String);
                        [self readNeighbours];
                      }];
}

/** Ask iCloud for what is not downloaded, wait for each under coordination, then read them all
 * again in Blender, which says what is still missing. */
- (void)readNeighbours
{
  const std::vector<std::string> unreadable = _unreadable;
  _unreadable.clear();
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    for (const std::string &path : unreadable) {
      @autoreleasepool {
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
        [NSFileManager.defaultManager startDownloadingUbiquitousItemAtURL:url error:nil];
        NSFileCoordinator *coordinator = [[[NSFileCoordinator alloc] initWithFilePresenter:nil]
            autorelease];
        [coordinator coordinateReadingItemAtURL:url
                                        options:NSFileCoordinatorReadingWithoutChanges
                                          error:nil
                                     byAccessor:^(NSURL *){
                                     }];
      }
    }
    GHOST_ios_engine_perform([unreadable](blender::bContext *C) {
      if (C) {
        blender::WM_apple_ios_document_neighbours_reload(C, unreadable);
      }
    });
  });
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Held documents (ROUND6 SAFE-2)
 *
 * A file Blender's Save would ask about before overwriting (from a newer Blender, with missing
 * colour spaces, managed by the asset system) is not written until the person answers once:
 * Save a Copy and Work on That, Save Here Anyway, or Keep Read-Only. Asked at the first edit or
 * the first Save, never at open; the header says so meanwhile. Blender's own auto-save still
 * keeps the work.
 * \{ */

- (BOOL)held
{
  return _holdReason.length && _holdAnswer == 0;
}

- (BOOL)readOnly
{
  return _holdReason.length && _holdAnswer == 2;
}

- (BOOL)needsAnswerBeforeClosing
{
  return ((self.held || self.readOnly) && !_discard && (_blenderModified || _recovered)) ||
         _recoveryPending;
}

- (void)presentHold:(BOOL)closing
{
  if (_recoveryPending) {
    /* First whether the recovered work is wanted at all. */
    [self presentRecovered];
    return;
  }
  if (_holdAlert.presentingViewController) {
    return;
  }
  _holdAsked = YES;
  const BOOL read_only = self.readOnly;
  NSString *message = read_only ? [NSString stringWithFormat:@"“%@” is kept read-only: changes "
                                                             @"are not saved to it. Save a copy "
                                                             @"to keep them.",
                                                             self.name] :
                                  _holdReason;
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:[NSString stringWithFormat:closing ? @"Close “%@”?" :
                                                                    @"Save “%@”?",
                                                          self.name]
                       message:message
                preferredStyle:UIAlertControllerStyleAlert];
  UIAlertAction *copy = [UIAlertAction actionWithTitle:@"Save a Copy and Work on That"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *) {
                                                 [self saveCopyAndWorkOnIt];
                                               }];
  [alert addAction:copy];
  if (!read_only && !_holdCopyOnly) {
    [alert addAction:[UIAlertAction actionWithTitle:@"Save Here Anyway"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *) {
                                              [self answerHold:1 closing:closing];
                                            }]];
  }
  if (closing) {
    [alert addAction:[UIAlertAction actionWithTitle:@"Close Without Saving"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *) {
                                              [self answerHold:2 closing:YES];
                                            }]];
  }
  else if (!read_only) {
    [alert addAction:[UIAlertAction actionWithTitle:@"Keep Read-Only"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *) {
                                              [self answerHold:2 closing:NO];
                                            }]];
  }
  [alert addAction:wm_apple_ios_cancel_action(closing ? @"Cancel" : @"Not Now",
                                              ^(UIAlertAction *) {
                                                WM_native_ui_log("document", "held: not answered");
                                              })];
  alert.preferredAction = copy;
  [_holdAlert release];
  _holdAlert = [alert retain];
  WM_native_ui_log("document",
                   [NSString stringWithFormat:@"held: asked%@%@", closing ? @" on closing" : @"",
                                              read_only ? @" (read-only)" : @""]
                       .UTF8String);
  wm_apple_ios_present_alert(nil, alert);
}

/** 1: Save Here Anyway, 2: Keep Read-Only (or Close Without Saving when `closing`). */
- (void)answerHold:(int)answer closing:(BOOL)closing
{
  _holdAnswer = answer;
  WM_native_ui_log("document", answer == 1 ? "held: save here anyway" : "held: kept read-only");
  if (answer == 1) {
    if (closing) {
      wm_apple_ios_launcher_show_documents(nil);
    }
    else if (_blenderModified || _recovered) {
      [self updateChangeCount:UIDocumentChangeDone];
      [self saveAlongTheWay];
    }
  }
  else if (closing) {
    [self closeWithoutSaving];
  }
}

/** What is loaded, written as a new file beside the document, which then opens in its place:
 * the document's own file is left as it is. */
- (void)saveCopyAndWorkOnIt
{
  NSString *stem = self.name.stringByDeletingPathExtension;
  if ([stem.pathExtension isEqualToString:@"asset"]) {
    stem = stem.stringByDeletingPathExtension;
  }
  NSString *name = [NSString stringWithFormat:@"%@ (%d.%d).blend",
                                              stem,
                                              BLENDER_VERSION / 100,
                                              BLENDER_VERSION % 100];
  /* The document is not written from here on, whatever becomes of the copy. */
  _holdAnswer = 2;
  WM_native_ui_log("document", [@"held: a copy to work on, " stringByAppendingString:name].UTF8String);
  NSURL *next_to = [[self.fileURL copy] autorelease];
  writeFreshCopy(name, nil, YES, ^(NSURL *copy) {
    if (copy) {
      /* The copy holds every change (Blender marked it saved with the write): closing this
       * document as the copy opens asks nothing (device round: "Close? changes are not saved"
       * although they were). An edit from here on marks it changed again. */
      _blenderModified = NO;
      _recovered = NO;
      wm_apple_ios_launcher_adopt_copy(copy, next_to);
    }
  });
}

- (void)setHold:(const blender::wmDocumentOpened &)opened
{
  NSString *title = opened.hold_title.empty() ?
                        nil :
                        [NSString stringWithUTF8String:opened.hold_title.c_str()];
  NSString *reason = opened.hold_reason.empty() ?
                         nil :
                         [NSString stringWithUTF8String:opened.hold_reason.c_str()];
  /* A reopen of the same file keeps the answer given. */
  if (![reason isEqual:_holdReason]) {
    _holdAnswer = 0;
    _holdAsked = NO;
  }
  [_holdTitle release];
  _holdTitle = [title copy];
  [_holdReason release];
  _holdReason = [reason copy];
  _holdCopyOnly = opened.hold_copy_only;
}

/** \} */

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
  /* After a failure, longer each time (two, four, eight minutes, at most ten): its alert said it
   * once, and the cause rarely goes by itself within a minute. */
  const CFTimeInterval wait = _failures > 0 ?
                                  std::min(document_save_interval * (1 << std::min(_failures, 4)),
                                           600.0) :
                                  std::max(document_save_delay,
                                           document_save_interval -
                                               (CACurrentMediaTime() - _lastWrite));
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, int64_t(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        _alongTheWayScheduled = NO;
        if ((self.documentState & UIDocumentStateClosed) ||
            !(_blenderModified || [super hasUnsavedChanges]) || self.held || self.readOnly)
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
          /* After the outcome is said, which #writeContents queued before UIKit finished. */
          dispatch_async(dispatch_get_main_queue(), ^{
            if (!success && (_failure || _busy)) {
              _failures++;
            }
            /* Edited since, Blender was mid-stroke, or the write failed. */
            if ((_blenderModified || !success) && !_refused && !_discard) {
              [self saveAlongTheWay];
            }
          });
        }];
      });
}

- (void)openWithCompletionHandler:(void (^)(BOOL success))completionHandler
{
  /* Blender opens the file by its path, outside of the document's coordinated read. */
  _accessing = [self.fileURL startAccessingSecurityScopedResource];
  [super openWithCompletionHandler:^(BOOL success) {
    if (!success) {
      /* Said in the launcher, with Blender's words; the launcher takes files again at once. */
      wm_apple_ios_launcher_open_failed(self, _openProblem ?: @"The file could not be read.");
    }
    /* Work recovered from the auto-save goes into the document, as an edit would. */
    if (success && _recovered) {
      /* Said, with the time, and declinable (ROUND6 SAFE-5, decision R6-4): nothing is written
       * until the person answers. */
      dispatch_async(dispatch_get_main_queue(), ^{
        _recoveryPending = YES;
        [self updateChangeCount:UIDocumentChangeDone];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(),
                       ^{
                         [self presentRecovered];
                       });
      });
    }
    /* Files sent to the app while no document was open are imported into this one (ROUND6
     * FILES-8), once it shows. */
    if (success) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(1.5 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(),
                     ^{
                       GHOST_ios_engine_perform([](blender::bContext *C) {
                         if (C) {
                           blender::WM_apple_ios_import_pending_run(C);
                         }
                       });
                     });
    }
    /* Files beside it that cannot be read: said once it shows, after the questions above. */
    if (success) {
      dispatch_async(dispatch_get_main_queue(), ^{
        _neighboursTries = 30;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(),
                       ^{
                         [self presentNeighbours];
                       });
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
  auto opened = std::make_shared<blender::wmDocumentOpened>();
  bool timed_out = false;
  if (engine_wait(
          [path, template_document, opened](blender::bContext *C) {
            return blender::WM_apple_ios_document_open(C, path.c_str(), template_document, *opened);
          },
          &timed_out))
  {
    _recovered = opened->recovered;
    NSDate *recovered_time = opened->recovered_time ?
                                 [NSDate dateWithTimeIntervalSince1970:double(opened->recovered_time)] :
                                 nil;
    [_recoveredTime release];
    _recoveredTime = [recovered_time retain];
    blender::wmDocumentOpened hold = *opened;
    /* Before the open completes on the main queue, so it is known when the document shows. */
    dispatch_async(dispatch_get_main_queue(), ^{
      [self setHold:hold];
      _unreadable = hold.unreadable;
      [_unreadableFolder release];
      _unreadableFolder = [[NSString alloc] initWithUTF8String:hold.unreadable_folder.c_str()];
    });
    return YES;
  }
  /* Blender's own reason, for the launcher to show (ROUND6 SAFE-2): never "corrupt" for all. */
  NSString *reason = timed_out ? @"The app was busy for five minutes and did not open the file." :
                                 [NSString stringWithUTF8String:opened->error.c_str()];
  if (!reason.length) {
    reason = @"The file could not be read.";
  }
  [_openProblem release];
  _openProblem = [reason copy];
  if (outError) {
    *outError = [NSError errorWithDomain:NSCocoaErrorDomain
                                    code:NSFileReadUnknownError
                                userInfo:@{
                                  NSLocalizedFailureReasonErrorKey : reason,
                                  @"WMIOSDocumentOutcome" : @"open",
                                }];
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
  /* A new write: its outcome is said below, or by #handleError when UIKit fails around it. */
  dispatch_async(dispatch_get_main_queue(), ^{
    _outcomeSaid = NO;
  });
  struct Result {
    blender::wmDocumentWrite outcome = blender::wmDocumentWrite::Failed;
    std::string error = "The file could not be written yet.";
  };
  auto result = std::make_shared<Result>();
  bool timed_out = false;
  if (engine_wait(
          [path, preview, along_the_way, result](blender::bContext *C) {
            result->outcome = blender::WM_apple_ios_document_write(
                C, path.c_str(), preview, along_the_way, result->error);
            return result->outcome == blender::wmDocumentWrite::Written;
          },
          &timed_out))
  {
    _lastWrite = CACurrentMediaTime();
    _previewStale = !preview;
    WM_native_ui_log("document",
                     [NSString stringWithFormat:@"written %@%@",
                                                along_the_way ? @"along the way" : @"in full",
                                                preview ? @" with its preview" : @""]
                         .UTF8String);
    dispatch_async(dispatch_get_main_queue(), ^{
      [self writeOutcome:@"written" reason:nil];
    });
    return YES;
  }
  /* Read only once Blender has finished with it: never after a time-out. */
  NSString *outcome = @"failed";
  NSString *reason = nil;
  if (timed_out) {
    outcome = @"busy";
    reason = @"Busy, not saved yet.";
  }
  else if (result->outcome == blender::wmDocumentWrite::Refused) {
    outcome = @"refused";
    reason = @"Another file is loaded than this document.";
    dispatch_async(dispatch_get_main_queue(), ^{
      [self writeRefused];
    });
  }
  else if (result->outcome == blender::wmDocumentWrite::Deferred) {
    outcome = @"deferred";
    reason = @"Not saved while an operation runs.";
  }
  else {
    reason = [NSString stringWithUTF8String:result->error.c_str()] ?: @"";
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [self writeOutcome:outcome reason:reason];
  });
  if (outError) {
    *outError = [NSError errorWithDomain:NSCocoaErrorDomain
                                    code:NSFileWriteUnknownError
                                userInfo:@{
                                  NSLocalizedFailureReasonErrorKey : reason,
                                  @"WMIOSDocumentOutcome" : outcome,
                                }];
  }
  return NO;
}

- (BOOL)hasUnsavedChanges
{
  /* Refused: nothing loaded is the document's to save, see #_refused. Closed without saving, as
   * the person chose. Held or read-only: not written until the person answers (ROUND6 SAFE-2). */
  if (_refused || _discard || self.held || self.readOnly || _recoveryPending) {
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
  [alert addAction:wm_apple_ios_cancel_action(@"Not Now", nil)];
  WM_native_ui_log("document", "refusal shown: Save a Copy, Reopen Document, Not Now");
  wm_apple_ios_present_alert(nil, alert);
}

- (void)revertAsked
{
  /* Blender's own question (ROUND6 SAFE-5): Revert asks first. */
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"Revert to the Saved File"
                       message:@"Any unsaved changes will be lost. They are kept as Recovered "
                               @"Work in the documents."
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"Revert"
                                            style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *) {
                                            [self openAsLastSaved:"revert"];
                                          }]];
  [alert addAction:wm_apple_ios_cancel_action(@"Cancel", nil)];
  WM_native_ui_log("document", "revert: asked");
  wm_apple_ios_present_alert(nil, alert);
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
  if (self.held || self.readOnly) {
    [self presentHold:NO];
    return;
  }
  if (!self.hasUnsavedChanges && !_failure) {
    WM_native_ui_log("document", "save: nothing changed since it was saved");
    return;
  }
  if (!self.hasUnsavedChanges) {
    /* Failed before: write again, whatever UIKit counts. */
    [self updateChangeCount:UIDocumentChangeDone];
  }
  /* A failure is said by the failure path, see #saveFailed:. */
  [self saveForPerson:NO
           completion:^(BOOL success) {
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
    if (self.held) {
      /* Asked at the first edit, not at open (ROUND6 SAFE-2). */
      if (!_holdAsked) {
        [self presentHold:NO];
      }
      return;
    }
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

/** A fresh copy of what Blender has loaded, written from memory into a new temporary folder:
 * `done` gets it, or nil after an alert with Blender's reason. */
static void writeFreshCopy(NSString *name,
                           UIViewController *presenter,
                           BOOL holds_work,
                           void (^done)(NSURL *url))
{
  [presenter retain];
  void (^finish)(NSURL *) = [done copy];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString *folder = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[@"save-copy-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:folder
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    NSURL *copy = [NSURL fileURLWithPath:[folder stringByAppendingPathComponent:name]];
    const std::string path = copy.path.UTF8String;
    auto error = std::make_shared<std::string>("The copy could not be written yet.");
    bool timed_out = false;
    const bool written = engine_wait(
        [path, error, holds_work](blender::bContext *C) {
          return blender::WM_apple_ios_document_copy_write(C, path.c_str(), holds_work, *error);
        },
        &timed_out);
    NSString *reason = timed_out ? @"Busy. Try again when the current work has finished." :
                       written   ? nil :
                                   [NSString stringWithUTF8String:error->c_str()];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!written) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Could Not Save a Copy"
                             message:reason ?: @"Check available storage and try again."
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        wm_apple_ios_present_alert(presenter, alert);
      }
      finish(written ? copy : nil);
      [finish release];
      [presenter release];
    });
  });
}

void wm_apple_ios_document_file_now(UIViewController *presenter, void (^done)(NSURL *url))
{
  WMIOSBlendDocument *document = (WMIOSBlendDocument *)wm_apple_ios_launcher_document();
  void (^finish)(NSURL *) = [[done copy] autorelease];
  if (![document isKindOfClass:WMIOSBlendDocument.class]) {
    WM_native_ui_log("document", "file now: no document open");
    finish(nil);
    return;
  }
  NSString *name = document.fileURL.lastPathComponent ?: @"Untitled.blend";
  NSURL *documentURL = [[document.fileURL copy] autorelease];
  [presenter retain];
  [document retain];
  [finish retain];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    /* Files it reads from outside itself would be missing from a copy sent elsewhere: offer to
     * include them first, as desktop's Pack Resources (ROUND6 FILES-5). */
    auto external = std::make_shared<std::string>();
    engine_wait([external](blender::bContext *C) {
      *external = blender::WM_apple_ios_document_external(C);
      return true;
    });
    int packable = 0, unpackable = 0;
    char first[1024] = "";
    sscanf(external->c_str(), "%d %d %1023[^\n]", &packable, &unpackable, first);
    if (packable + unpackable > 0) {
      NSString *example = [NSString stringWithUTF8String:first] ?: @"";
      dispatch_async(dispatch_get_main_queue(), ^{
        void (^go)(BOOL) = ^(BOOL include) {
          dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            if (include) {
              engine_wait([](blender::bContext *C) {
                blender::WM_apple_ios_document_pack_external(C);
                return true;
              });
            }
            wm_apple_ios_document_file_now_go(document, documentURL, name, presenter, finish);
          });
        };
        NSString *count = packable + unpackable == 1 ?
                              @"1 file" :
                              [NSString stringWithFormat:@"%d files", packable + unpackable];
        NSMutableString *message = [NSMutableString
            stringWithFormat:@"“%@” reads %@ from outside itself, such as “%@”. A copy sent "
                             @"elsewhere would miss them.",
                             name,
                             count,
                             example];
        if (unpackable > 0) {
          [message appendFormat:@" %d of them (movies, sequences, caches or linked libraries) "
                                @"cannot be included and stay outside.",
                                unpackable];
        }
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Include External Files?"
                             message:message
                      preferredStyle:UIAlertControllerStyleAlert];
        if (packable > 0) {
          UIAlertAction *include = [UIAlertAction actionWithTitle:@"Include External Files"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(UIAlertAction *) {
                                                            go(YES);
                                                          }];
          [alert addAction:include];
          alert.preferredAction = include;
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"Send Without Them"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *) {
                                                  go(NO);
                                                }]];
        [alert addAction:wm_apple_ios_cancel_action(@"Cancel", ^(UIAlertAction *) {
          WM_native_ui_log("document",
                           "include external files: "
                           "cancelled");
          finish(nil);
          [presenter release];
          [document release];
          [finish release];
        })];
        WM_native_ui_log("document",
                         [NSString stringWithFormat:@"include external files asked: %d, %d not "
                                                    @"packable",
                                                    packable + unpackable,
                                                    unpackable]
                             .UTF8String);
        wm_apple_ios_present_alert(presenter, alert);
      });
      return;
    }
    wm_apple_ios_document_file_now_go(document, documentURL, name, presenter, finish);
  });
}

/** The rest of #wm_apple_ios_document_file_now, off the main queue, once external files are
 * answered for. Releases what that retained. */
static void wm_apple_ios_document_file_now_go(WMIOSBlendDocument *document,
                                              NSURL *documentURL,
                                              NSString *name,
                                              UIViewController *presenter,
                                              void (^finish)(NSURL *))
{
  {
    /* What is loaded is the document's: save it, then hand on the file, as Files apps do. Not the
     * document's (refused, ROUND5 9D.1): what is loaded exists nowhere on disk, so write it as a
     * copy and hand on that, leaving the document as it is. The same when the save fails (ROUND6
     * SAFE-1): the document's file is as last written, never the work since. */
    const bool own = engine_wait(
        [](blender::bContext *) { return blender::WM_apple_ios_document_is_loaded(); });
    void (^release_all)(void) = ^{
      [presenter release];
      [document release];
      [finish release];
    };
    if (own && [document canWriteInPlace]) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [document saveToURL:documentURL
              forSaveOperation:UIDocumentSaveForOverwriting
             completionHandler:^(BOOL success) {
               if (success) {
                 finish(documentURL);
                 release_all();
                 return;
               }
               WM_native_ui_log("document", "file now: the save failed, a fresh copy instead");
               writeFreshCopy(name, presenter, NO, ^(NSURL *copy) {
                 finish(copy);
                 release_all();
               });
             }];
      });
      return;
    }
    writeFreshCopy(name, presenter, NO, ^(NSURL *copy) {
      finish(copy);
      release_all();
    });
  }
}

void wm_apple_ios_document_save_as(UIViewController *presenter)
{
  [presenter retain];
  wm_apple_ios_document_file_now(presenter, ^(NSURL *url) {
    if (url) {
      presentExporter(url, presenter);
    }
    [presenter release];
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
