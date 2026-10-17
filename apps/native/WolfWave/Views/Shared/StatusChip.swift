//
//  StatusChip.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-03-27.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// A capsule-shaped status indicator with a leading glyph and label text.
///
/// Used across settings views (Discord, WebSocket, Twitch, etc.) to show
/// connection or server state. Has a modest minimum width so the pill stays
/// stable across short state labels ("Off"/"Live"/"On") without crowding the
/// neighboring Configure affordance in tight rows.
///
/// Pass `systemImage` for status chips so the state reads through a shape, not
/// color alone (WCAG 1.4.1). When omitted, the chip falls back to a plain
/// colored dot, fine for non-status category tags where there is no shared
/// icon vocabulary.
///
/// The glyph (or dot) is drawn in ``DSColor/glyph(for:in:)`` rather than the raw
/// tint, so in light appearance a semantic token swaps to its darker
/// `glyph…Light` variant and stays above 3:1 on the chip's own wash (WCAG 1.4.11).
struct StatusChip: View {

    // MARK: - Properties

    /// Visible state label. Also the VoiceOver label and the identifier suffix
    /// (`statusChip.<text>`), and changing it cross-fades the label.
    let text: String
    /// State tint for the wash and (via `glyphColor`) the glyph. Use a `DSColor`
    /// semantic token for status; a raw color is only for category tags.
    let color: Color
    /// Optional leading SF Symbol. When set, the symbol replaces the colored
    /// dot so state is conveyed by shape and color together, not color alone.
    var systemImage: String?

    /// Picks the light- or dark-appearance glyph color.
    @Environment(\.colorScheme) private var colorScheme

    /// Contrast-safe color for the leading glyph or dot.
    private var glyphColor: Color { DSColor.glyph(for: color, in: colorScheme) }

    // MARK: - Body

    var body: some View {
        HStack(spacing: DSSpace.s1h) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: DSFont.Size.sm, weight: .semibold))
                    .foregroundStyle(glyphColor)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(glyphColor)
                    .frame(width: DSDimension.StatusChip.dot, height: DSDimension.StatusChip.dot)
                    .contentTransition(.interpolate)
                    .accessibilityHidden(true)
            }

            Text(text)
                .font(.system(size: DSFont.Size.sm, weight: .semibold))
                .foregroundStyle(.primary)
                .contentTransition(.opacity)
        }
        .frame(minWidth: DSDimension.StatusChip.minWidth)
        .padding(.horizontal, DSSpace.s3)
        .padding(.vertical, DSSpace.s1)
        .background(color.opacity(DSOpacity.wash))
        .clipShape(Capsule())
        .motionSafe(.easeInOut(duration: DSMotion.Duration.base), value: text)
        .motionSafe(.easeInOut(duration: DSMotion.Duration.base), value: color)
        // Label only: a value equal to the label made VoiceOver read the state twice.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
        .accessibilityIdentifier("statusChip.\(text)")
    }
}

// MARK: - Status-State Symbols

extension StatusChip {

    /// Standard leading glyphs so connection state reads through shape as well
    /// as color (WCAG 1.4.1). Reused by the integration dashboard and any pane
    /// that shows an on / off / paused chip.
    ///
    /// `nonisolated` because this is a symbol-name vocabulary, not UI: the module
    /// defaults to `MainActor`, which otherwise walls it off from the pure status
    /// resolvers (``StreamDeckPaneStatus``) that exist to be unit-tested.
    nonisolated enum StateGlyph {
        /// A connected / live / on state. Filled check.
        public static let on = "checkmark.circle.fill"
        /// An off / disconnected state. Hollow circle.
        public static let off = "circle"
        /// A paused-by-system state (e.g. missing permission). Pause glyph.
        public static let paused = "pause.circle.fill"
        /// An error state. Warning triangle.
        public static let error = "exclamationmark.triangle.fill"
        /// A transient starting / connecting state. Ellipsis.
        public static let starting = "ellipsis.circle"
    }
}

// MARK: - Semantic Glyph Contrast

extension DSColor {

    /// The color to draw a glyph in when it sits on a wash of `tint`.
    ///
    /// The semantic tints are tuned for dark appearance. In light appearance a
    /// bright tint drawn on a 10% wash of itself lands under 3:1 (success and
    /// warning near 2:1), which fails WCAG 1.4.11 for meaningful non-text marks.
    /// Each semantic token therefore maps to its darker `glyph…Light` variant in
    /// light appearance. Dark appearance, and any non-semantic color (a category
    /// tag's `.purple`, a tint with its own opacity), pass through unchanged.
    ///
    /// Use only for the glyph or dot. Keep the wash itself on the semantic
    /// tint, so the chip still reads as the same state color.
    ///
    /// `nonisolated` so the mapping is unit-testable off the main actor.
    nonisolated static func glyph(for tint: Color, in colorScheme: ColorScheme) -> Color {
        guard colorScheme == .light else { return tint }
        switch tint {
        case DSColor.success: return DSColor.glyphSuccessLight
        case DSColor.warning: return DSColor.glyphWarningLight
        case DSColor.error: return DSColor.glyphErrorLight
        case DSColor.info: return DSColor.glyphInfoLight
        case DSColor.neutral: return DSColor.glyphNeutralLight
        default: return tint
        }
    }
}

// MARK: - Previews

#Preview("Live") {
    StatusChip(text: "Live", color: DSColor.success, systemImage: StatusChip.StateGlyph.on)
        .padding()
        .frame(width: 360)
}

#Preview("Off") {
    StatusChip(text: "Off", color: DSColor.neutral, systemImage: StatusChip.StateGlyph.off)
        .padding()
        .frame(width: 360)
}

#Preview("Error") {
    StatusChip(text: "Error", color: DSColor.error, systemImage: StatusChip.StateGlyph.error)
        .padding()
        .frame(width: 360)
}

#Preview("Light vs dark glyphs") {
    HStack(spacing: DSSpace.s4) {
        ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
            VStack(alignment: .leading, spacing: DSSpace.s2) {
                StatusChip(text: "Live", color: DSColor.success, systemImage: StatusChip.StateGlyph.on)
                StatusChip(text: "Starting", color: DSColor.warning, systemImage: StatusChip.StateGlyph.starting)
                StatusChip(text: "Error", color: DSColor.error, systemImage: StatusChip.StateGlyph.error)
                StatusChip(text: "Joined", color: DSColor.info, systemImage: StatusChip.StateGlyph.off)
                StatusChip(text: "Off", color: DSColor.neutral, systemImage: StatusChip.StateGlyph.off)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
        }
    }
    .padding()
}

#Preview("Dot fallback (category tag)") {
    StatusChip(text: "Twitch", color: .purple)
        .padding()
        .frame(width: 360)
}
