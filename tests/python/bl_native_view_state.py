# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""A document's viewpoint survives saving and opening, see `bl_ui.native_view_state`. A background
run has no 3D View, so the view is a stand-in with the same attributes."""
import os
import tempfile
from types import SimpleNamespace

import bpy
from bl_ui import native_view_state as state

checks = []


def check(ok, name):
    assert ok, name
    checks.append(name)


def near(a, b):
    return all(abs(x - y) < 1e-5 for x, y in zip(a, b))


view = SimpleNamespace(view_location=(1.0, 2.0, 3.0), view_rotation=(0.7071, 0.7071, 0.0, 0.0),
                       view_distance=2.5, view_perspective='ORTHO')
space = SimpleNamespace(lens=35.0, clip_start=0.05, clip_end=500.0)
scene = bpy.context.scene
state.store(scene, space, view)

path = os.path.join(tempfile.mkdtemp(), "view_state.blend")
bpy.ops.wm.save_as_mainfile(filepath=path)
bpy.ops.wm.read_homefile(use_empty=True)
check(state.KEY not in bpy.context.scene, "A new file has no stored view")
bpy.ops.wm.open_mainfile(filepath=path)

opened = SimpleNamespace(view_location=(0, 0, 0), view_rotation=(1, 0, 0, 0), view_distance=10.0,
                         view_perspective='PERSP')
opened_space = SimpleNamespace(lens=50.0, clip_start=0.01, clip_end=1000.0)
check(state.apply(bpy.context.scene, opened_space, opened), "The stored view is applied")
check(near(opened.view_location, (1, 2, 3)) and near(opened.view_rotation, (0.7071, 0.7071, 0, 0)),
      "Location and rotation come back")
check(abs(opened.view_distance - 2.5) < 1e-5 and opened.view_perspective == 'ORTHO', "Distance and projection come back")
check(abs(opened_space.lens - 35) < 1e-5 and abs(opened_space.clip_end - 500) < 1e-3, "Lens and clipping come back")

camera_view = SimpleNamespace(**dict(vars(view), view_perspective='CAMERA'))
state.store(bpy.context.scene, space, camera_view)
bpy.context.scene.camera = None
check(state.apply(bpy.context.scene, opened_space, opened) and opened.view_perspective == 'PERSP',
      "Without a camera, a camera view opens in perspective")
check(not state.apply(bpy.data.scenes.new("Empty"), opened_space, opened), "A scene without one changes nothing")
check(not state.enabled, "Off outside the iPad")

print("native view state:", len(checks), "checks passed")
