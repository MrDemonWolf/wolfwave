//
//  CopyButton.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-03-27.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// A reusable copy-to-clipboard button with optional visual feedback.
/// Shows a checkmark icon briefly after copying.
///
/// Writes through `Pasteboard.copy(_:sensitive:)`, so sensitive values get the
/// shared delayed-clear behavior.
struct CopyButton: View {

    // MARK: - Properties

    /// The string written to the pasteboard. Read at click time.
    let text: String
    /// Text shown beside the icon. Text only renders when both `label` and
    /// `copiedLabel` are set; otherwise the button is icon-only.
    var label: String? = nil
    /// Text shown in place of `label` during the feedback window.
    var copiedLabel: String? = nil
    /// Bordered (small control) or borderless (with pointer cursor).
    var buttonStyle: CopyButtonStyle = .bordered
    /// Disables the button, for example under Streamer Mode.
    var isDisabled: Bool = false
    /// Required, because the icon-only form has no visible text.
    var accessibilityLabel: String
    /// Optional UI-test identifier; applied only when non-nil.
    var accessibilityIdentifier: String? = nil
    /// How long the checkmark stays up after a copy, in seconds.
    var feedbackDuration: TimeInterval = 2.0
    /// Clears this value from the general pasteboard after a short delay, but
    /// only if the user has not copied anything else in the meantime.
    /// The delay is `Pasteboard`'s, not `feedbackDuration`.
    var isSensitive = false
    /// Why the button is disabled (e.g. "Turn off Streamer Mode to copy."),
    /// read by VoiceOver as the hint while `isDisabled` is on. Ignored while
    /// the button is live.
    var disabledHint: String?
    /// Optional side effect fired right after the text is copied (e.g. a parent
    /// status update). The pasteboard write + checkmark feedback are handled
    /// internally regardless.
    var action: (() -> Void)? = nil

    /// True during the feedback window; swaps the icon and label.
    @State private var copied = false

    /// VoiceOver hint while the button is live, and the disabled fallback when
    /// no `disabledHint` is given.
    private static let defaultHint = "Copies text to clipboard"

    // MARK: - Body

    var body: some View {
        let button = Button {
            Pasteboard.copy(text, sensitive: isSensitive)
            action?()
            copied = true
            // Unstructured, so it outlives the view; each click starts its own
            // timer, and an earlier click's timer can end a later click's
            // checkmark early. Harmless for a cosmetic flag.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(feedbackDuration))
                copied = false
            }
        } label: {
            if let label, let copiedLabel {
                HStack(spacing: DSSpace.s1) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: DSFont.Size.sm))
                    Text(copied ? copiedLabel : label)
                        .font(.system(size: DSFont.Size.sm))
                }
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: DSFont.Size.sm))
            }
        }
        .modifier(CopyButtonStyleModifier(style: buttonStyle))
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isDisabled ? (disabledHint ?? Self.defaultHint) : Self.defaultHint)
        .accessibilityValue(copied ? "Copied" : "Not copied")

        button.accessibilityIdentifier(optional: accessibilityIdentifier)
    }

    // MARK: - Style

    /// Visual style of the button.
    enum CopyButtonStyle {
        case bordered
        case borderless
    }
}

// MARK: - Style Modifier

/// Applies the button style (and control size or cursor) for a `CopyButtonStyle`.
private struct CopyButtonStyleModifier: ViewModifier {
    let style: CopyButton.CopyButtonStyle

    func body(content: Content) -> some View {
        switch style {
        case .bordered:
            content
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .borderless:
            content
                .buttonStyle(.borderless)
                .pointerCursor()
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: DSSpace.s6) {
        CopyButton(
            text: "ws://localhost:9090",
            accessibilityLabel: "Copy URL"
        )

        CopyButton(
            text: "http://localhost:9091/widget",
            label: "Copy Link",
            copiedLabel: "Copied",
            accessibilityLabel: "Copy widget URL"
        )

        CopyButton(
            text: "brew upgrade wolfwave",
            buttonStyle: .borderless,
            accessibilityLabel: "Copy brew command"
        )
    }
    .padding()
}
