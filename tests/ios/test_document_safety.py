# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Work is never lost without a word (ROUND6 Run 1, SAFE).

Sweeps of the iPad document's sources, one per class, so the next gap fails loudly:

- SAFE-1: every caller of the document's write (`saveChangesWithCompletionHandler:`,
  `saveToURL:`, `closeWithCompletionHandler:`, `autosaveWithCompletionHandler:` and Swift's
  `save(to:)`, `close`, `autosave`) is known, and every write ends in the one failure path: the
  write's outcome from `writeContents`, or UIKit's error through `handleError:`.

- SAFE-2: every condition Blender's Save asks about before overwriting
  (`BKE_main_needs_overwrite_confirm`) has the held document's words, and nothing writes a held
  document before the person answers.

- SAFE-4: whatever opens a document at launch passes the session marker first, every path that
  opens a document sets it, and the log is kept where iOS keeps it, dated, within a second.

Read from the sources, so it runs on any Mac without a build:
`python3 -m unittest tests/ios/test_document_safety.py`.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WM = ROOT / 'source/blender/windowmanager'
APPLE = WM / 'apple_ios'
BDOC = APPLE / 'wm_apple_ios_blend_document.mm'
LAUNCH = APPLE / 'wm_apple_ios_launcher.mm'
DOC = WM / 'intern/wm_apple_ios_document.cc'

# Every place that asks UIKit to write (or close, which writes) the document, by file and the
# function or method around it, with how its failure reaches the person. A new caller fails the
# sweep until it is listed here, with its reason.
WRITE_CALLERS = {
    ('wm_apple_ios_blend_document.mm', 'saveForPerson:completion:'):
        'the person\'s save (Save, Try Again, Back, opening another): marked explicit, so the '
        'failure path says its failure every time',
    ('wm_apple_ios_blend_document.mm', 'saveChangesWithCompletionHandler:'):
        'the override itself: passes to UIKit\'s autosave, whose write ends in writeContents',
    ('wm_apple_ios_blend_document.mm', 'autosaveWithCompletionHandler:'):
        'the override itself: UIKit\'s periodic autosave is declined while editing',
    ('wm_apple_ios_blend_document.mm', 'saveAlongTheWay'):
        'saving along the way: its failure is said once per cause and it backs off',
    ('wm_apple_ios_blend_document.mm', 'closeWithCompletionHandler:'):
        'the override itself: closing writes through writeContents',
    ('wm_apple_ios_blend_document.mm', 'wm_apple_ios_document_file_now'):
        'Save As and Share: on failure a fresh copy is written from memory, never the old file',
    ('wm_apple_ios_launcher.mm', 'openDocumentAtURL:'):
        'opening another document closes this one, marked as the person\'s save; on failure the '
        'failure path said why and the document stays',
    ('wm_apple_ios_launcher.mm', 'sceneWillDeactivate:'):
        'leaving the app: a nil completion, the failure path says it once per cause',
    ('wm_apple_ios_launcher.mm', 'launcher_close_document'):
        'visionOS closing after Back: reached only once nothing is left to save',
    ('wm_apple_ios_launcher.mm', 'wm_apple_ios_document_check_step'):
        'a check launch\'s `save` step, which reports the outcome it gets',
}

CALL = re.compile(r'saveChangesWithCompletionHandler:|saveToURL:|closeWithCompletionHandler:|'
                  r'autosaveWithCompletionHandler:|\.save\(to:|\.close\(completionHandler|'
                  r'\.autosave\(')


def enclosing(text, offset):
    """The Objective-C method, C function or Swift function around \a offset."""
    head = text[:offset]
    best, name = -1, None
    for match in re.finditer(r'^- \(.*$', head, re.M):
        if match.start() > best:
            line = match.group(0)
            selector = ''.join(part + ':' for part in re.findall(r'(\w+):\(', line))
            best, name = match.start(), selector or re.match(r'- \([^)]*\)\s*(\w+)', line).group(1)
    for match in re.finditer(r'^(?:static |extern "C" )?[A-Za-z_][\w *]*?\b(\w+)\([^;{]*\)\n\{', head, re.M):
        if match.start() > best:
            best, name = match.start(), match.group(1)
    for match in re.finditer(r'^\s*(?:@objc )?(?:private |public )?func (\w+)', head, re.M):
        if match.start() > best:
            best, name = match.start(), match.group(1)
    return name


def body_of(text, signature):
    """The body of the function or method whose definition starts with \a signature."""
    start = text.index(signature)
    while True:
        brace = text.index('\n{\n', start)
        if ';' not in text[start:brace]:
            break  # A definition, not a declaration.
        start = text.index(signature, start + 1)
    start = brace + 3
    return text[start:text.index('\n}\n', start)]


class SaveFailureIsSaidTest(unittest.TestCase):
    """SAFE-1: a failed save is said."""

    @classmethod
    def setUpClass(cls):
        cls.document = BDOC.read_text(encoding='utf-8')
        cls.launcher = LAUNCH.read_text(encoding='utf-8')
        cls.doc = DOC.read_text(encoding='utf-8')

    def write_callers(self):
        found = set()
        paths = sorted(APPLE.glob('*.mm')) + sorted((APPLE / 'swift').glob('*.swift')) + \
            sorted((ROOT / 'intern/ghost/intern').glob('*IOS*.mm'))
        for path in paths:
            text = path.read_text(encoding='utf-8')
            for match in CALL.finditer(text):
                line = text[text.rfind('\n', 0, match.start()) + 1:text.find('\n', match.start())]
                if line.startswith('- ('):
                    continue  # The override's own definition.
                found.add((path.name, enclosing(text, match.start())))
        return found

    def test_every_write_caller_is_known(self):
        found = self.write_callers()
        unknown = sorted(found - set(WRITE_CALLERS))
        self.assertEqual(unknown, [], "These write or close the document and are not known to pass "
                                      "through the failure path: list them with their reason")
        stale = sorted(set(WRITE_CALLERS) - found)
        self.assertEqual(stale, [], "Listed as writing the document but no longer found")

    def test_every_write_ends_in_the_failure_path(self):
        write = body_of(self.document, '- (BOOL)writeContents:(id)contents')
        self.assertIn('[self writeOutcome:@"written" reason:nil]', write)
        self.assertIn('[self writeOutcome:outcome reason:reason]', write)
        self.assertIn('NSLocalizedFailureReasonErrorKey : reason', write,
                      "UIKit must be handed Blender's reason")
        handle = body_of(self.document, '- (void)handleError:(NSError *)error')
        self.assertIn('[self saveFailed:reason]', handle)
        self.assertIn('finishedHandlingError:error', handle)
        outcome = body_of(self.document, '- (void)writeOutcome:(NSString *)outcome')
        for said in ('[self saveFailed:reason]', '[self saveBusy]', '[self writeSucceeded]'):
            self.assertIn(said, outcome)

    def test_blenders_reason_is_kept(self):
        write = body_of(self.doc, 'static bool wm_document_write(')
        self.assertLess(write.index('write_reason(reports)'), write.index('BKE_reports_free(&reports)'),
                        "Blender's reason is freed before anyone reads it")

    def test_busy_is_not_a_failure(self):
        wait = body_of(self.document, 'static bool engine_wait(')
        self.assertIn('*r_timed_out = true;', wait)
        write = body_of(self.document, '- (BOOL)writeContents:(id)contents')
        self.assertRegex(write, r'if \(timed_out\) \{\s*outcome = @"busy";')

    def test_back_never_calls_itself(self):
        back = body_of(self.launcher, 'void wm_apple_ios_launcher_show_documents(id sender)')
        self.assertNotIn('wm_apple_ios_launcher_show_documents(', back,
                         "Back saves and calls itself again on failure: an endless loop")
        self.assertIn('saveForPerson:YES', back, "Back's save must offer Close Without Saving")
        self.assertIn('Close Without Saving', self.document)

    def test_save_as_and_share_never_hand_out_the_old_file(self):
        now = body_of(self.document, 'void wm_apple_ios_document_file_now(')
        self.assertRegex(now, r'if \(success\) \{\s*finish\(documentURL\);',
                         "The document's file is handed on only after a successful save")
        self.assertIn('writeFreshCopy(name, presenter', now)
        save_as = body_of(self.document, 'void wm_apple_ios_document_save_as(')
        self.assertIn('wm_apple_ios_document_file_now(', save_as)
        top_bar = (APPLE / 'swift/TopBar.swift').read_text(encoding='utf-8')
        share = top_bar[top_bar.index('func shareDocument()'):top_bar.index('func saveAsTemplate()')]
        self.assertIn('wm_apple_ios_share_document_file(', share)
        self.assertNotIn('.save(to:', share)

    def test_the_header_says_not_saved(self):
        model = (APPLE / 'swift/ShellModel.swift').read_text(encoding='utf-8')
        self.assertIn('wm_apple_ios_document_status()', model)
        top_bar = (APPLE / 'swift/TopBar.swift').read_text(encoding='utf-8')
        self.assertIn('model.documentStatus', top_bar)
        self.assertIn('wm_apple_ios_document_status_tapped()', top_bar)


class OverwriteQuestionIsAskedTest(unittest.TestCase):
    """SAFE-2: Blender's overwrite question is asked."""

    @classmethod
    def setUpClass(cls):
        cls.document = BDOC.read_text(encoding='utf-8')
        cls.launcher = LAUNCH.read_text(encoding='utf-8')
        cls.doc = DOC.read_text(encoding='utf-8')

    def test_every_overwrite_condition_has_words(self):
        main = (ROOT / 'source/blender/blenkernel/intern/main.cc').read_text(encoding='utf-8')
        confirm = body_of(main, 'bool BKE_main_needs_overwrite_confirm(')
        flags = re.findall(r'bmain->([\w.]+)', confirm)
        self.assertGreaterEqual(len(flags), 3, "The sweep no longer reads Blender's conditions")
        hold = body_of(self.doc, 'static void document_hold(')
        missing = [flag for flag in flags if 'bmain->' + flag not in hold]
        self.assertEqual(missing, [], "Blender asks before overwriting for these, and the held "
                                      "document has no words for them")

    def test_a_recovered_document_asks_by_its_own_file(self):
        # Its auto-save was written by this Blender: the file's header decides.
        hold = body_of(self.doc, 'static void document_hold(')
        self.assertIn('blend_file_version(filepath)', hold)
        self.assertIn('if (r_opened.recovered)', hold)

    def test_nothing_writes_a_held_document(self):
        unsaved = body_of(self.document, '- (BOOL)hasUnsavedChanges')
        self.assertIn('self.held || self.readOnly', unsaved)
        along = body_of(self.document, '- (void)saveAlongTheWay')
        self.assertIn('self.held || self.readOnly', along)
        place = body_of(self.document, '- (BOOL)canWriteInPlace')
        self.assertIn('!self.held && !self.readOnly', place, "Save As and Share would write it")
        edited = body_of(self.document, '- (void)setBlenderModified:(BOOL)modified')
        self.assertLess(edited.index('[self presentHold:NO]'), edited.index('[self saveAlongTheWay]'))
        save = body_of(self.document, '- (void)saveNow')
        self.assertLess(save.index('[self presentHold:NO]'), save.index('saveForPerson:'))

    def test_closing_a_held_document_asks(self):
        back = body_of(self.launcher, 'void wm_apple_ios_launcher_show_documents(id sender)')
        self.assertLess(back.index('needsAnswerBeforeClosing'), back.index('saveForPerson:'))
        open_other = body_of(self.launcher, '- (void)openDocumentAtURL:(NSURL *)url')
        self.assertLess(open_other.index('needsAnswerBeforeClosing'),
                        open_other.index('closeWithCompletionHandler:'))

    def test_the_question_has_its_answers(self):
        for words in ('Save a Copy and Work on That', 'Save Here Anyway', 'Keep Read-Only'):
            self.assertIn('@"%s"' % words, self.document)
        ask = body_of(self.document, '- (void)presentHold:(BOOL)closing')
        self.assertIn('!_holdCopyOnly', ask, "An asset system file may only be saved as a copy")

    def test_a_failed_open_says_why(self):
        read = body_of(self.document, '- (BOOL)readFromURL:(NSURL *)url error:(NSError **)outError')
        self.assertNotIn('NSFileReadCorruptFileError', read, "Every cause called corrupt")
        self.assertIn('@"WMIOSDocumentOutcome" : @"open"', read)
        opened = body_of(self.document, '- (void)openWithCompletionHandler:')
        self.assertIn('wm_apple_ios_launcher_open_failed(self', opened)
        failed = body_of(self.launcher, '- (void)openFailed:(UIDocument *)document reason:(NSString *)reason')
        self.assertIn('_opening = NO;', failed, "The launcher refuses files for a minute")
        open_doc = body_of(self.doc, 'bool WM_apple_ios_document_open(')
        self.assertIn('r_opened.error', open_doc)


class UncleanEndIsSaidTest(unittest.TestCase):
    """SAFE-4: a launch after a bad end stays in the launcher, and the log says what happened."""

    @classmethod
    def setUpClass(cls):
        cls.launcher = LAUNCH.read_text(encoding='utf-8')

    def test_nothing_opens_by_itself_after_an_unclean_end(self):
        load = body_of(self.launcher, '- (void)viewDidLoad')
        marker = load.index('dictionaryForKey:launcher_marker_key')
        # Every way the launch opens a document (the system's pending file, the last document's
        # bookmark) comes after the marker is read, and is skipped while it says the last session
        # ended badly.
        for opener in ('dataForKey:launcher_open_document_key', '[self openDocumentAtURL:url]'):
            self.assertLess(marker, load.index(opener), opener)
        self.assertRegex(load, r'if \(_endedMarker\) \{[^}]*url = nil;', "An ended document reopens")
        ended = body_of(self.launcher, '- (void)presentEndedSession')
        for answer in ('Open Again', 'Open a Copy', 'Stay Here', 'Start Without Add-ons and Saved Preferences'):
            self.assertIn('@"%s"' % answer, ended)
        self.assertIn('_openingEnds >= 2', ended)

    def test_every_open_sets_the_marker(self):
        # One door: every way a document opens passes openDocumentAtURL:, which sets it.
        opening = body_of(self.launcher, '- (void)openDocumentAtURL:(NSURL *)url')
        self.assertIn('launcherMarkerSet(url, @"opening")', opening)
        others = re.findall(r'self\.document = (?!nil|document;)', self.launcher)
        self.assertEqual(others, [], "A document is set other than through openDocumentAtURL:")
        self.assertIn('launcherMarkerClear("in the background")',
                      body_of(self.launcher, '- (void)appDidEnterBackground:(NSNotification *)notification'))
        self.assertIn('launcherMarkerClear("closed")', body_of(self.launcher, '- (void)setDocument:(UIDocument *)document'))

    def test_the_log_survives_and_is_dated(self):
        native = (WM / 'intern/wm_native_ui.cc').read_text(encoding='utf-8')
        path = body_of(native, 'static void session_log_path(')
        self.assertIn('"Application Support"', path)
        self.assertIn('static constexpr double session_log_delay = 1.0;', native)
        self.assertNotIn('> 10.0', body_of(native, 'void WM_native_ui_session_log(const char *kind'))
        diagnostics = (APPLE / 'swift/SessionDiagnostics.swift').read_text(encoding='utf-8')
        for needed in ('MXMetricManager.shared.add', 'pastDiagnosticPayloads', 'yyyy-MM-dd',
                       'os_proc_available_memory', 'the last session ended cleanly'):
            self.assertIn(needed, diagnostics)
        cmake = (ROOT / 'source/creator/CMakeLists.txt').read_text(encoding='utf-8')
        self.assertIn('apple_ios/swift/SessionDiagnostics.swift', cmake)


if __name__ == '__main__':
    unittest.main()
