# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Test the production serializer without starting Blender; UIKit tests cover the flyout."""

import ast
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch


class NativeToolGroupsTest(unittest.TestCase):
    def setUp(self):
        path = Path(__file__).resolve().parents[2] / "scripts/startup/bl_ui/space_toolsystem_common.py"
        tree = ast.parse(path.read_text())
        functions = [node for node in tree.body
                     if isinstance(node, ast.FunctionDef) and node.name == "native_toolbar"]
        # The bridge reads the list itself (`bridge_tools_build`), so there is no JSON step.
        self.tools = []
        self.active = None
        self.remembered = {}
        toolbar = SimpleNamespace(
            tools_from_context=lambda context: self.tools,
            _tool_group_active=self.remembered,
            _tool_group_active_get_from_item=lambda items: min(
                self.remembered.get(items[0].idname, 0), len(items) - 1),
        )
        namespace = {"ToolSelectPanelHelper": SimpleNamespace(
            _tool_class_from_space_type=lambda space: toolbar,
            _tool_active_from_context=lambda context, space: SimpleNamespace(idname=self.active),
        )}
        exec(compile(ast.Module(body=functions, type_ignores=[]), str(path), "exec"), namespace)
        self.serialize = namespace["native_toolbar"]

    def snapshot(self):
        translations = SimpleNamespace(pgettext_iface=lambda s: s, pgettext_tip=lambda s: s)
        with patch.dict("sys.modules", {"bpy.app.translations": translations}):
            # Round-trip through JSON: the bridge needs plain values only.
            return json.loads(json.dumps(self.serialize(SimpleNamespace(space_data=SimpleNamespace(type="VIEW_3D")))))

    @staticmethod
    def tool(name):
        return SimpleNamespace(idname=name, label=name + " label", icon="icon." + name,
                               description=name + " description")

    def test_groups_separators_icons_and_memory_match_definitions(self):
        box, circle, move = map(self.tool, ("box", "circle", "move"))
        self.tools = [(box, None, circle), None, move]
        self.active = "circle"
        result = self.snapshot()
        self.assertEqual(len(result), 3)
        self.assertIsNone(result[1])
        self.assertEqual(result[0]["id"], "circle")
        self.assertEqual(result[0]["group"], "box")
        self.assertEqual(result[0]["icon"], "icon.circle")
        self.assertEqual(result[0]["description"], "circle description")
        self.assertEqual([item["id"] if item else None for item in result[0]["children"]],
                         ["box", None, "circle"])
        self.active = "move"
        self.assertEqual(self.snapshot()[0]["id"], "circle")
        self.assertNotIn("children", result[2])

    def test_context_changes_and_registered_tools_are_not_hardcoded(self):
        self.tools = [(self.tool("extension.one"), self.tool("extension.two"))]
        self.assertEqual(self.snapshot()[0]["group"], "extension.one")
        self.tools = [self.tool("sculpt.brush")]
        self.assertEqual([item["id"] for item in self.snapshot()], ["sculpt.brush"])
        self.tools = [(None,), None]
        self.assertEqual(self.snapshot(), [None])

    def test_tweak_stands_alone_above_move(self):
        tweak, box, move = map(self.tool, ("builtin.select", "builtin.select_box", "builtin.move"))
        self.tools = [(tweak, box), None, move]
        result = self.snapshot()
        self.assertEqual([item["id"] if item else None for item in result],
                         ["builtin.select_box", None, "builtin.select", "builtin.move"])
        self.assertEqual([item["id"] for item in result[0]["children"]], ["builtin.select_box"])


if __name__ == "__main__":
    unittest.main()
