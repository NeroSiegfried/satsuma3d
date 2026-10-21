/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The scene in the room through the camera on iPad and iPhone: the same live meshes the Apple
 * Vision Pro volume shows, see `VolumeView.swift`, standing on the first table or floor the
 * camera finds. Pinching scales it, twisting turns it, tapping an object selects it.
 */

#if os(iOS)

import ARKit
import RealityKit
import SwiftUI

@MainActor
@Observable
final class ARPreviewState {
  static let shared = ARPreviewState()
  var shown = false

  /** World tracking, which needs a rear camera and motion sensors. */
  static var supported: Bool { ARWorldTrackingConfiguration.isSupported }
}

struct ARPreview: View {
  @State private var store = VolumeStore.shared
  @State private var gestureZoom: Float?
  @State private var gestureTurn: Float?
  /** A surface found and the scene stood on it. */
  @State private var anchored = false
  @State private var anchoring: EventSubscription?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    RealityView { content in
      content.camera = .spatialTracking
      let anchor = AnchorEntity(.plane(.horizontal, classification: .any, minimumBounds: [0.2, 0.2]))
      anchor.addChild(store.root)
      content.add(anchor)
      anchoring = content.subscribe(to: SceneEvents.AnchoredStateChanged.self, on: anchor) { event in
        anchored = event.isAnchored
      }
    }
    .ignoresSafeArea()
    .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { value in
      guard let name = store.objectName(value.entity) else { return }
      Engine.setting("volume_select", name)
    })
    .simultaneousGesture(MagnifyGesture()
      .onChanged { value in
        let start = gestureZoom ?? store.zoom
        gestureZoom = start
        store.zoom = max(0.1, min(20, start * Float(value.magnification)))
        store.fit()
      }
      .onEnded { _ in gestureZoom = nil })
    .simultaneousGesture(RotateGesture()
      .onChanged { value in
        let start = gestureTurn ?? store.turn
        gestureTurn = start
        store.turn = start - Float(value.rotation.radians)
        store.fit()
      }
      .onEnded { _ in gestureTurn = nil })
    .overlay(alignment: .top) {
      HStack {
        Button("Reset", systemImage: "arrow.counterclockwise") {
          store.zoom = 1
          store.turn = 0
          store.fit()
        }
        .labelStyle(.iconOnly)
        Spacer()
        Button("Done", systemImage: "xmark") { dismiss() }
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.bordered)
      .buttonBorderShape(.circle)
      .controlSize(.large)
      .padding()
    }
    .overlay(alignment: .bottom) {
      if !anchored {
        Label("Move to find a table or the floor", systemImage: "viewfinder")
          .font(.subheadline.weight(.medium))
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .panelGlass(in: Capsule())
          .padding(.bottom, 40)
          .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.25), value: anchored)
    .onAppear {
      store.standing = true
      store.windowOpened(true)
    }
    .onDisappear {
      store.windowOpened(false)
      store.standing = false
    }
  }
}

#endif
