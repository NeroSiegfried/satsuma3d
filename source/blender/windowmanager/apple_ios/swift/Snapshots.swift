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
 * - `floor continue`: the device floor's notice, as its Continue (ROUND5 8N; the notice shows in a
 *   check launch with `PLATYPUS_PRETEND_DEVICE`, see `DeviceFloorNotice.swift`);
 * - `gate <label>`: the input gate's answer (ROUND5 9G.1) at the viewport's middle and at a point
 *   left of the middle, where a sheet's dimmed surround is, written to the log as
 *   `gate <label> centre <answer> side <answer>`: `takes`, or why Blender is given no input there;
 * - `present render|search|templates`: the render sheet, Search, or the template picker as File ›
 *   New… opens it (the last only in the scratch document); `present close`: what is presented, as
 *   its Cancel would;
 * - `dialog cancel`: every native dialog and alert, as their Cancel;
 * - `edit <identifier>`: put a number field into editing, as a tap does, so a shot shows the full
 *   value it is typed from (ROUND5 7E.7): the first field shown whose node key ends in it, or
 *   whose `<property>.<label>` it is, such as `location.X` or `scale.X`; logged either way;
 * - `gizmo drag <dx> <dy>|hold|release`: what the navigation gizmo's recognizers call (ROUND5 12A,
 *   12B): a drag of that many points from the gizmo, which turns the view; the hold, which opens
 *   the menu of views; letting go of it. Not the recognizers themselves;
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
 * - `sidebar properties|outliner open|close [sample]`: Properties or the Outliner, as the header's
 *   buttons show and hide them (ROUND5 10A); `sample` logs where the shell has the gizmo against where
 *   Blender last drew it, through the slide (ROUND5 14B, 14C);
 * - `fingers tool|navigate`: the touch setting for this launch only, not stored (ROUND5 13);
 *   `fingers tap <x> <y>`: a finger's tap on the view where fingers move it, the click it sends
 *   (ROUND6 TOUCH-1), at a point in the window's points;
 * - `finger <x> <y> down|move|up`, `finger second`: a finger on the tool where fingers use it, as
 *   it lands, moves and lifts, and a second finger landing (ROUND6 TOUCH-2);
 * - `motion reduce on|off`: the app's Reduce Motion path without the system setting (ROUND5 14C):
 *   the sidebars' slide and the insets in one step; until the app quits, never saved;
 * - `trait compact on|off`, `trait text <size>|default`: the window's horizontal size class or its
 *   text size (a `UIContentSizeCategory` name's end, such as `extraExtraLarge` or
 *   `accessibilityLarge`), as trait overrides of this launch's window (ROUND5 14C): the window's
 *   size and the owner's settings are not touched;
 * - `touch <x> <y>|@<WHERE>[#<type>[:last]] tap|what|hold [<dx> <dy>]|drag <dx> <dy> [flick]`: a
 *   finger on Blender's own
 *   interface at that point of the window, in points (ROUND5 13B): it enters where a finger's touch
 *   on interface does and is told apart the same way (a tap; a hold, then a drag if given, or alone
 *   a right-click, ROUND6 DESK-2; a drag over 0.3 s, ended still or as a flick). `what` only logs what Blender says is there. It proves
 *   the telling-apart and Blender's answers, not UIKit's delivery;
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
        if !inScratch && (["send", "tool", "op", "panel", "key", "document", "gizmo"].contains(verb) ||
                          step.hasPrefix("editor uv desktop") || step.hasPrefix("present templates")) {
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
        panels.setInspectorShown(true, by: "script")
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
      case "floor":
        /* The device floor's notice: `floor continue`, as its button. */
        guard words.first == "continue" else {
          WM_native_ui_log("snapshot", "unknown step: \(step)")
          break
        }
        WM_native_ui_log("snapshot", "floor continue: \(DeviceFloorNotice.continueNotice() ? "done" : "no notice")")
        try? await Task.sleep(for: .seconds(1))
      case "gate":
        /* What every input asks before it reaches Blender (ROUND5 9G.1, decision 66). */
        let label = words.first ?? "-"
        func answer(_ x: CGFloat, _ y: CGFloat) -> String {
          wm_apple_ios_window_gate(ShellModel.current?.window, CGPoint(x: x, y: y)).map { "blocked (\($0))" } ?? "takes"
        }
        WM_native_ui_log("snapshot", "gate \(label) centre \(answer(0.5, 0.5)) side \(answer(0.12, 0.5))")
      case "present":
        guard let what = words.first else {
          WM_native_ui_log("snapshot", "unknown step: \(step)")
          break
        }
        switch what {
          case "render":
            /* As the top bar's Render button shows its sheet, without rendering. */
            ShellCommands.current?.render?.showRenders()
          case "search":
            ShellModel.current?.searchOpen = true
          case "templates":
            /* As File › New… does inside a document: the template picker, cancelled by `present
             * close` before anything is made. */
            if let root = shownRoot { wm_apple_ios_new_document(root) }
          case "close":
            ShellModel.current?.searchOpen = false
            var top = shownRoot
            while let presented = top?.presentedViewController { top = presented }
            if let top, top !== shownRoot { top.presentingViewController?.dismiss(animated: false) }
          default:
            WM_native_ui_log("snapshot", "unknown step: \(step)")
        }
        WM_native_ui_log("snapshot", step)
        try? await Task.sleep(for: .seconds(1.5))
      case "dialog":
        guard words.first == "cancel" else {
          WM_native_ui_log("snapshot", "unknown step: \(step)")
          break
        }
        WM_native_ui_log("snapshot", "dialog cancel: \(wm_apple_ios_dialogs_cancel_all())")
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
      case "gizmo":
        /* ROUND5 12A/12B: what the gizmo's recognizers call, not the recognizers. `gizmo drag <dx>
         * <dy>`: a drag from the gizmo of that many points; `gizmo hold`; `gizmo release`. */
        /* ROUND5 12D: `gizmo <zoom|move|camera|projection|lock> tap` and `… drag <dx> <dy>`: what
         * the window sends for a finger that begins on that button, through its entry. */
        let buttons = ["axes": 1.0, "zoom": 2.0, "move": 3.0, "camera": 4.0, "projection": 5.0, "lock": 6.0]
        if let name = words.first, let kind = buttons[name], let model = ShellModel.current {
          /* `words` holds at most three: the drag's numbers are split again here. */
          let words = Array(step.split(separator: " ").map(String.init).dropFirst())
          let parts = model.navigationParts
          let scale = Double(model.pointScale)
          guard let index = stride(from: 0, to: parts.count - 3, by: 4).first(where: { parts[$0] == kind }),
                scale > 0 else {
            WM_native_ui_log("snapshot", "gizmo \(name): not shown")
            break
          }
          let start = CGPoint(x: parts[index + 1] / scale, y: parts[index + 2] / scale)
          var end = start
          if words.count >= 4, words[1] == "drag", let dx = Double(words[2]), let dy = Double(words[3]) {
            end = CGPoint(x: start.x + dx, y: start.y + dy)
          }
          else if words.count < 2 || words[1] != "tap" {
            WM_native_ui_log("snapshot", "unknown step: \(step)")
            break
          }
          if !wm_apple_ios_window_navigation_button(model.window, 0, start) {
            WM_native_ui_log("snapshot", "gizmo \(name): not taken")
            break
          }
          let moves = end == start ? 0 : 20
          for i in stride(from: 1, through: moves, by: 1) {
            try? await Task.sleep(for: .milliseconds(16))
            let t = Double(i) / Double(moves)
            _ = wm_apple_ios_window_navigation_button(
              model.window, 1, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
          }
          try? await Task.sleep(for: .milliseconds(50))
          _ = wm_apple_ios_window_navigation_button(model.window, 2, end)
          WM_native_ui_log("snapshot", step)
          try? await Task.sleep(for: .seconds(1))
          break
        }
        guard let model = ShellModel.current, let gizmo = ViewGizmoState.current else {
          WM_native_ui_log("snapshot", "gizmo: no gizmo shown")
          break
        }
        if words.first == "drag", words.count >= 3, let dx = Double(words[1]), let dy = Double(words[2]) {
          gizmo.dragBegan(model: model, translation: .zero)
          if !gizmo.dragging { WM_native_ui_log("snapshot", "gizmo drag: not taken") }
          for i in 1...20 {
            try? await Task.sleep(for: .milliseconds(16))
            gizmo.dragMoved(model: model, translation: CGPoint(x: dx * Double(i) / 20, y: dy * Double(i) / 20))
          }
          gizmo.dragEnded(model: model, translation: CGPoint(x: dx, y: dy), velocity: .zero, cancelled: false)
        }
        else if words.first == "hold" {
          gizmo.holdBegan(model: model)
        }
        else if words.first == "release" {
          gizmo.release(at: nil)
        }
        else {
          WM_native_ui_log("snapshot", "unknown step: \(step)")
          break
        }
        WM_native_ui_log("snapshot", step)
        try? await Task.sleep(for: .seconds(1))
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
        /* ROUND5 14B: `sidebar <name> <open|close> sample` notes where Blender has the navigation
         * gizmo before the slide, a fifth of a second into it, and after it. */
        let sample = words.count >= 3 && words[2] == "sample"
        func gizmoX() -> String { ShellModel.current?.navigationGizmo.first.map { String(Int($0)) } ?? "none" }
        let before = gizmoX()
        if words[0] == "properties" { panels.setInspectorShown(words[1] == "open", by: "script") }
        else { panels.setHierarchyShown(words[1] == "open", by: "script") }
        WM_native_ui_log("snapshot", step)
        if sample {
          /* ROUND5 14C: the hotspot (the shell's place for the gizmo) against where Blender last drew
           * it, at moments through the slide; the largest difference is the line's verdict. */
          var samples: [String] = []
          var largest: CGFloat = 0
          var elapsed = 0
          for moment in [50, 100, 150, 200, 300, 450, 700] {
            try? await Task.sleep(for: .milliseconds(moment - elapsed))
            elapsed = moment
            guard let model = ShellModel.current, let hotspot = model.navigationGizmoRect else { continue }
            var drawn = CGPoint.zero
            var radius: CGFloat = 0
            guard wm_apple_ios_window_navigation_drawn(model.window, &drawn, &radius) else {
              samples.append("\(moment) ms: not drawn")
              continue
            }
            let difference = abs(hotspot.midX - drawn.x)
            largest = max(largest, difference)
            samples.append(String(format: "%d ms: %.1f/%.1f", moment, hotspot.midX, drawn.x))
          }
          let middle = gizmoX()
          try? await Task.sleep(for: .milliseconds(300))
          WM_native_ui_log("snapshot", "gizmo slide x: \(before) -> \(middle) -> \(gizmoX()) px")
          WM_native_ui_log("snapshot", "gizmo hotspot/drawn x pt: " + samples.joined(separator: ", ") +
                           String(format: "; largest difference %.1f pt", largest))
        }
        else {
          try? await Task.sleep(for: .seconds(1))
        }
      case "touch":
        var parts = step.split(separator: " ").map(String.init)
        /* `@<WHERE>[#<button type>[:last]]` in place of `<x> <y>`: the place Blender's map has, with
         * `+` for the space in its name (`@TOPBAR+HEADER#16:last`, `@PROPERTIES+WINDOW#6`). */
        if let place = parts.first, place.hasPrefix("@"), let window = ShellModel.current?.window {
          let spec = place.dropFirst().split(separator: "#", maxSplits: 1).map(String.init)
          let kind = spec.count > 1 ? spec[1].split(separator: ":").map(String.init) : []
          var found = CGPoint.zero
          let region = spec[0].replacingOccurrences(of: "+", with: " ")
          guard wm_apple_ios_window_touch_find(window, region, Int32(kind.first ?? "") ?? -1,
                                               kind.last == "last", &found) else {
            WM_native_ui_log("snapshot", "touch \(step): \(place) not found")
            break
          }
          parts.replaceSubrange(0...0, with: [String(Double(found.x)), String(Double(found.y))])
        }
        guard parts.count >= 3, let x = Double(parts[0]), let y = Double(parts[1]),
              let window = ShellModel.current?.window else {
          WM_native_ui_log("snapshot", "unknown step: \(step)")
          break
        }
        let point = CGPoint(x: x, y: y)
        let action = parts[2]
        let numbers = parts.dropFirst(3).compactMap(Double.init)
        let travel = numbers.count >= 2 ? CGPoint(x: numbers[0], y: numbers[1]) : .zero
        WM_native_ui_log("snapshot", "touch \(step): \(wm_apple_ios_window_touch_description(window, point))")
        if action == "what" { break }
        guard ["tap", "hold", "drag"].contains(action) else {
          WM_native_ui_log("snapshot", "unknown step: \(step)")
          break
        }
        guard wm_apple_ios_window_script_touch(window, 0, point) else {
          WM_native_ui_log("snapshot", "touch \(step): not taken (not interface, or the gate is closed)")
          break
        }
        if action == "hold" { try? await Task.sleep(for: .milliseconds(500)) }
        if action == "tap" { try? await Task.sleep(for: .milliseconds(60)) }
        if travel != .zero {
          for index in 1...12 {
            try? await Task.sleep(for: .milliseconds(25))
            let fraction = Double(index) / 12
            _ = wm_apple_ios_window_script_touch(window, 1, CGPoint(x: x + travel.x * fraction, y: y + travel.y * fraction))
          }
          if !parts.contains("flick") { try? await Task.sleep(for: .milliseconds(150)) }
        }
        _ = wm_apple_ios_window_script_touch(window, 2, CGPoint(x: x + travel.x, y: y + travel.y))
        try? await Task.sleep(for: .milliseconds(parts.contains("flick") ? 1500 : 600))
      case "finger":
        /* ROUND6 TOUCH-2: a finger on the tool, as fingers use it: `finger <x> <y> down|move|up`
         * and `finger second`, a second finger landing (navigation). */
        guard let model = ShellModel.current else { break }
        if words.first == "second" {
          let taken = wm_apple_ios_window_script_tool_finger(model.window, 3, .zero)
          WM_native_ui_log("snapshot", "\(step): \(taken ? "taken" : "not taken")")
          try? await Task.sleep(for: .milliseconds(300))
          break
        }
        let phases = ["down": Int32(0), "move": 1, "up": 2]
        guard words.count >= 3, let x = Double(words[0]), let y = Double(words[1]), let phase = phases[words[2]] else {
          WM_native_ui_log("snapshot", "unknown step: \(step)")
          break
        }
        let taken = wm_apple_ios_window_script_tool_finger(model.window, phase, CGPoint(x: x, y: y))
        WM_native_ui_log("snapshot", "\(step): \(taken ? "taken" : "not taken (fingers move the view, or the gate is closed)")")
        try? await Task.sleep(for: .milliseconds(phase == 1 ? 50 : 300))
      case "fingers":
        /* ROUND5 13: the touch setting for this launch only (Pencil and Fingers: `tool`; Pencil
         * Only: `navigate`), as Settings applies it, without storing it: the owner's setting is
         * read again at the next launch. */
        if words.first == "tap", words.count >= 3, let x = Double(words[1]), let y = Double(words[2]),
           let model = ShellModel.current {
          /* ROUND6 TOUCH-1: a finger's tap where fingers move the view, as the tap recognizer
           * sends it: a click there. */
          let taken = wm_apple_ios_window_script_view_tap(model.window, CGPoint(x: x, y: y))
          WM_native_ui_log("snapshot", "\(step): \(taken ? "clicked" : "not taken (fingers use the tool, or the gate is closed)")")
          try? await Task.sleep(for: .milliseconds(400))
          break
        }
        guard let mode = words.first, ["tool", "navigate"].contains(mode), let model = ShellModel.current else {
          WM_native_ui_log("snapshot", "unknown step: \(step)")
          break
        }
        model.fingerUsesTool = mode == "tool"
        wm_apple_ios_window_set_finger_tool(model.window, mode == "tool")
        WM_native_ui_log("snapshot", step)
      case "motion":
        guard words.count >= 2, words[0] == "reduce", ["on", "off"].contains(words[1]) else {
          WM_native_ui_log("snapshot", "unknown step: \(step)")
          break
        }
        SidebarSlide.reduceMotionForScript = words[1] == "on"
        WM_native_ui_log("snapshot", step)
      case "trait":
        guard words.count >= 2, let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first else {
          WM_native_ui_log("snapshot", "unknown step: \(step)")
          break
        }
        if words[0] == "compact", ["on", "off"].contains(words[1]) {
          if words[1] == "on" { window.traitOverrides.horizontalSizeClass = .compact }
          else { window.traitOverrides.remove(UITraitHorizontalSizeClass.self) }
        }
        else if words[0] == "text" {
          if words[1] == "default" { window.traitOverrides.remove(UITraitPreferredContentSizeCategory.self) }
          else {
            let sizes: [String: UIContentSizeCategory] = [
              "large": .large, "extraLarge": .extraLarge, "extraExtraLarge": .extraExtraLarge,
              "extraExtraExtraLarge": .extraExtraExtraLarge, "accessibilityMedium": .accessibilityMedium,
              "accessibilityLarge": .accessibilityLarge, "accessibilityExtraLarge": .accessibilityExtraLarge,
            ]
            guard let size = sizes[words[1]] else {
              WM_native_ui_log("snapshot", "unknown step: \(step)")
              break
            }
            window.traitOverrides.preferredContentSizeCategory = size
          }
        }
        else {
          WM_native_ui_log("snapshot", "unknown step: \(step)")
          break
        }
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
          BlenderSettings.set("desktop_open", .text("UV_EDITING"))
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
