//
//  StatusChipGlyphTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-11.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import SwiftUI
import Testing
@testable import WolfWave

/// Pins the light-appearance glyph mapping behind `StatusChip` and
/// `CalloutBanner`.
///
/// The bright semantic tints read at about 2:1 on a 10% wash of themselves in
/// light appearance, so the glyph swaps to a darker `glyph…Light` token there.
/// These cases make sure every semantic state gets its darker glyph, dark mode
/// keeps the tint, and non-status colors (category tags) are never rewritten.
/// Nothing here touches process-global state.
@Suite("StatusChip glyph contrast")
struct StatusChipGlyphTests {

    // MARK: - Light appearance

    @Test(
        "Each semantic tint maps to its darker glyph in light mode",
        arguments: [
            (DSColor.success, DSColor.glyphSuccessLight),
            (DSColor.warning, DSColor.glyphWarningLight),
            (DSColor.error, DSColor.glyphErrorLight),
            (DSColor.info, DSColor.glyphInfoLight),
            (DSColor.neutral, DSColor.glyphNeutralLight)
        ]
    )
    func lightSemanticGlyphs(tint: Color, expected: Color) {
        #expect(DSColor.glyph(for: tint, in: .light) == expected)
        #expect(DSColor.glyph(for: tint, in: .light) != tint)
    }

    @Test("A non-status category tint passes through in light mode")
    func lightCategoryTintPassesThrough() {
        #expect(DSColor.glyph(for: .purple, in: .light) == .purple)
        #expect(DSColor.glyph(for: DSColor.partnerTwitch, in: .light) == DSColor.partnerTwitch)
    }

    // MARK: - Dark appearance

    @Test(
        "Dark mode keeps every semantic tint",
        arguments: [DSColor.success, DSColor.warning, DSColor.error, DSColor.info, DSColor.neutral]
    )
    func darkKeepsTint(tint: Color) {
        #expect(DSColor.glyph(for: tint, in: .dark) == tint)
    }

    // MARK: - Rendering

    @Test("Chip renders in both appearances")
    @MainActor
    func rendersInBothAppearances() {
        for scheme in [ColorScheme.light, .dark] {
            let view = StatusChip(text: "Live", color: DSColor.success, systemImage: StatusChip.StateGlyph.on)
                .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: view)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width >= DSDimension.StatusChip.minWidth)
        }
    }
}
