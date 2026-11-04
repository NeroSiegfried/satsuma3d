# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Generate a language's code for the protocol with an interface, from `protocol.fbs`.

Blender's build runs this with FlatBuffers' schema compiler, `flatc`, from its libraries, for C++
and for the iPad's Swift; `tests/kotlin_check.py` runs it for Kotlin.

    python3 generate.py --flatc /path/to/flatc --language swift --output /path/to/folder
"""

import argparse
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA = os.path.join(HERE, "protocol.fbs")

# Each language reads and writes buffers directly, without objects in between: Blender writes each
# node straight into its buffer, and interfaces read the nodes they keep where they are.
LANGUAGES = {
    "cpp": ["--cpp", "--scoped-enums", "--cpp-std", "c++17"],
    "swift": ["--swift"],
    "kotlin": ["--kotlin"],
}


def generate(flatc, language, output):
    os.makedirs(output, exist_ok=True)
    subprocess.run([flatc, *LANGUAGES[language], "-o", output, SCHEMA], check=True)
    if language == "swift":
        # The Swift runtime is built into the app with the generated code, not as a module of its
        # own.
        swift = os.path.join(output, "protocol_generated.swift")
        with open(swift) as file:
            text = file.read()
        with open(swift, "w") as file:
            file.write(text.replace("\nimport FlatBuffers\n", "\n"))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--flatc", required=True, help="FlatBuffers' schema compiler")
    parser.add_argument("--language", required=True, choices=LANGUAGES)
    parser.add_argument("--output", required=True, help="The folder to write the code to")
    args = parser.parse_args()
    generate(args.flatc, args.language, args.output)


if __name__ == "__main__":
    main()
