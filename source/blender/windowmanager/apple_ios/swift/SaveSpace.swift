/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Free space before a save (ROUND5 8I.5, decision 45). Before Save and Save As the app reads the
 * free space of the volume it writes to, and when it is low says so, with Save Anyway and Cancel:
 * a save never fails unannounced for want of room, and never is skipped without the person
 * choosing. This is the use Apple's reason E174.1 describes for the disk-space category in
 * `release/ios/PrivacyInfo.xcprivacy` ("check whether there is sufficient disk space to write
 * files"); the figure never leaves the device.
 *
 * #SaveSpace.warning is the one rule, a pure function, tested on the Mac by
 * `tests/ios/test_save_space.py`. The shell's Save As asks it directly (`ShellCommands`); Blender's
 * Save and Save As operators ask it through `wm_apple_ios_save_space_warning`. This file uses
 * Foundation only, so the test can build it alone.
 */

import Foundation

@objc(WMIOSSaveSpace)
final class SaveSpace: NSObject {
  /** The least free space a save is made without asking: 200 MB, as Settings counts (decimal). */
  static let floorBytes: Int64 = 200_000_000

  /**
   * The warning for a save with \a freeBytes free on the volume, of a file whose last saved size
   * is \a lastSavedBytes (0 for a file never saved): nil when there is room, which is at least
   * the larger of twice that size and #floorBytes. A negative free space is unknown: nil.
   */
  static func warning(freeBytes: Int64, lastSavedBytes: Int64) -> String? {
    guard freeBytes >= 0 else { return nil }
    let needed = max(2 * max(lastSavedBytes, 0), floorBytes)
    guard freeBytes < needed else { return nil }
    return "Low storage: \(freeBytes / 1_000_000) MB free."
  }

  /** What the warning's alert says under its title, and its buttons. */
  static let detail = "The save may fail."
  static let saveAnyway = "Save Anyway"
  static let cancel = "Cancel"

  /** The free space for important writes on the volume holding \a path (or the app's temporary
   * folder when \a path is empty), or -1 when it cannot be read. */
  static func freeBytes(near path: String) -> Int64 {
    let place = path.isEmpty ? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) :
      URL(fileURLWithPath: path).deletingLastPathComponent()
    guard let values = try? place.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
          let free = values.volumeAvailableCapacityForImportantUsage
    else { return -1 }
    return free
  }

  /** The size of the file at \a path as last saved, 0 when there is none. */
  static func savedBytes(at path: String) -> Int64 {
    guard !path.isEmpty,
          let size = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize
    else { return 0 }
    return Int64(size)
  }

  /**
   * The warning for saving the file at \a path, read from the device, as `[status, title, detail,
   * Save Anyway, Cancel]`: status `low` with the rest, or `room` or `unknown` alone. When the free
   * space cannot be read the save goes ahead; the caller logs which it was.
   */
  @objc(warningForSavingAt:)
  static func warning(forSavingAt path: String) -> [String] {
    let free = freeBytes(near: path)
    guard free >= 0 else { return ["unknown"] }
    guard let title = warning(freeBytes: free, lastSavedBytes: savedBytes(at: path)) else { return ["room"] }
    return ["low", title, detail, saveAnyway, cancel]
  }
}
