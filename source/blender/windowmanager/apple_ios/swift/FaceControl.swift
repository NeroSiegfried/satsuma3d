/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The brush set by facial expression, through the front camera's face tracking: opening the mouth
 * sets the brush's strength, raising the eyebrows makes it larger. One hand paints while the face
 * plays the brush, as music apps let it play an instrument.
 */

#if !os(visionOS) /* No front camera facing the person on Apple Vision Pro. */

import ARKit
import SwiftUI

@MainActor
@Observable
final class FaceControl: NSObject, ARSessionDelegate {
  static let shared = FaceControl()

  /** Only with a camera that tracks faces, as iPads with Face ID have. */
  nonisolated static var supported: Bool { ARFaceTrackingConfiguration.isSupported }
  /** Settings shows it beside the brush and in More; off until turned on there. */
  static let shownKey = "BlenderShowFaceControl"

  private(set) var running = false
  /** A face is in view. */
  private(set) var tracking = false
  /** How open the mouth is, and how raised the eyebrows, from 0 to 1, smoothed. */
  private(set) var mouth: Double = 0
  private(set) var brows: Double = 0

  /** The brush's values from Blender, for their ranges and the size to grow from. */
  @ObservationIgnored var brush: JSON? {
    didSet { if running && brush?.dict("size") == nil && brush?.dict("strength") == nil { stop() } }
  }
  @ObservationIgnored private var session: ARSession?
  @ObservationIgnored private var baseSize: Double?
  @ObservationIgnored private var lastSent = Date.distantPast

  func toggle() {
    if running { stop() } else { start() }
  }

  func start() {
    guard Self.supported, !running else { return }
    let session = ARSession()
    session.delegate = self
    session.delegateQueue = .main
    let configuration = ARFaceTrackingConfiguration()
    configuration.maximumNumberOfTrackedFaces = 1
    session.run(configuration, options: [.resetTracking])
    self.session = session
    baseSize = brush?.dict("size")?.double("value")
    mouth = 0
    brows = 0
    running = true
    Haptics.impact(.light)
  }

  func stop() {
    guard running else { return }
    session?.pause()
    session = nil
    running = false
    tracking = false
    /* The values as they were left, as one undo step. */
    send(commit: true)
  }

  nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
    guard let face = anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first else { return }
    let jaw = face.blendShapes[.jawOpen]?.doubleValue ?? 0
    let brow = face.blendShapes[.browInnerUp]?.doubleValue ?? 0
    let tracked = face.isTracked
    MainActor.assumeIsolated { self.update(jaw: jaw, brow: brow, tracked: tracked) }
  }

  nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
    MainActor.assumeIsolated { self.stop() }
  }

  private func update(jaw: Double, brow: Double, tracked: Bool) {
    guard running else { return }
    tracking = tracked
    guard tracked else { return }
    /* A relaxed face reads a little open and raised: past that, to a wide open mouth and fully
     * raised eyebrows. Smoothed, so the brush follows the face without trembling. */
    let mouthTarget = min(1, max(0, (jaw - 0.04) / 0.5))
    let browsTarget = min(1, max(0, (brow - 0.08) / 0.6))
    mouth += (mouthTarget - mouth) * 0.35
    brows += (browsTarget - brows) * 0.35
    if Date().timeIntervalSince(lastSent) > 1.0 / 30 {
      lastSent = Date()
      send(commit: false)
    }
  }

  private func send(commit: Bool) {
    if let strength = brush?.dict("strength") {
      let low = strength.double("min") ?? 0
      let high = min(1, strength.double("max") ?? 1)
      /* Never quite nothing, so a closed mouth still paints faintly. */
      sendBrushValue("strength", low + (high - low) * (0.1 + 0.9 * mouth), commit: commit)
    }
    if let size = brush?.dict("size"), let baseSize {
      let high = size.double("max") ?? baseSize * 2
      sendBrushValue("size", min(high, baseSize * (1 + brows)), commit: commit)
    }
  }
}

/** While the face plays the brush: what it reads, and a button to stop. */
struct FaceControlBadge: View {
  private var face: FaceControl { FaceControl.shared }

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: face.tracking ? "face.smiling" : "face.dashed")
        .font(.title3)
        .foregroundStyle(face.tracking ? Color.accentColor : .secondary)
        .contentTransition(.symbolEffect(.replace))
      meter("Strength", face.mouth, symbol: "mouth")
      meter("Size", face.brows, symbol: "eyebrow")
      Button("Stop Face Control", systemImage: "xmark") { face.stop() }
        .labelStyle(.iconOnly)
        .font(.footnote.weight(.semibold))
        .frame(width: 28, height: 28)
        .contentShape(Circle())
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
    .padding(.leading, 14)
    .padding(.trailing, 8)
    .frame(height: 44)
    .panelGlass(in: Capsule())
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("blender.face-control")
  }

  private func meter(_ title: String, _ value: Double, symbol: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: symbol).font(.caption).foregroundStyle(.secondary)
      Capsule()
        .fill(Color.primary.opacity(0.12))
        .frame(width: 54, height: 6)
        .overlay(alignment: .leading) {
          Capsule().fill(Color.accentColor).frame(width: max(6, 54 * value), height: 6)
        }
    }
    .accessibilityElement()
    .accessibilityLabel(title)
    .accessibilityValue("\(Int((value * 100).rounded())) percent")
  }
}

#endif
