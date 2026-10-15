//
//  SongRequestService.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-04-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import Foundation
import MusicKit

/// Orchestrates the song request system.
///
/// Coordinates search resolution, blocklist checking, queue management,
/// and Apple Music playback via MusicKit. State is polled by the queue
/// settings view via a refresh timer, so this type does not adopt the
/// `@Observable` macro.
///
/// MainActor-isolated by the module default. Concurrency safety rests on that:
/// every reentrancy guard (`isStartingPlayback`, the native-clear gate, the
/// playback generation) is checked and set with no `await` in between, and is
/// re-checked after each Music.app await because other calls can interleave
/// there.
final class SongRequestService {
    // MARK: - Types

    /// Result of processing a song request.
    enum RequestResult {
        /// The caller was cancelled before the request could mutate queue or
        /// playback state. Callers deliberately keep this outcome silent.
        case cancelled
        /// Queued in the live queue. `position` is the 1-based slot from
        /// `SongRequestQueue.add`; playback may already have started.
        case added(item: SongRequestItem, position: Int)
        /// Approval mode is on: the request is held for the streamer to approve or
        /// reject before it reaches the live queue.
        case pendingApproval(item: SongRequestItem)
        /// The queue (or the pending pen) is at its configured capacity.
        case queueFull(max: Int)
        /// The requester already has `max` items for their role tier (now-playing counts).
        case userLimitReached(max: Int)
        /// The requester already has this song queued, pending, or playing.
        case alreadyInQueue
        /// The requester, the song, or its artist is on the blocklist.
        case blocked
        /// Plain-text search found nothing.
        case notFound(query: String)
        /// A music link couldn't be matched to one catalog track.
        case linkNotFound
        /// MusicKit access was denied or restricted (never asked counts as allowed,
        /// so the first search can show the prompt).
        case notAuthorized
        /// The song-request feature's master toggle is off. No request of any
        /// kind (chat, channel points, bits) is accepted.
        case featureDisabled
        /// User-facing failure text: the chat audience denial message, or a
        /// search / MusicKit error.
        case error(String)
    }

    /// What a ``SongRequestService/skip()`` call actually did.
    ///
    /// A skip can fail without touching the queue (Music closed, a playback
    /// command timed out, another transition in flight), so callers must not
    /// read "nothing started" as "the queue drained".
    enum SkipOutcome: Equatable {
        /// The next request started and is now playing.
        case started(SongRequestItem)
        /// No requests were left. The drain policy (fallback playlist,
        /// autoplay, or silence) took over.
        case drained
        /// Another playback transition or queue clear was in flight, so
        /// nothing changed.
        case busy
        /// The next request couldn't start and was kept at the head of the
        /// queue (Music closed, command failed, track not ready, cancelled).
        case retained

        /// The item that started, or `nil` for every non-`started` outcome.
        var startedItem: SongRequestItem? {
            if case .started(let item) = self { return item }
            return nil
        }
    }

    // MARK: - Properties

    /// Live queue, pending-approval pen, and now-playing slot. Source of truth for ordering.
    let queue: SongRequestQueue
    /// Requester, song, and artist blocks checked before anything is queued.
    let blocklist: SongBlocklist
    /// Music.app / MusicKit boundary (stubbed in tests).
    let musicController: any AppleMusicControlling
    /// Turns request text or links into a catalog `Song`.
    let searchResolver: SongSearchResolver

    /// Who may request a song via the `!sr` chat command.
    var chatAudience: RequestAudience {
        RequestAudience.current()
    }

    /// One-time migration of the legacy `songRequestSubscriberOnly` boolean to
    /// the `songRequestChatAudience` setting. No-op once the new key exists.
    static func migrateAccessSettings(defaults: Foundation.UserDefaults = DefaultsStore.store) {
        guard defaults.string(forKey: AppConstants.UserDefaults.songRequestChatAudience) == nil else { return }
        let legacySubOnly = defaults.bool(forKey: AppConstants.UserDefaults.songRequestSubscriberOnly)
        let audience: RequestAudience = legacySubOnly ? .subscribers : .everyone
        defaults.set(audience.rawValue, forKey: AppConstants.UserDefaults.songRequestChatAudience)
    }

    // MARK: - Setup Gate & Playlist Health

    /// One-time grandfather of the setup gate. Anyone who already had song
    /// requests turned on (or a song-list link configured) before the guided
    /// setup existed is marked complete, so the update never bounces an existing
    /// streamer back through setup. No-op once `songRequestSetupComplete` has
    /// been written. Mirrors `migrateAccessSettings`.
    static func migrateSetupState(defaults: Foundation.UserDefaults = DefaultsStore.store) {
        guard defaults.object(forKey: AppConstants.UserDefaults.songRequestSetupComplete) == nil else { return }
        let alreadyEnabled = defaults.bool(forKey: AppConstants.UserDefaults.songRequestEnabled)
        let link = defaults.string(forKey: AppConstants.UserDefaults.songRequestSongListURL) ?? ""
        let hasLink = !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if alreadyEnabled || hasLink {
            defaults.set(true, forKey: AppConstants.UserDefaults.songRequestSetupComplete)
        }
        // Fresh installs are left unset (false) so they go through the wizard.
    }

    /// The fallback to apply after a health check. Pure data so the policy is
    /// unit-testable without touching UserDefaults or the network.
    struct HealthOutcome: Equatable {
        /// Status written to `songRequestPlaylistStatus` (drives the banner).
        var status: PlaylistSetupStatus
        /// Turn off `!playlist` (cosmetic link break).
        var disableLink = false
        /// Re-engage the setup gate and stop the feature (essential break).
        var reEngageGate = false
        /// Write a refreshed public share URL when the playlist was republished.
        var updatedShareURL: String?
    }

    /// Maps a playlist probe to the fallback policy. Returns `nil` for an
    /// unreachable API so a network blip never clears a real banner or flips a
    /// toggle. Pure: the only inputs are the probe and the currently stored link.
    ///
    /// - `.missing` is an essential break (the rebuild attempt already failed by
    ///   the time the caller passes `.missing` here) so it re-engages the gate.
    /// - `.notPublic` only matters when a link was stored; then it's a cosmetic
    ///   `!playlist` break. With no stored link, a private playlist is fine.
    /// - `.ok` refreshes the stored link if the public URL changed (republished).
    ///
    /// `localVisibility` is the second, independent layer. The probe above only
    /// proves the playlist exists in the Apple Music **cloud** library, while
    /// playback resolves it through AppleScript against Music.app's **local**
    /// library, so a cloud-healthy playlist can still be unplayable. A definitive
    /// `.notVisible` relabels an otherwise-cosmetic outcome to
    /// `.playlistNotInMusic` while leaving every side effect intact: it must not
    /// escalate to an essential break, because Sync Library latency and an
    /// empty-playlist edge case can both produce a `.notVisible` that clears
    /// itself, and holding the whole feature on that would be worse than the
    /// banner. `.unknown` (Music closed, probe failed) changes nothing.
    static func resolveHealth(
        probe: AppleMusicLibraryService.PlaylistProbe,
        storedShareURL: String,
        localVisibility: PlaylistLocalVisibility = .unknown
    ) -> HealthOutcome? {
        let trimmed = storedShareURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLink = !trimmed.isEmpty
        var outcome: HealthOutcome
        switch probe {
        case .unreachable:
            return nil
        case .missing:
            outcome = HealthOutcome(status: .playlistMissing, reEngageGate: true)
        case .notPublic:
            outcome = hasLink
                ? HealthOutcome(status: .linkUnshared, disableLink: true)
                : HealthOutcome(status: .ok)
        case .ok(let url):
            if hasLink, let url, url != trimmed {
                outcome = HealthOutcome(status: .ok, updatedShareURL: url)
            } else {
                outcome = HealthOutcome(status: .ok)
            }
        }
        if localVisibility == .notVisible, !outcome.status.isEssential {
            outcome.status = .playlistNotInMusic
        }
        return outcome
    }

    /// Checks that the song-request playlist setup is still healthy and applies
    /// the fallback when it is not. Safe to call on launch and whenever the pane
    /// appears.
    ///
    /// Order of checks, cheapest and most essential first: setup not finished →
    /// nothing to police; Apple Music access lost → prompt a re-grant; otherwise
    /// probe the playlist (rebuilding it once if it was deleted) and resolve the
    /// link state. An unreachable API changes nothing.
    func runSetupHealthCheck() async {
        let defaults = DefaultsStore.store

        // Before setup is finished the pane shows the "Set up" call to action,
        // not a banner, so there is nothing to police yet.
        guard defaults.bool(forKey: AppConstants.UserDefaults.songRequestSetupComplete) else {
            setPlaylistStatus(.ok)
            return
        }

        // Apple Music access is the first essential. Non-destructive: requests
        // already guard on auth, and re-granting clears this on the next check.
        guard musicController.isAuthorized else {
            applyHealth(HealthOutcome(status: .musicAccessLost))
            return
        }

        let library = AppleMusicLibraryService()
        let storedURL = defaults.string(forKey: AppConstants.UserDefaults.songRequestSongListURL) ?? ""
        var probe = await library.probeRequestsPlaylist()

        // A deleted playlist self-heals: rebuild it once before treating the loss
        // as an essential break. After a rebuild the new playlist is private, so
        // re-probe to capture the (not-yet-public) link state.
        if case .missing = probe {
            library.resetCachedPlaylistID()
            if (try? await library.ensureRequestsPlaylist()) != nil {
                probe = await library.probeRequestsPlaylist()
            }
        }

        // Second layer: the cloud probe above can say "healthy" about a playlist
        // Music.app cannot see, and AppleScript playback only ever reads the local
        // library. Ask Music directly, in the terminology playback uses.
        let localVisibility = await musicController.requestsPlaylistLocalVisibility()

        guard let outcome = Self.resolveHealth(
            probe: probe,
            storedShareURL: storedURL,
            localVisibility: localVisibility
        ) else { return }
        applyHealth(outcome)
    }

    /// Persists a `HealthOutcome`: updates a refreshed link, turns off `!playlist`
    /// on a cosmetic break, re-engages the gate and stops the feature on an
    /// essential break, then records the status that drives the banner.
    private func applyHealth(_ outcome: HealthOutcome) {
        let defaults = DefaultsStore.store
        if let updated = outcome.updatedShareURL {
            defaults.set(updated, forKey: AppConstants.UserDefaults.songRequestSongListURL)
        }
        if outcome.disableLink {
            defaults.set(false, forKey: AppConstants.UserDefaults.songListCommandEnabled)
        }
        if outcome.reEngageGate {
            defaults.set(false, forKey: AppConstants.UserDefaults.songRequestSetupComplete)
            defaults.set(false, forKey: AppConstants.UserDefaults.songRequestEnabled)
            NotificationCenter.default.postEnabled(.songRequestSettingChanged, enabled: false)
            Log.info("SongRequestService: Playlist setup broke; re-engaging setup gate", category: .songRequest)
        }
        setPlaylistStatus(outcome.status)
    }

    /// Writes the playlist health status that backs the pane's `@AppStorage`
    /// banner. Only writes on a change to avoid waking observers needlessly.
    private func setPlaylistStatus(_ status: PlaylistSetupStatus) {
        let defaults = DefaultsStore.store
        let key = AppConstants.UserDefaults.songRequestPlaylistStatus
        guard defaults.string(forKey: key) != status.rawValue else { return }
        defaults.set(status.rawValue, forKey: key)
    }

    /// Whether the song-request feature's master toggle is on. Every request
    /// path (chat `!sr`, channel points, bits) is rejected when this is off, so
    /// the per-command and per-redemption toggles can't accept requests on their
    /// own while the feature as a whole is disabled.
    var isFeatureEnabled: Bool {
        FeatureFlags.songRequestEnabled
    }

    /// Whether the poll advances the queue on its own. Defaults to on; when off,
    /// requests only start from the explicit start paths (skip, approve, etc.)
    /// and the polling task is not created.
    var isAutoAdvanceEnabled: Bool {
        Preferences.bool(AppConstants.UserDefaults.songRequestAutoAdvance, default: true)
    }

    /// Whether resolved requests wait in a holding pen for the streamer to approve
    /// before they reach the live queue. Off by default: requests auto-queue.
    var isApprovalRequired: Bool {
        Preferences.bool(AppConstants.UserDefaults.songRequestApprovalRequired, default: false)
    }

    /// Whether Apple Music's own autoplay should keep going once the request
    /// queue empties (when no fallback playlist is configured). Off means the
    /// stream goes silent on an empty queue.
    var isAutoplayWhenEmptyEnabled: Bool {
        Preferences.bool(AppConstants.UserDefaults.songRequestAutoplayWhenEmpty, default: true)
    }

    /// Hold mode: requests keep queueing but nothing new starts. See ``setHold(_:)``.
    var isHoldEnabled: Bool {
        FeatureFlags.songRequestHoldEnabled
    }

    /// Toggle hold mode. When enabled, new requests buffer without playing and
    /// auto-advance is suspended. When disabled, the first buffered song plays immediately.
    ///
    /// Persists the flag, posts `.songRequestHoldChanged` (the queue view and Stream Deck
    /// state refresh from it), and always reconciles the polling task on exit. On release
    /// the buffered song only starts if Music.app is running and nothing is playing.
    func setHold(_ enabled: Bool) async {
        guard !Task.isCancelled else { return }
        DefaultsStore.store.set(enabled, forKey: AppConstants.UserDefaults.songRequestHoldEnabled)
        NotificationCenter.default.postEnabled(.songRequestHoldChanged, enabled: enabled)
        Log.debug("SongRequestService: Hold \(enabled ? "enabled" : "released")", category: .songRequest)
        defer { reconcilePlaybackMonitoring() }

        if !enabled {
            guard musicController.isMusicAppRunning else { return }
            if queue.nowPlaying == nil && !queue.isEmpty {
                guard !Task.isCancelled else { return }
                if let started = await playNextInQueue() {
                    guard !Task.isCancelled else { return }
                    sendChatMessage?("Now playing: \"\(started.title)\" by \(started.artist) (requested by \(started.requesterUsername))")
                }
            }
        }
    }

    /// The auto-advance polling loop. `nil` whenever ``updatePlaybackPolling()``
    /// decides polling isn't needed, so an idle service does no periodic work.
    private var playbackObserver: Task<Void, Never>?
    /// True only between explicit `startPlaybackMonitoring` / stop lifecycle calls.
    private var isPlaybackMonitoringEnabled = false

    /// `NSWorkspace` launch observer that flushes buffered requests when Music.app starts.
    private var musicAppLaunchObserver: NSObjectProtocol?
    /// `.songRequestQueueChanged` observer that starts / stops the polling task.
    private var queueChangeObserver: NSObjectProtocol?

    /// Interval between auto-advance polls. Injectable so tests can use a small
    /// value instead of waiting the full production cadence.
    private let pollInterval: Duration

    /// Reentrancy guard for `playNextInQueue()`. Set and checked with no
    /// intervening `await`, so two near-simultaneous callers (e.g. two
    /// `processRequest` calls while Music.app is closed) can't both dequeue and
    /// start playback for the same slot.
    private var isStartingPlayback = false

    /// Invalidates every playback operation that began before clearQueue().
    /// Successful stale starts are stopped instead of being committed back into
    /// a queue the user explicitly cleared.
    private var playbackGeneration = 0

    /// Synchronously advanced by AppDelegate before it asynchronously tells the
    /// vote manager about an observed track change. A poll target captures this
    /// revision so actor scheduling cannot briefly make an old target look live.
    private var playbackRevision: UInt64 = 0

    /// One native clear shared by every overlapping `clearQueue()` caller.
    /// Keeping the operation installed until the latest clear waiter publishes
    /// its result also gates every other Music.app mutation while clear runs.
    private var nativeClearOperation: (id: Int, task: Task<Void, Never>)?
    /// Monotonic id source for `nativeClearOperation`, so a release can tell
    /// its own operation from a newer one.
    private var nativeClearOperationSequence = 0

    /// The latest completed clear that still needs to start a request which
    /// arrived after that clear. A pre-clear playback command may still be
    /// suspended; in that case reconciliation waits until its stale cleanup has
    /// finished so an older completion cannot erase the replacement request.
    private var pendingClearReconciliationGeneration: Int?

    /// True only while a native Music.app clear command is active.
    private var isNativeClearInFlight: Bool {
        nativeClearOperation != nil
    }

    /// Small test seam for suspending or failing item playback without needing
    /// to manufacture a MusicKit Song. Production leaves this nil and routes
    /// through AppleMusicControlling.playNow(song:).
    private let playbackOverride: ((SongRequestItem) async throws -> Void)?

    /// Track key (name + tab + artist, see `PlaybackSnapshot.trackKey`) of the
    /// streamer's own song that a queued request is waiting to follow. Set the first time the poll notices a pending request
    /// while the streamer's own (non-request, non-fallback) track is playing,
    /// then cleared once that track changes so the request takes over. This is
    /// what implements the "play when the current song ends" takeover policy
    /// instead of interrupting a track mid-play.
    private var takeoverBaselineTrackID: String?

    /// Consecutive poll ticks that have read Music.app as stopped. The poll
    /// requires two in a row before advancing or taking over, so a single
    /// transient "stopped" read can't trigger a spurious skip mid-track. (A
    /// failed read is a `nil` snapshot and skips the tick without touching this.)
    private var stoppedPollStreak = 0

    /// Track key (name + tab + artist, not Music's persistent ID, which flakes for
    /// streamed tracks) Music.app loaded for the request that is currently
    /// playing. Established on the first poll tick after a request starts, then
    /// compared against Music.app's live current track. If they diverge while
    /// playback continues, the request either finished (Music autoplayed the next
    /// track) or the streamer hit skip inside Music.app. Either way the request is
    /// done, so the next queued request takes over instead of leaving a
    /// non-request track parked on the now-playing slot forever.
    private var playingRequestTrackID: String?

    /// Consecutive poll ticks the loaded track has differed from the takeover
    /// baseline (the streamer's own track a request is waiting to follow). Like
    /// `stoppedPollStreak`, a track change must be seen on two reads in a row
    /// before the queue takes over, so a single transient AppleScript read can't
    /// trigger a spurious takeover that cuts the streamer's song off mid-play.
    private var takeoverDivergenceStreak = 0

    /// Consecutive poll ticks the loaded track has differed from the playing
    /// request's baseline. Same two-in-a-row debounce as `takeoverDivergenceStreak`,
    /// applied to the "request finished / streamer skipped" hand-off.
    private var requestDivergenceStreak = 0

    /// Number of consecutive confirming reads a stop or track change needs before
    /// the queue acts on it. Two ≈ one extra poll interval of latency at a track
    /// boundary (unnoticeable) in exchange for immunity to a single flaky read.
    private let pollConfirmations = 2

    /// Clears the takeover-detection debounce: the streamer-track baseline and
    /// its divergence streak. Kept granular (never merged with
    /// ``resetRequestPlaybackTracking()``) so each poll branch resets exactly the
    /// state it owns. Does not touch `stoppedPollStreak`. Not for the
    /// baseline-establishment sites, which set `takeoverBaselineTrackID` to the
    /// current key rather than nil.
    private func resetTakeoverTracking() {
        takeoverBaselineTrackID = nil
        takeoverDivergenceStreak = 0
    }

    /// Clears the playing-request debounce: the tracked request track ID and its
    /// divergence streak.
    private func resetRequestPlaybackTracking() {
        playingRequestTrackID = nil
        requestDivergenceStreak = 0
    }

    /// Whether the fallback playlist is currently playing (no active requests).
    private(set) var isPlayingFallback = false

    /// Per-item count of consecutive failed play attempts. A request can fail to
    /// play because its track is still syncing down from iCloud Music Library
    /// right after being added; keeping a count lets the poll retry a few times
    /// before giving up on one that never becomes playable (e.g. a song that
    /// isn't available or the streamer has no active subscription).
    private var playAttemptCounts: [UUID: Int] = [:]

    /// Maximum play attempts before a stuck request is dropped with a chat notice.
    private let maxPlayAttempts = 3

    /// Callback used to relay status messages back to Twitch chat. Set by
    /// `AppDelegate` once `TwitchChatService` is wired up.
    var sendChatMessage: ((String) -> Void)?

    // MARK: - Init

    /// Creates a song request service with overridable collaborators.
    ///
    /// All collaborators default to production implementations. Tests inject
    /// fakes via the parameters.
    ///
    /// - Parameters:
    ///   - queue: Backing queue store.
    ///   - blocklist: Title/artist blocklist.
    ///   - musicController: Apple Music controller (AppleScript-backed in prod).
    ///   - searchResolver: MusicKit/URL resolver. Defaults to one bound to
    ///     `musicController`.
    ///   - pollInterval: Auto-advance poll cadence. Defaults to 2 seconds; tests
    ///     pass a small value to avoid waiting the full production interval.
    ///   - playbackOverride: Test-only item playback seam. Production passes nil
    ///     and uses musicController.
    init(
        queue: SongRequestQueue = SongRequestQueue(),
        blocklist: SongBlocklist = SongBlocklist(),
        musicController: any AppleMusicControlling = AppleMusicController(),
        searchResolver: SongSearchResolver? = nil,
        pollInterval: Duration = .seconds(2),
        playbackOverride: ((SongRequestItem) async throws -> Void)? = nil
    ) {
        self.queue = queue
        self.blocklist = blocklist
        self.musicController = musicController
        self.searchResolver = searchResolver ?? SongSearchResolver(musicController: musicController)
        self.pollInterval = pollInterval
        self.playbackOverride = playbackOverride
    }

    // MARK: - Lifecycle

    /// Begins watching Apple Music playback and the Music.app launch state.
    ///
    /// Installs lightweight launch/queue observers. The 2-second auto-advance
    /// polling task exists only while auto-advance is enabled, hold is off, and
    /// the live queue has a pending or current request.
    ///
    /// - Important: Idempotent. Calling twice cancels and re-creates observers.
    func startPlaybackMonitoring() {
        stopPlaybackMonitoring()
        isPlaybackMonitoringEnabled = true

        // Watch for Music.app launching so buffered requests flush automatically.
        musicAppLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == AppConstants.Music.bundleIdentifier else { return }
            Task { await self?.handleMusicAppLaunched() }
        }

        // Queue mutations already publish this notification. Use it to keep the
        // 2-second task completely absent while there is no queued/current request.
        queueChangeObserver = NotificationCenter.default.addObserver(
            forName: .songRequestQueueChanged,
            object: queue,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcilePlaybackMonitoring()
            }
        }

        reconcilePlaybackMonitoring()
    }

    /// Reconciles the polling task after a queue or playback-setting change.
    /// The settings view calls this after updating its `@AppStorage` binding.
    /// A stopped service remains stopped; reconciliation never starts lifecycle.
    func reconcilePlaybackMonitoring() {
        updatePlaybackPolling()
    }

    /// Starts or stops the auto-advance task to match current queue activity.
    /// Pending-approval items do not need playback observation until approved.
    private func updatePlaybackPolling() {
        let hasLiveRequest = queue.nowPlaying != nil || !queue.isEmpty
        let needsPolling = isPlaybackMonitoringEnabled
            && isAutoAdvanceEnabled
            && !isHoldEnabled
            && hasLiveRequest
        guard needsPolling else {
            playbackObserver?.cancel()
            playbackObserver = nil
            return
        }
        guard playbackObserver == nil else { return }

        playbackObserver = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                // Auto-advance polling is not time-critical. A 20% tolerance lets
                // macOS coalesce the wakeup (0.4s at the default 2s cadence).
                do {
                    try await Task.sleep(
                        for: self.pollInterval,
                        tolerance: self.pollInterval / 5)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.pollTick()
            }
        }
    }

    /// One auto-advance poll evaluation: reads a playback snapshot and applies
    /// the advance / takeover / fallback rules. The monitoring loop calls this
    /// every `pollInterval`.
    ///
    /// Internal (not private) on purpose: tests drive ticks through this method
    /// directly, so debounce and yield behavior is asserted per-tick instead of
    /// racing the wall-clock polling task (which gets starved on loaded CI hosts).
    func pollTick() async {
        guard isAutoAdvanceEnabled else { return }
        guard !isHoldEnabled else { return }
        // Music.app closed: nothing to advance, and probing player state
        // would relaunch the app the user just quit. Buffered requests
        // flush via the didLaunchApplication observer when Music reopens.
        guard musicController.isMusicAppRunning else { return }

        // Idle early-out: with no request playing and an empty queue there is
        // nothing to advance or take over, so skip the AppleScript round trip
        // entirely (these are NSLock-guarded in-memory reads). Reset the streak
        // counters so the two-consecutive-reads debounce restarts cleanly when
        // activity resumes.
        if queue.nowPlaying == nil, queue.isEmpty {
            resetTakeoverTracking()
            resetRequestPlaybackTracking()
            stoppedPollStreak = 0
            return
        }

        // One atomic read of player state + the loaded track's identity.
        // A nil snapshot means the AppleScript read failed this tick
        // (Apple Events to Music.app time out intermittently on macOS 26):
        // treat it as "no information" and skip the tick entirely, so a
        // flaky read can never be mistaken for a stop or a track change and
        // cut a song off mid-play. Streak counters are left untouched so a
        // single dropped read doesn't reset an in-progress debounce.
        guard let snapshot = await musicController.playbackSnapshot() else { return }

        // Debounce stopped detection: require two consecutive stopped reads
        // before advancing/taking over, so one flaky read can't skip a track.
        let confirmedStopped: Bool
        if snapshot.state == .stopped {
            stoppedPollStreak += 1
            confirmedStopped = stoppedPollStreak >= pollConfirmations
        } else {
            stoppedPollStreak = 0
            confirmedStopped = false
        }

        if queue.nowPlaying != nil {
            // A request is playing.
            resetTakeoverTracking()

            // Playback clearly stopped (two reads): advance, or drain.
            if confirmedStopped {
                resetRequestPlaybackTracking()
                if !queue.isEmpty {
                    await advanceQueue()
                } else {
                    await handleQueueEmptied()
                }
                return
            }

            // Still playing: hand off to the next request the moment the
            // request's own track is replaced: the request ended and Music
            // autoplayed the next track, or the streamer skipped inside
            // Music.app. Music never reports "stopped" in either case.
            if snapshot.state == .playing {
                await handleRequestPlaybackDivergence(currentKey: snapshot.trackKey)
            }
            return
        }

        // No request is playing.
        resetRequestPlaybackTracking()

        // Nothing to do unless requests wait.
        guard !queue.isEmpty else {
            resetTakeoverTracking()
            return
        }

        if confirmedStopped || isPlayingFallback {
            // Silence, or the fallback playlist is filling: start the first
            // queued request. The fallback is explicit filler that yields to
            // a real request right away.
            resetTakeoverTracking()
            await advanceQueue()
        } else if snapshot.state == .playing {
            // The streamer's own track is playing. Honor "play when the
            // current song ends": remember the loaded track, then take over
            // only once it changes to a different, confirmed track, never on
            // a single transient read that would cut the song off mid-play.
            await handleStreamerTrackTakeover(currentKey: snapshot.trackKey)
        }
        // Paused, or an unconfirmed stopped read: wait.
    }

    /// Stops the polling task and removes the Music.app/queue observers.
    /// Safe to call when no monitoring is active.
    func stopPlaybackMonitoring() {
        isPlaybackMonitoringEnabled = false
        playbackObserver?.cancel()
        playbackObserver = nil
        if let observer = musicAppLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            musicAppLaunchObserver = nil
        }
        if let observer = queueChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            queueChangeObserver = nil
        }
    }

    // MARK: - Song Request Processing

    /// Resolves a query into a track, runs blocklist + queue validation, and
    /// either enqueues or starts playback as appropriate.
    ///
    /// Used by `SongRequestCommand` (`!sr`), channel-point redemptions, and
    /// bit cheers. The `RequestAudience` gate applies only to chat commands.
    /// Redemptions are gated by their own enable toggle.
    ///
    /// - Parameters:
    ///   - query: Search string, Apple Music link, Spotify link, or YouTube link.
    ///   - username: Twitch login of the requester (legacy callers may pass a display name).
    ///   - displayName: Optional display name, checked against legacy blocklist entries.
    ///   - source: How the request arrived (chat command, channel points, bits).
    /// - Returns: A `RequestResult` describing the outcome (added, blocked,
    ///   queue-full, not-found, etc.)
    func processRequest(
        query: String, username: String, source: RequestSource, displayName: String? = nil
    ) async -> RequestResult {
        guard !Task.isCancelled else { return .cancelled }

        // Master gate. The settings UI hides itself when this is off, but the
        // `!sr` command, channel-point reward, and bit handler can each still
        // fire from their own independent toggles, so the only safe place to
        // enforce "feature off = no requests" is this shared chokepoint.
        guard isFeatureEnabled else { return .featureDisabled }

        if case .chatCommand(let context) = source {
            let audience = chatAudience
            if !audience.permits(context) {
                return .error(audience.denialMessage)
            }
        }

        // A blocked person is blocked whatever they ask for and however they
        // ask, so this runs before the audience-agnostic paths and before any
        // MusicKit lookup is spent on them.
        let requesterLogin: String
        let requesterDisplayName: String
        if case .chatCommand(let context) = source {
            requesterLogin = context.requesterLogin
            requesterDisplayName = context.username
        } else {
            requesterLogin = username
            requesterDisplayName = displayName ?? username
        }
        let blockedLogin = await blocklist.isBlockedRequester(requesterLogin)
        let blockedDisplayName = await blocklist.isBlockedRequester(requesterDisplayName)
        if blockedLogin || blockedDisplayName {
            guard !Task.isCancelled else { return .cancelled }
            return .blocked
        }

        guard musicController.isAuthorized || musicController.authStatus == .notDetermined else {
            return .notAuthorized
        }

        let searchResult = await searchResolver.resolve(query: query)
        guard !Task.isCancelled else { return .cancelled }

        switch searchResult {
        case .found(let song):
            let isBlocked = await blocklist.isBlocked(title: song.title, artist: song.artistName)
            guard !Task.isCancelled else { return .cancelled }
            if isBlocked {
                return .blocked
            }

            // Sub/VIP queue-jump perk (WW-43). Only chat requests carry badges;
            // channel-point / bit redemptions have none, so they never gain
            // priority. The flag rides on the item so an approved-from-pending
            // request keeps its jump. Cooldown-skip is enforced upstream in the
            // dispatcher, so this only cares about the queue-jump tier.
            let isPriority: Bool
            if case .chatCommand(let context) = source {
                isPriority = SongRequestPriority.mode().jumpsQueue && SongRequestPriority.qualifies(context)
            } else {
                isPriority = false
            }
            let item = SongRequestItem(song: song, requesterUsername: requesterLogin, isPriority: isPriority)

            // Approval mode: park the resolved request in the holding pen and let
            // the streamer approve/reject it from the Queue pane. The per-user and
            // capacity gates run at approval time via `queue.addApproved`.
            if isApprovalRequired {
                guard !Task.isCancelled else { return .cancelled }
                switch queue.addPending(item) {
                case .added:
                    return .pendingApproval(item: item)
                case .queueFull(let max):
                    return .queueFull(max: max)
                case .alreadyInQueue:
                    return .alreadyInQueue
                case .userLimitReached(let max):
                    // Defensive only: addPending is not per-user capped today, so
                    // this never fires. Handled because AddResult is shared with add(_:).
                    return .userLimitReached(max: max)
                }
            }

            // Resolve the requester's per-user limit from their roles. Chat
            // requests use the sender's badges; channel-point / bit requests have
            // no chat badges, so they fall back to the everyone tier.
            let effectiveUserLimit: Int
            if case .chatCommand(let context) = source {
                effectiveUserLimit = SongRequestLimits.effectiveLimit(
                    isSubscriber: context.isSubscriber,
                    isVIP: context.isVIP,
                    isModerator: context.isModerator,
                    isBroadcaster: context.isBroadcaster
                )
            } else {
                effectiveUserLimit = SongRequestLimits.nonChatLimit()
            }
            guard !Task.isCancelled else { return .cancelled }
            let addResult = queue.add(item, perUserLimit: effectiveUserLimit)

            switch addResult {
            case .added(let position):
                if musicController.isMusicAppRunning && !isHoldEnabled && queue.nowPlaying == nil {
                    // Start now only from an idle or fallback state; never interrupt
                    // the streamer's actively-playing track (or act on a flaky read).
                    // When a track is playing, the poll takes over at its boundary.
                    if !Task.isCancelled {
                        await startImmediatelyIfIdle()
                    }
                }
                // else: a request is already playing, Music.app is closed, or hold is
                // active; the request stays buffered for the poll / launch flush.
                return .added(item: item, position: position)
            case .queueFull(let max):
                return .queueFull(max: max)
            case .userLimitReached(let max):
                return .userLimitReached(max: max)
            case .alreadyInQueue:
                return .alreadyInQueue
            }

        case .notFound(let query):
            return .notFound(query: query)
        case .linkNotFound:
            return .linkNotFound
        case .error(let message):
            return .error(message)
        }
    }

    /// Skips the now-playing track and immediately starts the next queued
    /// request. Falls back to the drain policy (fallback playlist / autoplay /
    /// silence) when the queue empties.
    ///
    /// The current request is not discarded until its replacement has started
    /// and committed. A failed replacement leaves queue state intact.
    ///
    /// - Returns: What the skip did. Only ``SkipOutcome/drained`` means the
    ///   queue is really empty; ``SkipOutcome/busy`` and
    ///   ``SkipOutcome/retained`` mean nothing was skipped.
    @discardableResult
    func skip() async -> SkipOutcome {
        guard !Task.isCancelled else { return .retained }
        // Take the playback-transition guard so the auto-advance poll can't
        // interleave a second dequeue across the native playback await.
        guard !isNativeClearInFlight, !isStartingPlayback else { return .busy }
        isStartingPlayback = true

        let result: SkipOutcome
        guard !queue.isEmpty else {
            isStartingPlayback = false
            await handleQueueEmptied()
            await reconcilePendingClearIfNeeded()
            return .drained
        }

        let generation = playbackGeneration
        if let next = await playNextInQueueUnguarded(generation: generation) {
            resetTakeoverTracking()
            resetRequestPlaybackTracking()
            Log.debug("SongRequestService: Skipped to \"\(next.title)\"", category: .songRequest)
            result = .started(next)
        } else {
            // Read the queue synchronously, right after the attempt returns and
            // before any further await. Unplayable items may have been dropped
            // on the way, so an empty queue here is a genuine drain; a
            // non-empty one means the head was kept for a retry.
            result = queue.isEmpty ? .drained : .retained
        }
        isStartingPlayback = false
        await reconcilePendingClearIfNeeded()
        return result
    }

    /// Notes an observed Music track change before AppDelegate dispatches any
    /// unstructured vote-manager work.
    ///
    /// Bumping the revision invalidates every ``PlaybackTarget`` captured before
    /// the change, so a vote opened on the old song can't skip the new one.
    /// Wraps on overflow; only equality matters.
    func notePlaybackTrackChanged() {
        playbackRevision &+= 1
    }

    /// Captures the exact Music track and current in-process revision for a new
    /// vote. The revision is rechecked after the snapshot await.
    ///
    /// - Returns: `nil` when Music is closed, the read failed, no track is loaded,
    ///   or the track changed while the snapshot was in flight.
    func capturePlaybackTarget() async -> PlaybackTarget? {
        let revision = playbackRevision
        guard let snapshot = await musicController.playbackSnapshot(),
              revision == playbackRevision,
              let trackKey = snapshot.trackKey,
              !trackKey.isEmpty
        else {
            return nil
        }
        return PlaybackTarget(trackKey: trackKey, revision: revision)
    }

    /// Applies a passed vote only while Music.app still has `target` loaded.
    ///
    /// Queue policy is selected before the await, but neither the pending head
    /// nor now-playing/fallback state is committed until the controller's single
    /// PID-targeted AppleScript event reports that it performed the mutation.
    ///
    /// Action choice: the next queued request if any; otherwise, while a request
    /// is playing, the drain policy (fallback playlist, then autoplay-on as
    /// `next track`, then stop); otherwise a plain `next track` past the
    /// streamer's own song.
    ///
    /// - Returns: `true` when Music changed tracks and the queue state was
    ///   committed; `false` for a stale target, a busy or cancelled service, a
    ///   failed command, or a clear that landed during the command.
    @discardableResult
    func voteSkip(target: PlaybackTarget) async -> Bool {
        guard !Task.isCancelled,
              target.revision == playbackRevision,
              !isNativeClearInFlight,
              !isStartingPlayback
        else {
            return false
        }
        isStartingPlayback = true
        let generation = playbackGeneration

        let reservedItem = queue.peekNext()
        let action: TargetedPlaybackAction
        if let reservedItem {
            action = .request(reservedItem)
        } else if queue.nowPlaying != nil {
            let fallback = DefaultsStore.store.string(
                forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist) ?? ""
            if !fallback.isEmpty, !isHoldEnabled {
                action = .fallbackPlaylist(name: fallback)
            } else if isAutoplayWhenEmptyEnabled, !isHoldEnabled {
                // Natural queue drain still leaves autoplay alone. A passed vote
                // must actively advance the voted request to the next Music item.
                action = .nextTrack
            } else {
                action = .stop
            }
        } else {
            action = .nextTrack
        }

        let didMutate: Bool
        do {
            guard !Task.isCancelled else {
                isStartingPlayback = false
                await reconcilePendingClearIfNeeded()
                return false
            }
            didMutate = try await musicController.performTargetedPlayback(
                action,
                ifCurrentTrackKeyEquals: target.trackKey)
        } catch {
            Log.debug(
                "SongRequestService: Target-bound vote-skip failed: \(error)",
                category: .songRequest)
            didMutate = false
        }

        // A successful Music mutation can synchronously trigger the monitor and
        // advance playbackRevision before this await resumes. The atomic script
        // already proved the target; only queue-clear generation remains valid
        // as a post-command gate.
        guard didMutate, generation == playbackGeneration
        else {
            if generation != playbackGeneration {
                await stopPlaybackStartedBeforeClear()
            }
            isStartingPlayback = false
            await reconcilePendingClearIfNeeded()
            return false
        }

        if let reservedItem {
            guard queue.commitNext(id: reservedItem.id) != nil else {
                await runCoalescedNativeClear()
                isStartingPlayback = false
                await reconcilePendingClearIfNeeded()
                return false
            }
            playAttemptCounts[reservedItem.id] = nil
            isPlayingFallback = false
        } else {
            queue.clearNowPlaying()
            if case .fallbackPlaylist = action {
                isPlayingFallback = true
            } else {
                isPlayingFallback = false
            }
        }

        resetTakeoverTracking()
        resetRequestPlaybackTracking()
        isStartingPlayback = false
        await reconcilePendingClearIfNeeded()
        return true
    }

    /// Removes every request from the queue and clears Music.app's player.
    ///
    /// Invalidates any playback await already in flight. If that stale operation
    /// later succeeds, it observes the new generation and stops Music again.
    ///
    /// - Returns: Number of items that were in the queue before clearing.
    func clearQueue() async -> Int {
        guard !Task.isCancelled else { return 0 }
        playbackGeneration &+= 1
        let generation = playbackGeneration
        pendingClearReconciliationGeneration = nil
        let count = queue.clear()
        resetTakeoverTracking()
        resetRequestPlaybackTracking()
        playAttemptCounts.removeAll()
        isPlayingFallback = false

        let operation = beginNativeClear()
        await operation.task.value

        // Only the newest overlapping clear publishes completion. An older
        // waiter must not release the shared gate or reconcile state erased by a
        // later clear.
        guard generation == playbackGeneration else { return count }
        releaseNativeClear(operation.id)
        pendingClearReconciliationGeneration = generation
        await reconcilePendingClearIfNeeded()
        return count
    }

    /// Bit-cheer boost: moves the cheerer's oldest queued request to the
    /// front, then starts it immediately when nothing from the request queue is
    /// playing (idle player or the fallback playlist is filling). Without this
    /// kick, a boost over a fallback playlist would silently sit until the
    /// fallback track happened to end. Returns the boosted item, or `nil` when
    /// the user has nothing queued or the feature is off.
    @discardableResult
    func boost(username: String) async -> SongRequestItem? {
        guard !Task.isCancelled else { return nil }
        guard isFeatureEnabled else { return nil }
        guard !Task.isCancelled else { return nil }
        guard let boosted = queue.boost(username: username) else { return nil }
        if musicController.isMusicAppRunning, !isHoldEnabled, queue.nowPlaying == nil {
            resetTakeoverTracking()
            guard !Task.isCancelled else { return boosted }
            await startImmediatelyIfIdle()
        }
        return boosted
    }

    // MARK: - Approval

    /// Number of requests waiting for approval.
    var pendingApprovalCount: Int { queue.pendingCount }

    /// Approve a held request: move it into the live queue and start it if idle.
    /// No-op (returns `nil`) when the ID is unknown or the queue is full.
    ///
    /// On a full queue the request goes back into the pending pen and chat is
    /// told it's still pending. On success chat gets an "Approved" line.
    @discardableResult
    func approve(id: UUID) async -> SongRequestItem? {
        guard let item = queue.takePending(id: id) else { return nil }
        guard case .added = queue.addApproved(item) else {
            // Live queue is full: put the request back in the pending pen so the
            // streamer can retry once a slot frees up, instead of losing it.
            queue.addPending(item)
            sendChatMessage?("Couldn't queue \"\(item.title)\". The queue is full. Still pending; approve again once there's room.")
            return nil
        }
        if musicController.isMusicAppRunning, !isHoldEnabled, queue.nowPlaying == nil {
            resetTakeoverTracking()
            await startImmediatelyIfIdle()
        }
        sendChatMessage?("Approved: \"\(item.title)\" by \(item.artist) (requested by \(item.requesterUsername))")
        return item
    }

    /// Reject a held request and drop it, posting a "Request declined" chat line.
    /// Returns the removed item, or `nil` when the ID is unknown.
    @discardableResult
    func reject(id: UUID) -> SongRequestItem? {
        guard let item = queue.takePending(id: id) else { return nil }
        sendChatMessage?("Request declined: \"\(item.title)\" (\(item.requesterUsername))")
        return item
    }

    /// Drops the request that is playing right now and moves on, telling chat
    /// why so the requester isn't left wondering.
    ///
    /// Distinct from ``skip()``, which advances playback and says nothing: this
    /// is the streamer rejecting *this request*, and a silent removal reads to
    /// the requester like the bot ate their song.
    ///
    /// - Returns: The rejected item, or `nil` when no request is playing.
    @discardableResult
    func rejectCurrent() async -> SongRequestItem? {
        guard let current = queue.nowPlaying else { return nil }
        sendChatMessage?(
            "Request removed: \"\(current.title)\" by \(current.artist) (\(current.requesterUsername))"
        )
        // Skip after announcing. Skipping first would start the replacement and
        // its own "Now playing" line, putting the two messages out of order.
        await skip()
        return current
    }

    // MARK: - Private Helpers

    /// Returns the active native clear or starts one. No `await` occurs between
    /// the state check and installation, so overlapping clear callers coalesce.
    private func beginNativeClear() -> (id: Int, task: Task<Void, Never>) {
        if let nativeClearOperation {
            return nativeClearOperation
        }
        nativeClearOperationSequence &+= 1
        let id = nativeClearOperationSequence
        let task = Task { await self.musicController.clearPlayerQueue() }
        let operation = (id: id, task: task)
        nativeClearOperation = operation
        return operation
    }

    /// Releases only the native clear operation the caller actually awaited.
    /// This identity check prevents an older completion from clearing a newer
    /// operation's playback gate.
    private func releaseNativeClear(_ id: Int) {
        guard nativeClearOperation?.id == id else { return }
        nativeClearOperation = nil
    }

    /// Runs one clear, coalescing with an operation already in flight.
    private func runCoalescedNativeClear() async {
        let operation = beginNativeClear()
        await operation.task.value
        releaseNativeClear(operation.id)
        await reconcilePendingClearIfNeeded()
    }

    /// A playback command that began before `clearQueue()` can complete after
    /// the user's native clear. Wait for that command, then issue one serialized
    /// cleanup clear after it so the stale song cannot revive. Request playback
    /// remains guarded until this caller releases `isStartingPlayback`.
    private func stopPlaybackStartedBeforeClear() async {
        if isNativeClearInFlight {
            await runCoalescedNativeClear()
        }
        await runCoalescedNativeClear()
    }

    /// Starts a request that arrived after the latest clear, once both the
    /// native clear and any pre-clear playback command are fully settled.
    private func reconcilePendingClearIfNeeded() async {
        guard let generation = pendingClearReconciliationGeneration,
              generation == playbackGeneration,
              !isNativeClearInFlight,
              !isStartingPlayback
        else {
            return
        }
        pendingClearReconciliationGeneration = nil
        guard musicController.isMusicAppRunning,
              !isHoldEnabled,
              queue.nowPlaying == nil,
              !queue.isEmpty
        else {
            return
        }

        // Re-check ownership after the snapshot await inside this helper. If a
        // newer clear began, its own completion owns reconciliation.
        if isPlayingFallback {
            guard generation == playbackGeneration, !isNativeClearInFlight else { return }
            await playNextInQueue()
            return
        }
        guard let snapshot = await musicController.playbackSnapshot() else { return }
        guard generation == playbackGeneration,
              !isNativeClearInFlight,
              snapshot.state != .playing
        else {
            return
        }
        await playNextInQueue()
    }

    /// Starts the just-added (or just-boosted) request immediately, but only from
    /// a state where doing so won't cut a song off mid-play.
    ///
    /// Starts now when the fallback playlist is filling (explicit filler that
    /// yields to a real request) or when nothing is actively playing (silent or
    /// paused). When the streamer's own track is actively playing, or the
    /// playback read is inconclusive (`nil`), this does nothing, and the
    /// auto-advance poll starts the request at the next confirmed track boundary.
    /// That is the "wait until the current song ends" rule, applied at the entry
    /// point so a request never interrupts a live read that happened to flake.
    private func startImmediatelyIfIdle() async {
        guard !isNativeClearInFlight else { return }
        if isPlayingFallback {
            await playNextInQueue()
            return
        }
        // A nil snapshot is an inconclusive read: don't risk interrupting; let the
        // poll take over at the next confirmed boundary.
        guard let snapshot = await musicController.playbackSnapshot() else { return }
        guard snapshot.state != .playing else { return }
        await playNextInQueue()
    }

    /// Boundary detection for the takeover poll: starts the first queued request
    /// once the streamer's own track changes.
    ///
    /// Ignores an unknown (`nil`) track key: a failed metadata read is "no
    /// information", never a boundary, and requires the new track to be seen on
    /// `pollConfirmations` reads in a row, so a single transient read can't be
    /// mistaken for a song change and cut the streamer's track off mid-play.
    private func handleStreamerTrackTakeover(currentKey: String?) async {
        guard let currentKey else {
            // A track is loaded but its identity couldn't be read this tick. Hold
            // the baseline and wait; never treat "unknown" as "the song changed".
            return
        }
        guard let baseline = takeoverBaselineTrackID else {
            // First read with the streamer's track loaded: baseline it.
            takeoverBaselineTrackID = currentKey
            takeoverDivergenceStreak = 0
            return
        }
        guard currentKey != baseline else {
            // Same song still loaded: reset any in-progress divergence streak.
            takeoverDivergenceStreak = 0
            return
        }
        takeoverDivergenceStreak += 1
        guard takeoverDivergenceStreak >= pollConfirmations else { return }
        resetTakeoverTracking()
        await advanceQueue()
    }

    /// Boundary detection while a request is playing: advances to the next queued
    /// request once the request's own track is replaced (it ended and Music
    /// autoplayed on, or the streamer skipped inside Music.app). Same `nil`
    /// tolerance and two-in-a-row confirmation as `handleStreamerTrackTakeover`.
    private func handleRequestPlaybackDivergence(currentKey: String?) async {
        guard let currentKey else { return }
        guard let baseline = playingRequestTrackID else {
            // First playing tick for this request: establish the divergence
            // baseline from whatever Music.app loaded.
            playingRequestTrackID = currentKey
            requestDivergenceStreak = 0
            return
        }
        guard currentKey != baseline else {
            requestDivergenceStreak = 0
            return
        }
        requestDivergenceStreak += 1
        guard requestDivergenceStreak >= pollConfirmations else { return }
        resetRequestPlaybackTracking()
        if !queue.isEmpty {
            await advanceQueue()
        } else {
            await handleQueueEmptied()
        }
    }

    /// Optimistically starts the current queue head and commits it only after
    /// Music.app accepts the playback command.
    ///
    /// Guarded against reentrancy: the `isStartingPlayback` check and set happen
    /// with no `await` between them, so two near-simultaneous callers cannot both
    /// reserve and start the same slot.
    @discardableResult
    func playNextInQueue() async -> SongRequestItem? {
        guard !isNativeClearInFlight, !isStartingPlayback else { return nil }
        isStartingPlayback = true
        let result = await playNextInQueueUnguarded(generation: playbackGeneration)
        isStartingPlayback = false
        await reconcilePendingClearIfNeeded()
        return result
    }

    /// Body of `playNextInQueue` without the reentrancy guard, so the
    /// skip-unplayable retry can recurse without deadlocking on the guard.
    /// Callers must already hold `isStartingPlayback`.
    ///
    /// Failure handling: Music closed, cancellation, and command failures keep
    /// the head for a later retry; `notPlayable` keeps it until
    /// `maxPlayAttempts`, then drops it with a chat notice and tries the next
    /// item; any other error drops the item silently and tries the next. The
    /// queue head remains present across the playback await. Any intervening
    /// clear, remove, move, or boost wins: the stale start is stopped and cannot
    /// rewrite the user's newer queue state.
    @discardableResult
    private func playNextInQueueUnguarded(generation: Int) async -> SongRequestItem? {
        guard let item = queue.peekNext() else { return nil }

        do {
            try await performPlayback(for: item)
            guard generation == playbackGeneration else {
                await stopPlaybackStartedBeforeClear()
                Log.warn(
                    "SongRequestService: Stopped stale playback start for \"\(item.title)\" after queue clear",
                    category: .songRequest
                )
                return nil
            }
            guard let committed = queue.commitNext(id: item.id) else {
                await runCoalescedNativeClear()
                Log.warn(
                    "SongRequestService: Stopped stale playback start for \"\(item.title)\" after queue changed",
                    category: .songRequest
                )
                guard generation == playbackGeneration else { return nil }
                return await playNextInQueueUnguarded(generation: generation)
            }
            playAttemptCounts[item.id] = nil
            isPlayingFallback = false
            Log.debug(
                "SongRequestService: Now playing",
                category: .songRequest,
                fields: [
                    "title": item.title,
                    "artist": item.artist,
                    "requester": item.requesterUsername
                ])
            return committed
        } catch {
            guard generation == playbackGeneration else {
                await stopPlaybackStartedBeforeClear()
                return nil
            }

            if error is CancellationError {
                Log.debug(
                    "SongRequestService: Playback start was cancelled; retained \"\(item.title)\" at queue head",
                    category: .songRequest
                )
                return nil
            }

            switch error {
            case PlaybackError.musicAppNotRunning:
                Log.debug(
                    "SongRequestService: Music.app closed, retained \"\(item.title)\" at queue head",
                    category: .songRequest
                )
                return nil

            case PlaybackError.notPlayable(let title):
                let attempts = (playAttemptCounts[item.id] ?? 0) + 1
                if attempts >= maxPlayAttempts {
                    playAttemptCounts[item.id] = nil
                    guard queue.removeNext(id: item.id) != nil else { return nil }
                    Log.debug(
                        "SongRequestService: Dropping track, unavailable or no subscription",
                        category: .songRequest,
                        fields: ["title": title, "attempt": attempts]
                    )
                    sendChatMessage?("Couldn't play \"\(title)\" (not available on Apple Music). Skipping it.")
                    return await playNextInQueueUnguarded(generation: generation)
                }
                playAttemptCounts[item.id] = attempts
                Log.debug(
                    "SongRequestService: Track not ready, retained at head",
                    category: .songRequest,
                    fields: ["title": title, "attempt": attempts, "limit": maxPlayAttempts]
                )
                return nil

            case PlaybackError.commandFailed(let command, let message):
                Log.warn(
                    "SongRequestService: \(command) failed for \"\(item.title)\": \(message); retained at head",
                    category: .songRequest
                )
                return nil

            default:
                Log.debug("SongRequestService: Failed to play \"\(item.title)\": \(error)", category: .songRequest)
                guard queue.removeNext(id: item.id) != nil else { return nil }
                return await playNextInQueueUnguarded(generation: generation)
            }
        }
    }

    /// Routes playback through a narrow injectable seam for deterministic race
    /// tests. Every item carries a `Song`, so there is no unplayable-item branch
    /// to get wrong here (see `SongRequestItem.song`).
    private func performPlayback(for item: SongRequestItem) async throws {
        if let playbackOverride {
            try await playbackOverride(item)
            return
        }
        try await musicController.playNow(song: item.song)
    }

    /// Advances to the next queued track when the current request finishes,
    /// or kicks off the fallback playlist if the queue has run dry.
    private func advanceQueue() async {
        guard !queue.isEmpty else {
            await handleQueueEmptied()
            return
        }
        isPlayingFallback = false
        if let started = await playNextInQueue() {
            sendChatMessage?("Now playing: \"\(started.title)\" by \(started.artist) (requested by \(started.requesterUsername))")
        }
    }

    /// Decides what happens once the request queue runs dry. Previously the poll
    /// just cleared now-playing and let Music.app do whatever, so the fallback
    /// playlist never started on a normal drain and "Resume Autoplay When Empty"
    /// did nothing. Now: play the configured fallback playlist if set; otherwise
    /// either leave Apple Music autoplaying (toggle on) or stop for silence
    /// (toggle off). Honors hold mode and never relaunches a closed Music.app.
    private func handleQueueEmptied() async {
        guard !isNativeClearInFlight else { return }
        queue.clearNowPlaying()
        guard !isHoldEnabled, musicController.isMusicAppRunning else { return }
        if !queue.isEmpty {
            await playNextInQueue()
            return
        }

        let fallback = DefaultsStore.store
            .string(forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist) ?? ""
        if !fallback.isEmpty {
            await startFallbackIfConfigured()
        } else if isAutoplayWhenEmptyEnabled {
            isPlayingFallback = false
            Log.debug("SongRequestService: Queue empty, Apple Music continues normally", category: .songRequest)
        } else {
            await runCoalescedNativeClear()
            isPlayingFallback = false
            Log.debug("SongRequestService: Queue empty, autoplay off, stopping playback", category: .songRequest)
        }
    }

    /// Called when Music.app starts. Flushes the first buffered request (or
    /// starts the fallback playlist) after a 500 ms grace period so Music.app
    /// has time to initialize its AppleScript surface.
    ///
    /// If a request was marked now-playing when Music quit and Music now reports
    /// stopped, the drain path runs so the stale now-playing slot is cleared.
    /// Gates are re-checked after the grace sleep because settings can change in it.
    func handleMusicAppLaunched() async {
        guard isFeatureEnabled, isAutoAdvanceEnabled else { return }
        Log.debug("SongRequestService: Music.app launched, flushing buffered requests", category: .songRequest)
        // Give Music.app a moment to finish launching before sending commands
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled, isFeatureEnabled, isAutoAdvanceEnabled else { return }
        guard !isHoldEnabled else {
            Log.debug("SongRequestService: Hold enabled, skipping flush on Music.app launch", category: .songRequest)
            return
        }
        if queue.nowPlaying == nil {
            if !queue.isEmpty {
                await playNextInQueue()
            } else {
                await startFallbackIfConfigured()
            }
        } else if let snapshot = await musicController.playbackSnapshot(), snapshot.state == .stopped {
            guard !Task.isCancelled, isFeatureEnabled, isAutoAdvanceEnabled, !isHoldEnabled else { return }
            await handleQueueEmptied()
        }
    }

    /// Plays the user-configured fallback playlist when the queue is empty,
    /// so the stream is never silent. No-op when no playlist is configured
    /// or hold mode is active.
    ///
    /// Takes the `isStartingPlayback` guard for the command; if a clear lands
    /// while it runs, the started playlist is stopped instead of being marked live.
    private func startFallbackIfConfigured() async {
        guard !isNativeClearInFlight, !isStartingPlayback, !isHoldEnabled else { return }
        let name = DefaultsStore.store.string(forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist) ?? ""
        guard !name.isEmpty else { return }
        guard musicController.isMusicAppRunning else { return }
        isStartingPlayback = true
        let generation = playbackGeneration
        var didStart = false
        do {
            try await musicController.playFallbackPlaylist(name: name)
            didStart = true
        } catch {
            Log.debug("SongRequestService: Failed to start fallback playlist: \(error)", category: .songRequest)
        }
        if generation != playbackGeneration {
            await stopPlaybackStartedBeforeClear()
        } else if didStart {
            isPlayingFallback = true
            Log.debug("SongRequestService: Fallback playlist '\(name)' playing", category: .songRequest)
        }
        isStartingPlayback = false
        await reconcilePendingClearIfNeeded()
    }
}
