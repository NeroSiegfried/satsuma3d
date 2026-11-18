# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""What the native interface shows after each command, see `bl_ui.native_reveal`: every
registered operator is classified, and those that add or make something must have a rule."""
import collections
import json

import bpy
from bl_ui import native_reveal as reveal

checks = []


def check(ok, name):
    assert ok, name
    checks.append(name)


def shows(idname, call=""):
    rule = reveal.classify(idname, call)
    return rule.show if rule else "DEFAULT"


# 1. Every operator, classified; those that make something have a rule of their own.
KEYWORDS = ("_add", "_new", "_assign", "_bake", "_unwrap", "_project", "_apply", "_import", "_append", "_link",
            "_duplicate", "_hide", "_convert", "_join", "_separate", "_bind", "_generate")
operators = [module + "." + name for module in dir(bpy.ops) for name in dir(getattr(bpy.ops, module))]
check(len(operators) > 1000, "Operators enumerated: %d" % len(operators))
unruled = [idname for idname in operators if reveal.classify(idname) is None]
check(not [idname for idname in unruled if any(key in idname for key in KEYWORDS)],
      "Every operator that makes something has a rule: %s" % unruled)
check(not unruled, "Every operator has a rule: %s" % unruled)
for rule in reveal.RULES:
    check(rule.show != "none" or rule.why, "A rule showing nothing says why: " + rule.pattern.pattern[:40])

# 2. The plan's table (ROUND5.md, Stage 2A).
TABLE = {
    ("object.modifier_add", "type='SUBSURF'"): "properties:MODIFIER",
    ("object.modifier_add", "type='NODES'"): "editor:geometry_nodes",
    ("object.modifier_add", "type='CLOTH'"): "properties:PHYSICS",
    ("object.modifier_add", "type='FLUID'"): "properties:PHYSICS",
    ("object.native_modifier_toggle", ""): "properties:MODIFIER",
    ("object.modifier_copy", ""): "properties:MODIFIER",
    ("object.subdivision_set", ""): "properties:MODIFIER",
    ("object.multires_subdivide", ""): "properties:MODIFIER",
    ("object.quick_fur", ""): "properties:MODIFIER",
    ("object.quick_explode", ""): "properties:MODIFIER",
    ("object.quick_smoke", ""): "properties:PHYSICS",
    ("object.quick_liquid", ""): "properties:PHYSICS",
    ("object.forcefield_toggle", ""): "properties:PHYSICS",
    ("rigidbody.object_add", ""): "properties:PHYSICS",
    ("rigidbody.objects_add", ""): "properties:PHYSICS",
    ("rigidbody.constraint_add", ""): "properties:PHYSICS",
    ("node.new_geometry_nodes_modifier", ""): "editor:geometry_nodes",
    ("object.shaderfx_add", ""): "properties:SHADERFX",
    ("object.constraint_add", ""): "properties:CONSTRAINT",
    ("object.constraint_add_with_targets", ""): "properties:CONSTRAINT",
    ("object.track_set", ""): "properties:CONSTRAINT",
    ("pose.constraint_add", ""): "properties:BONE_CONSTRAINT",
    ("pose.ik_add", ""): "properties:BONE_CONSTRAINT",
    ("object.material_slot_add", ""): "properties:MATERIAL",
    ("material.new", ""): "properties:MATERIAL",
    ("object.vertex_group_add", ""): "properties:DATA",
    ("object.vertex_group_assign_new", ""): "properties:DATA",
    ("object.shape_key_add", ""): "properties:DATA",
    ("mesh.uv_texture_add", ""): "properties:DATA",
    ("geometry.attribute_add", ""): "properties:DATA",
    ("geometry.color_attribute_add", ""): "properties:DATA",
    ("object.particle_system_add", ""): "properties:PARTICLES",
    ("world.new", ""): "properties:WORLD",
    ("texture.new", ""): "properties:TEXTURE",
    ("object.light_add", ""): "properties_if_open:DATA",
    ("object.camera_add", ""): "properties_if_open:DATA",
    ("object.text_add", ""): "properties_if_open:DATA",
    ("object.speaker_add", ""): "properties_if_open:DATA",
    ("object.lightprobe_add", ""): "properties_if_open:DATA",
    # ROUND5 9B.4: what makes or lays out a UV map shows the UV Editor; the rest keeps the settings.
    ("uv.unwrap", ""): "editor:uv",
    ("uv.smart_project", ""): "editor:uv",
    ("uv.cube_project", ""): "editor:uv",
    ("uv.cylinder_project", ""): "editor:uv",
    ("uv.sphere_project", ""): "editor:uv",
    ("uv.project_from_view", ""): "editor:uv",
    ("uv.lightmap_pack", ""): "editor:uv",
    ("uv.reset", ""): "editor:uv",
    ("uv.follow_active_quads", ""): "editor:uv",
    ("uv.pack_islands", ""): "editor:uv",
    ("uv.average_islands_scale", ""): "editor:uv",
    ("uv.minimize_stretch", ""): "editor:uv",
    ("uv.stitch", ""): "operation",
    ("uv.weld", ""): "operation",
    ("uv.mark_seam", ""): "operation",
    ("object.bake", ""): "editor:image",
    ("object.bake_image", ""): "editor:image",
    ("image.new", ""): "editor:image",
    ("image.open", ""): "editor:image",
    ("paint.add_texture_paint_slot", ""): "editor:image",
    ("anim.keyframe_insert", ""): "message",
    ("anim.keyframe_insert_menu", ""): "message",
    ("anim.keyframe_delete", ""): "message",
    ("render.render", ""): "render",
    ("render.opengl", ""): "render",
    ("object.hide_view_set", ""): "message",
    ("mesh.hide", ""): "message",
    ("ed.undo", ""): "message",
    ("ed.redo", ""): "message",
    ("object.join", ""): "operation",
    ("object.parent_set", ""): "operation",
    ("object.parent_clear", ""): "operation",
    ("collection.create", ""): "operation",
    ("object.move_to_collection", ""): "operation",
    ("wm.append", ""): "message",
    ("wm.link", ""): "message",
    ("wm.obj_import", ""): "message",
    ("view3d.rotate", ""): "none",
    ("view3d.select", ""): "none",
    ("view3d.select_box", ""): "none",
    ("sculpt.brush_stroke", ""): "none",
    ("object.mode_set", ""): "none",
    ("mesh.subdivide", ""): "operation",
    ("mesh.extrude_region_move", ""): "operation",
    ("mesh.duplicate_move", ""): "operation",
    ("mesh.native_paste_move", ""): "operation",
    ("transform.translate", ""): "operation",
}
for (idname, call), expected in TABLE.items():
    check(shows(idname, call) == expected, "%s %s shows %s, not %s" % (idname, call, expected, shows(idname, call)))

check(shows("wm.tool_set_by_id", 'bpy.ops.wm.tool_set_by_id(name="builtin.primitive_cube_add")') == "message",
      "An Add tool says how it is used")
check(shows("wm.tool_set_by_id", 'bpy.ops.wm.tool_set_by_id(name="builtin.move")') == "none",
      "Other tools show in the toolbar")

# 3. The bridge's form of the answer.
answer = reveal.after_operator(bpy.context, "OBJECT_OT_hide_view_set", "bpy.ops.object.hide_view_set()",
                               "Hide Selected")
check(answer["show"] == "message" and answer["text"] == "Hide Selected" and answer["button"].endswith(
    "action:object.reveal"), "Hide offers Reveal: %s" % answer)

# 4. Commands acting onto the active object say when they had nothing to act on (the owner's
# Parent with Automatic Weights with only the armature selected), and where parenting to an
# armature put its results.
for ob in list(bpy.data.objects):
    bpy.data.objects.remove(ob)
mesh = bpy.data.objects.new("Body", bpy.data.meshes.new("Body"))
rig = bpy.data.objects.new("Rig", bpy.data.armatures.new("Rig"))
for ob in (mesh, rig):
    bpy.context.scene.collection.objects.link(ob)
layer = bpy.context.view_layer
layer.objects.active = rig
rig.select_set(True)
mesh.select_set(False)
for idname in reveal.TO_ACTIVE:
    answer = reveal.after_operator(bpy.context, idname, "bpy.ops.%s(type='ARMATURE_AUTO')" % idname)
    check(answer["show"] == "message" and answer["level"] == "warning" and "Extend" in answer["text"],
          "%s with nothing else selected warns: %s" % (idname, answer))
mesh.select_set(True)
answer = reveal.after_operator(bpy.context, "OBJECT_OT_parent_set", "bpy.ops.object.parent_set(type='ARMATURE_AUTO')")
check(answer["level"] == "info" and "Body parented to Rig with automatic weights" in answer["text"] and
      "Modifiers" in answer["text"] and "Object Data" in answer["text"], "Automatic weights says where: %s" % answer)
check(reveal.after_operator(bpy.context, "OBJECT_OT_parent_set", "bpy.ops.object.parent_set(type='OBJECT')")["show"]
      == "operation", "Plain parenting keeps its settings")

# 5. The bridge evaluates `bl_ui.native_<name>....` after only `import bl_ui`: every such module it
# names must be loaded by `bl_ui` itself (native_reveal was not, so on the iPad it never ran).
import os
import re
import bl_ui
here = os.path.dirname(os.path.abspath(__file__))
bridge = os.path.join(here, "..", "..", "source", "blender", "windowmanager", "intern", "wm_native_ui.cc")
if os.path.exists(bridge):
    names = sorted(set(re.findall(r"bl_ui\.(native_[a-z_]+)", open(bridge, encoding="utf-8").read())))
    check(len(names) >= 5, "Bridge modules found: %s" % names)
    missing = [name for name in names if not hasattr(bl_ui, name)]
    check(not missing, "Every module the bridge calls is loaded by bl_ui: missing %s" % missing)

counts = collections.Counter(shows(idname) for idname in operators)
print("reveal: " + json.dumps(counts, sort_keys=True))
print('PASS: native reveal ' + json.dumps(checks[:4] + ["%d table rows" % len(TABLE)]))
