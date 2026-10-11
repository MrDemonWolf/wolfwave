//
//  StreamDeckClearQueueTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-10.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest
@testable import WolfWave

/// The Stream Deck "Clear Queue" key must take the same path as the tray item:
/// `SongRequestService.clearQueue()`, which also empties Music.app's native
/// player queue. Clearing the in-memory list alone left the requests queued in
/// Music.
@MainActor
final class StreamDeckClearQueueTests: WolfWaveTestCase {

    func testClearQueueKeyClearsNativePlayerQueueToo() async {
        let queue = SongRequestQueue()
        let controller = MockAppleMusicController()
        let service = SongRequestService(queue: queue, musicController: controller)
        defer { service.stopPlaybackMonitoring() }
        _ = queue.add(makeTestRequestItem(title: "Song 1", artist: "A", requesterUsername: "user1"))

        let delegate = AppDelegate()
        delegate.songRequestService = service

        let ack = await delegate.handleStreamDeckCommand(
            StreamDeckCommand(action: .clearQueue, args: [:])
        )

        XCTAssertTrue(ack.ok)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertTrue(controller.clearCalled, "The key must go through the service-level clear")
    }

    func testClearQueueKeyFailsWithoutService() async {
        let delegate = AppDelegate()
        let ack = await delegate.handleStreamDeckCommand(
            StreamDeckCommand(action: .clearQueue, args: [:])
        )
        XCTAssertFalse(ack.ok)
        XCTAssertEqual(ack.error, "unavailable")
    }
}
