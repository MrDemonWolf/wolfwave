//
//  MusicMonitorSettingsView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-01-13.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI
import AppKit

/// Music Sync section at the top of the General pane: the "Sync Music" master
/// toggle, the Music Automation permission row, the hero now-playing card, and
/// the integrations dashboard (whose Configure rows call `configure`).
///
/// When Apple Events automation has been denied for `com.apple.Music`, the
/// view adds `PermissionDeniedBanner` above the toggle, swaps the hero card
/// for `PermissionPausedNowPlayingCard`, and hides the inline permission row.
///
/// State is fed by notifications (now playing, Twitch / Discord / WebSocket
/// state, `musicPermissionDenied`) after an initial snapshot from
/// `AppDelegate.shared`; the permission is re-probed whenever the app becomes
/// active.
struct MusicMonitorSettingsView: View {

    // MARK: - Environment

    /// Drops the state-change animations when Reduce Motion is on.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - User Settings

    /// Master music-tracking switch. Changes also post `trackingSettingChanged`
    /// so the playback monitor starts or stops.
    @AppStorage(AppConstants.UserDefaults.trackingEnabled)
    private var trackingEnabled = true

    /// The "Show on Discord" switch. The dashboard reads Off from this, so a
    /// switched-off integration never looks like a failed connection.
    @AppStorage(AppConstants.UserDefaults.discordPresenceEnabled)
    private var discordPresenceEnabled = AppConstants.UserDefaults.Defaults.discordPresenceEnabled

    // MARK: - Music permission

    /// Last resolved Automation grant for Music. Starts `.unknown` until the
    /// first probe (or the session cache) answers.
    @State private var permissionState: MusicPermissionState = .unknown
    /// Presents `PermissionInstructionSheet`.
    @State private var showInstructionSheet = false
    /// Keeps the recovery banner up after a denial even if a later recheck
    /// lands on `.unknown` (for example Music closed), so the "Try again"
    /// feedback isn't yanked away. Cleared only by `.granted`.
    @State private var showPermissionRecovery = false
    /// True while the system Automation prompt is in flight ("Allow" spinner).
    @State private var isRequesting = false

    // MARK: - Now playing

    /// Now-playing snapshot for the hero card. `nil` track means nothing is
    /// playing (or Music is closed).
    @State private var currentTrack: String?
    @State private var currentArtist: String?
    @State private var currentAlbum: String?
    /// Artwork resolved by `ArtworkService`; retain the previous URL while the
    /// next track lookup is pending, then replace it (or clear a resolved miss).
    @State private var currentArtworkURL: URL?
    @State private var currentIsPaused: Bool = false

    // MARK: - Integration status

    /// Dashboard inputs. Seeded by `loadIntegrationStatuses()`, then kept
    /// current by the service state notifications. The lifecycle enums are kept
    /// whole (not collapsed to a Bool) so the dashboard can show Connecting,
    /// Starting, and a failed server.
    @State private var twitchConnected = false
    @State private var twitchChannel: String?
    @State private var discordState: DiscordRPCService.ConnectionState = .disconnected
    @State private var serverState: WebSocketServerService.ServerState = .stopped

    // MARK: - Inputs

    /// Routes a dashboard "Configure" row to its settings pane (supplied by
    /// `SettingsView` through `GeneralSettingsView`).
    var configure: (IntegrationDashboardView.Section) -> Void = { _ in }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: AppConstants.SettingsUI.sectionSpacing) {

            if permissionState == .denied || showPermissionRecovery {
                PermissionDeniedBanner(
                    onOpenSystemSettings: { MusicPermissionChecker.openAutomationSettings() },
                    onTryAgain: refreshPermission,
                    onShowInstructions: { showInstructionSheet = true }
                )
            }

            // Master toggle + permission row
            VStack(alignment: .leading, spacing: 0) {
                ToggleSettingRow(
                    title: "Sync Music",
                    subtitle: "When this is on, your Apple Music shows up in chat, on Discord, and in your stream.",
                    isOn: $trackingEnabled,
                    accessibilityLabel: "Toggle Sync Music",
                    accessibilityIdentifier: "musicTrackingToggle",
                    onChange: { newValue in
                        notifyTrackingSettingChanged(enabled: newValue)
                    }
                )
                .padding(AppConstants.SettingsUI.cardPadding)

                // When access is denied the recovery card above already owns the
                // explanation + CTA, so hide this row to avoid repeating it.
                // Granted/unknown keep it inline (status + in-context Allow).
                if permissionState != .denied {
                    Divider().padding(.horizontal, AppConstants.SettingsUI.cardPadding)

                    permissionStatusRow
                        .padding(AppConstants.SettingsUI.cardPadding)
                }
            }
            .cardStyleUnpadded()

            // Hero now-playing
            VStack(alignment: .leading, spacing: DSSpace.s2) {
                Text("Live from Apple Music")
                    .sectionEyebrow()
                    .accessibilityAddTraits(.isHeader)

                if permissionState == .denied {
                    PermissionPausedNowPlayingCard()
                } else {
                    NowPlayingHeroCard(
                        track: currentTrack,
                        artist: currentArtist,
                        album: currentAlbum,
                        artworkURL: currentArtworkURL,
                        trackingEnabled: trackingEnabled,
                        isPaused: currentIsPaused,
                        // Read at render time. The card only re-renders when the
                        // track changes, and Music quitting drives the track to
                        // nil, so the flag is evaluated exactly when it matters.
                        musicNotRunning: currentTrack == nil && !MusicProcess.isRunning,
                        onOpenMusic: { Task { await MusicPermissionChecker.ensureMusicRunning() } }
                    )
                }
            }

            // Integration dashboard
            IntegrationDashboardView(
                twitchConnected: twitchConnected,
                twitchChannel: twitchChannel,
                discordEnabled: discordPresenceEnabled,
                discordState: discordState,
                serverState: serverState,
                widgetURL: WidgetLink.loopback,
                permissionPaused: permissionState == .denied,
                configure: configure
            )
        }
        .sheet(isPresented: $showInstructionSheet) {
            PermissionInstructionSheet(
                onOpenSystemSettings: {
                    MusicPermissionChecker.openAutomationSettings()
                },
                onTryAgain: refreshPermission
            )
        }
        .task {
            // Yield so the first frame paints before we read services / system state.
            await Task.yield()
            // Permission check is the costliest read, reuse the session cache when fresh.
            if let cached = MusicPermissionCache.read() {
                permissionState = cached
            } else {
                _ = await refreshPermission()
            }
            loadCurrentTrack()
            if permissionState == .granted {
                AppDelegate.shared?.refreshNowPlaying()
            }
            await loadIntegrationStatuses()
        }
        .onReceive(NotificationCenter.default.publisher(for: .nowPlayingChanged)) { notification in
            let payload = notification.nowPlaying
            // The source re-emits the same track ~every 5s. Only the track
            // identity change needs another artwork lookup; a pause flip updates
            // in place. Keep the old cover until the next lookup resolves.
            let trackChanged = currentTrack != payload.track || currentArtist != payload.artist
            withMotionSafeAnimation(.easeInOut(duration: DSMotion.Duration.base), reduceMotion: reduceMotion) {
                currentTrack = payload.track
                currentArtist = payload.artist
                currentAlbum = payload.album
                currentIsPaused = payload.isPaused
            }
            // A successful track read implies the user has granted access.
            if currentTrack != nil, permissionState == .denied {
                MusicPermissionCache.write(.granted)
                permissionState = .granted
            }
            if trackChanged { fetchArtwork() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .twitchConnectionStateChanged)) { notification in
            withMotionSafeAnimation(.easeInOut(duration: DSMotion.Duration.base), reduceMotion: reduceMotion) {
                twitchConnected = notification.isConnectedFlag ?? false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .discordStateChanged)) { notification in
            withMotionSafeAnimation(.easeInOut(duration: DSMotion.Duration.base), reduceMotion: reduceMotion) {
                discordState = notification.stateString
                    .flatMap(DiscordRPCService.ConnectionState.init(rawValue:)) ?? .disconnected
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .websocketServerStateChanged)) { notification in
            withMotionSafeAnimation(.easeInOut(duration: DSMotion.Duration.base), reduceMotion: reduceMotion) {
                serverState = notification.stateString
                    .flatMap(WebSocketServerService.ServerState.init(rawValue:)) ?? .stopped
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { _ = await refreshPermission() }
        }
        .onChange(of: permissionState) { _, next in
            // A closed Music app must not remove the recheck's unknown-state feedback.
            if next == .denied { showPermissionRecovery = true }
            if next == .granted {
                showPermissionRecovery = false
                showInstructionSheet = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .musicPermissionDenied)) { _ in
            // The data path detected that Music.app is running but ScriptingBridge
            // reads return nil, the canonical TCC Automation denial. Flip the
            // banner immediately and persist so other tabs see it too.
            MusicPermissionCache.write(.denied)
            withMotionSafeAnimation(.easeInOut(duration: DSMotion.Duration.base), reduceMotion: reduceMotion) {
                permissionState = .denied
            }
        }
    }

    // MARK: - Permission status row

    /// Keep action labels intact; explanatory text and actions stack in narrow panes.
    private var permissionStatusRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DSSpace.s4) {
                permissionSummary
                Spacer(minLength: DSSpace.s2)
                permissionTrailingControl
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(minWidth: permissionSubtitle == nil ? nil : DSDimension.Settings.inlineActionsMinWidth)

            VStack(alignment: .leading, spacing: DSSpace.s3) {
                permissionSummary
                permissionTrailingControl
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private var permissionSummary: some View {
        HStack(spacing: DSSpace.s4) {
            Image(systemName: permissionIconName)
                .font(.system(size: DSFont.Size.md, weight: .semibold))
                .foregroundStyle(permissionIconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: DSSpace.s0) {
                Text(permissionTitle)
                    .font(.system(size: DSFont.Size.base, weight: .medium))
                if let subtitle = permissionSubtitle {
                    Text(subtitle)
                        .font(.system(size: DSFont.Size.sm))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Granted: a quiet Recheck. Denied: Open System Settings. Unknown: Allow
    /// (triggers the system prompt) plus a manual Open Settings fallback.
    @ViewBuilder
    private var permissionTrailingControl: some View {
        switch permissionState {
        case .granted:
            grantedRecheckControl

        case .denied:
            Button("Open System Settings") {
                MusicPermissionChecker.openAutomationSettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityLabel("Open System Settings")
            .accessibilityHint("Opens Privacy and Security to grant Apple Music access")
            .accessibilityIdentifier("musicMonitor.openSystemSettingsButton")

        case .unknown:
            HStack(spacing: DSSpace.s1h) {
                Button(action: requestPermission) {
                    HStack(spacing: DSSpace.s1h) {
                        if isRequesting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                        }
                        Text("Allow")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isRequesting)
                .accessibilityLabel("Allow Apple Music access")
                .accessibilityHint("Prompts macOS for automation permission so the current track can be read")
                .accessibilityIdentifier("musicMonitor.allowButton")

                Button("Open Settings") {
                    MusicPermissionChecker.openAutomationSettings()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Open System Settings")
                .accessibilityHint("Opens Privacy and Security to grant Apple Music access manually")
                .accessibilityIdentifier("musicMonitor.openSettingsButton")
            }
        }
    }

    /// Quiet "Recheck" for the granted state. `AsyncActionButton` owns the
    /// spinner, the double-tap guard, and the brief checkmark, so a recheck
    /// that changes nothing (the common case) still shows it ran. If the grant
    /// is gone, `permissionState` changes and this control leaves the row.
    private var grantedRecheckControl: some View {
        AsyncActionButton(
            title: "Recheck",
            style: .borderless,
            successDuration: 1.2,
            accessibilityIdentifier: "musicMonitor.recheckButton"
        ) {
            _ = await refreshPermission()
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("Recheck Apple Music access")
        .accessibilityHint("Re-queries macOS for the current automation permission state")
    }

    /// SF Symbol for the permission row; a lock only when denied.
    private var permissionIconName: String {
        switch permissionState {
        case .granted: return "music.note"
        case .denied: return "lock.fill"
        case .unknown: return "music.note"
        }
    }

    /// Tint for the permission row icon.
    private var permissionIconColor: Color {
        switch permissionState {
        case .granted: return AppConstants.Brand.appleMusicGradientEnd
        case .denied: return DSColor.error
        case .unknown: return .accentColor
        }
    }

    /// Headline for the permission row.
    private var permissionTitle: String {
        switch permissionState {
        case .granted: return "Music access on"
        case .denied: return "Music access off"
        case .unknown: return "Allow Music access"
        }
    }

    /// Supporting line for the permission row; `nil` when granted (nothing to say).
    private var permissionSubtitle: String? {
        switch permissionState {
        case .granted: return nil
        case .denied: return "Turn on Automation → Music in System Settings."
        case .unknown: return "macOS will ask once. It lets WolfWave read the track and control playback."
        }
    }

    // MARK: - Helpers

    /// Re-queries Apple Music automation permission off the main actor, caches
    /// the result, and reloads the current track if permission is now granted.
    /// The Apple Events probe can take tens of milliseconds, keep it off main.
    private func refreshPermission() async -> MusicPermissionState {
        let next = await MusicPermissionChecker.recheck()
        MusicPermissionCache.write(next)
        withMotionSafeAnimation(.easeInOut(duration: DSMotion.Duration.base), reduceMotion: reduceMotion) {
            permissionState = next
        }
        if next == .granted {
            loadCurrentTrack()
            AppDelegate.shared?.refreshNowPlaying()
        }
        return next
    }

    /// Prompts the user for Apple Music automation permission, animates the
    /// resolution, and pulls the current track on success.
    private func requestPermission() {
        isRequesting = true
        Task {
            let resolved = await MusicPermissionChecker.requestAccess()
            await MainActor.run {
                // Refresh the process-local cache so re-entering the pane within
                // the TTL reflects the just-granted/denied result, not a stale
                // earlier probe.
                MusicPermissionCache.write(resolved)
                withMotionSafeAnimation(.easeInOut(duration: DSMotion.Duration.base), reduceMotion: reduceMotion) {
                    permissionState = resolved
                }
                isRequesting = false
                if resolved == .granted {
                    loadCurrentTrack()
                }
            }
        }
    }

    /// Snapshots the currently-playing track from `AppDelegate` into the
    /// view's state so the "Now Playing" preview reflects live playback.
    private func loadCurrentTrack() {
        if let appDelegate = AppDelegate.shared {
            currentTrack = appDelegate.currentSong
            currentArtist = appDelegate.currentArtist
            currentAlbum = appDelegate.currentAlbum
            currentIsPaused = appDelegate.currentIsPaused
        }
        fetchArtwork()
    }

    /// Fetches artwork for the current track from `ArtworkService` and stores
    /// the resolved URL. Called on initial load and on every track change.
    private func fetchArtwork() {
        guard let track = currentTrack, let artist = currentArtist else {
            currentArtworkURL = nil
            return
        }
        ArtworkService.shared.fetchTrackLinks(track: track, artist: artist) { links in
            Task { @MainActor in
                // A different track can arrive while the shared lookup is in flight.
                // Check after the actor hop, immediately before publishing its result.
                guard currentTrack == track, currentArtist == artist else { return }
                currentArtworkURL = links.artworkURL.flatMap(URL.init(string:))
            }
        }
    }

    /// Loads connection status for Twitch / Discord / overlay from the
    /// running services so the integration row chips reflect reality.
    private func loadIntegrationStatuses() async {
        guard let appDelegate = AppDelegate.shared else { return }
        twitchConnected = appDelegate.twitchService?.currentlyConnected ?? false
        serverState = appDelegate.websocketServer?.state ?? .stopped
        discordState = appDelegate.discordService?.stateSnapshot ?? .disconnected
        let snapshot = await TwitchCredentialStore.shared.loadConnectionSnapshot()
        guard !Task.isCancelled else { return }
        twitchChannel = snapshot?.channelID
    }

    /// Posts a `trackingSettingChanged` notification so the music monitor
    /// starts or stops based on the user's toggle.
    ///
    /// - Parameter enabled: New tracking value.
    private func notifyTrackingSettingChanged(enabled: Bool) {
        NotificationCenter.default.postEnabled(.trackingSettingChanged, enabled: enabled)
    }
}

// MARK: - Permission cache

/// Process-lifetime cache for the Music automation permission result.
///
/// `MusicPermissionChecker.currentState()` issues an Apple Events probe that can take tens of
/// milliseconds, measurable when switching back to the General settings pane. Cache the result
/// for a short window so re-entering the pane within the same session is instant. The cache is
/// refreshed (overwritten) on `NSApplication.didBecomeActiveNotification`, by explicit
/// rechecks, and by the `musicPermissionDenied` signal.
///
/// MainActor-isolated (module default). Every caller already runs on main, so
/// this is race-free and turns any future off-main use into a compile error
/// instead of a silent data race on the `value`/`storedAt` pair (the previous
/// `nonisolated(unsafe)` markers disabled the compiler's race checking).
@MainActor
enum MusicPermissionCache {
    /// Freshness window, in seconds.
    private static let ttl: TimeInterval = 30
    /// Cached state; meaningful only alongside `storedAt`.
    private static var value: MusicPermissionState?
    /// When `value` was written.
    private static var storedAt: Date?

    /// The cached state, or `nil` if nothing was written or it is older than `ttl`.
    static func read() -> MusicPermissionState? {
        guard let value, let storedAt, Date().timeIntervalSince(storedAt) < ttl else { return nil }
        return value
    }

    /// Stores `state` and restarts the freshness window.
    static func write(_ state: MusicPermissionState) {
        value = state
        storedAt = Date()
    }
}

// MARK: - Preview

#Preview("Granted, playing") {
    MusicMonitorSettingsView()
        .padding()
        .frame(width: 720)
        .onAppear {
            NotificationCenter.default.postNowPlaying(
                track: "Moonlit Howl",
                artist: "Arctic Wolf",
                album: "Tundra Sessions"
            )
        }
}

#Preview("Empty") {
    MusicMonitorSettingsView()
        .padding()
        .frame(width: 720)
}
