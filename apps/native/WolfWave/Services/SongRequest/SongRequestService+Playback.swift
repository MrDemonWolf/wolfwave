//
//  SongRequestService+Playback.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Playback internals: native queue-clear coalescing, takeover and divergence
/// tracking, starting the next request, and the empty-queue drain policy.
extension SongRequestService {

    // MARK: - Private Helpers

    /// Returns the active native clear or starts one. No `await` occurs between
    /// the state check and installation, so overlapping clear callers coalesce.
    func beginNativeClear() -> (id: Int, task: Task<Void, Never>) {
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
    func releaseNativeClear(_ id: Int) {
        guard nativeClearOperation?.id == id else { return }
        nativeClearOperation = nil
    }

    /// Runs one clear, coalescing with an operation already in flight.
    func runCoalescedNativeClear() async {
        let operation = beginNativeClear()
        await operation.task.value
        releaseNativeClear(operation.id)
        await reconcilePendingClearIfNeeded()
    }

    /// A playback command that began before `clearQueue()` can complete after
    /// the user's native clear. Wait for that command, then issue one serialized
    /// cleanup clear after it so the stale song cannot revive. Request playback
    /// remains guarded until this caller releases `isStartingPlayback`.
    func stopPlaybackStartedBeforeClear() async {
        if isNativeClearInFlight {
            await runCoalescedNativeClear()
        }
        await runCoalescedNativeClear()
    }

    /// Starts a request that arrived after the latest clear, once both the
    /// native clear and any pre-clear playback command are fully settled.
    func reconcilePendingClearIfNeeded() async {
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
    func startImmediatelyIfIdle() async {
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
    func handleStreamerTrackTakeover(currentKey: String?) async {
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
    func handleRequestPlaybackDivergence(currentKey: String?) async {
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
    func playNextInQueueUnguarded(generation: Int) async -> SongRequestItem? {
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
    func advanceQueue() async {
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
    func handleQueueEmptied() async {
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
