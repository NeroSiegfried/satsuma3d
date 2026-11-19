# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""What the iPad's system picker asks each file selector (ROUND6 FILES-1, finding F7).

Every operator type of this build with a `filepath` or `directory` property, C++ and Python, is
put through the iPad's rule (`file_select_kind` in `wm_apple_ios_file_mode.hh`, built alone with
clang) with its properties as they stand when its selector opens, and the answer is compared with
what the operator means:

- an operator declared through `WM_operator_properties_filesel` or `ExportHelper` has a
  `check_existing` whose default is Blender's own word (`FILE_SAVE` writes, `FILE_OPENFILE` reads);
- `buttons.file_browse` is run for the four paths it can be given (an output path naming a folder,
  an output path naming a folder and a name, an input path, a typed choice of the caller);
- every other operator is listed below with its meaning, or as not opening a selector at all.
  An operator in none of these fails: a new one has to be placed.
"""
import inspect
import json
import os
import shutil
import subprocess
import tempfile

import bpy

checks = []


def check(ok, name):
    assert ok, name
    checks.append(name)


ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
HEADER = os.path.join(ROOT, "source", "blender", "windowmanager", "intern",
                      "wm_apple_ios_file_mode.hh")

# Operators with file properties and no `check_existing`: what each means. "none": it never opens a
# file selector (its path is given by a drop, a caller or a preset menu).
WITHOUT_CHECK_EXISTING = {
    # Writes a file the person names (F7's three).
    "anim.keying_set_export": "save",
    "preferences.keyconfig_export": "save",
    "wm.sysinfo": "save",
    # Reads files.
    "extensions.package_install_files": "open",
    "image.import_as_mesh_planes": "open",
    "image.open_images": "open",
    "import_anim.bvh": "open",
    "import_curve.svg": "open",
    "import_scene.fbx": "open",
    "import_scene.gltf": "open",
    "node.add_import_node": "none",
    "preferences.addon_install": "open",
    "preferences.app_template_install": "open",
    "preferences.keyconfig_import": "open",
    "preferences.studiolight_install": "open",
    "preferences.theme_install": "open",
    "scene.freestyle_module_open": "open",
    "wm.previews_batch_clear": "open",
    "wm.previews_batch_generate": "open",
    # Folders.
    "preferences.script_directory_add": "directory",
    # Never a selector.
    "file.directory_new": "none",
    "file.filepath_drop": "none",
    "image.external_edit": "none",
    "object.bake": "none",
    "paint.image_from_view": "none",
    "preferences.keyconfig_activate": "none",
    "script.execute_preset": "none",
    "script.python_file_run": "none",
    "text.jump_to_file_at_point": "none",
    "view3d.camera_background_image_add": "none",
    "wm.drop_blend_file": "none",
    "wm.drop_import_file": "none",
    "wm.path_open": "none",
    "wm.read_homefile": "none",
    "workspace.append_activate": "none",
}

# Declared through `WM_operator_properties_filesel`, yet Blender's default for `check_existing` is
# not the operator's meaning (none known today).
DECLARED_OTHERWISE = {}


def facts_of(idname, rna):
    props = rna.properties
    keys = set(props.keys())
    blenlib = ("filter_blenlib" in keys and props["filter_blenlib"].default) or (
        "filemode" in keys and props["filemode"].default == 1)  # FILE_LOADLIB
    filepath = props["filepath"].default if "filepath" in keys else ""
    return {
        "filepath": "filepath" in keys,
        "directory": "directory" in keys,
        "filename": "filename" in keys,
        "files": "files" in keys,
        "has_check_existing": "check_existing" in keys,
        "check_existing": "check_existing" in keys and props["check_existing"].default,
        "blenlib": bool(blenlib),
        "output_path": False,
        "path_is_folder": filepath.endswith("/") or not filepath,
        "name": rna.name,
    }


def meaning_declared(facts):
    """What Blender's own declaration says the operator does."""
    if facts["blenlib"]:
        return "library"
    if not facts["filepath"] and not facts["filename"] and not facts["files"]:
        return "directory"
    return "save" if facts["check_existing"] else "open"


rows = []  # (label, facts, expected)
python_ops = 0
for module_name in dir(bpy.ops):
    module = getattr(bpy.ops, module_name)
    for op_name in dir(module):
        try:
            rna = getattr(module, op_name).get_rna_type()
        except (AttributeError, KeyError):
            continue
        keys = set(rna.properties.keys())
        if not {"filepath", "directory"} & keys:
            continue
        idname = "%s.%s" % (module_name, op_name)
        cls = bpy.types.Operator.bl_rna_get_subclass_py(rna.identifier)
        python_ops += cls is not None
        facts = facts_of(idname, rna)
        if idname == "buttons.file_browse":
            # Its invoke sets `check_existing` to "the property is an output path".
            for label, output, folder, expected in (
                    ("render output //render/", True, True, "directory"),
                    ("render output //render/frame_", True, False, "save"),
                    ("an image path", False, False, "open"),
            ):
                row = dict(facts, check_existing=output, output_path=output, path_is_folder=folder)
                rows.append(("buttons.file_browse (%s)" % label, row, expected))
            continue
        if idname in DECLARED_OTHERWISE:
            expected = DECLARED_OTHERWISE[idname]
        elif facts["has_check_existing"]:
            expected = meaning_declared(facts)
        else:
            assert idname in WITHOUT_CHECK_EXISTING, (
                "%s has file properties and no check_existing: say what it means" % idname)
            expected = WITHOUT_CHECK_EXISTING[idname]
            if cls is not None and expected == "none":
                source = inspect.getsource(cls)
                assert "fileselect_add" not in source, (
                    "%s is listed as never opening a selector, yet calls fileselect_add" % idname)
            if expected == "none":
                continue
        rows.append((idname, facts, expected))

stale = sorted(set(WITHOUT_CHECK_EXISTING) - {label.split(" ")[0] for label, _f, _e in rows}
               - {k for k, v in WITHOUT_CHECK_EXISTING.items() if v == "none"})
check(not stale, "the table lists operators this build has: %s" % stale)
check(len(rows) > 60 and python_ops >= 20,
      "the sweep saw the class (%d selectors, %d Python operators)" % (len(rows), python_ops))

# Run the iPad's rule over every row.
KIND = {"Browser": "browser", "Library": "library", "Open": "open", "Save": "save",
        "Directory": "directory"}
compiler = shutil.which("clang++") or shutil.which("c++")
check(compiler is not None, "a C++ compiler builds the rule")
driver = ['#include "%s"' % HEADER, "#include <cstdio>",
          "using namespace blender::wm::apple_ios;",
          "static const char *name(FileSelectKind k) { switch (k) {"]
driver += ['  case FileSelectKind::%s: return "%s";' % (k, v) for k, v in KIND.items()]
driver += ["  } return \"?\"; }", "int main() {"]
for label, facts, _expected in rows:
    fields = ", ".join("true" if facts[k] else "false" for k in (
        "filepath", "directory", "filename", "files", "has_check_existing", "check_existing",
        "blenlib", "output_path", "path_is_folder"))
    driver.append('  { FileSelectFacts f{%s, %s}; printf("%%s\\n", name(file_select_kind(f))); }'
                  % (fields, json.dumps(facts["name"])))
driver += ["  return 0;", "}"]
with tempfile.TemporaryDirectory() as directory:
    source = os.path.join(directory, "rule.cc")
    binary = os.path.join(directory, "rule")
    with open(source, "w") as handle:
        handle.write("\n".join(driver))
    subprocess.run([compiler, "-std=c++17", "-o", binary, source], check=True)
    answers = subprocess.run([binary], check=True, capture_output=True,
                             text=True).stdout.split()

check(len(answers) == len(rows), "the rule answered every row")
wrong = []
for (label, _facts, expected), answer in zip(rows, answers):
    if answer != expected:
        wrong.append("%s: asks %s, means %s" % (label, answer, expected))
check(not wrong, "the picker asks what each operator means:\n  " + "\n  ".join(wrong))

table = {}
for (label, _facts, expected) in rows:
    table[expected] = table.get(expected, 0) + 1
print("FILE MODES " + json.dumps(table, sort_keys=True))
print("PASS: native file modes " + json.dumps(checks))
