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
};

}  // namespace blender
