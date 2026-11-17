# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Drive Blender's native UI bridge from inside a windowed macOS build, as the iPad shell does.

Run through `mac_bridge_check.py`, which generates the protocol's Python code first.
Subscribes to views through the exported C API, pumps the bridge from a timer with
WM_native_ui_flush_commands, decodes updates into node trees, sends commands, writes a report.
"""
import ctypes
import json
import sys
import traceback

import bpy

argv = sys.argv[sys.argv.index("--") + 1:]
sys.path.insert(0, argv[0])
REPORT = argv[1]
SCENARIO = argv[2] if len(argv) > 2 else "actions"

import flatbuffers  # noqa: E402
from Blender.NativeUI import (  # noqa: E402
    BoolValue, Button, ButtonStyle, Choice, Command, Commands, Content, Group, Node, Op, Param, Subscribe, TextValue,
    Updates, Value,
)

lib = ctypes.CDLL(None)
lib.WM_native_ui_subscribe.restype = ctypes.c_uint32
lib.WM_native_ui_subscribe.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
lib.WM_native_ui_send.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
lib.WM_native_ui_take_updates.restype = ctypes.c_void_p
lib.WM_native_ui_buffer_data.restype = ctypes.POINTER(ctypes.c_uint8)
lib.WM_native_ui_buffer_data.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t)]
lib.WM_native_ui_buffer_free.argtypes = [ctypes.c_void_p]
flush = getattr(lib, "_ZN7blender27WM_native_ui_flush_commandsEPNS_8bContextE")
flush.argtypes = [ctypes.c_void_p]


def text_param(builder, key, value):
    k = builder.CreateString(key)
    v = builder.CreateString(value)
    TextValue.Start(builder)
    TextValue.AddValue(builder, v)
    tv = TextValue.End(builder)
    Param.Start(builder)
    Param.AddKey(builder, k)
    Param.AddValueType(builder, Value.Value.TextValue)
    Param.AddValue(builder, tv)
    return Param.End(builder)


def bool_param(builder, key, value):
    k = builder.CreateString(key)
    BoolValue.Start(builder)
    BoolValue.AddValue(builder, value)
    bv = BoolValue.End(builder)
    Param.Start(builder)
    Param.AddKey(builder, k)
    Param.AddValueType(builder, Value.Value.BoolValue)
    Param.AddValue(builder, bv)
    return Param.End(builder)


def subscribe(view, **params):
    builder = flatbuffers.Builder(256)
    name = builder.CreateString(view)
    offsets = [bool_param(builder, key, value) if isinstance(value, bool) else text_param(builder, key, value)
               for key, value in params.items()]
    Subscribe.StartParamsVector(builder, len(offsets))
    for offset in reversed(offsets):
        builder.PrependUOffsetTRelative(offset)
    vector = builder.EndVector()
    Subscribe.Start(builder)
    Subscribe.AddView(builder, name)
    Subscribe.AddParams(builder, vector)
    builder.Finish(Subscribe.End(builder))
    data = bytes(builder.Output())
    return lib.WM_native_ui_subscribe(data, len(data))


def invoke(subscription, target, command_id):
    builder = flatbuffers.Builder(256)
    t = builder.CreateString(target)
    Command.Start(builder)
    Command.AddId(builder, command_id)
    Command.AddSubscription(builder, subscription)
    Command.AddTarget(builder, t)
    Command.AddOp(builder, Op.Op.Invoke)
    c = Command.End(builder)
    Commands.StartCommandsVector(builder, 1)
    builder.PrependUOffsetTRelative(c)
    v = builder.EndVector()
    Commands.Start(builder)
    Commands.AddCommands(builder, v)
    builder.Finish(Commands.End(builder))
    data = bytes(builder.Output())
    lib.WM_native_ui_send(data, len(data))


CONTENT_NAMES = {value: name for name, value in vars(Content.Content).items() if not name.startswith("_")}
STYLE_NAMES = {value: name for name, value in vars(ButtonStyle.ButtonStyle).items() if not name.startswith("_")}
views = {}  # subscription -> {"top": key, "nodes": {key: dict}, "children": {key: [keys]}}
acks = {}


def s(value):
    return value.decode() if isinstance(value, bytes) else value


def decode_node(raw):
    node = Node.Node.GetRootAs(raw, 0)
    entry = {"label": s(node.Label()), "icon": s(node.Icon()), "enabled": node.Enabled(),
             "content": CONTENT_NAMES.get(node.ContentType(), node.ContentType())}
    try:
        entry["role"] = node.Role()
        entry["property"] = s(node.Property())
    except AttributeError:
        pass
    if node.ContentType() == Content.Content.Button:
        table = node.Content()
        button = Button.Button()
        button.Init(table.Bytes, table.Pos)
        entry.update(style=STYLE_NAMES.get(button.Style()), operator=s(button.Operator()), pressed=button.Pressed())
        params = {}
        for i in range(button.ParamsLength()):
            param = button.Params(i)
            if param.ValueType() == Value.Value.TextValue:
                tv = TextValue.TextValue()
                tv.Init(param.Value().Bytes, param.Value().Pos)
                params[s(param.Key())] = s(tv.Value())
        if params:
            entry["params"] = params
    elif node.ContentType() == Content.Content.Choice:
        table = node.Content()
        choice = Choice.Choice()
        choice.Init(table.Bytes, table.Pos)
        entry.update(value=s(choice.Value()),
                     options=[s(choice.Options(i).Value()) for i in range(choice.OptionsLength())])
    return s(node.Key()), entry


def pump():
    flush(bpy.context.as_pointer())
    while True:
        handle = lib.WM_native_ui_take_updates()
        if not handle:
            return
        size = ctypes.c_size_t()
        pointer = lib.WM_native_ui_buffer_data(handle, ctypes.byref(size))
        data = bytearray(ctypes.string_at(pointer, size.value))
        lib.WM_native_ui_buffer_free(handle)
        updates = Updates.Updates.GetRootAs(data, 0)
        for i in range(updates.AcksLength()):
            ack = updates.Acks(i)
            acks[ack.Command()] = s(ack.Error()) or "ok"
        for i in range(updates.UpdatesLength()):
            update = updates.Updates(i)
            view = views.setdefault(update.Subscription(), {"top": None, "nodes": {}, "children": {}})
            if update.Reset():
                view.update(top=s(update.Top()), nodes={}, children={})
            for j in range(update.NodesLength()):
                buffer = update.Nodes(j)
                key, entry = decode_node(bytearray(buffer.NodeAsNumpy().tobytes()))
                view["nodes"][key] = entry
            for j in range(update.ChildrenLength()):
                children = update.Children(j)
                view["children"][s(children.Parent())] = [s(children.Keys(k)) for k in range(children.KeysLength())]
            for j in range(update.RemovedLength()):
                view["nodes"].pop(s(update.Removed(j)), None)


def tree(subscription):
    view = views.get(subscription)
    if not view or not view["top"]:
        return None

    def walk(key):
        out = dict(view["nodes"].get(key, {}), key=key)
        kids = view["children"].get(key)
        if kids:
            out["children"] = [walk(child) for child in kids]
        return out
    return walk(view["top"])


report = {"steps": []}
subs = {}
step = 0


def finish(status):
    report["status"] = status
    with open(REPORT, "w") as f:
        json.dump(report, f, indent=1)
    bpy.ops.wm.quit_blender()


def tick_actions():
    global step
    try:
        pump()
        step += 1
        cube = bpy.data.objects["Cube"]
        if step == 1:
            bpy.ops.object.select_all(action='DESELECT')
            cube.select_set(True)
            bpy.context.view_layer.objects.active = cube
            for surface in ("palette", "long_press", "radial"):
                subs[surface] = subscribe("actions", surface=surface)
            subs["toolbar"] = subscribe("toolbar")
        elif step == 5:
            report["steps"].append({"name": "object_mesh", "trees": {name: tree(sub) for name, sub in subs.items()
                                                                       if name != "toolbar"},
                                    "toolbar_actions": [n for n in (tree(subs["toolbar"]) or {}).get("children", [])
                                                        if n["key"] == "actions"]})
            invoke(subs["palette"], "action:object.subdivision", 7)
        elif step == 9:
            report["steps"].append({"name": "after_subdivision_invoke", "ack": acks.get(7),
                                    "has_subsurf": any(m.type == 'SUBSURF' for m in cube.modifiers),
                                    "palette": tree(subs["palette"])})
            # Reveal Hidden needs a 3D View for its poll, so it is exercised here, not in ctest.
            cube.hide_set(True)
            invoke(subs["palette"], "action:object.reveal", 8)
        elif step == 11:
            report["steps"].append({"name": "after_reveal_invoke", "ack": acks.get(8),
                                    "cube_visible": not cube.hide_get()})
            cube.hide_set(False)
            bpy.context.view_layer.objects.active = cube
            cube.select_set(True)
            bpy.ops.object.mode_set(mode='EDIT')
            bpy.context.tool_settings.mesh_select_mode = (False, True, False)
            bpy.ops.mesh.select_all(action='SELECT')
        elif step == 15:
            report["steps"].append({"name": "edit_edges", "trees": {name: tree(sub) for name, sub in subs.items()
                                                                     if name != "toolbar"}})
            invoke(subs["palette"], "action:mesh.subdivide", 9)
        elif step == 18:
            report["steps"].append({"name": "after_subdivide", "ack": acks.get(9), "verts": len(cube.data.vertices),
                                    "repeat": [n for n in (tree(subs["toolbar"]) or {}).get("children", [])
                                               if n["key"] == "repeat"]})
            invoke(subs["toolbar"], "repeat", 10)
        elif step == 21:
            bpy.ops.object.mode_set(mode='OBJECT')
            bpy.ops.object.mode_set(mode='EDIT')
            report["steps"].append({"name": "after_repeat_subdivide", "ack": acks.get(10),
                                    "verts": len(cube.data.vertices)})
            # Head heights: a copy moved up, then Repeat Last stacks the next one as far again.
            bpy.ops.mesh.select_all(action='SELECT')
            # As actions run it (`native_actions.run`): with undo, so Blender keeps it for Repeat Last.
            bpy.ops.mesh.duplicate_move('EXEC_DEFAULT', True, TRANSFORM_OT_translate={"value": (0, 0, 2)})
        elif step == 23:
            invoke(subs["toolbar"], "repeat", 11)
        elif step == 26:
            bpy.ops.object.mode_set(mode='OBJECT')
            zs = [v.co.z for v in cube.data.vertices]
            report["steps"].append({"name": "after_repeat_duplicate", "ack": acks.get(11),
                                    "verts": len(cube.data.vertices), "top": max(zs)})
            finish("done")
            return None
        if step > 40:
            finish("timeout")
            return None
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.25


def count(node):
    return 1 + sum(count(child) for child in node.get("children", []))


def labels(node, out=None):
    out = [] if out is None else out
    if node.get("label"):
        out.append(node["label"])
    for child in node.get("children", []):
        labels(child, out)
    return out


# Every tab of Properties, the 3D Viewport's sidebar tabs among them, in every mode: each is
# asked for and must come back. A tab that reads something the mode lacks would crash here.
TAB_MODES = ("object", "edit_mesh", "sculpt", "edit_curve", "edit_armature", "pose")


def enter(mode):
    if bpy.context.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    cube = bpy.data.objects["Cube"]
    if mode in {"object", "edit_mesh", "sculpt"}:
        bpy.ops.object.select_all(action='DESELECT')
        cube.select_set(True)
        bpy.context.view_layer.objects.active = cube
        if mode == "edit_mesh":
            bpy.ops.object.mode_set(mode='EDIT')
            bpy.ops.mesh.select_all(action='SELECT')
        elif mode == "sculpt":
            bpy.ops.object.mode_set(mode='SCULPT')
    elif mode == "edit_curve":
        bpy.ops.curve.primitive_bezier_curve_add(enter_editmode=True)
    elif mode == "edit_armature":
        bpy.ops.object.armature_add(enter_editmode=True)
    elif mode == "pose":
        bpy.ops.object.mode_set(mode='POSE')


def tick_tabs():
    global step
    try:
        pump()
        step += 1
        if step == 1:
            enter("object")
            subs["OBJECT"] = subscribe("properties", tab="OBJECT", properties=True)
        elif step == 4:
            top = tree(subs["OBJECT"]) or {}
            tabs = next((n.get("options") for n in top.get("children", []) if n["key"] == "tabs"), None)
            if not tabs:
                report["error"] = "Properties lists no tabs"
                finish("error")
                return None
            report["tabs"] = tabs
            for tab in tabs:
                if tab not in subs:
                    subs[tab] = subscribe("properties", tab=tab, properties=True)
        elif step > 4 and (step - 5) % 4 == 3:
            mode = TAB_MODES[(step - 5) // 4]
            trees = {tab: tree(sub) for tab, sub in subs.items()}
            missing = [tab for tab, top in trees.items() if top is None]
            entry = {"name": mode, "context": bpy.context.mode, "missing": missing,
                     "nodes": {tab: count(top) for tab, top in trees.items() if top},
                     "item": labels(trees.get("SIDEBAR:Item") or {}),
                     "item_tree": trees.get("SIDEBAR:Item"),
                     "view": labels(trees.get("SIDEBAR:View") or {})}
            report["steps"].append(entry)
            if missing:
                report["error"] = "No view for " + ", ".join(missing) + " in " + mode
                finish("error")
                return None
            if mode == TAB_MODES[-1]:
                finish("done")
                return None
            enter(TAB_MODES[TAB_MODES.index(mode) + 1])
        if step > 80:
            finish("timeout")
            return None
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.25


# Blender's header menus as the native menus ask for them, in Object and Edit Mode: the editor's
# menus (View, Select, Add, Object | Mesh, Vertex, Edge, Face, UV) and the top bar's Edit menu.
MENU_ROUTES = ("VIEW3D_MT_editor_menus", "TOPBAR_MT_edit", "VIEW3D_MT_view", "VIEW3D_MT_object_apply")


def tick_menus():
    global step
    try:
        pump()
        step += 1
        if step == 1:
            enter("object")
            for route in MENU_ROUTES:
                subs["object " + route] = subscribe("menu", route=route)
        elif step == 5:
            report["steps"].append({"name": "object", "menus": {
                name: [(n.get("label"), n.get("content")) for n in (tree(sub) or {}).get("children", [])]
                for name, sub in subs.items()}})
            enter("edit_mesh")
            for route in MENU_ROUTES[:1]:
                subs["edit " + route] = subscribe("menu", route=route)
        elif step == 10:
            report["steps"].append({"name": "edit", "menus": {
                name: [(n.get("label"), n.get("content")) for n in (tree(sub) or {}).get("children", [])]
                for name, sub in subs.items() if name.startswith("edit")}})
            finish("done")
            return None
        if step > 40:
            finish("timeout")
            return None
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.25


bpy.app.timers.register({"tabs": tick_tabs, "menus": tick_menus}.get(SCENARIO, tick_actions), first_interval=1.0)
