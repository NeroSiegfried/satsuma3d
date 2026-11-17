# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""The free-space rule before a save (ROUND5 8I.5, decision 45): `SaveSpace.warning` in
`SaveSpace.swift`, built alone for the Mac with `swiftc` and run against a table of cases. The
file uses Foundation only, so it builds here as it does in the iPad app."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'source/blender/windowmanager/apple_ios/swift/SaveSpace.swift'

MB = 1_000_000
# (free bytes, last saved bytes, the warning or None)
CASES = (
    (10_000 * MB, 0, None),                       # plenty of room, a new file
    (200 * MB, 0, None),                          # exactly the floor: room
    (199 * MB, 0, 'Low storage: 199 MB free.'),   # under the floor
    (150 * MB + 999_999, 0, 'Low storage: 150 MB free.'),  # whole megabytes, rounded down
    (500 * MB, 240 * MB, None),                   # twice the file is 480 MB: room
    (479 * MB, 240 * MB, 'Low storage: 479 MB free.'),  # twice the file is more than the floor
    (250 * MB, 50 * MB, None),                    # twice the file is under the floor: the floor counts
    (0, 0, 'Low storage: 0 MB free.'),            # a full volume
    (-1, 0, None),                                # unknown: the save goes ahead
    (100 * MB, -5, 'Low storage: 100 MB free.'),  # a nonsense size counts as none
)

DRIVER = '''
import Foundation
let cases: [(Int64, Int64, String?)] = [%s]
var failures = 0
for (free, saved, expected) in cases {
  let got = SaveSpace.warning(freeBytes: free, lastSavedBytes: saved)
  if got != expected {
    print("free \\(free) saved \\(saved): got \\(got ?? "nil"), expected \\(expected ?? "nil")")
    failures += 1
  }
}
let empty = SaveSpace.warning(forSavingAt: "")
if empty.first != "room" && empty.first != "unknown" && empty.first != "low" {
  print("warning(forSavingAt:) answered \\(empty)")
  failures += 1
}
if empty.first == "low" && empty.count != 5 {
  print("a low warning has a title, a detail and two buttons: \\(empty)")
  failures += 1
}
print("checked \\(cases.count) cases")
exit(failures == 0 ? 0 : 1)
'''


class SaveSpaceTest(unittest.TestCase):
    def test_rule(self):
        if shutil.which('xcrun') is None:
            self.skipTest('needs Xcode to build Swift')
        cases = ', '.join('(%d, %d, %s)' % (free, saved, 'nil' if text is None else '"%s"' % text)
                          for free, saved, text in CASES)
        with tempfile.TemporaryDirectory() as directory:
            driver = Path(directory) / 'main.swift'
            driver.write_text(DRIVER % cases)
            binary = Path(directory) / 'save_space'
            subprocess.run(['xcrun', 'swiftc', '-O', str(SOURCE), str(driver), '-o', str(binary)], check=True,
                           capture_output=True)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('checked %d cases' % len(CASES), result.stdout)

    def test_message_offers_both_choices(self):
        text = SOURCE.read_text(encoding='utf-8')
        self.assertIn('static let saveAnyway = "Save Anyway"', text)
        self.assertIn('static let cancel = "Cancel"', text)
        self.assertIn('static let detail = "The save may fail."', text)


if __name__ == '__main__':
    unittest.main()
