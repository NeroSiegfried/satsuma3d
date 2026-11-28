# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Sweeps of the iPad shell's Swift sources for constructs that are known to go wrong on the
device, so a class of fault found once cannot come back (ROUND5 Stage 6). The Swift itself is
only compiled by the iPad build; this reads it as text, so it runs with any Blender build."""
import ast
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
# control's fill. The rows are ControlRow and the views it draws, up to NativeButton. Panel headers
# too: their toggles are Blender's checkbox or icon toggle, not the system's switch.
controls = code['NativeControls.swift']
rows = controls[controls.index('struct ControlRow'):controls.index('struct NativeButton')]
check('struct NativeSwitch' not in controls and 'NativeSwitch(' not in panels
      and 'PanelHeaderToggle(' in panels,
      "Panel headers draw toggles with Blender's widgets, not the system switch (ROUND5 7C)")
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

# 7D: a data-block and its slots as Blender has them. Lists are Blender's list box with its
# buttons in a column at the side (the pill above the rows is gone); the ID row is Blender's
# template_ID, with where it is linked from at its end (the bridge's `Link` role); the table of
# what the viewport's shading hides is one place.
lists = code['NativeLists.swift']
check('struct NativeListToolbar' not in lists and 'NativeListSideColumn(' in lists,
      "Lists keep their buttons in Blender's side column, not a pill above the rows (ROUND5 7D)")
check('templateID' in lists and 'ReferenceLinkDropdown(' in lists and 'link: link' in code['NativeControls.swift'],
      "The ID row is Blender's template_ID with the Link dropdown at its end (ROUND5 7D)")
check('Link,' in (SWIFT.parents[1] / 'native_ui/protocol.fbs').read_text(encoding='utf-8') and
      'protocol::Role::Link' in bridge,
      "The bridge sends a material slot's link with the Link role (ROUND5 7D)")
check(code['RevealCoordinator.swift'].count('enum ShadingHint') == 1 and
      'VIEW3D_OT_toggle_shading' in (SWIFT / 'RevealCoordinator.swift').read_text(encoding='utf-8') and
      not any('VIEW3D_OT_toggle_shading' in path.read_text(encoding='utf-8') for path in sources()
              if path.name != 'RevealCoordinator.swift'),
      "What the shading hides is one table beside RevealCoordinator (ROUND5 7D, decision 30)")


# 8A.7: the app never calls itself Blender (decision 34). Every string literal holding "Blender" in
# the shell's Swift and Objective-C, its iOS `Info.plist` files and its own Python must be on
# `release/ios/branding_allowed.txt`, with its reason, and every line there must still be found.
# Labels the bridge sends from Blender's Python are checked by the Mac harness's `menus` scenario.
ROOT = SWIFT.parents[4]
SHELL = SWIFT.parent


def literals(text):
    r"""The string literals of Swift or Objective-C \a text, with Swift's interpolations `\(…)`
    left out, as (line, text)."""
    i, n = 0, len(text)
    while i < n:
        if text.startswith('//', i):
            end = text.find('\n', i)
            i = n if end < 0 else end
        elif text.startswith('/*', i):
            end = text.find('*/', i + 2)
            i = n if end < 0 else end + 2
        elif text.startswith('"""', i):
            end = text.find('"""', i + 3)
            end = n if end < 0 else end
            yield text.count('\n', 0, i) + 1, text[i + 3:end]
            i = end + 3
        elif text[i] == '"':
            j, out, depth = i + 1, [], 0
            while j < n:
                c = text[j]
                if depth:
                    if c == '(':
                        depth += 1
                    elif c == ')':
                        depth -= 1
                    elif c == '"':
                        # A string inside an interpolation: skip it whole.
                        k = j + 1
                        while k < n and text[k] != '"':
                            k += 2 if text[k] == '\\' else 1
                        j = k
                    j += 1
                    continue
                if text.startswith('\\(', j):
                    depth, j = 1, j + 2
                    out.append('\\(…)')
                    continue
                if c == '\\':
                    out.append(text[j:j + 2])
                    j += 2
                    continue
                if c in '"\n':
                    break
                out.append(c)
                j += 1
            yield text.count('\n', 0, i) + 1, ''.join(out)
            i = j + 1
        elif text[i] == "'" and 0 < text.find("'", i + 1) - i <= 4:
            i = text.find("'", i + 1) + 1
        else:
            i += 1


def python_strings(text):
    """The string constants of Python \a text that are not docstrings, as (line, text)."""
    import ast
    tree = ast.parse(text)
    docstrings = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and node.body and \
                isinstance(node.body[0], ast.Expr) and isinstance(node.body[0].value, ast.Constant):
            docstrings.add(id(node.body[0].value))
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in docstrings:
            yield node.lineno, node.value


branding_sources = {}  # where -> [(line, text)]
for path in sorted(SHELL.glob('swift/*.swift')) + sorted(SHELL.glob('*.mm')) + sorted(SHELL.glob('*.h')) + \
        sorted(SHELL.glob('*.hh')):
    branding_sources[path.name] = list(literals(path.read_text(encoding='utf-8')))
for path in sorted((ROOT / 'scripts/startup/bl_ui').glob('native_*.py')):
    branding_sources[path.name] = list(python_strings(path.read_text(encoding='utf-8')))
for relative in ('release/ios/Blender.app/Info.plist', 'release/ios/blender-thumbnailer.appex/Info.plist'):
    text = (ROOT / relative).read_text(encoding='utf-8')
    branding_sources[relative] = [(text.count('\n', 0, m.start()) + 1, m.group(1))
                                  for m in re.finditer(r'<(?:string|key)>([^<]*)</(?:string|key)>', text)]
check(len(branding_sources) > 50, "The branding sweep reads the shell's sources")

# 8I.1: the app's old name is caught the same way (decision 47): a user-visible "Platypus" is a
# self-reference under a name the app no longer has. Internal names keep it in lower or upper case
# (`platypus-scratch`, `PLATYPUS_…`), which this does not match.
BRANDS = ('Blender', 'Platypus')


def branded(text):
    return any(word in text for word in BRANDS)


allowed, bad_lines = {}, []
REASONS = ('file type', 'keymap name', 'style name', 'credit', 'internal key')
for number, line in enumerate((ROOT / 'release/ios/branding_allowed.txt').read_text(encoding='utf-8').splitlines(), 1):
    if not line.strip() or line.startswith('#') or line.startswith('artwork '):
        continue
    parts = line.split(' | ', 2)
    if len(parts) != 3 or not parts[1].startswith(REASONS) or not branded(parts[2]):
        bad_lines.append(number)
        continue
    allowed[(parts[0], parts[2])] = parts[1]
for number in bad_lines:
    print('branding_allowed.txt:%d: not `<where> | <reason> | <text>` with a reason from %s' % (number, REASONS))
check(not bad_lines, "Every line of branding_allowed.txt names where, a reason and a string holding \"Blender\" or \"Platypus\"")

unlisted = ['%s:%d: %r' % (where, line, text) for where, found in branding_sources.items()
            for line, text in found if branded(text) and (where, text) not in allowed]
for offender in unlisted:
    print('%s holds "Blender" or "Platypus" and is not on release/ios/branding_allowed.txt: the app never '
          'calls itself Blender, nor by its old name; use AppIdentity.name, or list it there with its reason '
          '(ROUND5 8A.7, 8I.1)' % offender)
check(not unlisted, "Every \"Blender\" or \"Platypus\" string in the shell is on the allow-list")
found = {(where, text) for where, items in branding_sources.items() for _line, text in items}
stale = sorted('%s | %s' % key for key in allowed if not key[0].startswith('menu ') and key not in found)
for line in stale:
    print('branding_allowed.txt: no longer found, remove it: %s' % line)
check(not stale, "Every line of branding_allowed.txt is still found in its file")


# 9G.2: pictures are swept as words are (decision 67). Every use of Blender's two logo icons, in
# Blender's C and C++, its Python interface and the shell, is a line of branding_allowed.txt's
# artwork section, with its reason, and every line there is still found.
LOGOS = ('ICON_BLENDER', 'ICON_BLENDER_LOGO_LARGE')
ARTWORK_REASONS = ('file type', 'credit', 'not on the iPad')


def python_icon_lines(text):
    """The lines of Python \a text naming a logo icon: as an `icon=` argument, or a value of a
    name holding "icon" (a table of icons), as (icon, line number)."""
    import ast
    names = {'BLENDER': 'ICON_BLENDER', 'BLENDER_LOGO_LARGE': 'ICON_BLENDER_LOGO_LARGE'}
    found = set()

    def visit(node):
        for sub in ast.walk(node):
            if isinstance(sub, ast.Constant) and sub.value in names:
                found.add((names[sub.value], sub.lineno))
    for node in ast.walk(ast.parse(text)):
        if isinstance(node, ast.keyword) and node.arg == 'icon':
            visit(node.value)
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            if any('icon' in (getattr(t, 'id', None) or getattr(t, 'attr', None) or '').lower() for t in targets):
                # A table of icons: a dictionary's values, or every element.
                for value in node.value.values if isinstance(node.value, ast.Dict) else [node.value]:
                    visit(value)
    return found


artwork_uses = set()  # (icon, path, line text)
C_SUFFIXES = ('.c', '.cc', '.cpp', '.h', '.hh', '.m', '.mm')
for top in ('source', 'intern'):
    for path in (ROOT / top).rglob('*'):
        if path.suffix not in C_SUFFIXES or path.name == 'UI_icons.hh' or not path.is_file():
            continue
        text = path.read_text(encoding='utf-8', errors='replace')
        if 'ICON_BLENDER' not in text:
            continue
        for line in text.splitlines():
            for icon in re.findall(r'\b(ICON_BLENDER(?:_LOGO_LARGE)?)\b', line):
                artwork_uses.add((icon, path.relative_to(ROOT).as_posix(), line.strip()))
for top in ('scripts/startup', 'scripts/modules', 'scripts/addons_core'):
    for path in (ROOT / top).rglob('*.py'):
        text = path.read_text(encoding='utf-8', errors='replace')
        if 'BLENDER' not in text:
            continue
        lines = text.splitlines()
        for icon, number in python_icon_lines(text):
            artwork_uses.add((icon, path.relative_to(ROOT).as_posix(), lines[number - 1].strip()))
for path in sorted(SHELL.glob('swift/*.swift')) + sorted(SHELL.glob('*.mm')):
    for line in path.read_text(encoding='utf-8').splitlines():
        if re.search(r'["\']BLENDER(?:_LOGO_LARGE)?["\']', line):
            artwork_uses.add(('ICON_BLENDER', path.relative_to(ROOT).as_posix(), line.strip()))
check(len(artwork_uses) >= 5, "The artwork sweep finds Blender's logo icons where Blender uses them")

artwork_allowed, artwork_bad = set(), []
for number, line in enumerate((ROOT / 'release/ios/branding_allowed.txt').read_text(encoding='utf-8').splitlines(), 1):
    if not line.startswith('artwork '):
        continue
    parts = line.split(' | ', 2)
    head = parts[0].split(' ')
    if len(parts) != 3 or len(head) != 3 or head[1] not in LOGOS or not parts[1].startswith(ARTWORK_REASONS):
        artwork_bad.append(number)
        continue
    artwork_allowed.add((head[1], head[2], parts[2]))
for number in artwork_bad:
    print('branding_allowed.txt:%d: not `artwork <icon> <file> | <reason> | <line>` with a reason from %s' %
          (number, ARTWORK_REASONS))
check(not artwork_bad, "Every artwork line of branding_allowed.txt names the icon, the file, a reason and the line")
for icon, where, line in sorted(artwork_uses - artwork_allowed):
    print('%s: %s uses %s and is not on release/ios/branding_allowed.txt: Blender\'s logo marks only Blender '
          'files and credits; the app\'s mark is ICON_SATSUMA_GLYPH (ROUND5 9G.2, decision 67)' % (where, line, icon))
check(not (artwork_uses - artwork_allowed), "Every use of Blender's logo icons is on the allow-list's artwork section")
for icon, where, line in sorted(artwork_allowed - artwork_uses):
    print('branding_allowed.txt: artwork no longer found, remove it: %s %s | %s' % (icon, where, line))
check(not (artwork_allowed - artwork_uses), "Every artwork line of branding_allowed.txt is still found in its file")


# 9G.3 (decision 69): the UV Editor marks the selection in the theme's colours, which Blender sends
# as its UV Editor reads them; none is a constant in the shell. It follows UV Sync Selection, which
# its ⋯ menu switches.
image_editor_text = (SWIFT / 'ImageEditor.swift').read_text(encoding='utf-8')
image_native_text = (ROOT / 'source/blender/editors/space_image/image_native.cc').read_text(encoding='utf-8')
uv_drawing = image_editor_text[image_editor_text.index('private func rebuildUVPath'):
                               image_editor_text.index('/** The selected vertices')] + \
    image_editor_text[image_editor_text.index('struct UVTheme'):image_editor_text.index('extension CGPoint')]
check(all(('"%s"' % key) in image_native_text and ('"%s"' % key) in image_editor_text
          for key in ('face_select', 'active', 'wire_edit', 'edge_select', 'vertex_select', 'seam')) and
      'get_color_type_4fv' in image_native_text,
      "9G.3: the UV Editor's colours come from Blender's theme, sent with the image view")
check(not re.search(r'UIColor\((?:red|white):\s*[0-9.]', uv_drawing),
      "9G.3: no UV selection colour is a constant in the shell")
check('UV Sync Selection' in image_editor_text and 'tool_settings.use_uv_select_sync' in image_editor_text and
      'uvedit_face_visible_test(scene, face)' in image_native_text,
      "9G.3: the UV Editor follows UV Sync Selection, which its menu switches")

# 8C: About shows the licences the app carries, never a copy typed into the code; every row has
# what VoiceOver reads; it is reached from the launcher, Settings and the app menu.
about_text = (SWIFT / 'AboutSheet.swift').read_text(encoding='utf-8')
LICENCE_PHRASES = ('GNU GENERAL PUBLIC LICENSE', 'WITHOUT ANY WARRANTY', 'Permission is hereby granted',
                   'Free Software Foundation', 'Redistribution and use in source and binary forms')
typed = [phrase for phrase in LICENCE_PHRASES for _line, text in literals(about_text) if phrase in text]
check(not typed, "About types no licence text, it reads the app's own: %s" % typed)
check('license/spdx/' in about_text and 'license/license.md' in about_text and 'copyright.txt' in about_text,
      "About reads the GPL, the notices and the copyright notice from Assets/text")
about = about_text
row = about[about.index('private struct AboutRow'):about.index('private struct LicenceTextView')]
check('.accessibilityLabel(' in row and '.accessibilityElement(children: .combine)' in row,
      "About's rows each give VoiceOver one label")
page = about[about.index('struct AboutPage'):about.index('final class SwiftAbout')]
bare = [m.start() for m in re.finditer(r'^\s*Text\(', page, re.M)]
check(page.count('.accessibilityLabel(') >= 1 and all(
      'Section' in page[max(0, i - 200):i] or 'VStack' in page[max(0, i - 300):i] or 'footer' in page[max(0, i - 80):i]
      or 'header' in page[max(0, i - 80):i] for i in bare),
      "About's rows are AboutRows; other text is a header, a footer or the labelled title block")
check('SwiftAbout.present(from:' in code['DocumentWindow.swift'] and 'aboutPage' in code['SettingsSheet.swift']
      and 'WMIOSSwiftAbout' in (SHELL / 'wm_apple_ios_launcher.mm').read_text(encoding='utf-8')
      and 'case "about":' in (SWIFT / 'Snapshots.swift').read_text(encoding='utf-8'),
      "About opens from the app menu, the last page of Settings and the launcher; snapshots can open it")
check('Development build: source not published' in about_text,
      "A development build without a source address says so in About")


# 8E.3: iPadOS runs no other program. Every use of `subprocess` or `os.system` (and their kin) in
# Blender's Python is either in an operator whose poll fails on iPad through the one helper
# (`_bpy_internal.platform.sandbox.poll_programs`, "Not available on iPad: it needs another
# program"), or on this short reviewed list, keyed by file and the class or function holding it.
SCRIPTS = ROOT / 'scripts'
LAUNCHES = re.compile(r'\b(subprocess\.(run|Popen|call|check_call|check_output|getoutput|getstatusoutput)|'
                      r'os\.(system|popen|exec[lv]p?e?|spawn[lv]p?e?|posix_spawnp?|startfile))\s*\(')
REVIEWED = {
    ('addons_core/bl_pkg/bl_extension_utils.py', 'command_output_from_json_0'):
        "the extensions platform's worker: syncing needs online access, which is off on iPad, and add-ons "
        "install in-process through bl_ui.native_addons; a failure to start raises and is reported",
    ('addons_core/io_scene_gltf2/blender/exp/export.py', '__postprocess_with_gltfpack'):
        "gltfpack: its panel and preference are hidden on iPad (sandbox.IPAD); a failure is logged",
    ('addons_core/ui_translate/update_repo.py', 'UI_OT_i18n_updatetranslation_work_repo'):
        "translators' tool, not enabled",
    ('modules/_bl_i18n_utils/utils.py', 'I18nMessages'): "translators' tool, not run by the app",
    ('modules/_bl_text_utils/external_editor.py', 'open_external_editor'):
        "only with a program in Preferences > File Paths > Text Editor; its error is returned as a report",
    ('modules/_bpy_internal/platform/freedesktop.py', 'handle_mime_association_xml'): "Linux desktop registration only",
    ('modules/_bpy_internal/platform/freedesktop.py', 'handle_mime_association_default'):
        "Linux desktop registration only",
    ('modules/_bpy_internal/platform/freedesktop.py', 'main_run_as_root'): "Linux desktop registration only",
    ('modules/_bpy_internal/system_info/text_generate_runtime.py', 'write'):
        "Python's version for Save System Info, in a try: an error is written into the report",
    ('modules/_bpy_internal/system_info/url_prefill_startup.py', 'url_from_blender'):
        "the crash reporter's startup script, run outside the app; in a try",
    ('modules/_console_shell.py', 'shell_run'): "the Python console's Shell language, which reports errors",
    ('modules/_graphviz_export.py', 'graph_armature'): "developers' debugging",
}
seen_reviewed, unguarded = set(), []
for path in sorted(SCRIPTS.rglob('*.py')):
    relative = str(path.relative_to(SCRIPTS))
    if '/tests/' in relative or relative.startswith('templates_py/'):
        continue
    lines = path.read_text(encoding='utf-8', errors='replace').split('\n')
    for number, line in enumerate(lines, 1):
        stripped = line.split('#', 1)[0]
        if not LAUNCHES.search(stripped):
            continue
        # The class or function holding it, at the top level.
        holder = next((m.group(2) for previous in reversed(lines[:number])
                       for m in [re.match(r'(class|def)\s+(\w+)', previous)] if m), '')
        if (relative, holder) in REVIEWED:
            seen_reviewed.add((relative, holder))
            continue
        start = next(i for i in range(number - 1, -1, -1) if lines[i].startswith(('class ', 'def ')) or i == 0)
        end = next((i for i in range(number, len(lines)) if lines[i].startswith(('class ', 'def '))), len(lines))
        if lines[start].startswith('class ') and 'poll_programs(cls)' in '\n'.join(lines[start:end]):
            continue
        unguarded.append('scripts/%s:%d (%s)' % (relative, number, holder))
for offender in unguarded:
    print('%s starts another program and neither fails its poll on iPad through '
          '_bpy_internal.platform.sandbox.poll_programs nor is on the reviewed list (ROUND5 8E.3)' % offender)
check(not unguarded, "Every subprocess or os.system use is guarded on iPad or reviewed")
check(seen_reviewed == set(REVIEWED), "Every reviewed subprocess use still exists: %s" % sorted(set(REVIEWED) - seen_reviewed))
for idname, name in (('wm.py', 'WM_OT_path_open'), ('image.py', 'EditExternally'),
                     ('file.py', 'WM_OT_previews_batch_generate'), ('file.py', 'WM_OT_previews_batch_clear'),
                     ('screen_play_rendered_anim.py', 'PlayRenderedAnim'), ('assets.py', 'ASSET_OT_open_containing_blend_file')):
    text = (SCRIPTS / 'startup/bl_operators' / idname).read_text(encoding='utf-8')
    body = text[text.index('class %s(' % name):]
    body = body[:body.find('\nclass ', 1)] if '\nclass ' in body[1:] else body
    check('poll_programs(cls)' in body, "%s fails its poll on iPad (ROUND5 8E.3)" % name)

# 8E.1: online access is off on iPad as `--offline-mode` makes it, and the shell says so in words.
creator = (ROOT / 'source/creator/creator.cc').read_text(encoding='utf-8')
block = creator[creator.index('#ifdef WITH_APPLE_CROSSPLATFORM\n  /* The app never goes online'):]
check('G.f |= G_FLAG_INTERNET_OVERRIDE_PREF_OFFLINE;' in block[:600] and 'U.flag' not in block[:600],
      "iOS starts the engine offline through G.f, as --offline-mode does, without touching U.flag (ROUND5 8E.1)")
check('NO_ONLINE' in (SCRIPTS / 'startup/bl_ui/space_userpref.py').read_text(encoding='utf-8'),
      "Preferences' Network panel says on iPad why online access is off")

# 8I.5: free space before Save and Save As (decision 45). One rule (`SaveSpace.warning`, tested by
# tests/ios/test_save_space.py), asked by every way to save the document: Blender's Save and Save
# As operators and the shell's Save As, each offering Save Anyway and Cancel.
files_cc = (ROOT / 'source/blender/windowmanager/intern/wm_files.cc').read_text(encoding='utf-8')
for invoke in ('wm_save_mainfile_invoke', 'wm_save_as_mainfile_invoke'):
    body = files_cc[files_cc.index('static wmOperatorStatus %s(' % invoke):]
    body = body[:body.index('\n}\n')]
    check('wm_save_space_ask(C, op)' in body, "%s asks about free space first on iPad (ROUND5 8I.5)" % invoke)
check('warning->save_anyway' in files_cc and 'warning->cancel' in files_cc,
      "The operators' warning offers Save Anyway and Cancel (ROUND5 8I.5)")
top_bar = (SWIFT / 'TopBar.swift').read_text(encoding='utf-8')
save_as = top_bar[top_bar.index('func saveDocumentAs()'):top_bar.index('func shareDocument()')]
check('SaveSpace.warning(forSavingAt:' in save_as and 'space[3]' in save_as and 'space[4]' in save_as,
      "The shell's Save As asks about free space and offers Save Anyway and Cancel (ROUND5 8I.5)")
check(len(re.findall(r'static func warning\(freeBytes', '\n'.join(p.read_text(encoding='utf-8')
                                                                   for p in SWIFT.glob('*.swift')))) == 1,
      "One function decides when space is low (ROUND5 8I.5)")
check('apple_ios/swift/SaveSpace.swift' in (ROOT / 'source/creator/CMakeLists.txt').read_text(encoding='utf-8'),
      "SaveSpace.swift is built into the app")

# 7E: what the first run on the iPad showed.
panels = code['NativePanels.swift']
properties_panel = panels[panels.index('struct PropertiesPanel'):panels.index('struct PropertiesTabColumn')]
check('PanelsModel.inSidebarGroup(model.currentTab)' in properties_panel and 'BlenderIcon.image($0.icon) == nil' not in
      properties_panel, "E1: the sidebar's strip of words shows only on Tool and the sidebar's tabs (decision 41)")
check('tab.id == PanelsModel.toolTab && PanelsModel.isSidebarCategory(model.currentTab)' in panels,
      "E1: the Tool tab's icon stays lit for the sidebar's group")
shell_layout = code['ShellLayout.swift']
top_bar_code = code['TopBar.swift']
check('menusExpanded' not in shell_layout + top_bar_code and 'menusButton' not in shell_layout + top_bar_code and
      'struct State' in shell_layout and 'EditorMenus(sideBySide: model.headerMenus)' in top_bar_code and
      '"More Menus"' in (SWIFT / 'TopBar.swift').read_text(encoding='utf-8'),
      "E2: the editor's menus fold one at a time into More Menus, not all at once (decision 42)")
check('text(modeTitle)' not in shell_layout, "E2: the header's estimate does not count the mode's name, which it does not draw")
check('header spare' in (SWIFT / 'DocumentWindow.swift').read_text(encoding='utf-8') and '"edit", ["View", "Select", "Add", "Mesh", "Vertex", "Edge", '
      '"Face", "UV"]' in (SWIFT / 'ShellLayout.swift').read_text(encoding='utf-8'),
      "E2: a header with room to spare is logged, and the self-test has Edit Mode's eight menus")
interop = code['UIKitInterop.swift']
marks = interop[interop.index('struct ScrollMoreMarks'):interop.index('func makePanelGlass')]
check('LinearGradient' not in marks and 'if !glass { ShellStyle.region }' in marks,
      "E3: in Blender's style a bar's more-arrow stands on a strip of the bar's colour, not over the content")
controls = code['NativeControls.swift']
expanded = controls[controls.index('struct BlenderExpandedChoice'):controls.index('struct NativeButton:')]
grid = controls[controls.index('struct EqualCellGrid'):controls.index('func sizeThatFits', controls.index('struct EqualCellGrid'))]
check('EqualCellGrid(columns: columns, shrink: icons ? 1 : BlenderWidgetFace.textShrink' in expanded and
      'firstRow: true' in controls and 'fixed + max(0, ideal - fixed) * shrink' in grid and
      '.minimumScaleFactor(Self.textShrink)' in code['BlenderWidgets.swift'],
      "E4: an expanded choice that does not fit one row wraps into two joined rows (decision 43), "
      "the grid measured with its names as far shrunk as they may be (seen as a column on 2026-11-18)")
window_source = (SWIFT / 'DocumentWindow.swift').read_text(encoding='utf-8')
stored = window_source[window_source.index('private func desktopChanged()'):]
stored = stored[:stored.index('forKey: "BlenderDesktopInterface")')]
check('environment["PLATYPUS_SCRATCH_DOCUMENT"] == nil' in stored,
      "A check launch does not store the interface its scratch document opens in (2026-11-18)")
check('BlenderNumberText.format(' in controls,
      "E5: numbers are printed by BlenderNumberText (no sign on a zero), tested by tests/ios/test_number_text.py")
check('static func entry(tab: String, shading: String, path: [String])' in code['RevealCoordinator.swift'] and
      'path: model.pathItems.map' in panels,
      "E6: the shading line needs what it is about in the context path (a material in the slot)")
check('case "edit":' in (SWIFT / 'Snapshots.swift').read_text(encoding='utf-8') and 'NumberFieldEditRequest.notification' in controls,
      "7E.7: the snapshot step `edit <identifier>` puts a number field into editing")

# ROUND5 9A.6 (decision 52): a key kept from Blender does the shell's own version of its command
# only where the shell has one. `release/ios/key_stand_ins.txt` lists them; the shell carries out
# exactly these, and Blender's side names only these (the Mac harness's `keys` scenario).
stand_in_lines = [line for line in (ROOT / 'release/ios/key_stand_ins.txt').read_text(encoding='utf-8').splitlines()
                  if line.strip() and not line.startswith('#')]
stand_ins = {line.split(' | ', 1)[0] for line in stand_in_lines}
check(all(' | ' in line for line in stand_in_lines) and stand_ins,
      "Every line of key_stand_ins.txt is `<command> | <what the shell does>`")
window_text = (SWIFT / 'DocumentWindow.swift').read_text(encoding='utf-8')
run_start = window_text.index('private func runStandIn(')
run_body = window_text[run_start:balanced(window_text, window_text.index('{', run_start), '{', '}')]
handled = set(re.findall(r'case "([a-z_]+)":', run_body))
check(handled == stand_ins,
      "The shell carries out exactly the key stand-ins of key_stand_ins.txt (shell: %s, file: %s)" %
      (sorted(handled), sorted(stand_ins)))
bridge_text = (SWIFT.parents[1] / 'intern/wm_native_ui.cc').read_text(encoding='utf-8')
stand_in_function = bridge_text[bridge_text.index('static const char *bridge_key_stand_in('):]
stand_in_function = stand_in_function[:stand_in_function.index('\n}\n')]
named = set(re.findall(r'return "([a-z_]+)";', stand_in_function))
check(named <= stand_ins, "Blender names only stand-ins of key_stand_ins.txt (%s)" % sorted(named - stand_ins))
pull = window_text[window_text.index('private func pullMenuPopup('):run_start]
check('has nothing to show here' in pull and '"\\(menu) empty"' in pull and 'title: title' in pull,
      "9A.3: an empty menu from a key is said and logged, and a popup's menu has its title")
snapshots_text = (SWIFT / 'Snapshots.swift').read_text(encoding='utf-8')
check('case "key":' in snapshots_text and 'case "menu":' in snapshots_text and
      'wm_apple_ios_window_press_key(' in snapshots_text,
      "9A.9: the snapshot steps `key <NAME> [shift] [ctrl] [alt]` and `menu close`")

# ROUND5 9B (decision 53): the UV Editor and the Image Editor are one panel in two modes, each in
# the editors menu; the UV Editor has no "No Image" page and always draws the UVs.
image_editor = (SWIFT / 'ImageEditor.swift').read_text(encoding='utf-8')
check('case uv, image' in image_editor and 'model.mode == .image && model.snapshot != nil && model.image == nil'
      in image_editor and 'var drawsUVs: Bool { mode == .uv || showUVs }' in image_editor,
      "9B.2: the UV Editor shows the unit square instead of a No Image page, and always its UVs")
check('ForEach(ImageEditorModel.Mode.allCases)' in (SWIFT / 'TopBar.swift').read_text(encoding='utf-8'),
      "9B.1: the editors menu lists the UV Editor and the Image Editor")
check('BlenderSettings.set("desktop_open", .text("UV_EDITING"))' in image_editor and
      '{"UV_EDITING", "UV Editing"' in bridge_text,
      "9B.6: Edit UVs in Desktop Interface is a caller of the one hand-off (ROUND6 EDIT-11)")

# ROUND6 EDIT-11 (D10): one hand-off. Every Blender editor is native, hosted or handed off; the
# harness scenario `handoff` walks the editors and their modes against a written classification.
# Here: the Sidebar menu lists Blender's own list (the `desktop_open` options), not a copy, and
# nothing else sends the old one-off setting.
topbar_text = (SWIFT / 'TopBar.swift').read_text(encoding='utf-8')
check('BlenderSettings.desktopEditors' in topbar_text and 'desktopEditors\n' in topbar_text and
      'BlenderSettings.set("desktop_open", .text(editor.value' in topbar_text,
      "EDIT-11: the Sidebar menu's Open in Desktop Interface lists the settings view's editors")
check(not any('"desktop_uv_editing"' in path.read_text(encoding='utf-8') for path in SWIFT.glob('*.swift')) and
      '"desktop_uv_editing"' not in bridge_text,
      "EDIT-11: no one-off hand-off setting is left beside `desktop_open`")
# ROUND6 EDIT-12 (D11): the timeline's Playback and Keying is Blender's Timeline header and the top
# bar's scene and view layer, drawn by Blender (harness scenario `bars` walks the three bars).
timeline_text = (SWIFT / 'Timeline.swift').read_text(encoding='utf-8')
panels_text = (ROOT / 'scripts/startup/bl_ui/native_panels.py').read_text(encoding='utf-8')
check('"POPOVER:VIEW3D_PT_native_timeline_header\\tHEADER"' in timeline_text and 'playbackButton\n' in timeline_text
      and 'class VIEW3D_PT_native_timeline_header(' in panels_text and
      '    VIEW3D_PT_native_timeline_header,\n' in panels_text and 'playback_controls(layout, context)' in panels_text,
      "EDIT-12: the timeline's Playback and Keying opens Blender's Timeline header as a popover")
files_text = (ROOT / 'source/blender/windowmanager/intern/wm_files.cc').read_text(encoding='utf-8')
# The crash file is written from a crash handler and is not a document: the one write left out.
check(files_text.count('BLO_write_file(') == files_text.count('const NativeVisitWriteScope visit(bmain);') + 1 and
      files_text.count('const NativeVisitWriteScope visit(bmain);') == 3,
      "EDIT-11: every write of a document, startup file or auto-save goes through the visit's scope")

check('case "editor":' in snapshots_text, "9B.7: the snapshot step `editor uv|image open|close`")

# ROUND5 9C (decision 56): the size of Blender's own interface is the app's own setting, sent at
# start beside `desktop`, changed in Settings and kept when Blender's Window menu changes it.
settings_text = (SWIFT / 'SettingsSheet.swift').read_text(encoding='utf-8')
check('DesktopInterfaceSection()' in settings_text and 'Text("Desktop Interface")' in settings_text and
      'SettingsModel.applyDesktopScale()' in window_text and 'desktopScaleChanged()' in window_text and
      '"desktop_scale"' in bridge_text and 'case "interface":' in snapshots_text,
      "9C: Settings › Desktop Interface › Size, sent at start, kept from Blender, and the `interface` step")

# ROUND5 9F (report 34): a `ForEach` row keeps the position it was made with; reading the list it
# came from by that position, when the list is computed from live state, traps once the list
# gets shorter (switching to Texture Paint crashed in QuickActionsRow.actionItems). A row built
# by position may subscript only a snapshot: a local `let`, a stored property or a parameter.
POSITIONAL = re.compile(r'\b(?:ForEach|List)\((?:Array\((?P<src>.+?)\.enumerated\(\)\)|(?P<isrc>[\w.]+)\.indices)\s*,')


def positional_rows(text):
    """Each position-built list in \a text: (line, the names its row subscripts by position and
    that are not snapshots)."""
    for match in POSITIONAL.finditer(text):
        brace = text.index('{', match.end())
        body = text[brace:balanced(text, brace, '{', '}')]
        params = re.match(r'\{\s*([\w, ]+?)\s+in\b', body)
        position = params.group(1).split(',')[0].strip() if params else '_'
        if position == '_':
            continue
        before = text[:match.start()]
        enclosing = before[max(before.rfind('func '), before.rfind('var body'), 0):]
        unsafe = []
        for sub in re.finditer(r'\$?(\w+)(?:\.\w+)*\[([^\]]*)\]', body):
            if not re.search(r'\b%s\b' % re.escape(position), sub.group(2)):
                continue
            base = sub.group(1)
            local = re.search(r'\blet\s+%s\b\s*[:=]' % base, enclosing) or \
                re.search(r'\bfunc\s+\w+\([^)]*\b%s\s*:' % base, enclosing)
            stored = re.search(r'(?m)^\s*(?:@State\s+)?(?:private\s+)?(?:let|var)\s+%s\s*:[^{\n]*$' % base, text)
            if not (local or stored):
                unsafe.append(sub.group(0))
        yield text.count('\n', 0, match.start()) + 1, unsafe


positional = ['%s:%d %s' % (path.name, line, ', '.join(unsafe)) for path in sources()
              for line, unsafe in positional_rows(path.read_text(encoding='utf-8')) if unsafe]
for offender in positional:
    print('%s: a row reads a live list by the position it was made with' % offender)
check(not positional, "9F: no ForEach row reads a live list by a captured position (%d)" % len(positional))

# ROUND5 10E (decision 70): the session log is written in both interfaces, marks use with an
# `active` line, and About says truthfully what it holds: every kind of line a writer uses has
# its phrase in About's description.
LOG_KINDS = {
    'op': 'the commands you ran with their settings', 'modal': 'the commands you ran with their settings',
    'key': 'the commands you ran with their settings', 'menu': 'the commands you ran with their settings',
    'popup': 'the commands you ran with their settings', 'reveal': 'the commands you ran with their settings',
    'busy': 'the commands you ran with their settings',
    'info': 'the messages the app', 'warning': 'the messages the app', 'error': 'the messages the app',
    'document': 'when documents opened and saved', 'save': 'when documents opened and saved',
    'interface': 'which interface showed',
    'window': 'window and viewport sizes', 'viewport': 'window and viewport sizes', 'scene': 'window and viewport sizes',
    'layout': 'layout checks', 'selftest': 'layout checks',
    'snapshot': 'the steps of developer checks',
    'active': 'a mark at most once a minute while the app is in use',
    'input': 'input that arrived while a sheet was open',
    'gizmo': 'the gestures on the navigation gizmo',
    'panel': 'when side panels opened and closed',
    'device': "this iPad's chip and memory",
    'touch': "the kinds of finger gestures on the Desktop Interface's controls and what fingers do",
    'launch': "each launch with the app's version, this iPad's model and the memory available",
    'session': 'whether the last session ended cleanly',
    'exit': 'why iOS ended the app when it reports it',
    'render': 'whether a render could go on in the background and why it paused',
    'memory': 'the memory limits set at launch and what was freed when memory ran low',
    'msgbus': 'how often the app mended links to closed parts of the window',
}
writers = ''.join(path.read_text(encoding='utf-8', errors='replace')
                  for path in (SWIFT.parents[3]).rglob('*') if path.suffix in ('.cc', '.mm', '.swift'))
kinds = set(re.findall(r'WM_native_ui_(?:session_)?log\(\s*"(\w+)"', writers))
# GHOST writes through its native interface's `log` hook (ROUND5 9G.1).
kinds |= set(re.findall(r'ios_log\(\s*@"(\w+)"', (ROOT / 'intern/ghost/intern/GHOST_WindowIOS.mm')
                        .read_text(encoding='utf-8')))
kinds |= set(re.findall(r'\?\s*"(warning)"\s*:\s*"(info)"', writers)[0]) if '"warning" : "info"' in writers else set()
about_description = ' '.join(re.findall(r'"([^"]*)"', about_text[about_text.index('static let description'):
                                                                  about_text.index('/** Write the log out')]))
unlisted = sorted(kinds - set(LOG_KINDS))
check(not unlisted, "10E: every kind of session-log line has a phrase in About (%s)" % unlisted)
missing = sorted(kind for kind in kinds if kind in LOG_KINDS and LOG_KINDS[kind] not in about_description)
check(not missing, "10E: About's description says what each kind of line holds (%s)" % missing)
check('active' in kinds and 'PresenceRecognizer()' in window_text,
      "10E: input writes an `active` line (touches in Swift, keys and pointers in Blender)")
check(re.search(r'static bool session_log_enabled\(\)\s*\{[^}]*return true;', bridge_text) is not None,
      "10E: the session log is written in both interfaces")

# ROUND5 12A/12B (decision 74): a drag on the navigation gizmo is the app's orbit, and only a hold
# opens the menu of views. The pie is opened in one place, the hold's beginning; the pan's handler
# calls the window's drag entry and touches no pie.
gizmo_text = (SWIFT / 'ViewGizmo.swift').read_text(encoding='utf-8')
opens = [m.start() for m in re.finditer(r'pieVisible\s*=\s*true', gizmo_text)]
hold_began = re.search(r'func holdBegan\(model: ShellModel\) \{.*?\n  \}', gizmo_text, re.S)
check(len(opens) == 1 and hold_began is not None and hold_began.start() < opens[0] < hold_began.end(),
      "12B: the pie of views opens only where the hold begins (%d places)" % len(opens))
pan = re.search(r'@objc func drag\(_ gesture: UIPanGestureRecognizer\) \{.*?\n    \}', gizmo_text, re.S)
check(pan is not None and 'dragBegan' in pan.group(0) and 'pieVisible' not in pan.group(0) and
      'release(' not in pan.group(0) and 'hover(' not in pan.group(0),
      "12A: a drag on the gizmo calls the orbit's entry and never the pie")
drag_entry = re.search(r'func dragBegan\(.*?\n  \}', gizmo_text, re.S)
check(drag_entry is not None and 'wm_apple_ios_window_navigation_drag' in drag_entry.group(0),
      "12A: the gizmo's drag goes to the window's one orbit")
ghost_text = (ROOT / 'intern/ghost/intern/GHOST_WindowIOS.mm').read_text(encoding='utf-8')
check(ghost_text.count('orbit_gesture_id = ++') == 1 and '[self orbitBegin:true]' in ghost_text and
      '[self orbitBegin:false]' in ghost_text,
      "12A: one orbit in the window: the view's drag and the gizmo's begin it in one place")

# ROUND5 12D (decisions 78, 79): where the navigation gizmo's parts are is told once, by the code
# that places them; the footprint the shell keeps clear of and framing read that, and nothing works
# the stacking out a second time. A finger or the Pencil that begins on a button is Blender's pointer
# alone: routed before Tweak, the tool or navigation, and no recognizer takes it.
toolbar_gizmo = bridge_text[bridge_text.index('/* The navigation gizmo\'s parts where'):]
toolbar_gizmo = toolbar_gizmo[:toolbar_gizmo.index('data("navigation_footprint"')]
check('ED_view3d_navigate_gizmo_parts(' in toolbar_gizmo and 'gizmo_size_navigate_v3d' not in toolbar_gizmo and
      '28.0f' not in bridge_text and 'mini_axis_type' not in toolbar_gizmo,
      "12D: the gizmo's footprint is the union of the places its group exported, not a second stacking")
framing_12d = bridge_text[bridge_text.index('bool WM_native_ui_view3d_frame_insets('):]
check('ED_view3d_navigate_gizmo_parts(' in framing_12d[:framing_12d.index('\n}\n')],
      "12D: framing keeps clear of the gizmo's buttons, from the places its group exported")
send_event = ghost_text[ghost_text.index('- (void)sendEvent:(UIEvent *)event'):]
send_event = send_event[:send_event.index('\n}\n')]
check(0 < send_event.find('handleNavigationButtonTouch:') < send_event.find('sendFingerTweakTouch:') and
      'if (touch == navigation_button_touch) {\n    return NO;' in ghost_text and
      'native->touch_at(' in ghost_text,
      "12D: a touch on a gizmo's button is routed as a pointer before anything else, and no recognizer takes it")

# ROUND5 13 (decisions 81-84): a finger on Blender's own interface is told apart before it acts.
# It is routed after a gizmo's button and before Tweak, the tool or navigation; no one-finger
# recognizer takes it; one question answers what is under a point (12D's folded in); the drags a
# control takes are a closed list that fails the build when a button type is missing; the run-on
# after a flick uses the orbit's one integrator.
touch_source = (SWIFT.parents[2] / 'editors/interface/interface_touch.cc').read_text(encoding='utf-8')
takes_body = touch_source[touch_source.index('TouchTakes button_type_touch_takes('):]
takes_body = takes_body[:takes_body.index('\n}\n')]
bridge_kinds = bridge_text[bridge_text.index('static NativeTouchKind bridge_touch_main_kind('):]
bridge_kinds = bridge_kinds[:bridge_kinds.index('#  pragma clang diagnostic pop')]
check(0 < send_event.find('handleNavigationButtonTouch:') < send_event.find('handleInterfaceTouch:') <
      send_event.find('sendFingerTweakTouch:') and
      '(touch == interface_touch || interface_gesture) &&' in ghost_text and
      'navigation_part_at' not in ghost_text and 'WM_native_ui_navigation_part_at' not in bridge_text and
      'default:' not in takes_body and 'default:' not in bridge_kinds and
      'pragma clang diagnostic error "-Wswitch"' in touch_source and
      'pragma clang diagnostic error "-Wswitch"' in bridge_text and
      ghost_text.count('UIScrollViewDecelerationRateNormal') == 1 and
      'ios_momentum_step(window, &orbit_velocity' in ghost_text and
      'ios_momentum_step(window, &scroll_velocity' in ghost_text and
      'case "touch":' in snapshots_text,
      "13: a finger on interface is routed after the gizmo's buttons and before Tweak; one question; "
      "closed lists of controls and editors; one run-on integrator; the `touch` step")

# Found by 10A's measurement: the shell skips the first reveal it sees, so Blender publishes one
# (number 0) before any command; otherwise the first command of a session revealed nothing.
check('bridge_reveal_json = "{\\"number\\":0}"' in bridge_text and 'guard let seen = last else' in
      (SWIFT / 'RevealCoordinator.swift').read_text(encoding='utf-8'),
      "The first command of a session reveals: Blender publishes reveal 0 before any command")

# ROUND5 10B (decision 58): in a wide window the viewport lies behind the columns, the sidebars
# over it; Blender is told what they cover as insets, never by a smaller drawable.
columns_text = window_text[window_text.index('private var columnLayout'):window_text.index('static let hierarchyWidth')]
check(columns_text.index('viewportView(leading:') < columns_text.index('HStack(spacing: 0)') and
      'layers(bottom: false, viewport: false)' in columns_text,
      "10B: the viewport fills the window behind the columns, not inside them")
check('WM_native_ui_viewport_insets_step(' in window_text[window_text.index('final class ViewportContainer'):] and 'WM_native_ui_view3d_insets(region' in
      (SWIFT.parents[2] / 'editors/screen/area.cc').read_text(encoding='utf-8') and 'WM_native_ui_view3d_frame_insets(' in
      (SWIFT.parents[2] / 'editors/space_view3d/view3d_navigate_view_all.cc').read_text(encoding='utf-8'),
      "10B: the sidebars reach Blender as insets, read by the visible rectangle and by framing")
# 9G.4: framing keeps clear of the top bar and the controls along the bottom too, by the values the
# navigation gizmo keeps clear of.
frame_text = (SWIFT.parents[1] / 'intern/wm_native_ui.cc').read_text(encoding='utf-8')
frame_text = frame_text[frame_text.index('bool WM_native_ui_view3d_frame_insets('):]
frame_text = frame_text[:frame_text.index('\n}\n')]
check('bridge_top_bar' in frame_text and 'bridge_bottom_tray' in frame_text and
      'bridge_view3d_insets(region' in frame_text,
      "9G.4: framing keeps clear of the sidebars, the top bar and the controls along the bottom")
history_text = (SWIFT.parents[1] / 'intern/wm_files.cc').read_text(encoding='utf-8')
history_text = history_text[history_text.index('static void wm_history_file_update()\n{'):]
history_text = history_text[:history_text.index('\n}\n')]
check('PLATYPUS_SCRATCH_DOCUMENT' in history_text,
      "9G.4: a check launch adds nothing to the recent-files list")
check('images.first' not in image_native_text,
      "9G.4: the Image Editor shows an image only when one is chosen or painted on, never the first one")

check('CheckDocumentBanner.install(in: view)' in window_text and 'PLATYPUS_SCRATCH_DOCUMENT"] != nil' in
      window_text[window_text.index('enum CheckDocumentBanner'):] and 'CheckDocumentBanner.label' in snapshots_text,
      "10E.5: a check launch says on screen that its document is a throwaway copy, left out of the shots")

# ROUND5 10C (decision 59): an editor that takes a share of the window resizes the 3D view once per
# transition, never on the frames of its slide.
viewport_container = window_text[window_text.index('final class ViewportContainer'):window_text.index('struct ViewportView')]
cover_changed = viewport_container[viewport_container.index('private func coverChanged()'):]
cover_changed = cover_changed[:cover_changed.index('\n  }\n')]
check('CADisplayLink' not in cover_changed and 'shownCover' in cover_changed and
      'asyncAfter(deadline: .now() + Self.slideDuration' in cover_changed,
      "10C: the cover reaches Blender once, after the editor slides in and before it slides out")
# ROUND5 14B (decision 86): a sidebar's insets, which redraw overlays only, are eased over the slide
# by the same curve SwiftUI slides the panel with; framing reads where the slide ends.
check('SidebarSlide.progress(' in viewport_container and 'WM_native_ui_viewport_insets_step(' in viewport_container and
      'withAnimation(SidebarSlide.animation)' in (SWIFT / 'ShellPanels.swift').read_text(encoding='utf-8'),
      "14B: a sidebar's insets ease over its slide, on the panel's own curve")

# ROUND5 14C: whatever the shell places on Blender's gizmo takes its place from the easing during a
# slide: every reader of the gizmo's place goes through `navigationGizmoRect` or `navigationFrame`,
# which ride `navigationSlide`. The raw report is read only by them, by the slide's own bookkeeping
# and by the scripts' sampling (which compares the two).
raw = sorted('%s:%d' % (name, number) for name, text in code.items()
             for number, line in enumerate(text.splitlines(), 1)
             if re.search(r'\.navigation(Gizmo|Footprint)\b(?!Rect)', line) and not line.lstrip().startswith(('/*', '*', '//')))
allowed_raw = {'ShellModel.swift', 'Snapshots.swift', 'ViewGizmo.swift'}
check(all(entry.split(':')[0] in allowed_raw for entry in raw) and
      'let g = slide?.gizmo ?? navigationGizmo' in code['ShellModel.swift'] and
      'let f = slide?.footprint ?? navigationFootprint' in code['ShellModel.swift'] and
      'insetsEased?(.step(' in viewport_container and 'insetsEased?(.ended(' in viewport_container and
      'viewport.insetsEased = { [weak model] easing in model?.insetsEased(easing) }' in window_text,
      "14C: the gizmo's place in the shell rides the easing during a slide; raw reads only in %s" % raw)

# ROUND5 10D (decision 60): a resize under way, or while the scene is not in front, never reaches
# Blender; the size is applied once, at the end or on coming back.
viewport_container = window_text[window_text.index('final class ViewportContainer'):window_text.index('struct ViewportView')]
check('if holding && frame.size != appliedSize' in viewport_container and '!= .foregroundActive' in viewport_container
      and 'viewport.resizing = true' in window_text and 'self?.viewport.resizing = false' in window_text and
      'self.viewport.sceneActivated()' in window_text,
      "10D: the drawable is held through a window resize and while the scene is not in front")

# ROUND5 10A (decision 60): every change of the viewport's size is logged with its cause, at the
# one place the shell sets the drawable and where the bridge sees a 3D View's region change.
setters = [name for name, text in code.items() if re.search(r'drawableSize\s*=[^=]', text)]
check(setters == ['DocumentWindow.swift'], "10A: only the viewport's container sets the drawable (%s)" % setters)
container = window_text[window_text.index('final class ViewportContainer'):]
check('noteDrawable(size, from: loggedDrawable)' in container and '"drawable \\(' in container,
      "10A: each change of the drawable writes a `viewport drawable` line")
check('bridge_viewport_regions_note(C);' in bridge_text and '"region {}x{} <- {}x{} ({})"' in bridge_text,
      "10A: each change of a 3D View region's size writes a `viewport region` line")
check('case "sidebar":' in snapshots_text and 'case "mark":' in snapshots_text and
      'case "editor" where words.first == "nodes":' in snapshots_text,
      "10A: the snapshot steps `sidebar properties|outliner open|close`, `editor nodes`, `mark`")

# ROUND6 0.1 (A2): the iPad's Objective-C sources are built without ARC (no target turns it on), so
# an object kept in an instance variable or a file's static must be owned: retained, copied or made
# with alloc/new. One kept straight from a convenience constructor (`[NSString stringWith...]`,
# `[CALayer layer]`, `[NSTimer scheduledTimer...]`) is freed with the autorelease pool, or when
# whatever else holds it lets go, and is read afterwards: "Cancel" above the keyboard did that.
def c_code_only(text):
    """\a text with C comments, strings and character literals blanked (C comments do not nest)."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
        elif text[i] in '"\'':
            quote, j = text[i], i + 1
            while j < n and text[j] not in quote + '\n':
                j += 2 if text[j] == '\\' else 1
            j += 1
        else:
            out.append(text[i])
            i += 1
            continue
        out.append(''.join(c if c == '\n' else ' ' for c in text[i:j]))
        i = j
    return ''.join(out)


def c_balanced(text, start):
    """The end (exclusive) of the bracket opened at \a start, in text without strings or comments."""
    pairs = {'[': ']', '(': ')', '{': '}'}
    stack, i = [], start
    while i < len(text):
        if text[i] in pairs:
            stack.append(pairs[text[i]])
        elif stack and text[i] == stack[-1]:
            stack.pop()
            if not stack:
                return i + 1
        i += 1
    return len(text)


def c_top_level_split(text, separators):
    """\a text split at the characters in \a separators that are outside any bracket."""
    parts, depth, last = [], 0, 0
    for i, c in enumerate(text):
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        elif depth == 0 and c in separators:
            parts.append(text[last:i])
            last = i + 1
    parts.append(text[last:])
    return parts


def unowned_message(arm):
    """Whether the expression \a arm is one message whose result the caller does not own."""
    arm = arm.strip()
    while True:  # Casts: `(MTLCommandQueue *)[device newCommandQueue]`.
        cast = re.match(r'\(\s*[A-Za-z_][\w<>, ]*\s*\*?\s*\)\s*(?=\[)', arm)
        if not cast:
            break
        arm = arm[cast.end():].strip()
    if arm.startswith('@['):
        return True  # An array literal is autoreleased.
    if not arm.startswith('[') or c_balanced(arm, 0) != len(arm):
        return False
    inner = arm[1:-1].strip()
    if inner.startswith('['):
        receiver_end = c_balanced(inner, 0)
        receiver, rest = inner[:receiver_end], inner[receiver_end:]
    else:
        match = re.match(r'[\w.>-]+', inner)
        if not match:
            return False
        receiver, rest = match.group(0), inner[match.end():]
    selector = re.match(r'\s*(\w+)', rest)
    if not selector:
        return False
    selector = selector.group(1)
    if selector in ('retain', 'copy', 'mutableCopy') or selector.startswith(('alloc', 'new')):
        return False
    if selector.startswith('init') and re.fullmatch(r'\[\s*[\w.]+\s+(alloc|new)\s*\]', receiver):
        return False
    return True


MRC_SOURCES = (sorted((ROOT / 'intern/ghost/intern').glob('*IOS*.mm')) +
               sorted((ROOT / 'source/blender/windowmanager/apple_ios').glob('*.mm')))
MRC_HEADERS = (sorted((ROOT / 'intern/ghost/intern').glob('*IOS*.hh')) +
               sorted((ROOT / 'source/blender/windowmanager/apple_ios').glob('*.hh')))
mrc_cmake = '\n'.join(path.read_text(encoding='utf-8') for path in
                      (ROOT / 'source/creator/CMakeLists.txt', ROOT / 'intern/ghost/CMakeLists.txt',
                       ROOT / 'source/blender/windowmanager/CMakeLists.txt'))
check(len(MRC_SOURCES) >= 11 and 'fobjc-arc' not in mrc_cmake and
      not re.search(r'CLANG_ENABLE_OBJC_ARC\s+"?YES', mrc_cmake),
      "R6 0.1: the iPad's Objective-C sources are built without ARC (%d files)" % len(MRC_SOURCES))
# A class's instance variables: the braces after `@interface Name : Super <Protocols>` or
# `@implementation Name`, with the preprocessor's lines (an `#if` between the two) left out.
ivar_block = re.compile(r'@(?:interface|implementation)\s+\w+(?:\s*\([^)]*\))?[^;@{}()]*\{')
mrc_texts = {path: re.sub(r'^[ \t]*#.*$', '', c_code_only(path.read_text(encoding='utf-8')), flags=re.M)
             for path in MRC_SOURCES + MRC_HEADERS}
kept = set()
for text in mrc_texts.values():
    for block in ivar_block.finditer(text):
        body = text[block.end() - 1:c_balanced(text, block.end() - 1)]
        for statement in body[1:-1].split(';'):
            statement = statement.strip()
            if re.match(r'(?:[A-Z]\w*|id)\b', statement):
                kept.update(re.findall(r'\*\s*(\w+)\s*(?=,|$)', statement))
                if statement.startswith('id'):
                    kept.update(re.findall(r'>?\s*(\w+)\s*(?=,|$)', statement.split('>', 1)[-1]))
    kept.update(re.findall(r'^static\s+(?:[A-Z]\w*|id)\b[^;=(]*?\*?\s*(\w+)\s*(?:=[^;]*)?;', text, re.M))
unowned = []
for path in MRC_SOURCES:
    text = mrc_texts[path]
    for match in re.finditer(r'(?<![\w.])(\w+)\s*=(?!=)', text):
        if match.group(1) not in kept or text[:match.start()].rstrip().endswith(('*', '>')):
            continue
        end = match.end()
        while end < len(text) and text[end] != ';':
            end = c_balanced(text, end) if text[end] in '([{' else end + 1
        arms = c_top_level_split(text[match.end():end], '?:')
        if any(unowned_message(arm) for arm in arms):
            unowned.append('%s:%d %s' % (path.name, text.count('\n', 0, match.start()) + 1, match.group(1)))
for offender in unowned:
    print('%s: an instance variable or static keeps an object it does not own' % offender)
check('original_text' in kept and 'dialog_timer' in kept and '_blue' in kept and not unowned,
      "R6 0.1: every object kept in an instance variable or static of the iPad's Objective-C is "
      "owned (%d names; %s)" % (len(kept), unowned))
ghost_window_text = mrc_texts[ROOT / 'intern/ghost/intern/GHOST_WindowIOS.mm']
detach = ghost_window_text[ghost_window_text.index('- (void)detachBlender'):]
detach = detach[:detach.index('\n}\n')]
check('[original_text release];' in detach,
      "R6 0.1: the text Cancel puts back is released when Blender's window goes")

# ROUND6 0.4 (E5): the shell compares Blender's context mode (`ShellModel.mode`, from
# `CTX_data_mode_string`) only with strings Blender gives it. "pose" for Pose Mode's "posemode", and
# a prefix "edit_" no mode has, kept Pose Mode's transform settings away for good. Every literal
# compared with the mode, listed with it, or used as its prefix or suffix is one of Blender's.
context_source = (ROOT / 'source/blender/blenkernel/intern/context.cc').read_text(encoding='utf-8')
mode_table = context_source[context_source.index('static const char *data_mode_strings[] = {'):]
mode_strings = set(re.findall(r'"(\w+)"', mode_table[:mode_table.index('};')]))
check(len(mode_strings) >= 27 and {'posemode', 'objectmode', 'mesh_edit'} <= mode_strings,
      "R6 0.4: Blender's context mode strings read (%d)" % len(mode_strings))
mode_expr = r'(?:\b(?:model|self|\$0|shell\.model)\.mode|\bcontextMode)\b'
mode_uses, wrong_modes = 0, []
for path in sources():
    text = path.read_text(encoding='utf-8')
    text = re.sub(r'//[^\n]*', '', text)
    found = []
    found += [(m.start(), [m.group(1)]) for m in re.finditer(mode_expr + r'\s*[!=]=\s*"([^"]*)"', text)]
    found += [(m.start(), [m.group(1)]) for m in re.finditer(r'"([^"]*)"\s*[!=]=\s*' + mode_expr, text)]
    found += [(m.start(), re.findall(r'"([^"]*)"', m.group(1)))
              for m in re.finditer(r'\[([^\[\]]*)\]\.contains\(' + mode_expr + r'\)', text)]
    for m in re.finditer(mode_expr + r'\.has(Prefix|Suffix)\("([^"]*)"\)', text):
        affix = m.group(2)
        matched = [mode for mode in mode_strings
                   if (mode.startswith(affix) if m.group(1) == 'Prefix' else mode.endswith(affix))]
        found.append((m.start(), [] if matched else [m.group(0)]))
        mode_uses += 1
    for start, literals in found:
        mode_uses += len(literals)
        wrong_modes += ['%s:%d %s' % (path.name, text.count('\n', 0, start) + 1, literal)
                        for literal in literals if literal not in mode_strings]
check(not wrong_modes,
      "R6 0.4: every string the shell compares with Blender's mode is one Blender gives (%d uses; %s)"
      % (mode_uses, wrong_modes))
# ROUND6 MODE-2 (E5): what a mode has comes from Blender, never from the mode's name in Swift. The
# general case of 0.4: no literal at all is compared with the mode, listed with it or used as its
# affix (0.4 allowed Blender's own strings); the transform settings the row shows are those
# Blender's header draws in the mode, one by one (the `HEADER` walk's `shell:` parts), and the
# bridge's flags say the rest (brush strokes, text editing, the select menu, the Item card,
# shapes into a mesh, mesh select mode).
check(mode_uses == 0,
      "R6 MODE-2: the shell compares no string with Blender's mode (%d uses: %s)"
      % (mode_uses, wrong_modes))
row_text = (SWIFT / 'ToolSettingsRow.swift').read_text(encoding='utf-8')
model_text = (SWIFT / 'ShellModel.swift').read_text(encoding='utf-8')
properties_text = (ROOT / 'source/blender/editors/interface/interface_native_properties.cc').read_text(
    encoding='utf-8')
check('shell.panels.header.headerHas($0)' in row_text and 'transform_settings' not in model_text and
      'transform_settings' not in bridge_text and 'static const char *header_shell_part(' in properties_text and
      '"shell:" + part' in properties_text,
      "R6 MODE-2: the row's transform settings are those Blender's header draws in the mode")
flags_mode2 = ('brush_strokes', 'text_editing', 'select_menu', 'item_card', 'adds_into_mesh')
check(all('data("%s"' % flag in bridge_text and 'flag("%s")' % flag in model_text for flag in flags_mode2),
      "R6 MODE-2: the bridge publishes what a mode has, and the shell reads it")

# ROUND6 0.7 (C1, part): Settings › Quick Actions hides the actions, never a waiting operation's
# Confirm and Cancel, which are the way out of it. Every place the shell reads the setting to hide
# something keeps the modal bar (`modalKey`) on the same line.
quick_gates = []
for path in sources():
    if path.name == 'SettingsSheet.swift':
        continue  # Where the setting is stored and its toggle.
    for number, line in enumerate(code_only(path.read_text(encoding='utf-8')).splitlines(), 1):
        if 'showQuickActions' in line and '@AppStorage' not in line:
            quick_gates.append((path.name, number, 'modalKey' in line))
check(len(quick_gates) >= 2 and all(kept for _, _, kept in quick_gates),
      "R6 0.7: every use of the Quick Actions setting keeps a waiting operation's Confirm and Cancel (%s)"
      % ['%s:%d' % (name, number) for name, number, kept in quick_gates if not kept])

# ROUND6 TOUCH-1 (A4, E8, X1; decision R6-1): fingers use the tool until an Apple Pencil is seen,
# and a finger's tap always selects. What fingers do is read in one place, which knows "nobody chose
# yet"; nothing else reads the stored choice as a plain bool (a missing key read as false was the
# fault: Pencil Only on an iPad that never saw a Pencil).
plain_reads = []
for path in sources():
    for number, line in enumerate(code_only(path.read_text(encoding='utf-8')).splitlines(), 1):
        if 'fingerUsesToolKey' in line and path.name not in ('SettingsSheet.swift', 'ImageEditor.swift'):
            plain_reads.append('%s:%d' % (path.name, number))
        if re.search(r'bool\(forKey:\s*(SettingsModel\.)?fingerUsesToolKey', line):
            plain_reads.append('%s:%d' % (path.name, number))
settings_text = (SWIFT / 'SettingsSheet.swift').read_text(encoding='utf-8')
image_text = (SWIFT / 'ImageEditor.swift').read_text(encoding='utf-8')
check(not plain_reads and 'static var fingerUsesTool: Bool {' in settings_text and
      'defaults.object(forKey: fingerUsesToolKey) as? Bool' in settings_text and
      '!defaults.bool(forKey: pencilSeenKey)' in settings_text and
      'private var fingerChoice: Bool?' in image_text and 'view.fingerPaints = SettingsModel.fingerUsesTool' in image_text,
      "R6 TOUCH-1: what fingers do is read in one place that knows nobody chose (%s)" % plain_reads)
# Every place a person picks the touch setting keeps it: Settings' rows, the header's One Finger, a
# message's Keep Fingers on Tools. `setFingerUsesTool` alone (this launch, not kept) is for the
# Pencil being seen, the window's first layout and check scripts.
topbar_text = (SWIFT / 'TopBar.swift').read_text(encoding='utf-8')
one_finger = topbar_text[topbar_text.index('Label("One Finger"') - 600:topbar_text.index('Label("One Finger"')]
check('commands.chooseFingerUsesTool(true)' in one_finger and 'commands.chooseFingerUsesTool(false)' in one_finger and
      'commands.setFingerUsesTool(' not in one_finger and
      'model.choose(.pencilOnly)' in settings_text and 'model.choose(.pencilAndFingers)' in settings_text and
      'model.touchInput = .' not in settings_text and
      'ShellCommands.current?.chooseFingerUsesTool(true)' in (SWIFT / 'ShellModel.swift').read_text(encoding='utf-8'),
      "R6 TOUCH-1: every choice of what fingers do is kept, wherever it is made")
# The header's One Finger is in More at every rung, not only the narrowest.
overflow = topbar_text[topbar_text.index('private var overflowMenu: some View {'):]
rung_blocks = []
for m in re.finditer(r'if (?:!shown\.shading \|\| )?model\.headerRung == 0 \{', overflow):
    rung_blocks.append((m.start(), balanced(overflow, m.end() - 1, '{', '}')))
label_at = overflow.index('Label("One Finger"')
check(rung_blocks and not any(start < label_at < end for start, end in rung_blocks),
      "R6 TOUCH-1: One Finger is offered at every header rung")
# The Pencil is seen where the window first meets it (a touch, a hover, a squeeze or tap), and the
# shell hears of it by the one name; a finger's tap on an iPad where fingers move the view clicks.
ghost_r6 = (ROOT / 'intern/ghost/intern/GHOST_WindowIOS.mm').read_text(encoding='utf-8')
tap_body = ghost_r6[ghost_r6.index('- (void)handleTap:(GHOSTUITapGestureRecognizer *)sender'):]
tap_body = tap_body[:tap_body.index('\n}\n')]
check(ghost_r6.count('ios_pencil_seen();') >= 4 and '@"GHOSTIOSPencilSeen"' in ghost_r6 and
      'Notification.Name("GHOSTIOSPencilSeen")' in (SWIFT / 'DocumentWindow.swift').read_text(encoding='utf-8') and
      'UIUserInterfaceIdiomPhone' not in tap_body and 'viewClickAt:' in tap_body,
      "R6 TOUCH-1: the first Pencil is told to the shell, and a finger's tap clicks on an iPad too")
# A finger's drag that begins on a gizmo's handle drags it where fingers move the view: the pan asks
# before it orbits, from where the finger landed, as Blender answers it.
pan_body = ghost_r6[ghost_r6.index('- (void)handlePan:(GHOSTUIPanGestureRecognizer *)sender'):]
pan_body = pan_body[:pan_body.index('\n}\n')]
check(0 < pan_body.find('viewGizmoDrag:') < pan_body.find('handleNavigationDrag:') and
      '[self touchAnswerAt:view_finger_start].gizmo' in ghost_r6 and 'r_answer->gizmo =' in bridge_text,
      "R6 TOUCH-1: a finger's drag from a gizmo's handle drags it before the view would orbit")

# ROUND6 TOUCH-2 (A1, E1): a second finger never throws work away. A finger on the tool presses
# nothing as it lands; a second finger before the press sends nothing; after it, Escape only for a
# drag of the tool's own; the palm under a Pencil takes no part; the shell's hold ends the finger.
def objc_method(text, signature):
    body = text[text.index(signature):]
    return body[:body.index('\n}\n')]


began = objc_method(ghost_r6, '- (void)fingerToolBegan:(CGPoint)location')
second = objc_method(ghost_r6, '- (void)fingerToolSecondFinger')
send_event_r6 = objc_method(ghost_r6, '- (void)sendEvent:(UIEvent *)event')
check('generateUserInputEvents' not in began and 'touchAnswerAt:location].modal' in began,
      "R6 TOUCH-2: a finger on the tool presses nothing as it lands, and notes whether an operator waits")
owned_at = second.find('if (finger_drag_owned)')
check(0 < second.find('if (finger_pending)') < owned_at < second.find('[self cancelPencilStroke];') and
      'CANCEL_TOOL' not in second and 'finger_drag_owned = !finger_landed_modal;' in ghost_r6,
      "R6 TOUCH-2: a second finger sends Escape only for a drag the finger began with nothing waiting")
check('[self fingerToolSecondFinger];' in send_event_r6 and
      'current_pencil_touch.type == UITouchTypeDirect) {\n      [self cancelPencilStroke];' not in send_event_r6 and
      send_event_r6.find('[palm_touches addObject:touch]') < send_event_r6.find('handleNavigationButtonTouch:') and
      'if ([palm_touches containsObject:touch]) {\n    return NO;' in ghost_r6,
      "R6 TOUCH-2: the second finger goes through the one rule, and the palm is kept from everything first")
check('wm_apple_ios_window_hold_took_touch(model.window)' in (SWIFT / 'DocumentWindow.swift').read_text(encoding='utf-8'),
      "R6 TOUCH-2: the shell's hold ends what the finger began, so no click follows the menu")

# ROUND6 TOUCH-3 (C2, A12): the touch gestures are the shell's, whatever the key map; Undo and Redo
# pass one gate, wherever they are asked for. The window sends Blender no tap or edge event, no key
# map preset binds one, and no edge recognizer is left; the taps run what the buttons run.
ghost_r6 = (ROOT / 'intern/ghost/intern/GHOST_WindowIOS.mm').read_text(encoding='utf-8')
check(not re.search(r'GHOST_kEvent(Two|Three|Four)FingerTap', ghost_r6) and 'GHOST_EventTouch>' not in ghost_r6 and
      'UIScreenEdgePanGestureRecognizer' not in ghost_r6 and
      '@"GHOSTIOSFingersTapped"' in ghost_r6,
      "R6 TOUCH-3: the window gives the finger taps to the shell, not to Blender's key maps")
presets = sorted((ROOT / 'scripts/presets/keyconfig/keymap_data').glob('*.py'))
touch_bound = ['%s:%d' % (path.name, number) for path in presets
               for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1) if "'TOUCH_" in line]
check(len(presets) >= 2 and not touch_bound,
      "R6 TOUCH-3: no key map preset binds a touch gesture (%s)" % touch_bound)
window_r6 = (SWIFT / 'DocumentWindow.swift').read_text(encoding='utf-8')
tapped = window_r6[window_r6.index('@objc private func fingersTapped'):]
tapped = tapped[:tapped.index('\n  }\n')]
undo_runs = set()
for path in sources():
    undo_runs |= set(re.findall(r'Operators\.run\("(ED_OT_(?:undo|redo))"\)', path.read_text(encoding='utf-8')))
check('Operators.run("ED_OT_undo")' in tapped and 'Operators.run("ED_OT_redo")' in tapped and
      undo_runs == {'ED_OT_undo', 'ED_OT_redo'} and 'Notification.Name("GHOSTIOSFingersTapped")' in window_r6,
      "R6 TOUCH-3: the taps run Undo and Redo as their buttons do")
views_text = (SWIFT.parents[1] / 'intern/wm_native_ui_views.cc').read_text(encoding='utf-8')
run_body = views_text[views_text.index('bool operator_run(bContext *C,'):]
run_body = run_body[:run_body.index('\n}\n')]
check(0 < run_body.find('WM_native_ui_undo_refusal(C)') < run_body.find('WM_operator_poll(C, ot)') and
      'WM_native_ui_is_undo_command(idname)' in views_text[views_text.index('operators.live = '):] and
      'WM_native_ui_undo_refusal(C); !refusal.empty()' in bridge_text and 'ELEM(target, "undo", "redo") ||' in bridge_text,
      "R6 TOUCH-3: one gate for Undo and Redo, answered at once, never held back")

# ROUND6 TOUCH-4 (A13, E2, H11): a finger's tolerances are a finger's. Nothing of the bridge or the
# shell writes the person's click, drag or motion thresholds or tooltips; every finger GHOST sends
# Blender is marked as one; the WM picks a finger's distances in points where the event says so.
writers_u = []
for path in [SWIFT.parents[1] / 'intern' / name for name in ('wm_native_ui.cc', 'wm_native_ui_views.cc',
                                                              'wm_apple_ios_native.cc',
                                                              'wm_apple_ios_finger_tweak.cc')]:
    for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        if re.search(r'U\.(drag_threshold\w*|move_threshold|dbl_click_time)\s*=|U\.flag\s*&=\s*~USER_TOOLTIPS', line):
            writers_u.append('%s:%d' % (path.name, number))
        if path.name == 'wm_apple_ios_finger_tweak.cc' and 'U.drag_threshold' in line:
            writers_u.append('%s:%d (a finger measured with the tablet\'s threshold)' % (path.name, number))
check(not writers_u, "R6 TOUCH-4: the person's thresholds and tooltips are theirs, and a finger is measured as one (%s)"
      % writers_u)
query_text = (SWIFT.parents[1] / 'intern/wm_event_query.cc').read_text(encoding='utf-8')
system_text = (SWIFT.parents[1] / 'intern/wm_event_system.cc').read_text(encoding='utf-8')
drag_body = query_text[query_text.index('int WM_event_drag_threshold(const wmEvent *event)'):]
drag_body = drag_body[:drag_body.index('\n}\n')]
dbl_body = system_text[system_text.index('static bool wm_event_is_double_click('):]
dbl_body = dbl_body[:dbl_body.index('\n}\n')]
check('event->tablet.is_finger' in drag_body and 'WM_event_finger_double_tap_distance()' in dbl_body and
      'wm_cursor_motion_threshold()' in query_text[query_text.index('bool WM_cursor_test_motion_and_update('):] and
      'Active == GHOST_kTabletModeFinger' in system_text,
      "R6 TOUCH-4: drag, double tap and same place are a finger's when the event is one")
# Every place GHOST builds a finger's event marks it: the tool finger, the tap, the gizmo's drag,
# the interface (13B) through the pointer path while a finger sends it.
for name in ('- (void)fingerToolPress', '- (void)viewClickAt:(CGPoint)location'):
    body = objc_method(ghost_r6, name)
    check('[self fingerTabletData]' in body and 'GHOST_TABLET_DATA_NONE' not in body,
          "R6 TOUCH-4: %s marks a finger's event" % name.split(')')[1].split(':')[0])
move_body = objc_method(ghost_r6, '- (void)sendPointerMove:(CGPoint)location')
check('pointer_finger ? [self fingerTabletData]' in move_body and 'pointer_finger = touch.type == UITouchTypeDirect;' in ghost_r6,
      "R6 TOUCH-4: a finger on Blender's interface is marked as one through the pointer path")
keymap_text = (ROOT / 'scripts/presets/keyconfig/keymap_data/blender_default.py').read_text(encoding='utf-8')
check("(params.use_mouse_emulate_3_button or _touch_platform()) and params.select_mouse == 'LEFTMOUSE'" in keymap_text,
      "R6 TOUCH-4: a double tap on an edge selects its loop on the iPad (PLAN 4.3)")
check('"Select Menu…"' in (SWIFT / 'DocumentWindow.swift').read_text(encoding='utf-8') and
      'startswith("select_menu:")' in bridge_text and 'RNA_boolean_set(&props, "enumerate", true);' in bridge_text,
      "R6 TOUCH-4: the long-press menu has Select Menu…, the list of what is under the finger")

# ROUND6 TOUCH-5 (A3, C1): a waiting operation always shows itself and can always be ended. The bar
# leaves out only a listed family, each with why; no name test hides polyline gestures, Walk, Fly or
# Adjust; a command waiting for a click and every gesture waiting for its drag have one hint with
# Cancel; two fingers' navigation passes a command waiting for a click.
waiting_body = bridge_text[bridge_text.index('wmOperator *bridge_waiting_operator(wmWindow *win)'):]
waiting_body = waiting_body[:waiting_body.index('\n}\n')]
exclusions = bridge_text[bridge_text.index('static const BridgeBarExclusion bridge_bar_exclusions[] = {'):]
exclusions = exclusions[:exclusions.index('};')]
rows = re.findall(r'\{"([^"]+)",\s*(?:true|false),\s*"([^"]*)', exclusions)
check(len(rows) >= 5 and all(reason for _pattern, reason in rows) and
      'find("select")' not in waiting_body and 'find("gesture")' not in waiting_body and
      '"WM_OT_"' not in exclusions and 'bridge_bar_excluded(op->type->idname)' in waiting_body and
      'WM_GESTURE_POLYLINE' in waiting_body,
      "R6 TOUCH-5: the bar leaves out only a listed family, each with why (%d)" % len(rows))
check('WM_event_wait_for_input_operator(win)' in bridge_text and 'bridge_waiting_hint(' in bridge_text and
      'bridge_drag_hint(' not in bridge_text,
      "R6 TOUCH-5: one waiting state for a click and for a drag, shown with Cancel")
check('ui_handler_wait_for_input &&\n            (ISMOUSE_GESTURE(event->type) || event->type == NDOF_MOTION)' in system_text,
      "R6 TOUCH-5: two fingers navigate while a command waits for a click")

# ROUND6 TOUCH-6 (C5, A9, E6 ii, H10): the wait for the finger is the event system's. No operator
# keeps its own copy of the wait (only Add Object's depth step, a hover phase inside a drag-started
# operation, asks whether the input is a touch); the gate is "a touch started this", never the
# interface or the editor; the modal handler turns a waiting operation's press into "start here" and
# the lift into the confirmation; operations that can measure from the landing do so on "start here".
waits = []
for path in sorted((ROOT / 'source/blender/editors').rglob('*.cc')):
    text = path.read_text(encoding='utf-8', errors='replace')
    if 'WM_native_awaits_press' in text or 'WM_native_event_is_left_press' in text or 'awaits_press' in text:
        waits.append(path.name)
check(waits == ['view3d_placement.cc'], "R6 TOUCH-6: no operator keeps its own wait for the finger (%s)" % waits)
gate = (SWIFT.parents[1] / 'intern/wm_native_interface.cc').read_text(encoding='utf-8')
gate = gate[gate.index('bool WM_native_awaits_press('):]
gate = gate[:gate.index('\n}\n')]
check('WM_event_touch_input()' in gate and 'replaces_redo_panel' not in gate and 'SPACE_' not in gate,
      "R6 TOUCH-6: the wait is gated on a touch having started it, not on the interface or editor")
check('wm_operator_touch_arm(C, op, event);' in system_text and 'WM_EVENT_TOUCH_START' in system_text and
      'WM_EVENT_TOUCH_CONFIRM' in system_text and 'wm_touch_wait_no_keymap[]' in system_text and
      'ended on touch-down' in system_text,
      "R6 TOUCH-6: the modal handler waits for the finger for every operation of the class")
for name in ('editors/transform/transform.cc', 'editors/mesh/editmesh_bevel.cc', 'editors/mesh/editmesh_inset.cc'):
    check('WM_event_is_touch_start(event)' in (ROOT / 'source/blender' / name).read_text(encoding='utf-8'),
          "R6 TOUCH-6: %s measures from where the finger landed" % name.rsplit('/', 1)[1])

# ROUND6 TOUCH-7 (C4, E6 i, A10): a command that needs a place asks for one. Every operator whose
# `invoke` reads the pointer (`event->mval`, `event->xy`) and acts at once without going modal, and
# that a menu draws, either depends on the cursor (it then waits for one tap from a menu, Search or
# the bar) or is in this reviewed table with why its reading is harmless. A new one fails here.
POINTER_READERS_REVIEWED = {
    # The pointer is read only for a mode the menus never give.
    'ACTION_OT_select_leftright': "only for mode Check; menus give Before or After Current Frame",
    'GRAPH_OT_select_leftright': "only for mode Check; menus give Before or After Current Frame",
    'NLA_OT_select_leftright': "only for mode Check; menus give Before or After Current Frame",
    'NLA_OT_select_box': "only with tweak, which no menu sets",
    'SEQUENCER_OT_delete': "only to leave out the markers' row along the bottom",
    # Toward the pointer, else the middle: from a menu the pointer is the view's middle (A10).
    'CLIP_OT_view_zoom_in': "zooms toward the pointer, the view's middle from a menu",
    'CLIP_OT_view_zoom_out': "zooms toward the pointer, the view's middle from a menu",
    'IMAGE_OT_view_zoom_in': "zooms toward the pointer, the view's middle from a menu",
    'IMAGE_OT_view_zoom_out': "zooms toward the pointer, the view's middle from a menu",
    'VIEW2D_OT_zoom_in': "zooms toward the pointer, the view's middle from a menu",
    'VIEW2D_OT_zoom_out': "zooms toward the pointer, the view's middle from a menu",
    'RENDER_OT_view_show': "places the render window only",
    'OBJECT_OT_collection_instance_add': "places the instance under the pointer, the view's middle from a menu",
    # Editors whose menus are Blender's own (the Desktop Interface): there the pointer is at the
    # menu, in that editor, as on the desktop.
    'NODE_OT_clipboard_paste': "Blender's own Node Editor menu: pastes by the pointer, as on the desktop",
    'NODE_OT_join': "Blender's own Node Editor menu: the frame by the pointer, as on the desktop",
    'NODE_OT_select': "Blender's own Node Editor menu, as on the desktop",
    'SEQUENCER_OT_gap_insert': "Blender's own Sequencer menu: the side from the pointer, as on the desktop",
    'SEQUENCER_OT_gap_remove': "Blender's own Sequencer menu: the side from the pointer, as on the desktop",
    'SEQUENCER_OT_paste': "Blender's own Sequencer menu, as on the desktop",
    'SEQUENCER_OT_retiming_key_delete': "Blender's own Sequencer menu, as on the desktop",
    'SEQUENCER_OT_split': "Blender's own Sequencer menu: the side from the pointer, as on the desktop",
}
invoke_re = re.compile(r'^(?:static\s+)?(?:wmOperatorStatus|int)\s+(\w+)\s*\(\s*bContext\s*\*\s*\w*\s*,\s*'
                       r'wmOperator\s*\*\s*\w*\s*,\s*const\s+wmEvent\s*\*\s*(\w+)\s*\)\s*\n?\{', re.M)
invoke_bodies, op_defs = {}, []
for path in sorted((ROOT / 'source/blender/editors').rglob('*.cc')):
    text = path.read_text(encoding='utf-8', errors='replace')
    for match in invoke_re.finditer(text):
        end = c_balanced(text, match.end() - 1)
        invoke_bodies[match.group(1)] = (text[match.end():end], match.group(2))
    for match in re.finditer(r'ot->idname\s*=\s*"(\w+)";', text):
        start, end = text.rfind('\n{', 0, match.start()), text.find('\n}', match.end())
        op_defs.append((match.group(1), text[start:end]))
menu_ops = set()
for path in (ROOT / 'scripts/startup/bl_ui').glob('*.py'):
    menu_ops |= set(re.findall(r'\.operator(?:_menu_enum|_enum)?\(\s*"([a-z_0-9]+\.[a-z_0-9]+)"',
                               path.read_text(encoding='utf-8')))
pointer_unflagged, readers = [], 0
for idname, definition in op_defs:
    invoke = re.search(r'ot->invoke\s*=\s*(\w+);', definition)
    if not invoke or invoke.group(1) not in invoke_bodies:
        continue
    body, event = invoke_bodies[invoke.group(1)]
    if not re.search(r'\b%s->(mval|xy)\b' % event, body) or 'WM_event_add_modal_handler' in body or \
            'OPERATOR_RUNNING_MODAL' in body or re.search(r'\bWM_gesture_\w+_invoke\(', body):
        continue
    module, name = idname.split('_OT_')
    if '%s.%s' % (module.lower(), name) not in menu_ops:
        continue
    readers += 1
    if 'DEPENDS_ON_CURSOR' in definition or 'depends_on_cursor' in definition:
        continue
    if idname not in POINTER_READERS_REVIEWED:
        pointer_unflagged.append(idname)
check(readers >= 20 and not pointer_unflagged,
      "R6 TOUCH-7: every menu command that reads the pointer at invoke asks for a tap or is reviewed "
      "(%d; not: %s)" % (readers, pointer_unflagged))
actions_text = (ROOT / 'scripts/startup/bl_ui/native_actions.py').read_text(encoding='utf-8')
check("'DEPENDS_ON_CURSOR' in action.operator().bl_options" in actions_text and
      'reason[0] == \'\\x01\'' in bridge_text and 'WM_OT_native_action_at_tap' in bridge_text and
      'did nothing here' in actions_text,
      "R6 TOUCH-7: the bar's commands that need a place ask for a tap, and a silent cancel is said")
cursor_body = bridge_text[bridge_text.index('void bridge_menu_cursor_set(bContext *C'):]
cursor_body = cursor_body[:cursor_body.index('\n}\n')]
check('bridge_pointer_to_view_middle(win);' in cursor_body and
      'nothing there to act on' in system_text,
      "R6 TOUCH-7: a command with no position has the view's middle, never a stale pointer")

# ROUND6 TOUCH-8 (E3, E12, H5, A5, A11; decision R6-8): Shift, Ctrl and Alt for a finger are real
# keys GHOST holds, latches or locks, in both interfaces; GHOST owns what is held and lets go on
# leaving the foreground and when the window goes; a latch lasts one action; the held Snap and
# Precision go through the same keys and are let go when their button goes.
release_keys = objc_method(ghost_r6, '- (void)releaseKeys')
check('GHOST_ios_window_sticky_release_all(window)' in release_keys and
      'GHOST_ios_sticky_action_ended(window);' in ghost_r6 and
      'GHOST_ios_window_sticky_modifier(window, index, down ? GHOST_kStickyFingerDown : GHOST_kStickyHeldUp)' in ghost_r6,
      "R6 TOUCH-8: GHOST owns the held keys: let go on resign and detach, a latch after one action")
rails_r6 = (SWIFT / 'Rails.swift').read_text(encoding='utf-8')
window_t8 = (SWIFT / 'DocumentWindow.swift').read_text(encoding='utf-8')
sticky = rails_r6[rails_r6.index('struct StickyModifierKeys: View {'):]
modifier_button = rails_r6[rails_r6.index('private func modifierButton(_ key: String'):]
modifier_button = modifier_button[:modifier_button.index('\n  }\n')]
check('.onDisappear' in sticky and 'wm_apple_ios_window_sticky_modifier(model.window, Int32(index), 3)' in sticky and
      '.onDisappear' in modifier_button and
      'StickyModifierKeys(model: model)' in window_t8 and 'model.viewportReady && controlsShown' in window_t8 and
      'StickyModifierKeys(model: model, embedded: true)' in (SWIFT / 'DesktopCluster.swift').read_text(encoding='utf-8'),
      "R6 TOUCH-8: the keys are drawn in both interfaces (the Desktop Interface's in its cluster, DESK-1) and "
      "let go when their buttons go")

# ROUND6 TOUCH-9 (A8, E14): what a brush will touch is drawn without hover. Every gate on hover for
# what Blender draws at the pointer goes through one rule, which also shows it while a button is
# down; the brush's ring shows at the last contact for a moment after its size changed.
hover_gates = []
for path in sorted((ROOT / 'source/blender').rglob('*.cc')):
    text = path.read_text(encoding='utf-8', errors='replace')
    if 'pointer_hovering()' in text:
        hover_gates.append(path.name)
draw_text = (ROOT / 'source/blender/windowmanager/intern/wm_draw.cc').read_text(encoding='utf-8')
shown_body = draw_text[draw_text.index('bool wm_pointer_cursor_shown('):]
shown_body = shown_body[:shown_body.index('\n}\n')]
check(hover_gates == ['wm_draw.cc'] and 'state->val == KM_PRESS' in shown_body and
      'wm_pointer_cursor_shown(nullptr, win)' in (ROOT / 'source/blender/windowmanager/intern/wm_gesture.cc').read_text() and
      'bridge_cursor_flash(C);' in bridge_text,
      "R6 TOUCH-9: cursors show while a button is down and after a size change, through one rule (%s)" % hover_gates)

# ROUND6 TOUCH-10 (X2): the first launch says how. One guide, under Settings and once at the first
# launch (never in a check launch), with each gesture the window answers.
settings_t10 = (SWIFT / 'SettingsSheet.swift').read_text(encoding='utf-8')
guide = settings_t10[settings_t10.index('struct GestureGuide: View {'):]
guide = guide[:guide.index('struct GestureGuideSheet')]
check(all(word in guide for word in ('"One finger"', '"Two fingers"', '"Three fingers"', '"Four fingers"', '"Hold"',
                                     '"Double tap"', '"Apple Pencil"', 'Tap to undo', 'Tap to redo', '"Search"',
                                     'Switch to Desktop Interface', 'Return to iPad Interface', '"Shift, Ctrl and Alt"')) and
      'PLATYPUS_SCRATCH_DOCUMENT' in guide and 'GestureGuide()' in settings_t10 and
      'GestureGuideSheet()' in window_t8 and 'GestureGuide.due' in window_t8,
      "R6 TOUCH-10: How to Use names every gesture, in Settings and once at the first launch")

# ROUND6 TOUCH-11 (A14, A15, E11): small input faults. Cmd+. is Escape; a held key's repeat asks
# the gate; the native editors name keys with the viewport's own rule (by layout), with no table of
# their own; the bottom edge waits for a second swipe while a mode strokes; a text object's
# keyboard shows with the shell's controls hidden too.
node_t11 = (SWIFT / 'NodeEditor.swift').read_text(encoding='utf-8')
blender_key = node_t11[node_t11.index('static func blenderKey(_ key: UIKey)'):]
blender_key = blender_key[:blender_key.index('\n  }\n')]
repeat_body = objc_method(ghost_r6, '- (void)repeatKey:(CADisplayLink *)link')
check('key == GHOST_kKeyPeriod && (ui_key.modifierFlags & UIKeyModifierCommand)' in ghost_r6 and
      '[self blenderTakesKeyboard]' in repeat_body and
      'wm_apple_ios_key_name(' in blender_key and 'case ' not in blender_key,
      "R6 TOUCH-11: Cmd+. is Escape, a repeat asks the gate, one rule names keys for the viewport and the editors")
check('model.brushStrokes ? .bottom : []' in window_t8 and 'TOOLREF_FLAG_USE_BRUSHES' in bridge_text and
      'setNeedsUpdateOfScreenEdgesDeferringSystemGestures()' in window_t8 and
      'if !controlsShown && model.viewportReady {\n          TextObjectKeyboard(model: model)' in window_t8,
      "R6 TOUCH-11: the bottom edge defers while the tool strokes with a brush (MODE-2: Blender says); "
      "the text keyboard shows with controls hidden")

# ROUND6 BUSY-1 (G6, G13, B1, D12): one view of running work. Every job the status bar would show is
# in the `jobs` view, whose Stop is live (it reaches work whose operator holds a modal handler); the
# pill shows it in both interfaces (beside the shader compilation's, not behind the iPad controls'
# gate); a render's progress comes from its job, not from `render_stats` handlers. The harness
# scenario `jobs` walks `eWM_JobType` and stops each job it can start.
jobs_view = bridge_text[bridge_text.index('ViewType jobs;'):]
jobs_view = jobs_view[:jobs_view.index('view_type_add(std::move(jobs));')]
pills = (SWIFT / 'CompileIndicator.swift').read_text(encoding='utf-8')
layers_b1 = window_t8[window_t8.index('private func layers(bottom: Bool'):]
layers_b1 = layers_b1[:layers_b1.index('\n  }\n')]
render_py = (ROOT / 'scripts/startup/bl_ui/native_render.py').read_text(encoding='utf-8')
check('jobs.live = [](const protocol::Command & /*command*/) { return true; };' in jobs_view and
      'WM_jobs_list(' in bridge_text and 'G.is_break = true;' in bridge_text and
      'BlenderJobs.stop(job)' in pills and 'subscribe("jobs")' in pills and
      'CompileIndicator(progress: shell.compile, model: model)' in layers_b1 and 'controlsShown' not in layers_b1 and
      'CompileIndicator(progress: compile, inCluster: true)' in (SWIFT / 'DesktopCluster.swift').read_text(encoding='utf-8') and
      'handlers.render_stats' not in render_py and '"state:samples"' in bridge_text,
      "R6 BUSY-1: running work is listed with a live Stop in both interfaces; render progress from the job")

# ROUND6 BUSY-2 (G6, C1, R6-12): taps are refused, not replayed. A veil over the window after half a
# second of a blocked pass, naming the operator (pushed around every operator callback); every command
# carries the view version it was tapped on and the bridge refuses one whose node went or changed
# after work ran; a job's modal operator refuses commands, naming the job; live commands honour the
# interface lock; a held document request says so. The harness scenario `busy` runs each.
views_b2 = (SWIFT.parents[1] / 'intern/wm_native_ui_views.cc').read_text(encoding='utf-8')
events_b2 = (SWIFT.parents[1] / 'intern/wm_event_system.cc').read_text(encoding='utf-8')
ghost_b2 = (ROOT / 'intern/ghost/intern/GHOST_SystemIOS.mm').read_text(encoding='utf-8')
native_views_b2 = (SWIFT / 'NativeViews.swift').read_text(encoding='utf-8')
check('.overlay { BusyVeil(state: shell.busy) }' in window_t8 and 'shell.busy.refresh()' in window_t8 and
      'WM_native_ui_busy_label(' in pills and events_b2.count('const NativeBusyScope busy(') == 5 and
      'version: view.version)' in native_views_b2 and 'version: uint;' in
      (SWIFT.parents[1] / 'native_ui/protocol.fbs').read_text(encoding='utf-8') and
      'command_stale(' in views_b2 and 'command_job_refusal(C)' in views_b2 and
      'command_locked(C, subscription, command)' in views_b2 and
      'native_interface->engine_document_held(C)' in ghost_b2,
      "R6 BUSY-2: a veil names the work, stale and job-blocked commands are refused, the lock is honoured")

# ROUND6 BUSY-3 (G5, F10, D3, D22, R6-11): an animation render keeps what it made and honours the
# scene's Output. Frames go into a folder of the document's render library, listed from the start
# and counted again from Blender's manifest at launch; Stop asks first past a minute and waits for
# Blender's answer; Continue, Make Video and Save Frames act on kept frames; the video is written by
# Blender's FFmpeg (the shell encodes nothing itself). `script_native_render` sweeps every format
# and container; the harness scenario `renderkeep` stops, continues and makes the videos.
render_swift = (SWIFT / 'RenderSheet.swift').read_text(encoding='utf-8')
check('AVAssetWriter' not in render_swift and 'BlenderRender.start(' in render_swift and
      'addFrames(id: id, folder: folder)' in render_swift and '"Render.json"' in render_swift and
      'Continue from Frame' in render_swift and 'Make Video of' in render_swift and
      'Save Frames to Files…' in render_swift and '"Stop Rendering?"' in render_swift and
      'NativeViews.shared.outcome(of: sent)' in render_swift and
      'ELEM(verb, "image", "animation", "story", "continue", "video")' in bridge_text and
      'WM_jobs_has_running(wm)' in bridge_text and
      'def make_video(' in render_py and 'MANIFEST = "Render.json"' in render_py,
      "R6 BUSY-3: renders keep their frames, continue, make videos with FFmpeg, and ask before losing work")

# ROUND6 BUSY-4 (G8): background work asks before it assumes. Blender's loop is kept running in the
# background only by `BackgroundWork.decide` (task started; the GPU granted for work on the GPU, as
# Blender's `needs_gpu` says); otherwise the render pauses as the app leaves, holding the loop until
# the stop has reached Blender, and goes on when the app is back; heat pauses it between frames; the
# screen stays on while a job runs. `tests/ios/test_background_work.py` checks the table.
background_b4 = render_swift[render_swift.index('final class BackgroundRender {', render_swift.index('#else\n')):]
background_b4 = background_b4[:background_b4.index('#endif')]
check('GHOST_ios_engine_continue_work(continues || holding)' in background_b4 and
      background_b4.count('GHOST_ios_engine_continue_work(') == 1 and
      'BackgroundWork.decide(taskStarted: task != nil, gpuGranted: gpuGranted, needsGPU: needsGPU)' in background_b4 and
      'func appLeft()' in render_swift and 'BackgroundWork.tooWarm(ProcessInfo.processInfo.thermalState)' in render_swift and
      'BackgroundRender.shared.needsGPU = status.bool("gpu")' in render_swift and
      'UIApplication.shared.isIdleTimerDisabled = !idle' in pills and 'gpu=needs_gpu(scene)' in render_py,
      "R6 BUSY-4: the background is used only when granted, else the render pauses and goes on; heat pauses it")

# ROUND6 BUSY-5 (G10): until the governor (PLAN M5) exists, the iPad's start-up preferences are an
# iPad's: undo memory, the cache and the texture size capped from what iOS lets the app use, applied
# as the preferences load and before the caches take their limits (`tests/ios/test_memory_caps.py`
# checks the values for each tier). A memory warning or the pressure source writes the auto-save,
# frees caches and the older undo steps, and says once "Memory is low. Save your work."
files_b5 = (SWIFT.parents[1] / 'intern/wm_files.cc').read_text(encoding='utf-8')
userdef_b5 = files_b5[files_b5.index('static void wm_init_userdef(Main *bmain)'):]
userdef_b5 = userdef_b5[:userdef_b5.index('\n}\n')]
document_b5 = (SWIFT.parents[1] / 'intern/wm_apple_ios_document.cc').read_text(encoding='utf-8')
low_b5 = document_b5[document_b5.index('void WM_apple_ios_memory_low(bContext *C)'):]
low_b5 = low_b5[:low_b5.index('\n}\n')]
ghost_b5 = (ROOT / 'intern/ghost/intern/GHOST_SystemIOS.mm').read_text(encoding='utf-8')
check(0 <= userdef_b5.find('WM_apple_ios_memory_defaults();') < userdef_b5.find('MEM_CacheLimiter_set_maximum(') and
      'memory_caps_apply(caps, U.undomemory, U.memcachelimit, texture_limit);' in document_b5 and
      'U.glreslimit = short(texture_limit);' in document_b5 and
      'os_proc_available_memory()' in document_b5 and
      'WM_apple_ios_autosave_now(C);' in low_b5 and 'BKE_image_free_buffers(' in low_b5 and
      'BKE_undosys_stack_limit_steps_and_memory(' in low_b5 and '"Memory is low. Save your work."' in low_b5 and
      'UIApplicationDidReceiveMemoryWarningNotification' in ghost_b5 and 'DISPATCH_SOURCE_TYPE_MEMORYPRESSURE' in ghost_b5 and
      'native.memory_low = WM_apple_ios_memory_low;' in
      (SWIFT.parents[1] / 'intern/wm_apple_ios_native.cc').read_text(encoding='utf-8'),
      "R6 BUSY-5: the iPad's memory limits at start-up; low memory keeps the work and frees what it can")

# Device round (2026-11-21): the launch line read "memory available 8158 MB of 7520 MB". What is
# left of the app's limit (os_proc_available_memory, which counts compressed and swapped pages) is
# not a share of the RAM (hw.memsize): no memory line may put one "of" the other, and the caps take
# their shares of the RAM at most (`memory_caps_base`; `tests/ios/test_memory_caps.py` has the
# device's numbers).
launch_b5 = (SWIFT / 'SessionDiagnostics.swift').read_text(encoding='utf-8')
memory_lines_b5 = [s for s in [text for _line, text in literals(launch_b5)] + re.findall(r'"([^"\n]*)"', document_b5)
                   if 'MB' in s]
check(memory_lines_b5 and not any(re.search(r'available[^"]*MB of', s) for s in memory_lines_b5) and
      'memory_caps_base(available_bytes, physical_bytes)' in
      (SWIFT.parents[1] / 'intern/wm_apple_ios_memory.hh').read_text(encoding='utf-8') and
      'phys_footprint' in launch_b5,
      "Memory lines name each number's source; what is left of the limit is never shown as a share of the RAM")

# ROUND6 DESK-1 (H1, H3, H12, C1, C10; decision R6-6): over Blender's own interface the app draws one
# small cluster, in every screen state, Focus Mode included: it is shown on `model.desktop` alone,
# never gated by what Blender's screen shows. It holds the way back, Undo and Redo through the shell's
# one gate, Escape, Tab and Return, Shift, Ctrl and Alt, what one finger does, the jobs, the app's
# messages, and, folded or not, the waiting operation's ends. Blender builds that operation's bar in
# any editor, a 3D View current or not. The harness scenario `desk` starts the H1 operations from
# their menus in Focus Mode and ends each the way the cluster does.
cluster_d1 = (SWIFT / 'DesktopCluster.swift').read_text(encoding='utf-8')
cluster_body_d1 = cluster_d1[cluster_d1.index('struct DesktopCluster: View {'):]
cluster_body_d1 = cluster_body_d1[cluster_body_d1.index('  var body: some View {'):]
cluster_body_d1 = cluster_body_d1[:cluster_body_d1.index('\n  }\n')]
window_d1 = window_t8[window_t8.rindex('.overlay {', 0, window_t8.index('DesktopClusterLayer(model: model')):]
window_d1 = window_d1[:window_d1.index('\n      }\n')]
panel_d1 = cluster_d1[cluster_d1.index('  private var panel: some View {'):]
panel_d1 = panel_d1[:panel_d1.index('\n  }\n')]
toolbar_d1 = bridge_text[bridge_text.index('void bridge_toolbar_view_build('):]
toolbar_d1 = toolbar_d1[:toolbar_d1.index('\n}\n')]
window_mm_d1 = (SWIFT.parent / 'wm_apple_ios_window.mm').read_text(encoding='utf-8')
check('if model.viewportReady && model.desktop {' in window_d1 and 'controlsShown' not in window_d1 and
      'interfaceHidden' not in window_d1 and
      all(part in panel_d1 for part in ('BlenderSettings.set("desktop", .bool(false))', 'Operators.run("ED_OT_undo")',
                                        'Operators.run("ED_OT_redo")', '"ESC")', '"TAB")', '"RET")',
                                        'StickyModifierKeys(model: model, embedded: true)', 'fingerMenu', 'moreMenu')) and
      'commands.chooseFingerUsesTool(true)' in cluster_d1 and 'commands.chooseFingerUsesTool(false)' in cluster_d1 and
      all(part in cluster_body_d1 for part in ('waiting', 'jobs', 'messages')) and 'if folded' not in cluster_body_d1 and
      'model.messages.take(notices)' in cluster_d1 and 'model.dragHint' in cluster_d1 and '$0.modalKey' in cluster_d1 and
      'STREQ(key, "TAB") ? GHOST_kKeyTab' in window_mm_d1 and
      'bridge_actions_build(C, active_tool_id, builder, top, has_view3d);' in toolbar_d1 and
      toolbar_d1.index('bridge_actions_build(C, active_tool_id') < toolbar_d1.index('if (has_view3d) {\n    bridge_text_object_build'),
      "R6 DESK-1: the Desktop Interface's cluster is always drawn there, with the way back, keys, Undo, the "
      "touch setting, jobs, messages, and the waiting operation's ends folded or not")

# ROUND6 DESK-2 (H4, A5; decision R6-7): in Blender's own interface a hold that ends without moving
# is a right-click there; a hold that moves is the control's drag. The hold presses nothing; the lift
# sends the right button at where the finger began; a finger's button released there ends a latched
# Shift, Ctrl or Alt, as on the tool. The harness scenario `hold` places every right-button item and
# opens a menu at each kind of interface place.
hold_d2 = objc_method(ghost_r6, '- (void)interfaceHoldPress')
ended_d2 = objc_method(ghost_r6, '- (void)interfaceTouchEnded:(CGPoint)point time:(CFTimeInterval)time')
moved_d2 = objc_method(ghost_r6, '- (void)interfaceTouchMoved:(NSArray<NSValue *> *)samples time:(CFTimeInterval)time')
right_d2 = objc_method(ghost_r6, '- (void)rightClickInterface')
buttons_d2 = objc_method(ghost_r6, '- (void)sendPointerButtons:(UIEventButtonMask)buttons')
check('pressInterface' not in hold_d2 and 'interface_state = IOS_INTERFACE_HELD;' in hold_d2 and
      'state == IOS_INTERFACE_HELD' in ended_d2 and '[self rightClickInterface];' in ended_d2 and
      'UIEventButtonMaskSecondary' in right_d2 and 'interface_start' in right_d2 and
      moved_d2.index('IOS_INTERFACE_HELD') < moved_d2.index('[self pressInterface];') and
      'GHOST_ios_sticky_action_ended(window);' in buttons_d2,
      "R6 DESK-2: a hold on Blender's interface is a right-click if it lifts there, the control's drag if it moves")

# ROUND7 UF-1, UF-2: leaving full screen frees an area that a moved region's message-bus
# subscriptions still name until it draws again (Blender 5.3.0's own, 5.1.2's too); a mode change
# handled in the same pass read and wrote the freed area. Whoever toggles (the shell, Blender's
# maximize, Focus Mode, Back to Previous, the full-screen temporary editors), one guard mends the
# subscriptions where messages are handled: `WM_native_ui_msgbus_guard` right before the only
# `WM_msgbus_handle`. No caller resets subscriptions beside it, and every subscription that keeps
# an area as its user data has a notify the guard knows.
REPO_UF2 = Path(__file__).resolve().parents[2]
events_uf2 = c_code_only((REPO_UF2 / 'source/blender/windowmanager/intern/wm_event_system.cc').read_text(
    encoding='utf-8'))
handle_at_uf2 = events_uf2.find('WM_msgbus_handle(')
guard_at_uf2 = events_uf2.rfind('WM_native_ui_msgbus_guard(C);', 0, max(handle_at_uf2, 0))
handlers_uf2, area_notifies_uf2, resets_uf2 = [], [], []
for path in sorted(REPO_UF2.glob('source/blender/**/*')):
    if path.suffix not in ('.cc', '.mm', '.c'):
        continue
    code = c_code_only(path.read_text(encoding='utf-8', errors='replace'))
    if 'WM_msgbus_handle(' in code and path.name not in ('wm_event_system.cc', 'wm_message_bus.cc'):
        handlers_uf2.append(path.name)
    for match in re.finditer(r'\b(\w+)\.user_data = area;', code):
        if not re.search(r'wmMsgSubscribeValue %s\b' % match.group(1), code):
            continue  # Not a subscription being made (the guard pointing one at an area).
        notify = re.search(r'\b%s\.notify = (\w+);' % match.group(1), code[match.end():match.end() + 200])
        area_notifies_uf2.append((path.name, notify.group(1) if notify else None))
    if re.search(r'(native|apple_ios)', path.name) and path.name != 'wm_native_ui.cc' and \
            'WM_msgbus_clear_by_owner(' in code:
        resets_uf2.append(path.name)
bridge_uf2 = c_code_only(bridge_text)
guard_body_uf2 = bridge_uf2[bridge_uf2.find('void WM_native_ui_msgbus_guard(bContext *C)'):]
guard_body_uf2 = guard_body_uf2[:guard_body_uf2.find('\n}\n')]
names_uf2 = bridge_uf2[bridge_uf2.find('bool msgbus_names_area('):]
names_uf2 = names_uf2[:names_uf2.find('\n}\n')]
unknown_uf2 = ['%s: %s' % (name, notify) for name, notify in area_notifies_uf2
               if notify is None or notify not in names_uf2]
check(handle_at_uf2 >= 0 and guard_at_uf2 >= 0 and
      handle_at_uf2 - guard_at_uf2 < 400 and not handlers_uf2 and
      'bridge_screen_subscriptions_reset' not in bridge_uf2 and
      bridge_uf2.count('WM_msgbus_clear_by_owner(') == guard_body_uf2.count('WM_msgbus_clear_by_owner(') and
      not resets_uf2 and len(area_notifies_uf2) >= 2 and not unknown_uf2,
      "R7 UF-2: one guard, where messages are handled, mends every subscription naming a freed area "
      "(other handlers %s, resets beside it %s, area notifies it does not know %s)" %
      (handlers_uf2, resets_uf2, unknown_uf2))

# ROUND6 DESK-3 (A6, A7, H6, H7, D6): typing reaches everything Blender draws. A field's text reaches
# Blender on every change (null-safe, the cursor at its end, live updates only where the button asks);
# the field lies above the keyboard when the keyboard would cover it; a hardware keyboard types into
# the field too (input methods), Escape cancelling and Tab going on. Where what was pressed takes text
# from keys (the key maps' TEXTINPUT items, or a key capture waiting), a keyboard that sends key events
# is raised; the cluster's button raises it for anything else. The harness scenario `typing` checks
# the presses and runs a line in the Python Console.
change_d3 = objc_method(ghost_r6, '- (void)handleKeyboardEditChange:(UITextField *)text_field')
popup_d3 = objc_method(ghost_r6, '- (GHOST_TSuccess)popupOnscreenKeyboard:(const GHOST_KeyboardProperties &)keyboard_properties')
type_d3 = objc_method(ghost_r6, '- (void)typeText:(NSString *)text\n{')
handlers_d3 = (ROOT / 'source/blender/editors/interface/interface_handlers.cc').read_text(encoding='utf-8')
textedit_d3 = handlers_d3[handlers_d3.index('      case EVT_TEXTEDIT: {'):]
textedit_d3 = textedit_d3[:textedit_d3.index('      default: {')]
events_d3 = (SWIFT.parents[1] / 'intern/wm_event_system.cc').read_text(encoding='utf-8')
native_d3 = (SWIFT.parents[1] / 'intern/wm_apple_ios_native.cc').read_text(encoding='utf-8')
check('GHOST_kKeyTextEdit' in change_d3 and 'onscreen_keyboard_active' in change_d3 and
      'push_edits_back_to_blender' not in ghost_r6 and 'hardware_text_edit' not in ghost_r6 and
      'return has_text ? keyboard_string_.c_str() : nullptr;' in ghost_r6 and
      '[self liftTextField];' in popup_d3 and 'keyboard_frame = ' in ghost_r6 and
      'keyboard_string && text_edit.edit_string' in textedit_d3 and 'BUT_TEXTEDIT_UPDATE' in textedit_d3 and
      'but->pos = ' in textedit_d3 and
      '@interface GHOSTKeyInputView : UIView <UIKeyInput>' in ghost_r6 and 'GHOST_kKeyEnter' in type_d3 and
      'GHOST_kKeyTab' in type_d3 and 'responder == key_input_view ||' in ghost_r6 and
      '(key == GHOST_kKeyEsc || key == GHOST_kKeyTab)' in ghost_r6 and
      'wm_event_text_input_focus_note(C, wm, &win, event);' in events_d3 and
      'KM_TEXTINPUT' in events_d3[events_d3.index('static bool wm_region_takes_text('):] and
      'native.text_input_focus = text_input_focus;' in native_d3 and
      'state == BUTTON_STATE_WAIT_KEY_EVENT || data->state == BUTTON_STATE_WAIT_KEY_EVENT' in handlers_d3 and
      'wm_apple_ios_window_key_input(model.window, 2)' in cluster_d1 + (SWIFT / 'DesktopCluster.swift').read_text(encoding='utf-8'),
      "R6 DESK-3: fields send text as it changes and clear the keyboard; key-taking editors get a keyboard of keys")

# ROUND6 DESK-4 (H8, H9, H11, H15, C12): Stage 13's contract amended. A tap in any canvas presses,
# whatever the touch setting (Pencil Only's tap is a click wherever it lands, TOUCH-1); lists of rows
# are interface. The map asks Blender's own order: action zones (every type of `ED_screen_types.hh`
# placed), the edges between areas, a region's scroll-bars and time scrub, then the region; each of
# those the control's both ways. What Blender drags away (rows, previews, swatches) takes no drag:
# the drag begins after a hold. A finger's pinch over interface zooms nothing. A finger on interface
# is a finger's (TOUCH-4's distances). The harness scenario `touch` checks each place and editor.
screen_types_d4 = (ROOT / 'source/blender/editors/include/ED_screen_types.hh').read_text(encoding='utf-8')
azones_d4 = screen_types_d4[screen_types_d4.index('/** Action-Zone Type: #AZone.type */'):]
azones_d4 = re.findall(r'\n  (AZONE_\w+)', azones_d4[:azones_d4.index('};')])
names_d4 = bridge_text[bridge_text.index('static const char *bridge_touch_action_zone_name('):]
names_d4 = names_d4[:names_d4.index('\n}\n')]
update_d4 = bridge_text[bridge_text.index('static void bridge_touch_zones_update(wmWindowManager *wm)\n{'):]
update_d4 = update_d4[:update_d4.index('\n}\n')]
tap_d4 = objc_method(ghost_r6, '- (void)handleTap:(GHOSTUITapGestureRecognizer *)sender\n{')
zoom_d4 = objc_method(ghost_r6, '- (void)handleZoom:(GHOSTUIPinchGestureRecognizer *)sender')
takes_d4 = touch_source[touch_source.index('TouchTakes button_type_touch_takes('):]
takes_d4 = takes_d4[:takes_d4.index('\n}\n')]
rows_d4 = takes_d4[takes_d4.index('case ButtonType::ListRow:'):]
check(len(azones_d4) >= 5 and all('case %s:' % name in names_d4 for name in azones_d4) and
      'default:' not in names_d4 and
      0 < update_d4.index('area->actionzones') < update_d4.index('ED_screen_edges_touch_rects(') <
      update_d4.index('bridge_touch_region_places_add(') < update_d4.index('bridge_touch_zone_add(zones, win, area, region)') and
      'view2d_scroller_window_rects(' in bridge_text and 'ED_time_scrub_event_in_region_poll' in bridge_text and
      'draggable' not in takes_d4 and rows_d4[rows_d4.index('return'):].startswith('return TouchTakes::None;'),
      "R6 DESK-4: the map asks Blender's order, every action zone placed (%s); rows drag after a hold" % azones_d4)
check('touchAnswerAt' not in tap_d4 and 'place' not in tap_d4 and
      'zoom_place == GHOST_kIOSPlaceInterface' in zoom_d4 and
      'static constexpr CGFloat ios_interface_slop = 10.0;' in ghost_r6 and
      '[self fingerTabletData]' in objc_method(ghost_r6, '- (void)sendPointerButtons:(UIEventButtonMask)buttons'),
      "R6 DESK-4: a tap presses in every canvas, a pinch over interface zooms nothing, a finger's distances")

# ROUND6 DESK-5 (H2): one window means one window. `WM_window_open_temp` itself opens the editor full
# screen with Back to Previous where the platform shows one window, for every caller; the callers of
# `WM_window_open` are each kept from a second window where they are. A caller not in this list fails
# here; the harness scenario `windows` runs each `WM_window_open_temp` command and counts windows.
WINDOW_OPENERS = {
    'render_view.cc': 'WM_window_open: the render shows full screen on the iPad (USER_RENDER_DISPLAY_SCREEN)',
    'screen_ops.cc': 'WM_window_open: area_dupli_poll refuses on the iPad; the Drivers Editor and Info Log go '
                     'through WM_window_open_temp',
    'screen_edit.cc': 'WM_window_open_temp: ED_screen_temp_space_open (Preferences, File Browser, image)',
    'outliner_edit.cc': 'WM_window_open_temp: Manage Unused Data',
    'wm_operators.cc': 'WM_window_open: wm.window_new and window_new_main refuse on the iPad (their polls)',
}
openers_d5 = set()
for path in (ROOT / 'source/blender').rglob('*.cc'):
    if path.name == 'wm_window.cc':
        continue
    text_d5 = path.read_text(encoding='utf-8', errors='replace')
    if re.search(r'\bWM_window_open(_temp)?\(', text_d5):
        openers_d5.add(path.name)
window_cc_d5 = (SWIFT.parents[1] / 'intern/wm_window.cc').read_text(encoding='utf-8')
temp_d5 = window_cc_d5[window_cc_d5.index('wmWindow *WM_window_open_temp(bContext *C'):]
temp_d5 = temp_d5[:temp_d5.index('\n}\n')]
check(openers_d5 <= set(WINDOW_OPENERS) and
      temp_d5.index('native->single_window') < temp_d5.index('USER_TEMP_SPACE_DISPLAY_FULLSCREEN') <
      temp_d5.index('WM_window_dpi_set_userdef') and
      'native.single_window = true;' in (SWIFT.parents[1] / 'intern/wm_apple_ios_native.cc').read_text(encoding='utf-8'),
      "R6 DESK-5: every caller that opens a window is placed (%s); WM_window_open_temp keeps one window"
      % sorted(openers_d5 - set(WINDOW_OPENERS)))

# ROUND6 DESK-6 (H14): layout by finger. One margin in points, a finger's, independent of the
# interface size, in each hit test that takes a tolerance: the edges between areas, the action zones
# (corners, region edges), the scroll-bars; and the finger's map draws the same places with it. The
# harness scenario `margins` measures every kind at each offered size and splits an area from inside
# the margin.
geometry_d6 = (ROOT / 'source/blender/editors/screen/screen_geometry.cc').read_text(encoding='utf-8')
ops_d6 = (ROOT / 'source/blender/editors/screen/screen_ops.cc').read_text(encoding='utf-8')
view2d_d6 = (ROOT / 'source/blender/editors/interface/view2d/view2d.cc').read_text(encoding='utf-8')
query_d6 = (SWIFT.parents[1] / 'intern/wm_event_query.cc').read_text(encoding='utf-8')
finder_d6 = geometry_d6[geometry_d6.index('ScrEdge *screen_geom_find_active_scredge('):]
finder_d6 = finder_d6[:finder_d6.index('\n}\n')]
refresh_d6 = ops_d6[ops_d6.index('static AZone *area_actionzone_refresh_xy('):]
refresh_d6 = refresh_d6[:refresh_d6.index('if (BLI_rcti_isect_pt_v(&az_rect, xy))')]
scrollers_d6 = view2d_d6[view2d_d6.index('char view2d_mouse_in_scrollers_ex('):]
scrollers_d6 = scrollers_d6[:scrollers_d6.index('\n}\n')]
check('wm_finger_point_pixels' in query_d6[query_d6.index('int WM_event_finger_margin()'):][:200] and
      'UI_SCALE_FAC' not in query_d6[query_d6.index('int WM_event_finger_margin()'):][:200] and
      finder_d6.count('margin') >= 3 and 'WM_event_finger_pick_margin()' in refresh_d6 and
      'WM_event_finger_pick_margin()' in scrollers_d6 and
      geometry_d6.count('WM_event_finger_margin()') == 1 and view2d_d6.count('WM_event_finger_margin()') == 1 and
      'WM_event_finger_margin()' in update_d4,
      "R6 DESK-6: a finger's margin in points in every hit test with a tolerance, and in its map")

# ROUND6 MODE-3 (D9): an operator the shell runs by name is executed unless its work is in its
# invoke, where `operator_run` invokes it as a click on its menu item would. Every name the shell
# runs is on one of the two lists: executed (a plain `exec` that needs nothing more) or invoked
# (`operator_invoked_by_shell`, navigation, a file command). A new name on neither fails here.
views_d9 = (SWIFT.parents[1] / 'intern/wm_native_ui_views.cc').read_text(encoding='utf-8')
invoked_d9 = views_d9[views_d9.index('static bool operator_invoked_by_shell('):]
invoked_d9 = set(re.findall(r'"(\w+_OT_\w+)"', invoked_d9[:invoked_d9.index('\n}\n')]))
navigates_d9 = views_d9[views_d9.index('static bool operator_navigates('):]
invoked_d9 |= set(re.findall(r'"(\w+_OT_\w+)"', navigates_d9[:navigates_d9.index('\n}\n')]))
bridge_d9 = (SWIFT.parents[1] / 'intern/wm_native_ui.cc').read_text(encoding='utf-8')
documents_d9 = bridge_d9[bridge_d9.index('static const char *bridge_document_command('):]
invoked_d9 |= set(re.findall(r'\{"(\w+_OT_\w+)", "', documents_d9[:documents_d9.index('\n}\n')]))
EXECUTED_D9 = {
    'ED_OT_undo': 'steps back', 'ED_OT_redo': 'steps forward',
    'SCREEN_OT_animation_play': 'plays or stops', 'SCREEN_OT_frame_jump': 'jumps to the start or end',
    'SCREEN_OT_keyframe_jump': 'jumps to a key', 'VIEW3D_OT_toggle_shading': 'switches the shading',
    'WM_OT_call_panel': 'its exec opens the panel (Rename Active Item)',
    'WM_OT_collection_export_all': 'exports with the exporters the collections hold',
    'WM_OT_context_toggle': 'flips the property it names',
    'ANIM_OT_native_key_delete': 'the timeline\'s own', 'ANIM_OT_native_key_move': 'the timeline\'s own',
    'ANIM_OT_native_key_select': 'the timeline\'s own', 'ANIM_OT_native_key_jump': 'the timeline\'s own jump',
    'WM_OT_native_node_tree_new': 'the node editor\'s own',
    'OBJECT_OT_location_clear': 'clears', 'OBJECT_OT_rotation_clear': 'clears', 'OBJECT_OT_scale_clear': 'clears',
    'VIEW3D_OT_view_center_camera': 'frames the camera', 'VIEW3D_OT_localview': 'toggles Local View',
}


def idname_d9(name):
    if '_OT_' in name:
        return name
    module, _, op = name.partition('.')
    return module.upper() + '_OT_' + op


run_d9 = set()
for path in sources():
    text = path.read_text(encoding='utf-8')
    run_d9 |= {idname_d9(n) for n in re.findall(r'Operators\.run\("([\w.]+)"', text)}
    run_d9 |= {idname_d9(n) for n in re.findall(r'operatorName: "([\w.]+)"', text)}
    if path.name == 'ItemCard.swift':
        run_d9 |= set(re.findall(r'case [^:]+: "(\w+_OT_\w+)"', text))
unlisted_d9 = sorted(n for n in run_d9 if n not in invoked_d9 and n not in EXECUTED_D9)
check(not unlisted_d9 and len(run_d9) >= 20,
      "R6 MODE-3 (D9): every operator the shell runs by name (%d) is executed or invoked by a reviewed "
      "list (%s)" % (len(run_d9), unlisted_d9))
check({'ED_OT_undo_history', 'SCREEN_OT_repeat_history', 'SCREEN_OT_redo_last', 'WM_OT_batch_rename',
       'WM_OT_link', 'WM_OT_append'} <= invoked_d9,
      "R6 MODE-3 (D9): the Edit menu's four dialog commands, Link and Append are invoked as a click would")
both_d9 = sorted(set(EXECUTED_D9) & invoked_d9)
check(not both_d9, "R6 MODE-3 (D9): no operator is on both lists (%s)" % both_d9)

# ROUND6 MODE-3 (C6, E7): every popup of Blender's is taken where it is made. The iPad installs the
# hooks; the three functions every popup ends in ask them; the one function that creates every popup
# region counts what was not taken; a panel any command asks for opens as the interface's popover.
native_m3 = (SWIFT.parents[1] / 'intern/wm_apple_ios_native.cc').read_text(encoding='utf-8')
menu_popup_m3 = (ROOT / 'source/blender/editors/interface/regions/interface_region_menu_popup.cc').read_text(encoding='utf-8')
region_popup_m3 = (ROOT / 'source/blender/editors/interface/regions/interface_region_popup.cc').read_text(encoding='utf-8')


def body_m3(text, signature):
    at = text.index(signature)
    return text[at:text.index('\n}\n', at)]


check('native.popup_take = bridge_popup_take;' in native_m3 and 'native.popup_drawn = bridge_popup_drawn;' in native_m3,
      "R6 MODE-3: the iPad takes Blender's popups and counts what it did not take")
check(all('native->popup_take(' in body_m3(menu_popup_m3, signature) for signature in
          ('void popup_menu_end(bContext *C, PopupMenu *pup)', 'void popup_block_invoke_ex(', 'void popup_block_ex(')),
      "R6 MODE-3: popup_menu_end, popup_block_invoke_ex and popup_block_ex ask the interface first")
check('native->popup_drawn(' in body_m3(region_popup_m3, 'PopupBlockHandle *popup_block_create('),
      "R6 MODE-3: every popup region Blender creates is counted")
panel_m3 = body_m3(bridge_d9, 'bool bridge_panel_popup(bContext *C, const char *panel)\n{')
check('popup.panel = ' in panel_m3 and 'bridge_popup_refusal_say(' in panel_m3,
      "R6 MODE-3 (E7): wm.call_panel opens the interface's popover, or says where the panel is")
check('data("panel")' in (SWIFT / 'DocumentWindow.swift').read_text(encoding='utf-8') and
      'struct CalledPanelPopover' in (SWIFT / 'NativeToolSettings.swift').read_text(encoding='utf-8'),
      "R6 MODE-3 (E7): the shell shows a called panel as a popover")

# ROUND6 MODE-5 (C9): an operator whose `modal()` reads keys itself, with no modal key map, is on the
# reviewed list `release/ios/modal_keys.txt`, which says how a finger reaches what its keys do; a new
# one fails here, and so does a listed one that is gone. The modal bar reads the status bar's keys.
import ctypes
modal_lib_m5 = ctypes.CDLL(None)
modal_lib_m5.WM_native_ui_modal_without_keymap.restype = ctypes.c_char_p
modal_m5 = [line.split('\t') for line in modal_lib_m5.WM_native_ui_modal_without_keymap().decode().splitlines() if line]
needing_m5 = {fields[0] for fields in modal_m5 if len(fields) == 1}
reviewed_m5 = {}
for line in (ROOT / 'release/ios/modal_keys.txt').read_text(encoding='utf-8').splitlines():
    if line.strip() and not line.startswith('#'):
        idname, _, how = line.partition(' | ')
        reviewed_m5[idname.strip()] = how.strip()
check(len(needing_m5) > 100 and not sorted(needing_m5 - set(reviewed_m5)),
      "R6 MODE-5 (C9): every modal operator without a key map is reviewed (%s)" % sorted(needing_m5 - set(reviewed_m5)))
check(not sorted(set(reviewed_m5) - needing_m5),
      "R6 MODE-5 (C9): the reviewed list names no operator that is gone or has a key map now (%s)" %
      sorted(set(reviewed_m5) - needing_m5))
check(all(how.split(':')[0] in ('status', 'drag', 'job', 'desktop', 'none') and len(how.split(':', 1)[-1].strip()) > 5
          for how in reviewed_m5.values()), "R6 MODE-5 (C9): each says how, and why")
bar_m5 = bridge_d9[bridge_d9.index('static void bridge_modal_bar_build('):]
bar_m5 = bar_m5[:bar_m5.index('\n}\n')]
check('bridge_status_keys(C)' in bar_m5 and 'bridge_status_keys(C)' in
      bridge_d9[bridge_d9.index('static void bridge_modifier_names('):],
      "R6 MODE-5: the modal bar and the shell's modifier names read the status bar's keys")

# ROUND6 MODE-6 (C10): a command bound to a key or a mouse chord in Blender's default key map and
# named nowhere in `bl_ui` (no menu, panel, tool or action) is on the reviewed list
# `release/ios/key_only.txt`, which says where a finger reaches it or why it is desktop only. As the
# audit made the list: `generate_keymaps` minus every operator `bl_ui` names.
import sys as sys_m6
sys_m6.path.insert(0, str(ROOT / 'scripts/presets/keyconfig'))
from keymap_data import blender_default as keymap_m6
ui_text_m6 = ''.join(path.read_text(encoding='utf-8', errors='replace')
                     for path in (ROOT / 'scripts/startup/bl_ui').glob('*.py'))
bound_m6 = set()
for _name, args_m6, content_m6 in keymap_m6.generate_keymaps(keymap_m6.Params()):
    if args_m6.get('modal'):
        continue
    for item_m6 in content_m6.get('items', []):
        if item_m6 and isinstance(item_m6[0], str) and item_m6[0]:
            bound_m6.add(item_m6[0])
key_only_m6 = {op for op in bound_m6 if '"%s"' % op not in ui_text_m6 and "'%s'" % op not in ui_text_m6}
reviewed_m6 = {}
for line in (ROOT / 'release/ios/key_only.txt').read_text(encoding='utf-8').splitlines():
    if line.strip() and not line.startswith('#'):
        op_m6, _, how_m6 = line.partition(' | ')
        reviewed_m6[op_m6.strip()] = how_m6.strip()
check(len(key_only_m6) > 200 and not sorted(key_only_m6 - set(reviewed_m6)),
      "R6 MODE-6 (C10): every key-only command is reviewed (%s)" % sorted(key_only_m6 - set(reviewed_m6)))
check(not sorted(set(reviewed_m6) - key_only_m6),
      "R6 MODE-6 (C10): the list names nothing that has a menu, tool or action now (%s)" %
      sorted(set(reviewed_m6) - key_only_m6))
categories_m6 = ('navigation', 'selection', 'stroke', 'tool', 'menu', 'action', 'text', 'interface', 'editor', 'desktop')
check(all(how.split(':')[0] in categories_m6 and len(how.split(':', 1)[-1].strip()) > 5 for how in reviewed_m6.values()),
      "R6 MODE-6 (C10): each says where, or why desktop only")
check('pose.rotation_mode_set' not in key_only_m6 and
      all(reviewed_m6.get(op, '').startswith('desktop:') for op in
          ('paintcurve.add_point_slide', 'brush.stencil_control', 'paint.grab_clone')),
      "R6 MODE-6 (C10): Set Rotation Mode has an action; paint curves, the stencil and the clone source say desktop only")

# ROUND6 MODE-7 (C8, C13, X4): a menu item, Search result or pin is always answered. `menu_run` says
# why nothing ran and the bridge says it; a registered command that changed nothing says so; a pin
# runs by its route, not through a table filled only once Search has been opened.
menu_view_m7 = bridge_d9[bridge_d9.index('views::CommandResult bridge_menu_view_command('):]
menu_view_m7 = menu_view_m7[:menu_view_m7.index('\n}\n')]
check('ui::native::menu_run(C, command.target()->string_view(), &ran)' in menu_view_m7 and
      'WM_native_ui_notice(RPT_WARNING, why.c_str())' in menu_view_m7 and 'did nothing here' in menu_view_m7,
      "R6 MODE-7 (C8): a menu item that did not run, or did nothing, says so")
search_m7 = (SWIFT / 'CommandSearch.swift').read_text(encoding='utf-8')
run_m7 = search_m7[search_m7.index('func run(id: String) {'):]
run_m7 = run_m7[:run_m7.index('\n  }\n')]
check('BlenderMenus.shared.run(route:' in run_m7 and 'menuItems[' not in run_m7,
      "R6 MODE-7 (C8): a pin runs by its route")
check('bridge_id_counts_said(before, bridge_id_counts_last)' in bridge_d9,
      "R6 MODE-7 (C13): a command shown nowhere says what it added or removed")

# ROUND6 EDIT-2 (D2, D22): a live command runs while an operator or job holds Blender, so it must
# write nothing a job owns. Every view's `live` rule is reviewed here with what it lets through; a
# new one, or one gone, fails. The timeline's frame is refused while a render runs (a render counts
# its frames on the scene's), as desktop's timeline refuses it then.
live_e2 = {}
for path in (SWIFT.parents[1] / 'intern/wm_native_ui.cc', SWIFT.parents[1] / 'intern/wm_native_ui_views.cc'):
    for match in re.finditer(r'\b(\w+)\.live = ', path.read_text(encoding='utf-8')):
        live_e2[match.group(1)] = path.name
reviewed_e2 = {
    'toolbar': "tool settings, brush values, axis locks: the scene's tool settings and brushes, no job's data; "
               "Undo/Redo refused while an operation waits; a waiting operation's own keys",
    'settings': "the interface's own preferences",
    'timeline': "the frame: refused while a render runs (bridge_timeline_rendering)",
    'render': "Cancel and Clear of the render itself",
    'jobs': "Stop of a job",
    'operators': "navigation (the view) and Undo/Redo, refused while an operation waits",
}
check(sorted(live_e2) == sorted(reviewed_e2),
      "R6 EDIT-2 (D2): every view's live rule is reviewed (found %s, reviewed %s)" % (sorted(live_e2), sorted(reviewed_e2)))
timeline_e2 = bridge_d9[bridge_d9.index('views::CommandResult bridge_timeline_view_command('):]
timeline_e2 = timeline_e2[:timeline_e2.index('\n}\n')]
frame_e2 = timeline_e2[timeline_e2.index('if (target == "frame")'):]
check(frame_e2.index('bridge_timeline_rendering(C)') < frame_e2.index('RNA_property_int_set'),
      "R6 EDIT-2 (D2): the timeline refuses the frame while rendering, before setting it")
check('next.rendering = flag("rendering")' in (SWIFT / 'Timeline.swift').read_text(encoding='utf-8') and
      'guard !store.rendering else { return }' in (SWIFT / 'Timeline.swift').read_text(encoding='utf-8'),
      "R6 EDIT-2 (D2): the scrubber shows it cannot move while rendering")
# ROUND6 EDIT-3 (D7): every command goes through `NativeViews.send`, and its answer through
# `NativeView.answered`, the one place a refusal is said and a screen drawn ahead of Blender is put
# back. Only the screens that say errors themselves read a view's `error`, and they are marked so.
swift_e3 = {path.name: path.read_text(encoding='utf-8') for path in SWIFT.glob('*.swift')}
senders_e3 = sorted(name for name, text in swift_e3.items() if 'WM_native_ui_send(' in text)
check(senders_e3 == ['NativeViews.swift'] and swift_e3['NativeViews.swift'].count('WM_native_ui_send(') == 1,
      "R6 EDIT-3 (D7): commands reach Blender only through NativeViews.send (%s)" % senders_e3)
views_e3 = swift_e3['NativeViews.swift']
answered_e3 = views_e3[views_e3.index('fileprivate func answered(_ failure: String?) {'):]
answered_e3 = answered_e3[:answered_e3.index('\n  }\n')]
check('failed?()' in answered_e3 and 'messages.say(failure' in answered_e3 and '!showsErrors' in answered_e3,
      "R6 EDIT-3 (D7): an answer that is a refusal is said and puts the screen back")
check('.answered(ack.error)' in views_e3 and 'failures.removeValue(forKey: ack.command)' in views_e3,
      "R6 EDIT-3 (D7): every answer is read where commands are answered")
canvas_e3 = views_e3[views_e3.index('final class NativeCanvas {'):]
check('view.failed = { [weak self] in self?.taken = -1 }' in canvas_e3[:canvas_e3.index('func setShown')],
      "R6 EDIT-3 (D7): a canvas takes Blender's state again after a refused edit")
readers_e3 = sorted(name for name, text in swift_e3.items()
                    if name != 'NativeViews.swift' and re.search(r'\b(view|outlinerEdits)\??\.error\b', text))
check(readers_e3 == ['NativePanels.swift', 'ScenePanels.swift'] and
      all('showsErrors = true' in swift_e3[name] for name in readers_e3),
      "R6 EDIT-3 (D7): the screens that read a view's error say so with showsErrors (%s)" % readers_e3)
timeline_e3 = swift_e3['Timeline.swift']
check(all(re.search(r'Operators\.run\("anim\.native_key_%s"[^\n]*(\n[^\n]*){0,2}failed: resync\)' % op, timeline_e3)
          for op in ('select', 'move', 'delete')),
      "R6 EDIT-3 (D7): the strip's key edits shown ahead of Blender are put back when refused")
storyboard_e3 = (SWIFT.parents[2] / 'editors/space_sequencer/sequencer_native.cc').read_text(encoding='utf-8')
check(not re.search(r'return "(No |Could not)', storyboard_e3) and 'edit_failure.empty()' in storyboard_e3,
      "R6 EDIT-3 (D7): a storyboard failure is not returned as an undo step's name")
# ROUND6 EDIT-4 (D8): a canvas's state reaches Blender whatever the order it is set and shown in:
# kept on the view, not sent while paused, and sent again with every new subscription. Nothing
# else sends a `state`.
views_e4 = (SWIFT / 'NativeViews.swift').read_text(encoding='utf-8')
resume_e4 = views_e4[views_e4.index('func resume(_ view: NativeView) {'):]
resume_e4 = resume_e4[:resume_e4.index('\n  }\n')]
set_state_e4 = views_e4[views_e4.index('func setState(_ state: [String: Any]) {'):]
set_state_e4 = set_state_e4[:set_state_e4.index('\n  }\n')]
check('if let state = view.state { send(view, target: "state", params: state) }' in resume_e4 and
      'view.state = params' in set_state_e4 and 'guard view.subscription != 0 else { return }' in set_state_e4,
      "R6 EDIT-4 (D8): a canvas's state is kept, and sent again as it resumes")
state_senders_e4 = sorted(path.name for path in SWIFT.glob('*.swift')
                          if re.search(r'target:\s*"state"', path.read_text(encoding='utf-8')))
check(state_senders_e4 == ['NativeViews.swift'],
      "R6 EDIT-4 (D8): only the canvas sends its state (%s)" % state_senders_e4)
# ROUND6 EDIT-5 (D4, D14): the node editor names only operators that exist, offers each only where
# it polls (the snapshot's `polls`), and every action it sends has a branch in `apply_node_action`.
# A group that would nest the tree inside itself is neither listed nor added (`node_group_poll`).
import bpy  # noqa: E402
node_swift_e5 = (SWIFT / 'NodeEditor.swift').read_text(encoding='utf-8')
node_cc_e5 = (SWIFT.parents[2] / 'editors/interface/interface_native_properties.cc').read_text(encoding='utf-8')
named_e5 = sorted(set(re.findall(r'"(NODE_OT_\w+)"', node_swift_e5)))
registered_e5 = set(dir(bpy.ops.node))
check(named_e5 and all(op[len('NODE_OT_'):] in registered_e5 for op in named_e5),
      "R6 EDIT-5 (D14): every operator the node editor names exists (%s)" %
      [op for op in named_e5 if op[len('NODE_OT_'):] not in registered_e5])
menu_ops_e5 = node_cc_e5[node_cc_e5.index('native_node_menu_operators[] = {'):]
menu_ops_e5 = set(re.findall(r'"(NODE_OT_\w+)"', menu_ops_e5[:menu_ops_e5.index('};')]))
check(set(named_e5) <= menu_ops_e5 and all('model.polls("%s")' % op in node_swift_e5 for op in named_e5),
      "R6 EDIT-5 (D14): each is offered only where it polls (%s)" %
      [op for op in named_e5 if 'model.polls("%s")' % op not in node_swift_e5])
apply_e5 = node_cc_e5[node_cc_e5.index('std::optional<std::string> apply_node_action('):]
apply_e5 = apply_e5[:apply_e5.index('\n}\n')]
branches_e5 = set(re.findall(r'action == "(\w+)"', apply_e5))
sent_e5 = set(re.findall(r'model\.send\("(\w+)"', node_swift_e5)) | set(re.findall(r'\bsend\("(\w+)"', node_swift_e5))
check(sent_e5 and not sorted(sent_e5 - branches_e5),
      "R6 EDIT-5 (D14): every node action sent has a branch (%s)" % sorted(sent_e5 - branches_e5))
listed_e5 = node_cc_e5[node_cc_e5.index('void project_node_add_items('):]
listed_e5 = listed_e5[:listed_e5.index('\n}\n')]
added_e5 = node_cc_e5[node_cc_e5.index('bNode *add_native_node('):]
added_e5 = added_e5[:added_e5.index('\n}\n')]
check('bke::node_group_poll(&tree, &group, nullptr)' in listed_e5 and 'bke::node_group_poll(&tree, group_tree, &why)' in added_e5,
      "R6 EDIT-5 (D4): a group that would contain itself is neither listed nor added")
# ROUND6 EDIT-7 (D18, D19): every Outliner action the shell sends is one the Outliner's edit
# operator handles and its rows offer: a collection row's tap makes it active, a row's menu has
# Blender's restriction flags, and the panel says what it leaves to the Desktop Interface.
outliner_swift_e7 = (SWIFT / 'HierarchyView.swift').read_text(encoding='utf-8')
panels_py_e7 = (SWIFT.parents[4] / 'scripts/startup/bl_ui/native_panels.py').read_text(encoding='utf-8')
sent_e7 = set(re.findall(r'\bact\("(\w+)"', outliner_swift_e7)) | \
    set(re.findall(r'"action": "(\w+)"', outliner_swift_e7))
edit_e7 = panels_py_e7[panels_py_e7.index('class WM_OT_native_panel_edit('):]
handled_e7 = set(re.findall(r"(?:action|request\.get\('action'\)) == '(\w+)'", edit_e7)) | set(re.findall(r"'(\w+)'", ' '.join(
    re.findall(r"action in \{([^}]*)\}", edit_e7))))
offered_e7 = set(re.findall(r"'(\w+)'", ' '.join(re.findall(r"(?:actions|activate)(?: \+?=| =) [^\n]*", panels_py_e7))))
check(sent_e7 and not sorted(sent_e7 - handled_e7 - {'collection_new'}) and 'collection_new' in edit_e7,
      "R6 EDIT-7: every Outliner action sent has a branch (%s)" % sorted(sent_e7 - handled_e7))
check({'activate', 'restrict'} <= sent_e7 and {'activate', 'restrict'} <= offered_e7,
      "R6 EDIT-7 (D18, D19): rows offer and the shell sends activate and restrict (%s)" % sorted(offered_e7))
check('blender.hierarchy.scope' in outliner_swift_e7 and 'Desktop Interface' in outliner_swift_e7,
      "R6 EDIT-7 (D19): the Outliner says what it does not show")
# ROUND6 EDIT-8 (D20): the asset pane lists what the 3D View's drop boxes take, by a table that
# names every drop box Blender registers there; a tap on a material or modifier applies it to the
# active object by a direct call, and its tile is dimmed where that would be refused.
drop_cc_e8 = (SWIFT.parents[2] / 'editors/space_view3d/view3d_dropboxes.cc').read_text(encoding='utf-8')
registered_e8 = set(re.findall(r'WM_dropbox_add\(\s*lb,\s*"(\w+)"', drop_cc_e8))
bridge_e8 = (SWIFT.parents[1] / 'intern/wm_native_ui.cc').read_text(encoding='utf-8')
table_e8 = bridge_e8[bridge_e8.index('bridge_asset_dropboxes[] = {'):]
table_e8 = set(re.findall(r'\{"(\w+_OT_\w+)"', table_e8[:table_e8.index('};')]))
check(len(registered_e8) >= 8 and registered_e8 == table_e8,
      "R6 EDIT-8 (D20): the pane's drop-box table names the 3D View's drop boxes (missing %s, extra %s)" %
      (sorted(registered_e8 - table_e8), sorted(table_e8 - registered_e8)))
assets_swift_e8 = (SWIFT / 'Assets.swift').read_text(encoding='utf-8')
check('bridge_asset_apply(C, *asset);' in bridge_e8 and 'appliesMaterial' in assets_swift_e8 and
      'addsModifier' in assets_swift_e8 and 'private let assetTypes' in assets_swift_e8,
      "R6 EDIT-8 (D20): a material or modifier tap is a direct call, its tile dimmed by Blender's answer")
# ROUND6 EDIT-9 (D21): every image the editor reads or draws goes through one image user with the
# scene and frame (a Render Result was blank without it), and Save As is Blender's own, invoked.
image_cc_e9 = (SWIFT.parents[2] / 'editors/space_image/image_native.cc').read_text(encoding='utf-8')
check('ImageUser user = {};' not in image_cc_e9.replace('ImageUser user = {};\n  BKE_imageuser_default', '')
      and image_cc_e9.count('image_user(C, ') >= 4,
      "R6 EDIT-9 (D21): every image user of the image editor has the scene")
image_swift_e9 = (SWIFT / 'ImageEditor.swift').read_text(encoding='utf-8')
check('model.send("save_as")' in image_swift_e9 and '"IMAGE_OT_save_as", wm::OpCallContext::InvokeDefault' in image_cc_e9,
      "R6 EDIT-9 (D21): Save As runs Blender's own operator with its options and picker")
# ROUND6 EDIT-10 (D17): the storyboard publishes every strip (sound and effects locked), makes room
# with Blender's all-channel shift, runs operators nested so each edit is one undo step of its own,
# and every action it takes is driven by the harness's `storyboard` scenario (undo and redo of each)
# or named as a view action that is not an undo step.
story_cc_e10 = (SWIFT.parents[2] / 'editors/space_sequencer/sequencer_native.cc').read_text(encoding='utf-8')
apply_e10 = story_cc_e10[story_cc_e10.index('std::optional<std::string> apply_edit('):]
apply_e10 = apply_e10[:apply_e10.index('\n}\n')]
actions_e10 = set(re.findall(r'action == "(\w+)"', apply_e10))
harness_e10 = (SWIFT.parents[1] / 'native_ui/tests/mac_bridge_harness.py').read_text(encoding='utf-8')
edits_e10 = ast.literal_eval(re.search(r'STORYBOARD_EDITS = (\([^)]*\))', harness_e10).group(1))
views_e10 = ast.literal_eval(re.search(r'STORYBOARD_VIEW_ACTIONS = (\([^)]*\))', harness_e10).group(1))
driven_e10 = {name.split()[0] for name in edits_e10} | set(views_e10)
check(len(actions_e10) >= 20 and actions_e10 <= driven_e10,
      "R6 EDIT-10 (D17): every storyboard action is driven with undo and redo, or is a view action (%s)" %
      sorted(actions_e10 - driven_e10))
check('item->append_int("locked", 1);' in story_cc_e10 and
      'seq::transform_offset_after_frame(' in story_cc_e10 and 'strip.channel == channel' not in story_cc_e10,
      "R6 EDIT-10 (D17): sound and effects are published locked and moved with the shots")
check(apply_e10.count('WM_operator_name_call(') == 1 and 'SCREEN_OT_animation_play' in apply_e10 and
      'wm->op_undo_depth++;' in story_cc_e10 and 'return "";' not in apply_e10.replace(
          'return "";\n  }\n  if (action == "loop")', '').replace(
          'return "";\n  }\n  if (action == "play")', '').replace(
          'return "";\n  }\n  if (action == "sync")', '').replace(
          'return "";\n  }\n  if (action == "select")', ''),
      "R6 EDIT-10 (D17): operators run nested and every data edit names its one undo step")
storyboard_swift_e10 = (SWIFT / 'Storyboard.swift').read_text(encoding='utf-8')
render_py_e10 = (SWIFT.parents[4] / 'scripts/startup/bl_ui/native_render.py').read_text(encoding='utf-8')
check('renderStory()' in storyboard_swift_e10 and 'use_sequencer_scene' in render_py_e10 and
      '"story"' in bridge_e8,
      "R6 EDIT-10 (D17): Render Story renders the workspace's sequencer scene")
print('PASS: native shell sources ' + json.dumps(checks))

# Sheets separate with space, not boxes (the owner, ROUND6 device round: "every div should be well
# thought out and not separation for the sake of separation"). Every tinted or glass container,
# grouped list and Form in the shell's Swift is counted per file; a file's count may only change
# with this reviewed list, each entry saying why its containers are a unit a person must see as
# one (a control's own style, a selection, a HUD over the 3D View that needs contrast, Blender's own
# drawing). A container added only to set content apart fails here: use spacing and a heading.
TINTED_CONTAINER = re.compile(
    r'\.background\([^\n]*\bin:\s*(?:RoundedRectangle|UnevenRoundedRectangle|Capsule|Circle|ShellShape|shape\b|rounded\b)'
    r'|\.background\(\s*(?:RoundedRectangle|UnevenRoundedRectangle|Capsule\(|Circle\(|shape\.fill|rounded\.fill)'
    r'|\.listStyle\(\.insetGrouped\)|\bGroupBox\b|\.glassBackgroundEffect\(in:|\.panelGlass\(in:|\bForm \{')
TINTED_CONTAINERS_REVIEWED = {
    'ARPreview.swift': (1, "HUD capsule over the camera picture: needs contrast"),
    'Assets.swift': (2, "the browser's glass panel over the 3D View (glass style) and a filter chip (a control)"),
    'BlenderBridge.swift': (1, "a capsule chip: a control's own shape"),
    'CompileIndicator.swift': (3, "pills over the 3D View (shader compile, jobs): HUD, needs contrast"),
    'DesktopCluster.swift': (1, "the cluster's key buttons: a control's own style, over the Desktop Interface"),
    'FCurveEditor.swift': (1, "Form of a key's fields: the system's control layout in a popover (kept; owner may decide)"),
    'FaceControl.swift': (1, "HUD capsule over the 3D View"),
    'FontPicker.swift': (4, "text fields and option chips: controls' own shapes"),
    'HierarchyView.swift': (2, "the selected row's highlight, and a HUD capsule"),
    'ImageEditor.swift': (3, "label and close capsules over the canvas (contrast), New Image's Form (system controls)"),
    'InspectorView.swift': (1, "HUD capsule over the 3D View"),
    'ItemCard.swift': (1, "the Item card over the 3D View: HUD, needs contrast"),
    'Launcher.swift': (1, "visionOS window glass: the platform's window surface"),
    'NativeControls.swift': (4, "Blender's text field and popover surfaces (its widget look), HUD capsules"),
    'NativeLists.swift': (4, "Blender's list box and text field (its widget look), a selected chip, a HUD capsule"),
    'NativePanels.swift': (4, "the selected tab, a HUD capsule, Blender's panels as boxes (Blender draws them so), a drag highlight"),
    'NodeEditor.swift': (6, "nodes, sockets and badges on the node canvas: Blender's own drawing"),
    'QuickActions.swift': (5, "the action bar's buttons and pressed states over the 3D View: HUD controls"),
    'Rails.swift': (12, "the tool rail and its pressed and selected tools over the 3D View: HUD controls"),
    'RedoStrip.swift': (1, "the operator dialog's Form: the system's control layout (kept; owner may decide)"),
    'RenderSheet.swift': (4, "controls over the rendered picture (contrast) and the selected frame"),
    'SettingsSheet.swift': (4, "the pressure curve's plot area, two Settings Forms (system controls), Settings page icons"),
    'ShellMessages.swift': (1, "a message capsule over the 3D View: HUD"),
    'SqueezePalette.swift': (4, "the Pencil palette's ring and label over the 3D View: HUD"),
    'Storyboard.swift': (3, "a strip's colour tag and labels over shot pictures (contrast)"),
    'TemplatePicker.swift': (1, "a template tile: one tappable unit"),
    'UIKitInterop.swift': (6, "tooltip, glass and Blender surfaces of the shared styles (definitions, not uses)"),
    'VisionOrnaments.swift': (2, "visionOS ornaments: the platform's window surfaces"),
}
tinted_found = {}
for path in sources():
    count = len(TINTED_CONTAINER.findall(path.read_text(encoding='utf-8')))
    if count:
        tinted_found[path.name] = count
tinted_unreviewed = sorted(
    "%s: %d found, %s reviewed" % (name, count, TINTED_CONTAINERS_REVIEWED.get(name, (0,))[0])
    for name, count in tinted_found.items() if TINTED_CONTAINERS_REVIEWED.get(name, (0,))[0] != count)
tinted_stale = sorted(set(TINTED_CONTAINERS_REVIEWED) - set(tinted_found))
check(not tinted_unreviewed and not tinted_stale,
      "Sheets separate with space, not boxes: tinted containers not on the reviewed list (say why "
      "each is a unit, or use spacing and a heading): %s; listed but gone: %s" % (
          tinted_unreviewed, tinted_stale))
guide_e = (SWIFT / 'SettingsSheet.swift').read_text(encoding='utf-8')
guide_e = guide_e[guide_e.index('struct GestureGuide: View {'):guide_e.index('struct GestureGuideSheet')]
check('List {' not in guide_e and 'Section {' not in guide_e and '.background(' not in guide_e,
      "How to Use separates its sections with space and a plain heading, not boxes")
print('PASS: sheets separate with space ' + json.dumps(len(tinted_found)))

# Device round (2026-11-21), ROUND6 §0 rule 7 "nothing per frame": `viewport frame insets …` was
# written at every menu build (about 60 lines a second at launch). What is worked out again and
# again says a line only when it changes (`WM_native_ui_log_changed`). Swept: everything the view
# builders, the frame insets and the pointer's middle reach in `wm_native_ui.cc` (the call graph
# within the file), and in Swift what layout passes, display links and view bodies reach. A
# logging function reached from them must compare with what it said last (`!=` or a `guard`
# before the line), or be listed here with why it is said once.
native_n3 = c_code_only((SWIFT.parents[1] / 'intern/wm_native_ui.cc').read_text(encoding='utf-8'))
bodies_n3 = {}
for m in re.finditer(r'^(?:[A-Za-z_][\w:<>,\*& ]*?\s)?\**&?(\w+)\s*\([^;{}]*\)\s*(?:const\s*)?\{', native_n3, re.M):
    if m.group(1) not in ('if', 'for', 'while', 'switch', 'return'):
        bodies_n3[m.group(1)] = bodies_n3.get(m.group(1), '') + native_n3[m.end():c_balanced(native_n3, m.end() - 1)]
roots_n3 = [n for n in bodies_n3 if re.search(r'_view_build$|_json$|_frame_insets$|_view_middle$|_draw$', n)]
reach_n3, stack_n3 = {}, [(n, [n]) for n in roots_n3]
while stack_n3:
    name, path = stack_n3.pop()
    if name in reach_n3:
        continue
    reach_n3[name] = path
    stack_n3 += [(c, path + [c]) for c in set(re.findall(r'\b(\w+)\s*\(', bodies_n3[name]))
                 if c in bodies_n3 and c not in reach_n3 and c != 'WM_native_ui_log_changed']
per_build_logs_n3 = sorted(' -> '.join(path) for name, path in reach_n3.items()
                           if re.search(r'\bWM_native_ui_(?:session_)?log\s*\(', bodies_n3[name]))
check(len(roots_n3) >= 20 and 'WM_native_ui_view3d_frame_insets' in roots_n3 and
      'WM_native_ui_log_changed("viewport", "frame insets"' in
      (SWIFT.parents[1] / 'intern/wm_native_ui.cc').read_text(encoding='utf-8') and not per_build_logs_n3,
      "Nothing per build: what the view builders reach logs only on change (WM_native_ui_log_changed): %s" %
      per_build_logs_n3)
# Said once, at a slide's end, not at each of its steps.
SWIFT_ONCE_N3 = {('DocumentWindow.swift', 'noteSlide')}
swift_per_frame_n3 = []
for path in sources():
    text = path.read_text(encoding='utf-8')
    funcs = {}
    for m in re.finditer(r'\bfunc (\w+)\s*(?:<[^>]*>)?\([^{]*?\{', text):
        funcs.setdefault(m.group(1), []).append((m.group(1), m.end(), balanced(text, m.end() - 1, '{', '}')))
    roots = ['layoutSubviews', 'viewDidLayoutSubviews', 'draw'] + re.findall(
        r'CADisplayLink\(target: self, selector: #selector\((\w+)', text)
    stack = [span for root in roots for span in funcs.get(root, [])]
    for m in re.finditer(r'\bvar body: some View \{', text):
        body = text[m.end():balanced(text, m.end() - 1, '{', '}')]
        if 'WM_native_ui_log(' in body:
            swift_per_frame_n3.append('%s: a view body logs' % path.name)
    seen = set()
    while stack:
        name, start, end = stack.pop()
        if (start, end) in seen:
            continue
        seen.add((start, end))
        body = text[start:end]
        for k in re.finditer(r'WM_native_ui_log\(', body):
            before = body[:k.start()]
            if '!=' not in before and 'guard ' not in before and (path.name, name) not in SWIFT_ONCE_N3:
                swift_per_frame_n3.append('%s %s line %d' % (path.name, name, text[:start + k.start()].count('\n') + 1))
        stack += [span for callee, spans in funcs.items() if re.search(r'\b%s\(' % callee, body) for span in spans]
check(not swift_per_frame_n3,
      "Nothing per frame in Swift: what layout passes, display links and bodies reach logs only on change: %s" %
      swift_per_frame_n3)
print('PASS: nothing per frame ' + json.dumps([len(roots_n3), len(reach_n3)]))

# Device round (2026-11-21): a render run by exec (blocking) showed BUSY-2's veil "Render…" with
# no way to stop it for twelve minutes. The veil offers Stop whenever the operator holding Blender
# stops part way when asked (`G.is_break`, desktop's Esc), from the interface's own thread, and
# says plainly when it cannot. Each operator on the list reads `G.is_break` in its blocking run:
# the evidence for each is checked here, so the list cannot name one that ignores it.
native_b2 = (SWIFT.parents[1] / 'intern/wm_native_ui.cc').read_text(encoding='utf-8')
breakable_b2 = native_b2[native_b2.index('static constexpr const char *bridge_busy_breakable[] = {'):]
breakable_b2 = re.findall(r'"(\w+)"', breakable_b2[:breakable_b2.index('};')])
EDITORS_B2 = ROOT / 'source/blender/editors'
BREAK_EVIDENCE_B2 = {
    'RENDER_OT_render': (EDITORS_B2 / 'render/render_internal.cc',
                         ('RE_test_break_cb(re, nullptr, render_break);', 'static bool render_break(')),
    'OBJECT_OT_bake': (EDITORS_B2 / 'object/object_bake_api.cc',
                       ('RE_test_break_cb(re, nullptr, bake_break);', 'static bool bake_break(')),
    'PTCACHE_OT_bake': (ROOT / 'source/blender/blenkernel/intern/pointcache.cc', ('if (cancel || G.is_break) {',)),
    'PTCACHE_OT_bake_all': (ROOT / 'source/blender/blenkernel/intern/pointcache.cc', ('if (cancel || G.is_break) {',)),
}
for name in ('all', 'data', 'noise', 'mesh', 'particles', 'guides'):
    BREAK_EVIDENCE_B2['FLUID_OT_bake_' + name] = (
        EDITORS_B2 / 'physics/physics_fluid.cc', ('fluid_bake_startjob(job, &worker_status);', 'if (G.is_break) {'))
missing_b2 = [name for name in breakable_b2 if name not in BREAK_EVIDENCE_B2 or not all(
    s in BREAK_EVIDENCE_B2[name][0].read_text(encoding='utf-8') for s in BREAK_EVIDENCE_B2[name][1])]
veil_b2 = (SWIFT / 'CompileIndicator.swift').read_text(encoding='utf-8')
veil_b2 = veil_b2[veil_b2.index('final class BusyVeilState'):]
check(sorted(breakable_b2) == sorted(BREAK_EVIDENCE_B2) and not missing_b2 and
      'G.is_break = true;' in native_b2[native_b2.index('extern "C" bool WM_native_ui_busy_stop()'):] and
      'WM_native_ui_busy_stop_state()' in veil_b2 and 'WM_native_ui_busy_stop()' in veil_b2 and
      'Button("Stop") { state.requestStop() }' in veil_b2 and
      '"Cannot be stopped part way; it ends by itself"' in veil_b2,
      "The busy veil offers Stop for work that stops when asked, and says when it cannot: %s %s" % (
          breakable_b2, missing_b2))

# Device checks of build 2 (2026-11-26): the Desktop Interface's band (`WM_window_rect_calc`) is
# outside Blender's screen, and Blender draws on the window's pixels without clearing them, so the
# band kept the last picture drawn there (the iPad interface's gizmo, a Timeline and status bar from
# before the band). The window's draw clears whatever lies outside that rectangle, for any band.
draw_b2d = (SWIFT.parents[1] / 'intern/wm_draw.cc').read_text(encoding='utf-8')
onscreen_b2d = draw_b2d[draw_b2d.index('static void wm_draw_window_onscreen('):]
onscreen_b2d = onscreen_b2d[:onscreen_b2d.index('ED_screen_areas_iter (win, screen, area)')]
check('WM_window_rect_calc(win, &screen_rect);' in onscreen_b2d and
      re.search(r'screen_rect\.ymin > 0 \|\| screen_rect\.xmax < win_size\[0\] \|\|\s+screen_rect\.ymax < win_size\[1\]',
                onscreen_b2d) is not None and
      'GPU_clear_color(border[0], border[1], border[2], 1.0f);' in onscreen_b2d,
      "The window's pixels outside Blender's screen (the Desktop Interface's band) are cleared each draw")

# Run B3 (2026-11-26), grey screen: opening a second file while one is open faded Blender's window
# out, and the new document opened within the 0.3 s fade. The fade in was decided from
# `window.hidden`, still NO mid-fade, so it never ran and the window stayed at alpha 0 over the
# launcher's grey. The show and hide decide from the window's target alpha, and only the latest
# fade's end may hide the window. Every UIKit fade whose end hides a window or view is held to the
# same rule: its completion checks that no later change superseded it.
system_b3 = (ROOT / 'intern/ghost/intern/GHOST_SystemIOS.mm').read_text(encoding='utf-8')
visible_b3 = system_b3[system_b3.index('void GHOST_ios_document_window_set_visible('):]
visible_b3 = visible_b3[:visible_b3.index('\n}\n')]
check('window.hidden == visible' not in visible_b3 and
      'window.alpha == 1.0' in visible_b3 and
      re.search(r'completion:\^\(BOOL\) \{\s+if \(fade == document_window_fades && '
                r'!document_window_visible\)', visible_b3) is not None,
      "The document window's fade in is decided from its alpha, so a file opened mid fade out shows")
fades_b3 = []
for path_b3 in sorted((ROOT / 'intern/ghost/intern').glob('*IOS*.mm')) + sorted(
        (ROOT / 'source/blender/windowmanager/apple_ios').glob('*.mm')):
    text_b3 = path_b3.read_text(encoding='utf-8')
    for m_b3 in re.finditer(r'completion:\^\(BOOL[^)]*\)\s*\{(?P<body>[^{}]*)\}', text_b3):
        if re.search(r'\.hidden = YES|removeFromSuperview', m_b3.group('body')) and \
                not re.search(r'\bif \(', m_b3.group('body')):
            fades_b3.append('%s:%d' % (path_b3.name, text_b3.count('\n', 0, m_b3.start()) + 1))
check(not fades_b3,
      "Every fade that hides or removes a view at its end first checks it was not superseded: %s" %
      fades_b3)

# Run B3, the dark box: the field typed into (DESK-3) is opaque, so that Blender's field under it
# never shows at once, and it was never hidden: after any text edit an empty dark box stayed over
# the field, in the Desktop Interface and after leaving it. It is hidden from its creation, shown
# for the keyboard and hidden with it.
window_b3 = (ROOT / 'intern/ghost/intern/GHOST_WindowIOS.mm').read_text(encoding='utf-8')
init_b3 = window_b3[window_b3.index('- (void)initUITextField'):]
init_b3 = init_b3[:init_b3.index('\n}\n')]
popup_b3 = window_b3[window_b3.index('- (GHOST_TSuccess)popupOnscreenKeyboard:'):]
popup_b3 = popup_b3[:popup_b3.index('\n}\n')]
hide_b3 = window_b3[window_b3.index('- (GHOST_TSuccess)hideOnscreenKeyboard'):]
hide_b3 = hide_b3[:hide_b3.index('\n}\n')]
check(init_b3.index('text_field.hidden = YES;') < init_b3.index('addSubview:text_field') and
      popup_b3.index('text_field.hidden = NO;') < popup_b3.index('[text_field becomeFirstResponder]') and
      'text_field.hidden = YES;' in hide_b3,
      "The field typed into shows only while the keyboard is up")

# Run B3, silent runs: a check script's `op` step said nothing when its operator was cancelled
# without a reason (a render, which returned at once). The step waits for Blender's answer beside
# the script and logs it, and the bridge logs every operator run by name that cancels unexplained.
snap_b3 = (SWIFT / 'Snapshots.swift').read_text(encoding='utf-8')
op_b3 = snap_b3[snap_b3.index('case "op":'):]
op_b3 = op_b3[:op_b3.index('case "pad":')]
views_b3 = (SWIFT.parents[1] / 'intern/wm_native_ui_views.cc').read_text(encoding='utf-8')
run_b3 = views_b3[views_b3.index('bool operator_run('):]
run_b3 = run_b3[:run_b3.index('\n}\n')]
check('Operators.runAnswered(' in op_b3 and 'Operators.run(' not in op_b3 and
      'outcome(of: command)' in op_b3 and 'no answer in 900 s' in op_b3 and
      'const wmOperatorStatus status = WM_operator_name_call_ptr(' in run_b3 and
      'status & OPERATOR_CANCELLED' in run_b3 and 'WM_native_ui_log("op",' in run_b3,
      "A command run by name, and a script's op step, never end without a word")

# Run B3, the render's figure: Cycles with adaptive sampling reports nearly all its samples at once
# and then works on, so the job pill read 98 % for most of a long render. Both views that show a
# render's progress say when its figure stands still, with the engine's own words, and the pill
# and the render sheet show those words, not the figure, then.
ui_b3 = (SWIFT.parents[1] / 'intern/wm_native_ui.cc').read_text(encoding='utf-8')
jobs_b3 = ui_b3[ui_b3.index('static void bridge_jobs_view_build('):]
jobs_b3 = jobs_b3[:jobs_b3.index('\n}\n')]
render_b3 = ui_b3[ui_b3.index('void bridge_render_view_build('):]
render_b3 = render_b3[:render_b3.index('\n}\n')]
pill_b3 = (SWIFT / 'CompileIndicator.swift').read_text(encoding='utf-8')
sheet_b3 = (SWIFT / 'RenderSheet.swift').read_text(encoding='utf-8')
check('bridge_progress_stalled(key,' in jobs_b3 and 'key + ":stalled"' in jobs_b3 and
      'key + ":phase"' in jobs_b3 and 'bridge_progress_stalled("render",' in render_b3 and
      '"state:stalled"' in render_b3 and '"state:engine_phase"' in render_b3 and
      '!job.stalled' in pill_b3 and 'status.bool("stalled")' in sheet_b3 and
      'if let working = model.working' in sheet_b3,
      "A render's figure that stands still is said as work with the engine's words")

# Run B3, large text: at the accessibility sizes the document window's labels wrapped inside a word
# ("Se-lect", "Collec-tions") or were cut ("Actio..."): it is laid out in points for set widths. Its
# text is held, once at its root, to the size it is laid out for, and the Outliner's Select keeps
# its word whole.
window_text_b3 = (SWIFT / 'DocumentWindow.swift').read_text(encoding='utf-8')
hierarchy_b3 = (SWIFT / 'HierarchyView.swift').read_text(encoding='utf-8')
metrics_b3 = (SWIFT / 'QuickActions.swift').read_text(encoding='utf-8')
body_b3 = window_text_b3[window_text_b3.index('  public var body: some View {\n    window\n'):]
body_b3 = body_b3[:body_b3.index('\n  }\n')]
check('static let limit = DynamicTypeSize.xxxLarge' in metrics_b3 and
      'dynamicTypeSize(...ShellText.limit)' in metrics_b3 and
      re.search(r'\.shellChromeText\(\)\s*$', body_b3) is not None and
      re.search(r'"Select"\) \{.*?\.lineLimit\(1\)\s+\.fixedSize\(\)\s+'
                r'\.accessibilityIdentifier\("blender\.hierarchy\.select"\)', hierarchy_b3, re.S) is not None,
      "The document window's text keeps to the size it is laid out for")

# Run B3, the number field that went into typing (build 2's 5l.1): the check script's step "tap a
# panel's header" (`touch @PROPERTIES+WINDOW#-2`) was answered with the middle of Properties, as if
# no kind had been asked, because every negative kind meant "the region". It tapped a number field,
# which went into typing, and the next step's sideways drag only ended that typing. Only -1 (no
# kind) means the region; panel headers (-2) and every other kind are looked up in the map.
find_b3 = ui_b3[ui_b3.index('bool WM_native_ui_touch_find('):]
find_b3 = find_b3[:find_b3.index('\n}\n')]
check('if (button_type == -1) {' in find_b3 and 'button_type < 0' not in find_b3 and
      'Int32(kind.first ?? "") ?? -1' in snap_b3,
      "A script's touch place of a kind, panel headers included, is that kind's, never the region's middle")

# R8 F2, the render's words: the pill read "Mem:167M, Peak: 317M" (build 3), because the words were
# the last part of the text the render job composes for desktop's render window, which ends in
# Blender's memory line after a draw that carried no engine words. The engine's own words
# (`RenderStats::infostr`) are kept by the render module past their draw, and every view that shows
# a render's words or samples reads them there, never the composed text.
pipeline_r8 = (SWIFT.parents[2] / 'render/intern/pipeline.cc').read_text(encoding='utf-8')
engine_r8 = (SWIFT.parents[2] / 'render/intern/engine.cc').read_text(encoding='utf-8')
status_r8 = ui_b3[ui_b3.index('static std::string bridge_render_status('):]
status_r8 = status_r8[:status_r8.index('\n}\n')]
samples_r8 = ui_b3[ui_b3.index('static double bridge_render_samples('):]
samples_r8 = samples_r8[:samples_r8.index('\n}\n')]
infostr_sets_r8 = re.findall(r'(re->i\.infostr = (?!nullptr)[^;]+;)\n\s*(render_engine_status_set\(re, [^)]*\))?',
                             pipeline_r8)
check('RE_engine_status_get(re)' in status_r8 and 'result->text' not in status_r8 and
      'bridge_render_status(scene)' in samples_r8 and 'result->text' not in samples_r8 and
      'bridge_render_phase' not in ui_b3 and
      ui_b3.count('bridge_render_status(static_cast<const Scene *>(job.owner))') == 2 and
      'render_engine_status_set(re, info);' in engine_r8 and
      infostr_sets_r8 and all(kept for _, kept in infostr_sets_r8),
      "Every view shows a render's words from the engine's own status, never the composed text")
