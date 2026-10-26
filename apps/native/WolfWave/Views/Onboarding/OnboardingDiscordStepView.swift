//
//  OnboardingDiscordStepView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-02-13.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import SwiftUI

/// Discord Rich Presence step: one switch, whether Discord is open right now,
/// and (once on) what friends will see, with the buttons one tap away.
struct OnboardingDiscordStepView: View {

    // MARK: - Properties

    /// The `discordPresenceEnabled` preference, owned by `OnboardingView`.
    @Binding var presenceEnabled: Bool

    /// The two profile buttons, both on by default. One switch here covers
    /// both; Settings → Discord splits them.
    @AppStorage(AppConstants.UserDefaults.discordButtonsEnabled)
    private var buttonsEnabled = AppConstants.UserDefaults.Defaults.discordButtonsEnabled

    /// Whether a Discord app (stable, PTB, or Canary) is running. Re-read when
    /// WolfWave becomes active, since the usual fix is "open Discord, come back".
    @State private var discordRunning = Self.isDiscordRunning()

    // MARK: - Body

    var body: some View {
        OnboardingStepScaffold(
            title: "Show your music on Discord",
            description: "Friends see the song, artist, and cover art under your name.",
            icon: {
                BrandTile(
                    background: AnyShapeStyle(AppConstants.Brand.discord),
                    glowColor: AppConstants.Brand.discord,
                    glyph: BrandTileGlyph.asset("DiscordLogo")
                )
            },
            extras: {
                VStack(spacing: DSSpace.s4) {
                    ToggleSettingRow(
                        title: "Show on Discord",
                        subtitle: presenceEnabled ? "On. Updates when the song changes." : "Off. Turn it on any time.",
                        isOn: $presenceEnabled,
                        controlSize: .regular,
                        accessibilityLabel: "Show on Discord",
                        accessibilityIdentifier: "onboardingDiscordToggle",
                        // The binding only stores the preference; this post is what
                        // tells AppDelegate to start or stop Discord Rich Presence now.
                        onChange: { newValue in
                            NotificationCenter.default.postEnabled(.discordPresenceChanged, enabled: newValue)
                        }
                    )
                    .onboardingTintedToggleShell(
                        isOn: presenceEnabled,
                        tint: AppConstants.Brand.discord,
                        fillOpacity: 0.10,
                        glowOpacity: 0.18,
                        glowRadius: 18,
                        glowYOffset: 6
                    )

                    if presenceEnabled {
                        buttonsRow
                            .transition(.opacity)
                    }

                    discordStatus
                }
                .motionSafe(.easeInOut(duration: DSMotion.Duration.base), value: presenceEnabled)
            }
        )
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            discordRunning = Self.isDiscordRunning()
        }
    }

    // MARK: - Subviews

    /// The profile buttons, on by default, with a one-tap switch.
    private var buttonsRow: some View {
        ToggleSettingRow(
            title: "Listen buttons",
            subtitle: "\"Listen on Apple Music\" and a link for any other music app.",
            isOn: $buttonsEnabled,
            accessibilityLabel: "Listen buttons on your Discord profile",
            accessibilityIdentifier: "onboardingDiscordButtonsToggle"
        )
        .padding(.horizontal, DSSpace.s5)
    }

    /// Whether Discord is open, so "nothing shows up" has an obvious reason.
    private var discordStatus: some View {
        HStack(spacing: DSSpace.s1h) {
            Image(systemName: discordRunning ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(discordRunning ? DSColor.success : DSColor.warning)
                .accessibilityHidden(true)
            Text(discordRunning ? "Discord is open." : "Open the Discord app on this Mac. WolfWave finds it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: DSFont.Size.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DSSpace.s5)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboardingDiscordStatus")
    }

    // MARK: - Helpers

    /// `true` when any Discord build is running. Reads the running-apps list
    /// only, so it never launches Discord.
    private static func isDiscordRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier.map(DiscordRPCService.discordBundleIDs.contains) ?? false
        }
    }
}

// MARK: - Preview

#Preview {
    OnboardingDiscordStepView(presenceEnabled: .constant(true))
        .frame(width: 600, height: 420)
}
