# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Sweeps of the iPad shell's Swift sources for constructs that are known to go wrong on the
device, so a class of fault found once cannot come back (ROUND5 Stage 6). The Swift itself is
only compiled by the iPad build; this reads it as text, so it runs with any Blender build."""
import json
import re
from pathlib import Path

SWIFT = Path(__file__).resolve().parents[2] / 'source/blender/windowmanager/apple_ios/swift'
checks = []


def check(ok, name):
    assert ok, name
    checks.append(name)


def sources():
    files = sorted(SWIFT.glob('*.swift'))
    assert files, "no Swift sources at %s" % SWIFT
    return files


def skip_string_or_comment(text, i):
    """The index after a string literal or comment starting at \a i, or \a i itself."""
    if text.startswith('//', i):
        end = text.find('\n', i)
        return len(text) if end < 0 else end
    if text.startswith('/*', i):
        depth, i = 1, i + 2
        while i < len(text) and depth:
            if text.startswith('/*', i):
                depth, i = depth + 1, i + 2
            elif text.startswith('*/', i):
                depth, i = depth - 1, i + 2
            else:
                i += 1
        return i
    if text.startswith('"""', i):
        end = text.find('"""', i + 3)
        return len(text) if end < 0 else end + 3
    if text[i] == '"':
        i += 1
        while i < len(text) and text[i] not in '"\n':
            i += 2 if text[i] == '\\' else 1
        return i + 1
    return i


def balanced(text, start, open_char, close_char):
    """The end (exclusive) of the bracketed block whose opening bracket is at \a start."""
    depth, i = 0, start
    while i < len(text):
        j = skip_string_or_comment(text, i)
        if j != i:
            i = j
            continue
        if text[i] == open_char:
            depth += 1
        elif text[i] == close_char:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return len(text)


def code_only(text):
    """\a text with its comments and string literals blanked out, so words in them do not count."""
    out, i = [], 0
    while i < len(text):
        j = skip_string_or_comment(text, i)
        if j != i:
            out.append(''.join(c if c == '\n' else ' ' for c in text[i:j]))
            i = j
        else:
            out.append(text[i])
            i += 1
    return ''.join(out)


def content_closures(text, modifiers):
    """Each `.modifier(…) { … }` or `.modifier { … }` in \a text: (line, block)."""
    for match in re.finditer(r'\.(%s)\b' % '|'.join(modifiers), text):
        i = match.end()
        while i < len(text) and text[i] in ' \t':
            i += 1
        if i < len(text) and text[i] == '(':
            i = balanced(text, i, '(', ')')
            while i < len(text) and text[i] in ' \t':
                i += 1
        if i < len(text) and text[i] == '{':
            end = balanced(text, i, '{', '}')
            yield text.count('\n', 0, match.start()) + 1, text[i:end]


# 6A.6: SwiftUI ignores an alignment guide on a view inside a condition in an overlay's (or a
# background's) content; the Item card and the number pad were placed that way and landed on the
# bottom row instead of above it.
GUIDE_IN_CONDITION = ("SwiftUI ignores an alignment guide inside a condition in an overlay; place the view with "
                      "ShellLayout instead (ROUND5 Stage 6, V2)")
offenders = []
for path in sources():
    text = code_only(path.read_text(encoding='utf-8'))
    for line, block in content_closures(text, ('overlay', 'background')):
        if re.search(r'\bif\s', block) and '.alignmentGuide(' in block:
            offenders.append('%s:%d' % (path.name, line))
for offender in offenders:
    print('%s: %s' % (offender, GUIDE_IN_CONDITION))
check(not offenders, "No alignment guide inside a condition in an overlay or background")


def calls(text, name):
    """Each call `name(…)` in \a text: (line, its argument list)."""
    for match in re.finditer(r'\b%s\(' % re.escape(name), text):
        start = match.end() - 1
        yield text.count('\n', 0, match.start()) + 1, text[start:balanced(text, start, '(', ')')]


# 6C.6: one way to draw a setting in a bar. The tool settings row (whose items are in
# NativeToolSettings.swift), the last operation's strip and the Item card draw numbers only as
# Blender's widget, and never with the system's light field.
code = {path.name: code_only(path.read_text(encoding='utf-8')) for path in sources()}
check(not any(re.search(r'\bStripColumn\b', text) for text in code.values()),
      "StripColumn is gone: the strip draws its settings with BlenderSettingItem")
BARS = ('RedoStrip.swift', 'ItemCard.swift', 'ToolSettingsRow.swift', 'NativeToolSettings.swift')
plain = ['%s:%d' % (name, line) for name in BARS for line, args in calls(code[name], 'NativeNumberField')
         if 'widget:' not in args]
for offender in plain:
    print('%s: a number in a bar is drawn as Blender\'s field, NativeNumberField(…, widget:) (ROUND5 6C)' % offender)
check(not plain, "Numbers in the bars are drawn only through Blender's widget")
light = [name for name in BARS if 'PanelStyle.field' in code[name]]
check(not light, "No system field (PanelStyle.field) in the bars: %s" % light)

# 6D.4: numbers show the decimals Blender shows (the node's precision), never a count of
# significant digits, which turns 1234.567 into 1230.
rounded = ['%s:%d' % (name, line) for name, text in code.items() for line, args in calls(text, 'format')
           if 'significant' in args]
for offender in rounded:
    print('%s: a number is formatted with its precision, format(value), not significant digits (ROUND5 6D)' % offender)
check(not rounded, "No number is formatted by significant digits")

# 6D.1: the bridge sends the precision Blender draws each number with, not one literal for all.
# (Its values are checked against a running Blender by the Mac bridge harness, scenario
# `precision`: the bridge needs a window, which these background tests do not have.)
bridge = code_only((SWIFT.parents[2] / 'editors/interface/interface_native_properties.cc').read_text(encoding='utf-8'))
create = [args for line, args in calls(bridge, 'protocol::CreateNumber')]
check(any('precision' in args for args in create) and 'ui_but_calc_float_precision' in bridge,
      "The bridge sends Blender's precision for each number")

# 6E: in a lane too narrow for them, the pills become circles and the number pad's keys narrow
# (decision 31): the rule is in the layout function, and the pad takes its width from its slot.
layout = code['ShellLayout.swift']
check('iconPills' in layout and 'padMinWidth' in layout,
      "bottomStack shortens the pills and narrows the number pad in a narrow lane (ROUND5 6E)")
pad = code['QuickActions.swift']
pad = pad[pad.index('struct NumberPad'):]
check(not re.search(r'\.frame\(width:\s*56\b', pad) and 'NumberPad(model: model, width:' in code['QuickActions.swift'],
      "The number pad's keys take their width from its slot, not a literal 56 (ROUND5 6E)")

# 7A: a form is exactly as wide as what holds it. A `VStack` grows to its widest row, and a vertical
# scroll view centres content wider than itself, so one over-wide row pushed every card of
# Properties off its panel. The form and each panel's body are a PanelColumn, which lays every
# row out at the width it has and logs a panel whose rows need more.
panels = code['NativePanels.swift']
form = panels[panels.index('struct PanelsForm'):panels.index('struct PanelColumn')]
check('PanelColumn(' in form and not re.search(r'\bVStack\(alignment: \.leading, spacing: 17\)', form),
      "PanelsForm lays its panels out in a PanelColumn, not a VStack that grows to its widest row (ROUND5 7A)")
check('LayoutChecker.shared.overflow(' in panels and
      ' needs ' in (SWIFT / 'NativePanels.swift').read_text(encoding='utf-8'),
      "A panel whose rows need more width than it has is logged as `layout properties <tab> <panel> needs W of P`")
check('case "tab":' in (SWIFT / 'Snapshots.swift').read_text(encoding='utf-8'),
      "Snapshot scripts can open Properties on a tab (`tab <ID>`)")

# 7B: Properties is Blender's editor frame, not a settings form: a panel is one box (header and
# body together), no lines between rows, the tabs in a column, the tab's name as the title, and
# Blender's context path under it.
check(not re.search(r'cornerRadius:\s*20\b', panels) and 'Divider()' not in panels,
      "NativePanels.swift draws no inset-grouped card (radius 20) and no dividers between rows (ROUND5 7B)")
section = panels[panels.index('struct PanelSection'):panels.index('struct PanelBox')]
check('PanelBox {' in section, "PanelSection draws through PanelBox (ROUND5 7B)")
check('PropertiesTabColumn(' in panels and 'model.tabTitle' in panels and 'PropertiesContextPath(' in panels,
      "Properties has its tabs in a column, the tab's name as its title and the context path (ROUND5 7B)")
check('"path"' in (SWIFT.parents[2] / 'editors/interface/interface_native_properties.cc').read_text(encoding='utf-8')
      and 'ED_buttons_native_context_path' in bridge,
      "The bridge sends Blender's context path as a `path` group (ROUND5 7B)")

# 7C: a setting is drawn one way. Properties' rows use the widgets of the bars (BlenderWidgets.swift):
# no system slider, switch, colour well or menu picker in a row, and no light system field as a
# control's fill. The rows are ControlRow and the views it draws, up to NativeSwitch, which only
# panel headers use.
controls = code['NativeControls.swift']
rows = controls[controls.index('struct ControlRow'):controls.index('struct NativeSwitch')]
check('Slider(' not in rows and 'ColorPicker(' not in controls and 'UIColorWell' not in controls,
      "Properties' rows draw no system slider and no colour well (ROUND5 7C)")
check('.pickerStyle(.menu)' not in controls, "No system menu picker in Properties' rows (ROUND5 7C)")


def after_call(text, start):
    """The end of the call whose name starts at \a start, with its trailing closure."""
    i = balanced(text, text.index('(', start), '(', ')')
    while i < len(text) and text[i] in ' \t':
        i += 1
    return balanced(text, i, '{', '}') if i < len(text) and text[i] == '{' else i


bare_toggles = [m.start() for m in re.finditer(r'\bToggle\(', rows)
                if 'BlenderCheckboxStyle' not in rows[after_call(rows, m.start()):after_call(rows, m.start()) + 80]]
check(not bare_toggles, "Every toggle in a row is Blender's checkbox (BlenderCheckboxStyle) (ROUND5 7C)")
check('PanelStyle.field' not in rows, "No row fills a control with the system field (PanelStyle.field) (ROUND5 7C)")
check(all(name not in controls for name in ('struct NativeVectorRow', 'struct NativeToggleGroup', 'struct NativeSlider',
                                              'struct NativeColorSwatch', 'struct NativeColorPicker')),
      "The system-control rows are gone: vectors, toggle groups, sliders and colours draw with Blender's widgets")
check('NativeNumberField(model: model, node: node, widget: .alone)' in rows and 'BlenderVectorField(' in rows,
      "Numbers and vectors in Properties are Blender's fields (ROUND5 7C)")

print('PASS: native shell sources ' + json.dumps(checks))
