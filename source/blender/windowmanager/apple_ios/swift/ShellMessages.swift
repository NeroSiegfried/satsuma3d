/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Short messages at the top of the viewport: what Blender reports, and why a command did not run.
 * A touch interface has no status bar for Blender's reports and no pointer under which a disabled
 * item could explain itself; these are both. Blender sends the latest few as the toolbar's
 * `notices` (see `WM_native_ui_notice`); errors still stop the person with an alert.
 */

import SwiftUI

struct ShellMessage: Identifiable, Equatable {
  let id: Int
  /** `info`, `warning` or `error`. */
  let level: String
  let text: String
  /** What the button beside the text says, and what it does: `mode:<MODE>` or `action:<id>`. */
  let button: String?
  let target: String?
}

@MainActor
@Observable
final class ShellMessages {
  private(set) var shown: [ShellMessage] = []
  /** The last notice taken, so each is shown once. Nil until Blender's first list arrives: what
   * was said before the window opened is not shown. */
  @ObservationIgnored private var last: Int?
  @ObservationIgnored private var timers: [Int: Timer] = [:]

  /** Take the toolbar's `notices`, a JSON list of `number`, `level`, `text` and `button`. */
  func take(_ json: String) {
    guard let data = json.data(using: .utf8),
          let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
    let numbers = list.compactMap { $0["number"] as? Int }
    guard let seen = last else {
      last = numbers.max() ?? 0
      return
    }
    for entry in list {
      guard let number = entry["number"] as? Int, number > seen,
            let text = entry["text"] as? String, !text.isEmpty else { continue }
      let level = entry["level"] as? String ?? "info"
      var button: String?
      var target: String?
      if let spec = entry["button"] as? String, !spec.isEmpty {
        let parts = spec.split(separator: "\t", maxSplits: 1).map(String.init)
        button = parts[0]
        target = parts.count > 1 ? parts[1] : nil
      }
      show(ShellMessage(id: number, level: level, text: text, button: button, target: target))
    }
    last = max(seen, numbers.max() ?? seen)
  }

  /** A message of the interface's own, such as why a paste did nothing: numbered below Blender's,
   * so the two never share an identity. */
  @ObservationIgnored private var ownNumber = 0

  func say(_ text: String, level: String = "info", button: String? = nil, target: String? = nil) {
    ownNumber -= 1
    show(ShellMessage(id: ownNumber, level: level, text: text, button: button, target: target))
  }

  private func show(_ message: ShellMessage) {
    /* Said once: a refusal Blender says as a notice is also the refused command's answer. */
    guard !shown.contains(where: { $0.text == message.text }) else { return }
    withAnimation(.easeOut(duration: 0.2)) {
      shown.append(message)
      /* Three at most: the oldest goes. */
      while shown.count > 3 { dismiss(shown[0].id, animated: false) }
    }
    /* Long enough to read; a button stays a little longer, to be reached. */
    let seconds = (message.level == "info" ? 2.5 : 5.0) + (message.button == nil ? 0 : 2.0)
    timers[message.id] = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.dismiss(message.id) }
    }
    UIAccessibility.post(notification: .announcement, argument: message.text)
  }

  func dismiss(_ id: Int, animated: Bool = true) {
    timers.removeValue(forKey: id)?.invalidate()
    guard let index = shown.firstIndex(where: { $0.id == id }) else { return }
    if animated {
      withAnimation(.easeOut(duration: 0.18)) { _ = shown.remove(at: index) }
    }
    else {
      shown.remove(at: index)
    }
  }
}

/** The messages, newest at the bottom, centred under the top bar. */
struct ShellMessagesView: View {
  let messages: ShellMessages
  /** Run a message's button. */
  let perform: (String) -> Void

  var body: some View {
    VStack(spacing: 8) {
      ForEach(messages.shown) { message in
        ShellMessageRow(message: message) {
          if let target = message.target { perform(target) }
          messages.dismiss(message.id)
        }
        .onTapGesture { messages.dismiss(message.id) }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .fixedSize()
  }
}

private struct ShellMessageRow: View {
  let message: ShellMessage
  let action: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      icon
        .frame(width: 18, height: 18)
      Text(message.text)
        .font(.subheadline)
        .foregroundStyle(.primary)
        .multilineTextAlignment(.leading)
        /* Blender's words are not cut: a long one wraps, up to a width. */
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 460, alignment: .leading)
      if let button = message.button {
        Button(button, action: action)
          .font(.subheadline.weight(.semibold))
          .buttonStyle(.plain)
          .foregroundStyle(Color.accentColor)
          .padding(.horizontal, 8)
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(Rectangle())
      }
    }
    .padding(.leading, 14)
    .padding(.trailing, message.button == nil ? 16 : 8)
    .frame(minHeight: 44)
    .panelGlass(in: Capsule())
    .contentShape(Capsule())
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("blender.message")
  }

  @ViewBuilder private var icon: some View {
    let key = message.level == "info" ? "INFO" : "ERROR"
    if let image = BlenderIcon.image(key) {
      Image(uiImage: image).resizable().scaledToFit()
    }
    else {
      Image(systemName: message.level == "info" ? "info.circle" : "exclamationmark.triangle.fill")
        .foregroundStyle(message.level == "info" ? Color.secondary : Color.yellow)
    }
  }
}
