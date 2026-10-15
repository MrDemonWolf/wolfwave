//
//  OpenInBrowserButton.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-06-02.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Small bordered "Open" button that launches a URL string in the default browser.
///
/// Replaces the hand-rolled open buttons in Stream Widgets settings so the `safari`
/// glyph, sizing, and disabled handling live in one place. Opening goes through
/// `ExternalLink.open(_:)`, which owns the `URL(string:)` guard; an unparseable
/// string does nothing, silently.
struct OpenInBrowserButton: View {

    // MARK: - Properties

    /// The URL to open, as a string. Parsed only when the button is clicked.
    let urlString: String
    /// Visible label next to the glyph.
    var title: String = "Open"
    /// Disables the button, for example while Streamer Mode hides the URL.
    var isDisabled: Bool = false
    /// Required, because the visible "Open" alone doesn't say what opens.
    let accessibilityLabel: String
    /// Optional VoiceOver hint; empty means none.
    var accessibilityHint: String = ""
    /// Optional UI-test identifier; empty means none.
    var accessibilityIdentifier: String = ""

    var body: some View {
        Button {
            ExternalLink.open(urlString)
        } label: {
            HStack(spacing: DSSpace.s1) {
                Image(systemName: "safari").font(.system(size: DSFont.Size.sm))
                Text(title).font(.system(size: DSFont.Size.sm))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
