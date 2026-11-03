/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * The document window's panels: Properties, the Outliner, the timeline and the asset pane, fed
 * from Blender's snapshots. The window shows them; this keeps the model in step with them.
 */

import SwiftUI
import UIKit

@MainActor
final class ShellPanels {
  let model: ShellModel
  let panels = SwiftScenePanels()
  let timeline = SwiftTimeline()
  let assets = SwiftAssets()
  let compile = CompileProgress()

  init(model: ShellModel) {
    self.model = model
    panels.panelsDidChange = { [weak self] in
      guard let self else { return }
      withAnimation(SwiftTimeline.animation) {
        self.model.inspectorShown = self.panels.inspectorShown
        self.model.hierarchyShown = self.panels.hierarchyShown
      }
    }
    panels.nodes.shownChanged = { [weak self] shown in
      withAnimation(SwiftTimeline.animation) { self?.model.nodesShown = shown }
#if os(visionOS)
      /* A window of its own, beside the curve editor's if that is open too. */
      PanelWindows.set(.nodes, open: shown)
#else
      /* One editor along the bottom at a time. */
      if shown {
        self?.timeline.setCurvesShown(false)
        self?.timeline.setStoryboardShown(false)
      }
#endif
    }
    panels.image.shownChanged = { [weak self] shown in
      withAnimation(SwiftTimeline.animation) { self?.model.imageShown = shown }
#if os(visionOS)
      PanelWindows.set(.image, open: shown)
#endif
    }
    panels.graphSnapshot = { [weak self] snapshot in
      guard let self, timeline.store.curvesShown else { return }
      timeline.store.curves.update(snapshot)
    }
    panels.storyboardSnapshot = { [weak self] snapshot in
      guard let self, timeline.store.storyboardShown else { return }
      timeline.store.storyboard.update(snapshot)
    }
#if !os(visionOS)
    timeline.curvesDidOpen = { [weak self] in
      self?.panels.nodes.setShown(false)
    }
#endif
    timeline.visibilityDidChange = { [weak self] in
      guard let self else { return }
      model.timelineShown = timeline.visible
    }
    assets.visibilityDidChange = { [weak self] in
      guard let self else { return }
      model.assetsShown = assets.visible
    }
    assets.clientPoint = { [weak model] point in wm_apple_ios_window_pixels(model?.window, point) }
  }

  /** Blender's panels, timeline and asset snapshots, whichever changed. */
  func pullSnapshots() {
    timeline.update()
    assets.update()
    panels.preferenceLists.update()
    if let snapshot = takeJSON("panels", WM_native_ui_panels_take_json()) {
      InterfaceTimings.measure("panels.apply") { panels.updateSnapshot(snapshot) }
    }
    panels.image.pullPixels()
  }

  private func takeJSON(_ name: String, _ json: UnsafeMutablePointer<CChar>?) -> Any? {
    guard let json else { return nil }
    let data = Data(bytes: json, count: strlen(json))
    WM_native_ui_json_free(json)
    return InterfaceTimings.measure(name + ".decode", bytes: data.count) {
      try? JSONSerialization.jsonObject(with: data)
    }
  }
}
