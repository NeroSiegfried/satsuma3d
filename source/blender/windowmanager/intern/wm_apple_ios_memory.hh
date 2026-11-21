/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * The iPad's start-up memory preferences (ROUND6 BUSY-5, G10), until the memory governor (PLAN
 * M5) exists. Blender's defaults are a desktop's: undo memory unlimited, a 4 GB cache, no texture
 * limit; on an iPad each of them alone can take what iOS allows the app, which then ends it. Each
 * is capped by a share of the memory iOS lets this app use at launch: a person's lower value is
 * kept, an unlimited or higher one is brought down.
 *
 * Built alone for the Mac by `tests/ios/test_memory_caps.py`: it uses only the standard library.
 */

#pragma once

#include <algorithm>
#include <cstdint>

namespace blender::wm::apple_ios {

struct MemoryCaps {
  /** `U.undomemory`'s cap, in megabytes: a quarter of what the app may use. */
  int undo_megabytes = 0;
  /** `U.memcachelimit`'s cap (sequencer, clips, image sequences), in megabytes: an eighth. */
  int cache_megabytes = 0;
  /** `U.glreslimit`'s cap in pixels on the 8 GB tier and below, 0 for none above it. */
  int texture_limit = 0;
};

/**
 * The memory the caps are shares of. `os_proc_available_memory` is what is left of the app's
 * limit, and iPadOS counts compressed and swapped pages against that limit, so on an iPad with
 * swap it can exceed the RAM itself (device round: 8158 MB left on a 7520 MB iPad). What lives in
 * the RAM is the most the caches can count on: never more than \a physical_bytes when that is
 * known; half of it when the allowance is unknown (0).
 */
inline uint64_t memory_caps_base(const uint64_t available_bytes, const uint64_t physical_bytes)
{
  if (available_bytes == 0) {
    return physical_bytes / 2;
  }
  return physical_bytes ? std::min(available_bytes, physical_bytes) : available_bytes;
}

/**
 * \param available_bytes: what iOS lets the app allocate now (`os_proc_available_memory`), 0 when
 * unknown; see #memory_caps_base.
 * \param physical_bytes: the device's memory (`hw.memsize`).
 */
inline MemoryCaps memory_caps(const uint64_t available_bytes, const uint64_t physical_bytes)
{
  constexpr uint64_t megabyte = 1024 * 1024;
  constexpr uint64_t gigabyte = 1024 * megabyte;
  const uint64_t available = memory_caps_base(available_bytes, physical_bytes);
  const int64_t available_megabytes = int64_t(available / megabyte);
  MemoryCaps caps;
  caps.undo_megabytes = int(std::clamp<int64_t>(available_megabytes / 4, 256, 4096));
  caps.cache_megabytes = int(std::clamp<int64_t>(available_megabytes / 8, 128, 2048));
  /* An "8 GB" iPad reports a little less than 8 GB. */
  caps.texture_limit = physical_bytes <= 8 * gigabyte + gigabyte / 2 ? 4096 : 0;
  return caps;
}

/** Bring each preference down to its cap: 0 means unlimited for undo memory and textures. */
inline void memory_caps_apply(const MemoryCaps &caps,
                              int &undomemory,
                              int &memcachelimit,
                              int &glreslimit)
{
  if (undomemory == 0 || undomemory > caps.undo_megabytes) {
    undomemory = caps.undo_megabytes;
  }
  memcachelimit = std::min(memcachelimit, caps.cache_megabytes);
  if (caps.texture_limit && (glreslimit == 0 || glreslimit > caps.texture_limit)) {
    glreslimit = caps.texture_limit;
  }
}

}  // namespace blender::wm::apple_ios
