# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Copy a device app and package its native libraries as iOS frameworks.

Run before signing the output. Never modifies the input app. Python extensions
must already be linked as MH_DYLIB, rather than desktop MH_BUNDLE modules.
"""

import argparse
import hashlib
import json
import plistlib
import re
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path

from required_reason_apis import MANIFEST, categories_used, declared, manifest_for


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def macho_type(path):
    with path.open('rb') as stream:
        header = stream.read(16)
    if len(header) == 16 and header[:4] == b'\xcf\xfa\xed\xfe':
        return struct.unpack('<4I', header)[3]
    return None


def framework_name(path, app):
    if path.suffix == '.so':
        parts = path.relative_to(app).parts
        base = parts.index('site-packages') + 1 if 'site-packages' in parts else parts.index('lib-dynload') + 1
        return '.'.join((*parts[base:-1], path.name.split('.')[0]))
    if path.name.startswith('libOpenImageDenoise'):
        return re.sub(r'(?:\.\d+)*\.dylib$', '', path.name).removeprefix('lib')
    # Preserve versions where multiple ABIs are shipped together.
    return path.name.removesuffix('.dylib').removeprefix('lib')


def dependencies(path):
    return [line.strip().split(' (compatibility version', 1)[0]
            for line in run('xcrun', 'otool', '-L', str(path)).splitlines()[1:]]


def verify_platform(binary, minimum_os):
    if run('xcrun', 'lipo', '-archs', str(binary)) != 'arm64':
        raise ValueError(f'Expected an arm64 device binary: {binary}')
    commands = run('xcrun', 'vtool', '-show-build', str(binary))
    platform = re.search(r'platform (\S+)', commands)
    minimum = re.search(r'minos (\d+(?:\.\d+)*)', commands)
    if not platform or platform.group(1) != 'IOS' or not minimum:
        raise ValueError(f'Expected an iOS device build: {binary}')
    version = lambda text: tuple((list(map(int, text.split('.'))) + [0, 0])[:3])
    if version(minimum.group(1)) > version(minimum_os):
        raise ValueError(f'{binary} requires {minimum.group(1)}, above app minimum {minimum_os}')


# Blender's logo and icon artwork, which the app must not carry (ROUND5 8B, decision 34).
BLENDER_ARTWORK = ('blender_liquid_glass*', 'blender_icon.icns', 'blender_logo_mono.svg')
BLENDER_ICON_NAME = 'blender_liquid_glass'


def check_artwork(app):
    """Refuse an app that carries Blender's icon or logo, or names Blender's icon as its own."""
    found = sorted(str(path.relative_to(app)) for pattern in BLENDER_ARTWORK for path in app.rglob(pattern))
    if found:
        raise ValueError("The app carries Blender's artwork: " + ', '.join(found))
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    for key in ('CFBundleIcons', 'CFBundleIcons~ipad'):
        name = info.get(key, {}).get('CFBundlePrimaryIcon', {}).get('CFBundleIconName')
        if name == BLENDER_ICON_NAME:
            raise ValueError(f"The app's icon is Blender's ({key} names {name})")


def write_privacy_manifest(framework, binary, app_reasons):
    """Give \a framework a privacy manifest declaring the required reason APIs its \a binary uses,
    with the app's reasons for each (ROUND5 8D). Apple wants one in every bundle whose binary uses
    them; the app's own does not cover a framework's."""
    used = categories_used(binary)
    if not used:
        return
    missing = sorted(category for category in used if not app_reasons.get(category))
    if missing:
        raise ValueError(f'{binary.name} uses {", ".join(missing)}, which the app\'s {MANIFEST} '
                         'gives no reason for')
    (framework / MANIFEST).write_bytes(plistlib.dumps(manifest_for(used, app_reasons)))


def check_prepared(app):
    """The ways a prepared \a app breaks the framework layout; empty when it holds (ROUND5 8F.2).

    No loose `.dylib` or `.so`; each framework holds exactly one Mach-O, its `CFBundleExecutable`,
    with an install name of `@rpath/<name>.framework/<name>`; each `.fwork` marker names a
    framework binary whose `.origin` names the marker back; no `_CodeSignature` left from the
    input. Privacy manifests and Blender's artwork are checked by `required_reason_apis.scan` and
    `check_artwork`.
    """
    app = Path(app)
    problems = [f'loose library {path.relative_to(app)}' for path in sorted(app.rglob('*'))
                if path.suffix in ('.dylib', '.so')]
    frameworks = sorted((app / 'Frameworks').glob('*.framework'))
    if not frameworks:
        problems.append('no frameworks')
    for framework in frameworks:
        name = framework.name.removesuffix('.framework')
        info = plistlib.loads((framework / 'Info.plist').read_bytes()) if (framework / 'Info.plist').is_file() else {}
        if info.get('CFBundleExecutable') != name or info.get('CFBundlePackageType') != 'FMWK':
            problems.append(f'{framework.name}: Info.plist does not name {name} as a framework executable')
        binaries = [path for path in framework.rglob('*') if path.is_file() and macho_type(path) is not None]
        if binaries != [framework / name]:
            problems.append(f'{framework.name}: holds {len(binaries)} binaries, expected only {name}')
            continue
        identity = run('xcrun', 'otool', '-D', str(framework / name)).splitlines()[1:]
        if identity != [f'@rpath/{name}.framework/{name}']:
            problems.append(f'{framework.name}: install name {identity}')
    for marker in sorted(app.rglob('*.fwork')):
        binary = app / marker.read_text().strip()
        if not (binary.is_file() and binary.parent.parent == app / 'Frameworks'):
            problems.append(f'{marker.relative_to(app)} names no framework binary')
            continue
        origin = binary.with_name(binary.name + '.origin')
        if not origin.is_file() or origin.read_text().strip() != str(marker.relative_to(app)):
            problems.append(f'{origin.relative_to(app)} does not name {marker.relative_to(app)}')
    problems += [f'leftover signature {path.relative_to(app)}' for path in app.rglob('_CodeSignature')]
    problems += module_loader_problems(app)
    return problems


# Libraries that load modules of their own by path at run time, and the text their loader holds
# when it looks for those modules as sibling frameworks (a patch of the library's build).
MODULE_LOADERS = {
    # The literal alone, as the compiler keeps it: the framework's install name, set when it is
    # packaged, holds `.framework/` too.
    'OpenImageDenoise_core': (b'oidn_init_module_', b'\0.framework/\0',
                              'build_files/build_environment/patches/oidn_ios_frameworks.diff'),
}


def module_loader_problems(app):
    """The frameworks of \a app whose run-time module loader looks only beside itself: in the
    framework layout it finds nothing, and the library fails at run time with nothing failing
    here. Seen 2026-11-18: the prebuilt OpenImageDenoise said "no supported devices found" on the
    iPad, its Metal module in a framework of its own."""
    problems = []
    for name, (loader, framework_lookup, patch) in MODULE_LOADERS.items():
        binary = Path(app) / 'Frameworks' / f'{name}.framework' / name
        if binary.is_file():
            data = binary.read_bytes()
            if loader in data and framework_lookup not in data:
                problems.append(f'{name}: loads its modules only from its own folder, so they are not '
                                f'found as frameworks; rebuild the library with {patch}')
    return problems


def check_icons(app):
    """The ways \a app's compiled asset catalog lacks its icons; empty when it has them.

    `Assets.car` is compiled by a post-build step of the app's target; when Xcode cancels that
    step, the app is built without its icon and without the interface's glyphs, and nothing else
    fails (ROUND5 8F.4 found this on the first clean tester build).
    """
    app = Path(app)
    catalog = app / 'Assets.car'
    if not catalog.is_file():
        return ['no Assets.car: the app has no icon and no interface glyphs']
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    icon = info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {}).get('CFBundleIconName')
    names = {(entry.get('AssetType'), entry.get('Name'))
             for entry in json.loads(run('xcrun', 'assetutil', '--info', str(catalog)))[1:]}
    problems = []
    if ('Icon Image', icon) not in names:
        problems.append(f'Assets.car has no app icon named {icon}')
    if not any(name and name.startswith('blender.') for _, name in names):
        problems.append('Assets.car has no interface glyphs (blender.*)')
    return problems


def _prepare(source, output, replacements, without_plugins=False):
    source, output = source.resolve(), output.resolve()
    if output.exists() or source == output or source in output.parents:
        raise ValueError('Output must be a new directory outside the input app')
    info = plistlib.loads((source / 'Info.plist').read_bytes())
    if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        raise ValueError('Expected an iPhoneOS device application')
    verify_platform(source / info['CFBundleExecutable'], info['MinimumOSVersion'])
    candidates = [p for p in source.rglob('*') if p.is_file() and p.suffix in ('.dylib', '.so')]
    libraries = {}
    aliases = {}
    used_names = {}
    canonical = {}
    for path in candidates:
        real = path.resolve()
        if source not in real.parents:
            raise ValueError(f'Library escapes app: {path}')
        if real not in canonical:
            if 'Probe' in real.name or 'UITest' in real.name:
                raise ValueError(f'Development test library must not be distributed: {real}')
            replacement = replacements.get(real.name, real)
            if real.suffix == '.dylib' and replacement == real:
                matches = [p for p in replacements.values()
                           if p.suffix == '.dylib' and framework_name(p, source) == framework_name(real, source)]
                if len(matches) == 1:
                    replacement = matches[0]
            if macho_type(replacement) != 6:
                raise ValueError(f'Relink as an iOS dynamic library before packaging: {replacement}')
            verify_platform(replacement, info['MinimumOSVersion'])
            name = framework_name(real, source)
            if name in used_names:
                previous = used_names[name]
                old_binary = libraries[previous][1]
                if hashlib.sha256(old_binary.read_bytes()).digest() != hashlib.sha256(replacement.read_bytes()).digest():
                    raise ValueError(f'Conflicting framework binaries: {name}')
                canonical[real] = previous
            else:
                used_names[name] = real
                libraries[real] = (name, replacement)
                canonical[real] = real
        aliases[path.name] = libraries[canonical[real]][0]
    check_artwork(source)
    app_reasons = declared(source) or {}
    shutil.copytree(source, output, symlinks=True)
    if without_plugins:
        # App extensions, such as the thumbnailer, need App IDs and profiles of their own
        # (decision 36: the first tester builds ship without it).
        shutil.rmtree(output / 'PlugIns', ignore_errors=True)
    frameworks = output / 'Frameworks'
    frameworks.mkdir(exist_ok=True)
    binaries = [output / info['CFBundleExecutable']]
    # App extensions, such as the thumbnailer, load the same libraries from the app's Frameworks.
    extensions = []
    for appex in sorted((output / 'PlugIns').glob('*.appex')):
        appex_info = plistlib.loads((appex / 'Info.plist').read_bytes())
        extensions.append(appex / appex_info['CFBundleExecutable'])
    binaries.extend(extensions)
    for real, (name, replacement) in libraries.items():
        framework = frameworks / (name + '.framework')
        framework.mkdir()
        binary = framework / name
        shutil.copy2(replacement, binary)
        metadata = {
            'CFBundleExecutable': name,
            'CFBundleIdentifier': info['CFBundleIdentifier'] + '.lib.' + re.sub(r'[^A-Za-z0-9.-]', '-', name),
            'CFBundleName': name,
            'CFBundlePackageType': 'FMWK',
            'CFBundleInfoDictionaryVersion': '6.0',
            'CFBundleShortVersionString': '1.0',
            'CFBundleVersion': '1',
            'CFBundleSupportedPlatforms': ['iPhoneOS'],
            'MinimumOSVersion': info['MinimumOSVersion'],
        }
        (framework / 'Info.plist').write_bytes(plistlib.dumps(metadata))
        run('xcrun', 'install_name_tool', '-id', f'@rpath/{name}.framework/{name}', str(binary))
        write_privacy_manifest(framework, binary, app_reasons)
        binaries.append(binary)
        if real.suffix == '.so':
            # The dependency build's ABI tag may differ from embedded Python's
            # iPhoneOS tag. The generic .fwork suffix works with either runtime.
            marker = output / real.relative_to(source).with_name(real.name.split('.')[0] + '.fwork')
            marker.write_text(str(binary.relative_to(output)) + '\n')
            binary.with_name(binary.name + '.origin').write_text(str(marker.relative_to(output)) + '\n')
    for binary in binaries:
        changes = []
        for dependency in dependencies(binary):
            name = aliases.get(Path(dependency).name)
            if name:
                changes.extend(['-change', dependency, f'@rpath/{name}.framework/{name}'])
            elif not dependency.startswith(('/System/Library/', '/usr/lib/', '@rpath/')):
                raise ValueError(f'Unresolved dependency {dependency} in {binary}')
        if changes:
            run('xcrun', 'install_name_tool', *changes, str(binary))
    executable = binaries[0]
    load_commands = run('xcrun', 'otool', '-l', str(executable))
    if 'path @executable_path/Frameworks ' not in load_commands:
        run('xcrun', 'install_name_tool', '-add_rpath', '@executable_path/Frameworks', str(executable))
    for extension in extensions:
        # `Blender.app/PlugIns/<name>.appex/<executable>` reaches `Blender.app/Frameworks`.
        load_commands = run('xcrun', 'otool', '-l', str(extension))
        if 'path @executable_path/../../Frameworks ' not in load_commands:
            run('xcrun', 'install_name_tool', '-add_rpath', '@executable_path/../../Frameworks',
                str(extension))
    for path in candidates:
        (output / path.relative_to(source)).unlink()
    # Python's development configuration can include linker objects and static archives.
    # They are not runtime resources and cannot be shipped as loose executable material.
    for path in (output / 'Assets').rglob('*'):
        if path.is_file() and (path.suffix == '.a' or macho_type(path) == 1):
            path.unlink()
    for signature in list(output.rglob('_CodeSignature')):
        shutil.rmtree(signature)
    # A distribution app must not contain development probes or an injected test library.
    for path in output.rglob('*'):
        if path.is_file() and macho_type(path) is not None:
            if path != executable and path not in extensions and frameworks not in path.parents:
                raise ValueError(f'Unexpected executable outside Frameworks: {path}')
    for binary in binaries:
        for dependency in dependencies(binary):
            if dependency.startswith('@rpath/'):
                relative = dependency.removeprefix('@rpath/')
                if not (frameworks / relative).is_file() and not relative.startswith('libswift'):
                    raise ValueError(f'Missing packaged dependency: {dependency}')
    problems = check_prepared(output)
    if problems:
        raise ValueError('The prepared app breaks the framework layout:\n  ' + '\n  '.join(problems))
    return len(libraries)


def prepare(source, output, replacements, without_plugins=False):
    source, output = source.resolve(), output.resolve()
    if output.exists() or source == output or source in output.parents:
        raise ValueError('Output must be a new directory outside the input app')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='testflight-', dir=output.parent) as temporary:
        staged = Path(temporary) / output.name
        count = _prepare(source, staged, replacements, without_plugins)
        staged.rename(output)
    print(f'Packaged {count} frameworks into {output}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--replacement-directory', type=Path, action='append', default=[],
                        help='Libraries to package instead of the app\'s own, by file name: NumPy\'s '
                             'relinked modules, the rebuilt OpenImageDenoise. May be given more than once')
    parser.add_argument('--without-plugins', action='store_true',
                        help='Leave out app extensions, such as the thumbnailer, which need App IDs of their own')
    args = parser.parse_args()
    replacements = {}
    for directory in args.replacement_directory:
        for path in directory.rglob('*'):
            if path.is_file() and path.suffix in ('.so', '.dylib'):
                if path.name in replacements:
                    raise ValueError(f'Duplicate replacement: {path.name}')
                replacements[path.name] = path
    prepare(args.source, args.output, replacements, args.without_plugins)


if __name__ == '__main__':
    main()
