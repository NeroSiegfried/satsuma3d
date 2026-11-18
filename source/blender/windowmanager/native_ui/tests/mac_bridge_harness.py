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
# The "Blender" strings the app may show (ROUND5 8A.7), read by the `menus` scenario.
ALLOWED = argv[3] if len(argv) > 3 else None
# The shell's own commands a key may stand in for (ROUND5 9A.6), read by the `keys` scenario.
STAND_INS = argv[4] if len(argv) > 4 else None

import flatbuffers  # noqa: E402
from Blender.NativeUI import (  # noqa: E402
    BoolValue, Button, ButtonStyle, Choice, Command, Commands, Content, Data, Group, MenuButton, Node, Number, Op, Param,
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
lib.WM_native_ui_image_take_uvs.restype = ctypes.c_bool
lib.WM_native_ui_image_take_uvs.argtypes = [ctypes.POINTER(ctypes.POINTER(ctypes.c_float)), ctypes.POINTER(ctypes.c_int)]
lib.free.argtypes = [ctypes.c_void_p]


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
        allowed = branding.setdefault("allowed", branding_allowed())
        for route, menu in (("menubar", "menubar"), ("context", "context"),
                            ("TOPBAR_MT_file_import", "TOPBAR_MT_file_import"),
                            ("TOPBAR_MT_file_export", "TOPBAR_MT_file_export")):
            walk_state[subscribe("menu", route=route)] = (route, menu, 1)
        walk_state["seen_routes"] = set()
        return False
    allowed = branding["allowed"]
    pending = 0
    for sub, entry in list(walk_state.items()):
        if sub == "seen_routes" or entry is None:
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
                report["branding"] = {"menus_read": branding["menus"], "labels_with_blender": sorted(branding["seen"]),
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
    """The UV edges the bridge published since the last look, or None (`WM_native_ui_image_take_uvs`)."""
    segments = ctypes.POINTER(ctypes.c_float)()
    count = ctypes.c_int()
    if not lib.WM_native_ui_image_take_uvs(ctypes.byref(segments), ctypes.byref(count)):
        return None
    values = [round(segments[i], 5) for i in range(count.value)] if segments else []
    if segments:
        lib.free(segments)
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
        report["uv_counts"] = {k: len(state.get(k) or []) for k in ("before", "after", "undone")}
        for key in ("before", "after", "undone", "last"):
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


bpy.app.timers.register({"material": tick_material, "tabs": tick_tabs, "precision": tick_precision, "reveal": tick_reveal, "knife": tick_knife, "menus": tick_menus, "mirror": tick_mirror,
                         "extensions": tick_extensions, "keys": tick_keys}.get(SCENARIO, tick_actions),
                        first_interval=1.0)
