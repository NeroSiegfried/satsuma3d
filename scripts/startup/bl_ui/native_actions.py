# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Context actions for the native iPad interface.

One registry, four surfaces: the strip along the viewport (``actions``), the grouped palette it
expands into (``palette``), the long-press menu (``long_press``) and the Pencil squeeze radial
(``radial``). An action is defined once and each surface picks from it.

Each action has a *scope*, the context it belongs to at all (the mode, the mesh select mode, the
active tool or brush, the active object's type and whether anything is selected), and an *enabled*
rule, whether it can run right now (selection counts and the operator's ``poll``). Within one scope
the palette keeps every item in place and dims what cannot run, so buttons do not jump as the
selection count changes; content changes only when the scope does.

Every operator entry must make sense without a pointer location and must not destroy data the user
did not ask to change. Commands that need a pointer (Loop Cut, Knife, Rip) activate their tool
instead. Menu entries name a Blender menu, which the shell shows natively by its route.
Operators run directly; the Adjust Last Operation strip tunes them afterwards.
"""

import json
import bpy
from bpy.props import EnumProperty

__all__ = (
    "GROUPS",
    "actions",
    "long_press",
    "palette",
    "radial",
    "rename_active",
    "run",
)

# The palette's groups, in display order. The mesh-centric groups come first, as in the plan; the
# other modes' groups follow, and `Delete` always comes last.
GROUPS = (
    "Selection",
    "Add",
    "Transform",
    "Object",
    "Mesh",
    "Face",
    "Edge",
    "Vertex",
    "Normals & Shading",
    "UV",
    "Modifiers",
    "Mask",
    "Face Sets",
    "Sculpt",
    "Pose",
    "Paint",
    "Curve",
    "Armature",
    "Grease Pencil",
    "Cursor",
    "View",
    "Cleanup",
    "Delete",
)

# Blender's own context menu for each mode, which "More..." in the long-press menu opens. `None`
# where the mode has no context menu (the paint and sculpt modes use a panel instead).
MODE_MENUS = {
    'OBJECT': "VIEW3D_MT_object_context_menu",
    'EDIT_MESH': "VIEW3D_MT_edit_mesh_context_menu",
    'EDIT_CURVE': "VIEW3D_MT_edit_curve_context_menu",
    'EDIT_CURVES': "VIEW3D_MT_edit_curves_context_menu",
    'EDIT_SURFACE': "VIEW3D_MT_edit_curve_context_menu",
    'EDIT_TEXT': "VIEW3D_MT_edit_font_context_menu",
    'EDIT_ARMATURE': "VIEW3D_MT_armature_context_menu",
    'EDIT_METABALL': "VIEW3D_MT_edit_metaball_context_menu",
    'EDIT_LATTICE': "VIEW3D_MT_edit_lattice_context_menu",
    'EDIT_GREASE_PENCIL': "VIEW3D_MT_greasepencil_edit_context_menu",
    'EDIT_POINTCLOUD': None,
    'POSE': "VIEW3D_MT_pose_context_menu",
    'SCULPT': None,
    'PAINT_WEIGHT': None,
    'PAINT_VERTEX': None,
    'PAINT_TEXTURE': None,
    'PARTICLE': "VIEW3D_MT_particle_context_menu",
    'PAINT_GPENCIL': None,
    'EDIT_GPENCIL': None,
    'SCULPT_GPENCIL': None,
    'WEIGHT_GPENCIL': None,
    'VERTEX_GPENCIL': None,
    'SCULPT_CURVES': None,
    'PAINT_GREASE_PENCIL': None,
    'SCULPT_GREASE_PENCIL': None,
    'WEIGHT_GREASE_PENCIL': None,
    'VERTEX_GREASE_PENCIL': None,
}

# How many in-scope actions the long-press menu and the radial take.
LONG_PRESS_ACTIONS = 5
RADIAL_SLOTS = 8

# Object types that have an Edit Mode.
_EDITABLE_TYPES = {'MESH', 'CURVE', 'SURFACE', 'META', 'FONT', 'LATTICE', 'ARMATURE', 'GREASEPENCIL',
                   'CURVES', 'POINTCLOUD'}


class _State:
    """The context signals the rules read, gathered once per query."""

    def __init__(self, context, tool):
        self.context = context
        self.mode = context.mode
        self.tool = tool or ""
        self.selecting = self.tool.startswith("builtin.select")
        self.obj = context.active_object
        self.selected = list(context.selected_objects) if self.mode == 'OBJECT' else []
        # The sculpt brush in use, for the brushes that work on masks and face sets.
        brush = None
        if self.mode == 'SCULPT':
            paint = context.tool_settings.sculpt
            brush = paint.brush if paint else None
        self.sculpt_brush = getattr(brush, "sculpt_brush_type", "") if brush else ""
        self.verts = self.edges = self.faces = 0
        self.select_mode = (False, False, False)
        if self.mode == 'EDIT_MESH':
            self.select_mode = tuple(context.tool_settings.mesh_select_mode)
            for ob in context.objects_in_mode_unique_data:
                mesh = ob.data
                self.verts += mesh.total_vert_sel
                self.edges += mesh.total_edge_sel
                self.faces += mesh.total_face_sel

    @property
    def size(self):
        """A length on the scale of the active object, for initial bevel and inset sizes."""
        if self.obj is None:
            return 1.0
        return max(max(self.obj.dimensions), 1e-4)

    def selected_of_type(self, *types):
        return [ob for ob in self.selected if ob.type in types]

    @property
    def active_selected(self):
        """The active object, when it is also selected."""
        return self.obj if self.obj is not None and self.obj in self.selected else None

    @property
    def face_sets(self):
        """Working on face sets in Sculpt Mode: a face set tool or the Face Sets brush."""
        return self.mode == 'SCULPT' and ("face_set" in self.tool or self.sculpt_brush == 'DRAW_FACE_SETS')

    @property
    def masking(self):
        """Working on the mask in Sculpt Mode: a mask tool or the Mask brush."""
        return self.mode == 'SCULPT' and (
            ("mask" in self.tool and "face_set" not in self.tool) or self.sculpt_brush == 'MASK')

    def scope_key(self):
        """What decides presence. Two states with the same key show the same palette items."""
        return (self.mode, self.select_mode, self.tool, self.sculpt_brush,
                self.obj.type if self.obj else None,
                bool(self.selected) if self.mode == 'OBJECT' else self.verts > 0)

    def xray(self):
        space = self.context.space_data
        return bool(space and space.type == 'VIEW_3D' and space.shading.show_xray)


def _always(_state):
    return True


class Rule:
    """A scope and an enabled rule together, from the helpers below."""

    __slots__ = ("scope", "enabled")

    def __init__(self, scope, enabled=None):
        self.scope = scope
        self.enabled = enabled or _always

    def __call__(self, state):
        return self.scope(state) and self.enabled(state)


class Action:
    __slots__ = ("id", "label", "op", "icon", "scope", "enabled", "props", "checked", "first", "invoke",
                 "group", "destructive", "tool", "menu", "strip")

    def __init__(self, id, label, op, icon="", when=None, props=None, checked=None, first=None,
                 invoke=False, *, group, enabled=None, destructive=False, tool="", menu="", strip=True):
        self.id = id
        self.label = label
        self.icon = icon
        # Presence: does it belong to this context at all. A `Rule` brings its own enabled rule.
        when = when or _always
        self.scope = when.scope if isinstance(when, Rule) else when
        rules = [rule for rule in (when.enabled if isinstance(when, Rule) else None, enabled) if rule]
        # Dimming: can it run now. The operator's poll is checked on top of this.
        self.enabled = (lambda s: all(rule(s) for rule in rules)) if rules else _always
        self.props = props or {}
        self.checked = checked
        # Whether it leads the strip: what the active tool or brush works on comes before the rest.
        self.first = first
        # Runs where the pointer or Pencil last was, as from Blender's menu.
        self.invoke = invoke
        self.group = group
        # Tinted red, always last, never a radial default.
        self.destructive = destructive
        # Activates this tool rather than running an operator, for commands that need a pointer.
        self.tool = tool
        # Opens this Blender menu, which the shell shows natively.
        self.menu = menu
        # Whether it may show in the collapsed strip, or only in the palette; a bool or a rule.
        self.strip = strip
        if tool:
            self.op = "wm.tool_set_by_id"
            self.props = {"name": tool}
        elif menu:
            self.op = "wm.call_menu"
            self.props = {"name": menu}
            self.invoke = True
        else:
            self.op = op
        assert group in GROUPS, group

    def properties(self, state):
        return self.props(state) if callable(self.props) else dict(self.props)

    def operator(self):
        module, name = self.op.split(".")
        return getattr(getattr(bpy.ops, module), name)

    def in_strip(self, state):
        return self.strip(state) if callable(self.strip) else self.strip

    def applies(self, state):
        """In scope and able to run, ignoring the operator's poll."""
        return self.scope(state) and self.enabled(state)


def _unapplied_scale(s):
    """Non-unit scale silently skews bevels, modifiers and physics, so offer to apply it."""
    return any(any(abs(v - 1.0) > 1e-6 for v in ob.scale) for ob in s.selected)


_SELECT_MODES = {"VERT": 0, "EDGE": 1, "FACE": 2}


def _mesh(*modes, verts=0, edges=0, faces=0, exclude=()):
    """Edit Mesh with something selected and one of ``modes`` active (none of ``exclude``). The
    counts only dim: with too few selected the action stays in place."""

    def scope(s):
        if s.mode != 'EDIT_MESH' or not s.verts:
            return False
        if modes and not any(s.select_mode[_SELECT_MODES[mode]] for mode in modes):
            return False
        return not any(s.select_mode[_SELECT_MODES[mode]] for mode in exclude)

    def enabled(s):
        return s.verts >= verts and s.edges >= edges and s.faces >= faces
    return Rule(scope, enabled)


def _mesh_empty(s):
    return s.mode == 'EDIT_MESH' and not s.verts


def _object(min_selected=1, types=None, tools=None):
    """Object Mode with an object of ``types`` selected; fewer than ``min_selected`` only dims."""

    def scope(s):
        if s.mode != 'OBJECT' or (tools and s.tool not in tools):
            return False
        return bool(s.selected_of_type(*types) if types else s.selected)

    def enabled(s):
        chosen = s.selected_of_type(*types) if types else s.selected
        return len(chosen) >= min_selected
    return Rule(scope, enabled)


def _object_empty(s):
    return s.mode == 'OBJECT' and not s.selected


def _active_type(*types):
    """Object Mode with the active object selected and of one of ``types``."""
    return lambda s: s.mode == 'OBJECT' and s.active_selected is not None and s.active_selected.type in types


def _has_modifier(ob, kind):
    return any(mod.type == kind for mod in ob.modifiers)


def _modifier_on(kind):
    """Shows as pressed while every selected mesh has the modifier."""
    def checked(s):
        meshes = s.selected_of_type('MESH')
        return bool(meshes) and all(_has_modifier(ob, kind) for ob in meshes)
    return checked


def _selecting(s):
    return s.selecting


# The selection tools in Object and Edit Mode lead with selecting.
_SELECT_TOOLS = ("builtin.select", "builtin.select_box", "builtin.select_circle", "builtin.select_lasso")

# Ordered by how often each is needed in its context: within a scope, this order is the strip's and
# the palette group's. Destructive actions sort last wherever they are listed.
ACTIONS = [
    # Object Mode, nothing selected.
    Action("object.select_all", "Select All", "object.select_all", "SELECT_EXTEND", _object_empty,
           {"action": 'SELECT'}, group="Selection"),
    Action("object.add", "Add", "", "ADD", _object_empty, menu="VIEW3D_MT_add", group="Add"),
    Action("object.paste", "Paste", "view3d.pastebuffer", "PASTEDOWN", lambda s: s.mode == 'OBJECT',
           group="Object", strip=_object_empty),

    # Object Mode, a selection: the type-specific lead first.
    Action("object.active_camera", "Set Active Camera", "view3d.object_as_camera", "VIEW_CAMERA",
           _active_type('CAMERA'), group="Object", enabled=lambda s: s.context.scene.camera != s.obj),
    Action("object.pose", "Pose Mode", "object.posemode_toggle", "POSE_HLT", _active_type('ARMATURE'),
           group="Object"),
    Action("object.edit", "Edit", "object.editmode_toggle", "EDITMODE_HLT", _active_type(*_EDITABLE_TYPES),
           group="Object"),
    Action("object.convert_mesh", "Convert to Mesh", "object.convert", "OUTLINER_OB_MESH",
           _active_type('CURVE', 'SURFACE', 'FONT', 'META'), {"target": 'MESH'}, group="Object"),
    Action("object.duplicate", "Duplicate", "object.duplicate", "DUPLICATE", _object(), {"linked": False},
           group="Object"),
    Action("object.shade_smooth", "Shade Smooth", "object.shade_smooth", "", _object(types=('MESH',)),
           group="Normals & Shading"),
    Action("object.subdivision", "Subdivision", "object.native_modifier_toggle", "MOD_SUBSURF",
           _object(types=('MESH',)), {"type": 'SUBSURF'}, checked=_modifier_on('SUBSURF'), group="Modifiers"),
    Action("object.mirror", "Mirror", "object.native_modifier_toggle", "MOD_MIRROR",
           _object(types=('MESH',)), {"type": 'MIRROR'}, checked=_modifier_on('MIRROR'), group="Modifiers"),
    Action("object.hide", "Hide", "object.hide_view_set", "HIDE_ON", _object(), {"unselected": False},
           group="Object"),
    Action("object.apply_scale", "Apply Scale", "object.transform_apply", "CHECKMARK",
           Rule(_object().scope, _unapplied_scale), {"location": False, "rotation": False, "scale": True},
           group="Transform"),
    Action("object.delete", "Delete", "object.delete", "TRASH", _object(), {"use_global": False, "confirm": False},
           group="Delete", destructive=True),
    # Object Mode, the palette's additions.
    Action("object.join", "Join", "object.join", "", _object(),
           enabled=lambda s: s.obj in s.selected and s.obj is not None and
           len(s.selected_of_type(s.obj.type)) >= 2 and len(s.selected) == len(s.selected_of_type(s.obj.type)),
           group="Object", strip=False),
    Action("object.parent", "Parent", "object.parent_set", "CON_CHILDOF", _object(2), {"type": 'OBJECT'},
           group="Object", strip=False),
    Action("object.origin", "Origin to Geometry", "object.origin_set", "OBJECT_ORIGIN",
           _object(types=('MESH', 'CURVE', 'SURFACE', 'FONT', 'META')), {"type": 'ORIGIN_GEOMETRY'},
           group="Transform", strip=False),
    Action("object.convert", "Convert", "", "", _object(), menu="VIEW3D_MT_object_convert", group="Object",
           strip=False),
    Action("object.add_modifier", "Add Modifier", "", "MODIFIER", _object(types=('MESH', 'CURVE', 'FONT',
           'SURFACE', 'LATTICE', 'GREASEPENCIL', 'POINTCLOUD', 'CURVES')),
           menu="OBJECT_MT_modifier_add", group="Modifiers", strip=False),
    Action("object.shade_flat", "Shade Flat", "object.shade_flat", "", _object(types=('MESH',)),
           group="Normals & Shading", strip=False),
    Action("object.copy", "Copy", "view3d.copybuffer", "COPYDOWN", _object(), group="Object", strip=False),
    Action("object.keyframe", "Insert Keyframe", "anim.keyframe_insert", "DECORATE_KEYFRAME",
           lambda s: s.obj is not None and ((s.mode == 'OBJECT' and s.selected) or s.mode == 'POSE'),
           enabled=lambda s: s.mode == 'OBJECT' or bool(s.context.selected_pose_bones),
           group="Object", strip=lambda s: s.mode == 'POSE'),
    # Object Mode, the selection tools.
    Action("object.select_all_more", "Select All", "object.select_all", "SELECT_EXTEND",
           _object(tools=_SELECT_TOOLS), {"action": 'SELECT'}, first=_selecting, group="Selection"),
    Action("object.select_none", "Select None", "object.select_all", "SELECT_SUBTRACT",
           _object(tools=_SELECT_TOOLS), {"action": 'DESELECT'}, first=_selecting, group="Selection"),
    Action("object.select_invert", "Invert", "object.select_all", "SELECT_DIFFERENCE",
           _object(tools=_SELECT_TOOLS), {"action": 'INVERT'}, first=_selecting, group="Selection"),
    Action("object.select_linked", "Select Linked", "object.select_linked", "",
           _object(tools=_SELECT_TOOLS), {"type": 'OBDATA'}, first=_selecting, group="Selection"),

    # 3D cursor tool.
    Action("cursor.to_selected", "Cursor to Selected", "view3d.snap_cursor_to_selected", "PIVOT_CURSOR",
           lambda s: s.tool == "builtin.cursor", enabled=lambda s: bool(s.selected or s.verts), group="Cursor"),
    Action("cursor.selected_to", "Selection to Cursor", "view3d.snap_selected_to_cursor", "CURSOR",
           lambda s: s.tool == "builtin.cursor", {"use_offset": True},
           enabled=lambda s: bool(s.selected or s.verts), group="Cursor"),
    Action("cursor.to_origin", "Cursor to World Origin", "view3d.snap_cursor_to_center", "OBJECT_ORIGIN",
           lambda s: s.tool == "builtin.cursor", group="Cursor"),

    # Edit Mesh, nothing selected.
    Action("mesh.select_all", "Select All", "mesh.select_all", "SELECT_EXTEND", _mesh_empty,
           {"action": 'SELECT'}, group="Selection"),
    Action("mesh.add", "Add", "", "ADD", _mesh_empty, menu="VIEW3D_MT_mesh_add", group="Add"),

    # Edit Mesh, a selection. Extrude leads in every select mode.
    Action("mesh.extrude_faces", "Extrude", "view3d.edit_mesh_extrude_move_normal", "", _mesh("FACE"),
           group="Face"),
    Action("mesh.extrude_edges", "Extrude", "view3d.edit_mesh_extrude_move_normal", "",
           _mesh("EDGE", exclude=("FACE",)), group="Edge"),
    Action("mesh.extrude_verts", "Extrude", "view3d.edit_mesh_extrude_move_normal", "",
           _mesh("VERT", exclude=("EDGE", "FACE")), group="Vertex"),
    # Vertices.
    Action("mesh.connect", "Connect", "mesh.vert_connect_path", "", _mesh("VERT", verts=2), group="Vertex"),
    Action("mesh.merge_center", "Merge", "mesh.merge", "AUTOMERGE_OFF", _mesh("VERT", verts=2),
           {"type": 'CENTER'}, group="Vertex"),
    Action("mesh.bevel_vertices", "Bevel Vertices", "mesh.bevel", "MOD_BEVEL", _mesh("VERT", verts=1),
           lambda s: {"offset": s.size * 0.05, "segments": 2, "affect": 'VERTICES'}, group="Vertex"),
    Action("mesh.fill", "Make Edge/Face", "mesh.edge_face_add", "", _mesh("VERT", "EDGE", verts=2),
           group="Mesh", strip=lambda s: s.select_mode[0]),
    Action("mesh.dissolve_verts", "Dissolve", "mesh.dissolve_verts", "", _mesh("VERT", exclude=("EDGE", "FACE")),
           group="Cleanup"),
    Action("mesh.slide_verts", "Slide", "", "", _mesh("VERT"), tool="builtin.vertex_slide", group="Vertex",
           strip=False),
    Action("mesh.rip", "Rip", "", "", _mesh("VERT"), tool="builtin.rip_region", group="Vertex", strip=False),
    Action("mesh.merge_distance", "Merge by Distance", "mesh.remove_doubles", "", _mesh("VERT", verts=2),
           group="Cleanup", strip=False),
    # Faces, before the edge actions they share a strip with.
    Action("mesh.inset", "Inset", "mesh.inset", "", _mesh("FACE", faces=1),
           lambda s: {"thickness": s.size * 0.05}, group="Face"),
    Action("mesh.bevel_faces", "Bevel", "mesh.bevel", "MOD_BEVEL", _mesh("FACE", exclude=("VERT", "EDGE")),
           lambda s: {"offset": s.size * 0.05, "segments": 2, "affect": 'EDGES'}, group="Face"),
    # Edges.
    Action("mesh.bevel_edges", "Bevel", "mesh.bevel", "MOD_BEVEL", _mesh("EDGE", edges=1),
           lambda s: {"offset": s.size * 0.05, "segments": 2, "affect": 'EDGES'}, group="Edge"),
    Action("mesh.loop_cut", "Loop Cut", "", "", _mesh("EDGE", exclude=("FACE",)), tool="builtin.loop_cut",
           group="Edge"),
    Action("mesh.bridge", "Bridge Loops", "mesh.bridge_edge_loops", "", _mesh("EDGE", edges=2), group="Edge"),
    Action("mesh.subdivide", "Subdivide", "mesh.subdivide", "", _mesh("EDGE", "FACE", edges=1), group="Mesh"),
    Action("mesh.separate", "Separate", "mesh.separate", "", _mesh("FACE", faces=1), {"type": 'SELECTED'},
           group="Mesh"),
    Action("mesh.dissolve_edges", "Dissolve", "mesh.dissolve_edges", "",
           _mesh("EDGE", edges=1, exclude=("VERT", "FACE")), group="Cleanup"),
    Action("mesh.dissolve_faces", "Dissolve", "mesh.dissolve_faces", "", _mesh("FACE", faces=1, exclude=("VERT",)),
           group="Cleanup"),
    Action("mesh.mark_seam", "Mark Seam", "mesh.mark_seam", "", _mesh("EDGE", edges=1), {"clear": False},
           group="UV", strip=False),
    Action("mesh.mark_sharp", "Mark Sharp", "mesh.mark_sharp", "", _mesh("EDGE", edges=1), {"clear": False},
           group="Normals & Shading", strip=False),
    Action("mesh.loop_select", "Select Loops", "mesh.select_edge_loop_multi", "", _mesh("EDGE", edges=1),
           group="Selection", strip=False),
    Action("mesh.ring_select", "Select Rings", "mesh.select_edge_ring_multi", "", _mesh("EDGE", edges=1),
           group="Selection", strip=False),
    Action("mesh.knife", "Knife", "", "", _mesh("EDGE", "FACE"), tool="builtin.knife", group="Mesh", strip=False),
    # Faces, the palette's additions.
    Action("mesh.poke", "Poke", "mesh.poke", "", _mesh("FACE", faces=1), group="Face", strip=False),
    Action("mesh.triangulate", "Triangulate", "mesh.quads_convert_to_tris", "", _mesh("FACE", faces=1),
           group="Face", strip=False),
    Action("mesh.tris_to_quads", "Tris to Quads", "mesh.tris_convert_to_quads", "", _mesh("FACE", faces=1),
           group="Face", strip=False),
    Action("mesh.flip_normals", "Flip Normals", "mesh.flip_normals", "", _mesh("FACE", faces=1),
           group="Normals & Shading", strip=False),
    Action("mesh.recalc_normals", "Recalculate Normals", "mesh.normals_make_consistent", "",
           _mesh("FACE", faces=1), {"inside": False}, group="Normals & Shading", strip=False),
    Action("mesh.shade_smooth", "Shade Smooth", "mesh.faces_shade_smooth", "", _mesh("FACE", faces=1),
           group="Normals & Shading", strip=False),
    Action("mesh.shade_flat", "Shade Flat", "mesh.faces_shade_flat", "", _mesh("FACE", faces=1),
           group="Normals & Shading", strip=False),
    # Any selection.
    Action("mesh.duplicate", "Duplicate", "mesh.duplicate", "DUPLICATE", _mesh(verts=1), group="Mesh",
           strip=False),
    Action("mesh.hide", "Hide", "mesh.hide", "HIDE_ON", _mesh(verts=1), {"unselected": False}, group="Mesh",
           strip=False),
    Action("mesh.delete_verts", "Delete", "mesh.delete", "TRASH", _mesh("VERT", verts=1), {"type": 'VERT'},
           group="Delete", destructive=True),
    Action("mesh.delete_edges", "Delete", "mesh.delete", "TRASH", _mesh("EDGE", edges=1, exclude=("VERT",)),
           {"type": 'EDGE'}, group="Delete", destructive=True),
    Action("mesh.delete_faces", "Delete", "mesh.delete", "TRASH", _mesh("FACE", faces=1, exclude=("VERT", "EDGE")),
           {"type": 'FACE'}, group="Delete", destructive=True),
    # Growing and shrinking the selection: the selection tools lead with these.
    Action("mesh.select_all_more", "Select All", "mesh.select_all", "SELECT_EXTEND", _mesh(), {"action": 'SELECT'},
           first=_selecting, group="Selection", strip=_selecting),
    Action("mesh.select_none", "Select None", "mesh.select_all", "SELECT_SUBTRACT", _mesh(),
           {"action": 'DESELECT'}, first=_selecting, group="Selection", strip=_selecting),
    Action("mesh.select_invert", "Invert", "mesh.select_all", "SELECT_DIFFERENCE", _mesh(),
           {"action": 'INVERT'}, first=_selecting, group="Selection", strip=_selecting),
    Action("mesh.select_more", "More", "mesh.select_more", "SELECT_EXTEND", _mesh(), first=_selecting,
           group="Selection", strip=_selecting),
    Action("mesh.select_less", "Less", "mesh.select_less", "SELECT_SUBTRACT", _mesh(), first=_selecting,
           group="Selection", strip=_selecting),
    Action("mesh.select_linked", "Select Linked", "mesh.select_linked", "", _mesh(), first=_selecting,
           group="Selection", strip=_selecting),

    # Selection tools in Object and Edit Mode.
    Action("view.xray", "X-Ray", "view3d.toggle_xray", "XRAY",
           lambda s: s.selecting and s.mode in {'OBJECT', 'EDIT_MESH'}, checked=lambda s: s.xray(), group="View"),

    # Sculpt Mode: face sets, for the face set tools and brush.
    Action("sculpt.face_set_mask", "From Mask", "sculpt.face_sets_create", "", lambda s: s.face_sets,
           {"mode": 'MASKED'}, first=lambda s: s.face_sets, group="Face Sets"),
    Action("sculpt.face_set_visible", "From Visible", "sculpt.face_sets_create", "", lambda s: s.face_sets,
           {"mode": 'VISIBLE'}, first=lambda s: s.face_sets, group="Face Sets"),
    Action("sculpt.face_set_grow", "Grow", "sculpt.face_set_edit", "", lambda s: s.face_sets,
           {"mode": 'GROW'}, first=lambda s: s.face_sets, invoke=True, group="Face Sets"),
    Action("sculpt.face_set_shrink", "Shrink", "sculpt.face_set_edit", "", lambda s: s.face_sets,
           {"mode": 'SHRINK'}, first=lambda s: s.face_sets, invoke=True, group="Face Sets"),
    Action("sculpt.face_set_init", "Initialize by Parts", "sculpt.face_sets_init", "", lambda s: s.face_sets,
           {"mode": 'LOOSE_PARTS'}, first=lambda s: s.face_sets, group="Face Sets"),
    Action("sculpt.face_set_colors", "Randomize Colors", "sculpt.face_sets_randomize_colors", "",
           lambda s: s.face_sets, first=lambda s: s.face_sets, group="Face Sets"),

    # Sculpt Mode: the mask, first for the mask tools and brush.
    Action("sculpt.mask_invert", "Invert Mask", "paint.mask_flood_fill", "", lambda s: s.mode == 'SCULPT',
           {"mode": 'INVERT'}, first=lambda s: s.masking, group="Mask"),
    Action("sculpt.mask_clear", "Clear Mask", "paint.mask_flood_fill", "", lambda s: s.mode == 'SCULPT',
           {"mode": 'VALUE', "value": 0.0}, first=lambda s: s.masking, group="Mask"),
    Action("sculpt.mask_fill", "Fill Mask", "paint.mask_flood_fill", "", lambda s: s.masking,
           {"mode": 'VALUE', "value": 1.0}, first=lambda s: s.masking, group="Mask"),
    Action("sculpt.mask_grow", "Grow Mask", "sculpt.mask_filter", "", lambda s: s.masking,
           {"filter_type": 'GROW'}, first=lambda s: s.masking, group="Mask"),
    Action("sculpt.mask_shrink", "Shrink Mask", "sculpt.mask_filter", "", lambda s: s.masking,
           {"filter_type": 'SHRINK'}, first=lambda s: s.masking, group="Mask"),
    Action("sculpt.mask_smooth", "Smooth Mask", "sculpt.mask_filter", "MOD_SMOOTH", lambda s: s.masking,
           {"filter_type": 'SMOOTH'}, first=lambda s: s.masking, group="Mask"),
    Action("sculpt.mask_sharpen", "Sharpen Mask", "sculpt.mask_filter", "", lambda s: s.masking,
           {"filter_type": 'SHARPEN'}, first=lambda s: s.masking, group="Mask"),

    # Sculpt Mode: whole-mesh operations that otherwise need a menu.
    Action("sculpt.reveal", "Reveal", "paint.hide_show_all", "HIDE_OFF", lambda s: s.mode == 'SCULPT',
           {"action": 'SHOW'}, group="Sculpt"),
    Action("sculpt.remesh", "Remesh", "object.voxel_remesh", "MOD_REMESH", lambda s: s.mode == 'SCULPT',
           group="Sculpt"),
    Action("sculpt.symmetrize", "Symmetrize", "sculpt.symmetrize", "MOD_MIRROR", lambda s: s.mode == 'SCULPT',
           group="Sculpt"),

    # Pose Mode.
    Action("pose.clear", "Clear Transforms", "pose.transforms_clear", "LOOP_BACK", lambda s: s.mode == 'POSE',
           group="Pose"),
    Action("pose.copy", "Copy Pose", "pose.copy", "COPYDOWN", lambda s: s.mode == 'POSE', group="Pose"),
    Action("pose.paste", "Paste Pose", "pose.paste", "PASTEDOWN", lambda s: s.mode == 'POSE', {"flipped": False},
           group="Pose"),
    Action("pose.paste_flipped", "Paste Flipped", "pose.paste", "PASTEFLIPDOWN", lambda s: s.mode == 'POSE',
           {"flipped": True}, group="Pose"),

    # Weight and Vertex Paint.
    Action("weight.normalize", "Normalize All", "object.vertex_group_normalize_all", "",
           lambda s: s.mode == 'PAINT_WEIGHT', {"lock_active": False}, group="Paint"),
    Action("weight.smooth", "Smooth", "object.vertex_group_smooth", "MOD_SMOOTH",
           lambda s: s.mode == 'PAINT_WEIGHT', group="Paint"),
    Action("weight.clean", "Clean", "object.vertex_group_clean", "", lambda s: s.mode == 'PAINT_WEIGHT',
           group="Cleanup"),
    Action("vertex.fill", "Fill", "paint.vertex_color_set", "", lambda s: s.mode == 'PAINT_VERTEX', group="Paint"),
    Action("vertex.smooth", "Smooth", "paint.vertex_color_smooth", "MOD_SMOOTH", lambda s: s.mode == 'PAINT_VERTEX',
           group="Paint"),
    Action("vertex.invert", "Invert", "paint.vertex_color_invert", "", lambda s: s.mode == 'PAINT_VERTEX',
           group="Paint"),

    # Grease Pencil drawing.
    Action("grease.blank_frame", "Insert Blank Frame", "grease_pencil.insert_blank_frame", "ADD",
           lambda s: s.mode == 'PAINT_GREASE_PENCIL', group="Grease Pencil"),
    Action("grease.layer", "New Layer", "grease_pencil.layer_add", "OUTLINER_DATA_GP_LAYER",
           lambda s: s.mode == 'PAINT_GREASE_PENCIL', group="Grease Pencil"),

    # Curves, armatures and Grease Pencil strokes in Edit Mode.
    Action("curve.subdivide", "Subdivide", "curve.subdivide", "", lambda s: s.mode == 'EDIT_CURVE', group="Curve"),
    Action("curve.switch_direction", "Switch Direction", "curve.switch_direction", "ARROW_LEFTRIGHT",
           lambda s: s.mode == 'EDIT_CURVE', group="Curve"),
    Action("armature.subdivide", "Subdivide", "armature.subdivide", "", lambda s: s.mode == 'EDIT_ARMATURE',
           group="Armature"),
    Action("armature.duplicate", "Duplicate", "armature.duplicate", "DUPLICATE",
           lambda s: s.mode == 'EDIT_ARMATURE', group="Armature"),
    Action("grease.duplicate", "Duplicate", "grease_pencil.duplicate", "DUPLICATE",
           lambda s: s.mode == 'EDIT_GREASE_PENCIL', group="Grease Pencil"),
    Action("grease.delete", "Delete", "grease_pencil.delete", "TRASH", lambda s: s.mode == 'EDIT_GREASE_PENCIL',
           group="Delete", destructive=True),
]

_BY_ID = {action.id: action for action in ACTIONS}
_INDEX = {action.id: index for index, action in enumerate(ACTIONS)}

# The long-press menu's fixed top section, by mode: the actions it takes, in order. `rename` is the
# shell's own Rename, which asks for the name and sends it to `rename_active`.
_FIXED = {
    'OBJECT': ("object.copy", "object.paste", "object.duplicate", "rename", "object.delete"),
    'EDIT_MESH': ("mesh.duplicate", "mesh.delete_verts", "mesh.delete_edges", "mesh.delete_faces"),
    'POSE': ("pose.copy", "pose.paste", "rename"),
    'EDIT_ARMATURE': ("armature.duplicate", "rename"),
    'EDIT_GREASE_PENCIL': ("grease.duplicate", "grease.delete"),
}


def _poll(action):
    # The shell opens a menu natively by its route, so `wm.call_menu`'s need for a window does not
    # apply; the menu existing is enough.
    if action.menu:
        return hasattr(bpy.types, action.menu)
    try:
        return bool(action.operator().poll())
    except (AttributeError, KeyError, RuntimeError, ReferenceError):
        return False


def _in_scope(state):
    for action in ACTIONS:
        try:
            if action.scope(state):
                yield action
        except (AttributeError, KeyError, RuntimeError, ReferenceError):
            continue


def _can_run(action, state):
    try:
        return action.enabled(state) and _poll(action)
    except (AttributeError, KeyError, RuntimeError, ReferenceError):
        return False


def _order(state):
    """The strip's order: what the active tool or brush works on first, destructive actions last,
    otherwise the registry's order."""
    def key(action):
        leads = bool(action.first and action.first(state))
        return (0 if leads else 1, 1 if action.destructive else 0, _INDEX[action.id])
    return key


def _item(action, state, enabled=True):
    return {
        "title": action.label, "action": action.id, "operator": action.operator().idname(),
        "icon": action.icon, "symbol": "",
        "selected": bool(action.checked(state)) if action.checked else False,
        "enabled": enabled, "group": action.group, "destructive": action.destructive,
        "tool": action.tool, "menu": action.menu,
    }


def _strip(state):
    available = [action for action in _in_scope(state) if action.in_strip(state) and _can_run(action, state)]
    available.sort(key=_order(state))
    return available


def _commands(state):
    """The strip's actions for the long-press menu and the radial: the mode's own commands in the
    registry's order, without the selection tools' lead or the selection actions it brings."""
    available = [action for action in _strip(state) if action.group != "Selection"]
    available.sort(key=lambda action: (1 if action.destructive else 0, _INDEX[action.id]))
    return available


def actions(context, tool):
    """The collapsed strip: the in-scope actions that can run now and may show in the strip."""
    state = _State(context, tool)
    return [_item(action, state) for action in _strip(state)]


def palette(context, tool):
    """The expanded palette: every in-scope action, grouped in the fixed group order, dimmed when
    it cannot run. Only non-empty groups are listed."""
    state = _State(context, tool)
    groups = {}
    for action in _in_scope(state):
        groups.setdefault(action.group, []).append(_item(action, state, _can_run(action, state)))
    return [{"group": group, "items": groups[group]} for group in GROUPS if group in groups]


def long_press(context, tool):
    """The long-press menu: a fixed top section for the mode, then the mode's top commands that are
    not already in it (never selection actions), then "More..." for Blender's own context menu."""
    state = _State(context, tool)
    fixed = []
    taken = set()
    for action_id in _FIXED.get(state.mode, ()):
        if action_id == "rename":
            fixed.append({"title": "Rename", "action": "rename", "operator": "", "icon": "", "symbol": "",
                          "selected": False, "enabled": state.obj is not None, "group": "Object",
                          "destructive": False, "tool": "", "menu": ""})
            continue
        action = _BY_ID[action_id]
        taken.add(action.op)
        try:
            if action.scope(state):
                fixed.append(_item(action, state, _can_run(action, state)))
        except (AttributeError, KeyError, RuntimeError, ReferenceError):
            continue
    middle = [action for action in _commands(state) if action.op not in taken][:LONG_PRESS_ACTIONS]
    return {
        "fixed": fixed,
        "actions": [_item(action, state) for action in middle],
        "more": MODE_MENUS.get(state.mode) or "",
    }


def radial(context, tool):
    """The Pencil squeeze radial's default slots: the top in-scope actions that can run now, never a
    destructive one. The shell lets the owner pin slots over these."""
    state = _State(context, tool)
    chosen = [action for action in _commands(state) if not action.destructive][:RADIAL_SLOTS]
    return [_item(action, state) for action in chosen]


def rename_active(context, name):
    """Rename what Rename Active would: the active bone in an armature's modes, else the active
    object. ``name`` arrives as a JSON string."""
    name = json.loads(name)
    if not name:
        return
    if context.mode == 'POSE' and context.active_pose_bone:
        context.active_pose_bone.name = name
    elif context.mode == 'EDIT_ARMATURE' and context.active_bone:
        context.active_bone.name = name
    elif context.active_object:
        context.active_object.name = name


def run(context, action_id, tool=""):
    """Run an action if it still applies; the button may predate a context change."""
    action = _BY_ID.get(action_id)
    if action is None:
        return False
    state = _State(context, tool)
    if not action.applies(state):
        return False
    operator = action.operator()
    if not operator.poll():
        return False
    context_type = 'INVOKE_REGION_WIN' if action.invoke else 'EXEC_REGION_WIN'
    return 'FINISHED' in operator(context_type, True, **action.properties(state))


class OBJECT_OT_native_modifier_toggle(bpy.types.Operator):
    """Add the modifier to the selected meshes, or remove it when every one already has it"""

    bl_idname = "object.native_modifier_toggle"
    bl_label = "Toggle Modifier"
    bl_options = {'REGISTER', 'UNDO', 'INTERNAL'}

    type: EnumProperty(
        name="Type",
        items=(
            ('SUBSURF', "Subdivision", "Subdivision Surface"),
            ('MIRROR', "Mirror", "Mirror"),
        ),
    )

    @classmethod
    def poll(cls, context):
        return context.mode == 'OBJECT' and any(ob.type == 'MESH' for ob in context.selected_editable_objects)

    def execute(self, context):
        meshes = [ob for ob in context.selected_editable_objects if ob.type == 'MESH']
        if not meshes:
            return {'CANCELLED'}
        if all(_has_modifier(ob, self.type) for ob in meshes):
            for ob in meshes:
                for mod in [mod for mod in ob.modifiers if mod.type == self.type]:
                    ob.modifiers.remove(mod)
        else:
            name = "Subdivision" if self.type == 'SUBSURF' else "Mirror"
            for ob in meshes:
                if not _has_modifier(ob, self.type):
                    ob.modifiers.new(name=name, type=self.type)
        return {'FINISHED'}


classes = (
    OBJECT_OT_native_modifier_toggle,
)
