/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * The file commands a platform's document window takes its own route for, see
 * #wmNativeInterface::document_command. On its own, so the platform's Objective-C code can name
 * them without the window manager's headers.
 */

#pragma once

#include <cstdint>
#include <string>

namespace blender {

/**
 * What a document window does instead of loading or writing Blender's file itself (ROUND5 9D,
 * decisions 61-63): in a document window, the file Blender has loaded is the document, so these
 * commands take the platform's document route, whichever interface shows and whatever ran them.
 */
enum class wmDocumentCommand : int8_t {
  /** A new document (`argument`: Blender's app template, "General" for its own; empty for the
   * person to choose one). */
  New,
  /** Another file as its own document (`argument`: its path, empty to pick one). */
  Open,
  /** The document again as it was last saved, its auto-save left out. */
  Revert,
  /** The document saved now, through the document. */
  Save,
  /** A copy written where the person picks; the window stays on its document. */
  SaveAs,
  /** The document saved and closed, back to the documents. Never an exit. */
  Quit,
  /**
   * The document again with its scripts allowed, keeping the work since it was saved: the trust
   * prompt's Allow Execution, which reloads the file (ROUND6 SAFE-3). Blender's auto-save is
   * written first, so the document continues from it.
   */
  Reload,
};

/**
 * How a document's write ended (ROUND6 SAFE-1): every way is said to the person, none of them is
 * dropped. A write that was put off is not a failure.
 */
enum class wmDocumentWrite : int8_t {
  /** The file was written. */
  Written,
  /** Nothing was written: Blender has another file loaded than the document (ROUND5 9D.1). */
  Refused,
  /** Not now: a stroke or other modal operator is running, and saving along the way waits. */
  Deferred,
  /** Blender could not write the file; its reason comes with it. */
  Failed,
};

/** What opening a document found (ROUND6 SAFE-2). */
struct wmDocumentOpened {
  /** The document's auto-save was newer and opened instead: work it has yet to save. */
  bool recovered = false;
  /**
   * Why the document is not written until the person answers once: what Blender's Save asks
   * before overwriting, see #BKE_main_needs_overwrite_confirm. Empty when nothing. `hold_title`
   * is the header's short line, `hold_reason` the question's text.
   */
  std::string hold_title;
  std::string hold_reason;
  /** Only a new file may be written (an asset system file). */
  bool hold_copy_only = false;
  /** Why it could not be opened, in Blender's words. */
  std::string error;
};

}  // namespace blender
