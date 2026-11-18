# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""A document is never overwritten with another file (ROUND5 9D, decisions 61-64).

In a document window, the file Blender has loaded is the document, from open to close. Two
mechanisms keep it so, and this test fails when a new way around them appears:

- The front door: every operator in `wm_files.cc`, `wm_window.cc` and `wm_operators.cc` that can
  reach a main-file read, a write of the main file or an exit takes the document's route from its
  `invoke` on iOS (`WM_apple_ios_document_command`), or is on the short "backstop only" list below
  with its reason. The key table (`bridge_document_command` in `wm_native_ui.cc`) names the same
  operators.
- The backstop: every main-file read passes `wm_file_read_pre`, which counts it; the document
  records the count its own open loaded and refuses to write when Blender has read another file
  since. Nothing else replaces the session's data.

Read from the sources, so it runs on any Mac without a build.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WM = ROOT / 'source/blender/windowmanager'
OPERATOR_FILES = [WM / 'intern/wm_files.cc', WM / 'intern/wm_window.cc', WM / 'intern/wm_operators.cc']

# What loads a main file, writes it, or ends the app.
SINKS = {
    'WM_file_read', 'wm_file_read_opwrap', 'wm_homefile_read', 'wm_homefile_read_ex',
    'WM_file_recover_last_session', 'BKE_blendfile_read_setup_readfile',
    'wm_file_write', 'wm_apple_ios_file_write',
    'WM_exit', 'WM_exit_ex', 'wm_exit_schedule_delayed',
}

# Operators whose invoke takes the document's route on iOS, by their #wmDocumentCommand.
ROUTED = {
    'WM_OT_read_homefile': 'New',
    'WM_OT_read_factory_settings': 'New',
    'WM_OT_open_mainfile': 'Open',
    'WM_OT_recover_last_session': 'Open',
    'WM_OT_recover_auto_save': 'Open',
    'WM_OT_revert_mainfile': 'Revert',
    'WM_OT_save_mainfile': 'Save',
    'WM_OT_save_as_mainfile': 'SaveAs',
    'WM_OT_quit_blender': 'Quit',
}

# Functions every caller of which takes the document's route on iOS, as their first statement: what
# reaches a sink only through them is routed. Closing the last window and a request to quit pass
# the quit prompt (Close Window, and Save Startup File closing a temporary window).
GUARDED = {
    'wm_quit_with_optional_confirmation_prompt': 'Quit',
}

# Operators that reach a sink but are not routed, each with why the backstop is enough.
BACKSTOP_ONLY = {
    'WM_OT_read_userpref': 'reads the preferences only (use_data false): the session\'s data is not '
                           'replaced and nothing is counted',
    'WM_OT_read_factory_userpref': 'reads the factory preferences only (use_data false), as above',
}

# Calls of the routed operators in the exec context, which skip their invoke and so the front
# door: each is known, with why it is safe or what it leaves (reported in STATUS.md).
EXEC_CALLS = {
    ('source/blender/windowmanager/intern/wm_apple_ios_document.cc', 'WM_OT_open_mainfile'):
        'the document\'s own open (readFromURL), which records what it loaded',
    ('source/blender/windowmanager/intern/wm_files.cc', 'WM_OT_read_homefile'):
        'after the close-file dialog of its own invoke, which routes before it on iOS',
    ('source/blender/windowmanager/intern/wm_files.cc', 'WM_OT_recover_last_session'):
        'after the close-file dialog of its own invoke, which routes before it on iOS',
    ('source/blender/windowmanager/intern/wm_files.cc', 'WM_OT_save_mainfile'):
        'the overwrite and close-file dialogs\' Save, reached from invokes that route before them '
        'on iOS',
    ('source/blender/editors/asset/intern/asset_ops.cc', 'WM_OT_save_mainfile'):
        'Install Asset Bundle saves into an asset library; it writes Blender\'s path, never the '
        'document object (the backstop does not see it: a write, not a read)',
}

IOS_BRANCH = '#if defined(WITH_APPLE_CROSSPLATFORM) && APPLE_TARGET_IOS'


def functions(text):
    """Top-level function definitions, Blender's style: the name and parameters, then `{` on a
    line of its own, the body ending at the first `}` alone on a line."""
    found = {}
    for match in re.finditer(r'^[A-Za-z][^\n;#]*?\b(\w+)\((?:[^()]|\([^()]*\))*\)\s*(?:const\s*)?\n\{\n',
                             text, re.M):
        end = text.find('\n}\n', match.end())
        if end != -1:
            found.setdefault(match.group(1), text[match.end():end])
    return found


def calls(body):
    return set(re.findall(r'\b(\w+)\s*\(', body))


def operators(text):
    """Each `WM_OT_*` definition's idname, invoke and exec."""
    found = {}
    for name, body in functions(text).items():
        idname = re.search(r'ot->idname = "(\w+)";', body)
        if not name.startswith('WM_OT_') or not idname:
            continue
        found[idname.group(1)] = {
            'invoke': (re.search(r'ot->invoke = (\w+);', body) or [None, None])[1],
            'exec': (re.search(r'ot->exec = (\w+);', body) or [None, None])[1],
        }
    return found


class DocumentIdentityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sources = {path: path.read_text(encoding='utf-8') for path in OPERATOR_FILES}
        cls.bodies = {}
        cls.operators = {}
        for text in cls.sources.values():
            cls.bodies.update(functions(text))
            cls.operators.update(operators(text))
        cls.reach_cache = {}

    def reaches(self, name, seen=None):
        """Whether calling `name` can reach a sink, through functions of these files."""
        if name in self.reach_cache:
            return self.reach_cache[name]
        seen = seen if seen is not None else set()
        if name in SINKS:
            return True
        if name in GUARDED:
            return False
        if name in seen or name not in self.bodies:
            return False
        seen.add(name)
        result = any(self.reaches(callee, seen) for callee in calls(self.bodies[name]))
        self.reach_cache[name] = result
        return result

    def reaching_operators(self):
        return sorted(idname for idname, op in self.operators.items()
                      if any(op[kind] and self.reaches(op[kind]) for kind in ('invoke', 'exec')))

    def test_every_file_operator_is_routed_or_listed(self):
        reaching = self.reaching_operators()
        self.assertTrue(set(ROUTED) <= set(reaching), "The sweep no longer sees the routed operators")
        unknown = [idname for idname in reaching if idname not in ROUTED and idname not in BACKSTOP_ONLY]
        self.assertEqual(unknown, [], "These operators load, write or quit and neither take the "
                                      "document's route nor are listed as backstop only, with a reason")

    def test_lists_are_current(self):
        reaching = set(self.reaching_operators())
        stale = sorted(set(BACKSTOP_ONLY) - reaching)
        self.assertEqual(stale, [], "Listed as backstop only but no longer reaching a load, write or exit")
        for idname, reason in BACKSTOP_ONLY.items():
            self.assertTrue(len(reason) > 20, "%s needs its reason" % idname)

    def test_routed_invokes_take_the_front_door(self):
        for idname, command in ROUTED.items():
            invoke = self.operators[idname]['invoke']
            self.assertIsNotNone(invoke, idname)
            body = self.bodies[invoke]
            self.assertIn(IOS_BRANCH, body, "%s's invoke has no iOS branch" % idname)
            self.assertIn('WM_apple_ios_document_command(C, wmDocumentCommand::%s' % command, body,
                          "%s's invoke does not take the document's route (%s)" % (idname, command))

    def test_guarded_functions_route_first(self):
        for name, command in GUARDED.items():
            body = self.bodies[name]
            self.assertTrue(body.lstrip().startswith(IOS_BRANCH) and
                            'WM_apple_ios_document_command(C, wmDocumentCommand::%s' % command in
                            body[:body.index('#endif')],
                            "%s no longer takes the document's route before anything else" % name)

    def test_quit_never_exits_on_ios(self):
        # Nothing catches an exit, so Quit's exec routes too.
        exec_body = self.bodies[self.operators['WM_OT_quit_blender']['exec']]
        self.assertIn('WM_apple_ios_document_command(C, wmDocumentCommand::Quit', exec_body)
        self.assertLess(exec_body.index('wmDocumentCommand::Quit'), exec_body.index('wm_exit_schedule_delayed'))

    def test_key_table_knows_the_file_commands(self):
        text = (WM / 'intern/wm_native_ui.cc').read_text(encoding='utf-8')
        start = text.index('static const char *bridge_document_command(')
        table = dict(re.findall(r'\{"(WM_OT_\w+)", "(\w+)"\}', text[start:text.index('\n}\n', start)]))
        names = {'New': 'new', 'Open': 'open', 'Revert': 'revert', 'Save': 'save', 'SaveAs': 'save_as',
                 'Quit': 'quit'}
        self.assertEqual(table, {idname: names[command] for idname, command in ROUTED.items()})
        for menu in ('TOPBAR_MT_file_new', 'TOPBAR_MT_file_open_recent', 'TOPBAR_MT_file_context_menu'):
            self.assertIn('menu == "%s"' % menu, text, "The key table does not know %s's key" % menu)

    def test_every_read_is_counted(self):
        files = self.sources[WM / 'intern/wm_files.cc']
        bodies = functions(files)
        self.assertRegex(bodies['wm_file_read_pre'], r'if \(use_data\) \{\s*/\*[^*]*(?:\*(?!/)[^*]*)*\*/\s*'
                                                     r'wm_file_read_counter\+\+;',
                         "wm_file_read_pre no longer counts every read of the session's data")
        # Whatever replaces the session's data passes wm_file_read_pre first.
        for name, body in bodies.items():
            if 'BKE_blendfile_read_setup_readfile(' in body:
                self.assertIn('wm_file_read_pre(', body, "%s replaces the session's data uncounted" % name)
        # Nowhere else replaces it (undo has its own, which keeps the document's data).
        elsewhere = []
        for path in (ROOT / 'source').rglob('*.c*'):
            if path.suffix not in ('.cc', '.c', '.mm') or path.name in ('wm_files.cc', 'blendfile.cc'):
                continue
            if 'BKE_blendfile_read_setup_readfile(' in path.read_text(encoding='utf-8', errors='replace'):
                elsewhere.append(str(path.relative_to(ROOT)))
        self.assertEqual(elsewhere, [], "The session's data is replaced outside wm_files.cc")

    def test_the_document_refuses_another_file(self):
        text = (WM / 'intern/wm_apple_ios_document.cc').read_text(encoding='utf-8')
        bodies = functions(text)
        write = bodies['WM_apple_ios_document_write']
        refusal = write.index('if (!WM_apple_ios_document_is_loaded())')
        self.assertLess(refusal, write.index('wm_document_write('), "The check comes after the write")
        self.assertIn('write refused: the loaded file is not this document', write)
        self.assertIn('document_read = WM_file_read_count();', bodies['WM_apple_ios_document_open'])
        self.assertIn('document_read = UINT64_MAX;', bodies['WM_apple_ios_document_open'],
                      "A document that failed to open must own nothing")
        document = (WM / 'apple_ios/wm_apple_ios_blend_document.mm').read_text(encoding='utf-8')
        for needed in ('Save a Copy…', 'Reopen Document', '[self writeRefused]'):
            self.assertIn(needed, document, "The refusal is not said with %s" % needed)

    def test_the_shell_invokes_file_commands(self):
        # The shell's operator channel runs buttons in the exec context: file commands are invoked
        # there, so they take the route (seen 2026-11-18: `op WM_OT_read_homefile` read the
        # start-up file into a document window and crashed on the freed reports).
        views = (WM / 'intern/wm_native_ui_views.cc').read_text(encoding='utf-8')
        run = functions(views)['operator_run']
        self.assertIn('WM_native_ui_is_document_command(ot->idname)', run)
        self.assertIn('if (CTX_wm_manager(C) != wm) {', run)

    def test_check_launches_leave_the_persons_document(self):
        # A check launch's Quit or Back must not drop the bookmark the next ordinary launch
        # continues in (seen 2026-11-18).
        launcher = (WM / 'apple_ios/wm_apple_ios_launcher.mm').read_text(encoding='utf-8')
        for match in re.finditer(r'removeObjectForKey:launcher_open_document_key', launcher):
            before = launcher[max(0, match.start() - 400):match.start()]
            self.assertTrue('!_scratch' in before or 'PLATYPUS_SCRATCH_DOCUMENT"] == nil' in before,
                            "A check launch can drop the person's open document (offset %d)" % match.start())

    def test_exec_calls_are_known(self):
        names = '|'.join(ROUTED)
        found = set()
        for path in (ROOT / 'source').rglob('*'):
            if path.suffix not in ('.cc', '.c', '.mm'):
                continue
            text = path.read_text(encoding='utf-8', errors='replace')
            for match in re.finditer(r'"(%s)"' % names, text):
                window = text[match.start():match.start() + 300]
                if re.search(r'^[^;]*ExecDefault', window, re.S):
                    found.add((str(path.relative_to(ROOT)), match.group(1)))
        unknown = sorted(found - set(EXEC_CALLS))
        self.assertEqual(unknown, [], "These run a file command's exec directly, past the front door")


if __name__ == '__main__':
    unittest.main()
