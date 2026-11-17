# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""What the native iPad interface shows after a command: one rule table for every flow.

A desktop user sees a command's result where Blender leaves it: the Adjust Last Operation panel,
the Properties tab that holds the new modifier, the editor with the new node tree. On a tablet those
are folded away, so a command that ends with nothing visible reads as one that did nothing. After
each command the bridge asks `after_operator`, and the interface opens what it names.

First match wins. `show` is one of:

- ``operation``: the last operation's settings;
- ``properties:<TAB>``: Properties on that tab (``focus`` names what to bring into view);
- ``properties_if_open:<TAB>``: that tab, only while Properties already shows; with the settings;
- ``editor:<name>``: ``geometry_nodes``, ``shader``, ``image`` or ``timeline``;
- ``render``: the render sheet, which opens by itself;
- ``message``: a short message, ``text``, with an optional ``button`` (``Label\\ttarget``);
- ``none``: nothing, and ``why`` says why.

`tests/python/bl_native_reveal.py` enumerates every operator and fails when one that adds, makes,
assigns, bakes, unwraps, applies, imports, links, duplicates, hides, converts, joins, separates,
binds or generates something falls through to the default without a rule here.
"""

__all__ = (
    "RULES",
    "after_operator",
    "classify",
)

import re


class Rule:
    __slots__ = ("pattern", "when", "show", "focus", "text", "button", "why")

    def __init__(self, match, show, *, when=None, focus="", text="", button="", why=""):
        self.pattern = re.compile(match)
        # A part the operator's Python call must contain, such as "type='NODES'".
        self.when = when
        self.show = show
        self.focus = focus
        self.text = text
        self.button = button
        self.why = why
        assert show != "none" or why, match

    def matches(self, idname, call):
        if not self.pattern.fullmatch(idname):
            return False
        return self.when is None or self.when in call


_PHYSICS = ("CLOTH", "SOFT_BODY", "COLLISION", "FLUID", "DYNAMIC_PAINT")

RULES = (
    # Not something the person sees as a result: kept out of everything below.
    Rule(r"(view3d|view2d)\.(rotate|zoom|move|dolly|view_roll|view_orbit|view_pan|ndof_.*|view_axis|"
         r"view_selected|view_all|view_center_.*|view_camera|zoom_border|localview.*|view_persportho|"
         r"navigate|walk|fly|smoothview|clear_render_border|render_border)",
         "none", why="the view itself shows the result"),
    Rule(r"(view3d|mesh|object|curve|curves|armature|pose|paint|sculpt|gpencil|grease_pencil|uv|graph|"
         r"action|nla|node|sequencer|clip|outliner|file|image|lattice|mball|particle|font|marker|"
         r"pointcloud)\.(select.*|.*_select|.*_select_.*|loop_multi_select|edgering_select|"
         r"shortest_path_.*|deselect.*|.*_pick)",
         "none", why="the selection shows in the viewport"),
    Rule(r"(paint|sculpt|grease_pencil|gpencil|curves|sculpt_curves)\.(.*stroke.*|brush_stroke|"
         r"image_paint|vertex_paint|weight_paint|texture_paint|.*_paint|mask_.*|sample_.*|"
         r"weight_sample.*|.*_draw)",
         "none", why="a stroke shows as it is drawn"),
    Rule(r"object\.(mode_set|.*mode_toggle|transfer_mode)|mesh\.select_mode|"
         r"(sculpt|paint)\..*_toggle",
         "none", why="the mode shows in the header"),
    # What comes in from a file: a message, and a way to find it in the view.
    Rule(r"wm\.(append|link)|.*import.*", "message", text="{label}",
         button="Frame Selected\taction:view.frame_selected"),
    Rule(r"ed\.(undo|redo|undo_history)", "message", text="{label}"),
    Rule(r"ed\..*|gizmogroup\..*|view2d\..*|uilist\..*|text_editor\..*|export_.*\..*|workspace\..*|"
         r"geometry\.geometry_randomization",
         "none", why="housekeeping, a file picker, or a change that shows where it is made"),
    Rule(r"brush\..*|paintcurve\..*|palette\..*|sculpt_curves\..*",
         "none", why="the brush, its curve and its colours show in the tool settings and sidebar"),
    Rule(r"poselib\..*", "none", why="the pose shows on the armature"),
    Rule(r"boid\..*", "properties:PARTICLES"),
    Rule(r"screen\.(repeat_last|repeat_history|redo_last|.*)", "none", why="the interface's own"),
    # The Add tools take two drags, which nothing on screen says: once, the first time.
    Rule(r"wm\.tool_set_by_id", "message", when="builtin.primitive_", focus="once",
         text="Drag for the base, then drag for the height"),
    Rule(r"wm\.tool_set_by_(id|index|brush_type)", "none", why="the tool shows in the toolbar"),
    Rule(r"wm\.(context_.*|call_menu.*|call_panel|search_menu|search_operator|operator_.*|"
         r"doc_.*|url_open.*|.*_preset.*|properties_.*|save_.*|open_mainfile|read_.*|revert_mainfile|"
         r"recover_.*|quit_blender|window_.*|redraw_timer|memory_statistics|debug_.*|sysinfo|"
         r"previews_.*|lib_.*|id_linked_relocate|drop_.*|batch_rename|set_stereo_3d|"
         r"tool_set_by_.*|toolbar.*|keyconfig_.*|keyitem_.*|keymap_.*|interface_theme_preset_.*|"
         r"radial_control|stereo3d_set|owner_.*|usd_.*|alembic_.*|collada_.*|ply_.*|stl_.*|obj_.*|"
         r"grease_pencil_export_.*|.*_export|gpencil_export_.*|splash.*|xr_.*|clear_recent_files|"
         r"append|link|grease_pencil_import_svg|.*_import|import_.*|path_open|blend_strings_utf8_validate|"
         r"previews_batch_.*|textedit_.*|asset_.*|console_toggle|open|"
         r"read_factory.*|extension_.*|ndof_sensitivity_change|.*)",
         "none", why="window manager housekeeping, or its own dialog and file picker"),
    Rule(r"(ui|info|console|text|file|buttons|outliner|preferences|userpref|extensions|asset|script|"
         r"sound|cachefile|image_editor|cycles|eevee|bl_pkg|anim\.channels_.*)\..*",
         "none", why="answered in its own editor or dialog"),

    # Modifiers and physics.
    Rule(r"object\.modifier_add", "editor:geometry_nodes", when="type='NODES'", focus="newest"),
    *(Rule(r"object\.modifier_add", "properties:PHYSICS", when="type='{:s}'".format(kind)) for kind in _PHYSICS),
    Rule(r"object\.modifier_add|object\.native_modifier_toggle|object\.modifier_copy|object\.subdivision_set|"
         r"object\.multires_.*|object\.quick_fur|object\.quick_explode|object\.correctivesmooth_bind|"
         r"object\.surfacedeform_bind|object\.meshdeform_bind|object\.laplaciandeform_bind|"
         r"object\.skin_.*|object\.ocean_bake|object\.explode_refresh|object\.modifier_.*|"
         r"object\.geometry_nodes_input_attribute_toggle|object\.geometry_node_.*",
         "properties:MODIFIER", focus="newest"),
    Rule(r"object\.quick_smoke|object\.quick_liquid|object\.forcefield_toggle|rigidbody\..*|"
         r"ptcache\..*|fluid\..*|cloth\..*|dpaint\..*|object\.collision_.*", "properties:PHYSICS"),
    Rule(r"node\.new_geometry_nodes_modifier|node\.new_geometry_node_group_.*|"
         r"object\.geometry_nodes_.*", "editor:geometry_nodes"),
    Rule(r"object\.shaderfx_.*", "properties:SHADERFX", focus="newest"),
    Rule(r"object\.constraint_add.*|object\.constraints_.*|object\.track_set|constraint\..*|"
         r"object\.constraint_.*", "properties:CONSTRAINT", focus="newest"),
    Rule(r"pose\.constraint_add.*|pose\.ik_add|pose\.constraints_.*|pose\.ik_clear", "properties:BONE_CONSTRAINT",
         focus="newest"),

    # Data the object holds, in Properties.
    Rule(r"object\.material_slot_.*|material\..*|object\.material_.*|.*\.material_slot_.*", "properties:MATERIAL",
         focus="newest"),
    Rule(r"object\.vertex_group_.*|object\.shape_key_.*|mesh\.uv_texture_.*|geometry\..*attribute.*|"
         r"mesh\.(customdata_.*|sculpt_vertex_color_.*|vertex_color_.*)|object\.face_map_.*|"
         r"geometry\.color_attribute_.*|mesh\.attribute_set|object\.data_transfer|object\.datalayout_transfer|"
         r"armature\.collection_.*|armature\.bone_.*collection.*|curves\.surface_set|"
         r"object\.vertex_weight_.*|object\.vertex_parent_set|object\.hook_.*|object\.lineart_.*|"
         r"grease_pencil\.layer_.*|grease_pencil\.(vertex_group_.*|material_.*)",
         "properties:DATA", focus="newest"),
    Rule(r"object\.particle_system_.*|particle\..*|object\.particle_.*", "properties:PARTICLES", focus="newest"),
    Rule(r"world\..*", "properties:WORLD"),
    Rule(r"texture\..*|brush\..*texture.*", "properties:TEXTURE"),
    Rule(r"scene\.(view_layer_.*|freestyle_.*|render_view_.*|.*)", "properties:SCENE"),
    Rule(r"camera\..*|object\.camera_.*", "properties_if_open:DATA"),
    Rule(r"object\.(light|camera|text|speaker|lightprobe|empty|image|effector|armature|metaball|"
         r"pointcloud|curves|grease_pencil|volume|collection_instance|data_instance)_add|"
         r"object\.(add|add_named|empty_image_add|light_linking_.*|lightprobe_cache_.*)",
         "properties_if_open:DATA"),
    Rule(r"mesh\.primitive_.*|curve\.primitive_.*|surface\.primitive_.*|mball\.primitive_.*|"
         r"object\.text_add|object\.quick_.*", "operation"),

    # UVs and images.
    Rule(r"uv\.(unwrap|smart_project|cube_project|cylinder_project|sphere_project|project_from_view|"
         r"lightmap_pack|reset|follow_active_quads|pack_islands|average_islands_scale|minimize_stretch|"
         r"align.*|stitch|weld|seams_from_islands|mark_seam|copy|paste|randomize_uv_transform|.*)",
         "operation"),
    Rule(r"object\.bake.*|image\..*|paint\.add_texture_paint_slot|paint\.add_simple_uvs|"
         r"paint\.(texture_paint_.*|project_image|image_from_view)", "editor:image"),

    # Animation.
    Rule(r"anim\.keyframe_insert.*|anim\.keyframe_delete.*|anim\.keyframe_clear.*|anim\.keying_set_.*|"
         r"anim\.(insert_keyframe_.*|keyframe_.*|driver_.*|.*)|action\..*|graph\..*|nla\..*|"
         r"screen\.(frame_.*|keyframe_jump|marker_jump|animation_.*)|marker\..*|pose\.(paste|copy|"
         r"breakdown|push|relax|blend_.*|.*keyframe.*)",
         "message", text="{label}", button="Timeline\teditor:timeline"),
    Rule(r"render\.(render|opengl|view_show|play_rendered_anim|.*)", "render"),
    Rule(r"sequencer\..*|clip\..*|mask\..*|node\..*|nodes\..*|spreadsheet\..*|geometry_nodes\..*",
         "none", why="answered in its own editor"),

    # Hiding and showing.
    Rule(r"object\.hide_view_set|object\.hide_collection|object\.hide_render_.*|"
         r"(mesh|curve|curves|armature|pose|grease_pencil|paint|sculpt|lattice|mball|uv|particle|"
         r"gpencil|point_cloud|pointcloud)\.(hide.*|.*_hide.*)|outliner\.hide",
         "message", text="{label}", button="Reveal Hidden\taction:object.reveal"),
    Rule(r".*\.(reveal.*|.*_reveal.*|hide_view_clear|unhide.*)", "none", why="what was hidden shows again"),

    # Relations and collections: the settings where there are any, else a message.
    Rule(r"object\.(join|join_uvs|parent_set|parent_clear|parent_no_inverse_set|parent_inverse_apply|"
         r"move_to_collection|link_to_collection|make_links_.*|make_local|make_single_user|"
         r"make_override_library|convert|duplicates_make_real|instance_offset_.*|origin_set|"
         r"transform_apply|visual_transform_apply|transforms_to_deltas|location_clear|rotation_clear|"
         r"scale_clear|origin_clear|randomize_transform|align|shade_.*|.*)|collection\..*",
         "operation"),
    # Edit Mode, Sculpt, the rest: the last operation's settings.
    Rule(r"(mesh|curve|curves|surface|armature|pose|lattice|mball|font|grease_pencil|gpencil|sculpt|"
         r"paint|transform|object|view3d|pointcloud|point_cloud|bmesh|uv)\..*",
         "operation"),
)


def _python_idname(idname):
    """`OBJECT_OT_modifier_add` as `object.modifier_add`; a Python form is returned as is."""
    if "_OT_" in idname:
        module, name = idname.split("_OT_", 1)
        return module.lower() + "." + name
    return idname


def classify(idname, call=""):
    """The first rule for an operator, by its Python idname and Python call, or None."""
    idname = _python_idname(idname)
    for rule in RULES:
        if rule.matches(idname, call):
            return rule
    return None


def after_operator(_context, idname, call, label=""):
    """What to show after the operator `idname` finished, as called by `call`: a dict of `show`,
    `focus`, `text`, `button` and `why`, for the bridge's `reveal`."""
    rule = classify(idname, call)
    if rule is None:
        return {"show": "operation", "focus": "", "text": "", "button": "", "why": "", "rule": ""}
    return {
        "show": rule.show,
        "focus": rule.focus,
        "text": rule.text.format(label=label or _python_idname(idname)),
        "button": rule.button,
        "why": rule.why,
        "rule": rule.pattern.pattern[:60],
    }


classes = ()
