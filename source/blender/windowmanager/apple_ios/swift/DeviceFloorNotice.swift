/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * An iPad below the floor is told so (ROUND5 8N). At every launch the session log says what the
 * app read and decided (`device floor: chip=… memory=… verdict=…`, N3). Below the floor, the first
 * launch of each app version shows one alert with Continue, and the app then runs as usual (N2,
 * decision 96); About says the same for as long as it is true. The rule is #DeviceFloor.verdict
 * (`DeviceFloor.swift`).
 *
 * A check launch (`PLATYPUS_SCRATCH_DOCUMENT`) may pretend to be another iPad with
 * `PLATYPUS_PRETEND_DEVICE="<GPU name>,<GB>"` (N4), so the notice can be seen on an iPad at the
 * floor. A pretended or check launch shows the notice every time and records nothing.
 *
 * Asked by the launcher (`viewDidAppear`, through `WMIOSSwiftDeviceFloor`) and by a document's
 * window (`DocumentWindow`), whichever comes first; the notice shows once per launch at most.
 */

import Metal
import UIKit

@MainActor
@objc(WMIOSSwiftDeviceFloor)
public final class DeviceFloorNotice: NSObject {
  /** What this iPad is, read once per launch. */
  struct Reading {
    let chipName: String?
    let memoryBytes: UInt64
    let pretend: Bool
    var verdict: DeviceFloor.Verdict {
      DeviceFloor.verdict(chipName: chipName, memoryBytes: memoryBytes)
    }
    var sentence: String {
      DeviceFloor.sentence(appName: AppIdentity.name, chipName: chipName, memoryBytes: memoryBytes)
    }
  }

  /** The defaults key holding the app version the notice was last shown for. */
  static let shownKey = "SatsumaDeviceFloorNoticeVersion"

  private static var checkLaunch: Bool {
    ProcessInfo.processInfo.environment["PLATYPUS_SCRATCH_DOCUMENT"] != nil
  }

  static let reading: Reading = {
    let environment = ProcessInfo.processInfo.environment
    if checkLaunch, let pretend = DeviceFloor.pretend(environment["PLATYPUS_PRETEND_DEVICE"]) {
      return Reading(chipName: pretend.name, memoryBytes: pretend.memoryBytes, pretend: true)
    }
    return Reading(chipName: MTLCreateSystemDefaultDevice()?.name, memoryBytes: ProcessInfo.processInfo.physicalMemory,
                   pretend: false)
  }()

  /** About's sentence: nil at the floor or when not known. */
  static var aboutSentence: String? {
    reading.verdict == .below ? reading.sentence : nil
  }

  private static var logged = false
  private static var asked = false
  private static weak var shown: UIAlertController?

  /** Log the reading once per launch; below the floor, show the notice unless it was shown for
   * this version already. \a launcher is the launcher when it asks (nil from a document's window);
   * either way the notice goes on what the person sees: the key window's topmost controller,
   * waiting while a document opens behind the launcher, whose window would cover it. */
  @objc(presentIfNeededFrom:) public static func presentIfNeeded(from launcher: UIViewController?) {
    let reading = Self.reading
    if !logged {
      logged = true
      WM_native_ui_log("device", DeviceFloor.logLine(chipName: reading.chipName, memoryBytes: reading.memoryBytes,
                                                     verdict: reading.verdict, pretend: reading.pretend))
    }
    guard !asked, reading.verdict == .below else { return }
    let version = AppIdentity.versionAndBuild
    let record = !reading.pretend && !checkLaunch
    if record && UserDefaults.standard.string(forKey: shownKey) == version {
      return
    }
    asked = true
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1))
      /* A document opening: its window becomes the key one shortly (at most 5 s more). */
      for _ in 0..<10 where wm_apple_ios_document_url() != nil && launcher?.view.window?.isKeyWindow == true {
        try? await Task.sleep(for: .milliseconds(500))
      }
      guard let top = AboutPage.topmost() else {
        WM_native_ui_log("device", "floor notice: no window to show it on")
        return
      }
      let alert = UIAlertController(title: nil, message: reading.sentence, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "Continue", style: .default) { _ in
        WM_native_ui_log("device", "floor notice: continue")
      })
      shown = alert
      top.present(alert, animated: true)
      if record {
        UserDefaults.standard.set(version, forKey: shownKey)
      }
      WM_native_ui_log("device", "floor notice shown for \(version)\(record ? "" : " (not recorded: check launch)")")
    }
  }

  /** The notice's Continue, as its button does (a script's `floor continue`). False when none shows. */
  static func continueNotice() -> Bool {
    guard let alert = shown, alert.presentingViewController != nil else { return false }
    alert.dismiss(animated: false)
    WM_native_ui_log("device", "floor notice: continue")
    return true
  }
}
