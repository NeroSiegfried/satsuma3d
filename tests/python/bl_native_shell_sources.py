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
check('"desktop_uv_editing"' in image_editor and '"desktop_uv_editing"' in bridge_text,
      "9B.6: Edit UVs in Desktop Interface reaches Blender's settings view")
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
check(mode_uses >= 5 and not wrong_modes,
      "R6 0.4: every string the shell compares with Blender's mode is one Blender gives (%d uses; %s)"
      % (mode_uses, wrong_modes))
row_text = (SWIFT / 'ToolSettingsRow.swift').read_text(encoding='utf-8')
check('model.hasTransformSettings' in row_text and 'flag("transform_settings")' in
      (SWIFT / 'ShellModel.swift').read_text(encoding='utf-8') and
      'builder.add(top, "transform_settings"' in bridge_text,
      "R6 0.4: the row of transform settings shows where Blender says the mode has them")

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
      'StickyModifierKeys(model: model)' in window_t8 and 'model.desktop || controlsShown' in window_t8,
      "R6 TOUCH-8: the keys are drawn in both interfaces and let go when their buttons go")

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

print('PASS: native shell sources ' + json.dumps(checks))
