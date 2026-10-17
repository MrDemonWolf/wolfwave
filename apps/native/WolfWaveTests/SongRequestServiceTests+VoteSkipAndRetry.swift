//
//  SongRequestServiceTests+VoteSkipAndRetry.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import MusicKit
import XCTest

@testable import WolfWave

/// Vote-skip wiring, NotPlayable retry-to-drop, fallback yielding to a request, and chat messages on queue advance.
extension SongRequestServiceTests {
    // MARK: - VoteSkip

    func testVoteSkipIdleCallsSkipToNext() async {
        // With nothing in nowPlaying, a passed vote should forward straight to
        // Apple Music's own skip (so vote-skip works during normal streaming).
        mockController.isMusicAppRunning = true
        mockController.isPlaying = true
        mockController.currentTrackID = "Playing\tArtist"

        await service.captureAndVoteSkip()

        XCTAssertTrue(mockController.skipCalled, "voteSkip with empty nowPlaying must call skipToNext()")
    }

    func testVoteSkipLastRequestWithAutoplayAdvancesMusic() async {
        // Natural queue drain leaves Music autoplay alone, but a passed vote
        // against the last request must actively advance off the voted track.
        _ = queue.add(makeTestRequestItem(title: "Playing", artist: "A", requesterUsername: "user1"))
        queue.dequeue()  // nowPlaying = "Playing"
        XCTAssertNotNil(queue.nowPlaying, "Precondition: a request must be in nowPlaying")
        mockController.currentTrackID = "Playing\tA"

        await service.captureAndVoteSkip()

        XCTAssertTrue(mockController.skipCalled)
        XCTAssertNil(queue.nowPlaying)
    }

    func testVoteSkipLastRequestUsesTargetedFallback() async {
        DefaultsStore.store.set(
            "Gaming Vibes",
            forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)
        let current = makeTestRequestItem(
            title: "Playing", artist: "A", requesterUsername: "viewer")
        _ = queue.add(current)
        queue.dequeue()
        mockController.currentTrackID = "Playing\tA"

        await service.captureAndVoteSkip()

        XCTAssertTrue(mockController.playFallbackCalled)
        XCTAssertEqual(mockController.fallbackPlaylistName, "Gaming Vibes")
        XCTAssertNil(queue.nowPlaying)
    }

    func testVoteSkipLastRequestStopsWhenAutoplayIsDisabled() async {
        DefaultsStore.store.set(
            false,
            forKey: AppConstants.UserDefaults.songRequestAutoplayWhenEmpty)
        let current = makeTestRequestItem(
            title: "Playing", artist: "A", requesterUsername: "viewer")
        _ = queue.add(current)
        queue.dequeue()
        mockController.currentTrackID = "Playing\tA"

        await service.captureAndVoteSkip()

        XCTAssertTrue(mockController.clearCalled)
        XCTAssertNil(queue.nowPlaying)
    }

    /// A vote-skip bound to one track must not act if the playing track changes while it is
    /// suspended: the controller's targeted handler refuses, the skip reports failure, and the
    /// replacement track and queue are left alone.
    func testTargetedVoteSkipDoesNotReplaceTrackOrCommitQueueAfterTargetChanges() async {
        let gate = PlaybackGate()
        let current = makeTestRequestItem(
            title: "Current", artist: "Artist", requesterUsername: "first")
        let queued = makeTestRequestItem(
            title: "Queued", artist: "Artist", requesterUsername: "second")
        _ = queue.add(current)
        _ = queue.add(queued)
        queue.dequeue()
        mockController.currentTrackID = "Current\tArtist"
        guard let target = await service.capturePlaybackTarget() else {
            return XCTFail("Expected a playback target")
        }
        XCTAssertEqual(target, PlaybackTarget(trackKey: "Current\tArtist", revision: 0))

        mockController.targetedPlaybackHandler = { [weak mockController] action, targetKey in
            await gate.suspend()
            guard mockController?.currentTrackID == targetKey else { return false }
            if case .request = action {
                mockController?.playNowCalled = true
            }
            return true
        }

        let skipping = Task {
            await self.service.voteSkip(target: target)
        }
        await gate.waitUntilStarted()
        mockController.currentTrackID = "Replacement\tArtist"
        service.notePlaybackTrackChanged()
        await gate.release()

        let didSkip = await skipping.value
        XCTAssertFalse(didSkip)
        XCTAssertEqual(mockController.currentTrackID, "Replacement\tArtist")
        XCTAssertFalse(mockController.playNowCalled)
        XCTAssertEqual(queue.nowPlaying?.id, current.id)
        XCTAssertEqual(queue.items.map(\.id), [queued.id])
    }

    /// A successful targeted skip commits the reserved queue head even when the playback
    /// monitor reports the track change (caused by the skip itself) before the call returns.
    func testSuccessfulTargetedVoteCommitsReservedHeadAfterOwnTrackCallback() async {
        let gate = PlaybackGate()
        let current = makeTestRequestItem(
            title: "Current", artist: "Artist", requesterUsername: "first")
        let queued = makeTestRequestItem(
            title: "Queued", artist: "Artist", requesterUsername: "second")
        _ = queue.add(current)
        _ = queue.add(queued)
        queue.dequeue()
        mockController.currentTrackID = "Current\tArtist"
        guard let target = await service.capturePlaybackTarget() else {
            return XCTFail("Expected a playback target")
        }

        mockController.targetedPlaybackHandler = { action, targetKey in
            await gate.suspend()
            guard targetKey == "Current\tArtist" else { return false }
            guard case .request(let item) = action else { return false }
            return item.id == queued.id
        }

        let skipping = Task {
            await self.service.voteSkip(target: target)
        }
        await gate.waitUntilStarted()
        // The successful Music command can make the playback monitor observe
        // its own replacement before this task resumes.
        service.notePlaybackTrackChanged()
        await gate.release()

        let didSkip = await skipping.value
        XCTAssertTrue(didSkip)
        XCTAssertEqual(queue.nowPlaying?.id, queued.id)
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: - NotPlayable Retry-to-Drop

    /// A track that is not playable on Apple Music is retried, and on the third failed attempt
    /// is dropped with a chat message naming it; the next request then plays.
    func testNotPlayableRetryDropsSendsChatMessage() async {
        var badSongAttempts = 0
        service = SongRequestService(
            queue: queue,
            musicController: mockController,
            playbackOverride: { item in
                guard item.title == "Unavailable" else { return }
                badSongAttempts += 1
                throw PlaybackError.notPlayable(title: item.title)
            }
        )
        var capturedMessages: [String] = []
        service.sendChatMessage = { capturedMessages.append($0) }

        let unavailable = makeTestRequestItem(
            title: "Unavailable", artist: "A", requesterUsername: "u1")
        let playable = makeTestRequestItem(
            title: "Playable", artist: "B", requesterUsername: "u2")
        _ = queue.add(unavailable)
        _ = queue.add(playable)

        let firstAttempt = await service.playNextInQueue()
        let secondAttempt = await service.playNextInQueue()
        XCTAssertNil(firstAttempt)
        XCTAssertNil(secondAttempt)
        let result = await service.playNextInQueue()

        XCTAssertEqual(badSongAttempts, 3)
        XCTAssertEqual(result?.id, playable.id)
        XCTAssertEqual(queue.nowPlaying?.id, playable.id)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(capturedMessages.count, 1)
        let message = capturedMessages.first ?? ""
        XCTAssertTrue(message.contains("Unavailable"))
        XCTAssertTrue(message.contains("not available on Apple Music"))
    }

    func testNoAdvanceChatMessageWhenQueueDrainsOnStop() async {
        // When the last request finishes and the queue empties, advanceQueue is
        // not called (handleQueueEmptied is called instead), so no "Now playing:" message.
        service = SongRequestService(
            queue: queue,
            musicController: mockController,
            pollInterval: .milliseconds(20)
        )
        var capturedMessages: [String] = []
        service.sendChatMessage = { capturedMessages.append($0) }

        mockController.isMusicAppRunning = true
        mockController.isPlaying = true

        _ = queue.add(makeTestRequestItem(title: "Last", artist: "A", requesterUsername: "u1"))
        queue.dequeue()  // nowPlaying = "Last", queue now empty

        service.startPlaybackMonitoring()

        // Two confirmed-stopped ticks → handleQueueEmptied, no advance message.
        mockController.isPlaying = false
        mockController.isPaused = false
        mockController.snapshotProvider = { PlaybackSnapshot(state: .stopped, trackKey: nil) }

        let gotUnexpectedMessage = await waitUntil(timeout: .seconds(1)) {
            capturedMessages.contains { $0.hasPrefix("Now playing:") }
        }
        service.stopPlaybackMonitoring()

        XCTAssertFalse(
            gotUnexpectedMessage,
            "No 'Now playing:' message should be sent when the queue drains to empty")
    }

    // MARK: - Fallback Yields to Request

    func testFallbackYieldsToIncomingRequest() async {
        // Once isPlayingFallback is true, a request added to the queue takes over
        // on the very next poll tick (the fallback explicitly yields to real requests).
        // Seeding isPlayingFallback requires a prior request to finish: add an item,
        // dequeue it into nowPlaying, then stop playback so handleQueueEmptied fires
        // and starts the fallback. Then add a new request and confirm it takes over.
        //
        // Drives pollTick() directly instead of startPlaybackMonitoring(): the
        // wall-clock poll Task is MainActor-bound and gets starved under parallel
        // CI load, so even a 3s waitUntil flaked (PR #341, run 27247125149).
        // Direct ticks make the debounce counts exact and remove all timing.
        DefaultsStore.store.set(
            "Gaming Vibes", forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)

        mockController.isMusicAppRunning = true
        mockController.isPlaying = true
        mockController.currentTrackID = "req-track"

        // Seed nowPlaying with an item so the poll is in the "request playing" branch.
        _ = queue.add(makeTestRequestItem(title: "Finishing", artist: "A", requesterUsername: "u1"))
        queue.dequeue()

        // One playing tick establishes the request baseline, then stop playback.
        await service.pollTick()
        mockController.snapshotProvider = { PlaybackSnapshot(state: .stopped, trackKey: nil) }

        // Two confirmed stopped ticks → handleQueueEmptied → startFallbackIfConfigured.
        await service.pollTick()
        await service.pollTick()
        guard mockController.playFallbackCalled else {
            XCTFail("Precondition: fallback should start once the last request finishes")
            DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)
            return
        }

        // isPlayingFallback is now true. Add a request and verify the very next
        // poll tick dequeues it (fallback yields to a real request immediately).
        _ = queue.add(makeTestRequestItem(title: "RequestedSong", artist: "B", requesterUsername: "viewer"))
        await service.pollTick()

        XCTAssertEqual(
            queue.nowPlaying?.title, "RequestedSong",
            "A request added while the fallback is playing should take over on the next poll tick (fallback yields)")

        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)
    }

    func testFallbackYieldsViaIsPlayingFallbackFlag() async {
        // Mirror of testFallbackYieldsToIncomingRequest using a different playlist
        // name, to confirm the dequeue is driven by the isPlayingFallback flag
        // (not just a stopped-state coincidence). Same deterministic pollTick()
        // driving; see the sibling test for the CI-flake rationale.
        DefaultsStore.store.set(
            "Chill Mix", forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)

        mockController.isMusicAppRunning = true
        mockController.isPlaying = true
        mockController.currentTrackID = "req-track"

        _ = queue.add(makeTestRequestItem(title: "LastReq", artist: "A", requesterUsername: "u1"))
        queue.dequeue()

        // Baseline playing tick, then two confirmed stopped ticks start the fallback.
        await service.pollTick()
        mockController.snapshotProvider = { PlaybackSnapshot(state: .stopped, trackKey: nil) }
        await service.pollTick()
        await service.pollTick()
        guard mockController.playFallbackCalled else {
            XCTFail("Precondition: fallback must activate before the request is added")
            DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)
            return
        }

        // isPlayingFallback = true. Switch the snapshot back to *playing* so the
        // stopped-debounce can't be what dequeues; only the isPlayingFallback
        // branch can take over on the next tick.
        mockController.snapshotProvider = { PlaybackSnapshot(state: .playing, trackKey: "fallback-track") }
        _ = queue.add(makeTestRequestItem(title: "LiveRequest", artist: "B", requesterUsername: "fan"))
        await service.pollTick()

        XCTAssertEqual(
            queue.nowPlaying?.title, "LiveRequest",
            "A request added while isPlayingFallback is true should dequeue on the next tick even if music is playing")

        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)
    }

    // MARK: - SendChatMessage on Queue Advance

    func testSendChatMessageFiresOnAdvanceWithNowPlayingInfo() async {
        // advanceQueue() sends "Now playing: <title> by <artist> (requested by <user>)".
        // Verify the message contains all three pieces of info.
        service = SongRequestService(
            queue: queue,
            musicController: mockController,
            pollInterval: .milliseconds(20)
        )
        var capturedMessages: [String] = []
        service.sendChatMessage = { capturedMessages.append($0) }

        mockController.isMusicAppRunning = true
        mockController.isPlaying = true
        mockController.currentTrackID = "playing-A"

        _ = queue.add(makeTestRequestItem(title: "Howl at the Moon", artist: "Wolf Pack", requesterUsername: "fanviewer"))
        _ = queue.add(makeTestRequestItem(title: "Midnight Run", artist: "Luna", requesterUsername: "nightowl"))
        queue.dequeue()  // nowPlaying = "Howl at the Moon", "Midnight Run" still queued

        service.startPlaybackMonitoring()

        // Let the first poll tick establish playingRequestTrackID = "playing-A"
        // before switching the track, so the poll sees a real divergence. A
        // second snapshot call proves the first tick finished handling its
        // "playing-A" read (ticks run serially).
        let polled = await waitUntil(timeout: .seconds(1)) {
            self.mockController.playbackSnapshotCallCount >= 2
        }
        XCTAssertTrue(polled, "The playback poll should tick before the track changes")

        // Trigger divergence: Music.app loads a different track → advanceQueue fires.
        mockController.currentTrackID = "playing-B"

        let gotMessage = await waitUntil(timeout: .seconds(1)) {
            capturedMessages.contains { $0.hasPrefix("Now playing:") }
        }
        service.stopPlaybackMonitoring()

        XCTAssertTrue(gotMessage, "A 'Now playing:' chat message must fire when the queue advances")
        let message = capturedMessages.first { $0.hasPrefix("Now playing:") } ?? ""
        XCTAssertTrue(message.contains("Midnight Run"), "Chat message must include the new track title")
        XCTAssertTrue(message.contains("Luna"), "Chat message must include the new artist name")
        XCTAssertTrue(message.contains("nightowl"), "Chat message must include the requester username")
    }

    func testSendChatMessageFiresOnHoldRelease() async {
        // setHold(false) also sends a "Now playing:" message when there's a
        // buffered request waiting. Verify this independently of the poll loop.
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.songRequestHoldEnabled)
        var capturedMessages: [String] = []
        service.sendChatMessage = { capturedMessages.append($0) }

        mockController.isMusicAppRunning = true
        mockController.isPlaying = false
        mockController.isPaused = false

        _ = queue.add(makeTestRequestItem(title: "Released Track", artist: "SomeArtist", requesterUsername: "waitingfan"))
        // Do not dequeue: nowPlaying is nil, item is queued, hold is on.
        XCTAssertNil(queue.nowPlaying, "Precondition: nothing playing while hold is on")

        await service.setHold(false)

        // After hold releases, playNextInQueue fires: the controller plays the
        // item's song, the item commits into nowPlaying, and setHold sends the
        // "Now playing:" message.
        XCTAssertTrue(mockController.playNowCalled, "Hold release must actually start the buffered request")
        let sentMessage = capturedMessages.contains { $0.hasPrefix("Now playing:") }
        XCTAssertTrue(sentMessage, "'Now playing:' message must be sent when hold is released with a buffered request")
        XCTAssertTrue(
            capturedMessages.first { $0.hasPrefix("Now playing:") }?.contains("Released Track") == true,
            "Hold-release message must name the dequeued track")
    }
}
