# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Blender's side of a long iPad session, run inside the app by `run_soak.py`.

Works Blender for a while with a seeded series of everyday actions: objects added, deleted,
selected and renamed, modes and tools changed, brush values set, frames moved, undo and redo.
Every second it writes what Blender has, to compare with what the native interface believed at
the same moment, and notes when its own loop stalled.

Reads `BLENDER_SOAK_MINUTES` and `BLENDER_SOAK_SEED` from the environment, and writes to
`soak/` in the app's temporary folder.
"""

import json
import os
import random
import tempfile
import time
import traceback

import bpy

DIRECTORY = os.path.join(tempfile.gettempdir(), "soak")
MINUTES = float(os.environ.get("BLENDER_SOAK_MINUTES", "10"))
SEED = int(os.environ.get("BLENDER_SOAK_SEED", "1"))
# How often the session acts, and how often it records.
ACT_INTERVAL = 1.5
RECORD_INTERVAL = 1.0
MAX_OBJECTS = 24

os.makedirs(DIRECTORY, exist_ok=True)
_files = {name: open(os.path.join(DIRECTORY, name), "w") for name in ("blender.jsonl", "blender_actions.jsonl")}
_random = random.Random(SEED)
_state = {"start": None, "last_record": 0.0, "last_act": 0.0, "last_tick": None, "done": False}


def _write(name, record):
    record["t"] = time.time()
    _files[name].write(json.dumps(record) + "\n")
    _files[name].flush()


def _override():
    window = bpy.context.window_manager.windows[0]
    area = next(area for area in window.screen.areas if area.type == 'VIEW_3D')
    region = next(region for region in area.regions if region.type == 'WINDOW')
    return {"window": window, "area": area, "region": region}


def _brush():
    import bl_ui.native_brush
    try:
        return json.loads(bl_ui.native_brush.brush_json(bpy.context)) or {}
    except Exception:
        return {}


def _record():
    context = bpy.context
    obj = context.active_object
    tool = context.workspace.tools.from_space_view3d_mode(context.mode, create=False)
    brush = _brush()
    record = {
        "mode": context.mode,
        "objectMode": obj.mode if obj else "OBJECT",
        "activeName": obj.name if obj else "",
        "tool": tool.idname if tool else "",
        "frame": context.scene.frame_current,
        "objects": len(context.view_layer.objects),
    }
    if "size" in brush:
        record["brushSize"] = brush["size"]["value"]
    if "strength" in brush:
        record["brushStrength"] = brush["strength"]["value"]
    _write("blender.jsonl", record)


def _soak_objects():
    return [obj for obj in bpy.context.view_layer.objects if obj.name.startswith("Soak")]


def _to_object_mode():
    obj = bpy.context.active_object
    if obj and obj.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')


def _add():
    if len(_soak_objects()) >= MAX_OBJECTS:
        return _delete()
    _to_object_mode()
    location = [_random.uniform(-6, 6), _random.uniform(-6, 6), _random.uniform(0, 3)]
    kind = _random.choice(["cube", "sphere", "monkey", "grease_pencil"])
    if kind == "cube":
        bpy.ops.mesh.primitive_cube_add(location=location)
    elif kind == "sphere":
        bpy.ops.mesh.primitive_uv_sphere_add(location=location)
    elif kind == "monkey":
        bpy.ops.mesh.primitive_monkey_add(location=location)
    else:
        bpy.ops.object.grease_pencil_add(type='STROKE', location=location)
    bpy.context.active_object.name = "Soak " + kind
    return {"add": kind}


def _delete():
    objects = _soak_objects()
    if not objects:
        return _add()
    _to_object_mode()
    obj = _random.choice(objects)
    name = obj.name
    bpy.data.objects.remove(obj)
    return {"delete": name}


def _select():
    objects = _soak_objects()
    if not objects:
        return _add()
    _to_object_mode()
    obj = _random.choice(objects)
    for other in bpy.context.view_layer.objects:
        other.select_set(other == obj)
    bpy.context.view_layer.objects.active = obj
    return {"select": obj.name}


def _rename():
    obj = bpy.context.active_object
    if obj is None or not obj.name.startswith("Soak"):
        return _select()
    obj.name = "Soak %s %d" % (obj.type.lower(), _random.randrange(1000))
    return {"rename": obj.name}


MODES = {
    'MESH': ['OBJECT', 'EDIT', 'SCULPT', 'VERTEX_PAINT', 'WEIGHT_PAINT', 'TEXTURE_PAINT'],
    'GREASEPENCIL': ['OBJECT', 'EDIT', 'PAINT_GREASE_PENCIL', 'SCULPT_GREASE_PENCIL'],
}


def _mode():
    obj = bpy.context.active_object
    if obj is None or obj.type not in MODES:
        return _select()
    mode = _random.choice(MODES[obj.type])
    bpy.ops.object.mode_set(mode=mode)
    return {"mode": mode}


def _tool():
    from bl_ui.space_toolsystem_common import ToolSelectPanelHelper
    cls = ToolSelectPanelHelper._tool_class_from_space_type('VIEW_3D')
    ids = [item.idname for item in ToolSelectPanelHelper._tools_flatten(cls.tools_from_context(bpy.context))
           if item is not None]
    if not ids:
        return None
    tool = _random.choice(ids)
    bpy.ops.wm.tool_set_by_id(name=tool)
    return {"tool": tool}


def _brush_value():
    import bl_ui.native_brush
    brush = _brush()
    keys = [key for key in ("size", "strength") if key in brush]
    if not keys:
        return _tool()
    key = _random.choice(keys)
    low, high = brush[key]["min"], brush[key]["max"]
    top = min(high, max(low * 4, 200)) if key == "size" else high
    value = low + (top - low) * _random.random()
    bl_ui.native_brush.brush_set(bpy.context, json.dumps({"key": key, "value": value}))
    return {"brush": key, "value": value}


def _frame():
    scene = bpy.context.scene
    scene.frame_set(_random.randint(scene.frame_start, scene.frame_end))
    return {"frame": scene.frame_current}


def _undo():
    operators = [name for name in ("undo", "redo") if getattr(bpy.ops.ed, name).poll()]
    if not operators:
        return None
    operator = _random.choice(operators)
    getattr(bpy.ops.ed, operator)()
    return {operator: True}


ACTIONS = [(_add, 3), (_delete, 2), (_select, 4), (_rename, 1), (_mode, 4), (_tool, 4), (_brush_value, 3),
           (_frame, 3), (_undo, 2)]


def _act():
    action = _random.choices([action for action, _ in ACTIONS], [weight for _, weight in ACTIONS])[0]
    try:
        with bpy.context.temp_override(**_override()):
            result = action()
        if result:
            # Changes from scripts are undoable only once pushed, as the interface's are.
            bpy.ops.ed.undo_push(message="Soak")
            _write("blender_actions.jsonl", result)
    except Exception:
        _write("blender_actions.jsonl", {"error": action.__name__, "trace": traceback.format_exc(limit=2)})


def _tick():
    now = time.time()
    if _state["start"] is None:
        _state["start"] = now
        for scene in bpy.data.scenes:
            # EEVEE's shaders do not build in the iPad simulator.
            scene.render.engine = 'BLENDER_WORKBENCH'
    # Blender's loop stalled: the timer came back late.
    if _state["last_tick"] is not None and now - _state["last_tick"] > 1.0:
        _write("blender_actions.jsonl", {"stall": now - _state["last_tick"]})
    _state["last_tick"] = now
    if now - _state["start"] > MINUTES * 60:
        _write("blender_actions.jsonl", {"done": True})
        for file in _files.values():
            file.close()
        return None
    if now - _state["last_record"] >= RECORD_INTERVAL:
        _state["last_record"] = now
        try:
            with bpy.context.temp_override(**_override()):
                _record()
        except Exception:
            _write("blender_actions.jsonl", {"error": "record", "trace": traceback.format_exc(limit=2)})
    if now - _state["last_act"] >= ACT_INTERVAL:
        _state["last_act"] = now
        _act()
    return 0.2


bpy.app.timers.register(_tick, first_interval=10.0, persistent=True)
