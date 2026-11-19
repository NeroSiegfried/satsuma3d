# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Exercise distribution packaging with real iOS Mach-O dependencies."""

import json
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# The scripts under test are release tools, in `release/ios`.
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "release" / "ios"))

from archive_testflight import APP_ENTITLEMENTS, signing_entitlements
from check_numpy_replacements import check as check_replacements
from prepare_testflight import check_artwork, check_icons, check_prepared, dependencies, macho_type, prepare
from required_reason_apis import MANIFEST, manifest_for, scan


class ArchiveEntitlementsTest(unittest.TestCase):
    GPU = 'com.apple.developer.background-tasks.continued-processing.gpu'

    def provisioning(self, **granted):
        return {'Entitlements': {'application-identifier': 'TEAM.org.blender.test', **granted}}

    def test_app_entitlements_are_signed(self):
        entitlements = signing_entitlements(self.provisioning(**{self.GPU: True}),
                                            'TEAM.org.blender.test', 'TEAM', {self.GPU: True})
        self.assertTrue(entitlements[self.GPU])
        self.assertEqual(entitlements['application-identifier'], 'TEAM.org.blender.test')
        self.assertFalse(entitlements['get-task-allow'])

    def test_entitlements_the_profile_lacks_are_refused(self):
        with self.assertRaisesRegex(ValueError, 'does not grant ' + self.GPU):
            signing_entitlements(self.provisioning(), 'TEAM.org.blender.test', 'TEAM', {self.GPU: True})

    def test_app_requests_background_gpu(self):
        self.assertTrue(plistlib.loads(APP_ENTITLEMENTS.read_bytes()).get(self.GPU))



@unittest.skipUnless(sys.platform == 'darwin', 'Requires the iPhoneOS SDK')
class TestFlightPackagingTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'Input.app'
        self.lib = self.app / 'Assets/lib'
        self.lib.mkdir(parents=True)
        self.sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
        (self.app / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'org.blender.packaging-test',
            'CFBundleExecutable': 'Test',
            'CFBundleSupportedPlatforms': ['iPhoneOS'],
            'MinimumOSVersion': '27.0',
        }))

    def compile(self, name, source, *arguments):
        path = self.root / (name + '.c')
        path.write_text(source)
        subprocess.run(['xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64',
                        '-isysroot', self.sdk, '-miphoneos-version-min=27.0',
                        '-Wl,-headerpad_max_install_names', str(path), *map(str, arguments)],
                       check=True, capture_output=True)

    def test_relocates_dependency_graph_and_python_extensions(self):
        library = self.lib / 'libExample.1.dylib'
        self.compile('lib', 'int example(void) { return 42; }', '-dynamiclib',
                     '-Wl,-install_name,@rpath/libExample.1.dylib', '-o', library)
        (self.lib / 'libExample.dylib').symlink_to(library.name)
        self.compile('app', 'int example(void); int main(void) { return example(); }',
                     library, '-o', self.app / 'Test')
        modules = self.app / 'Assets/5.1/python/lib/python3.13/site-packages/demo'
        modules.mkdir(parents=True)
        module = modules / '_native.abi3.so'
        self.compile('module', 'int example(void); int native(void) { return example(); }',
                     '-dynamiclib', library, '-o', module)
        before = (self.app / 'Test').read_bytes()
        output = self.root / 'Output.app'
        prepare(self.app, output, {})
        self.assertEqual((self.app / 'Test').read_bytes(), before)
        self.assertTrue(module.exists())
        self.assertFalse(list(output.rglob('*.dylib')))
        self.assertFalse(list(output.rglob('*.so')))
        self.assertIn('@rpath/Example.1.framework/Example.1', dependencies(output / 'Test'))
        marker = output / module.relative_to(self.app).with_name('_native.fwork')
        extension = output / marker.read_text().strip()
        self.assertEqual(macho_type(extension), 6)
        self.assertEqual(extension.with_name(extension.name + '.origin').read_text().strip(),
                         str(marker.relative_to(output)))
        self.assertIn('@rpath/Example.1.framework/Example.1', dependencies(extension))
        self.assertEqual(check_prepared(output), [])
        with self.assertRaises(ValueError):
            prepare(self.app, output, {})

    def test_prepared_layout_check(self):
        """ROUND5 8F.2: the layout check finds a loose library, a second binary in a framework and a
        marker that names nothing."""
        library = self.lib / 'libExample.1.dylib'
        self.compile('lib', 'int example(void) { return 42; }', '-dynamiclib',
                     '-Wl,-install_name,@rpath/libExample.1.dylib', '-o', library)
        self.compile('app', 'int example(void); int main(void) { return example(); }',
                     library, '-o', self.app / 'Test')
        modules = self.app / 'Assets/5.1/python/lib/python3.13/site-packages/demo'
        modules.mkdir(parents=True)
        self.compile('module', 'int native(void) { return 1; }', '-dynamiclib', '-o', modules / '_native.abi3.so')
        output = self.root / 'Output.app'
        prepare(self.app, output, {})
        self.assertEqual(check_prepared(output), [])
        framework = output / 'Frameworks/Example.1.framework'
        (framework / 'Extra').write_bytes((framework / 'Example.1').read_bytes())
        (output / 'Assets/stray.dylib').write_bytes(b'')
        marker = output / 'Assets/5.1/python/lib/python3.13/site-packages/demo/_native.fwork'
        marker.write_text('Frameworks/missing.framework/missing\n')
        problems = '\n'.join(check_prepared(output))
        self.assertIn('Example.1.framework: holds 2 binaries', problems)
        self.assertIn('loose library Assets/stray.dylib', problems)
        self.assertIn('_native.fwork names no framework binary', problems)

    def test_without_plugins(self):
        """Decision 36: a tester build leaves the thumbnail extension out."""
        self.compile('app', 'int main(void) { return 0; }', '-o', self.app / 'Test')
        appex = self.app / 'PlugIns/Thumbnailer.appex'
        appex.mkdir(parents=True)
        (appex / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'thumbnailer'}))
        self.compile('appex', 'int main(void) { return 0; }', '-o', appex / 'thumbnailer')
        library = self.lib / 'libExample.dylib'
        self.compile('lib', 'int example(void) { return 42; }', '-dynamiclib',
                     '-Wl,-install_name,@rpath/libExample.dylib', '-o', library)
        output = self.root / 'Output.app'
        prepare(self.app, output, {}, without_plugins=True)
        self.assertFalse((output / 'PlugIns').exists())
        self.assertTrue(appex.is_dir())

    def test_relocates_app_extension_dependencies(self):
        library = self.lib / 'libExample.1.dylib'
        self.compile('lib', 'int example(void) { return 42; }', '-dynamiclib',
                     '-Wl,-install_name,@rpath/libExample.1.dylib', '-o', library)
        self.compile('app', 'int example(void); int main(void) { return example(); }',
                     library, '-o', self.app / 'Test')
        appex = self.app / 'PlugIns/Thumbnailer.appex'
        appex.mkdir(parents=True)
        (appex / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'thumbnailer'}))
        self.compile('appex', 'int example(void); int main(void) { return example(); }',
                     library, '-Wl,-rpath,@loader_path/../../Assets/lib', '-o', appex / 'thumbnailer')
        output = self.root / 'Output.app'
        prepare(self.app, output, {})
        extension = output / 'PlugIns/Thumbnailer.appex/thumbnailer'
        self.assertIn('@rpath/Example.1.framework/Example.1', dependencies(extension))
        load_commands = subprocess.check_output(['xcrun', 'otool', '-l', str(extension)], text=True)
        self.assertIn('path @executable_path/../../Frameworks ', load_commands)

    def test_rejects_desktop_bundle_modules_without_modifying_source(self):
        self.compile('app', 'int main(void) { return 0; }', '-o', self.app / 'Test')
        self.compile('bundle', 'int example(void) { return 42; }', '-bundle',
                     '-o', self.lib / 'bad.so')
        with self.assertRaisesRegex(ValueError, 'Relink'):
            prepare(self.app, self.root / 'Rejected.app', {})
        self.assertTrue((self.lib / 'bad.so').exists())
        self.assertFalse((self.root / 'Rejected.app').exists())

    def test_refuses_blender_artwork(self):
        """ROUND5 8B: a prepared app holds none of Blender's icon or logo files, nor its icon's name."""
        self.compile('app', 'int main(void) { return 0; }', '-o', self.app / 'Test')
        for name in ('blender_logo_mono.svg', 'blender_liquid_glass60x60@2x.png', 'blender_icon.icns'):
            (self.app / name).write_bytes(b'artwork')
            with self.assertRaisesRegex(ValueError, "Blender's artwork"):
                prepare(self.app, self.root / 'Rejected.app', {})
            (self.app / name).unlink()
        info = plistlib.loads((self.app / 'Info.plist').read_bytes())
        info['CFBundleIcons~ipad'] = {'CFBundlePrimaryIcon': {'CFBundleIconName': 'blender_liquid_glass'}}
        (self.app / 'Info.plist').write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, "icon is Blender's"):
            prepare(self.app, self.root / 'Rejected.app', {})
        self.assertFalse((self.root / 'Rejected.app').exists())

    def manifest(self, app, **reasons):
        (app / MANIFEST).write_bytes(plistlib.dumps(manifest_for(reasons, reasons)))

    def test_required_reason_apis(self):
        """ROUND5 8D: each binary's required reason APIs are found, and its manifest must declare them."""
        library = self.lib / 'libClock.dylib'
        self.compile('lib', '#include <mach/mach_time.h>\nunsigned long long clock_now(void) '
                     '{ return mach_absolute_time(); }', '-dynamiclib', '-Wl,-install_name,@rpath/libClock.dylib',
                     '-o', library)
        self.compile('app', '#include <sys/stat.h>\nunsigned long long clock_now(void);\n'
                     'int main(void) { struct stat s; return stat("x", &s) + (int)clock_now(); }',
                     library, '-o', self.app / 'Test')
        usage, problems = scan(self.app)
        self.assertEqual(usage['NSPrivacyAccessedAPICategoryFileTimestamp'], {'Test': ['stat']})
        self.assertEqual(usage['NSPrivacyAccessedAPICategorySystemBootTime'],
                         {'Assets/lib/libClock.dylib': ['mach_absolute_time']})
        self.assertEqual(len(problems), 2)  # No manifest at all.
        self.manifest(self.app, NSPrivacyAccessedAPICategoryFileTimestamp=['C617.1'])
        problems = scan(self.app)[1]
        self.assertEqual(len(problems), 1)
        self.assertIn('NSPrivacyAccessedAPICategorySystemBootTime', problems[0])
        self.manifest(self.app, NSPrivacyAccessedAPICategoryFileTimestamp=['C617.1'],
                      NSPrivacyAccessedAPICategorySystemBootTime=['XXXX.1'])
        self.assertIn('needs reasons from', scan(self.app)[1][0])
        self.manifest(self.app, NSPrivacyAccessedAPICategoryFileTimestamp=['C617.1'],
                      NSPrivacyAccessedAPICategorySystemBootTime=['35F9.1'])
        self.assertEqual(scan(self.app)[1], [])
        # Packaged, the library is a framework with its own manifest, holding its subset.
        output = self.root / 'Output.app'
        prepare(self.app, output, {})
        framework = output / 'Frameworks/Clock.framework'
        manifest = plistlib.loads((framework / MANIFEST).read_bytes())
        self.assertEqual([entry['NSPrivacyAccessedAPIType'] for entry in manifest['NSPrivacyAccessedAPITypes']],
                         ['NSPrivacyAccessedAPICategorySystemBootTime'])
        self.assertFalse(manifest['NSPrivacyTracking'])
        self.assertEqual(scan(output)[1], [])
        # A framework using an API the app gives no reason for stops packaging.
        self.manifest(self.app, NSPrivacyAccessedAPICategoryFileTimestamp=['C617.1'])
        with self.assertRaisesRegex(ValueError, 'gives no reason'):
            prepare(self.app, self.root / 'Rejected.app', {})


@unittest.skipUnless(sys.platform == 'darwin', 'Requires the iPhoneOS SDK')
class NumpyReplacementsTest(unittest.TestCase):
    """ROUND5 8F.1: a relinked module must be an iOS MH_DYLIB named and exporting as the bundled one."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()

    def module(self, path, kind, minimum='26.0', symbol='PyInit__demo'):
        path.parent.mkdir(parents=True, exist_ok=True)
        source = self.root / 'module.c'
        source.write_text(f'void *{symbol}(void) {{ return 0; }}')
        subprocess.run(['xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64', '-isysroot', self.sdk,
                        f'-miphoneos-version-min={minimum}', kind, str(source), '-o', str(path)],
                       check=True, capture_output=True)

    def problems(self):
        return [problem for _, problems in check_replacements(self.root / 'bundled/numpy', self.root / 'out', '26.0')
                for problem in problems]

    def test_check(self):
        self.module(self.root / 'bundled/numpy/core/_demo.cpython-313-darwin.so', '-bundle')
        replacement = self.root / 'out/numpy/core/_demo.cpython-313-arm64-iphoneos.so'
        self.module(replacement, '-bundle')
        self.assertIn('not MH_DYLIB', self.problems())
        replacement.unlink()
        self.module(replacement, '-dynamiclib')
        self.assertEqual(self.problems(), [])
        replacement.unlink()
        self.module(replacement, '-dynamiclib', minimum='27.0')
        self.assertIn('minos 27.0, expected 26.0', self.problems())
        replacement.unlink()
        self.module(replacement, '-dynamiclib', symbol='PyInit__other')
        self.assertTrue(any(problem.startswith('exports') for problem in self.problems()))
        replacement.unlink()
        # The Mac's file suffix: the module is missing under the name the app installs.
        self.module(replacement.with_name('_demo.cpython-313-darwin.so'), '-dynamiclib')
        problems = self.problems()
        self.assertTrue(any(problem.startswith('no replacement') for problem in problems))
        self.assertIn('replaces no bundled module', problems)


@unittest.skipUnless(sys.platform == 'darwin', 'Requires the iPhoneOS SDK')
class OidnReplacementsTest(unittest.TestCase):
    """ROUND5 8K: the rebuilt OpenImageDenoise stands in for the prebuilt set, finds its device module
    as a framework, and asks for the framework name packaging gives it."""
    ROOT = Path(__file__).resolve().parents[2]
    CORE = 'libOpenImageDenoise_core.2.4.1.dylib'
    METAL = 'libOpenImageDenoise_device_metal.2.4.1.dylib'

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()

    def library(self, folder, name, source, *arguments, minimum='14.0'):
        folder.mkdir(parents=True, exist_ok=True)
        path = self.root / (name + '.c')
        path.write_text(source)
        subprocess.run(['xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64', '-isysroot', self.sdk,
                        f'-miphoneos-version-min={minimum}', '-dynamiclib',
                        f'-Wl,-install_name,@rpath/{name}', str(path), *map(str, arguments),
                        '-o', str(folder / name)], check=True, capture_output=True)

    def set(self, folder, lookup=True, minimum='14.0', *arguments):
        strings = ['oidn_init_module_', 'OpenImageDenoise_'] + (['.framework/'] if lookup else [])
        core = ''.join(f'static __attribute__((used)) const char *s{i} = "{text}";\n' for i, text in enumerate(strings))
        self.library(folder, self.CORE, core + 'int oidnNewDevice(void) { return 1; }', *arguments, minimum=minimum)
        self.library(folder, self.METAL, 'void oidn_init_module_device_metal_v20401(void) {}',
                     folder / self.CORE, *arguments, minimum=minimum)

    def problems(self, prebuilt, replacements):
        from check_oidn_replacements import check
        return [problem for _, problems in check(prebuilt, replacements) for problem in problems]

    def test_check(self):
        prebuilt, out = self.root / 'prebuilt', self.root / 'out'
        self.set(prebuilt, lookup=False)
        self.set(out)
        self.assertEqual(self.problems(prebuilt, out), [])
        # The prebuilt core itself, without the patch: refused.
        self.assertIn('no framework lookup', ' '.join(self.problems(prebuilt, prebuilt)))
        self.set(out, minimum='15.0')
        self.assertTrue(any(problem.startswith('minos 15.0') for problem in self.problems(prebuilt, out)))
        self.set(out, True, '14.0', '-Wl,-rpath,/opt/builder/oidn/lib')
        self.assertTrue(any('run paths' in problem for problem in self.problems(prebuilt, out)))
        self.set(out)
        (out / self.METAL).unlink()
        (out / 'libOpenImageDenoise_device_metal.dylib').write_bytes((prebuilt / self.METAL).read_bytes())
        problems = self.problems(prebuilt, out)
        self.assertTrue(any(problem.startswith('no replacement') for problem in problems))
        self.assertIn('replaces no prebuilt library', problems)

    def test_framework_names_agree(self):
        """The patched core asks for `OpenImageDenoise_` + module + SHARED_POSTFIX (empty in Release)
        as `<name>.framework/<name>`; packaging names the module's framework the same."""
        from prepare_testflight import framework_name
        patch = (self.ROOT / 'build_files/build_environment/patches/oidn_ios_frameworks.diff').read_text()
        self.assertIn('OIDN_LIBRARY_NAME "_" + name + SHARED_POSTFIX', patch)
        self.assertIn('"../" + frameworkName + ".framework/" + frameworkName', patch)
        self.assertEqual(framework_name(Path(self.METAL), Path('.')), 'OpenImageDenoise_device_metal')
        self.assertEqual(framework_name(Path(self.CORE), Path('.')), 'OpenImageDenoise_core')

    def test_build_script_follows_the_recipe(self):
        script = (self.ROOT / 'release/ios/build_oidn_ios.sh').read_text()
        recipe = (self.ROOT / 'build_files/build_environment/cmake/openimagedenoise.cmake').read_text()
        for patch in ('oidn.diff', 'oidn_ios_frameworks.diff'):
            self.assertIn(patch, recipe)
            self.assertIn(patch, script)
        for option in ('-DOIDN_DEVICE_METAL=ON', '-DOIDN_DEVICE_CPU=OFF', '-DOIDN_APPS=OFF',
                       '-DOIDN_FILTER_RTLIGHTMAP=OFF'):
            self.assertIn(option, script)
        testflight = (self.ROOT / 'release/ios/build_testflight.sh').read_text()
        self.assertIn('--replacement-directory "$denoiser"', testflight)
        self.assertIn('check_oidn_replacements.py', testflight)


class BuildScriptTest(unittest.TestCase):
    """ROUND5 8F.4: `build_testflight.sh` makes a tester build and never sends it anywhere."""
    SCRIPT = Path(__file__).resolve().parents[2] / 'release/ios/build_testflight.sh'

    def test_never_uploads(self):
        text = self.SCRIPT.read_text()
        for word in ('altool', 'iTMSTransporter', 'Transporter', 'notarytool', '<string>upload</string>',
                     'destination=upload', 'curl', 'git push'):
            self.assertNotIn(word, text)
        self.assertIn('<key>destination</key><string>export</string>', text)
        self.assertIn('--without-plugins', text)
        # The icon follows the checkout, not a stale cache entry (the icon's folder was renamed).
        self.assertIn('-UIOS_APP_ICON -UIOS_APP_ICON_NAME', text)

    def run_with(self, settings):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'testflight.env'
            path.write_text(settings)
            return subprocess.run(['bash', str(self.SCRIPT), str(path)], capture_output=True, text=True,
                                  timeout=60)

    def test_encryption_key_follows_the_check(self):
        """ROUND5 8M, E4 (decision 95): the tester build's key is written from the check of the
        prepared program: false when it finds no encryption library, absent when it finds one, and
        the identity check holds the pair. Nothing else writes the key. E5: one setting brings the
        library back. The development build's template keeps its key."""
        text = self.SCRIPT.read_text()
        self.assertIn('"$release/check_no_encryption_library.py" "$prepared"', text)
        self.assertIn("Delete :ITSAppUsesNonExemptEncryption' \"$prepared/Info.plist\"", text)
        self.assertIn("0) encryption=none\n       /usr/libexec/PlistBuddy -c 'Add :ITSAppUsesNonExemptEncryption bool false'", text)
        self.assertIn('1) encryption=present ;;', text)
        self.assertIn('*) fail_log encryption ;;', text)
        self.assertEqual(text.count('ITSAppUsesNonExemptEncryption bool'), 1)
        self.assertIn("if (encryption, key) not in (('none', False), ('present', 'absent')):", text)
        self.assertIn('PYTHON_OPENSSL=OFF', text)
        self.assertIn('-DWITH_PLATYPUS_PYTHON_OPENSSL="$PYTHON_OPENSSL"', text)
        template = plistlib.loads((self.SCRIPT.parent / 'Blender.app/Info.plist').read_bytes())
        self.assertIs(template.get('ITSAppUsesNonExemptEncryption'), False)

    def test_refuses_the_development_identity_and_a_missing_source(self):
        result = self.run_with('BUNDLE_ID=app.example.dev\n')
        self.assertEqual(result.returncode, 1)
        self.assertIn("ends in .dev", result.stderr)
        result = self.run_with('SOURCE_URL=\n')
        self.assertEqual(result.returncode, 1)
        self.assertIn('must name its source', result.stderr)


def ios_program(path, source, *arguments):
    """Compile a small iOS arm64 program."""
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    path.parent.mkdir(parents=True, exist_ok=True)
    source_path = path.with_name(path.name + '.c')
    source_path.write_text(source)
    subprocess.run(['xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64', '-isysroot', sdk,
                    '-miphoneos-version-min=27.0', str(source_path), *map(str, arguments), '-o', str(path)],
                   check=True, capture_output=True)
    source_path.unlink()
    return path


LIBDIR = Path(__file__).resolve().parents[2] / 'lib/ios_arm64'
PLAIN_PROGRAM = 'int main(void) { return 0; }\n'
# The same program, linked against the prebuilt OpenSSL the way the stock app was.
OPENSSL_PROGRAM = ('const char *OpenSSL_version(int);\n'
                   'int main(void) { return OpenSSL_version(0)[0] == 0; }\n')


@unittest.skipUnless(sys.platform == 'darwin', 'Requires the iPhoneOS SDK')
class EncryptionCheckTest(unittest.TestCase):
    """ROUND5 8M, E1: `check_no_encryption_library.py` tells a program with OpenSSL from one without."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def verdict(self, path):
        result = subprocess.run([sys.executable, '-B', str(Path(__file__).resolve().parents[2] /
                                 'release/ios/check_no_encryption_library.py'), str(path)],
                                capture_output=True, text=True)
        return result.returncode, result.stdout.strip().splitlines()[-1]

    def test_with_and_without_the_library(self):
        crypto = LIBDIR / 'ssl/lib/libcrypto.a'
        if not crypto.is_file():
            self.skipTest('No prebuilt OpenSSL at ' + str(crypto))
        with_library = ios_program(self.root / 'with', OPENSSL_PROGRAM, crypto)
        without = ios_program(self.root / 'without', PLAIN_PROGRAM)
        self.assertEqual(self.verdict(without), (0, f'no encryption library: {without}'))
        status, line = self.verdict(with_library)
        self.assertEqual((status, line), (1, f'encryption library present: {with_library}'))

    def test_app_and_its_frameworks(self):
        crypto = LIBDIR / 'ssl/lib/libcrypto.a'
        if not crypto.is_file():
            self.skipTest('No prebuilt OpenSSL at ' + str(crypto))
        app = self.root / 'Example.app'
        ios_program(app / 'Example', PLAIN_PROGRAM)
        (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Example'}))
        self.assertEqual(self.verdict(app)[0], 0)
        # A library in a framework that carries it counts too.
        ios_program(app / 'Frameworks/Crypto.framework/Crypto', OPENSSL_PROGRAM, crypto)
        self.assertEqual(self.verdict(app)[0], 1)

    def test_version_string_alone(self):
        program = ios_program(self.root / 'text', 'const char *v = "OpenSSL 3.5.2 5 Aug 2025";\n'
                              'int main(void) { return v[0] == 0; }\n')
        self.assertEqual(self.verdict(program)[0], 1)

    def test_unreadable_is_never_a_pass(self):
        self.assertEqual(self.verdict(self.root / 'missing')[0], 2)
        (self.root / 'Empty.app').mkdir()
        self.assertEqual(self.verdict(self.root / 'Empty.app')[0], 2)
        (self.root / 'text').write_text('not a program')
        self.assertEqual(self.verdict(self.root / 'text')[0], 2)


@unittest.skipUnless(sys.platform == 'darwin', 'Requires the iPhoneOS SDK')
class DerivePythonTest(unittest.TestCase):
    """ROUND5 8M, M1: Python's library without `_ssl` and `_hashlib`, derived at build time."""
    ROOT = Path(__file__).resolve().parents[2]
    PYTHON = LIBDIR / 'python'
    CONFIG = PYTHON / 'lib/python3.13/config-3.13-arm64-iphoneos/config.c'

    def setUp(self):
        if not (self.PYTHON / 'lib/libpython3.13.a').is_file():
            self.skipTest('No prebuilt iOS Python')
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()

    def derive(self, library, config, output):
        return subprocess.run([sys.executable, '-B', str(self.ROOT / 'release/ios/derive_python_without_openssl.py'),
                               str(library), str(config), str(self.PYTHON / 'include/python3.13'), str(output),
                               '--sysroot', self.sdk, '--minimum', '27.0'], capture_output=True, text=True)

    def members(self, library):
        return subprocess.check_output(['ar', 't', str(library)], text=True).splitlines()

    def test_the_prebuilt_library(self):
        """The real library: the two members gone, the module table without them, nothing of
        OpenSSL left; run again, it is left alone."""
        output = self.root / 'out'
        result = self.derive(self.PYTHON / 'lib/libpython3.13.a', self.CONFIG, output)
        self.assertEqual(result.returncode, 0, result.stderr)
        derived = output / 'libpython3.13.a'
        members = self.members(derived)
        self.assertNotIn('_ssl.o', members)
        self.assertNotIn('_hashopenssl.o', members)
        for member in ('md5module.o', 'sha1module.o', 'sha2module.o', 'sha3module.o', 'blake2module.o',
                       'config.o'):
            self.assertIn(member, members)
        self.assertEqual(len(members) + 2, len(self.members(self.PYTHON / 'lib/libpython3.13.a')))
        symbols = subprocess.check_output(['nm', '-A', '-g', str(derived)], text=True, stderr=subprocess.DEVNULL)
        self.assertNotIn('_PyInit__ssl', symbols)
        self.assertNotIn('_PyInit__hashlib', symbols)
        self.assertIn('_PyInit__sha2', symbols)
        self.assertFalse(re.search(r' U _(SSL|EVP|OPENSSL|CRYPTO|X509)_', symbols))
        built = subprocess.check_output(['otool', '-l', str(derived)], text=True)
        self.assertIn('minos 27.0', built)
        modified = derived.stat().st_mtime_ns
        again = self.derive(self.PYTHON / 'lib/libpython3.13.a', self.CONFIG, output)
        self.assertIn('up to date', again.stdout)
        self.assertEqual(derived.stat().st_mtime_ns, modified)

    def test_refuses_a_table_it_does_not_know(self):
        config = self.root / 'config.c'
        config.write_text(self.CONFIG.read_text().replace('    {"_ssl", PyInit__ssl},\n', ''))
        result = self.derive(self.PYTHON / 'lib/libpython3.13.a', config, self.root / 'out')
        self.assertEqual(result.returncode, 1)
        self.assertIn('does not declare and list _ssl exactly once', result.stderr)
        self.assertFalse((self.root / 'out/libpython3.13.a').exists())

    def test_refuses_another_user_of_the_modules(self):
        """A member other than `config.o` that needs what the two define: refused, not stubbed."""
        objects = self.root / 'objects'
        objects.mkdir()
        sources = {
            '_ssl.o': 'void *SSL_new(void *); void *PyInit__ssl(void) { return SSL_new(0); }',
            '_hashopenssl.o': 'void *EVP_MD_fetch(void); void *PyInit__hashlib(void) { return EVP_MD_fetch(); }',
            'config.o': 'void *PyInit__ssl(void); void *PyInit__hashlib(void);'
                        'void *table[] = {PyInit__ssl, PyInit__hashlib};',
            'other.o': 'void *PyInit__ssl(void); void *other(void) { return PyInit__ssl(); }',
        }
        for name, source in sources.items():
            (objects / (name + '.c')).write_text(source)
            subprocess.run(['xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64', '-isysroot', self.sdk,
                            '-c', name + '.c', '-o', name], cwd=objects, check=True, capture_output=True)
        library = self.root / 'libpython3.13.a'
        subprocess.run(['xcrun', 'ar', 'rcs', str(library), *sources], cwd=objects, check=True)
        result = self.derive(library, self.CONFIG, self.root / 'out')
        self.assertEqual(result.returncode, 1)
        self.assertIn("members other than config.o use what", result.stderr)
        self.assertIn('other.o', result.stderr)

    def test_the_build_links_it(self):
        """E5: the option is off for the iPad, and OpenSSL is linked only when it is on."""
        platform = (self.ROOT / 'build_files/cmake/platform/platform_apple.cmake').read_text()
        self.assertIn('option(WITH_PLATYPUS_PYTHON_OPENSSL', platform)
        self.assertIn("and with them OpenSSL (build 1's library)\" OFF)", platform)
        self.assertIn('if(WITH_PYTHON AND NOT WITH_PLATYPUS_PYTHON_OPENSSL)', platform)
        self.assertIn('set(PYTHON_LIBRARIES "${CMAKE_BINARY_DIR}/python_without_openssl/', platform)
        # Inside the iOS block only: desktop builds are not touched.
        start = platform.index('if(WITH_APPLE_CROSSPLATFORM)\n  # The iPad app carries no OpenSSL')
        self.assertLess(start, platform.index('option(WITH_PLATYPUS_PYTHON_OPENSSL'))
        creator = (self.ROOT / 'source/creator/CMakeLists.txt').read_text()
        guarded = creator[creator.index('if(WITH_PLATYPUS_PYTHON_OPENSSL)'):]
        self.assertLess(guarded.index('libssl.a'), guarded.index('endif()'))
        self.assertEqual(creator.count('libssl.a'), 1)
        self.assertEqual(creator.count('libcrypto.a'), 1)


class UploadScriptTest(unittest.TestCase):
    """ROUND5 8L, L4: `upload_testflight.sh` prints what it would send and refuses without the build
    number repeated. Run in a throwaway repository whose `github` remote is a local bare one, with an
    `xcodebuild` stand-in that records any call: nothing can reach Apple. It is never called here
    with the right number."""
    SCRIPT = Path(__file__).resolve().parents[2] / 'release/ios/upload_testflight.sh'

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.repo = root / 'checkout'
        script = self.repo / 'release/ios/upload_testflight.sh'
        script.parent.mkdir(parents=True)
        script.write_text(self.SCRIPT.read_text())
        check = 'check_no_encryption_library.py'
        (script.parent / check).write_text((self.SCRIPT.parent / check).read_text())
        self.git('init', '-q', '-b', 'ipad/main')
        self.git('add', '.')
        self.git('commit', '-q', '-m', 'one')
        self.commit = self.git('rev-parse', 'HEAD')
        self.git('init', '-q', '--bare', str(root / 'remote.git'), cwd=root)
        self.git('remote', 'add', 'github', str(root / 'remote.git'))
        self.git('push', '-q', 'github', 'ipad/main')
        self.build = root / 'build'
        app = self.build / 'Satsuma3D.xcarchive/Products/Applications/Blender.app'
        app.mkdir(parents=True)
        self.info = {'CFBundleIdentifier': 'app.example', 'CFBundleShortVersionString': '0.1.0',
                     'CFBundleVersion': '3', 'CFBundleDisplayName': 'Example',
                     'SatsumaSourceCommit': self.commit, 'ITSAppUsesNonExemptEncryption': False}
        self.app = app
        ios_program(app / 'Blender', PLAIN_PROGRAM)
        self.write_info()
        (self.build / 'export').mkdir()
        (self.build / 'export/Example.ipa').write_bytes(b'')
        self.settings = root / 'testflight.env'
        self.settings.write_text(f'BUNDLE_ID=app.example\nMARKETING_VERSION=0.1.0\nBUILD_NUMBER=3\n'
                                 f'BUILD_DIR={self.build}\n')
        self.bin = root / 'bin'
        self.bin.mkdir()
        self.called = root / 'xcodebuild-called'
        stand_in = self.bin / 'xcodebuild'
        stand_in.write_text(f'#!/bin/sh\necho "$@" >> {self.called}\nexit 1\n')
        stand_in.chmod(0o755)

    def git(self, *args, cwd=None):
        return subprocess.run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                               '-c', 'core.hooksPath=/dev/null', *args], cwd=cwd or self.repo,
                              check=True, capture_output=True, text=True).stdout.strip()

    def write_info(self):
        (self.app / 'Info.plist').write_bytes(plistlib.dumps(self.info))

    def run_script(self, *args):
        import os
        environment = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}')
        result = subprocess.run(['bash', str(self.repo / 'release/ios/upload_testflight.sh'), *args,
                                 str(self.settings)], capture_output=True, text=True, timeout=60,
                                env=environment)
        self.assertFalse(self.called.exists(), 'xcodebuild was called')
        return result

    def test_prints_and_sends_nothing_without_the_flag(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        for text in ('app.example', '0.1.0', 'build      3', self.commit, 'source     on github/ipad/main',
                     'ITSAppUsesNonExemptEncryption  false', 'encryption check  no encryption library',
                     'Nothing sent', '--upload-build 3'):
            self.assertIn(text, result.stdout)

    def test_key_and_check_agree(self):
        """ROUND5 8M, E4: false with no library, absent with one; anything else is refused."""
        del self.info['ITSAppUsesNonExemptEncryption']
        self.write_info()
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertIn('no encryption library in the program, but ITSAppUsesNonExemptEncryption is (absent)',
                      result.stdout)
        crypto = LIBDIR / 'ssl/lib/libcrypto.a'
        if not crypto.is_file():
            self.skipTest('No prebuilt OpenSSL at ' + str(crypto))
        ios_program(self.app / 'Blender', OPENSSL_PROGRAM, crypto)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('ITSAppUsesNonExemptEncryption  (absent)', result.stdout)
        self.assertIn('encryption check  encryption library present', result.stdout)
        self.info['ITSAppUsesNonExemptEncryption'] = False
        self.write_info()
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertIn('the program carries an encryption library, but ITSAppUsesNonExemptEncryption is false',
                      result.stdout)
        (self.app / 'Blender').unlink()
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertIn('the encryption check could not read the program', result.stdout)

    def test_refuses_a_wrong_build_number(self):
        for number in ('2', '30', ''):
            result = self.run_script('--upload-build', number) if number else self.run_script('--upload-build')
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('== upload', result.stdout)

    def test_refuses_a_commit_not_on_github(self):
        self.git('commit', '-q', '--allow-empty', '-m', 'local only')
        self.info['SatsumaSourceCommit'] = self.git('rev-parse', 'HEAD')
        self.write_info()
        result = self.run_script('--upload-build', '3')
        self.assertEqual(result.returncode, 1)
        self.assertIn("is not on github's ipad/main", result.stdout)

    def test_refuses_an_archive_other_than_the_settings(self):
        self.info['CFBundleVersion'] = '4'
        self.write_info()
        result = self.run_script('--upload-build', '4')
        self.assertEqual(result.returncode, 1)
        self.assertIn("the archive's build is 4, the settings say 3", result.stdout)

    def test_uploads_only_through_xcode_and_pushes_only_the_tag(self):
        text = self.SCRIPT.read_text()
        self.assertIn('<key>destination</key><string>upload</string>', text)
        self.assertIn('<key>method</key><string>app-store-connect</string>', text)
        pushes = [line.strip() for line in text.splitlines() if 'push' in line and line.strip().startswith('git ')]
        self.assertEqual(pushes, ['git -C "$checkout" push "$REMOTE" "refs/tags/$tag"'])
        for word in ('altool', 'iTMSTransporter', 'curl'):
            self.assertNotIn(word, text)


class ModuleLoaderTest(unittest.TestCase):
    """A library that loads its own modules at run time finds them as frameworks (2026-11-18)."""

    def test_loader_without_framework_lookup(self):
        from prepare_testflight import module_loader_problems
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / 'App.app'
            binary = app / 'Frameworks/OpenImageDenoise_core.framework/OpenImageDenoise_core'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'\0oidn_init_module_\0@rpath/OpenImageDenoise_core.framework/OpenImageDenoise_core\0')
            self.assertEqual(len(module_loader_problems(app)), 1)
            binary.write_bytes(b'\0oidn_init_module_\0.framework/\0')
            self.assertEqual(module_loader_problems(app), [])


class IdentityTest(unittest.TestCase):
    """ROUND5 8A/8B: the iPad app's template names the configured identity and icon, not Blender's."""
    ROOT = Path(__file__).resolve().parents[2]

    def test_info_plist_template(self):
        text = (self.ROOT / 'release/ios/Blender.app/Info.plist').read_text()
        info = plistlib.loads(text.encode())
        self.assertEqual(info['CFBundleName'], '${IOS_PRODUCT_NAME}')
        self.assertEqual(info['CFBundleDisplayName'], '${IOS_PRODUCT_NAME}')
        for key in ('SatsumaBlenderVersion', 'SatsumaSourceURL', 'SatsumaSourceCommit'):
            self.assertIn(key, info)
        for key in ('CFBundleIcons', 'CFBundleIcons~ipad'):
            self.assertEqual(info[key]['CFBundlePrimaryIcon']['CFBundleIconName'], '${IOS_APP_ICON_NAME}')
        self.assertNotIn('liquid_glass', text)

    def test_icon_is_the_apps(self):
        cmake = (self.ROOT / 'source/creator/CMakeLists.txt').read_text()
        self.assertIn('release/ios/satsuma.icon CACHE PATH', cmake)
        self.assertIn('set(IOS_APP_ICON_NAME satsuma CACHE STRING', cmake)
        self.assertNotIn('blender_logo_mono.svg\n    )', cmake)
        self.assertFalse((self.ROOT / 'release/ios/platypus.icon').exists())
        icon = self.ROOT / 'release/ios/satsuma.icon'
        document = json.loads((icon / 'icon.json').read_text())
        for layer in (icon / 'Assets').iterdir():
            self.assertNotIn('Blender', layer.name)
        # Every layer the document names is in it, and every file in it is a layer: the icon
        # compiler leaves a missing layer out without failing.
        named = {layer['image-name'] for group in document['groups'] for layer in group['layers']}
        self.assertEqual(named, {layer.name for layer in (icon / 'Assets').iterdir()})

    def test_versions_kept_apart(self):
        """The app's version (`CFBundleShortVersionString`, 0.1.0) is not Blender's (5.1.2).

        Only About shows the app's version; everything that needs Blender's (templates'
        `minimumBlender`) reads it as compiled. When the template check read the app's version,
        every template was refused: no Choose a Template, no Start Creating, no check document.
        """
        readers = sorted(
            str(path.relative_to(self.ROOT))
            for folder in ('source/blender/windowmanager', 'intern/ghost', 'scripts/startup')
            for path in (self.ROOT / folder).rglob('*')
            if path.suffix in ('.mm', '.m', '.cc', '.hh', '.h', '.swift', '.py') and path.is_file()
            and 'CFBundleShortVersionString' in path.read_text(errors='replace'))
        self.assertEqual(readers, ['source/blender/windowmanager/apple_ios/swift/AppIdentity.swift'])
        header = (self.ROOT / 'source/blender/blenkernel/BKE_blender_version.h').read_text()
        number = lambda name: int(re.search(rf'#define {name} (\d+)', header).group(1))
        blender = [number('BLENDER_VERSION') // 100, number('BLENDER_VERSION') % 100,
                   number('BLENDER_VERSION_PATCH')]
        manifests = [self.ROOT / 'release/ios/templates/library/manifest.json']
        installed = self.ROOT.parent / 'build_ios_device/bin/Blender.app/Assets'
        manifests += sorted(installed.glob('*/datafiles/templates/manifest.json'))
        for manifest in manifests:
            templates = json.loads(manifest.read_text())['templates']
            self.assertTrue(templates, manifest)
            for template in templates:
                self.assertLessEqual(template['minimumBlender'], blender, (manifest, template['id']))

    def test_privacy_manifest(self):
        """ROUND5 8D: the app's manifest tracks nothing, collects nothing, and names only Apple's reasons."""
        from required_reason_apis import REASONS
        manifest = plistlib.loads((self.ROOT / 'release/ios/PrivacyInfo.xcprivacy').read_bytes())
        self.assertIs(manifest['NSPrivacyTracking'], False)
        self.assertEqual(manifest['NSPrivacyTrackingDomains'], [])
        self.assertEqual(manifest['NSPrivacyCollectedDataTypes'], [])
        for entry in manifest['NSPrivacyAccessedAPITypes']:
            reasons = entry['NSPrivacyAccessedAPITypeReasons']
            self.assertTrue(reasons and set(reasons) <= REASONS[entry['NSPrivacyAccessedAPIType']], entry)
        # ROUND5 8I.5: the free-space check before saving makes Apple's E174.1 true, and declared.
        declared = {entry['NSPrivacyAccessedAPIType']: entry['NSPrivacyAccessedAPITypeReasons']
                    for entry in manifest['NSPrivacyAccessedAPITypes']}
        self.assertEqual(declared.get('NSPrivacyAccessedAPICategoryDiskSpace'), ['E174.1'])

    def test_installed_app(self):
        """The app Xcode last built, when there is one beside the checkout (`deploy_ipad.sh`'s)."""
        app = self.ROOT.parent / 'build_ios_device/bin/Release/Blender.app'
        if not (app / 'Info.plist').is_file():
            self.skipTest('No installed iPad app at ' + str(app))
        check_artwork(app)
        self.assertEqual(self.encryption_check(app / 'Blender'), self.expected_check(app))

    def encryption_check(self, path):
        """ROUND5 8M, E1: the check's exit status on a built program (0: none, 1: present)."""
        return subprocess.run([sys.executable, '-B', str(self.ROOT / 'release/ios/check_no_encryption_library.py'),
                               str(path)], capture_output=True, text=True).returncode

    def expected_check(self, app):
        """0 unless the build directory the app came from links OpenSSL (`WITH_PLATYPUS_PYTHON_OPENSSL`)."""
        build = next(parent for parent in app.parents if (parent / 'CMakeCache.txt').is_file())
        return 1 if 'WITH_PLATYPUS_PYTHON_OPENSSL:BOOL=ON' in (build / 'CMakeCache.txt').read_text() else 0

    def test_prepared_apps(self):
        """ROUND5 8F.2: the prepared apps beside the checkout, when there are any: the development
        one (`build_ios_device/prepared`) and the tester one `build_testflight.sh` makes."""
        apps = [self.ROOT.parent / folder / 'prepared/Blender.app'
                for folder in ('build_ios_device', 'build_ios_testflight')]
        apps = [app for app in apps if (app / 'Info.plist').is_file()]
        if not apps:
            self.skipTest('No prepared iPad app beside the checkout')
        for app in apps:
            with self.subTest(app=str(app)):
                self.assertEqual(check_prepared(app), [])
                self.assertEqual(check_icons(app), [])
                self.assertEqual(scan(app)[1], [])
                check_artwork(app)
                numpy = sorted((app / 'Frameworks').glob('numpy.*.framework'))
                self.assertEqual(len(numpy), 19)
                self.assertEqual(len(list(app.rglob('*.fwork'))), len(numpy))
                status = self.encryption_check(app)
                self.assertEqual(status, self.expected_check(app))
                if 'build_ios_testflight' in app.parts:
                    # ROUND5 8M, E4: the key is false exactly when the check finds no library.
                    info = plistlib.loads((app / 'Info.plist').read_bytes())
                    self.assertEqual(info.get('ITSAppUsesNonExemptEncryption', 'absent'),
                                     False if status == 0 else 'absent')


if __name__ == '__main__':
    unittest.main()
