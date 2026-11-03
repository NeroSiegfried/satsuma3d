# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Generate each language's code for the protocol with an interface, from `protocol.fbs`.

The generated files are checked in, so Blender builds without `flatc`, FlatBuffers' schema
compiler: run this after changing the schema, with the `flatc` of the version in
`extern/flatbuffers/README.blender`.

    python3 generate.py --flatc /path/to/flatc          # Write the generated files.
    python3 generate.py --flatc /path/to/flatc --check  # Fail if they are out of date.

`--flatc` defaults to the `FLATC` environment variable, then `flatc` on the path.
"""

import argparse
import filecmp
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA = os.path.join(HERE, "protocol.fbs")
GENERATED = os.path.join(HERE, "generated")

# What each language needs: Blender builds buffers; the iPad keeps the nodes it shows as objects,
# apart from the buffers they came in; Android reads them.
LANGUAGES = {
    "cpp": ["--cpp", "--scoped-enums"],
    "swift": ["--swift", "--gen-object-api"],
    "kotlin": ["--kotlin"],
}


def find_flatc(flatc):
    flatc = flatc or os.environ.get("FLATC") or shutil.which("flatc")
    if not flatc or not os.path.exists(flatc):
        sys.exit("No flatc: pass --flatc or set FLATC")
    return flatc


def generate(flatc, destination):
    for language, options in LANGUAGES.items():
        output = os.path.join(destination, language)
        os.makedirs(output, exist_ok=True)
        subprocess.run([flatc, *options, "-o", output, SCHEMA], check=True)
    # The Swift runtime is built into the app with the generated code, not as a module of its own.
    swift = os.path.join(destination, "swift", "protocol_generated.swift")
    with open(swift) as file:
        text = file.read()
    with open(swift, "w") as file:
        file.write(text.replace("\nimport FlatBuffers\n", "\n"))


def same(a, b):
    """Whether two folders hold the same files."""
    comparison = filecmp.dircmp(a, b)
    if comparison.left_only or comparison.right_only or comparison.diff_files or comparison.funny_files:
        return False
    return all(same(os.path.join(a, name), os.path.join(b, name)) for name in comparison.common_dirs)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--flatc", help="FlatBuffers' schema compiler")
    parser.add_argument("--check", action="store_true", help="Fail when the generated files are out of date")
    args = parser.parse_args()
    flatc = find_flatc(args.flatc)
    if args.check:
        with tempfile.TemporaryDirectory() as directory:
            generate(flatc, directory)
            if not all(same(os.path.join(directory, language), os.path.join(GENERATED, language))
                       for language in LANGUAGES):
                sys.exit("Out of date: run `generate.py` after changing protocol.fbs")
        print("Up to date")
        return
    for language in LANGUAGES:
        shutil.rmtree(os.path.join(GENERATED, language), ignore_errors=True)
    generate(flatc, GENERATED)
    print("Wrote %s" % os.path.relpath(GENERATED))


if __name__ == "__main__":
    main()
