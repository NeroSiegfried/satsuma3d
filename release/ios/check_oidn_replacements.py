# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Check rebuilt OpenImageDenoise libraries against the prebuilt ones they replace (ROUND5 8K).

    python3 check_oidn_replacements.py <prebuilt-lib-dir> <replacement-dir>

<prebuilt-lib-dir> is `lib/ios_arm64/openimagedenoise/lib`; <replacement-dir> is
`build_oidn_ios.sh`'s output. For every real (not symbolic link) prebuilt library there must be
exactly one replacement of the same name, and each must:

- be an MH_DYLIB, arm64 only, built for iOS (`platform IOS`) with the prebuilt one's `minos`;
- have the prebuilt one's install name, depend on the same libraries and export the same symbols;
- carry no run path of the machine that built it, and no home folder path in its contents.

The core library must also hold its framework lookup (`oidn_ios_frameworks.diff`, the text
`prepare_testflight.MODULE_LOADERS` looks for), and each device module must be packaged under the
framework name that lookup asks for: `OpenImageDenoise_` + the module's name (from its exported
`oidn_init_module_<name>_v<version>`), which must be what `prepare_testflight.framework_name` gives
the module's file. No replacement may be left over. Prints a table and exits non-zero on any failure.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

from prepare_testflight import MODULE_LOADERS, framework_name

MH_DYLIB = 6
CORE = 'OpenImageDenoise_core'
# The core's lookup: `OIDN_LIBRARY_NAME "_" + name + SHARED_POSTFIX`, the postfix empty in Release.
LIBRARY_PREFIX = 'OpenImageDenoise_'


def run(*args):
    return subprocess.check_output(args, text=True)


def macho_type(path):
    header = path.read_bytes()[:16]
    return int.from_bytes(header[12:16], 'little') if header[:4] == b'\xcf\xfa\xed\xfe' else None


def exports(path):
    return sorted(line.split()[-1] for line in run('xcrun', 'nm', '-gU', str(path)).splitlines() if line.split())


def install_name(path):
    lines = run('xcrun', 'otool', '-D', str(path)).splitlines()[1:]
    return lines[0].strip() if lines else None


def dependencies(path):
    own = install_name(path)
    return [line.strip().split(' (compatibility version', 1)[0]
            for line in run('xcrun', 'otool', '-L', str(path)).splitlines()[1:]
            if line.strip().split(' (compatibility version', 1)[0] != own]


def run_paths(path):
    lines = run('xcrun', 'otool', '-l', str(path)).splitlines()
    return [lines[i + 2].split()[1] for i, line in enumerate(lines)
            if line.strip() == 'cmd LC_RPATH' and i + 2 < len(lines)]


def minimum_os(path):
    build = run('xcrun', 'vtool', '-show-build', str(path))
    platform = re.search(r'platform (\S+)', build)
    minimum = re.search(r'minos (\S+)', build)
    return (platform.group(1) if platform else None), (minimum.group(1) if minimum else None)


def module_names(path):
    """The device module names \a path initialises (`oidn_init_module_<name>_v<version>`)."""
    return [match.group(1) for symbol in exports(path)
            for match in [re.match(r'_oidn_init_module_(.+)_v\d+$', symbol)] if match]


def problems_of(prebuilt, replacement):
    """The ways \a replacement fails to stand in for \a prebuilt; empty when it does."""
    problems = []
    if macho_type(replacement) != MH_DYLIB:
        problems.append('not MH_DYLIB')
    if run('xcrun', 'lipo', '-archs', str(replacement)).strip() != 'arm64':
        problems.append('not arm64 only')
    platform, minimum = minimum_os(replacement)
    if platform != 'IOS':
        problems.append(f'platform {platform}, expected IOS')
    if minimum != minimum_os(prebuilt)[1]:
        problems.append(f'minos {minimum}, the prebuilt library {minimum_os(prebuilt)[1]}')
    if install_name(replacement) != install_name(prebuilt):
        problems.append(f'install name {install_name(replacement)}, the prebuilt library {install_name(prebuilt)}')
    if dependencies(replacement) != dependencies(prebuilt):
        problems.append(f'depends on {dependencies(replacement)}, the prebuilt library on {dependencies(prebuilt)}')
    if exports(replacement) != exports(prebuilt):
        missing = sorted(set(exports(prebuilt)) - set(exports(replacement)))
        extra = sorted(set(exports(replacement)) - set(exports(prebuilt)))
        problems.append(f'exports differ: {len(missing)} missing {missing[:3]}, {len(extra)} extra {extra[:3]}')
    absolute = [path for path in run_paths(replacement) if not path.startswith('@')]
    if absolute:
        problems.append(f'run paths of the building machine: {absolute}')
    if b'/Users/' in replacement.read_bytes():
        problems.append('holds a home folder path')
    name = replacement.name
    if name.startswith('lib' + CORE + '.'):
        loader, framework_lookup, patch = MODULE_LOADERS[CORE]
        data = replacement.read_bytes()
        if loader not in data or framework_lookup not in data:
            problems.append(f'no framework lookup: build it with {patch}')
        if (LIBRARY_PREFIX.encode() + b'\0') not in data:
            problems.append(f'the module file name no longer starts {LIBRARY_PREFIX!r}')
    for module in module_names(replacement):
        wanted = LIBRARY_PREFIX + module
        given = framework_name(replacement, replacement.parent)
        if given != wanted:
            problems.append(f'the core looks for {wanted}.framework, packaging names it {given}.framework')
    return problems


def check(prebuilt_dir, replacement_dir):
    """[(library, problems)] for every prebuilt library, plus leftovers."""
    prebuilt_dir, replacement_dir = Path(prebuilt_dir), Path(replacement_dir)
    results = []
    expected = set()
    for prebuilt in sorted(prebuilt_dir.glob('*.dylib')):
        if prebuilt.is_symlink():
            continue
        expected.add(prebuilt.name)
        replacement = replacement_dir / prebuilt.name
        if not replacement.is_file() or replacement.is_symlink():
            results.append((prebuilt.name, ['no replacement at ' + str(replacement)]))
        else:
            results.append((prebuilt.name, problems_of(prebuilt, replacement)))
    for replacement in sorted(replacement_dir.rglob('*')):
        if replacement.is_file() and replacement.name not in expected:
            results.append((str(replacement.relative_to(replacement_dir)), ['replaces no prebuilt library']))
    if not any(name.startswith('lib' + CORE + '.') for name in expected):
        results.append((str(prebuilt_dir), [f'no {CORE} among the prebuilt libraries']))
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('prebuilt', type=Path)
    parser.add_argument('replacements', type=Path)
    args = parser.parse_args()
    results = check(args.prebuilt, args.replacements)
    for library, problems in results:
        print(f'{"FAIL" if problems else "ok  "} {library}' + (': ' + '; '.join(problems) if problems else ''))
    failing = sum(1 for _, problems in results if problems)
    print(f'{len(results)} libraries, {failing} failing')
    return 1 if failing else 0


if __name__ == '__main__':
    sys.exit(main())
