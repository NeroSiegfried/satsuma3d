# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Add-ons for the native iPad interface, installed in-process.

Blender's extensions platform installs packages through a helper process, which iPadOS does not
allow. Here a file the person picked (an extension's `.zip`, or a legacy add-on's `.py` or `.zip`)
is installed with Python alone: an extension into the user repository, a legacy add-on with
Blender's own operator, then enabled. Online repositories stay off: only files the person chose
are installed.

Also turns on the bundled extensions once, on the first launch, so they are there to try; turning
one off afterwards is remembered.
"""

import json
import os
import shutil
import tempfile
import zipfile

import bpy

__all__ = (
    "install",
)

# Bundled in the app's system repository and enabled on the first launch.
BUNDLED = ("looptools",)
_FIRST_RUN_MARKER = "native_bundled_extensions.json"


def _report(message, error=False):
    """Tell the person, with Blender's own report, which the native interface shows."""
    print(("Error: " if error else "") + message)
    if bpy.app.background:
        return
    window_manager = bpy.context.window_manager

    def draw(self, _context):
        self.layout.label(text=message)
    try:
        window_manager.popup_menu(draw, title="Add-on Not Installed" if error else "Add-on Installed",
                                  icon='ERROR' if error else 'CHECKMARK')
    except RuntimeError:
        pass


def _manifest(archive):
    """An extension's manifest, at the archive's top or in its only folder, as `(data, prefix)`."""
    import tomllib
    for name in archive.namelist():
        parts = name.split("/")
        if parts[-1] == "blender_manifest.toml" and len(parts) <= 2:
            return tomllib.loads(archive.read(name).decode("utf-8")), "/".join(parts[:-1])
    return None, ""


def _user_repo():
    for repo in bpy.context.preferences.extensions.repos:
        if repo.module == "user_default":
            return repo
    return None


def _safe_extract(archive, prefix, destination):
    """Extract the archive's files under `prefix` into `destination`, refusing paths leaving it."""
    root = os.path.realpath(destination)
    for info in archive.infolist():
        name = info.filename
        if prefix:
            if not name.startswith(prefix + "/"):
                continue
            name = name[len(prefix) + 1:]
        if not name or name.endswith("/"):
            continue
        target = os.path.realpath(os.path.join(root, name))
        if not target.startswith(root + os.sep):
            raise ValueError("The archive has a file outside its folder: " + info.filename)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with archive.open(info) as source, open(target, "wb") as output:
            shutil.copyfileobj(source, output)


def _install_extension(archive, manifest, prefix):
    if manifest.get("type", "add-on") != "add-on":
        raise ValueError("Only add-on extensions can be installed here, not " + manifest.get("type", ""))
    package = manifest.get("id", "")
    if not package or not package.isidentifier():
        raise ValueError("The extension's manifest has no usable id")
    if any(name.endswith((".so", ".dylib", ".pyd", ".whl")) for name in archive.namelist()):
        raise ValueError("It contains compiled code, which iPadOS only runs when signed into the app")
    repo = _user_repo()
    if repo is None:
        raise ValueError("There is no user repository for extensions")
    directory = repo.directory
    os.makedirs(directory, exist_ok=True)
    destination = os.path.join(directory, package)
    module = "bl_ext.{:s}.{:s}".format(repo.module, package)
    if module in bpy.context.preferences.addons:
        bpy.ops.preferences.addon_disable(module=module)
    staging = tempfile.mkdtemp(prefix=package + "-", dir=directory)
    try:
        _safe_extract(archive, prefix, staging)
        if os.path.exists(destination):
            shutil.rmtree(destination)
        os.rename(staging, destination)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    result = bpy.ops.preferences.addon_enable(module=module)
    if 'FINISHED' not in result:
        raise ValueError("Installed, but it did not turn on: see the console")
    return manifest.get("name", package)


def _install_legacy(path):
    before = set(bpy.context.preferences.addons.keys())
    import addon_utils
    known = {module.__name__ for module in addon_utils.modules(refresh=False)}
    result = bpy.ops.preferences.addon_install(filepath=path, overwrite=True)
    if 'FINISHED' not in result:
        raise ValueError("The add-on could not be installed")
    new = [module.__name__ for module in addon_utils.modules(refresh=True) if module.__name__ not in known]
    if not new:
        # Reinstalled over itself: its name is the file's.
        new = [os.path.splitext(os.path.basename(path))[0]]
    names = []
    for module in new:
        if module not in before and 'FINISHED' in bpy.ops.preferences.addon_enable(module=module):
            names.append(module)
    return ", ".join(names) or new[0]


def install(context, path):
    """Install and enable the add-on at `path`, given as a JSON string: an extension's `.zip`, or a
    legacy add-on's `.py` or `.zip`. Returns its name, or an empty string after reporting why not."""
    path = json.loads(path)
    try:
        if path.lower().endswith(".zip"):
            with zipfile.ZipFile(path) as archive:
                manifest, prefix = _manifest(archive)
                name = _install_extension(archive, manifest, prefix) if manifest else _install_legacy(path)
        elif path.lower().endswith(".py"):
            name = _install_legacy(path)
        else:
            raise ValueError("Choose an add-on's .zip or .py file")
    except (ValueError, OSError, zipfile.BadZipFile, RuntimeError) as ex:
        _report(str(ex), error=True)
        return ""
    bpy.ops.wm.save_userpref()
    _report(name + " is installed and turned on")
    return name


def _enable_bundled_once():
    marker = os.path.join(bpy.utils.user_resource('CONFIG', create=True), _FIRST_RUN_MARKER)
    if os.path.exists(marker):
        return None
    preferences = bpy.context.preferences
    enabled = []
    for package in BUNDLED:
        module = "bl_ext.system." + package
        if module not in preferences.addons:
            try:
                if 'FINISHED' in bpy.ops.preferences.addon_enable(module=module):
                    enabled.append(module)
            except RuntimeError as ex:
                print("Bundled extension", package, "did not turn on:", ex)
    with open(marker, "w", encoding="utf-8") as f:
        json.dump({"enabled": enabled}, f)
    if enabled:
        bpy.ops.wm.save_userpref()
    return None


def register():
    # Not in background runs (tests, command line), which must not change the preferences.
    if not bpy.app.background:
        bpy.app.timers.register(_enable_bundled_once, first_interval=1.0, persistent=False)


def unregister():
    if bpy.app.timers.is_registered(_enable_bundled_once):
        bpy.app.timers.unregister(_enable_bundled_once)


classes = ()
