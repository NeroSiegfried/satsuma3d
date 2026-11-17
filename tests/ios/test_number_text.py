# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Numbers as Blender draws them (ROUND5 6D, 7E/E5): `BlenderNumberText.format` in
`NumberText.swift`, built alone for the Mac with `swiftc` and run against a table of cases, in the
locale `en_US_POSIX` so the separators are fixed."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'source/blender/windowmanager/apple_ios/swift/NumberText.swift'

# (value shown, decimals, unit, text)
CASES = (
    (1.0, 3, None, '1.000'),
    (1.1426, 3, None, '1.143'),
    (-0.00001, 4, None, '0.0000'),     # E5: rounds to zero, so no sign
    (-0.00004, 4, 'm', '0.0000 m'),
    (-0.00005, 4, None, '-0.0001'),    # half away from zero: not zero, keeps its sign
    (-0.4, 0, None, '0'),
    (-0.6, 0, None, '-1'),
    (-12.5, 1, None, '-12.5'),
    (0.0, 2, None, '0.00'),
    (-0.0, 2, None, '0.00'),           # a negative zero
    (90.0, 1, '°', '90.0 °'),
)

DRIVER = '''
import Foundation
let locale = Locale(identifier: "en_US_POSIX")
let cases: [(Double, Int, String?, String)] = [%s]
var failures = 0
for (value, decimals, unit, expected) in cases {
  let got = BlenderNumberText.format(value, decimals: decimals, unit: unit, locale: locale)
  if got != expected {
    print("\\(value) at \\(decimals): got \\(got), expected \\(expected)")
    failures += 1
  }
}
print("checked \\(cases.count) cases")
exit(failures == 0 ? 0 : 1)
'''


class NumberTextTest(unittest.TestCase):
    def test_format(self):
        if shutil.which('xcrun') is None:
            self.skipTest('needs Xcode to build Swift')
        cases = ', '.join('(%r, %d, %s, "%s")' % (value, decimals, 'nil' if unit is None else '"%s"' % unit, text)
                          for value, decimals, unit, text in CASES)
        with tempfile.TemporaryDirectory() as directory:
            driver = Path(directory) / 'main.swift'
            driver.write_text(DRIVER % cases)
            binary = Path(directory) / 'number_text'
            subprocess.run(['xcrun', 'swiftc', '-O', str(SOURCE), str(driver), '-o', str(binary)], check=True,
                           capture_output=True)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('checked %d cases' % len(CASES), result.stdout)


if __name__ == '__main__':
    unittest.main()
