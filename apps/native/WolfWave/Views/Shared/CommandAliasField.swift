//
//  CommandAliasField.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-06-04.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// A compact "Custom aliases:" label paired with a rounded text field.
///
/// Every chat-command settings row offers extra trigger names (comma-separated,
/// without the leading `!`). This view is the one shared layout for that field,
/// extracted from the per-pane copies that previously lived in the Twitch, Song
/// Request, and History settings so they share a single look and accessibility
/// contract.
struct CommandAliasField: View {

    // MARK: - Properties

    /// Raw comma-separated alias text, stored as typed. Parsing (splitting,
    /// trimming, dropping a leading `!`) is the consumer's job, not this view's.
    @Binding var aliases: String
    /// Visible label before the field.
    var label: String = "Custom aliases:"
    /// Placeholder shown while the field is empty.
    var placeholder: String = "e.g. np, track"
    /// VoiceOver label for the field.
    var accessibilityLabel: String = "Custom aliases"
    /// Optional UI-test identifier. Applied only when non-nil so call sites that
    /// never set one (and don't need unique targeting) emit no identifier.
    var accessibilityIdentifier: String?

    // MARK: - Body

    var body: some View {
        HStack(spacing: DSSpace.s2) {
            Text(label)
                .font(.system(size: DSFont.Size.sm))
                .foregroundStyle(.tertiary)

            field
        }
    }

    // MARK: - Private Views

    /// The rounded text field, capped at the shared inline-field width.
    @ViewBuilder
    private var field: some View {
        let base = TextField(placeholder, text: $aliases)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: DSFont.Size.sm))
            .frame(maxWidth: AppConstants.SettingsUI.inlineFieldMaxWidth)
            .accessibilityLabel(accessibilityLabel)

        base.accessibilityIdentifier(optional: accessibilityIdentifier)
    }
}

// MARK: - Preview

#Preview {
    struct Wrapper: View {
        @State private var aliases = "np, track"
        var body: some View {
            CommandAliasField(aliases: $aliases, accessibilityIdentifier: "preview.aliases")
                .padding()
                .frame(width: 420)
        }
    }
    return Wrapper()
}
