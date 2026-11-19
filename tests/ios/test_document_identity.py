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

# Every function in the operator files and the document that runs an operator in the exec
# context, whatever names it (a string, or an operator type held in a variable, which the
# string sweep above cannot see: the trust prompt's reload was one, ROUND6 SAFE-3).
EXEC_SITES = {
    ('wm_files.cc', 'wm_homefile_read_after_dialog_callback'):
        'after the close-file dialog of read_homefile\'s invoke, which routes before it on iOS',
    ('wm_files.cc', 'wm_recover_last_session_after_dialog_callback'):
        'after the close-file dialog of recover_last_session\'s invoke, which routes before it',
    ('wm_files.cc', 'wm_block_autorun_warning_reload_with_scripts'):
        'saves the preferences only; the reload is wm_test_autorun_revert_action_exec',
    ('wm_files.cc', 'wm_block_autorun_warning_enable_scripts'):
        'saves the preferences only',
    ('wm_files.cc', 'wm_test_autorun_revert_action_exec'):
        'the trust prompt\'s reload: goes through the document first on iOS (ROUND6 SAFE-3)',
    ('wm_files.cc', 'save_file_overwrite_confirm'):
        'the overwrite dialog\'s Save, reached from save_mainfile\'s invoke, which routes before it',
    ('wm_files.cc', 'wm_block_file_close_save'):
        'the close-file dialog\'s Save, reached from invokes that route before it on iOS',
    ('wm_operators.cc', 'doc_view_manual_ui_context_exec'):
        'opens the manual; no file is read or written',
    ('wm_apple_ios_document.cc', 'wm_document_operator'):
        'the document\'s own open (readFromURL), which records what it loaded',
    ('wm_apple_ios_document.cc', 'WM_apple_ios_factory_preferences'):
        'read_factory_userpref: the preferences only, backstop only (ROUND6 SAFE-4)',
}

# Every caller of wm_file_read_opwrap, with what a read by its exec (past the front door) does
# to the document: the document's own path is adopted, another path refused (ROUND6 SAFE-3).
READ_SITES = {
    'wm_open_mainfile__open': 'open_mainfile\'s exec: the document\'s own open, or a script\'s '
                              'open: of its own path adopted, of another path refused',
    'wm_revert_mainfile_exec': 'revert_mainfile\'s exec reads Blender\'s own path, the document\'s: '
                               'adopted',
    'WM_file_recover_last_session': 'quit.blend, another path: refused',
    'wm_recover_auto_save_exec': 'an auto-save, another path: refused',
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
            # The command may be chosen in place (Open with a path, else Recovered Work: ROUND6
            # SAFE-5), but it is the document's route either way.
            self.assertRegex(body, r'WM_apple_ios_document_command\(\s*C,[^;]*wmDocumentCommand::%s\b' % command,
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


    def test_every_exec_call_is_known(self):
        found = set()
        for path in OPERATOR_FILES + [WM / 'intern/wm_apple_ios_document.cc']:
            for name, body in functions(path.read_text(encoding='utf-8')).items():
                if re.search(r'WM_operator_\w*call\w*\((?:[^;])*?ExecDefault', body, re.S):
                    found.add((path.name, name))
        unknown = sorted(found - set(EXEC_SITES))
        self.assertEqual(unknown, [], "These run an operator's exec, past the front door: list them "
                                      "with what they do to the document")
        self.assertEqual(sorted(set(EXEC_SITES) - found), [], "Listed but no longer found")

    def test_every_read_by_exec_is_known(self):
        files = self.sources[WM / 'intern/wm_files.cc']
        found = {name for name, body in functions(files).items() if 'wm_file_read_opwrap(' in body}
        self.assertEqual(sorted(found - set(READ_SITES)), [], "A new way to read a file by exec")
        self.assertEqual(sorted(set(READ_SITES) - found), [], "Listed but no longer found")

    def test_the_trust_prompt_reloads_through_the_document(self):
        files = self.sources[WM / 'intern/wm_files.cc']
        body = functions(files)['wm_test_autorun_revert_action_exec']
        self.assertTrue(body.lstrip().startswith(IOS_BRANCH),
                        "The trust prompt's reload reads the file before the document is asked")
        self.assertIn('WM_apple_ios_document_reload_with_scripts(C)', body[:body.index('#endif')])
        doc = functions((WM / 'intern/wm_apple_ios_document.cc').read_text(encoding='utf-8'))
        reload = doc['WM_apple_ios_document_reload_with_scripts']
        self.assertLess(reload.index('WM_autosave_write('), reload.index('wmDocumentCommand::Reload'),
                        "The work since the save is dropped: the auto-save must be written first")
        self.assertIn('RNA_boolean_set(&props, "use_scripts", true);',
                      doc['WM_apple_ios_document_open'], "The reopen must run the scripts")

    def test_a_read_of_the_documents_own_file_is_adopted(self):
        doc = functions((WM / 'intern/wm_apple_ios_document.cc').read_text(encoding='utf-8'))
        loaded = doc['WM_apple_ios_document_is_loaded']
        # Same path by exec: adopted, so a save is written.
        self.assertRegex(loaded, r'BLI_path_cmp\(BKE_main_blendfile_path\(G_MAIN\), document_path\.c_str\(\)\) == 0\)\s*'
                                 r'\{\s*document_read = WM_file_read_count\(\);')
        # Another path by exec: still refused.
        self.assertTrue(loaded.rstrip().endswith('return false;'))
        self.assertIn('return wmDocumentWrite::Refused;', doc['WM_apple_ios_document_write'])


if __name__ == '__main__':
    unittest.main()
