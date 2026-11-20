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
import os
import sys
import time
import traceback

import bpy

argv = sys.argv[sys.argv.index("--") + 1:]
sys.path.insert(0, argv[0])
REPORT = argv[1]
SCENARIO = argv[2] if len(argv) > 2 else "actions"
# The "Blender" strings the app may show (ROUND5 8A.7), read by the `menus` scenario.
ALLOWED = argv[3] if len(argv) > 3 else None
# The shell's own commands a key may stand in for (ROUND5 9A.6), read by the `keys` scenario.
STAND_INS = argv[4] if len(argv) > 4 else None

import flatbuffers  # noqa: E402
from Blender.NativeUI import (  # noqa: E402
    BoolValue, Button, ButtonStyle, Choice, Command, Commands, Content, Data, FloatsValue, FloatValue, Group, MenuButton, Node, Number,
    Op, Param,
    Reference,
    Subscribe, TextValue, TextsValue, Toggle, Updates, Value,
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
image_update = getattr(lib, "_ZN7blender25WM_native_ui_image_updateEPNS_8bContextE")
image_update.argtypes = [ctypes.c_void_p]
class NativeImageUVs(ctypes.Structure):
    """`WMNativeImageUVs` (ROUND5 9G.3)."""
    _fields_ = [("edges", ctypes.POINTER(ctypes.c_float)), ("edge_flags", ctypes.POINTER(ctypes.c_uint8)),
                ("edge_count", ctypes.c_int), ("faces", ctypes.POINTER(ctypes.c_float)),
                ("face_sizes", ctypes.POINTER(ctypes.c_int)), ("face_count", ctypes.c_int),
                ("active_face", ctypes.c_int), ("capped", ctypes.c_bool)]


lib.WM_native_ui_image_take_uvs.restype = ctypes.c_bool
lib.WM_native_ui_image_take_uvs.argtypes = [ctypes.POINTER(NativeImageUVs)]
lib.WM_native_ui_image_uvs_free.argtypes = [ctypes.POINTER(NativeImageUVs)]
lib.free.argtypes = [ctypes.c_void_p]
lib.WM_native_ui_viewport_insets_set.argtypes = [ctypes.c_float, ctypes.c_float]
lib.WM_native_ui_top_bar_set.argtypes = [ctypes.c_float]
lib.WM_native_ui_bottom_tray_set.argtypes = [ctypes.c_float]
# ROUND5 9G.5: the band the controls along the bottom stand in, which framing keeps clear of. Absent
# from builds before it, which the `insets` scenario then measures with the tray alone.
BOTTOM_CONTROLS = getattr(lib, "WM_native_ui_bottom_controls_set", None)
if BOTTOM_CONTROLS is not None:
    BOTTOM_CONTROLS.argtypes = [ctypes.c_float]


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


def invoke(subscription, target, command_id, op=None):
    invoke_many(subscription, [(target, command_id)], op=op, version=0)


def invoke_many(subscription, targets, op=None, version=None):
    """Commands sent together, as taps that reach Blender in one pass; each carries the version of
    the view shown (as the shell's do), unless `version` says otherwise."""
    if version is None:
        version = views.get(subscription, {}).get("version", 0)
    builder = flatbuffers.Builder(256)
    offsets = []
    for target, command_id in targets:
        t = builder.CreateString(target)
        Command.Start(builder)
        Command.AddId(builder, command_id)
        Command.AddSubscription(builder, subscription)
        Command.AddTarget(builder, t)
        Command.AddOp(builder, Op.Op.Invoke if op is None else op)
        Command.AddVersion(builder, version)
        offsets.append(Command.End(builder))
    Commands.StartCommandsVector(builder, len(offsets))
    for c in reversed(offsets):
        builder.PrependUOffsetTRelative(c)
    v = builder.EndVector()
    Commands.Start(builder)
    Commands.AddCommands(builder, v)
    builder.Finish(Commands.End(builder))
    data = bytes(builder.Output())
    lib.WM_native_ui_send(data, len(data))


def set_bool(subscription, target, value, command_id):
    builder = flatbuffers.Builder(256)
    t = builder.CreateString(target)
    BoolValue.Start(builder)
    BoolValue.AddValue(builder, value)
    bv = BoolValue.End(builder)
    Command.Start(builder)
    Command.AddId(builder, command_id)
    Command.AddSubscription(builder, subscription)
    Command.AddTarget(builder, t)
    Command.AddOp(builder, Op.Op.Set)
    Command.AddValueType(builder, Value.Value.BoolValue)
    Command.AddValue(builder, bv)
    c = Command.End(builder)
    Commands.StartCommandsVector(builder, 1)
    builder.PrependUOffsetTRelative(c)
    vec = builder.EndVector()
    Commands.Start(builder)
    Commands.AddCommands(builder, vec)
    builder.Finish(Commands.End(builder))
    data = bytes(builder.Output())
    lib.WM_native_ui_send(data, len(data))


def set_text(subscription, target, text, command_id):
    builder = flatbuffers.Builder(256)
    t = builder.CreateString(target)
    v = builder.CreateString(text)
    TextValue.Start(builder)
    TextValue.AddValue(builder, v)
    tv = TextValue.End(builder)
    Command.Start(builder)
    Command.AddId(builder, command_id)
    Command.AddSubscription(builder, subscription)
    Command.AddTarget(builder, t)
    Command.AddOp(builder, Op.Op.Set)
    Command.AddValueType(builder, Value.Value.TextValue)
    Command.AddValue(builder, tv)
    c = Command.End(builder)
    Commands.StartCommandsVector(builder, 1)
    builder.PrependUOffsetTRelative(c)
    vec = builder.EndVector()
    Commands.Start(builder)
    Commands.AddCommands(builder, vec)
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
    elif node.ContentType() == Content.Content.MenuButton:
        table = node.Content()
        menu = MenuButton.MenuButton()
        menu.Init(table.Bytes, table.Pos)
        params = {}
        for i in range(menu.ParamsLength()):
            param = menu.Params(i)
            if param.ValueType() == Value.Value.TextValue:
                tv = TextValue.TextValue()
                tv.Init(param.Value().Bytes, param.Value().Pos)
                params[s(param.Key())] = s(tv.Value())
        entry.update(view=s(menu.View()), params=params)
    elif node.ContentType() == Content.Content.Choice:
        table = node.Content()
        choice = Choice.Choice()
        choice.Init(table.Bytes, table.Pos)
        entry.update(value=s(choice.Value()),
                     options=[s(choice.Options(i).Value()) for i in range(choice.OptionsLength())])
    elif node.ContentType() == Content.Content.Data:
        table = node.Content()
        data = Data.Data()
        data.Init(table.Bytes, table.Pos)
        if data.ValueType() == Value.Value.TextValue:
            tv = TextValue.TextValue()
            tv.Init(data.Value().Bytes, data.Value().Pos)
            entry.update(value=s(tv.Value()))
        elif data.ValueType() == Value.Value.FloatValue:
            fv = FloatValue.FloatValue()
            fv.Init(data.Value().Bytes, data.Value().Pos)
            entry.update(value=fv.Value())
        elif data.ValueType() == Value.Value.FloatsValue:
            fv = FloatsValue.FloatsValue()
            fv.Init(data.Value().Bytes, data.Value().Pos)
            entry.update(value=[fv.Value(i) for i in range(fv.ValueLength())])
        elif data.ValueType() == Value.Value.TextsValue:
            tv = TextsValue.TextsValue()
            tv.Init(data.Value().Bytes, data.Value().Pos)
            entry.update(value=[s(tv.Value(i)) for i in range(tv.ValueLength())])
    elif node.ContentType() == Content.Content.Number:
        table = node.Content()
        number = Number.Number()
        number.Init(table.Bytes, table.Pos)
        entry.update(value=number.Value(), integer=bool(number.Integer()), precision=number.Precision())
    elif node.ContentType() == Content.Content.Reference:
        table = node.Content()
        reference = Reference.Reference()
        reference.Init(table.Bytes, table.Pos)
        entry.update(name=s(reference.Name()), users=reference.Users(), can_new=reference.CanNew(),
                     can_unlink=reference.CanUnlink(), can_single_user=reference.CanSingleUser(),
                     can_fake_user=reference.CanFakeUser(), fake_user=reference.FakeUser(),
                     choices=reference.OptionsLength())
    elif node.ContentType() == Content.Content.Toggle:
        table = node.Content()
        toggle = Toggle.Toggle()
        toggle.Init(table.Bytes, table.Pos)
        entry.update(value=bool(toggle.Value()))
    return s(node.Key()), entry


decoded = [0]


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
            view["version"] = update.Version()
            if update.Reset():
                view.update(top=s(update.Top()), nodes={}, children={})
            elif update.Top():
                # A view whose top node changed key, as the popup's does for each request.
                view["top"] = s(update.Top())
            for j in range(update.NodesLength()):
                buffer = update.Nodes(j)
                key, entry = decode_node(bytearray(buffer.NodeAsNumpy().tobytes()))
                decoded[0] += 1
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
    if mode in {"object", "edit_mesh", "sculpt", "weight_paint", "vertex_paint", "texture_paint"}:
        bpy.ops.object.select_all(action='DESELECT')
        cube.select_set(True)
        bpy.context.view_layer.objects.active = cube
        if mode == "edit_mesh":
            bpy.ops.object.mode_set(mode='EDIT')
            bpy.ops.mesh.select_all(action='SELECT')
        elif mode in {"sculpt", "weight_paint", "vertex_paint", "texture_paint"}:
            bpy.ops.object.mode_set(mode=mode.upper())
    elif mode == "edit_curve":
        bpy.ops.curve.primitive_bezier_curve_add(enter_editmode=True)
    elif mode == "edit_armature":
        bpy.ops.object.armature_add(enter_editmode=True)
    elif mode == "pose":
        bpy.ops.object.mode_set(mode='POSE')


def path_of(top):
    """The context path the tab sends (ROUND5 7B): its elements' names and icons."""
    node = next((n for n in (top or {}).get("children", []) if n["key"] == "path"), None)
    return [(n.get("label"), n.get("icon")) for n in (node or {}).get("children", [])]


def expected_path_end(tab):
    """The name the last element of a tab's context path must have, where the tab names it: the
    active object's, its data's or its material's; None where the tab is not checked by name."""
    ob = bpy.context.view_layer.objects.active
    if ob is None:
        return None
    if tab in {"OBJECT", "MODIFIER", "PARTICLES", "PHYSICS", "CONSTRAINT"}:
        return ob.name
    if tab == "DATA" and ob.data is not None:
        return ob.data.name
    if tab == "MATERIAL":
        return ob.active_material.name if ob.active_material else ob.name
    return None


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
            # Every tab but Tool and the sidebar's (which have none in Blender) sends Blender's
            # context path, ending in what the tab shows (ROUND5 7B).
            paths = {tab: path_of(top) for tab, top in trees.items() if top}
            path_problems = []
            for tab, path in paths.items():
                if tab == "TOOL" or tab.startswith("SIDEBAR:"):
                    if path:
                        path_problems.append("%s sends a path %s" % (tab, path))
                    continue
                if not path:
                    path_problems.append("%s sends no path" % tab)
                    continue
                expected = expected_path_end(tab)
                if expected is not None and path[-1][0] != expected:
                    path_problems.append("%s ends in %r, not %r" % (tab, path[-1][0], expected))
            entry = {"name": mode, "context": bpy.context.mode, "missing": missing,
                     "paths": paths, "path_problems": path_problems,
                     "nodes": {tab: count(top) for tab, top in trees.items() if top},
                     "item": labels(trees.get("SIDEBAR:Item") or {}),
                     "item_tree": trees.get("SIDEBAR:Item"),
                     "view": labels(trees.get("SIDEBAR:View") or {})}
            report["steps"].append(entry)
            if missing:
                report["error"] = "No view for " + ", ".join(missing) + " in " + mode
                finish("error")
                return None
            if path_problems:
                report["error"] = "Context path in " + mode + ": " + "; ".join(path_problems)
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


def numbers(node, out=None):
    """Every number under \a node: its property, label, value and precision."""
    out = [] if out is None else out
    if node.get("content") == "Number":
        out.append({k: node.get(k) for k in ("key", "property", "label", "value", "integer", "precision")})
    for child in node.get("children", []):
        numbers(child, out)
    return out


def tick_precision():
    """The decimals the bridge sends for numbers (ROUND5 6D): the Object tab's, and how many nodes
    each change of a value sends, before and after the value crosses a power of ten. The bridge
    needs a window, so this runs here rather than in the background tests."""
    global step
    try:
        pump()
        step += 1
        cube = bpy.data.objects["Cube"]
        if step == 1:
            enter("object")
            subs["OBJECT"] = subscribe("properties", tab="OBJECT", properties=True)
        elif step == 4:
            report["object"] = numbers(tree(subs["OBJECT"]) or {})
        if 6 <= step <= 10:
            # What the change made in the step before sent.
            report.setdefault("changes", []).append({
                "scale_x": cube.scale[0], "nodes_sent": decoded[0] - report["mark"],
                "shown": next((n for n in numbers(tree(subs["OBJECT"]) or {})
                               if n["property"] == "scale" and n["label"] == "X"), None)})
        if 5 <= step <= 9:
            # One change a step: the scale moves within 1-10, crosses 10, drops below 0.001, back.
            report["mark"] = decoded[0]
            cube.scale[0] = (1.25, 1.5, 12.5, 0.0004, 1.0)[step - 5]
            for area in bpy.context.screen.areas:
                area.tag_redraw()
        if step == 11:
            finish("done")
            return None
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.3


# Blender's header menus as the native menus ask for them, in Object and Edit Mode: the editor's
# menus (View, Select, Add, Object | Mesh, Vertex, Edge, Face, UV) and the top bar's Edit menu.
MENU_ROUTES = ("VIEW3D_MT_editor_menus", "TOPBAR_MT_edit", "VIEW3D_MT_view", "VIEW3D_MT_object_apply")


def branding_allowed():
    """`release/ios/branding_allowed.txt` as {(where, text)}: the "Blender" strings the app may show."""
    allowed = set()
    with open(ALLOWED, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            where, _reason, text = line.split(" | ", 2)
            allowed.add((where, text))
    return allowed


branding = {"menus": 0, "seen": set(), "unlisted": []}
# Links about Blender rather than this app, which the iPad's menus leave out (ROUND5 decision 35),
# and Help's links to Blender's support, community and contribution pages (8I.6, decision 46).
NOT_ON_IPAD = {"Release Notes", "Report a Bug", "Splash Screen", "About Blender", "Donate to Blender",
               "Support", "User Communities", "Get Involved"}
walk_state = {}  # subscription -> (route, menu idname, depth); `None` once read


def walk_branding(mode):
    """Read the menus the shell reads (the menu bar, the context menu, Import and Export), to depth 4,
    a few at a time. Labels holding "Blender" that are not on the allow-list for their menu go into
    `branding["unlisted"]`. True once every menu has been read."""
    if not walk_state:
        branding.setdefault("allowed", branding_allowed())
        # ROUND5 9E.4: the menus this mode's keys open too, as the keys view lists them.
        walk_state["keys"] = subscribe("keys")
        walk_state["seen_routes"] = set()
        return False
    if walk_state.get("keys") is not None:
        top = tree(walk_state["keys"])
        if top is None:
            return False
        lib.WM_native_ui_unsubscribe(walk_state["keys"])
        walk_state["keys"] = None
        key_menus = {}
        for row in top.get("children", []):
            call, _tab, answer = (row.get("value") or "").partition("\t")
            if answer.startswith("menu ") and answer.endswith(" poll"):
                key_menus[answer.split(" ")[1]] = \
                    "call_menu_pie" if call.startswith("WM_OT_call_menu_pie") else "call_menu"
            elif answer.startswith("document menu "):
                key_menus[answer.split(" ")[2]] = "call_menu"
        branding["key_menus"] = sorted(set(branding.get("key_menus", [])) | set(key_menus))
        # Asked for as a key asks, through the popup hook, so the interface may draw them.
        lib.WM_native_ui_test_install_hooks()
        for name, operator in key_menus.items():
            _call_menu(operator, name)
        roots = [("menubar", "menubar"), ("context", "context"),
                 ("TOPBAR_MT_file_import", "TOPBAR_MT_file_import"),
                 ("TOPBAR_MT_file_export", "TOPBAR_MT_file_export")] + [(name, name) for name in key_menus]
        for route, menu in roots:
            walk_state["seen_routes"].add(route)
            walk_state[subscribe("menu", route=route)] = (route, menu, 1)
        return False
    allowed = branding["allowed"]
    pending = 0
    for sub, entry in list(walk_state.items()):
        if sub in ("seen_routes", "keys") or entry is None:
            continue
        route, menu, depth = entry
        top = tree(sub)
        if top is None:
            pending += 1
            continue
        walk_state[sub] = None
        lib.WM_native_ui_unsubscribe(sub)
        branding["menus"] += 1
        for node in top.get("children", []):
            label = node.get("label") or ""
            params = node.get("params") or {}
            if label in NOT_ON_IPAD:
                branding["unlisted"].append("menu %s | %s (decision 35: not shown on iPad)" % (menu, label))
            if label == "Manual":
                branding["help_read"] = True
            # The app's old name is caught as "Blender" is (ROUND5 8I.1, decision 47).
            if "Blender" in label or "Platypus" in label:
                branding["seen"].add("menu %s | %s" % (menu, label))
                if ("menu " + menu, label) not in allowed:
                    branding["unlisted"].append("menu %s | %s" % (menu, label))
            child = params.get("route")
            if child and depth < 4 and node.get("enabled") and child not in walk_state["seen_routes"]:
                walk_state["seen_routes"].add(child)
                walk_state[subscribe("menu", route=child)] = (child, params.get("menu") or menu, depth + 1)
                pending += 1
    return pending == 0


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
            for sub in subs.values():
                lib.WM_native_ui_unsubscribe(sub)
            subs.clear()
            enter("object")
        elif step > 10:
            # ROUND5 8A.7: every label the shell can reach through the menus, in Object then Edit Mode.
            if walk_branding("object" if step < 200 else "edit_mesh"):
                if step < 200:
                    step = 199
                    enter("edit_mesh")
                    walk_state.clear()
                    return 0.25
                problems = sorted(set(branding["unlisted"]))
                if not branding.get("help_read"):
                    problems.append("the Help menu was not read (no Manual)")
                if not branding.get("key_menus"):
                    problems.append("no menu a key opens was read (ROUND5 9E.4)")
                report["branding"] = {"menus_read": branding["menus"], "key_menus": branding.get("key_menus", []),
                                      "labels_with_blender": sorted(branding["seen"]),
                                      "unlisted": problems}
                finish("done" if not problems else "error")
                return None
        if step > 400:
            finish("timeout")
            return None
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.25


# The mirror or symmetry axes in every mode whose header has them, as Blender names them there.
MIRROR_MODES = ("OBJECT", "EDIT", "SCULPT", "WEIGHT_PAINT", "VERTEX_PAINT", "TEXTURE_PAINT", "ARMATURE_EDIT", "POSE")


def tick_mirror():
    global step
    try:
        pump()
        step += 1
        if step == 1:
            subs["toolbar"] = subscribe("toolbar")
            bpy.ops.object.armature_add()
            report["armature"] = bpy.context.object.name
        index = (step - 2) // 4
        if step >= 2 and (step - 2) % 4 == 0 and index < len(MIRROR_MODES):
            mode = MIRROR_MODES[index]
            if bpy.context.mode != 'OBJECT':
                bpy.ops.object.mode_set(mode='OBJECT')
            if mode == "OBJECT":
                return 0.25
            name = report["armature"] if mode in {"ARMATURE_EDIT", "POSE"} else "Cube"
            ob = bpy.data.objects[name]
            bpy.ops.object.select_all(action='DESELECT')
            ob.select_set(True)
            bpy.context.view_layer.objects.active = ob
            bpy.ops.object.mode_set(mode='EDIT' if mode == "ARMATURE_EDIT" else mode)
        elif step >= 2 and (step - 2) % 4 == 3 and index < len(MIRROR_MODES):
            top = tree(subs["toolbar"]) or {}
            node = next((n for n in top.get("children", []) if n["key"] == "mirror"), None)
            # Blender's header widgets: snapping and proportional editing as a toggle and a
            # dropdown each, Auto Merge in Edit Mesh (ROUND5 Stage 5E).
            header = {n["key"]: n.get("value", n.get("options")) for n in top.get("children", [])
                      if n["key"] in {"snap_on", "snap_element", "proportional_on", "proportional_falloff",
                                      "automerge", "orientation", "pivot"}}
            report["steps"].append({"name": MIRROR_MODES[index], "context": bpy.context.mode,
                                    "mirror": node and {"label": node["label"], "options": node.get("options")},
                                    "header": header})
            if MIRROR_MODES[index] == "EDIT":
                # The header's new commands, as the shell sends them; checked a step later.
                for n, (target, text) in enumerate((("snap_on", "on"), ("snap_element", "vertex"),
                                                    ("proportional_on", "on"), ("proportional_falloff", "SHARP"),
                                                    ("automerge", "on"))):
                    set_text(subs["toolbar"], target, text, 900 + n)
            if index > 0 and MIRROR_MODES[index - 1] == "EDIT":
                ts = bpy.context.scene.tool_settings
                report["header_set"] = {"use_snap": ts.use_snap, "snap_elements": sorted(ts.snap_elements),
                                        "use_proportional_edit": ts.use_proportional_edit,
                                        "proportional_edit_falloff": ts.proportional_edit_falloff,
                                        "use_mesh_automerge": ts.use_mesh_automerge,
                                        "acks": {k: v for k, v in acks.items() if k >= 900}}
            if index == len(MIRROR_MODES) - 1:
                finish("done")
                return None
        if step > 60:
            finish("timeout")
            return None
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.25


# What the app shows after commands (ROUND5 Stage 2A, the reveal rules): each case runs an
# operator as the shell would and reads the toolbar's `reveal` answer. The iPad interface installs
# the after-command hook; here the test entry does.
def _reveal_cases():
    import bmesh  # noqa: F401
    def objects(*names):
        bpy.ops.object.mode_set(mode='OBJECT') if bpy.context.mode != 'OBJECT' else None
        bpy.ops.object.select_all(action='DESELECT')
        for name in names:
            bpy.data.objects[name].select_set(True)
        bpy.context.view_layer.objects.active = bpy.data.objects[names[-1]]
    return [
        ("modifier_add", lambda: (objects("Cube"), bpy.ops.object.modifier_add('EXEC_DEFAULT', True, type='SUBSURF'))),
        ("constraint_add", lambda: (objects("Cube"), bpy.ops.object.constraint_add('EXEC_DEFAULT', True, type='COPY_LOCATION'))),
        ("material_slot_add", lambda: (objects("Cube"), bpy.ops.object.material_slot_add('EXEC_DEFAULT', True))),
        ("vertex_group_add", lambda: (objects("Cube"), bpy.ops.object.vertex_group_add('EXEC_DEFAULT', True))),
        ("hide_view_set", lambda: (objects("Cube"), bpy.ops.object.hide_view_set('EXEC_DEFAULT', True))),
        ("hide_view_clear", lambda: bpy.ops.object.hide_view_clear('EXEC_DEFAULT', True)),
        ("parent_one_selected", lambda: (objects("Armature"), bpy.ops.object.parent_set('EXEC_DEFAULT', True, type='ARMATURE_AUTO'))),
        ("parent_auto_weights", lambda: (objects("Cube", "Armature"), bpy.ops.object.parent_set('EXEC_DEFAULT', True, type='ARMATURE_AUTO'))),
        ("light_add", lambda: bpy.ops.object.light_add('EXEC_DEFAULT', True, type='POINT')),
        ("subdivide", lambda: (objects("Cube"), bpy.ops.object.mode_set(mode='EDIT'),
                               bpy.ops.mesh.select_all(action='SELECT'),
                               bpy.ops.mesh.subdivide('EXEC_DEFAULT', True))),
        # ROUND5 9B.4: an unwrap shows its layout in the UV Editor; another UV command its settings.
        ("uv_unwrap", lambda: (objects("Cube"), bpy.ops.object.mode_set(mode='EDIT'),
                               bpy.ops.mesh.select_all(action='SELECT'),
                               bpy.ops.uv.unwrap('EXEC_DEFAULT', True, method='CONFORMAL'))),
        ("uv_smart_project", lambda: bpy.ops.uv.smart_project('EXEC_DEFAULT', True)),
    ]


# What each reveal case must show, where it is checked.
REVEAL_EXPECTED = {"uv_unwrap": "editor:uv", "uv_smart_project": "editor:uv"}


def _take_uvs():
    """The UVs the bridge published since the last look, or None (`WM_native_ui_image_take_uvs`): the
    edges' points and flags, the selected faces' corner counts, the active face, the cap."""
    taken = NativeImageUVs()
    if not lib.WM_native_ui_image_take_uvs(ctypes.byref(taken)):
        return None
    sizes = [taken.face_sizes[i] for i in range(taken.face_count)]
    values = {"edges": [round(taken.edges[i], 5) for i in range(taken.edge_count * 4)],
              "flags": [taken.edge_flags[i] for i in range(taken.edge_count)],
              "faces": [round(taken.faces[i], 5) for i in range(sum(sizes) * 2)],
              "face_sizes": sizes, "active": taken.active_face, "capped": taken.capped}
    lib.WM_native_ui_image_uvs_free(ctypes.byref(taken))
    return values


def _publish_uvs():
    """Blender's loop publishes the image editor's picture and UVs on the iPad (`engine_step`); here
    the harness calls it, then takes what was published, keeping the last."""
    image_update(bpy.context.as_pointer())
    taken = _take_uvs()
    if taken is not None:
        report["uv_publish"]["last"] = taken
    return report["uv_publish"].get("last")


def tick_reveal():
    global step
    try:
        pump()
        step += 1
        if step == 1:
            lib.WM_native_ui_test_install_hooks()
            subs["toolbar"] = subscribe("toolbar")
            bpy.ops.object.armature_add(location=(3, 0, 0))
            report["cases"] = _reveal_cases()
            report["case"] = 0
            return 0.25
        cases = report["cases"]
        index = report["case"]
        if step % 2 == 0 and index < len(cases):
            cases[index][1]()
        elif step % 2 == 1 and index < len(cases):
            top = tree(subs["toolbar"]) or {}
            node = next((n for n in top.get("children", []) if n["key"] == "reveal"), None)
            answer = json.loads(node["value"]) if node and node.get("value") else {}
            report["steps"].append({"name": cases[index][0],
                                    **{k: answer.get(k) for k in ("operator", "show", "text", "level", "why")}})
            report["case"] = index + 1
        if step > 160:
            del report["cases"]
            finish("timeout")
            return None
        if report["case"] >= len(cases):
            return _reveal_uv_editor()
    except Exception:
        report.pop("cases", None)
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.25


def _reveal_uv_editor():
    """ROUND5 9B.3, 9B.5, 9B.6: with the image editor shown and no image chosen, the bridge publishes
    the mesh's UVs; they follow an unwrap and come back on undo; Edit UVs in Desktop Interface lands
    on the UV Editing workspace, added from the startup file where the document has none."""
    state = report.setdefault("uv_publish", {"phase": "show", "wait": 0})
    problems = report.setdefault("problems", [])
    if state["wait"] > 0:
        state["wait"] -= 1
        return 0.25
    phase = state["phase"]
    if phase == "show":
        for name, expected in REVEAL_EXPECTED.items():
            seen = next((s.get("show") for s in report["steps"] if s["name"] == name), None)
            if seen != expected:
                problems.append("%s shows %r, not %r" % (name, seen, expected))
        subs["image"] = subscribe("image")
        enter("edit_mesh")
        state.update(phase="before", wait=3)
    elif phase == "before":
        state["before"] = _publish_uvs()
        if not state["before"]:
            problems.append("no UVs published with the image editor shown and no image chosen")
        bpy.ops.uv.unwrap('EXEC_DEFAULT', True, method='ANGLE_BASED')
        state.update(phase="after", wait=3)
    elif phase == "after":
        state["after"] = _publish_uvs()
        if state["after"] == state["before"]:
            problems.append("the published UVs did not follow uv.unwrap")
        window, area, region = _view3d()
        with bpy.context.temp_override(window=window, area=area, region=region):
            bpy.ops.ed.undo()
        state.update(phase="undone", wait=4)
    elif phase == "undone":
        state["undone"] = _publish_uvs()
        if state["undone"] != state["before"]:
            problems.append("the published UVs did not come back after ed.undo")
        report["uv_counts"] = {k: len((state.get(k) or {}).get("edges", [])) // 4 for k in ("before", "after", "undone")}
        # ROUND5 9G.3: one face selected changes the published flags and faces, not the edges; with
        # UV Sync Selection off only that face is published.
        bpy.context.scene.tool_settings.use_uv_select_sync = True
        bpy.ops.mesh.select_all(action='SELECT')
        state.update(phase="all", wait=3)
    elif phase == "all":
        state["all"] = _publish_uvs()
        import bmesh
        mesh = bpy.context.edit_object.data
        state["face_count"] = len(bmesh.from_edit_mesh(mesh).faces)
        bpy.ops.mesh.select_all(action='DESELECT')
        bm = bmesh.from_edit_mesh(mesh)
        bm.faces.ensure_lookup_table()
        bm.faces[0].select_set(True)
        bm.select_flush_mode()
        bmesh.update_edit_mesh(mesh)
        # A notifier, as a tap's selection sends one, without changing what is selected.
        bpy.ops.mesh.select_mode(type='FACE')
        state.update(phase="one", wait=3)
    elif phase == "one":
        state["one"] = _publish_uvs()
        bpy.context.scene.tool_settings.use_uv_select_sync = False
        state.update(phase="unsynced", wait=3)
    elif phase == "unsynced":
        state["unsynced"] = _publish_uvs()
        everything, one, unsynced = state["all"] or {}, state["one"] or {}, state["unsynced"] or {}
        report["uv_selection"] = {
            name: {"edges": len(v.get("edges", [])) // 4, "selected_edges": sum(1 for f in v.get("flags", []) if f & 1),
                   "faces": len(v.get("face_sizes", [])), "active": v.get("active"), "capped": v.get("capped")}
            for name, v in (("all", everything), ("one", one), ("sync_off", unsynced))}
        if one.get("edges") != everything.get("edges"):
            problems.append("selecting one face changed the published edges, not only their flags")
        if one.get("flags") == everything.get("flags"):
            problems.append("selecting one face did not change the published flags")
        if len(one.get("face_sizes", [])) != 1 or len(everything.get("face_sizes", [])) != state["face_count"]:
            problems.append("the selected faces published are not the selection: %s" % report["uv_selection"])
        if len(unsynced.get("edges", [])) // 4 != 4 or len(unsynced.get("face_sizes", [])) != 1:
            problems.append("with UV Sync Selection off the one selected face is not published alone: %s" %
                            report["uv_selection"])
        bpy.context.scene.tool_settings.use_uv_select_sync = True
        for key in ("before", "after", "undone", "last", "all", "one", "unsynced"):
            state.pop(key, None)
        # Edit UVs in Desktop Interface, on a document without the UV Editing workspace.
        workspace = bpy.data.workspaces.get("UV Editing")
        if workspace is not None and workspace != bpy.context.window.workspace:
            bpy.data.batch_remove([workspace])
        subs["settings"] = subscribe("settings")
        state.update(phase="desktop", wait=2)
    elif phase == "desktop":
        # ROUND5 9C: Blender's own interface at the app's size (75 % by default), the iPad's at its own.
        state["dpi_ipad"] = bpy.context.preferences.system.dpi
        set_bool(subs["settings"], "desktop_uv_editing", True, 960)
        state.update(phase="landed", wait=4)
    elif phase == "landed":
        window = bpy.context.window_manager.windows[0]
        top = tree(subs["settings"]) or {}
        desktop = next((n.get("value") for n in top.get("children", []) if n["key"] == "desktop"), None)
        report["desktop_uv_editing"] = {"ack": acks.get(960), "workspace": window.workspace.name,
                                        "desktop": desktop, "mode": bpy.context.mode}
        if acks.get(960) != "ok" or not window.workspace.name.startswith("UV Editing") or desktop is not True:
            problems.append("Edit UVs in Desktop Interface did not land on UV Editing in the desktop "
                            "interface: %s" % report["desktop_uv_editing"])
        dpi = bpy.context.preferences.system.dpi
        report["desktop_dpi"] = {"ipad": state["dpi_ipad"], "desktop": dpi,
                                 "ui_scale": bpy.context.preferences.view.ui_scale}
        if abs(dpi - state["dpi_ipad"] * 0.75) > 1:
            problems.append("Blender's own interface is not drawn at 75 %%: DPI %s in the iPad interface, %s in "
                            "the desktop one" % (state["dpi_ipad"], dpi))
        set_bool(subs["settings"], "desktop", False, 961)
        state.update(phase="back", wait=3)
    elif phase == "back":
        dpi = bpy.context.preferences.system.dpi
        report["desktop_dpi"]["back"] = dpi
        if dpi != state["dpi_ipad"]:
            problems.append("the iPad interface's DPI changed: %s, was %s" % (dpi, state["dpi_ipad"]))
        state.update(phase="done")
    elif phase == "done":
        report.pop("cases", None)
        finish("done" if not problems else "error")
        return None
    return 0.25


# The knife, as the Knife tool starts it: what the action bar offers while it waits (it must offer
# a way to end it), then Cancel through the bar.
def _view3d():
    for window in bpy.context.window_manager.windows:
        for area in window.screen.areas:
            if area.type == 'VIEW_3D':
                region = next(r for r in area.regions if r.type == 'WINDOW')
                return window, area, region
    return None


def _bar():
    top = tree(subs["toolbar"]) or {}
    row = next((n for n in top.get("children", []) if n["key"] == "actions"), {})
    return [(n["key"], n.get("label")) for n in row.get("children", [])]


def tick_knife():
    global step
    try:
        pump()
        step += 1
        if step == 1:
            lib.WM_native_ui_test_install_hooks()
            subs["toolbar"] = subscribe("toolbar")
            bpy.ops.object.mode_set(mode='EDIT')
        elif step == 3:
            report["before"] = _bar()
            window, area, region = _view3d()
            with bpy.context.temp_override(window=window, area=area, region=region):
                report["invoke"] = list(bpy.ops.mesh.knife_tool('INVOKE_DEFAULT'))
            report["modal_handlers"] = [h for h in ["running"]]
        elif step == 6:
            report["during"] = _bar()
            report["hint"] = next((n.get("value") for n in (tree(subs["toolbar"]) or {}).get("children", [])
                                   if n["key"] == "modal_hint"), None)
            keys = [k for k, _ in report["during"]]
            report["unique_keys"] = len(keys) == len(set(keys))
            # Cancel is Escape: the shell sends it as a key; through the bridge it is the same key.
            report["cancel_target"] = "modal:cancel" if "modal:cancel" in keys else None
            invoke(subs["toolbar"], "modalkey:ESC", 77)
        elif step == 9:
            report["after"] = _bar()
            report["ack"] = acks.get(77)
            report["mode"] = bpy.context.mode
            finish("done")
            return None
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.3


# ROUND6 0.2 (C3): the number pad types into a waiting operation. Move, X, `2.5`, Confirm, each sent
# as the pad sends it (`modalkey:`), puts the cube at x = 2.5: the digits reach the numeric input as
# a typed character, as a keyboard's does. Before, digits carried no character and did nothing.
def tick_numinput():
    global step
    try:
        pump()
        step += 1
        if step == 1:
            lib.WM_native_ui_test_install_hooks()
            subs["toolbar"] = subscribe("toolbar")
            cube = bpy.data.objects["Cube"]
            cube.location = (0.0, 0.0, 0.0)
            bpy.context.view_layer.objects.active = cube
            cube.select_set(True)
        elif step == 3:
            window, area, region = _view3d()
            with bpy.context.temp_override(window=window, area=area, region=region):
                report["invoke"] = list(bpy.ops.transform.translate('INVOKE_DEFAULT'))
        elif step in (5, 6, 7, 8):
            key = {5: "X", 6: "TWO", 7: "PERIOD", 8: "FIVE"}[step]
            invoke(subs["toolbar"], "modalkey:" + key, 80 + step)
        elif step == 9:
            invoke(subs["toolbar"], "modalkey:RET", 90)
        elif step == 12:
            location = tuple(round(v, 4) for v in bpy.data.objects["Cube"].location)
            report["location"] = location
            report["acks"] = {k: acks.get(k) for k in (85, 86, 87, 88, 90)}
            finish("done" if location == (2.5, 0.0, 0.0) else "error")
            return None
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.3


# ROUND6 0.3 (G1): Stop stops a render. An animation render holds a modal handler for as long as it
# runs, and a command that is not live waits for that to end. The render view's `cancel`, sent while
# it renders (past the first frames), must end the render job within a second.
def tick_render():
    global step
    try:
        pump()
        step += 1
        if step == 1:
            lib.WM_native_ui_test_install_hooks()
            subs["render"] = subscribe("render")
            scene = bpy.context.scene
            scene.render.resolution_percentage = 25
            scene.frame_start, scene.frame_end = 1, 2000
            report["engine"] = scene.render.engine
        elif step == 3:
            invoke(subs["render"], "animation", 100)
        elif step < 200 and "rendering_at" not in report:
            # Past its first frame, which compiles shaders and stops only once they are done.
            if bpy.app.is_job_running('RENDER') and bpy.context.scene.frame_current > 2:
                if "clear_sent" not in report:
                    # Each of the view's buttons is live or refused: Clear answers at once (and leaves
                    # a running render alone); rendering again is refused while this render's job
                    # runs, with its name (ROUND6 BUSY-2: refused, not queued to run afterwards).
                    invoke(subs["render"], "clear", 102)
                    invoke(subs["render"], "image", 103)
                    report["clear_sent"] = step
                    return 0.1
                if step < report["clear_sent"] + 8 and 102 not in acks:
                    return 0.1  # The view answers as it is next built, four times a second at most.
                report["clear_ack"] = acks.get(102)
                report["image_ack_while_rendering"] = acks.get(103)
                report["rendering_at"] = step
                invoke(subs["render"], "cancel", 101)
                report["cancel_sent"] = time.monotonic()
            return 0.1
        elif "rendering_at" not in report:
            report["error"] = "The render never started"
            finish("error")
            return None
        else:
            running = bpy.app.is_job_running('RENDER')
            elapsed = time.monotonic() - report["cancel_sent"]
            if not running or elapsed > 1.0:
                pump()
                report["cancel_ack"] = acks.get(101)
                report["stopped_after"] = round(elapsed, 2)
                report["job_running"] = running
                report["cancel_sent"] = None
                finish("done" if not running and acks.get(101) == "ok" and report["clear_ack"] == "ok" and
                       (report["image_ack_while_rendering"] or "").startswith("Wait for") else "error")
                return None
            return 0.05
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.3


# ROUND6 BUSY-3 (G5, D3, F10): an animation render keeps what it made, through the bridge as the
# iPad drives it (a window, the render as a job). Stop part way: the frames written are listed and on
# disk. Continue: only the missing frames render. A movie scene: the frames, then the scene's movie
# written by FFmpeg from a timer once the frames' job ended. Make Video of the first frames, with the
# scene now set to a movie: that movie (a refused codec can be changed and the video made again).
def _render_state():
    view = views.get(subs["render"], {"nodes": {}})
    nodes = view["nodes"]

    def value(key):
        node = nodes.get("state:" + key, {})
        return node.get("value")
    return value


def tick_render_keep():
    global step
    import os
    try:
        pump()
        step += 1
        scene = bpy.context.scene
        value = _render_state() if "render" in subs else None
        if step == 1:
            lib.WM_native_ui_test_install_hooks()
            subs["render"] = subscribe("render")
            scene.render.resolution_percentage = 25
            scene.frame_start, scene.frame_end = 1, 400
            scene.render.image_settings.file_format = 'PNG'
            report["folder"] = os.path.join(argv[0], "kept frames")
            report["movie_folder"] = os.path.join(argv[0], "movie frames")
            report["phase"] = "stop"
            return 0.3
        if step == 3:
            invoke(subs["render"], "animation:" + report["folder"], 700)
            report["sent"] = time.monotonic()
            return 0.1
        if step < 3:
            return 0.3
        state = value("state")
        if (value("id") or 0) <= report.get("sent_id", 0):
            state = "sent"  # What was shown before the command: its answer is still to come.
        if time.monotonic() - report["sent"] > 180:
            report["error"] = "timed out in phase %s at state %s" % (report["phase"], state)
            report["acks"] = {k: acks.get(k) for k in range(700, 708)}
            finish("error")
            return None
        if report["phase"] == "stop":
            if state == "rendering" and (value("done") or 0) >= 3 and "cancel_at" not in report:
                invoke(subs["render"], "cancel", 701)
                report["cancel_at"] = value("done")
            elif state == "cancelled":
                manifest = json.load(open(os.path.join(report["folder"], "Render.json")))
                files = sorted(name for name in os.listdir(report["folder"]) if name.startswith("Frame "))
                report["stopped"] = {"done": int(value("done")), "listed": len(manifest["frames"]), "files": len(files),
                                     "next": value("next"), "frames_said": len(value("frames") or [])}
                ok = (value("done") >= 3 and value("done") == len(manifest["frames"]) == len(files) ==
                      report["stopped"]["frames_said"] and value("next") == value("done") + 1)
                if not ok:
                    report["error"] = "the frames rendered before Stop are not all kept"
                    finish("error")
                    return None
                scene.frame_end = int(value("done")) + 2
                report["written"] = []
                bpy.app.handlers.render_write.append(lambda s, *_: report["written"].append(s.frame_current))
                invoke(subs["render"], "clear", 702)
                invoke(subs["render"], "continue:" + report["folder"], 703)
                report["phase"] = "continue"
                report["sent"] = time.monotonic()
                report["sent_id"] = value("id") or 0
            return 0.1
        if report["phase"] == "continue":
            if state == "done":
                report["continued"] = {"done": value("done"), "written": list(report["written"])}
                expected = [report["stopped"]["done"] + 1, report["stopped"]["done"] + 2]
                if report["written"] != expected or value("done") != report["stopped"]["done"] + 2:
                    report["error"] = "Continue did not render only the missing frames"
                    finish("error")
                    return None
                scene.frame_start, scene.frame_end = 1, 3
                scene.render.image_settings.media_type = 'VIDEO'
                scene.render.ffmpeg.format, scene.render.ffmpeg.codec = 'MPEG4', 'H264'
                invoke(subs["render"], "clear", 704)
                invoke(subs["render"], "animation:" + report["movie_folder"], 705)
                report["phase"] = "movie"
                report["phases_seen"] = []
                report["sent"] = time.monotonic()
                report["sent_id"] = value("id") or 0
            elif state in ("error", "cancelled"):
                report["error"] = "Continue ended %s: %s" % (state, value("message"))
                finish("error")
                return None
            return 0.1
        if report["phase"] == "movie":
            if state == "rendering" and value("phase") not in report["phases_seen"]:
                report["phases_seen"].append(value("phase"))
            if state == "done":
                video = value("video") or ""
                with open(video, "rb") as f:
                    head = f.read(8)
                report["movie"] = {"video": os.path.basename(video), "frames": len(value("frames") or []),
                                   "phases": report["phases_seen"]}
                # The video phase may pass between two looks: the movie's name says which it was.
                if (head[4:8] != b"ftyp" or not os.path.basename(video).startswith("Video ") or
                        not video.endswith(".mp4") or report["phases_seen"][:1] != ["frames"]):
                    report["error"] = "the scene's movie was not written after its frames"
                    finish("error")
                    return None
                invoke(subs["render"], "clear", 706)
                invoke(subs["render"], "video:" + report["folder"], 707)
                report["phase"] = "quick"
                report["sent"] = time.monotonic()
                report["sent_id"] = value("id") or 0
            elif state in ("error", "cancelled"):
                report["error"] = "the movie render ended %s: %s" % (state, value("message"))
                finish("error")
                return None
            return 0.1
        if report["phase"] == "quick":
            if state == "done":
                video = value("video") or ""
                report["quick"] = {"video": os.path.basename(video), "quick": value("quick"),
                                   "settings_kept": scene.render.image_settings.media_type == 'VIDEO' and
                                   scene.render.ffmpeg.format == 'MPEG4' and ".Render Video" not in bpy.data.scenes}
                finish("done" if video.endswith(".mp4") and report["quick"]["settings_kept"] else "error")
                return None
            if state in ("error", "cancelled"):
                report["error"] = "the quick video ended %s: %s" % (state, value("message"))
                finish("error")
                return None
            return 0.1
        return 0.1
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None


# Materials as the Material tab makes them (ROUND5 7D): with no slots, New makes one slot holding one
# material (C5); the slot's Link is sent with its role, can be set and reads back; the material's
# reference lists its actions; in Edit Mode, Assign gives the selected faces the active slot.
def _material_nodes():
    top = tree(subs["MATERIAL"]) or {}
    found = {}

    def walk(node):
        content, role = node.get("content"), node.get("role")
        if content == "Reference" and node["key"].endswith("active_material"):
            found["reference"] = node
        elif content == "Choice" and node.get("property") == "link":
            found["link"] = node
        elif content == "List" and "active_material_index" in node["key"]:
            found["list"] = node
        elif content == "Button" and "material_slot_assign" in node["key"]:
            found["assign"] = node
        for child in node.get("children", []):
            walk(child)
    walk(top)
    return found


def tick_material():
    global step
    try:
        pump()
        step += 1
        ob = bpy.data.objects["Cube"]
        if step == 1:
            enter("object")
            while ob.material_slots:
                bpy.ops.object.material_slot_remove()
            report["materials_before"] = len(bpy.data.materials)
            subs["MATERIAL"] = subscribe("properties", tab="MATERIAL", properties=True)
        elif step == 4:
            nodes = _material_nodes()
            report["no_slots"] = {"rows": len(nodes.get("list", {}).get("children", [])),
                                  "reference": nodes.get("reference", {}).get("key"),
                                  "path_icons": [icon for _name, icon in path_of(tree(subs["MATERIAL"]))]}
            # C5: New on the material's reference, as its ＋ New does.
            invoke(subs["MATERIAL"], nodes["reference"]["key"], 31, op=Op.Op.Add)
        elif step == 7:
            nodes = _material_nodes()
            reference = nodes.get("reference", {})
            report["after_new"] = {
                "ack": acks.get(31), "slots": len(ob.material_slots),
                "slot_material": ob.material_slots[0].material.name if ob.material_slots and
                ob.material_slots[0].material else None,
                "materials_made": len(bpy.data.materials) - report["materials_before"],
                "reference_actions": {k: reference.get(k) for k in
                                      ("name", "users", "can_new", "can_unlink", "can_single_user", "can_fake_user",
                                       "choices")},
                "link": nodes.get("link") and {k: nodes["link"].get(k) for k in ("key", "role", "value", "options")},
                "path_icons": [icon for _name, icon in path_of(tree(subs["MATERIAL"]))]}
            set_text(subs["MATERIAL"], nodes["link"]["key"], "OBJECT", 32)
        elif step == 10:
            nodes = _material_nodes()
            report["link_set"] = {"ack": acks.get(32), "slot_link": ob.material_slots[0].link,
                                  "sent": nodes.get("link", {}).get("value")}
            set_text(subs["MATERIAL"], nodes["link"]["key"], "DATA", 33)
        elif step == 12:
            report["link_back"] = {"ack": acks.get(33), "slot_link": ob.material_slots[0].link}
            # A second slot with a material of its own, active; face 0 alone selected.
            bpy.ops.object.material_slot_add()
            ob.material_slots[1].material = bpy.data.materials.new("Second")
            ob.active_material_index = 1
            mesh = ob.data
            for polygon in mesh.polygons:
                polygon.select = polygon.index == 0
                polygon.material_index = 0
            first = set(mesh.polygons[0].vertices)
            for vertex in mesh.vertices:
                vertex.select = vertex.index in first
            for edge in mesh.edges:
                edge.select = all(v in first for v in edge.vertices)
            bpy.ops.object.mode_set(mode='EDIT')
        elif step == 16:
            nodes = _material_nodes()
            report["edit_mode_buttons"] = nodes.get("assign", {}).get("key")
            invoke(subs["MATERIAL"], nodes["assign"]["key"], 34)
        elif step == 19:
            bpy.ops.object.mode_set(mode='OBJECT')
            report["assign"] = {"ack": acks.get(34),
                                "material_index": [p.material_index for p in ob.data.polygons]}
            problems = []
            if report["no_slots"]["rows"] != 0:
                problems.append("rows before New")
            if report["after_new"]["slots"] != 1 or report["after_new"]["materials_made"] != 1 or \
                    not report["after_new"]["slot_material"]:
                problems.append("New did not make one slot holding one material")
            if not report["after_new"]["link"] or report["after_new"]["link"]["role"] != 8:
                problems.append("the link is not sent with its role")
            if report["link_set"]["slot_link"] != "OBJECT" or report["link_set"]["sent"] != "OBJECT":
                problems.append("Link set to Object does not read back")
            if report["link_back"]["slot_link"] != "DATA":
                problems.append("Link set back to Data does not read back")
            actions = report["after_new"]["reference_actions"]
            if not (actions["can_new"] and actions["can_unlink"]):
                problems.append("the reference lists no New or Unlink")
            # ROUND5 7E/E6: the shell's Solid-view line keys on the material in the context path
            # (`ShadingHint.Entry.needs`): there with a material, absent with none.
            if "MATERIAL_DATA" in report["no_slots"]["path_icons"]:
                problems.append("the path names a material with no slot")
            if "MATERIAL_DATA" not in report["after_new"]["path_icons"]:
                problems.append("the path does not name the new material (MATERIAL_DATA)")
            if report["assign"]["material_index"][0] != 1 or any(report["assign"]["material_index"][1:]):
                problems.append("Assign did not give the selected face the active slot")
            report["problems"] = problems
            finish("done" if not problems else "error")
            return None
        if step > 40:
            finish("timeout")
            return None
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.3


# ROUND5 9A.8: a key never does nothing. In each mode, every item of the key-maps that apply in the
# 3D View, as the `keys` view reads them, with what its key does in the iPad interface: runs, a
# menu, a choice, a dialog, the rename field, a stand-in or a line that says so. Fails when (a) a
# key's menu passes its poll and, asked for as a key asks (`wm.call_menu`, the popup hook), comes
# back empty; (b) an item has no answer, or says nothing; (c) a stand-in names a command the shell
# does not have (`release/ios/key_stand_ins.txt`); (d) a file command (New, Open, Open Recent,
# Revert, Recover, Save, Save As, Quit, and the keys of File › New, Open Recent and the File context
# menu) answers anything but `document` (ROUND5 9D.4): in a document window they take the document's
# route, never load or write Blender's file. Then one item runs through the popup's own route:
# U's UV Mapping › Unwrap Angle Based, and the mesh's UVs must change.
KEY_MODES = ("object", "edit_mesh", "sculpt", "weight_paint", "vertex_paint", "texture_paint", "edit_curve",
             "edit_armature", "pose")
ANSWERS = ("runs", "menu ", "choice", "dialog", "rename", "stand-in ", "says ", "document ")
# ROUND5 9D.4: the file commands, which must answer `document`.
DOCUMENT_OPERATORS = ("WM_OT_read_homefile", "WM_OT_read_factory_settings", "WM_OT_open_mainfile",
                      "WM_OT_recover_last_session", "WM_OT_recover_auto_save", "WM_OT_revert_mainfile",
                      "WM_OT_save_mainfile", "WM_OT_save_as_mainfile", "WM_OT_quit_blender")
DOCUMENT_MENUS = ("TOPBAR_MT_file_new", "TOPBAR_MT_file_open_recent", "TOPBAR_MT_file_context_menu")


# ROUND5 9E.3: operators that only carry what a key opens or changes; a line naming one of these by
# its own name ("Call Asset Shelf Popover", "Context Enum Menu") says nothing a person knows.
CARRIERS = ("wm.call_menu", "wm.call_menu_pie", "wm.call_panel", "wm.call_asset_shelf_popover",
            "wm.context_menu_enum", "wm.context_pie_enum", "wm.context_toggle", "wm.context_toggle_enum",
            "screen.space_type_set_or_cycle")


def carrier_names():
    names = {}
    for path in CARRIERS:
        module, name = path.split(".")
        op = getattr(getattr(bpy.ops, module), name)
        names[op.idname()] = op.get_rna_type().name
    return names


def is_document_command(call):
    name = call.partition("(")[0]
    return name in DOCUMENT_OPERATORS or (
        name == "WM_OT_call_menu" and any('name="%s"' % menu in call for menu in DOCUMENT_MENUS))
keys_state = {"mode": 0, "phase": "enter", "wait": 0, "table": [], "problems": [], "menus": {}, "counts": {}}


def stand_ins():
    with open(STAND_INS, encoding="utf-8") as f:
        return {line.split(" | ", 1)[0] for line in f.read().splitlines() if line.strip() and not line.startswith("#")}


def _uvs():
    import bmesh
    mesh = bpy.data.objects["Cube"].data
    bm = bmesh.from_edit_mesh(mesh)
    layer = bm.loops.layers.uv.active
    return [tuple(round(c, 5) for c in loop[layer].uv) for face in bm.faces for loop in face.loops] if layer else []


def _call_menu(operator, name):
    window, area, region = _view3d()
    with bpy.context.temp_override(window=window, area=area, region=region):
        getattr(bpy.ops.wm, operator)(name=name)


def tick_keys():
    global step
    state = keys_state
    try:
        pump()
        step += 1
        if step == 1:
            lib.WM_native_ui_test_install_hooks()
            state["stand_ins"] = stand_ins()
            state["carriers"] = carrier_names()
            return 0.25
        if state["wait"] > 0:
            state["wait"] -= 1
            return 0.25
        if state["mode"] >= len(KEY_MODES):
            return _keys_uv_route()
        mode = KEY_MODES[state["mode"]]
        if state["phase"] == "enter":
            enter(mode)
            subs["keys"] = subscribe("keys")
            state.update(phase="read", wait=3)
        elif state["phase"] == "read":
            top = tree(subs["keys"]) or {}
            lib.WM_native_ui_unsubscribe(subs.pop("keys"))
            rows = top.get("children", [])
            if not rows:
                state["problems"].append("%s: the keys view listed no key-map items" % mode)
            state["menus"] = {}
            counts = state["counts"].setdefault(mode, {})
            for row in rows:
                keymap, _index = row["key"].split("\t", 1)
                call, _tab, answer = (row.get("value") or "").partition("\t")
                state["table"].append("%s | %s | %s | %s | %s" % (mode, keymap, row.get("label") or "", call, answer))
                kind = next((a.strip() for a in ANSWERS if answer == a or answer.startswith(a)), None)
                counts[kind or "none"] = counts.get(kind or "none", 0) + 1
                if is_document_command(call) and kind != "document":
                    state["problems"].append("%s: %s %s is a file command and answers %r, not document" %
                                             (mode, keymap, call, answer))
                if kind is None:
                    state["problems"].append("%s: %s %s has no answer (%r)" % (mode, keymap, call, answer))
                elif kind == "says" and not answer[len("says "):].strip():
                    state["problems"].append("%s: %s %s says nothing" % (mode, keymap, call))
                elif kind == "says" and call.partition("(")[0] in state["carriers"] and \
                        state["carriers"][call.partition("(")[0]] in answer:
                    state["problems"].append("%s: %s %s says the operator's generic name: %r" %
                                             (mode, keymap, call, answer))
                elif kind == "stand-in" and answer[len("stand-in "):] not in state["stand_ins"]:
                    state["problems"].append("%s: %s %s stands in for %r, which the shell does not have" %
                                             (mode, keymap, call, answer[len("stand-in "):]))
                elif kind == "menu":
                    _menu, name, poll = answer.split(" ")
                    if poll == "poll" and name not in state["menus"]:
                        operator = "call_menu_pie" if call.startswith("WM_OT_call_menu_pie") else "call_menu"
                        state["menus"][name] = operator
                elif kind == "document" and answer.startswith("document menu "):
                    # F4: the File context menu shows, its file commands taking the document's route.
                    state["menus"].setdefault(answer.split(" ")[2], "call_menu")
            # Asked for as a key asks: through the popup hook, which lets the interface draw it.
            for name, operator in state["menus"].items():
                _call_menu(operator, name)
                subs["menu " + name] = subscribe("menu", route=name)
            state.update(phase="check", wait=4)
        elif state["phase"] == "check":
            for name in state["menus"]:
                sub = subs.pop("menu " + name)
                items = [n for n in (tree(sub) or {}).get("children", []) if n.get("label")]
                lib.WM_native_ui_unsubscribe(sub)
                state["table"].append("%s | menu | %s | %d items" % (mode, name, len(items)))
                if not items:
                    state["problems"].append("%s: the menu %s passes its poll and shows no items" % (mode, name))
            state.update(mode=state["mode"] + 1, phase="enter")
        if step > 600:
            finish("timeout")
            return None
    except Exception:
        report["error"] = traceback.format_exc()
        report["table"] = state["table"]
        finish("error")
        return None
    return 0.25


def _keys_uv_route():
    """U in Edit Mode, through the popup's own route: the popup view names the menu and its title, the
    menu view lists it, and its Unwrap Angle Based changes the mesh's UVs."""
    state = keys_state
    uv = state.setdefault("uv", {"phase": "enter"})
    if uv["phase"] == "enter":
        enter("edit_mesh")
        subs["popup"] = subscribe("popup")
        uv["phase"] = "ask"
        state["wait"] = 2
    elif uv["phase"] == "ask":
        uv["before"] = _uvs()
        _call_menu("call_menu", "VIEW3D_MT_uv_map")
        uv["phase"] = "popup"
        state["wait"] = 2
    elif uv["phase"] == "popup":
        top = tree(subs["popup"]) or {}
        named = next((n.get("value") for n in top.get("children", []) if n["key"] == "menu"), None)
        uv["popup"] = {"title": top.get("label"), "menu": named}
        if named != "VIEW3D_MT_uv_map" or top.get("label") != "UV Mapping":
            state["problems"].append("U's popup is %r, not UV Mapping (VIEW3D_MT_uv_map)" % uv["popup"])
        subs["uvmenu"] = subscribe("menu", route=named or "VIEW3D_MT_uv_map")
        uv["phase"] = "run"
        state["wait"] = 2
    elif uv["phase"] == "run":
        items = (tree(subs["uvmenu"]) or {}).get("children", [])
        uv["items"] = [n.get("label") for n in items if n.get("label")]
        unwrap = next((n for n in items if n.get("label") == "Unwrap Angle Based"), None)
        if unwrap is None:
            state["problems"].append("UV Mapping has no Unwrap Angle Based: %s" % uv["items"])
        else:
            invoke(subs["uvmenu"], unwrap["key"], 950)
        uv["phase"] = "after"
        state["wait"] = 3
    elif uv["phase"] == "after":
        after = _uvs()
        uv["ack"] = acks.get(950)
        uv["changed"] = bool(after) and after != uv["before"]
        if uv["ack"] != "ok" or not uv["changed"]:
            state["problems"].append("Unwrap Angle Based through the popup's route did not change the UVs "
                                     "(ack %r, changed %r)" % (uv["ack"], uv["changed"]))
        del uv["before"]
        report.update(table=state["table"], counts=state["counts"], uv_route=uv, problems=state["problems"])
        finish("done" if not state["problems"] else "error")
        return None
    return 0.25


def tick_extensions():
    """ROUND5 8E.1: started offline as the iPad starts, online access stays off and cannot be turned
    on, and the bundled extension (LoopTools) still turns on and registers its operators."""
    global step
    try:
        step += 1
        if step == 1:
            system = bpy.context.preferences.system
            report["online_access"] = bpy.app.online_access
            report["override"] = bpy.app.online_access_override
            report["online_toggle_readonly"] = not system.bl_rna.properties["use_online_access"].is_readonly and \
                system.is_property_readonly("use_online_access")
            module = "bl_ext.system.looptools"
            report["enable"] = list(bpy.ops.preferences.addon_enable(module=module))
            report["enabled"] = module in bpy.context.preferences.addons
            report["operator"] = hasattr(bpy.types, "MESH_OT_looptools_bridge") or "looptools_bridge" in dir(bpy.ops.mesh)
            problems = [name for name, good in (
                ("online access is on", not report["online_access"]),
                ("not overridden", report["override"]),
                ("the online toggle can be changed", report["online_toggle_readonly"]),
                ("LoopTools did not turn on", report["enabled"]),
                ("LoopTools registered no operator", report["operator"])) if not good]
            report["problems"] = problems
            finish("done" if not problems else "error")
            return None
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.3


def _toolbar_floats(key):
    top = tree(subs["toolbar"]) or {}
    node = next((n for n in top.get("children", []) if n["key"] == key), None)
    return node["value"] if node and isinstance(node.get("value"), list) else None


def _gizmo_x():
    gizmo = _toolbar_floats("navigation_gizmo")
    return gizmo[0] if gizmo else None


def _parts():
    """ROUND5 12D: the navigation gizmo's parts as Blender placed them and the toolbar sends them:
    [kind, x, y, radius] in window pixels from the top left (kind 1 the axes, 2 zoom, 3 move, 4 camera,
    5 projection, 6 camera lock)."""
    values = _toolbar_floats("navigation_parts") or []
    return [values[i:i + 4] for i in range(0, len(values) - 3, 4)]


def _column():
    """The gizmo's column of buttons across the region, (left, right) in region pixels, or None."""
    region = _region()
    buttons = [p for p in _parts() if p[0] != 1]
    if not buttons:
        return None
    return (min(p[1] - p[3] for p in buttons) - region.x, max(p[1] + p[3] for p in buttons) - region.x)


def _clear_insets(insets, width, column):
    """ROUND5 12D.5: framing adds the gizmo's column to the inset on its side, as
    `WM_native_ui_view3d_frame_insets` does, while a fifth of the view is left showing."""
    import math
    leading, trailing = insets[0], insets[1]
    if column:
        left, right = column
        if (left + right) / 2.0 > width / 2.0:
            new = (leading, max(trailing, width - math.floor(left)))
        else:
            new = (max(leading, math.ceil(right)), trailing)
        if width - new[0] - new[1] >= width // 5:
            leading, trailing = new
    return (leading, trailing) + tuple(insets[2:])


def _frame_selected():
    """Frame Selected as the iPad's button runs it, at once (exec: no smooth view); what it chose."""
    window, area, region = _view3d()
    with bpy.context.temp_override(window=window, area=area, region=region):
        bpy.ops.view3d.view_selected()
    rv3d = region.data
    return {"distance": rv3d.view_distance, "location": list(rv3d.view_location)}


def _region():
    return _view3d()[2]


def _region_top_gap():
    """Window pixels above the 3D View's region, which the top bar's height counts from. The window's
    height in pixels is where its highest region ends (`Window.height` is in points)."""
    window, _area, region = _view3d()
    top = max(r.y + r.height for area in window.screen.areas for r in area.regions)
    return top - (region.y + region.height)


def _shown_centre():
    """Where the cube's centre is drawn, in region pixels, from the view's current matrices."""
    from bpy_extras.view3d_utils import location_3d_to_region_2d
    _window, _area, region = _view3d()
    point = location_3d_to_region_2d(region, region.data, bpy.data.objects["Cube"].matrix_world.translation)
    return [round(point.x, 1), round(point.y, 1)] if point else None


def tick_insets():
    """ROUND5 10B: the sidebars lie over the 3D View. With insets set, the region keeps its size, its
    visible part (where the navigation gizmo stands) and Frame Selected move into what is left
    showing; set back to none, all is as before."""
    global step
    try:
        pump()
        step += 1
        _window, _area, region = _view3d()
        size = [region.width, region.height]
        if step == 1:
            # The iPad interface, as the app registers it: without it Blender's own is all there is.
            lib.WM_native_ui_test_install_hooks()
            subs["toolbar"] = subscribe("toolbar")
            subs["settings"] = subscribe("settings")
            enter("object")
            report["default_view"] = list(_view3d()[2].data.view_rotation)
            for ob in bpy.context.view_layer.objects:
                ob.select_set(ob.name == "Cube")
            bpy.context.view_layer.objects.active = bpy.data.objects["Cube"]
        elif step == 4:
            report["before"] = {"size": size, "gizmo_x": _gizmo_x(), "column": _column(), "frame": _frame_selected()}
        elif step == 7:
            report["before"]["centre"] = _shown_centre()
            report["insets"] = [int(size[0] * 0.3), int(size[0] * 0.25)]
            # ROUND5 9G.4: the top bar and the controls along the bottom, from the window's top and
            # bottom, which the region fills here.
            report["bars"] = [int(size[1] * 0.2), int(size[1] * 0.1)]
            lib.WM_native_ui_viewport_insets_set(ctypes.c_float(report["insets"][0]), ctypes.c_float(report["insets"][1]))
            lib.WM_native_ui_top_bar_set(ctypes.c_float(report["bars"][0] + _region_top_gap()))
            lib.WM_native_ui_bottom_tray_set(ctypes.c_float(report["bars"][1] + _region().y))
        elif step == 10:
            report["with"] = {"size": size, "gizmo_x": _gizmo_x(), "column": _column(), "frame": _frame_selected()}
        elif step == 13:
            report["with"]["centre"] = _shown_centre()
            lib.WM_native_ui_viewport_insets_set(ctypes.c_float(0), ctypes.c_float(0))
            lib.WM_native_ui_top_bar_set(ctypes.c_float(0))
            lib.WM_native_ui_bottom_tray_set(ctypes.c_float(0))
        elif step == 16:
            report["after"] = {"size": size, "gizmo_x": _gizmo_x(), "column": _column(), "parts": _parts(),
                               "frame": _frame_selected()}
        elif step == 19:
            report["after"]["centre"] = _shown_centre()
            before, inset, after = report["before"], report["with"], report["after"]
            leading, trailing = report["insets"]
            top, bottom = report["bars"]
            width, height = before["size"]
            # Framing keeps clear of the gizmo's column of buttons too (ROUND5 12D.5).
            before_leading, before_trailing = _clear_insets((0, 0), width, before["column"])
            clear_leading, clear_trailing = _clear_insets((leading, trailing), width, inset["column"])
            shown = width - clear_leading - clear_trailing
            shown_y = height - top - bottom
            expected_x = (clear_leading + width - clear_trailing) / 2.0
            expected_y = (bottom + height - top) / 2.0
            expected_x0 = (before_leading + width - before_trailing) / 2.0
            ratio = min(width, height) / min(shown, shown_y)
            problems = []
            if inset["size"] != before["size"] or after["size"] != before["size"]:
                problems.append("the region's size changed: %s, %s, %s" % (before["size"], inset["size"], after["size"]))
            if None in (before["gizmo_x"], inset["gizmo_x"]) or abs((before["gizmo_x"] - inset["gizmo_x"]) - trailing) > 2:
                problems.append("the gizmo did not keep clear of the trailing inset: %s -> %s" %
                                (before["gizmo_x"], inset["gizmo_x"]))
            if after["gizmo_x"] != before["gizmo_x"]:
                problems.append("the gizmo did not come back: %s -> %s" % (before["gizmo_x"], after["gizmo_x"]))
            if not before["centre"] or abs(before["centre"][0] - expected_x0) > 2:
                problems.append("without insets the cube is not framed in the middle of what shows: %s, expected %.1f" %
                                (before["centre"], expected_x0))
            if not inset["centre"] or abs(inset["centre"][0] - expected_x) > 3 or \
                    abs(inset["centre"][1] - expected_y) > 3:
                problems.append("with insets the cube is not in the middle of what shows: %s, expected %.1f, %.1f" %
                                (inset["centre"], expected_x, expected_y))
            # How far is the corner fit's business (ROUND5 9G.5): the cases below.
            if abs(after["frame"]["distance"] - before["frame"]["distance"]) > 1e-4 or not after["centre"] or \
                    abs(after["centre"][0] - expected_x0) > 2:
                problems.append("without insets again the framing is not as before")
            report.update(expected_x=expected_x, expected_y=expected_y, expected_ratio=ratio, problems=problems)
            _fit_setup()
        elif step >= 20 and "fit_failed" not in report:
            if _fit_tick(step - 20):
                report["footprint_from"] = step + 1
        elif step >= 20:
            if _footprint_tick(step - report["footprint_from"]):
                finish("done" if not report["problems"] else "error")
                return None
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.3


# ROUND5 9G.5: after any framing command, in the iPad interface, every corner of the framed box is
# drawn inside the clear part of the view (less the sidebars, the top bar and the bottom controls'
# band), and the box is not framed too far away. A flat plane seen from the top keeps Blender's own
# distance. The default cube from the default view failed this before 9G.5.
# Set the view, let it draw (a projection's change reaches `is_persp` only then), frame, let it draw, measure.
FIT_TICKS = 5


def _fit_insets(name, size):
    width, height = size
    if name == "none":
        return (0, 0, 0, 0)
    if name == "sidebar":
        return (0, int(width * 0.25), 0, 0)
    return (int(width * 0.2), int(width * 0.25), int(height * 0.15), int(height * 0.12))


def _fit_set(insets):
    leading, trailing, top, bottom = insets
    lib.WM_native_ui_viewport_insets_set(ctypes.c_float(leading), ctypes.c_float(trailing))
    lib.WM_native_ui_top_bar_set(ctypes.c_float(top + _region_top_gap() if top else 0))
    band = ctypes.c_float(bottom + _region().y if bottom else 0)
    if BOTTOM_CONTROLS is not None:
        BOTTOM_CONTROLS(band)
        lib.WM_native_ui_bottom_tray_set(ctypes.c_float(0))
    else:
        lib.WM_native_ui_bottom_tray_set(band)


def _fit_setup():
    from math import pi
    from mathutils import Euler
    bpy.context.preferences.view.smooth_view = 0
    objects = {"cube": bpy.data.objects["Cube"]}
    bpy.ops.mesh.primitive_cube_add(location=(1, 2, 0.5), scale=(5, 0.5, 0.5))
    objects["bar"] = bpy.context.active_object
    bpy.ops.mesh.primitive_cube_add(location=(-2, 0, 1), scale=(0.5, 0.5, 5))
    objects["tower"] = bpy.context.active_object
    bpy.ops.mesh.primitive_monkey_add(location=(0.5, -1, 0.3))
    objects["suzanne"] = bpy.context.active_object
    bpy.ops.mesh.primitive_plane_add(size=2, location=(0, 0, 0))
    objects["plane"] = bpy.context.active_object
    report["fit_objects"] = {k: v.name for k, v in objects.items()}
    views = {
        "default": report["default_view"],
        "front": list(Euler((pi / 2, 0, 0)).to_quaternion()),
        "right": list(Euler((pi / 2, 0, pi / 2)).to_quaternion()),
        "top": [1.0, 0.0, 0.0, 0.0],
    }
    cases = []
    for target, view in (("cube", "default"), ("bar", "front"), ("bar", "right"), ("bar", "top"),
                         ("tower", "default"), ("suzanne", "default")):
        for persp in ("PERSP", "ORTHO"):
            for insets in ("none", "sidebar", "four"):
                cases.append({"target": target, "view": view, "persp": persp, "insets": insets})
    cases.append({"target": "plane", "view": "top", "persp": "PERSP", "insets": "none", "blender": True})
    report["fit_views"] = views
    report["fit_cases"] = cases
    report["fit"] = []


def _fit_box(ob):
    from mathutils import Vector
    world = [ob.matrix_world @ Vector(c) for c in ob.bound_box]
    lo = [min(v[i] for v in world) for i in range(3)]
    hi = [max(v[i] for v in world) for i in range(3)]
    return [Vector(((hi if i & 1 else lo)[0], (hi if i & 2 else lo)[1], (hi if i & 4 else lo)[2])) for i in range(8)]


def _fit_blender_distance(region, size):
    """`ED_view3d_radius_to_dist` with Blender's margin (1.4), in perspective, for a box whose longest
    side is \a size: the view's half angle has the tangent 18 / lens, doubled by the viewport's zoom."""
    lens = _view3d()[1].spaces.active.lens
    aspect = max(region.width, region.height) / min(region.width, region.height)
    return (size / 2.0) * 1.4 / (18.0 / lens * 2.0) * aspect


def _fit_tick(index):
    from bpy_extras.view3d_utils import location_3d_to_region_2d
    from mathutils import Quaternion
    cases = report["fit_cases"]
    case_index, phase = divmod(index, FIT_TICKS)
    if case_index >= len(cases):
        _fit_set((0, 0, 0, 0))
        failed = [r for r in report["fit"] if r["problems"]]
        report["fit_failed"] = len(failed)
        report["problems"] += ["%s %s %s %s: %s" % (r["target"], r["view"], r["persp"], r["insets"], "; ".join(r["problems"]))
                               for r in failed]
        return True
    case = cases[case_index]
    window, area, region = _view3d()
    rv3d = region.data
    size = [region.width, region.height]
    insets = _fit_insets(case["insets"], size)
    ob = bpy.data.objects[report["fit_objects"][case["target"]]]
    if phase == 0:
        _fit_set(insets)
        bpy.ops.object.select_all(action='DESELECT')
        ob.select_set(True)
        bpy.context.view_layer.objects.active = ob
        rv3d.view_perspective = case["persp"]
        rv3d.view_rotation = Quaternion(report["fit_views"][case["view"]])
        # From afar and off centre, so the result owes nothing to where the view was.
        rv3d.view_distance = 40.0
        rv3d.view_location = (3.0, -2.0, 1.0)
        return False
    if phase == 2:
        case["column"] = _column()
        case["frame"] = _frame_selected()
        return False
    if phase < FIT_TICKS - 1:
        return False
    if rv3d.is_perspective != (case["persp"] == "PERSP"):
        report["problems"].append("the view did not take %s before framing" % case["persp"])
    # The gizmo's column of buttons joins the inset on its side (ROUND5 12D.5).
    leading, trailing, top, bottom = _clear_insets(insets, size[0], case["column"])
    shown = (size[0] - leading - trailing, size[1] - top - bottom)
    points = [location_3d_to_region_2d(region, rv3d, c) for c in _fit_box(ob)]
    result = dict(case, distance=round(rv3d.view_distance, 4), region=size, clear=[leading, bottom, size[0] - trailing,
                                                                                    size[1] - top], problems=[])
    if None in points:
        result["problems"].append("a corner is behind the eye")
    else:
        xs = [p.x for p in points]
        ys = [p.y for p in points]
        result["corners"] = [[round(x, 1), round(y, 1)] for x, y in zip(xs, ys)]
        outside = [i for i, (x, y) in enumerate(zip(xs, ys))
                   if x < leading - 1 or x > size[0] - trailing + 1 or y < bottom - 1 or y > size[1] - top + 1]
        if outside:
            result["problems"].append("corners %s outside the clear part" % outside)
        fill = max((max(xs) - min(xs)) / shown[0], (max(ys) - min(ys)) / shown[1])
        result["fill"] = round(fill, 3)
        # Blender's own fit for the clear part is kept where it already shows everything (decision 71):
        # for a long box it leaves the box smaller than 60 %, and that is Blender's view, not a fault.
        own = _fit_blender_distance(region, max(ob.dimensions)) * min(size) / min(shown)
        result["blender_clear"] = round(own, 4)
        if fill < 0.6 and abs(rv3d.view_distance - own) > 1e-3 * own:
            result["problems"].append("framed too far away: %.0f %% of the tight side at %.4f, Blender's own %.4f" %
                                      (fill * 100, rv3d.view_distance, own))
    if case.get("blender"):
        dims = ob.dimensions
        expected = _fit_blender_distance(region, max(dims))
        result["blender_distance"] = round(expected, 4)
        if abs(rv3d.view_distance - expected) > 1e-3 * expected:
            result["problems"].append("not Blender's own distance: %.4f, expected %.4f" % (rv3d.view_distance, expected))
    report["fit"].append(result)
    return False


# ROUND5 12D (decision 79): where the navigation gizmo's parts are is told once, by the code that
# places them. In both styles and all four corners: the footprint the shell keeps clear of is the
# union of the parts, the hotspot's circle is the axes', the parts stand in the chosen corner, and the
# minimal style shows the axes alone.
FOOTPRINT_TICKS = 5
CORNERS = ("bottom_right", "bottom_left", "top_right", "top_left")


def _footprint_tick(index):
    cases = [(style, corner) for style in ("blender", "minimal") for corner in CORNERS]
    case_index, phase = divmod(index, FOOTPRINT_TICKS)
    command = 9000 + index
    if case_index >= len(cases):
        if phase == 0:
            set_text(subs["settings"], "navigation_style", "blender", command)
            set_text(subs["settings"], "navigation_corner", "bottom_right", command + 500)
        if phase < FOOTPRINT_TICKS - 1:
            return False
        return True
    style, corner = cases[case_index]
    if phase == 0:
        set_text(subs["settings"], "navigation_style", style, command)
        set_text(subs["settings"], "navigation_corner", corner, command + 500)
        return False
    if phase < FOOTPRINT_TICKS - 1:
        return False
    region = _region()
    parts = _parts()
    footprint = _toolbar_floats("navigation_footprint")
    gizmo = _toolbar_floats("navigation_gizmo")
    result = {"style": style, "corner": corner, "parts": parts, "footprint": footprint, "gizmo": gizmo,
              "problems": []}
    kinds = sorted(int(p[0]) for p in parts)
    if style == "minimal" and kinds != [1]:
        result["problems"].append("the minimal gizmo shows parts other than the axes: %s" % kinds)
    if style == "blender" and not {1, 2, 3, 4}.issubset(kinds):
        result["problems"].append("Blender's gizmo lacks its axes, zoom, move or camera: %s" % kinds)
    if not parts or not footprint:
        result["problems"].append("no parts or no footprint sent")
    else:
        union = [min(p[1] - p[3] for p in parts), min(p[2] - p[3] for p in parts),
                 max(p[1] + p[3] for p in parts), max(p[2] + p[3] for p in parts)]
        if any(abs(a - b) > 0.5 for a, b in zip(union, footprint)):
            result["problems"].append("the footprint %s is not the union of the parts %s" % (footprint, union))
        axes = next((p for p in parts if p[0] == 1), None)
        if not axes or not gizmo or any(abs(a - b) > 0.5 for a, b in zip(axes[1:], gizmo)):
            result["problems"].append("the hotspot's circle %s is not the axes' %s" % (gizmo, axes))
        # In the chosen corner: window pixels from the top left, the region from its own corner.
        top_px = _toolbar_window_height() - (region.y + region.height)
        middle = (region.x + region.width / 2.0, top_px + region.height / 2.0)
        for p in parts:
            right, below = p[1] > middle[0], p[2] > middle[1]
            if right != corner.endswith("right") or below != corner.startswith("bottom"):
                result["problems"].append("part %d at %.0f,%.0f is not in the %s corner" % (p[0], p[1], p[2], corner))
                break
    report.setdefault("footprints", []).append(result)
    report["problems"] += ["footprint %s %s: %s" % (style, corner, "; ".join(result["problems"]))
                           for _ in [0] if result["problems"]]
    return False


def _toolbar_window_height():
    """The window's height in pixels: where its highest region ends."""
    window = _view3d()[0]
    return max(r.y + r.height for area in window.screen.areas for r in area.regions)


# ROUND5 13A: what a finger meets, as the window manager's map says after a draw.
TOUCH = getattr(lib, "WM_native_ui_touch_query", None)
if TOUCH is not None:
    TOUCH.restype = ctypes.c_bool
    TOUCH.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_int), ctypes.c_char_p, ctypes.c_int]
    lib.WM_native_ui_touch_map_text.restype = ctypes.c_void_p
# `ButtonType`'s values (UI_interface_c.hh): the ones the scenario looks for.
BUTTON_NUM, BUTTON_TAB = 6, 16
TOUCH_KINDS = {0: "nothing", 1: "3D View", 2: "canvas", 3: "interface", 4: "navigation"}
TOUCH_TAKES = {0: "none", 1: "x", 2: "y", 3: "both"}


def _touch(x, y):
    """Blender's answer at a point of the window, in its pixels from the bottom left."""
    values = (ctypes.c_int * 6)()
    where = ctypes.create_string_buffer(40)
    found = TOUCH(int(x), int(y), values, where, 40)
    return {"at": [int(x), int(y)], "found": bool(found), "kind": TOUCH_KINDS.get(values[0], values[0]),
            "part": values[1], "scroll_x": bool(values[2]), "scroll_y": bool(values[3]),
            "takes": TOUCH_TAKES.get(values[4], values[4]), "button_type": values[5],
            "where": where.value.decode()}


def _touch_map():
    """The map's zones and buttons: [(where, type or 'zone', takes or kind, (xmin, ymin, xmax, ymax))]."""
    pointer = lib.WM_native_ui_touch_map_text()
    text = ctypes.string_at(pointer).decode()
    lib.free(ctypes.c_void_p(pointer))
    rows = []
    for line in text.splitlines():
        where, kind, takes, rect = line.split("|")
        rows.append((where, kind, takes, tuple(int(v) for v in rect.split())))
    return rows


def _centre(rect):
    return ((rect[0] + rect[2]) / 2.0, (rect[1] + rect[3]) / 2.0)


def _point_answering(rect, where):
    """A point of \a rect where the map answers \a where: places overlap (a corner over an edge, the
    time scrub over its region), and the map answers the one Blender would take first."""
    steps = [0.5] + [i / 20.0 for i in range(1, 20) if i != 10]
    for fy in steps:
        for fx in steps:
            point = (rect[0] + (rect[2] - rect[0]) * fx, rect[1] + (rect[3] - rect[1]) * fy)
            if _touch(*point)["where"] == where:
                return point
    return _centre(rect)


touch_state = {}
# `ButtonType::ListRow`'s value (UI_interface_c.hh).
BUTTON_LISTROW = 30
# ROUND6 DESK-4 (H8): each editor's main region as a finger meets it. Lists of rows are interface (a
# drag scrolls, a tap presses), as is text; what is drawn on, panned or zoomed is a canvas.
TOUCH_EDITORS = [
    ("OUTLINER", "interface"), ("FILES", "interface"), ("SPREADSHEET", "interface"), ("INFO", "interface"),
    ("TEXT_EDITOR", "interface"), ("CONSOLE", "interface"), ("PROPERTIES", "interface"),
    ("PREFERENCES", "interface"),
    ("UV", "canvas"), ("IMAGE_EDITOR", "canvas"), ("ShaderNodeTree", "canvas"), ("DOPESHEET", "canvas"),
    ("FCURVES", "canvas"), ("NLA_EDITOR", "canvas"), ("SEQUENCE_EDITOR", "canvas"), ("CLIP_EDITOR", "canvas"),
    ("VIEW_3D", "3D View"),
]


def tick_touch():
    """ROUND5 13A, check 2: Blender's answers in its own interface (Layout, factory settings): a
    header, a number field, a panel's empty space, the toolbar, the 3D View, the top bar's tabs and a
    menu. Each is checked against what 13A says it is."""
    global step
    try:
        pump()
        step += 1
        if TOUCH is None:
            report["problems"] = ["this build has no WM_native_ui_touch_query"]
            finish("error")
            return None
        if step == 1:
            # As the app has it: the iPad interface registered, then Blender's own interface
            # (Desktop Interface) switched on, which brings Blender's own layout back.
            lib.WM_native_ui_test_install_hooks()
            subs["settings"] = subscribe("settings")
            return 0.5
        if step == 2:
            set_bool(subs["settings"], "desktop", True, 1300)
            return 1.0
        if step < 6:
            return 0.5
        rows = _touch_map()
        zones = {where: rect for where, kind, _takes, rect in rows if kind == "zone"}
        buttons = [(where, int(kind), takes, rect) for where, kind, takes, rect in rows if kind != "zone"]
        problems = report.setdefault("problems", [])
        cases = report.setdefault("cases", {})

        def expect(name, point, kind, takes=None, scroll=None):
            answer = _touch(*point)
            cases[name] = answer
            if answer["kind"] != kind:
                problems.append("%s: %s, expected %s" % (name, answer["kind"], kind))
            if takes is not None and answer["takes"] != takes:
                problems.append("%s: takes %s, expected %s" % (name, answer["takes"], takes))
            if scroll is not None:
                axis, value = scroll
                if answer["scroll_" + axis] != value:
                    problems.append("%s: scroll %s is %s, expected %s" % (name, axis, answer["scroll_" + axis], value))
            return answer

        if step == 6:
            report["zones"] = sorted(zones)
            report["areas"] = [(a.type, [(r.type, r.x, r.y, r.width, r.height) for r in a.regions])
                               for a in _view3d()[0].screen.areas]
            report["button_count"] = len(buttons)
            header = next(rect for where, _t, _k, rect in buttons if where == "VIEW_3D HEADER")
            expect("a header (the 3D View's first button)", _centre(header), "interface", takes="none")
            numbers = [rect for where, kind, _k, rect in buttons if where == "PROPERTIES WINDOW" and kind == BUTTON_NUM]
            if not numbers:
                problems.append("no number field in Properties' map")
            else:
                expect("a number field (Properties)", _centre(numbers[0]), "interface", takes="x")
            headers = [rect for where, kind, _k, rect in buttons if where == "PROPERTIES WINDOW" and kind == -2]
            if not headers:
                problems.append("no panel header in Properties' map")
            else:
                expect("a panel's header (Properties)", _centre(headers[0]), "interface", takes="none")
            properties = zones["PROPERTIES WINDOW"]
            props_buttons = [rect for where, _t, _k, rect in buttons if where == "PROPERTIES WINDOW"]
            # A point of Properties under no button and no panel header: a panel's empty space.
            empty = None
            for y in range(properties[3] - 4, properties[1], -3):
                for x in (properties[0] + 6, properties[0] + 10):
                    if not any(r[0] <= x <= r[2] and r[1] <= y <= r[3] for r in props_buttons):
                        empty = (x, y)
                        break
                if empty:
                    break
            expect("a panel's empty space (Properties)", empty, "interface", takes="none")
            tools = next(rect for where, _t, _k, rect in buttons if where == "VIEW_3D TOOLS")
            expect("the toolbar (a tool)", _centre(tools), "interface", takes="none")
            expect("the 3D View", _centre(zones["VIEW_3D WINDOW"]), "3D View")
            tabs = [rect for where, kind, _k, rect in buttons if where == "TOPBAR HEADER" and kind == BUTTON_TAB]
            if not tabs:
                problems.append("no workspace tab in the top bar's map")
            else:
                expect("the top bar's last workspace tab", _centre(tabs[-1]), "interface", takes="none")
            timeline = zones.get("DOPESHEET_EDITOR WINDOW")
            if timeline:
                expect("the timeline (a canvas)", _point_answering(timeline, "DOPESHEET_EDITOR WINDOW"), "canvas")
            # Properties scrolls along y exactly when its content is longer than the region.
            _window = _view3d()[0]
            area = next(a for a in _window.screen.areas if a.type == 'PROPERTIES')
            region = next(r for r in area.regions if r.type == 'WINDOW')
            report["properties_region"] = [region.width, region.height]
            _call_menu("call_menu", "VIEW3D_MT_add")
            return 0.6
        if step == 7:
            menu = zones.get("MENU")
            if not menu:
                problems.append("no menu in the map after opening Add")
            else:
                answer = expect("a menu (Add)", _centre(menu), "interface", takes="none")
                report["menu_rect"] = list(menu)
                report["menu_scrolls"] = answer["scroll_y"]
            # Outside every area: nothing.
            expect("outside the window", (-50, -50), "nothing")
            # A Properties tab longer than the region: it scrolls along y now, and not along x.
            _window = _view3d()[0]
            cube = bpy.data.objects["Cube"]
            bpy.context.view_layer.objects.active = cube
            for index in range(12):
                # Panels as long as twelve Bevels', without evaluating twelve stacked Bevels (100 to
                # 135 s on this Mac, which stopped the scenario at its 300 s limit).
                cube.modifiers.new("Bevel %d" % index, 'BEVEL').show_viewport = False
            area = next(a for a in _window.screen.areas if a.type == 'PROPERTIES')
            area.spaces[0].context = 'MODIFIER'
            for _a in _window.screen.areas:
                _a.tag_redraw()
            return 0.8
        if step == 8:
            expect("Properties on Modifiers (12 Bevels), longer than the region", _centre(zones["PROPERTIES WINDOW"]),
                   "interface", scroll=("y", True))
            expect("Properties on Modifiers, not wider than the region", _centre(zones["PROPERTIES WINDOW"]),
                   "interface", scroll=("x", False))
            # ROUND6 DESK-4 (H9): what the screen takes before a region, in Blender's order, each the
            # control's both ways: an area's corner, an edge between areas, a region's edge, a
            # scroll-bar, the time scrub.
            places = {}
            for where, rect in zones.items():
                for suffix in (" AREA CORNER", "AREA EDGE", " REGION EDGE", " SCROLLBAR", " TIME SCRUB"):
                    # One of each that the map answers as itself somewhere: an area's corner may
                    # cover a small region's edge, as it takes the press first in Blender too.
                    if where.endswith(suffix) and suffix not in places and \
                            _touch(*_point_answering(rect, where))["where"] == where:
                        places[suffix] = (where, rect)
            report["screen places"] = sorted(where for where in zones if any(
                where.endswith(suffix) for suffix in (" AREA CORNER", "AREA EDGE", " REGION EDGE", " SCROLLBAR", " TIME SCRUB")))
            for suffix in (" AREA CORNER", "AREA EDGE", " REGION EDGE", " SCROLLBAR", " TIME SCRUB"):
                if suffix not in places:
                    problems.append("DESK-4: no%s in the map" % suffix)
                    continue
                where, rect = places[suffix]
                answer = expect("DESK-4: %s" % where, _point_answering(rect, where), "interface", takes="both")
                if answer["where"] != where:
                    problems.append("DESK-4: %s answers as %s: a region before it" % (where, answer["where"]))
            # Material slots: a list whose rows Blender drags away.
            properties_area = next(a for a in _view3d()[0].screen.areas if a.type == 'PROPERTIES')
            properties_area.spaces[0].context = 'MATERIAL'
            properties_area.tag_redraw()
            return 0.8
        if step == 9:
            # A row Blender drags away takes no drag: a scroll begins there, the drag after a hold.
            rows = [rect for where, kind, _k, rect in buttons if kind in (BUTTON_LISTROW, 35, 48)]
            report["list rows in the map"] = len(rows)
            report["Properties' button types on Material"] = sorted({kind for where, kind, _k, _r in buttons
                                                                    if where == "PROPERTIES WINDOW"})
            if not rows:
                # Not every layout shows one; the closed list says what rows take (sources sweep).
                report["no list row, preview or view item in the map"] = True
            for rect in rows[:1]:
                expect("DESK-4: a list's row (material slots)", _centre(rect), "interface", takes="none")
            # ROUND6 DESK-4 (H8): every editor's main region is placed, row lists as interface.
            touch_state["editors"] = list(TOUCH_EDITORS)
            touch_state["area"] = next(a for a in _view3d()[0].screen.areas if a.type == 'DOPESHEET_EDITOR')
            return 0.1
        editors = touch_state.get("editors")
        if editors is not None:
            area = touch_state["area"]
            if "checking" in touch_state:
                ui_type, kind = touch_state.pop("checking")
                region = next(r for r in area.regions if r.type == 'WINDOW')
                rect = (region.x, region.y, region.x + region.width, region.y + region.height)
                answer = expect("DESK-4: %s's main region" % ui_type,
                                _point_answering(rect, "%s WINDOW" % area.type), kind)
                cases["DESK-4: %s's main region" % ui_type]["ui_type"] = ui_type
            if editors:
                ui_type, kind = editors.pop(0)
                area.ui_type = ui_type
                area.tag_redraw()
                touch_state["checking"] = (ui_type, kind)
                return 0.5
            area.ui_type = 'TIMELINE'
            finish("done" if not problems else "error")
            return None
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.3


# ROUND6 TOUCH (run with `--enable-event-simulate`, which `mac_bridge_check.py` passes for it): what
# Blender tells a finger landing in a 3D View besides the place. TOUCH-1: with the Move tool, the
# cursor put on the object's origin lights up the gizmo's handle there, and the answer says so at
# that point only; in empty space it does not. TOUCH-2: an operator waiting for a click is said.
TOUCH_WINDOW = getattr(lib, "WM_native_ui_touch_window_query", None)
if TOUCH_WINDOW is not None:
    TOUCH_WINDOW.restype = ctypes.c_bool
    TOUCH_WINDOW.argtypes = [ctypes.POINTER(ctypes.c_int)]
fingers_state = {}
ESCAPE_OPS = getattr(lib, "WM_native_ui_escape_cancel_operators", None)


def _touch_window():
    values = (ctypes.c_int * 4)()
    found = TOUCH_WINDOW(values)
    return {"found": bool(found), "modal": bool(values[0]), "gizmo": bool(values[1]),
            "cursor": [values[2], values[3]]}


def _simulate(window, kind, value, x, y):
    window.event_simulate(type=kind, value=value, x=int(x), y=int(y))


def tick_fingers():
    global step
    try:
        pump()
        step += 1
        problems = report.setdefault("problems", [])
        if TOUCH_WINDOW is None:
            problems.append("this build has no WM_native_ui_touch_window_query")
            finish("error")
            return None
        window, area, region = _view3d()
        if step == 1:
            lib.WM_native_ui_test_install_hooks()
            subs["toolbar"] = subscribe("toolbar")
            cube = bpy.data.objects["Cube"]
            bpy.context.view_layer.objects.active = cube
            cube.select_set(True)
            with bpy.context.temp_override(window=window, area=area, region=region):
                bpy.ops.wm.tool_set_by_id(name="builtin.move")
            return 0.5
        if step == 2:
            from bpy_extras import view3d_utils
            rv3d = area.spaces[0].region_3d
            origin = view3d_utils.location_3d_to_region_2d(region, rv3d, bpy.data.objects["Cube"].location)
            fingers_state["origin"] = (region.x + origin.x, region.y + origin.y)
            _simulate(window, 'MOUSEMOVE', 'NOTHING', *fingers_state["origin"])
            return 0.6
        if step == 3:
            answer = _touch_window()
            report["on the handle"] = answer
            if not answer["gizmo"]:
                problems.append("TOUCH-1: the cursor on the Move gizmo's centre lights no handle in the answer")
            if answer["modal"]:
                problems.append("TOUCH-2: an operator is said to wait before any runs")
            _simulate(window, 'MOUSEMOVE', 'NOTHING', region.x + 12, region.y + 12)
            return 0.6
        if step == 4:
            answer = _touch_window()
            report["empty space"] = answer
            if answer["gizmo"]:
                problems.append("TOUCH-1: empty space is said to be a gizmo's handle")
            with bpy.context.temp_override(window=window, area=area, region=region):
                report["translate"] = list(bpy.ops.transform.translate('INVOKE_DEFAULT'))
            return 0.6
        if step == 5:
            answer = _touch_window()
            report["waiting move"] = answer
            if not answer["modal"]:
                problems.append("TOUCH-2: a waiting Move is not said")
            _simulate(window, 'ESC', 'PRESS', region.x + 12, region.y + 12)
            _simulate(window, 'ESC', 'RELEASE', region.x + 12, region.y + 12)
            return 0.6
        if step == 6:
            answer = _touch_window()
            report["after Escape"] = answer
            if answer["modal"]:
                problems.append("TOUCH-2: Move is said to wait after Escape ended it")
            # TOUCH-2's class: every operator whose modal key map cancels on Escape and answers the
            # left button. Each that starts here from a timer, in the mode its name suggests, must be
            # said to wait as it runs (the window then withdraws a press without Escape), and end.
            ESCAPE_OPS.restype = ctypes.c_void_p
            pointer = ESCAPE_OPS()
            text = ctypes.string_at(pointer).decode()
            lib.free(ctypes.c_void_p(pointer))
            members = [line.split("|") for line in text.splitlines() if line]
            report["escape class"] = len(members)
            names = {idname for idname, _keymap in members}
            for needed in ("MESH_OT_knife_tool", "TRANSFORM_OT_translate"):
                if needed not in names:
                    problems.append("TOUCH-2: %s is missing from the Escape class" % needed)
            fingers_state["queue"] = sorted(names)
            fingers_state["started"], fingers_state["not started"] = [], {}
            return 0.3
        queue = fingers_state.get("queue")
        if queue is None:
            return 0.3
        current = fingers_state.get("current")
        if current:
            answer = _touch_window()
            if not answer["modal"]:
                problems.append("TOUCH-2: %s runs and is not said to wait" % current)
            _simulate(window, 'ESC', 'PRESS', region.x + 12, region.y + 12)
            _simulate(window, 'ESC', 'RELEASE', region.x + 12, region.y + 12)
            fingers_state["current"] = None
            fingers_state["ending"] = current
            return 0.4
        ending = fingers_state.pop("ending", None)
        if ending and _touch_window()["modal"]:
            # Not every member ends on Escape alone (a confirm step, a popup): ended by the harness.
            fingers_state["not started"].setdefault("still running after Escape", []).append(ending)
            _simulate(window, 'RIGHTMOUSE', 'PRESS', region.x + 12, region.y + 12)
            _simulate(window, 'RIGHTMOUSE', 'RELEASE', region.x + 12, region.y + 12)
            return 0.4
        while queue:
            idname = queue.pop(0)
            module, name = idname.split("_OT_")
            operator = getattr(getattr(bpy.ops, module.lower()), name)
            mode = 'OBJECT'
            if module in ("MESH",):
                mode = 'EDIT'
            elif module in ("SCULPT", "PAINT"):
                mode = 'SCULPT'
            if bpy.context.object and bpy.context.object.mode != mode:
                bpy.ops.object.mode_set(mode=mode)
            with bpy.context.temp_override(window=window, area=area, region=region):
                if not operator.poll():
                    fingers_state["not started"].setdefault("poll fails here", []).append(idname)
                    continue
                try:
                    result = operator('INVOKE_DEFAULT')
                except Exception as error:
                    fingers_state["not started"].setdefault("refused", []).append("%s: %s" % (idname, str(error).splitlines()[0][:80]))
                    continue
            if 'RUNNING_MODAL' in result:
                fingers_state["started"].append(idname)
                fingers_state["current"] = idname
                return 0.4
            fingers_state["not started"].setdefault("did not wait", []).append(idname)
        if bpy.context.object and bpy.context.object.mode != 'OBJECT':
            bpy.ops.object.mode_set(mode='OBJECT')
        report["escape class started"] = fingers_state["started"]
        report["escape class not started"] = fingers_state["not started"]
        if len(fingers_state["started"]) < 3:
            problems.append("TOUCH-2: fewer than three of the Escape class started; the sweep proves little")
        finish("done" if not problems else "error")
        return None
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.3


# ROUND6 TOUCH-3 (C2, A12): undo and redo while an operation waits. The two-finger tap reached the
# key map, where a waiting move passed it to `ed.undo`; the gate is now one, the shell's: Undo and
# Redo (buttons, taps, the palette) are refused with a word while a modal operator exists, and run
# when none does. For each of a set of operations that wait, `ED_OT_undo` through the operators view
# (as the shell sends it, before the operation ends) must leave the undo stack where it was; the
# old way in, the TOUCH_TWO_FINGER_TAP event, must not move it either.
UNDO_CASES = [("OBJECT", "transform.translate"), ("OBJECT", "transform.rotate"), ("OBJECT", "transform.resize"),
              ("EDIT", "mesh.knife_tool"), ("EDIT", "transform.translate"), ("EDIT", "mesh.bevel"),
              ("OBJECT", "view3d.walk")]
undo_state = {}


def _menu_state():
    top = tree(subs["toolbar"]) or {}
    node = next((n for n in top.get("children", []) if n["key"] == "menu_state"), {})
    return node.get("value")


def _undo_behind():
    """What an undo would change, read after the operation ended: the undo stack's place (the
    toolbar's `menu_state`) and the cube's x, which the harness moved by one as the step behind."""
    return (_menu_state(), round(bpy.data.objects["Cube"].location.x, 4))


def tick_undo():
    global step
    try:
        pump()
        step += 1
        problems = report.setdefault("problems", [])
        window, area, region = _view3d()
        if step == 1:
            lib.WM_native_ui_test_install_hooks()
            subs["toolbar"] = subscribe("toolbar")
            subs["operators"] = subscribe("operators")
            cube = bpy.data.objects["Cube"]
            bpy.context.view_layer.objects.active = cube
            cube.select_set(True)
            # A step to undo to.
            cube.location.x += 1.0
            bpy.ops.ed.undo_push(message="harness move")
            undo_state["cases"] = list(UNDO_CASES)
            undo_state["results"] = {}
            return 0.5
        phase = undo_state.get("phase", "start")
        if phase == "start" and "steps_before" in undo_state:
            # After the operation ended: had undo run, the undo stack has fewer steps behind it now.
            behind = _undo_behind()
            entry = undo_state["results"][undo_state["current"]]
            entry["undone after it ended"] = behind[1] != undo_state.pop("steps_before")[1]
            if entry["undone after it ended"]:
                problems.append("%s: an Undo sent while it waited ran after it ended" % undo_state["current"])
        if phase == "start":
            if not undo_state["cases"]:
                if "control" not in undo_state:
                    # With nothing waiting, Undo runs: the harness's move by one is taken back.
                    if bpy.context.object.mode != 'OBJECT':
                        bpy.ops.object.mode_set(mode='OBJECT')
                    undo_state["control"] = 600
                    undo_state["x before control"] = round(bpy.data.objects["Cube"].location.x, 4)
                    invoke(subs["operators"], "ED_OT_undo", 600)
                    return 0.8
                undo_state["control waits"] = undo_state.get("control waits", 0) + 1
                if 600 not in acks and undo_state["control waits"] < 4:
                    return 0.4
                report["control: undo with nothing waiting"] = {
                    "answer": acks.get(600), "cube x": [undo_state["x before control"],
                                                        round(bpy.data.objects["Cube"].location.x, 4)]}
                if acks.get(600) != "ok":
                    problems.append("Undo with nothing waiting did not run (%s)" % acks.get(600))
                report["results"] = undo_state["results"]
                if len(undo_state["results"]) < 4:
                    problems.append("fewer than four operations started")
                finish("done" if not problems else "error")
                return None
            mode, name = undo_state["cases"].pop(0)
            if bpy.context.object.mode != mode:
                bpy.ops.object.mode_set(mode=mode)
            module, op = name.split(".")
            with bpy.context.temp_override(window=window, area=area, region=region):
                result = getattr(getattr(bpy.ops, module), op)('INVOKE_DEFAULT')
            if 'RUNNING_MODAL' not in result:
                undo_state["results"][mode + " " + name] = "did not wait: %s" % sorted(result)
                return 0.3
            undo_state.update(current=mode + " " + name, phase="tap")
            return 0.5
        if phase == "tap":
            undo_state["before"] = _menu_state()
            undo_state["steps_before"] = _undo_behind()
            # The old way in: the window's two-finger tap event.
            _simulate(window, 'TOUCH_TWO_FINGER_TAP', 'PRESS', region.x + 40, region.y + 40)
            # The shell's way: Undo, as the button and now the taps send it.
            invoke(subs["operators"], "ED_OT_undo", 500 + step)
            undo_state.update(command=500 + step, phase="check")
            return 0.6
        if phase == "check":
            if undo_state["command"] not in acks and not undo_state.get("waited"):
                # The answer comes with the next update.
                undo_state["waited"] = True
                return 0.4
            undo_state["waited"] = False
            after = _menu_state()
            entry = {"stack moved": after != undo_state["before"], "answer": acks.get(undo_state["command"])}
            undo_state["results"][undo_state["current"]] = entry
            if entry["stack moved"]:
                problems.append("%s: undo ran while it waited" % undo_state["current"])
            if not entry["answer"] or "Finish or cancel" not in entry["answer"]:
                problems.append("%s: Undo was not refused with a word (%s)" % (undo_state["current"], entry["answer"]))
            _simulate(window, 'ESC', 'PRESS', region.x + 12, region.y + 12)
            _simulate(window, 'ESC', 'RELEASE', region.x + 12, region.y + 12)
            undo_state["phase"] = "start"
            return 0.6
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.3


# ROUND6 TOUCH-4 (A13, E2, H11): a finger's tolerances are a finger's. The bridge no longer
# overwrites the person's thresholds and tooltips on a layout pass; and a finger (simulated events
# marked as one, 2 pixels a point) that taps twice 4 pixels apart over two stacked objects picks the
# one behind on the second tap, as "click again in the same place" does on the desktop, while a
# mouse with a motion threshold of 0 (what the bridge used to force) picks the front one again.
SIMULATE_FINGER = getattr(lib, "WM_native_ui_test_simulate_finger", None)
if SIMULATE_FINGER is not None:
    SIMULATE_FINGER.argtypes = [ctypes.c_float]
tolerance_state = {}


def _tap(window, x, y):
    _simulate(window, 'MOUSEMOVE', 'NOTHING', x, y)
    _simulate(window, 'LEFTMOUSE', 'PRESS', x, y)
    _simulate(window, 'LEFTMOUSE', 'RELEASE', x, y)


def tick_tolerance():
    global step
    try:
        pump()
        step += 1
        problems = report.setdefault("problems", [])
        if SIMULATE_FINGER is None:
            problems.append("this build has no WM_native_ui_test_simulate_finger")
            finish("error")
            return None
        window, area, region = _view3d()
        prefs = bpy.context.preferences
        wanted = {"drag_threshold_mouse": 7, "drag_threshold_tablet": 11, "drag_threshold": 4, "move_threshold": 5}
        if step == 1:
            lib.WM_native_ui_test_install_hooks()
            subs["toolbar"] = subscribe("toolbar")
            for key, value in wanted.items():
                setattr(prefs.inputs, key, value)
            prefs.view.show_tooltips = True
            # Two objects under one point: the cube and a smaller one inside it.
            bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0.0, 0.0, 0.0))
            bpy.context.active_object.name = "Inner"
            return 1.0
        if step == 2:
            # Layout passes have run: the person's values stand.
            now = {key: getattr(prefs.inputs, key) for key in wanted}
            report["preferences after layout"] = dict(now, show_tooltips=prefs.view.show_tooltips)
            if now != wanted or not prefs.view.show_tooltips:
                problems.append("TOUCH-4: the bridge changed the person's thresholds or tooltips: %s" % now)
            from bpy_extras import view3d_utils
            rv3d = area.spaces[0].region_3d
            centre = view3d_utils.location_3d_to_region_2d(region, rv3d, (0.0, 0.0, 0.0))
            tolerance_state["point"] = (region.x + centre.x, region.y + centre.y)
            bpy.ops.object.select_all(action='DESELECT')
            # The mouse first, as the bridge left it: "the same place" was the same pixel.
            prefs.inputs.move_threshold = 0
            x, y = tolerance_state["point"]
            _tap(window, x, y)
            return 0.5
        if step == 3:
            tolerance_state["mouse first"] = bpy.context.view_layer.objects.active.name
            x, y = tolerance_state["point"]
            _tap(window, x + 4, y)
            return 0.5
        if step == 4:
            report["mouse, move threshold 0, two clicks 4 px apart"] = [
                tolerance_state["mouse first"], bpy.context.view_layer.objects.active.name]
            prefs.inputs.move_threshold = wanted["move_threshold"]
            bpy.ops.object.select_all(action='DESELECT')
            SIMULATE_FINGER(2.0)
            x, y = tolerance_state["point"]
            # Away first, so the finger's first tap is a fresh place.
            _tap(window, x + 200, y + 200)
            return 0.5
        if step == 5:
            x, y = tolerance_state["point"]
            _tap(window, x, y)
            return 0.5
        if step == 6:
            tolerance_state["finger first"] = bpy.context.view_layer.objects.active.name
            x, y = tolerance_state["point"]
            _tap(window, x + 4, y)
            return 0.5
        if step == 7:
            first, second = tolerance_state["finger first"], bpy.context.view_layer.objects.active.name
            report["finger, two taps 4 px apart"] = [first, second]
            if first == second:
                problems.append("TOUCH-4: a finger's second tap 4 px away did not pick what is behind")
            SIMULATE_FINGER(0.0)
            finish("done" if not problems else "error")
            return None
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.3


# ROUND6 TOUCH-5 (A3, C1): a waiting operation always shows itself and can always be ended. Every
# command that depends on the cursor, run as a native menu item runs it, and every operator of
# TOUCH-2's class (modal, ends on Escape), started from a timer in its mode, must show Cancel: the
# toolbar's `drag_hint` (the shell's hint with Cancel) or the actions row's `modal:cancel` (the bar),
# unless the bar's exclusion list names why it has no end to offer. Escape (what Cancel sends) must
# then leave nothing waiting.
WAIT_LIST = getattr(lib, "WM_native_ui_test_cursor_operators", None)
MENU_CALL = getattr(lib, "WM_native_ui_test_menu_call", None)
BAR_EXCLUDED = getattr(lib, "WM_native_ui_test_bar_excluded", None)
if MENU_CALL is not None:
    WAIT_LIST.restype = ctypes.c_void_p
    MENU_CALL.restype = ctypes.c_bool
    MENU_CALL.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    BAR_EXCLUDED.restype = ctypes.c_char_p
    BAR_EXCLUDED.argtypes = [ctypes.c_char_p]
waiting_state = {}


def _shows_cancel():
    top = tree(subs["toolbar"]) or {}
    children = top.get("children", [])
    hint = next((n for n in children if n["key"] == "drag_hint"), None)
    row = next((n for n in children if n["key"] == "actions"), {})
    bar = any(n["key"] == "modal:cancel" for n in row.get("children", []))
    return (hint.get("label") if hint else None), bar


def _mode_for(idname):
    module = idname.split("_OT_")[0]
    if module in ("MESH",):
        return 'EDIT'
    if module in ("SCULPT", "PAINT"):
        return 'SCULPT'
    return 'OBJECT'


def tick_waiting():
    global step
    try:
        pump()
        step += 1
        problems = report.setdefault("problems", [])
        if MENU_CALL is None or ESCAPE_OPS is None:
            problems.append("this build has no TOUCH-5 test functions")
            finish("error")
            return None
        window, area, region = _view3d()
        if step == 1:
            lib.WM_native_ui_test_install_hooks()
            subs["toolbar"] = subscribe("toolbar")
            pointer = WAIT_LIST()
            cursor = [line for line in ctypes.string_at(pointer).decode().splitlines() if line]
            lib.free(ctypes.c_void_p(pointer))
            ESCAPE_OPS.restype = ctypes.c_void_p
            pointer = ESCAPE_OPS()
            modal = [line.split("|")[0] for line in ctypes.string_at(pointer).decode().splitlines() if line]
            lib.free(ctypes.c_void_p(pointer))
            report["cursor commands"] = len(cursor)
            waiting_state["queue"] = [("menu", name) for name in sorted(cursor)] + \
                [("modal", name) for name in sorted(set(modal) - set(cursor))]
            waiting_state.update(shown={}, excluded={}, not_started={})
            return 0.5
        current = waiting_state.get("current")
        if current:
            kind, idname = current
            hint, bar = _shows_cancel()
            if hint or bar:
                waiting_state["shown"][idname] = hint or "bar"
            else:
                reason = BAR_EXCLUDED(idname.encode()).decode()
                if reason:
                    waiting_state["excluded"][idname] = reason
                else:
                    problems.append("TOUCH-5: %s waits with no Cancel shown" % idname)
            _simulate(window, 'ESC', 'PRESS', region.x + 12, region.y + 12)
            _simulate(window, 'ESC', 'RELEASE', region.x + 12, region.y + 12)
            waiting_state["current"] = None
            waiting_state["ending"] = idname
            return 0.4
        ending = waiting_state.pop("ending", None)
        if ending:
            hint, bar = _shows_cancel()
            still = _touch_window()["modal"] if TOUCH_WINDOW else False
            if hint or still:
                waiting_state["not_started"].setdefault("still waiting after Escape", []).append(ending)
                _simulate(window, 'RIGHTMOUSE', 'PRESS', region.x + 12, region.y + 12)
                _simulate(window, 'RIGHTMOUSE', 'RELEASE', region.x + 12, region.y + 12)
                return 0.4
        queue = waiting_state["queue"]
        while queue:
            kind, idname = queue.pop(0)
            mode = _mode_for(idname)
            if bpy.context.object and bpy.context.object.mode != mode:
                bpy.ops.object.mode_set(mode=mode)
            if kind == "menu":
                if not MENU_CALL(bpy.context.as_pointer(), idname.encode()):
                    waiting_state["not_started"].setdefault("poll fails here", []).append(idname)
                    continue
                waiting_state["current"] = (kind, idname)
                return 0.5
            module, name = idname.split("_OT_")
            operator = getattr(getattr(bpy.ops, module.lower()), name)
            with bpy.context.temp_override(window=window, area=area, region=region):
                if not operator.poll():
                    waiting_state["not_started"].setdefault("poll fails here", []).append(idname)
                    continue
                try:
                    result = operator('INVOKE_DEFAULT')
                except Exception as error:
                    waiting_state["not_started"].setdefault("refused", []).append(
                        "%s: %s" % (idname, str(error).splitlines()[0][:80]))
                    continue
            if 'RUNNING_MODAL' not in result:
                waiting_state["not_started"].setdefault("did not wait", []).append(idname)
                continue
            waiting_state["current"] = (kind, idname)
            return 0.5
        if bpy.context.object and bpy.context.object.mode != 'OBJECT':
            bpy.ops.object.mode_set(mode='OBJECT')
        report["shown with Cancel"] = waiting_state["shown"]
        report["excluded, with why"] = waiting_state["excluded"]
        report["not started"] = waiting_state["not_started"]
        if len(waiting_state["shown"]) < 10:
            problems.append("TOUCH-5: fewer than ten waiting operations were seen; the sweep proves little")
        for needed in ("VIEW3D_OT_walk", "VIEW3D_OT_fly", "MESH_OT_rip"):
            if needed not in waiting_state["shown"]:
                problems.append("TOUCH-5: %s did not show Cancel" % needed)
        finish("done" if not problems else "error")
        return None
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.3


# ROUND6 TOUCH-6 (C5, A9, E6 ii, H10): the wait for the finger is the event system's. Every operator
# with a `modal` that the event system says waits for the finger (its modal key map ends on a left
# press, or it is listed), and every operator of TOUCH-2's class, is started in its mode as a menu
# starts it (no button down) with the input a finger's; one finger lands on the view and lifts. It
# must still run after the touch-down, and nothing may be logged as "ended on touch-down". Then the
# same for transforms in the Dope Sheet and the Graph Editor (H10: once 3D View only).
TOUCH_WAIT_LIST = getattr(lib, "WM_event_test_modal_operators", None)
TOUCH_DOWN_ENDINGS = getattr(lib, "WM_event_test_touch_down_endings", None)
if TOUCH_WAIT_LIST is not None:
    TOUCH_WAIT_LIST.restype = ctypes.c_void_p
    TOUCH_WAIT_LIST.argtypes = [ctypes.c_void_p]
    TOUCH_DOWN_ENDINGS.restype = ctypes.c_void_p
touchstart_state = {}
# Operators that need properties to start, as their menus give them.
TOUCHSTART_PROPERTIES = {
    "WM_OT_context_modal_mouse": {"data_path_iter": "selected_editable_objects",
                                  "data_path_item": "empty_display_size"},
    "WM_OT_radial_control": {"data_path_primary": "tool_settings.sculpt.brush.size"},
    "TRANSFORM_OT_transform": {"mode": 'TRANSLATION'},
}
# Not started: not about the pointer, or they open a window or a file browser.
TOUCHSTART_SKIP = ("RENDER_OT_", "OBJECT_OT_bake", "SCREEN_OT_", "FILE_OT_", "WM_OT_save", "WM_OT_open",
                   "WM_OT_link", "WM_OT_append", "WM_OT_recover", "WM_OT_splash", "WM_OT_search", "WM_OT_call",
                   "WM_OT_url", "WM_OT_window", "UI_OT_", "SEQUENCER_OT_", "CLIP_OT_", "IMAGE_OT_", "NODE_OT_",
                   "OUTLINER_OT_", "GRAPH_OT_", "ACTION_OT_", "NLA_OT_", "TEXT_OT_", "CONSOLE_OT_", "MARKER_OT_",
                   "ANIM_OT_", "VIEW2D_OT_", "PAINT_OT_", "GREASE_PENCIL_OT_", "GPENCIL_OT_", "CURVES_OT_",
                   "SCULPT_CURVES_OT_", "PARTICLE_OT_", "WM_OT_xr", "VIEW3D_OT_navigate", "VIEW3D_OT_walk",
                   "VIEW3D_OT_fly", "WM_OT_modal_timer", "PREFERENCES_OT_", "INFO_OT_", "BUTTONS_OT_",
                   "PALETTE_OT_", "ED_OT_", "OBJECT_OT_quick", "SOUND_OT_", "MESH_OT_knife_project")


def _touchstart_mode(idname):
    module = idname.split("_OT_")[0]
    if module in ("MESH",):
        return 'EDIT', "Cube"
    if module in ("POSE", "POSELIB"):
        return 'POSE', "Armature"
    if module in ("ARMATURE",):
        return 'EDIT', "Armature"
    if module in ("SCULPT",) or idname in ("OBJECT_OT_voxel_size_edit", "WM_OT_radial_control"):
        return 'SCULPT', "Cube"
    return 'OBJECT', "Cube"


def _touchstart_enter(mode, name):
    ob = bpy.data.objects[name]
    if bpy.context.object and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for other in bpy.context.view_layer.objects:
        other.select_set(other == ob)
    bpy.context.view_layer.objects.active = ob
    if mode != 'OBJECT':
        bpy.ops.object.mode_set(mode=mode)
    if mode == 'EDIT' and name == "Cube":
        bpy.ops.mesh.select_all(action='SELECT')
    if mode in ('POSE', 'EDIT') and name == "Armature":
        if mode == 'POSE':
            bpy.ops.pose.select_all(action='SELECT')
        else:
            bpy.ops.armature.select_all(action='SELECT')


def _touchstart_keys():
    """The cube's two keys afresh, at frames 1 and 10: each editor case starts from the same keys,
    not from what the case before scaled or moved."""
    cube = bpy.data.objects["Cube"]
    cube.animation_data_clear()
    location = cube.location.copy()
    cube.keyframe_insert("location", frame=1)
    cube.location.x += 1.0
    cube.keyframe_insert("location", frame=10)
    cube.location = location


def _touchstart_endings():
    pointer = TOUCH_DOWN_ENDINGS()
    text = ctypes.string_at(pointer).decode()
    lib.free(ctypes.c_void_p(pointer))
    return [line for line in text.splitlines() if line]


def _touchstart_running():
    return _touch_window()["modal"]


def _touchstart_area(ui_type):
    """The largest area other than the 3D View as \a ui_type: (window, area, region), or the
    text "switched" when it had to change first (its regions are laid out at the next redraw)."""
    window = bpy.context.window_manager.windows[0]
    areas = [area for area in window.screen.areas if area.type != 'VIEW_3D']
    if not areas:
        # The layout is one 3D View, which cannot be split here: the editors' cases come last, so
        # the view itself becomes the editor.
        _view3d()[1].ui_type = ui_type
        return "switched"
    area = max(areas, key=lambda area: area.width * area.height)
    if area.ui_type != ui_type:
        area.ui_type = ui_type
        return "switched"
    region = next((r for r in area.regions if r.type == 'WINDOW'), None)
    return (window, area, region) if region is not None else None


def tick_touchstart():
    global step
    try:
        pump()
        step += 1
        problems = report.setdefault("problems", [])
        if TOUCH_WAIT_LIST is None or TOUCH_WINDOW is None or SIMULATE_FINGER is None:
            problems.append("this build has no TOUCH-6 test functions")
            finish("error")
            return None
        view = _view3d()
        st = touchstart_state
        if view is None:
            # The view became an editor for the last cases (see `_touchstart_area`).
            target = st.get("target")
            view = (target[0], target[1], target[2]) if target else (bpy.context.window_manager.windows[0], None, None)
        window, area, region = view
        if step == 1:
            lib.WM_native_ui_test_install_hooks()
            subs["toolbar"] = subscribe("toolbar")
            cube = bpy.data.objects["Cube"]
            cube.keyframe_insert("location", frame=1)
            cube.location.x += 1.0
            cube.keyframe_insert("location", frame=10)
            cube.location.x -= 1.0
            bpy.ops.object.armature_add(location=(3.0, 0.0, 0.0))
            bpy.context.object.name = "Armature"
            bpy.ops.object.mode_set(mode='EDIT')
            bpy.ops.armature.extrude_move(TRANSFORM_OT_translate={"value": (0.0, 0.0, 1.0)})
            bpy.ops.object.mode_set(mode='OBJECT')
            # Keys on either side of the current frame, for Pose's In-Betweens.
            armature = bpy.data.objects["Armature"]
            for frame, angle in ((1, 0.0), (9, 0.6)):
                for bone in armature.pose.bones:
                    bone.rotation_mode = 'XYZ'
                    bone.rotation_euler.x = angle
                    bone.keyframe_insert("rotation_euler", frame=frame)
            bpy.context.scene.frame_set(5)
            pointer = TOUCH_WAIT_LIST(bpy.context.as_pointer())
            rows = [line.split("|", 1) for line in ctypes.string_at(pointer).decode().splitlines() if line]
            lib.free(ctypes.c_void_p(pointer))
            st["refusals"] = dict(rows)
            members = sorted(name for name, why in rows if not why)
            ESCAPE_OPS.restype = ctypes.c_void_p
            pointer = ESCAPE_OPS()
            escape = [line.split("|")[0] for line in ctypes.string_at(pointer).decode().splitlines() if line]
            lib.free(ctypes.c_void_p(pointer))
            report["modal operators"] = len(rows)
            report["wait for the finger"] = len(members)
            report["not known to end on a press (no modal key map, not listed)"] = sorted(
                name for name, why in rows if why == "not known to end on a left press")
            queue = sorted(set(members) | set(escape))
            # The editors first (H10): the 3D View is made each editor in turn, then a 3D View again.
            # One case each: in this harness, more transforms in one area that changes between the
            # Dope Sheet and the Graph Editor crash Blender in transform's animation code with a
            # mouse as with a finger (2026-11-19, not the touch's; reported in STATUS).
            st["queue"] = [("DOPESHEET", "TRANSFORM_OT_transform:TIME_SCALE"),
                           ("FCURVES", "TRANSFORM_OT_translate"),
                           ("VIEW_3D", "")]
            st["queue"] += [("view", name) for name in queue if not name.startswith(TOUCHSTART_SKIP)]
            st.update(results={}, not_started={})
            # The input is a finger's from now on (2 pixels a point): a menu's command started now is
            # one a touch started.
            SIMULATE_FINGER(2.0)
            _touchstart_endings()
            return 0.5
        phase = st.get("phase")
        if phase == "down":
            # Started, waiting: one finger lands away from where the pointer was.
            target_window, _area, target_region, idname = st["target"]
            x = target_region.x + target_region.width * 0.6
            y = target_region.y + target_region.height * 0.4
            st["point"] = (x, y)
            _simulate(target_window, 'MOUSEMOVE', 'NOTHING', x, y)
            _simulate(target_window, 'LEFTMOUSE', 'PRESS', x, y)
            st["phase"] = "check down"
            return 0.4
        if phase == "check down":
            target_window, _area, _region, idname = st["target"]
            entry = st["results"][idname]
            entry["running after touch-down"] = _touchstart_running()
            ended = _touchstart_endings()
            if ended:
                problems.append("TOUCH-6: %s ended on touch-down" % ", ".join(ended))
            if entry["waits"] and not entry["running after touch-down"]:
                problems.append("TOUCH-6: %s waits for the finger but did not run after it landed" % idname)
            x, y = st["point"]
            _simulate(target_window, 'MOUSEMOVE', 'NOTHING', x + 30, y + 10)
            _simulate(target_window, 'LEFTMOUSE', 'RELEASE', x + 30, y + 10)
            st["phase"] = "check lift"
            return 0.4
        if phase == "check lift":
            target_window, _area, _region, idname = st["target"]
            entry = st["results"][idname]
            entry["running after lift"] = _touchstart_running()
            ended = _touchstart_endings()
            if ended:
                problems.append("TOUCH-6: %s ended on touch-down" % ", ".join(ended))
            st["phase"] = None
            if entry["running after lift"]:
                _simulate(target_window, 'ESC', 'PRESS', region.x + 12, region.y + 12)
                _simulate(target_window, 'ESC', 'RELEASE', region.x + 12, region.y + 12)
                return 0.4
        queue = st["queue"]
        while queue:
            where, name = queue.pop(0)
            if where == "VIEW_3D":
                # Back to the 3D View for the rest.
                if _touchstart_running():
                    queue.insert(0, (where, name))
                    _simulate(window, 'ESC', 'PRESS', 12, 12)
                    _simulate(window, 'ESC', 'RELEASE', 12, 12)
                    return 0.5
                if _view3d() is None:
                    st["target"][1].ui_type = 'VIEW_3D'
                    return 0.5
                continue
            idname, _, mode_value = name.partition(":")
            module, opname = idname.split("_OT_")
            operator = getattr(getattr(bpy.ops, module.lower()), opname)
            properties = dict(TOUCHSTART_PROPERTIES.get(idname, {}))
            if mode_value:
                properties["mode"] = mode_value
            if where == "view":
                mode, ob = _touchstart_enter_for(idname)
                target = (window, area, region)
            else:
                if _touchstart_running():
                    # Never change an editor under a running operation.
                    queue.insert(0, (where, name))
                    _simulate(window, 'ESC', 'PRESS', 12, 12)
                    _simulate(window, 'ESC', 'RELEASE', 12, 12)
                    return 0.5
                _touchstart_enter('OBJECT', "Cube")
                _touchstart_keys()
                found = _touchstart_area(where)
                if found == "switched":
                    queue.insert(0, (where, name))
                    return 0.5
                if found is None:
                    st["not_started"].setdefault("no such editor", []).append(name)
                    continue
                target = found
                with bpy.context.temp_override(window=target[0], area=target[1], region=target[2]):
                    bpy.ops.action.select_all(action='SELECT') if where == "DOPESHEET" else \
                        bpy.ops.graph.select_all(action='SELECT')
            with bpy.context.temp_override(window=target[0], area=target[1], region=target[2]):
                if not operator.poll():
                    st["not_started"].setdefault("poll fails here", []).append(name)
                    continue
                try:
                    result = operator('INVOKE_DEFAULT', **properties)
                except Exception as error:
                    st["not_started"].setdefault("refused", []).append(
                        "%s: %s" % (name, str(error).splitlines()[0][:80]))
                    continue
            if 'RUNNING_MODAL' not in result:
                st["not_started"].setdefault("did not wait", []).append(name)
                continue
            key = name if where == "view" else where + ":" + name
            waits = not st["refusals"].get(idname, "unknown")
            st["results"][key] = {"waits": waits, "why not": st["refusals"].get(idname, "unknown")}
            st["target"] = (target[0], target[1], target[2], key)
            st["phase"] = "down"
            print("touchstart: started", key, flush=True)
            return 0.4
        if bpy.context.object and bpy.context.object.mode != 'OBJECT':
            bpy.ops.object.mode_set(mode='OBJECT')
        SIMULATE_FINGER(0.0)
        results = st["results"]
        report["started"] = len(results)
        report["waited for the finger"] = sorted(n for n, e in results.items() if e["waits"])
        report["started, not waiting (why)"] = {n: e["why not"] for n, e in results.items() if not e["waits"]}
        report["still running after the lift"] = sorted(n for n, e in results.items() if e.get("running after lift"))
        report["not started"] = st["not_started"]
        for needed in ("POSE_OT_push", "POSE_OT_relax", "WM_OT_context_modal_mouse", "TRANSFORM_OT_translate",
                       "MESH_OT_bevel", "MESH_OT_inset", "MESH_OT_loopcut_slide",
                       "DOPESHEET:TRANSFORM_OT_transform:TIME_SCALE", "FCURVES:TRANSFORM_OT_translate"):
            if needed not in results:
                problems.append("TOUCH-6: %s was not started; the sweep proves little" % needed)
            elif not results[needed]["waits"]:
                problems.append("TOUCH-6: %s does not wait for the finger" % needed)
        finish("done" if not problems else "error")
        return None
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.3


# ROUND6 BUSY-2 (G6, C1, R6-12): taps are refused, not replayed. (1) Two removes of the same modifier
# sent together, as two taps that reached Blender in one pass after it was held up: the first runs,
# the second is refused, its button gone. (2) While a job's operator holds its modal handler, an
# operator command is refused naming the job, not parked to run when it ends. (3) An operator names
# itself while it runs, for the veil (`WM_native_ui_busy_label`). (4) With Lock Interface, a live
# command is refused while the render runs; the render's own Cancel still works.
class TEST_OT_busy_probe(bpy.types.Operator):
    bl_idname = "test.busy_probe"
    bl_label = "Busy Probe"

    def execute(self, _context):
        buffer = ctypes.create_string_buffer(256)
        named = lib.WM_native_ui_busy_label(buffer, 256)
        report["busy_label"] = buffer.value.decode() if named else None
        return {'FINISHED'}


def _busy_buttons(subscription, operator):
    view = views.get(subscription, {"nodes": {}})
    return [key for key, node in view["nodes"].items()
            if node.get("operator") == operator or key.split(":")[0] == operator]


def tick_busy():
    global step
    try:
        pump()
        step += 1
        if step == 1:
            lib.WM_native_ui_busy_label.restype = ctypes.c_bool
            lib.WM_native_ui_busy_label.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
            bpy.utils.register_class(TEST_OT_busy_probe)
            bpy.ops.test.busy_probe()
            idle = ctypes.create_string_buffer(256)
            report["busy_label_idle"] = bool(lib.WM_native_ui_busy_label(idle, 256))
            cube = bpy.data.objects["Cube"]
            for index in range(2):
                cube.modifiers.new("Bevel %d" % index, 'BEVEL')
            subs["MODIFIER"] = subscribe("properties", tab="MODIFIER", properties=True)
            subs["operators"] = subscribe("operators")
            subs["jobs"] = subscribe("jobs")
            return 0.5
        if step == 3:
            removes = _busy_buttons(subs["MODIFIER"], "OBJECT_OT_modifier_remove")
            report["remove_buttons"] = removes
            if not removes:
                nodes = views.get(subs["MODIFIER"], {"nodes": {}})["nodes"]
                report["operators_seen"] = sorted({n.get("operator") for n in nodes.values() if n.get("operator")})
                report["node_sample"] = [(k, n.get("content"), n.get("label")) for k, n in list(nodes.items())[:60]]
                finish("error")
                return None
            invoke_many(subs["MODIFIER"], [(removes[0], 701), (removes[0], 702)])
            return 0.5
        if step == 5:
            report["first_remove"] = acks.get(701)
            report["second_remove"] = acks.get(702)
            report["modifiers_left"] = [m.name for m in bpy.data.objects["Cube"].modifiers]
            report["job_start"] = sorted(_jobs_start_pointcache(REPORT.rsplit("/", 1)[0]))
            return 0.5
        if step == 7:
            invoke(subs["operators"], "object.select_all", 703)
            return 0.5
        if step == 9:
            report["command_during_job"] = acks.get(703)
            for key in views[subs["jobs"]]["children"].get("jobs", []):
                invoke(subs["jobs"], key + ":stop", 704)
            return 1.0
        if step == 11:
            # Only once the bake ended: a render starting as the cloth bake ends is not this test.
            if views[subs["jobs"]]["children"].get("jobs"):
                step -= 1
                return 0.2
            scene = bpy.context.scene
            scene.render.use_lock_interface = True
            report["lock_start"] = sorted(_jobs_start_render(REPORT.rsplit("/", 1)[0]))
            subs["timeline"] = subscribe("timeline")
            subs["render"] = subscribe("render")
            return 1.0
        if step == 13:
            report["render_running_locked"] = bpy.app.is_job_running('RENDER')
            return 0.1
        if step == 14:
            set_text(subs["timeline"], "frame", "10", 706)
            return 0.5
        if step == 16:
            report["live_while_locked"] = acks.get(706)
            invoke(subs["render"], "cancel", 707)
            return 1.0
        if step == 18:
            report["cancel_while_locked"] = acks.get(707)
            report["render_running_after_cancel"] = bpy.app.is_job_running('RENDER')
            ok = (report["busy_label"] == "Busy Probe" and not report["busy_label_idle"] and
                  report["first_remove"] == "ok" and (report["second_remove"] or "").startswith("Not done") and
                  len(report["modifiers_left"]) == 1 and
                  (report["command_during_job"] or "").startswith("Wait for Baking point cache") and
                  (report["live_while_locked"] or "").startswith("The render locks") and
                  report["cancel_while_locked"] == "ok")
            finish("done" if ok else "error")
            return None
        return 0.25
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None


# ROUND6 BUSY-1 (G13): a still render's progress rises as it renders. It is read from the render job
# (the engine reports it there in an interactive session), not from `render_stats` handlers, which hear
# only the per-frame time there: before, a still read 0 % until it was done.
def tick_render_progress():
    global step
    try:
        pump()
        step += 1
        if step == 1:
            subs["render"] = subscribe("render")
            scene = bpy.context.scene
            scene.render.engine = 'BLENDER_EEVEE'
            scene.eevee.taa_render_samples = 256
            scene.render.resolution_percentage = 100
            report["seen"] = []
            return 0.3
        if step == 3:
            invoke(subs["render"], "image", 600)
            report["sent"] = time.monotonic()
            return 0.1
        if step < 3:
            return 0.3
        view = views.get(subs["render"], {"nodes": {}})
        state = view["nodes"].get("state:state", {}).get("value")
        samples = view["nodes"].get("state:samples", {})
        report["seen"].append((state, round(samples["value"], 3) if "value" in samples else None))
        if state in ("done", "error", "cancelled") or time.monotonic() - report["sent"] > 120:
            rising = [value for name, value in report["seen"] if name == "rendering" and value]
            report["seen"] = report["seen"][-12:]
            report["rising_values"] = len(rising)
            finish("done" if state == "done" and rising and 0 < min(rising) < 1 else "error")
            return None
        return 0.1
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None


# ROUND6 BUSY-1 (G6, G13, B1, D12): every job Blender's status bar would show is in the `jobs` view,
# with its progress and a Stop that ends it. The sweep walks `eWM_JobType` as `WM_api.hh` declares it:
# each type the harness can start is started, must be listed, and must end within a few seconds of
# its Stop (sent while its operator holds a modal handler, where it has one); every other type is in
# `_JOBS_NOT_STARTED` with the reason. A type in neither fails.
def _job_types():
    import os
    import re
    header = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "WM_api.hh")
    with open(header) as f:
        text = f.read()
    body = text[text.index("enum eWM_JobType {"):]
    body = body[:body.index("};")]
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.S)
    return {name: value for value, name in enumerate(re.findall(r"WM_JOB_TYPE_(\w+)", body))}


_JOBS_NOT_STARTED = {
    "ANY": "not a job type",
    "RENDER_PREVIEW": "previews: no WM_JOB_PROGRESS, so not listed, as desktop's status bar",
    "LOAD_PREVIEW": "previews: no WM_JOB_PROGRESS, so not listed, as desktop's status bar",
    "STUDIOLIGHT": "studio light previews: no WM_JOB_PROGRESS, so not listed, as desktop's status bar",
    "SEQ_DRAW_THUMBNAIL": "sequencer thumbnails: no WM_JOB_PROGRESS, so not listed, as desktop's status bar",
    "SEQ_DRAG_DROP_PREVIEW": "sequencer drag preview: no WM_JOB_PROGRESS, so not listed, as desktop's status bar",
    "FSMENU_BOOKMARK_VALIDATE": "no job of this type is started anywhere",
    "SHADER_COMPILATION": "not a WM job: shaders compile on the GPU module's own threads; the "
                          "Compiling Shaders pill shows it",
    "FILESEL_READDIR": "Blender's file browser reading a folder: listed when it runs; the iPad shows "
                       "no file browser of Blender's to start it from here",
    "ASSET_LIBRARY_LOAD": "an asset library loading: listed when it runs; ends by itself in a moment",
    "CLIP_BUILD_PROXY": "needs movie footage in a clip",
    "CLIP_TRACK_MARKERS": "needs movie footage in a clip",
    "CLIP_SOLVE_CAMERA": "needs tracked footage",
    "CLIP_PREFETCH": "needs movie footage in a clip",
    "SEQ_BUILD_PROXY": "needs a movie strip",
    "SEQ_BUILD_PREVIEW": "needs a sound strip (no sound on the iPad, G11)",
    "ALEMBIC_IMPORT": "needs an Alembic file; the export's job is started and stopped instead",
    "USD_IMPORT": "USD is not built for the iPad",
    "USD_EXPORT": "USD is not built for the iPad",
    "COMPOSITE": "the compositor's job starts from its node editor's own updates, not an operator",
    "TRACE_IMAGE": "needs an image empty to trace",
    "LINEART": "needs a Grease Pencil object with a Line Art modifier",
    "UV_PACK": "ends in a moment for any mesh the harness can make",
    "QUADRIFLOW_REMESH": "ends or fails in a moment for any mesh the harness can make",
    "OBJECT_BAKE_TEXTURE": "Blender Internal's multires bake: needs a multires setup",
    "CALCULATE_SIMULATION_NODES": "started by playback's simulation, not an operator here; the "
                                  "geometry nodes bake is started instead",
}


def _jobs_window():
    window = bpy.context.window_manager.windows[0]
    area = next((a for a in window.screen.areas if a.type == 'VIEW_3D'), window.screen.areas[0])
    region = next(r for r in area.regions if r.type == 'WINDOW')
    return dict(window=window, screen=window.screen, area=area, region=region)


def _jobs_mesh(name, op, **kwargs):
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob)
    with bpy.context.temp_override(**_jobs_window()):
        op(**kwargs)
    ob = bpy.context.view_layer.objects.active
    ob.name = name
    ob.select_set(True)
    return ob


def _jobs_start_render(directory):
    scene = bpy.context.scene
    if scene.camera is None:
        camera = bpy.data.objects.new("Camera", bpy.data.cameras.new("Camera"))
        scene.collection.objects.link(camera)
        scene.camera = camera
    scene.render.engine = 'BLENDER_EEVEE'
    scene.render.resolution_percentage = 25
    scene.frame_start, scene.frame_end = 1, 2000
    scene.render.filepath = directory + "/render_"
    bpy.context.preferences.view.render_display_type = 'NONE'
    with bpy.context.temp_override(**_jobs_window()):
        return bpy.ops.render.render('INVOKE_DEFAULT', animation=True)


def _jobs_start_pointcache(directory):
    ob = _jobs_mesh("Cloth", bpy.ops.mesh.primitive_grid_add, x_subdivisions=80, y_subdivisions=80, size=2)
    ob.modifiers.new("Cloth", 'CLOTH')
    bpy.context.scene.frame_start, bpy.context.scene.frame_end = 1, 5000
    ob.modifiers["Cloth"].point_cache.frame_end = 5000
    with bpy.context.temp_override(**_jobs_window()):
        return bpy.ops.ptcache.bake_all('INVOKE_DEFAULT', bake=True)


def _jobs_start_object_bake(directory):
    ob = _jobs_mesh("Baked", bpy.ops.mesh.primitive_uv_sphere_add, segments=64, ring_count=32)
    scene = bpy.context.scene
    scene.render.engine = 'CYCLES'
    scene.cycles.device = 'CPU'
    scene.cycles.samples = 4096
    material = bpy.data.materials.new("Baked")
    material.use_nodes = True
    ob.data.materials.append(material)
    node = material.node_tree.nodes.new('ShaderNodeTexImage')
    node.image = bpy.data.images.new("Baked", 2048, 2048)
    material.node_tree.nodes.active = node
    with bpy.context.temp_override(**_jobs_window(), object=ob, active_object=ob, selected_objects=[ob]):
        return bpy.ops.object.bake('INVOKE_DEFAULT', type='COMBINED')


def _jobs_start_geometry_nodes(directory):
    ob = _jobs_mesh("Simulated", bpy.ops.mesh.primitive_ico_sphere_add, subdivisions=5)
    group = bpy.data.node_groups.new("Simulated", 'GeometryNodeTree')
    group.interface.new_socket("Geometry", in_out='INPUT', socket_type='NodeSocketGeometry')
    group.interface.new_socket("Geometry", in_out='OUTPUT', socket_type='NodeSocketGeometry')
    nodes, links = group.nodes, group.links
    inputs, outputs = nodes.new('NodeGroupInput'), nodes.new('NodeGroupOutput')
    sim_in, sim_out = nodes.new('GeometryNodeSimulationInput'), nodes.new('GeometryNodeSimulationOutput')
    sim_in.pair_with_output(sim_out)
    subdivide = nodes.new('GeometryNodeSubdivideMesh')
    subdivide.inputs["Level"].default_value = 2
    links.new(inputs.outputs[0], sim_in.inputs[0])
    links.new(sim_in.outputs[1], subdivide.inputs[0])
    links.new(subdivide.outputs[0], sim_out.inputs[0])
    links.new(sim_out.outputs[0], outputs.inputs[0])
    modifier = ob.modifiers.new("Simulated", 'NODES')
    modifier.node_group = group
    bpy.context.scene.frame_start, bpy.context.scene.frame_end = 1, 100000
    with bpy.context.temp_override(**_jobs_window(), object=ob, active_object=ob, selected_objects=[ob]):
        return bpy.ops.object.simulation_nodes_cache_bake('INVOKE_DEFAULT', selected=True)


def _jobs_start_light_bake(directory):
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob)
    scene = bpy.context.scene
    scene.render.engine = 'BLENDER_EEVEE'
    with bpy.context.temp_override(**_jobs_window()):
        bpy.ops.mesh.primitive_monkey_add()
        bpy.ops.object.lightprobe_add(type='VOLUME')
    probe = bpy.context.view_layer.objects.active
    probe.data.resolution_x = probe.data.resolution_y = probe.data.resolution_z = 32
    probe.data.bake_samples = 4096
    with bpy.context.temp_override(**_jobs_window(), object=probe, active_object=probe, selected_objects=[probe]):
        return bpy.ops.object.lightprobe_cache_bake('INVOKE_DEFAULT', subset='ALL')


def _jobs_start_ocean(directory):
    ob = _jobs_mesh("Ocean", bpy.ops.mesh.primitive_plane_add)
    modifier = ob.modifiers.new("Ocean", 'OCEAN')
    modifier.resolution = 24
    modifier.filepath = directory + "/ocean"
    modifier.frame_start, modifier.frame_end = 1, 5000
    with bpy.context.temp_override(**_jobs_window(), object=ob, active_object=ob):
        return bpy.ops.object.ocean_bake('INVOKE_DEFAULT', modifier="Ocean")


def _jobs_start_dynamic_paint(directory):
    ob = _jobs_mesh("Canvas", bpy.ops.mesh.primitive_grid_add, x_subdivisions=20, y_subdivisions=20)
    ob.modifiers.new("DynamicPaint", 'DYNAMIC_PAINT')
    with bpy.context.temp_override(**_jobs_window(), object=ob, active_object=ob):
        bpy.ops.dpaint.type_toggle(type='CANVAS')
    surface = ob.modifiers["DynamicPaint"].canvas_settings.canvas_surfaces[0]
    surface.surface_format = 'IMAGE'
    surface.image_resolution = 2048
    surface.image_output_path = directory + "/dpaint"
    surface.frame_start, surface.frame_end = 1, 5000
    with bpy.context.temp_override(**_jobs_window(), object=ob, active_object=ob):
        bpy.ops.mesh.uv_texture_add() if not ob.data.uv_layers else None
        return bpy.ops.dpaint.bake()


def _jobs_start_alembic(directory):
    ob = _jobs_mesh("Exported", bpy.ops.mesh.primitive_ico_sphere_add, subdivisions=6)
    # Moving, so each frame is written.
    ob.keyframe_insert("location", frame=1)
    ob.location.x = 100
    ob.keyframe_insert("location", frame=100000)
    ob.modifiers.new("Wave", 'WAVE')
    with bpy.context.temp_override(**_jobs_window()):
        return bpy.ops.wm.alembic_export(filepath=directory + "/out.abc", start=1, end=100000,
                                         as_background_job=True)


_JOBS_STARTED = {
    "RENDER": _jobs_start_render,
    "POINTCACHE": _jobs_start_pointcache,
    "OBJECT_BAKE": _jobs_start_object_bake,
    "BAKE_GEOMETRY_NODES": _jobs_start_geometry_nodes,
    "LIGHT_BAKE": _jobs_start_light_bake,
    "OBJECT_SIM_OCEAN": _jobs_start_ocean,
    "DPAINT_BAKE": _jobs_start_dynamic_paint,
    "ALEMBIC_EXPORT": _jobs_start_alembic,
    "OBJECT_SIM_FLUID": None,  # Filled in below: needs its own domain.
}


def _jobs_start_fluid(directory):
    domain = _jobs_mesh("Domain", bpy.ops.mesh.primitive_cube_add, size=4)
    domain.modifiers.new("Fluid", 'FLUID')
    domain.modifiers["Fluid"].fluid_type = 'DOMAIN'
    settings = domain.modifiers["Fluid"].domain_settings
    settings.resolution_max = 96
    settings.cache_directory = directory + "/fluid"
    settings.cache_frame_end = 5000
    with bpy.context.temp_override(**_jobs_window()):
        bpy.ops.mesh.primitive_uv_sphere_add(radius=0.5)
    flow = bpy.context.view_layer.objects.active
    flow.modifiers.new("Fluid", 'FLUID')
    flow.modifiers["Fluid"].fluid_type = 'FLOW'
    flow.modifiers["Fluid"].flow_settings.flow_type = 'SMOKE'
    flow.modifiers["Fluid"].flow_settings.flow_behavior = 'INFLOW'
    bpy.context.view_layer.objects.active = domain
    with bpy.context.temp_override(**_jobs_window(), object=domain, active_object=domain):
        return bpy.ops.fluid.bake_data('INVOKE_DEFAULT')


_JOBS_STARTED["OBJECT_SIM_FLUID"] = _jobs_start_fluid
_jobs = {"queue": None, "current": None}


def _jobs_listed(value):
    view = views.get(subs["jobs"])
    prefix = "job:%d:" % value
    if not view:
        return None
    for key in view["children"].get("jobs", []):
        if key.startswith(prefix):
            return key
    return None


def tick_jobs():
    global step
    try:
        pump()
        step += 1
        if step == 1:
            types = _job_types()
            report["types"] = len(types)
            unknown = sorted(set(types) - set(_JOBS_STARTED) - set(_JOBS_NOT_STARTED))
            stale = sorted((set(_JOBS_STARTED) | set(_JOBS_NOT_STARTED)) - set(types))
            report["unlisted_types"], report["stale_types"] = unknown, stale
            report["not_started"] = {name: _JOBS_NOT_STARTED[name] for name in sorted(_JOBS_NOT_STARTED)}
            report["jobs"] = {}
            subs["jobs"] = subscribe("jobs")
            subs["render"] = subscribe("render")
            _jobs["types"] = types
            _jobs["queue"] = list(_JOBS_STARTED)
            return 0.3
        current = _jobs["current"]
        now = time.monotonic()
        if current is None:
            # The next job's scene is made only once nothing runs: a job still running on data the
            # next set-up deletes would end the run, not test anything.
            if views.get(subs["jobs"], {}).get("children", {}).get("jobs"):
                _jobs.setdefault("idle_wait", now)
                if now - _jobs["idle_wait"] < 30:
                    return 0.2
                report["error"] = "jobs still listed 30 s after the last one ended: %s" % (
                    views[subs["jobs"]]["children"]["jobs"])
                finish("error")
                return None
            _jobs.pop("idle_wait", None)
            print("JOBS", json.dumps(report.get("jobs")), flush=True)
            if not _jobs["queue"]:
                failed = [name for name, entry in report["jobs"].items() if not entry.get("ok")]
                report["failed"] = failed
                finish("done" if not failed and not report["unlisted_types"] and not report["stale_types"]
                       else "error")
                return None
            name = _jobs["queue"].pop(0)
            entry = report["jobs"][name] = {}
            _jobs["current"] = {"name": name, "value": _jobs["types"][name], "started": now}
            try:
                entry["start"] = sorted(_JOBS_STARTED[name](REPORT.rsplit("/", 1)[0]))
            except Exception as ex:
                entry["error"] = "could not start: %s" % ex
                _jobs["current"] = None
            return 0.1
        entry = report["jobs"][current["name"]]
        key = _jobs_listed(current["value"])
        if "stop_sent" not in current:
            if key is None:
                if "seen" in current:
                    entry["error"] = "ended by itself before Stop was sent"
                    _jobs["current"] = None
                elif now - current["started"] > 15:
                    entry["error"] = "never listed in the jobs view"
                    _jobs["current"] = None
                return 0.1
            if "seen" not in current:
                current["seen"] = now
                node = views[subs["jobs"]]["nodes"].get(key, {})
                entry["label"] = node.get("label")
                return 0.1
            if now - current["seen"] < 0.3:
                return 0.05
            progress = views[subs["jobs"]]["nodes"].get(key + ":progress", {})
            entry["progress_node"] = "value" in progress or progress.get("content") == "Data"
            # Stop must reach work whose operator holds a modal handler (non-live commands wait).
            entry["modal_operator"] = _touchstart_running()
            invoke(subs["jobs"], key + ":stop", 500 + len(report["jobs"]))
            current["stop_sent"] = now
            current["stop_id"] = 500 + len(report["jobs"])
            return 0.05
        if key is None:
            entry["stopped_after"] = round(now - current["stop_sent"], 2)
            entry["stop_ack"] = acks.get(current["stop_id"])
            entry["ok"] = entry["stop_ack"] == "ok" and entry["label"] is not None
            _jobs["current"] = None
            if current["name"] == "RENDER":
                invoke(subs["render"], "clear", 499)
            return 0.5
        if now - current["stop_sent"] > 20:
            entry["error"] = "still listed 20 s after Stop"
            entry["stop_ack"] = acks.get(current["stop_id"])
            _jobs["current"] = None
            return 0.5
        return 0.05
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None


# ROUND6 DESK-1 (H1, H3, C1; decision R6-6): in the Desktop Interface nothing of Blender's ends an
# operation that only a key or the right button ends, and Focus Mode hides every bar. With Blender's
# own interface on, each H1 operation is started as its menu starts it, in an editor in Focus Mode
# (no 3D View on the screen, no top bar): the toolbar view must offer its end (the hint's Done or
# Cancel, or the bar's Cancel), which the shell's cluster shows whatever Blender's screen is, and
# Escape, which those buttons send, must leave nothing waiting. Undo must be offered there too. Last,
# from Focus Mode, the way back to the iPad interface must bring the 3D View back.
DESK_CASES = [
    # (editor ui_type, operator, object mode)
    ("UV", "uv.select_circle", 'EDIT'),
    ("ShaderNodeTree", "node.select_circle", 'OBJECT'),
    ("DOPESHEET", "action.select_circle", 'OBJECT'),
    ("FCURVES", "graph.select_circle", 'OBJECT'),
    ("CLIP_EDITOR", "clip.select_circle", 'OBJECT'),
    ("VIEW_3D", "mesh.knife_tool", 'EDIT'),
]
desk_state = {}


def _desk_area(ui_type):
    """The area the case runs in: the 3D View for its own operations, the timeline's otherwise."""
    window = bpy.context.window_manager.windows[0]
    wanted = 'VIEW_3D' if ui_type == "VIEW_3D" else 'DOPESHEET_EDITOR'
    for area in window.screen.areas:
        if area.type == wanted or (wanted == 'DOPESHEET_EDITOR' and area.type in
                                   ('IMAGE_EDITOR', 'NODE_EDITOR', 'GRAPH_EDITOR', 'CLIP_EDITOR')):
            return window, area
    return window, None


def _desk_only_area():
    window = bpy.context.window_manager.windows[0]
    area = window.screen.areas[0]
    return window, area, next(r for r in area.regions if r.type == 'WINDOW')


def _desk_ends():
    """What the toolbar view offers to end the waiting operation: the hint's label, the bar's Cancel."""
    hint, bar = _shows_cancel()
    return hint, bar


def _desk_object():
    return bpy.context.view_layer.objects.active


def _desk_mode(mode):
    """The cube's mode, set in a 3D View's context where there is one, as Focus Mode may hide it."""
    found = _view3d()
    if found:
        window, area, region = found
        with bpy.context.temp_override(window=window, area=area, region=region, active_object=_desk_object()):
            bpy.ops.object.mode_set(mode=mode)
    else:
        with bpy.context.temp_override(active_object=_desk_object(), object=_desk_object()):
            bpy.ops.object.mode_set(mode=mode)


def tick_desk():
    global step
    try:
        pump()
        step += 1
        problems = report.setdefault("problems", [])
        cases = report.setdefault("cases", {})
        if TOUCH_WINDOW is None:
            problems.append("this build has no WM_native_ui_touch_window_query")
            finish("error")
            return None
        if step == 1:
            lib.WM_native_ui_test_install_hooks()
            subs["settings"] = subscribe("settings")
            subs["toolbar"] = subscribe("toolbar")
            cube = bpy.data.objects["Cube"]
            bpy.context.view_layer.objects.active = cube
            cube.select_set(True)
            # Something to undo, and keys for the Graph Editor's operations to see.
            cube.keyframe_insert("location", frame=1)
            cube.location.x += 1.0
            cube.keyframe_insert("location", frame=20)
            bpy.ops.ed.undo_push(message="harness keys")
            return 0.5
        if step == 2:
            set_bool(subs["settings"], "desktop", True, 1400)
            return 1.0
        if step < 5:
            return 0.5
        phase = desk_state.get("phase", "next")
        if phase == "next":
            queue = desk_state.setdefault("queue", list(DESK_CASES))
            if not queue:
                desk_state["phase"] = "back"
                return 0.1
            ui_type, idname, mode = queue.pop(0)
            desk_state["case"] = (ui_type, idname)
            if _desk_object().mode != mode:
                _desk_mode(mode)
            window, area = _desk_area(ui_type)
            if area is None:
                problems.append("DESK-1 %s: no area to run it in" % idname)
                return 0.1
            if ui_type != "VIEW_3D":
                area.ui_type = ui_type
            region = next(r for r in area.regions if r.type == 'WINDOW')
            # Focus Mode: every bar hidden, this editor alone on the screen.
            with bpy.context.temp_override(window=window, area=area, region=region):
                bpy.ops.screen.screen_full_area(use_hide_panels=True)
            desk_state["phase"] = "start"
            return 0.6
        if phase == "start":
            ui_type, idname = desk_state["case"]
            window, area, region = _desk_only_area()
            entry = cases[idname] = {"editor": area.type, "areas on screen": len(window.screen.areas),
                                     "3D View on screen": any(a.type == 'VIEW_3D' for a in window.screen.areas)}
            module, name = idname.split(".")
            operator = getattr(getattr(bpy.ops, module), name)
            with bpy.context.temp_override(window=window, area=area, region=region):
                if not operator.poll():
                    entry["not started"] = "poll fails here"
                    desk_state["phase"] = "restore"
                    return 0.1
                result = operator('INVOKE_DEFAULT')
            entry["result"] = sorted(result)
            if 'RUNNING_MODAL' not in result:
                problems.append("DESK-1 %s: did not wait (%s)" % (idname, sorted(result)))
                desk_state["phase"] = "restore"
                return 0.1
            desk_state["phase"] = "check"
            return 0.6
        if phase == "check":
            ui_type, idname = desk_state["case"]
            entry = cases[idname]
            hint, bar = _desk_ends()
            entry["offered"] = hint or ("bar's Cancel" if bar else None)
            entry["undo enabled while it waits"] = _toolbar_node("undo").get("enabled")
            if not (hint or bar):
                problems.append("DESK-1 %s: waits in Focus Mode with no end offered" % idname)
            window, area, region = _desk_only_area()
            x, y = region.x + region.width // 2, region.y + region.height // 2
            # What the cluster's Done or Cancel sends.
            _simulate(window, 'ESC', 'PRESS', x, y)
            _simulate(window, 'ESC', 'RELEASE', x, y)
            desk_state["phase"] = "ended"
            return 0.6
        if phase == "ended":
            ui_type, idname = desk_state["case"]
            entry = cases[idname]
            hint, bar = _desk_ends()
            entry["waiting after Escape"] = bool(_touch_window()["modal"] or hint or bar)
            if entry["waiting after Escape"]:
                problems.append("DESK-1 %s: still waits after Escape" % idname)
            desk_state["phase"] = "restore"
            return 0.1
        if phase == "restore":
            window, area, region = _desk_only_area()
            if len(window.screen.areas) == 1:
                with bpy.context.temp_override(window=window, area=area, region=region):
                    bpy.ops.screen.screen_full_area(use_hide_panels=True)
            if _desk_object().mode != 'OBJECT':
                _desk_mode('OBJECT')
            desk_state["phase"] = "next"
            return 0.6
        if phase == "back":
            # Undo is offered with no 3D View on the screen: Focus Mode on the timeline.
            window, area = _desk_area("DOPESHEET")
            area.ui_type = "DOPESHEET"
            region = next(r for r in area.regions if r.type == 'WINDOW')
            with bpy.context.temp_override(window=window, area=area, region=region):
                bpy.ops.screen.screen_full_area(use_hide_panels=True)
            desk_state["phase"] = "undo"
            return 0.8
        if phase == "undo":
            report["undo enabled in Focus Mode on the Dope Sheet"] = _toolbar_node("undo").get("enabled")
            if not report["undo enabled in Focus Mode on the Dope Sheet"]:
                problems.append("DESK-1: Undo is not offered with no 3D View on the screen")
            # The way back, from Focus Mode on an editor that is not a 3D View.
            set_bool(subs["settings"], "desktop", False, 1401)
            desk_state["phase"] = "returning"
            return 0.5
        if phase == "returning":
            # The command was taken in this pass; the layout follows on the next ones.
            desk_state["phase"] = "returned"
            return 1.0
        if phase == "returned":
            window = bpy.context.window_manager.windows[0]
            report["after the way back"] = [a.type for a in window.screen.areas]
            if not any(a.type == 'VIEW_3D' for a in window.screen.areas):
                problems.append("DESK-1: the way back from Focus Mode did not bring the 3D View back")
            started = [name for name, entry in cases.items() if "offered" in entry]
            report["started"] = started
            if len(started) < 4:
                problems.append("DESK-1: fewer than four H1 operations started; the sweep proves little")
            finish("done" if not problems else "error")
            return None
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.3


def _toolbar_node(key):
    top = tree(subs["toolbar"]) or {}
    return next((n for n in top.get("children", []) if n["key"] == key), {})


# ROUND6 DESK-2 (H4, A5; decision R6-7): in Blender's own interface a hold that ends without moving
# is a right-click there. The class: every key-map item on the right button. Each is placed by the
# kind of place its region is for a finger (the map's own rule): interface, where a hold reaches it,
# or a canvas, whose editor's header menus carry the same commands (H4); a region the rule does not
# place fails. Then, with Blender's own interface on, the right-click GHOST sends after a hold (a
# finger's right button at the point) must open a menu at each kind of interface place: a number
# field, a header's empty space, a workspace tab, a header's button, an Outliner row and an area's
# edge.
TOUCH_KIND = getattr(lib, "WM_native_ui_test_touch_kind", None)
if TOUCH_KIND is not None:
    TOUCH_KIND.restype = ctypes.c_int
    TOUCH_KIND.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
hold_state = {}


def _menu_open():
    return any(where == "MENU" for where, kind, _t, _r in _touch_map() if kind == "zone")


def _right_click(window, x, y):
    _simulate(window, 'MOUSEMOVE', 'NOTHING', x, y)
    _simulate(window, 'RIGHTMOUSE', 'PRESS', x, y)
    _simulate(window, 'RIGHTMOUSE', 'RELEASE', x, y)


def _hold_places():
    rows = _touch_map()
    buttons = [(where, int(kind), rect) for where, kind, _t, rect in rows if kind != "zone"]
    zones = {where: rect for where, kind, _t, rect in rows if kind == "zone"}
    places = []
    numbers = [r for w, k, r in buttons if w == "PROPERTIES WINDOW" and k == BUTTON_NUM]
    if numbers:
        places.append(("a number field (Properties)", _centre(numbers[0])))
    # A header's empty space (its own menu: show, hide, flip). A panel's header has a menu only in a
    # region with category tabs, as on the desktop.
    bar = zones.get("VIEW_3D HEADER")
    if bar:
        header_buttons = [r for w, k, r in buttons if w == "VIEW_3D HEADER"]
        y = (bar[1] + bar[3]) / 2
        for x in range(bar[2] - 4, bar[0], -4):
            if not any(r[0] - 4 <= x <= r[2] + 4 for r in header_buttons):
                places.append(("a header's empty space (3D View)", (x, y)))
                break
    tabs = [r for w, k, r in buttons if w == "TOPBAR HEADER" and k == BUTTON_TAB]
    if tabs:
        places.append(("a workspace tab", _centre(tabs[-1])))
    header = [r for w, k, r in buttons if w == "VIEW_3D HEADER"]
    if header:
        places.append(("a header's button (3D View)", _centre(header[0])))
    outliner = zones.get("OUTLINER WINDOW")
    if outliner:
        places.append(("an Outliner row", (outliner[0] + 60, outliner[3] - 12)))
        # The edge between the Outliner and Properties, below it.
        places.append(("the edge between the Outliner and Properties", ((outliner[0] + outliner[2]) / 2, outliner[1] - 1)))
    return places


def tick_hold():
    global step
    try:
        pump()
        step += 1
        problems = report.setdefault("problems", [])
        if TOUCH is None or TOUCH_KIND is None:
            problems.append("this build has no touch map or WM_native_ui_test_touch_kind")
            finish("error")
            return None
        if step == 1:
            lib.WM_native_ui_test_install_hooks()
            subs["settings"] = subscribe("settings")
            # The class: every right-button item, placed by its region's kind for a finger.
            kinds = {1: "3D View", 2: "canvas", 3: "interface"}
            placed, unplaced = {}, []
            for keymap in bpy.context.window_manager.keyconfigs.active.keymaps:
                for item in keymap.keymap_items:
                    if item.type != 'RIGHTMOUSE' or not item.active or item.map_type != 'MOUSE':
                        continue
                    kind = TOUCH_KIND(keymap.space_type.encode(), keymap.region_type.encode())
                    entry = "%s: %s" % (keymap.name, item.idname)
                    if kind in kinds:
                        placed.setdefault(kinds[kind], []).append(entry)
                    elif keymap.region_type == 'WINDOW' and keymap.space_type == 'EMPTY':
                        # Window and screen key maps: where the pointer is decides, any place.
                        placed.setdefault("any place", []).append(entry)
                    else:
                        unplaced.append("%s (%s %s)" % (entry, keymap.space_type, keymap.region_type))
            report["right-button items by place"] = {key: len(value) for key, value in placed.items()}
            report["right-button items on canvases (their header menus, H4)"] = sorted(placed.get("canvas", []))
            for entry in unplaced:
                problems.append("DESK-2: a right-button item in a region no rule places: %s" % entry)
            if len(placed.get("interface", [])) < 5:
                problems.append("DESK-2: fewer than five right-button items found on interface; the sweep proves little")
            return 0.5
        if step == 2:
            set_bool(subs["settings"], "desktop", True, 1500)
            return 1.0
        if step < 5:
            return 0.5
        window = bpy.context.window_manager.windows[0]
        if "places" not in hold_state:
            hold_state["places"] = _hold_places()
            hold_state["results"] = report.setdefault("menus", {})
            if len(hold_state["places"]) < 6:
                problems.append("DESK-2: only %d of the six kinds of place found" % len(hold_state["places"]))
        current = hold_state.pop("current", None)
        if current:
            opened = _menu_open()
            hold_state["results"][current] = "menu" if opened else "nothing"
            if not opened:
                problems.append("DESK-2: a right-click on %s opened no menu" % current)
            _simulate(window, 'ESC', 'PRESS', 4, 4)
            _simulate(window, 'ESC', 'RELEASE', 4, 4)
            return 0.5
        if hold_state["places"]:
            name, (x, y) = hold_state["places"].pop(0)
            if _menu_open():
                problems.append("DESK-2: a menu was still open before %s" % name)
            _right_click(window, x, y)
            hold_state["current"] = name
            return 0.6
        finish("done" if not problems else "error")
        return None
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.3


# ROUND6 DESK-3 (A6, H6, D6): typing reaches what Blender takes text from keys for. The class is the
# key maps' `TEXTINPUT` items; a press in a region tells the platform whether one of its key maps
# would take typed text there now, and the iPad raises its keyboard that sends key events then.
# With Blender's own interface on: a press in the Text Editor, the Python Console and a text object
# in Edit Mode says so, a press in Properties does not; and a line typed as key events, as that
# keyboard sends them, runs in the Python Console.
TEXT_FOCUS = getattr(lib, "WM_native_ui_test_text_input_focus", None)
if TEXT_FOCUS is not None:
    TEXT_FOCUS.restype = ctypes.c_int
    TEXT_FOCUS.argtypes = [ctypes.POINTER(ctypes.c_int)]
typing_state = {}
# A line as the iPad's keyboard sends it: each character as its key with its text.
TYPED_KEYS = {" ": "SPACE", "=": "EQUAL", ".": "PERIOD", "-": "MINUS"}
TYPED_DIGITS = ["ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE"]


def _text_focus():
    count = ctypes.c_int(0)
    value = TEXT_FOCUS(ctypes.byref(count))
    return value, count.value


def _type_line(window, x, y, line):
    for character in line:
        if character.isdigit():
            kind = TYPED_DIGITS[int(character)]
        elif character.isalpha():
            kind = character.upper()
        else:
            kind = TYPED_KEYS[character]
        window.event_simulate(type=kind, value='PRESS', x=x, y=y, unicode=character)
        window.event_simulate(type=kind, value='RELEASE', x=x, y=y)
    window.event_simulate(type='RET', value='PRESS', x=x, y=y)
    window.event_simulate(type='RET', value='RELEASE', x=x, y=y)


def _typing_area(ui_type):
    window = bpy.context.window_manager.windows[0]
    if ui_type == 'VIEW_3D':
        area = next(a for a in window.screen.areas if a.type == 'VIEW_3D')
    elif ui_type == 'PROPERTIES':
        area = next(a for a in window.screen.areas if a.type == 'PROPERTIES')
    else:
        area = next(a for a in window.screen.areas
                    if a.type in ('DOPESHEET_EDITOR', 'TEXT_EDITOR', 'CONSOLE', 'SEQUENCE_EDITOR'))
        area.ui_type = ui_type
    region = next(r for r in area.regions if r.type == 'WINDOW')
    return window, area, region


def tick_typing():
    global step
    try:
        pump()
        step += 1
        problems = report.setdefault("problems", [])
        if TEXT_FOCUS is None:
            problems.append("this build has no WM_native_ui_test_text_input_focus")
            finish("error")
            return None
        if step == 1:
            lib.WM_native_ui_test_install_hooks()
            subs["settings"] = subscribe("settings")
            # The class: every key map with a `TEXTINPUT` item, by editor and region.
            items = []
            for keymap in bpy.context.window_manager.keyconfigs.active.keymaps:
                for item in keymap.keymap_items:
                    if item.type == 'TEXTINPUT' and item.active:
                        items.append("%s (%s %s): %s" % (keymap.name, keymap.space_type, keymap.region_type, item.idname))
            report["TEXTINPUT items"] = sorted(items)
            if len(items) < 4:
                problems.append("DESK-3: fewer than four TEXTINPUT items; the sweep proves little")
            return 0.5
        if step == 2:
            set_bool(subs["settings"], "desktop", True, 1600)
            return 1.0
        if step < 5:
            return 0.5
        cases = typing_state.setdefault("cases", [
            ("TEXT_EDITOR", True), ("CONSOLE", True), ("PROPERTIES", False), ("VIEW_3D text object", True),
            ("SEQUENCE_EDITOR", None),
        ])
        current = typing_state.pop("current", None)
        results = report.setdefault("a press says it takes text", {})
        if current:
            name, expected = current
            value, count = _text_focus()
            said = None if count == typing_state["count"] else bool(value)
            results[name] = said
            if expected is not None and said != expected:
                problems.append("DESK-3: a press in %s said %s, expected %s" % (name, said, expected))
            if name == "VIEW_3D text object":
                _desk_mode('OBJECT')
            if name == "CONSOLE":
                # A line typed as key events, as the keyboard sends it, runs.
                window, area, region = _typing_area("CONSOLE")
                x, y = region.x + region.width // 2, region.y + region.height // 2
                _type_line(window, x, y, "x = 40")
                _type_line(window, x, y, "x")
                typing_state["console"] = area
                return 0.8
            return 0.2
        if "console" in typing_state:
            area = typing_state.pop("console")
            lines = [line.body for line in area.spaces[0].scrollback]
            report["console scrollback"] = lines[-4:]
            if "40" not in lines:
                problems.append("DESK-3: a line typed as key events did not run in the Python Console")
            return 0.2
        if not cases:
            finish("done" if not problems else "error")
            return None
        name, expected = cases.pop(0)
        if name == "TEXT_EDITOR":
            window, area, region = _typing_area("TEXT_EDITOR")
            area.spaces[0].text = bpy.data.texts.new("typed")
        elif name == "VIEW_3D text object":
            bpy.ops.object.text_add()
            _desk_mode('EDIT')
            window, area, region = _typing_area("VIEW_3D")
        elif name == "SEQUENCE_EDITOR":
            window, area, region = _typing_area("SEQUENCE_EDITOR")
            area.spaces[0].view_type = 'PREVIEW'
            region = next(r for r in area.regions if r.type == 'PREVIEW')
            scene = bpy.context.scene
            if scene.sequence_editor is None:
                scene.sequence_editor_create()
            strip = scene.sequence_editor.strips.new_effect("typed", 'TEXT', channel=1, frame_start=1, length=20)
            scene.sequence_editor.active_strip = strip
            strip.select = True
            with bpy.context.temp_override(window=window, area=area, region=region):
                try:
                    bpy.ops.sequencer.text_edit_mode_toggle()
                    report["sequencer text editing"] = "on"
                except Exception as error:
                    report["sequencer text editing"] = str(error).splitlines()[0][:100]
        else:
            window, area, region = _typing_area(name)
        x, y = region.x + region.width // 2, region.y + region.height // 2
        typing_state["count"] = _text_focus()[1]
        _simulate(window, 'MOUSEMOVE', 'NOTHING', x, y)
        _simulate(window, 'LEFTMOUSE', 'PRESS', x, y)
        _simulate(window, 'LEFTMOUSE', 'RELEASE', x, y)
        typing_state["current"] = (name, expected)
        return 0.5
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.3


# ROUND6 DESK-5 (H2): one window means one window. Each command that opens a window of its own on a
# desktop (`WM_window_open_temp`'s callers) is run as its menu or button runs it, with Blender's own
# interface on: the window manager must keep one window, the command's editor shown full screen with
# Back to Previous, which brings the layout back.
WINDOW_CASES = [("outliner.orphans_manage", 'OUTLINER'), ("screen.info_log_show", 'INFO'),
                ("screen.drivers_editor_show", 'GRAPH_EDITOR')]
windows_state = {}


def tick_windows():
    global step
    try:
        pump()
        step += 1
        problems = report.setdefault("problems", [])
        cases = report.setdefault("cases", {})
        wm = bpy.context.window_manager
        if step == 1:
            lib.WM_native_ui_test_install_hooks()
            subs["settings"] = subscribe("settings")
            return 0.5
        if step == 2:
            set_bool(subs["settings"], "desktop", True, 1700)
            return 1.0
        if step < 5:
            return 0.5
        phase = windows_state.get("phase", "next")
        window = wm.windows[0]
        if phase == "next":
            queue = windows_state.setdefault("queue", list(WINDOW_CASES))
            if not queue:
                finish("done" if not problems else "error")
                return None
            idname, editor = queue.pop(0)
            windows_state["case"] = (idname, editor)
            windows_state["areas before"] = sorted(a.type for a in window.screen.areas)
            area = next(a for a in window.screen.areas if a.type == 'PROPERTIES')
            region = next(r for r in area.regions if r.type == 'WINDOW')
            module, name = idname.split(".")
            with bpy.context.temp_override(window=window, area=area, region=region):
                result = getattr(getattr(bpy.ops, module), name)('INVOKE_DEFAULT')
            cases[idname] = {"result": sorted(result)}
            windows_state["phase"] = "check"
            return 0.8
        if phase == "check":
            idname, editor = windows_state["case"]
            entry = cases[idname]
            entry["windows"] = len(wm.windows)
            entry["areas"] = [a.type for a in wm.windows[-1].screen.areas]
            if len(wm.windows) != 1:
                problems.append("DESK-5: %s opened a window of its own (%d windows)" % (idname, len(wm.windows)))
                # Closed again, so the next case starts from one window.
                for extra in list(wm.windows)[1:]:
                    with bpy.context.temp_override(window=extra):
                        bpy.ops.wm.window_close()
                windows_state["phase"] = "next"
                return 0.8
            if editor not in entry["areas"]:
                problems.append("DESK-5: %s shows no %s (%s)" % (idname, editor, entry["areas"]))
            area = next((a for a in window.screen.areas if a.type == editor), None)
            if area is not None:
                region = next(r for r in area.regions if r.type == 'WINDOW')
                with bpy.context.temp_override(window=window, area=area, region=region):
                    entry["back to previous"] = sorted(bpy.ops.screen.back_to_previous())
            windows_state["phase"] = "back"
            return 0.8
        if phase == "back":
            idname, editor = windows_state["case"]
            entry = cases[idname]
            entry["areas after Back to Previous"] = sorted(a.type for a in window.screen.areas)
            if entry["areas after Back to Previous"] != windows_state["areas before"]:
                problems.append("DESK-5: Back to Previous after %s did not bring the layout back" % idname)
            windows_state["phase"] = "next"
            return 0.3
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.3


# ROUND6 DESK-6 (H14): layout by finger. Blender's small screen targets that take a tolerance (an
# area's corner, a region's edge, an edge between areas, a scroll-bar) get a finger's margin in
# points, whatever the interface size. At each offered size from the smallest to the largest, the
# finger's map measures each kind of target across, in points; the ones with no menu route (a corner:
# swap; a region's edge: resize) must reach a floor. Then a finger's press inside the margin, outside
# Blender's own band, on the edge between the Outliner and Properties, dragged, moves the edge:
# Blender's own test takes it.
MARGIN_SIZES = [0.5, 0.75, 1.0, 1.5]
MARGIN_FLOOR_PT = 16.0
MARGIN_KINDS = (" AREA CORNER", " REGION EDGE", "AREA EDGE", " SCROLLBAR")
margins_state = {}


def set_float(subscription, target, value, command_id):
    builder = flatbuffers.Builder(256)
    t = builder.CreateString(target)
    FloatValue.Start(builder)
    FloatValue.AddValue(builder, value)
    fv = FloatValue.End(builder)
    Command.Start(builder)
    Command.AddId(builder, command_id)
    Command.AddSubscription(builder, subscription)
    Command.AddTarget(builder, t)
    Command.AddOp(builder, Op.Op.Set)
    Command.AddValueType(builder, Value.Value.FloatValue)
    Command.AddValue(builder, fv)
    c = Command.End(builder)
    Commands.StartCommandsVector(builder, 1)
    builder.PrependUOffsetTRelative(c)
    vec = builder.EndVector()
    Commands.Start(builder)
    Commands.AddCommands(builder, vec)
    builder.Finish(Commands.End(builder))
    data = bytes(builder.Output())
    lib.WM_native_ui_send(data, len(data))


def tick_margins():
    global step
    try:
        pump()
        step += 1
        problems = report.setdefault("problems", [])
        point = 2.0
        if step == 1:
            lib.WM_native_ui_test_install_hooks()
            subs["settings"] = subscribe("settings")
            return 0.5
        if step == 2:
            set_bool(subs["settings"], "desktop", True, 1800)
            # A finger, 2 window pixels a point: its margin is 6 pt.
            SIMULATE_FINGER(point)
            window = bpy.context.window_manager.windows[0]
            _simulate(window, 'MOUSEMOVE', 'NOTHING', 10, 10)
            margins_state["sizes"] = list(MARGIN_SIZES)
            return 1.0
        sizes = margins_state.get("sizes")
        if "measuring" in margins_state:
            size = margins_state.pop("measuring")
            widths = {}
            for where, kind, _t, rect in _touch_map():
                if kind != "zone":
                    continue
                for suffix in MARGIN_KINDS:
                    if where.endswith(suffix):
                        across = min(rect[2] - rect[0], rect[3] - rect[1]) / point
                        widths[suffix.strip()] = round(min(widths.get(suffix.strip(), 1e9), across), 1)
            report.setdefault("narrowest, in points, by interface size", {})[str(size)] = widths
            for suffix in (" AREA CORNER", " REGION EDGE"):
                width = widths.get(suffix.strip())
                if width is None:
                    problems.append("DESK-6: no%s at size %s" % (suffix, size))
                elif width < MARGIN_FLOOR_PT:
                    problems.append("DESK-6:%s is %.1f pt across at size %s, under %.0f pt" % (suffix, width, size, MARGIN_FLOOR_PT))
        if sizes:
            size = sizes.pop(0)
            set_float(subs["settings"], "desktop_scale", size, 1810 + len(sizes))
            margins_state["measuring"] = size
            return 1.5
        if "moved" not in margins_state:
            window = bpy.context.window_manager.windows[0]
            outliner = next(a for a in window.screen.areas if a.type == 'OUTLINER')
            # The edge between the Outliner and Properties below it, pressed inside the finger's
            # margin, outside the band Blender has for a mouse (its band and 3 pt more), then dragged.
            edge_y = outliner.y
            mouse_band = 4 * bpy.context.preferences.system.ui_scale * point / 2 + 2
            x = outliner.x + outliner.width // 2
            y = int(edge_y + mouse_band + 3 * point)
            if os.environ.get("DESK6_CONTROL"):
                # The control: on the edge itself, where a mouse takes it too.
                y = edge_y
            report["edge and press"] = [edge_y, [x, y]]
            margins_state["moved"] = outliner.height
            _simulate(window, 'MOUSEMOVE', 'NOTHING', x, y)
            _simulate(window, 'LEFTMOUSE', 'PRESS', x, y)
            for i in range(1, 9):
                _simulate(window, 'MOUSEMOVE', 'NOTHING', x, y + 8 * i)
            _simulate(window, 'LEFTMOUSE', 'RELEASE', x, y + 64)
            return 1.0
        window = bpy.context.window_manager.windows[0]
        outliner = next(a for a in window.screen.areas if a.type == 'OUTLINER')
        report["Outliner height before and after the edge's drag"] = [margins_state["moved"], outliner.height]
        if outliner.height == margins_state["moved"]:
            problems.append("DESK-6: a finger's drag from inside the margin of an edge between areas moved nothing")
        SIMULATE_FINGER(0.0)
        finish("done" if not problems else "error")
        return None
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.3


def _touchstart_enter_for(idname):
    mode, name = _touchstart_mode(idname)
    _touchstart_enter(mode, name)
    return mode, name


bpy.app.timers.register({"touch": tick_touch, "material": tick_material, "insets": tick_insets, "tabs": tick_tabs, "precision": tick_precision, "reveal": tick_reveal, "knife": tick_knife, "menus": tick_menus, "mirror": tick_mirror,
                         "extensions": tick_extensions, "keys": tick_keys,
                         "numinput": tick_numinput, "render": tick_render,
                         "fingers": tick_fingers, "undo": tick_undo,
                         "tolerance": tick_tolerance, "waiting": tick_waiting,
                         "touchstart": tick_touchstart, "jobs": tick_jobs,
                         "renderprogress": tick_render_progress, "busy": tick_busy,
                         "renderkeep": tick_render_keep, "desk": tick_desk, "hold": tick_hold, "typing": tick_typing, "windows": tick_windows, "margins": tick_margins}.get(SCENARIO, tick_actions),
                        first_interval=1.0)
