//
//  SongRequestServiceTests+SkipAndQueue.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import MusicKit
import XCTest

@testable import WolfWave

/// Skip outcomes, clearing the queue, and buffering while Music.app is closed.
extension SongRequestServiceTests {
    // MARK: - Skip

    func testSkipEmptyQueueReportsDrained() async {
        let result = await service.skip()
        XCTAssertEqual(result, .drained)
        XCTAssertNil(result.startedItem)
    }

    func testSkipWithQueueItemsAdvancesInternalQueue() async {
        _ = queue.add(makeTestRequestItem(title: "Song A", artist: "Artist", requesterUsername: "user1"))
        _ = queue.add(makeTestRequestItem(title: "Song B", artist: "Artist", requesterUsername: "user2"))
        queue.dequeue()

        let next = await service.skip()
        XCTAssertEqual(next.startedItem?.title, "Song B")
        XCTAssertEqual(queue.nowPlaying?.title, "Song B")
    }

    func testSkipCallsNativeSkip() async {
        // No fallback + autoplay-off → draining the queue via skip stops Music.app.
        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.songRequestAutoplayWhenEmpty)
        _ = queue.add(makeTestRequestItem(title: "Song A", artist: "Artist", requesterUsername: "user1"))
        queue.dequeue()

        _ = await service.skip()
        XCTAssertTrue(mockController.clearCalled)

        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.songRequestAutoplayWhenEmpty)
    }

    // MARK: - ClearQueue

    func testClearQueueReturnsZeroWhenEmpty() async {
        let count = await service.clearQueue()
        XCTAssertEqual(count, 0)
    }

    func testClearQueueReturnsClearedCount() async {
        _ = queue.add(makeTestRequestItem(title: "Song 1", artist: "A", requesterUsername: "user1"))
        _ = queue.add(makeTestRequestItem(title: "Song 2", artist: "B", requesterUsername: "user2"))

        let count = await service.clearQueue()
        XCTAssertEqual(count, 2)
        XCTAssertTrue(queue.isEmpty)
    }

    func testClearQueueAlsoClearsPlayerQueue() async {
        _ = queue.add(makeTestRequestItem(title: "Song 1", artist: "A", requesterUsername: "user1"))

        _ = await service.clearQueue()
        XCTAssertTrue(mockController.clearCalled)
    }

    func testClearRequestsClearsThePlaylistAndStopsRequestPlayback() async {
        _ = queue.add(makeTestRequestItem(title: "Song 1", artist: "A", requesterUsername: "user1"))

        let result = await service.clearQueueAndRequestsPlaylist()

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.requestPlaylistCleared)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertTrue(mockController.clearCalled)
        XCTAssertTrue(mockController.clearRequestsPlaylistCalled)
    }

    func testClearOldRequestsPlaylistLeavesUnrelatedMusicPlaying() async {
        mockController.isPlaying = true

        let result = await service.clearQueueAndRequestsPlaylist()

        XCTAssertEqual(result.count, 0)
        XCTAssertTrue(result.requestPlaylistCleared)
        XCTAssertFalse(mockController.clearCalled)
        XCTAssertTrue(mockController.clearRequestsPlaylistCalled)
    }

    func testPlaylistClearKeepsPlaybackBlockedUntilCleanupFinishes() async throws {
        let service = try XCTUnwrap(self.service)
        mockController.clearRequestsPlaylistHandler = {
            let outcome = await service.skip()
            XCTAssertEqual(outcome, .busy)
        }

        let result = await service.clearQueueAndRequestsPlaylist()

        XCTAssertTrue(result.requestPlaylistCleared)
        XCTAssertFalse(service.isNativeClearInFlight)
    }

    func testPlaylistClearFailureIsReportedAfterQueueIsCleared() async {
        _ = queue.add(makeTestRequestItem(title: "Song 1", artist: "A", requesterUsername: "user1"))
        mockController.shouldThrowClearRequestsPlaylist = true

        let result = await service.clearQueueAndRequestsPlaylist()

        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result.requestPlaylistCleared)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertTrue(mockController.clearCalled)
        XCTAssertTrue(mockController.clearRequestsPlaylistCalled)
    }

    /// `clearQueue()` is parked in the player-queue clear (`PlaybackGate`). A request added
    /// meanwhile must not start until the clear finishes: `playNextInQueue()` returns nil during
    /// the clear, then the new item starts and the controller was cleared once.
    func testRequestAddedDuringSuspendedClearStartsOnlyAfterClearCompletes() async {
        let clearGate = PlaybackGate()
        let startedIDs = ThreadSafeBox<[UUID]>([])
        mockController.clearPlayerQueueHandler = {
            await clearGate.suspend()
        }
        service = SongRequestService(
            queue: queue,
            musicController: mockController,
            playbackOverride: { item in
                startedIDs.mutate { $0.append(item.id) }
            }
        )
        let removed = makeTestRequestItem(
            title: "Removed", artist: "Artist", requesterUsername: "old")
        _ = queue.add(removed)

        let clearing = Task { await self.service.clearQueue() }
        await clearGate.waitUntilStarted()
        let fresh = makeTestRequestItem(
            title: "Fresh", artist: "Artist", requesterUsername: "new")
        _ = queue.add(fresh)

        let startWhileClearing = await service.playNextInQueue()

        XCTAssertNil(startWhileClearing)
        XCTAssertTrue(startedIDs.value.isEmpty)
        XCTAssertEqual(queue.items.map(\.id), [fresh.id])

        await clearGate.release()
        let clearedCount = await clearing.value
        XCTAssertEqual(clearedCount, 1)
        XCTAssertEqual(startedIDs.value, [fresh.id])
        XCTAssertEqual(queue.nowPlaying?.id, fresh.id)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(mockController.clearCallCount, 1)
    }

    /// Two overlapping `clearQueue()` calls share one controller clear (`clearCallCount == 1`),
    /// each reports the one item it removed, and only the newest request is started afterward.
    func testOverlappingClearsCoalesceAndOnlyNewestGenerationReconciles() async {
        let clearGate = PlaybackGate()
        let startedIDs = ThreadSafeBox<[UUID]>([])
        mockController.clearPlayerQueueHandler = {
            await clearGate.suspend()
        }
        service = SongRequestService(
            queue: queue,
            musicController: mockController,
            playbackOverride: { item in
                startedIDs.mutate { $0.append(item.id) }
            }
        )
        let firstRemoved = makeTestRequestItem(
            title: "First removed", artist: "Artist", requesterUsername: "old")
        _ = queue.add(firstRemoved)

        let firstClear = Task { await self.service.clearQueue() }
        await clearGate.waitUntilStarted()

        let secondRemoved = makeTestRequestItem(
            title: "Second removed", artist: "Artist", requesterUsername: "middle")
        _ = queue.add(secondRemoved)
        let secondClear = Task { await self.service.clearQueue() }
        let secondClearStarted = await waitUntil {
            self.queue.isEmpty
        }
        XCTAssertTrue(secondClearStarted)

        let latest = makeTestRequestItem(
            title: "Latest", artist: "Artist", requesterUsername: "new")
        _ = queue.add(latest)
        let startWhileClearing = await service.playNextInQueue()
        XCTAssertNil(startWhileClearing)
        XCTAssertTrue(startedIDs.value.isEmpty)

        await clearGate.release()
        let firstCount = await firstClear.value
        let secondCount = await secondClear.value

        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 1)
        XCTAssertEqual(mockController.clearCallCount, 1)
        XCTAssertEqual(startedIDs.value, [latest.id])
        XCTAssertEqual(queue.nowPlaying?.id, latest.id)
        XCTAssertTrue(queue.isEmpty)
    }
    func testPlaybackFailureLeavesReservedHeadAndCurrentItemUntouched() async {
        let current = makeTestRequestItem(
            title: "Current", artist: "Artist", requesterUsername: "first")
        let reserved = makeTestRequestItem(
            title: "Reserved", artist: "Artist", requesterUsername: "second")
        _ = queue.add(current)
        _ = queue.add(reserved)
        queue.dequeue()
        service = SongRequestService(
            queue: queue,
            musicController: mockController,
            playbackOverride: { _ in
                throw PlaybackError.commandFailed(command: "playNow", message: "timed out")
            }
        )

        let result = await service.playNextInQueue()

        XCTAssertNil(result)
        XCTAssertEqual(queue.nowPlaying?.id, current.id)
        XCTAssertEqual(queue.items.map(\.id), [reserved.id])
    }

    func testSkipWithFailedPlaybackReportsRetainedNotDrained() async {
        let current = makeTestRequestItem(
            title: "Current", artist: "Artist", requesterUsername: "first")
        let reserved = makeTestRequestItem(
            title: "Reserved", artist: "Artist", requesterUsername: "second")
        _ = queue.add(current)
        _ = queue.add(reserved)
        queue.dequeue()
        service = SongRequestService(
            queue: queue,
            musicController: mockController,
            playbackOverride: { _ in
                throw PlaybackError.commandFailed(command: "playNow", message: "timed out")
            }
        )

        let outcome = await service.skip()

        XCTAssertEqual(outcome, .retained)
        XCTAssertEqual(queue.nowPlaying?.id, current.id)
        XCTAssertEqual(queue.items.map(\.id), [reserved.id])
    }

    func testCancelledPlaybackRetainsQueueHead() async {
        let current = makeTestRequestItem(
            title: "Current", artist: "Artist", requesterUsername: "first")
        let reserved = makeTestRequestItem(
            title: "Reserved", artist: "Artist", requesterUsername: "second")
        _ = queue.add(current)
        _ = queue.add(reserved)
        queue.dequeue()
        service = SongRequestService(
            queue: queue,
            musicController: mockController,
            playbackOverride: { _ in throw CancellationError() }
        )

        let result = await service.playNextInQueue()

        XCTAssertNil(result)
        XCTAssertEqual(queue.nowPlaying?.id, current.id)
        XCTAssertEqual(queue.items.map(\.id), [reserved.id])
    }

    /// A clear that lands while a start is still suspended must win: the stale start returns nil,
    /// the queue stays empty with no now-playing item, and Music is stopped a second time to
    /// undo the late successful start.
    func testClearDuringSuspendedPlaybackCannotResurrectRequest() async {
        let gate = PlaybackGate()
        let reserved = makeTestRequestItem(
            title: "Reserved", artist: "Artist", requesterUsername: "viewer")
        _ = queue.add(reserved)
        service = SongRequestService(
            queue: queue,
            musicController: mockController,
            playbackOverride: { _ in await gate.suspend() }
        )

        let playback = Task { await service.playNextInQueue() }
        await gate.waitUntilStarted()
        let cleared = await service.clearQueue()
        await gate.release()
        let result = await playback.value

        XCTAssertEqual(cleared, 1)
        XCTAssertNil(result)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.nowPlaying)
        XCTAssertEqual(
            mockController.clearCallCount, 2,
            "clearQueue stops once immediately and the stale successful start stops again")
    }

    /// If a boost reorders the queue while the head's start is suspended, the old head is
    /// not committed: the service retries with the new head, which becomes now-playing.
    func testReorderDuringSuspendedPlaybackRetriesNewHead() async {
        let gate = PlaybackGate()
        let first = makeTestRequestItem(
            title: "First", artist: "Artist", requesterUsername: "first")
        let second = makeTestRequestItem(
            title: "Second", artist: "Artist", requesterUsername: "second")
        _ = queue.add(first)
        _ = queue.add(second)
        service = SongRequestService(
            queue: queue,
            musicController: mockController,
            playbackOverride: { _ in await gate.suspend() }
        )

        let playback = Task { await service.playNextInQueue() }
        await gate.waitUntilStarted()
        // A bit-cheer boost is the production path that reorders the head.
        queue.boost(username: "second")
        await gate.release()
        let result = await playback.value

        XCTAssertEqual(result?.id, second.id)
        XCTAssertEqual(queue.nowPlaying?.id, second.id)
        XCTAssertEqual(queue.items.map(\.id), [first.id])
        XCTAssertEqual(mockController.clearCallCount, 1)
    }

    // MARK: - Buffered Mode (Music.app closed)

    func testRequestWhileMusicAppClosedBuffers() async {
        mockController.stubSearchSuccess()
        mockController.isMusicAppRunning = false

        let result = await service.processRequest(
            query: "any song", username: "viewer", source: chatSource())

        // Assert the request actually reached the gate. Without this the test
        // passes on a `.notFound` that never touched the Music-closed branch.
        guard case .added = result else {
            return XCTFail("request did not queue, so the Music-closed gate was never reached: \(result)")
        }
        XCTAssertEqual(queue.items.count, 1, "a request arriving with Music closed must stay buffered")
        XCTAssertFalse(mockController.playNowCalled, "playNow should not fire when Music.app is closed")
    }

    func testPlayNextInQueueRequeuesItemWhenMusicAppNotRunning() async {
        mockController.shouldThrowMusicAppNotRunning = true

        _ = queue.add(makeTestRequestItem(
            title: "Buffered Song", artist: "Artist", requesterUsername: "user1"))

        // Actually exercise playNextInQueue. The old version called
        // processRequest instead, which resolved to .notFound, so playNow was
        // never invoked and the requeue-on-throw path could be deleted whole
        // while the test stayed green.
        let started = await service.playNextInQueue()

        XCTAssertTrue(
            mockController.playNowCallCount > 0,
            "guard against vacuity: playNow must actually have been attempted")
        XCTAssertNil(started, "playNow threw musicAppNotRunning, so nothing should be playing")
        XCTAssertNil(queue.nowPlaying, "a throwing start must not leave the item marked as playing")
        XCTAssertEqual(
            queue.items.map(\.title), ["Buffered Song"],
            "the item must be re-queued for the launch flush, not dropped")
    }
}
