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
        VStack(alignment: .leading, spacing: DSSpace.s6) {
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
                    subtitle: "Friends can open the song in one click.",
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
                        title: "Any-app link (song.link)",
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
                        subtitle: playlistShowName
                            ? "Friends see the playlist's real name."
                            : "Friends see a generic label. The name stays private.",
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

    /// What the profile shows when you pause, and when music stops: one
    /// plain choice per situation. Backed by the `discordClearWhilePaused` and
    /// `discordShowIdleStatus` keys, so backups and old choices carry over.
    ///
    /// Real behaviour (`DiscordRPCService.updatePresence`): a hidden paused
    /// song is treated exactly like stopped music, so "Hide it" then shows
    /// whatever the second choice says.
    var behaviorSection: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            cardTitle("When the music isn't playing", "Pick what your profile shows in each case.")

            VStack(alignment: .leading, spacing: DSSpace.s6) {
                behaviorPicker(
                    title: "When you pause",
                    subtitle: clearWhilePaused
                        ? "Your profile shows the \"When music stops\" choice below."
                        : "The song stays up with a paused badge.",
                    selection: pausedChoice,
                    options: [
                        (DiscordPauseChoice.keepSong.rawValue, "Keep the song"),
                        (DiscordPauseChoice.hideSong.rawValue, "Hide the song")
                    ],
                    accessibilityIdentifier: "discordPausedPicker"
                )

                Divider()

                behaviorPicker(
                    title: "When music stops",
                    subtitle: showIdleStatus
                        ? "Shows \"Listening to WolfWave\" with no song."
                        : "Your Discord status is cleared.",
                    selection: stoppedChoice,
                    options: [
                        (DiscordStopChoice.showWolfWave.rawValue, "Listening to WolfWave"),
                        (DiscordStopChoice.showNothing.rawValue, "Nothing")
                    ],
                    accessibilityIdentifier: "discordStoppedPicker"
                )
            }
            .cardStyle()
        }
        .transition(.opacity)
    }

    /// The pause choice as a picker selection over `discordClearWhilePaused`.
    private var pausedChoice: Binding<String> {
        Binding<String>(
            get: { DiscordPauseChoice(clearWhilePaused: clearWhilePaused).rawValue },
            set: { clearWhilePaused = (DiscordPauseChoice(rawValue: $0) ?? .keepSong).clearWhilePaused }
        )
        .snapped(to: DiscordPauseChoice.allCases.map(\.rawValue), fallback: DiscordPauseChoice.keepSong.rawValue)
    }

    /// The stop choice as a picker selection over `discordShowIdleStatus`.
    private var stoppedChoice: Binding<String> {
        Binding<String>(
            get: { DiscordStopChoice(showIdleStatus: showIdleStatus).rawValue },
            set: { showIdleStatus = (DiscordStopChoice(rawValue: $0) ?? .showWolfWave).showIdleStatus }
        )
        .snapped(to: DiscordStopChoice.allCases.map(\.rawValue), fallback: DiscordStopChoice.showWolfWave.rawValue)
    }

    /// One labelled segmented choice with a line that says what it does now.
    private func behaviorPicker(
        title: String,
        subtitle: String,
        selection: Binding<String>,
        options: [(tag: String, label: String)],
        accessibilityIdentifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.s2) {
            VStack(alignment: .leading, spacing: DSSpace.s0) {
                Text(title)
                    .font(.system(size: DSFont.Size.base, weight: .medium))
                Text(subtitle)
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker(title, selection: selection) {
                ForEach(options, id: \.tag) { option in
                    Text(option.label).tag(option.tag)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityLabel(title)
            .accessibilityIdentifier(accessibilityIdentifier)
        }
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
