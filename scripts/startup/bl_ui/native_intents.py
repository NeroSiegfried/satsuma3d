# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Siri and Shortcuts for the native iPad interface.

The app's intents are generic, as Blender is: one runs any command (an operator), two read and
write any setting (an RNA property), one describes the scene. Each request comes in as JSON from
the app and is answered with JSON, see `perform`. What people say arrives in plain words, such as
"levels 2", "3 m" or "red", and is read against the operator's or property's own RNA definition:
its names, units, ranges and enum items. Answers are sentences to be spoken.

Commands are limited to what is safe to run by voice on the open document: nothing that quits,
runs scripts, changes the preferences, or reads or writes other files.
"""

import json
import re

import bpy

__all__ = (
    "perform",
)

classes = ()

# -----------------------------------------------------------------------------
# Context


def _view3d_override(context):
    """The window, area and region of the document's 3D Viewport, as operators expect them."""
    wm = context.window_manager
    windows = [context.window] if context.window else []
    windows += [win for win in wm.windows if win != context.window]
    for win in windows:
        screen = win.screen
        for area in screen.areas:
            if area.type != 'VIEW_3D':
                continue
            region = next((region for region in area.regions if region.type == 'WINDOW'), None)
            if region is not None:
                # The screen follows from the window: the iPad shows the viewport full screen,
                # in a temporary screen, which can't be overridden.
                return {"window": win, "area": area, "region": region}
    return {"window": windows[0]} if windows else {}


def _mode_name(context):
    return {
        'OBJECT': "Object Mode",
        'EDIT_MESH': "Edit Mode",
        'EDIT_CURVE': "Edit Mode",
        'EDIT_CURVES': "Edit Mode",
        'EDIT_SURFACE': "Edit Mode",
        'EDIT_TEXT': "Edit Mode",
        'EDIT_ARMATURE': "Edit Mode",
        'EDIT_METABALL': "Edit Mode",
        'EDIT_LATTICE': "Edit Mode",
        'EDIT_GREASE_PENCIL': "Edit Mode",
        'POSE': "Pose Mode",
        'SCULPT': "Sculpt Mode",
        'PAINT_WEIGHT': "Weight Paint",
        'PAINT_VERTEX': "Vertex Paint",
        'PAINT_TEXTURE': "Texture Paint",
        'PAINT_GREASE_PENCIL': "Draw Mode",
        'SCULPT_GREASE_PENCIL': "Sculpt Mode",
        'WEIGHT_GREASE_PENCIL': "Weight Paint",
        'VERTEX_GREASE_PENCIL': "Vertex Paint",
    }.get(context.mode, context.mode.replace("_", " ").title())


def _join(names):
    """Names as a spoken list: "Cube", "Cube and Sphere", "Cube, Sphere and Cone"."""
    names = list(names)
    if not names:
        return ""
    if len(names) == 1:
        return names[0]
    return ", ".join(names[:-1]) + " and " + names[-1]


def _plural(count, noun):
    if count == 1:
        return "1 " + noun
    if noun.endswith("h") or noun.endswith("s"):
        return "{:d} {:s}es".format(count, noun)
    return "{:d} {:s}s".format(count, noun)


# -----------------------------------------------------------------------------
# Values in Plain Words

_NUMBER_WORDS = {
    "zero": 0, "none": 0, "once": 1, "one": 1, "a": 1, "an": 1, "single": 1, "twice": 2, "two": 2,
    "double": 2, "thrice": 3, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
    "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30,
    "fifty": 50, "hundred": 100, "half": 0.5, "quarter": 0.25,
}

_TRUE_WORDS = {"on", "yes", "true", "enable", "enabled", "show", "shown", "checked", "1", "use"}
_FALSE_WORDS = {"off", "no", "false", "disable", "disabled", "unchecked", "0", "none"}

# Common colors by name, in sRGB from 0 to 255. "Light" and "dark" vary any of them.
_COLORS = {
    "red": (230, 25, 25), "green": (40, 180, 60), "blue": (30, 80, 230), "yellow": (250, 220, 30),
    "orange": (250, 130, 20), "purple": (130, 50, 180), "violet": (140, 80, 220),
    "pink": (250, 120, 180), "magenta": (230, 30, 200), "cyan": (20, 210, 230),
    "teal": (0, 128, 128), "turquoise": (60, 210, 200), "white": (255, 255, 255),
    "black": (0, 0, 0), "gray": (128, 128, 128), "grey": (128, 128, 128),
    "brown": (120, 70, 30), "gold": (230, 180, 40), "silver": (192, 192, 192),
    "navy": (20, 30, 110), "lime": (150, 230, 40), "maroon": (120, 20, 30),
    "olive": (128, 128, 0), "beige": (235, 220, 180), "indigo": (75, 0, 130),
    "crimson": (220, 20, 60), "coral": (250, 128, 80), "salmon": (250, 140, 115),
    "lavender": (180, 160, 230), "mint": (150, 230, 180), "sky blue": (120, 190, 240),
    "cream": (255, 250, 220), "tan": (210, 180, 140), "skin": (230, 185, 160),
}


def _words(text):
    return re.findall(r"[a-z]+|[-+]?\d*\.?\d+", text.lower())


def _number(text):
    """A number in words or digits, or None."""
    text = text.strip().lower()
    try:
        return float(text)
    except ValueError:
        pass
    for word in _words(text):
        if word in _NUMBER_WORDS:
            return float(_NUMBER_WORDS[word])
        try:
            return float(word)
        except ValueError:
            continue
    return None


def _clean_number_text(text):
    """Number words as digits, so units still apply ("two meters" is "2 meters")."""
    def replace(match):
        word = match.group(0)
        return str(_NUMBER_WORDS[word]) if word in _NUMBER_WORDS else word
    return re.sub(r"[a-z]+", replace, text.lower())


def _unit_settings(context):
    scene = context.scene
    units = scene.unit_settings if scene else None
    system = units.system if units else 'METRIC'
    scale = units.scale_length if units and units.scale_length > 0.0 else 1.0
    return system, scale


def _float_from_text(context, prop, text):
    """A float from words, read in the property's unit: "3 m", "45 degrees", "two"."""
    text = _clean_number_text(text).strip()
    unit = getattr(prop, "unit", 'NONE')
    if unit != 'NONE' and unit in bpy.utils.units.categories:
        system, scale = _unit_settings(context)
        text = text.replace("degrees", "°").replace("degree", "°")
        try:
            value = bpy.utils.units.to_value(system, unit, text)
        except ValueError:
            value = None
        if value is not None:
            return value / scale if unit == 'LENGTH' else value
    if text.endswith("%"):
        number = _number(text[:-1])
        return None if number is None else number / 100.0
    return _number(text)


def _linear(channel):
    return channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4


def _srgb(channel):
    channel = max(channel, 0.0)
    return channel * 12.92 if channel <= 0.0031308 else 1.055 * channel ** (1.0 / 2.4) - 0.055


def _color_from_text(text):
    """An sRGB color from 0 to 1: a name ("red", "dark blue"), hex ("#ff8800") or numbers."""
    text = text.strip().lower()
    match = re.search(r"#?\b([0-9a-f]{6})\b", text)
    if match:
        value = match.group(1)
        return tuple(int(value[i:i + 2], 16) / 255.0 for i in (0, 2, 4))
    for name in sorted(_COLORS, key=len, reverse=True):
        if re.search(r"\b" + name + r"\b", text):
            color = [channel / 255.0 for channel in _COLORS[name]]
            if re.search(r"\b(dark|deep)\b", text):
                color = [channel * 0.45 for channel in color]
            elif re.search(r"\b(light|pale|pastel)\b", text):
                color = [channel + (1.0 - channel) * 0.55 for channel in color]
            return tuple(color)
    numbers = [float(word) for word in re.findall(r"\d*\.?\d+", text)]
    if len(numbers) >= 3:
        if any(number > 1.0 for number in numbers[:3]):
            return tuple(number / 255.0 for number in numbers[:3])
        return tuple(numbers[:3])
    return None


def _color_text(srgb):
    """A color as it is said: by its name when it is one, otherwise in hex and the nearest name."""
    def distance(name):
        return sum((a - b / 255.0) ** 2 for a, b in zip(srgb, _COLORS[name]))
    name = min((name for name in _COLORS if name != "grey"), key=distance)
    if distance(name) < 1e-4:
        return name
    hex_value = "".join("{:02X}".format(round(min(max(c, 0.0), 1.0) * 255)) for c in srgb[:3])
    return "#{:s}, close to {:s}".format(hex_value, name)


def _is_color(prop):
    return prop.type == 'FLOAT' and prop.subtype in {'COLOR', 'COLOR_GAMMA'} and prop.array_length in {3, 4}


def _enum_items(prop, owner=None):
    """The enum's items as (identifier, name) pairs, also for items only known at run time, such
    as the render engines, which RNA lists when it refuses a value that is not one of them."""
    items = [(item.identifier, item.name) for item in prop.enum_items]
    if owner is None or prop.is_enum_flag or not hasattr(owner, prop.identifier):
        return items
    try:
        setattr(owner, prop.identifier, "")
    except TypeError as ex:
        message = str(ex)
        if "not found in" in message:
            identifiers = re.findall(r"'([^']+)'", message.split("not found in", 1)[1])
            known = dict(items)
            items = []
            for identifier in identifiers:
                name = known.get(identifier)
                if name is None:
                    try:
                        name = bpy.types.UILayout.enum_item_name(owner, prop.identifier, identifier)
                    except (TypeError, ValueError):
                        name = ""
                items.append((identifier, name or identifier.replace("_", " ").title()))
    return items


def _enum_match(items, text):
    """The item named in `text`, by its name or identifier, with or without spaces."""
    def simple(value):
        return re.sub(r"[^a-z0-9]", "", value.lower())
    wanted = simple(text)
    if not wanted:
        return None
    for identifier, name in items:
        if wanted in {simple(identifier), simple(name)}:
            return identifier
    # The longest item name the words contain, so "a subdivision surface modifier" finds it.
    found = [(len(name), identifier) for identifier, name in items
             if len(simple(name)) > 2 and simple(name) in wanted]
    if found:
        return max(found)[1]
    for identifier, name in items:
        if simple(name).startswith(wanted) or simple(identifier).startswith(wanted):
            return identifier
    return None


def value_from_text(context, prop, text, current=None, owner=None):
    """A value for `prop` from plain words, or raise ValueError with a sentence saying why."""
    text = str(text).strip()
    lowered = text.lower()
    if prop.type == 'BOOLEAN':
        if getattr(prop, "is_array", False) and prop.array_length > 0:
            words = [word for word in _words(lowered) if word in _TRUE_WORDS | _FALSE_WORDS]
            if len(words) == 1:
                return [words[0] in _TRUE_WORDS] * prop.array_length
            if len(words) == prop.array_length:
                return [word in _TRUE_WORDS for word in words]
            raise ValueError("Say on or off.")
        words = set(_words(lowered))
        if words & {"toggle", "switch", "flip"} and current is not None:
            return not current
        if words & _FALSE_WORDS:
            return False
        if words & _TRUE_WORDS:
            return True
        raise ValueError("Say on or off.")

    if prop.type == 'ENUM':
        items = _enum_items(prop, owner)
        if prop.is_enum_flag:
            chosen = set()
            for part in re.split(r",|\band\b", lowered):
                identifier = _enum_match(items, part)
                if identifier:
                    chosen.add(identifier)
            if not chosen:
                raise ValueError("Choose from " + _join([name for _, name in items[:8]]) + ".")
            return chosen
        identifier = _enum_match(items, lowered)
        if identifier is None:
            raise ValueError("Choose from " + _join([name for _, name in items[:8]]) + ".")
        return identifier

    if prop.type == 'STRING':
        return text

    if prop.type in {'INT', 'FLOAT'}:
        length = prop.array_length if getattr(prop, "is_array", False) else 0
        if length and _is_color(prop):
            color = _color_from_text(lowered)
            if color is None:
                raise ValueError("Say a color, such as red, light blue or #FF8800.")
            if prop.subtype == 'COLOR':
                color = tuple(_linear(channel) for channel in color)
            value = list(current) if current is not None else [1.0] * length
            value[:3] = color
            return value

        def scalar(part):
            value = _float_from_text(context, prop, part) if prop.type == 'FLOAT' else _number(part)
            if value is None:
                raise ValueError("Say a number" + (", such as 2 m." if prop.unit == 'LENGTH' else "."))
            if prop.type == 'INT':
                value = int(round(value))
            return value

        if not length:
            relative = re.match(r"^\s*(by|plus|minus|increase by|decrease by|add|subtract)\b(.*)$", lowered)
            if relative and current is not None:
                amount = scalar(relative.group(2))
                if relative.group(1) in {"minus", "decrease by", "subtract"}:
                    amount = -amount
                return current + amount
            return scalar(lowered)

        # Arrays: "x 2", "x 1 y 2", "1, 2, 3", or one value for all of them.
        value = list(current) if current is not None else [0] * length
        axes = "xyzw" if prop.subtype not in {'COLOR', 'COLOR_GAMMA'} else "rgba"
        labeled = re.findall(r"\b([" + axes + r"])\b\s*(?:to|=|:)?\s*([-+]?[^,a-z]*[a-z°%]*)", lowered)
        labeled = [(axis, part) for axis, part in labeled if part.strip()]
        if labeled:
            for axis, part in labeled:
                index = axes.index(axis)
                if index < length:
                    value[index] = scalar(part)
            return value
        parts = [part for part in re.split(r"[,;]|\s+(?=[-+]?\d)", lowered) if part.strip()]
        if len(parts) == length:
            return [scalar(part) for part in parts]
        single = scalar(lowered)
        return [single] * length

    raise ValueError("That setting can't be changed by voice.")


def _float_text(value):
    text = "{:.3f}".format(value).rstrip("0").rstrip(".")
    return "0" if text in {"-0", ""} else text


def value_to_text(context, prop, value, owner=None):
    """A value as it is said: with its unit, a color by name, an enum item by its name."""
    if prop.type == 'BOOLEAN':
        if getattr(prop, "is_array", False) and prop.array_length > 0:
            return ", ".join("on" if item else "off" for item in value)
        return "on" if value else "off"
    if prop.type == 'ENUM':
        names = dict(_enum_items(prop, owner))
        if prop.is_enum_flag:
            return _join(sorted(names.get(item, item) for item in value)) or "none"
        return names.get(value, value)
    if prop.type == 'STRING':
        return '"{:s}"'.format(value)
    if prop.type in {'INT', 'FLOAT'}:
        if _is_color(prop):
            srgb = list(value)[:3]
            if prop.subtype == 'COLOR':
                srgb = [_srgb(channel) for channel in srgb]
            return _color_text(srgb)

        def scalar(item):
            if prop.type == 'INT':
                return str(int(item))
            unit = getattr(prop, "unit", 'NONE')
            if unit != 'NONE' and unit in bpy.utils.units.categories:
                system, scale = _unit_settings(context)
                return bpy.utils.units.to_string(system, unit, item * (scale if unit == 'LENGTH' else 1.0))
            if prop.subtype == 'FACTOR' and 0.0 <= item <= 1.0 and prop.soft_max <= 1.0:
                return _float_text(item)
            if prop.subtype == 'PERCENTAGE':
                return _float_text(item) + "%"
            return _float_text(item)

        if getattr(prop, "is_array", False) and prop.array_length > 0:
            return ", ".join(scalar(item) for item in value)
        return scalar(value)
    return str(value)


# -----------------------------------------------------------------------------
# Commands

# Operator categories that work on the document's content in the 3D Viewport.
_COMMAND_MODULES = {
    "anim", "armature", "collection", "constraint", "curve", "curves", "ed", "font", "geometry",
    "grease_pencil", "lattice", "marker", "material", "mball", "mesh", "object", "paint",
    "particle", "pointcloud", "pose", "rigidbody", "scene", "screen", "sculpt", "sculpt_curves",
    "transform", "uv", "view3d", "world",
}

# Only these from their category: the rest change the interface or Blender itself.
_COMMAND_ONLY = {
    "ed": {"undo", "redo"},
    "screen": {"animation_play", "animation_cancel", "frame_jump", "keyframe_jump", "frame_offset"},
}

# Words that mark commands that read or write other files, run code or leave the document, or
# that only work by hand, such as a gizmo's.
_UNSAFE_WORDS = {
    "addon", "append", "bake", "browse", "clipboard", "console", "exit", "export", "extension",
    "external", "file", "files", "filepath", "gizmo", "image", "import", "keyconfig", "keymap",
    "library",
    "link", "load", "make_local", "movie", "open", "pack", "path", "preferences", "python", "quit",
    "recover", "reload", "render", "revert", "save", "screenshot", "script", "sound", "text",
    "theme", "unpack", "url", "userpref", "relocate",
}

# Properties that name files: an operator that takes them reads or writes outside the document.
_FILE_PROPERTIES = {"filepath", "directory", "filename", "files", "relative_path", "filter_glob"}

# Words that mark commands that throw away work, which ask before they run.
_DESTRUCTIVE_WORDS = {
    "delete", "remove", "clear", "dissolve", "purge", "unlink", "collapse", "merge", "decimate",
    "reset",
}

# Other ways people say a command, beyond its name.
_SYNONYMS = {
    "object.delete": ("Remove", "Erase", "Get Rid Of"),
    "mesh.delete": ("Remove", "Erase"),
    "object.duplicate_move": ("Copy", "Clone", "Duplicate"),
    "object.duplicate_move_linked": ("Instance", "Linked Copy"),
    "object.shade_smooth": ("Smooth Shading", "Make Smooth"),
    "object.shade_flat": ("Flat Shading", "Make Flat", "Faceted"),
    "object.shade_auto_smooth": ("Auto Smooth",),
    "object.subdivision_set": ("Subdivide", "Smooth Subdivision", "Add Subdivision"),
    "mesh.subdivide": ("Divide", "Add Detail", "Cut Into Pieces"),
    "object.join": ("Combine", "Merge Objects"),
    "object.origin_set": ("Center Origin", "Move Origin"),
    "object.modifier_add": ("Add Effect",),
    "object.convert": ("Convert To Mesh", "Make Real"),
    "object.transform_apply": ("Apply Scale", "Apply Rotation", "Freeze Transforms"),
    "object.location_clear": ("Reset Position", "Move To Center"),
    "object.rotation_clear": ("Reset Rotation", "Straighten"),
    "object.scale_clear": ("Reset Size", "Reset Scale"),
    "object.select_all": ("Select Everything", "Deselect All", "Select None", "Invert Selection"),
    "object.hide_view_set": ("Hide",),
    "object.hide_view_clear": ("Show Hidden", "Unhide", "Reveal"),
    "object.parent_set": ("Parent", "Attach To"),
    "object.parent_clear": ("Unparent", "Detach"),
    "object.camera_add": ("New Camera",),
    "object.light_add": ("New Light", "Add Lamp"),
    "mesh.primitive_cube_add": ("New Cube", "Box"),
    "mesh.primitive_uv_sphere_add": ("New Sphere", "Ball"),
    "mesh.primitive_cylinder_add": ("New Cylinder", "Tube"),
    "mesh.primitive_plane_add": ("New Plane", "Floor"),
    "mesh.primitive_monkey_add": ("Monkey", "Suzanne"),
    "mesh.extrude_region_move": ("Extrude", "Pull Out"),
    "mesh.inset": ("Inset",),
    "mesh.bevel": ("Round Edges", "Chamfer"),
    "mesh.flip_normals": ("Flip Normals", "Turn Inside Out"),
    "mesh.normals_make_consistent": ("Recalculate Normals", "Fix Normals"),
    "mesh.remove_doubles": ("Merge By Distance", "Remove Doubles"),
    "mesh.fill": ("Fill Hole",),
    "transform.translate": ("Move", "Shift"),
    "transform.rotate": ("Turn", "Spin", "Rotate"),
    "transform.resize": ("Scale", "Resize", "Make Bigger", "Make Smaller"),
    "transform.mirror": ("Mirror", "Flip"),
    "view3d.view_selected": ("Focus", "Zoom To Selection", "Frame Selected", "Look At"),
    "view3d.view_all": ("Show Everything", "Zoom Out", "Frame All"),
    "view3d.view_camera": ("Camera View", "Look Through Camera"),
    "view3d.view_persportho": ("Orthographic", "Perspective"),
    "view3d.localview": ("Isolate", "Local View", "Focus Mode"),
    "ed.undo": ("Go Back", "Take That Back", "Undo That"),
    "ed.redo": ("Do Again", "Redo That"),
    "screen.animation_play": ("Play", "Play Animation", "Pause", "Stop Playing"),
    "screen.frame_jump": ("Go To Start", "Go To End", "Rewind"),
    "anim.keyframe_insert": ("Add Keyframe", "Key", "Set Key"),
    "anim.keyframe_delete_v3d": ("Remove Keyframe",),
    "material.new": ("New Material",),
    "sculpt.sculptmode_toggle": ("Sculpt", "Start Sculpting"),
    "object.editmode_toggle": ("Edit Mode", "Edit Mesh", "Leave Edit Mode"),
    "object.mode_set": ("Change Mode", "Switch Mode"),
    "paint.texture_paint_toggle": ("Paint", "Texture Paint"),
}

# Commands offered first, and as phrases such as "Shade Smooth in Blender".
_SUGGESTED = (
    "object.shade_smooth",
    "object.shade_flat",
    "object.subdivision_set",
    "object.duplicate_move",
    "object.delete",
    "object.join",
    "object.origin_set",
    "object.modifier_add",
    "mesh.primitive_cube_add",
    "mesh.primitive_uv_sphere_add",
    "mesh.primitive_monkey_add",
    "view3d.view_selected",
    "view3d.view_all",
    "screen.animation_play",
    "ed.undo",
    "ed.redo",
)

# How the result of a command is said, where its name is not a verb.
_SPOKEN = {
    "object.subdivision_set": "Subdivided",
    "object.shade_smooth": "Smoothed the shading of",
    "object.shade_flat": "Flattened the shading of",
    "object.duplicate_move": "Duplicated",
    "object.modifier_add": "Added the modifier to",
    "object.origin_set": "Set the origin of",
    "object.select_all": "Changed the selection",
    "object.mode_set": "Changed the mode of",
    "object.transform_apply": "Applied the transform of",
    "object.editmode_toggle": "Toggled Edit Mode on",
    "ed.undo": "Undone",
    "ed.redo": "Redone",
    "screen.animation_play": "Toggled playback",
    "view3d.view_selected": "Framed",
    "view3d.view_all": "Framed everything",
}

_IRREGULAR_PAST = {
    "add": "Added", "apply": "Applied", "cut": "Cut", "clear": "Cleared", "copy": "Copied",
    "flip": "Flipped", "make": "Made", "set": "Set", "shade": "Shaded", "snap": "Snapped",
    "split": "Split", "spin": "Spun", "join": "Joined", "select": "Selected", "hide": "Hid",
    "show": "Showed", "toggle": "Toggled", "fill": "Filled", "insert": "Inserted",
    "extrude": "Extruded", "bevel": "Beveled", "mirror": "Mirrored", "scale": "Scaled",
    "rotate": "Rotated", "move": "Moved", "duplicate": "Duplicated", "delete": "Deleted",
    "remove": "Removed", "smooth": "Smoothed", "subdivide": "Subdivided", "unwrap": "Unwrapped",
    "recalculate": "Recalculated", "convert": "Converted", "parent": "Parented",
    "separate": "Separated", "dissolve": "Dissolved", "merge": "Merged", "inset": "Inset",
    "triangulate": "Triangulated", "randomize": "Randomized", "reveal": "Revealed",
}


def _operator(idname):
    module, _, name = idname.partition(".")
    if not module or not name:
        return None
    try:
        operator = getattr(getattr(bpy.ops, module), name)
        operator.get_rna_type()
    except (AttributeError, KeyError):
        return None
    return operator


def _command_allowed(idname, operator):
    module, _, name = idname.partition(".")
    if module not in _COMMAND_MODULES:
        return False
    if module in _COMMAND_ONLY and name not in _COMMAND_ONLY[module]:
        return False
    if set(name.split("_")) & _UNSAFE_WORDS:
        return False
    try:
        if 'INTERNAL' in operator.bl_options:
            return False
        rna = operator.get_rna_type()
    except (AttributeError, KeyError, RuntimeError):
        return False
    if not rna.name:
        return False
    for prop in rna.properties:
        if prop.identifier in _FILE_PROPERTIES or prop.subtype in {'FILE_PATH', 'DIR_PATH', 'FILE_NAME'}:
            return False
    return True


def _destructive(idname):
    return bool(set(idname.partition(".")[2].split("_")) & _DESTRUCTIVE_WORDS)


def _command_entity(idname, operator):
    rna = operator.get_rna_type()
    description = (rna.description or "").strip()
    module = idname.partition(".")[0]
    category = {"ed": "Edit", "view3d": "View", "screen": "Playback"}.get(
        module, module.replace("_", " ").title())
    return {
        "id": idname,
        "title": rna.name,
        "subtitle": description.split("\n")[0] if description else category,
        "category": category,
        "synonyms": list(_SYNONYMS.get(idname, ())),
        "destructive": _destructive(idname),
    }


def _all_commands():
    for module in sorted(_COMMAND_MODULES):
        try:
            names = dir(getattr(bpy.ops, module))
        except AttributeError:
            continue
        for name in names:
            idname = module + "." + name
            operator = _operator(idname)
            if operator is not None and _command_allowed(idname, operator):
                yield idname, operator


def _poll(operator):
    try:
        return operator.poll()
    except Exception:
        # A script's poll may fail in a context it never expected: it can't run here.
        return False


def _command_score(entity, query_words, query):
    """How well a command matches the words said: lower is better, None for no match."""
    title = entity["title"].lower()
    synonyms = [synonym.lower() for synonym in entity["synonyms"]]
    if query in {title} | set(synonyms):
        return 0
    if title.startswith(query) or any(synonym.startswith(query) for synonym in synonyms):
        return 1
    names = " ".join([title] + synonyms + [entity["id"].replace("_", " ").replace(".", " ")])
    if all(word in names for word in query_words):
        return 2
    if all(word in (names + " " + entity["subtitle"].lower()) for word in query_words):
        return 3
    return None


def _commands(context, request):
    """Commands that can run now, matching the words said; or the suggested ones."""
    query = (request.get("query") or "").strip().lower()
    available = bool(request.get("document", True))
    ids = request.get("ids")
    limit = int(request.get("limit") or 60)
    results = []
    if ids is not None:
        for idname in ids:
            operator = _operator(idname)
            if operator is not None and _command_allowed(idname, operator):
                results.append(_command_entity(idname, operator))
        return {"commands": results}
    if not query:
        for idname in _SUGGESTED:
            operator = _operator(idname)
            if operator is not None and _command_allowed(idname, operator):
                results.append(_command_entity(idname, operator))
        return {"commands": results}
    query_words = _words(query)
    scored = []
    for idname, operator in _all_commands():
        entity = _command_entity(idname, operator)
        score = _command_score(entity, query_words, query)
        if score is None:
            continue
        if available and not _poll(operator):
            continue
        suggested = 0 if idname in _SUGGESTED else 1
        scored.append((score, suggested, len(entity["title"]), idname, entity))
    scored.sort(key=lambda item: item[:4])
    return {"commands": [item[4] for item in scored[:limit]]}


def _options_properties(rna):
    return [
        prop for prop in rna.properties
        if prop.identifier != "rna_type" and not prop.is_hidden and prop.type != 'POINTER' and
        prop.type != 'COLLECTION'
    ]


def _default(prop):
    if getattr(prop, "is_array", False) and prop.array_length > 0:
        return list(prop.default_array)
    return getattr(prop, "default", None)


def _property_names(prop):
    """How a property may be named in speech, longest first: "number of cuts", "cuts"."""
    names = {prop.name.lower(), prop.identifier.replace("_", " ")}
    words = prop.name.lower().split()
    if len(words) > 1:
        names.add(words[-1])
    if words and words[-1].endswith("s") and len(words[-1]) > 3:
        names.add(words[-1][:-1])
    return sorted((name for name in names if len(name) > 1 and re.fullmatch(r"[a-z][a-z ]*", name)),
                  key=len, reverse=True)


def parse_options(context, rna, text):
    """Operator properties from plain words: "levels 2", "4 cuts", "size 3 m", "smooth".

    Each property may be named before or after its value. Words left over choose enum items by
    name ("subdivision surface") or set the first number the operator takes ("twice").
    """
    text = (text or "").strip().lower()
    result = {}
    if not text:
        return result
    props = _options_properties(rna)
    names = sorted(((name, prop) for prop in props for name in _property_names(prop)),
                   key=lambda item: len(item[0]), reverse=True)
    spans = []
    for name, prop in names:
        if any(span[2] == prop for span in spans):
            continue
        for match in re.finditer(r"\b" + re.escape(name) + r"\b", text):
            if not any(start < match.end() and match.start() < end for start, end, _ in spans):
                spans.append((match.start(), match.end(), prop))
                break
    spans.sort(key=lambda span: span[0])
    used = [False] * len(text)
    for index, (start, end, prop) in enumerate(spans):
        following = spans[index + 1][0] if index + 1 < len(spans) else len(text)
        value_text = re.sub(r"^\s*(to|of|=|:|at|is|by)\b", "", text[end:following]).strip(" ,;")
        value_text = re.sub(r"\b(and|with)\s*$", "", value_text).strip(" ,;")
        value_span = (end, following)
        before = text[:start].rstrip()
        if prop.type == 'BOOLEAN' and not (set(_words(value_text)) & (_TRUE_WORDS | _FALSE_WORDS)):
            # Named alone, it is on: "with smooth"; "without smooth" or "no smooth" is off.
            negated = re.search(r"\b(no|not|without|don't)\s*$", before)
            value_text = "off" if negated else "on"
            value_span = (negated.start(1) if negated else start, start)
        elif not value_text or (prop.type in {'INT', 'FLOAT'} and _number(value_text) is None and
                                not _is_color(prop)):
            # The value comes first: "4 cuts".
            match = re.search(r"([-+]?\d*\.?\d+\s*[a-z°%]*|\b[a-z]+)\s*$", before)
            if match and _number(match.group(1)) is not None:
                value_text = match.group(1)
                value_span = (match.start(1), start)
        try:
            result[prop.identifier] = value_from_text(context, prop, value_text, _default(prop))
        except ValueError:
            continue
        for i in range(start, end):
            used[i] = True
        for i in range(*value_span):
            used[i] = True
    leftover = "".join(" " if used[i] else char for i, char in enumerate(text))
    leftover = re.sub(r"\b(and|with|by|to|the|a|an|of|it|this|that|please|times?)\b", " ", leftover)
    leftover = " ".join(leftover.split())
    if leftover:
        for prop in props:
            if prop.type == 'ENUM' and prop.identifier not in result and not prop.is_enum_flag:
                identifier = _enum_match(_enum_items(prop), leftover)
                if identifier:
                    result[prop.identifier] = identifier
                    leftover = ""
                    break
    if leftover and _number(leftover) is not None:
        # The operator's first number takes it: Move's vector ("z 2 m"), Subdivide's cuts.
        for prop in props:
            if prop.type in {'INT', 'FLOAT'} and prop.identifier not in result:
                try:
                    result[prop.identifier] = value_from_text(context, prop, leftover, _default(prop))
                except ValueError:
                    continue
                break
    return result


def _targets(context):
    """What a command works on, as said: "Cube", "Cube and Sphere", "4 objects"."""
    if context.mode == 'OBJECT':
        names = [ob.name for ob in context.selected_objects]
        if not names and context.active_object:
            names = [context.active_object.name]
        return _join(names) if len(names) <= 3 else _plural(len(names), "object")
    if context.active_object:
        return context.active_object.name
    return ""


def _past_tense(idname, title, targets):
    """The sentence's start for a command that ran: "Deleted Cube", "Cleared Location of Cube"."""
    if idname in _SPOKEN:
        return _SPOKEN[idname] + (" " + targets if targets else "")
    words = title.split()
    first = words[0].lower() if words else ""
    if first not in _IRREGULAR_PAST:
        return None
    rest = [word for word in words[1:] if word.lower() not in {"objects", "object", "selected", "all"}]
    sentence = " ".join([_IRREGULAR_PAST[first]] + rest)
    if targets:
        sentence += (" of " if rest else " ") + targets
    return sentence


def _spoken_options(rna, options, context):
    parts = []
    for identifier, value in options.items():
        prop = rna.properties[identifier]
        parts.append("{:s} {:s}".format(prop.name, value_to_text(context, prop, value)))
    return _join(parts)


def _run(context, request):
    idname = request.get("command") or ""
    operator = _operator(idname)
    if operator is None or not _command_allowed(idname, operator):
        return {"sentence": "Blender doesn't have that command."}
    rna = operator.get_rna_type()
    title = rna.name
    if not _poll(operator):
        return {"sentence": "{:s} isn't available in {:s} right now.".format(title, _mode_name(context))}
    options = parse_options(context, rna, request.get("options") or "")
    module, _, name = idname.partition(".")
    targets = ""
    if module not in {"ed", "screen", "view3d"} and (
            idname in _SPOKEN or not (name.endswith("_add") or "primitive" in name)):
        targets = _targets(context)
    if _destructive(idname) and not request.get("confirmed"):
        return {"confirm": "{:s}{:s}?".format(title, " " + targets if targets else "")}
    try:
        result = operator('EXEC_REGION_WIN', True, **options)
    except TypeError as ex:
        return {"sentence": "{:s} couldn't use those options: {:s}".format(title, str(ex))}
    except RuntimeError as ex:
        message = str(ex).split(":", 1)[-1].strip() or "it couldn't run"
        return {"sentence": "{:s} didn't work: {:s}".format(title, message)}
    if 'FINISHED' not in result:
        return {"sentence": "{:s} didn't change anything.".format(title)}
    past = _past_tense(idname, title, targets)
    if past:
        sentence = past
    else:
        sentence = "Done: " + title + (" on " + targets if targets else "")
    spoken = _spoken_options(rna, options, context)
    if spoken:
        sentence += " with " + spoken
    return {"sentence": sentence + ".", "changed": True}


# -----------------------------------------------------------------------------
# Settings

_SKIP_PROPERTIES = {
    "rna_type", "session_uid", "is_evaluated", "original", "users", "use_fake_user",
    "use_extra_user", "is_embedded_data", "is_missing", "is_runtime_data", "is_editable",
    "tag", "is_library_indirect", "library", "library_weak_reference", "asset_data",
    "override_library", "preview", "name_full", "id_type", "use_extra_recalc_object",
    "use_extra_recalc_data", "is_linked_packed", "bl_rna",
}

# Settings offered first: what people change most.
_SUGGESTED_SETTINGS = (
    "Base Color", "Location", "Euler Rotation", "Scale", "Roughness", "Metallic", "Name", "Power",
    "Color", "Focal Length", "End Frame", "Current Frame", "Render Engine", "Samples", "Radius",
    "Strength",
)


def _setting_allowed(prop):
    if prop.identifier in _SKIP_PROPERTIES or prop.is_readonly or prop.is_hidden:
        return False
    if prop.type in {'POINTER', 'COLLECTION'}:
        return False
    if prop.subtype in {'FILE_PATH', 'DIR_PATH', 'FILE_NAME', 'BYTE_STRING', 'PASSWORD'}:
        return False
    if prop.type == 'STRING' and prop.identifier != "name":
        return False
    return True


def _id_path(id_data, collection):
    return '{:s}["{:s}"]'.format(collection, bpy.utils.escape_identifier(id_data.name))


def _local(id_data):
    return id_data is not None and id_data.library is None


def _principled(material):
    """The material's surface shader node, when it is a Principled BSDF."""
    if not material or not material.use_nodes or not material.node_tree:
        return None
    for node in material.node_tree.nodes:
        if node.type == 'BSDF_PRINCIPLED':
            return node
    return None


def _owners(context):
    """Where settings are found: (id prefix, owner, owner's spoken name, rank, subtitle)."""
    owners = []
    ob = context.active_object
    scene = context.scene
    if ob is not None and _local(ob):
        path = "data:" + _id_path(ob, "objects")
        material = ob.active_material
        if _local(material):
            node = _principled(material)
            if node is not None:
                for index, socket in enumerate(node.inputs):
                    if socket.is_linked or not hasattr(socket, "default_value") or not socket.enabled:
                        continue
                    owners.append((
                        "{:s}.node_tree.nodes[\"{:s}\"].inputs[{:d}]".format(
                            "data:" + _id_path(material, "materials"),
                            bpy.utils.escape_identifier(node.name), index),
                        socket, ob.name, 0, material.name + " material", socket.name))
            owners.append(("data:" + _id_path(material, "materials"), material, ob.name, 2,
                           material.name + " material", None))
        owners.append((path, ob, ob.name, 1, "Object", None))
        data = ob.data
        collection = {'LIGHT': "lights", 'CAMERA': "cameras"}.get(ob.type)
        if collection and _local(data):
            owners.append(("data:" + _id_path(data, collection), data, ob.name, 1,
                           ob.type.title(), None))
    if scene is not None:
        scene_path = "data:" + _id_path(scene, "scenes")
        owners.append((scene_path, scene, "Scene", 3, "Scene " + scene.name, None))
        owners.append((scene_path + ".render", scene.render, "Render", 3, "Render", None))
        engine = {'BLENDER_EEVEE': "eevee", 'BLENDER_EEVEE_NEXT': "eevee", 'CYCLES': "cycles"}.get(
            scene.render.engine)
        if engine and getattr(scene, engine, None) is not None:
            owners.append((scene_path + "." + engine, getattr(scene, engine), "Render", 3, "Render",
                           None))
        if _local(scene.world):
            owners.append(("data:" + _id_path(scene.world, "worlds"), scene.world, "World", 4,
                           "World", None))
        owners.append((scene_path + ".tool_settings", scene.tool_settings, "Tool Settings", 5,
                       "Tool Settings", None))
    brush = _brush(context)
    if brush is not None:
        owners.append(("brush:", brush, "Brush", 1, "Brush " + brush.name, None))
    return owners


def _brush(context):
    try:
        from bl_ui.properties_paint_common import UnifiedPaintPanel
        settings = UnifiedPaintPanel.paint_settings(context)
    except (ImportError, AttributeError):
        return None
    return settings.brush if settings is not None else None


def _brush_owner(context, identifier):
    """Where the brush's size, strength or color live: its own, or shared by all brushes."""
    from bl_ui.properties_paint_common import UnifiedPaintPanel
    settings = UnifiedPaintPanel.paint_settings(context)
    brush = settings.brush if settings else None
    if brush is None:
        return None
    ups = getattr(settings, "unified_paint_settings", None)
    shared = {"size": "size", "unprojected_size": "size", "strength": "strength", "color": "color",
              "secondary_color": "color", "weight": "weight"}.get(identifier)
    if shared and ups is not None and getattr(ups, "use_unified_" + shared, False) and \
       hasattr(ups, identifier):
        return ups
    return brush


def _base_color_property():
    return bpy.types.NodeSocketColor.bl_rna.properties["default_value"]


def _takes_material(ob):
    return ob is not None and _local(ob) and hasattr(ob.data, "materials") and _local(ob.data)


def _settings_list(context):
    """Every setting that can be read and set now, as (id, owner, prop, title, rank, subtitle)."""
    settings = []
    ob = context.active_object
    if _takes_material(ob) and ob.active_material is None:
        # Its color is the first thing people change: setting it gives the object a material.
        settings.append(("material:" + _id_path(ob, "objects"), None, _base_color_property(),
                         ob.name + " › Base Color", 0, "New material"))
    for prefix, owner, owner_name, rank, subtitle, socket_name in _owners(context):
        if socket_name is not None:
            prop = owner.bl_rna.properties["default_value"]
            if _setting_allowed(prop):
                settings.append((prefix + ".default_value", owner, prop,
                                 owner_name + " › " + socket_name, rank, subtitle))
            continue
        for prop in owner.bl_rna.properties:
            if not _setting_allowed(prop):
                continue
            separator = "" if prefix.endswith(":") else "."
            settings.append((prefix + separator + prop.identifier, owner, prop,
                             owner_name + " › " + prop.name, rank, subtitle))
    return settings


def _setting_synonyms(setting):
    """Other names for a setting: its own name alone, and "Color" for the material's color."""
    sid, owner, prop, title, rank, subtitle = setting
    name = title.split(" › ", 1)[-1]
    synonyms = [name]
    if prop.identifier != "default_value":
        spoken = prop.identifier.replace("_", " ").title()
        if spoken.lower() != name.lower():
            synonyms.append(spoken)
    elif _is_color(prop) and name == "Base Color":
        synonyms += ["Color", "Material Color"]
    return synonyms


def _setting_entity(setting):
    sid, owner, prop, title, rank, subtitle = setting
    synonyms = _setting_synonyms(setting)
    return {
        "id": sid,
        "title": title,
        "subtitle": subtitle + (" · " + prop.description if prop.description else ""),
        "synonyms": synonyms,
    }


def _new_material(ob):
    """A material for an object that has none, with its own shader, assigned to it."""
    material = bpy.data.materials.new(ob.name)
    material.use_nodes = True
    if ob.material_slots:
        ob.active_material = material
    else:
        ob.data.materials.append(material)
    return material


def resolve_setting(context, sid, create=False):
    """The owner and property behind a setting's id, or (None, None). A new material's color has
    no owner until `create` gives the object its material."""
    if sid.startswith("material:"):
        try:
            ob = bpy.data.path_resolve(sid[len("material:"):])
        except ValueError:
            return None, None
        if not isinstance(ob, bpy.types.Object) or not _takes_material(ob):
            return None, None
        material = ob.active_material
        if material is None and create:
            material = _new_material(ob)
        node = _principled(material) if _local(material) else None
        if node is None:
            return (None, _base_color_property()) if material is None else (None, None)
        return node.inputs["Base Color"], _base_color_property()
    if sid.startswith("brush:"):
        identifier = sid[len("brush:"):]
        owner = _brush_owner(context, identifier)
    elif sid.startswith("data:"):
        path, _, identifier = sid[len("data:"):].rpartition(".")
        if not path.split("[", 1)[0] in {"objects", "materials", "scenes", "lights", "cameras", "worlds"}:
            return None, None
        try:
            owner = bpy.data.path_resolve(path)
        except ValueError:
            return None, None
    else:
        return None, None
    if owner is None or not hasattr(owner, "bl_rna"):
        return None, None
    prop = owner.bl_rna.properties.get(identifier)
    if prop is None or not _setting_allowed(prop):
        return None, None
    id_data = getattr(owner, "id_data", None)
    if id_data is not None and id_data.library is not None:
        return None, None
    return owner, prop


def _spoken(title):
    """A setting's title in a sentence: "Cube's Base Color", or "the End Frame" for the scene's."""
    owner, _, name = title.rpartition(" › ")
    if not owner or owner in {"Scene", "Render", "World", "Tool Settings", "Brush"}:
        return "the " + name
    return owner + "’s " + name


def _setting_title(context, sid, owner, prop):
    for setting in _settings_list(context):
        if setting[0] == sid:
            return setting[3]
    if sid.startswith("material:"):
        # The color of a material the setting gave the object.
        return bpy.data.path_resolve(sid[len("material:"):]).name + " › Base Color"
    owner_name = getattr(getattr(owner, "id_data", None), "name", "") or ""
    return (owner_name + " › " if owner_name else "") + prop.name


def _settings(context, request):
    query = (request.get("query") or "").strip().lower()
    ids = request.get("ids")
    limit = int(request.get("limit") or 60)
    all_settings = _settings_list(context)
    if ids is not None:
        by_id = {setting[0]: setting for setting in all_settings}
        results = []
        for sid in ids:
            if sid in by_id:
                results.append(_setting_entity(by_id[sid]))
                continue
            owner, prop = resolve_setting(context, sid)
            if prop is not None:
                # A setting of an object or scene that is no longer active.
                title = _setting_title(context, sid, owner, prop)
                results.append(_setting_entity((sid, owner, prop, title, 0, title.rpartition(" › ")[0])))
        return {"settings": results}
    scored = []
    words = _words(query)
    for setting in all_settings:
        sid, owner, prop, title, rank, subtitle = setting
        name = title.split(" › ", 1)[-1].lower()
        if not query:
            if title.split(" › ", 1)[-1] not in _SUGGESTED_SETTINGS or (
                    prop.identifier == "name" and not sid.startswith("data:objects")):
                continue
            score = _SUGGESTED_SETTINGS.index(title.split(" › ", 1)[-1])
        else:
            synonyms = [synonym.lower() for synonym in _setting_synonyms(setting)]
            haystack = (title + " " + " ".join(synonyms)).lower()
            if query in {name, title.lower()} | set(synonyms):
                score = 0
            elif name.startswith(query):
                score = 1
            elif all(word in haystack for word in words):
                score = 2
            elif all(word in (haystack + " " + subtitle.lower() + " " + prop.description.lower())
                     for word in words):
                score = 3
            else:
                continue
        scored.append((score, rank, len(title), sid, setting))
    scored.sort(key=lambda item: item[:4])
    return {"settings": [_setting_entity(item[4]) for item in scored[:limit]]}


def _get(context, request):
    sid = request.get("setting") or ""
    owner, prop = resolve_setting(context, sid)
    if prop is None:
        return {"sentence": "That setting isn't in the open document."}
    if owner is None:
        title = _setting_title(context, sid, owner, prop)
        return {"sentence": "{:s} has no material yet, so it shows in the default gray.".format(
            title.rpartition(" › ")[0])}
    title = _setting_title(context, sid, owner, prop)
    value = getattr(owner, prop.identifier)
    if getattr(prop, "is_array", False) and prop.array_length > 0:
        value = list(value)
    text = value_to_text(context, prop, value, owner)
    sentence = "{:s} is {:s}.".format(_spoken(title), text)
    return {"sentence": sentence[0].upper() + sentence[1:], "value": text}


def _set(context, request):
    sid = request.get("setting") or ""
    owner, prop = resolve_setting(context, sid)
    if prop is None:
        return {"sentence": "That setting isn't in the open document."}
    title = _setting_title(context, sid, owner, prop)
    current = getattr(owner, prop.identifier) if owner is not None else _default(prop)
    if getattr(prop, "is_array", False) and prop.array_length > 0:
        current = list(current)
    try:
        value = value_from_text(context, prop, request.get("value") or "", current, owner)
    except ValueError as ex:
        return {"sentence": "Couldn't set {:s}. {:s}".format(_spoken(title), str(ex))}
    if owner is None:
        owner, prop = resolve_setting(context, sid, create=True)
        if owner is None:
            return {"sentence": "Couldn't give it a material to set {:s}.".format(_spoken(title))}
    try:
        setattr(owner, prop.identifier, value)
    except (TypeError, ValueError, AttributeError) as ex:
        return {"sentence": "Couldn't set {:s}: {:s}".format(_spoken(title), str(ex))}
    bpy.ops.ed.undo_push(message="Set " + title.replace(" › ", " "))
    value = getattr(owner, prop.identifier)
    if getattr(prop, "is_array", False) and prop.array_length > 0:
        value = list(value)
    text = value_to_text(context, prop, value, owner)
    return {"sentence": "Set {:s} to {:s}.".format(_spoken(title), text), "value": text, "changed": True}


# -----------------------------------------------------------------------------
# Scene


def _length(context, value):
    system, scale = _unit_settings(context)
    return bpy.utils.units.to_string(system, 'LENGTH', value * scale)


def _describe(context, _request):
    """The scene as facts to reason over: its objects by type, the selection, the active one."""
    scene = context.scene
    view_layer = context.view_layer
    objects = list(view_layer.objects) if view_layer else list(scene.objects)
    facts = []
    by_type = {}
    for ob in objects:
        by_type.setdefault(ob.type, []).append(ob.name)
    type_names = {
        'MESH': "mesh", 'CURVE': "curve", 'SURFACE': "surface", 'META': "metaball",
        'FONT': "text", 'CURVES': "hair curves", 'POINTCLOUD': "point cloud", 'VOLUME': "volume",
        'GREASEPENCIL': "Grease Pencil drawing", 'ARMATURE': "armature", 'LATTICE': "lattice",
        'EMPTY': "empty", 'LIGHT': "light", 'LIGHT_PROBE': "light probe", 'CAMERA': "camera",
        'SPEAKER': "speaker",
    }
    blend_name = bpy.path.display_name_from_filepath(bpy.data.filepath) if bpy.data.filepath else ""
    header = "The document" + (" “{:s}”".format(blend_name) if blend_name else "")
    if not objects:
        facts.append(header + " has no objects in its scene “{:s}”.".format(scene.name))
    else:
        groups = []
        for ob_type, names in sorted(by_type.items(), key=lambda item: -len(item[1])):
            label = _plural(len(names), type_names.get(ob_type, ob_type.lower()))
            shown = names if len(names) <= 12 else names[:12] + ["more"]
            groups.append("{:s} ({:s})".format(label, ", ".join(shown)))
        facts.append("{:s} has {:s} in its scene “{:s}”: {:s}.".format(
            header, _plural(len(objects), "object"), scene.name, "; ".join(groups)))
    selected = [ob.name for ob in objects if ob.select_get()]
    active = context.active_object
    if selected:
        facts.append("Selected: {:s}.".format(_join(selected[:20]) if len(selected) <= 20 else
                                              _plural(len(selected), "object")))
    else:
        facts.append("Nothing is selected.")
    facts.append("Working in {:s}.".format(_mode_name(context)))
    if active is not None:
        d = active.dimensions
        loc = active.matrix_world.translation
        facts.append("The active object is {:s}, a {:s}, {:s} by {:s} by {:s}, at {:s}, {:s}, {:s}.".format(
            active.name, type_names.get(active.type, active.type.lower()),
            _length(context, d.x), _length(context, d.y), _length(context, d.z),
            _length(context, loc.x), _length(context, loc.y), _length(context, loc.z)))
        if active.type == 'MESH' and active.data:
            mesh = active.data
            facts.append("Its mesh has {:s}, {:s} and {:s}.".format(
                _plural(len(mesh.vertices), "vertex").replace("vertexs", "vertices"),
                _plural(len(mesh.edges), "edge"), _plural(len(mesh.polygons), "face")))
        if active.modifiers:
            facts.append("Modifiers: {:s}.".format(_join([mod.name for mod in active.modifiers])))
        materials = [slot.material.name for slot in active.material_slots if slot.material]
        if materials:
            facts.append("Materials: {:s}.".format(_join(materials)))
    frames = "Frame {:d} of {:d} to {:d}".format(scene.frame_current, scene.frame_start, scene.frame_end)
    render = scene.render
    engine = render.bl_rna.properties["engine"].enum_items.get(render.engine)
    facts.append("{:s}, rendering with {:s} at {:d} by {:d}.".format(
        frames, engine.name if engine else render.engine.title(),
        render.resolution_x * render.resolution_percentage // 100,
        render.resolution_y * render.resolution_percentage // 100))
    return {
        "sentence": " ".join(facts),
        "objects": len(objects),
        "selected": selected,
        "active": active.name if active else None,
        "mode": _mode_name(context),
    }


# -----------------------------------------------------------------------------
# Entry Point

_HANDLERS = {
    "commands": _commands,
    "run": _run,
    "settings": _settings,
    "get": _get,
    "set": _set,
    "describe": _describe,
}


def perform(context, request):
    """Answer one request from the app's intents: JSON in, JSON out.

    The request names what to do ("commands", "run", "settings", "get", "set" or "describe") and
    its arguments. Everything runs in the document's 3D Viewport, as Blender's own interface would.
    A failure answers with a sentence too, never an exception.
    """
    try:
        request = json.loads(request)
        handler = _HANDLERS[request.get("intent")]
    except (ValueError, KeyError, TypeError, AttributeError):
        return json.dumps({"sentence": "Blender didn't understand that."})
    try:
        with context.temp_override(**_view3d_override(context)):
            answer = handler(bpy.context, request)
    except Exception as ex:
        import traceback
        traceback.print_exc()
        answer = {"sentence": "Blender couldn't do that: {:s}".format(str(ex))}
    return json.dumps(answer, ensure_ascii=False)
