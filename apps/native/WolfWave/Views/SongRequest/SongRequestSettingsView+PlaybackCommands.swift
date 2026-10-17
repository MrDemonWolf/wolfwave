//
//  SongRequestSettingsView+PlaybackCommands.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

// Playback and chat-command cards for the Song Requests settings pane.

// MARK: - Playback

/// Hold, auto-advance, autoplay-when-empty, and the fallback playlist.
struct SongRequestPlaybackCard: View {
    /// Play the next request when a song ends. Changes ask the service to
    /// start or stop its playback monitor.
    @AppStorage(AppConstants.UserDefaults.songRequestAutoAdvance)
    private var autoAdvance = true

    /// Hand back to Apple Music autoplay when the queue runs dry.
    @AppStorage(AppConstants.UserDefaults.songRequestAutoplayWhenEmpty)
    private var autoplayWhenEmpty = true

    /// Exact Music playlist name to play when the queue is empty; blank = silence.
    @AppStorage(AppConstants.UserDefaults.songRequestFallbackPlaylist)
    private var fallbackPlaylist = ""

    /// Hold mode. Mirrors the queue view's Hold / Resume; changes go through
    /// `SongRequestService.setHold(_:)`.
    @AppStorage(AppConstants.UserDefaults.songRequestHoldEnabled)
    private var holdEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            Text("Playback")
                .font(.system(size: DSFont.Size.base, weight: .semibold))

            ToggleSettingRow(
                title: "Hold Queue",
                subtitle: "Requests still queue, but nothing plays until you resume",
                isOn: $holdEnabled,
                accessibilityLabel: "Hold the request queue",
                accessibilityIdentifier: "songRequests.holdEnabled",
                onChange: { enabled in
                    if let service = AppDelegate.shared?.songRequestService {
                        Task { await service.setHold(enabled) }
                    }
                }
            )

            ToggleSettingRow(
                title: "Auto-Advance Queue",
                subtitle: "Automatically play the next request when a song ends",
                isOn: $autoAdvance,
                accessibilityLabel: "Auto-advance queue",
                accessibilityIdentifier: "songRequests.autoAdvance",
                onChange: { _ in
                    AppDelegate.shared?.songRequestService?.reconcilePlaybackMonitoring()
                }
            )

            ToggleSettingRow(
                title: "Resume Autoplay When Empty",
                subtitle: "Let Apple Music's autoplay take over when the queue is empty",
                isOn: $autoplayWhenEmpty,
                accessibilityLabel: "Resume autoplay when queue is empty",
                accessibilityIdentifier: "songRequests.autoplayWhenEmpty"
            )

            Divider()

            VStack(alignment: .leading, spacing: DSSpace.s1h) {
                Text("Fallback playlist")
                    .font(.system(size: DSFont.Size.body, weight: .medium))
                TextField("e.g. Gaming Vibes", text: $fallbackPlaylist)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: DSFont.Size.body))
                VStack(alignment: .leading, spacing: DSSpace.s0) {
                    Text("Plays an Apple Music playlist when the queue is empty.")
                    Text("Type the playlist name exactly as it appears in Music.")
                    Text("Leave blank for silence.")
                }
                .font(.system(size: DSFont.Size.xs))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardStyle()
    }
}

// MARK: - Commands

/// Per-command switches and aliases for the song-request chat commands, the
/// `!sr` cooldowns, and the `!playlist` link status.
struct SongRequestCommandsCard: View {
    // Command switches (all default on except `!playlist`).
    @AppStorage(AppConstants.UserDefaults.srCommandEnabled) private var srCommandEnabled = true
    @AppStorage(AppConstants.UserDefaults.queueCommandEnabled) private var queueCommandEnabled = true
    @AppStorage(AppConstants.UserDefaults.myQueueCommandEnabled) private var myQueueCommandEnabled = true
    @AppStorage(AppConstants.UserDefaults.skipCommandEnabled) private var skipCommandEnabled = true
    @AppStorage(AppConstants.UserDefaults.clearQueueCommandEnabled) private var clearQueueCommandEnabled = true

    // Comma-separated extra triggers per command.
    @AppStorage(AppConstants.UserDefaults.srCommandAliases) private var srAliases = ""
    @AppStorage(AppConstants.UserDefaults.queueCommandAliases) private var queueAliases = ""
    @AppStorage(AppConstants.UserDefaults.myQueueCommandAliases) private var myQueueAliases = ""
    @AppStorage(AppConstants.UserDefaults.skipCommandAliases) private var skipAliases = ""
    @AppStorage(AppConstants.UserDefaults.clearQueueCommandAliases) private var clearQueueAliases = ""

    // `!sr` cooldowns, in seconds: channel-wide and per viewer.
    @AppStorage(AppConstants.UserDefaults.songRequestGlobalCooldown) private var globalCooldown: Double = 5.0
    @AppStorage(AppConstants.UserDefaults.songRequestUserCooldown) private var userCooldown: Double = 30.0

    // `!playlist` switch, aliases, and the public link it shares.
    @AppStorage(AppConstants.UserDefaults.songListCommandEnabled) private var songListCommandEnabled = false
    @AppStorage(AppConstants.UserDefaults.songListCommandAliases) private var songListAliases = ""
    @AppStorage(AppConstants.UserDefaults.songRequestSongListURL) private var songListURL = ""

    /// Opens the setup sheet's share step so the streamer can (re)configure the
    /// public !playlist link without leaving the pane.
    let onManageLink: () -> Void

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s6) {
            SectionHeaderWithStatus(
                title: "Song Request Commands",
                subtitle: "Toggle commands on/off and add custom aliases (comma-separated, without !).",
                prominence: .section
            )

            VStack(spacing: 1) {
                CommandSettingRow(
                    title: "!sr Command",
                    triggers: "!sr  ·  !request  ·  !songrequest",
                    isOn: $srCommandEnabled,
                    accessibilityLabel: "Enable song request command",
                    accessibilityIdentifier: "srCommandToggle",
                    cooldown: .init(global: $globalCooldown, user: $userCooldown),
                    aliases: $srAliases,
                    aliasPlaceholder: "e.g. play, add",
                    aliasAccessibilityIdentifier: "srCommandAliases"
                )

                CommandSettingRow(
                    title: "!queue Command",
                    triggers: "!queue  ·  !songlist  ·  !requests",
                    isOn: $queueCommandEnabled,
                    accessibilityLabel: "Enable queue command",
                    accessibilityIdentifier: "queueCommandToggle",
                    aliases: $queueAliases,
                    aliasPlaceholder: "e.g. q, upnext",
                    aliasAccessibilityIdentifier: "queueCommandAliases"
                )

                CommandSettingRow(
                    title: "!myqueue Command",
                    triggers: "!myqueue  ·  !mysongs",
                    isOn: $myQueueCommandEnabled,
                    accessibilityLabel: "Enable my queue command",
                    accessibilityIdentifier: "myQueueCommandToggle",
                    aliases: $myQueueAliases,
                    aliasPlaceholder: "e.g. mine, mysr",
                    aliasAccessibilityIdentifier: "myQueueCommandAliases"
                )

                CommandSettingRow(
                    title: "!skip Command",
                    triggers: "!skip  ·  !next  (mod only)",
                    isOn: $skipCommandEnabled,
                    accessibilityLabel: "Enable skip command",
                    accessibilityIdentifier: "skipCommandToggle",
                    aliases: $skipAliases,
                    aliasPlaceholder: "e.g. nextsong, ns",
                    aliasAccessibilityIdentifier: "skipCommandAliases"
                )

                CommandSettingRow(
                    title: "!clearqueue Command",
                    triggers: "!clearqueue  ·  !cq  (mod only)",
                    isOn: $clearQueueCommandEnabled,
                    accessibilityLabel: "Enable clear queue command",
                    accessibilityIdentifier: "clearQueueCommandToggle",
                    aliases: $clearQueueAliases,
                    aliasPlaceholder: "e.g. wipe, clearsr",
                    aliasAccessibilityIdentifier: "clearQueueCommandAliases"
                )

                CommandSettingRow(
                    title: "!playlist Command",
                    triggers: "!playlist  ·  links your request playlist",
                    isOn: $songListCommandEnabled,
                    accessibilityLabel: "Enable playlist link command",
                    accessibilityIdentifier: "songListCommandToggle",
                    aliases: $songListAliases,
                    aliasPlaceholder: "e.g. list, amplaylist",
                    aliasAccessibilityIdentifier: "songListCommandAliases",
                    isLast: true
                )
            }
            .cardStyleUnpadded()

            // Slim song-list link status. The full guided flow (open in Music,
            // share, fetch the link) now lives in the setup sheet; this row just
            // shows whether a link is set and offers a way back into that step.
            VStack(alignment: .leading, spacing: DSSpace.s2) {
                HStack {
                    Text("Song list link")
                        .font(.system(size: DSFont.Size.body, weight: .medium))
                    Spacer()
                    songListLinkChip
                    Button("Manage") { onManageLink() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("songRequests.manageSongList")
                }

                Text("!playlist drops a link to your requests playlist in chat. Set it up in the guided steps.")
                    .font(.system(size: DSFont.Size.xs))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HintRow("Cooldowns don't apply to you or your mods.")
        }
    }

    /// Song-list link status. "Ready" only for a link `!playlist` will
    /// actually post: `Preferences.songListURL` drops anything that doesn't
    /// normalize through `normalizedHTTPSURL`, so this chip does too.
    @ViewBuilder
    private var songListLinkChip: some View {
        let trimmed = songListURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            StatusChip(text: "Needs setup", color: DSColor.neutral, systemImage: StatusChip.StateGlyph.off)
        } else if Preferences.normalizedHTTPSURL(trimmed) == nil {
            StatusChip(text: "Invalid link", color: DSColor.warning, systemImage: StatusChip.StateGlyph.error)
        } else {
            StatusChip(text: "Ready", color: DSColor.success, systemImage: StatusChip.StateGlyph.on)
        }
    }
}
