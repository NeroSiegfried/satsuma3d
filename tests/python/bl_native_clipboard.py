# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Copy and Paste of mesh geometry in Edit Mode, see `bl_ui.native_clipboard`, and Repeat Last
stacking copies, as a figure is measured out in head heights."""
import json

import bmesh
import bpy
from bl_ui import native_clipboard as clipboard

checks = []


def check(ok, name):
    assert ok, name
    checks.append(name)


def edit(ob):
    bpy.ops.object.mode_set(mode='OBJECT')
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.mode_set(mode='EDIT')


def selected_verts(ob):
    bm = bmesh.from_edit_mesh(ob.data)
    return [ob.matrix_world @ v.co for v in bm.verts if v.select]


bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.mesh.primitive_cube_add(location=(0, 0, 0))
cube = bpy.context.object
red = bpy.data.materials.new("Red")
cube.data.materials.append(red)
bpy.ops.mesh.primitive_plane_add(location=(5, 0, 0))
plane = bpy.context.object
bpy.ops.wm.save_as_mainfile(filepath=bpy.app.tempdir + "clipboard.blend")
check(not bpy.data.is_dirty, "Saved")

edit(cube)
bpy.ops.mesh.select_all(action='SELECT')
check(not bpy.ops.mesh.native_paste.poll(), "Nothing to paste before copying")
before = {d.name for d in bpy.data.meshes}
bpy.ops.mesh.native_copy()
check(clipboard.has_copy(), "Copy holds the selection")
check({d.name for d in bpy.data.meshes} == before, "Copy adds nothing to the file")
copied = sorted(tuple(round(c, 4) for c in v) for v in selected_verts(cube))

bpy.ops.mesh.native_paste()
bm = bmesh.from_edit_mesh(cube.data)
check(len(bm.verts) == 16, "Paste adds the eight vertices: %d" % len(bm.verts))
check(sum(v.select for v in bm.verts) == 8, "Only what was pasted is selected")

# Into another object, at the same place in the world, its material kept.
edit(plane)
bpy.ops.mesh.native_paste()
pasted = sorted(tuple(round(c, 4) for c in v) for v in selected_verts(plane))
check(pasted == copied, "Pasted into another object, where it was in the world")
check(any(slot.material == red for slot in plane.material_slots), "The pasted faces' material came with them")
bm = bmesh.from_edit_mesh(plane.data)
red_index = [slot.material for slot in plane.material_slots].index(red)
check(all(f.material_index == red_index for f in bm.faces if f.select), "Pasted faces use that material")
bpy.ops.object.mode_set(mode='OBJECT')
check({d.name for d in bpy.data.meshes} == before, "Paste leaves no temporary mesh behind")

# Paste and move, then Repeat Last: evenly stacked copies.
edit(cube)
bpy.ops.mesh.select_all(action='DESELECT')
bm = bmesh.from_edit_mesh(cube.data)
bm.verts.ensure_lookup_table()
for v in bm.verts[:8]:
    v.select = True
bm.select_flush_mode()
bmesh.update_edit_mesh(cube.data)
bpy.ops.mesh.native_copy()
start = len(bmesh.from_edit_mesh(cube.data).verts)
bpy.ops.mesh.native_paste_move(TRANSFORM_OT_translate={"value": (0, 0, 2)})
check(len(bmesh.from_edit_mesh(cube.data).verts) == start + 8, "Paste and move adds a copy")
top = max(v[2] for v in selected_verts(cube))
check(abs(top - 3.0) < 1e-4, "The copy moved up by 2: top at %.3f" % top)

# The same stacking with Duplicate, as Repeat Last runs it (the macro's exec with its values).
bpy.ops.mesh.duplicate_move(TRANSFORM_OT_translate={"value": (0, 0, 2)})
bpy.ops.mesh.duplicate_move(TRANSFORM_OT_translate={"value": (0, 0, 2)})
top = max(v[2] for v in selected_verts(cube))
check(abs(top - 7.0) < 1e-4, "Duplicate and move twice more: top at %.3f" % top)

bpy.ops.object.mode_set(mode='OBJECT')
bpy.ops.wm.open_mainfile(filepath=bpy.app.tempdir + "clipboard.blend")
check(not clipboard.has_copy(), "Opening a file forgets what was copied")
print('PASS: native clipboard ' + json.dumps(checks))
