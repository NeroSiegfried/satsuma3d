/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#pragma once

#include <cstdint>
#include <functional>
#include <string>

struct wmIOSDialog;
class GHOST_WindowIOS;

namespace blender {
struct bContext;
struct wmWindow;
struct Report;
struct ReportList;
/** See `WM_document_command.hh`. */
enum class wmDocumentCommand : int8_t;
enum class wmDocumentWrite : int8_t;
struct wmDocumentOpened;

/* Engine-thread API. UIKit exchanges only owned values and request identifiers. */
/**
 * Register the native interface: with GHOST, for the app's windows and its loop, and with the
 * window manager, in place of parts of Blender's interface, see #wmNativeInterface. Called before
 * the app starts, as the launcher shows at once.
 */
void WM_apple_ios_native_interface_register();

/* The native interface's views, as GHOST asks for them, see #GHOST_IOSNativeInterface.
 * `UIViewController *` and `MTKView *` are passed as `void *`. */

/**
 * The document launcher, for the app's first window. It shows at once on launch, styled with
 * Blender's brand, logo and a large Suzanne to flick around, while Blender starts behind it. It
 * owns the open document; Blender's window shows only while one is open.
 */
void *WM_apple_ios_launcher_controller();
void *WM_apple_ios_window_controller(void *metal_view, GHOST_WindowIOS *window, void **r_root);
void WM_apple_ios_document_window_changed();
/** Follow Blender's unsaved changes, which make the document save itself. */
void WM_apple_ios_document_set_modified(bool modified);
/** Open the document at an `NSURL *` the system handed to the app. */
void WM_apple_ios_open_url(void *url);
/** The app's own About, from Blender's splash and About operators, see
 * #wmNativeInterface::about_show. */
void WM_apple_ios_about_show();
/** The app's name, as the system shows it. */
const char *WM_apple_ios_app_name();

/**
 * Fingers moving objects with the Tweak tool, see `wm_apple_ios_finger_tweak.cc`. GHOST asks
 * whether they do and hands over their touches from UIKit's thread, see
 * #GHOST_IOSNativeInterface::finger_tweak_touch; Blender's loop applies them with
 * #WM_apple_ios_finger_tweak_flush.
 */
bool WM_apple_ios_finger_tweak_active();
void WM_apple_ios_finger_tweak_touch(uint64_t id, int phase, int x, int y);
int WM_apple_ios_finger_tweak_holding(bool *r_landing);
/** Follow the active tool and mode, as they change. */
void WM_apple_ios_finger_tweak_mode_update(bContext *C);
void WM_apple_ios_finger_tweak_flush(bContext *C);
bool WM_apple_ios_dialog_begin(bContext *C,
                               const wmIOSDialog &dialog,
                               std::function<void(bContext *, int, uint64_t)> complete,
                               std::function<void(bContext *)> cancel = {},
                               const char *key = "");
void WM_apple_ios_dialog_flush(bContext *C);
bool WM_apple_ios_dialog_active(const wmWindow *win);
void WM_apple_ios_reports(wmWindow *win, ReportList *reports, int minimum_level);
/** One report, added to the window manager's list by other than an operator. */
void WM_apple_ios_report(wmWindow *win, const Report *report);
/** Keep auto-save on: iOS ends apps without warning. Call after loading the preferences. */
void WM_apple_ios_autosave_ensure();
/** Write the auto-save now, in any mode, when the app goes to the background. */
void WM_apple_ios_autosave_now(bContext *C);
/* Documents. UIKit owns them, and Blender reads and writes their files when asked. */

/**
 * Open the document's file. `r_opened`: whether its newer auto-save opened instead, why it must
 * not be written before the person answers (ROUND6 SAFE-2), or why it could not be opened.
 */
bool WM_apple_ios_document_open(bContext *C,
                                const char *filepath,
                                bool template_document,
                                wmDocumentOpened &r_opened);
/**
 * Write the open file to `filepath`, for iOS to move into place as the saved document. Without
 * `preview` the file stores no preview image, which needs the GPU.
 */
/** `when_idle`: put off (#wmDocumentWrite::Deferred) rather than write while a stroke or other
 * modal operator runs. #wmDocumentWrite::Refused: nothing was written because Blender has another
 * file loaded than the one the document opened (ROUND5 9D, decision 62): writing it would replace
 * the document with that file. The document says so and offers to save a copy.
 * #wmDocumentWrite::Failed: `r_error` has Blender's reason (ROUND6 SAFE-1). */
wmDocumentWrite WM_apple_ios_document_write(
    bContext *C, const char *filepath, bool preview, bool when_idle, std::string &r_error);
/** Whether what Blender has loaded is the file the document opened, see #WM_file_read_count; a
 * read of the document's own file again is adopted (ROUND6 SAFE-3). */
bool WM_apple_ios_document_is_loaded();
/**
 * The trust prompt's reload with scripts, through the document (ROUND6 SAFE-3): Blender's
 * auto-save written first so no work is dropped, then the document reopened with its scripts on.
 * False outside a document window, where Blender reloads by itself.
 */
bool WM_apple_ios_document_reload_with_scripts(bContext *C);
/** Start without add-ons and saved preferences, for this session (ROUND6 SAFE-4): offered after
 * the app ended twice in a row while a document was opening. */
void WM_apple_ios_factory_preferences(bContext *C);
/** The open document's auto-save, with the work as it is now, set aside as Recovered Work: for
 * Revert, Open as Last Saved and Restore Version from Opening (ROUND6 SAFE-5). */
void WM_apple_ios_document_set_aside(bContext *C, const char *why);
/** Write what Blender has loaded to `filepath` as a copy, for Save a Copy: the document and its
 * auto-save are left as they are. */
bool WM_apple_ios_document_copy_write(bContext *C, const char *filepath, std::string &r_error);
/**
 * The front door (ROUND5 9D, decision 61): a file command run in a document window, from a key, a
 * menu, Search or a button, in either interface, takes the document's route instead of loading or
 * writing Blender's file, see #wmDocumentCommand. Logged as `document route <command>`. Called
 * from the commands' operators on iOS and through #wmNativeInterface::document_command.
 */
bool WM_apple_ios_document_command(bContext *C, wmDocumentCommand command, const char *argument);
/** The launcher's side of #WM_apple_ios_document_command, on UIKit's thread. */
void WM_apple_ios_launcher_document_command(wmDocumentCommand command, const std::string &argument);
/**
 * A check launch's own steps (`document …`, see `Snapshots.swift`), in the check's scratch
 * document only: `marker` (set a marker in the scene and mark the file edited), `check` (whether
 * the marker is in what Blender has loaded) and `python <code>`. The answer is logged and returned.
 */
std::string WM_apple_ios_document_check_step(bContext *C, const std::string &step);
/** Save a portable template copy and PNG preview without marking the document saved. */
std::string WM_apple_ios_document_template_write(bContext *C,
                                                 const char *filepath,
                                                 const char *preview,
                                                 std::string &attribution);

}  // namespace blender
