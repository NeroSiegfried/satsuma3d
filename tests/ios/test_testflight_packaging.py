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
from prepare_testflight import check_artwork, dependencies, macho_type, prepare


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
        with self.assertRaises(ValueError):
            prepare(self.app, output, {})

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


class IdentityTest(unittest.TestCase):
    """ROUND5 8A/8B: the iPad app's template names the configured identity and icon, not Blender's."""
    ROOT = Path(__file__).resolve().parents[2]

    def test_info_plist_template(self):
        text = (self.ROOT / 'release/ios/Blender.app/Info.plist').read_text()
        info = plistlib.loads(text.encode())
        self.assertEqual(info['CFBundleName'], '${IOS_PRODUCT_NAME}')
        self.assertEqual(info['CFBundleDisplayName'], '${IOS_PRODUCT_NAME}')
        for key in ('PlatypusBlenderVersion', 'PlatypusSourceURL', 'PlatypusSourceCommit'):
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

    def test_installed_app(self):
        """The app Xcode last built, when there is one beside the checkout (`deploy_ipad.sh`'s)."""
        app = self.ROOT.parent / 'build_ios_device/bin/Release/Blender.app'
        if not (app / 'Info.plist').is_file():
            self.skipTest('No installed iPad app at ' + str(app))
        check_artwork(app)


if __name__ == '__main__':
    unittest.main()
