# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Every control the shell lays over the window has a place no other one takes (device round,
2026-11-21: Shift, Ctrl and Alt stood at a fixed place and covered the operation strip's Cancel, a
folded Actions and, in the Desktop Interface, the Timeline's header; the render's pill covered the
tool settings row).

One rule: each overlay is placed by a function that reserves room for it, and the others are
placed in what is left.

- The bottom row (`ShellLayout.bottomStack`): Shift, Ctrl and Alt first, at the lane's leading
  end, then the pills, the open bar and strip, the number pad and the Item card. Checked here as
  geometry: the function itself, taken from `ShellLayout.swift` with the metrics it reads, built
  for the Mac with swiftc and run over every configuration and a range of lanes; no two pieces may
  overlap. Their band along the bottom is what Blender's framing keeps clear of
  (`LayoutChecker.bottomZones`, `WM_native_ui_bottom_controls_set`).
- The top column: the running work's pills hang below the header and the tool settings row and
  reserve their height (`ShellModel.jobsHeight`); the drag hint, a waiting operation's words and
  messages hang below them.
- The Desktop Interface's cluster: its band along the top or the bottom is kept out of Blender's
  screen (`WM_native_ui_desktop_insets_set`, `WM_window_rect_calc`), so it covers no region.
- Over the whole window by design: the busy veil, the Pencil's palette and dials, the text
  object's keyboard where the controls are hidden.

`OVERLAYS` lists every overlay of the window's body with the rule that places it; one that is
not listed fails, as does a control placed by a fixed padding from a window edge.
"""

import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WM = ROOT / 'source/blender/windowmanager'
SWIFT = WM / 'apple_ios/swift'

# What each `.overlay` of the document window's body holds, and the rule that places it.
OVERLAYS = {
    'TextObjectKeyboard': 'only where the controls are hidden: nothing else is along the bottom',
    'StickyModifierKeys': 'visionOS only (no bottom row there); on the iPad in the bottom row, rule 0',
    'DesktopClusterLayer': 'its band is kept out of Blender\'s screen (WM_native_ui_desktop_insets_set)',
    'BusyVeil': 'over the whole window by design: Blender is held up',
    'SqueezePaletteLayer': 'the Pencil\'s palette, over everything while it shows, at the Pencil',
    'RollDialLayer': 'the Pencil\'s dial, over everything while it rolls',
    'ColorRollLayer': 'the Pencil\'s colour dial, over everything while it rolls',
}


def block(text, start):
    """The text of the brace block that opens at or after \a start, braces included."""
    open_at = text.index('{', start)
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    raise ValueError('unbalanced')


DRIVER = r'''
import Foundation
import CoreGraphics

%(metrics)s

%(types)s

enum ShellLayout {
%(function)s
}

var failures = 0
var layouts = 0
let folds: [BottomStackInput.Fold] = [.none, .folded, .open]
for width in [440.0, 560.0, 683.0, 797.0, 910.0, 1024.0, 1100.0, 1366.0] as [CGFloat] {
  for leading in [12.0, 90.0, 240.0] as [CGFloat] {
    let laneWidth = max(0, width - leading - 136)
    // Portrait (1024) and landscape (1366) iPads, Split View and Slide Over widths; no box, the box
    // folded, and one to three keys (the sidebar's own left out).
    for keys in [0, ShellMetrics.modifierKeysWidth(folded: true), ShellMetrics.modifierKeysWidth(folded: false, keys: 1),
                 ShellMetrics.modifierKeysWidth(folded: false, keys: 2), ShellMetrics.modifierKeysWidth(folded: false)] {
      for actions in folds {
        for actionsWidth in [300.0, 2000.0] as [CGFloat] {
          for operation in folds {
            for operationWidth in [420.0, 2000.0] as [CGFloat] {
              for item in folds {
                for pad in [false, true] {
                  var input = BottomStackInput(width: width, laneLeading: leading, laneWidth: laneWidth,
                                               headroom: 600, itemMaxHeight: 300)
                  input.modifierKeys = keys
                  input.actions = actions
                  input.actionsWidth = actionsWidth
                  input.operation = operation
                  input.operationPillWidth = 96
                  input.operationWidth = operationWidth
                  input.item = item
                  input.pad = pad && actions == .open
                  layouts += 1
                  let frames = ShellLayout.bottomStack(input)
                  var zones: [(String, CGRect)] = []
                  if let r = frames.modifierKeys { zones.append(("modifier keys", r)) }
                  if let r = frames.actions { zones.append(("actions", r)) }
                  if let r = frames.operation { zones.append(("operation", r)) }
                  if let r = frames.item { zones.append(("item", r)) }
                  if let r = frames.pad { zones.append(("number pad", r)) }
                  if keys > 0 && frames.modifierKeys == nil {
                    failures += 1
                    print("keys not placed: \(width) \(leading)")
                  }
                  for (i, a) in zones.enumerated() {
                    for b in zones[(i + 1)...] {
                      let o = a.1.intersection(b.1)
                      if !o.isNull && o.width > 1 && o.height > 1 {
                        failures += 1
                        if failures < 20 {
                          print("\(a.0) ∩ \(b.0) at width \(width) lane \(leading)+\(laneWidth) keys \(keys) " +
                                "actions \(actions) operation \(operation) item \(item) pad \(input.pad)")
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
print("checked \(layouts) layouts, \(failures) overlaps")
exit(failures == 0 ? 0 : 1)
'''


class BottomRowGeometryTest(unittest.TestCase):
    """The bottom row's layout, built and run: nothing in it lies under anything else."""

    def test_no_two_pieces_overlap(self):
        if shutil.which('xcrun') is None:
            self.skipTest('needs Xcode to build Swift')
        quick = (SWIFT / 'QuickActions.swift').read_text(encoding='utf-8')
        layout = (SWIFT / 'ShellLayout.swift').read_text(encoding='utf-8')
        metrics = block(quick, quick.index('enum ShellMetrics {'))
        types = '\n\n'.join(block(layout, layout.index(name)) for name in (
            'struct BottomStackInput: Equatable {', 'enum BottomStackPill: Hashable {',
            'struct BottomStackFrames: Equatable {'))
        start = layout.index('  nonisolated static func bottomStack(')
        function = block(layout, start).replace('nonisolated static func', 'static func', 1)
        source = DRIVER % {'metrics': metrics, 'types': types, 'function': function}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'main.swift'
            path.write_text(source)
            binary = Path(directory) / 'stack'
            built = subprocess.run(['xcrun', 'swiftc', '-O', str(path), '-o', str(binary)],
                                   capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr[-3000:])
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=600)
        self.assertEqual(result.returncode, 0, result.stdout[-3000:])
        self.assertRegex(result.stdout, r'checked \d{5,} layouts, 0 overlaps')


KEYS_DRIVER = r"""
import Foundation

enum SidebarContent {
%(offers)s
}

enum StickyModifierKeys {
%(shown)s
}

var failures = 0
func expect(_ name: String, _ effects: [String: String], _ offers: Set<String>, _ shown: [Int]) {
  let got = StickyModifierKeys.shownKeys(effects: effects, offers: offers)
  if got != shown { failures += 1; print("\(name): \(got), not \(shown)") }
}
let selecting = SidebarContent.offers(buttons: true, smooth: false, transforming: false, strokes: false)
let transforming = SidebarContent.offers(buttons: true, smooth: false, transforming: true, strokes: false)
let sculpt = SidebarContent.offers(buttons: true, smooth: true, transforming: false, strokes: true)
let none = SidebarContent.offers(buttons: false, smooth: false, transforming: false, strokes: false)
// Edit Mode, Select Box, as the bridge names its clicks (the harness's statuskeys scenario).
let box = ["shift": "mode:ADD", "ctrl": "mode:SUB", "alt": "op:MESH_OT_loop_select"]
expect("Select Box beside its Set, Extend, Subtract, Toggle", box, selecting, [2])
expect("Select Box with the sidebar tucked away", box, none, [0, 1, 2])
// The Tweak tool's Shift-click toggles, its Ctrl-click (no item) passes.
expect("Tweak", ["shift": "toggle"], selecting, [1, 2])
// Moving: the sidebar's Snap and Precision hold Ctrl and Shift themselves.
expect("Move", ["ctrl": "key:ctrl", "shift": "key:shift", "alt": "status:Snap Invert"], transforming, [2])
// Sculpt: + and - (Ctrl's Invert) and Smooth (Shift).
expect("Sculpt Draw", ["shift": "mode:SMOOTH", "ctrl": "mode:INVERT"], sculpt, [2])
// Everything the box would hold, the sidebar offers: no box.
expect("all offered", ["shift": "mode:ADD", "ctrl": "mode:SUB", "alt": "mode:XOR"], selecting, [])
print("checked, \(failures) wrong")
exit(failures == 0 ? 0 : 1)
"""


class DuplicateKeysTest(unittest.TestCase):
    """Owner, on the iPad (Edit Mode, Select Box): the box read Extend, Subtract and Select while the
    sidebar beside it offered Set, Extend, Subtract and Toggle. A key whose click the sidebar offers
    is left out, the box with none left goes; decided from what the column offers and what Blender
    says each click does, never from a tool's name. The two functions, built and run."""

    def test_keys_the_sidebar_offers_are_left_out(self):
        if shutil.which('xcrun') is None:
            self.skipTest('needs Xcode to build Swift')
        rails = (SWIFT / 'Rails.swift').read_text(encoding='utf-8')
        offers = block(rails, rails.index('  static func offers(buttons: Bool, smooth: Bool, transforming: Bool'))
        shown = block(rails, rails.index('  nonisolated static func shownKeys(effects:'))
        shown = shown.replace('nonisolated static func', 'static func', 1)
        source = KEYS_DRIVER % {'offers': offers, 'shown': shown}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'main.swift'
            path.write_text(source)
            binary = Path(directory) / 'keys'
            built = subprocess.run(['xcrun', 'swiftc', str(path), '-o', str(binary)], capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr[-3000:])
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_the_box_follows_the_keys_it_shows(self):
        rails = (SWIFT / 'Rails.swift').read_text(encoding='utf-8')
        quick = (SWIFT / 'QuickActions.swift').read_text(encoding='utf-8')
        # Its width in the row is the keys it shows, and no box with none (the same layout rule).
        self.assertIn('let keys = StickyModifierKeys.shownKeys(model: model, embedded: false).count', quick)
        self.assertIn('if model.viewportReady && keys > 0 {', quick)
        self.assertIn('ForEach(shown, id: \\.self) { index in', rails)
        # A key left out lets go.
        self.assertIn('for index in Self.keys.indices where !shown.contains(index) {', rails)
        # What the sidebar offers is set from what it shows, while it shows.
        self.assertIn('content.offers(transforming: model.transforming, strokes: model.direction != nil)', rails)
        # The names: Blender says what the click does, as it dispatches it (the bridge).
        native = (WM / 'intern/wm_native_ui.cc').read_text(encoding='utf-8')
        self.assertIn('if (ot == nullptr || !WM_operator_poll(C, ot)) {', native)
        self.assertIn('const bool says = !held.name.empty() && held.name != plain.name &&', native)
        self.assertIn('data("modifier_effects", std::string_view(modifier_effects));', native)


class OverlaysAreReservedTest(unittest.TestCase):
    """Every overlay has a rule that reserves its place."""

    @classmethod
    def setUpClass(cls):
        cls.window = (SWIFT / 'DocumentWindow.swift').read_text(encoding='utf-8')

    def test_every_window_overlay_is_listed(self):
        body = block(self.window, self.window.index('  public var body: some View {'))
        found = set()
        for match in re.finditer(r'\.overlay(?:\(alignment: \.\w+\))? \{', body):
            content = block(body, match.start())
            names = re.findall(r'\b([A-Z]\w+)\(', content)
            names = [n for n in names if n in OVERLAYS or n.endswith(('Layer', 'Keys', 'Veil', 'Keyboard'))]
            self.assertTrue(names, 'An overlay with no view this test knows: ' + content[:200])
            found.update(names)
        unlisted = sorted(found - set(OVERLAYS))
        self.assertEqual(unlisted, [], 'Overlays with no rule that reserves their place: add the rule, '
                                       'then list them in OVERLAYS')
        stale = sorted(set(OVERLAYS) - found)
        self.assertEqual(stale, [], 'Listed overlays no longer in the window')

    def test_modifier_keys_stand_in_the_row(self):
        quick = (SWIFT / 'QuickActions.swift').read_text(encoding='utf-8')
        self.assertIn('if let slot = frames.modifierKeys {', quick)
        self.assertIn('StickyModifierKeys(model: model)\n                .layoutZone("modifier keys")', quick)
        self.assertIn('input.modifierKeys = ShellMetrics.modifierKeysWidth(folded: StickyModifierState.shared.folded, '
                      'keys: keys)', quick)
        # Everywhere else: the cluster (embedded) and visionOS, which has no row.
        uses = []
        for path in sorted(SWIFT.glob('*.swift')):
            text = path.read_text(encoding='utf-8')
            for m in re.finditer(r'StickyModifierKeys\(model: model[^)]*\)', text):
                uses.append((path.name, m.group(0)))
        self.assertEqual(sorted(uses), sorted([
            ('DesktopCluster.swift', 'StickyModifierKeys(model: model, embedded: true)'),
            ('DocumentWindow.swift', 'StickyModifierKeys(model: model)'),
            ('QuickActions.swift', 'StickyModifierKeys(model: model)')]))
        visionos = self.window[self.window.index('#if os(visionOS)\n      /* Shift, Ctrl and Alt'):]
        self.assertLess(visionos.index('StickyModifierKeys(model: model)'), visionos.index('#endif'))
        layout = (SWIFT / 'ShellLayout.swift').read_text(encoding='utf-8')
        function = block(layout, layout.index('  nonisolated static func bottomStack('))
        self.assertIn('var x = rowLeading', function, 'The pills start after the keys')
        self.assertIn('rowWidth < M.wideRow', function)
        # The self-test on the device covers them too, and the runtime checker sees their zone.
        self.assertIn('("modifier keys", inWindow(rect))', layout)
        interop = (SWIFT / 'UIKitInterop.swift').read_text(encoding='utf-8')
        self.assertRegex(interop, r'bottomZones: Set<String> = \["modifier keys",')

    def test_the_top_column_hangs_below_the_pills(self):
        indicator = (SWIFT / 'CompileIndicator.swift').read_text(encoding='utf-8')
        self.assertIn('let below = max(0, (model?.topBarBottom ?? 0) - proxy.frame(in: .global).minY)', indicator)
        self.assertIn('.layoutZone("jobs")', indicator)
        self.assertIn('model.jobsHeight = reserve', indicator)
        self.assertIn('CompileIndicator(progress: shell.compile, model: model)', self.window)
        rails = (SWIFT / 'Rails.swift').read_text(encoding='utf-8')
        self.assertIn('let topColumn = safe.minY + model.jobsHeight', rails)
        self.assertNotIn('y: safe.minY + 34', rails, 'Something hangs at the top over the running work')
        self.assertIn('let messagesTop: CGFloat = model.jobsHeight + 12 + 56 * CGFloat((hintShown ? 1 : 0) + '
                      '(faceShown ? 1 : 0))', rails)
        self.assertIn('.position(x: safe.midX, y: topColumn + 34 + (hintShown ? 56 : 0))', rails,
                      'The face control stands under the hint, not on it')

    def test_the_desktop_cluster_has_its_band(self):
        cluster = (SWIFT / 'DesktopCluster.swift').read_text(encoding='utf-8')
        self.assertIn('WM_native_ui_desktop_insets_set(Float(band.top), Float(band.bottom))', cluster)
        self.assertIn('.onDisappear { WM_native_ui_desktop_insets_set(0, 0) }', cluster)
        window = (WM / 'intern/wm_window.cc').read_text(encoding='utf-8')
        rect = block(window, window.index('void WM_window_rect_calc(const wmWindow *win, rcti *r_rect)'))
        self.assertIn('WM_native_ui_desktop_insets(&top, &bottom)', rect)
        native = (WM / 'intern/wm_native_ui.cc').read_text(encoding='utf-8')
        self.assertIn('if (bridge_desktop_insets_changed.exchange(false)) {', native)
        self.assertIn('ED_screen_refresh(C, wm, &win);', native, 'Laid out again at once, not at a draw')
        # A band moving from the bottom to the top keeps the screen's size: its areas move too.
        geometry = (ROOT / 'source/blender/editors/screen/screen_geometry.cc').read_text(encoding='utf-8')
        self.assertIn('screen_size_y_prev != screen_size_y || moved) {', geometry)

    def test_every_placed_control_has_a_zone_or_a_reason(self):
        # Owner, on the iPad: a control that places itself, and does not move when the layout
        # changes, lands on others. Every `.position(` and `.placed(in:` of the controls over the
        # viewport reports its zone to the layout checker (and stands where a layout function put
        # it), or is listed here as anchored to the control or finger it belongs to.
        anchored = {
            ('Rails.swift', 'railFlyout'): 'the open tool list, at the rail it opens from',
            ('Rails.swift', 'railLabel'): "a held tool's name beside its rail, while it is held",
            ('Rails.swift', 'dialBody'): "the Pencil's dial, at the Pencil",
            ('Rails.swift', 'wheel'): "the colour dial's knob, inside the dial",
            ('Rails.swift', 'ColorRollLayer'): "the colour dial, at the colour well it rolls from",
            ('ViewGizmo.swift', '*'): 'the navigation gizmo\'s parts, where Blender placed it (its footprint '
                                      'is a zone the bottom row and framing keep clear of)',
        }
        unplaced = []
        for name in ('Rails.swift', 'QuickActions.swift', 'ViewGizmo.swift', 'CompileIndicator.swift',
                     'DesktopCluster.swift', 'DocumentWindow.swift'):
            lines = (SWIFT / name).read_text(encoding='utf-8').split('\n')
            for i, line in enumerate(lines):
                if not re.search(r'\.position\(|\.placed\(in:', line):
                    continue
                # The modifier chain the placement ends: back to the line that starts the view.
                # The view's first line: the nearest line above, less indented than the modifier,
                # that is not itself a modifier.
                indent = len(line) - len(line.lstrip())
                start = i
                while start > 0:
                    start -= 1
                    text = lines[start]
                    if text.strip() and len(text) - len(text.lstrip()) < indent and \
                            not text.strip().startswith(('.', '}', ')')):
                        break
                chain = '\n'.join(lines[start:i + 1])
                view = lines[start].strip()
                if 'layoutZone(' in chain or re.match(r'(ItemCard|NumberPad)\(', view):
                    continue  # ItemCard reports its own zone ("item").
                owner = next((m.group(1) for j in range(i, -1, -1)
                              for m in [re.match(r'\s*(?:private |@ViewBuilder |fileprivate )*(?:func|var) (\w+)|'
                                                 r'(?:struct|final class) (\w+)', lines[j])] if m), '?')
                struct = next((m.group(1) for j in range(i, -1, -1)
                               for m in [re.match(r'(?:private |fileprivate )?struct (\w+)', lines[j])] if m), '?')
                if (name, owner) in anchored or (name, struct) in anchored or (name, '*') in anchored:
                    continue
                unplaced.append('%s:%d %s' % (name, i + 1, view[:60]))
        self.assertEqual(unplaced, [], 'Placed controls with no layout zone and no reason')

    def test_the_tool_settings_row_has_one_spacing(self):
        # Owner, on the iPad: the bar under the header packed its items too tightly. One spacing,
        # Blender's header's (`buttonspacex`, 8), between every item and on either side of a divider.
        quick = (SWIFT / 'QuickActions.swift').read_text(encoding='utf-8')
        self.assertIn('static let headerSpacing: CGFloat = 8', quick)
        row = (SWIFT / 'ToolSettingsRow.swift').read_text(encoding='utf-8')
        items = block(row, row.index('  private var items: some View {'))
        self.assertIn('HStack(spacing: ShellMetrics.headerSpacing)', items)
        self.assertEqual(re.findall(r'spacing: \d', items), [], 'A one-off spacing in the row')
        self.assertEqual(items.count('BlenderWidgetSeparator(padding: 0)'), items.count('BlenderWidgetSeparator('))
        top = (SWIFT / 'TopBar.swift').read_text(encoding='utf-8')
        mirror = block(top, top.index('struct MirrorInline: View {'))
        self.assertIn('HStack(spacing: ShellMetrics.headerSpacing) {\n      if !axes.isEmpty {', mirror)

    def test_no_control_is_placed_by_a_fixed_edge_padding(self):
        # The old placement: a fixed distance from the window's bottom, outside any layout.
        for path in sorted(SWIFT.glob('*.swift')):
            text = path.read_text(encoding='utf-8')
            for m in re.finditer(r'\.padding\(\.bottom, 96\)', text):
                before = text[:m.start()]
                self.assertGreater(before.rfind('#if os(visionOS)'), before.rfind('#endif'),
                                   '%s: a control placed 96 points above the bottom' % path.name)


if __name__ == '__main__':
    unittest.main()
