# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Check the bridge's views on a Mac, without an iPad: run a macOS build of Blender made with
`WITH_NATIVE_UI` (point `FLATBUFFERS_ROOT` at the iOS libraries' FlatBuffers), subscribe to views
through the C API as the shell does, pump the bridge, send commands, and print the report.

Needs FlatBuffers' `flatc` from Blender's libraries and FlatBuffers' Python runtime of the same
version (the `flatbuffers` package), for example:

    python3 mac_bridge_check.py --blender build/bin/Blender.app/Contents/MacOS/Blender \
        --flatc lib/ios_arm64/flatbuffers/bin/flatc --flatbuffers-python /path/with/flatbuffers
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--blender", required=True)
    parser.add_argument("--flatc", required=True)
    parser.add_argument("--flatbuffers-python", required=True,
                        help="A directory holding the `flatbuffers` Python package")
    parser.add_argument("--scenario", default="actions", choices=("actions", "tabs", "menus", "mirror", "reveal", "knife", "precision", "material",
                                 "extensions", "keys", "insets"),
                        help="`actions`: the palette, long press and radial. `tabs`: every Properties tab in every mode")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as directory:
        subprocess.run([args.flatc, "--python", "-o", directory, os.path.join(HERE, "..", "protocol.fbs")],
                       check=True)
        shutil.copytree(os.path.join(args.flatbuffers_python, "flatbuffers"), os.path.join(directory, "flatbuffers"))
        report = os.path.join(directory, "report.json")
        env, extra = dict(os.environ), []
        if args.scenario == "extensions":
            # As the iPad starts the engine (ROUND5 8E.1): offline, with the app's bundled extensions
            # as the system repository, and preferences of its own.
            root = os.path.join(directory, "extensions")
            os.makedirs(root)
            os.symlink(os.path.join(HERE, "..", "..", "..", "..", "..", "release", "ios", "extensions"),
                       os.path.join(root, "system"))
            env["BLENDER_SYSTEM_EXTENSIONS"] = root
            env["BLENDER_USER_RESOURCES"] = os.path.join(directory, "user")
            extra = ["--offline-mode"]
        subprocess.run([args.blender, "--factory-startup", *extra, "--python", os.path.join(HERE, "mac_bridge_harness.py"),
                        "--", directory, report, args.scenario,
                        os.path.join(HERE, "..", "..", "..", "..", "..", "release", "ios", "branding_allowed.txt"),
                        os.path.join(HERE, "..", "..", "..", "..", "..", "release", "ios", "key_stand_ins.txt")],
                       check=True, timeout=300, env=env)
        with open(report) as f:
            result = json.load(f)
    print(json.dumps(result, indent=1))
    return 0 if result.get("status") == "done" else 1


if __name__ == "__main__":
    sys.exit(main())
