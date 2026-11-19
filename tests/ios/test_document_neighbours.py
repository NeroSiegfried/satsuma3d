# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""The files beside a document (ROUND6 FILES-3, finding F8).

A document's access covers its one file. What it reads beside itself is found as it opens, said
once with Give Access to the Folder, and read again once the folder is given. The class is every
data-block type whose `IDTypeInfo::foreach_path` lists a path: each must be in the table of
`wm_apple_ios_document.cc` ("NEIGHBOURS <type>: ..."), counted and read again, or not counted with
why. A type that gains `foreach_path` upstream fails here until it is placed.

Read from the sources, so it runs on any Mac without a build.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOC = ROOT / 'source/blender/windowmanager/intern/wm_apple_ios_document.cc'
BDOC = ROOT / 'source/blender/windowmanager/apple_ios/wm_apple_ios_blend_document.mm'
PICKER = ROOT / 'intern/ghost/intern/GHOST_IOSDocumentPicker.mm'

# Each type's ID code, and where `WM_apple_ios_document_neighbours_reload` reads it again.
TYPES = {
    'image': ('ID_IM', 'bmain->images'),
    'library': ('ID_LI', 'bmain->libraries'),
    'movieclip': ('ID_MC', 'bmain->movieclips'),
    'cachefile': ('ID_CF', 'bmain->cachefiles'),
    'volume': ('ID_VO', 'bmain->volumes'),
    'vfont': ('ID_VF', 'bmain->fonts'),
    'scene': ('ID_SCE', 'bmain->scenes'),
    'sound': ('ID_SO', None),
    'camera': ('ID_CA', None),
    'mesh': ('ID_ME', None),
    'node': ('ID_NT', None),
    'object': ('ID_OB', None),
    'text': ('ID_TXT', None),
}


def foreach_path_types():
    """The `IDTypeInfo`s with a `foreach_path`, by their file's name."""
    found = set()
    for path in (ROOT / 'source/blender/blenkernel/intern').glob('*.cc'):
        text = path.read_text(errors='replace')
        match = re.search(r'/\*foreach_path\*/\s*([\w:]+)', text)
        if match and match.group(1) != 'nullptr':
            found.add(path.stem)
    return found


class NeighboursTest(unittest.TestCase):
    def setUp(self):
        self.doc = DOC.read_text()
        self.table = dict(re.findall(r'NEIGHBOURS (\w+): ([^\n]*)', self.doc))

    def test_every_type_with_paths_is_placed(self):
        types = foreach_path_types()
        self.assertGreaterEqual(len(types), 12, types)
        unplaced = sorted(types - set(self.table))
        self.assertFalse(unplaced, 'data-block types with paths not in the NEIGHBOURS table: '
                         '%s' % unplaced)
        stale = sorted(set(self.table) - types)
        self.assertFalse(stale, 'the table names types without paths: %s' % stale)

    def test_counted_types_are_read_again(self):
        scan = self.doc[self.doc.index('static bool neighbour_type_read'):]
        scan = scan[:scan.index('\n}\n')]
        reload = self.doc[self.doc.index('WM_apple_ios_document_neighbours_reload('):]
        reload = reload[:reload.index('\n}\n')]
        for name, how in self.table.items():
            code, store = TYPES[name]
            counted = how.startswith('counted')
            self.assertEqual(code in scan, counted,
                             '%s: the scan and the table disagree (%s)' % (name, how))
            if counted:
                self.assertIsNotNone(store, name)
                self.assertIn(store, reload, '%s is counted but not read again' % name)
            else:
                self.assertRegex(how, r'^not counted: \w', '%s: say why it is not counted' % name)

    def test_open_says_it_and_the_grant_reads_again(self):
        bdoc = BDOC.read_text()
        self.assertIn('r_opened.unreadable = WM_apple_ios_document_unreadable(', self.doc)
        self.assertIn('[self presentNeighbours]', bdoc)
        self.assertIn('@"Give Access to the Folder"', bdoc)
        # The given folder is bookmarked as the picker's own picks are, and kept for later opens.
        self.assertIn('GHOST_ios_document_access_remember_url(url)', bdoc)
        self.assertIn('void GHOST_ios_document_access_remember_url', PICKER.read_text())
        # iCloud placeholders are asked for and read under coordination, then all read again.
        read = bdoc[bdoc.index('- (void)readNeighbours'):]
        read = read[:read.index('\n}\n')]
        for call in ('startDownloadingUbiquitousItemAtURL', 'coordinateReadingItemAtURL',
                     'WM_apple_ios_document_neighbours_reload'):
            self.assertIn(call, read)
        # A folder given before is not asked for again.
        present = bdoc[bdoc.index('- (void)presentNeighbours'):]
        self.assertLess(present.index('GHOST_ios_document_can_write_path'),
                        present.index('alertControllerWithTitle'))

    def test_what_is_left_is_said(self):
        reload = self.doc[self.doc.index('WM_apple_ios_document_neighbours_reload('):]
        reload = reload[:reload.index('\n}\n')]
        self.assertIn('still cannot be read', reload)
        self.assertIn('read now', reload)


if __name__ == '__main__':
    unittest.main()
