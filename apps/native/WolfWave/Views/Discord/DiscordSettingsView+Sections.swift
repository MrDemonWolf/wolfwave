//
//  DiscordSettingsView+Sections.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// The Discord pane's cards: connection, buttons, playlist, behavior, and the
/// live presence preview.
extension DiscordSettingsView {

    // MARK: - Sections

    /// Header + status chip, the enable toggle, and either the "Not
    /// configured" banner or the current connection error.
    var connectionSection: some View {
        VStack(alignment: .leading, spacing: AppConstants.SettingsUI.sectionSpacing) {
            SectionHeaderWithStatus(
                title: "Discord",
                subtitle: "Show your music on your Discord profile.",
                statusText: statusChipText,
                statusColor: statusChipColor
            )

            ToggleSettingRow(
                title: "Show on Discord",
                subtitle: "Displays the song and cover art on your profile",
                isOn: $presenceEnabled,
                isDisabled: !hasClientID,
                accessibilityLabel: "Enable Discord Status",
                accessibilityIdentifier: "discordPresenceToggle",
                accessibilityHint: "Toggle to enable or disable Discord Status",
                onChange: { newValue in
                    notifyPresenceSettingChanged(enabled: newValue)
                }
            )
            .cardStyle()

            if !hasClientID {
                CalloutBanner(
                    "Discord Rich Presence isn't set up in this build. Add DISCORD_CLIENT_ID to Config.xcconfig, or grab a build from the website where it's already wired.",
                    title: "Not configured",
                    style: .warning
                )
            } else if let error = connectionErrorBanner {
                ErrorCallout(error: error) { action in
                    switch action {
                    case .retry:
                        Task { await AppDelegate.shared?.discordService?.connectIfNeeded() }
                    case .reportBug:
                        BugReportURL.openPrefilledIssue()
                    default:
                        break
                    }
                }
            }
        }
    }

    /// The failure to show, or `nil` when there is nothing wrong worth saying.
    ///
    /// Every one of these used to be `Log.error` only, surfacing as the single
    /// asserted string "Discord not running" no matter what actually happened.
    private var connectionErrorBanner: UserFacingError? {
        guard presenceEnabled, connectionState == .disconnected else { return nil }
        switch connectionFailure {
        case .none, .notConfigured:
            // Not configured has its own banner above; `.none` means no attempt
            // has failed yet.
            return nil
        case .notRunning:
            return UserFacingError(
                id: "discord.notRunning",
                title: "Discord isn't running",
                fix: "Open Discord and WolfWave connects on its own.",
                severity: .info,
                docsAnchor: "discord-not-connecting"
            )
        case .handshakeRejected:
            return UserFacingError(
                id: "discord.handshakeRejected",
                title: "Discord refused the connection",
                cause: "Discord is running but rejected WolfWave's handshake.",
                fix: "Restarting Discord usually clears it.",
                severity: .warning,
                actions: [.retry],
                docsAnchor: "discord-not-connecting"
            )
        case .socketUnavailable:
            return UserFacingError(
                id: "discord.socketUnavailable",
                title: "WolfWave can't reach Discord",
                cause: "macOS blocked the connection to Discord's local socket.",
                fix: "Restart WolfWave. If it keeps happening, send a bug report.",
                severity: .error,
                actions: [.retry, .reportBug],
                docsAnchor: "discord-not-connecting"
            )
        }
    }

    /// Profile buttons: the master toggle and, when on, one row per button
    /// with its resolved URL.
    var buttonsSection: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            cardTitle("Profile Buttons", "Up to two buttons appear under your song on Discord.")

            VStack(alignment: .leading, spacing: DSSpace.s6) {
                ToggleSettingRow(
                    title: "Show buttons",
                    subtitle: "Display action buttons on your Discord profile.",
                    isOn: $buttonsEnabled,
                    accessibilityLabel: "Show Discord profile buttons",
                    accessibilityIdentifier: "discordButtonsMasterToggle"
                )

                if buttonsEnabled {
                    Divider()

                    DiscordButtonConfigRow(
                        title: "Apple Music link",
                        resolvedURL: nowPlaying.appleMusicURL,
                        accessibilityPrefix: "discordButton1",
                        isEnabled: $button1Enabled
                    )

                    Divider()

                    DiscordButtonConfigRow(
                        title: "Cross-service link (song.link)",
                        resolvedURL: nowPlaying.songLinkURL,
                        accessibilityPrefix: "discordButton2",
                        isEnabled: $button2Enabled
                    )
                }
            }
            .cardStyle()
            .animation(reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.base), value: buttonsEnabled)
        }
        .transition(.opacity)
    }

    /// Playlist toggle, display-style picker, and name-privacy toggle.
    var playlistSection: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            cardTitle("Playlist", "Show the Apple Music playlist you're listening from.")

            VStack(alignment: .leading, spacing: DSSpace.s6) {
                ToggleSettingRow(
                    title: "Show playlist",
                    subtitle: "Adds the current playlist to your Discord status",
                    isOn: $playlistEnabled,
                    accessibilityLabel: "Show playlist on Discord",
                    accessibilityIdentifier: "discordPlaylistToggle",
                    accessibilityHint: "Toggle to show or hide the current playlist"
                )

                if playlistEnabled {
                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: DSSpace.s0) {
                            Text("Display style")
                                .font(.system(size: DSFont.Size.base, weight: .medium))
                            Text(playlistStyleSubtitle)
                                .font(.system(size: DSFont.Size.sm))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Picker("Display style", selection: $playlistStyle) {
                            Text("Artist + playlist line").tag(DiscordPlaylistStyle.artistLine)
                            Text("Playlist tooltip").tag(DiscordPlaylistStyle.iconTooltip)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .accessibilityIdentifier("discordPlaylistStylePicker")
                    }

                    Divider()

                    ToggleSettingRow(
                        title: "Show playlist name",
                        subtitle: "Off shows a generic label so the name stays private",
                        isOn: $playlistShowName,
                        accessibilityLabel: "Show playlist name",
                        accessibilityIdentifier: "discordPlaylistShowNameToggle",
                        accessibilityHint: "Toggle to reveal or hide the playlist's name"
                    )
                }
            }
            .cardStyle()
        }
        .transition(.opacity)
    }

    /// Idle-status and clear-while-paused toggles.
    var behaviorSection: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            cardTitle("When not playing", "Control what your profile shows when music stops or pauses.")

            VStack(alignment: .leading, spacing: DSSpace.s6) {
                ToggleSettingRow(
                    title: "Show idle status",
                    subtitle: "Keep an idle \"Listening to WolfWave\" status on your profile instead of clearing it",
                    isOn: $showIdleStatus,
                    accessibilityLabel: "Show idle status on Discord",
                    accessibilityIdentifier: "discordIdleStatusToggle",
                    accessibilityHint: "Toggle to keep an idle activity on your profile when nothing is playing"
                )

                Divider()

                ToggleSettingRow(
                    title: "Hide track while paused",
                    subtitle: "Clear the track when you pause, rather than leaving it on your profile",
                    isOn: $clearWhilePaused,
                    accessibilityLabel: "Hide track while paused",
                    accessibilityIdentifier: "discordClearWhilePausedToggle",
                    accessibilityHint: "Toggle to clear your Discord profile while playback is paused"
                )
            }
            .cardStyle()
        }
        .transition(.opacity)
    }

    /// Live mock of the profile card, plus a hint when the playlist is only
    /// visible as the icon tooltip.
    var previewSection: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            SectionHeaderWithStatus(
                title: "Preview",
                subtitle: "How your profile will look on Discord.",
                prominence: .section,
                statusText: previewStatusText,
                statusColor: previewStatusColor
            )

            DiscordPreviewCard(
                mode: previewMode,
                trackTitle: nowPlaying.track,
                artist: previewStateLine,
                album: nowPlaying.album,
                artworkURL: nowPlaying.artworkURL.flatMap(URL.init(string:)),
                button1: Self.previewButton(index: 1, url: nowPlaying.appleMusicURL, defaults: DefaultsStore.store),
                button2: Self.previewButton(index: 2, url: nowPlaying.songLinkURL, defaults: DefaultsStore.store),
                playlistTooltip: previewPlaylistTooltip
            )
            .padding(.horizontal, DSSpace.s1)

            if previewMode.showsTrack, let tooltip = previewPlaylistTooltip {
                HStack(spacing: DSSpace.s1h) {
                    Image(systemName: "info.circle")
                    Text("Hover the app icon on Discord to see: \(tooltip)")
                }
                .font(.system(size: DSFont.Size.sm))
                .foregroundStyle(.secondary)
                .padding(.horizontal, DSSpace.s1)
            }
        }
        .transition(.opacity)
    }
}
