# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""The Outliner's rows for the native interface, and its edits. Properties comes from Blender's
actual UI layouts."""

import json
import bpy
from bpy.props import StringProperty


def _uid(item):
    return str(item.session_uid)


def _object_actions(context, obj):
    actions = ['visibility']
    # Renaming, moving into collections and parenting only change data: in any mode, as in the
    # Outliner, though not for an object being edited.
    if obj.is_editable and obj.mode != 'EDIT':
        actions += ['rename', 'move']
    if context.mode == 'OBJECT' and obj.is_editable:
        if obj.visible_get(view_layer=context.view_layer) and not obj.hide_select:
            actions.append('duplicate')
        if not obj.library and not obj.override_library:
            actions.append('delete')
    return actions


def _accepts_children(context, obj):
    """Whether objects can be dropped onto this one to be parented to it."""
    return obj.is_editable and obj.mode != 'EDIT' and not obj.library


def _collection_actions(context, layer):
    # The scene collection cannot be hidden, renamed or deleted, as in the Outliner.
    if layer == context.view_layer.layer_collection:
        return []
    coll = layer.collection
    actions = ['visibility']
    if coll.is_editable and not coll.override_library:
        actions += ['rename', 'move']
        if context.mode == 'OBJECT':
            actions.append('delete')
    return actions


def _accepts_drop(context, layer):
    """Whether objects and collections can be moved into this collection."""
    coll = layer.collection
    return not layer.exclude and coll.is_editable and not coll.override_library


def _scene_collections(context):
    """Every collection in the scene, the scene collection included."""
    found = [context.scene.collection]
    for coll in found:
        found += [child for child in coll.children if child not in found]
    return found


def _collection_by_uid(context, uid):
    return next((coll for coll in _scene_collections(context) if _uid(coll) == uid), None)


def _objects(context, request):
    """The objects a request is about: a single `id`, or several `ids` for a selection."""
    ids = request.get('ids') or [request.get('id')]
    lookup = {_uid(obj): obj for obj in context.view_layer.objects}
    objects = [lookup[uid] for uid in ids if uid in lookup]
    if not objects or len(objects) != len(ids):
        raise ValueError("Some of these objects are no longer in the current view layer.")
    return objects


def _keep_transform(obj, parent):
    matrix = obj.matrix_world.copy()
    obj.parent = parent
    obj.matrix_world = matrix


def _move_objects(context, objects, target):
    """Move objects into a collection, out of the scene's other collections. Children whose parent
    stays behind are unparented in place, so they show up where they were dropped."""
    for obj in objects:
        for coll in _scene_collections(context):
            if coll != target and obj.name in coll.objects:
                coll.objects.unlink(obj)
        if obj.name not in target.objects:
            target.objects.link(obj)
    for obj in objects:
        if obj.parent and obj.parent not in objects:
            _keep_transform(obj, None)


def _parent_objects(context, objects, parent):
    """Parent objects to another, keeping where they are, like dropping in the Outliner."""
    for obj in objects:
        ancestor = parent
        while ancestor:
            if ancestor == obj:
                raise ValueError("An object cannot be parented to itself or its children.")
            ancestor = ancestor.parent
    shared = [coll for coll in _scene_collections(context) if parent.name in coll.objects]
    for obj in objects:
        _keep_transform(obj, parent)
        # Children list under their parent only when they share a collection.
        if shared and not any(obj.name in coll.objects for coll in shared):
            _move_objects(context, [obj], shared[0])
            _keep_transform(obj, parent)


def _move_collections(context, collections, target):
    for coll in collections:
        if coll == target or target in _descendants(coll):
            raise ValueError("A collection cannot be moved into itself.")
    for coll in collections:
        for parent in _scene_collections(context):
            if parent != target and coll.name in parent.children:
                parent.children.unlink(coll)
        if coll.name not in target.children:
            target.children.link(coll)


def _descendants(coll):
    found = list(coll.children)
    for child in found:
        found += [grandchild for grandchild in child.children if grandchild not in found]
    return found


def _layer_collection(layer, coll):
    if layer.collection == coll:
        return layer
    for child in layer.children:
        found = _layer_collection(child, coll)
        if found:
            return found
    return None


def _delete_collection(context, coll):
    """Remove a collection but keep its contents, like the Outliner's Delete: objects and child
    collections move to every collection that held it, so nothing leaves the scene."""
    parents = [c for c in bpy.data.collections if coll.name in c.children]
    parents += [scene.collection for scene in bpy.data.scenes if coll.name in scene.collection.children]
    for parent in parents:
        for obj in coll.objects:
            if obj.name not in parent.objects:
                parent.objects.link(obj)
        for child in coll.children:
            if child.name not in parent.children:
                parent.children.link(child)
    bpy.data.collections.remove(coll)


def _hierarchy(context):
    rows = []
    active = context.view_layer.objects.active
    objects = {obj.name: obj for obj in context.view_layer.objects}

    def collection(layer, depth, parent):
        coll = layer.collection
        key = parent + "/c" + _uid(coll)
        rows.append({"key": key, "parent": parent, "depth": depth, "kind": "collection",
                     "id": _uid(coll), "name": coll.name, "icon": "OUTLINER_COLLECTION",
                     "enabled": not layer.exclude, "active": False, "hidden": layer.hide_viewport,
                     "actions": _collection_actions(context, layer),
                     "accepts": _accepts_drop(context, layer)})
        members = {obj.name: obj for obj in coll.objects if obj.name in objects}
        children = {}
        for obj in members.values():
            parent_name = obj.parent.name if obj.parent and obj.parent.name in members else ""
            children.setdefault(parent_name, []).append(obj)

        def object_rows(parent_name, level, parent_key):
            for obj in sorted(children.get(parent_name, []), key=lambda item: item.name.casefold()):
                obj_key = parent_key + "/o" + _uid(obj)
                rows.append({"key": obj_key, "parent": parent_key, "depth": level,
                             "kind": "object", "id": _uid(obj), "name": obj.name,
                             "icon": 'OUTLINER_OB_' + obj.type, "active": obj == active,
                             "selected": obj.select_get(view_layer=context.view_layer),
                             "hidden": obj.hide_get(view_layer=context.view_layer),
                             "actions": _object_actions(context, obj),
                             "accepts": _accepts_children(context, obj),
                             "enabled": obj.visible_get(view_layer=context.view_layer)
                             and not obj.hide_select and context.mode == 'OBJECT'})
                object_rows(obj.name, level + 1, obj_key)

        object_rows("", depth + 1, key)
        for child in layer.children:
            collection(child, depth + 1, key)

    collection(context.view_layer.layer_collection, 0, "")
    parents = {row['parent'] for row in rows}
    for row in rows:
        row['children'] = row['key'] in parents
    return rows


def hierarchy(context):
    """The Outliner's rows, in outline order, for the native interface's `outliner` view."""
    return _hierarchy(context)


class WM_OT_native_panel_edit(bpy.types.Operator):
    bl_idname = "wm.native_panel_edit"
    bl_label = "Outliner Edit"
    bl_options = {'INTERNAL', 'UNDO'}
    request: StringProperty(options={'HIDDEN', 'SKIP_SAVE'})

    def execute(self, context):
        try:
            request = json.loads(self.request)
            obj = next((obj for obj in context.view_layer.objects if _uid(obj) == request.get('id')), None)
            action = request.get('action')
            if action in {'move', 'parent'}:
                # Dragged rows, or a selection moved with the menu: objects or collections.
                if request.get('kind') == 'collection':
                    collections = [_collection_by_uid(context, uid) for uid in request.get('ids', [])]
                    target = _collection_by_uid(context, request.get('target'))
                    if not collections or None in collections or target is None:
                        raise ValueError("These collections are no longer in the scene.")
                    layers = [_layer_collection(context.view_layer.layer_collection, coll)
                              for coll in collections]
                    if any(layer is None or 'move' not in _collection_actions(context, layer)
                           for layer in layers):
                        raise ValueError("These collections cannot be moved.")
                    _move_collections(context, collections, target)
                else:
                    objects = _objects(context, request)
                    if any('move' not in _object_actions(context, item) for item in objects):
                        raise ValueError("These objects cannot be moved in the current mode.")
                    if action == 'parent':
                        parent = next((item for item in context.view_layer.objects
                                       if _uid(item) == request.get('target')), None)
                        if parent is None:
                            raise ValueError("That object is no longer in the current view layer.")
                        if not _accepts_children(context, parent):
                            raise ValueError("Objects cannot be parented to that object now.")
                        _parent_objects(context, objects, parent)
                    else:
                        target = _collection_by_uid(context, request.get('target'))
                        layer = target and _layer_collection(context.view_layer.layer_collection, target)
                        if layer is None or not _accepts_drop(context, layer):
                            raise ValueError("Objects cannot be moved into that collection.")
                        _move_objects(context, objects, target)
            elif request.get('ids') and action in {'duplicate', 'delete', 'visibility'}:
                # The same action on every selected object, as one undo step.
                objects = _objects(context, request)
                if any(action not in _object_actions(context, item) for item in objects):
                    raise ValueError("This action is no longer available for all of these objects.")
                if action == 'visibility':
                    for item in objects:
                        item.hide_set(bool(request['value']), view_layer=context.view_layer)
                elif action == 'delete':
                    with context.temp_override(selected_objects=objects):
                        result = bpy.ops.object.delete('EXEC_DEFAULT', False, use_global=False)
                    if 'FINISHED' not in result:
                        raise ValueError("These objects could not be deleted.")
                else:
                    for other in context.view_layer.objects:
                        other.select_set(other in objects)
                    context.view_layer.objects.active = objects[0]
                    result = bpy.ops.object.duplicate('EXEC_DEFAULT', False, linked=False)
                    if 'FINISHED' not in result:
                        raise ValueError("These objects could not be duplicated.")
            elif action == 'collection_new':
                name = request.get('value')
                parent = context.view_layer.active_layer_collection
                if context.mode != 'OBJECT' or not parent.collection.is_editable or parent.exclude:
                    raise ValueError("A collection cannot be added here in the current mode.")
                if not isinstance(name, str) or not name.strip():
                    raise ValueError("Enter a collection name.")
                collection = bpy.data.collections.new(name.strip())
                try:
                    parent.collection.children.link(collection)
                except Exception:
                    bpy.data.collections.remove(collection)
                    raise
                context.view_layer.update()
                context.view_layer.active_layer_collection = parent.children[collection.name]
            elif request.get('kind') == 'collection':
                coll = next((c for c in bpy.data.collections if _uid(c) == request.get('id')), None)
                layer = coll and _layer_collection(context.view_layer.layer_collection, coll)
                action = request.get('action')
                if layer is None:
                    raise ValueError("This collection is no longer in the current view layer.")
                if action not in _collection_actions(context, layer):
                    raise ValueError("This action is no longer available for this collection.")
                if action == 'visibility':
                    layer.hide_viewport = bool(request['value'])
                elif action == 'rename':
                    name = request.get('value')
                    if not isinstance(name, str) or not name.strip():
                        raise ValueError("Enter a collection name.")
                    coll.name = name.strip()
                else:
                    _delete_collection(context, coll)
            elif obj is None:
                raise ValueError("This object is no longer in the current view layer.")
            elif request.get('action') == 'select':
                if context.mode != 'OBJECT' or obj.hide_select or not obj.visible_get():
                    raise ValueError("This object cannot be selected in the current mode.")
                selected = bool(request.get('value', True))
                if not request.get('extend', False):
                    for other in context.view_layer.objects:
                        other.select_set(other == obj)
                else:
                    obj.select_set(selected)
                if selected:
                    context.view_layer.objects.active = obj
                elif context.view_layer.objects.active == obj:
                    context.view_layer.objects.active = next(
                        (other for other in context.view_layer.objects if other.select_get()), None)
            elif request.get('action') == 'visibility':
                obj.hide_set(bool(request['value']), view_layer=context.view_layer)
            elif request.get('action') in {'duplicate', 'delete', 'rename'}:
                action = request['action']
                if action not in _object_actions(context, obj):
                    raise ValueError("This action is no longer available for this object.")
                if action == 'rename':
                    name = request.get('value')
                    if not isinstance(name, str) or not name.strip():
                        raise ValueError("Enter an object name.")
                    obj.name = name.strip()
                elif action == 'delete':
                    # Delete only this row, retaining Blender's scene/link and override handling.
                    with context.temp_override(selected_objects=[obj]):
                        result = bpy.ops.object.delete('EXEC_DEFAULT', False, use_global=False)
                    if 'FINISHED' not in result:
                        raise ValueError("This object could not be deleted.")
                else:
                    selected = list(context.selected_objects)
                    active = context.view_layer.objects.active
                    try:
                        # The duplicate operator consumes selected bases, not just RNA objects.
                        for other in context.view_layer.objects:
                            other.select_set(other == obj)
                        context.view_layer.objects.active = obj
                        result = bpy.ops.object.duplicate('EXEC_DEFAULT', False, linked=False)
                        if 'FINISHED' not in result:
                            raise ValueError("This object could not be duplicated.")
                    except Exception:
                        for other in context.view_layer.objects:
                            other.select_set(other in selected)
                        context.view_layer.objects.active = active
                        raise
            else:
                raise ValueError("Unknown hierarchy action.")
            for area in context.screen.areas:
                area.tag_redraw()
        except (ValueError, TypeError, RuntimeError, ReferenceError, KeyError) as error:
            self.report({'ERROR'}, str(error))
            return {'CANCELLED'}
        return {'FINISHED'}


class VIEW3D_PT_native_sculpt_settings(bpy.types.Panel):
    """Key sculpt settings for the native iPadOS top bar."""
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "Tool"
    bl_label = "Sculpt"

    @classmethod
    def poll(cls, context):
        # Only the native projection draws this, from the viewport's main region.
        # Blender's own UI draws side-bar panels in the 'UI' region and never polls true.
        region = context.region
        return (context.mode == 'SCULPT' and context.sculpt_object is not None and
                region is not None and region.type == 'WINDOW')

    def draw(self, context):
        # The brush's size, strength, direction and color are in the sidebar beside the viewport
        # and above the brushes, see `bl_ui.native_brush`.
        layout = self.layout
        obj = context.sculpt_object
        dyntopo = obj.use_dynamic_topology_sculpting
        layout.operator(
            "sculpt.dynamic_topology_toggle",
            text="Dyntopo",
            icon='CHECKBOX_HLT' if dyntopo else 'CHECKBOX_DEHLT',
        )
        if dyntopo:
            # Beside the toggle, a number to type or drag rather than a slider.
            sculpt = context.tool_settings.sculpt
            if sculpt.detail_type_method in {'CONSTANT', 'MANUAL'}:
                layout.prop(sculpt, "constant_detail_resolution", text="")
            elif sculpt.detail_type_method == 'BRUSH':
                layout.prop(sculpt, "detail_percent", text="")
            else:
                layout.prop(sculpt, "detail_size", text="")
        _draw_mirror(layout, context)


class VIEW3D_PT_native_sculpt_remesh_popout_settings(bpy.types.Panel):
    """Voxel Remesh for the native iPadOS top bar: one control there, its options popping out."""
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "Tool"
    bl_label = "Remesh"

    @classmethod
    def poll(cls, context):
        region = context.region
        obj = context.sculpt_object
        return (context.mode == 'SCULPT' and obj is not None and obj.type == 'MESH' and
                region is not None and region.type == 'WINDOW')

    def draw(self, context):
        layout = self.layout
        mesh = context.sculpt_object.data
        layout.prop(mesh, "remesh_voxel_size", text="Voxel Size")
        layout.prop(mesh, "remesh_voxel_adaptivity", text="Adaptivity")
        layout.prop(mesh, "use_remesh_fix_poles", text="Fix Poles")
        layout.prop(mesh, "use_remesh_preserve_volume", text="Preserve Volume")
        layout.prop(mesh, "use_remesh_preserve_attributes", text="Preserve Attributes")
        layout.operator("object.voxel_remesh", text="Remesh", icon='MOD_REMESH')


def _draw_mirror(layout, context):
    """The mode's mirror axes as one row of toggles, as Blender's tool header shows them."""
    mode = context.mode
    obj = context.object
    if obj is None:
        return
    # Edit Mode and Pose Mode have Mirror with the transform settings, at the top.
    if mode in {'PAINT_WEIGHT', 'SCULPT', 'PAINT_VERTEX', 'PAINT_TEXTURE'}:
        owner, props = obj, ("use_mesh_mirror_x", "use_mesh_mirror_y", "use_mesh_mirror_z")
    elif mode == 'SCULPT_CURVES':
        owner, props = obj.data, ("use_mirror_x", "use_mirror_y", "use_mirror_z")
    else:
        return
    row = layout.row(align=True)
    row.label(text="Mirror")
    for prop in props:
        row.prop(owner, prop, text=prop[-1].upper(), toggle=True)


def _unified_owner(settings, brush, name):
    ups = getattr(settings, "unified_paint_settings", None)
    return ups if ups is not None and getattr(ups, "use_unified_" + name, False) else brush


# Enum items must stay referenced while Blender shows them.
_material_items = []


def _grease_pencil_material_items(_self, context):
    global _material_items
    obj = context.object if context else None
    items = []
    for index, slot in enumerate(obj.material_slots if obj else ()):
        material = slot.material
        icon = 'MATERIAL'
        if material:
            # The material's own swatch, as Blender's material popover shows it.
            material.preview_ensure()
            icon = material.preview.icon_id
        items.append((str(index), material.name if material else "Empty Slot", "", icon, index))
    _material_items = items or [('0', "No Material", "", 'MATERIAL', 0)]
    return _material_items


def _grease_pencil_material_get(_self):
    obj = bpy.context.object
    return obj.active_material_index if obj else 0


def _grease_pencil_material_set(_self, value):
    obj = bpy.context.object
    if obj and value < len(obj.material_slots):
        obj.active_material_index = value


def _grease_pencil_color_mode_get(_self):
    return 0 if bpy.context.tool_settings.gpencil_paint.color_mode == 'MATERIAL' else 1


def _grease_pencil_color_mode_set(_self, value):
    bpy.context.tool_settings.gpencil_paint.color_mode = 'MATERIAL' if value == 0 else 'VERTEXCOLOR'


class VIEW3D_PT_native_brush_settings(bpy.types.Panel):
    """Key brush settings of the paint modes other than Sculpt for the native iPadOS top bar."""
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "Tool"
    bl_label = "Brush"

    @classmethod
    def register(cls):
        bpy.types.WindowManager.native_grease_pencil_material = bpy.props.EnumProperty(
            name="Material",
            description="Material to draw with, the object's active material",
            items=_grease_pencil_material_items,
            get=_grease_pencil_material_get,
            set=_grease_pencil_material_set,
        )
        # Draw Mode's Color Mode, named short enough for the top bar.
        bpy.types.WindowManager.native_grease_pencil_color_mode = bpy.props.EnumProperty(
            name="Color",
            description="Draw with the material's color, or a color of the stroke's own",
            items=(
                ('MATERIAL', "Material", "Draw with the material's color", 'MATERIAL', 0),
                ('COLOR', "Color", "Draw with a color of the stroke's own", 'VPAINT_HLT', 1),
            ),
            get=_grease_pencil_color_mode_get,
            set=_grease_pencil_color_mode_set,
        )

    @classmethod
    def unregister(cls):
        del bpy.types.WindowManager.native_grease_pencil_material
        del bpy.types.WindowManager.native_grease_pencil_color_mode

    @classmethod
    def poll(cls, context):
        # As the Sculpt panel, only the native projection draws this, from the main region.
        from bl_ui.properties_paint_common import UnifiedPaintPanel
        region = context.region
        if region is None or region.type != 'WINDOW' or context.mode == 'SCULPT':
            return False
        settings = UnifiedPaintPanel.paint_settings(context)
        return settings is not None and settings.brush is not None

    def draw(self, context):
        from bl_ui.properties_paint_common import UnifiedPaintPanel

        layout = self.layout
        mode = context.mode
        settings = UnifiedPaintPanel.paint_settings(context)
        brush = settings.brush
        draw_type = brush.gpencil_brush_type if mode == 'PAINT_GREASE_PENCIL' else None

        # The brush's size, strength and color are in the sidebar beside the viewport and above
        # the brushes, see `bl_ui.native_brush`.
        if draw_type in {'DRAW', 'FILL'}:
            paint = context.tool_settings.gpencil_paint
            layout.prop(context.window_manager, "native_grease_pencil_color_mode", expand=True)
            if paint.color_mode != 'VERTEXCOLOR':
                layout.prop(context.window_manager, "native_grease_pencil_material", text="Material")
        if mode == 'PAINT_GREASE_PENCIL' and context.space_data and context.space_data.type == 'VIEW_3D':
            # The neighbouring frames shown faintly, to draw in between.
            layout.prop(context.space_data.overlay, "use_gpencil_onion_skin", text="Onion Skin",
                        icon='ONIONSKIN_ON')
        if draw_type == 'FILL':
            layout.prop(brush.gpencil_settings, "fill_direction", text="Direction", expand=True)
        elif draw_type == 'ERASE':
            layout.prop(brush.gpencil_settings, "eraser_mode", text="Mode", expand=True)
        elif mode in {'PAINT_WEIGHT', 'WEIGHT_GREASE_PENCIL'}:
            layout.prop(_unified_owner(settings, brush, "weight"), "weight", text="Weight", slider=True)
        _draw_mirror(layout, context)


# Above this many selected vertices their median is not worked out as the panel is drawn.
_MEDIAN_LIMIT = 50000


def _median_selection(context):
    """The Edit Mode meshes' selected vertices as `[(object, mesh, vertices)]`, or an empty list
    when there are none or too many to go through."""
    objects = [ob for ob in context.objects_in_mode_unique_data if ob.type == 'MESH']
    count = sum(ob.data.total_vert_sel for ob in objects)
    if count == 0 or count > _MEDIAN_LIMIT:
        return []
    import bmesh
    selection = []
    for ob in objects:
        if ob.data.total_vert_sel:
            mesh = bmesh.from_edit_mesh(ob.data)
            selection.append((ob, mesh, [vert for vert in mesh.verts if vert.select]))
    return selection


def _median_global(self, selection):
    # Several objects have no local space in common.
    return self.native_item_space == 'GLOBAL' or len(selection) > 1


def _median(self, selection):
    from mathutils import Vector
    use_global = _median_global(self, selection)
    total = Vector()
    count = 0
    for ob, _mesh, verts in selection:
        matrix = ob.matrix_world
        for vert in verts:
            total += (matrix @ vert.co) if use_global else vert.co
        count += len(verts)
    return total / count


def _median_get(self):
    selection = _median_selection(bpy.context)
    return tuple(_median(self, selection)) if selection else (0.0, 0.0, 0.0)


def _median_set(self, value):
    from mathutils import Vector
    import bmesh
    selection = _median_selection(bpy.context)
    if not selection:
        return
    offset = Vector(value) - _median(self, selection)
    use_global = _median_global(self, selection)
    for ob, _mesh, verts in selection:
        local = (ob.matrix_world.inverted_safe().to_3x3() @ offset) if use_global else offset
        for vert in verts:
            vert.co += local
        bmesh.update_edit_mesh(ob.data, loop_triangles=True, destructive=False)


class VIEW3D_PT_native_item_median(bpy.types.Panel):
    """Item's Transform in Edit Mode for the native interface: where the selected vertices are,
    which Blender's own panel shows in fields that are not properties"""
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "Item"
    bl_label = "Transform"

    @classmethod
    def register(cls):
        bpy.types.WindowManager.native_item_median = bpy.props.FloatVectorProperty(
            name="Median",
            description="Where the selected vertices are, on average: changing it moves them all",
            subtype='TRANSLATION',
            unit='LENGTH',
            precision=4,
            get=_median_get,
            set=_median_set,
        )
        bpy.types.WindowManager.native_item_space = bpy.props.EnumProperty(
            name="Space",
            description="The space the median is in",
            items=(
                ('GLOBAL', "Global", "The scene's space"),
                ('LOCAL', "Local", "The object's own space"),
            ),
            default='LOCAL',
        )

    @classmethod
    def unregister(cls):
        del bpy.types.WindowManager.native_item_median
        del bpy.types.WindowManager.native_item_space

    @classmethod
    def poll(cls, context):
        # As the panels above, only the native projection draws this, from the main region.
        region = context.region
        return context.mode == 'EDIT_MESH' and region is not None and region.type == 'WINDOW'

    def draw(self, context):
        layout = self.layout
        layout.use_property_split = True
        window_manager = context.window_manager
        count = sum(ob.data.total_vert_sel for ob in context.objects_in_mode_unique_data
                    if ob.type == 'MESH')
        if count == 0:
            layout.label(text="Nothing selected")
        elif count > _MEDIAN_LIMIT:
            layout.label(text="Select fewer vertices to move them by typing")
        else:
            layout.prop(window_manager, "native_item_median", text="Vertex" if count == 1 else "Median")
            layout.prop(window_manager, "native_item_space", expand=True)


class WM_OT_native_node_tree_new(bpy.types.Operator):
    """Make a node tree for the native node editor to show, as its own buttons do"""
    bl_idname = "wm.native_node_tree_new"
    bl_label = "New Node Tree"
    bl_options = {'INTERNAL', 'UNDO'}
    kind: StringProperty(options={'HIDDEN', 'SKIP_SAVE'})

    def execute(self, context):
        ob = context.active_object
        if self.kind == 'SHADER':
            if ob is None:
                return {'CANCELLED'}
            material = bpy.data.materials.new("Material")
            if len(ob.material_slots) and ob.material_slots[ob.active_material_index].material is None:
                ob.active_material = material
            else:
                ob.data.materials.append(material)
                ob.active_material_index = len(ob.material_slots) - 1
        elif self.kind == 'GEOMETRY':
            # A Geometry Nodes modifier without a node group gets one, rather than another modifier.
            modifier = ob.modifiers.active if ob is not None else None
            if modifier is not None and modifier.type == 'NODES' and modifier.node_group is None:
                bpy.ops.node.new_geometry_node_group_assign()
            else:
                bpy.ops.node.new_geometry_nodes_modifier()
        elif self.kind == 'COMPOSITOR':
            before = set(bpy.data.node_groups)
            bpy.ops.node.new_compositing_node_group(name="Compositor Nodes")
            made = [group for group in bpy.data.node_groups if group not in before]
            if made:
                context.scene.compositing_node_group = made[0]
        else:
            return {'CANCELLED'}
        return {'FINISHED'}


classes = (
    WM_OT_native_panel_edit,
    WM_OT_native_node_tree_new,
    VIEW3D_PT_native_sculpt_settings,
    VIEW3D_PT_native_sculpt_remesh_popout_settings,
    VIEW3D_PT_native_brush_settings,
    VIEW3D_PT_native_item_median,
)
