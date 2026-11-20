# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Blender preferences shown in the native iPad Settings."""

import bpy

__all__ = (
    "keymap_set",
    "addons",
    "keymaps",
    "addon_enable",
    "keymap_item_active",
)

# Keymap presets offered on the iPad, by preset file name.
KEYMAPS = ("Industry_Compatible", "Blender")


def keymap_set(context, name):
    if name not in KEYMAPS:
        return
    if context.window_manager.keyconfigs.active.name == name:
        return
    filepath = bpy.utils.preset_find(name, "keyconfig")
    if not filepath or not bpy.utils.keyconfig_set(filepath):
        return
    # The iPad may end the app without warning: keep the choice now rather than on quit.
    if context.preferences.use_preferences_save:
        bpy.ops.wm.save_userpref()



def addons(context):
    """The add-ons Settings lists, as Blender's Preferences do, with whether each is enabled."""
    import addon_utils
    from bpy.app.translations import pgettext_iface as iface_

    enabled = {addon.module: addon for addon in context.preferences.addons}
    addons = []
    for mod in addon_utils.modules(refresh=False):
        info = addon_utils.module_bl_info(mod)
        addon = enabled.get(mod.__name__)
        preferences = addon.preferences if addon is not None else None
        addons.append({
            "module": mod.__name__,
            "name": iface_(info["name"]),
            "category": iface_(info["category"]),
            "description": iface_(info["description"]),
            "warning": iface_(info["warning"]),
            "enabled": addon is not None,
            # Its own preferences, which `USERPREF_PT_native_addon` draws (ROUND6 PANEL-15).
            "preferences": preferences is not None and hasattr(type(preferences), "draw"),
        })
    addons.sort(key=lambda addon: (addon["category"].casefold(), addon["name"].casefold()))
    return addons


def _keymaps_flat(items, depth, result):
    for name, space_type, region_type, children in items:
        result.append((name, space_type, region_type, depth))
        _keymaps_flat(children, depth + 1, result)


def keymaps(context, search="", expanded=()):
    """
    The user's keymaps in the order Blender's Preferences list them, each with its depth in that
    hierarchy, with the items of those named in ``expanded``; with a ``search``, only the items whose name or keys match are listed, in every keymap that has any.
    """
    from bl_keymap_utils import keymap_hierarchy

    expanded = set(expanded)
    search = search.casefold()
    keyconfig = context.window_manager.keyconfigs.user
    flat = []
    _keymaps_flat(keymap_hierarchy.generate(), 0, flat)
    keymaps = []
    for name, space_type, region_type, depth in flat:
        km = keyconfig.keymaps.find(name, space_type=space_type, region_type=region_type)
        if km is None:
            continue
        entry = {"name": name, "title": km.name, "depth": depth}
        if search or name in expanded:
            items = []
            for kmi in km.active().keymap_items:
                item_name = kmi.name or kmi.idname
                keys = kmi.to_string()
                if search and search not in item_name.casefold() and search not in keys.casefold():
                    continue
                items.append({"id": kmi.id, "name": item_name, "keys": keys, "active": kmi.active})
            if search and not items:
                continue
            entry["items"] = items
        keymaps.append(entry)
    return keymaps


def addon_enable(context, module, enable):
    if enable:
        bpy.ops.preferences.addon_enable(module=module)
    else:
        bpy.ops.preferences.addon_disable(module=module)
    # Saved with the other preferences, see `bridge_preferences_save` in `wm_native_ui.cc`.
    context.preferences.is_dirty = True


def keymap_item_active(context, keymap, item_id, active):
    km = context.window_manager.keyconfigs.user.keymaps.get(keymap)
    kmi = km and km.active().keymap_items.from_id(item_id)
    if kmi is None:
        return
    kmi.active = active
    context.preferences.is_dirty = True


class USERPREF_PT_native_addon(bpy.types.Panel):
    """An add-on's own preferences, as Blender's Add-ons section draws them under it, for the
    native interface's list of add-ons, which has no room for them (ROUND6 PANEL-15). The walker
    sets the module to draw, see `preferences_tabs`."""
    bl_space_type = 'PREFERENCES'
    bl_region_type = 'WINDOW'
    bl_context = "native_addon"
    bl_label = "Preferences"
    bl_options = {'HIDE_HEADER'}

    @classmethod
    def register(cls):
        bpy.types.WindowManager.native_addon_module = bpy.props.StringProperty(
            name="Add-on",
            description="The add-on whose preferences the native interface shows",
            options={'SKIP_SAVE'},
        )

    @classmethod
    def unregister(cls):
        del bpy.types.WindowManager.native_addon_module

    @staticmethod
    def _preferences(context):
        addon = context.preferences.addons.get(context.window_manager.native_addon_module)
        return addon.preferences if addon is not None else None

    def draw(self, context):
        preferences = self._preferences(context)
        draw = getattr(preferences, "draw", None)
        if draw is None:
            self.layout.label(text="This add-on has no preferences")
            return
        # As Blender's Add-ons section draws them (`space_userpref.py`): the class's layout.
        preferences_class = type(preferences)
        preferences_class.layout = self.layout
        try:
            draw(context)
        except Exception:
            import traceback
            traceback.print_exc()
            self.layout.label(text="These preferences could not be drawn", icon='ERROR')
        finally:
            del preferences_class.layout


classes = (USERPREF_PT_native_addon,)
