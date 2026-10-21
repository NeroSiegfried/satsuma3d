/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The asset pane along the bottom of the viewport: the assets Blender publishes, by type and
 * catalog, searchable. Tapping one adds it; dragging one into the viewport runs Blender's own asset
 * drag and drop through the engine inbox.
 */

import SwiftUI
import UIKit

/* Matches #IOSAssetDragPhase in `wm_apple_ios_ui.cc`. */
enum AssetDragPhase: Int32 {
  case begin = 0, move = 1, drop = 2, cancel = 3, add = 4
}

private let assetsHeight: CGFloat = 212
private let assetsCompactHeight: CGFloat = 184
private let assetsMaxWidth: CGFloat = 1600
let assetTile: CGFloat = 96
/* The pane opens on the Starter library's basic shapes. */
private let startType = "Object"
private let startCategory = "Primitives"

/** Data-block types Blender publishes, with their Blender icon and a readable plural. */
private let assetTypes: [(type: String, icon: String, plural: String)] = [
  ("Object", "OBJECT_DATA", "Objects"), ("Collection", "OUTLINER_COLLECTION", "Collections"),
  ("Material", "MATERIAL", "Materials"), ("World", "WORLD", "Worlds"), ("Modifier", "MODIFIER", "Modifiers"),
]

func assetTypeIcon(_ type: String?) -> UIImage? {
  if let entry = assetTypes.first(where: { $0.type == type }) { return BlenderIcon.image(entry.icon) }
  return UIImage(systemName: "shippingbox")
}

/** What tapping an asset does, matching where Blender's drop boxes accept it. */
private func assetAddTitle(_ type: String?) -> String {
  switch type {
    case "Material": return "Apply to Active Object"
    case "Modifier": return "Add to Active Object"
    case "World": return "Use as World"
    default: return "Add at 3D Cursor"
  }
}

/** Where a drop lands, shown in the drag preview over the viewport. */
func assetDropHint(_ type: String?) -> String {
  type == "Material" || type == "Modifier" ? "Drop on an object" : "Drop to place"
}

/** Catalogs are browsed by name, merging libraries. */
private func assetCategory(_ item: JSON) -> String? {
  guard let catalog = item.string("catalog"), !catalog.isEmpty else { return nil }
  return (catalog as NSString).lastPathComponent
}

@MainActor
final class AssetsStore: ObservableObject {
  @Published var items: [JSON] = []
  @Published var loading = true
  @Published var type = startType
  @Published var category: String? = startCategory
  @Published var query = ""
  @Published var visible = false
  /** An asset dragged out of the pane is over the viewport: the pane fades so the scene shows. */
  @Published var overViewport = false
  /** Where the pane is in the window, to tell a drag over it from one over the viewport. */
  var paneFrame = CGRect.zero
  var close: () -> Void = {}
  /** The asset being dragged out of the pane, for the viewport's drop interaction. */
  var dragged: JSON?
  /** An asset pulled up out of the pane at once, without the system's hold to lift it: where
   * the finger is, in the window. */
  var pull: ((AssetPullPhase, JSON, CGPoint) -> Void)?

  private var terms: [String] { query.split(whereSeparator: \.isWhitespace).map(String.init) }

  var types: [String] {
    let present = Set(items.compactMap { $0.string("type") })
    return assetTypes.map(\.type).filter(present.contains)
  }

  var categories: [String] {
    var names = Array(Set(items.filter { $0.string("type") == type }.compactMap(assetCategory)))
    names.sort { $0.localizedStandardCompare($1) == .orderedAscending }
    /* The basic shapes lead, as the place to start. */
    if let index = names.firstIndex(of: startCategory) { names.insert(names.remove(at: index), at: 0) }
    return names
  }

  /** A search looks through every category of the type. */
  var shownCategory: String? { terms.isEmpty ? category : nil }

  var filtered: [JSON] {
    let terms = self.terms
    let category = shownCategory
    return items.filter { item in
      guard item.string("type") == type, category == nil || assetCategory(item) == category else { return false }
      /* Every word must match the name, tags, catalog, description or author, like the Asset
       * Browser's filter. */
      let haystack = ([item.string("name"), item.string("catalog"), item.string("description"),
                       item.string("author"), item.string("type")].compactMap { $0 } + item.strings("tags"))
        .joined(separator: "\n")
      return terms.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
  }

  func update(_ snapshot: JSON) {
    loading = snapshot.bool("loading")
    let next = snapshot.array("items")
    if !(next as NSArray).isEqual(items as NSArray) { items = next }
    /* Nothing of that type: show the first type there is. */
    if !types.isEmpty && !types.contains(type) {
      type = types[0]
      category = nil
    }
    if let category, !items.isEmpty && !categories.contains(category) { self.category = nil }
  }

  func add(_ item: JSON) {
    WM_apple_ios_ui_asset_drag(AssetDragPhase.add.rawValue, item.string("id") ?? "", 0, 0)
    Haptics.impact()
  }
}

struct AssetsPane: View {
  @ObservedObject var store: AssetsStore

  var body: some View {
    VStack(spacing: 4) {
      HStack(spacing: 8) {
        typeMenu
        if !store.categories.isEmpty { categoryMenu }
        PanelSearchField(text: $store.query, prompt: "Search Assets", identifier: "blender.assets.search")
          .frame(maxWidth: .infinity)
        EditorCloseButton(label: "Hide Assets", action: store.close)
      }
      .frame(height: 40)
      .padding(.leading, 14)
      .padding(.trailing, 12)
      .padding(.top, 10)
      grid
        .padding(.bottom, 8)
    }
  }

  private var typeMenu: some View {
    Menu {
      Picker("Type", selection: Binding(get: { store.type }, set: { store.type = $0; store.category = nil })) {
        ForEach(store.types, id: \.self) { type in
          Label {
            Text(assetTypes.first { $0.type == type }?.plural ?? type)
          } icon: {
            if let image = assetTypeIcon(type) { Image(uiImage: image) }
          }
          .tag(type)
        }
      }
      .pickerStyle(.inline)
    } label: {
      menuLabel(store.type)
    }
    .glassButtonStyle()
    .accessibilityIdentifier("blender.assets.type")
  }

  private var categoryMenu: some View {
    Menu {
      Picker("Category", selection: Binding(get: { store.shownCategory ?? "" },
                                            set: { store.category = $0.isEmpty ? nil : $0 })) {
        Text("All Categories").tag("")
        Section {
          ForEach(store.categories, id: \.self) { Text($0).tag($0) }
        }
      }
      .pickerStyle(.inline)
    } label: {
      menuLabel(store.shownCategory ?? "All Categories")
    }
    .glassButtonStyle()
    .accessibilityIdentifier("blender.assets.category")
  }

  private func menuLabel(_ title: String) -> some View {
    HStack(spacing: 4) {
      Text(title).lineLimit(1)
      Image(systemName: "chevron.up.chevron.down").font(.caption)
    }
    .frame(maxWidth: 200)
    .fixedSize()
  }

  @ViewBuilder
  private var grid: some View {
    let items = store.filtered
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(spacing: 10) {
        ForEach(Array(items.enumerated()), id: \.element.assetID) { _, item in
          AssetTile(store: store, item: item)
        }
      }
      .padding(.horizontal, 14)
      .frame(maxHeight: .infinity, alignment: .top)
    }
    .dismissesKeyboardOnScroll(interactively: false)
    .overlay {
      if items.isEmpty {
        Text(store.loading && store.items.isEmpty ? "Loading Assets…" :
               store.query.isEmpty ? "No Assets" : "No Results for \u{201C}\(store.query)\u{201D}")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .accessibilityIdentifier("blender.assets.grid")
  }
}

private extension Dictionary where Key == String, Value == Any {
  var assetID: String { string("id") ?? "" }
}

enum AssetPullPhase { case begin, move, drop }

struct AssetTile: View {
  @ObservedObject var store: AssetsStore
  let item: JSON
  /** A drag on the tile pulls the asset out, or else scrolls the pane; decided as it starts. */
  @State private var pulling: Bool?

  var body: some View {
    Button {
      store.add(item)
    } label: {
      VStack(spacing: 6) {
        thumbnail
        Text(item.string("name") ?? "")
          .font(.caption)
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(.primary)
          .frame(width: assetTile + 8)
      }
    }
    .buttonStyle(AssetTileStyle())
    .accessibilityLabel(item.string("name") ?? "")
    .accessibilityHint(assetAddTitle(item.string("type")))
    .accessibilityIdentifier("blender.asset." + (item.string("name") ?? ""))
    .contextMenu { menu }
    /* Pulled upwards, towards the scene, it lifts at once; sideways the pane scrolls. A hold
     * lifts it too, as the system does. */
    .simultaneousGesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
      .onChanged { value in
        if pulling == nil {
          let up = -value.translation.height
          pulling = up > abs(value.translation.width)
          if pulling == true { store.pull?(.begin, item, value.location) }
        }
        if pulling == true { store.pull?(.move, item, value.location) }
      }
      .onEnded { value in
        if pulling == true { store.pull?(.drop, item, value.location) }
        pulling = nil
      })
    .onDrag {
      store.dragged = item
      return NSItemProvider(object: (item.string("name") ?? "") as NSString)
    } preview: {
      thumbnail
    }
  }

  private var thumbnail: some View {
    Group {
      if let image = PreviewCache.image(item.string("preview")) {
        Image(uiImage: image).resizable().scaledToFill()
      }
      else if let icon = assetTypeIcon(item.string("type")) {
        Image(uiImage: icon).foregroundStyle(.secondary)
      }
    }
    .frame(width: assetTile, height: assetTile)
    .background(PanelStyle.field)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  @ViewBuilder
  private var menu: some View {
    let subtitle = (item.string("catalog") ?? "").isEmpty ? item.string("library") ?? "" :
      "\(item.string("library") ?? "") · \(item.string("catalog") ?? "")"
    if let description = item.string("description"), !description.isEmpty { Text(description) }
    Section(subtitle) {
      Button { store.add(item) } label: { Label(assetAddTitle(item.string("type")), systemImage: "plus") }
      if let category = assetCategory(item) {
        Button {
          store.query = ""
          store.type = item.string("type") ?? store.type
          store.category = category
        } label: {
          Label("Show \(category)", systemImage: "square.grid.2x2")
        }
      }
    }
  }
}

private struct AssetTileStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
  }
}

/* -------------------------------------------------------------------- */
/** \name Pane
 * \{ */

/** The asset pane along the bottom of the window, in the system's glass. */
struct AssetsPanel: View {
  @ObservedObject var store: AssetsStore
  let compact: Bool

  static func height(compact: Bool) -> CGFloat { compact ? assetsCompactHeight : assetsHeight }

  var body: some View {
    AssetsPane(store: store)
      .frame(maxWidth: assetsMaxWidth)
      .frame(height: Self.height(compact: compact))
      .panelGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
      .opacity(store.overViewport ? 0.35 : 1)
      .animation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.2), value: store.overViewport)
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { store.paneFrame = $0 }
      .accessibilityIdentifier("blender.assets.panel")
  }
}

#if !os(macOS) /* The Mac drags with AppKit, see `MacAssets.swift`. */
/** The pane's state and Blender's side of it, and dragging assets from it into the viewport. */
@MainActor
final class SwiftAssets: NSObject, UIDropInteractionDelegate {
  let store = AssetsStore()
  var visible: Bool { store.visible }
  private(set) var dropInteraction: UIDropInteraction!
  var clientPoint: ((CGPoint) -> CGPoint)?
  var visibilityDidChange: (() -> Void)?

  private var dragging = false
  private var dropped = false
  private var dropPoint = CGPoint.zero

  override init() {
    super.init()
    dropInteraction = UIDropInteraction(delegate: self)
    store.close = { [weak self] in self?.toggle() }
    store.pull = { [weak self] phase, item, point in self?.pull(phase, item, point) }
  }

  /* -------------------------------------------------------------------- */
  /** \name Pulling an asset out of the pane
   * \{ */

  /** The asset under the finger while it is pulled out: its thumbnail, or over the viewport the
   * pill naming it. */
  private var pullPreview: UIView?
  private var pullOverViewport = false

  private func pull(_ phase: AssetPullPhase, _ item: JSON, _ point: CGPoint) {
    guard let view = dropInteraction.view, let window = view.window else { return }
    let over = !store.paneFrame.contains(point)
    let local = view.convert(point, from: nil)
    let client = clientPoint?(local) ?? local
    let id = item.string("id") ?? ""
    switch phase {
      case .begin:
        Haptics.impact(.light)
        pullOverViewport = false
        showPullPreview(item, over: false, in: window)
      case .move:
        if over != pullOverViewport {
          pullOverViewport = over
          showPullPreview(item, over: over, in: window)
          if over { Haptics.selection() }
          withAnimation(.easeOut(duration: 0.15)) { store.overViewport = over }
          WM_apple_ios_ui_asset_drag(over ? AssetDragPhase.begin.rawValue : AssetDragPhase.cancel.rawValue,
                                     id, Int32(client.x.rounded()), Int32(client.y.rounded()))
        }
        else if over {
          WM_apple_ios_ui_asset_drag(AssetDragPhase.move.rawValue, id, Int32(client.x.rounded()),
                                     Int32(client.y.rounded()))
        }
      case .drop:
        if pullOverViewport {
          WM_apple_ios_ui_asset_drag(AssetDragPhase.drop.rawValue, id, Int32(client.x.rounded()),
                                     Int32(client.y.rounded()))
          Haptics.impact(.medium)
        }
        let preview = pullPreview
        pullPreview = nil
        UIView.animate(withDuration: 0.2, animations: {
          preview?.alpha = 0
          preview?.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
        }, completion: { _ in preview?.removeFromSuperview() })
        pullOverViewport = false
        withAnimation(.easeOut(duration: 0.15)) { store.overViewport = false }
        return
    }
    pullPreview?.center = CGPoint(x: point.x, y: point.y - (pullOverViewport ? 44 : 0))
  }

  private func showPullPreview(_ item: JSON, over: Bool, in window: UIWindow) {
    let center = pullPreview?.center
    pullPreview?.removeFromSuperview()
    let preview: UIView
    if over {
      let pill = UIHostingController(rootView: AssetDropPill(item: item))
      pill.view.backgroundColor = .clear
      let size = pill.sizeThatFits(in: CGSize(width: 320, height: 56))
      pill.view.frame = CGRect(x: 0, y: 0, width: size.width, height: 56)
      preview = pill.view
    }
    else {
      let image = UIImageView(image: PreviewCache.image(item.string("preview")) ?? assetTypeIcon(item.string("type")))
      image.frame = CGRect(x: 0, y: 0, width: assetTile, height: assetTile)
      image.contentMode = PreviewCache.image(item.string("preview")) != nil ? .scaleAspectFill : .center
      image.backgroundColor = .tertiarySystemFill
      image.layer.cornerRadius = 14
      image.clipsToBounds = true
      preview = image
    }
    preview.isUserInteractionEnabled = false
    preview.layer.shadowColor = UIColor.black.cgColor
    preview.layer.shadowOpacity = 0.25
    preview.layer.shadowRadius = 12
    window.addSubview(preview)
    if let center { preview.center = center }
    pullPreview = preview
  }

  /** \} */

  func updateSnapshot(_ snapshot: Any?) {
    /* Blender's JSON may hold null, which arrives as NSNull. */
    guard let snapshot = snapshot as? JSON else { return }
    store.update(snapshot)
  }

  func toggle() {
    withAnimation(SwiftTimeline.animation) { store.visible.toggle() }
    Engine.setting("assets", visible ? "show" : "hide")
    visibilityDidChange?()
  }

  /* -------------------------------------------------------------------- */
  /** \name Dropping into the viewport
   * \{ */

  private func asset(_ session: UIDropSession) -> JSON? {
    guard session.localDragSession != nil, session.items.count == 1, let item = store.dragged,
          !(item.string("id") ?? "").isEmpty
    else { return nil }
    return item
  }

  /** Whether the drag is over the viewport rather than this pane. */
  private func isOverViewport(_ session: UIDropSession) -> Bool {
    guard let view = dropInteraction.view else { return false }
    return !store.paneFrame.contains(view.convert(session.location(in: view), to: nil))
  }

  private func sendDrag(_ phase: AssetDragPhase, _ session: UIDropSession) {
    guard let view = dropInteraction.view else { return }
    let point = session.location(in: view)
    let client = clientPoint?(point) ?? point
    WM_apple_ios_ui_asset_drag(phase.rawValue, asset(session)?.string("id") ?? "", Int32(client.x.rounded()),
                               Int32(client.y.rounded()))
  }

  /** Over the viewport the lifted thumbnail becomes a compact pill beside the finger, so the
   * surface under it, and Blender's preview of where the asset lands, stay visible. */
  private func pillPreview(_ item: JSON) -> UIDragPreview {
    let pill = UIHostingController(rootView: AssetDropPill(item: item))
    pill.view.backgroundColor = .clear
    let size = pill.sizeThatFits(in: CGSize(width: 320, height: 56))
    let gap: CGFloat = 20
    /* The preview's center sits under the finger: place the pill in the upper left quarter. */
    let container = UIView(frame: CGRect(x: 0, y: 0, width: 2 * (size.width + gap), height: 2 * (56 + gap)))
    container.backgroundColor = .clear
    container.overrideUserInterfaceStyle = dropInteraction.view?.traitCollection.userInterfaceStyle ?? .unspecified
    pill.view.frame = CGRect(x: 0, y: 0, width: size.width, height: 56)
    container.addSubview(pill.view)
    let parameters = UIDragPreviewParameters()
    let shape = UIBezierPath(roundedRect: pill.view.frame, cornerRadius: 28)
    parameters.visiblePath = shape
    parameters.shadowPath = shape
    parameters.backgroundColor = .clear
    return UIDragPreview(view: container, parameters: parameters)
  }

  /** The thumbnail as it was lifted from the pane. */
  private func thumbnailPreview(_ item: JSON) -> UIDragPreview {
    let image = UIImageView(image: PreviewCache.image(item.string("preview")) ?? assetTypeIcon(item.string("type")))
    image.frame = CGRect(x: 0, y: 0, width: assetTile, height: assetTile)
    image.contentMode = PreviewCache.image(item.string("preview")) != nil ? .scaleAspectFill : .center
    image.backgroundColor = .tertiarySystemFill
    let parameters = UIDragPreviewParameters()
    parameters.visiblePath = UIBezierPath(roundedRect: image.bounds, cornerRadius: 14)
    parameters.backgroundColor = .clear
    return UIDragPreview(view: image, parameters: parameters)
  }

  /** Crossing between the pane and the viewport: swap the preview, let the scene show through
   * the pane, and give a light tick so the change is felt. */
  private func setOverViewport(_ over: Bool, _ session: UIDropSession) {
    guard over != store.overViewport else { return }
    store.overViewport = over
    if let item = asset(session) {
      let preview = over ? pillPreview(item) : thumbnailPreview(item)
      for drag in session.localDragSession?.items ?? [] { drag.previewProvider = { preview } }
    }
    if over { Haptics.selection() }
  }

  func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
    asset(session) != nil
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
    dropped = false
  }

  func dropInteraction(_ interaction: UIDropInteraction,
                              sessionDidUpdate session: UIDropSession) -> UIDropProposal
  {
    let over = isOverViewport(session)
    setOverViewport(over, session)
    if over && !dragging {
      /* Start Blender's drag where the asset enters the viewport, so it previews from there. */
      dragging = true
      sendDrag(.begin, session)
    }
    else if over {
      sendDrag(.move, session)
    }
    else if dragging {
      /* Back over the pane: stop previewing in the viewport. */
      dragging = false
      WM_apple_ios_ui_asset_drag(AssetDragPhase.cancel.rawValue, nil, 0, 0)
    }
    return UIDropProposal(operation: over ? .copy : .cancel)
  }

  func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
    guard dragging else { return }
    dropped = true
    dragging = false
    if let view = interaction.view { dropPoint = session.location(in: view) }
    sendDrag(.drop, session)
    Haptics.impact(.medium)
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
    setOverViewport(false, session)
    if dragging {
      dragging = false
      WM_apple_ios_ui_asset_drag(AssetDragPhase.cancel.rawValue, nil, 0, 0)
    }
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
    if dragging && !dropped { WM_apple_ios_ui_asset_drag(AssetDragPhase.cancel.rawValue, nil, 0, 0) }
    dragging = false
    store.overViewport = false
    store.dragged = nil
  }

  func dropInteraction(_ interaction: UIDropInteraction, previewForDropping item: UIDragItem,
                              withDefault defaultPreview: UITargetedDragPreview) -> UITargetedDragPreview?
  {
    /* The asset lands in the scene: shrink the thumbnail into the drop point. */
    guard let view = interaction.view else { return defaultPreview }
    let target = UIDragPreviewTarget(container: view, center: dropPoint,
                                     transform: CGAffineTransform(scaleX: 0.05, y: 0.05))
    return defaultPreview.retargetedPreview(with: target)
  }

  /** \} */
}

/** The drag preview over the viewport: thumbnail, name and where the drop lands. */
private struct AssetDropPill: View {
  let item: JSON

  var body: some View {
    HStack(spacing: 4) {
      Group {
        if let image = PreviewCache.image(item.string("preview")) {
          Image(uiImage: image).resizable().scaledToFill()
        }
        else if let icon = assetTypeIcon(item.string("type")) {
          Image(uiImage: icon).foregroundStyle(.secondary)
        }
      }
      .frame(width: 44, height: 44)
      .background(Color(uiColor: .tertiarySystemFill))
      .clipShape(Circle())
      .padding(6)
      VStack(alignment: .leading, spacing: 0) {
        Text(item.string("name") ?? "").font(.headline).lineLimit(1)
        Text(assetDropHint(item.string("type"))).font(.caption).foregroundStyle(.secondary)
      }
      .padding(.trailing, 16)
    }
    .frame(height: 56)
    .frame(maxWidth: 320)
    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
  }
}
#endif

/** \} */
