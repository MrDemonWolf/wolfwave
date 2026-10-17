//
//  SongRequestService+QueueControl.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Streamer and chat actions on the live queue: skip, vote-skip, clear,
/// boost, and the approval holding pen.
extension SongRequestService {

    // MARK: - Queue Control

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
}
