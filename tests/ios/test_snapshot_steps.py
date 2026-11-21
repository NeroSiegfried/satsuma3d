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


if __name__ == '__main__':
    unittest.main()
