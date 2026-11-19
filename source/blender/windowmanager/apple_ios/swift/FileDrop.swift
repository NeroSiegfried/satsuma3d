/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Files dragged in from other apps drop on the viewport where they land, as on a Mac: images,
 * models, .blend files and anything else Blender opens.
 *
 * Where a dropped file is kept (ROUND6 FILES-5, decision R6-14): what Blender can pack (images,
 * fonts, models, whose textures are images) is copied into the app's temporary folder and packed
 * into the document as it is next written, so the document holds it wherever it goes. What
 * Blender reads by its path and cannot pack (movies, sounds, caches, a .blend to link) is kept in
 * "Brought In" in the app's own documents, which Files shows and backups keep. The hidden
 * "Dropped Files" folder is no longer used.
 */

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FileDrop: DropDelegate {
  let model: ShellModel
  /** Assets dragged out of the pane drop through their own path. */
  let assetDragging: () -> Bool

  /** Image formats Blender reads directly. Others, such as HEIC photos, become PNG. */
  private static let readableImages: [UTType] = [.png, .jpeg, .tiff, .bmp, .webP] +
    ["com.ilm.openexr-image", "public.radiance", "com.truevision.tga-image", "public.jpeg-2000"]
      .compactMap { UTType($0) }

  func validateDrop(info: DropInfo) -> Bool {
    !assetDragging() && info.hasItemsConforming(to: [.data, .image])
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .copy)
  }

  func performDrop(info: DropInfo) -> Bool {
    let providers = info.itemProviders(for: [.data, .image])
    guard !providers.isEmpty else { return false }
    let stamp = Self.dropStamp()
    let point = info.location
    let window = model.window
    Task {
      var paths: [String] = []
      for (index, provider) in providers.enumerated() {
        if let path = await Self.copy(provider, index: index, stamp: stamp) { paths.append(path) }
      }
      await MainActor.run {
        if paths.isEmpty { Haptics.error() }
        else { wm_apple_ios_window_drop_files(window, paths, point) }
      }
    }
    return true
  }

  /** One name per drop, so files of the same name never replace each other. */
  private static func dropStamp() -> String {
    let format = DateFormatter()
    format.dateFormat = "yyyy-MM-dd HH.mm.ss"
    return "\(format.string(from: Date())) \(UUID().uuidString.prefix(8))"
  }

  /** Files Blender reads by their path and cannot pack into the document. */
  static func keptByPath(_ type: UTType) -> Bool {
    if type.conforms(to: .movie) || type.conforms(to: .audio) { return true }
    let ext = type.preferredFilenameExtension?.lowercased() ?? ""
    return ["abc", "vdb", "usd", "usda", "usdc", "usdz", "blend", "mov", "mp4", "mkv", "avi",
            "webm"].contains(ext)
  }

  /** The drop's folder for a file of `type`: the app's temporary folder for what is packed, "Brought
   * In" in the app's documents for what is read by its path. */
  private static func dropFolder(for type: UTType, stamp: String) -> URL? {
    let files = FileManager.default
    let base: URL
    if keptByPath(type) {
      guard let documents = try? files.url(for: .documentDirectory, in: .userDomainMask,
                                           appropriateFor: nil, create: true) else { return nil }
      base = documents.appending(path: "Brought In", directoryHint: .isDirectory)
    } else {
      base = files.temporaryDirectory.appending(path: "Dropped", directoryHint: .isDirectory)
    }
    let folder = base.appending(path: stamp, directoryHint: .isDirectory)
    return (try? files.createDirectory(at: folder, withIntermediateDirectories: true)) != nil ? folder : nil
  }

  /** The original's name, with the type's extension when it has none, as Blender's drop boxes
   * and importers recognize files by extension. */
  private static func fileName(_ name: String?, _ type: UTType, _ index: Int) -> String {
    var name = (name as NSString?)?.lastPathComponent ?? ""
    if name.isEmpty || name.hasPrefix(".") { name = "Dropped \(index + 1)" }
    if (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension {
      name = (name as NSString).appendingPathExtension(ext) ?? name
    }
    return name
  }

  /** Copy one item into its drop folder, returning its path, or nil when it offers nothing
   * Blender could open. */
  private static func copy(_ provider: NSItemProvider, index: Int, stamp: String) async -> String? {
    let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
      for readable in readableImages {
        if let type = types.first(where: { $0.conforms(to: readable) }) {
          return await copyFile(provider, type: type, index: index, stamp: stamp)
        }
      }
      if provider.canLoadObject(ofClass: UIImage.self) {
        let image: UIImage? = await withCheckedContinuation { done in
          _ = provider.loadObject(ofClass: UIImage.self) { object, _ in done.resume(returning: object as? UIImage) }
        }
        let name = fileName((provider.suggestedName as NSString?)?.deletingPathExtension, .png, index)
        guard let folder = dropFolder(for: .png, stamp: stamp) else { return nil }
        let target = folder.appending(path: name)
        guard let png = image?.pngData(), (try? png.write(to: target)) != nil else { return nil }
        return target.path
      }
    }
    /* Any other file (models, .blend, fonts, ...): copied as it is. */
    guard let type = types.first(where: { $0.conforms(to: .data) && !$0.conforms(to: .url) }) else { return nil }
    return await copyFile(provider, type: type, index: index, stamp: stamp)
  }

  private static func copyFile(_ provider: NSItemProvider, type: UTType, index: Int, stamp: String) async -> String? {
    guard let folder = dropFolder(for: type, stamp: stamp) else { return nil }
    let suggested = provider.suggestedName
    return await withCheckedContinuation { done in
      _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
        /* The file is deleted when this returns, so copy it now. */
        guard let url else { return done.resume(returning: nil) }
        let target = folder.appending(path: fileName(url.lastPathComponent.isEmpty ? suggested : url.lastPathComponent,
                                                     type, index))
        done.resume(returning: (try? FileManager.default.copyItem(at: url, to: target)) != nil ? target.path : nil)
      }
    }
  }
}
