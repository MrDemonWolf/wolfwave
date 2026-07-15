//
//  SongRequestQueuePendingTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-07-14.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// Approval holding-pen behavior on `SongRequestQueue` (the WW-27 opt-in
/// screening mode). Pure queue logic, no music/network dependencies.
@MainActor
final class SongRequestQueuePendingTests: WolfWaveTestCase {
    var queue: SongRequestQueue!

    override func setUp() {
        super.setUp()
        queue = SongRequestQueue()
        resetAllSettings()
    }

    override func tearDown() {
        queue = nil
        resetAllSettings()
        super.tearDown()
    }

    func testAddPendingHoldsWithoutTouchingQueue() {
        let item = SongRequestItem(title: "Howl", artist: "Grey Wolf", requesterUsername: "viewer1")
        let result = queue.addPending(item)
        guard case .added = result else { return XCTFail("expected .added, got \(result)") }
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertTrue(queue.isEmpty, "pending must not reach the live queue")
    }

    func testAddPendingDedupsSameSongSameUser() {
        let a = SongRequestItem(title: "Howl", artist: "Grey Wolf", requesterUsername: "viewer1")
        let b = SongRequestItem(title: "howl", artist: "grey wolf", requesterUsername: "VIEWER1")
        _ = queue.addPending(a)
        guard case .alreadyInQueue = queue.addPending(b) else {
            return XCTFail("expected duplicate rejection")
        }
        XCTAssertEqual(queue.pendingCount, 1)
    }

    func testApproveFlowMovesPendingToQueueBypassingPerUserLimit() {
        // Per-user limit of 1: two pending items from the same user must both be
        // approvable, since the manual approval is the gate (addApproved skips the
        // per-user check).
        Foundation.UserDefaults.standard.set(1, forKey: AppConstants.UserDefaults.songRequestPerUserLimit)
        let a = SongRequestItem(title: "Song A", artist: "Wolf", requesterUsername: "viewer1")
        let b = SongRequestItem(title: "Song B", artist: "Wolf", requesterUsername: "viewer1")
        _ = queue.addPending(a)
        _ = queue.addPending(b)

        let takenA = queue.takePending(id: a.id)
        XCTAssertEqual(takenA?.id, a.id)
        guard case .added = queue.addApproved(a) else { return XCTFail("approve A failed") }
        guard case .added = queue.addApproved(b) else {
            return XCTFail("approve B failed: per-user limit should not apply to approvals")
        }
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.pendingCount, 1, "only A was taken; B is still pending")
    }

    func testTakePendingUnknownIDReturnsNil() {
        XCTAssertNil(queue.takePending(id: UUID()))
    }

    func testClearAlsoDropsPending() {
        _ = queue.addPending(SongRequestItem(title: "P", artist: "W", requesterUsername: "v"))
        _ = queue.add(SongRequestItem(title: "Q", artist: "W", requesterUsername: "v2"))
        _ = queue.clear()
        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertTrue(queue.isEmpty)
    }
}
