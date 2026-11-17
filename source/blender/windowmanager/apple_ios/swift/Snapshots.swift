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
 * - `size <width> <height>`: ask Stage Manager for a window this size, in points (the scene's
 *   size restrictions, set to it and put back when the script ends);
 * - `rail <leading|trailing|top|bottom>`: the edge the tool rail rests on;
 * - `stack <actions|operation|item> <open|fold>`: open or fold a piece of the bottom row, see
 *   #BottomStackState (`operation open` opens the last operation's strip, if there is one);
 * - `tab <ID>`: open Properties on a tab, such as `tab MATERIAL` or `tab SIDEBAR:Item`;
 * - `op <IDNAME> [name=value ...]`: run a Blender operator, as a button runs it;
 * - `pad open|close`: the number pad of a waiting operation;
 * - `panel <key end> open|close`: a Properties panel, such as `panel PT_surface open`;
 * - `wait <seconds>`;
 * - `shot <name>`: every window of the scene, drawn into `tmp/shots/<name>.png`.
 *
 * Launch with `PLATYPUS_SCRATCH_DOCUMENT=1` too: the app then opens a fresh copy of the General
 * template instead of the last document, and `send` and `tool` steps run only there.
 *
 * The viewport may come out black: the chrome is what is checked.
 */

import SwiftUI
import UIKit

@MainActor
enum ShellSnapshots {
  private static var started = false

  static func start() {
    if !started { ShellLayout.selfTest() }
    guard !started, let script = ProcessInfo.processInfo.environment["PLATYPUS_SNAPSHOT_SCRIPT"] else { return }
    started = true
    let steps = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    /* The person's own style, put back when the script ends: a script must not change settings. */
    let style = UserDefaults.standard.string(forKey: ShellStyle.key)
    let rail = UserDefaults.standard.string(forKey: "BlenderToolRailEdge")
    let restrictions = scene?.sizeRestrictions.map { ($0.minimumSize, $0.maximumSize) }
    Task { @MainActor in
      defer {
        UserDefaults.standard.set(style, forKey: ShellStyle.key)
        UserDefaults.standard.set(rail, forKey: "BlenderToolRailEdge")
        if let restrictions, let limits = scene?.sizeRestrictions {
          limits.minimumSize = restrictions.0
          limits.maximumSize = restrictions.1
        }
      }
      /* The window and Blender's first views first. */
      for _ in 0..<200 where ShellModel.current == nil {
        try? await Task.sleep(for: .milliseconds(100))
      }
      try? await Task.sleep(for: .seconds(3))
      /* Steps that edit (`send`, `tool`) run only in the check's own copy of the General template
       * (`PLATYPUS_SCRATCH_DOCUMENT`, see `wm_apple_ios_launcher.mm`): a document saves itself,
       * and a script must never change someone's work. */
      let path = wm_apple_ios_document_url()?.path ?? ""
      let scratch = path.contains("/platypus-scratch/")
      WM_native_ui_log("snapshot", "script in \(scratch ? "scratch document" : "a person's document") \((path as NSString).lastPathComponent)")
      for step in steps {
        let verb = step.split(separator: " ").first.map(String.init) ?? ""
        if !scratch && ["send", "tool", "op", "panel"].contains(verb) {
          WM_native_ui_log("snapshot", "refused outside the scratch document: \(step)")
          continue
        }
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
      case "size":
        guard words.count >= 2, let width = Double(words[0]), let height = Double(words[1]),
              let limits = scene?.sizeRestrictions else { break }
        let size = CGSize(width: width, height: height)
        limits.minimumSize = size
        limits.maximumSize = size
        try? await Task.sleep(for: .seconds(2))
        let bounds = scene?.coordinateSpace.bounds.size ?? .zero
        WM_native_ui_log("snapshot", "size \(Int(width))x\(Int(height)) asked, \(Int(bounds.width))x\(Int(bounds.height)) given")
      case "rail":
        if let edge = words.first, RailEdge(rawValue: edge) != nil {
          UserDefaults.standard.set(edge, forKey: "BlenderToolRailEdge")
        }
        try? await Task.sleep(for: .milliseconds(600))
      case "stack":
        guard words.count >= 2, let model = ShellModel.current, ["open", "fold"].contains(words[1]) else {
          WM_native_ui_log("snapshot", "unknown step: \(step)")
          break
        }
        let open = words[1] == "open"
        withAnimation(.easeOut(duration: 0.2)) {
          switch words[0] {
            case "actions":
              model.stack.actionsOpen = open
            case "operation":
              let key = ShellPanels.current?.panels.redo.operationKey
              if open && key == nil { WM_native_ui_log("snapshot", "stack operation open: no last operation") }
              model.stack.redoOpenID = open ? key : nil
            case "item":
              model.stack.itemFolded = !open
            default:
              WM_native_ui_log("snapshot", "unknown step: \(step)")
          }
        }
        try? await Task.sleep(for: .milliseconds(600))
      case "tab":
        /* Properties, open on the tab, as a reveal opens it (ROUND5 7A.4). */
        guard let tab = words.first, let panels = SwiftScenePanels.current else {
          WM_native_ui_log("snapshot", "unknown step: \(step)")
          break
        }
        panels.setInspectorShown(true)
        try? await Task.sleep(for: .milliseconds(600))
        panels.properties.selectTab(tab)
        try? await Task.sleep(for: .seconds(1))
      case "op":
        /* A Blender operator, as a button runs it: `op OBJECT_OT_modifier_add type=BEVEL`. */
        guard let name = words.first else { break }
        var properties: [String: NativeValue] = [:]
        for pair in words.dropFirst().joined(separator: " ").split(separator: " ") {
          let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
          guard parts.count == 2 else { continue }
          properties[parts[0]] = Double(parts[1]).map { .float($0) } ?? .text(parts[1])
        }
        Operators.run(name, properties)
        try? await Task.sleep(for: .milliseconds(600))
      case "pad":
        /* The number pad of a waiting operation, as its 123 button shows it. */
        withAnimation(.easeOut(duration: 0.18)) { NumberPadState.shared.shown = words.first == "open" }
        try? await Task.sleep(for: .milliseconds(600))
      case "panel":
        /* A Properties panel opened or closed by the end of its key: `panel PT_surface open`. */
        guard words.count >= 2, let properties = SwiftScenePanels.current?.properties,
              let panel = properties.panels.first(where: { $0.key.hasSuffix(words[0]) }) else {
          WM_native_ui_log("snapshot", "unknown step: \(step)")
          break
        }
        properties.setOpen(panel, words[1] == "open")
        try? await Task.sleep(for: .seconds(1))
      case "wait":
        try? await Task.sleep(for: .seconds(Double(words.first ?? "") ?? 0.5))
      case "shot":
        shot(words.first ?? "shot")
      default:
        WM_native_ui_log("snapshot", "unknown step: \(step)")
    }
  }

  private static var scene: UIWindowScene? {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
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
