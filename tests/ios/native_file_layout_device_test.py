# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Run in a QA app with Documents/desktop-layout.blend saved from desktop Blender.

The fixture's active workspace must be named 'Desktop File Layout'. Tests the
actual file reader, including explicit overrides and the desktop-mode opt-in.
The fixture and test report are disposable; no source scene is saved or changed.
"""

import json
from pathlib import Path
import traceback

import bpy

root = Path.home() / 'Documents'
fixture = root / 'desktop-layout.blend'
output = root / 'native-file-layout-test.json'
report = {'status': 'running', 'checks': []}
original_preference = bpy.context.preferences.filepaths.use_load_ui
step = 0


def desktop_mode():
    return bpy.ops.wm.native_interface_toggle.get_rna_type().name == 'Return to iPad Interface'


def save():
    output.write_text(json.dumps(report, indent=2))


def check(condition, label):
    assert condition, label
    report['checks'].append(label)
    save()


def tick():
    global step
    try:
        if step == 0:
            if desktop_mode():
                bpy.ops.wm.native_interface_toggle()
            bpy.context.preferences.filepaths.use_load_ui = True
            step = 1
            return 2.0
        if step in (1, 2, 3):
            expected = f'Native Layout Retained {step}'
            bpy.context.window_manager.windows[0].workspace.name = expected
            args = ({}, {'load_ui': True}, {'load_ui': False})[step - 1]
            report['stage'] = f'native_open_{step}'
            save()
            bpy.ops.wm.open_mainfile(filepath=str(fixture), **args)
            check(bpy.context.window_manager.windows[0].workspace.name == expected,
                  f'Native layout retained for open arguments {args}')
            check(bpy.context.window_manager.windows[0].screen.show_fullscreen, 'Native full-screen state retained')
            check('Desktop File Layout' not in bpy.data.workspaces,
                  'File workspace was not loaded')
            step += 1
            return 2.0
        if step == 4:
            expected = bpy.context.window_manager.windows[0].workspace.name
            bpy.ops.wm.revert_mainfile()
            check(bpy.context.window_manager.windows[0].workspace.name == expected, 'Revert retains the native layout')
            step = 5
            return 2.0
        if step == 5:
            bpy.ops.wm.native_interface_toggle()
            check(desktop_mode(), 'Desktop mode explicitly enabled')
            bpy.ops.wm.open_mainfile(filepath=str(fixture), load_ui=True)
            check(bpy.context.window_manager.windows[0].workspace.name == 'Desktop File Layout',
                  'Desktop mode still permits loading file UI')
            bpy.ops.wm.native_interface_toggle()
            step = 6
            return 2.0
        check(not desktop_mode(), 'Returned to native mode')
        check(bpy.context.window_manager.windows[0].screen.show_fullscreen, 'Native full-screen layout restored')
        bpy.context.preferences.filepaths.use_load_ui = original_preference
        report['status'] = 'passed'
        save()
    except Exception:
        bpy.context.preferences.filepaths.use_load_ui = original_preference
        if desktop_mode():
            bpy.ops.wm.native_interface_toggle()
        report['status'] = 'failed'
        report['error'] = traceback.format_exc()
        save()
        traceback.print_exc()
    return None


save()
bpy.app.timers.register(tick, first_interval=8.0, persistent=True)
