/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The scene live in 3D, in a volumetric window on Apple Vision Pro, to walk around beside the
 * editor. Blender sends its evaluated meshes as GPU-ready arrays, only those that changed, and
 * every instance's transform, see `wm_apple_ios_volume.cc`; they are copied straight into
 * RealityKit's low-level meshes, which are reused while they have room. Tapping an object selects
 * it; pinching and dragging one moves it. Both hands scale and turn the scene.
 */

#if os(visionOS)

import RealityKit
import SwiftUI

/* -------------------------------------------------------------------- */
/** \name Store
 * \{ */

@MainActor
@Observable
final class VolumeStore {
  static let shared = VolumeStore()

  /** The window is open. */
  private(set) var shown = false

  /** Blender's Z-up scene, turned Y-up, scaled and centered to fit the volume. */
  @ObservationIgnored let root = Entity()
  /** The scene in Blender's own space, under `root`. */
  @ObservationIgnored let scene = Entity()

  private struct MeshEntry {
    let mesh: LowLevelMesh
    let resource: MeshResource
    let bounds: BoundingBox
  }

  private struct InstanceEntry {
    let entity: ModelEntity
    var mesh: UInt64
    var name: String
    var material: Int
  }

  @ObservationIgnored private var meshes: [UInt64: MeshEntry] = [:]
  /** Meshes no longer shown, kept to fill again rather than make new ones. */
  @ObservationIgnored private var spare: [MeshEntry] = []
  @ObservationIgnored private var instances: [UInt64: InstanceEntry] = [:]
  @ObservationIgnored private var materials: [Int: PhysicallyBasedMaterial] = [:]
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var fitted = false
  @ObservationIgnored private var bounds = BoundingBox()

  /** The volume's size the scene fits in, in meters. */
  static let size: Float = 0.8
  /** How much the hands have scaled and turned the scene. */
  @ObservationIgnored var zoom: Float = 1
  @ObservationIgnored var turn: Float = 0

  private init() {
    root.addChild(scene)
    /* Blender's Z up is RealityKit's Y up. */
    scene.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
  }

  /* Opening and closing */

  func setShown(_ shown: Bool) {
    PanelWindows.set(.volume, open: shown)
  }

  func windowOpened(_ open: Bool) {
    guard open != shown else { return }
    shown = open
    Engine.setting("volume_visible", open ? "1" : "0")
    timer?.invalidate()
    timer = nil
    if open {
      fitted = false
      /* Cheap while nothing changed: Blender says when a frame is ready. */
      timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.pull() }
      }
    }
    else {
      clear()
    }
  }

  private func clear() {
    for instance in instances.values { instance.entity.removeFromParent() }
    instances.removeAll()
    meshes.removeAll()
    spare.removeAll()
  }

  /* Frames */

  private func pull() {
    guard let frame = WM_apple_ios_volume_take() else { return }
    defer { WM_apple_ios_volume_free(frame) }
    var info = WMVolumeFrameInfo()
    WM_apple_ios_volume_info(frame, &info)
    if info.reset { clear() }

    for index in 0..<Int(info.mesh_count) {
      var data = WMVolumeMesh()
      WM_apple_ios_volume_mesh(frame, Int32(index), &data)
      if let entry = makeMesh(data) {
        if let old = meshes[data.key] { spare.append(old) }
        meshes[data.key] = entry
      }
    }

    var seen = Set<UInt64>()
    for index in 0..<Int(info.instance_count) {
      var name: UnsafePointer<CChar>?
      let instance = WM_apple_ios_volume_instance(frame, Int32(index), &name)!.pointee
      seen.insert(instance.id)
      show(instance, name: name.map { String(cString: $0) } ?? "")
    }
    for (id, instance) in instances where !seen.contains(id) {
      instance.entity.removeFromParent()
      instances[id] = nil
    }

    /* Meshes no instance shows are kept to fill again, a few at most. */
    let used = Set(instances.values.map(\.mesh))
    for (key, entry) in meshes where !used.contains(key) {
      meshes[key] = nil
      spare.append(entry)
    }
    if spare.count > 8 { spare.removeFirst(spare.count - 8) }

    bounds = BoundingBox(min: SIMD3(info.bounds_min.0, info.bounds_min.1, info.bounds_min.2),
                         max: SIMD3(info.bounds_max.0, info.bounds_max.1, info.bounds_max.2))
    if !fitted && !instances.isEmpty {
      fitted = true
      fit()
    }
  }

  /** A mesh's triangles, in a spare low-level mesh with room for them or a new one. */
  private func makeMesh(_ data: WMVolumeMesh) -> MeshEntry? {
    let vertices = Int(data.vertex_count), indices = Int(data.index_count)
    guard vertices > 0, indices > 0, let source = data.vertices, let sourceIndices = data.indices else {
      return nil
    }
    let bounds = BoundingBox(min: SIMD3(data.bounds_min.0, data.bounds_min.1, data.bounds_min.2),
                             max: SIMD3(data.bounds_max.0, data.bounds_max.1, data.bounds_max.2))
    var mesh: LowLevelMesh
    var resource: MeshResource?
    if let index = spare.firstIndex(where: {
      $0.mesh.descriptor.vertexCapacity >= vertices && $0.mesh.descriptor.indexCapacity >= indices
    }) {
      let reused = spare.remove(at: index)
      mesh = reused.mesh
      resource = reused.resource
    }
    else {
      var descriptor = LowLevelMesh.Descriptor()
      descriptor.vertexAttributes = [
        .init(semantic: .position, format: .float3, offset: 0),
        .init(semantic: .normal, format: .float3, offset: 12),
      ]
      descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferStride: 24)]
      /* Some room to grow, as a mesh being edited does. */
      descriptor.vertexCapacity = vertices + vertices / 4
      descriptor.indexCapacity = indices + indices / 4
      descriptor.indexType = .uint32
      guard let made = try? LowLevelMesh(descriptor: descriptor) else { return nil }
      mesh = made
    }
    mesh.withUnsafeMutableBytes(bufferIndex: 0) { buffer in
      buffer.copyMemory(from: UnsafeRawBufferPointer(start: source, count: vertices * 24))
    }
    mesh.withUnsafeMutableIndices { buffer in
      buffer.copyMemory(from: UnsafeRawBufferPointer(start: sourceIndices, count: indices * 4))
    }
    mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: indices, topology: .triangle, bounds: bounds)])
    if resource == nil {
      resource = try? MeshResource(from: mesh)
    }
    guard let resource else { return nil }
    return MeshEntry(mesh: mesh, resource: resource, bounds: bounds)
  }

  private func show(_ instance: WMVolumeInstance, name: String) {
    guard let mesh = meshes[instance.mesh] else { return }
    let color = instance.color
    let materialKey = Int(color.0 * 255) | Int(color.1 * 255) << 8 | Int(color.2 * 255) << 16 |
      Int(color.3 * 255) << 24 | (instance.selected ? 1 << 32 : 0)
    var entry: InstanceEntry
    if let existing = instances[instance.id] {
      entry = existing
    }
    else {
      let entity = ModelEntity()
      entity.components.set(InputTargetComponent())
      entity.components.set(HoverEffectComponent())
      scene.addChild(entity)
      entry = InstanceEntry(entity: entity, mesh: 0, name: name, material: -1)
    }
    if entry.mesh != instance.mesh || entry.entity.model == nil {
      entry.mesh = instance.mesh
      entry.entity.model = ModelComponent(mesh: mesh.resource, materials: [material(materialKey, instance)])
      entry.material = materialKey
      /* Its box to look at and pinch, rather than every triangle. */
      let size = mesh.bounds.max - mesh.bounds.min
      entry.entity.components.set(CollisionComponent(
        shapes: [ShapeResource.generateBox(size: simd_max(size, SIMD3(repeating: 0.01)))
          .offsetBy(translation: mesh.bounds.center)]))
    }
    else if entry.material != materialKey {
      entry.entity.model?.materials = [material(materialKey, instance)]
      entry.material = materialKey
    }
    entry.name = name
    let m = instance.matrix
    entry.entity.transform = Transform(matrix: float4x4(
      SIMD4(m.0, m.1, m.2, m.3), SIMD4(m.4, m.5, m.6, m.7),
      SIMD4(m.8, m.9, m.10, m.11), SIMD4(m.12, m.13, m.14, m.15)))
    instances[instance.id] = entry
  }

  /** The material's viewport color, lit; selected ones glow in the selection's orange. */
  private func material(_ key: Int, _ instance: WMVolumeInstance) -> PhysicallyBasedMaterial {
    if let cached = materials[key] { return cached }
    var material = PhysicallyBasedMaterial()
    let color = instance.color
    material.baseColor = .init(tint: UIColor(red: CGFloat(color.0), green: CGFloat(color.1),
                                             blue: CGFloat(color.2), alpha: 1))
    material.roughness = 0.6
    material.metallic = 0.0
    if color.3 < 0.999 {
      material.blending = .transparent(opacity: .init(floatLiteral: color.3))
    }
    if instance.selected {
      material.emissiveColor = .init(color: UIColor(red: 1, green: 0.55, blue: 0.1, alpha: 1))
      material.emissiveIntensity = 0.35
    }
    materials[key] = material
    return material
  }

  /** The whole scene in the volume, as the hands left it scaled and turned. */
  func fit() {
    let extent = max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z)
    guard extent.isFinite, extent > 0 else { return }
    let scale = Self.size * 0.6 / extent * zoom
    /* Centered across, resting on the volume's floor as a model on a table does. Blender's Y is
     * RealityKit's -Z. */
    let center = bounds.center
    root.scale = SIMD3(repeating: scale)
    root.orientation = simd_quatf(angle: turn, axis: [0, 1, 0])
    let floor = -Self.size / 2 + 0.02 - bounds.min.z * scale
    root.position = root.orientation.act(SIMD3(-center.x * scale, 0, center.y * scale)) + SIMD3(0, floor, 0)
  }

  /* Commands */

  /** The object an entity shows, to select or move. */
  func objectName(_ entity: Entity) -> String? {
    instances.values.first { $0.entity === entity }?.name
  }

  /** A point in the volume's space as Blender's world space. */
  func blenderPoint(_ point: SIMD3<Float>, from entity: Entity) -> SIMD3<Float> {
    entity.convert(position: point, to: scene)
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Window
 * \{ */

struct VolumeView: View {
  @State private var store = VolumeStore.shared
  /** The object being moved, and where in Blender's space the pinch began. */
  @State private var moving: (name: String, start: SIMD3<Float>, lastSent: Date)?
  @State private var gestureZoom: Float?
  @State private var gestureTurn: Float?
  @Environment(\.dismissWindow) private var dismissWindow

  var body: some View {
    RealityView { content in
      content.add(store.root)
    }
    .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { value in
      guard let name = store.objectName(value.entity) else { return }
      Engine.setting("volume_select", name)
    })
    .gesture(DragGesture(minimumDistance: 0.002).targetedToAnyEntity()
      .onChanged { value in
        guard let name = store.objectName(value.entity) else { return }
        let here = value.convert(value.location3D, from: .local, to: store.scene)
        if moving == nil {
          let start = value.convert(value.startLocation3D, from: .local, to: store.scene)
          moving = (name, start, .distantPast)
          Engine.setting("volume_select", name)
          Engine.setting("volume_move", "\(name)|begin|0|0|0")
        }
        guard let current = moving, Date().timeIntervalSince(current.lastSent) > 1.0 / 30.0 else { return }
        let delta = here - current.start
        Engine.setting("volume_move", "\(name)|move|\(delta.x)|\(delta.y)|\(delta.z)")
        moving?.lastSent = Date()
      }
      .onEnded { value in
        guard let current = moving else { return }
        let here = value.convert(value.location3D, from: .local, to: store.scene)
        let delta = here - current.start
        Engine.setting("volume_move", "\(current.name)|end|\(delta.x)|\(delta.y)|\(delta.z)")
        moving = nil
      })
    .simultaneousGesture(MagnifyGesture().targetedToAnyEntity()
      .onChanged { value in
        let start = gestureZoom ?? store.zoom
        gestureZoom = start
        store.zoom = max(0.1, min(10, start * Float(value.magnification)))
        store.fit()
      }
      .onEnded { _ in gestureZoom = nil })
    .simultaneousGesture(RotateGesture3D(constrainedToAxis: .y).targetedToAnyEntity()
      .onChanged { value in
        let start = gestureTurn ?? store.turn
        gestureTurn = start
        store.turn = start + Float(value.rotation.angle.radians) *
          (value.rotation.axis.y < 0 ? -1 : 1)
        store.fit()
      }
      .onEnded { _ in gestureTurn = nil })
    .ornament(attachmentAnchor: .scene(.bottomFront)) {
      Button("Frame All", systemImage: "arrow.up.left.and.down.right.magnifyingglass") {
        store.zoom = 1
        store.turn = 0
        store.fit()
      }
      .labelStyle(.iconOnly)
      .padding(8)
      .glassBackgroundEffect()
    }
    .onAppear {
      PanelWindows.close[.volume] = { dismissWindow(id: PanelWindow.volume.rawValue) }
      store.windowOpened(true)
    }
    .onDisappear {
      PanelWindows.close[.volume] = nil
      store.windowOpened(false)
    }
  }
}

/** \} */

#endif
