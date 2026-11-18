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
 * - `popover shading|close`: the 3D View's shading popover;
 * - `prefs open|close`: Preferences;
 * - `about open|close`: About and Licences, as the app menu and the launcher open it (ROUND5 8C);
 * - `edit <identifier>`: put a number field into editing, as a tap does, so a shot shows the full
 *   value it is typed from (ROUND5 7E.7): the first field shown whose node key ends in it, or
 *   whose `<property>.<label>` it is, such as `location.X` or `scale.X`; logged either way;
 * - `key <NAME> [shift] [ctrl] [alt]`: a key pressed and let go, by Blender's event name (`U`, `F2`,
 *   `SPACE`), as a hardware keyboard sends it, with the pointer at the viewport's middle (ROUND5
 *   9A.9); logged when the key is not known;
 * - `menu close`: close a menu, choice or field a key or step opened, and Search;
 * - `interface desktop|ipad`: Blender's own interface or the iPad's; `interface size <percent>`:
 *   the size of Blender's own (ROUND5 9C); both put back as they were when the script ends;
 *   `interface measure`: Blender's DPI, pixel size and Resolution Scale, written to the log and to
 *   `tmp/interface-measure.txt`;
 * - `editor uv|image open|close`: the UV Editor or the Image Editor, as the editors menu opens it
 *   (ROUND5 9B.7); `editor uv desktop`: its Edit UVs in Desktop Interface; `editor nodes
 *   open|close`: the Shader Editor docked along the bottom (ROUND5 10A);
 * - `sidebar properties|outliner open|close`: Properties or the Outliner, as the header's buttons
 *   show and hide them (ROUND5 10A);
 * - `mark <text>`: a line in the log, to count what a group of steps wrote (ROUND5 10A);
 * - `document <step>`: the document checks of ROUND5 9D.5, in the scratch document only and on
 *   files in its folder: `copy <name>`, `open <name>`, `stat <name>`, `list`, `save`, `reopen`,
 *   `back`, `marker`, `check`, `python <code>`, see `wm_apple_ios_document_check_step`;
 * - `wait <seconds>`;
 * - `shot <name>`: every window of the scene, drawn into `tmp/shots/<name>.png`.
 *
 * Launch with `PLATYPUS_SCRATCH_DOCUMENT=1` too: the app then opens a fresh copy of the General
 * template instead of the last document, and steps that edit run only there. `$SCRATCH` in a step
 * is the scratch document's folder, such as `op WM_OT_open_mainfile filepath=$SCRATCH/Second.blend`.
 *
 * The viewport may come out black: the chrome is what is checked.
 */

import SwiftUI
import UIKit

/** A script's `edit` step: the first number field shown that matches takes it. */
@MainActor
final class NumberFieldEditRequest {
  static let notification = Notification.Name("ShellSnapshotEditNumber")
  let identifier: String
  /** The key of the field that began editing. */
  var claimedBy: String?

  init(identifier: String) { self.identifier = identifier }

  /** Whether \a node is the one asked for. */
  func matches(_ node: NativeNode) -> Bool {
    node.key == identifier || node.key.hasSuffix(identifier) ||
      "\(node.node.property ?? "").\(node.label)" == identifier
  }
}

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
    let editorMode = UserDefaults.standard.string(forKey: ImageEditorModel.modeKey)
    /* The interface the run started in (a launch argument may set it for the run), put back when it
     * ends, as `editor uv desktop` leaves it. */
    let desktop = UserDefaults.standard.bool(forKey: "BlenderDesktopInterface")
    let restrictions = scene?.sizeRestrictions.map { ($0.minimumSize, $0.maximumSize) }
    Task { @MainActor in
      defer {
        UserDefaults.standard.set(style, forKey: ShellStyle.key)
        UserDefaults.standard.set(rail, forKey: "BlenderToolRailEdge")
        UserDefaults.standard.set(editorMode, forKey: ImageEditorModel.modeKey)
        if BlenderSettings.desktop != desktop { BlenderSettings.set("desktop", .bool(desktop)) }
        SettingsModel.applyDesktopScale()
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
      let folder = (path as NSString).deletingLastPathComponent
      WM_native_ui_log("snapshot", "script in \(scratch ? "scratch document" : "a person's document") \((path as NSString).lastPathComponent)")
      for written in steps {
        let step = scratch ? written.replacingOccurrences(of: "$SCRATCH", with: folder) : written
        let verb = step.split(separator: " ").first.map(String.init) ?? ""
        /* Asked again before each step: a step may open another document (ROUND5 9D.5), and a
         * check works only in its own folder. Back in the documents, no document is open. */
        let now = wm_apple_ios_document_url()?.path
        let inScratch = scratch && (now == nil || now!.contains("/platypus-scratch/"))
        /* `editor uv desktop` changes the document's workspaces, as the desktop's tabs do. */
        if !inScratch && (["send", "tool", "op", "panel", "key", "document"].contains(verb) ||
                          step.hasPrefix("editor uv desktop")) {
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
      case "popover":
        /* The 3D View's shading popover, as its header button opens it: `popover shading|close`. */
        if words.first == "shading" { SwiftScenePanels.current?.showShadingTab("SHADING") }
        ShellModel.current?.shadingOpen = words.first == "shading"
        try? await Task.sleep(for: .seconds(1))
      case "prefs":
        /* Preferences, as Settings opens them: `prefs open|close`. */
        if words.first == "open" {
          SqueezePalette.shared.showSettings?()
        }
        else {
          shownRoot?.presentedViewController?.dismiss(animated: false)
        }
        try? await Task.sleep(for: .seconds(1))
      case "about":
        /* About, as the app menu opens it: `about open|close`. */
        if words.first == "open", let root = shownRoot {
          SwiftAbout.present(from: root)
        }
        else {
          SwiftAbout.dismiss()
        }
        try? await Task.sleep(for: .seconds(1))
      case "edit":
        guard let identifier = words.first else {
          WM_native_ui_log("snapshot", "unknown step: \(step)")
          break
        }
        let request = NumberFieldEditRequest(identifier: identifier)
        NotificationCenter.default.post(name: NumberFieldEditRequest.notification, object: request)
        try? await Task.sleep(for: .milliseconds(800))
        WM_native_ui_log("snapshot", request.claimedBy.map { "edit \(identifier): editing \($0)" } ??
                         "edit \(identifier): no number field shown matches")
      case "key":
        /* `key S shift`: the modifiers in any order after the key. */
        let parts = step.split(separator: " ").dropFirst().map(String.init)
        guard let name = parts.first, let model = ShellModel.current else {
          WM_native_ui_log("snapshot", "unknown step: \(step)")
          break
        }
        let held = Set(parts.dropFirst())
        if !wm_apple_ios_window_press_key(model.window, name, held.contains("shift"), held.contains("ctrl"),
                                          held.contains("alt")) {
          WM_native_ui_log("snapshot", "key \(name): not a key the script knows")
        }
        try? await Task.sleep(for: .seconds(1))
      case "menu":
        guard words.first == "close" else {
          WM_native_ui_log("snapshot", "unknown step: \(step)")
          break
        }
        ShellMenuPresenter.shared.dismiss()
        ShellModel.current?.searchOpen = false
        scene?.windows.first?.rootViewController?.presentedViewController?.dismiss(animated: false)
        try? await Task.sleep(for: .milliseconds(600))
      case "editor" where words.first == "nodes":
        guard words.count >= 2, let nodes = SwiftScenePanels.current?.nodes, ["open", "close"].contains(words[1]) else {
          WM_native_ui_log("snapshot", "unknown step: \(step)")
          break
        }
        /* As the editors menu's Shader Editor does. */
        if words[1] == "open" { nodes.setKind(.shader) }
        nodes.setShown(words[1] == "open")
        WM_native_ui_log("snapshot", step)
        try? await Task.sleep(for: .seconds(1))
      case "sidebar":
        guard words.count >= 2, let panels = SwiftScenePanels.current, ["open", "close"].contains(words[1]),
              ["properties", "outliner"].contains(words[0]) else {
          WM_native_ui_log("snapshot", "unknown step: \(step)")
          break
        }
        if words[0] == "properties" { panels.setInspectorShown(words[1] == "open") }
        else { panels.setHierarchyShown(words[1] == "open") }
        WM_native_ui_log("snapshot", step)
        try? await Task.sleep(for: .seconds(1))
      case "mark":
        WM_native_ui_log("snapshot", step)
      case "editor":
        guard words.count >= 2, let mode = ImageEditorModel.Mode(rawValue: words[0]),
              let image = SwiftScenePanels.current?.image, ["open", "close", "desktop"].contains(words[1]),
              words[1] != "desktop" || mode == .uv else {
          WM_native_ui_log("snapshot", "unknown step: \(step)")
          break
        }
        if words[1] == "desktop" {
          /* As the UV Editor's ⋯ menu does: Blender's own interface, on its UV Editing workspace. */
          BlenderSettings.set("desktop_uv_editing", .bool(true))
          try? await Task.sleep(for: .seconds(2))
          break
        }
        image.show(mode, words[1] == "open")
        WM_native_ui_log("snapshot", step)
        try? await Task.sleep(for: .seconds(1))
      case "interface":
        if words.first == "desktop" || words.first == "ipad" {
          BlenderSettings.set("desktop", .bool(words.first == "desktop"))
        }
        else if words.first == "measure" {
          BlenderSettings.set("interface_measure", .bool(true))
        }
        else if words.first == "size", words.count >= 2, let percent = Double(words[1]) {
          /* 67 is two thirds, as Window › Interface Size has it. */
          BlenderSettings.set("desktop_scale", .float(percent == 67 ? 2.0 / 3.0 : percent / 100))
        }
        else {
          WM_native_ui_log("snapshot", "unknown step: \(step)")
          break
        }
        try? await Task.sleep(for: .seconds(2))
      case "document":
        let rest = String(step.dropFirst("document ".count))
        let _: String = await withCheckedContinuation { done in
          wm_apple_ios_document_check(rest) { answer in done.resume(returning: answer) }
        }
        try? await Task.sleep(for: .seconds(1))
      case "wait":
        try? await Task.sleep(for: .seconds(Double(words.first ?? "") ?? 0.5))
      case "shot":
        shot(words.first ?? "shot")
      default:
        WM_native_ui_log("snapshot", "unknown step: \(step)")
    }
  }

  /** The root of the window being shown, as a person's tap would reach it. The scene's first
   * window is the launcher's, which stays behind the document's window and is not drawn: a sheet
   * presented there is never seen (an `about` step showed nothing on 2026-11-18). */
  private static var shownRoot: UIViewController? {
    let shown = scene?.windows.filter { !$0.isHidden } ?? []
    return (shown.first(where: \.isKeyWindow) ?? shown.last)?.rootViewController
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
    /* Without the check document's banner, which a person sees: the shots show the interface. */
    let banner = CheckDocumentBanner.label
    banner?.isHidden = true
    defer { banner?.isHidden = false }
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
