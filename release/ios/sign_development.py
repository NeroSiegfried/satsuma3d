# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Sign a device build for development and, optionally, install it on a connected iPad.

For development only: every Mach-O in the app is signed where it is, frameworks and app
extensions as bundles, inner code first. It signs either layout: the installed app as it is
(loose libraries; desktop-style Python extension bundles load as they are), or one
`prepare_testflight.py` has packaged as frameworks, to run the App Store layout on a device with a
development profile (ROUND5 8F.3). Uses the app's free-team entitlements by default, which the
profile must grant; pass `--entitlements entitlements.plist` with a paid team.

    python3 sign_development.py /path/to/Blender.app /path/to/Signed.app \
        --profile profile.mobileprovision --identity "Apple Development: ..." [--install UDID]
"""

import argparse
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

from archive_testflight import signing_entitlements

FREE_ENTITLEMENTS = Path(__file__).resolve().parent / 'entitlements_free.plist'
MACHO_MAGIC = (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe')


def is_macho(path):
    if not path.is_file() or path.is_symlink():
        return False
    with path.open('rb') as stream:
        return stream.read(4) in MACHO_MAGIC


def sign(app, output, profile, identity, entitlements_path=FREE_ENTITLEMENTS, without_plugins=False):
    app, output = app.resolve(), output.resolve()
    if output.exists():
        shutil.rmtree(output)
    shutil.copytree(app, output, symlinks=True)
    if without_plugins:
        # Each extension needs a profile of its own identifier; leave them out of a quick install.
        shutil.rmtree(output / 'PlugIns', ignore_errors=True)
    info = plistlib.loads((output / 'Info.plist').read_bytes())
    provisioning = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(profile)]))
    team = provisioning['TeamIdentifier'][0]
    identifier = provisioning['ApplicationIdentifierPrefix'][0] + '.' + info['CFBundleIdentifier']
    if provisioning['Entitlements']['application-identifier'] != identifier:
        raise ValueError(f'The profile is for {provisioning["Entitlements"]["application-identifier"]}, '
                         f'not {identifier}')
    shutil.copy2(profile, output / 'embedded.mobileprovision')
    entitlements = signing_entitlements(provisioning, identifier, team,
                                        plistlib.loads(Path(entitlements_path).read_bytes()))
    # Inner code first, deepest paths first: nested bundles, then loose binaries.
    nested = sorted((p for p in output.rglob('*') if p.suffix in {'.framework', '.appex'} and p.is_dir()),
                    key=lambda p: len(p.parts), reverse=True)
    loose = [p for p in output.rglob('*') if is_macho(p) and p != output / info['CFBundleExecutable']
             and not any(bundle in p.parents for bundle in nested)]
    for path in loose:
        subprocess.run(['codesign', '--force', '--sign', identity, '--timestamp=none', str(path)], check=True,
                       stdout=subprocess.DEVNULL)
    for bundle in nested:
        subprocess.run(['codesign', '--force', '--sign', identity, '--timestamp=none', str(bundle)], check=True)
    with tempfile.NamedTemporaryFile(suffix='.plist') as file:
        file.write(plistlib.dumps(entitlements))
        file.flush()
        subprocess.run(['codesign', '--force', '--sign', identity, '--timestamp=none', '--entitlements', file.name,
                        '--generate-entitlement-der', str(output)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(output)], check=True)
    print(f'Signed {len(loose)} binaries and {len(nested)} bundles inside {output}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('app', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--profile', type=Path, required=True)
    parser.add_argument('--identity', required=True)
    parser.add_argument('--entitlements', type=Path, default=FREE_ENTITLEMENTS)
    parser.add_argument('--without-plugins', action='store_true',
                        help='Leave out app extensions, such as the thumbnailer, which need profiles of their own')
    parser.add_argument('--install', metavar='UDID', help='Install on this connected device with devicectl')
    args = parser.parse_args()
    sign(args.app, args.output, args.profile, args.identity, args.entitlements, args.without_plugins)
    if args.install:
        subprocess.run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', args.install,
                        str(args.output)], check=True)


if __name__ == '__main__':
    main()
