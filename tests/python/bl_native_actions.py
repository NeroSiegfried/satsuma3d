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
check(not any(action.op in {"object.location_clear", "object.rotation_clear", "object.scale_clear",
                            "object.origin_clear"} for action in actions.ACTIONS),
      "No esoteric object transform clearing")
modes = set(bpy.types.Context.bl_rna.properties['mode'].enum_items.keys())
check(modes == set(actions.MODE_MENUS), "Every mode names where its fallback actions come from: " +
      str(sorted(modes ^ set(actions.MODE_MENUS))))
for mode, menu in actions.MODE_MENUS.items():
    check(menu is None or hasattr(bpy.types, menu), f"{mode}'s context menu {menu} exists")
# ROUND6 MODE-4 (E9): the long-press and radial surfaces, which no screen read, are gone; the long
# press and the Pencil's radial menu show Blender's context menu, checked by the harness's `header`.
check(not any(hasattr(actions, name) for name in ("long_press", "radial", "_FIXED")),
      "No surface nothing reads: long_press, radial and their fixed section are gone")

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

# Edit Mesh.
bpy.ops.object.select_all(action='DESELECT')
cube.select_set(True)
bpy.context.view_layer.objects.active = cube
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
check(seed(vertex) == ["Subdivide", "Connect", "Merge", "Bevel Vertices", "Make Edge/Face", "Dissolve", "Mirror", "Duplicate", "Copy", "Delete"],
      "The vertex strip is the seed: " + str(vertex))
check("mesh.rip" in palette_items("builtin.move") and palette_items("builtin.move")["mesh.rip"]["tool"] ==
      "builtin.rip_region", "Rip activates its tool from the palette")

bpy.context.tool_settings.mesh_select_mode = (False, True, False)
edge = titles("builtin.move")
check(seed(edge) == ["Subdivide", "Bevel", "Loop Cut", "Bridge Loops", "Dissolve", "Mirror", "Duplicate", "Copy", "Delete"],
      "The edge strip is the seed: " + str(edge))
items = palette_items("builtin.move")
check("mesh.loop_select" in items and "mesh.ring_select" in items and "mesh.mark_seam" in items,
      "The edge palette adds loops, rings and seams")

bpy.context.tool_settings.mesh_select_mode = (False, False, True)
face = titles("builtin.move")
check(seed(face) == ["Subdivide", "Inset", "Bevel", "Separate", "Dissolve", "Mirror", "Duplicate", "Copy", "Delete"],
      "The face strip is the seed: " + str(face))
groups = [group["group"] for group in palette("builtin.move")]
check("Normals & Shading" in groups and "Vertex" not in groups, "The face palette: " + str(groups))

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
why = actions.run_reported(bpy.context, "mesh.inset")
check(why.startswith("Inset") and len(why) > len("Inset"), "A stale action says why it did not run: " + why)
check(actions.run_reported(bpy.context, "no.such_action") == "", "An unknown action says nothing")
cube.hide_set(True)
check(applies('object.reveal'), "Hidden objects offer Reveal Hidden")
# Reveal's poll needs a 3D View, which a background run has not: it is run in the Mac harness.
check(actions._BY_ID["object.reveal"].op == "object.hide_view_clear", "Reveal Hidden runs Blender's Alt+H")
why = actions.run_reported(bpy.context, "object.reveal")
check(why == "" or why.endswith("Object Mode") or why.startswith("Reveal Hidden"),
      "Reveal Hidden runs or says why: " + why)
cube.hide_set(False)
check(not applies('object.reveal'), "Nothing hidden, nothing to reveal")
bpy.context.view_layer.objects.active = cube
cube.select_set(True)
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='DESELECT')
mesh = bmesh.from_edit_mesh(cube.data)
mesh.verts.ensure_lookup_table()
mesh.verts[0].select_set(True)
mesh.select_flush_mode()
bmesh.update_edit_mesh(cube.data)
bpy.context.tool_settings.mesh_select_mode = (True, False, False)
why = actions._BY_ID["mesh.connect"].reason(actions._State(bpy.context, "builtin.move"))
check(why == "Connect: select at least 2 vertices", "A dimmed action names what it needs: " + why)
bpy.ops.object.mode_set(mode='OBJECT')

bpy.ops.object.mode_set(mode='SCULPT')
check(titles("builtin_brush.Draw")[:2] == ["Invert Mask", "Clear Mask"], "Sculpt keeps its mask actions")
bpy.ops.object.mode_set(mode='OBJECT')

# ROUND6 MODE-4 (E9): a mode without rules fills its strip from its own menus, as Blender lists
# them: Edit Lattice (its context menu). Texture Paint has none: it has rules of its own.
lattice_ob = bpy.data.objects.new("Lattice", bpy.data.lattices.new("Lattice"))
bpy.context.scene.collection.objects.link(lattice_ob)
bpy.ops.object.select_all(action='DESELECT')
lattice_ob.select_set(True)
bpy.context.view_layer.objects.active = lattice_ob
bpy.ops.object.mode_set(mode='EDIT')
lattice = actions.actions(bpy.context, "builtin.select_box")
check(len(lattice) >= actions.MINIMUM_ACTIONS and any(i["action"].startswith("menu:") for i in lattice),
      "Edit Lattice's strip is filled from its context menu: " + str([i["title"] for i in lattice]))
first = next(i for i in lattice if i["action"].startswith("menu:"))
check(first["action"] in actions._BY_ID, "A fallback action runs by its id: " + first["action"])
groups = {item["action"] for group in palette("builtin.select_box") for item in group["items"]}
check(first["action"] in groups, "Search's palette lists the fallback actions too")
bpy.ops.object.mode_set(mode='OBJECT')
bpy.data.objects.remove(lattice_ob)
bpy.context.view_layer.objects.active = cube
cube.select_set(True)
bpy.ops.object.mode_set(mode='TEXTURE_PAINT')
# Its header has no menu of its own: hand rules (Frame All needs a viewport, so it is counted by
# the harness's `header`, with every other mode's bar).
paint = {item["action"] for group in palette("builtin_brush.Draw") for item in group["items"]}
check({"paint.add_slot", "paint.save_images", "view.frame_all"} <= paint,
      "Texture Paint has its own actions: " + str(sorted(paint)))
bpy.ops.object.mode_set(mode='OBJECT')

bpy.ops.object.armature_add()
check(titles("builtin.move")[0] == "Pose Mode", "An armature leads with Pose Mode")
bpy.ops.object.mode_set(mode='POSE')
bpy.context.object.pose.bones[0].select = True
check(applies('object.keyframe'), "Pose Mode offers the first keyframe before an action exists")
check("Clear Transforms" in titles(), "Pose Mode offers pose actions")

# ROUND6 MODE-7 (X4): a tool action is offered only where its tool is on the toolbar; elsewhere it
# would only warn "Tool ... not found for space", which the person saw four times in one second.
bpy.ops.object.mode_set(mode='OBJECT')
loop_cut = actions._BY_ID["mesh.loop_cut"]
check(not actions._poll(loop_cut), "Loop Cut's tool is not offered in Object Mode")
why = actions.run_reported(bpy.context, "mesh.loop_cut")
check(why and "Tool" not in why, "Run outside its mode, a tool action says why in words: " + why)
bpy.ops.object.mode_set(mode='POSE')

# Desktop staples bound to keys: what Ctrl+C, Ctrl+V, Ctrl+X, Shift+D and Shift+R run in the 3D
# View's keymaps is a registry action, or an exception says why not.
import sys
sys.path.append(str(Path(__file__).resolve().parents[2] / 'scripts/presets/keyconfig/keymap_data'))
import blender_default
STAPLES = {("C", "ctrl"): "Ctrl+C", ("V", "ctrl"): "Ctrl+V", ("X", "ctrl"): "Ctrl+X",
           ("D", "shift"): "Shift+D", ("R", "shift"): "Shift+R"}
KEYMAPS = ("Screen", "3D View", "Object Mode", "Mesh", "Curve", "Armature", "Pose", "Grease Pencil Edit Mode")
EXCEPTIONS = {
    "Mesh Ctrl+V": "opens the Vertex menu, which the context menu and Search reach",
    "Mesh Ctrl+X": "Dissolve by select mode: the strip's Dissolve",
    "Curve Ctrl+X": "Dissolve Vertices: in the Delete menu",
    "Armature Ctrl+X": "Dissolve: in the Delete menu",
    "Grease Pencil Edit Mode Ctrl+X": "Dissolve: in the Delete menu",
}
registered = {action.op for action in actions.ACTIONS}
table = []
for name, _space, data in blender_default.generate_keymaps():
    if name not in KEYMAPS:
        continue
    for idname, event, _props in data["items"]:
        if not isinstance(event, dict):
            continue
        for (key, modifier), label in STAPLES.items():
            others = [m for m in ("ctrl", "shift", "alt", "oskey") if m != modifier and event.get(m)]
            if event.get("type") != key or not event.get(modifier) or others or event.get("value") != 'PRESS':
                continue
            where = name + " " + label
            if where in EXCEPTIONS:
                table.append((where, idname, "exception: " + EXCEPTIONS[where]))
                continue
            check(idname in registered, where + " (" + idname + ") is a registry action")
            table.append((where, idname, "action"))
for row in table:
    print("staple: {:<24} {:<32} {}".format(*row))
check(any(row[1] == "screen.repeat_last" for row in table), "Shift+R was found in the keymaps")
# ROUND6 TOUCH-7 (C4, E6 i): an action whose operator reads the pointer to choose what to act on
# asks for a tap instead of running wherever the last touch left it. Every such action is invoked
# (it runs at the tap); the tap's own operator waits for the tap as a menu's command does.
placed = [action.id for action in actions._BY_ID.values() if actions.needs_place(action)]
check("sculpt.face_set_grow" in placed and "sculpt.face_set_shrink" in placed,
      "Grow and Shrink Face Set ask for a tap: " + ", ".join(placed))
check(all(actions._BY_ID[name].invoke for name in placed), "An action that asks for a tap runs as invoked there")
check('DEPENDS_ON_CURSOR' in bpy.ops.wm.native_action_at_tap.bl_options,
      "The tap's operator waits for the tap, as a menu's command that depends on the pointer does")
# ROUND6 TOUCH-8 (E3, E12, H5, A5, A11, C9 part; decision R6-8): every tool key-map item with a
# modifier or a double click, and every modal item on a modifier key, has a touch route. A left
# press with Shift, Ctrl or Alt: the shell's real keys for them, in both interfaces. A double
# click: a finger's double tap (22 pt, TOUCH-4). A modal item on Shift, Ctrl or Alt: the same keys,
# named from the modal map while it runs. Anything else must be in TOUCH_ROUTES with its route, or
# "desktop only" with why; a new one fails here.
MODIFIER_KEYS = ('LEFT_SHIFT', 'RIGHT_SHIFT', 'LEFT_CTRL', 'RIGHT_CTRL', 'LEFT_ALT', 'RIGHT_ALT')
TOUCH_ROUTES = {
    ("Image Editor Tool: Uv, Grab", "F", "shift"): "the sidebar's Strength slider",
    ("Image Editor Tool: Uv, Pinch", "F", "shift"): "the sidebar's Strength slider",
    ("Image Editor Tool: Uv, Relax", "F", "shift"): "the sidebar's Strength slider",
}
routes = {"sticky": 0, "double tap": 0, "modal": 0, "listed": 0}
unrouted = []
for name, space, data in blender_default.generate_keymaps():
    for item in data["items"]:
        if item is None or not isinstance(item[1], dict):
            continue
        idname, event, _props = item
        mods = [m for m in ("shift", "ctrl", "alt", "oskey") if event.get(m) in (True, 1)]
        if space.get("modal"):
            if event.get("type") in MODIFIER_KEYS:
                routes["modal"] += 1
            continue
        if " Tool:" not in name:
            continue
        if not mods and event.get("value") != 'DOUBLE_CLICK' and "key_modifier" not in event:
            continue
        if event.get("type") == 'LEFTMOUSE' and "oskey" not in mods and "key_modifier" not in event:
            routes["double tap" if not mods else "sticky"] += 1
            continue
        if (name, event.get("type"), "+".join(mods)) in TOUCH_ROUTES:
            routes["listed"] += 1
            continue
        unrouted.append("%s: %s %s%s (%s)" % (name, "+".join(mods), event.get("type"),
                                               " with " + event["key_modifier"] if "key_modifier" in event else "", idname))
print("touch routes: " + json.dumps(routes))
check(routes["sticky"] >= 20 and routes["modal"] >= 20 and not unrouted,
      "R6 TOUCH-8: every tool binding with a modifier or a double click has a touch route (%s)" % unrouted)
bridge_text = (Path(__file__).resolve().parents[2] / 'source/blender/windowmanager/intern/wm_native_ui.cc').read_text()
check('data("modifier_names"' in bridge_text and 'operator_bool_set(ptr, "toggle", toggle);' in bridge_text,
      "R6 TOUCH-8: Shift, Ctrl and Alt are named for the running operation and the tool; the latch has Toggle")
print('PASS: native context actions ' + json.dumps(checks))
