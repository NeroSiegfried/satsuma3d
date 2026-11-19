/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * What the iPad's system picker asks for a file selector (ROUND6 FILES-1, finding F7).
 *
 * Desktop Blender's File Browser lets the person type any name, so an operator never had to say
 * whether it opens or writes; the browser only reads `check_existing`'s *value* to colour an
 * existing name red (`fileselect_ensure_updated_file_params`). The system picker asks one question
 * at a time (pick an existing file, name a new one in a folder, pick a folder), so the question is
 * derived here from the operator's properties as they stand when the selector opens, after the
 * operator's own invoke (`buttons.file_browse` sets `check_existing` there for output paths).
 *
 * Kept free of Blender's headers so the Mac's `script_native_file_modes` test builds it alone and
 * runs it over every operator with file properties.
 */

#pragma once

#include <string_view>

namespace blender::wm::apple_ios {

enum class FileSelectKind {
  /** Not a file selector this picker serves: Blender's own File Browser is used. */
  Browser,
  /** Browses data-blocks inside a `.blend` (Link, Append). */
  Library,
  /** Pick existing files. */
  Open,
  /** Name a new file in a folder the person picks (the folder is granted). */
  Save,
  /** Pick a folder. */
  Directory,
};

struct FileSelectFacts {
  bool filepath = false;
  bool directory = false;
  bool filename = false;
  bool files = false;
  bool has_check_existing = false;
  /** The value at the time the selector opens, not the property's default. */
  bool check_existing = false;
  /** `filter_blenlib` or `filemode == FILE_LOADLIB`. */
  bool blenlib = false;
  /** A property's path is browsed (`buttons.file_browse`) and the property is an output path:
   * Blender writes there, so it is "a folder and a name". */
  bool output_path = false;
  /** The path the selector starts from ends with a separator (it names a folder). */
  bool path_is_folder = false;
  /** The operator's name as the person reads it ("Export Keying Set"). */
  std::string_view name;
};

/** An operator that has no `check_existing` says what it does in its name. Python operators that
 * call `fileselect_add` without `ExportHelper` (keying set and key configuration export, system
 * info) only have their name to go by. */
inline bool file_select_name_writes(std::string_view name)
{
  for (const std::string_view verb : {std::string_view("Save"), std::string_view("Export")}) {
    if (name.substr(0, verb.size()) == verb &&
        (name.size() == verb.size() || name[verb.size()] == ' '))
    {
      return true;
    }
  }
  return false;
}

inline FileSelectKind file_select_kind(const FileSelectFacts &facts)
{
  if (facts.blenlib) {
    return FileSelectKind::Library;
  }
  if (!facts.filepath && !facts.directory) {
    return FileSelectKind::Browser;
  }
  /* Blender's own rule for a folder selector (`FILE_DIRSEL_ONLY`). */
  if (!facts.filepath && !facts.filename && !facts.files) {
    return FileSelectKind::Directory;
  }
  if (facts.output_path) {
    /* "//render/" names a folder Blender writes into; "//render/frame_" a folder and a name. */
    return facts.path_is_folder ? FileSelectKind::Directory : FileSelectKind::Save;
  }
  if (facts.has_check_existing) {
    return facts.check_existing ? FileSelectKind::Save : FileSelectKind::Open;
  }
  return facts.filepath && file_select_name_writes(facts.name) ? FileSelectKind::Save :
                                                                  FileSelectKind::Open;
}

}  // namespace blender::wm::apple_ios
