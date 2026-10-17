//
//  SongRequestServiceTests+FallbackAndHold.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import MusicKit
import XCTest

@testable import WolfWave

/// The fallback playlist and hold mode.
extension SongRequestServiceTests {
    // MARK: - Fallback Playlist

    func testFallbackPlaylistPlaysWhenQueueEmpties() async {
        DefaultsStore.store.set(
            "Gaming Vibes", forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)
        mockController.isMusicAppRunning = true

        _ = await service.clearQueue()

        XCTAssertFalse(
            mockController.playFallbackCalled, "clearQueue should not trigger fallback playlist")

        DefaultsStore.store.removeObject(
            forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)
    }

    func testSkippingLastRequestStartsConfiguredFallback() async {
        DefaultsStore.store.set(
            "Gaming Vibes",
            forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)
        mockController.isMusicAppRunning = true
        let current = makeTestRequestItem(
            title: "Last request", artist: "Artist", requesterUsername: "viewer")
        _ = queue.add(current)
        queue.dequeue()

        let replacement = await service.skip()

        XCTAssertEqual(replacement, .drained)
        XCTAssertNil(queue.nowPlaying)
        XCTAssertTrue(mockController.playFallbackCalled)
        XCTAssertEqual(mockController.fallbackPlaylistName, "Gaming Vibes")

        DefaultsStore.store.removeObject(
            forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)
    }

    func testClearQueueDoesNotStartFallback() async {
        DefaultsStore.store.set(
            "Gaming Vibes", forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)
        _ = queue.add(makeTestRequestItem(title: "Song 1", artist: "A", requesterUsername: "user1"))

        _ = await service.clearQueue()

        XCTAssertFalse(
            mockController.playFallbackCalled, "clearQueue should never auto-start fallback playlist")
        XCTAssertTrue(mockController.clearCalled, "clearQueue should stop Music.app")

        DefaultsStore.store.removeObject(
            forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)
    }

    // MARK: - Hold Mode

    func testHoldBlocksAutoPlayOnRequest() async {
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.songRequestHoldEnabled)
        mockController.stubSearchSuccess()
        mockController.isMusicAppRunning = true
        mockController.isPlaying = false

        let result = await service.processRequest(
            query: "song", username: "viewer", source: chatSource())

        // Every other condition in the auto-play gate is deliberately satisfied
        // above (Music running, nothing playing, request queued), so hold is the
        // only thing left that can stop playback. Without the `.added` check the
        // request resolved to `.notFound` and this asserted nothing at all.
        guard case .added = result else {
            return XCTFail("request did not queue, so the hold gate was never reached: \(result)")
        }
        XCTAssertFalse(mockController.playNowCalled, "Hold should block auto-play on new requests")
    }

    func testAutoPlayFiresWhenHoldIsOff() async {
        // The control for `testHoldBlocksAutoPlayOnRequest`. Identical setup with
        // hold off must reach playNow, which is what proves the assertion above
        // is about hold and not about some unrelated short-circuit.
        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.songRequestHoldEnabled)
        mockController.stubSearchSuccess()
        mockController.isMusicAppRunning = true
        mockController.isPlaying = false

        let result = await service.processRequest(
            query: "song", username: "viewer", source: chatSource())

        guard case .added = result else {
            return XCTFail("request did not queue: \(result)")
        }
        XCTAssertTrue(mockController.playNowCalled, "with hold off an idle Music should start the request")
    }

    func testSetHoldTogglesFlag() async {
        await service.setHold(true)
        XCTAssertTrue(service.isHoldEnabled)
        await service.setHold(false)
        XCTAssertFalse(service.isHoldEnabled)
    }

    func testHoldBlocksFallbackStart() async {
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.songRequestHoldEnabled)
        DefaultsStore.store.set(
            "Gaming Vibes", forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)

        _ = await service.clearQueue()
        XCTAssertFalse(
            mockController.playFallbackCalled, "No fallback should start while hold is enabled")

        DefaultsStore.store.removeObject(
            forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)
    }

    func testRequestWaitsForStreamersOwnTrackToEnd() async {
        // A request is queued while the streamer's own track is playing. Policy:
        // don't cut it off mid-song; take over the moment that track changes.
        service = SongRequestService(
            queue: queue,
            musicController: mockController,
            pollInterval: .milliseconds(20)
        )

        mockController.isMusicAppRunning = true
        mockController.isPlaying = true
        mockController.isPaused = false
        mockController.currentTrackID = "streamer-track-A"

        _ = queue.add(makeTestRequestItem(title: "Requested", artist: "A", requesterUsername: "viewer"))

        service.startPlaybackMonitoring()

        // While the streamer's track is unchanged, the request must not take over.
        let tookOverEarly = await waitUntil(timeout: .milliseconds(300)) {
            self.queue.nowPlaying != nil
        }
        XCTAssertFalse(tookOverEarly, "Request must not interrupt the streamer's own track mid-song")

        // The streamer's track ends and Music advances → request takes over.
        mockController.currentTrackID = "streamer-track-B"
        let tookOver = await waitUntil(timeout: .seconds(1)) {
            self.queue.nowPlaying?.title == "Requested"
        }
        service.stopPlaybackMonitoring()

        XCTAssertTrue(tookOver, "Request should take over once the current track ends")
    }

    func testFlakyTrackReadDoesNotInterruptStreamerSong() async {
        // Regression for the "request cut my song off mid-play" bug. On macOS 26,
        // Apple Events to Music.app time out intermittently, so a mid-song read can
        // come back with no loaded-track identity even though the streamer's song
        // is still playing. The old takeover logic treated that empty/nil read as
        // "the song changed" and started the request immediately. It must not.
        service = SongRequestService(
            queue: queue,
            musicController: mockController,
            pollInterval: .milliseconds(20)
        )
        mockController.isMusicAppRunning = true

        // "streamer-A" plays the whole time, but every third read flakes: a nil
        // whole-snapshot (timed-out script) or a nil track key (track loaded,
        // metadata unread). Neither is a real track boundary.
        var reads = 0
        mockController.snapshotProvider = {
            reads += 1
            switch reads % 3 {
            case 0: return nil  // whole AppleScript read failed this tick
            case 1: return PlaybackSnapshot(state: .playing, trackKey: nil)  // key unread
            default: return PlaybackSnapshot(state: .playing, trackKey: "streamer-A")
            }
        }

        _ = queue.add(makeTestRequestItem(title: "Requested", artist: "A", requesterUsername: "viewer"))
        service.startPlaybackMonitoring()

        // Across many poll ticks of flaky reads, the request must never take over.
        let tookOver = await waitUntil(timeout: .milliseconds(400)) {
            self.queue.nowPlaying != nil || self.mockController.playNowCalled
        }
        service.stopPlaybackMonitoring()

        XCTAssertFalse(tookOver, "A flaky or empty track read must not be mistaken for a song change")
        XCTAssertNil(queue.nowPlaying, "The streamer's song must keep playing until it actually ends")
    }

    func testSingleTransientTrackChangeDoesNotTakeOver() async {
        // A genuine boundary is two confirming reads of a new track. A single stray
        // different-track read that immediately reverts to the streamer's track is
        // noise, not a boundary, and must not trigger a takeover.
        service = SongRequestService(
            queue: queue,
            musicController: mockController,
            pollInterval: .milliseconds(20)
        )
        mockController.isMusicAppRunning = true

        // Pattern A, A, B (one stray), A, A, A... never two B's in a row.
        var reads = 0
        mockController.snapshotProvider = {
            reads += 1
            let key = (reads == 3) ? "streamer-B" : "streamer-A"
            return PlaybackSnapshot(state: .playing, trackKey: key)
        }

        _ = queue.add(makeTestRequestItem(title: "Requested", artist: "A", requesterUsername: "viewer"))
        service.startPlaybackMonitoring()

        let tookOver = await waitUntil(timeout: .milliseconds(400)) {
            self.queue.nowPlaying != nil
        }
        service.stopPlaybackMonitoring()

        XCTAssertFalse(tookOver, "A single transient track-id blip must not trigger a takeover")
        XCTAssertFalse(mockController.playNowCalled, "No blip may reach the controller")
    }

    func testBoostDoesNotInterruptStreamersPlayingTrack() async {
        // Boost routes through the same idle-only fast path as a new request
        // (`startImmediatelyIfIdle`): it reorders the queue but must NOT cut off the
        // streamer's actively-playing track. A takeover, if any, happens later at
        // the boundary via the poll, never as an immediate interrupt on the add.
        service = SongRequestService(
            queue: queue,
            musicController: mockController,
            pollInterval: .seconds(10)  // isolate the boost fast path from the poll
        )
        mockController.isMusicAppRunning = true
        mockController.isPlaying = true
        mockController.currentTrackID = "streamer-A"
        _ = queue.add(makeTestRequestItem(title: "A", artist: "x", requesterUsername: "alice"))

        let boosted = await service.boost(username: "alice")

        XCTAssertEqual(boosted?.title, "A")
        XCTAssertFalse(mockController.playNowCalled, "Boost must not interrupt the streamer's playing track")
        XCTAssertNil(queue.nowPlaying, "Boosted request must wait, not take over immediately")
    }

    func testBoostStartsImmediatelyWhenPlayerIsIdle() async {
        // The flip side: when nothing is actively playing, the boost fast path does
        // start the request right away (no song to wait for).
        service = SongRequestService(
            queue: queue,
            musicController: mockController,
            pollInterval: .seconds(10)
        )
        mockController.isMusicAppRunning = true
        mockController.isPlaying = false  // idle / stopped
        mockController.isPaused = false
        _ = queue.add(makeTestRequestItem(title: "A", artist: "x", requesterUsername: "alice"))

        let boosted = await service.boost(username: "alice")

        XCTAssertEqual(boosted?.title, "A")
        // Idle → the request is pulled into the now-playing slot immediately.
        XCTAssertEqual(queue.nowPlaying?.title, "A", "Boost should start the request from an idle player")
    }

    func testSkipInsideMusicAppAdvancesRequestQueue() async {
        // A request is playing. The streamer hits skip inside Music.app (or the
        // track ends and Music autoplays the next one): Music never reports
        // "stopped", it just loads a different track. The queue must hand off to
        // the next queued request instead of stalling on the gone track.
        service = SongRequestService(
            queue: queue,
            musicController: mockController,
            pollInterval: .milliseconds(20)
        )

        _ = queue.add(makeTestRequestItem(title: "Current", artist: "A", requesterUsername: "user1"))
        _ = queue.add(makeTestRequestItem(title: "Next", artist: "B", requesterUsername: "user2"))
        queue.dequeue()  // nowPlaying = "Current", "Next" still queued

        mockController.isMusicAppRunning = true
        mockController.isPlaying = true
        mockController.isPaused = false
        mockController.currentTrackID = "request-track-current"

        service.startPlaybackMonitoring()

        // While Music.app stays on the request's own track, no advance.
        let advancedEarly = await waitUntil(timeout: .milliseconds(300)) {
            self.queue.nowPlaying?.title != "Current"
        }
        XCTAssertFalse(advancedEarly, "Request must not advance while its own track is still loaded")

        // Streamer skips inside Music.app → a different track loads, still playing.
        mockController.currentTrackID = "some-autoplay-track"
        let advanced = await waitUntil(timeout: .seconds(1)) {
            self.queue.nowPlaying?.title == "Next"
        }
        service.stopPlaybackMonitoring()

        // Advancing now-playing to the next queued item is the proof the
        // divergence handoff fired, and the item only commits after the
        // controller accepts its song.
        XCTAssertTrue(advanced, "Skipping inside Music.app should advance to the next queued request")
        XCTAssertEqual(queue.nowPlaying?.title, "Next")
        XCTAssertTrue(mockController.playNowCalled, "The handoff must actually start the next request")
    }

    func testAutoAdvanceDoesNotFireWhenPaused() async {
        // Inject a fast poll cadence so the monitor cycles many times within a
        // short, bounded wait instead of the 2s production interval.
        service = SongRequestService(
            queue: queue,
            musicController: mockController,
            pollInterval: .milliseconds(20)
        )

        _ = queue.add(makeTestRequestItem(title: "Next Song", artist: "A", requesterUsername: "user1"))
        _ = queue.add(makeTestRequestItem(title: "Current", artist: "B", requesterUsername: "user2"))
        queue.dequeue()

        mockController.isPlaying = false
        mockController.isPaused = true

        service.startPlaybackMonitoring()
        // Negative assertion: poll for the *forbidden* advance. The wait spans
        // many poll cycles, so a false return proves the paused state never
        // advanced (rather than just not having waited long enough).
        let advanced = await waitUntil(timeout: .milliseconds(400)) {
            self.mockController.playNowCalled || self.queue.nowPlaying?.title != "Next Song"
        }
        service.stopPlaybackMonitoring()

        XCTAssertFalse(advanced, "Auto-advance must not fire while Music.app is paused")
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.items.first?.title, "Current")
        XCTAssertEqual(queue.nowPlaying?.title, "Next Song")
    }

    /// With an empty queue the monitor owns no periodic task (zero snapshot reads); a
    /// queue-change notification wakes polling.
    func testPlaybackMonitorSleepsCompletelyWhileQueueIsIdle() async {
        service = SongRequestService(
            queue: queue,
            musicController: mockController,
            pollInterval: .milliseconds(20)
        )
        mockController.isPlaying = true
        mockController.currentTrackID = "streamer-track"

        service.startPlaybackMonitoring()
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(
            mockController.playbackSnapshotCallCount,
            0,
            "An empty queue should not own a periodic playback task")

        _ = queue.add(makeTestRequestItem(
            title: "Later", artist: "Artist", requesterUsername: "viewer"))
        let beganPolling = await waitUntil(timeout: .seconds(1)) {
            self.mockController.playbackSnapshotCallCount > 0
        }
        service.stopPlaybackMonitoring()

        XCTAssertTrue(beganPolling, "A queue-change notification should activate polling")
    }

    func testUnrelatedQueueChangeDoesNotActivatePlaybackPolling() async {
        service = SongRequestService(
            queue: queue,
            musicController: mockController,
            pollInterval: .milliseconds(20)
        )
        service.startPlaybackMonitoring()

        let unrelatedQueue = SongRequestQueue()
        _ = unrelatedQueue.add(makeTestRequestItem(
            title: "Other", artist: "Artist", requesterUsername: "viewer"))
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(
            mockController.playbackSnapshotCallCount,
            0,
            "A different queue's notification must not wake this service")
    }

    func testStoppingPlaybackMonitorDoesNotPerformFinalPoll() async {
        service = makeServiceWithLiveRequest(pollInterval: .milliseconds(500))

        service.startPlaybackMonitoring()
        // Let the task enter its long sleep, then cancel well before a natural tick.
        try? await Task.sleep(for: .milliseconds(50))
        service.stopPlaybackMonitoring()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(
            mockController.playbackSnapshotCallCount,
            0,
            "Cancelling the sleep must return instead of executing one final poll")
    }

    func testReconcileDoesNotRestartStoppedPlaybackMonitor() async {
        service = makeServiceWithLiveRequest(pollInterval: .milliseconds(500))

        service.startPlaybackMonitoring()
        service.stopPlaybackMonitoring()
        service.reconcilePlaybackMonitoring()
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(
            mockController.playbackSnapshotCallCount,
            0,
            "Reconciliation must not resurrect an explicitly stopped monitor")
    }

    /// Polling follows the auto-advance setting: off means no polling, turning it on and
    /// calling `reconcilePlaybackMonitoring()` starts it, and turning it off cancels it at once.
    func testAutoAdvanceToggleReconcilesPlaybackPolling() async {
        service = makeServiceWithLiveRequest(pollInterval: .milliseconds(20))
        DefaultsStore.store.set(
            false, forKey: AppConstants.UserDefaults.songRequestAutoAdvance)

        service.startPlaybackMonitoring()
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(
            mockController.playbackSnapshotCallCount,
            0,
            "Disabled auto-advance should not own a periodic playback task")

        DefaultsStore.store.set(
            true, forKey: AppConstants.UserDefaults.songRequestAutoAdvance)
        service.reconcilePlaybackMonitoring()
        let beganPolling = await waitUntil(timeout: .seconds(1)) {
            self.mockController.playbackSnapshotCallCount > 0
        }
        XCTAssertTrue(beganPolling, "Enabling auto-advance should start polling")

        DefaultsStore.store.set(
            false, forKey: AppConstants.UserDefaults.songRequestAutoAdvance)
        service.reconcilePlaybackMonitoring()
        let callsAfterDisable = mockController.playbackSnapshotCallCount
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(
            mockController.playbackSnapshotCallCount,
            callsAfterDisable,
            "Disabling auto-advance should cancel polling immediately")
    }

    func testHoldToggleReconcilesPlaybackPolling() async {
        service = makeServiceWithLiveRequest(pollInterval: .milliseconds(20))

        service.startPlaybackMonitoring()
        let beganPolling = await waitUntil(timeout: .seconds(1)) {
            self.mockController.playbackSnapshotCallCount > 0
        }
        XCTAssertTrue(beganPolling)

        await service.setHold(true)
        let callsWhileHolding = mockController.playbackSnapshotCallCount
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(
            mockController.playbackSnapshotCallCount,
            callsWhileHolding,
            "Hold should cancel playback polling immediately")

        await service.setHold(false)
        let resumedPolling = await waitUntil(timeout: .seconds(1)) {
            self.mockController.playbackSnapshotCallCount > callsWhileHolding
        }
        XCTAssertTrue(resumedPolling, "Releasing hold should restore polling")
    }
}
