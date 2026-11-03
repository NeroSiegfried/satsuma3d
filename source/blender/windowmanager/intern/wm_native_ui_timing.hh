/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * Timing the bridge's work, for comparing one way of doing it with another, see
 * `native_ui/timings.py`.
 */

#pragma once

#include <chrono>
#include <cstdio>
#include <cstdlib>

#include "BKE_appdir.hh"

#include "BLI_fileops.h"
#include "BLI_path_utils.hh"

namespace blender {

/**
 * How long a part of a snapshot took to build, with `BLENDER_NATIVE_UI_RECORD`: a line of
 * `native_ui_record/timings.jsonl` for each, to find what makes the bridge slow.
 */
class BridgeTimer {
  const char *part_;
  std::chrono::steady_clock::time_point start_ = std::chrono::steady_clock::now();

 public:
  explicit BridgeTimer(const char *part) : part_(part) {}
  ~BridgeTimer()
  {
    static const bool record = getenv("BLENDER_NATIVE_UI_RECORD") != nullptr;
    static FILE *file = nullptr;
    static int lines = 0;
    if (!record || lines >= 1000000) {
      return;
    }
    if (file == nullptr) {
      char directory[FILE_MAX];
      BLI_path_join(directory, sizeof(directory), BKE_tempdir_base(), "native_ui_record");
      BLI_dir_create_recursive(directory);
      char path[FILE_MAX];
      BLI_path_join(path, sizeof(path), directory, "timings.jsonl");
      file = BLI_fopen(path, "wb");
      if (file == nullptr) {
        return;
      }
    }
    const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() -
                                                                start_)
                          .count();
    fprintf(file, "{\"part\":\"%s\",\"ms\":%.3f}\n", part_, ms);
    if (++lines % 100 == 0) {
      fflush(file);
    }
  }
};

/** Call \a fn, timed as \a part of a snapshot, see #BridgeTimer. */
template<typename Fn> auto bridge_timed(const char *part, Fn fn)
{
  BridgeTimer timer(part);
  return fn();
}

}  // namespace blender
