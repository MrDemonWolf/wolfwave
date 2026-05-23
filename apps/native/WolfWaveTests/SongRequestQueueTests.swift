//
//  SongRequestQueueTests.swift
//  WolfWaveTests
//
//  Created by MrDemonWolf, Inc. on 4/8/26.
//

import MusicKit
import XCTest

@testable import WolfWave

nonisolated final class SongRequestQueueTests: XCTestCase {
    nonisolated(unsafe) var queue: SongRequestQueue!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        queue = SongRequestQueue()
        // Reset UserDefaults for test isolation
        UserDefaults.standard.removeObject(forKey: AppConstants.UserDefaults.songRequestMaxQueueSize)
        UserDefaults.standard.removeObject(forKey: AppConstants.UserDefaults.songRequestPerUserLimit)
    }

    @MainActor
    override func tearDown() async throws {
        queue = nil
        UserDefaults.standard.removeObject(forKey: AppConstants.UserDefaults.songRequestMaxQueueSize)
        UserDefaults.standard.removeObject(forKey: AppConstants.UserDefaults.songRequestPerUserLimit)
        try await super.tearDown()
    }

    // MARK: - Basic Operations

    @MainActor func testQueueStartsEmpty() {
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.count, 0)
        XCTAssertFalse(queue.isFull)
        XCTAssertNil(queue.nowPlaying)
    }

    @MainActor func testDequeueEmptyReturnsNil() {
        XCTAssertNil(queue.dequeue())
    }

    @MainActor func testSkipWithEmptyQueue() {
        XCTAssertNil(queue.skip())
    }

    @MainActor func testClearEmptyQueue() {
        let count = queue.clear()
        XCTAssertEqual(count, 0)
    }

    // MARK: - User Position Lookup

    @MainActor func testPositionsForUnknownUser() {
        let positions = queue.positions(for: "unknownuser")
        XCTAssertTrue(positions.isEmpty)
    }

    // MARK: - Default Limits

    @MainActor func testDefaultMaxQueueSize() {
        XCTAssertEqual(queue.maxQueueSize, 10)
    }

    @MainActor func testDefaultPerUserLimit() {
        XCTAssertEqual(queue.perUserLimit, 2)
    }

    // MARK: - Custom Limits via UserDefaults

    @MainActor func testCustomMaxQueueSize() {
        UserDefaults.standard.set(5, forKey: AppConstants.UserDefaults.songRequestMaxQueueSize)
        XCTAssertEqual(queue.maxQueueSize, 5)
    }

    @MainActor func testCustomPerUserLimit() {
        UserDefaults.standard.set(3, forKey: AppConstants.UserDefaults.songRequestPerUserLimit)
        XCTAssertEqual(queue.perUserLimit, 3)
    }

    // MARK: - Clear Now Playing

    @MainActor func testClearNowPlaying() {
        queue.clearNowPlaying()
        XCTAssertNil(queue.nowPlaying)
    }

    // MARK: - Move Operations

    @MainActor func testMoveWithEmptyQueue() {
        // Should not crash
        queue.move(from: IndexSet(), to: 0)
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: - Remove by ID

    @MainActor func testRemoveByNonExistentID() {
        let fakeID = UUID()
        queue.remove(id: fakeID)
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: - Add Operations

    @MainActor func testAddSingleItem() {
        let item = SongRequestItem(title: "Bohemian Rhapsody", artist: "Queen", requesterUsername: "user1")
        let result = queue.add(item)
        guard case .added(let position) = result else {
            XCTFail("Expected .added, got \(result)")
            return
        }
        XCTAssertEqual(position, 1)
        XCTAssertEqual(queue.count, 1)
        XCTAssertFalse(queue.isEmpty)
    }

    @MainActor func testAddMultipleItemsIncrementsPosition() {
        let item1 = SongRequestItem(title: "Song A", artist: "Artist A", requesterUsername: "user1")
        let item2 = SongRequestItem(title: "Song B", artist: "Artist B", requesterUsername: "user2")
        let r1 = queue.add(item1)
        let r2 = queue.add(item2)
        guard case .added(let pos1) = r1, case .added(let pos2) = r2 else {
            XCTFail("Expected both .added")
            return
        }
        XCTAssertEqual(pos1, 1)
        XCTAssertEqual(pos2, 2)
        XCTAssertEqual(queue.count, 2)
    }

    @MainActor func testAddQueueFull() {
        UserDefaults.standard.set(2, forKey: AppConstants.UserDefaults.songRequestMaxQueueSize)
        UserDefaults.standard.set(5, forKey: AppConstants.UserDefaults.songRequestPerUserLimit)
        queue.add(SongRequestItem(title: "Song 1", artist: "A", requesterUsername: "user1"))
        queue.add(SongRequestItem(title: "Song 2", artist: "B", requesterUsername: "user2"))
        let result = queue.add(SongRequestItem(title: "Song 3", artist: "C", requesterUsername: "user3"))
        guard case .queueFull(let max) = result else {
            XCTFail("Expected .queueFull, got \(result)")
            return
        }
        XCTAssertEqual(max, 2)
    }

    @MainActor func testAddUserLimitReached() {
        UserDefaults.standard.set(1, forKey: AppConstants.UserDefaults.songRequestPerUserLimit)
        queue.add(SongRequestItem(title: "Song 1", artist: "A", requesterUsername: "user1"))
        let result = queue.add(SongRequestItem(title: "Song 2", artist: "B", requesterUsername: "user1"))
        guard case .userLimitReached(let max) = result else {
            XCTFail("Expected .userLimitReached, got \(result)")
            return
        }
        XCTAssertEqual(max, 1)
    }

    @MainActor func testAddDuplicateRejected() {
        let item1 = SongRequestItem(title: "Duplicate Song", artist: "Same Artist", requesterUsername: "user1")
        let item2 = SongRequestItem(title: "duplicate song", artist: "SAME ARTIST", requesterUsername: "USER1")
        queue.add(item1)
        let result = queue.add(item2)
        guard case .alreadyInQueue = result else {
            XCTFail("Expected .alreadyInQueue, got \(result)")
            return
        }
        XCTAssertEqual(queue.count, 1)
    }

    @MainActor func testAddDifferentUserSameSongAllowed() {
        let item1 = SongRequestItem(title: "Same Song", artist: "Artist", requesterUsername: "user1")
        let item2 = SongRequestItem(title: "Same Song", artist: "Artist", requesterUsername: "user2")
        let r1 = queue.add(item1)
        let r2 = queue.add(item2)
        guard case .added = r1, case .added = r2 else {
            XCTFail("Expected both .added")
            return
        }
        XCTAssertEqual(queue.count, 2)
    }

    // MARK: - Dequeue / Skip / Clear with Items

    @MainActor func testDequeueSetsNowPlaying() {
        let item = SongRequestItem(title: "Test Song", artist: "Test Artist", requesterUsername: "user1")
        queue.add(item)
        let dequeued = queue.dequeue()
        XCTAssertNotNil(dequeued)
        XCTAssertEqual(dequeued?.title, "Test Song")
        XCTAssertEqual(queue.nowPlaying?.title, "Test Song")
        XCTAssertTrue(queue.isEmpty)
    }

    @MainActor func testSkipAdvancesNowPlaying() {
        queue.add(SongRequestItem(title: "Song 1", artist: "A", requesterUsername: "user1"))
        queue.add(SongRequestItem(title: "Song 2", artist: "B", requesterUsername: "user2"))
        queue.dequeue() // sets nowPlaying to Song 1
        let next = queue.skip()
        XCTAssertEqual(next?.title, "Song 2")
        XCTAssertEqual(queue.nowPlaying?.title, "Song 2")
        XCTAssertTrue(queue.isEmpty)
    }

    @MainActor func testClearReturnsItemCount() {
        queue.add(SongRequestItem(title: "Song 1", artist: "A", requesterUsername: "user1"))
        queue.add(SongRequestItem(title: "Song 2", artist: "B", requesterUsername: "user2"))
        let removed = queue.clear()
        XCTAssertEqual(removed, 2)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.nowPlaying)
    }

    @MainActor func testClearAlsoClearsNowPlaying() {
        let item = SongRequestItem(title: "Test", artist: "A", requesterUsername: "user1")
        queue.add(item)
        queue.dequeue() // sets nowPlaying
        XCTAssertNotNil(queue.nowPlaying)
        queue.clear()
        XCTAssertNil(queue.nowPlaying)
    }

    // MARK: - Remove by ID

    @MainActor func testRemoveExistingItem() {
        let item = SongRequestItem(title: "Remove Me", artist: "Artist", requesterUsername: "user1")
        queue.add(item)
        XCTAssertEqual(queue.count, 1)
        queue.remove(id: item.id)
        XCTAssertEqual(queue.count, 0)
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: - Move

    @MainActor func testMoveReordersItems() {
        queue.add(SongRequestItem(title: "Song A", artist: "A", requesterUsername: "user1"))
        queue.add(SongRequestItem(title: "Song B", artist: "B", requesterUsername: "user2"))
        queue.add(SongRequestItem(title: "Song C", artist: "C", requesterUsername: "user3"))
        // Move Song C (index 2) to position 0
        queue.move(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(queue.items[0].title, "Song C")
        XCTAssertEqual(queue.items[1].title, "Song A")
    }

    // MARK: - Positions

    @MainActor func testPositionsForUser() {
        let user = "testuser"
        queue.add(SongRequestItem(title: "Song 1", artist: "A", requesterUsername: user))
        queue.add(SongRequestItem(title: "Song X", artist: "B", requesterUsername: "other"))
        queue.add(SongRequestItem(title: "Song 2", artist: "C", requesterUsername: user))
        let positions = queue.positions(for: user)
        XCTAssertEqual(positions.count, 2)
        XCTAssertEqual(positions[0].position, 1)
        XCTAssertEqual(positions[0].item.title, "Song 1")
        XCTAssertEqual(positions[1].position, 3)
        XCTAssertEqual(positions[1].item.title, "Song 2")
    }

    @MainActor func testIsFull() {
        UserDefaults.standard.set(2, forKey: AppConstants.UserDefaults.songRequestMaxQueueSize)
        UserDefaults.standard.set(5, forKey: AppConstants.UserDefaults.songRequestPerUserLimit)
        XCTAssertFalse(queue.isFull)
        queue.add(SongRequestItem(title: "Song 1", artist: "A", requesterUsername: "user1"))
        queue.add(SongRequestItem(title: "Song 2", artist: "B", requesterUsername: "user2"))
        XCTAssertTrue(queue.isFull)
    }
}
