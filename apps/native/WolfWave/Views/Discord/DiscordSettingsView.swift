//
//  DiscordSettingsView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-02-07.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import SwiftUI

/// Settings for Discord Rich Presence integration.
///
/// Cards, top to bottom (everything below Connection only shows once presence
/// is enabled and a client ID is configured):
///   1. **Connection**: header + status chip, enable toggle, not-configured banner.
///   2. **Buttons**: master toggle plus per-button enable + URL preview.
///   3. **Playlist**: show the source playlist, display style, name privacy.
///   4. **Behavior**: what the profile shows when stopped or paused.
///   5. **Preview**: mock Discord activity card driven by current settings.
///
/// The enable toggle posts `discordPresenceChanged`; every other setting change
/// is debounced into one `discordPresenceSettingsChanged` so `DiscordRPCService`
/// re-sends the presence with the new options. The preview reuses
/// `DiscordPresenceBuilder` so it can't disagree with the real payload.
struct DiscordSettingsView: View {
    // MARK: - User Settings

    /// Master Rich Presence switch.
    @AppStorage(AppConstants.UserDefaults.discordPresenceEnabled)
    var presenceEnabled = false

    /// Master switch for both profile buttons.
    @AppStorage(AppConstants.UserDefaults.discordButtonsEnabled)
    var buttonsEnabled = true

    /// "Listen on Apple Music" button.
    @AppStorage(AppConstants.UserDefaults.discordButton1Enabled)
    var button1Enabled = true

    /// Cross-service song.link button.
    @AppStorage(AppConstants.UserDefaults.discordButton2Enabled)
    var button2Enabled = true

    /// Include the source playlist in the presence.
    @AppStorage(AppConstants.UserDefaults.discordPlaylistEnabled)
    var playlistEnabled = false

    /// Show the real playlist name; off substitutes a generic label.
    @AppStorage(AppConstants.UserDefaults.discordPlaylistShowName)
    var playlistShowName = true

    /// Where the playlist appears: on the state line or in the icon tooltip.
    @AppStorage(AppConstants.UserDefaults.discordPlaylistStyle)
    var playlistStyle: DiscordPlaylistStyle = .default

    /// Keep an idle "Listening to WolfWave" activity instead of clearing.
    @AppStorage(AppConstants.UserDefaults.discordShowIdleStatus)
    var showIdleStatus = true

    /// Clear the track (rather than show it paused) while playback is paused.
    @AppStorage(AppConstants.UserDefaults.discordClearWhilePaused)
    var clearWhilePaused = false

    // MARK: - State

    /// Section and status transitions collapse under Reduce Motion.
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    /// Last known IPC state, from `discordStateChanged` plus a 10-second poll
    /// of the service (see `.task` in `body`).
    @State var connectionState: DiscordRPCService.ConnectionState = .disconnected

    /// Why the last connect attempt failed. Drives the status chip wording and
    /// the error banner, so a rejected handshake stops reading as "not running".
    @State var connectionFailure: DiscordRPCService.ConnectionFailure = .none
    /// Whether this build has a Discord client ID. Without one, presence can't
    /// be enabled and only the "Not configured" banner shows.
    @State var hasClientID = false
    /// Latest track for the preview and button URLs. Starts as `.sample`, which
    /// is never rendered as a track because `playbackMode` starts empty.
    @State var nowPlaying: NowPlayingSnapshot = .sample
    /// What the preview card represents, driven by live playback notifications.
    /// Seeded from Apple Music's running state on appear, then kept in sync by
    /// `.nowPlayingChanged` (track present / paused / nil) and the Discord
    /// connection state.
    @State private var playbackMode: DiscordPreviewCard.Mode = .stopped
    /// Pending debounced settings re-send; replaced on each change.
    @State private var settingsChangedTask: Task<Void, Never>?

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: AppConstants.SettingsUI.sectionSpacing) {
            connectionSection
                .deepLinkSection("presence")
            if presenceEnabled && hasClientID {
                // Controls on the left, live preview on the right. ResponsiveRow
                // collapses to a single stacked column on narrow windows.
                ResponsiveRow {
                    VStack(alignment: .leading, spacing: DSSpace.s6) {
                        buttonsSection
                            .deepLinkSection("buttons")
                        playlistSection
                            .deepLinkSection("playlist")
                        behaviorSection
                            .deepLinkSection("behavior")
                    }
                } right: {
                    previewSection
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.base), value: presenceEnabled)
        .animation(reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.base), value: playlistEnabled)
        .onAppear {
            hasClientID = DiscordRPCService.resolveClientID() != nil
            refreshConnectionState()
            // Seed an honest empty state immediately, then ask the active source
            // to rebroadcast so a live/paused track populates within a poll tick.
            playbackMode = isAppleMusicRunning() ? .stopped : .musicClosed
            AppDelegate.shared?.refreshNowPlaying()
        }
        .task {
            // Re-read the live Discord connection on a cadence so the status chip
            // stays honest on its own (catches a missed state notification or a
            // drop while the pane sits open). Replaces the manual "Check Discord"
            // button. Auto-cancels when the pane goes away.
            while !Task.isCancelled {
                refreshConnectionState()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name.discordStateChanged
            )
        ) { notification in
            if let rawValue = notification.stateString {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.base)) {
                    switch rawValue {
                    case "connected":   connectionState = .connected
                    case "connecting":  connectionState = .connecting
                    default:            connectionState = .disconnected
                    }
                    connectionFailure = (notification.errorMessage)
                        .flatMap(DiscordRPCService.ConnectionFailure.init(rawValue:)) ?? .none
                }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name.nowPlayingChanged
            )
        ) { notification in
            updateNowPlaying(from: notification)
        }
        .onChange(of: buttonsEnabled) { _, _ in scheduleSettingsResend() }
        .onChange(of: button1Enabled) { _, _ in scheduleSettingsResend() }
        .onChange(of: button2Enabled) { _, _ in scheduleSettingsResend() }
        .onChange(of: playlistEnabled) { _, _ in scheduleSettingsResend() }
        .onChange(of: playlistShowName) { _, _ in scheduleSettingsResend() }
        .onChange(of: playlistStyle) { _, _ in scheduleSettingsResend() }
        .onChange(of: showIdleStatus) { _, _ in scheduleSettingsResend() }
        .onChange(of: clearWhilePaused) { _, _ in scheduleSettingsResend() }
    }

    // MARK: - Preview State

    /// The mode the preview card renders. A disconnected Discord client wins
    /// over playback state. There's no profile to show music on. Otherwise the
    /// live playback mode is mapped through the two behavior toggles: a paused
    /// track can be hidden, and any "no track" state can fall back to the opt-in
    /// idle activity instead of an empty card.
    var previewMode: DiscordPreviewCard.Mode {
        if connectionState == .disconnected { return .discordOffline }
        switch playbackMode {
        case .playing:
            return .playing
        case .paused:
            return clearWhilePaused ? clearedPreviewMode(whenMusicClosed: false) : .paused
        case .stopped:
            return clearedPreviewMode(whenMusicClosed: false)
        case .musicClosed:
            return clearedPreviewMode(whenMusicClosed: true)
        case .discordOffline, .idleActivity:
            return playbackMode
        }
    }

    /// What the profile shows with no track: the opt-in idle activity, or the
    /// matching empty state.
    private func clearedPreviewMode(whenMusicClosed: Bool) -> DiscordPreviewCard.Mode {
        if showIdleStatus { return .idleActivity }
        return whenMusicClosed ? .musicClosed : .stopped
    }

    /// Preview header chip label for `previewMode`.
    var previewStatusText: String {
        switch previewMode {
        case .playing:        return "Live"
        case .paused:         return "Paused"
        case .stopped:        return "Idle"
        case .musicClosed:    return "Idle"
        case .idleActivity:   return "Idle"
        case .discordOffline: return "Offline"
        }
    }

    /// Preview header chip tint for `previewMode`.
    var previewStatusColor: Color {
        switch previewMode {
        case .playing:        return DSColor.success
        case .paused:         return DSColor.warning
        case .stopped,
             .musicClosed,
             .idleActivity,
             .discordOffline: return DSColor.neutral
        }
    }

    // MARK: - Playlist Preview Helpers

    /// Resolves the playlist for the preview using the same logic as the live presence.
    private var playlistDisplay: DiscordPresenceBuilder.PlaylistDisplay? {
        DiscordPresenceBuilder.resolvePlaylistDisplay(
            playlist: nowPlaying.playlist,
            album: nowPlaying.album,
            defaults: DefaultsStore.store
        )
    }

    /// The activity state line (line 2) as the live presence would render it.
    var previewStateLine: String {
        DiscordPresenceBuilder.stateLine(
            artist: nowPlaying.artist,
            playlist: playlistDisplay,
            style: playlistStyle
        )
    }

    /// The small-icon tooltip text, or nil when the playlist isn't shown there.
    var previewPlaylistTooltip: String? {
        guard playlistStyle == .iconTooltip, playlistDisplay != nil else { return nil }
        return DiscordPresenceBuilder.smallText(playlist: playlistDisplay, style: playlistStyle)
    }

    /// Caption describing where the chosen style surfaces the playlist.
    var playlistStyleSubtitle: String {
        switch playlistStyle {
        case .artistLine:  return "Shown next to the artist"
        case .iconTooltip: return "Shown when hovering the app icon"
        }
    }

    // MARK: - Helpers

    /// Compact title used by the grouped control cards in the two-column layout,
    /// where the single page header carries the one status chip.
    @ViewBuilder
    func cardTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.s0) {
            Text(title)
                .font(.system(size: DSFont.Size.base, weight: .semibold))
            Text(subtitle)
                .font(.system(size: DSFont.Size.sm))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Pane header chip label. While enabled but disconnected it names the
    /// actual failure; with no failure recorded yet it reads "Connecting".
    var statusChipText: String {
        switch connectionState {
        case .connected:    return "Connected"
        case .connecting:   return "Connecting"
        case .disconnected:
            guard presenceEnabled else { return "Disconnected" }
            // "Discord not running" used to be asserted for every failure,
            // including a rejected handshake with Discord open on screen.
            switch connectionFailure {
            case .notRunning:          return "Discord not running"
            case .none:                return "Connecting"
            case .handshakeRejected:    return "Refused"
            case .socketUnavailable:    return "Blocked"
            case .notConfigured:        return "Not configured"
            }
        }
    }

    /// Pane header chip tint, matching `statusChipText`.
    var statusChipColor: Color {
        switch connectionState {
        case .connected:    return DSColor.success
        case .connecting:   return DSColor.warning
        case .disconnected: return presenceEnabled && connectionFailure == .none ? DSColor.warning : DSColor.neutral
        }
    }

    /// Builds a preview pill through the same `resolveButton` the live presence
    /// uses, so label overrides and URL validation (e.g. a `javascript:` URL
    /// is dropped) match exactly. Static for tests.
    ///
    /// - Returns: `nil` when the button is disabled or its URL is unusable.
    static func previewButton(
        index: Int,
        url: String?,
        defaults: UserDefaults
    ) -> DiscordPreviewCard.PreviewButton? {
        guard let button = DiscordPresenceBuilder.resolveButton(index: index, url: url, defaults: defaults),
              let label = button["label"], let url = button["url"] else { return nil }
        return .init(label: label, url: url)
    }

    /// Reads the service's actor-isolated state on a task. With no service
    /// (presence never started) the state is `.disconnected`.
    private func refreshConnectionState() {
        guard let service = AppDelegate.shared?.discordService else {
            connectionState = .disconnected
            return
        }
        Task { @MainActor in
            connectionState = await service.state
        }
    }

    /// Maps a `nowPlayingChanged` payload to the preview: a track updates
    /// `nowPlaying` (links come from the artwork cache only, never a fetch) and
    /// sets playing / paused; no track sets stopped or Music closed.
    private func updateNowPlaying(from notification: Notification) {
        let payload = notification.nowPlaying
        guard let track = payload.track, let artist = payload.artist else {
            // No track in the payload: playback stopped, or Apple Music quit.
            // Mirror the live presence, which clears the profile in both cases.
            withAnimation(reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.base)) {
                playbackMode = isAppleMusicRunning() ? .stopped : .musicClosed
            }
            return
        }
        let album = payload.album ?? ""
        let playlist = payload.playlist ?? ""
        let links = ArtworkService.shared.cachedTrackLinks(track: track, artist: artist)
        nowPlaying = NowPlayingSnapshot(
            track: track,
            artist: artist,
            album: album,
            playlist: playlist,
            artworkURL: links.artworkURL,
            appleMusicURL: links.trackViewURL,
            songLinkURL: links.songLinkURL
        )
        withAnimation(reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.base)) {
            playbackMode = payload.isPaused ? .paused : .playing
        }
    }

    /// `true` when Apple Music is currently running, used to tell a stopped
    /// track apart from a quit app for the preview's empty state.
    private func isAppleMusicRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.Music"
        }
    }

    /// Posts `discordPresenceChanged` so the app delegate connects or
    /// disconnects Rich Presence.
    func notifyPresenceSettingChanged(enabled: Bool) {
        NotificationCenter.default.postEnabled(.discordPresenceChanged, enabled: enabled)
    }

    /// Debounce notification by 300ms so rapid typing/toggling doesn't spam the socket.
    private func scheduleSettingsResend() {
        settingsChangedTask?.cancel()
        settingsChangedTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            NotificationCenter.default.post(
                name: Notification.Name.discordPresenceSettingsChanged,
                object: nil
            )
        }
    }
}

// MARK: - NowPlayingSnapshot

/// Lightweight view-local snapshot of the currently playing track for previewing.
struct NowPlayingSnapshot {
    let track: String
    let artist: String
    let album: String
    let playlist: String
    /// Cached links for the track (`ArtworkService.cachedTrackLinks`); each is
    /// `nil` until that lookup has completed for this track.
    let artworkURL: String?
    let appleMusicURL: String?
    let songLinkURL: String?

    /// Placeholder used before the first track arrives. Invented track with a
    /// wolf-species "artist", like every other demo: never real music metadata.
    static let sample = NowPlayingSnapshot(
        track: "Moonlit Howl",
        artist: "Arctic Wolf",
        album: "Tundra Sessions",
        playlist: "Chill Saturday",
        artworkURL: nil,
        appleMusicURL: nil,
        songLinkURL: nil
    )
}

// MARK: - Preview

#Preview("Disconnected") {
    DiscordSettingsView()
        .padding()
        .frame(width: 600)
}

#Preview("Connected") {
    let view = DiscordSettingsView()
    return view
        .padding()
        .frame(width: 600)
        .onAppear {
            NotificationCenter.default.postDiscordState("connected")
        }
}
