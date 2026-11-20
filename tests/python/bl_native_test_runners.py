# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""A test no runner runs is not a test (ROUND7 U4d).

`tests/ios/test_document_safety.py` and `test_document_identity.py` failed in four places after the
move to Blender 5.3 and nothing noticed: no runner named them. This sweep fails on any test file
under `tests/ios`, `tests/python/bl_native_*` or `source/blender/windowmanager/native_ui/tests` that
no runner names, unless it is on DELIBERATE below with its reason (a script that runs inside the
app on an iPad, a probe built elsewhere, a check that needs tools this Mac's ctest does not have).

The runners, and how a file counts as named by them:

- ctest: `tests/python/CMakeLists.txt` (`--python` of each `add_blender_test`) and the gtests of
  `source/blender/windowmanager/CMakeLists.txt`;
- the packaging run, `release/ios/build_testflight.sh` (the `tests/ios` files it names);
- the Mac's `tests/ios` runner, `tests/ios/mac_tests.py` (its QUICK, PACKAGING and OWED lists),
  itself run by ctest `script_native_ios_unittests`;
- the Mac scenarios, `native_ui/tests/mac_bridge_check.py` (`--list`, `--all`), which runs
  `mac_bridge_harness.py`;
- a named test that builds or reads another file in scope (a harness `.mm`, `.cc` or `.swift`, a
  folder, a module it imports) names that file too.

Also here, as the scenario list is one list: the harness's SCENARIOS and `mac_bridge_check.py`'s
name the same scenarios.
"""

import ast
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / 'tests/ios'
PYTHON = ROOT / 'tests/python'
NATIVE = ROOT / 'source/blender/windowmanager/native_ui/tests'
RENAMED = 'renamed in `2dd494eb01d`'
PROBE = ('dead: loads `ResponsiveDeviceProbe.dylib`, which calls `WM_native_ui_operator_enqueue` '
         '(and `WM_native_ui_toolbar_copy_json`, `WM_native_ui_menu_take_result`), ' + RENAMED)


def dead(function):
    return 'dead: calls `%s`, %s' % (function, RENAMED)


# Test files no runner on this Mac runs, on purpose, each with why. A dead one is kept, not ported
# (ROUND7 U4b part 1; the scripts are the same in both apps).
DELIBERATE = {
    # Inside the app on an iPad, copied in and launched as the README says (a device's).
    'tests/ios/testflight_device_test.py': 'runs inside the app on an iPad (a check launch)',
    'tests/ios/native_file_layout_device_test.py': 'runs inside the app on an iPad, with its fixture',
    'tests/ios/duo_render_test.py': 'runs inside the app on an iPad (or a simulator)',
    'tests/ios/hidden_alley_memory_device_test.py': 'runs inside the app on an iPad, with a '
                                                    'production scene this Mac does not have',
    # Dead in both apps (5.1.2 and 5.3.0): the bridge they call was renamed.
    'tests/ios/assets_device_test.py': dead('WM_native_ui_setting_enqueue'),
    'tests/ios/matcap_device_test.py': dead('WM_native_ui_setting_enqueue'),
    'tests/ios/smooth_view_device_test.py': dead('WM_native_ui_command_enqueue'),
    'tests/ios/undo_device_test.py': dead('WM_native_ui_operator_enqueue'),
    **{'tests/ios/%s' % name: PROBE for name in (
        'brush_rail_device_test.py', 'character_template_device_test.py', 'deep_device_test.py',
        'duo_device_test.py', 'hierarchy_add_device_test.py', 'hierarchy_swipe_device_test.py',
        'live_adjustments_device_test.py', 'mesh_select_device_test.py',
        'modifier_menu_device_test.py', 'native_dialogs_device_test.py',
        'native_menubar_device_test.py', 'native_theme_device_test.py',
        'number_sensitivity_device_test.py', 'paired_properties_device_test.py',
        'pencil_hover_device_test.py', 'quick_actions_device_test.py', 'redo_strip_device_test.py',
        'responsive_device_test.py', 'scene_panels_device_test.py',
        'selection_and_brush_hover_device_test.py', 'shading_device_test.py',
        'templates_device_test.py', 'tool_colors_device_test.py', 'tool_groups_device_test.py',
        'tool_settings_device_test.py', 'toolbar_labels_device_test.py',
        'view_gizmo_device_test.py', 'scene_panels_latency_test.py')},
    # Probes and tools built elsewhere.
    'tests/ios/responsive_device_probe.mm': 'the probe library a QA copy of the app carries, built '
                                            'by hand with the iPhoneOS SDK (README); dead with the '
                                            'scripts above: ' + PROBE[6:],
    'tests/ios/templates_device_probe.mm': 'a probe library for a QA copy on an iPad, built by hand',
    'tests/ios/check_pencil_hover_screenshots.swift': 'a person\'s tool for a device run\'s '
                                                      'screenshots of the Pencil hover',
    'source/blender/windowmanager/native_ui/tests/kotlin_check.py': 'the Kotlin shell\'s check: '
                                                                    'needs kotlinc and a JDK, which '
                                                                    'this Mac\'s ctest does not have',
    'source/blender/windowmanager/native_ui/tests/kotlin': 'the Kotlin code kotlin_check.py builds',
}

# Not tests: documentation and caches.
IGNORED = {'README.md', '__pycache__'}

checks = []


def check(ok, name):
    assert ok, name
    checks.append(name)


def in_scope():
    files = [p for p in sorted(IOS.iterdir()) if p.name not in IGNORED]
    files += sorted(PYTHON.glob('bl_native_*.py'))
    files += [p for p in sorted(NATIVE.iterdir()) if p.name not in IGNORED]
    return {str(p.relative_to(ROOT)): p for p in files}


def literal(text, name):
    """The value of the module-level assignment `name = <literal>` in Python source \a text."""
    for node in ast.parse(text).body:
        if isinstance(node, ast.Assign) and any(getattr(t, 'id', None) == name for t in node.targets):
            return node.value
    raise AssertionError("no %s in the source" % name)


def runner_names():
    """{file in scope: the runner that names it}, by the rules in the docstring."""
    named = {}
    cmake = (PYTHON / 'CMakeLists.txt').read_text(encoding='utf-8')
    for match in re.finditer(r'\$\{CMAKE_CURRENT_LIST_DIR\}/([\w./]+\.py)', cmake):
        named[str((PYTHON / match.group(1)).resolve().relative_to(ROOT))] = 'ctest (tests/python)'
    wm = (ROOT / 'source/blender/windowmanager/CMakeLists.txt').read_text(encoding='utf-8')
    for match in re.finditer(r'native_ui/tests/([\w.]+)', wm):
        named['source/blender/windowmanager/native_ui/tests/' + match.group(1)] = 'ctest (gtest)'
    packaging = (ROOT / 'release/ios/build_testflight.sh').read_text(encoding='utf-8')
    for match in re.finditer(r'tests/ios/(\w+\.py)', packaging):
        named['tests/ios/' + match.group(1)] = 'the packaging run (build_testflight.sh)'
    mac_tests = (IOS / 'mac_tests.py').read_text(encoding='utf-8')
    for listed in ('QUICK', 'PACKAGING', 'OWED'):
        value = ast.literal_eval(literal(mac_tests, listed))
        for name in value:
            named['tests/ios/%s.py' % name] = 'tests/ios/mac_tests.py (%s)' % listed
    named['source/blender/windowmanager/native_ui/tests/mac_bridge_check.py'] = 'the Mac scenarios (--all)'
    named['source/blender/windowmanager/native_ui/tests/mac_bridge_harness.py'] = 'mac_bridge_check.py'
    # What a named test builds, reads or imports.
    scope = in_scope()
    changed = True
    while changed:
        changed = False
        # Not from the runners' own lists, which name files to run, not files a test builds.
        sources = [p for p in named if p in scope and scope[p].is_file() and
                   p not in ('tests/python/bl_native_test_runners.py', 'tests/ios/mac_tests.py')]
        for path in sources:
            text = scope[path].read_text(encoding='utf-8', errors='replace')
            for other, other_path in scope.items():
                if other in named or other in DELIBERATE:
                    continue
                name = other_path.name
                if other_path.suffix in ('.mm', '.cc', '.swift') or other_path.is_dir():
                    hit = re.search(r'\b%s\b' % re.escape(name), text)
                elif other_path.suffix == '.py':
                    hit = re.search(r'^\s*(?:import|from)\s+%s\b' % re.escape(other_path.stem), text, re.M)
                else:
                    hit = None
                if hit:
                    named[other] = 'built, read or imported by ' + path
                    changed = True
    return named


def test_every_test_has_a_runner():
    scope = in_scope()
    named = runner_names()
    unnamed = sorted(p for p in scope if p not in named and p not in DELIBERATE)
    check(not unnamed, "test files no runner names (put each in a runner, or on DELIBERATE with "
                       "its reason): %s" % unnamed)
    both = sorted(p for p in DELIBERATE if p in named)
    check(not both, "on DELIBERATE but named by a runner (%s)" % both)
    gone = sorted(p for p in DELIBERATE if p not in scope)
    check(not gone, "on DELIBERATE but no longer there: %s" % gone)
    # A runner's name for a file that is not there is a runner that runs nothing.
    missing = sorted(p for p in named if p in scope or p.startswith(('tests/ios/', 'tests/python/bl_native_'))
                     if not (ROOT / p).exists())
    check(not missing, "named by a runner but missing: %s" % missing)
    # Each dead reason stays true: the script still calls the function it names.
    for path, reason in DELIBERATE.items():
        function = re.match(r'dead: calls `(\w+)`', reason)
        if function:
            check(function.group(1) in (ROOT / path).read_text(encoding='utf-8'),
                  "%s no longer calls %s: its reason is stale" % (path, function.group(1)))
    print("runners name %d test files; %d are a person's or a device's" % (
        len([p for p in scope if p in named]), len(DELIBERATE)))


def test_one_scenario_list():
    check_text = (NATIVE / 'mac_bridge_check.py').read_text(encoding='utf-8')
    listed = ast.literal_eval(literal(check_text, 'SCENARIOS'))
    harness = (NATIVE / 'mac_bridge_harness.py').read_text(encoding='utf-8')
    registered = [key.value for key in literal(harness, 'SCENARIOS').keys]
    check(len(set(listed)) == len(listed), "a scenario listed twice in mac_bridge_check.py")
    check(sorted(listed) == sorted(registered),
          "mac_bridge_check.py's SCENARIOS and the harness's differ: only listed %s, only registered %s"
          % (sorted(set(listed) - set(registered)), sorted(set(registered) - set(listed))))
    check('choices=SCENARIOS' in check_text, "--scenario takes another list than SCENARIOS")
    check('SCENARIOS.get(SCENARIO, _unknown_scenario)' in harness,
          "the harness runs another scenario for a name it does not know")
    print("%d scenarios, one list" % len(listed))


def main():
    test_every_test_has_a_runner()
    test_one_scenario_list()
    print("%d checks passed" % len(checks))


if __name__ == '__main__':
    main()
