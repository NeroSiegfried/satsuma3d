/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Pictures of the interface, taken on the device by a script, for checking the chrome without
 * someone looking at the screen. With `PLATYPUS_SNAPSHOT_SCRIPT` in the environment, its steps,
 * separated by `;`, run once after the window opens:
 *
 * - `send <target> <op> [value]`: a command to the toolbar's view, as the shell sends it, such
 *   as `send mode set EDIT`, `send action:mesh.subdivide invoke`, `send repeat invoke`;
 * - `tool <id>`: make a tool active, such as `tool builtin.scale`;
 * - `style blender|glass`: the interface style;
 * - `wait <seconds>`;
 * - `shot <name>`: every window of the scene, drawn into `tmp/shots/<name>.png`.
 *
 * The viewport may come out black: the chrome is what is checked.
 */

import SwiftUI
import UIKit

@MainActor
enum ShellSnapshots {
  private static var started = false

  static func start() {
    guard !started, let script = ProcessInfo.processInfo.environment["PLATYPUS_SNAPSHOT_SCRIPT"] else { return }
    started = true
    let steps = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    /* The person's own style, put back when the script ends: a script must not change settings. */
    let style = UserDefaults.standard.string(forKey: ShellStyle.key)
    Task { @MainActor in
      defer { UserDefaults.standard.set(style, forKey: ShellStyle.key) }
      /* The window and Blender's first views first. */
      for _ in 0..<200 where ShellModel.current == nil {
        try? await Task.sleep(for: .milliseconds(100))
      }
      try? await Task.sleep(for: .seconds(3))
      for step in steps {
        await run(step)
      }
      WM_native_ui_log("snapshot", "script done")
    }
  }

  private static let ops: [String: Blender_NativeUI_Op] = [
    "set": .set_, "invoke": .invoke, "open": .open_, "close": .close, "activate": .activate,
  ]

  private static func run(_ step: String) async {
    var words = step.split(separator: " ", maxSplits: 3).map(String.init)
    guard !words.isEmpty else { return }
    let verb = words.removeFirst()
    switch verb {
      case "send":
        guard words.count >= 2, let op = ops[words[1]] else { break }
        let value: NativeValue? = words.count > 2 ? (Double(words[2]).map { .float($0) } ?? .text(words[2])) : nil
        ShellModel.current?.send(words[0], op, value)
        try? await Task.sleep(for: .milliseconds(400))
      case "tool":
        if let id = words.first { ShellModel.current?.setTool(id) }
        try? await Task.sleep(for: .milliseconds(400))
      case "style":
        UserDefaults.standard.set(words.first == "glass" ? ShellStyle.glass.rawValue : ShellStyle.blender.rawValue,
                                  forKey: ShellStyle.key)
        try? await Task.sleep(for: .milliseconds(400))
      case "wait":
        try? await Task.sleep(for: .seconds(Double(words.first ?? "") ?? 0.5))
      case "shot":
        shot(words.first ?? "shot")
      default:
        WM_native_ui_log("snapshot", "unknown step: \(step)")
    }
  }

  private static func shot(_ name: String) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shots")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
      .filter { !$0.isHidden }
    guard let main = windows.first else { return }
    let bounds = main.bounds
    let renderer = UIGraphicsImageRenderer(bounds: bounds)
    let image = renderer.image { _ in
      for window in windows {
        window.drawHierarchy(in: window.convert(window.bounds, to: main), afterScreenUpdates: true)
      }
    }
    let url = folder.appendingPathComponent(name + ".png")
    do {
      try image.pngData()?.write(to: url)
      WM_native_ui_log("snapshot", "shot \(name)")
    }
    catch {
      WM_native_ui_log("snapshot", "shot \(name) failed: \(error.localizedDescription)")
    }
  }
}
