# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Files brought into a document on the iPad (ROUND6 FILES-4, FILES-5).

What is brought in (ROUND6 FILES-5, finding F4, decision R6-14): a file from outside the
document's folder, dropped, picked with the system picker, or loaded by a script, is packed into
the document as it is next written (`pack_brought_in`, run by the document's write), as images
opened in the Image Editor and fonts always were. Share and Save As offer to include the rest
(`external_files`, `pack_external`).

Link and Append for the iPad (ROUND6 FILES-4, finding F9).

Desktop browses inside a `.blend` with its own File Browser, which reads folders itself: in the
iPad's sandbox it can list only the app's own folder. Here it is two steps: the system picker for
the `.blend` (which grants it), then a list of its data-blocks by type, read with Blender's own
library loader (`BLO_blendhandle`), with Link or Append and the operator's options. The chosen
data-blocks are then linked or appended by Blender's own `wm.link`, `wm.append` or
`wm.id_linked_relocate`, so their options and results are desktop's.

On the iPad, `WM_apple_ios_fileselect_begin` hands each of those three operators here, from any
menu, Search, a key or a dropped `.blend`; this operator is reachable on its own too.
"""

import os
import re

import bpy
from bpy.props import (
    BoolProperty,
    CollectionProperty,
    EnumProperty,
    IntProperty,
    StringProperty,
)
from bpy.types import Operator, PropertyGroup

# Blender's names for the data-block types, by the plural the library loader lists them under:
# `IDTypeInfo::name` against `name_plural` (`tests/python/bl_native_link_append.py` checks this
# against blenkernel). The library loader's names that are not data a person brings in are left out.
ID_TYPE_NAMES = {
    "actions": "Action",
    "annotations": "Annotation",
    "armatures": "Armature",
    "brushes": "Brush",
    "cache_files": "CacheFile",
    "cameras": "Camera",
    "collections": "Collection",
    "curves": "Curve",
    "fonts": "Font",
    "grease_pencils": "GreasePencil",
    "hair_curves": "Curves",
    "images": "Image",
    "lattices": "Lattice",
    "lightprobes": "LightProbe",
    "lights": "Light",
    "linestyles": "FreestyleLineStyle",
    "masks": "Mask",
    "materials": "Material",
    "meshes": "Mesh",
    "metaballs": "Metaball",
    "movieclips": "MovieClip",
    "node_groups": "NodeTree",
    "objects": "Object",
    "paint_curves": "PaintCurve",
    "palettes": "Palette",
    "particles": "ParticleSettings",
    "pointclouds": "PointCloud",
    "scenes": "Scene",
    "shape_keys": "Key",
    "sounds": "Sound",
    "speakers": "Speaker",
    "texts": "Text",
    "textures": "Texture",
    "volumes": "Volume",
    "workspaces": "WorkSpace",
    "worlds": "World",
}
# Listed by the loader but not brought in by a person: the file's screens, its own libraries.
NOT_LISTED = {"screens", "libraries", "link_placeholders"}

# Desktop's own operators, whose options this one carries.
OPTIONS = ("autoselect", "active_collection", "instance_collections", "instance_object_data",
           "do_reuse_local_id", "clear_asset_data")

# What each file holds, read once per file: {path: {plural: [names]}}.
_listings = {}
# Dynamic enum items must outlive the call that made them.
_type_items = []


def library_path(path):
    """The `.blend` in a path that may browse inside it ("lib.blend/Object/Cube")."""
    match = re.match(r"(.+?\.blend\d*)(?:[/\\]|$)", path or "")
    return match.group(1) if match else (path or "")


def listing(path):
    """The data-blocks of the `.blend` at ``path``, by type, read with Blender's library loader."""
    if path not in _listings:
        found = {}
        with bpy.data.libraries.load(path, link=True) as (data_from, _data_to):
            for plural in ID_TYPE_NAMES:
                names = list(getattr(data_from, plural, ()) or ())
                if names:
                    found[plural] = sorted(names, key=str.casefold)
        _listings[path] = found
    return _listings[path]


def id_by_session_uid(uid):
    """The data-block with this session id, and the plural its type is listed under."""
    for plural in ID_TYPE_NAMES:
        for id_data in getattr(bpy.data, plural, ()):
            if id_data.session_uid == uid:
                return id_data, plural
    return None, ""


def run(path, mode, plural, names, options=None, id_session_uid=0):
    """Link, append or relocate ``names`` of type ``plural`` from the `.blend` at ``path``, through
    Blender's own operators. Returns their result."""
    directory = os.path.join(path, ID_TYPE_NAMES[plural]) + os.sep
    props = {key: value for key, value in (options or {}).items() if key in OPTIONS}
    files = [{"name": name} for name in names]
    if mode == 'RELOCATE':
        return bpy.ops.wm.id_linked_relocate(
            'EXEC_DEFAULT', id_session_uid=id_session_uid, directory=directory,
            filename=names[0], filepath=directory + names[0],
            **{key: value for key, value in props.items() if key not in {"do_reuse_local_id", "clear_asset_data"}})
    operator = bpy.ops.wm.link if mode == 'LINK' else bpy.ops.wm.append
    if mode == 'LINK':
        props = {key: value for key, value in props.items() if key not in {"do_reuse_local_id", "clear_asset_data"}}
    return operator('EXEC_DEFAULT', directory=directory, files=files, filename=names[0],
                    filepath=directory + names[0], **props)


def _absolute(path, id_data):
    library = getattr(id_data, "library", None)
    return os.path.normpath(bpy.path.abspath(path, library=library))


def _inside(path, folder):
    return bool(folder) and (path == folder or path.startswith(folder.rstrip(os.sep) + os.sep))


def _packable():
    """The data-blocks Blender can pack, with their file, not packed yet and the file's own."""
    for image in bpy.data.images:
        if (image.library is None and image.packed_file is None and image.filepath and
                image.source in {'FILE', 'TILED'}):
            yield image, _absolute(image.filepath, image)
    for font in bpy.data.fonts:
        if font.library is None and font.packed_file is None and font.filepath not in {"", "<builtin>"}:
            yield font, _absolute(font.filepath, font)
    for volume in bpy.data.volumes:
        if volume.library is None and volume.packed_file is None and volume.filepath and \
                hasattr(volume, "pack"):
            yield volume, _absolute(volume.filepath, volume)


def _unpackable():
    """Files Blender reads by their path and cannot pack: movies, image sequences, movie clips,
    caches, sounds, linked libraries."""
    for image in bpy.data.images:
        if image.library is None and image.packed_file is None and image.filepath and \
                image.source in {'MOVIE', 'SEQUENCE'}:
            yield image, _absolute(image.filepath, image)
    for collection in (bpy.data.movieclips, bpy.data.cache_files, bpy.data.sounds):
        for id_data in collection:
            if id_data.library is None and getattr(id_data, "packed_file", None) is None and \
                    id_data.filepath:
                yield id_data, _absolute(id_data.filepath, id_data)
    for library in bpy.data.libraries:
        if library.packed_file is None and library.filepath:
            yield library, _absolute(library.filepath, library)


def _document_folder():
    path = bpy.data.filepath
    return os.path.dirname(os.path.normpath(path)) if path else ""


def pack_brought_in():
    """Pack every file a data-block reads from outside the document's folder (R6-14). Returns the
    names packed. Files that cannot be read are left as they are (FILES-3 asks for them)."""
    folder = _document_folder()
    if not folder:
        return []
    packed = []
    for id_data, path in list(_packable()):
        if _inside(path, folder) or not os.path.isfile(path):
            continue
        try:
            id_data.pack()
        except RuntimeError as error:
            print("Could not pack %s: %s" % (id_data.name, error))
            continue
        packed.append(id_data.name)
    return packed


def external_files():
    """What a copy of the document sent elsewhere would miss: (packable, unpackable) file names."""
    packable = sorted({os.path.basename(path) for _id, path in _packable()})
    unpackable = sorted({os.path.basename(path) for _id, path in _unpackable()})
    return packable, unpackable


def external_summary():
    """"packable unpackable first-name" for the document's Share and Save As."""
    packable, unpackable = external_files()
    first = (packable or unpackable or [""])[0]
    return "%d %d %s" % (len(packable), len(unpackable), first)


def pack_external():
    """Include External Files: pack everything Blender can pack, as Pack Resources does."""
    count = 0
    for id_data, path in list(_packable()):
        if os.path.isfile(path):
            id_data.pack()
            count += 1
    return count


class WM_PG_native_library_item(PropertyGroup):
    use: BoolProperty(name="Use", default=False)


def _id_type_items(self, _context):
    _type_items.clear()
    held = _listings.get(library_path(self.filepath), {})
    for plural in ID_TYPE_NAMES:
        if plural in held:
            _type_items.append((plural, "%s (%d)" % (bpy.path.display_name(plural), len(held[plural])),
                                ID_TYPE_NAMES[plural]))
    if not _type_items:
        _type_items.append(('NONE', "Nothing to bring in", ""))
    return _type_items


class WM_OT_native_link_append(Operator):
    """Link or append data-blocks from another .blend file"""

    bl_idname = "wm.native_link_append"
    bl_label = "Link or Append"
    bl_options = {'INTERNAL'}

    # The `.blend`, picked with the system picker (granted), or given by a drop or a caller.
    filepath: StringProperty(subtype='FILE_PATH', options={'HIDDEN', 'SKIP_SAVE'})
    filter_blender: BoolProperty(default=True, options={'HIDDEN', 'SKIP_SAVE'})
    filter_folder: BoolProperty(default=True, options={'HIDDEN', 'SKIP_SAVE'})
    mode: EnumProperty(
        name="Mode",
        items=(('APPEND', "Append", "Copy the data-blocks into this file"),
               ('LINK', "Link", "Use the data-blocks from the other file, which stays theirs"),
               ('RELOCATE', "Relocate", "Use another data-block in place of a linked one")),
        default='APPEND', options={'HIDDEN', 'SKIP_SAVE'})
    id_type: EnumProperty(name="Type", items=_id_type_items, options={'HIDDEN', 'SKIP_SAVE'})
    listed_type: StringProperty(options={'HIDDEN', 'SKIP_SAVE'})
    items: CollectionProperty(type=WM_PG_native_library_item, options={'HIDDEN', 'SKIP_SAVE'})
    id_session_uid: IntProperty(options={'HIDDEN', 'SKIP_SAVE'})
    # Blender's own options (hidden here so the picker comes first; the list's dialog draws them).
    autoselect: BoolProperty(name="Select", default=True, options={'HIDDEN', 'SKIP_SAVE'})
    active_collection: BoolProperty(name="Active Collection", default=True, options={'HIDDEN', 'SKIP_SAVE'})
    instance_collections: BoolProperty(name="Instance Collections", default=False,
                                       options={'HIDDEN', 'SKIP_SAVE'})
    instance_object_data: BoolProperty(name="Instance Object Data", default=True,
                                       options={'HIDDEN', 'SKIP_SAVE'})
    do_reuse_local_id: BoolProperty(name="Re-Use Local Data", default=False, options={'HIDDEN', 'SKIP_SAVE'})
    clear_asset_data: BoolProperty(name="Clear Asset Data", default=False, options={'HIDDEN', 'SKIP_SAVE'})

    def _fill(self):
        """The list of the chosen type's data-blocks, kept ticked across a type change."""
        held = _listings.get(library_path(self.filepath), {})
        plural = self.id_type if self.id_type in held else next(iter(held), "")
        self.items.clear()
        for name in held.get(plural, ()):
            self.items.add().name = name
        self.listed_type = plural

    def check(self, _context):
        if self.id_type != self.listed_type:
            self._fill()
            return True
        return False

    def invoke(self, context, _event):
        path = library_path(self.filepath)
        if path and os.path.isfile(path):
            self.filepath = path
            return self.execute(context)
        context.window_manager.fileselect_add(self)
        return {'RUNNING_MODAL'}

    def execute(self, context):
        path = library_path(self.filepath)
        self.filepath = path
        if not self.listed_type:
            # The `.blend` is picked: list what it holds, then ask.
            try:
                held = listing(path)
            except (OSError, RuntimeError) as error:
                self.report({'ERROR'}, "“%s” could not be read: %s" % (os.path.basename(path), error))
                return {'CANCELLED'}
            if not held:
                self.report({'WARNING'}, "“%s” holds nothing to link or append" % os.path.basename(path))
                return {'CANCELLED'}
            if self.mode == 'RELOCATE':
                _id_data, plural = id_by_session_uid(self.id_session_uid)
                if plural not in held:
                    self.report({'WARNING'}, "“%s” holds nothing of this type" % os.path.basename(path))
                    return {'CANCELLED'}
                self.id_type = plural
            self._fill()
            confirm = {'APPEND': "Append", 'LINK': "Link", 'RELOCATE': "Relocate"}[self.mode]
            return context.window_manager.invoke_props_dialog(
                self, width=420, title=os.path.basename(path), confirm_text=confirm)
        names = [item.name for item in self.items if item.use]
        if not names:
            self.report({'WARNING'}, "Nothing was chosen")
            return {'CANCELLED'}
        if self.mode == 'RELOCATE' and len(names) != 1:
            self.report({'WARNING'}, "Choose one data-block to use in its place")
            return {'CANCELLED'}
        options = {key: getattr(self, key) for key in OPTIONS}
        return run(path, self.mode, self.listed_type, names, options, self.id_session_uid)

    def draw(self, _context):
        layout = self.layout
        if self.mode != 'RELOCATE':
            layout.prop(self, "mode", expand=True)
            layout.prop(self, "id_type")
        column = layout.column(align=True)
        for item in self.items:
            column.prop(item, "use", text=item.name)
        layout.separator()
        column = layout.column(heading="Options")
        column.prop(self, "autoselect")
        column.prop(self, "active_collection")
        if self.mode == 'APPEND':
            column.prop(self, "do_reuse_local_id")
            column.prop(self, "clear_asset_data")
        column.prop(self, "instance_collections")
        column.prop(self, "instance_object_data")


classes = (
    WM_PG_native_library_item,
    WM_OT_native_link_append,
)
