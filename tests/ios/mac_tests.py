# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""The Mac's runner of the `test_*.py` modules in `tests/ios` (ROUND7 U4d).

A test no runner runs is not a test: on the move to Blender 5.3 `test_document_safety.py` and
`test_document_identity.py` failed in four places and nothing noticed, because nothing ran them.
Every module is named here, in one of three lists, and `tests/python/bl_native_test_runners.py`
(ctest `script_native_test_runners`) fails on a test file that no runner names.

- `QUICK`: run by ctest `script_native_ios_unittests`, inside Blender's own Python (the modules
  that start Blender get it as `BLENDER_BIN`). Source sweeps and short checks; a few seconds each.
- `PACKAGING`: the packaging run's set (minutes): `python3 tests/ios/mac_tests.py packaging`.
  `build_testflight.sh` runs the first itself.
- `OWED`: failing, each with what fails. They are run with the quick set and must
  still fail as written; one that passes fails the run, so the list cannot go stale. Nothing here
  is silent: every run prints each owed module's failures.

    blender --background --factory-startup --python tests/ios/mac_tests.py -- quick
    python3 tests/ios/mac_tests.py packaging
"""

import io
import os
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent

QUICK = (
    'test_background_work',
    'test_build_capabilities',
    'test_character_template',
    'test_device_floor',
    'test_document_identity',
    'test_document_neighbours',
    'test_document_safety',
    'test_export_icons',
    'test_files_sent',
    'test_ipad_pencil',
    'test_ipad_resize',
    'test_iphone_startup',
    'test_memory_caps',
    'test_native_dialogs',
    'test_native_files',
    'test_native_templates',
    'test_native_tool_groups',
    'test_no_programs',
    'test_number_text',
    'test_responsive_ui',
    'test_save_space',
    'test_starter_library',
    'test_swiftui_panels',
)

PACKAGING = (
    'test_testflight_packaging',
    'test_check_publishable',
)

# Failing, each with what fails; empty when none is (every module passes on 5.1.2). A module that
# fails on a reading of a new Blender goes here with its failure until it is mended, never quietly
# skipped.
OWED = {}


def run(names, expect_failure=False):
    """Run each module on its own; the names whose outcome is not the expected one."""
    wrong = []
    for name in names:
        stream = io.StringIO()
        suite = unittest.defaultTestLoader.loadTestsFromName(name)
        result = unittest.TextTestRunner(stream=stream, verbosity=1).run(suite)
        failed = not result.wasSuccessful()
        tag = ('owed, still failing' if failed else 'OWED BUT PASSES') if expect_failure else \
            ('FAILED' if failed else 'ok')
        print('%-34s %s: %d run, %d failed, %d errors, %d skipped' % (
            name, tag, result.testsRun, len(result.failures), len(result.errors), len(result.skipped)))
        if failed:
            for test, trace in result.failures + result.errors:
                print('    %s: %s' % (test.id(), trace.strip().splitlines()[-1][:300]))
        if failed != expect_failure:
            wrong.append(name)
    return wrong


def main(argv):
    which = argv[0] if argv else 'quick'
    sys.path.insert(0, str(HERE))
    os.chdir(HERE.parents[1])
    try:
        import bpy
        os.environ.setdefault('BLENDER_BIN', bpy.app.binary_path)
    except ImportError:
        pass
    if which == 'quick':
        wrong = run(QUICK) + run(sorted(OWED), expect_failure=True)
        total = len(QUICK) + len(OWED)
    elif which == 'packaging':
        wrong = run(PACKAGING)
        total = len(PACKAGING)
    else:
        print('usage: mac_tests.py quick|packaging')
        return 2
    print('%s: %d modules, %d not as expected%s' % (which, total, len(wrong),
                                                    (': ' + ', '.join(wrong)) if wrong else ''))
    return 1 if wrong else 0


if __name__ == '__main__':
    argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else sys.argv[1:]
    sys.exit(main(argv))
