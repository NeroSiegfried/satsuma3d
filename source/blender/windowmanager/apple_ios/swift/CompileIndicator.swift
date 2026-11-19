/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The pills below the toolbar, in both interfaces: shader compilation, shown while Blender compiles
 * shaders and is held up by it, with its progress and count; and every job Blender's status bar
 * would show (a render, a bake, a simulation, an export), with its progress and a Stop, from
 * Blender's `jobs` view (ROUND6 BUSY-1, `bridge_jobs_view_build`). And the veil while Blender is
 * held up by one long piece of work (ROUND6 BUSY-2).
 */

import SwiftUI
import UIKit

/** Whether Blender is held up compiling shaders, polled with the window's state. */
@MainActor
@Observable
final class CompileProgress {
  /** Brief hitches are not worth a message: only show once Blender has been held up this long. */
  private static let showAfter = 0.3
  /** Once shown, stay long enough to be read rather than flicker. */
  private static let minimumVisible = 0.5

  private(set) var shown = false
  private(set) var finished = 0
  private(set) var total = 0
  @ObservationIgnored private var shownAt = Date.distantPast

  func refresh() {
    var finished: Int32 = 0, total: Int32 = 0, busy = 0.0
    let compiling = wm_apple_ios_shader_compilation(&finished, &total, &busy)
    if compiling && busy > Self.showAfter {
      if self.finished != Int(finished) { self.finished = Int(finished) }
      if self.total != Int(total) { self.total = Int(total) }
      if !shown {
        shownAt = Date()
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.2)) { shown = true }
      }
    }
    else if shown && Date().timeIntervalSince(shownAt) >= Self.minimumVisible {
      withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeIn(duration: 0.2)) { shown = false }
    }
  }
}

/** Blender's running jobs, from its `jobs` view: a node per job, named by Blender, with its
 * progress (0 until the job reports any) and a Stop button. */
@MainActor
enum BlenderJobs {
  static let view = NativeViews.shared.subscribe("jobs")

  struct Job: Identifiable {
    let id: String
    let name: String
    /** From 0 to 1; 0 until the job reports progress, shown as working. */
    let progress: Double
    /** Stop was asked for and the job has not ended yet. */
    let stopping: Bool
  }

  static var jobs: [Job] {
    guard let top = view.top else { return [] }
    return view.children(of: top).map { node in
      let progress = view.node(node.key + ":progress")?.content(Blender_NativeUI_Data.self)?
        .value(type: Blender_NativeUI_FloatValue.self)?.value ?? 0
      return Job(id: node.key, name: node.label, progress: progress, stopping: node.node.description == "stopping")
    }
  }

  /** Ask the job to stop, as desktop's ✕ does; it ends when it next looks. */
  static func stop(_ job: Job) { NativeViews.shared.send(view, target: job.id + ":stop", op: .invoke) }
}

/** One running job: its name, its progress (or that it is working) and Stop. */
private struct JobPill: View {
  let job: BlenderJobs.Job

  /** Blender's job names end in "...", as "Rendering...": the pill says it without. */
  private var name: String {
    var name = job.name
    while name.hasSuffix(".") { name.removeLast() }
    return job.stopping ? "Stopping \(name)" : name
  }

  var body: some View {
    HStack(spacing: 10) {
      Text(name)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      if job.progress > 0 && !job.stopping {
        ProgressView(value: job.progress)
          .frame(width: 88)
        Text(job.progress, format: .percent.precision(.fractionLength(0)))
          .font(.system(size: 12).monospacedDigit())
          .foregroundStyle(.tertiary)
      }
      else {
        ProgressView()
          .controlSize(.small)
      }
      Button {
        BlenderJobs.stop(job)
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 17))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.secondary)
          .frame(width: 32, height: 32)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(job.stopping)
      .accessibilityLabel("Stop \(name)")
    }
    .tint(Color(uiColor: .systemBlue))
    .padding(.leading, 14)
    .padding(.trailing, 4)
    .frame(height: 32)
    .panelGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .transition(.opacity.combined(with: .offset(y: -6)))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(name)
    .accessibilityValue(job.progress > 0 ? "\(Int((job.progress * 100).rounded())) percent" : "Working")
    .accessibilityIdentifier("blender.job")
  }
}

/** The pills below the toolbar: shader compilation, then each running job. Only the pills take
 * touches; the rest of the column lets them through to the viewport. */
struct CompileIndicator: View {
  let progress: CompileProgress
  /** In the Desktop Interface's cluster (ROUND6 DESK-1): the pills alone, hugging them, rather than
   * a column hung from the window's top over Blender's top bar. */
  var inCluster = false

  var body: some View {
    VStack(spacing: 6) {
      compilePill
        .allowsHitTesting(false)
      ForEach(BlenderJobs.jobs) { job in
        JobPill(job: job)
      }
      if !inCluster {
        Spacer(minLength: 0)
          .allowsHitTesting(false)
      }
    }
    .padding(.top, inCluster ? 0 : 8)
    .animation(UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.2),
               value: BlenderJobs.jobs.map(\.id))
    /* The screen stays on while work runs in front, so the iPad does not lock and send it to the
     * background part way (R6 BUSY-4, G8). */
    .onChange(of: BlenderJobs.jobs.isEmpty, initial: true) { _, idle in
      UIApplication.shared.isIdleTimerDisabled = !idle
    }
    .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
  }

  @ViewBuilder
  private var compilePill: some View {
    VStack {
      if progress.shown {
        HStack(spacing: 10) {
          Text("Compiling Shaders")
            .font(.footnote)
            .foregroundStyle(.secondary)
          ProgressView(value: progress.total > 0 ? Double(progress.finished) / Double(progress.total) : 0)
            .frame(width: 88)
          Text("\(progress.finished)/\(progress.total)")
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.tertiary)
        }
        .tint(Color(uiColor: .systemBlue))
        .padding(.horizontal, 14)
        .frame(height: 32)
        .panelGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.opacity.combined(with: .offset(y: -6)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Compiling Shaders")
        .accessibilityValue("\(progress.finished) of \(progress.total)")
        .accessibilityIdentifier("blender.shader-compilation")
      }
    }
  }
}

/** Blender held up by one long piece of work, as an Apply or an import (ROUND6 BUSY-2, decision
 * R6-12): after half a second, a veil over the window says what runs, and taps on it are
 * swallowed, not queued to run afterwards on whatever is then current. Shader compilation has its
 * own pill and no veil. Polled with the window's state. */
@MainActor
@Observable
final class BusyVeilState {
  /** Brief hitches are not worth a veil. */
  private static let showAfter = 0.5

  private(set) var shown = false
  private(set) var label = ""

  func refresh() {
    var finished: Int32 = 0, total: Int32 = 0, busy = 0.0
    let compiling = wm_apple_ios_shader_compilation(&finished, &total, &busy)
    let held = busy > Self.showAfter && !compiling
    if held {
      var buffer = [CChar](repeating: 0, count: 256)
      let named = WM_native_ui_busy_label(&buffer, buffer.count)
      let text = named ? buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : ""
      let label = text.isEmpty ? "Working" : text
      if self.label != label { self.label = label }
    }
    if held != shown {
      withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.15)) { shown = held }
    }
  }
}

/** The veil itself: dims the window, names the work, takes every touch. */
struct BusyVeil: View {
  let state: BusyVeilState

  var body: some View {
    if state.shown {
      ZStack {
        Color.black.opacity(0.18)
        HStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
          Text("\(state.label)…")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .panelGlass(in: Capsule())
      }
      .ignoresSafeArea()
      .contentShape(Rectangle())
      /* Taps are swallowed while Blender cannot answer them. */
      .onTapGesture {}
      .gesture(DragGesture(minimumDistance: 0).onEnded { _ in })
      .transition(.opacity)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(state.label), please wait")
      .accessibilityAddTraits(.updatesFrequently)
      .accessibilityIdentifier("blender.busy-veil")
    }
  }
}
