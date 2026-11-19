/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * About and Licences (ROUND5 8C): the app's name and version, that it is independent of the
 * Blender Foundation, the credits, the GPL and the third-party notices as the app carries them,
 * where its source is, and the session's log to share. One page, `AboutPage`: the last page of
 * Settings, and a sheet of its own from the launcher and the app menu (`SwiftAbout`).
 *
 * No licence text is typed here: each is read from `Assets/text` in the app, which the build
 * installs from Blender's own `release/license` (`WITH_INSTALL_COPYRIGHT`).
 */

import SwiftUI
import UIKit

/* -------------------------------------------------------------------- */
/** \name Licence Files
 * \{ */

/** A licence or notice the app carries, opened from a row. */
struct LicenceDocument: Identifiable, Hashable {
  let id: String
  let title: String
  let text: String
}

enum LicenceFiles {
  /** `Assets/text` in the app. */
  static var folder: URL? {
    Bundle.main.resourceURL?.appendingPathComponent("Assets/text", isDirectory: true)
  }

  private static func read(_ relative: String) -> String? {
    guard let url = folder?.appendingPathComponent(relative) else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
  }

  /** The GNU GPL the app is distributed under, as the app carries it: version 3 or later, which
   * the whole is under through its dependencies, and version 2 or later, Blender's own code's. */
  static let licences: [LicenceDocument] = [
    ("GPL-3.0-or-later", "GNU General Public License v3.0 or later"),
    ("GPL-2.0-or-later", "GNU General Public License v2.0 or later"),
  ].compactMap { id, title in
    read("license/spdx/\(id).txt").map { LicenceDocument(id: id, title: title, text: $0) }
  }

  /** The third-party notices: the copyright notice (`copyright.txt`), then each licence of
   * `license/license.md` with the libraries it covers. */
  static let notices: [LicenceDocument] = {
    var result: [LicenceDocument] = []
    if let copyright = read("copyright.txt") {
      result.append(LicenceDocument(id: "copyright", title: "Copyright Notice", text: copyright))
    }
    guard let markdown = read("license/license.md") else { return result }
    /* Each licence's section starts `## [Name](address)`, or `## Name`. */
    var title: String?
    var lines: [Substring] = []
    func close() {
      guard let title else { return }
      var body = lines.joined(separator: "\n")
      for tag in ["<details>", "</details>", "<summary>", "</summary>"] {
        body = body.replacingOccurrences(of: tag, with: "")
      }
      result.append(LicenceDocument(id: "notice:" + title, title: title,
                                    text: body.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("## ") {
        close()
        var heading = line.dropFirst(3)
        if heading.hasPrefix("["), let end = heading.firstIndex(of: "]") {
          heading = heading[heading.index(after: heading.startIndex)..<end]
        }
        title = String(heading)
        lines = []
      }
      else if title != nil {
        lines.append(line)
      }
    }
    close()
    return result
  }()
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Session Log
 * \{ */

enum SessionLogShare {
  /** What the log holds, said truthfully from its writers (`WM_native_ui_session_log`), in both
   * interfaces; `bl_native_shell_sources.py` holds each kind of line to a phrase here. Settings,
   * messages and documents can name files and objects. */
  static let description = "The session log lists the commands you ran with their settings, the messages the app "
    + "showed, when documents opened and saved, which interface showed, window and viewport sizes, layout checks, "
    + "the steps of developer checks, the gestures on the navigation gizmo, when side panels opened and closed, "
    + "this iPad's chip and memory, the kinds of finger gestures on the Desktop Interface's controls and what fingers do, "
    + "input that arrived while a sheet was open, on the sheet or behind it, "
    + "each launch with the app's version, this iPad's model and the memory available, "
    + "whether the last session ended cleanly, why iOS ended the app when it reports it, "
    + "whether a render could go on in the background and why it paused, "
    + "the memory limits set at launch and what was freed when memory ran low, "
    + "and a mark at most once a minute while the app is in use. It can include "
    + "the names of your files and objects. It stays on this iPad unless you share it."

  /** Write the log out and share a copy of it from \a presenter, or say why there is none. */
  @MainActor
  static func share(from presenter: UIViewController, source: UIView?) {
    var buffer = [CChar](repeating: 0, count: 1024)
    let exists = WM_native_ui_session_log_file(&buffer, buffer.count)
    let path = String(cString: buffer)
    let copy = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(AppIdentity.name) Session Log.txt")
    do {
      guard exists else { throw CocoaError(.fileNoSuchFile) }
      try? FileManager.default.removeItem(at: copy)
      try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
    }
    catch {
      let alert = UIAlertController(title: "No Session Log",
                                    message: "Nothing has been logged in this session yet.", preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "OK", style: .default))
      presenter.present(alert, animated: true)
      return
    }
    let activity = UIActivityViewController(activityItems: [copy], applicationActivities: nil)
    activity.popoverPresentationController?.sourceView = source ?? presenter.view
    if source == nil {
      activity.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                                                  y: presenter.view.bounds.midY, width: 1, height: 1)
    }
    presenter.present(activity, animated: true)
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name View
 * \{ */

/** A row of About: its text, with what VoiceOver reads for it. */
private struct AboutRow: View {
  let title: String
  var detail: String? = nil
  var symbol: String? = nil

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      if let symbol {
        Image(systemName: symbol).frame(width: 28).foregroundStyle(.tint)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title).foregroundStyle(.primary)
        if let detail {
          Text(detail).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
  }
}

/** A licence's text, as the app carries it. */
private struct LicenceTextView: View {
  let document: LicenceDocument

  var body: some View {
    ScrollView {
      /* Long texts are laid out a paragraph at a time. */
      LazyVStack(alignment: .leading, spacing: 10) {
        ForEach(Array(document.text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
          Text(paragraph)
            .font(.system(.footnote, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .textSelection(.enabled)
      .padding()
    }
    .navigationTitle(document.title)
    .navigationBarTitleDisplayMode(.inline)
  }
}

/** About the app, from top to bottom: who it is, its credits, its licences, its source, its log. */
struct AboutPage: View {
  /** Where the share sheet comes from: the controller showing this page. */
  var presenter: () -> UIViewController? = { AboutPage.topmost() }

  /** The controller on top of the key window, which shows this page wherever it is. */
  @MainActor
  static func topmost() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  private var sourceRow: AboutRow {
    let commit = AppIdentity.sourceCommit.isEmpty ? nil : "Commit \(AppIdentity.sourceCommit)"
    if AppIdentity.sourceURL.isEmpty {
      return AboutRow(title: "Development build: source not published", detail: commit,
                      symbol: "chevron.left.forwardslash.chevron.right")
    }
    return AboutRow(title: AppIdentity.sourceURL, detail: commit, symbol: "chevron.left.forwardslash.chevron.right")
  }

  var body: some View {
    List {
      Section {
        VStack(alignment: .leading, spacing: 4) {
          Text(AppIdentity.name).font(.title2.weight(.semibold))
          Text("Version \(AppIdentity.versionAndBuild)").foregroundStyle(.secondary)
          Text("Based on Blender \(AppIdentity.blenderVersion)").foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(AppIdentity.name), version \(AppIdentity.versionAndBuild), "
          + "based on Blender \(AppIdentity.blenderVersion)")
        AboutRow(title: "\(AppIdentity.name) is an independent project. It is not affiliated with or endorsed by "
          + "the Blender Foundation.")
        /* Below the device floor, for as long as it is true (ROUND5 8N). */
        if let floor = DeviceFloorNotice.aboutSentence {
          AboutRow(title: floor, symbol: "exclamationmark.triangle")
        }
      }

      Section {
        Link(destination: URL(string: "https://www.blender.org")!) {
          AboutRow(title: "The Blender project and its contributors", detail: "blender.org", symbol: "heart")
        }
        AboutRow(title: "William Reynish", detail: "For the native iPadOS interface this app is built on",
                 symbol: "ipad.landscape")
      } header: {
        Text("Credits")
      }

      Section {
        ForEach(LicenceFiles.licences) { document in
          NavigationLink(value: document) { AboutRow(title: document.title, symbol: "doc.text") }
        }
        if LicenceFiles.licences.isEmpty {
          AboutRow(title: "The licence text is missing from this build", symbol: "exclamationmark.triangle")
        }
      } header: {
        Text("Licence")
      }

      Section {
        ForEach(LicenceFiles.notices) { document in
          NavigationLink(value: document) { AboutRow(title: document.title) }
        }
        if LicenceFiles.notices.isEmpty {
          AboutRow(title: "The notices are missing from this build", symbol: "exclamationmark.triangle")
        }
      } header: {
        Text("Third-Party Notices")
      }

      Section {
        if let url = URL(string: AppIdentity.sourceURL), !AppIdentity.sourceURL.isEmpty {
          Link(destination: url) { sourceRow }
        }
        else {
          sourceRow
        }
      } header: {
        Text("Source Code")
      }

      Section {
        Button {
          if let presenter = presenter() { SessionLogShare.share(from: presenter, source: nil) }
        } label: {
          AboutRow(title: "Share Session Log", symbol: "square.and.arrow.up")
        }
      } footer: {
        Text(SessionLogShare.description)
      }
    }
    .navigationDestination(for: LicenceDocument.self) { document in
      LicenceTextView(document: document)
    }
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Controller
 * \{ */

/** About as a sheet of its own, from the launcher and the app menu. */
@MainActor
@objc(WMIOSSwiftAbout)
public final class SwiftAbout: NSObject {
  private static weak var shown: UIViewController?

  /** Present About from \a presenter, once. */
  @objc public static func present(from presenter: UIViewController) {
    guard shown == nil else { return }
    var top = presenter
    while let presented = top.presentedViewController { top = presented }
    weak var sheet: UIViewController?
    let view = NavigationStack {
      AboutPage(presenter: { sheet })
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { sheet?.dismiss(animated: true) }
          }
        }
    }
    let controller = UIHostingController(rootView: view)
    controller.modalPresentationStyle = .formSheet
    controller.preferredContentSize = CGSize(width: 620, height: 760)
    sheet = controller
    shown = controller
    top.present(controller, animated: true)
  }

  /** Close About, if it shows. */
  static func dismiss() {
    shown?.dismiss(animated: false)
  }
}

/** \} */
