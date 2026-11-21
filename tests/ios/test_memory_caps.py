# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""The iPad's start-up memory preferences (ROUND6 BUSY-5, G10): `memory_caps` and
`memory_caps_apply` in `wm_apple_ios_memory.hh`, built alone for the Mac with clang and run over
each iPad memory tier, from Blender's own defaults (undo memory unlimited, the cache's 4 GB, no
texture limit) and from a person's lower and higher values. That the iPad applies them as its
preferences load, before the caches take their limits, is checked by `script_native_shell_sources`."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / 'source/blender/windowmanager/intern/wm_apple_ios_memory.hh'
GB = 1024 ** 3

# (tier, what iOS lets the app use at launch, device memory) → (undo MB, cache MB, texture limit)
TIERS = (
    ('6 GB', int(2.9 * GB), int(5.6 * GB), (742, 371, 4096)),
    ('8 GB', int(5.6 * GB), int(7.5 * GB), (1433, 716, 4096)),
    ('12 GB', int(8.9 * GB), int(11.6 * GB), (2278, 1139, 0)),
    ('16 GB', int(12.2 * GB), int(15.6 * GB), (3123, 1561, 0)),
    ('unknown available, 8 GB', 0, 8 * GB, (1024, 512, 4096)),
    # The device round's iPad (iPad13,10, swap on): more left of the app's limit than the RAM
    # holds; the caps count only the RAM (7520 MB → a quarter 1880, an eighth 940).
    ('8 GB with swap', 8158 * 1024 ** 2, 7520 * 1024 ** 2, (1880, 940, 4096)),
)
# Blender's defaults: undo memory 0 (unlimited), cache 4096 MB (half the memory at most), textures 0.
BLENDER_DEFAULTS = (0, 4096, 0)

DRIVER = '''
#include "%s"
#include <cstdio>
using namespace blender::wm::apple_ios;
int main()
{
  int failures = 0;
  struct Row { const char *tier; unsigned long long available, physical; int undo, cache, texture; };
  const Row rows[] = {%s};
  for (const Row &row : rows) {
    const MemoryCaps caps = memory_caps(row.available, row.physical);
    /* From Blender's defaults: the iPad's values. */
    int undo = %d, cache = %d, texture = %d;
    memory_caps_apply(caps, undo, cache, texture);
    if (undo != row.undo || cache != row.cache || texture != row.texture) {
      printf("%%s: got %%d %%d %%d\\n", row.tier, undo, cache, texture);
      failures++;
    }
    /* A person's lower values are kept. */
    int lower_undo = 128, lower_cache = 64, lower_texture = 1024;
    memory_caps_apply(caps, lower_undo, lower_cache, lower_texture);
    if (lower_undo != 128 || lower_cache != 64 || lower_texture != 1024) {
      printf("%%s: a lower value was changed\\n", row.tier);
      failures++;
    }
    /* Higher ones are brought down. */
    int high_undo = 100000, high_cache = 100000, high_texture = 8192;
    memory_caps_apply(caps, high_undo, high_cache, high_texture);
    if (high_undo != row.undo || high_cache != row.cache || high_texture != (row.texture ? row.texture : 8192)) {
      printf("%%s: a higher value was kept\\n", row.tier);
      failures++;
    }
  }
  printf("checked %%d tiers\\n", int(sizeof(rows) / sizeof(rows[0])));
  return failures == 0 ? 0 : 1;
}
'''


class MemoryCapsTest(unittest.TestCase):
    def test_tiers(self):
        if shutil.which('xcrun') is None:
            self.skipTest('needs Xcode to build C++')
        rows = ', '.join('{"%s", %dull, %dull, %d, %d, %d}' % (tier, available, physical, *expected)
                         for tier, available, physical, expected in TIERS)
        with tempfile.TemporaryDirectory() as directory:
            driver = Path(directory) / 'main.cc'
            driver.write_text(DRIVER % (HEADER, rows, *BLENDER_DEFAULTS))
            binary = Path(directory) / 'memory_caps'
            subprocess.run(['xcrun', 'clang++', '-std=c++17', str(driver), '-o', str(binary)], check=True,
                           capture_output=True)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('checked %d tiers' % len(TIERS), result.stdout)


if __name__ == '__main__':
    unittest.main()
