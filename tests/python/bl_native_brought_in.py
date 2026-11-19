# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""One rule for what is brought in (ROUND6 FILES-5, finding F4, decision R6-14).

A file a data-block reads from outside the document's folder is packed into the document as it
is next written (`bl_ui.native_files.pack_brought_in`, which the iPad's document write runs). For
each way a file comes in that a background session can take (Image › Open, an image loaded by a
script or the Image Editor, an image empty as a dropped picture makes, an OBJ whose material
names a texture, a font), the document is saved, the folder the files came from is removed, and
the document opened again: no data-block may miss its file. A texture beside the document is a
neighbour (FILES-3) and is left as it is. What Blender cannot pack is listed for Share and Save
As's question, and Include External Files packs every packable file.
"""
import json
import os
import shutil
import tempfile

import bpy
from bl_ui import native_files

checks = []


def check(ok, name):
    assert ok, name
    checks.append(name)


ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
root = tempfile.mkdtemp()
outside = os.path.join(root, "Elsewhere")      # Files from another app, a drop, iCloud.
document_folder = os.path.join(root, "Project")
os.makedirs(outside)
os.makedirs(os.path.join(document_folder, "textures"))
document = os.path.join(document_folder, "scene.blend")


def write_png(path, color):
    image = bpy.data.images.new("tmp", 4, 4)
    image.pixels = list(color) * 16
    image.filepath_raw = path
    image.file_format = 'PNG'
    image.save()
    bpy.data.images.remove(image)


bpy.ops.wm.read_factory_settings(use_empty=True)
for name, color in (("opened", (1, 0, 0, 1)), ("loaded", (0, 1, 0, 1)), ("empty", (0, 0, 1, 1)),
                    ("wood", (1, 1, 0, 1))):
    write_png(os.path.join(outside, name + ".png"), color)
write_png(os.path.join(document_folder, "textures", "beside.png"), (1, 1, 1, 1))
with open(os.path.join(outside, "crate.mtl"), "w") as handle:
    handle.write("newmtl Crate\nmap_Kd wood.png\n")
with open(os.path.join(outside, "crate.obj"), "w") as handle:
    handle.write("mtllib crate.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 0 1\n"
                 "usemtl Crate\nf 1/1 2/2 3/3\n")
fonts = bpy.utils.system_resource('DATAFILES', path="fonts")
font_source = next((os.path.join(fonts, f) for f in sorted(os.listdir(fonts))
                    if f.endswith((".ttf", ".otf", ".woff2"))), None) if fonts else None

bpy.ops.wm.save_as_mainfile(filepath=document)
ways = []
bpy.ops.image.open(filepath=os.path.join(outside, "opened.png"))
ways.append("Image › Open")
bpy.data.images.load(os.path.join(outside, "loaded.png"))
ways.append("an image loaded by a script or the Image Editor")
# `object.empty_image_add` needs a 3D View; this is what it makes.
empty = bpy.data.objects.new("Reference", None)
empty.empty_display_type = 'IMAGE'
empty.data = bpy.data.images.load(os.path.join(outside, "empty.png"))
bpy.context.scene.collection.objects.link(empty)
ways.append("an image empty, as a dropped picture makes")
bpy.ops.wm.obj_import(filepath=os.path.join(outside, "crate.obj"))
ways.append("an OBJ whose material names a texture")
if font_source:
    font_copy = os.path.join(outside, os.path.basename(font_source))
    shutil.copy(font_source, font_copy)
    bpy.data.fonts.load(font_copy)
    ways.append("a font")
# Kept in the file as data-blocks in use are.
for id_data in (*bpy.data.images, *bpy.data.fonts):
    id_data.use_fake_user = True
brought = sorted(image.name for image in bpy.data.images) + sorted(font.name for font in bpy.data.fonts)
neighbour = bpy.data.images.load(os.path.join(document_folder, "textures", "beside.png"))
neighbour.filepath = "//textures/beside.png"
neighbour.use_fake_user = True

packed = native_files.pack_brought_in()
check(len(packed) >= 5, "everything brought in from outside is packed: %s" % packed)
check(neighbour.packed_file is None, "a texture beside the document is left as a neighbour")
bpy.ops.wm.save_mainfile()
shutil.rmtree(outside)
bpy.ops.wm.open_mainfile(filepath=document)
present = sorted(image.name for image in bpy.data.images) + sorted(font.name for font in bpy.data.fonts)
check(set(brought) <= set(present), "what was brought in is in the document: %s" % brought)
missing = []
for collection in (bpy.data.images, bpy.data.fonts):
    for id_data in collection:
        if id_data.packed_file is None and id_data.filepath and id_data.filepath != "<builtin>" and \
                not os.path.exists(bpy.path.abspath(id_data.filepath)):
            missing.append(id_data.name)
check(not missing, "after each way in, saved and with the source gone, nothing is missing: %s; ways: %s"
      % (missing, ways))
check(native_files.pack_brought_in() == [], "a second write packs nothing more")

# What a copy sent elsewhere would miss, and Include External Files.
sequence = bpy.data.images.load(os.path.join(document_folder, "textures", "beside.png"),
                                check_existing=False)
sequence.source = 'SEQUENCE'
packable, unpackable = native_files.external_files()
check(packable == ["beside.png"] and unpackable == ["beside.png"],
      "Share lists the neighbour as includable and a sequence as not: %s %s" % (packable, unpackable))
check(native_files.external_summary().startswith("1 1 "), "the summary the document reads")
check(native_files.pack_external() == 1 and native_files.external_files()[0] == [],
      "Include External Files packs every packable file")

# The iPad's document write runs the rule before it writes, and Share and Save As ask.
with open(os.path.join(ROOT, "source", "blender", "windowmanager", "intern",
                       "wm_apple_ios_document.cc")) as handle:
    doc = handle.read()
write = doc[doc.index("static bool wm_document_write("):]
write = write[:write.index("\n}\n")]
check(write.index("WM_apple_ios_document_pack_brought_in(C)") < write.index("wm_file_write("),
      "the document's write packs what was brought in first")
with open(os.path.join(ROOT, "source", "blender", "windowmanager", "apple_ios",
                       "wm_apple_ios_blend_document.mm")) as handle:
    bdoc = handle.read()
now = bdoc[bdoc.index("void wm_apple_ios_document_file_now("):]
now = now[:now.index("static void wm_apple_ios_document_file_now_go(")]
check('@"Include External Files"' in now and "WM_apple_ios_document_pack_external(C)" in now and
      now.count("wm_apple_ios_document_file_now_go(document") == 2,
      "Share and Save As offer Include External Files first")
with open(os.path.join(ROOT, "source", "blender", "windowmanager", "apple_ios", "swift",
                       "FileDrop.swift")) as handle:
    drop = handle.read()
check('path: "Dropped Files"' not in drop and "temporaryDirectory" in drop and '"Brought In"' in drop,
      "drops no longer go to the hidden Dropped Files folder")

shutil.rmtree(root, ignore_errors=True)
print("PASS: native brought in " + json.dumps(checks))
