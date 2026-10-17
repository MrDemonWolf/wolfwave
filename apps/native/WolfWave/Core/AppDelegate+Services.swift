//
//  AppDelegate+Services.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-04-03.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import Foundation

// MARK: - Playback Flush Guards

// File-scope because `AppDelegate` extensions cannot add stored properties.
// The app has exactly one delegate instance, and the module's MainActor
// default isolates these globals to the main actor alongside the
// `PlaybackSourceDelegate` callbacks that touch them.

/// Consecutive `Script error` statuses received from the playback source.
/// ScriptingBridge reads are documented flaky on macOS 26, so one bad read
/// mid-track must not flush history and blank the now-playing snapshot.
private var consecutiveScriptErrorCount = 0

/// How many consecutive `Script error` statuses are required before playback
/// is treated as genuinely stopped.
private let scriptErrorStopThreshold = 3

// MARK: - Service Initialization

/// Launch-time construction and cross-wiring of every long-lived service.
/// Each `setup…` method is called once from `applicationDidFinishLaunching`
/// (usually through `guardedStart(_:_:)`); several depend on services an
/// earlier setup created, so call order matters where noted.
extension AppDelegate {

    /// Runs one service-setup closure, isolating a *synchronous* construction
    /// failure so a single bad service degrades instead of aborting the whole
    /// launch sequence. The setups' async bodies (`Task { … }`) still handle
    /// their own errors; a truly unforeseen ObjC exception is caught
    /// process-wide by `CrashReporter`. `name` labels the service in the log.
    func guardedStart(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            Log.error(
                "AppDelegate: service \(name) failed to start: \(error.localizedDescription)",
                category: .app
            )
        }
    }

    /// Creates the Apple Music monitor and sets this as its delegate.
    ///
    /// Does not start tracking; `initializeTrackingState()` does that once
    /// the tracking preference has been seeded.
    func setupMusicMonitor() {
        let source = AppleMusicSource()
        source.delegate = self
        appleMusicSource = source
    }

    /// Creates the Twitch chat service and wires up song info callbacks.
    ///
    /// Also kicks off replay of any paid redemption outcomes (fulfill/refund)
    /// that a previous run persisted but never delivered to Helix. A missing
    /// Client ID is logged, not fatal: the service exists but cannot connect.
    func setupTwitchService() {
        twitchService = TwitchChatService()
        Task { [weak self] in
            await self?.twitchService?.replayPendingRedemptionResolutions()
        }

        if TwitchChatService.resolveClientID() == nil {
            Log.error(
                "AppDelegate: No Twitch Client ID found. "
                    + "Copy Config.xcconfig.example to Config.xcconfig and set your Client ID.",
                category: .twitch)
        }

        // Async providers. The actor hops to MainActor inside each closure
        // to read AppDelegate state. Replaces the prior Thread.isMainThread +
        // DispatchQueue.main.sync dance (G5).
        twitchService?.setCurrentSongInfoProvider { [weak self] in
            await MainActor.run { self?.getCurrentSongInfo() ?? "Nothing playing right now" }
        }
        twitchService?.setLastSongInfoProvider { [weak self] in
            await MainActor.run { self?.getLastSongInfo() ?? "No previous track yet" }
        }
        twitchService?.setStatsInfoProvider { [weak self] in
            await MainActor.run { self?.getStatsInfo() ?? "No listening stats yet" }
        }
    }

    /// Creates the Discord RPC service, consumes its state / artwork streams, and enables if configured.
    ///
    /// The two consumer tasks are retained on `AppDelegate` and cancelled in
    /// `applicationWillTerminate` (or replaced if this runs again). State changes are re-posted as the
    /// `discordState` notification and trigger a Stream Deck health broadcast;
    /// artwork Discord resolves is forwarded to the overlay server.
    func setupDiscordService() {
        let service = DiscordRPCService()
        discordService = service

        if DiscordRPCService.resolveClientID() != nil {
            Log.debug("AppDelegate: Resolved Discord Client ID from Info.plist", category: .discord)
        } else {
            Log.info(
                "AppDelegate: No Discord Client ID found. "
                    + "Set DISCORD_CLIENT_ID in Config.xcconfig to enable Discord Status.",
                category: .discord)
        }

        discordStateConsumer?.cancel()
        discordStateConsumer = Task { @MainActor [weak self] in
            for await newState in service.stateChanges {
                let stateString: String
                switch newState {
                case .connected: stateString = "connected"
                case .connecting: stateString = "connecting"
                case .disconnected: stateString = "disconnected"
                }
                // Carry why it failed alongside the state. Read from the
                // nonisolated snapshot so this stays a synchronous hop.
                NotificationCenter.default.postDiscordState(
                    stateString,
                    failure: service.failureSnapshot.rawValue
                )
                // Discord connect/disconnect flips the Stream Deck health key.
                self?.broadcastStreamDeckState()
            }
        }

        discordArtworkConsumer?.cancel()
        discordArtworkConsumer = Task { @MainActor [weak self] in
            for await resolution in service.artworkResolutions {
                if let server = self?.websocketServer {
                    await server.updateArtworkURL(
                        resolution.url,
                        track: resolution.track,
                        artist: resolution.artist
                    )
                }
            }
        }

        let enabled = FeatureFlags.discordEnabled
        if enabled {
            Task { await service.setEnabled(true) }
        }
    }

    /// Creates the WebSocket server on the configured port and enables if configured.
    ///
    /// Loads (or creates) the overlay and control tokens off the main actor,
    /// because both touch the Keychain. If the two ever come back equal, the
    /// control token is rotated so a read-only overlay credential can never
    /// authorize commands; a failed rotation is logged and the server still
    /// starts with the tokens it has. The server itself is built back on the
    /// main actor, so `websocketServer` is `nil` until this task finishes.
    func setupWebSocketServer() {
        Task { [weak self] in
            let tokens = await Task.detached(priority: .utility) {
                let overlay = WebSocketAuthToken.currentOrCreate(for: .overlay)
                var control = WebSocketAuthToken.currentOrCreate(for: .control)
                if WebSocketAuthToken.constantTimeEquals(overlay, control) {
                    do { control = try WebSocketAuthToken.rotate(.control) } catch { Log.error("AppDelegate: Could not separate WebSocket credentials", category: .websocket) }
                }
                return (overlay, control)
            }.value
            guard let self else { return }
            self.guardedStart("WebSocket") {
                self.setupWebSocketServer(overlayToken: tokens.0, controlToken: tokens.1)
            }
        }
    }

    /// Builds the server with already-resolved credentials, installs the
    /// Stream Deck command handler, and starts consuming server state changes.
    ///
    /// - Parameters:
    ///   - overlayToken: Read-only `wolfwave.overlay.<hex>` credential.
    ///   - controlToken: Command-capable `wolfwave.control.<hex>` credential.
    ///     Both are only ever logged in redacted form.
    private func setupWebSocketServer(overlayToken: String, controlToken: String) {
        // One off-main scan primes the LAN IP cache. Network path updates refresh
        // it again after network-path changes.
        Task.detached(priority: .utility) {
            await NetworkInfoService.shared.refreshIPv4()
        }

        let port = Preferences.resolvedWebSocketServerPort

        Log.info(
            "AppDelegate: WebSocket server initialized on port " + String(port)
                + " (overlay=" + WebSocketAuthToken.redact(overlayToken)
                + ", control=" + WebSocketAuthToken.redact(controlToken) + ")",
            category: .websocket
        )
        let server = WebSocketServerService(
            port: port,
            overlayToken: overlayToken,
            controlToken: controlToken
        )
        websocketServer = server

        // Only loopback control-role connections can reach this handler.
        Task { [weak self] in
            await server.setCommandHandler { [weak self] command in
                await self?.handleStreamDeckCommand(command)
                    ?? CommandAck.failure(command.action.rawValue, "unavailable")
            }
            if FeatureFlags.websocketEnabled { await server.setEnabled(true) }
        }

        let stateChanges = server.stateChanges
        Task.detached { [weak self] in
            for await (newState, clientCount) in stateChanges {
                Log.debug(
                    "AppDelegate: WebSocket state changed to \(newState.rawValue) (\(clientCount) clients)",
                    category: .websocket)
                MetricsService.shared.recordWebSocketClients(clientCount)
                // Push a fresh queue/health snapshot so a newly connected Stream
                // Deck key shows correct state immediately instead of waiting for
                // the next change.
                if clientCount > 0 {
                    await MainActor.run { self?.broadcastStreamDeckState() }
                }
            }
        }

    }

    /// Creates the Sparkle updater. Release builds start background update
    /// checks; DEBUG builds create it without starting (manual checks only).
    func setupSparkleUpdater() {
        sparkleUpdater = SparkleUpdaterService()
        Log.info("AppDelegate: Sparkle updater initialized", category: .update)
    }

    /// Records the app launch and applies the on-device diagnostics opt-in.
    func setupDiagnostics() {
        DiagnosticsService.shared.recordAppLaunch()
        DiagnosticsService.shared.applyEnabledState()
    }

    /// Creates the song request service and wires up playback monitoring + chat replies.
    ///
    /// Must run after `setupTwitchService()`: the chat passthroughs and
    /// redemption reference are only installed when `twitchService` already
    /// exists. Runs the one-time settings migrations first, and ends by
    /// creating the skip-vote manager.
    func setupSongRequestService() {
        SongRequestService.migrateAccessSettings()
        SongRequestService.migrateSetupState()

        let queue = SongRequestQueue()
        let blocklist = SongBlocklist()
        let musicController = AppleMusicController()
        let searchResolver = SongSearchResolver(musicController: musicController)

        songRequestService = SongRequestService(
            queue: queue,
            blocklist: blocklist,
            musicController: musicController,
            searchResolver: searchResolver
        )

        // Wire chat message sending for auto-advance announcements
        songRequestService?.sendChatMessage = { [weak self] message in
            guard let service = self?.twitchService else { return }
            Task { await service.sendMessage(message) }
        }

        // Wire commands to the service via TwitchChatService passthroughs
        if let twitchService {
            Task { [weak self] in
                await twitchService.setSongRequestService { [weak self] in
                    MainActor.assumeIsolated { self?.songRequestService }
                }
                await twitchService.setSongRequestQueue { [weak self] in
                    MainActor.assumeIsolated { self?.songRequestService?.queue }
                }
                // Direct reference for the channel-point / bit redemption handlers
                let reference = await MainActor.run { self?.songRequestService }
                await twitchService.setSongRequestServiceReference(reference)
            }
        }

        // Start playback monitoring if song requests are enabled
        let enabled = FeatureFlags.songRequestEnabled
        if enabled {
            songRequestService?.startPlaybackMonitoring()
        }

        // Verify the requests playlist is still set up and shared. Catches a
        // playlist deleted or un-shared between launches and surfaces the "needs
        // setup again" banner; no-op until the guided setup has been finished.
        Task { [weak self] in
            await self?.songRequestService?.runSetupHealthCheck()
        }

        setupSkipVoteManager()

        Log.info("AppDelegate: Song request service initialized", category: .songRequest)
    }

    /// Creates the chat vote-to-skip manager and wires its skip + chat callbacks.
    ///
    /// Must run after `setupTwitchService()` and `songRequestService` exist so the
    /// skip action and chat-message relay can reach the live services.
    func setupSkipVoteManager() {
        let voteManager = SkipVoteManager()
        skipVoteManager = voteManager

        let capturePlaybackTarget: @Sendable () async -> PlaybackTarget? = { [weak self] in
            let service = await MainActor.run { self?.songRequestService }
            return await service?.capturePlaybackTarget()
        }
        let performSkip: @Sendable (PlaybackTarget) async -> Bool = { [weak self] target in
            let service = await MainActor.run { self?.songRequestService }
            return await service?.voteSkip(target: target) ?? false
        }
        let sendChatMessage: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let service = self?.twitchService else { return }
                await service.sendMessage(message)
            }
        }
        let createPoll: @Sendable (String, Int) async -> SkipPollCreationOutcome = {
            [weak self] title, duration in
            let service = await MainActor.run { self?.twitchService }
            guard let service else { return .definitiveFailure }
            return await service.createSkipPoll(title: title, durationSeconds: duration)
        }
        let onVoteEvent: @Sendable (SkipVoteManager.VoteEvent) -> Void = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleVoteEvent(event)
            }
        }

        Task {
            await voteManager.configure(
                capturePlaybackTarget: capturePlaybackTarget,
                performSkip: performSkip,
                sendChatMessage: sendChatMessage,
                createPoll: createPoll,
                onVoteEvent: onVoteEvent
            )
        }

        if let twitchService {
            Task { [weak self] in
                await twitchService.setSkipVoteManager { [weak self] in
                    MainActor.assumeIsolated { self?.skipVoteManager }
                }
            }

            // Route finished Twitch polls back into the vote manager via the
            // AsyncStream surface.
            skipPollObserverTask?.cancel()
            skipPollObserverTask = Task { [weak self] in
                for await result in twitchService.skipPollResults {
                    await self?.skipVoteManager?.handlePollEnded(
                        pollID: result.pollID,
                        skipVotes: result.skipVotes, keepVotes: result.keepVotes)
                }
            }
        }
    }

    /// Creates the iCloud settings mirror and starts it if the user opted in.
    /// Later toggles arrive through the `iCloudSettingsSyncSettingChanged`
    /// observer in `setupNotificationObservers()`.
    func setupSettingsSync() {
        let service = SettingsSyncService()
        settingsSyncService = service
        let enabled = FeatureFlags.iCloudSettingsSyncEnabled
        service.setEnabled(enabled)
        Log.info("AppDelegate: Settings sync initialized (enabled: \(enabled))")
    }

    /// Creates the listening history service and loads existing history if the
    /// feature is enabled.
    func setupHistoryService() {
        let enabled = FeatureFlags.listeningHistoryEnabled
        historyService = ListeningHistoryService(enabled: enabled)
        historyService?.start()
        Log.info(
            "AppDelegate: Listening history service initialized (enabled: \(enabled))",
            category: .history
        )
    }
}

// MARK: - Power State

/// Slows polling and broadcast cadences while the Mac is in Low Power Mode
/// (or otherwise reduced), and restores them when it leaves.
extension AppDelegate {

    /// Initializes the power state monitor and registers for power state change notifications.
    func setupPowerStateMonitor() {
        observeOnMain(Notification.Name.powerStateChanged) { [weak self] n in
            self?.powerStateChanged(n)
        }

        // Register before constructing the singleton: its initial evaluation may
        // synchronously publish reduced mode. Explicitly apply the current snapshot
        // as well so launch state never depends on notification ordering.
        let reduced = PowerStateMonitor.shared.isReducedMode
        applyPowerState(reduced: reduced)
    }

    /// Adjusts service polling intervals when system power state changes.
    @objc func powerStateChanged(_ notification: Notification) {
        guard let reduced = notification.isReducedModeFlag else { return }
        applyPowerState(reduced: reduced)
    }

    /// Pushes the matching intervals to the Music poll, the Discord
    /// availability poll, and the overlay progress broadcast.
    ///
    /// - Parameter reduced: `true` for the slower low-power intervals.
    private func applyPowerState(reduced: Bool) {
        // 5 s is the normal Music fallback poll interval.
        appleMusicSource?.updateCheckInterval(
            reduced ? AppConstants.PowerManagement.reducedMusicCheckInterval : 5.0
        )
        if let discordService {
            let discordInterval = reduced
                ? AppConstants.PowerManagement.reducedDiscordPollInterval
                : AppConstants.Discord.availabilityPollInterval
            Task { await discordService.updatePollInterval(discordInterval) }
        }
        let wsInterval: TimeInterval = reduced
            ? AppConstants.PowerManagement.reducedProgressBroadcastInterval
            : AppConstants.WebSocketServer.progressBroadcastInterval
        Task { [weak self] in await self?.websocketServer?.updateProgressInterval(wsInterval) }

        Log.debug("AppDelegate: Power state changed: reduced=\(reduced)", category: .app)
    }
}

// MARK: - Overlay Toggle

/// The single overlay on/off switch behind the tray menu's overlay toggle.
extension AppDelegate {

    /// Applies the full overlay-service on/off state used by the tray toggle:
    /// flips the WebSocket and widget-HTTP prefs in lockstep and broadcasts the
    /// change. Stream Deck visibility is independent so its control transport
    /// remains connected while cards are hidden.
    ///
    /// Synchronous by design so the pref write and notification post are not
    /// deferred into a `Task` (a synchronous observer would otherwise briefly
    /// read the stale value). Callers own the async
    /// `websocketServer.setWidgetHTTPEnabled(_:)` hop.
    func applyOverlayEnabled(_ newValue: Bool) {
        Preferences.setWebSocketEnabled(newValue)
        // Keep widgetHTTPEnabled in sync: OBS loads the widget page over HTTP,
        // so the overlay stays blank if the WebSocket channel comes up without it.
        Preferences.setWidgetHTTPEnabled(newValue)
        NotificationCenter.default.postWebSocketServerChanged(
            enabled: newValue,
            widgetHTTPEnabled: newValue
        )
    }
}

// MARK: - Tracking State

/// Launch-time decision on whether the Apple Music monitor runs.
extension AppDelegate {

    /// Defaults tracking to enabled on first launch, then starts or stops the monitor.
    func initializeTrackingState() {
        Preferences.seedTrackingEnabledDefaultIfNeeded()

        if isTrackingEnabled() {
            appleMusicSource?.startTracking()
        } else {
            postNowPlayingUpdate(song: nil, artist: nil, album: nil)
        }
    }

    /// The persisted Music Sync toggle (seeded to `true` on first launch).
    private func isTrackingEnabled() -> Bool {
        FeatureFlags.trackingEnabled
    }
}

// MARK: - Widget Artwork

/// Overlay artwork lookups.
extension AppDelegate {

    /// Fetches album artwork via the shared ArtworkService and forwards it to the WebSocket server.
    /// Hits the network (iTunes Search) on a cache miss; a failed lookup
    /// (`nil` URL) leaves the overlay's current artwork untouched.
    func fetchArtworkForWidget(track: String, artist: String) {
        ArtworkService.shared.fetchArtworkURL(track: track, artist: artist) { [weak self] url in
            guard let url else { return }
            Task { [weak self] in
                await self?.websocketServer?.updateArtworkURL(url, track: track, artist: artist)
            }
        }
    }
}

// MARK: - Playback Source Delegate

/// Fans each playback update from `AppleMusicSource` out to history, the
/// tray menu, notifications, the overlay, and Discord.
extension AppDelegate: PlaybackSourceDelegate {

    /// Updates track history, broadcasts to all services, and fetches artwork.
    ///
    /// Called on every emit, including the same track re-emitted by the 5 s
    /// fallback poll and on pause/resume. Per-track side effects (history,
    /// recents, banner, artwork fetch, skip-vote reset) run only when the
    /// title + artist + album identity changes; the now-playing snapshot and
    /// overlay / Discord updates run every time so elapsed time stays current.
    func playbackSource(
        didUpdateTrack track: String,
        artist: String,
        album: String,
        playlist: String,
        duration: TimeInterval,
        elapsed: TimeInterval,
        isPaused: Bool
    ) {
        // A good read ends any ScriptingBridge error streak.
        consecutiveScriptErrorCount = 0

        // Composite identity: title alone conflates distinct songs that share
        // a name (a cover, a live version, two songs called "Home"), silently
        // skipping history recording, the !last update, recents, and the
        // song-change banner on such transitions. Genuine re-emits of the same
        // track carry identical title + artist + album, so pause/resume
        // behavior is unchanged.
        let isSameTrack = currentSong == track
            && currentArtist == artist
            && (currentAlbum ?? "") == album
        if !isSameTrack {
            // The outgoing track's last polled playhead position (`currentElapsed`)
            // is how far it actually played. Hand it to history before we
            // overwrite the now-playing state, unless this play was already
            // flushed (History toggle-off): recording it again would double
            // count the track.
            if let outgoing = currentSong, let outgoingArtist = currentArtist,
               !currentPlayFlushedToHistory {
                historyService?.recordTrackChange(
                    track: outgoing,
                    artist: outgoingArtist,
                    album: currentAlbum ?? "",
                    duration: currentDuration,
                    playedSeconds: currentElapsed
                )
            }
            // The incoming track is a fresh play; it hasn't been flushed yet.
            currentPlayFlushedToHistory = false
            lastSong = currentSong
            lastArtist = currentArtist

            // Votes cast against the outgoing song must not carry over to the
            // incoming one. Ends any open chat-tally vote session without
            // starting the inter-session cooldown. Advance the service revision
            // synchronously before the unstructured actor task, so an old poll
            // cannot win a scheduling window and target the replacement track.
            songRequestService?.notePlaybackTrackChanged()
            Task { [weak self] in
                await self?.skipVoteManager?.trackDidChange()
            }

            // Push the incoming track onto the tray-menu recents buffer.
            // De-dup happens inside the buffer so Music.app's resume
            // re-broadcasts don't pollute the list.
            recentTracks.push(RecentTrack(title: track, artist: artist, playedAt: Date()))

            // Suppress the first track after launch (it was already playing);
            // notify on every genuine change thereafter. Pause/resume of the
            // same track is filtered above by the `isSameTrack` guard so
            // toggling play state never re-fires the banner.
            if hasSeenInitialTrack {
                maybePostSongChangeNotification(track: track, artist: artist, album: album)
            }
            hasSeenInitialTrack = true

            // Artwork is keyed by track+artist, so only refetch on a genuine
            // track change. On a same-track re-emit (~every 5s) the previous
            // fetch already populated the cache; refetching triggered a
            // redundant full overlay rebroadcast per tick via updateArtworkURL.
            fetchArtworkForWidget(track: track, artist: artist)
        }

        currentSong = track
        currentArtist = artist
        currentAlbum = album
        currentPlaylist = playlist
        currentDuration = duration
        currentElapsed = elapsed
        currentIsPaused = isPaused

        postNowPlayingUpdate(song: track, artist: artist, album: album, playlist: playlist, isPaused: isPaused)

        let cachedArtworkURL = ArtworkService.shared.cachedArtworkURL(track: track, artist: artist)
        Task { [weak self] in
            await self?.websocketServer?.updateNowPlaying(
                track: track,
                artist: artist,
                album: album,
                duration: duration,
                elapsed: elapsed,
                artworkURL: cachedArtworkURL,
                isPaused: isPaused
            )
        }

        if let discordService {
            Task {
                await discordService.updatePresence(
                    track: track,
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

    /// Applies the "no track" Discord state, honoring the idle-status
    /// preference: shows the opt-in idle activity, or clears the profile.
    func applyDiscordCleared() {
        guard let discordService else { return }
        if FeatureFlags.discordShowIdleStatus {
            Task { await discordService.showIdleStatus() }
        } else {
            Task { await discordService.clearPresence() }
        }
    }

    /// Posts a macOS song-change notification when the user has enabled the
    /// setting. Called only on a genuine track change, never on the first
    /// track seen after launch.
    private func maybePostSongChangeNotification(track: String, artist: String, album: String) {
        guard FeatureFlags.songChangeNotificationsEnabled else { return }

        Task {
            await NotificationService.shared.postSongChange(track: track, artist: artist, album: album)
        }
    }

    /// Posts a macOS notification for a skip-vote lifecycle event when both the
    /// vote-skip feature and the matching notification toggle are on.
    ///
    /// Belt-and-braces gating: the settings UI already hides/disables these
    /// toggles when vote-skip is off, but we re-check `voteSkipEnabled` here so a
    /// stale persisted toggle can't fire a notification for an impossible event.
    @MainActor
    func handleVoteEvent(_ event: SkipVoteManager.VoteEvent) {
        guard FeatureFlags.voteSkipEnabled else { return }

        let track = currentSong ?? ""
        let artist = currentArtist ?? ""

        switch event {
        case .started(let needed):
            guard FeatureFlags.skipVoteStartedNotificationsEnabled else { return }
            Task {
                await NotificationService.shared.postSkipVoteStarted(
                    track: track, artist: artist, votesNeeded: needed, viaPoll: false)
            }
        case .pollStarted:
            guard FeatureFlags.skipVoteStartedNotificationsEnabled else { return }
            Task {
                await NotificationService.shared.postSkipVoteStarted(
                    track: track, artist: artist, votesNeeded: 0, viaPoll: true)
            }
        case .passed:
            guard FeatureFlags.skipVotePassedNotificationsEnabled else { return }
            Task {
                await NotificationService.shared.postSkipVotePassed(track: track, artist: artist)
            }
        }
    }

    /// Clears track state and notifies services when playback stops.
    ///
    /// - Parameter status: One of the `AppleMusicSource.DelegateStatus`
    ///   strings (for example `noTrackPlaying`, `musicNotRunning`,
    ///   `scriptError`).
    func playbackSource(didUpdateStatus status: String) {
        Log.info("AppDelegate: Playback status = \(status)", category: .music)

        // Debounce ScriptingBridge read errors. A single flaky read mid-track
        // (documented macOS 26 behavior) must not flush a partial play to
        // history (which double-counts the track when it later ends) or blank
        // Discord and the overlay. Only a sustained error streak clears
        // playback; any other status, or a good track read, resets the streak.
        if status == AppleMusicSource.DelegateStatus.scriptError {
            consecutiveScriptErrorCount += 1
            if consecutiveScriptErrorCount < scriptErrorStopThreshold {
                Log.debug(
                    "AppDelegate: transient script error (\(consecutiveScriptErrorCount)/\(scriptErrorStopThreshold)), keeping playback snapshot",
                    category: .music
                )
                return
            }
        } else {
            consecutiveScriptErrorCount = 0
        }

        // Any of these statuses mean "no track is reliably playing right now".
        // Flush in-progress history and blank the cached snapshot so Discord
        // Rich Presence and the WebSocket overlay don't keep broadcasting a
        // stale song after Music quits, permission is revoked, or SB errors out.
        let shouldClearPlayback = status == AppleMusicSource.DelegateStatus.noTrackPlaying
            || status == AppleMusicSource.DelegateStatus.accessDenied
            || status == AppleMusicSource.DelegateStatus.musicNotRunning
            || status == AppleMusicSource.DelegateStatus.noTrackInfo
            || status == AppleMusicSource.DelegateStatus.scriptError

        if shouldClearPlayback {
            clearPlaybackStateAndOutputs()
        }

        if status == AppleMusicSource.DelegateStatus.accessDenied {
            // Tell the Music Monitor settings view to flip its banner now,
            // without waiting for the next AEDeterminePermissionToAutomateTarget
            // poll or the user clicking Recheck.
            NotificationCenter.default.post(name: .musicPermissionDenied, object: nil)
        }

        if !shouldClearPlayback {
            postNowPlayingUpdate(song: nil, artist: nil, album: nil)
        }
    }
}
