# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Run via --factory-startup --python-expr in the prepared (framework layout) app, signed for development.

Checks the same framework packaging used by TestFlight: NumPy imports from its frameworks,
OpenImageDenoise loads, Blender saves, renders, and exports the default cube to glTF (which uses
NumPy). Seventh (ROUND5 8M, E2/E3): the app carries no OpenSSL, so `hashlib` gives the right
digests from Python's own hashes (MD5, SHA-1, SHA-2, SHA-3, BLAKE2), `hmac` too, the asset system's
file hash service hashes a file, `import ssl` raises `ImportError`, `_hashlib` is absent, an `https`
request fails with Python's own error, and the default cube goes out to FBX and back in (the FBX
importer hashes with SHA-1). Never run against a user's open scene: it works in the factory startup scene, and stops
if a document is opened under it.

Everything it writes goes to `tmp/testflight-check/` in the app's container, not `Documents`: with
a free team the only app this can run in is the owner's development app (`app.platypus3d.dev`),
whose Documents the owner sees in Files. The `.blend` is saved as a copy, so Blender's recent-files
list is not touched. The report is `tmp/testflight-check/testflight-device-test.json`, also printed
as one line starting `TESTFLIGHT_DEVICE_TEST`. Launch with `PLATYPUS_SCRATCH_DOCUMENT=1` in the
environment, so the launcher opens a scratch copy instead of the owner's last document (see
`wm_apple_ios_launcher.mm`). The exact commands are in `release/ios/README.md`.
"""

import ctypes
import importlib
import json
from pathlib import Path
import sys
import traceback

import bpy


def main():
    report = {'checks': [], 'success': False}
    output = Path.home() / 'tmp' / 'testflight-check'
    output.mkdir(parents=True, exist_ok=True)
    bundle = Path(bpy.app.binary_path).parent

    def factory_scene(step):
        # The launcher may open a document while this runs; never work in one.
        assert bpy.data.filepath == '', f'{step}: a document is open ({bpy.data.filepath}), stopped'

    try:
        factory_scene('start')
        assert Path(sys.executable).parent == bundle, sys.executable
        report['checks'].append('Python resolves frameworks relative to the app bundle')
        import numpy as np
        frameworks = sorted((bundle / 'Frameworks').glob('numpy.*.framework'))
        assert frameworks, 'No NumPy frameworks found'
        for framework in frameworks:
            module = importlib.import_module(framework.stem)
            assert str(module.__file__).endswith('.fwork'), module.__file__
        report['checks'].append(f'Imported all {len(frameworks)} NumPy frameworks')
        np.testing.assert_allclose(np.linalg.solve([[2.0, 0.0], [0.0, 4.0]], [6.0, 8.0]), [3.0, 2.0])
        np.testing.assert_allclose(np.fft.ifft(np.fft.fft([1.0, 2.0, 3.0])), [1.0, 2.0, 3.0])
        assert np.random.default_rng(42).integers(0, 10, size=4).shape == (4,)
        report['checks'].append('NumPy linear algebra, FFT and random generation work')
        oidn = ctypes.CDLL(str(bundle / 'Frameworks/OpenImageDenoise.framework/OpenImageDenoise'))
        oidn.oidnNewDevice.argtypes = [ctypes.c_int]
        oidn.oidnNewDevice.restype = ctypes.c_void_p
        oidn.oidnCommitDevice.argtypes = [ctypes.c_void_p]
        oidn.oidnGetDeviceError.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_char_p)]
        oidn.oidnGetDeviceError.restype = ctypes.c_int
        oidn.oidnReleaseDevice.argtypes = [ctypes.c_void_p]
        device = oidn.oidnNewDevice(0)
        assert device, 'Could not create the OpenImageDenoise device'
        try:
            oidn.oidnCommitDevice(device)
            message = ctypes.c_char_p()
            error = oidn.oidnGetDeviceError(device, ctypes.byref(message))
            assert error == 0, (error, message.value)
        finally:
            oidn.oidnReleaseDevice(device)
        report['checks'].append('OpenImageDenoise loads and initializes its Metal framework')
        factory_scene('save')
        scene = bpy.context.scene
        scene.render.resolution_x = 64
        scene.render.resolution_y = 64
        scene.render.resolution_percentage = 100
        scene.render.filepath = str(output / 'testflight-render.png')
        # A copy: the scene stays unsaved, so the recent-files list is not written.
        bpy.ops.wm.save_as_mainfile(filepath=str(output / 'testflight-check.blend'), copy=True)
        assert (output / 'testflight-check.blend').stat().st_size > 0
        bpy.ops.render.render(write_still=True)
        assert (output / 'testflight-render.png').stat().st_size > 0
        report['checks'].append('Blender saves a scene and renders an image')
        factory_scene('glTF export')
        assert 'Cube' in bpy.data.objects, 'No default cube in the factory scene'
        import addon_utils
        addon_utils.enable('io_scene_gltf2', default_set=False)
        glb = output / 'testflight-cube.glb'
        bpy.ops.export_scene.gltf(filepath=str(glb), export_format='GLB')
        data = glb.read_bytes()
        assert data[:4] == b'glTF', data[:4]
        chunk = int.from_bytes(data[12:16], 'little')
        document = json.loads(data[20:20 + chunk])
        assert [node.get('name') for node in document['nodes']].count('Cube') == 1, document['nodes']
        assert document['meshes'][0]['primitives'][0]['attributes']['POSITION'] is not None
        report['checks'].append(f'Exported the default cube to glTF ({len(data)} bytes)')
        factory_scene('hashes without OpenSSL')
        report['checks'].append(check_no_openssl(output))
        factory_scene('end')
        report['success'] = True
    except Exception:
        report['error'] = traceback.format_exc()
    (output / 'testflight-device-test.json').write_text(json.dumps(report, indent=2))
    print('TESTFLIGHT_DEVICE_TEST ' + json.dumps(report), flush=True)


# Digests of b'abc' (and HMAC-SHA256 of the usual sentence with key b'key'), from Python on the Mac.
KNOWN_DIGESTS = {
    'md5': '900150983cd24fb0d6963f7d28e17f72',
    'sha1': 'a9993e364706816aba3e25717850c26c9cd0d89d',
    'sha224': '23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7',
    'sha256': 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    'sha384': 'cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed'
              '8086072ba1e7cc2358baeca134c825a7',
    'sha512': 'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a'
              '2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f',
    'sha3_256': '3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532',
    'sha3_512': 'b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e'
                '10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0',
    'blake2b': 'ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1'
               '7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923',
    'blake2s': '508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982',
}
KNOWN_HMAC = 'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8'


def check_no_openssl(output):
    """ROUND5 8M: hashing whole on Python's own hashes; no TLS; FBX out and in."""
    import hashlib
    import hmac
    for name, digest in KNOWN_DIGESTS.items():
        assert hashlib.new(name, b'abc').hexdigest() == digest, name
        assert getattr(hashlib, name)(b'abc', usedforsecurity=False).hexdigest() == digest, name
    assert hashlib.shake_128(b'abc').hexdigest(16) == '5881092dd818bf5cf8a3ddb793fbcba7'
    assert hmac.new(b'key', b'The quick brown fox jumps over the lazy dog', 'sha256').hexdigest() == KNOWN_HMAC
    assert hmac.compare_digest(KNOWN_HMAC, KNOWN_HMAC)
    assert not hasattr(hashlib, 'pbkdf2_hmac') and not hasattr(hashlib, 'scrypt'), 'OpenSSL-only functions present'
    assert '_hashlib' not in sys.builtin_module_names and '_ssl' not in sys.builtin_module_names, \
        sys.builtin_module_names
    for name in ('_hashlib', '_ssl', 'ssl'):
        try:
            importlib.import_module(name)
        except ImportError:
            pass
        else:
            raise AssertionError(f'import {name} succeeded')
    import urllib.error
    import urllib.request
    try:
        urllib.request.urlopen('https://localhost.invalid/', timeout=1)
    except urllib.error.URLError as error:
        assert 'unknown url type: https' in str(error), error
    else:
        raise AssertionError('an https request did not fail')
    sample = output / 'hash-sample.bin'
    sample.write_bytes(b'abc')
    from _bpy_internal.disk_file_hash_service import get_service
    assert get_service(output / 'hash-cache').get_hash(sample, 'sha256') == KNOWN_DIGESTS['sha256']
    import addon_utils
    addon_utils.enable('io_scene_fbx', default_set=False)
    fbx = output / 'testflight-cube.fbx'
    before = set(bpy.data.objects)
    # The mesh only: Blender 5.1's FBX importer fails on a light (`lamp.cycles.cast_shadow`,
    # `import_fbx.py`), with or without OpenSSL (2026-11-19).
    bpy.ops.export_scene.fbx(filepath=str(fbx), use_selection=False, object_types={'MESH'})
    assert fbx.stat().st_size > 0
    bpy.ops.import_scene.fbx(filepath=str(fbx))
    imported = [obj for obj in bpy.data.objects if obj not in before and obj.type == 'MESH']
    assert len(imported) == 1 and len(imported[0].data.vertices) == 8, imported
    return (f'Without OpenSSL: {len(KNOWN_DIGESTS)} hashes and HMAC give known digests, the file hash '
            f'service hashes, no ssl or _hashlib, https fails with URLError; FBX out ({fbx.stat().st_size} '
            f'bytes) and back in')


main()
