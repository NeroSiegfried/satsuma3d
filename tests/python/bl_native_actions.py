# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Context action choices against real Blender scenes. Runs in background mode, so actions whose
operators need a 3D viewport (Hide, X-Ray) fail their poll here and are covered on the
device instead."""
import importlib.util
import json
from pathlib import Path
import bpy

path = Path(__file__).resolve().parents[2] / 'scripts/startup/bl_ui/native_actions.py'
spec = importlib.util.spec_from_file_location('native_actions_under_test', path)
actions = importlib.util.module_from_spec(spec)
spec.loader.exec_module(actions)
# The module under test registers its own operator when loaded this way.
if not hasattr(bpy.types, "OBJECT_OT_native_modifier_toggle"):
    for cls in actions.classes:
        bpy.utils.register_class(cls)
checks = []


def check(ok, name):
    assert ok, name
    checks.append(name)


def titles(tool="builtin.select_box"):
    return [item["title"] for item in actions.actions(bpy.context, tool)]


def palette(tool="builtin.select_box"):
    return actions.palette(bpy.context, tool)


def palette_items(tool="builtin.select_box"):
    return {item["action"]: item for group in palette(tool) for item in group["items"]}


def applies(action_id, tool="builtin.select_box"):
    return actions._BY_ID[action_id].applies(actions._State(bpy.context, tool))


import os


def tool_icon_exists(name):
    """A tool's icon, as the toolbar shows it: `ops.mesh.inset` and the like."""
    return os.path.exists(os.path.join(bpy.utils.system_resource('DATAFILES', path="icons"), name + ".dat"))


# The registry itself.
icons = bpy.types.UILayout.bl_rna.functions['prop'].parameters['icon'].enum_items.keys()
for action in actions.ACTIONS:
    try:
        action.operator().get_rna_type()
        exists = True
    except KeyError:
        exists = False
    check(exists, f"{action.op} exists ({action.id})")
    check(bool(action.icon), f"{action.id} has an icon, as the strip shows icons")
    check(action.icon in icons or (action.icon.startswith("ops.") and tool_icon_exists(action.icon)),
          f"{action.icon} is a Blender icon or tool icon")
    check(action.group in actions.GROUPS, f"{action.id} has a known group")
    check(action.destructive == (action.group == "Delete"), f"{action.id}: destructive exactly in Delete")
    if action.menu:
        check(hasattr(bpy.types, action.menu), f"{action.menu} is a menu")
check(len(actions._BY_ID) == len(actions.ACTIONS), "Action ids are unique")
check(not any("clear" in action.op and "_clear" in action.op for action in actions.ACTIONS if
              action.op.startswith("object.")), "No esoteric object transform clearing")
modes = set(bpy.types.Context.bl_rna.properties['mode'].enum_items.keys())
check(modes == set(actions.MODE_MENUS), "Every mode has a More... entry: " +
      str(sorted(modes ^ set(actions.MODE_MENUS))))
for mode, menu in actions.MODE_MENUS.items():
    check(menu is None or hasattr(bpy.types, menu), f"{mode}'s context menu {menu} exists")
for mode, fixed in actions._FIXED.items():
    check(all(item == "rename" or item in actions._BY_ID for item in fixed), f"{mode}'s fixed items exist")

# Object Mode, nothing selected.
cube = bpy.data.objects['Cube']
bpy.ops.object.select_all(action='DESELECT')
check(titles()[:2] == ["Select All", "Add"] and "Delete" not in titles(),
      "Nothing selected offers Select All and Add: " + str(titles()))
add = next(item for item in actions.actions(bpy.context, "") if item["action"] == "object.add")
check(add["menu"] == "VIEW3D_MT_add", "Add opens the Add menu natively")

# Object Mode, one mesh selected.
cube.select_set(True)
bpy.context.view_layer.objects.active = cube
strip = titles("builtin.move")
check(strip[0] == "Edit" and strip[-1] == "Delete", "A selected mesh leads with Edit, ends with Delete: " + str(strip))
check(strip.index("Duplicate") < strip.index("Shade Smooth") < strip.index("Subdivision") < strip.index("Mirror"),
      "The seed order for a selected mesh: " + str(strip))
check(titles()[:1] == ["Select All"] and "Duplicate" in titles(), "Selection tools lead with selecting")
check("Join" not in titles() and "Parent" not in titles(), "Join and Parent stay in the palette")
items = palette_items()
check(not items["object.join"]["enabled"] and not items["object.parent"]["enabled"],
      "One mesh dims Join and Parent in the palette")
check("Apply Scale" not in titles() and not items["object.apply_scale"]["enabled"],
      "Apply Scale only runs when the scale is not applied")
cube.scale = (2, 1, 1)
check("Apply Scale" in titles("builtin.scale"), "Unapplied scale offers Apply Scale")
cube.scale = (1, 1, 1)
groups = [group["group"] for group in palette()]
check(groups == [group for group in actions.GROUPS if group in groups] and groups[-1] == "Delete",
      "Palette groups follow the fixed order, Delete last: " + str(groups))

# Modifier toggles.
check(actions.run(bpy.context, "object.subdivision"), "Run the Subdivision toggle")
check(any(mod.type == 'SUBSURF' for mod in cube.modifiers), "Subdivision added")
check(palette_items()["object.subdivision"]["selected"], "Subdivision shows as on")
check(actions.run(bpy.context, "object.subdivision"), "Run the Subdivision toggle again")
check(not any(mod.type == 'SUBSURF' for mod in cube.modifiers), "Subdivision removed")

# Two meshes, then a light: Join needs one type.
bpy.ops.mesh.primitive_uv_sphere_add(location=(3, 0, 0))
sphere = bpy.context.active_object
cube.select_set(True)
items = palette_items()
check(items["object.join"]["enabled"] and items["object.parent"]["enabled"], "Two meshes enable Join and Parent")
light = bpy.data.objects['Light']
light.select_set(True)
check(not palette_items()["object.join"]["enabled"], "Join needs objects of one type")

# Cameras.
bpy.ops.object.select_all(action='DESELECT')
bpy.ops.object.camera_add()
check(applies("object.active_camera"), "A camera that is not the scene camera can become active")
bpy.context.scene.camera = bpy.context.active_object
check(not applies("object.active_camera") and "object.active_camera" in palette_items(),
      "The scene camera dims Set Active Camera but keeps it in place")

# Long-press menu in Object Mode.
bpy.ops.object.select_all(action='DESELECT')
cube.select_set(True)
bpy.context.view_layer.objects.active = cube
menu = actions.long_press(bpy.context, "builtin.move")
check([item["title"] for item in menu["fixed"]] == ["Copy", "Paste", "Duplicate", "Rename", "Delete"],
      "Long press leads with Copy, Paste, Duplicate, Rename, Delete: " + str(menu["fixed"]))
check(len(menu["actions"]) <= actions.LONG_PRESS_ACTIONS and
      not {item["title"] for item in menu["actions"]} & {"Duplicate", "Delete"},
      "Long press adds up to five other actions: " + str(menu["actions"]))
check(menu["more"] == "VIEW3D_MT_object_context_menu", "More... opens the object context menu")
menu = actions.long_press(bpy.context, "builtin.select_box")
check(not any(item["group"] == "Selection" for item in menu["actions"]) and menu["actions"][0]["title"] == "Edit",
      "The selection tools' lead stays in the strip, out of the long-press menu: " + str(menu["actions"]))
check(not any(item["group"] == "Selection" for item in actions.radial(bpy.context, "builtin.select_box")),
      "The radial has no selection actions")
radial = actions.radial(bpy.context, "builtin.move")
check(len(radial) <= actions.RADIAL_SLOTS and not any(item["destructive"] for item in radial),
      "The radial has up to eight slots and nothing destructive")

# Edit Mesh.
bpy.ops.object.mode_set(mode='EDIT')
bpy.context.tool_settings.mesh_select_mode = (True, False, False)
bpy.ops.mesh.select_all(action='DESELECT')
check(titles()[:1] == ["Select All"] and "Delete" not in titles(), "Edit Mode with nothing selected")
check(any(item["menu"] == "VIEW3D_MT_mesh_add" for item in actions.actions(bpy.context, "")),
      "Edit Mode with nothing selected offers the mesh Add menu")

import bmesh


def select_verts(count):
    mesh = bmesh.from_edit_mesh(cube.data)
    for vert in mesh.verts:
        vert.select_set(vert.index < count)
    mesh.select_flush_mode()
    bmesh.update_edit_mesh(cube.data)


# The stability rule: one vertex or all, the palette keeps its items; only dimming changes.
select_verts(1)
one = palette_items("builtin.move")
bpy.ops.mesh.select_all(action='SELECT')
every = palette_items("builtin.move")
check(list(one) == list(every), "Selection counts do not move palette items")
check(not one["mesh.connect"]["enabled"] and every["mesh.connect"]["enabled"], "One vertex dims Connect")

def seed(strip):
    """The strip without Extrude, whose poll depends on the build having a viewport in the background."""
    return [title for title in strip if title != "Extrude"]


vertex = titles("builtin.move")
check(seed(vertex) == ["Connect", "Merge", "Bevel Vertices", "Make Edge/Face", "Dissolve", "Delete"],
      "The vertex strip is the seed: " + str(vertex))
check("mesh.rip" in palette_items("builtin.move") and palette_items("builtin.move")["mesh.rip"]["tool"] ==
      "builtin.rip_region", "Rip activates its tool from the palette")

bpy.context.tool_settings.mesh_select_mode = (False, True, False)
edge = titles("builtin.move")
check(seed(edge) == ["Bevel", "Loop Cut", "Bridge Loops", "Subdivide", "Dissolve", "Delete"],
      "The edge strip is the seed: " + str(edge))
items = palette_items("builtin.move")
check("mesh.loop_select" in items and "mesh.ring_select" in items and "mesh.mark_seam" in items,
      "The edge palette adds loops, rings and seams")

bpy.context.tool_settings.mesh_select_mode = (False, False, True)
face = titles("builtin.move")
check(seed(face) == ["Inset", "Bevel", "Subdivide", "Separate", "Dissolve", "Delete"],
      "The face strip is the seed: " + str(face))
groups = [group["group"] for group in palette("builtin.move")]
check("Normals & Shading" in groups and "Vertex" not in groups, "The face palette: " + str(groups))
menu = actions.long_press(bpy.context, "builtin.move")
check([item["title"] for item in menu["fixed"]] == ["Duplicate", "Delete"] and
      menu["more"] == "VIEW3D_MT_edit_mesh_context_menu", "Edit Mesh long press: " + str(menu))

mesh = bmesh.from_edit_mesh(cube.data)
for f in mesh.faces:
    f.select_set(f.index == 0)
mesh.select_flush_mode()
bmesh.update_edit_mesh(cube.data)
faces = len(cube.data.polygons)
check(actions.run(bpy.context, "mesh.inset"), "Run Inset")
bpy.ops.object.mode_set(mode='OBJECT')
check(len(cube.data.polygons) > faces, "Inset changed the mesh")
check(not actions.run(bpy.context, "mesh.inset"), "A stale action does not run outside its context")

bpy.ops.object.mode_set(mode='SCULPT')
check(titles("builtin_brush.Draw")[:2] == ["Invert Mask", "Clear Mask"], "Sculpt keeps its mask actions")
check(actions.long_press(bpy.context, "builtin_brush.Draw")["more"] == "", "Sculpt has no context menu")
bpy.ops.object.mode_set(mode='OBJECT')

bpy.ops.object.armature_add()
check(titles("builtin.move")[0] == "Pose Mode", "An armature leads with Pose Mode")
bpy.ops.object.mode_set(mode='POSE')
bpy.context.object.pose.bones[0].select = True
check(applies('object.keyframe'), "Pose Mode offers the first keyframe before an action exists")
check("Clear Transforms" in titles(), "Pose Mode offers pose actions")
print('PASS: native context actions ' + json.dumps(checks))
