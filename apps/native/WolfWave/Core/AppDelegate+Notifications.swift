//
//  AppDelegate+Notifications.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import Foundation

// MARK: - Notification Observers

/// Registration of every app-lifetime `NotificationCenter` observer. Tokens
/// accumulate in `notificationObservers` and are removed at termination.
extension AppDelegate {

    /// Registers a `NotificationCenter` observer that runs `handler` on the main
    /// actor and stores the token in `notificationObservers` for teardown.
    ///
    /// Collapses the repeated `queue: .main` + `nonisolated(unsafe) let n` +
    /// `MainActor.assumeIsolated` incantation shared by every settings/system
    /// observer. `queue: .main` guarantees the block runs on the main thread,
    /// which is what keeps `assumeIsolated` sound. Observers with custom bodies
    /// (window-close filtering, notifications dropped with `_`) stay inline.
    func observeOnMain(
        _ name: NSNotification.Name,
        center: NotificationCenter = .default,
        _ handler: @escaping @MainActor (Notification) -> Void
    ) {
        notificationObservers.append(
            center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { notification in
                nonisolated(unsafe) let n = notification
                MainActor.assumeIsolated { handler(n) }
            }
        )
    }

    /// Registers all `NotificationCenter` observers for settings and system
    /// events, and installs the user-notification center delegate.
    func setupNotificationObservers() {
        // Present WolfWave banners while the app is frontmost. Without a
        // `UNUserNotificationCenterDelegate`, macOS suppresses every banner
        // for the foreground app, exactly when the user is in Settings
        // flipping the notification toggles and expecting a preview.
        NotificationService.shared.installCenterDelegate()

        let nc = NotificationCenter.default

        observeOnMain(NSWorkspace.didWakeNotification, center: NSWorkspace.shared.notificationCenter) { [weak self] _ in
            Task { await self?.twitchService?.handleSystemWake() }
        }

        observeOnMain(Notification.Name.trackingSettingChanged) { [weak self] n in
            self?.trackingSettingChanged(n)
        }
        observeOnMain(Notification.Name.dockVisibilityChanged) { [weak self] n in
            self?.dockVisibilityChanged(n)
        }

        // Custom body — kept inline. Onboarding and What's New are handled by
        // their own `windowWillClose` delegate. Every other closing window,
        // including SwiftUI's Settings scene window, falls through here to
        // restore menu-only mode.
        notificationObservers.append(
            nc.addObserver(
                forName: NSWindow.willCloseNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                nonisolated(unsafe) let n = notification
                MainActor.assumeIsolated {
                    guard let self,
                          let window = n.object as? NSWindow,
                          window !== self.onboardingWindow,
                          window !== self.whatsNewWindow else { return }
                    self.restoreMenuOnlyIfNeeded()
                }
            }
        )

        observeOnMain(Notification.Name.discordPresenceChanged) { [weak self] n in
            self?.discordPresenceSettingChanged(n)
        }
        observeOnMain(Notification.Name.websocketServerChanged) { [weak self] n in
            self?.websocketServerSettingChanged(n)
        }
        observeOnMain(Notification.Name.widgetHTTPServerChanged) { [weak self] n in
            self?.widgetHTTPServerSettingChanged(n)
        }
        observeOnMain(Notification.Name.updateStateChanged) { [weak self] n in
            self?.handleUpdateStateChanged(n)
        }
        observeOnMain(Notification.Name.songRequestSettingChanged) { [weak self] n in
            self?.songRequestSettingChanged(n)
        }
        observeOnMain(Notification.Name.voteSkipPollsSettingChanged) { [weak self] n in
            self?.voteSkipPollsSettingChanged(n)
        }
        observeOnMain(Notification.Name.listeningHistorySettingChanged) { [weak self] n in
            self?.listeningHistorySettingChanged(n)
        }
        observeOnMain(Notification.Name.iCloudSettingsSyncSettingChanged) { [weak self] n in
            guard let enabled = n.enabledFlag else { return }
            self?.settingsSyncService?.setEnabled(enabled)
        }
        observeOnMain(Notification.Name.twitchConnectionStateChanged) { [weak self] n in
            self?.twitchConnectionStateChanged(n)
        }
        observeOnMain(Notification.Name.twitchReauthNeededChanged) { [weak self] _ in
            guard let self else { return }
            if Preferences.twitchReauthNeeded {
                self.cancelTwitchBootValidation()
            } else if self.twitchBootValidationTask == nil {
                self.restartTwitchTokenValidationSchedule()
            }
        }

        // Custom bodies (they drop the notification payload) — kept inline.
        // Refresh the Stream Deck queue-counter / health broadcasts whenever the
        // request queue or hold state changes, so counter and hold keys stay
        // live without polling.
        //
        // Hold matters as much as the counts here: hold is togglable from the
        // tray, chat (`!hold`), and Settings, so a Stream Deck key that only
        // learned about its own presses would show the wrong state the moment
        // hold changed anywhere else.
        for name in [
            Notification.Name.songRequestQueueChanged,
            Notification.Name.songRequestHoldChanged
        ] {
            notificationObservers.append(
                nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.broadcastStreamDeckState() }
                }
            )
        }
    }
}

// MARK: - Notification Handlers

/// Handlers for settings and system notifications. All run on the main actor
/// (delivered via `observeOnMain`); async service work is hopped into a `Task`.
extension AppDelegate {

    /// Starts or stops the music monitor when the tracking toggle changes.
    @objc func trackingSettingChanged(_ notification: Notification) {
        guard let enabled = notification.enabledFlag else { return }
        if enabled {
            appleMusicSource?.startTracking()
        } else {
            stopTrackingAndUpdate()
        }
    }

    /// Pokes the active playback source to broadcast a fresh now-playing
    /// snapshot. Safe to call from the UI; no-ops if tracking is disabled.
    @MainActor
    func refreshNowPlaying() {
        appleMusicSource?.forceRefresh()
    }

    /// Stops the music monitor and clears the now-playing display.
    private func stopTrackingAndUpdate() {
        appleMusicSource?.stopTracking()
        clearPlaybackStateAndOutputs()
    }

    /// Canonical no-track transition shared by source failure and the user
    /// disabling Music Sync. Clears every cached/output surface together.
    func clearPlaybackStateAndOutputs() {
        flushCurrentPlayToHistoryOnce()
        currentSong = nil
        currentArtist = nil
        currentAlbum = nil
        currentPlaylist = nil
        currentDuration = 0
        currentElapsed = 0
        currentIsPaused = false
        postNowPlayingUpdate(song: nil, artist: nil, album: nil)
        applyDiscordCleared()
        Task { [weak self] in await self?.websocketServer?.clearNowPlaying() }
    }

    /// Enables or disables the Discord IPC service and pushes current track if enabling.
    @objc func discordPresenceSettingChanged(_ notification: Notification) {
        guard let enabled = notification.enabledFlag else { return }
        guard let discordService else { return }

        let song = currentSong
        let artist = currentArtist
        let album = currentAlbum ?? ""
        let playlist = currentPlaylist ?? ""
        let duration = currentDuration
        let elapsed = currentElapsed
        let isPaused = currentIsPaused

        Task { [weak self] in
            await discordService.setEnabled(enabled)
            // The flip alone changes `discordState` ("off" vs "disconnected")
            // even when the IPC state doesn't move, so push it now.
            self?.broadcastStreamDeckState()
            if enabled, let song, let artist {
                await discordService.updatePresence(
                    track: song,
                    artist: artist,
                    album: album,
                    playlist: playlist,
                    duration: duration,
                    elapsed: elapsed,
                    isPaused: isPaused
                )
            }
        }
    }

    /// Applies the new dock visibility mode from the notification payload.
    @objc func dockVisibilityChanged(_ notification: Notification) {
        guard let mode = notification.modeString else { return }
        applyDockVisibility(mode)
    }

    /// Toggles the WebSocket server and applies any port change from the notification.
    ///
    /// Ordering is deliberate: when enabling, the port changes first so the
    /// listener binds the new port once; when disabling, the server stops
    /// first so it never rebinds a port it is about to release. The widget
    /// HTTP server follows the same rule, and is only touched when the
    /// payload carries a widget flag. A missing `enabled` flag falls back to
    /// the stored preference.
    @objc func websocketServerSettingChanged(_ notification: Notification) {
        let enabled = notification.enabledFlag ?? FeatureFlags.websocketEnabled
        let portChange = notification.portValue
        let widgetEnabled = notification.widgetHTTPEnabledFlag
        let widgetPortChange = notification.widgetPortValue
        Task { [weak self] in
            guard let server = self?.websocketServer else { return }
            if enabled {
                if let portChange { await server.updatePort(portChange) }
                await server.setEnabled(true)
            } else {
                await server.setEnabled(false)
                if let portChange { await server.updatePort(portChange) }
            }
            if let widgetEnabled {
                if widgetEnabled {
                    if let widgetPortChange { await server.updateWidgetPort(widgetPortChange) }
                    await server.setWidgetHTTPEnabled(true)
                } else {
                    await server.setWidgetHTTPEnabled(false)
                    if let widgetPortChange { await server.updateWidgetPort(widgetPortChange) }
                }
            }
        }
    }

    /// Toggles the widget HTTP server independently from the WebSocket server.
    /// Always re-reads the resolved widget port from preferences before
    /// applying the enabled state.
    @objc func widgetHTTPServerSettingChanged(_ notification: Notification) {
        let enabled = notification.enabledFlag ?? FeatureFlags.widgetHTTPEnabled
        let port = Preferences.resolvedWidgetPort
        Task { [weak self] in
            guard let server = self?.websocketServer else { return }
            await server.updateWidgetPort(port)
            await server.setWidgetHTTPEnabled(enabled)
        }
    }

    /// Starts or stops the song request playback monitor when the setting changes.
    @objc func songRequestSettingChanged(_ notification: Notification) {
        guard let enabled = notification.enabledFlag else { return }
        if enabled {
            songRequestService?.startPlaybackMonitoring()
        } else {
            songRequestService?.stopPlaybackMonitoring()
        }
        // Channel-point / bit subscriptions are gated on the master toggle too,
        // so re-evaluate them whenever it flips (subscribe on enable, drop the
        // managed reward setup on disable).
        Task { [weak self] in await self?.twitchService?.refreshRedemptionSubscriptions() }
    }

    /// Refreshes channel.poll.end on the current EventSub session when native
    /// Polls mode is enabled after Twitch already connected.
    @objc func voteSkipPollsSettingChanged(_ notification: Notification) {
        guard let enabled = notification.enabledFlag else { return }
        Task { [weak self] in
            await self?.twitchService?.refreshPollSubscriptionIfNeeded(enabled: enabled)
        }
    }

    /// Enables or disables listening-history recording when the toggle changes.
    @objc func listeningHistorySettingChanged(_ notification: Notification) {
        guard let enabled = notification.enabledFlag else { return }
        if enabled {
            historyService?.enable()
        } else {
            // Capture the in-progress play before recording stops. Marks the
            // play consumed so it can't be recorded a second time when the
            // track later changes or playback stops.
            flushCurrentPlayToHistoryOnce()
            historyService?.disable()
        }
        historyService?.prune()
    }

    /// Flushes the in-progress play to history at most once per track.
    ///
    /// Wraps `flushCurrentPlayToHistory()` in a consumed flag so a single play
    /// can't be recorded twice (e.g. the History toggle flushing mid-track,
    /// then the track-change handler recording the same play again when the
    /// song ends). The flag resets when a new track starts playing.
    func flushCurrentPlayToHistoryOnce() {
        guard !currentPlayFlushedToHistory else { return }
        flushCurrentPlayToHistory()
        currentPlayFlushedToHistory = true
    }

    /// Clears skip-vote session state when the Twitch connection drops.
    /// EventSub does not replay missed `poll.end` events, so a poll left
    /// "active" across a disconnect would block every future vote session.
    @objc func twitchConnectionStateChanged(_ notification: Notification) {
        // Twitch connect/disconnect flips the Stream Deck health key.
        broadcastStreamDeckState()

        guard notification.isConnectedFlag == false else { return }
        Task { [weak self] in
            await self?.skipVoteManager?.reset()
        }
    }

    /// Logs that Sparkle reported an available update. Only logs: Sparkle
    /// shows its own update UI.
    @objc func handleUpdateStateChanged(_ notification: Notification) {
        guard let update = notification.updateState, update.isUpdateAvailable else { return }
        let version = update.latestVersion

        Log.info("AppDelegate: Update available notification received: v\(version)", category: .update)
    }
}
