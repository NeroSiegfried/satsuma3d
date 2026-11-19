/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The app's identity, from its `Info.plist`, where the build's configuration writes it
 * (`IOS_PRODUCT_NAME`, `IOS_MARKETING_VERSION`, `IOS_BUNDLE_VERSION`, `IOS_SOURCE_URL`, in
 * `source/creator/CMakeLists.txt`). Nothing in the shell types the app's name, version or source
 * address itself (ROUND5 8A, constraint D2). Objective-C reads the same keys, see
 * `wm_apple_ios_app_name`.
 */

import Foundation

enum AppIdentity {
  private static func value(_ key: String) -> String? {
    guard let text = Bundle.main.object(forInfoDictionaryKey: key) as? String, !text.isEmpty else { return nil }
    return text
  }

  /** The name the app calls itself, as on the Home Screen. */
  static let name: String = value("CFBundleDisplayName") ?? value("CFBundleName") ?? ProcessInfo.processInfo.processName
  /** The app's own version, as "0.1.0". */
  static let version: String = value("CFBundleShortVersionString") ?? ""
  /** The build number, as "1". */
  static let build: String = value("CFBundleVersion") ?? ""
  /** The version of Blender the app is based on, as "5.1.2". */
  static let blenderVersion: String = value("SatsumaBlenderVersion") ?? ""
  /** Where the complete source is published; empty for a development build that has none yet. */
  static let sourceURL: String = value("SatsumaSourceURL") ?? ""
  /** The commit the app was built from. */
  static let sourceCommit: String = value("SatsumaSourceCommit") ?? ""
  /** A development build: its identifier ends in `.dev`. */
  static let isDevelopment: Bool = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false

  /** "0.1.0 (1)". */
  static var versionAndBuild: String { build.isEmpty ? version : "\(version) (\(build))" }
}

/** `AppIdentity` for Objective-C, so the app's version is read in this file only (the packaging
 * test `test_versions_kept_apart` keeps it apart from Blender's). */
@objc(WMIOSAppIdentity)
final class AppIdentityObjC: NSObject {
  /** "0.1.0 (1)", or "?" when the build wrote no version. */
  @objc static var versionAndBuild: String { AppIdentity.version.isEmpty ? "?" : AppIdentity.versionAndBuild }
}
