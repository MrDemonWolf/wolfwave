//
//  StreamDeckApproveNextTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest
@testable import WolfWave

/// The Stream Deck "Approve Next" key must report what actually happened. When
/// the live queue is full, `approve(id:)` puts the request back in pending, so
/// the key has to fail instead of flashing success.
@MainActor
final class StreamDeckApproveNextTests: WolfWaveTestCase {

    override func tearDown() async throws {
        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.songRequestMaxQueueSize)
        try await super.tearDown()
    }

    func testApproveNextFailsWithFullWhenLiveQueueIsFull() async {
        DefaultsStore.store.set(1, forKey: AppConstants.UserDefaults.songRequestMaxQueueSize)
        let queue = SongRequestQueue()
        let service = SongRequestService(queue: queue, musicController: MockAppleMusicController())
        defer { service.stopPlaybackMonitoring() }
        _ = queue.addApproved(makeTestRequestItem(title: "Queued", artist: "A", requesterUsername: "user1"))
        _ = queue.addPending(makeTestRequestItem(title: "Held", artist: "B", requesterUsername: "user2"))

        let delegate = AppDelegate()
        delegate.songRequestService = service

        let ack = await delegate.handleStreamDeckCommand(
            StreamDeckCommand(action: .approveNext, args: [:])
        )

        XCTAssertFalse(ack.ok)
        XCTAssertEqual(ack.error, "full")
        XCTAssertEqual(queue.pendingCount, 1, "The request stays pending for a later retry")
    }

    func testApproveNextSucceedsWithRoom() async {
        DefaultsStore.store.set(5, forKey: AppConstants.UserDefaults.songRequestMaxQueueSize)
        let queue = SongRequestQueue()
        let service = SongRequestService(queue: queue, musicController: MockAppleMusicController())
        defer { service.stopPlaybackMonitoring() }
        _ = queue.addPending(makeTestRequestItem(title: "Held", artist: "B", requesterUsername: "user2"))

        let delegate = AppDelegate()
        delegate.songRequestService = service

        let ack = await delegate.handleStreamDeckCommand(
            StreamDeckCommand(action: .approveNext, args: [:])
        )

        XCTAssertTrue(ack.ok)
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testApproveNextFailsWithEmptyWhenNothingPending() async {
        let queue = SongRequestQueue()
        let service = SongRequestService(queue: queue, musicController: MockAppleMusicController())
        defer { service.stopPlaybackMonitoring() }

        let delegate = AppDelegate()
        delegate.songRequestService = service

        let ack = await delegate.handleStreamDeckCommand(
            StreamDeckCommand(action: .approveNext, args: [:])
        )

        XCTAssertFalse(ack.ok)
        XCTAssertEqual(ack.error, "empty")
    }
}
