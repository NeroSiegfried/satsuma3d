# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Every exporter Blender's File > Export menu lists writes a file from the default scene: the
iPad's File menu shows that same menu. Exporters that cannot run on the iPad must say so through
their poll or a report, not fail silently; those found are listed."""
import json
import os
import tempfile

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
# Exporters whose extension is chosen by an option rather than `filename_ext`.
EXTENSIONS = {"usd_export": ".usdc", "alembic_export": ".abc"}

folder = tempfile.mkdtemp()
written = []
refused = []
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
    try:
        operator('EXEC_DEFAULT', filepath=path)
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

for row in written:
    print("export: wrote  ", row)
for row in refused:
    print("export: refused", *row)
check("wm.obj_export" in written, "OBJ exports")
print('PASS: native export ' + json.dumps(checks))
