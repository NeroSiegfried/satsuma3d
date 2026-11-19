/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * What the session log says about launches and ends (ROUND6 SAFE-4): a dated launch line with the
 * version, the device and the memory available; whether the last session ended cleanly (the
 * launcher's marker, see `wm_apple_ios_launcher.mm`); and the system's own reasons for earlier
 * exits (memory, watchdog, crash), which MetricKit hands over at a later launch. A kill leaves
 * nothing in the app itself, so this is the only trace a tester can send.
 */

import Foundation
import MetricKit
import os
import UIKit

@objc(WMIOSSessionDiagnostics)
final class SessionDiagnostics: NSObject, MXMetricManagerSubscriber {
  private static let shared = SessionDiagnostics()

  /** Called once, as the launcher loads: `lastSession` says how the last session ended when it
   * did not end cleanly, nil otherwise. */
  @objc(startWithLastSession:)
  static func start(lastSession: String?) {
    WM_native_ui_log("launch", launchLine())
    WM_native_ui_log("launch", lastSession ?? "the last session ended cleanly")
    MXMetricManager.shared.add(shared)
    /* What arrived while the app was not running. */
    shared.didReceive(MXMetricManager.shared.pastDiagnosticPayloads)
  }

  private static func launchLine() -> String {
    let version = AppIdentity.version.isEmpty ? "?" : AppIdentity.version
    let build = AppIdentity.build.isEmpty ? "?" : AppIdentity.build
    var system = utsname()
    uname(&system)
    let machine = withUnsafeBytes(of: &system.machine) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
    let available = Double(os_proc_available_memory()) / 1_048_576
    let installed = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
    return String(format: "%@ %@ %@ (%@), %@, %@ %@, memory available %.0f MB of %.0f MB",
                  formatter.string(from: Date()), AppIdentity.name, version, build, machine,
                  UIDevice.current.systemName, UIDevice.current.systemVersion, available, installed)
  }

  /* Daily metrics: how many times the app was ended, and why. */
  func didReceive(_ payloads: [MXMetricPayload]) {
    for payload in payloads {
      guard let exits = payload.applicationExitMetrics else { continue }
      let foreground = exits.foregroundExitData
      let background = exits.backgroundExitData
      let counts: [(String, Int)] = [
        ("foreground memory limit", foreground.cumulativeMemoryResourceLimitExitCount),
        ("foreground watchdog", foreground.cumulativeAppWatchdogExitCount),
        ("foreground crash", foreground.cumulativeBadAccessExitCount +
          foreground.cumulativeIllegalInstructionExitCount + foreground.cumulativeAbnormalExitCount),
        ("background memory limit", background.cumulativeMemoryResourceLimitExitCount),
        ("background memory pressure", background.cumulativeMemoryPressureExitCount),
        ("background watchdog", background.cumulativeAppWatchdogExitCount),
        ("background task time-out", background.cumulativeBackgroundTaskAssertionTimeoutExitCount),
        ("background crash", background.cumulativeBadAccessExitCount +
          background.cumulativeIllegalInstructionExitCount + background.cumulativeAbnormalExitCount),
      ]
      let said = counts.filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }
      if !said.isEmpty {
        WM_native_ui_log("exit", "iOS ended the app (\(payload.timeStampBegin) to \(payload.timeStampEnd)): " +
                                 said.joined(separator: ", "))
      }
    }
  }

  /* Diagnostics: each crash and hang, with what iOS knows of it. */
  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    for payload in payloads {
      for crash in payload.crashDiagnostics ?? [] {
        var parts = ["crash, build \(crash.metaData.applicationBuildVersion)"]
        if let signal = crash.signal { parts.append("signal \(signal)") }
        if let type = crash.exceptionType { parts.append("exception \(type)") }
        if let reason = crash.terminationReason { parts.append(reason) }
        WM_native_ui_log("exit", parts.joined(separator: ", "))
      }
      for hang in payload.hangDiagnostics ?? [] {
        WM_native_ui_log("exit", "hang of \(hang.hangDuration), build \(hang.metaData.applicationBuildVersion)")
      }
    }
  }
}
