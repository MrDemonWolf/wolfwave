//
//  WolfHeroMark.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-26.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

// MARK: - WolfHeroMark

/// Scalable presentation wrapper around the canonical `WolfMark` template asset.
///
/// Decorative only: hidden from VoiceOver, so place it next to text that names
/// the screen.
struct WolfHeroMark: View {

    // MARK: - Style

    /// How the mark is filled.
    enum Style: Equatable {
        /// Flat tint for small or inline marks.
        case mono(Color)
        /// Theme-adaptive WolfWave gradient for hero surfaces.
        case brandGradient
    }

    // MARK: - Properties

    /// Square render size in points.
    var size: CGFloat
    /// Fill treatment. Defaults to the primary label color.
    var style: Style = .mono(.primary)

    /// Picks the gradient stops for `.brandGradient`.
    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Body

    var body: some View {
        Group {
            switch style {
            case .mono(let color):
                mark.foregroundStyle(color)
            case .brandGradient:
                brandGradient.mask(mark)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: - Private Views

    /// The `WolfMark` asset as a template image, so either a flat style or a
    /// gradient mask can color it.
    private var mark: some View {
        Image("WolfMark")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
    }

    /// Brand gradient, top-leading to bottom-trailing. Dark appearance shifts to
    /// lighter stops so the mark keeps contrast on a dark window.
    private var brandGradient: LinearGradient {
        let colors: [Color] = colorScheme == .dark
            ? [AppConstants.Brand.wolfwaveGradientEnd, DSColor.brand300]
            : [AppConstants.Brand.wolfwaveGradientStart, AppConstants.Brand.wolfwaveGradientEnd]
        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Previews

#Preview("mono: primary") {
    WolfHeroMark(size: 120, style: .mono(.primary))
        .padding(DSSpace.s7)
}

#Preview("brand gradient") {
    WolfHeroMark(size: 120, style: .brandGradient)
        .padding(DSSpace.s7)
}

#Preview("brand gradient: dark") {
    WolfHeroMark(size: 120, style: .brandGradient)
        .padding(DSSpace.s7)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
}

#Preview("mono: twitch tint, small") {
    WolfHeroMark(size: 44, style: .mono(AppConstants.Brand.twitch))
        .padding(DSSpace.s4)
}
