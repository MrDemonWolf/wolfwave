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
    var playbackObserver: Task<Void, Never>?
    /// True only between explicit `startPlaybackMonitoring` / stop lifecycle calls.
    var isPlaybackMonitoringEnabled = false

    /// `NSWorkspace` launch observer that flushes buffered requests when Music.app starts.
    var musicAppLaunchObserver: NSObjectProtocol?
    /// `.songRequestQueueChanged` observer that starts / stops the polling task.
    var queueChangeObserver: NSObjectProtocol?

    /// Interval between auto-advance polls. Injectable so tests can use a small
    /// value instead of waiting the full production cadence.
    let pollInterval: Duration

    /// Reentrancy guard for `playNextInQueue()`. Set and checked with no
    /// intervening `await`, so two near-simultaneous callers (e.g. two
    /// `processRequest` calls while Music.app is closed) can't both dequeue and
    /// start playback for the same slot.
    var isStartingPlayback = false

    /// Invalidates every playback operation that began before clearQueue().
    /// Successful stale starts are stopped instead of being committed back into
    /// a queue the user explicitly cleared.
    var playbackGeneration = 0

    /// Synchronously advanced by AppDelegate before it asynchronously tells the
    /// vote manager about an observed track change. A poll target captures this
    /// revision so actor scheduling cannot briefly make an old target look live.
    var playbackRevision: UInt64 = 0

    /// One native clear shared by every overlapping `clearQueue()` caller.
    /// Keeping the operation installed until the latest clear waiter publishes
    /// its result also gates every other Music.app mutation while clear runs.
    var nativeClearOperation: (id: Int, task: Task<Void, Never>)?
    /// Monotonic id source for `nativeClearOperation`, so a release can tell
    /// its own operation from a newer one.
    var nativeClearOperationSequence = 0

    /// The latest completed clear that still needs to start a request which
    /// arrived after that clear. A pre-clear playback command may still be
    /// suspended; in that case reconciliation waits until its stale cleanup has
    /// finished so an older completion cannot erase the replacement request.
    var pendingClearReconciliationGeneration: Int?

    /// True only while a native Music.app clear command is active.
    var isNativeClearInFlight: Bool {
        nativeClearOperation != nil
    }

    /// Small test seam for suspending or failing item playback without needing
    /// to manufacture a MusicKit Song. Production leaves this nil and routes
    /// through AppleMusicControlling.playNow(song:).
    let playbackOverride: ((SongRequestItem) async throws -> Void)?

    /// Track key (name + tab + artist, see `PlaybackSnapshot.trackKey`) of the
    /// streamer's own song that a queued request is waiting to follow. Set the first time the poll notices a pending request
    /// while the streamer's own (non-request, non-fallback) track is playing,
    /// then cleared once that track changes so the request takes over. This is
    /// what implements the "play when the current song ends" takeover policy
    /// instead of interrupting a track mid-play.
    var takeoverBaselineTrackID: String?

    /// Consecutive poll ticks that have read Music.app as stopped. The poll
    /// requires two in a row before advancing or taking over, so a single
    /// transient "stopped" read can't trigger a spurious skip mid-track. (A
    /// failed read is a `nil` snapshot and skips the tick without touching this.)
    var stoppedPollStreak = 0

    /// Track key (name + tab + artist, not Music's persistent ID, which flakes for
    /// streamed tracks) Music.app loaded for the request that is currently
    /// playing. Established on the first poll tick after a request starts, then
    /// compared against Music.app's live current track. If they diverge while
    /// playback continues, the request either finished (Music autoplayed the next
    /// track) or the streamer hit skip inside Music.app. Either way the request is
    /// done, so the next queued request takes over instead of leaving a
    /// non-request track parked on the now-playing slot forever.
    var playingRequestTrackID: String?

    /// Consecutive poll ticks the loaded track has differed from the takeover
    /// baseline (the streamer's own track a request is waiting to follow). Like
    /// `stoppedPollStreak`, a track change must be seen on two reads in a row
    /// before the queue takes over, so a single transient AppleScript read can't
    /// trigger a spurious takeover that cuts the streamer's song off mid-play.
    var takeoverDivergenceStreak = 0

    /// Consecutive poll ticks the loaded track has differed from the playing
    /// request's baseline. Same two-in-a-row debounce as `takeoverDivergenceStreak`,
    /// applied to the "request finished / streamer skipped" hand-off.
    var requestDivergenceStreak = 0

    /// Number of consecutive confirming reads a stop or track change needs before
    /// the queue acts on it. Two ≈ one extra poll interval of latency at a track
    /// boundary (unnoticeable) in exchange for immunity to a single flaky read.
    let pollConfirmations = 2

    /// Clears the takeover-detection debounce: the streamer-track baseline and
    /// its divergence streak. Kept granular (never merged with
    /// ``resetRequestPlaybackTracking()``) so each poll branch resets exactly the
    /// state it owns. Does not touch `stoppedPollStreak`. Not for the
    /// baseline-establishment sites, which set `takeoverBaselineTrackID` to the
    /// current key rather than nil.
    func resetTakeoverTracking() {
        takeoverBaselineTrackID = nil
        takeoverDivergenceStreak = 0
    }

    /// Clears the playing-request debounce: the tracked request track ID and its
    /// divergence streak.
    func resetRequestPlaybackTracking() {
        playingRequestTrackID = nil
        requestDivergenceStreak = 0
    }

    /// Whether the fallback playlist is currently playing (no active requests).
    var isPlayingFallback = false

    /// Per-item count of consecutive failed play attempts. A request can fail to
    /// play because its track is still syncing down from iCloud Music Library
    /// right after being added; keeping a count lets the poll retry a few times
    /// before giving up on one that never becomes playable (e.g. a song that
    /// isn't available or the streamer has no active subscription).
    var playAttemptCounts: [UUID: Int] = [:]

    /// Maximum play attempts before a stuck request is dropped with a chat notice.
    let maxPlayAttempts = 3

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
}
