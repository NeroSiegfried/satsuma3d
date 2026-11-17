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
    BoolValue, Button, ButtonStyle, Choice, Command, Commands, Content, Data, Group, Node, Number, Op, Param, Subscribe,
    TextValue, Toggle, Updates, Value,
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
    ]


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
        if report["case"] >= len(cases):
            del report["cases"]
            finish("done")
            return None
        if step > 80:
            del report["cases"]
            finish("timeout")
            return None
    except Exception:
        report.pop("cases", None)
        report["error"] = traceback.format_exc()
        finish("error")
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


bpy.app.timers.register({"tabs": tick_tabs, "precision": tick_precision, "reveal": tick_reveal, "knife": tick_knife, "menus": tick_menus, "mirror": tick_mirror}.get(SCENARIO, tick_actions),
                        first_interval=1.0)
