# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Timeline keyframes against real Blender: how the native timeline's keys are selected, moved,
deleted and jumped to. Its edits are the Timeline's own, run in a hidden Timeline (ROUND6 EDIT-6):
the keys of the scene, the world and the selected objects, locked channels left alone, keys moved
onto others replacing them. The strip's drawn keys against the jump and a real Timeline are
compared on the Mac by `mac_bridge_check.py --scenario timelinekeys`."""
import json
import bpy

checks = []


def check(ok, name):
    assert ok, name
    checks.append(name)


def bag(owner):
    for layer in owner.animation_data.action.layers:
        for strip in layer.strips:
            return strip.channelbags[0]


def curve_frames(owner):
    return sorted({round(p.co.x, 3) for fc in bag(owner).fcurves for p in fc.keyframe_points})


def frames(owner=None):
    return [int(f) if f == int(f) else f for f in curve_frames(owner or cube)]


def selected(owner=None):
    return sorted({round(p.co.x) for fc in bag(owner or cube).fcurves for p in fc.keyframe_points
                   if p.select_control_point})


scene = bpy.context.scene
cube = bpy.data.objects['Cube']
camera = bpy.data.objects['Camera']
scene.frame_start, scene.frame_end = 1, 250
for frame, x in ((1, 0.0), (10, 5.0), (20, 9.0)):
    cube.location.x = x
    cube.keyframe_insert('location', frame=frame)
camera.keyframe_insert('location', frame=30)
bpy.ops.object.select_all(action='DESELECT')
cube.select_set(True)
bpy.context.view_layer.objects.active = cube


def jumps(start):
    """The frames the strip's next button visits from \a start."""
    scene.frame_set(start)
    visited = []
    while bpy.ops.anim.native_key_jump(next=True) == {'FINISHED'}:
        visited.append(scene.frame_current)
    return visited


check(jumps(-100) == [1, 10, 20], 'The jump visits the selected objects\' keys, as the Timeline with Only Show Selected')
camera.select_set(True)
check(jumps(-100) == [1, 10, 20, 30], 'Every selected object adds its keys')
camera.select_set(False)
scene.frame_set(25)
check(bpy.ops.anim.native_key_jump(next=False) == {'FINISHED'} and scene.frame_current == 20,
      'The previous button goes back to a key')

check(bpy.ops.anim.native_key_select(frames="10") == {'FINISHED'} and selected() == [10],
      'Selecting a frame selects only its keys')
check(bpy.ops.anim.native_key_move(delta=5) == {'FINISHED'} and frames() == [1, 15, 20] and selected() == [15],
      'Moving moves the selected keys')
scene.frame_set(15)
check(abs(cube.location.x - 5.0) < 1e-6, 'Moved keys keep their values')
check(bpy.ops.anim.native_key_move(delta=5) == {'FINISHED'} and frames() == [1, 20],
      'A key moved onto another key replaces it')
scene.frame_set(20)
check(abs(cube.location.x - 5.0) < 1e-6, 'The moved key wins, as when moving keys in Blender')
check(bpy.ops.anim.native_key_select(frames="1,20") == {'FINISHED'} and selected() == [1, 20],
      'A box selects several frames')
check(bpy.ops.anim.native_key_move(delta=2) == {'FINISHED'} and frames() == [3, 22],
      'Selected keys move together')
check(bpy.ops.anim.native_key_select(frames="") == {'FINISHED'} and selected() == [],
      'Selecting nothing deselects everything')
check(bpy.ops.anim.native_key_move(delta=1) == {'CANCELLED'}, 'Nothing selected moves nothing')
bpy.ops.anim.native_key_select(frames="3")
check(bpy.ops.anim.native_key_select(frames="22", extend=True) == {'FINISHED'} and selected() == [3, 22],
      'Extending keeps the selection')
bpy.ops.anim.native_key_select(frames="22")
check(bpy.ops.anim.native_key_delete() == {'FINISHED'} and frames() == [3], 'Deleting removes the selected keys')
bpy.ops.anim.native_key_select(frames="3")
check(bpy.ops.anim.native_key_delete() == {'FINISHED'} and len(bag(cube).fcurves) == 0,
      'Curves left without keys are removed')
check(bpy.ops.anim.native_key_delete() == {'CANCELLED'}, 'Nothing selected deletes nothing')
check(len(bag(camera).fcurves[0].keyframe_points) == 1, 'Unselected objects are untouched')

# ROUND6 EDIT-1 (D1): the strip's edits keep to the frames it draws. A key at 40, selected
# elsewhere, is outside a strip drawing 1 to 30: moving and deleting leave it alone.
for frame in (5, 40):
    cube.keyframe_insert('location', frame=frame)
bpy.ops.anim.native_key_select(frames="5,40")
check(bpy.ops.anim.native_key_move(delta=2, frame_start=1, frame_end=30) == {'FINISHED'}
      and frames() == [7, 40] and selected() == [7, 40], 'A move keeps to the frames the strip draws')
check(bpy.ops.anim.native_key_delete(frame_start=1, frame_end=30) == {'FINISHED'} and frames() == [40]
      and selected() == [40], 'A delete keeps to the frames the strip draws')
check(bpy.ops.anim.native_key_move(delta=2, frame_start=1, frame_end=30) == {'CANCELLED'} and frames() == [40],
      'A key selected outside them alone does not move')

# ROUND6 EDIT-6 (D16): a locked channel's keys stay, as in the Timeline.
for frame in (50, 60):
    cube.keyframe_insert('location', frame=frame)
locked = next(fc for fc in bag(cube).fcurves if fc.array_index == 1)
locked.lock = True
bpy.ops.anim.native_key_select(frames="50")
check(bpy.ops.anim.native_key_move(delta=3) == {'FINISHED'}
      and sorted(round(p.co.x) for p in locked.keyframe_points) == [40, 50, 60]
      and all(53 in [round(p.co.x) for p in fc.keyframe_points] for fc in bag(cube).fcurves if not fc.lock),
      'A locked channel\'s key does not move')
bpy.ops.anim.native_key_select(frames="60")
bpy.ops.anim.native_key_delete()
check(60 in [round(p.co.x) for p in locked.keyframe_points]
      and all(60 not in [round(p.co.x) for p in fc.keyframe_points] for fc in bag(cube).fcurves if not fc.lock),
      'A locked channel\'s key is not deleted')
locked.lock = False

# ROUND6 EDIT-6 (D16): a key between frames is not taken for the frame it is drawn on when
# another lands there: only keys on the same frame are replaced, as in the Timeline.
x = next(fc for fc in bag(cube).fcurves if fc.array_index == 0)
x.keyframe_points.insert(70.4, 1.0)
x.keyframe_points.insert(66, 2.0)
bpy.ops.anim.native_key_select(frames="66")
check(bpy.ops.anim.native_key_move(delta=4) == {'FINISHED'}
      and [round(p.co.x, 1) for p in x.keyframe_points if p.co.x > 65] == [70.0, 70.4],
      'A key landing beside a key between frames leaves it')

# The scene's and the world's keys are the Timeline's too, selected or not.
world = scene.world
world.color = (0.1, 0.2, 0.3)
world.keyframe_insert('color', frame=90)
scene.keyframe_insert('audio_volume', frame=95)
check(jumps(80) == [90, 95], 'The world\'s and the scene\'s keys are jumped to, as in the Timeline')
bpy.ops.anim.native_key_select(frames="90")
check(bpy.ops.anim.native_key_move(delta=1) == {'FINISHED'}
      and [round(p.co.x) for fc in bag(world).fcurves for p in fc.keyframe_points] == [91, 91, 91],
      'The world\'s keys move with the strip')

# Grease Pencil drawings are keys of the Timeline: a locked layer stays.
bpy.ops.object.grease_pencil_add(type='EMPTY')
pencil = bpy.context.active_object
layer = pencil.data.layers.new("Ink")
locked_layer = pencil.data.layers.new("Locked")
for frame in (100, 110):
    layer.frames.new(frame)
    locked_layer.frames.new(frame)
locked_layer.lock = True
check(jumps(98) == [100, 110], 'A selected Grease Pencil object\'s drawings are jumped to')
bpy.ops.anim.native_key_select(frames="100")
check(bpy.ops.anim.native_key_move(delta=2) == {'FINISHED'}
      and sorted(f.frame_number for f in layer.frames) == [102, 110]
      and sorted(f.frame_number for f in locked_layer.frames) == [100, 110],
      'Drawings move with the strip, those of a locked layer stay')
print('PASS: native timeline keys ' + json.dumps(checks))
