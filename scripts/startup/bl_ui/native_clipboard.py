# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Copy and Paste of mesh geometry in Edit Mode, for the native iPad interface.

Desktop Blender copies whole objects (Ctrl+C in Object Mode) and copies geometry with Duplicate.
On a tablet, copying part of one mesh and pasting it into another, or stacking copies with Paste
and Repeat Last, is how a figure is measured out in head heights. What is copied is held in
memory only, with its positions in world space: nothing is written into the file, and it is
forgotten when another file opens.

Paste continues into a move (`mesh.native_paste_move`), as Duplicate does, so a copy never lands
unseen on its original, and Repeat Last repeats the paste and its move together.
"""

import bmesh
import bpy
from bpy.app.handlers import persistent

# The copied geometry, in world space, and the material of each of its material indices.
_clipboard = {"bm": None, "materials": [], "verts": 0}


def has_copy():
    return _clipboard["bm"] is not None


def clear():
    bm = _clipboard["bm"]
    if bm is not None:
        bm.free()
    _clipboard.update(bm=None, materials=[], verts=0)


def _selected_copy(bm):
    """A copy of ``bm`` holding only what is selected."""
    copy = bm.copy()
    faces = [f for f in copy.faces if not f.select]
    if faces:
        bmesh.ops.delete(copy, geom=faces, context='FACES_ONLY')
    edges = [e for e in copy.edges if not e.select]
    if edges:
        bmesh.ops.delete(copy, geom=edges, context='EDGES_FACES')
    verts = [v for v in copy.verts if not v.select]
    if verts:
        bmesh.ops.delete(copy, geom=verts, context='VERTS')
    return copy


def copy_selected(ob):
    """Copy the selected geometry of ``ob``, in Edit Mode. Returns the number of vertices."""
    bm = bmesh.from_edit_mesh(ob.data)
    copy = _selected_copy(bm)
    if not copy.verts:
        copy.free()
        return 0
    bmesh.ops.transform(copy, matrix=ob.matrix_world, verts=copy.verts[:])
    clear()
    _clipboard.update(bm=copy, materials=[slot.material for slot in ob.material_slots], verts=len(copy.verts))
    return len(copy.verts)


def _material_index(ob, material, cache):
    """The index of ``material`` in ``ob``'s slots, adding a slot for it where there is none."""
    if material in cache:
        return cache[material]
    for index, slot in enumerate(ob.material_slots):
        if slot.material == material:
            cache[material] = index
            return index
    if material is None:
        cache[material] = 0
        return 0
    ob.data.materials.append(material)
    cache[material] = len(ob.material_slots) - 1
    return cache[material]


def paste(ob):
    """Add the copied geometry to ``ob``'s mesh in Edit Mode, where it was in the world; only the
    pasted geometry is left selected. Returns the number of vertices."""
    source = _clipboard["bm"]
    if source is None:
        return 0
    me = ob.data
    copy = source.copy()
    bmesh.ops.transform(copy, matrix=ob.matrix_world.inverted_safe(), verts=copy.verts[:])
    # Materials by material, not by slot number: the target may order its slots otherwise.
    cache = {}
    materials = _clipboard["materials"]
    for face in copy.faces:
        material = materials[face.material_index] if face.material_index < len(materials) else None
        face.material_index = _material_index(ob, material, cache)
    for element in (*copy.verts, *copy.edges, *copy.faces):
        element.select = True
    temporary = bpy.data.meshes.new("Paste")
    try:
        copy.to_mesh(temporary)
        bm = bmesh.from_edit_mesh(me)
        for element in (*bm.verts, *bm.edges, *bm.faces):
            element.select = False
        bm.from_mesh(temporary)
        bm.select_flush_mode()
        bmesh.update_edit_mesh(me, loop_triangles=True, destructive=True)
    finally:
        copy.free()
        bpy.data.meshes.remove(temporary)
    return _clipboard["verts"]


class MESH_OT_native_copy(bpy.types.Operator):
    """Copy the selected geometry, to paste into this mesh or another"""

    bl_idname = "mesh.native_copy"
    bl_label = "Copy"
    bl_options = {'REGISTER'}

    @classmethod
    def poll(cls, context):
        ob = context.edit_object
        return ob is not None and ob.type == 'MESH' and ob.data.total_vert_sel > 0

    def execute(self, context):
        count = copy_selected(context.edit_object)
        if not count:
            self.report({'WARNING'}, "Nothing selected to copy")
            return {'CANCELLED'}
        self.report({'INFO'}, "Copied {:d} {:s}".format(count, "vertex" if count == 1 else "vertices"))
        return {'FINISHED'}


class MESH_OT_native_paste(bpy.types.Operator):
    """Paste the copied geometry, where it was copied from"""

    bl_idname = "mesh.native_paste"
    bl_label = "Paste"
    bl_options = {'REGISTER', 'UNDO'}

    @classmethod
    def poll(cls, context):
        ob = context.edit_object
        if ob is None or ob.type != 'MESH':
            return False
        if not has_copy():
            cls.poll_message_set("Nothing copied yet")
            return False
        return True

    def execute(self, context):
        if not paste(context.edit_object):
            return {'CANCELLED'}
        return {'FINISHED'}


class MESH_OT_native_paste_move(bpy.types.Macro):
    """Paste the copied geometry and move it"""

    bl_idname = "mesh.native_paste_move"
    bl_label = "Paste"
    bl_options = {'REGISTER', 'UNDO'}


@persistent
def _load_post(_filepath):
    # Materials of another file are gone; so is what was copied from it.
    clear()


classes = (
    MESH_OT_native_copy,
    MESH_OT_native_paste,
)


def register():
    """After `classes`: the macro, which `bl_ui` cannot unregister with them (a macro has no
    `is_registered`), and its steps."""
    bpy.utils.register_class(MESH_OT_native_paste_move)
    MESH_OT_native_paste_move.define("MESH_OT_native_paste")
    MESH_OT_native_paste_move.define("TRANSFORM_OT_translate")
    if _load_post not in bpy.app.handlers.load_post:
        bpy.app.handlers.load_post.append(_load_post)


def unregister():
    if hasattr(bpy.types, "MESH_OT_native_paste_move"):
        bpy.utils.unregister_class(MESH_OT_native_paste_move)
    if _load_post in bpy.app.handlers.load_post:
        bpy.app.handlers.load_post.remove(_load_post)
    clear()
