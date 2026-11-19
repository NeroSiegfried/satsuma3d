/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Whether long work goes on while the app is away, and when heat pauses it (ROUND6 BUSY-4, G8).
 * Built alone for the Mac by `tests/ios/test_background_work.py`, which checks every row of the
 * table: it uses nothing but Foundation.
 */

import Foundation

enum BackgroundWork {
  enum Decision: Equatable {
    /** Blender's loop keeps running with the app in the background. */
    case continueWork
    /** The work stops as the app leaves, keeping every finished frame, and goes on from the next
     * frame when the app is back. */
    case pause
  }

  /**
   * Go on in the background only once iPadOS has started the continued-processing task (its
   * launch handler ran, not merely the request accepted), and, for work on the GPU, only when the
   * task was granted the GPU: the GPU refuses work from an app in the background otherwise, and
   * a frame rendered so would be wrong or black.
   *
   * - Parameters:
   *   - taskStarted: the task's launch handler ran.
   *   - gpuGranted: the request that started was one asking for the GPU.
   *   - needsGPU: the work renders on the GPU, as Blender says (`bl_ui.native_render.needs_gpu`).
   */
  static func decide(taskStarted: Bool, gpuGranted: Bool, needsGPU: Bool) -> Decision {
    guard taskStarted else { return .pause }
    return needsGPU && !gpuGranted ? .pause : .continueWork
  }

  /** Heat at which an animation pauses between frames, as the system asks of heavy work. */
  static func tooWarm(_ state: ProcessInfo.ThermalState) -> Bool {
    state == .serious || state == .critical
  }

  /** Cool enough for a render paused by heat to go on. */
  static func coolEnough(_ state: ProcessInfo.ThermalState) -> Bool {
    state == .nominal || state == .fair
  }
}
