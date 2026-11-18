/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * What the window's panels share: a panel's header, and the top bar's popovers of settings.
 */

import SwiftUI
import UIKit

/** Whether a panel fills a window of its own, as Properties and the Outliner do on visionOS. */
extension EnvironmentValues {
  @Entry var panelInWindow = false
}

struct PanelHeader<Trailing: View>: View {
  @Environment(\.panelInWindow) private var inWindow
  /** Beside the second bar in a wide window (ROUND5 14A, decision 85): its height, which the title
   * strip takes, with the bar's surface and lower edge. */
  @Environment(\.secondBarHeight) private var bar
  let title: String
  /** The panel's name for the layout checker, which a title that changes with the tab is not. */
  var zone = "properties"
  let close: () -> Void
  @ViewBuilder var trailing: Trailing

  var body: some View {
    if let bar {
      row
        .padding(.top, -5)
        .frame(height: bar)
        .frame(maxWidth: .infinity)
        .secondBarSurface()
        .sidebarTitleEdge(zone)
    }
    else {
      row
    }
  }

  private var row: some View {
    HStack(spacing: 0) {
      Text(title)
        .font(.headline)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 8)
      trailing
      /* A panel in a window of its own closes with the window. */
      if !inWindow {
        Button(action: close) {
          Image(systemName: "xmark")
            .font(.body.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close \(title)")
      .keyboardShortcut(.cancelAction)
      }
    }
    .padding(.leading, 16)
    .padding(.trailing, 5)
    .padding(.top, 5)
  }
}

/** A sidebar's title strip as the second bar continued, when \a shown (ROUND5 14A). */
struct SecondBarStrip: ViewModifier {
  let shown: Bool
  let zone: String

  func body(content: Content) -> some View {
    if shown {
      content.frame(maxWidth: .infinity).secondBarSurface().sidebarTitleEdge(zone)
    }
    else {
      content
    }
  }
}

extension View {
  /** The second bar's surface (ROUND5 14A.2): Blender's tool header grey with its edge below, as
   * the tool settings row draws it, for a sidebar's title strip that continues the row. */
  func secondBarSurface() -> some View {
    background {
      Rectangle().fill(ShellStyle.region)
        .overlay(alignment: .bottom) { Rectangle().fill(ShellStyle.outline).frame(height: 1) }
    }
    .environment(\.colorScheme, .dark)
  }

  /** Report a sidebar's title strip to the layout checker, which holds its lower edge to the second
   * bar's (ROUND5 14A.4). */
  func sidebarTitleEdge(_ name: String) -> some View {
    onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
      LayoutChecker.shared.setBarEdge("sidebar title " + name, $0)
    }
    .onDisappear { LayoutChecker.shared.setBarEdge("sidebar title " + name, nil) }
  }
}

/* -------------------------------------------------------------------- */
/** \name Tool settings strip
 *
 * The active tool's settings in the top bar: compact columns, a caption over each control. The
 * strip scrolls sideways when the bar is narrow, and a trailing button opens them all.
 * \{ */

/** A top bar item that opens a popover with controls: the bar names it, its overflow menu too. */
struct ToolSettingPopover<Content: View>: View {
  let title: String
  let icon: String?
  let systemImage: String
  @ViewBuilder let content: () -> Content
  @State private var open = false

  var body: some View {
    Button {
      open = true
    } label: {
      if let icon, BlenderIcon.image(icon) != nil {
        Label { Text(title) } icon: { IconView(name: icon) }
      }
      else {
        Text(title)
      }
    }
    .popover(isPresented: $open) {
      ScrollView { content().padding() }
        .frame(idealWidth: 320, idealHeight: 380)
        .presentationCompactAdaptation(.popover)
        .tint(PanelStyle.tint)
        .popoverSurface()
    }
  }
}

/** A compact capsule naming what it opens, with a chevron: the strip's menus and pop-outs. */
struct StripCapsuleLabel: View {
  let title: String
  var icon: String?

  var body: some View {
    HStack(spacing: 4) {
      if let image = BlenderIcon.image(icon ?? "") {
        Image(uiImage: image).resizable().scaledToFit().frame(width: 18, height: 18)
      }
      Text(title).font(.caption).lineLimit(1).fixedSize()
      Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
    }
    .foregroundStyle(.primary)
    .padding(.horizontal, 10)
    .frame(height: 30)
    .panelGlass(in: Capsule())
    .contentShape(Capsule())
  }
}

/** \} */

