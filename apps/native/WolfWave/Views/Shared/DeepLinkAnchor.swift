//
//  DeepLinkAnchor.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-09-01.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Scroll target id for a `wolfwave://settings/<pane>/<section>` link.
/// Typed (not a bare `String`) so it can never collide with other `.id`s
/// in the same scroll view.
nonisolated struct DeepLinkAnchor: Hashable {
    /// The kebab-case section slug from the link (for example the `<section>`
    /// in `wolfwave://settings/<pane>/<section>`).
    let slug: String
}

// MARK: - View Extension

extension View {
    /// Marks this view as the `<section>` target of a settings deep link.
    /// `slug` is kebab-case and must be unique within its pane. The view
    /// flashes an accent ring when a link lands on it.
    func deepLinkSection(_ slug: String) -> some View {
        modifier(DeepLinkHighlight(slug: slug))
    }
}

// MARK: - Highlight Modifier

/// Applies the `DeepLinkAnchor` id and draws the accent ring that flashes when
/// `SettingsNavigation.shared.highlighted` names this slug.
private struct DeepLinkHighlight: ViewModifier {
    /// This anchor's section slug.
    let slug: String
    /// Ring visibility, from 0 (hidden) to 1. Animated back to 0 by `flash()`.
    @State private var ringOpacity: Double = 0

    func body(content: Content) -> some View {
        content
            .id(DeepLinkAnchor(slug: slug))
            .overlay {
                RoundedRectangle(cornerRadius: AppConstants.SettingsUI.cardCornerRadius, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .opacity(ringOpacity)
                    .allowsHitTesting(false)
            }
            // `initial: true` so a link that lands before this view mounts (the
            // pane was just opened) still flashes on first appearance.
            .onChange(of: SettingsNavigation.shared.highlighted == slug, initial: true) { _, isTarget in
                guard isTarget else { return }
                flash()
            }
    }

    /// Shows the ring at full opacity, holds it for one `pulseSlow` duration, then
    /// fades it out over another.
    ///
    /// Visual only. `SettingsView` owns clearing `highlighted`, so a slug
    /// with no mounted anchor still expires.
    private func flash() {
        ringOpacity = 1
        withAnimation(.easeOut(duration: DSMotion.Duration.pulseSlow).delay(DSMotion.Duration.pulseSlow)) {
            ringOpacity = 0
        }
    }
}
