# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""
The contract between Blender and a platform's own interface, `native_ui.fbs`: its generated types
are up to date, and snapshots Blender sent fit it.

    python3 tests/python/native_ui_schema_test.py
    python3 tests/python/native_ui_schema_test.py --snapshots DIR

`--snapshots` validates snapshots recorded from a running app, see `BLENDER_NATIVE_UI_RECORD` in
`wm_native_ui.cc`: one folder per snapshot type, named after its table, such as `Toolbar/`.
"""

import argparse
import glob
import json
import os
import sys
import unittest

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "source", "blender", "windowmanager", "native_ui"))

import native_ui_schema  # noqa: E402

SNAPSHOTS = None


def minimal_toolbar(**fields):
    toolbar = {"mode": "objectmode", "tools": [], "actions": []}
    toolbar.update(fields)
    return toolbar


class SchemaTest(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.schema = native_ui_schema.load()

    def errors(self, value, table="Toolbar"):
        return native_ui_schema.validate(self.schema, table, value)

    def test_generated_up_to_date(self):
        for language, text in native_ui_schema.generated().items():
            with open(native_ui_schema.GENERATED[language]) as file:
                self.assertEqual(
                    file.read(), text,
                    "%s is out of date: run `native_ui_schema.py generate`" % native_ui_schema.GENERATED[language])

    def test_root_is_toolbar(self):
        self.assertEqual(self.schema.root, "Toolbar")

    def test_minimal_toolbar(self):
        self.assertEqual(self.errors(minimal_toolbar()), [])

    def test_unknown_field(self):
        self.assertEqual(self.errors(minimal_toolbar(colour="red")), ["$.colour: not in Toolbar"])

    def test_missing_required(self):
        toolbar = minimal_toolbar()
        del toolbar["mode"]
        self.assertEqual(self.errors(toolbar), ["$.mode: required"])

    def test_null_is_absent(self):
        self.assertEqual(self.errors(minimal_toolbar(render=None, dragHint=None)), [])

    def test_wrong_types(self):
        errors = self.errors(minimal_toolbar(canUndo="yes", propertiesAck=1.5, navigationGizmo=[0.5, "x"]))
        self.assertEqual(len(errors), 3, errors)

    def test_flags_as_numbers(self):
        self.assertEqual(self.errors(minimal_toolbar(canUndo=1, canRedo=0)), [])
        self.assertNotEqual(self.errors(minimal_toolbar(canUndo=2)), [])

    def test_enums(self):
        self.assertEqual(self.errors(minimal_toolbar(objectMode="SCULPT", shading="rendered")), [])
        self.assertNotEqual(self.errors(minimal_toolbar(objectMode="sculpt")), [])

    def test_nested_tables(self):
        settings = {"orientation": "local", "pivot": "cursor", "snap": "vertex", "proportional": "off",
                    "mirror_axes": "XYZ", "mirror": "X", "mirror_topology": "on"}
        self.assertEqual(self.errors(minimal_toolbar(settings=settings)), [])
        settings["pivot"] = "elsewhere"
        self.assertEqual(len(self.errors(minimal_toolbar(settings=settings))), 1)

    def test_separators(self):
        tool = {"id": "builtin.move", "title": "Move", "icon": "ops.transform.translate", "symbol": "",
                "description": ""}
        group = dict(tool, group="builtin.select_box", children=[tool, None, tool])
        self.assertEqual(self.errors(minimal_toolbar(tools=[tool, None, group])), [])
        self.assertNotEqual(self.errors(minimal_toolbar(actions=[None])), [])

    def test_open_parts_take_anything(self):
        self.assertEqual(self.errors(minimal_toolbar(toolSettings={"anything": [1, {"x": None}]}, brushes=[])), [])

    def test_parse_errors(self):
        with self.assertRaises(native_ui_schema.SchemaError):
            native_ui_schema.parse("table A { b: Missing; }")


class RecordedSnapshotsTest(unittest.TestCase):
    """Snapshots a running app recorded, when given."""

    def test_recorded(self):
        if not SNAPSHOTS:
            self.skipTest("No --snapshots folder given")
        schema = native_ui_schema.load()
        checked = 0
        failures = []
        for folder in sorted(glob.glob(os.path.join(SNAPSHOTS, "*"))):
            table = os.path.basename(folder)
            if table not in schema.tables:
                continue
            for path in sorted(glob.glob(os.path.join(folder, "*.json"))):
                with open(path) as file:
                    errors = native_ui_schema.validate(schema, table, json.load(file))
                checked += 1
                failures += ["%s: %s" % (os.path.relpath(path, SNAPSHOTS), error) for error in errors[:10]]
        self.assertGreater(checked, 0, "No snapshots of a described table in %s" % SNAPSHOTS)
        self.assertEqual(failures, [], "\n".join(failures[:50]))


def main():
    global SNAPSHOTS
    parser = argparse.ArgumentParser()
    parser.add_argument("--snapshots", help="Snapshots recorded from a running app")
    args, remaining = parser.parse_known_args()
    SNAPSHOTS = args.snapshots
    unittest.main(argv=[sys.argv[0]] + remaining)


if __name__ == "__main__":
    main()
