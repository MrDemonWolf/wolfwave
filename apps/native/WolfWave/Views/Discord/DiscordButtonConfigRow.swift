//
//  DiscordButtonConfigRow.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Settings row for configuring a single Discord Rich Presence button.
///
/// Lets the user toggle the button on/off and previews the URL that will be sent.
struct DiscordButtonConfigRow: View {

    // MARK: - Properties

    /// Section title shown above the toggle (e.g. "Apple Music link").
    let title: String

    /// URL that the service would send for this button, or nil if unavailable.
    /// Displayed in small monospaced tertiary text below the toggle; a
    /// "(no track playing…)" placeholder when nil or empty.
    let resolvedURL: String?

    /// Accessibility identifier prefix (e.g. "discordButton1"); the toggle and
    /// link get `<prefix>Toggle` / `<prefix>Link`.
    let accessibilityPrefix: String

    /// Whether this button is included in the presence payload.
    @Binding var isEnabled: Bool

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s3) {
            ToggleSettingRow(
                title: title,
                subtitle: isEnabled
                    ? "Shown on your Discord profile."
                    : "Hidden from your Discord profile.",
                isOn: $isEnabled,
                accessibilityLabel: "\(title) enabled",
                accessibilityIdentifier: "\(accessibilityPrefix)Toggle"
            )

            urlPreview
        }
    }

    // MARK: - Helpers

    /// The URL line under the toggle. When a real URL is resolved it renders as a
    /// clickable ``Link`` so the user can open and preview it; otherwise it falls
    /// back to a plain placeholder string.
    @ViewBuilder
    private var urlPreview: some View {
        if let url = resolvedURL, !url.isEmpty, let destination = URL(string: url) {
            Link(destination: destination) {
                urlText(url)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(title): \(url)")
            .accessibilityIdentifier("\(accessibilityPrefix)Link")
        } else {
            urlText("(no track playing, URL fills in once a song starts)")
        }
    }

    /// Single-line, middle-truncated URL text; the full URL is in the tooltip.
    /// Dimmed while the button is disabled.
    private func urlText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: DSFont.Size.xs, design: .monospaced))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(resolvedURL ?? "")
            .opacity(isEnabled ? 1.0 : 0.5)
    }
}

// MARK: - Preview

#Preview("Enabled") {
    DiscordButtonConfigRow(
        title: "Apple Music link",
        resolvedURL: "https://music.apple.com/us/album/example/123?i=456",
        accessibilityPrefix: "discordButton1Preview",
        isEnabled: .constant(true)
    )
    .padding()
    .frame(width: 480)
}

#Preview("Disabled") {
    DiscordButtonConfigRow(
        title: "Apple Music link",
        resolvedURL: nil,
        accessibilityPrefix: "discordButton1Preview",
        isEnabled: .constant(false)
    )
    .padding()
    .frame(width: 480)
}
