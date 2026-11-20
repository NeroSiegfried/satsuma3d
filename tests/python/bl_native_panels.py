# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Hierarchy tests against real Blender. Native Properties is tested on the device."""
import importlib.util
import json
from pathlib import Path
import bpy

path = Path(__file__).resolve().parents[2] / 'scripts/startup/bl_ui/native_panels.py'
spec = importlib.util.spec_from_file_location('scene_panels_under_test', path)
panels = importlib.util.module_from_spec(spec)
spec.loader.exec_module(panels)
bpy.utils.register_class(panels.WM_OT_native_panel_edit)
checks = []


def check(ok, name):
    assert ok, name
    checks.append(name)


_failed = []


def apply(**request):
    """Run an edit as the outliner view does, remembering whether it failed."""
    try:
        result = bpy.ops.wm.native_panel_edit('EXEC_DEFAULT', True, request=json.dumps(request))
    except RuntimeError:
        result = {'CANCELLED'}
    _failed[:] = ['FINISHED' not in result]


def failed():
    return _failed[0]


def rows():
    return panels.hierarchy(bpy.context)


def edit(obj, action, **values):
    apply(id=str(obj.session_uid), action=action, **values)


cube = bpy.context.active_object
camera = bpy.data.objects['Camera']
check(len([row for row in rows() if row['kind'] == 'object']) == 3, 'Real scene objects')
edit(camera, 'select')
check(bpy.context.active_object == camera and camera.select_get() and not cube.select_get(), 'Active object selection')
edit(cube, 'select', extend=True, value=True)
check(bpy.context.active_object == cube and camera.select_get() and cube.select_get(), 'Native multi-selection adds an active object')
edit(cube, 'select', extend=True, value=False)
check(bpy.context.active_object == camera and camera.select_get() and not cube.select_get(), 'Native deselection preserves remaining selection')
edit(cube, 'visibility', value=True)
check(cube.hide_get(), 'Hide object')
edit(cube, 'select')
check(bpy.context.active_object == camera and failed(), 'Hidden object cannot be selected')
edit(cube, 'visibility', value=False)
check(not cube.hide_get(), 'Show object')
cube.hide_select = True
edit(cube, 'select')
check(bpy.context.active_object == camera and failed(), 'Selection lock respected')
cube.hide_select = False
child = bpy.data.objects.new('Nested "quoted"', None)
bpy.context.collection.objects.link(child)
child.parent = cube
hierarchy = rows()
parent = next(row for row in hierarchy if row['id'] == str(cube.session_uid))
nested = next(row for row in hierarchy if row['id'] == str(child.session_uid))
check(nested['parent'] == parent['key'] and parent['children'], 'Parent tree and disclosure state')
uid = str(child.session_uid)
bpy.data.objects.remove(child, do_unlink=True)
apply(id=uid, action='select')
check(failed(), 'Deleted target is rejected')
edit(cube, 'select')
bpy.ops.object.mode_set(mode='EDIT')
edit(camera, 'select')
check(bpy.context.active_object == cube and failed(), 'Edit Mode guarded')
bpy.ops.object.mode_set(mode='OBJECT')
edit(cube, 'rename', value='  Renamed Cube  ')
check(cube.name == 'Renamed Cube', 'Rename trims the native field')
edit(cube, 'rename', value='  ')
check(cube.name == 'Renamed Cube' and failed(), 'Blank names are rejected')
camera.select_set(True)
before = set(bpy.data.objects)
edit(cube, 'duplicate')
added = set(bpy.data.objects) - before
check(len(added) == 1 and not failed(), 'Duplicate targets only the swiped row despite multi-selection')
duplicate = added.pop()
check(duplicate.data != cube.data and duplicate.data.vertices[0].co == cube.data.vertices[0].co,
      'Duplicate uses Blender data duplication')
check(bpy.context.active_object == duplicate and duplicate.select_get() and not camera.select_get(),
      'Duplicate becomes the active selected object')
camera.select_set(True)
edit(duplicate, 'delete')
check(set(bpy.data.objects) == before and camera.select_get(), 'Delete targets only one row and preserves other selected objects')
edit(cube, 'visibility', value=True)
actions = next(row['actions'] for row in rows() if row['id'] == str(cube.session_uid))
check('duplicate' not in actions and {'visibility', 'rename', 'delete'} <= set(actions),
      'Hidden rows expose only applicable actions')
edit(cube, 'duplicate')
check(failed() and set(bpy.data.objects) == before, 'Hidden-object duplication is rejected')
edit(cube, 'visibility', value=False)
edit(cube, 'select')
bpy.ops.object.mode_set(mode='EDIT')
for action in ('delete', 'duplicate'):
    edit(camera, action, value='Not renamed')
    check(failed() and bpy.data.objects.get('Camera') == camera, 'Edit Mode guards ' + action)
bpy.ops.object.mode_set(mode='OBJECT')
# Scene-local deletion must retain an object linked into another scene.
other_scene = bpy.data.scenes.new('Other Scene')
other_scene.collection.objects.link(camera)
edit(camera, 'delete')
check(camera.name in other_scene.objects and camera.name not in bpy.context.scene.objects,
      'Delete respects Blender scene-local unlinking')
def collection_row(coll):
    return next(row for row in rows() if row['kind'] == 'collection' and row['id'] == str(coll.session_uid))


def edit_collection(coll, action, **values):
    apply(id=str(coll.session_uid), kind='collection', action=action, **values)


parent = bpy.context.view_layer.active_layer_collection
edit(cube, 'collection_new', value='  Native Collection  ')
collection = bpy.data.collections.get('Native Collection')
# ROUND6 EDIT-7 (D18): New Collection goes under the active collection and leaves it active, as
# the Outliner's does; three in a row are siblings, not A > B > C.
check(collection and collection.name in parent.collection.children and
      bpy.context.view_layer.active_layer_collection == parent,
      'New collection is nested under the active one, which stays active')
for name in ('Sibling A', 'Sibling B', 'Sibling C'):
    edit(cube, 'collection_new', value=name)
check(all(name in parent.collection.children for name in ('Sibling A', 'Sibling B', 'Sibling C'))
      and bpy.context.view_layer.active_layer_collection == parent,
      'New Collection three times gives three siblings')
check([row['name'] for row in rows() if row['kind'] == 'collection' and row['current']] == [parent.collection.name],
      'Exactly one row is marked the active collection')
edit_collection(collection, 'activate')
check(not failed() and bpy.context.collection == collection and collection_row(collection)['current']
      and not collection_row(parent.collection)['current'], 'A collection row makes it the active collection')
bpy.ops.mesh.primitive_cube_add()
check(bpy.context.object.name in collection.objects, 'New objects go into the active collection')
edit_collection(bpy.context.scene.collection, 'activate')
check(not failed() and bpy.context.collection == bpy.context.scene.collection,
      'The scene collection can be the active one')
edit_collection(collection, 'activate')
for name in ('Sibling A', 'Sibling B', 'Sibling C'):
    bpy.data.collections.remove(bpy.data.collections[name])
count = len(bpy.data.collections)
edit(cube, 'collection_new', value='   ')
check(len(bpy.data.collections) == count and failed(), 'Blank collection names are rejected')
bpy.ops.object.mode_set(mode='EDIT')
edit(cube, 'collection_new', value='Not Added')
check(len(bpy.data.collections) == count and failed(), 'Collection creation is guarded in Edit Mode')
bpy.ops.object.mode_set(mode='OBJECT')
edit(cube, 'collection_new', value='Native Collection')
check(len(bpy.data.collections) == count + 1 and 'Native Collection.001' in bpy.data.collections,
      'Blender assigns unique collection names')
check(collection_row(bpy.context.scene.collection)['actions'] == ['activate'],
      'The scene collection cannot be hidden, renamed or deleted, only made active')
check(set(collection_row(collection)['actions']) == {'activate', 'visibility', 'restrict', 'rename', 'delete', 'move'},
      'Collections offer swipe actions and can be dragged')

# ROUND6 EDIT-7 (D19): every restriction column of Blender's Outliner is a row's restriction or its
# eye; a row it dims can be undimmed from its own menu.
COLUMNS = {'enable': 'layer.exclude', 'select': 'collection.hide_select', 'hide': 'visibility',
           'viewport': 'collection.hide_viewport', 'render': 'collection.hide_render',
           'holdout': 'layer.holdout', 'indirect_only': 'layer.indirect_only'}
columns = {prop.identifier[len('show_restrict_column_'):] for prop in bpy.types.SpaceOutliner.bl_rna.properties
           if prop.identifier.startswith('show_restrict_column_')}
offered = {item['key'] for item in collection_row(collection)['restrictions']} | {'visibility'}
check(columns == set(COLUMNS) and set(COLUMNS.values()) <= offered,
      'Every Outliner restriction column is offered (%s, %s)' % (sorted(columns), sorted(offered)))
check({item['key'] for item in next(row for row in rows() if row['id'] == str(cube.session_uid))['restrictions']} ==
      {'object.hide_select', 'object.hide_viewport', 'object.hide_render'},
      'Objects offer their selectable, viewport and render flags')
check(collection_row(bpy.context.scene.collection)['restrictions'] == [], 'The scene collection has none')
edit(cube, 'restrict', value={'key': 'object.hide_select', 'value': True})
cube_row = next(row for row in rows() if row['id'] == str(cube.session_uid))
check(cube.hide_select and not cube_row['enabled'] and 'restrict' in cube_row['actions'],
      'An unselectable object is dimmed and keeps its restrictions')
edit(cube, 'restrict', value={'key': 'object.hide_select', 'value': False})
check(not cube.hide_select and next(row for row in rows() if row['id'] == str(cube.session_uid))['enabled'],
      'Its restriction undims it')
edit_collection(collection, 'restrict', value={'key': 'layer.exclude', 'value': True})
check(collection_row(collection)['enabled'] is False and 'activate' not in collection_row(collection)['actions'],
      'An excluded collection is dimmed and cannot be the active one')
edit_collection(collection, 'restrict', value={'key': 'layer.exclude', 'value': False})
check(collection_row(collection)['enabled'], 'Including it again undims it')
edit_collection(collection, 'restrict', value={'key': 'object.hide_select', 'value': True})
check(failed(), 'A flag of another kind of row is refused')
edit_collection(collection, 'visibility', value=True)
check(collection_row(collection)['hidden'] and
      panels._layer_collection(bpy.context.view_layer.layer_collection, collection).hide_viewport,
      'Hide uses the collection viewport toggle')
edit_collection(collection, 'visibility', value=False)
edit_collection(collection, 'rename', value='  Props  ')
check(collection.name == 'Props', 'Rename a collection')
inner = bpy.data.collections.new('Inner')
collection.children.link(inner)
contents = set(collection.objects)
holder = parent.collection
edit_collection(collection, 'delete')
check('Props' not in bpy.data.collections and contents <= set(holder.objects) and inner.name in holder.children,
      'Delete keeps objects and child collections in the parent, like the Outliner')

# Dragging rows: objects into collections or onto other objects, collections into collections.
def request(action, ids, target, kind='object'):
    apply(action=action, kind=kind, ids=ids, target=target)
    return failed()


scene_collection = bpy.context.scene.collection
shelf = bpy.data.collections.new('Shelf')
scene_collection.children.link(shelf)
bpy.context.view_layer.update()
check(collection_row(shelf)['accepts'] and collection_row(scene_collection)['accepts'],
      'Collections accept dropped rows')
stand = bpy.data.objects.new('Stand', None)
stand.location = (1, 2, 3)
scene_collection.objects.link(stand)
lamp = bpy.data.objects['Light']
lamp.location = (4, 1, 6)
bpy.context.view_layer.update()
before = lamp.matrix_world.copy()
error = request('move', [str(lamp.session_uid)], str(shelf.session_uid))
check(not error and list(lamp.users_collection) == [shelf], 'Dropping an object on a collection moves it there')
error = request('parent', [str(lamp.session_uid)], str(stand.session_uid))
check(not error and lamp.parent == stand and all(abs(a - b) < 1e-5 for a, b in zip(lamp.matrix_world.translation, before.translation)),
      'Dropping an object on another parents it in place')
hierarchy = rows()
stand_rows = [row for row in hierarchy if row['id'] == str(stand.session_uid)]
lamp_row = next(row for row in hierarchy if row['id'] == str(lamp.session_uid))
check(lamp_row['parent'] in {row['key'] for row in stand_rows},
      'A parented object lists under its parent, sharing its collection')
error = request('parent', [str(stand.session_uid)], str(lamp.session_uid))
check(error and stand.parent is None, 'An object cannot be parented to its own child')
error = request('move', [str(lamp.session_uid)], str(shelf.session_uid))
check(not error and lamp.parent is None and list(lamp.users_collection) == [shelf] and
      all(abs(a - b) < 1e-5 for a, b in zip(lamp.matrix_world.translation, before.translation)),
      'Moving a child out of its parent unparents it in place')
error = request('move', [str(lamp.session_uid), str(stand.session_uid)], str(scene_collection.session_uid))
check(not error and scene_collection in lamp.users_collection and scene_collection in stand.users_collection
      and lamp.name not in shelf.objects, 'Several dragged objects move together')
bpy.ops.ed.undo_push(message='Before nesting')
box = bpy.data.collections.new('Box')
scene_collection.children.link(box)
bpy.context.view_layer.update()
error = request('move', [str(box.session_uid)], str(shelf.session_uid), kind='collection')
check(not error and box.name in shelf.children and box.name not in scene_collection.children,
      'Dropping a collection on another nests it')
error = request('move', [str(shelf.session_uid)], str(box.session_uid), kind='collection')
check(error and shelf.name in scene_collection.children, 'A collection cannot move into its own child')

# The selection's swipe and menu actions, as one step each.
both = [str(lamp.session_uid), str(stand.session_uid)]
request_ids = lambda action, **values: apply(action=action, ids=both, **values)
request_ids('visibility', value=True)
check(lamp.hide_get() and stand.hide_get(), 'Hide several objects')
request_ids('visibility', value=False)
count = len(bpy.data.objects)
request_ids('duplicate')
check(len(bpy.data.objects) == count + 2 and not failed(), 'Duplicate several objects')
request_ids('delete')
check('Light' not in bpy.data.objects and 'Stand' not in bpy.data.objects and not failed(),
      'Delete several objects')

# Item's Transform in Edit Mode: the median of the selected vertices, read and moved.
import bmesh
from mathutils import Vector
bpy.ops.object.select_all(action='DESELECT')
cube.hide_set(False)
cube.select_set(True)
bpy.context.view_layer.objects.active = cube
cube.location = (2.0, 0.0, 0.0)
bpy.context.view_layer.update()
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
window_manager = bpy.context.window_manager
window_manager.native_item_space = 'LOCAL'
check(Vector(window_manager.native_item_median).length < 1e-5, 'Median of a whole cube is its origin, locally')
window_manager.native_item_space = 'GLOBAL'
check((Vector(window_manager.native_item_median) - Vector((2.0, 0.0, 0.0))).length < 1e-5, 'Median in global space')
window_manager.native_item_median = (2.0, 0.0, 1.5)
mesh = bmesh.from_edit_mesh(cube.data)
check(abs(sum(vert.co.z for vert in mesh.verts) / len(mesh.verts) - 1.5) < 1e-5, 'Typing a median moves the vertices')
window_manager.native_item_space = 'LOCAL'
check((Vector(window_manager.native_item_median) - Vector((0.0, 0.0, 1.5))).length < 1e-5, 'Median in local space')
bpy.ops.mesh.select_all(action='DESELECT')
check(tuple(window_manager.native_item_median) == (0.0, 0.0, 0.0), 'Nothing selected has no median')
# The means beside it, which Blender's panel shows in fields that are not properties (ROUND6
# PANEL-14, B14): the edges' crease and bevel weight, made the first time they are set.
bpy.ops.mesh.select_all(action='SELECT')
window_manager.native_item_mean_crease_edge = 0.5
window_manager.native_item_mean_bevel_weight_edge = 0.25
mesh = bmesh.from_edit_mesh(cube.data)
crease = mesh.edges.layers.float.get("crease_edge")
bevel = mesh.edges.layers.float.get("bevel_weight_edge")
check(crease is not None and all(abs(edge[crease] - 0.5) < 1e-5 for edge in mesh.edges),
      'Mean Crease sets the selected edges')
check(bevel is not None and all(abs(edge[bevel] - 0.25) < 1e-5 for edge in mesh.edges),
      'Mean Bevel Weight sets the selected edges')
check(abs(window_manager.native_item_mean_crease_edge - 0.5) < 1e-5, 'Mean Crease reads back')
bpy.ops.object.mode_set(mode='OBJECT')
# A curve's control points and a lattice's points, which had no Transform in the Item tab (B14):
# their median moves them, a curve's handles with them, and their means set them.
bpy.ops.curve.primitive_bezier_curve_add(location=(0.0, 0.0, 0.0), enter_editmode=True)
curve = bpy.context.active_object
bpy.ops.curve.select_all(action='SELECT')
window_manager.native_item_space = 'LOCAL'
points = curve.data.splines[0].bezier_points
handle_before = points[0].handle_left.z - points[0].co.z
window_manager.native_item_median = (0.0, 0.0, 1.0)
check(abs(sum(point.co.z for point in points) / len(points) - 1.0) < 1e-5, 'Typing a curve median moves its points')
check(abs(points[0].handle_left.z - points[0].co.z - handle_before) < 1e-5, 'A control point carries its handles')
window_manager.native_item_mean_radius = 2.0
check(all(abs(point.radius - 2.0) < 1e-5 for point in points), 'Mean Radius sets the control points')
bpy.ops.object.mode_set(mode='OBJECT')
bpy.ops.object.add(type='LATTICE', location=(0.0, 0.0, 0.0))
lattice = bpy.context.active_object
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.lattice.select_all(action='SELECT')
window_manager.native_item_median = (0.0, 0.0, 0.5)
check(abs(sum(point.co_deform.z for point in lattice.data.points) / len(lattice.data.points) - 0.5) < 1e-5,
      'Typing a lattice median moves its points')
bpy.ops.object.mode_set(mode='OBJECT')
print('PASS: native scene panels ' + json.dumps(checks))
