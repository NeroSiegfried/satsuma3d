# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Exercise distribution packaging with real iOS Mach-O dependencies."""

import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# The scripts under test are release tools, in `release/ios`.
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "release" / "ios"))

from archive_testflight import APP_ENTITLEMENTS, signing_entitlements
from check_numpy_replacements import check as check_replacements
from prepare_testflight import check_artwork, check_prepared, dependencies, macho_type, prepare
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

    def run_with(self, settings):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'testflight.env'
            path.write_text(settings)
            return subprocess.run(['bash', str(self.SCRIPT), str(path)], capture_output=True, text=True,
                                  timeout=60)

    def test_refuses_the_development_identity_and_a_missing_source(self):
        result = self.run_with('BUNDLE_ID=app.example.dev\n')
        self.assertEqual(result.returncode, 1)
        self.assertIn("ends in .dev", result.stderr)
        result = self.run_with('SOURCE_URL=\n')
        self.assertEqual(result.returncode, 1)
        self.assertIn('must name its source', result.stderr)


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
        self.assertIn('release/ios/platypus.icon CACHE PATH', cmake)
        self.assertIn('set(IOS_APP_ICON_NAME platypus CACHE STRING', cmake)
        self.assertNotIn('blender_logo_mono.svg\n    )', cmake)
        icon = self.ROOT / 'release/ios/platypus.icon'
        self.assertTrue((icon / 'icon.json').is_file())
        for layer in (icon / 'Assets').iterdir():
            self.assertNotIn('Blender', layer.name)

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
                self.assertEqual(scan(app)[1], [])
                check_artwork(app)
                numpy = sorted((app / 'Frameworks').glob('numpy.*.framework'))
                self.assertEqual(len(numpy), 19)
                self.assertEqual(len(list(app.rglob('*.fwork'))), len(numpy))


if __name__ == '__main__':
    unittest.main()
