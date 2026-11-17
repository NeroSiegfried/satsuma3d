# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Check relinked Python extension modules against the bundled ones they replace (ROUND5 8F.1).

    python3 check_numpy_replacements.py <bundled-numpy-dir> <replacement-dir> [--minimum-os 26.0]

<bundled-numpy-dir> is the bundled package (`lib/ios_arm64/.../site-packages/numpy`, or the same
folder inside an installed app); <replacement-dir> is `build_numpy_ios.sh`'s output, holding
`numpy/**/*.so`. For every bundled module there must be exactly one replacement, and each must:

- have the name the app installs (`.cpython-313-arm64-iphoneos.so`; the libraries' `-darwin.so`
  is renamed at install, see `source/creator/CMakeLists.txt`), at the same path in the package;
- be an MH_DYLIB (not MH_BUNDLE), arm64 only, built for iOS (`platform IOS`) with `minos` equal to
  --minimum-os;
- export the same `PyInit_` symbol as the module it replaces;
- depend on the same libraries (its own install name aside).

No replacement may be left over. Prints a table and exits non-zero on any failure.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

MH_DYLIB = 6


def run(*args):
    return subprocess.check_output(args, text=True)


def installed_name(name):
    """The file name the app installs a bundled module under."""
    return re.sub(r'-darwin\.so$', '-arm64-iphoneos.so', name)


def macho_type(path):
    header = path.read_bytes()[:16]
    return int.from_bytes(header[12:16], 'little') if header[:4] == b'\xcf\xfa\xed\xfe' else None


def pyinit(path):
    return sorted(line.split()[-1] for line in run('xcrun', 'nm', '-gU', str(path)).splitlines()
                  if line.split() and line.split()[-1].startswith('_PyInit_'))


def install_name(path):
    lines = run('xcrun', 'otool', '-D', str(path)).splitlines()[1:]
    return lines[0].strip() if lines else None


def dependencies(path):
    own = install_name(path)
    return [line.strip().split(' (compatibility version', 1)[0]
            for line in run('xcrun', 'otool', '-L', str(path)).splitlines()[1:]
            if line.strip().split(' (compatibility version', 1)[0] != own]


def problems_of(bundled, replacement, minimum_os):
    """The ways \a replacement fails to stand in for \a bundled; empty when it does."""
    problems = []
    if macho_type(replacement) != MH_DYLIB:
        problems.append('not MH_DYLIB')
    if run('xcrun', 'lipo', '-archs', str(replacement)).strip() != 'arm64':
        problems.append('not arm64 only')
    build = run('xcrun', 'vtool', '-show-build', str(replacement))
    if not re.search(r'platform IOS\b', build):
        problems.append('platform not IOS')
    minimum = re.search(r'minos (\S+)', build)
    if not minimum or minimum.group(1) != minimum_os:
        problems.append(f'minos {minimum.group(1) if minimum else "missing"}, expected {minimum_os}')
    if not pyinit(replacement) or pyinit(replacement) != pyinit(bundled):
        problems.append(f'exports {pyinit(replacement)}, the bundled module {pyinit(bundled)}')
    if dependencies(replacement) != dependencies(bundled):
        problems.append(f'depends on {dependencies(replacement)}, the bundled module on {dependencies(bundled)}')
    return problems


def check(bundled_dir, replacement_dir, minimum_os):
    """[(module, problems)] for every bundled module, plus leftovers; prints a table."""
    bundled_dir, replacement_dir = Path(bundled_dir), Path(replacement_dir)
    package = bundled_dir.name
    results = []
    expected = set()
    for bundled in sorted(bundled_dir.rglob('*.so')):
        relative = bundled.relative_to(bundled_dir).with_name(installed_name(bundled.name))
        expected.add(relative)
        replacement = replacement_dir / package / relative
        if not replacement.is_file():
            results.append((str(relative), ['no replacement at ' + str(replacement)]))
        else:
            results.append((str(relative), problems_of(bundled, replacement, minimum_os)))
    for replacement in sorted((replacement_dir / package).rglob('*.so')):
        relative = replacement.relative_to(replacement_dir / package)
        if relative not in expected:
            results.append((str(relative), ['replaces no bundled module']))
    if not results:
        results.append((str(bundled_dir), ['no bundled modules found']))
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('bundled', type=Path)
    parser.add_argument('replacements', type=Path)
    parser.add_argument('--minimum-os', default='26.0')
    args = parser.parse_args()
    results = check(args.bundled, args.replacements, args.minimum_os)
    for module, problems in results:
        print(f'{"FAIL" if problems else "ok  "} {module}' + (': ' + '; '.join(problems) if problems else ''))
    failing = sum(1 for _, problems in results if problems)
    print(f'{len(results)} modules, {failing} failing')
    return 1 if failing else 0


if __name__ == '__main__':
    sys.exit(main())
