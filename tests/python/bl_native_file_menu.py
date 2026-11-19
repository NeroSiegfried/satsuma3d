# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""The File menu's housekeeping on the iPad (ROUND6 FILES-7, finding F12).

Every operator Blender's File menu (`TOPBAR_MT_file`, recursively) lists is reached in the iPad
interface, through the shell's File menu or Search, which walks Blender's File menu hiding what
the system menu bar hides (`hidden_from_menu_bar` in `interface_native_menu.cc`). One hidden there
must be in `REPLACED_BY` below, with what takes its place; one in neither fails, as does a
replacement listed for an operator that is reached after all.
"""
import json
import os
import re

import bpy

checks = []


def check(ok, name):
    assert ok, name
    checks.append(name)


ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))

# Operators of Blender's File menu the iPad interface does not show, and what takes their place.
REPLACED_BY = {
    "wm.quit_blender": "the system ends the app; Documents goes back to the documents",
    "wm.save_homefile": "new documents come from the launcher's templates (Save as Template)",
    "wm.read_factory_settings": "documents start from the launcher's templates, never from a reset session",
    "wm.recover_auto_save": "the launcher's Recovered Work (ROUND6 SAFE-5)",
    "wm.previews_batch_generate": "refused by poll: it needs another program (8E)",
    "wm.previews_batch_clear": "refused by poll: it needs another program (8E)",
    "outliner.orphans_manage": "Clean Up › Purge Unused Data; it opens an Outliner window, which the "
                               "iPad interface has no room for (the Desktop Interface has it)",
    "wm.previews_ensure": "Data Previews is hidden with its menu, whose batch commands need another "
                          "program; previews are made as the asset pane shows them",
    "wm.previews_clear": "as wm.previews_ensure",
}


class Layout:
    """Records what a menu's draw function lists; every other call does nothing."""

    def __init__(self, found, path):
        self.found = found
        self.path = path
        self.operator_context = 'INVOKE_DEFAULT'

    def operator(self, idname, text="", **_kwargs):
        self.found.append((idname, tuple(self.path)))
        return Props()

    def menu(self, name, **_kwargs):
        walk(name, self.found, self.path + [name])

    def menu_contents(self, name):
        walk(name, self.found, self.path + [name])

    def __getattr__(self, _name):
        return lambda *args, **kwargs: self

    def __setattr__(self, name, value):
        object.__setattr__(self, name, value)


class Props:
    def __setattr__(self, _name, _value):
        pass

    def __getattr__(self, _name):
        return None


def walk(name, found, path):
    menu = getattr(bpy.types, name, None)
    if menu is None or len(path) > 6:
        return
    for draw in getattr(menu.draw, "_draw_funcs", None) or [menu.draw]:
        holder = type("Holder", (), {"layout": Layout(found, path), "bl_idname": name})()
        try:
            draw(holder, bpy.context)
        except Exception as ex:
            print("menu draw failed:", name, ex)


found = []
walk("TOPBAR_MT_file", found, ["TOPBAR_MT_file"])
check(len(found) > 25, "Blender's File menu was walked (%d items)" % len(found))

with open(os.path.join(ROOT, "source", "blender", "editors", "interface",
                       "interface_native_menu.cc")) as handle:
    menu_source = handle.read()
hidden_source = menu_source[menu_source.index("bool hidden_from_menu_bar"):]
operators_block = hidden_source[:hidden_source.index("static const Set<StringRef> menus")]
menus_block = hidden_source[hidden_source.index("static const Set<StringRef> menus"):]
menus_block = menus_block[:menus_block.index("};")]
hidden_operators = set(re.findall(r'"(\w+_OT_\w+)"', operators_block))
hidden_menus = set(re.findall(r'"(\w+_MT_\w+)"', menus_block))
check("TOPBAR_MT_file" in re.search(r'"TOPBAR_MT_editor_menus", "VIEW3D_MT_editor_menus", "TOPBAR_MT_file"\)',
                                     menu_source).group(0),
      "Blender's File menu, as Search walks it, hides what the menu bar hides")


def blender_name(idname):
    module, name = idname.split(".")
    return module.upper() + "_OT_" + name


unreached = {}
reached = set()
for idname, path in found:
    hidden_by = None
    if blender_name(idname) in hidden_operators:
        hidden_by = blender_name(idname)
    for menu in path:
        if menu in hidden_menus:
            hidden_by = menu
    if hidden_by:
        unreached.setdefault(idname, hidden_by)
    else:
        reached.add(idname)
# An operator listed in a hidden menu and elsewhere too (Open in File and in Open Recent) is reached.
unreached = {idname: by for idname, by in unreached.items() if idname not in reached}
missing = sorted(set(unreached) - set(REPLACED_BY))
check(not missing, "every File menu operator the iPad hides has a replacement: %s"
      % {idname: unreached[idname] for idname in missing})
stale = sorted(set(REPLACED_BY) - set(unreached))
check(not stale, "every replacement listed is for an operator the iPad hides: %s" % stale)
for wanted in ("file.pack_all", "file.unpack_all", "file.make_paths_relative", "file.make_paths_absolute",
               "file.report_missing_files", "file.find_missing_files", "outliner.orphans_purge",
               "wm.revert_mainfile", "wm.link", "wm.append"):
    check(wanted in reached, "%s is reached in the iPad interface" % wanted)

# The shell's File menu shows the housekeeping, and Search walks Blender's File menu.
swift = os.path.join(ROOT, "source", "blender", "windowmanager", "apple_ios", "swift")
with open(os.path.join(swift, "TopBar.swift")) as handle:
    top_bar = handle.read()
file_menu = top_bar[top_bar.index("private var fileMenu: some View"):]
file_menu = file_menu[:file_menu.index("\n  }\n")]
for needed in ("externalDataRoute", "cleanUpRoute", '"WM_OT_revert_mainfile"', '"WM_OT_collection_export_all"',
               '"WM_OT_link"', '"WM_OT_append"'):
    check(needed in file_menu, "the shell's File menu has %s" % needed)
with open(os.path.join(swift, "CommandSearch.swift")) as handle:
    search = handle.read()
check('BlenderMenus.route("TOPBAR_MT_file")' in search, "Search walks Blender's File menu")
can_show = menu_source[menu_source.index("bool menu_can_show"):]
can_show = can_show[:can_show.index("\n}\n")]
for root in ("TOPBAR_MT_file", "TOPBAR_MT_file_external_data", "TOPBAR_MT_file_cleanup"):
    check('"%s"' % root in can_show, "the interface draws %s as a root" % root)

print("FILE MENU reached %d, replaced %d" % (len(reached), len(unreached)))
print("PASS: native file menu " + json.dumps(checks))
