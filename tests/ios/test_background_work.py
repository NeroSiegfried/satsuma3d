# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Long work while the app is away (ROUND6 BUSY-4, G8): `BackgroundWork` in `BackgroundWork.swift`,
built alone for the Mac with `swiftc` and run against the whole table of (task started, GPU granted,
engine) and of the thermal states. Which engines need the GPU is Blender's to say
(`bl_ui.native_render.needs_gpu`), checked for every engine by `script_native_render`; the engine
column here is that table's."""

import itertools
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'source/blender/windowmanager/apple_ios/swift/BackgroundWork.swift'

# Engine (as Blender names it, with Cycles' device) → whether it renders on the GPU.
ENGINES = {
    'BLENDER_EEVEE': True,
    'BLENDER_WORKBENCH': True,
    'CYCLES on the CPU': False,
    'CYCLES on Metal': True,
    'a video written from frames': False,
}


def expected(task_started, gpu_granted, needs_gpu):
    if not task_started:
        return 'pause'  # Asked for, not started: nothing lets the app run.
    if needs_gpu and not gpu_granted:
        return 'pause'  # The GPU refuses work from the background.
    return 'continueWork'


THERMAL = (('nominal', False, True), ('fair', False, True), ('serious', True, False), ('critical', True, False))

DRIVER = '''
import Foundation
var failures = 0
let rows: [(String, Bool, Bool, Bool, String)] = [%s]
for (engine, started, granted, gpu, expected) in rows {
  let got = BackgroundWork.decide(taskStarted: started, gpuGranted: granted, needsGPU: gpu)
  let name = got == .continueWork ? "continueWork" : "pause"
  if name != expected {
    print("\\(engine), started \\(started), GPU granted \\(granted): got \\(name), expected \\(expected)")
    failures += 1
  }
}
let states: [(ProcessInfo.ThermalState, String, Bool, Bool)] = [%s]
for (state, name, warm, cool) in states {
  if BackgroundWork.tooWarm(state) != warm || BackgroundWork.coolEnough(state) != cool {
    print("thermal state \\(name)")
    failures += 1
  }
}
print("checked \\(rows.count) rows and \\(states.count) thermal states")
exit(failures == 0 ? 0 : 1)
'''


class BackgroundWorkTest(unittest.TestCase):
    def test_table(self):
        if shutil.which('xcrun') is None:
            self.skipTest('needs Xcode to build Swift')
        rows = [(engine, started, granted, gpu, expected(started, granted, gpu))
                for (engine, gpu), started, granted in itertools.product(ENGINES.items(), (False, True), (False, True))]
        swift_rows = ', '.join('("%s", %s, %s, %s, "%s")' % (engine, str(started).lower(), str(granted).lower(),
                                                             str(gpu).lower(), outcome)
                               for engine, started, granted, gpu, outcome in rows)
        states = ', '.join('(.%s, "%s", %s, %s)' % (name, name, str(warm).lower(), str(cool).lower())
                           for name, warm, cool in THERMAL)
        with tempfile.TemporaryDirectory() as directory:
            driver = Path(directory) / 'main.swift'
            driver.write_text(DRIVER % (swift_rows, states))
            binary = Path(directory) / 'background_work'
            subprocess.run(['xcrun', 'swiftc', '-O', str(SOURCE), str(driver), '-o', str(binary)], check=True,
                           capture_output=True)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('checked %d rows and %d thermal states' % (len(rows), len(THERMAL)), result.stdout)


if __name__ == '__main__':
    unittest.main()
