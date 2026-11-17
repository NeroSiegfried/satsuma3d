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

print('PASS: native shell sources ' + json.dumps(checks))
