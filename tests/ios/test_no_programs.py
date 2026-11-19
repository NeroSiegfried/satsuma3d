# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Nothing on the iPad starts another program without saying it cannot (ROUND6 FILES-9, G12; 8E).

Every file in Blender's three script trees that starts a process (`subprocess`, `os.system`,
`os.spawn*`, `multiprocessing`) is listed below with how the iPad keeps it from starting one: its
operators fail their poll through `poll_programs` (checked: the named file calls it), the call is
caught and said, or it is not reached on the iPad, with why. A new one fails until it is placed.

Read from the sources, so it runs on any Mac without a build.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TREES = ('scripts/startup', 'scripts/modules', 'scripts/addons_core')
SPAWN = re.compile(r'subprocess\.(?:Popen|run|call|check_output|check_call)\(|os\.system\(|os\.spawn\w*\(|'
                   r'multiprocessing\.')

# file → ("poll", file whose operators poll `poll_programs`) or ("why", reason).
PLACED = {
    'scripts/startup/bl_operators/wm.py': ('poll', 'scripts/startup/bl_operators/wm.py'),
    'scripts/startup/bl_operators/file.py': ('poll', 'scripts/startup/bl_operators/file.py'),
    'scripts/startup/bl_operators/assets.py': ('poll', 'scripts/startup/bl_operators/assets.py'),
    'scripts/startup/bl_operators/image.py': ('poll', 'scripts/startup/bl_operators/image.py'),
    'scripts/startup/bl_operators/screen_play_rendered_anim.py':
        ('poll', 'scripts/startup/bl_operators/screen_play_rendered_anim.py'),
    # The extension system's helper process: every command class shares `_ExtCmdMixIn`, whose
    # subclasses all poll `poll_programs` first.
    'scripts/addons_core/bl_pkg/bl_extension_utils.py': ('poll', 'scripts/addons_core/bl_pkg/bl_extension_ops.py'),
    'scripts/addons_core/bl_pkg/tests/test_blender.py': ('why', 'tests, not shipped behaviour'),
    'scripts/addons_core/bl_pkg/tests/test_cli.py': ('why', 'tests, not shipped behaviour'),
    'scripts/addons_core/bl_pkg/tests/test_cli_blender.py': ('why', 'tests, not shipped behaviour'),
    'scripts/addons_core/bl_pkg/tests/modules/python_wheel_generate.py': ('why', 'tests, not shipped behaviour'),
    'scripts/addons_core/io_scene_gltf2/blender/exp/export.py':
        ('why', 'gltfpack: the failure is caught and the export goes on without it'),
    'scripts/addons_core/ui_translate/update_repo.py': ('why', 'a translators\' add-on for a checkout of the sources'),
    'scripts/modules/_bl_text_utils/external_editor.py': ('why', 'caught and said in the Text Editor'),
    'scripts/modules/_bpy_internal/system_info/text_generate_runtime.py': ('why', 'caught: system info notes it'),
    'scripts/modules/_bpy_internal/system_info/url_prefill_startup.py': ('why', 'a crash report link for desktop; not shown on the iPad'),
    'scripts/modules/_bpy_internal/http/downloader.py': ('why', 'reached only online, which the app never is (8E)'),
    'scripts/modules/_bpy_internal/platform/freedesktop.py': ('why', 'Linux desktop registration'),
    'scripts/modules/_bl_i18n_utils/utils.py': ('why', 'translation tooling for a checkout of the sources'),
    'scripts/modules/_graphviz_export.py': ('why', 'a developer module, not reached from the interface'),
}


class NoProgramsTest(unittest.TestCase):
    def test_every_process_spawn_is_placed(self):
        found = set()
        for tree in TREES:
            for path in (ROOT / tree).rglob('*.py'):
                if SPAWN.search(path.read_text(errors='replace')):
                    found.add(path.relative_to(ROOT).as_posix())
        self.assertGreaterEqual(len(found), 15, found)
        unplaced = sorted(found - set(PLACED))
        self.assertFalse(unplaced, 'files that start a process, not placed: %s' % unplaced)
        stale = sorted(set(PLACED) - found)
        self.assertFalse(stale, 'placed files that no longer start a process: %s' % stale)
        for name, (how, where) in PLACED.items():
            if how == 'poll':
                self.assertIn('poll_programs', (ROOT / where).read_text(), name)

    def test_extension_commands_poll_programs(self):
        ops = (ROOT / 'scripts/addons_core/bl_pkg/bl_extension_ops.py').read_text()
        mixin = ops[ops.index('class _ExtCmdMixIn:'):]
        mixin = mixin[:mixin.index('\n    def exec_command_iter')]
        self.assertIn('poll_programs(cls_)', mixin)
        self.assertIn('cls.poll = classmethod(poll)', mixin)

    def test_console_only_commands_say_so(self):
        events = (ROOT / 'source/blender/windowmanager/intern/wm_event_system.cc').read_text()
        table = events[events.index('static const char *wm_operator_unavailable'):]
        self.assertIn('"WM_OT_memory_statistics"', table[:table.index('\n}\n')])


if __name__ == '__main__':
    unittest.main()
