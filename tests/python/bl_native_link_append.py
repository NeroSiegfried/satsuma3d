# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Link and Append through the iPad's list (ROUND6 FILES-4, finding F9), `bl_ui.native_files`.

- The list names each data-block type as Blender's library paths do: every `IDTypeInfo`'s
  `name_plural` the library loader lists is mapped to its `name`, or left out with why.
- A `.blend` with objects, a material, a node group and a collection is listed by type; appending
  an object, linking a material, appending a node group and relocating a linked material each go
  through Blender's own operator and leave what desktop leaves.
- The operator reads a path that browses inside the `.blend` ("lib.blend/Object/") as the file.
"""
import json
import os
import re
import shutil
import tempfile

import bpy
from bl_ui import native_files

checks = []


def check(ok, name):
    assert ok, name
    checks.append(name)


ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))

# Blender's own pairs, from blenkernel.
pairs = {}
intern = os.path.join(ROOT, "source", "blender", "blenkernel", "intern")
for name in os.listdir(intern):
    if name.endswith(".cc"):
        with open(os.path.join(intern, name), encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        if "IDTypeInfo IDType_" not in text:
            continue
        for type_name, plural in re.findall(
                r'/\*name\*/ "(\w+)",\s*/\*name_plural\*/ (?:N_\()?"(\w+)"', text):
            pairs[plural] = type_name
check(len(pairs) >= 35, "blenkernel's data-block types were read (%d)" % len(pairs))
wrong = {plural: (name, pairs.get(plural)) for plural, name in native_files.ID_TYPE_NAMES.items()
         if pairs.get(plural) != name}
check(not wrong, "every type the list shows has Blender's library name: %s" % wrong)
unplaced = sorted(set(pairs) - set(native_files.ID_TYPE_NAMES) - native_files.NOT_LISTED)
check(not unplaced, "every data-block type is listed or left out with why: %s" % unplaced)

# A library to bring things in from.
root = tempfile.mkdtemp()
library = os.path.join(root, "lib.blend")
bpy.ops.wm.read_factory_settings(use_empty=True)
material = bpy.data.materials.new("Wood")
mesh = bpy.data.meshes.new("Plank")
plank = bpy.data.objects.new("Plank", mesh)
plank.data.materials.append(material)
bpy.context.scene.collection.objects.link(plank)
bpy.data.objects.new("Lamp Post", None)
bpy.data.node_groups.new("Rust", 'ShaderNodeTree').use_fake_user = True
bpy.data.materials.new("Stone").use_fake_user = True
group = bpy.data.collections.new("Props")
bpy.context.scene.collection.children.link(group)
bpy.ops.wm.save_as_mainfile(filepath=library)

bpy.ops.wm.read_factory_settings(use_empty=True)
held = native_files.listing(library)
check(held.get("objects") == ["Lamp Post", "Plank"] or held.get("objects") == ["Plank"],
      "the file's objects are listed: %s" % held.get("objects"))
check(held.get("materials") == ["Stone", "Wood"], "its materials are listed: %s" % held.get("materials"))
check("node_groups" in held and "collections" in held and "screens" not in held,
      "node groups and collections are listed, its screens are not: %s" % sorted(held))
check(native_files.library_path(library + "/Object/") == library and
      native_files.library_path(library) == library, "a path inside the .blend reads as the file")

result = native_files.run(library, 'APPEND', "objects", ["Plank"],
                          {"autoselect": True, "active_collection": True})
check(result == {'FINISHED'} and "Plank" in bpy.data.objects and not bpy.data.objects["Plank"].library,
      "Append brings an object in as this file's")
check("Wood" in bpy.data.materials, "its material comes with it")
result = native_files.run(library, 'LINK', "materials", ["Stone"])
check(result == {'FINISHED'} and bpy.data.materials["Stone", library].library is not None,
      "Link brings a material in as the library's")
result = native_files.run(library, 'APPEND', "node_groups", ["Rust"], {"do_reuse_local_id": True})
check(result == {'FINISHED'} and "Rust" in bpy.data.node_groups, "a node group is appended")

# Relocate a linked material to another of the library's.
linked = bpy.data.materials["Stone", library]
uid = linked.session_uid
found, plural = native_files.id_by_session_uid(uid)
check(found == linked and plural == "materials", "a linked data-block is found by its session id")
plank_material = bpy.data.objects["Plank"].material_slots[0]
plank_material.link = 'OBJECT'
plank_material.material = linked
result = native_files.run(library, 'RELOCATE', "materials", ["Wood"], {}, uid)
check(result == {'FINISHED'} and bpy.data.objects["Plank"].material_slots[0].material.name == "Wood",
      "relocating puts the chosen data-block in its place: %s" %
      bpy.data.objects["Plank"].material_slots[0].material)

# The operator itself: listing then the list's answer (a background session has no dialog).
check(bpy.ops.wm.native_link_append.poll(), "the operator runs here")
shutil.rmtree(root, ignore_errors=True)
print("PASS: native link append " + json.dumps(checks))
