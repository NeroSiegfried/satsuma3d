# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""A check script's steps read their own words (`Snapshots.swift`, `ShellSnapshots.run`).

`run` takes the verb off the step once (`words.removeFirst()`). A branch that splits the step
again must drop the verb too: `touch` did not, read the word "touch" as its place, and every
`touch` step was "unknown" on the iPad (ROUND7 U4b; seen again in the ROUND6 device round).
Read from the source, so it runs on any Mac without a build:
`python3 -m unittest tests/ios/test_snapshot_steps.py`.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SNAPSHOTS = ROOT / 'source/blender/windowmanager/apple_ios/swift/Snapshots.swift'


class SnapshotStepsTest(unittest.TestCase):

    def run_body(self):
        text = SNAPSHOTS.read_text()
        start = text.index('private static func run(_ step: String) async {')
        end = text.index('private static var shownRoot', start)
        return text[start:end]

    def test_every_split_of_a_step_drops_its_verb(self):
        body = self.run_body()
        splits = [m for m in re.finditer(r'step\.split\(separator: " "[^)]*\)([^\n]*)', body)]
        self.assertGreater(len(splits), 3, "The step splits were not found: is the sweep stale?")
        for match in splits:
            line = match.group(0)
            if 'maxSplits: 3' in line:
                continue  # `words`, whose verb `run` removes once.
            self.assertIn('dropFirst()', line, "A step split again keeps its verb as its first word: "
                                               + line.strip())



APPLE = ROOT / 'source/blender/windowmanager/apple_ios'


class DialogCancelReachesEveryAlertTest(unittest.TestCase):
    """`dialog cancel` answers every alert on screen as its Cancel (device round 2026-11-21: it
    reached Blender's dialog queue only, and the document's own alerts stayed up). The app's
    alerts made in Objective-C++ make their Cancel through `wm_apple_ios_cancel_action`, so its
    handler is known and run; a Swift alert's Cancel has no handler, so dismissing it is all its
    Cancel does. Any other alert is dismissed and said, not left."""

    def test_every_cancel_action_is_known(self):
        raw = []
        for path in sorted(APPLE.glob('*.mm')):
            if path.name == 'wm_apple_ios_alerts.mm':
                continue  # Blender's own dialogs, the queue `dialog cancel` finishes first.
            text = path.read_text(encoding='utf-8')
            raw += ['%s:%d' % (path.name, text[:m.start()].count('\n') + 1)
                    for m in re.finditer(r'UIAlertActionStyleCancel', text)]
        self.assertEqual(raw, [], "Cancel actions not made with wm_apple_ios_cancel_action: "
                                  "`dialog cancel` cannot run their handlers")
        made = sum(path.read_text(encoding='utf-8').count('wm_apple_ios_cancel_action(')
                   for path in APPLE.glob('*.mm'))
        self.assertGreaterEqual(made, 11, "The sweep no longer finds the app's alerts")

    def test_swift_cancel_actions_have_no_handler(self):
        with_handler = []
        for path in sorted((APPLE / 'swift').glob('*.swift')):
            text = path.read_text(encoding='utf-8')
            for m in re.finditer(r'UIAlertAction\(title: [^\n]*style: \.cancel([^\n]*)', text):
                if 'handler' in m.group(1) or '{' in m.group(1):
                    with_handler.append('%s:%d' % (path.name, text[:m.start()].count('\n') + 1))
        self.assertEqual(with_handler, [], "A Swift Cancel with a handler: `dialog cancel` would "
                                           "dismiss it without running it")

    def test_cancel_all_reaches_the_alerts_on_screen(self):
        alerts = (APPLE / 'wm_apple_ios_alerts.mm').read_text(encoding='utf-8')
        start = alerts.index('extern "C" int wm_apple_ios_dialogs_cancel_all(void)')
        body = alerts[start:alerts.index('\n}\n', start)]
        self.assertIn('[request finish:-1];', body)
        self.assertIn('alerts_cancel_all(queued)', body)
        walk = alerts[alerts.index('static int alerts_cancel_all('):start]
        for needed in ('connectedScenes', 'presentedViewController', 'UIAlertActionStyleCancel',
                       'cancel_handlers() objectForKey:cancel', 'dismissViewControllerAnimated:NO',
                       '"dialog cancel: alert with no Cancel dismissed: "'):
            self.assertIn(needed, walk)
        self.assertIn('wm_apple_ios_dialogs_cancel_all()', SNAPSHOTS.read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
