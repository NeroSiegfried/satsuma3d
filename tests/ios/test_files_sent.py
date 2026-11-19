# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Other kinds of file reach the app (ROUND6 FILES-8, finding F14).

- Every extension a 3D View file handler of this build imports is a type `Info.plist` declares
  (system types by their identifier, the others by an imported declaration), as Viewer with an
  Alternate rank, so Files, the share sheet and AirDrop offer the app for it. Extensions left out
  are listed with why.
- A file sent to the app that is not a `.blend` is imported into the open document as a drop
  would be, or waits for the next one; a drop or a sent file nothing can open is said.

Read from the sources, so it runs on any Mac without a build.
"""

import plistlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLIST = ROOT / 'release/ios/Blender.app/Info.plist'
CACHE = ROOT.parent / 'build_ios_device/CMakeCache.txt'

# Types the system declares, by the extension a handler names.
SYSTEM_TYPES = {
    '.obj': 'public.geometry-definition-format',
    '.stl': 'public.standard-tesselated-geometry-format',
    '.ply': 'public.polygon-file-format',
    '.svg': 'public.svg-image',
}
# Handlers the iPad does not take files for, and why.
NOT_SENT = {
    'IO_FH_usd': 'USD is off in the iPad build',
    'SEQUENCER_FH_image_strip': 'the Video Sequencer\'s own drops; a sent image goes to the 3D View',
    'SEQUENCER_FH_movie_strip': 'the Video Sequencer\'s own drops',
    'SEQUENCER_FH_sound_strip': 'sound is off in the iPad build',
}


def handlers():
    """(name, [extensions]) of every file handler in the sources."""
    found = []
    for path in (ROOT / 'source/blender/editors/io').glob('*.cc'):
        text = path.read_text(errors='replace')
        for match in re.finditer(r'STRNCPY(?:_UTF8)?\(fh->idname, "(\w+)"\);(.*?)file_extensions_str, "([^"]+)"',
                                 text, re.S):
            found.append((match.group(1), match.group(3).split(';')))
    for path in list((ROOT / 'scripts/addons_core').rglob('*.py')) + list((ROOT / 'scripts/startup').rglob('*.py')):
        text = path.read_text(errors='replace')
        for match in re.finditer(r'bl_idname = "(\w+_FH_\w+)"(.*?)bl_file_extensions = ([^\n]+)', text, re.S):
            value = match.group(3)
            if value.startswith('"') and '.join' not in value:
                found.append((match.group(1), value.strip('"').split(';')))
            else:
                # Built from Blender's image (and movie) extension lists: public.image covers them;
                # movies are not offered (no sound, and every video would list the app).
                found.append((match.group(1), ['<images>']))
    return found


class FilesSentTest(unittest.TestCase):
    def setUp(self):
        self.plist = plistlib.loads(PLIST.read_bytes())

    def test_importable_types_are_declared(self):
        types = self.plist['CFBundleDocumentTypes']
        imported = [entry for entry in types if entry.get('LSHandlerRank') == 'Alternate']
        self.assertEqual(len(imported), 1)
        self.assertEqual(imported[0]['CFBundleTypeRole'], 'Viewer')
        declared = set(imported[0]['LSItemContentTypes'])
        tags = {}
        for declaration in self.plist['UTImportedTypeDeclarations']:
            for extension in declaration['UTTypeTagSpecification']['public.filename-extension']:
                tags['.' + extension] = declaration['UTTypeIdentifier']
        found = handlers()
        self.assertGreaterEqual(len(found), 8, found)
        missing = []
        for name, extensions in found:
            if name in NOT_SENT:
                continue
            for extension in extensions:
                if extension == '<images>':
                    if 'public.image' not in declared:
                        missing.append((name, 'images'))
                    continue
                identifier = SYSTEM_TYPES.get(extension) or tags.get(extension)
                if identifier not in declared:
                    missing.append((name, extension))
        self.assertFalse(missing, 'file handlers whose files the app is not offered for: %s' % missing)
        if CACHE.exists():
            self.assertIn('WITH_USD:BOOL=OFF', CACHE.read_text())

    def test_sent_and_dropped_files_are_imported_or_said(self):
        launcher = (ROOT / 'source/blender/windowmanager/apple_ios/wm_apple_ios_launcher.mm').read_text()
        opening = launcher[launcher.index('- (void)openDocumentAtURL:(NSURL *)url\n{'):]
        self.assertLess(opening.index('[self importURL:url]'), opening.index('_opening = YES'))
        importing = launcher[launcher.index('- (void)importURL:(NSURL *)url\n{'):]
        importing = importing[:importing.index('\n}\n')]
        for call in ('WM_apple_ios_import_file', 'WM_apple_ios_import_pending_add', 'coordinateReadingItemAtURL'):
            self.assertIn(call, importing)
        document = (ROOT / 'source/blender/windowmanager/apple_ios/wm_apple_ios_blend_document.mm').read_text()
        self.assertIn('WM_apple_ios_import_pending_run(C)', document)
        files = (ROOT / 'source/blender/windowmanager/intern/wm_apple_ios_file.cc').read_text()
        importer = files[files.index('bool WM_apple_ios_import_file('):]
        importer = importer[:importer.index('\n}\n')]
        self.assertIn('file_handlers_poll_file_drop', importer)
        self.assertIn('cannot open this kind of file', importer)
        events = (ROOT / 'source/blender/windowmanager/intern/wm_event_system.cc').read_text()
        self.assertIn('native->drop_unhandled(C, first.c_str(), count)', events)
        native = (ROOT / 'source/blender/windowmanager/intern/wm_apple_ios_native.cc').read_text()
        self.assertIn('native.drop_unhandled = drop_unhandled;', native)
        self.assertIn('cannot open this kind of file', native)


if __name__ == '__main__':
    unittest.main()
