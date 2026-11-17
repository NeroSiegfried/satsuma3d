# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""The viewpoint of a document, kept with it for the native iPad interface.

The iPad opens files without their screens (`G_FILE_NO_UI`), so its own layout is kept; that also
dropped where the view looked from. The main 3D View's viewpoint is stored on the scene when the
file is saved and applied when it is opened, so a document, and a template made from one, opens
where it was left.
"""

import os
import sys

import bpy
from bpy.app.handlers import persistent

KEY = "native_view"


def _on_ipad():
    # Python built for iOS says "ios" from 3.13; builds patched before that say "darwin", with the
    # device's model as the machine and "iphoneos" in the multiarch.
    if sys.platform == "ios" or "iphoneos" in getattr(sys.implementation, "_multiarch", ""):
        return True
    return os.uname().machine.startswith(("iPad", "iPhone"))


# Only where the native interface opens files without their screens. Tests turn it on.
enabled = _on_ipad()


def main_view(window_manager):
    """The largest 3D View of the first window that has one: its space and region data."""
    for window in window_manager.windows:
        areas = [area for area in window.screen.areas if area.type == 'VIEW_3D']
        if not areas:
            continue
        area = max(areas, key=lambda area: area.width * area.height)
        space = area.spaces.active
        if space and space.region_3d:
            return space, space.region_3d
    return None, None


def store(scene, space, rv3d):
    scene[KEY] = {
        "location": list(rv3d.view_location),
        "rotation": list(rv3d.view_rotation),
        "distance": rv3d.view_distance,
        "perspective": rv3d.view_perspective,
        "lens": space.lens,
        "clip_start": space.clip_start,
        "clip_end": space.clip_end,
    }


def apply(scene, space, rv3d):
    """Apply the stored viewpoint; returns whether there was one."""
    state = scene.get(KEY)
    if state is None:
        return False
    try:
        rv3d.view_location = state["location"]
        rv3d.view_rotation = state["rotation"]
        rv3d.view_distance = state["distance"]
        # Looking through a camera that may since be gone: from where the camera looked instead.
        perspective = state["perspective"]
        if perspective == 'CAMERA' and scene.camera is None:
            perspective = 'PERSP'
        rv3d.view_perspective = perspective
        space.lens = state["lens"]
        space.clip_start = state["clip_start"]
        space.clip_end = state["clip_end"]
    except (KeyError, TypeError, ValueError):
        return False
    return True


@persistent
def _save_pre(_filepath):
    if not enabled:
        return
    context = bpy.context
    space, rv3d = main_view(context.window_manager)
    if rv3d is not None and context.scene is not None:
        store(context.scene, space, rv3d)


@persistent
def _load_post(_filepath):
    if not enabled:
        return
    context = bpy.context
    space, rv3d = main_view(context.window_manager)
    if rv3d is not None and context.scene is not None:
        apply(context.scene, space, rv3d)


def register():
    if _save_pre not in bpy.app.handlers.save_pre:
        bpy.app.handlers.save_pre.append(_save_pre)
    if _load_post not in bpy.app.handlers.load_post:
        bpy.app.handlers.load_post.append(_load_post)


def unregister():
    if _save_pre in bpy.app.handlers.save_pre:
        bpy.app.handlers.save_pre.remove(_save_pre)
    if _load_post in bpy.app.handlers.load_post:
        bpy.app.handlers.load_post.remove(_load_post)


classes = ()
