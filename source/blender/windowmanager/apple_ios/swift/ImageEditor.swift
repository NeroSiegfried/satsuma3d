/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The Image Editor drawn natively, a viewport of its own beside the 3D one, as Blender's Texture
 * Paint workspace has it: the same rails and sliders paint on either. Blender sends
 * the images, the one shown and its pixels as they change, so a texture fills in while it is
 * painted on the model; the UVs show over it. The image shown follows the texture being painted,
 * as Blender's follows the active paint slot, until another is chosen. See `image_native.cc`.
 */

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/* -------------------------------------------------------------------- */
/** \name Model
 * \{ */

@MainActor
@Observable
final class ImageEditorModel {
  /** What of the image shows, as Blender's Display Channels. */
  enum Channels: String, CaseIterable, Identifiable {
    case colorAlpha = "COLOR_ALPHA", color = "COLOR", alpha = "ALPHA", red = "RED", green = "GREEN", blue = "BLUE"
    var id: String { rawValue }
    var title: String {
      switch self {
        case .colorAlpha: "Color & Alpha"
        case .color: "Color"
        case .alpha: "Alpha"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
      }
    }
    var icon: String {
      switch self {
        case .colorAlpha: "IMAGE_RGB_ALPHA"
        case .color: "IMAGE_RGB"
        case .alpha: "IMAGE_ALPHA"
        case .red: "COLOR_RED"
        case .green: "COLOR_GREEN"
        case .blue: "COLOR_BLUE"
      }
    }
  }

  private(set) var shown = false
  private(set) var snapshot: JSON?
  /** The picture as Blender sent it, in the channels shown. */
  private(set) var picture: CGImage?
  /** The image's own size, which may be larger than the picture sent. */
  private(set) var imageSize: CGSize = .zero
  /** The image the picture is of. */
  private(set) var pictureName = ""
  /** UV edges, two points each, in UV space. */
  private(set) var uvs: [Float] = []
  /** Bumped to fit the image in the view, as when another one shows. */
  private(set) var fitRequest = 0
  /** Bumped to show the image's pixels one to one on the screen. */
  private(set) var actualSizeRequest = 0
  @ObservationIgnored var shownChanged: (Bool) -> Void = { _ in }
  /** The pixels as sent, kept to show other channels. */
  @ObservationIgnored private var rgba: Data?
  @ObservationIgnored private var pixelSize = (width: 0, height: 0)

  var showUVs = UserDefaults.standard.object(forKey: "BlenderImageUVs") as? Bool ?? true {
    didSet { UserDefaults.standard.set(showUVs, forKey: "BlenderImageUVs") }
  }
  var channels = Channels(rawValue: UserDefaults.standard.string(forKey: "BlenderImageChannels") ?? "") ?? .colorAlpha {
    didSet {
      UserDefaults.standard.set(channels.rawValue, forKey: "BlenderImageChannels")
      makePicture()
    }
  }

  var images: [JSON] { snapshot?.array("images") ?? [] }
  var image: JSON? { snapshot?.dict("image") }
  /** The brush strokes paint with: Texture Paint's, as Blender's 2D painting uses. */
  var brush: JSON? { snapshot?.dict("brush") }
  /** The image can be painted on: not a render or a movie. */
  var paintable: Bool { image?.bool("paintable") == true }
  /** The object is in Texture Paint, so the image shown follows what it paints on. */
  var painting: Bool { snapshot?.bool("painting") == true }

  func setShown(_ shown: Bool) {
    guard shown != self.shown else { return }
    self.shown = shown
    if shown { fitRequest += 1 }
    Engine.setting("native_image_visible", shown ? "1" : "0")
    shownChanged(shown)
  }

  /** Shows another image, until the texture painted on changes. */
  func choose(_ name: String) {
    /* Told apart from the last choice, of this or an earlier document. */
    let pick = Int(Date().timeIntervalSince1970 * 1000)
    Engine.setting("native_image_state", json: ["image": name, "pick": pick])
  }

  func send(_ action: String, _ extra: JSON = [:]) {
    var request: JSON = ["action": action]
    request.merge(extra) { $1 }
    Engine.setting("native_image_edit", json: request)
  }

  /** A stroke's points, as x, y in the image's pixels and pressure; \a zoom is the screen's pixels
   * for each of the image's, which the brush's size is measured in. */
  func stroke(_ phase: String, _ points: [Float], zoom: CGFloat) {
    guard !points.isEmpty || phase == "end" else { return }
    send("stroke", ["phase": phase, "points": points.map { Double($0) }, "zoom": Double(zoom)])
  }

  func requestFit() { fitRequest += 1 }
  func requestActualSize() { actualSizeRequest += 1 }

  func update(_ next: JSON) {
    if let snapshot, (snapshot as NSDictionary).isEqual(next as NSDictionary) { return }
    snapshot = next
  }

  /** The picture and UVs Blender published since the last look. */
  func pullPixels() {
    var name: UnsafeMutablePointer<CChar>?
    var pixels: UnsafeMutablePointer<UInt8>?
    var width: Int32 = 0, height: Int32 = 0, fullWidth: Int32 = 0, fullHeight: Int32 = 0
    if WM_apple_ios_ui_image_take_pixels(&name, &pixels, &width, &height, &fullWidth, &fullHeight) {
      let named = name.map { String(cString: $0) } ?? ""
      free(name)
      if let pixels, width > 0, height > 0 {
        rgba = Data(bytesNoCopy: pixels, count: Int(width) * Int(height) * 4, deallocator: .free)
        pixelSize = (Int(width), Int(height))
      }
      else {
        rgba = nil
        pixelSize = (0, 0)
      }
      let size = CGSize(width: Int(fullWidth), height: Int(fullHeight))
      /* Another image, or the same one at another size, is framed anew. */
      if named != pictureName || size != imageSize { fitRequest += 1 }
      pictureName = named
      imageSize = size
      makePicture()
    }
    var segments: UnsafeMutablePointer<Float>?
    var count: Int32 = 0
    if WM_apple_ios_ui_image_take_uvs(&segments, &count) {
      uvs = segments.map { Array(UnsafeBufferPointer(start: $0, count: Int(count))) } ?? []
      free(segments)
    }
  }

  private func makePicture() {
    guard let rgba, pixelSize.width > 0 else {
      picture = nil
      return
    }
    let (width, height) = pixelSize
    switch channels {
      case .colorAlpha, .color:
        guard let provider = CGDataProvider(data: rgba as CFData) else { return }
        /* Color alone leaves the alpha out, as if the image were opaque. */
        let alpha: CGImageAlphaInfo = channels == .color ? .noneSkipLast : .last
        picture = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue), provider: provider,
                          decode: nil, shouldInterpolate: true, intent: .defaultIntent)
      default:
        /* One channel, as gray. */
        let offset = [Channels.red: 0, .green: 1, .blue: 2, .alpha: 3][channels] ?? 3
        var gray = Data(count: width * height)
        rgba.withUnsafeBytes { source in
          gray.withUnsafeMutableBytes { target in
            let from = source.bindMemory(to: UInt8.self), to = target.bindMemory(to: UInt8.self)
            for i in 0..<(width * height) { to[i] = from[i * 4 + offset] }
          }
        }
        guard let provider = CGDataProvider(data: gray as CFData) else { return }
        picture = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                          provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Editor
 * \{ */

/** The Image Editor along the bottom: which image, and the image itself. */
struct ImageEditorPanel: View {
  let model: ImageEditorModel
  /** What the bars and rails over it cover, which the image is fitted clear of. */
  var obscured = EdgeInsets()
  @State private var creating = false
  @State private var opening = false
  @State private var zoom: CGFloat = 1

  var body: some View {
    ZStack {
      if model.snapshot != nil && model.image == nil {
        ContentUnavailableView {
          Label("No Image", systemImage: "photo")
        } description: {
          Text(model.painting ? "Add a texture to paint on in Properties, or a new image here." :
                                "Images show here, such as the textures painted on a model.")
        } actions: {
          Button("New Image") { creating = true }
            .buttonStyle(.borderedProminent)
        }
        .padding(.top, obscured.top)
      }
      else {
        ImageCanvas(model: model, zoom: $zoom, obscured: obscured)
          .ignoresSafeArea()
          .overlay(alignment: .bottomLeading) { info.padding(.bottom, obscured.bottom) }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ImageCanvasView.backdrop.ignoresSafeArea())
    /* Below the window's bar, as the viewport's own controls are. */
    .overlay(alignment: .top) { header.padding(.top, max(0, obscured.top - 52)) }
    .background(NodeKeyCapture(model: model))
    .sheet(isPresented: $creating) {
      NewImageSheet(suggestedName: "Untitled") { request in
        model.send("new", request)
        creating = false
      }
    }
    .fileImporter(isPresented: $opening, allowedContentTypes: [.image]) { result in
      guard case let .success(url) = result else { return }
      openImage(url)
    }
  }

  /** The image shown and what to do with it, floating over the top of the image as the
   * viewport's quick actions float over the scene. Its brush is the rails' and sliders'. */
  private var header: some View {
    HStack(spacing: 4) {
      imagePicker
        .padding(.leading, 14)
        .padding(.trailing, 6)
      moreMenu
      Button { creating = true } label: {
        Label("New Image", systemImage: "plus")
      }
      .editorHeaderButton()
      EditorCloseButton(label: "Close Image Editor") { model.setShown(false) }
    }
    .padding(4)
    .panelGlass(in: Capsule())
    .padding(.horizontal, 12)
  }

  /** The image shown, from all of them, the ones painted on marked with a brush. */
  private var imagePicker: some View {
    Menu {
      Picker("Image", selection: Binding(get: { model.image?.string("name") ?? "" },
                                         set: { model.choose($0) })) {
        ForEach(model.images.compactMap { $0.string("name") }, id: \.self) { name in
          let item = model.images.first { $0.string("name") == name }
          Label {
            Text(name)
            if item?.bool("paint") == true { Text("Painting") }
          } icon: {
            /* Its preview, as materials show theirs; a symbol until it is rendered. */
            if let preview = PreviewCache.image(item?.string("preview")) {
              Image(uiImage: preview)
            }
            else {
              Image(systemName: item?.bool("paint") == true ? "paintbrush.pointed" : "photo")
            }
          }
          .tag(name)
        }
      }
      .pickerStyle(.inline)
      Section {
        Button("New Image…", systemImage: "plus") { creating = true }
        Button("Open Image…", systemImage: "folder") { opening = true }
      }
    } label: {
      HStack(spacing: 4) {
        Text(model.image?.string("name") ?? "No Image")
          .lineLimit(1)
        if model.image?.bool("dirty") == true {
          /* Painted on since it was last kept. */
          Text("*").foregroundStyle(.secondary)
        }
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .font(.subheadline.weight(.medium))
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .accessibilityLabel("Image")
  }

  private var moreMenu: some View {
    Menu {
      Section {
        Toggle(isOn: Binding(get: { model.showUVs }, set: { model.showUVs = $0 })) {
          Label("UVs", systemImage: "square.grid.3x3")
        }
        Picker(selection: Binding(get: { model.channels }, set: { model.channels = $0 })) {
          ForEach(ImageEditorModel.Channels.allCases) { channels in
            Label {
              Text(channels.title)
            } icon: {
              if let icon = BlenderIcon.image(channels.icon) { Image(uiImage: icon) }
            }
            .tag(channels)
          }
        } label: {
          Label("Display Channels", systemImage: "circle.lefthalf.filled")
        }
        .pickerStyle(.menu)
      }
      Section {
        Button("Frame All", systemImage: "arrow.up.left.and.arrow.down.right") { model.requestFit() }
        Button("Actual Size", systemImage: "1.magnifyingglass") { model.requestActualSize() }
      }
      Section {
        let image = model.image
        /* Kept in the document, which saves itself: painted pixels are otherwise lost. */
        Button("Pack into Document", systemImage: "shippingbox") { model.send("pack") }
          .disabled(image == nil || (image?.bool("packed") == true && image?.bool("dirty") != true))
        Button("Reload", systemImage: "arrow.clockwise") { model.send("reload") }
          .disabled(image == nil || image?.string("source") == "GENERATED" || image?.bool("dirty") == true)
        Button("Share…", systemImage: "square.and.arrow.up") { share() }
          .disabled(image == nil)
      }
    } label: {
      Label("More", systemImage: "ellipsis")
    }
    .editorHeaderButton()
  }

  /** The image's size and the zoom, in a corner. */
  @ViewBuilder
  private var info: some View {
    if let image = model.image, let width = image.int("width"), let height = image.int("height"), width > 0 {
      HStack(spacing: 6) {
        Text(verbatim: "\(width) × \(height)")
        Text(verbatim: "·").foregroundStyle(.tertiary)
        Text(zoom, format: .percent.precision(.fractionLength(0)))
          .monospacedDigit()
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .glassEffect(.regular, in: Capsule())
      .padding(10)
      .allowsHitTesting(false)
    }
  }

  /** A file from elsewhere, copied where Blender can read it and kept in the document. */
  private func openImage(_ url: URL) {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OpenedImages", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let copy = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent(url.lastPathComponent)
    do {
      try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: url, to: copy)
    }
    catch { return }
    model.send("open", ["path": copy.path])
  }

  /** The image as a PNG, which Blender writes, to share or save. */
  private func share() {
    guard let name = model.image?.string("name") else { return }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SharedImages", isDirectory: true)
    try? FileManager.default.removeItem(at: folder)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let safe = name.replacingOccurrences(of: "/", with: "-")
    let url = folder.appendingPathComponent((safe as NSString).deletingPathExtension + ".png")
    model.send("export", ["path": url.path])
    /* Written on Blender's side; offered once it is there. */
    Task { @MainActor in
      for _ in 0..<50 {
        if FileManager.default.fileExists(atPath: url.path) {
          try? await Task.sleep(for: .milliseconds(100))
          ImageSharing.present(url)
          return
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }
}

@MainActor
private enum ImageSharing {
  static func present(_ url: URL) {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive }),
      let root = scene.keyWindow?.rootViewController
    else { return }
    var top = root
    while let presented = top.presentedViewController { top = presented }
    let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    if let popover = activity.popoverPresentationController {
      popover.sourceView = top.view
      popover.sourceRect = CGRect(x: top.view.bounds.maxX - 80, y: top.view.bounds.maxY - 80, width: 1, height: 1)
    }
    top.present(activity, animated: true)
  }
}

private struct NewImageSheet: View {
  let suggestedName: String
  let create: (JSON) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var width = 1024
  @State private var height = 1024
  @State private var color = Color.black
  @State private var alpha = true
  @State private var type = "BLANK"
  @State private var float = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Name", text: $name)
        }
        Section {
          Picker("Size", selection: Binding(get: { width == height && [512, 1024, 2048, 4096].contains(width) ? width : 0 },
                                            set: { if $0 > 0 { width = $0; height = $0 } })) {
            ForEach([512, 1024, 2048, 4096], id: \.self) { Text(verbatim: "\($0) × \($0)").tag($0) }
            if !(width == height && [512, 1024, 2048, 4096].contains(width)) { Text("Custom").tag(0) }
          }
          Stepper(value: $width, in: 1...16384, step: 64) {
            LabeledContent("Width") { Text(verbatim: "\(width) px").monospacedDigit() }
          }
          Stepper(value: $height, in: 1...16384, step: 64) {
            LabeledContent("Height") { Text(verbatim: "\(height) px").monospacedDigit() }
          }
        }
        Section {
          Picker("Fill", selection: $type) {
            Text("Blank").tag("BLANK")
            Text("UV Grid").tag("UV_GRID")
            Text("Color Grid").tag("COLOR_GRID")
          }
          if type == "BLANK" {
            ColorPicker("Color", selection: $color, supportsOpacity: alpha)
          }
          Toggle("Alpha", isOn: $alpha)
          Toggle("32-bit Float", isOn: $float)
        }
      }
      .navigationTitle("New Image")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            create(["name": trimmed.isEmpty ? suggestedName : trimmed, "width": width, "height": height,
                    "color": rgba, "alpha": alpha ? 1 : 0, "type": type, "float": float ? 1 : 0])
          }
        }
      }
    }
    .onAppear { name = suggestedName }
    .presentationDetents([.medium, .large])
  }

  /** Linear, as Blender's color properties are. */
  private var rgba: [Double] {
    let resolved = color.resolve(in: EnvironmentValues())
    return [Double(resolved.linearRed), Double(resolved.linearGreen), Double(resolved.linearBlue),
            Double(resolved.opacity)]
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Canvas
 *
 * The image in a scroll view, which zooms about the fingers or the pointer and pans, as the
 * system's own pictures do. Pixels show as squares once larger than the screen's, as Blender
 * shows them; the checkerboard behind stays the same size on screen. A Pencil or pointer paints
 * on it with the brush, as Blender's Paint mode does. Fingers move the view, or with Settings'
 * Pencil and Fingers one paints and two move it, as in the viewport.
 * \{ */

private struct ImageCanvas: UIViewRepresentable {
  let model: ImageEditorModel
  @Binding var zoom: CGFloat
  var obscured = EdgeInsets()
  /** Settings' Apple Pencil & Touch, which the viewport follows too. */
  @AppStorage(SettingsModel.fingerUsesToolKey) private var fingerUsesTool = false

  func makeUIView(context: Context) -> ImageCanvasView {
    ImageCanvasView()
  }

  func updateUIView(_ view: ImageCanvasView, context: Context) {
    /* Told after the update that changed it, as it may change during one. */
    view.zoomChanged = { value in
      DispatchQueue.main.async { if abs(value - zoom) > 0.001 { zoom = value } }
    }
    view.show(picture: model.picture, size: model.imageSize, checker: model.channels == .colorAlpha)
    view.show(uvs: model.showUVs ? model.uvs : [])
    view.fit(request: model.fitRequest)
    view.actualSize(request: model.actualSizeRequest)
    view.obscured = UIEdgeInsets(top: obscured.top, left: obscured.leading, bottom: obscured.bottom,
                                 right: obscured.trailing)
    /* Painted as the 3D viewport is, in Texture Paint, with its brush. */
    view.paintable = model.paintable && model.painting
    view.fingerPaints = fingerUsesTool
    view.brushRadius = CGFloat((model.brush?["radius"] as? NSNumber)?.doubleValue ?? 0)
    view.stroke = { phase, points, zoom in model.stroke(phase, points, zoom: zoom) }
  }
}

final class ImageCanvasView: UIView, UIScrollViewDelegate {
  private let scroll = UIScrollView()
  /** The zoomed view, as large as the image in points at a zoom of 1. */
  private let content = UIView()
  private let picture = CALayer()
  private let uvLayer = CAShapeLayer()
  /** Behind the image, unzoomed. */
  private let checker = UIView()
  private var imageSize: CGSize = .zero
  private var uvs: [Float] = []
  private var fitSeen = -1
  private var actualSizeSeen = 0
  /** Fitted, and kept so as the view changes size, until zoomed or panned. */
  private var fitted = true
  var zoomChanged: (CGFloat) -> Void = { _ in }
  /** Strokes on the image, as its pixels and pressures, see #ImageEditorModel.stroke. */
  var stroke: (String, [Float], CGFloat) -> Void = { _, _, _ in }
  var paintable = false {
    didSet {
      painter.isEnabled = paintable
      if !paintable { cursor.isHidden = true }
    }
  }
  /** One finger paints, as the Pencil does, and two move the view: Settings' Pencil and Fingers,
   * as in the viewport. Otherwise fingers only move the view. */
  var fingerPaints = false {
    didSet {
      guard fingerPaints != oldValue else { return }
      var types = [UITouch.TouchType.pencil, .indirectPointer]
      if fingerPaints { types.append(.direct) }
      painter.allowedTouchTypes = types.map { NSNumber(value: $0.rawValue) }
      scroll.panGestureRecognizer.minimumNumberOfTouches = fingerPaints ? 2 : 1
      doubleTap.isEnabled = !fingerPaints
    }
  }
  /** The brush's radius in the screen's pixels, as Blender measures it. */
  var brushRadius: CGFloat = 0
  /** A Pencil or a pointer paints at once, and a finger too when it uses the tool. */
  private let painter = StrokeRecognizer()
  private let doubleTap = UITapGestureRecognizer()
  /** The brush's circle where a Pencil or pointer hovers. */
  private let cursor = CAShapeLayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    backgroundColor = Self.backdropColor
    checker.backgroundColor = UIColor(patternImage: Self.checkerTile)
    checker.isUserInteractionEnabled = false
    addSubview(checker)

    scroll.delegate = self
    scroll.showsHorizontalScrollIndicator = false
    scroll.showsVerticalScrollIndicator = false
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.decelerationRate = .fast
    scroll.bouncesZoom = true
    addSubview(scroll)
    scroll.addSubview(content)

    picture.magnificationFilter = .nearest
    picture.minificationFilter = .trilinear
    picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    content.layer.addSublayer(picture)

    uvLayer.fillColor = nil
    uvLayer.strokeColor = UIColor(white: 1, alpha: 0.7).cgColor
    uvLayer.shadowColor = UIColor.black.cgColor
    uvLayer.shadowOpacity = 0.5
    uvLayer.shadowRadius = 0.5
    uvLayer.shadowOffset = .zero
    uvLayer.actions = ["path": NSNull(), "lineWidth": NSNull(), "bounds": NSNull(), "position": NSNull()]
    content.layer.addSublayer(uvLayer)

    doubleTap.addTarget(self, action: #selector(doubleTapped(_:)))
    doubleTap.numberOfTapsRequired = 2
    doubleTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    scroll.addGestureRecognizer(doubleTap)

    /* Fingers pan; trackpads and mice scroll to pan as well. */
    scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    scroll.panGestureRecognizer.allowedScrollTypesMask = .all
    painter.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue),
                                 NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
    painter.space = content
    painter.addTarget(self, action: #selector(painted(_:)))
    painter.isEnabled = false
    scroll.addGestureRecognizer(painter)
    let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
    scroll.addGestureRecognizer(hover)

    cursor.fillColor = nil
    cursor.strokeColor = UIColor.white.cgColor
    cursor.lineWidth = 1
    cursor.shadowColor = UIColor.black.cgColor
    cursor.shadowOpacity = 0.6
    cursor.shadowRadius = 1
    cursor.shadowOffset = .zero
    cursor.isHidden = true
    cursor.actions = ["position": NSNull(), "path": NSNull(), "hidden": NSNull()]
    layer.addSublayer(cursor)
  }

  /** Points in the content view as the image's pixels, bottom row first as Blender's are. */
  private func imagePoints(_ samples: [(CGPoint, CGFloat)]) -> [Float] {
    samples.flatMap { point, pressure in
      [Float(point.x), Float(imageSize.height - point.y), Float(pressure)]
    }
  }

  private var strokeZoom: CGFloat { scroll.zoomScale * screenScale }

  @objc private func painted(_ gesture: StrokeRecognizer) {
    let points = imagePoints(gesture.take())
    switch gesture.state {
      case .began: stroke("begin", points, strokeZoom)
      case .changed: stroke("points", points, strokeZoom)
      case .ended: stroke("end", points, strokeZoom)
      /* A second finger moves the view instead: what the first painted goes, as in the viewport. */
      case .cancelled, .failed: stroke("cancel", [], strokeZoom)
      default: break
    }
    if gesture.touchType != .direct { showCursor(at: gesture.location(in: self)) }
  }

  @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
    switch gesture.state {
      case .began, .changed: showCursor(at: gesture.location(in: self))
      default: cursor.isHidden = true
    }
  }

  private func showCursor(at point: CGPoint) {
    let radius = brushRadius / screenScale
    guard paintable, radius > 0 else {
      cursor.isHidden = true
      return
    }
    cursor.path = UIBezierPath(ovalIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)).cgPath
    cursor.position = point
    cursor.isHidden = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /** Behind the image, dark as the viewport's backdrop is whatever the interface's appearance. */
  private static let backdropColor = UIColor(white: 0.16, alpha: 1)
  static var backdrop: Color { Color(uiColor: backdropColor) }

  /** What covers the view's edges, which fitting and centering keep the image clear of. */
  var obscured = UIEdgeInsets.zero {
    didSet {
      guard obscured != oldValue else { return }
      updateZoomLimits()
      if fitted { applyFit(animated: false) } else { center() }
    }
  }

  private static let checkerTile: UIImage = {
    let side: CGFloat = 8
    return UIGraphicsImageRenderer(size: CGSize(width: side * 2, height: side * 2)).image { context in
      UIColor(white: 0.4, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: side * 2, height: side * 2))
      UIColor(white: 0.6, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: side, height: side))
      context.fill(CGRect(x: side, y: side, width: side, height: side))
    }
  }()

  func show(picture image: CGImage?, size: CGSize, checker showChecker: Bool) {
    picture.contents = image
    checker.isHidden = !showChecker || image == nil
    guard size != imageSize else { return }
    imageSize = size
    let scale = scroll.zoomScale
    scroll.zoomScale = 1
    content.frame = CGRect(origin: .zero, size: size)
    picture.frame = content.bounds
    uvLayer.frame = content.bounds
    scroll.contentSize = size
    scroll.zoomScale = scale
    updateZoomLimits()
    rebuildUVPath()
    setNeedsLayout()
  }

  func show(uvs next: [Float]) {
    guard next != uvs else { return }
    uvs = next
    rebuildUVPath()
  }

  func fit(request: Int) {
    guard request != fitSeen else { return }
    fitSeen = request
    fitted = true
    setNeedsLayout()
    layoutIfNeeded()
    applyFit(animated: request > 0 && window != nil)
  }

  func actualSize(request: Int) {
    guard request != actualSizeSeen else { return }
    actualSizeSeen = request
    zoom(to: 1 / screenScale, about: CGPoint(x: bounds.midX, y: bounds.midY), animated: true)
  }

  private var screenScale: CGFloat { window?.screen.scale ?? traitCollection.displayScale }

  /** The zoom that shows the whole image, with a margin. */
  private var fitScale: CGFloat {
    let room = bounds.inset(by: obscured)
    guard imageSize.width > 0, imageSize.height > 0, room.width > 0, room.height > 0 else { return 1 }
    let margin: CGFloat = 24
    return max(0.0001, min((room.width - margin * 2) / imageSize.width,
                           (room.height - margin * 2) / imageSize.height))
  }

  private func updateZoomLimits() {
    scroll.minimumZoomScale = min(fitScale * 0.5, 1 / screenScale)
    /* Up to each pixel 32 of the screen's across, as Blender zooms. */
    scroll.maximumZoomScale = max(fitScale * 2, 32 / screenScale)
  }

  private func applyFit(animated: Bool) {
    updateZoomLimits()
    let apply = {
      self.scroll.zoomScale = self.fitScale
      self.center()
    }
    if animated {
      UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: apply)
    }
    else {
      apply()
    }
    fitted = true
    zoomDidChange()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if scroll.frame != bounds {
      scroll.frame = bounds
      updateZoomLimits()
      if fitted { applyFit(animated: false) }
    }
    center()
    placeChecker()
  }

  /** Smaller than what is left uncovered, the image stays in its middle; larger, it scrolls to
   * its edges there. */
  private func center() {
    let size = CGSize(width: imageSize.width * scroll.zoomScale, height: imageSize.height * scroll.zoomScale)
    let room = scroll.bounds.inset(by: obscured)
    let x = max(0, (room.width - size.width) / 2)
    let y = max(0, (room.height - size.height) / 2)
    scroll.contentInset = UIEdgeInsets(top: obscured.top + y, left: obscured.left + x, bottom: obscured.bottom + y,
                                       right: obscured.right + x)
  }

  private func placeChecker() {
    checker.frame = content.convert(content.bounds, to: self).intersection(bounds)
    /* The pattern lines up with the image's corner as it moves. */
    let origin = content.convert(CGPoint.zero, to: self)
    checker.bounds.origin = CGPoint(x: checker.frame.minX - origin.x, y: checker.frame.minY - origin.y)
  }

  private func zoom(to scale: CGFloat, about point: CGPoint, animated: Bool) {
    let target = min(max(scale, scroll.minimumZoomScale), scroll.maximumZoomScale)
    let location = content.convert(point, from: self)
    let size = CGSize(width: bounds.width / target, height: bounds.height / target)
    let rect = CGRect(x: location.x - size.width / 2, y: location.y - size.height / 2,
                      width: size.width, height: size.height)
    fitted = false
    scroll.zoom(to: rect, animated: animated)
    if !animated { zoomDidChange() }
  }

  @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
    /* Fitted, closer in where tapped; otherwise all of it again. */
    if abs(scroll.zoomScale - fitScale) < fitScale * 0.05 {
      zoom(to: max(fitScale * 3, 1 / screenScale), about: gesture.location(in: self), animated: true)
    }
    else {
      applyFit(animated: true)
    }
  }

  private func rebuildUVPath() {
    let path = CGMutablePath()
    let w = CGFloat(imageSize.width), h = CGFloat(imageSize.height)
    if w > 0, h > 0 {
      var i = 0
      while i + 3 < uvs.count {
        path.move(to: CGPoint(x: CGFloat(uvs[i]) * w, y: (1 - CGFloat(uvs[i + 1])) * h))
        path.addLine(to: CGPoint(x: CGFloat(uvs[i + 2]) * w, y: (1 - CGFloat(uvs[i + 3])) * h))
        i += 4
      }
    }
    uvLayer.path = path
    uvLayer.isHidden = uvs.isEmpty
    updateLineWidth()
  }

  /** One point wide on screen, at any zoom. */
  private func updateLineWidth() {
    let scale = max(scroll.zoomScale, 0.0001)
    uvLayer.lineWidth = 1 / scale
    uvLayer.shadowRadius = 0.5 / scale
  }

  private func zoomDidChange() {
    updateLineWidth()
    placeChecker()
    zoomChanged(scroll.zoomScale * screenScale)
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

  func scrollViewDidZoom(_ scrollView: UIScrollView) {
    center()
    zoomDidChange()
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) { placeChecker() }

  func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { fitted = false }
  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { fitted = false }
}

/** Begins as soon as a Pencil or pointer touches, with every sample of its movement and the
 * Pencil's pressure, rather than after moving a little as a pan does. */
final class StrokeRecognizer: UIGestureRecognizer {
  /** Where samples are measured. */
  weak var space: UIView?
  private var tracked: UITouch?
  private var samples: [(CGPoint, CGFloat)] = []

  /** The samples since the last look. */
  func take() -> [(CGPoint, CGFloat)] {
    defer { samples = [] }
    return samples
  }

  private func sample(_ touch: UITouch) -> (CGPoint, CGFloat) {
    (touch.preciseLocation(in: space), touch.type == .pencil ? Self.pressure(touch) : 1)
  }

  /** The Pencil's force as the pressure the viewport gets, with Settings' curve, see
   * `pencil_pressure` in `GHOST_WindowIOS.mm`. */
  private static func pressure(_ touch: UITouch) -> CGFloat {
    guard touch.maximumPossibleForce > 0 else { return 1 }
    let setting = UserDefaults.standard.object(forKey: "BlenderPencilPressureSensitivity") as? Double
    let sensitivity = min(1, max(0, setting ?? 0.5))
    let full = 0.9 - 0.5 * sensitivity, exponent = 1.0 - 0.75 * sensitivity
    return CGFloat(pow(min(1, max(0, Double(touch.force / touch.maximumPossibleForce) / full)), exponent))
  }

  /** The kind of touch painting. */
  private(set) var touchType: UITouch.TouchType = .pencil

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    guard tracked == nil, touches.count == 1, let touch = touches.first else {
      /* A second finger: the fingers move the view rather than paint. */
      if tracked?.type == .direct || touches.contains(where: { $0.type == .direct }) {
        state = tracked == nil ? .failed : .cancelled
      }
      else {
        for touch in touches where touch !== tracked { ignore(touch, for: event) }
      }
      return
    }
    touchType = touch.type
    tracked = touch
    samples = [sample(touch)]
    state = .began
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let tracked, touches.contains(tracked) else { return }
    for touch in event.coalescedTouches(for: tracked) ?? [tracked] { samples.append(sample(touch)) }
    state = .changed
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let tracked, touches.contains(tracked) else { return }
    samples.append(sample(tracked))
    state = .ended
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let tracked, touches.contains(tracked) else { return }
    state = .cancelled
  }

  override func reset() {
    super.reset()
    tracked = nil
    samples = []
  }

  /* The scroll view's pinch and pan take over from a finger as a second one lands. */
  override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
  override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Hardware Keys
 *
 * As Blender's Image Editor has them for viewing: Home frames the image, and 1 shows its pixels one
 * to one on the screen.
 * \{ */

extension ImageEditorModel: HardwareKeyTarget {
  var takesKeys: Bool { shown }

  func sendKey(_ key: String, shift: Bool, ctrl: Bool, alt: Bool, oskey: Bool) {
    switch key {
      case "HOME", "PERIOD": requestFit()
      case "ONE": requestActualSize()
      default: break
    }
  }
}

/** \} */
