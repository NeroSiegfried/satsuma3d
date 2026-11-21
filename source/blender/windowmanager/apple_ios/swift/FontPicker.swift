/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Fonts for text objects from the system's font picker: the iPad's, or the Mac's font panel.
 * Blender loads fonts from files, so the chosen face is written out as a font file of its own,
 * which Blender packs into the document. Choosing the regular face also sets the family's bold,
 * italic and bold italic faces, as text apps do.
 */

import CoreText
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum FontFiles {
  /** Where the written fonts are kept, by PostScript name. */
  private static var directory: URL? {
    guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
      return nil
    }
    let directory = caches.appendingPathComponent("Fonts", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  static func postScriptName(_ font: CTFont) -> String {
    CTFontCopyPostScriptName(font) as String
  }

  /** A font file of the face alone, which a system font in a collection is not. */
  static func file(for font: CTFont) -> URL? {
    guard let directory else { return nil }
    /* The array holds the tags themselves, not objects. */
    guard let available = CTFontCopyAvailableTables(font, []) else { return nil }
    let tags = (0..<CFArrayGetCount(available)).map {
      UInt32(truncatingIfNeeded: UInt(bitPattern: CFArrayGetValueAtIndex(available, $0)))
    }
    guard !tags.isEmpty else { return nil }
    let cff = tags.contains(0x4346_4620) /* 'CFF ' */
    let name = postScriptName(font).replacingOccurrences(of: "/", with: "-")
    let url = directory.appendingPathComponent(name + (cff ? ".otf" : ".ttf"))
    if FileManager.default.fileExists(atPath: url.path) {
      return url
    }
    var tables: [(UInt32, Data)] = []
    for tag in tags.sorted() {
      if let data = CTFontCopyTable(font, CTFontTableTag(tag), []) as Data? {
        tables.append((tag, data))
      }
    }
    guard let data = sfnt(tables, cff: cff), (try? data.write(to: url, options: .atomic)) != nil else {
      return nil
    }
    return url
  }

  /** The OpenType file format: a table directory, then each table, four byte aligned. */
  private static func sfnt(_ tables: [(UInt32, Data)], cff: Bool) -> Data? {
    guard !tables.isEmpty, tables.count < 0xFFFF else { return nil }
    var data = Data()
    func u16(_ value: Int) { data.append(contentsOf: [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) }
    func u32(_ value: UInt32) {
      data.append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
                               UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
    let count = tables.count
    var power = 1, log = 0
    while power * 2 <= count { power *= 2; log += 1 }
    u32(cff ? 0x4F54_544F /* 'OTTO' */ : 0x0001_0000)
    u16(count)
    u16(power * 16)
    u16(log)
    u16(count * 16 - power * 16)
    var offset = 12 + 16 * count
    for (tag, table) in tables {
      u32(tag)
      u32(checksum(table))
      u32(UInt32(offset))
      u32(UInt32(table.count))
      offset += (table.count + 3) & ~3
    }
    for (_, table) in tables {
      data.append(table)
      data.append(contentsOf: [UInt8](repeating: 0, count: ((table.count + 3) & ~3) - table.count))
    }
    return data
  }

  private static func checksum(_ table: Data) -> UInt32 {
    var sum: UInt32 = 0
    var bytes = [UInt8](table)
    bytes.append(contentsOf: [UInt8](repeating: 0, count: ((bytes.count + 3) & ~3) - bytes.count))
    var index = 0
    while index < bytes.count {
      sum &+= UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16 |
        UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])
      index += 4
    }
    return sum
  }

  /** The family's bold, italic and bold italic faces, for Blender's font slots of those names. */
  static func family(of font: CTFont) -> [String: URL] {
    let family = CTFontCopyFamilyName(font) as String
    var faces: [String: URL] = [:]
    for (slot, traits) in [("font_bold", CTFontSymbolicTraits.traitBold),
                           ("font_italic", .traitItalic),
                           ("font_bold_italic", [.traitBold, .traitItalic])]
    {
      let mask: CTFontSymbolicTraits = [.traitBold, .traitItalic]
      guard let face = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, traits, mask),
            CTFontCopyFamilyName(face) as String == family,
            CTFontGetSymbolicTraits(face).intersection(mask) == traits,
            let url = file(for: face)
      else { continue }
      faces[slot] = url
    }
    return faces
  }

  /** Writes the face, and with `family` its bold and italic faces, away from the main thread. */
  static func write(_ descriptor: CTFontDescriptor, family withFamily: Bool,
                    then done: @escaping @MainActor (URL, [String: URL]) -> Void)
  {
    DispatchQueue.global(qos: .userInitiated).async {
      let font = CTFontCreateWithFontDescriptor(descriptor, 0, nil)
      guard let url = file(for: font) else { return }
      let faces = withFamily ? family(of: font) : [:]
      DispatchQueue.main.async { done(url, faces) }
    }
  }

  /** The font a written file holds, by its name. */
  static func font(file: String?, size: CGFloat) -> UIFont? {
    guard let file, !file.isEmpty else { return nil }
    return UIFont(name: URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent, size: size)
  }

}

#if os(macOS)

/** The Mac's font panel for a font slot; a choice applies once the panel settles on it. */
@MainActor
final class FontPickerSession: NSObject {
  static var active: FontPickerSession?
  /** The font file shown as chosen, and what to do with a choice. */
  private let current: String?
  private let pick: (CTFontDescriptor) -> Void
  private var pending: DispatchWorkItem?

  init(current: String?, pick: @escaping (CTFontDescriptor) -> Void) {
    self.current = current
    self.pick = pick
  }

  func present(from _: AnchorBox) {
    FontPickerSession.active = self
    let manager = NSFontManager.shared
    manager.target = self
    if let font = FontFiles.font(file: current, size: 24) {
      manager.setSelectedFont(font, isMultiple: false)
    }
    manager.orderFrontFontPanel(nil)
  }

  @objc func changeFont(_ sender: Any?) {
    guard let manager = sender as? NSFontManager else { return }
    let font = manager.convert(manager.selectedFont ?? NSFont.systemFont(ofSize: 24))
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.pick(font.fontDescriptor as CTFontDescriptor)
    }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
  }

  @objc func validModesForFontPanel(_ panel: NSFontPanel) -> NSFontPanel.ModeMask {
    [.collection, .face]
  }
}

#else

/** The iPad's font picker for a font slot, its faces included. */
@MainActor
final class FontPickerSession: NSObject, UIFontPickerViewControllerDelegate {
  static var active: FontPickerSession?
  /** The font file shown as chosen, and what to do with a choice. */
  private let current: String?
  private let pick: (CTFontDescriptor) -> Void

  init(current: String?, pick: @escaping (CTFontDescriptor) -> Void) {
    self.current = current
    self.pick = pick
  }

  func present(from anchor: AnchorBox) {
    let configuration = UIFontPickerViewController.Configuration()
    configuration.includeFaces = true
    let picker = UIFontPickerViewController(configuration: configuration)
    picker.delegate = self
    if let font = FontFiles.font(file: current, size: 17) {
      picker.selectedFontDescriptor = font.fontDescriptor
    }
    FontPickerSession.active = self
    anchor.present(picker, preferredSize: CGSize(width: 375, height: 600))
  }

  func fontPickerViewControllerDidPickFont(_ picker: UIFontPickerViewController) {
    if let descriptor = picker.selectedFontDescriptor {
      pick(descriptor as CTFontDescriptor)
    }
    picker.dismiss(animated: true)
    FontPickerSession.active = nil
  }

  func fontPickerViewControllerDidCancel(_ picker: UIFontPickerViewController) {
    FontPickerSession.active = nil
  }
}

#endif

/* -------------------------------------------------------------------- */
/** \name Font Rows
 *
 * A text object's fonts as the system's apps show them: the family by name, in its own typeface,
 * with its typeface beneath; Blender's bold and italic fonts as rows of their own.
 * \{ */

/** A family's typefaces: PostScript name and style name, as the system lists them. */
private func typefaces(ofFamily family: String) -> [(name: String, style: String)] {
#if os(macOS)
  return (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { member in
    guard let name = member.first as? String, member.count > 1, let style = member[1] as? String else { return nil }
    return (name, style)
  }
#else
  return UIFont.fontNames(forFamilyName: family).map { name in
    let style = UIFont(name: name, size: 12)?.fontDescriptor.object(forKey: .face) as? String
    return (name, style ?? name)
  }
#endif
}

/** The font's family, which only the Mac's fonts may lack. */
private func familyName(_ font: UIFont) -> String {
#if os(macOS)
  return font.familyName ?? font.fontName
#else
  return font.familyName
#endif
}

private func styleName(_ font: UIFont) -> String {
  font.fontDescriptor.object(forKey: .face) as? String ?? "Regular"
}

/** A font slot of a view's panel: its family, typeface and, for the bold and italic slots, the
 * face they use. A font chosen loads from its file, the regular one with its family's faces. */
struct NativeFontSlotRow: View {
  let model: PanelsModel
  let node: NativeNode
  private let anchor = AnchorBox()

  private var reference: Blender_NativeUI_Reference? { node.reference }
  private var role: String { node.node.property ?? "font" }
  private var font: UIFont? { FontFiles.font(file: reference?.file, size: 17) }
  /** The regular font's family, which the other slots usually share. */
  private var family: String? {
    let regular = model.view.top.map { model.children(ofAll: $0) }?.first {
      $0.kind == .reference && $0.node.property == "font"
    }
    return FontFiles.font(file: regular?.reference?.file, size: 17).map(familyName)
  }
  private var slotTitle: String {
    ["font_bold": "Bold", "font_italic": "Italic", "font_bold_italic": "Bold Italic"][role] ?? node.label
  }

  var body: some View {
    if role == "font" {
      VStack(alignment: .leading, spacing: 8) {
        Button(action: pick) {
          HStack {
            Text(font.map(familyName) ?? "Default Font")
              .font(font.map { Font($0 as CTFont) } ?? .body)
              .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
          }
          .padding(.horizontal, 12)
          .frame(minHeight: 44)
          .background(PanelStyle.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(PresentationAnchor(anchor: anchor))
        .disabled(!node.enabled)
        .accessibilityLabel("Font, \(font.map(familyName) ?? "Default Font")")
        .accessibilityHint("Shows the fonts to choose from.")
        if let font, typefaces(ofFamily: familyName(font)).count > 1 {
          typefaceMenu(font)
        }
      }
      .padding(.vertical, 4)
    }
    else {
      /* Blender's fonts for bold and italic text, which choosing a family sets too. */
      HStack {
        Text(slotTitle)
        Spacer(minLength: 8)
        Button(action: pick) {
          HStack(spacing: 4) {
            Text(font.map { familyName($0) == family ? styleName($0) : "\(familyName($0)) \(styleName($0))" } ?? "Default")
              .font(font.map { Font($0.withSize(15) as CTFont) } ?? .body)
              .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
          }
          .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .background(PresentationAnchor(anchor: anchor))
        .disabled(!node.enabled)
      }
      .frame(minHeight: 40)
    }
  }

  private func pick() {
    FontPickerSession(current: reference?.file) { choose($0) }.present(from: anchor)
  }

  /** Writes the face, and for the regular slot its family, then loads them in Blender. */
  private func choose(_ descriptor: CTFontDescriptor) {
    FontFiles.write(descriptor, family: role == "font") { url, faces in
      var files = [url.path]
      if !faces.isEmpty {
        files += ["font_bold", "font_italic", "font_bold_italic"].map { faces[$0]?.path ?? "" }
      }
      model.send(node, .add, .texts(files))
    }
  }

  /** The family's typefaces, in a second menu beside the family. */
  private func typefaceMenu(_ font: UIFont) -> some View {
    Menu {
      ForEach(typefaces(ofFamily: familyName(font)), id: \.name) { face in
        Button {
          guard let chosen = UIFont(name: face.name, size: 17) else { return }
          choose(chosen.fontDescriptor as CTFontDescriptor)
        } label: {
          if face.name == font.fontName { Label(face.style, systemImage: "checkmark") }
          else { Text(face.style) }
        }
      }
    } label: {
      HStack {
        Text(styleName(font))
        Spacer(minLength: 8)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 12)
      .frame(minHeight: 40)
      .background(PanelStyle.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!node.enabled)
    .accessibilityLabel("Typeface, \(styleName(font))")
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Text Section
 *
 * A text object's text, as a text inspector shows it: its font, bold, italic and underline,
 * and size; its alignment; its spacing. Out of Edit Mode these style all of the text, while
 * typing what is selected and what is typed next.
 * \{ */

struct TextStyleSection: View {
  let style: JSON
  private let anchor = AnchorBox()
  /** Values just set, shown until Blender's snapshot has them. */
  @State private var local: [String: Double] = [:]

  private var font: UIFont? { FontFiles.font(file: style.string("font_file"), size: 17) }

  private func edit(_ name: String, _ value: NativeValue) {
    ShellModel.current?.setText(name, value)
  }

  private func number(_ key: String) -> Double {
    local[key] ?? (style[key] as? NSNumber)?.doubleValue ?? 0
  }

  private func setNumber(_ key: String, _ value: Double) {
    local[key] = value
    edit(key, .float(value))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 17) {
      card {
        fontRow
        Divider()
        stylesRow
        Divider()
        stepperRow("Size", key: "size", step: 0.1, range: 0.0001...10000, field: true)
      }
      card {
        alignmentRow(key: "align_x", choices: [
          ("LEFT", "text.alignleft", "Align Left"), ("CENTER", "text.aligncenter", "Center"),
          ("RIGHT", "text.alignright", "Align Right"), ("JUSTIFY", "text.justify", "Justify"),
        ], same: ["FLUSH": "JUSTIFY"])
        Divider()
        alignmentRow(key: "align_y", choices: [
          ("TOP", "arrow.up.to.line", "Align Top"),
          ("CENTER", "arrow.down.and.line.horizontal.and.arrow.up", "Align Middle"),
          ("BOTTOM", "arrow.down.to.line", "Align Bottom"),
        ], same: ["TOP_BASELINE": "TOP", "BOTTOM_BASELINE": "BOTTOM"])
      }
      card {
        stepperRow("Line Spacing", key: "space_line", step: 0.1, range: 0...10)
        Divider()
        stepperRow("Tracking", key: "space_character", step: 0.1, range: 0...10)
        Divider()
        stepperRow("Word Spacing", key: "space_word", step: 0.1, range: 0...10)
      }
    }
    .onChange(of: style.map { "\($0.key)=\($0.value)" }.sorted()) { _, _ in local.removeAll() }
  }

  /** A group of rows with dividers, apart from the next by the stack's spacing: no card behind
   * it (ROUND6 device round: space separates, not boxes). */
  private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(spacing: 0) { content() }
      .padding(.horizontal, 12)
  }

  /** The family by name, which the system's font picker chooses. */
  private var fontRow: some View {
    Button {
      FontPickerSession(current: style.string("font_file")) { descriptor in
        /* The family's bold and italic faces along with it, which Blender's styles use. */
        FontFiles.write(descriptor, family: true) { url, faces in
          let lines = ["font=" + url.path] + faces.map { "\($0.key)=\($0.value.path)" }
          ShellModel.current?.setText("font", .texts(lines))
        }
      }.present(from: anchor)
    } label: {
      HStack(spacing: 8) {
        Text("Font")
        Spacer(minLength: 8)
        Text(font.map(familyName) ?? "Default")
          .font(font.map { Font($0 as CTFont) } ?? .body)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .frame(minHeight: 48)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(PresentationAnchor(anchor: anchor))
    .accessibilityLabel("Font, \(font.map(familyName) ?? "Default")")
  }

  /** Bold, italic and underline, with small caps among the rest, in one row. */
  private var stylesRow: some View {
    HStack(spacing: 0) {
      styleButton("BOLD", key: "bold", symbol: "bold", title: "Bold")
      styleButton("ITALIC", key: "italic", symbol: "italic", title: "Italic")
      styleButton("UNDERLINE", key: "underline", symbol: "underline", title: "Underline")
      Menu {
        Toggle("Small Caps", isOn: Binding(
          get: { style.bool("small_caps") },
          set: { edit("small_caps", .bool($0)) }))
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 19, weight: .semibold))
          .frame(maxWidth: .infinity, minHeight: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("More Text Options")
    }
    .padding(.vertical, 6)
  }

  private func styleButton(_ name: String, key: String, symbol: String, title: String) -> some View {
    let on = style.bool(key)
    return Button {
      edit(name.lowercased(), .bool(!on))
    } label: {
      Image(systemName: symbol)
        .font(.system(size: 19, weight: .semibold))
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(on ? Color.primary.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityAddTraits(on ? .isSelected : [])
  }

  /** A value with the system's minus and plus. */
  private func stepperRow(_ title: String, key: String, step: Double, range: ClosedRange<Double>,
                          field: Bool = false) -> some View
  {
    let value = number(key)
    return HStack(spacing: 10) {
      Text(title)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .layoutPriority(1)
      Spacer(minLength: 4)
      /* Tapped, the number takes a typed value; the stepper nudges it. */
      TextField(title, value: Binding(get: { value },
                                      set: { setNumber(key, min(range.upperBound, max(range.lowerBound, $0))) }),
                format: .number.precision(.fractionLength(2)))
        .keyboardType(.decimalPad)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(width: 84, height: 36)
        .background(PanelStyle.field, in: Capsule())
      Stepper(title, value: Binding(get: { value }, set: { setNumber(key, min(range.upperBound, max(range.lowerBound, $0))) }),
              in: range, step: step)
        .labelsHidden()
    }
    .frame(minHeight: 52)
  }

  /** Choices as a row of icons, the chosen one filled. */
  private func alignmentRow(key: String, choices: [(String, String, String)], same: [String: String]) -> some View {
    let raw = style.string(key) ?? ""
    let current = same[raw] ?? raw
    return HStack(spacing: 6) {
      ForEach(choices, id: \.0) { value, symbol, title in
        let chosen = value == current
        Button {
          edit(key == "align_x" ? "align" : "align_y", .text(value))
        } label: {
          Image(systemName: symbol)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(chosen ? Color.white : .primary)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(chosen ? Color.accentColor : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
      }
    }
    .padding(.vertical, 8)
  }
}

/** \} */
