# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Every exporter Blender's File > Export menu lists writes a file from the default scene: the
iPad's File menu shows that same menu. Exporters that cannot run on the iPad must say so through
their poll or a report, not fail silently; those found are listed.

R8 F6: what each export left is put through the iPad's rule for "nothing was written"
(`file_select_nothing_written` in `wm_apple_ios_file_mode.hh`, built alone with clang), which the
iPad's picker applies after every write it names: every export that wrote is not flagged, and an
export that returns FINISHED having written nothing (the Grease Pencil PDF export with no stroke in
view) is, with Blender's words for why."""
import json
import os
import shutil
import subprocess
import tempfile
import time

import bpy

checks = []


def check(ok, name):
    assert ok, name
    checks.append(name)


class Layout:
    """Records what a menu's draw function lists; every other call does nothing."""

    def __init__(self, found):
        self.found = found
        self.operator_context = 'INVOKE_DEFAULT'

    def operator(self, idname, text="", **_kwargs):
        self.found.append((idname, text))
        return Props()

    def __getattr__(self, _name):
        return lambda *args, **kwargs: self


class Props:
    def __setattr__(self, _name, _value):
        pass


menu = bpy.types.TOPBAR_MT_file_export
found = []
draws = getattr(menu.draw, "_draw_funcs", None) or [menu.draw]
for draw in draws:
    holder = type("Holder", (), {"layout": Layout(found), "bl_idname": menu.bl_idname})()
    try:
        draw(holder, bpy.context)
    except Exception as ex:
        print("menu draw failed:", draw, ex)
check(len(found) >= 3, "The Export menu lists exporters: %s" % found)

# A Grease Pencil object too, for its exporters, which write nothing without one.
bpy.ops.object.grease_pencil_add(type='STROKE')
bpy.ops.object.select_all(action='SELECT')
# The Grease Pencil exporters size their page from the 3D View: in its camera view, from the
# camera's frame, which needs nothing drawn. Otherwise from where the strokes land in the view
# (`grease_pencil_io.cc`, `prepare_render_params`), which can come out empty (UP-9: 14 of 30 runs
# of the 5.3 tree wrote no PDF).
VIEW_3D = next(area for area in bpy.context.screen.areas if area.type == 'VIEW_3D')
VIEW_3D.spaces.active.region_3d.view_perspective = 'CAMERA'
# Exporters whose extension is chosen by an option rather than `filename_ext`.
EXTENSIONS = {"usd_export": ".usdc", "alembic_export": ".abc"}

folder = tempfile.mkdtemp()
written = []
refused = []
# (exporter, the facts the iPad's picker reads after it, whether nothing was written).
outcomes = []


def written_facts(path, finished, started):
    """`WrittenFacts` as `check_written` (`wm_apple_ios_file.cc`) reads them after a write."""
    exists = os.path.exists(path)
    is_folder = exists and os.path.isdir(path)
    size = os.path.getsize(path) if exists and not is_folder else 0
    beside = os.path.dirname(path)
    folder_written = any(os.path.isfile(os.path.join(beside, f)) and os.path.getsize(os.path.join(beside, f)) > 0
                         and os.path.getmtime(os.path.join(beside, f)) >= started - 1.0
                         for f in os.listdir(beside))
    return {"finished": finished, "exists": exists, "is_folder": is_folder, "size": size,
            "folder_written": folder_written}

for idname, text in found:
    module, name = idname.split(".")
    operator = getattr(getattr(bpy.ops, module), name)
    rna = operator.get_rna_type()
    if "filepath" not in rna.properties:
        continue
    extension = rna.properties["filename_ext"].default if "filename_ext" in rna.properties else ""
    path = os.path.join(folder, name + (extension or EXTENSIONS.get(name, ".out")))
    if not operator.poll():
        refused.append((idname, "poll"))
        continue
    started = time.time()
    try:
        result = operator('EXEC_DEFAULT', filepath=path)
    except RuntimeError as ex:
        refused.append((idname, str(ex).strip()[:120]))
        continue
    target = path if os.path.exists(path) else None
    if target is None:
        # Some write a folder or add their own extension.
        matches = [f for f in os.listdir(folder) if f.startswith(name)]
        target = os.path.join(folder, matches[0]) if matches else None
    ok = target is not None and (os.path.isdir(target) or os.path.getsize(target) > 0)
    check(ok, "%s (%s) writes a file" % (text or idname, idname))
    written.append(idname)
    outcomes.append((idname, written_facts(path, 'FINISHED' in result, started), False))

for row in written:
    print("export: wrote  ", row)
for row in refused:
    print("export: refused", *row)
check("wm.obj_export" in written, "OBJ exports")

# R8 F6: an export that finishes having written nothing. The Grease Pencil PDF export with every
# layer hidden, outside the camera view: no stroke to place, the page size is 0, and it reports
# "Unable to export PDF" as a warning and returns FINISHED (`io_grease_pencil.cc`, `grease_pencil_export_pdf_exec`).
if hasattr(bpy.ops.wm, "grease_pencil_export_pdf"):
    empty_folder = tempfile.mkdtemp()
    pencil = next(ob for ob in bpy.context.scene.objects if ob.type == 'GREASEPENCIL')
    bpy.context.view_layer.objects.active = pencil
    for layer in pencil.data.layers:
        layer.hide = True
    # Outside the camera view, where the page is sized from the strokes.
    VIEW_3D.spaces.active.region_3d.view_perspective = 'PERSP'
    empty_path = os.path.join(empty_folder, "hidden.pdf")
    started = time.time()
    result = bpy.ops.wm.grease_pencil_export_pdf('EXEC_DEFAULT', filepath=empty_path)
    check('FINISHED' in result and not (os.path.exists(empty_path) and os.path.getsize(empty_path) > 0),
          "the PDF export of hidden strokes returns FINISHED and writes nothing (%s)" % result)
    outcomes.append(("wm.grease_pencil_export_pdf of hidden strokes",
                     written_facts(empty_path, True, started), True))
    for layer in pencil.data.layers:
        layer.hide = False
    shutil.rmtree(empty_folder)

# The iPad's rule over every outcome, and the words it says for the empty one.
HEADER = os.path.join(os.path.dirname(__file__), "..", "..", "source", "blender", "windowmanager", "intern",
                      "wm_apple_ios_file_mode.hh")
compiler = shutil.which("clang++") or shutil.which("c++")
check(compiler is not None, "a C++ compiler builds the rule")
driver = ['#include "%s"' % os.path.abspath(HEADER), "#include <cstdio>",
          "using namespace blender::wm::apple_ios;", "int main() {"]
for _label, facts, _empty in outcomes:
    driver.append('  { WrittenFacts f{%s, %s, %s, %dull, %s}; '
                  'puts(file_select_nothing_written(f) ? "empty" : "written"); }'
                  % tuple(["true" if facts[k] else "false" for k in ("finished", "exists", "is_folder")] +
                          [facts["size"], "true" if facts["folder_written"] else "false"]))
driver.append('  puts(file_select_nothing_written_message("hidden.pdf", "Unable to export PDF").c_str());')
driver.append('  puts(file_select_nothing_written_message("hidden.pdf", "").c_str());')
driver += ["  return 0;", "}"]
with tempfile.TemporaryDirectory() as directory:
    source = os.path.join(directory, "rule.cc")
    binary = os.path.join(directory, "rule")
    with open(source, "w") as handle:
        handle.write("\n".join(driver))
    subprocess.run([compiler, "-std=c++17", "-o", binary, source], check=True)
    answers = subprocess.run([binary], check=True, capture_output=True, text=True).stdout.splitlines()
wrong = ["%s: %s" % (label, answer) for (label, _facts, empty), answer in zip(outcomes, answers)
         if answer != ("empty" if empty else "written")]
check(len(answers) == len(outcomes) + 2 and not wrong,
      "the iPad's rule tells each export that wrote from one that wrote nothing: %s" % wrong)
check(any(empty for _l, _f, empty in outcomes) or not hasattr(bpy.ops.wm, "grease_pencil_export_pdf"),
      "the rule met an export that wrote nothing")
check(answers[-2] == 'Nothing was written to "hidden.pdf". Unable to export PDF.' and
      answers[-1] == 'Nothing was written to "hidden.pdf". The export gave no reason.',
      "the person is told nothing was written, in Blender's words for why: %s" % answers[-2:])
print('PASS: native export ' + json.dumps(checks))
