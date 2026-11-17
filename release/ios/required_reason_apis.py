# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""List the required reason API categories each binary of an iOS app uses, and check that the
privacy manifest covering each binary declares them (ROUND5 8D).

    python3 required_reason_apis.py <app> [--json]

Prints each category with the binaries that use it. Exits non-zero when a binary uses a category
that its manifest does not declare, or when a binary has no manifest. A binary is covered by the
`PrivacyInfo.xcprivacy` of the bundle holding it: its framework, its app extension, or the app.

The categories, the APIs in each and the reasons are Apple's, taken on 2026-11-17 from:
  https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
  https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype
  https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons
Apple updates the list from time to time: read the pages again before each submission.

C functions are found among a binary's undefined symbols (`nm -u`). Foundation constants and
classes are found the same way, by their exported symbol. Objective-C methods (`systemUptime`,
`fileModificationDate`, `activeInputModes`) are found by their selector's name in the binary.
"""

import argparse
import json
import plistlib
import struct
import subprocess
import sys
from pathlib import Path

# Category: (C functions, Foundation symbols, Objective-C selectors), from Apple's page.
CATEGORIES = {
    'NSPrivacyAccessedAPICategoryFileTimestamp': (
        ('getattrlist', 'getattrlistbulk', 'fgetattrlist', 'stat', 'fstat', 'fstatat', 'lstat',
         'getattrlistat'),
        ('NSFileCreationDate', 'NSFileModificationDate', 'NSURLContentModificationDateKey',
         'NSURLCreationDateKey'),
        ('fileModificationDate',),
    ),
    'NSPrivacyAccessedAPICategorySystemBootTime': (
        ('mach_absolute_time',),
        (),
        ('systemUptime',),
    ),
    'NSPrivacyAccessedAPICategoryDiskSpace': (
        ('statfs', 'statvfs', 'fstatfs', 'fstatvfs', 'getattrlist', 'fgetattrlist', 'getattrlistat'),
        ('NSURLVolumeAvailableCapacityKey', 'NSURLVolumeAvailableCapacityForImportantUsageKey',
         'NSURLVolumeAvailableCapacityForOpportunisticUsageKey', 'NSURLVolumeTotalCapacityKey',
         'NSFileSystemFreeSize', 'NSFileSystemSize'),
        (),
    ),
    'NSPrivacyAccessedAPICategoryActiveKeyboards': (
        (),
        (),
        ('activeInputModes',),
    ),
    'NSPrivacyAccessedAPICategoryUserDefaults': (
        (),
        ('OBJC_CLASS_$_NSUserDefaults',),
        (),
    ),
}

# The reasons Apple lists for each category, to check a manifest names only real ones.
REASONS = {
    'NSPrivacyAccessedAPICategoryFileTimestamp': {'DDA9.1', 'C617.1', '3B52.1', '0A2A.1'},
    'NSPrivacyAccessedAPICategorySystemBootTime': {'35F9.1', '8FFB.1', '3D61.1'},
    'NSPrivacyAccessedAPICategoryDiskSpace': {'85F4.1', 'E174.1', '7D9E.1', 'B728.1'},
    'NSPrivacyAccessedAPICategoryActiveKeyboards': {'3EC4.1', '54BD.1'},
    'NSPrivacyAccessedAPICategoryUserDefaults': {'CA92.1', '1C8F.1', 'C56D.1', 'AC6B.1'},
}

MANIFEST = 'PrivacyInfo.xcprivacy'


def is_macho(path):
    try:
        with path.open('rb') as stream:
            magic = stream.read(4)
    except OSError:
        return False
    return magic in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')


def undefined_symbols(binary):
    """The names \a binary imports, without the leading underscore and any `$INODE64`-style suffix."""
    output = subprocess.run(['xcrun', 'nm', '-u', '-j', str(binary)], capture_output=True, text=True)
    if output.returncode != 0:
        raise RuntimeError(f'nm failed on {binary}: {output.stderr.strip()}')
    names = set()
    for line in output.stdout.split('\n'):
        name = line.strip()
        if not name or name.endswith(':'):
            continue
        name = name[1:] if name.startswith('_') else name
        names.add(name.split('$INODE64')[0] if '$INODE64' in name else name)
    return names


def selectors(binary):
    """The Objective-C selector names in \a binary, from its `__objc_methname` section."""
    data = binary.read_bytes()
    names = set()
    for section in _sections(data, b'__objc_methname'):
        names.update(part.decode('utf-8', 'replace') for part in section.split(b'\0') if part)
    return names


def _sections(data, wanted):
    """The contents of the sections named \a wanted in a thin 64-bit Mach-O."""
    if data[:4] != b'\xcf\xfa\xed\xfe':
        return []
    ncmds = struct.unpack_from('<I', data, 16)[0]
    offset, found = 32, []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', data, offset)
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack_from('<I', data, offset + 64)[0]
            for i in range(nsects):
                base = offset + 72 + i * 80
                name = data[base:base + 16].rstrip(b'\0')
                if name == wanted:
                    sect_size = struct.unpack_from('<Q', data, base + 40)[0]
                    sect_offset = struct.unpack_from('<I', data, base + 48)[0]
                    found.append(data[sect_offset:sect_offset + sect_size])
        offset += size
    return found


def categories_used(binary):
    """{category: [the APIs of it \a binary uses]}."""
    imported = undefined_symbols(binary)
    methods = selectors(binary)
    used = {}
    for category, (functions, symbols, method_names) in CATEGORIES.items():
        apis = sorted({f for f in functions if f in imported} | {s for s in symbols if s in imported} |
                      {m for m in method_names if m in methods})
        if apis:
            used[category] = apis
    return used


def bundle_of(binary, app):
    """The bundle whose manifest covers \a binary: its framework or app extension, or the app."""
    for parent in binary.parents:
        if parent == app.parent:
            break
        if parent.suffix in ('.framework', '.appex') or parent == app:
            return parent
    return app


def declared(bundle):
    """{category: reasons} from \a bundle's manifest, or None without one."""
    path = bundle / MANIFEST
    if not path.is_file():
        return None
    manifest = plistlib.loads(path.read_bytes())
    return {entry.get('NSPrivacyAccessedAPIType'): list(entry.get('NSPrivacyAccessedAPITypeReasons', []))
            for entry in manifest.get('NSPrivacyAccessedAPITypes', [])}


def scan(app):
    """(usage, problems): usage is {category: {binary: [apis]}}."""
    app = app.resolve()
    usage, problems = {}, []
    binaries = sorted(path for path in app.rglob('*') if path.is_file() and not path.is_symlink() and is_macho(path))
    if not binaries:
        problems.append(f'no Mach-O binaries in {app}')
    for binary in binaries:
        used = categories_used(binary)
        if not used:
            continue
        bundle = bundle_of(binary, app)
        manifest = declared(bundle)
        relative = str(binary.relative_to(app))
        for category, apis in used.items():
            usage.setdefault(category, {})[relative] = apis
            if manifest is None:
                problems.append(f'{relative} uses {category} ({", ".join(apis)}), and '
                                f'{bundle.relative_to(app.parent)} has no {MANIFEST}')
            elif not manifest.get(category):
                problems.append(f'{relative} uses {category} ({", ".join(apis)}), which '
                                f'{bundle.relative_to(app.parent)}/{MANIFEST} does not declare')
    for bundle in sorted({app} | {p for p in app.rglob('*') if p.suffix in ('.framework', '.appex')}):
        manifest = declared(bundle)
        for category, reasons in (manifest or {}).items():
            if category not in REASONS:
                problems.append(f'{bundle.name}/{MANIFEST}: unknown category {category}')
            elif not reasons or set(reasons) - REASONS[category]:
                problems.append(f'{bundle.name}/{MANIFEST}: {category} needs reasons from {sorted(REASONS[category])}, '
                                f'has {reasons}')
    return usage, problems


def manifest_for(categories, reasons):
    """A privacy manifest declaring \a categories, each with its reasons from \a reasons."""
    return {
        'NSPrivacyTracking': False,
        'NSPrivacyTrackingDomains': [],
        'NSPrivacyCollectedDataTypes': [],
        'NSPrivacyAccessedAPITypes': [
            {'NSPrivacyAccessedAPIType': category, 'NSPrivacyAccessedAPITypeReasons': list(reasons[category])}
            for category in sorted(categories)
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('app', type=Path)
    parser.add_argument('--json', action='store_true', help='Print the usage as JSON')
    args = parser.parse_args()
    usage, problems = scan(args.app)
    if args.json:
        print(json.dumps({'usage': usage, 'problems': problems}, indent=1))
    else:
        for category in sorted(usage):
            print(category)
            for binary, apis in sorted(usage[category].items()):
                print(f'  {binary}: {", ".join(apis)}')
        for problem in problems:
            print('ERROR: ' + problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
