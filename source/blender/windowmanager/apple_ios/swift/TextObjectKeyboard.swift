/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * Typing into a text object: in its Edit Mode the system keyboard comes up, and what it types,
 * deletes and starts on a new line goes to Blender's text editing, as Blender's own keys would.
 * Above the keyboard, the system's text formatting sets the font, bold, italic,
 * underline and alignment. With a hardware keyboard Blender takes the keys itself, as on the
 * desktop.
 */

import CoreText
import GameController
import SwiftUI
import UIKit

struct TextObjectKeyboard: View {
  let model: ShellModel
  /** The system keyboard is up for the text. */
  @State private var shown = false
  /** Bumped to bring the keyboard back after it was put away. */
  @State private var focusRequest = 0
  @State private var hardwareKeyboard = GCKeyboard.coalesced != nil

  private var editing: Bool { model.mode == "text_edit" }
  private var active: Bool { editing && !hardwareKeyboard }

  var body: some View {
    ZStack(alignment: .bottom) {
      TextObjectInput(active: active, focusRequest: focusRequest, textObject: model.textObject, shown: $shown)
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      if active && !shown {
        Button {
          focusRequest += 1
        } label: {
          Label("Show Keyboard", systemImage: "keyboard")
            .padding(.horizontal, 16)
            .frame(height: 44)
        }
        .buttonStyle(.plain)
        .panelGlass(interactive: true, in: Capsule())
        .padding(.bottom, model.safeAreaInsets.bottom + model.bottomTray + 16)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        .accessibilityIdentifier("blender.text.keyboard")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    .animation(.snappy(duration: 0.25), value: active && !shown)
    .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in
      hardwareKeyboard = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
      hardwareKeyboard = GCKeyboard.coalesced != nil
    }
  }
}

/** The responder the system keyboard types into, which holds no text of its own. */
private struct TextObjectInput: UIViewRepresentable {
  let active: Bool
  let focusRequest: Int
  let textObject: JSON?
  @Binding var shown: Bool

  func makeUIView(context: Context) -> TextObjectInputView {
    TextObjectInputView()
  }

  func updateUIView(_ view: TextObjectInputView, context: Context) {
    view.textObject = textObject
    view.focusChanged = { focused in
      if shown != focused { shown = focused }
    }
    let requested = view.focusRequest != focusRequest
    view.focusRequest = focusRequest
    let activated = active && !view.active
    view.active = active
    /* After this update: the keyboard moving lays out the views being updated. */
    if active, activated || requested, !view.isFirstResponder {
      DispatchQueue.main.async { _ = view.becomeFirstResponder() }
    }
    else if !active, view.isFirstResponder {
      DispatchQueue.main.async { _ = view.resignFirstResponder() }
    }
  }
}

final class TextObjectInputView: UIView, UIKeyInput, UITextFormattingViewController.Delegate {
  var active = false
  var focusRequest = 0
  var focusChanged: (Bool) -> Void = { _ in }

  override var canBecomeFirstResponder: Bool { active && window != nil }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became {
      focusChanged(true)
    }
    return became
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned {
      focusChanged(false)
    }
    return resigned
  }

  /* -------------------------------------------------------------------- */
  /* Typing */

  /** Always, so the delete key deletes Blender's text. */
  var hasText: Bool { true }

  func insertText(_ text: String) {
    /* New lines are Blender's line breaks; the rest is inserted as typed. */
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    for (index, line) in lines.enumerated() {
      if index > 0 {
        Engine.setting("text_object_edit", "line_break")
      }
      if !line.isEmpty {
        Engine.setting("text_object_edit", "insert:" + line)
      }
    }
  }

  func deleteBackward() {
    Engine.setting("text_object_edit", "delete")
  }

  var autocorrectionType: UITextAutocorrectionType = .no
  var spellCheckingType: UITextSpellCheckingType = .no
  var smartQuotesType: UITextSmartQuotesType = .no
  var smartDashesType: UITextSmartDashesType = .no
  var autocapitalizationType: UITextAutocapitalizationType = .sentences
  var returnKeyType: UIReturnKeyType = .default

  /* -------------------------------------------------------------------- */
  /* Formatting */

  /** The text's style where the cursor is, from Blender's snapshot. */
  var textObject: JSON? {
    didSet {
      /* The open panel follows the text, as the cursor moves or a change applies. */
      if let formatting, !jsonEqual(textObject.map { $0 as NSDictionary }, oldValue.map { $0 as NSDictionary }) {
        formatting.formattingDescriptor = formattingDescriptor
      }
    }
  }
  private weak var formatting: UITextFormattingViewController?

  private lazy var formatItem = UIBarButtonItem(
    image: UIImage(systemName: "textformat.alt"),
    primaryAction: UIAction { [weak self] _ in self?.showFormatting() })

  /** Above the keyboard: the system's text formatting, and leaving Edit Mode. */
  private lazy var toolbar: UIToolbar = {
    let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 600, height: 50))
    formatItem.accessibilityLabel = "Text Formatting"
    toolbar.items = [
      formatItem,
      .flexibleSpace(),
      UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in
        /* Leaves Edit Mode, as Tab does. */
        Engine.setting("object_mode", "OBJECT")
      }),
    ]
    toolbar.sizeToFit()
    return toolbar
  }()

#if !os(visionOS) /* No accessory over its keyboard there. */
  override var inputAccessoryView: UIView? { toolbar }
#endif

  /** The system's text formatting: font, styles and alignment. */
  private func showFormatting() {
    let configuration = UITextFormattingViewController.Configuration(groups: [
      .group([.component(.fontPicker, .regular)]),
      .group([.component(.fontAttributes, .regular), .component(.textAlignment, .regular)]),
    ])
    let controller = UITextFormattingViewController(configuration: configuration)
    controller.delegate = self
    controller.formattingDescriptor = formattingDescriptor
    formatting = controller
    controller.modalPresentationStyle = .popover
    controller.popoverPresentationController?.sourceItem = formatItem
    var presenter = window?.rootViewController
    while let next = presenter?.presentedViewController, !next.isBeingDismissed { presenter = next }
    presenter?.present(controller, animated: true)
  }

  private var formattingDescriptor: UITextFormattingViewController.FormattingDescriptor {
    var descriptor = UITextFormattingViewController.FormattingDescriptor()
    let text = textObject ?? [:]
    var font = FontFiles.font(file: text.string("font_file"), size: 17) ?? UIFont.systemFont(ofSize: 17)
    var traits = font.fontDescriptor.symbolicTraits
    if text.bool("bold") { traits.insert(.traitBold) }
    if text.bool("italic") { traits.insert(.traitItalic) }
    if let styled = font.fontDescriptor.withSymbolicTraits(traits) {
      font = UIFont(descriptor: styled, size: 17)
    }
    descriptor.fonts = [font]
    descriptor.underlinePresent = text.bool("underline")
    let alignments: [String: UITextFormattingViewController.TextAlignment] = [
      "LEFT": .left, "CENTER": .center, "RIGHT": .right, "JUSTIFY": .justified, "FLUSH": .justified,
    ]
    if let alignment = alignments[text.string("align") ?? ""] {
      descriptor.textAlignments = [alignment]
    }
    return descriptor
  }

  func textFormattingViewController(_ viewController: UITextFormattingViewController,
                                    didChangeValue changeValue: UITextFormattingViewController.ChangeValue)
  {
    switch changeValue {
      case .bold(let on): Engine.setting("text_object_edit", "style:BOLD:" + (on ? "1" : "0"))
      case .italic(let on): Engine.setting("text_object_edit", "style:ITALIC:" + (on ? "1" : "0"))
      case .underline(let on): Engine.setting("text_object_edit", "style:UNDERLINE:" + (on ? "1" : "0"))
      case .textAlignment(let alignment):
        let names: [UITextFormattingViewController.TextAlignment: String] = [
          .left: "LEFT", .center: "CENTER", .right: "RIGHT", .justified: "JUSTIFY", .natural: "LEFT",
        ]
        if let name = names[alignment] { Engine.setting("text_object_edit", "align:" + name) }
      case .font(let font):
        /* A family sets Blender's bold and italic fonts too, which its styles then use. */
        FontFiles.write(font.fontDescriptor as CTFontDescriptor, family: true) { url, faces in
          let lines = ["font=" + url.path] + faces.map { "\($0.key)=\($0.value.path)" }
          Engine.setting("text_object_edit", "font:" + lines.joined(separator: "\n"))
        }
      default:
        break
    }
  }

  func textFormattingDidFinish(_ viewController: UITextFormattingViewController) {
    /* Back to typing. */
    if active { _ = becomeFirstResponder() }
  }
}
