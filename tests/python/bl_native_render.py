# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""The iPad's renders (`bl_ui.native_render`) keep what they make and honour the scene's Output
(ROUND6 BUSY-3, G5, F10, D3, D22).

- Every media type and file format, a still and an animation through the native path: it starts,
  ends "done", restores every setting it changed, and the file it delivers is what its extension
  and the scene's setting say (magic bytes). Every movie container likewise.
- The rows of G5's table that a background session can run: a finished animation keeps its frames
  (image formats) or writes the movie with FFmpeg (movie formats); frames left by a render that
  stopped, or one that was killed while writing a frame, are continued from the first missing
  frame, not rendered again; a video can be made of any frames; failures say why and keep the
  frames. Stop during a running render is the harness scenario `render` (it needs a window).

A background session has no window, so the render runs to its end inside `start`.
"""
import json
import os
import shutil
import tempfile

import bpy
from bl_ui import native_render

checks = []


def check(ok, name):
    assert ok, name
    checks.append(name)


IMAGE_MAGIC = {
    ".png": [(0, b"\x89PNG")],
    ".jpg": [(0, b"\xff\xd8\xff")],
    ".bmp": [(0, b"BM")],
    ".rgb": [(0, b"\x01\xda")],
    ".jp2": [(0, b"\x00\x00\x00\x0cjP  ")],
    ".j2c": [(0, b"\xff\x4f\xff\x51")],
    ".cin": [(0, b"\x80\x2a\x5f\xd7")],
    ".dpx": [(0, b"SDPX"), (0, b"XPDS")],
    ".exr": [(0, b"\x76\x2f\x31\x01")],
    ".hdr": [(0, b"#?")],
    ".tif": [(0, b"II*\x00"), (0, b"MM\x00*")],
    ".webp": [(0, b"RIFF")],
    ".avif": [(4, b"ftyp")],
}
# Targa has no signature: its third byte is the image type (2, 3, 10 or 11 for what Blender writes).
TARGA_TYPES = {2, 3, 10, 11}

# FFmpeg's containers: the extensions Blender gives them and their signatures.
MOVIE_MAGIC = {
    'MPEG4': ([".mp4"], [(4, b"ftyp")]),
    'QUICKTIME': ([".mov"], [(4, b"ftyp"), (4, b"wide"), (4, b"mdat"), (4, b"moov")]),
    'MKV': ([".mkv"], [(0, b"\x1a\x45\xdf\xa3")]),
    'WEBM': ([".webm"], [(0, b"\x1a\x45\xdf\xa3")]),
    'AVI': ([".avi"], [(8, b"AVI ")]),
    'FLASH': ([".flv"], [(0, b"FLV")]),
    'MPEG1': ([".mpg"], [(0, b"\x00\x00\x01\xba"), (0, b"\x00\x00\x01\xb3")]),
    'MPEG2': ([".mpg", ".dvd", ".vob"], [(0, b"\x00\x00\x01\xba"), (0, b"\x00\x00\x01\xb3")]),
    'OGG': ([".ogv", ".ogg"], [(0, b"OggS")]),
    'DV': ([".dv"], [(0, b"\x1f\x07\x00")]),
}


def matches(path, signatures):
    with open(path, "rb") as f:
        head = f.read(16)
    return any(head[offset:offset + len(magic)] == magic for offset, magic in signatures)


def image_ok(path):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".tga":
        with open(path, "rb") as f:
            return f.read(3)[2] in TARGA_TYPES
    return ext in IMAGE_MAGIC and matches(path, IMAGE_MAGIC[ext])


def settings(scene):
    render = scene.render
    return (render.filepath, render.use_file_extension, render.use_overwrite, render.use_placeholder,
            json.dumps(native_render._snapshot(render.image_settings), sort_keys=True),
            json.dumps(native_render._snapshot(render.ffmpeg), sort_keys=True),
            bpy.context.preferences.view.render_display_type)


def run(verb, folder=None, **kwargs):
    """Run one of the bridge's commands as the iPad sends it; return the state it ends in."""
    native_render.clear(bpy.context)
    if verb == "video":
        native_render.make_video(bpy.context, folder)
    else:
        native_render.start(bpy.context, verb != "image", folder, verb == "continue")
    state = dict(native_render.status(bpy.context))
    check(state.get("state") in {"done", "error", "cancelled"}, "a background render ends inside start (%s)" % verb)
    return state


scene = bpy.context.scene
scene.render.engine = 'BLENDER_WORKBENCH'
scene.render.resolution_x, scene.render.resolution_y, scene.render.resolution_percentage = 64, 36, 100
scene.render.fps, scene.render.fps_base = 25, 1.0
scene.render.filepath = "//my output/"
root = tempfile.mkdtemp(prefix="native render ")


def folder(name):
    path = os.path.join(root, name)
    os.makedirs(path, exist_ok=True)
    return path


# -----------------------------------------------------------------------------
# Every media type and file format, through the native path (F10, D22).

image = scene.render.image_settings
formats = []
for media in [item.identifier for item in image.bl_rna.properties['media_type'].enum_items]:
    image.media_type = media
    if media == 'VIDEO':
        formats.append((media, 'FFMPEG'))
        continue
    for item in image.bl_rna.properties['file_format'].enum_items:
        try:
            image.file_format = item.identifier  # The formats the media type offers.
        except TypeError:
            continue
        formats.append((media, item.identifier))

seen = []
for media, file_format in formats:
    image.media_type = media
    image.file_format = file_format
    scene.frame_start, scene.frame_end = 1, 2
    before = settings(scene)
    expected_ext = scene.render.file_extension if media != 'VIDEO' else ".png"

    still = run("image", folder("still %s %s" % (media, file_format)))
    check(still["state"] == "done", "%s %s: a still renders (%s)" % (media, file_format, still.get("message")))
    check(settings(scene) == before, "%s %s: a still leaves every setting as it was" % (media, file_format))
    path = still["image"]
    check(os.path.basename(path) == "Render" + expected_ext and image_ok(path),
          "%s %s: a still is named by what it is (%s)" % (media, file_format, os.path.basename(path)))
    shown = still.get("preview") or path
    check(os.path.splitext(shown)[1].lower() in native_render.SHOWN_AS_IS and image_ok(shown),
          "%s %s: a still has an image the iPad shows" % (media, file_format))

    animation = run("animation", folder("animation %s %s" % (media, file_format)))
    check(animation["state"] == "done",
          "%s %s: an animation renders (%s)" % (media, file_format, animation.get("message")))
    check(settings(scene) == before, "%s %s: an animation leaves every setting as it was" % (media, file_format))
    frames = animation["frames"]
    check(len(frames) == 2 and all(os.path.splitext(f)[1] == expected_ext and image_ok(f) for f in frames),
          "%s %s: the frames are kept, in the scene's format" % (media, file_format))
    if media == 'VIDEO':
        exts, signatures = MOVIE_MAGIC[scene.render.ffmpeg.format]
        video = animation["video"]
        check(os.path.splitext(video)[1] in exts and matches(video, signatures),
              "VIDEO: the scene's movie is written with FFmpeg (%s)" % os.path.basename(video))
    else:
        check(animation["video"] == "", "%s %s: an image format makes no video by itself" % (media, file_format))
    seen.append(file_format)
check(len(seen) >= 14, "every file format was rendered: %s" % seen)

# Every movie container, each with a codec it takes (G5's "any FFmpeg container/codec"), and the four
# codecs the iPad's FFmpeg is built with for MP4 and Matroska.
image.media_type = 'VIDEO'
CODEC_FOR = {'WEBM': 'WEBM', 'OGG': 'THEORA', 'FLASH': 'FLASH', 'DV': 'DV', 'MPEG1': 'MPEG1', 'MPEG2': 'MPEG2'}
containers = [item.identifier for item in scene.render.ffmpeg.bl_rna.properties['format'].enum_items]
movies = [(container, CODEC_FOR.get(container, 'H264')) for container in containers]
movies += [('MPEG4', 'H265'), ('MKV', 'AV1'), ('MKV', 'WEBM')]
for container, codec in movies:
    scene.render.ffmpeg.format = container
    scene.render.ffmpeg.codec = codec
    if container == 'DV':
        # DV holds PAL or NTSC frames only, on desktop too.
        scene.render.resolution_x, scene.render.resolution_y = 720, 576
    elif codec == 'AV1':
        # AV1's encoder needs a frame larger than its tiles, on desktop too.
        scene.render.resolution_x, scene.render.resolution_y = 256, 144
    before = settings(scene)
    state = run("animation", folder("movie %s %s" % (container, codec)))
    exts, signatures = MOVIE_MAGIC[container]
    video = state.get("video", "")
    check(state["state"] == "done" and os.path.splitext(video)[1] in exts and matches(video, signatures),
          "%s %s: the movie is the scene's container and codec (%s %s)" % (
              container, codec, os.path.basename(video), state.get("message")))
    check(settings(scene) == before, "%s %s: every setting as it was" % (container, codec))
    scene.render.resolution_x, scene.render.resolution_y = 64, 36

# The movie cannot be written (a codec its container does not take, as desktop refuses too): the
# reason is the state, and the frames are kept.
scene.render.ffmpeg.format, scene.render.ffmpeg.codec = 'WEBM', 'H264'
before = settings(scene)
refused = run("animation", folder("movie refused"))
check(refused["state"] == "error" and "codec" in refused["message"] and len(refused["frames"]) == 2 and
      all(image_ok(f) for f in refused["frames"]) and settings(scene) == before,
      "a movie FFmpeg refuses says why and keeps the frames (%s)" % refused.get("message"))

# -----------------------------------------------------------------------------
# G5's rows: what is kept, and what a second start does.

image.media_type = 'IMAGE'
image.file_format = 'PNG'
written = []


def count_written(*_args):
    written.append(bpy.context.scene.frame_current)


bpy.app.handlers.render_write.append(count_written)

# Stopped at frame 3 of 6 (the frames written before the stop are what the manifest lists).
kept = folder("stopped")
scene.frame_start, scene.frame_end = 1, 3
first = run("animation", kept)
scene.frame_end = 6
manifest = native_render._read_manifest(kept)
check(first["state"] == "done" and sorted(manifest["frames"], key=int) == ["1", "2", "3"],
      "frames finished before a stop are listed in the render's folder")

# Killed while writing frame 5: a file the manifest does not list, and an empty placeholder.
with open(os.path.join(kept, "Frame 0005.png"), "wb") as f:
    f.write(b"\x89PNG half")
open(os.path.join(kept, "Frame 0004.png"), "wb").close()
del written[:]
resumed = run("continue", kept)
check(resumed["state"] == "done" and sorted(written) == [4, 5, 6] and resumed["done"] == 6 and
      all(image_ok(f) for f in resumed["frames"]),
      "Continue renders only the missing frames, and redoes one a kill left half written: %s" % written)
del written[:]
again = run("continue", kept)
check(again["state"] == "done" and written == [] and again["done"] == 6,
      "Continue with nothing missing renders nothing and keeps all %d frames" % again["done"])

# A video of the frames, the quick H.264 one (R6-11: an extra).
quick = run("video", kept)
check(quick["state"] == "done" and quick["video"].endswith(".mp4") and matches(quick["video"], MOVIE_MAGIC['MPEG4'][1]),
      "a quick H.264 video is made of the kept frames (%s)" % quick.get("message"))
check(all(os.path.isfile(f) for f in quick["frames"]), "making a video keeps the frames")

# A video of fewer frames than wanted: "Make Video of 3 Frames" after a stop.
partial = folder("partial")
scene.frame_end = 3
run("animation", partial)
manifest = native_render._read_manifest(partial)
manifest["wanted"] = list(range(1, 7))
native_render._write_manifest(partial, manifest)
summary = native_render._frames_summary(partial, manifest)
check(summary["done"] == 3 and summary["total"] == 6 and summary["next"] == 4,
      "a stopped render says how many frames it has and where it goes on")
short = run("video", partial)
check(short["state"] == "done" and matches(short["video"], MOVIE_MAGIC['MPEG4'][1]),
      "a video is made of the frames a stopped render has")

# A movie scene stopped part way: its video is the scene's movie, not the quick one.
image.media_type = 'VIDEO'
scene.render.ffmpeg.format = 'MKV'
movie = folder("movie stopped")
run("animation", movie)
check(native_render._read_manifest(movie)["movie"], "a movie scene's frames remember the movie they are for")
movie_again = run("video", movie)
check(movie_again["state"] == "done" and movie_again["video"].endswith(".mkv") and not movie_again["quick"],
      "Make Video of a movie scene's frames writes the scene's movie")

# The movie FFmpeg refused is made once the codec is changed: Make Video uses the scene's movie now.
scene.render.ffmpeg.format, scene.render.ffmpeg.codec = 'MKV', 'H264'
image.media_type = 'VIDEO'
retried = run("video", refused["folder"])
check(retried["state"] == "done" and retried["video"].endswith(".mkv") and
      matches(retried["video"], MOVIE_MAGIC['MKV'][1]),
      "Make Video after changing the codec writes the movie a refused one could not")

# The format changed between the stop and Continue: said, nothing rendered, nothing changed.
image.media_type = 'IMAGE'
image.file_format = 'JPEG'
before = settings(scene)
del written[:]
changed = run("continue", kept)
check(changed["state"] == "error" and "format changed" in changed["message"] and written == [] and
      settings(scene) == before, "Continue after the format changed says so and renders nothing")

# Frames that are gone: said, not a silent nothing.
gone = folder("gone")
shutil.rmtree(gone)
check(run("continue", gone)["state"] == "error", "Continue with no frames left says so")
empty = folder("empty")
native_render._write_manifest(empty, {"version": 1, "frames": {}, "wanted": [1, 2]})
failed = run("video", empty)
check(failed["state"] == "error" and failed["message"], "a video of no frames says why")

# Rendering cannot start: settings are restored and the reason is the state (D22).
camera = scene.camera
scene.camera = None
before = settings(scene)
refused = run("animation", folder("no camera"))
check(refused["state"] == "error" and "camera" in refused["message"] and settings(scene) == before,
      "an animation that cannot start says why and changes nothing")
scene.camera = camera

# The temporary scene a video is written from is gone afterwards.
check(native_render.VIDEO_SCENE not in bpy.data.scenes, "the video's scene is removed after the video")

bpy.app.handlers.render_write.remove(count_written)
shutil.rmtree(root, ignore_errors=True)
print("PASS: native render " + json.dumps(checks))
