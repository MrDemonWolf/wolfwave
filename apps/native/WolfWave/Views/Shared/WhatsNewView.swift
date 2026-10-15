//
//  WhatsNewView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-03-30.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Displays a "What's New" window highlighting key features introduced in this version.
///
/// Shown once per *feature* release (`AppConstants.AppInfo.whatsNewVersion`) to
/// returning users who have completed onboarding; `AppDelegate.checkWhatsNew()`
/// owns that gate. Each feature is displayed as a card-styled row with an SF
/// Symbol icon, title, and short description.
///
/// The feature list is hardcoded below. Update it, and bump `whatsNewVersion`,
/// in the same change when a feature release ships.
struct WhatsNewView: View {

    // MARK: - Properties

    /// Used only when `onClose` is `nil`.
    @Environment(\.dismiss) private var dismiss

    /// Closes the hosting window. `AppDelegate` hosts this view in an `NSWindow`,
    /// where `dismiss` is a no-op, so it passes a closure that closes the
    /// window. When `nil` (a sheet or a preview), `dismiss` is used instead.
    var onClose: (() -> Void)?

    // MARK: - Feature Data

    /// One row per headline feature: SF Symbol, its tint, title, and one-line
    /// description. `title` doubles as the `ForEach` id and the accessibility
    /// identifier suffix, so titles must be unique.
    private let features: [(icon: String, iconColor: Color, title: String, description: String)] = [
        ("text.bubble.fill", .purple, "Custom Commands", "Make your own !commands with variables and cooldowns."),
        ("checkmark.circle.fill", .orange, "Approve Requests", "Hold every song request until you say yes."),
        ("person.3.sequence.fill", .blue, "Fair-Share Queue", "Everyone's first request plays before anyone's second, and subs or VIPs can get a perk."),
        ("opticaldisc.fill", .pink, "Vinyl & Classic Overlays", "Two new looks for your stream: a spinning record, or art beside the track."),
        ("bolt.fill", .yellow, "Lighter on Your Mac", "Much less work between songs. Same features, less CPU and battery."),
        ("checkmark.seal.fill", .green, "Steadier & Smoother", "Fixed UI freezes and crashes across requests, overlays, and stats."),
    ]

    // MARK: - Body

    var body: some View {
        VStack(spacing: DSSpace.s7) {
            // MARK: Header
            VStack(spacing: DSSpace.s1h) {
                Text("What's New in WolfWave v\(AppConstants.AppInfo.whatsNewVersion)")
                    .sectionHeader()

                Text("The big ones. There's more in the full changelog.")
                    .font(.system(size: DSFont.Size.base))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, DSSpace.s1)

            // MARK: Feature List
            ScrollView {
                VStack(spacing: DSSpace.s3) {
                    ForEach(features, id: \.title) { feature in
                        featureRow(feature)
                    }
                }
            }

            // MARK: Actions
            VStack(spacing: DSSpace.s3) {
                Button("Got it") {
                    if let onClose {
                        onClose()
                    } else {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Closes what's new")
                .accessibilityIdentifier("whatsNew.gotIt")

                Button("See all changes") {
                    ExternalLink.open(AppConstants.URLs.changelog)
                }
                .buttonStyle(.link)
                .font(.system(size: DSFont.Size.body))
                .accessibilityHint("Opens the full changelog in your browser")
                .accessibilityIdentifier("whatsNew.seeAllChanges")
            }
        }
        .padding(DSSpace.s8)
        .frame(
            idealWidth: DSDimension.WhatsNew.windowWidth,
            idealHeight: DSDimension.WhatsNew.windowHeight
        )
    }

    // MARK: - Private Helpers

    /// Renders a single feature as a card-styled row.
    private func featureRow(_ feature: (icon: String, iconColor: Color, title: String, description: String)) -> some View {
        HStack(spacing: DSSpace.s5) {
            Image(systemName: feature.icon)
                .font(.system(size: DSFont.Size.xl))
                .foregroundStyle(feature.iconColor)
                .frame(width: 36, height: 36)
                .background(feature.iconColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.md))

            VStack(alignment: .leading, spacing: DSSpace.s0) {
                Text(feature.title)
                    .font(.system(size: DSFont.Size.base, weight: .semibold))

                Text(feature.description)
                    .font(.system(size: DSFont.Size.body))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(feature.title). \(feature.description)")
        .accessibilityIdentifier("whatsNew.feature.\(feature.title)")
    }
}

// MARK: - Preview

#Preview {
    WhatsNewView()
        .frame(
            width: DSDimension.WhatsNew.windowWidth,
            height: DSDimension.WhatsNew.windowHeight
        )
}
