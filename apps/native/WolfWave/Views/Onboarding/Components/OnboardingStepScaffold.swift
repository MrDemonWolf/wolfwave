//
//  OnboardingStepScaffold.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-25.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Shared top-aligned layout for every interior onboarding step.
///
/// Icon, title, one-line description, then the step's controls, all hung from
/// the same top edge. Because nothing is vertically centered, the icon and
/// title sit at an identical Y on every step whatever the controls below them
/// measure, and short steps keep their controls right under the copy instead of
/// floating them in the middle of the window. Tall controls (the Twitch device
/// code) just run further down; the container scrolls if they ever pass the
/// bottom.
///
/// Every step uses it except Welcome, which is the hero bookend.
struct OnboardingStepScaffold<Icon: View, Extras: View>: View {

    // MARK: - Properties

    /// Step headline. Marked as a header for VoiceOver.
    let title: String
    /// One short sentence under the title, capped to a readable width.
    let description: String

    /// The step's hero, normally a `BrandTile`.
    @ViewBuilder var icon: () -> Icon
    /// Step-specific controls, placed `DSSpace.s7` under the description.
    @ViewBuilder var extras: () -> Extras

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            icon()
                .padding(.bottom, DSSpace.s5)

            Text(title)
                // 22pt = the app's `.paneTitle()` H1 size. Welcome and the
                // completion screen stay at 26pt as the hero bookends.
                .font(.system(size: DSFont.Size.x2xl, weight: .bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(description)
                .font(.system(size: DSFont.Size.base))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: DSDimension.Onboarding.contentMaxWidth)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DSSpace.s1h)

            extras()
                .frame(maxWidth: DSDimension.Onboarding.contentMaxWidth)
                .padding(.top, DSSpace.s7)
        }
        .padding(.horizontal, DSSpace.s8)
        .padding(.top, DSSpace.s6)
        .padding(.bottom, DSSpace.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Preview

#Preview("With extras") {
    OnboardingStepScaffold(
        title: "Sample step",
        description: "The header sits at the same spot on every step.",
        icon: {
            BrandTileGlyph.symbol("bolt.fill", tint: AppConstants.Brand.discord)
        },
        extras: {
            RoundedRectangle(cornerRadius: DSRadius.lg2)
                .fill(Color.accentColor.opacity(0.10))
                .frame(height: 80)
        }
    )
    .frame(width: 600, height: 480)
}

#Preview("No extras") {
    OnboardingStepScaffold(
        title: "Sample step",
        description: "Header stays put even with empty extras.",
        icon: {
            BrandTileGlyph.symbol("bolt.fill", tint: AppConstants.Brand.twitch)
        },
        extras: { EmptyView() }
    )
    .frame(width: 600, height: 480)
}
