/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The device floor (ROUND5 8N, decision 96): the app is made for iPads with an M-series chip and
 * 8 GB of memory, and Apple has no install requirement meaning that, so any iPad on iPadOS 27 can
 * install a tester build. #DeviceFloor.verdict is the one rule, a pure function, tested on the Mac
 * by `tests/ios/test_device_floor.py`; `DeviceFloorNotice.swift` reads the device, logs the
 * verdict at every launch, and below the floor says so once per app version (and in About).
 * This file uses Foundation only, so the test can build it alone.
 */

import Foundation

enum DeviceFloor {
  enum Verdict: String {
    case atFloor = "at_floor"
    case below = "below"
    /** A chip name the rule does not know: treated as at the floor, and logged. */
    case unknown = "unknown"
  }

  /** The least memory at the floor. An 8 GB iPad reports a little under 8 GiB, so 7. */
  static let minimumMemoryBytes: UInt64 = 7 << 30

  /** The chip's family and generation from the GPU's name, such as "Apple M1 GPU" (M, 1) or
   * "Apple A16 GPU" (A, 16); nil for a name of another form. */
  static func chip(_ name: String?) -> (family: Character, generation: Int)? {
    guard let name else { return nil }
    let words = name.split(separator: " ")
    guard words.count >= 2, words[0] == "Apple", let family = words[1].first, family == "M" || family == "A",
          let generation = Int(words[1].dropFirst()), generation > 0 else { return nil }
    return (family, generation)
  }

  /**
   * At the floor, below it, or not known, from the GPU's name (`MTLDevice.name`, nil when it could
   * not be read) and the memory the system reports. Less memory than #minimumMemoryBytes is below
   * whatever the chip; then an M-series chip is at the floor, an A-series one below, and any other
   * name not known.
   */
  static func verdict(chipName: String?, memoryBytes: UInt64) -> Verdict {
    if memoryBytes < minimumMemoryBytes {
      return .below
    }
    switch chip(chipName)?.family {
      case "M": return .atFloor
      case "A": return .below
      default: return .unknown
    }
  }

  /** Memory in whole gigabytes as the iPad is sold: the system reports a little less than that
   * (an 8 GB iPad about 7.5 GiB, a 6 GB one about 5.6), so the next whole number up. */
  static func gigabytes(_ bytes: UInt64) -> Int {
    Int((Double(bytes) / Double(1 << 30) - 0.001).rounded(.up))
  }

  /** The chip as a person names it: "Apple A16 GPU" reads "Apple A16"; nil when not known. */
  static func chipLabel(_ name: String?) -> String? {
    guard let name, chip(name) != nil else { return nil }
    return name.hasSuffix(" GPU") ? String(name.dropLast(4)) : name
  }

  /** What the notice and About say below the floor. Without a chip name it says the memory only. */
  static func sentence(appName: String, chipName: String?, memoryBytes: UInt64) -> String {
    let memory = "\(gigabytes(memoryBytes)) GB"
    let has = chipLabel(chipName).map { "\($0), \(memory)" } ?? memory
    return "\(appName) is made for iPads with an M-series chip and 8 GB of memory. This iPad has \(has). "
      + "Large scenes may run out of memory, and this iPad has not been tested."
  }

  /** The session log's line (N3), after its kind `device`. */
  static func logLine(chipName: String?, memoryBytes: UInt64, verdict: Verdict, pretend: Bool) -> String {
    let memory = String(format: "%.1fGB", Double(memoryBytes) / Double(1 << 30))
    return "floor: chip=\(chipName ?? "unread") memory=\(memory) verdict=\(verdict.rawValue)"
      + (pretend ? " (pretend)" : "")
  }

  /** `PLATYPUS_PRETEND_DEVICE="<name>,<GB>"` (N4), such as "Apple A16 GPU,6": nil when absent or
   * malformed. The caller honours it only in a check launch (`PLATYPUS_SCRATCH_DOCUMENT`). */
  static func pretend(_ value: String?) -> (name: String, memoryBytes: UInt64)? {
    guard let value, let comma = value.lastIndex(of: ",") else { return nil }
    let name = value[..<comma].trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, let gigabytes = Double(value[value.index(after: comma)...].trimmingCharacters(in: .whitespaces)),
          gigabytes > 0 else { return nil }
    return (name, UInt64(gigabytes * Double(1 << 30)))
  }
}
