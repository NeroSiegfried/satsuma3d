# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Compile the generated Kotlin code with a shell's use of it, `kotlin/ViewsCheck.kt`, and run it.

Needs `kotlinc`, a JDK, and the source of FlatBuffers of the version in `extern/flatbuffers`, for its
Java runtime, which the Kotlin code uses:

    python3 kotlin_check.py --flatbuffers /path/to/flatbuffers
"""

import argparse
import glob
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GENERATED = os.path.join(HERE, "..", "generated", "kotlin")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--flatbuffers", required=True, help="FlatBuffers' source folder")
    parser.add_argument("--kotlinc", default=shutil.which("kotlinc") or "kotlinc")
    args = parser.parse_args()
    runtime = glob.glob(os.path.join(args.flatbuffers, "java", "src", "main", "java", "com", "google",
                                     "flatbuffers", "*.java"))
    if not runtime:
        sys.exit("No FlatBuffers Java runtime in " + args.flatbuffers)
    with tempfile.TemporaryDirectory() as build:
        classes = os.path.join(build, "classes")
        subprocess.run(["javac", "-nowarn", "-d", classes, *runtime], check=True)
        sources = glob.glob(os.path.join(GENERATED, "**", "*.kt"), recursive=True)
        jar = os.path.join(build, "check.jar")
        subprocess.run([args.kotlinc, "-nowarn", "-cp", classes, "-include-runtime", "-d", jar,
                        *sources, os.path.join(HERE, "kotlin", "ViewsCheck.kt")], check=True)
        subprocess.run(["java", "-cp", jar + os.pathsep + classes, "ViewsCheckKt"], check=True)


if __name__ == "__main__":
    main()
