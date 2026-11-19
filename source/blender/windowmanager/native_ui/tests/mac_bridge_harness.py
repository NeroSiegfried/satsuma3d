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
    BoolValue, Button, ButtonStyle, Choice, Command, Commands, Content, Data, FloatsValue, Group, MenuButton, Node, Number,
    Op, Param,
    Reference,
    Subscribe, TextValue, Toggle, Updates, Value,
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
    builder = flatbuffers.Builder(256)
    t = builder.CreateString(target)
    Command.Start(builder)
    Command.AddId(builder, command_id)
    Command.AddSubscription(builder, subscription)
    Command.AddTarget(builder, t)
    Command.AddOp(builder, Op.Op.Invoke if op is None else op)
    c = Command.End(builder)
    Commands.StartCommandsVector(builder, 1)
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
        elif data.ValueType() == Value.Value.FloatsValue:
            fv = FloatsValue.FloatsValue()
            fv.Init(data.Value().Bytes, data.Value().Pos)
            entry.update(value=[fv.Value(i) for i in range(fv.ValueLength())])
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
                    # Each of the view's buttons is live or waits: Clear answers at once (and leaves
                    # a running render alone), rendering again waits for this render.
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
                       report["image_ack_while_rendering"] is None else "error")
                return None
            return 0.05
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.3


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


touch_state = {}


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
                expect("the timeline (a canvas)", _centre(timeline), "canvas")
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
                cube.modifiers.new("Bevel %d" % index, 'BEVEL')
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
            finish("done" if not problems else "error")
            return None
    except Exception:
        report["error"] = traceback.format_exc()
        finish("error")
        return None
    return 0.3


bpy.app.timers.register({"touch": tick_touch, "material": tick_material, "insets": tick_insets, "tabs": tick_tabs, "precision": tick_precision, "reveal": tick_reveal, "knife": tick_knife, "menus": tick_menus, "mirror": tick_mirror,
                         "extensions": tick_extensions, "keys": tick_keys,
                         "numinput": tick_numinput, "render": tick_render}.get(SCENARIO, tick_actions),
                        first_interval=1.0)
