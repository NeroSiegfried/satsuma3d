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

  /** Writes the face, and for the regular slot its family, then asks Blender to load them. */
  static func choose(_ descriptor: CTFontDescriptor, for property: JSON, store: InspectorStore) {
    let role = property.string("font_role") ?? "font"
    write(descriptor, family: role == "font") { url, faces in
      var extra: JSON = ["id_action": "load_font", "value": url.path]
      if !faces.isEmpty {
        extra["family"] = faces.mapValues { $0.path }
      }
      store.request(property, extra: extra)
    }
  }

  /** The font a written file holds, by its name. */
  static func font(file: String?, size: CGFloat) -> UIFont? {
    guard let file, !file.isEmpty else { return nil }
    return UIFont(name: URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent, size: size)
  }

  /** The font a slot's file was written from, to show its name in it. */
  static func displayName(_ property: JSON) -> String? {
    guard let file = property.string("font_file"), !file.isEmpty else { return nil }
    let name = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
    return UIFont(name: name, size: 12) != nil ? name : nil
  }
}

#if os(macOS)

/** The Mac's font panel for a font slot; a choice applies once the panel settles on it. */
@MainActor
final class FontPickerSession: NSObject {
  static var active: FontPickerSession?
  let property: JSON
  weak var store: InspectorStore?
  private var pending: DispatchWorkItem?

  init(property: JSON, store: InspectorStore) {
    self.property = property
    self.store = store
  }

  func present(from _: AnchorBox) {
    FontPickerSession.active = self
    let manager = NSFontManager.shared
    manager.target = self
    if let name = FontFiles.displayName(property), let font = NSFont(name: name, size: 24) {
      manager.setSelectedFont(font, isMultiple: false)
    }
    manager.orderFrontFontPanel(nil)
  }

  @objc func changeFont(_ sender: Any?) {
    guard let manager = sender as? NSFontManager else { return }
    let font = manager.convert(manager.selectedFont ?? NSFont.systemFont(ofSize: 24))
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, let store = self.store else { return }
      FontFiles.choose(font.fontDescriptor as CTFontDescriptor, for: self.property, store: store)
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
  let property: JSON
  weak var store: InspectorStore?

  init(property: JSON, store: InspectorStore) {
    self.property = property
    self.store = store
  }

  func present(from anchor: AnchorBox) {
    let configuration = UIFontPickerViewController.Configuration()
    configuration.includeFaces = true
    let picker = UIFontPickerViewController(configuration: configuration)
    picker.delegate = self
    if let name = FontFiles.displayName(property), let font = UIFont(name: name, size: 17) {
      picker.selectedFontDescriptor = font.fontDescriptor
    }
    FontPickerSession.active = self
    anchor.present(picker, preferredSize: CGSize(width: 375, height: 600))
  }

  func fontPickerViewControllerDidPickFont(_ picker: UIFontPickerViewController) {
    if let descriptor = picker.selectedFontDescriptor, let store {
      FontFiles.choose(descriptor as CTFontDescriptor, for: property, store: store)
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
 * A text object's fonts as Pages and Keynote show them: the family by name, in its own typeface,
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

struct FontSlotRow: View {
  let store: InspectorStore
  let property: JSON
  private let anchor = AnchorBox()

  private var role: String { property.string("font_role") ?? "font" }
  private var font: UIFont? { FontFiles.font(file: property.string("font_file"), size: 17) }
  private var editable: Bool { property.bool("editable") }
  /** The regular font's family, which the other slots usually share. */
  private var family: String? { FontFiles.font(file: property.string("family_file"), size: 17).map(familyName) }
  private var slotTitle: String {
    ["font_bold": "Bold", "font_italic": "Italic", "font_bold_italic": "Bold Italic"][role] ??
      property.string("label") ?? ""
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
        .disabled(!editable)
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
        .disabled(!editable)
      }
      .frame(minHeight: 40)
    }
  }

  private func pick() {
    FontPickerSession(property: property, store: store).present(from: anchor)
  }

  /** The family's typefaces, as Pages' second font menu. */
  private func typefaceMenu(_ font: UIFont) -> some View {
    Menu {
      ForEach(typefaces(ofFamily: familyName(font)), id: \.name) { face in
        Button {
          guard let chosen = UIFont(name: face.name, size: 17) else { return }
          FontFiles.choose(chosen.fontDescriptor as CTFontDescriptor, for: property, store: store)
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
    .disabled(!editable)
    .accessibilityLabel("Typeface, \(styleName(font))")
  }
}

/** \} */
