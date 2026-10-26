//
//  OnboardingNotificationsStepView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-06-01.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import SwiftUI
import UserNotifications

/// Notifications step. Asks for notification authorization, then lets the user
/// pick which alerts they want. The per-alert toggles (song change, skip-vote
/// started, skip-vote passed) stay disabled until authorization is granted.
/// Split out from the Apple Music permission step so each screen has one job.
///
/// This is the one place onboarding asks for notification permission, and only
/// when the user clicks Allow notifications: nothing here prompts on appear. The alert
/// toggles write preferences only; `AppDelegate` and `NotificationService` read
/// them when an event happens.
struct OnboardingNotificationsStepView: View {

    // MARK: - Notification State

    /// Last authorization status read from `UNUserNotificationCenter`. Starts as
    /// `.notDetermined` until the first async read, and is re-read whenever the
    /// app becomes active (the user may have changed it in System Settings).
    @State private var notificationsStatus: UNAuthorizationStatus = .notDetermined

    // MARK: - Notification Preferences

    @AppStorage(AppConstants.UserDefaults.songChangeNotificationsEnabled)
    private var songChangeNotificationsEnabled = false

    @AppStorage(AppConstants.UserDefaults.skipVoteStartedNotificationsEnabled)
    private var skipVoteStartedNotificationsEnabled = false

    @AppStorage(AppConstants.UserDefaults.skipVotePassedNotificationsEnabled)
    private var skipVotePassedNotificationsEnabled = false

    // MARK: - Body

    var body: some View {
        OnboardingStepScaffold(
            title: "Get a heads-up",
            description: "Banners for new songs and chat skip votes. All off until you pick.",
            icon: {
                BrandTileGlyph.symbol("bell.badge.fill", tint: Color.red)
            },
            extras: {
                notificationsSection
            }
        )
        .task {
            await refreshNotificationStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshNotificationStatus() }
        }
    }

    // MARK: - Notifications Section

    /// The permission row plus the alert group. The permission row is a
    /// button or a status line, never a switch, because macOS owns the
    /// answer: a switch that can't be turned off (or that opens System
    /// Settings) only looks like it does what it says.
    ///   - notDetermined → **Allow notifications** asks macOS
    ///   - authorized / provisional → "Notifications are on"
    ///   - denied → why, plus **Open System Settings**
    @ViewBuilder
    private var notificationsSection: some View {
        let isAuthorized = notificationsStatus == .authorized || notificationsStatus == .provisional

        VStack(alignment: .leading, spacing: DSSpace.s4) {
            permissionRow(isAuthorized: isAuthorized)

            // Dimmed, not hidden, until allowed: a user who skips the
            // permission still sees what they could turn on later.
            alertGroup
                .disabled(!isAuthorized)
                .opacity(isAuthorized ? 1 : 0.5)
        }
        .motionSafe(.easeInOut(duration: DSMotion.Duration.base), value: notificationsStatus)
    }

    /// The permission control for the current status.
    @ViewBuilder
    private func permissionRow(isAuthorized: Bool) -> some View {
        if isAuthorized {
            HStack(spacing: DSSpace.s2) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DSColor.success)
                    .accessibilityHidden(true)
                Text("Notifications are on. Pick what's worth a banner.")
                    .font(.system(size: DSFont.Size.base, weight: .medium))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("onboardingNotificationsStatus")
        } else if notificationsStatus == .denied {
            HStack(spacing: DSSpace.s3) {
                Text("Notifications are off for WolfWave in System Settings.")
                    .font(.system(size: DSFont.Size.base))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DSSpace.s2)
                Button("Open System Settings", action: openNotificationsSettings)
                    .buttonStyle(.bordered)
                    .pointerCursor()
                    .accessibilityIdentifier("onboardingNotificationsOpenSettings")
            }
        } else {
            HStack(spacing: DSSpace.s3) {
                Text("macOS asks once. Nothing pings you until you turn an alert on.")
                    .font(.system(size: DSFont.Size.base))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DSSpace.s2)
                Button("Allow notifications", action: requestNotificationAuthorization)
                    .buttonStyle(.borderedProminent)
                    .pointerCursor()
                    .accessibilityIdentifier("onboardingNotificationsToggle")
            }
        }
    }

    /// The per-alert toggles, rendered as chrome-free rows stacked inside one
    /// bordered card with text-aligned dividers between them.
    ///
    /// The toggles stay readable when disabled (dimmed, not hidden), so a user who
    /// skips the permission still sees what they could turn on later.
    @ViewBuilder
    private var alertGroup: some View {
        VStack(spacing: 0) {
            OnboardingToggleCard(
                icon: "music.note",
                iconColor: .pink,
                title: "Song changes",
                subtitle: "A banner with album art each time the track changes.",
                isOn: $songChangeNotificationsEnabled,
                accessibilityLabel: "Song change notifications",
                accessibilityIdentifier: "onboardingSongChangeNotificationsToggle",
                showsCardBackground: false
            )

            rowDivider

            OnboardingToggleCard(
                icon: "hand.raised.fill",
                iconColor: .orange,
                title: "Skip vote started",
                subtitle: "When chat opens a vote to skip the current song.",
                isOn: $skipVoteStartedNotificationsEnabled,
                accessibilityLabel: "Skip vote started notifications",
                accessibilityIdentifier: "onboardingSkipVoteStartedNotificationsToggle",
                showsCardBackground: false
            )

            rowDivider

            OnboardingToggleCard(
                icon: "checkmark.seal.fill",
                iconColor: .green,
                title: "Skip vote passed",
                subtitle: "When a chat skip-vote wins and the song is skipped.",
                isOn: $skipVotePassedNotificationsEnabled,
                accessibilityLabel: "Skip vote passed notifications",
                accessibilityIdentifier: "onboardingSkipVotePassedNotificationsToggle",
                showsCardBackground: false
            )
        }
        .subtleCardShell(cornerRadius: DSRadius.lg2)
    }

    /// Hairline between grouped rows, inset to start under the row title so it
    /// clears the icon tile (the standard grouped-list look).
    private var rowDivider: some View {
        Divider()
            .padding(.leading, AppConstants.OnboardingUI.iconTileSize + DSSpace.s4 * 2)
    }

    // MARK: - Notification Actions

    /// Queries the current notification authorization status and updates the
    /// view state on the main actor.
    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run {
            notificationsStatus = settings.authorizationStatus
        }
    }

    /// Requests notification authorization (`.alert`, `.sound`, `.badge`) and
    /// refreshes the view state with whatever decision the user makes.
    ///
    /// A thrown error is ignored on purpose: the status re-read that follows is
    /// what decides the UI, whatever the request returned.
    private func requestNotificationAuthorization() {
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            await MainActor.run {
                notificationsStatus = settings.authorizationStatus
            }
        }
    }

    /// Opens System Settings → Notifications. macOS 13+ deep-link.
    private func openNotificationsSettings() {
        ExternalLink.open(AppConstants.URLs.systemNotificationSettings)
    }
}

// MARK: - Preview

#Preview {
    OnboardingNotificationsStepView()
        .frame(width: 600, height: 520)
}
