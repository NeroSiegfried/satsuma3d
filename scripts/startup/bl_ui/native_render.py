# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Rendering and viewport options for the native iPad interface.

Renders run as Blender's usual render job, without its render window: the iPad shows progress and
the result itself.

An animation keeps what it makes (ROUND6 BUSY-3, G5, F10, D3, D22). Its frames are written, as they
finish, into a folder the iPad keeps for the document (`folder`), with a manifest (`Render.json`)
listing the frames that were written whole. Stopping, the system ending the work or the app being
killed leaves those frames; `continue` renders only the frames still missing. The scene's Output is
honoured: an image format keeps its frames in that format; a movie format renders the frames as PNG
and then writes the movie with FFmpeg, with the scene's container, codec and quality. A video can
be made of any frames (`make_video`): the scene's movie, or a quick H.264 one of an image format's.
A still is saved in the scene's image format, named by what it is, with a PNG to show when the iPad
cannot show that format.

Settings changed for a render are restored when it ends, and when it cannot start.
"""

import json
import os

import bpy

__all__ = (
    "start",
    "make_video",
    "cancel",
    "clear",
    "status",
    "frames_plan",
    "needs_gpu",
    "viewport_options",
    "viewport_toggle",
)

MANIFEST = "Render.json"
FRAME_PREFIX = "Frame "
# Formats the iPad shows as they are; a still in any other format gets a PNG beside it.
SHOWN_AS_IS = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".webp"}
# Frames holding scene-linear values, which a video gets the scene's view transform for.
LINEAR_FORMATS = {'OPEN_EXR', 'OPEN_EXR_MULTILAYER', 'HDR'}

_state = {"state": "idle"}
_restore = None
_display = None
_sequence = 0
# The render in progress: its folder, manifest and phase (`frames` or `video`).
_job = None
# Work to do on the main thread once the render job has ended, see `_follow_up`.
_pending = []


def _set_state(**values):
    global _state, _sequence
    _sequence += 1
    _state = dict(values, id=_sequence)


# -----------------------------------------------------------------------------
# Settings: saved and restored as a whole, so nothing a render changes stays changed.

def _properties(owner):
    for prop in owner.bl_rna.properties:
        if prop.identifier == "rna_type" or prop.is_readonly or prop.type in {'POINTER', 'COLLECTION'}:
            continue
        yield prop.identifier


def _snapshot(owner):
    values = {}
    for name in _properties(owner):
        value = getattr(owner, name)
        values[name] = list(value) if hasattr(value, "__len__") and not isinstance(value, str) else value
    return values


def _apply(owner, values, first=("media_type", "file_format", "format")):
    """Set `values` on `owner`, the properties that filter others' choices first. A value the
    owner cannot take now is tried again once the rest are set."""
    later = []
    for name in list(first) + [name for name in values if name not in first]:
        if name not in values:
            continue
        try:
            setattr(owner, name, values[name])
        except (TypeError, ValueError, AttributeError):
            later.append(name)
    for name in later:
        try:
            setattr(owner, name, values[name])
        except (TypeError, ValueError, AttributeError):
            pass


def _save_settings(scene):
    render = scene.render
    return {
        "scene": scene.name,
        "filepath": render.filepath,
        "use_file_extension": render.use_file_extension,
        "use_overwrite": render.use_overwrite,
        "use_placeholder": render.use_placeholder,
        "image": _snapshot(render.image_settings),
        "ffmpeg": _snapshot(render.ffmpeg),
    }


def _restore_settings():
    global _restore
    saved, _restore = _restore, None
    if saved is None:
        return
    scene = bpy.data.scenes.get(saved["scene"])
    if scene is None:
        return
    render = scene.render
    render.filepath = saved["filepath"]
    # The image settings first: setting their media type resets the movie's.
    _apply(render.image_settings, saved["image"])
    _apply(render.ffmpeg, saved["ffmpeg"])
    render.use_file_extension = saved["use_file_extension"]
    render.use_overwrite = saved["use_overwrite"]
    render.use_placeholder = saved["use_placeholder"]


def _restore_display():
    global _display
    if _display is not None:
        bpy.context.preferences.view.render_display_type = _display
        _display = None


# -----------------------------------------------------------------------------
# What a render writes.

def frames_plan(scene):
    """How an animation of `scene` is written: the frames' format and extension, whether they
    become a movie (the scene's Output is a video), and whether they hold linear values."""
    image = scene.render.image_settings
    if image.media_type == 'VIDEO':
        depth = '16' if image.color_depth in {'10', '12', '16'} else '8'
        mode = image.color_mode if image.color_mode in {'BW', 'RGB', 'RGBA'} else 'RGB'
        return {"format": 'PNG', "ext": ".png", "movie": True, "linear": False,
                "frames": {"media_type": 'IMAGE', "file_format": 'PNG', "color_mode": mode, "color_depth": depth}}
    return {"format": image.file_format, "ext": scene.render.file_extension, "movie": False,
            "linear": image.file_format in LINEAR_FORMATS, "frames": None}


def needs_gpu(scene, video=False):
    """Whether rendering `scene` uses the GPU, which iPadOS lets work in the background only when
    the background task was granted it (ROUND6 BUSY-4, G8): EEVEE, Workbench and any other engine
    draw with it; Cycles when its device is the GPU and one is set up; the compositor when set to
    the GPU. A video written from frames (`video`) is the sequencer's work, on the CPU."""
    render = scene.render
    if render.use_compositing and render.compositor_device == 'GPU':
        return True
    if video:
        return False
    if render.engine != 'CYCLES':
        return True
    if scene.cycles.device != 'GPU':
        return False
    addon = bpy.context.preferences.addons.get("cycles")
    preferences = addon.preferences if addon else None
    return bool(preferences and preferences.get_compute_device_type() != 'NONE' and preferences.has_active_device())


def _read_manifest(folder):
    try:
        with open(os.path.join(folder, MANIFEST), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _write_manifest(folder, manifest):
    """Written whole or not at all: it is what a later start trusts."""
    path = os.path.join(folder, MANIFEST)
    with open(path + ".part", "w", encoding="utf-8") as f:
        json.dump(manifest, f)
    os.replace(path + ".part", path)


def _frame_files(folder, manifest):
    """The frames written whole, in frame order, as paths."""
    frames = manifest.get("frames", {}) if manifest else {}
    return [os.path.join(folder, frames[key]) for key in sorted(frames, key=int)
            if os.path.isfile(os.path.join(folder, frames[key]))]


def _drop_unfinished(folder, manifest):
    """Remove frame files the manifest does not list: written by a render that was killed while
    writing them, or placeholders. Frames listed but gone are forgotten."""
    listed = set(manifest["frames"].values())
    for name in os.listdir(folder):
        if name.startswith(FRAME_PREFIX) and name not in listed:
            os.remove(os.path.join(folder, name))
    manifest["frames"] = {key: name for key, name in manifest["frames"].items()
                          if os.path.isfile(os.path.join(folder, name))}


def _scene_frames(scene):
    return list(range(scene.frame_start, scene.frame_end + 1, max(1, scene.frame_step)))


# -----------------------------------------------------------------------------
# Handlers. They run on the render job's thread: they record, and leave work to `_follow_up`.

def _remove_handlers():
    for handlers, function in (
            (bpy.app.handlers.render_write, _on_write),
            (bpy.app.handlers.render_complete, _on_complete),
            (bpy.app.handlers.render_cancel, _on_cancel),
    ):
        if function in handlers:
            handlers.remove(function)


def _add_handlers():
    _remove_handlers()
    bpy.app.handlers.render_write.append(_on_write)
    bpy.app.handlers.render_complete.append(_on_complete)
    bpy.app.handlers.render_cancel.append(_on_cancel)


def _on_write(scene, *_args):
    """A frame was written whole: list it."""
    if _job is None or _state.get("state") != "rendering" or not _state.get("animation"):
        return
    if _job["phase"] == "video":
        _set_state(**dict(_state, done=_state["done"] + 1))
        return
    path = scene.render.frame_path(frame=scene.frame_current)
    manifest = _job["manifest"]
    manifest["frames"][str(scene.frame_current)] = os.path.basename(path)
    try:
        _write_manifest(_job["folder"], manifest)
    except OSError as ex:
        print("native_render: the frame list could not be written:", ex)
    _set_state(**dict(_state, done=_state["done"] + 1, frame=scene.frame_current, last=path))


def _on_complete(scene, *_args):
    _remove_handlers()
    _pending.append(("complete", scene.name))
    _schedule()


def _on_cancel(*_args):
    _remove_handlers()
    _pending.append(("cancel", None))
    _schedule()


def _schedule():
    if _job is not None and _job.get("synchronous"):
        return  # Run by `_invoke` as the render returns.
    if not bpy.app.timers.is_registered(_follow_up):
        bpy.app.timers.register(_follow_up, first_interval=0.0)


def _follow_up():
    """On the main thread, after a render job ended."""
    while _pending:
        event, scene_name = _pending.pop(0)
        try:
            if event == "complete":
                _completed(scene_name)
            else:
                _cancelled()
        except Exception as ex:
            _end(state="error", message=str(ex) or type(ex).__name__)
    return None


def _end(**state):
    """The render is over: restore every setting and say how it ended."""
    global _job
    _remove_handlers()
    _restore_settings()
    _restore_display()
    if _job is not None:
        _remove_video_scene(_job)
        state.setdefault("folder", _job["folder"])
        if _job["animation"] and _job.get("manifest") is not None:
            # However it ended, the frames it has are said, to be kept, continued or made a video of.
            state = {**_frames_summary(_job["folder"], _job["manifest"]), "animation": True, **state}
    _job = None
    _set_state(**state)


def _frames_summary(folder, manifest):
    files = _frame_files(folder, manifest)
    wanted = manifest.get("wanted", [])
    have = {int(key) for key in manifest.get("frames", {})}
    missing = [frame for frame in wanted if frame not in have]
    return {
        "frames": files,
        "done": len(files),
        "total": len(wanted),
        "next": missing[0] if missing else 0,
        "ext": manifest.get("ext", ""),
        "movie": bool(manifest.get("movie")),
        "fps": manifest.get("fps", 24.0),
    }


def _completed(scene_name):
    job = _job
    if job is None:
        return
    if not job["animation"]:
        _end(state="done", animation=False, **_save_still(bpy.data.scenes.get(scene_name), job["folder"]))
        return
    if job["phase"] == "video":
        video = job.get("video", "")
        if not video or not os.path.isfile(video) or os.path.getsize(video) == 0:
            _end(state="error", message="The video could not be written.", animation=True,
                 **_frames_summary(job["folder"], job["manifest"]))
            return
        summary = _frames_summary(job["folder"], job["manifest"])
        _end(state="done", animation=True, video=video, quick=bool(job.get("quick")), **summary)
        return
    _restore_settings()
    manifest = job["manifest"]
    summary = _frames_summary(job["folder"], manifest)
    if manifest.get("movie") and summary["done"]:
        # The scene's Output is a movie: write it from the frames, with FFmpeg.
        _start_video(job["folder"], manifest, (manifest["movie_image"], manifest["movie_ffmpeg"]))
        return
    _end(state="done", animation=True, video="", **summary)


def _cancelled():
    job = _job
    if job is None:
        _end(state="cancelled")
        return
    if job["animation"]:
        if job["phase"] == "video" and job.get("video") and os.path.isfile(job["video"]):
            os.remove(job["video"])  # A movie stopped part way is not a movie.
        _end(state="cancelled", animation=True, **_frames_summary(job["folder"], job["manifest"]))
    else:
        _end(state="cancelled", animation=False)


# -----------------------------------------------------------------------------
# Stills.

def _save_still(scene, folder):
    """Save the render as the scene's image format says, named by what it is; a movie format
    saves a PNG, as desktop's Save As offers. A format the iPad cannot show gets a PNG beside it."""
    image = bpy.data.images.get("Render Result")
    if image is None or scene is None:
        raise RuntimeError("The render produced no image.")
    settings = scene.render.image_settings
    saved = _snapshot(settings)
    try:
        if settings.media_type == 'VIDEO':
            _apply(settings, {"media_type": 'IMAGE', "file_format": 'PNG'})
        ext = scene.render.file_extension
        path = os.path.join(folder, "Render" + ext)
        image.save_render(path, scene=scene)
        preview = ""
        if ext.lower() not in SHOWN_AS_IS:
            _apply(settings, {"media_type": 'IMAGE', "file_format": 'PNG', "color_mode": 'RGBA', "color_depth": '8'})
            preview = os.path.join(folder, "Preview.png")
            image.save_render(preview, scene=scene)
    finally:
        _apply(settings, saved)
    return {"image": path, "preview": preview, "ext": ext}


# -----------------------------------------------------------------------------
# Starting.

def _invoke(scene, animation):
    """Start Blender's render job for `scene`. Without a window (a background session) the render
    runs to its end here, and what follows it runs as it returns."""
    if bpy.app.background:
        _job["synchronous"] = True
        result = bpy.ops.render.render('EXEC_DEFAULT', animation=animation, scene=scene.name)
        _follow_up()
        return result
    window = bpy.context.window
    if window is None:
        # From a timer, after the frames: the first window runs the job.
        wm = bpy.context.window_manager
        window = wm.windows[0] if wm and wm.windows else None
        if window is None:
            raise RuntimeError("There is no window to render from.")
        with bpy.context.temp_override(window=window, screen=window.screen):
            return bpy.ops.render.render('INVOKE_DEFAULT', animation=animation, scene=scene.name)
    return bpy.ops.render.render('INVOKE_DEFAULT', animation=animation, scene=scene.name)


def _run(scene, animation):
    """Invoke the render; if it does not start, end with the reason."""
    try:
        result = _invoke(scene, animation)
    except RuntimeError as ex:
        _end(state="error", message=str(ex).strip() or "Rendering could not start.")
        return
    if 'RUNNING_MODAL' not in result and 'FINISHED' not in result and _job is not None:
        _end(state="error", message="Rendering could not start.")


def start(context, animation, folder=None, resume=False):
    """Render the image, or the animation when `animation` is true, into `folder` (the iPad's
    folder for this render; a temporary one when not given). With `resume`, the animation in
    `folder` goes on from its first missing frame. Never raises: what goes wrong is the state."""
    global _restore, _display, _job
    if _state.get("state") == "rendering" and _job is not None:
        return  # The iPad shows the render in progress.
    if bpy.app.is_job_running('RENDER'):
        _set_state(state="error", message="Something is already rendering. Wait for it, or stop it.")
        return
    try:
        _start(context, animation, folder, resume)
    except Exception as ex:
        _end(state="error", message=str(ex) or type(ex).__name__)


def _start(context, animation, folder, resume):
    global _restore, _display, _job
    scene = context.scene
    if scene.camera is None and not (scene.render.use_sequencer and scene.sequence_editor and
                                     scene.sequence_editor.strips_all):
        _set_state(state="error", message="Add a camera to the scene to render it.")
        return
    if folder is None:
        folder = os.path.join(bpy.app.tempdir, "Render {:d}".format(_sequence + 1))
    os.makedirs(folder, exist_ok=True)

    plan = frames_plan(scene) if animation else None
    manifest = None
    if animation:
        manifest = _read_manifest(folder) if resume else None
        if resume and manifest is None:
            _set_state(state="error", message="The frames of this render are gone.", folder=folder)
            return
        if manifest is not None:
            if manifest.get("ext") != plan["ext"] or bool(manifest.get("movie")) != plan["movie"]:
                _set_state(state="error", folder=folder, message=(
                    "The scene's Output format changed since these frames were rendered. "
                    "Render the animation again, or set the format back."))
                return
            _drop_unfinished(folder, manifest)
        else:
            manifest = {"version": 1, "frames": {}}
        render = scene.render
        manifest.update(
            scene=scene.name, format=plan["format"], ext=plan["ext"], movie=plan["movie"],
            linear=plan["linear"], wanted=_scene_frames(scene), fps=render.fps / render.fps_base,
            width=int(render.resolution_x * render.resolution_percentage / 100),
            height=int(render.resolution_y * render.resolution_percentage / 100),
        )
        if plan["movie"]:
            manifest["movie_image"] = _snapshot(render.image_settings)
            manifest["movie_ffmpeg"] = _snapshot(render.ffmpeg)
        manifest["view"] = _snapshot(scene.view_settings)
        manifest["display"] = scene.display_settings.display_device
        _write_manifest(folder, manifest)

    _restore = _save_settings(scene)
    _display = context.preferences.view.render_display_type
    # Blender's render window is replaced by the iPad's own progress and result.
    context.preferences.view.render_display_type = 'NONE'
    render = scene.render
    if animation:
        render.filepath = os.path.join(folder, FRAME_PREFIX)
        if plan["frames"]:
            _apply(render.image_settings, plan["frames"])
        render.use_file_extension = True
        # Frames already written are kept, and not rendered again.
        render.use_overwrite = False
        render.use_placeholder = False

    _job = {"folder": folder, "animation": bool(animation), "manifest": manifest, "phase": "frames"}
    done = len(manifest["frames"]) if animation else 0
    _set_state(
        state="rendering",
        animation=bool(animation),
        phase="frames",
        gpu=needs_gpu(scene),
        folder=folder,
        frame=scene.frame_start if animation else scene.frame_current,
        total=len(manifest["wanted"]) if animation else 1,
        done=done,
        resumed=done,
        fps=render.fps / render.fps_base,
        width=int(render.resolution_x * render.resolution_percentage / 100),
        height=int(render.resolution_y * render.resolution_percentage / 100),
    )
    _add_handlers()
    _run(scene, bool(animation))


# -----------------------------------------------------------------------------
# Videos, written by Blender's FFmpeg from frames on disk.

VIDEO_SCENE = ".Render Video"


def _remove_video_scene(job):
    name = job.pop("video_scene", None)
    scene = bpy.data.scenes.get(name) if name else None
    if scene is not None:
        bpy.data.scenes.remove(scene)


def _quick_video(image, ffmpeg):
    """H.264 in MP4, which every Apple device plays."""
    _apply(image, {"media_type": 'VIDEO', "file_format": 'FFMPEG', "color_mode": 'RGB'})
    _apply(ffmpeg, {"format": 'MPEG4', "codec": 'H264', "constant_rate_factor": 'HIGH',
                    "ffmpeg_preset": 'GOOD', "audio_codec": 'NONE'})


def _start_video(folder, manifest, movie):
    """Write the frames listed in `manifest` as a movie: with `movie`, a movie's image and FFmpeg
    settings, else as a quick H.264 one."""
    quick = movie is None
    global _job
    files = _frame_files(folder, manifest)
    if not files:
        _end(state="error", message="There are no frames to make a video of.", animation=True,
             **_frames_summary(folder, manifest))
        return
    if _job is None:
        _job = {"folder": folder, "animation": True, "manifest": manifest}
        global _display
        if _display is None:
            _display = bpy.context.preferences.view.render_display_type
            bpy.context.preferences.view.render_display_type = 'NONE'
    _job.update(phase="video", quick=quick)
    scene = bpy.data.scenes.new(VIDEO_SCENE)
    _job["video_scene"] = scene.name
    editor = scene.sequence_editor_create()
    strip = editor.strips.new_image("Frames", files[0], channel=1, frame_start=1, fit_method='FIT')
    for path in files[1:]:
        strip.elements.append(os.path.basename(path))
    scene.frame_start, scene.frame_end = 1, len(files)
    render = scene.render
    fps = float(manifest.get("fps") or 24.0)
    render.fps, render.fps_base = max(1, round(fps)), max(1, round(fps)) / fps
    width, height = int(manifest.get("width") or 0), int(manifest.get("height") or 0)
    if width <= 0 or height <= 0:
        image = bpy.data.images.load(files[0], check_existing=False)
        width, height = image.size
        bpy.data.images.remove(image)
    # Most codecs need even sizes.
    render.resolution_x, render.resolution_y = max(2, width & ~1), max(2, height & ~1)
    render.resolution_percentage = 100
    # Frames in a display format already hold the scene's look; linear frames get it now.
    if manifest.get("linear"):
        _apply(scene.view_settings, manifest.get("view", {}), first=("view_transform",))
    else:
        scene.view_settings.view_transform = 'Standard'
        scene.view_settings.look = 'None'
        scene.view_settings.exposure = 0.0
        scene.view_settings.gamma = 1.0
        scene.view_settings.use_curve_mapping = False
    try:
        scene.display_settings.display_device = manifest.get("display", "sRGB")
    except TypeError:
        pass
    if quick:
        _quick_video(render.image_settings, render.ffmpeg)
    else:
        # The media type first: setting it resets the movie's settings.
        _apply(render.image_settings, movie[0])
        _apply(render.ffmpeg, movie[1])
    render.use_file_extension = True
    render.use_overwrite = True
    render.filepath = os.path.join(folder, "Quick Video " if quick else "Video ")
    video = render.frame_path(frame=1)
    if os.path.isfile(video):
        os.remove(video)
    _job["video"] = video
    summary = _frames_summary(folder, manifest)
    del summary["frames"]
    _set_state(**dict(
        summary, state="rendering", animation=True, phase="video", folder=folder, gpu=needs_gpu(scene, video=True),
        done=0, total=len(files), resumed=0, quick=bool(quick), fps=fps, width=width, height=height))
    _add_handlers()
    _run(scene, True)


def make_video(context, folder):
    """Make a video of the frames in `folder`: the movie the scene's Output asks for now, when it
    is a movie (so a movie FFmpeg refused can be made again after changing the codec); else the
    movie it asked for when the frames were rendered; else a quick H.264 one."""
    if _state.get("state") == "rendering" and _job is not None:
        return
    if bpy.app.is_job_running('RENDER'):
        _set_state(state="error", message="Something is already rendering. Wait for it, or stop it.")
        return
    try:
        manifest = _read_manifest(folder)
        if manifest is None:
            _set_state(state="error", message="The frames of this render are gone.", folder=folder)
            return
        _drop_unfinished(folder, manifest)
        render = context.scene.render
        if render.image_settings.media_type == 'VIDEO':
            movie = (_snapshot(render.image_settings), _snapshot(render.ffmpeg))
        elif manifest.get("movie"):
            movie = (manifest["movie_image"], manifest["movie_ffmpeg"])
        else:
            movie = None
        _start_video(folder, manifest, movie)
    except Exception as ex:
        _end(state="error", message=str(ex) or type(ex).__name__)


def cancel(_context):
    """Called after the render job is stopped, in case Blender reported no cancellation."""
    if _state.get("state") != "rendering":
        return
    if any(event == "complete" for event, _scene in _pending):
        _follow_up()  # It ended before the stop reached it: keep what it made.
        return
    _pending.clear()
    _cancelled()


def clear(_context):
    """The iPad has shown the result: forget it."""
    if _state.get("state") != "rendering":
        _set_state(state="idle")


def status(_context):
    """The render's state. How far the frame being rendered is (`samples`) is added by the bridge,
    from the render job: `render_stats` handlers hear only the per-frame time in an interactive
    session (ROUND6 BUSY-1, G13)."""
    return _state


# -----------------------------------------------------------------------------
# Viewport options for the iPad's "More" menu.

def _view3d(context):
    space = context.space_data
    if space is not None and space.type == 'VIEW_3D':
        return space
    for area in context.screen.areas if context.screen else ():
        if area.type == 'VIEW_3D':
            return area.spaces.active
    return None


def _xray_owner(space):
    shading = space.shading
    return shading, ("show_xray_wireframe" if shading.type == 'WIREFRAME' else "show_xray")


_TOGGLES = {
    "overlays": lambda space: (space.overlay, "show_overlays"),
    "xray": _xray_owner,
    "gizmos": lambda space: (space, "show_gizmo"),
    "statistics": lambda space: (space.overlay, "show_stats"),
    "wireframe": lambda space: (space.overlay, "show_wireframes"),
    # Navigating moves the camera, keeping the view through it.
    "lock_camera": lambda space: (space, "lock_camera"),
    # Navigating stays in the camera view, without moving the camera.
    "keep_camera_view": lambda space: (space, "keep_camera_view"),
}


def viewport_options(context):
    space = _view3d(context)
    if space is None:
        return None
    result = {}
    for name, owner_and_property in _TOGGLES.items():
        owner, prop = owner_and_property(space)
        result[name] = bool(getattr(owner, prop))
    region = space.region_3d
    result["camera_view"] = region is not None and region.view_perspective == 'CAMERA'
    return result


def viewport_toggle(context, name):
    space = _view3d(context)
    toggle = _TOGGLES.get(name)
    if space is None or toggle is None:
        return
    owner, prop = toggle(space)
    setattr(owner, prop, not getattr(owner, prop))
    for area in context.screen.areas if context.screen else ():
        if area.type == 'VIEW_3D':
            area.tag_redraw()


classes = ()
