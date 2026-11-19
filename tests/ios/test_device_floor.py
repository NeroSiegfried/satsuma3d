# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""The device floor (ROUND5 8N, N1): `DeviceFloor.verdict` in `DeviceFloor.swift`, built alone for
the Mac with `swiftc` and run against a table of cases. The file uses Foundation only, so it builds
here as it does in the iPad app."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SWIFT = ROOT / 'source/blender/windowmanager/apple_ios/swift'
SOURCE = SWIFT / 'DeviceFloor.swift'

GIB = 1 << 30
# (GPU name or None, memory in bytes, verdict)
CASES = (
    ('Apple M1 GPU', 8 * GIB, 'atFloor'),               # the owner's floor
    ('Apple M1 GPU', int(7.5 * GIB), 'atFloor'),        # an 8 GB iPad reports a little under 8 GiB
    ('Apple M4 GPU', 16 * GIB, 'atFloor'),
    ('Apple M2 GPU', 7 * GIB, 'atFloor'),               # exactly the threshold
    ('Apple M2 GPU', 7 * GIB - 1, 'below'),             # less memory than the floor
    ('Apple A16 GPU', 6 * GIB, 'below'),                # an A-series chip
    ('Apple A17 Pro GPU', 8 * GIB, 'below'),            # A-series with 8 GB: still below
    ('Apple A12Z GPU', 6 * GIB, 'below'),               # memory decides first
    ('Apple Paravirtual device', 8 * GIB, 'unknown'),   # a name it does not know
    (None, 8 * GIB, 'unknown'),                         # no name read
    (None, 4 * GIB, 'below'),                           # no name, little memory: memory alone decides
    ('Apple MX GPU', 8 * GIB, 'unknown'),               # not a generation number
    ('AMD Radeon Pro', 32 * GIB, 'unknown'),
)

DRIVER = '''
import Foundation
let cases: [(String?, UInt64, DeviceFloor.Verdict)] = [%s]
var failures = 0
for (name, memory, expected) in cases {
  let got = DeviceFloor.verdict(chipName: name, memoryBytes: memory)
  if got != expected {
    print("\\(name ?? "nil") \\(memory): got \\(got), expected \\(expected)")
    failures += 1
  }
}
func expect(_ got: String, _ expected: String) {
  if got != expected {
    print("got:      \\(got)\\nexpected: \\(expected)")
    failures += 1
  }
}
let gib: UInt64 = 1 << 30
expect(DeviceFloor.sentence(appName: "Satsuma 3D", chipName: "Apple A16 GPU", memoryBytes: 6 * gib),
       "Satsuma 3D is made for iPads with an M-series chip and 8 GB of memory. This iPad has Apple A16, 6 GB. "
       + "Large scenes may run out of memory, and this iPad has not been tested.")
/* An unknown name is not said: the memory alone. */
expect(DeviceFloor.sentence(appName: "Satsuma 3D", chipName: nil, memoryBytes: UInt64(5.6 * Double(gib))),
       "Satsuma 3D is made for iPads with an M-series chip and 8 GB of memory. This iPad has 6 GB. "
       + "Large scenes may run out of memory, and this iPad has not been tested.")
expect(String(DeviceFloor.gigabytes(UInt64(7.5 * Double(gib)))), "8")
expect(String(DeviceFloor.gigabytes(8 * gib)), "8")
expect(String(DeviceFloor.gigabytes(UInt64(3.7 * Double(gib)))), "4")
expect(DeviceFloor.logLine(chipName: "Apple M1 GPU", memoryBytes: UInt64(7.5 * Double(gib)), verdict: .atFloor,
                           pretend: false),
       "floor: chip=Apple M1 GPU memory=7.5GB verdict=at_floor")
expect(DeviceFloor.logLine(chipName: nil, memoryBytes: 6 * gib, verdict: .below, pretend: true),
       "floor: chip=unread memory=6.0GB verdict=below (pretend)")
let pretend = DeviceFloor.pretend("Apple A16 GPU,6")
expect("\\(pretend?.name ?? "nil") \\(pretend?.memoryBytes ?? 0)", "Apple A16 GPU \\(6 * gib)")
for bad in [nil, "", "Apple A16 GPU", "Apple A16 GPU,", ",6", "Apple A16 GPU,six", "Apple A16 GPU,0"] as [String?] {
  if DeviceFloor.pretend(bad) != nil {
    print("pretend(\\(bad ?? "nil")) should be nil")
    failures += 1
  }
}
print("checked \\(cases.count) cases")
exit(failures == 0 ? 0 : 1)
'''


class DeviceFloorTest(unittest.TestCase):
    def test_rule(self):
        if shutil.which('xcrun') is None:
            self.skipTest('needs Xcode to build Swift')
        cases = ', '.join('(%s, %d, .%s)' % ('nil' if name is None else '"%s"' % name, memory, verdict)
                          for name, memory, verdict in CASES)
        with tempfile.TemporaryDirectory() as directory:
            driver = Path(directory) / 'main.swift'
            driver.write_text(DRIVER % cases)
            binary = Path(directory) / 'device_floor'
            build = subprocess.run(['xcrun', 'swiftc', '-O', str(SOURCE), str(driver), '-o', str(binary)],
                                   capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('checked %d cases' % len(CASES), result.stdout)

    def test_wired(self):
        """N2–N4: logged at every launch, the notice once per version with one button, About while
        true, pretending only in a check launch; the launcher and a document's window both ask."""
        notice = (SWIFT / 'DeviceFloorNotice.swift').read_text()
        self.assertIn('WM_native_ui_log("device", DeviceFloor.logLine(', notice)
        self.assertIn('if checkLaunch, let pretend = DeviceFloor.pretend(environment["PLATYPUS_PRETEND_DEVICE"])',
                      notice)
        self.assertEqual(notice.count('UIAlertAction('), 1)
        self.assertIn('UIAlertAction(title: "Continue", style: .default)', notice)
        self.assertIn('let record = !reading.pretend && !checkLaunch', notice)
        self.assertIn('MTLCreateSystemDefaultDevice()?.name', notice)
        self.assertIn('ProcessInfo.processInfo.physicalMemory', notice)
        self.assertIn('DeviceFloorNotice.aboutSentence', (SWIFT / 'AboutSheet.swift').read_text())
        self.assertIn('DeviceFloorNotice.presentIfNeeded(from: nil)', (SWIFT / 'DocumentWindow.swift').read_text())
        launcher = (SWIFT.parent / 'wm_apple_ios_launcher.mm').read_text()
        self.assertIn('[floor_class presentIfNeededFrom:self];', launcher)
        cmake = (ROOT / 'source/creator/CMakeLists.txt').read_text()
        for name in ('DeviceFloor.swift', 'DeviceFloorNotice.swift'):
            self.assertIn('apple_ios/swift/' + name, cmake)


if __name__ == '__main__':
    unittest.main()
