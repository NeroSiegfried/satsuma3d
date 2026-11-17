# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Run via --factory-startup --python-expr in the prepared (framework layout) app, signed for development.

Checks the same framework packaging used by TestFlight: NumPy imports from its frameworks,
OpenImageDenoise loads, Blender saves, renders, and exports the default cube to glTF (which uses
NumPy). Never run against a user's open scene: it works in the factory startup scene, and stops
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
        factory_scene('end')
        report['success'] = True
    except Exception:
        report['error'] = traceback.format_exc()
    (output / 'testflight-device-test.json').write_text(json.dumps(report, indent=2))
    print('TESTFLIGHT_DEVICE_TEST ' + json.dumps(report), flush=True)


main()
