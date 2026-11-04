# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Keyframes for the native iPad timeline.

The timeline shows what Blender's own timeline shows with Only Show Selected: the keys of the
selected objects and the active one, including their object data. Keys are summarized per frame,
and selecting, moving or deleting a frame acts on every key on it, as with summary keys in the
timeline.
"""

import bpy
from bpy.props import BoolProperty, IntProperty, StringProperty
from bpy_extras import anim_utils

__all__ = (
    "keys",
)


def _objects(context):
    objects = list(getattr(context, "selected_objects", ()) or ())
    active = getattr(context, "active_object", None)
    if active is not None and active not in objects:
        objects.append(active)
    return objects


def _channelbags(context):
    seen = set()
    for ob in _objects(context):
        for owner in (ob, ob.data):
            animation = getattr(owner, "animation_data", None)
            if animation is None or animation.action is None:
                continue
            key = (animation.action.session_uid, animation.action_slot.handle if animation.action_slot else -1)
            if key in seen:
                continue
            seen.add(key)
            channelbag = anim_utils.action_get_channelbag_for_slot(animation.action, animation.action_slot)
            if channelbag is not None:
                yield channelbag


def _fcurves(context):
    for channelbag in _channelbags(context):
        yield from channelbag.fcurves


def _grease_pencil_layers(context):
    """The layers of the Grease Pencil objects among them: their keys are drawings."""
    seen = set()
    for ob in _objects(context):
        if ob.type != 'GREASEPENCIL' or ob.data is None or ob.data.session_uid in seen:
            continue
        seen.add(ob.data.session_uid)
        yield from ob.data.layers


def keys(context):
    """Keyed frames as `[{"f": frame, "s": selected}, ...]`, sorted by frame."""
    frames = {}
    for fcurve in _fcurves(context):
        points = fcurve.keyframe_points
        count = len(points)
        if not count:
            continue
        co = [0.0] * (count * 2)
        selected = [False] * count
        points.foreach_get("co", co)
        points.foreach_get("select_control_point", selected)
        for i in range(count):
            frame = round(co[i * 2])
            frames[frame] = frames.get(frame, False) or bool(selected[i])
    for layer in _grease_pencil_layers(context):
        for gp_frame in layer.frames:
            frame = gp_frame.frame_number
            frames[frame] = frames.get(frame, False) or gp_frame.select
    return [{"f": frame, "s": frames[frame]} for frame in sorted(frames)]


def _frames(text):
    return {int(frame) for frame in text.split(",") if frame.strip()}


def _redraw(context):
    for area in context.screen.areas if context.screen else ():
        area.tag_redraw()


def _set_selected(point, selected):
    point.select_control_point = selected
    point.select_left_handle = selected
    point.select_right_handle = selected


class ANIM_OT_native_key_select(bpy.types.Operator):
    """Select the keys on some frames of the timeline"""
    bl_idname = "anim.native_key_select"
    bl_label = "Select Keyframes"
    bl_options = {'INTERNAL', 'UNDO'}

    frames: StringProperty(description="Comma separated frames", options={'SKIP_SAVE'})
    extend: BoolProperty(options={'SKIP_SAVE'})

    def execute(self, context):
        frames = _frames(self.frames)
        for fcurve in _fcurves(context):
            for point in fcurve.keyframe_points:
                if round(point.co.x) in frames:
                    _set_selected(point, True)
                elif not self.extend:
                    _set_selected(point, False)
        for layer in _grease_pencil_layers(context):
            for gp_frame in layer.frames:
                if gp_frame.frame_number in frames:
                    gp_frame.select = True
                elif not self.extend:
                    gp_frame.select = False
        _redraw(context)
        return {'FINISHED'}


class ANIM_OT_native_key_move(bpy.types.Operator):
    """Move the selected keys of the timeline by a number of frames"""
    bl_idname = "anim.native_key_move"
    bl_label = "Move Keyframes"
    bl_options = {'INTERNAL', 'UNDO'}

    delta: IntProperty(options={'SKIP_SAVE'})

    def execute(self, context):
        delta = self.delta
        if delta == 0:
            return {'CANCELLED'}
        moved = False
        for fcurve in _fcurves(context):
            points = fcurve.keyframe_points
            targets = {round(point.co.x) + delta for point in points if point.select_control_point}
            if not targets:
                continue
            # Moved keys replace unselected keys where they land, as when moving keys in Blender.
            for point in reversed([point for point in points
                                   if not point.select_control_point and round(point.co.x) in targets]):
                points.remove(point, fast=True)
            for point in points:
                if point.select_control_point:
                    point.co.x += delta
                    point.handle_left.x += delta
                    point.handle_right.x += delta
            fcurve.update()
            moved = True
        for layer in _grease_pencil_layers(context):
            selected = sorted((f.frame_number for f in layer.frames if f.select), reverse=delta > 0)
            if not selected:
                continue
            # Drawings moved replace unselected ones where they land, as keys do.
            targets = {frame + delta for frame in selected}
            for frame in [f.frame_number for f in layer.frames if not f.select and f.frame_number in targets]:
                layer.frames.remove(frame)
            for frame in selected:
                layer.frames.move(frame, frame + delta)
            moved = True
        if not moved:
            return {'CANCELLED'}
        _redraw(context)
        return {'FINISHED'}


class ANIM_OT_native_key_delete(bpy.types.Operator):
    """Delete the selected keys of the timeline"""
    bl_idname = "anim.native_key_delete"
    bl_label = "Delete Keyframes"
    bl_options = {'INTERNAL', 'UNDO'}

    def execute(self, context):
        deleted = False
        for channelbag in _channelbags(context):
            for fcurve in list(channelbag.fcurves):
                points = fcurve.keyframe_points
                selected = [point for point in points if point.select_control_point]
                if not selected:
                    continue
                for point in reversed(selected):
                    points.remove(point, fast=True)
                deleted = True
                # Like deleting keys in Blender, a curve left without keys goes too.
                if len(points):
                    fcurve.update()
                else:
                    channelbag.fcurves.remove(fcurve)
        for layer in _grease_pencil_layers(context):
            for frame in [f.frame_number for f in layer.frames if f.select]:
                layer.frames.remove(frame)
                deleted = True
        if not deleted:
            return {'CANCELLED'}
        _redraw(context)
        return {'FINISHED'}


classes = (
    ANIM_OT_native_key_select,
    ANIM_OT_native_key_move,
    ANIM_OT_native_key_delete,
)
