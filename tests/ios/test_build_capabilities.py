# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""What this build cannot do is not offered (ROUND6 FILES-6, findings F11 and G11, decision R6-13).

One table, `wm_operator_unavailable` in `wm_event_system.cc`, by build option and platform: an
operator there fails its poll with the reason, so it is greyed and says why everywhere it shows.

- Every operator whose `exec` has a branch for a build without Audaspace (it reports "Compiled
  without sound support", or returns without work) is in the table under `#ifndef
  WITH_AUDASPACE`, which the iPad build has.
- The iPad's GHOST has no image clipboard, so Image › Copy is in the table for the iPad.
- Every audio control Blender's own interface draws (`scripts/startup/bl_ui`) is behind
  `bpy.app.build_options.audaspace`.

Read from the sources, so it runs on any Mac without a build.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EVENTS = ROOT / 'source/blender/windowmanager/intern/wm_event_system.cc'
CACHE = ROOT.parent / 'build_ios_device/CMakeCache.txt'

# Blender's audio properties as its interface draws them.
AUDIO_PROPERTIES = {
    'use_audio', 'use_audio_scrub', 'audio_volume', 'audio_distance_model', 'audio_doppler_speed',
    'audio_doppler_factor', 'audio_codec', 'audio_channels', 'audio_mixrate', 'audio_bitrate',
    'audio_device', 'audio_mixing_buffer', 'audio_sample_rate', 'audio_sample_format',
}
# Panels drawing a sound's own settings by other names ("volume", "pitch", "sound").
AUDIO_PANELS = {'STRIP_PT_adjust_sound', 'STRIP_PT_scene_sound', 'DATA_PT_speaker',
                'DATA_PT_distance', 'DATA_PT_cone'}


def table(source, condition):
    """The operators listed under `#if...` \a condition in the table."""
    body = source[source.index('static const char *wm_operator_unavailable'):]
    body = body[:body.index('\n}\n')]
    found = set()
    active = False
    for line in body.splitlines():
        stripped = line.strip()
        if stripped.startswith('#if'):
            active = condition in stripped
        elif stripped.startswith('#endif'):
            active = False
        elif active:
            found.update(re.findall(r'\{"(\w+_OT_\w+)"', stripped))
    return found


def exec_without(option):
    """Operators whose `exec` has a branch for a build without \a option."""
    found = set()
    for path in (ROOT / 'source/blender/editors').rglob('*.cc'):
        text = path.read_text(errors='replace')
        if option not in text:
            continue
        execs = set()
        # A second definition of an exec in the `#else` of the option.
        for match in re.finditer(r'#else\s*/\*\s*%s\s*\*/(.*?)#endif' % option, text, re.S):
            execs.update(re.findall(r'static wmOperatorStatus (\w+_exec)\(', match.group(1)))
        # An exec whose body has its own `#else` returning without work.
        for match in re.finditer(r'static wmOperatorStatus (\w+_exec)\([^)]*\)\n\{(.*?)\n\}\n', text, re.S):
            if re.search(r'#ifdef %s.*?#else' % option, match.group(2), re.S):
                execs.add(match.group(1))
        for definition in re.finditer(r'void (\w+_OT_\w+)\(wmOperatorType \*ot\)\n\{(.*?)\n\}\n', text, re.S):
            body = definition.group(2)
            exec_name = re.search(r'ot->exec = (\w+);', body)
            idname = re.search(r'ot->idname = "(\w+)";', body)
            if exec_name and idname and exec_name.group(1) in execs:
                found.add(idname.group(1))
    return found


class BuildCapabilitiesTest(unittest.TestCase):
    def setUp(self):
        self.events = EVENTS.read_text()

    def test_ipad_build_is_without_sound(self):
        if not CACHE.exists():
            self.skipTest('no iPad build here')
        cache = CACHE.read_text()
        self.assertIn('WITH_AUDASPACE:BOOL=OFF', cache)

    def test_operators_without_sound_are_not_offered(self):
        found = exec_without('WITH_AUDASPACE')
        self.assertGreaterEqual(found, {'SOUND_OT_open', 'SOUND_OT_mixdown', 'GRAPH_OT_sound_to_samples'})
        listed = table(self.events, 'WITH_AUDASPACE')
        self.assertFalse(found - listed, 'operators that do nothing without sound, not in the table: %s'
                         % sorted(found - listed))

    def test_image_clipboard(self):
        ghost = (ROOT / 'intern/ghost/intern/GHOST_SystemIOS.hh').read_text()
        if 'putClipboardImage' not in ghost:
            self.assertIn('IMAGE_OT_clipboard_copy', table(self.events, 'APPLE_TARGET_IOS'))

    def test_poll_reads_the_table(self):
        poll = self.events[self.events.index('bool WM_operator_poll(bContext *C, wmOperatorType *ot)'):]
        poll = poll[:poll.index('\n}\n')]
        self.assertLess(poll.index('wm_operator_unavailable(ot)'), poll.index('ot->pyop_poll'))
        self.assertIn('CTX_wm_operator_poll_msg_set', poll)

    def test_audio_controls_are_behind_the_build_option(self):
        ungated = []
        for path in sorted((ROOT / 'scripts/startup/bl_ui').glob('*.py')):
            if path.name.startswith('native_'):
                continue
            text = path.read_text()
            classes = re.split(r'\n(?=class )', text)
            for chunk in classes:
                name = re.match(r'class (\w+)', chunk)
                if not name:
                    continue
                draws_audio = any(re.search(r'\.prop\([^)]*"%s"' % prop, chunk) for prop in AUDIO_PROPERTIES)
                if (draws_audio or name.group(1) in AUDIO_PANELS) and 'build_options.audaspace' not in chunk:
                    ungated.append('%s:%s' % (path.name, name.group(1)))
        # The speaker panels share their poll through `DataButtonsPanel`.
        speaker = (ROOT / 'scripts/startup/bl_ui/properties_data_speaker.py').read_text()
        if 'build_options.audaspace' in speaker[:speaker.index('class DATA_PT_context_speaker')]:
            ungated = [entry for entry in ungated if not entry.startswith('properties_data_speaker.py')]
        self.assertFalse(ungated, 'audio controls drawn whether or not the build has sound: %s' % ungated)


if __name__ == '__main__':
    unittest.main()
