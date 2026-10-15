//
//  DSIconButton.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-23.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Bordered, small-control icon button sized to align with `CopyButton` and
/// other `.bordered .small` neighbors. Use this instead of hand-rolling
/// `Button { Image(...) } .buttonStyle(.bordered) .controlSize(.small)` so
/// every icon-only button shares the same width/height baseline.
struct DSIconButton: View {

    // MARK: - Properties

    /// SF Symbol name for the glyph.
    let systemImage: String
    /// Runs on click.
    let action: () -> Void
    /// Disables the button.
    var isDisabled: Bool = false
    /// Required: an icon-only button has no visible text for VoiceOver to read.
    var accessibilityLabel: String
    /// Optional UI-test identifier; applied only when non-nil.
    var accessibilityIdentifier: String?

    // MARK: - Body

    var body: some View {
        // The min frame is what keeps an icon-only button from collapsing
        // narrower than its text-label neighbours.
        let button = Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: DSFont.Size.sm))
                .frame(
                    minWidth: DSDimension.IconButton.minWidth,
                    minHeight: DSDimension.IconButton.minHeight
                )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)

        button.accessibilityIdentifier(optional: accessibilityIdentifier)
    }
}

// MARK: - Preview

#Preview {
    HStack(spacing: DSSpace.s2) {
        DSIconButton(
            systemImage: "eye",
            action: {},
            accessibilityLabel: "Reveal"
        )
        DSIconButton(
            systemImage: "arrow.clockwise",
            action: {},
            accessibilityLabel: "Refresh"
        )
        CopyButton(
            text: "preview",
            label: "Copy",
            copiedLabel: "Copied",
            accessibilityLabel: "Copy"
        )
    }
    .padding()
}
