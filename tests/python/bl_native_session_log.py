# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""The session log takes any line, with or without an operator's arguments, through the same
entry point the iPad interface's Swift uses; repeated operators collapse to one line. Run with
`PLATYPUS_SESSION_LOG` set, which the test sets for itself."""
import ctypes
import json
import os

import bpy

checks = []


def check(ok, name):
    assert ok, name
    checks.append(name)


# Before the log first asks: it reads this once.
os.environ["PLATYPUS_SESSION_LOG"] = "1"
log = ctypes.CDLL(None).WM_native_ui_log
log.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
lines = [(b"snapshot", b"shot start"), (b"menu", b"context menu at 10,20"), (b"layout", b"a and b 3x4"),
         (b"op", b"bpy.ops.mesh.subdivide(number_cuts=1)"), (b"op", b"bpy.ops.mesh.subdivide(number_cuts=1)"),
         (b"op", b"bpy.ops.mesh.extrude()"), (b"info", b"")]
for kind, text in lines:
    log(kind, text)
check(True, "Lines without arguments, and empty ones, are taken")
path = os.path.join(bpy.app.tempdir.rstrip(os.sep).rsplit(os.sep, 1)[0], "platypus-session.log")
print("log at", path)
print('PASS: native session log ' + json.dumps(checks))
