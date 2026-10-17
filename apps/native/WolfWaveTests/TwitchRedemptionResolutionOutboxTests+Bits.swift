//
//  TwitchRedemptionResolutionOutboxTests+Bits.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import XCTest

@testable import WolfWave

/// Bits actions: replay across relaunch, failed enqueue and acknowledgement, and tombstone pruning.
extension TwitchRedemptionResolutionOutboxTests {
    /// A paid Bits message is deduplicated by message id and replays after relaunch until
    /// acknowledged. After acknowledgement the same message for the same broadcaster is
    /// suppressed, while the same id for a different broadcaster is accepted.
    func testBitsIntakeReplaysAcrossRelaunchThenTerminalSuppressesExactOwner()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date(timeIntervalSince1970: 1_000)
        let clock = ThreadSafeBox(now)
        let store = TwitchRedemptionResolutionOutbox(
            fileURL: fixture.file,
            nowProvider: { clock.value })

        let first = try store.enqueueBits(
            messageID: "paid-message",
            broadcasterID: "broadcaster-a",
            userName: "viewer",
            bits: 100,
            boostEnabled: false,
            query: "a song")
        XCTAssertTrue(first.inserted)
        let firstItem = try XCTUnwrap(first.item)
        let duplicate = try store.enqueueBits(
            messageID: "paid-message",
            broadcasterID: "broadcaster-a",
            userName: "viewer",
            bits: 100,
            boostEnabled: false,
            query: "a song")
        XCTAssertFalse(duplicate.inserted)
        XCTAssertEqual(duplicate.item, firstItem)

        let relaunched = TwitchRedemptionResolutionOutbox(
            fileURL: fixture.file,
            nowProvider: { clock.value })
        XCTAssertEqual(relaunched.pendingBitsItems(), [firstItem])
        let replay = try relaunched.enqueueBits(
            messageID: "paid-message",
            broadcasterID: "broadcaster-a",
            userName: "viewer",
            bits: 100,
            boostEnabled: false,
            query: "a song")
        XCTAssertFalse(replay.inserted)
        XCTAssertEqual(replay.item, firstItem)

        try relaunched.acknowledgeBits(firstItem.id)
        let completed = TwitchRedemptionResolutionOutbox(
            fileURL: fixture.file,
            nowProvider: { clock.value })
        XCTAssertTrue(completed.pendingBitsItems().isEmpty)
        XCTAssertNil(
            try completed.enqueueBits(
                messageID: "paid-message",
                broadcasterID: "broadcaster-a",
                userName: "viewer",
                bits: 100,
                boostEnabled: false,
                query: "a song").item)
        XCTAssertNotNil(
            try completed.enqueueBits(
                messageID: "paid-message",
                broadcasterID: "broadcaster-b",
                userName: "viewer",
                bits: 100,
                boostEnabled: false,
                query: "a song").item)
    }

    /// A failed write while enqueueing Bits leaves no item in memory or on disk.
    func testFailedBitsEnqueuePublishesNeitherMemoryNorDiskItem() throws {
        enum InjectedFailure: Error {
            case write
        }

        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = TwitchRedemptionResolutionOutbox(
            fileURL: fixture.file,
            atomicWriter: { _, _ in throw InjectedFailure.write })

        XCTAssertThrowsError(
            try store.enqueueBits(
                messageID: "paid-message",
                broadcasterID: "broadcaster",
                userName: "viewer",
                bits: 100,
                boostEnabled: false,
                query: "a song"))
        XCTAssertTrue(store.pendingBitsItems().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        XCTAssertTrue(
            TwitchRedemptionResolutionOutbox(fileURL: fixture.file)
                .pendingBitsItems().isEmpty)
    }

    /// A failed acknowledgement write keeps the Bits item replayable (same item on re-enqueue,
    /// before and after relaunch), the file bytes unchanged, and no tombstone suppressing it.
    func testFailedBitsAcknowledgementKeepsReplayableItemAndNoTombstone()
        throws {
        enum InjectedFailure: Error {
            case write
        }

        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let failWrites = ThreadSafeBox(false)
        let store = TwitchRedemptionResolutionOutbox(
            fileURL: fixture.file,
            atomicWriter: { data, url in
                if failWrites.value { throw InjectedFailure.write }
                try data.write(to: url, options: .atomic)
            })
        let item = try XCTUnwrap(
            store.enqueueBits(
                messageID: "paid-message",
                broadcasterID: "broadcaster",
                userName: "viewer",
                bits: 100,
                boostEnabled: false,
                query: "a song").item)
        let beforeAcknowledgement = try Data(contentsOf: fixture.file)

        failWrites.value = true
        XCTAssertThrowsError(try store.acknowledgeBits(item.id))
        XCTAssertEqual(store.pendingBitsItems(), [item])
        XCTAssertEqual(try Data(contentsOf: fixture.file), beforeAcknowledgement)
        XCTAssertEqual(
            try store.enqueueBits(
                messageID: "paid-message",
                broadcasterID: "broadcaster",
                userName: "viewer",
                bits: 100,
                boostEnabled: false,
                query: "a song").item,
            item)

        let relaunched = TwitchRedemptionResolutionOutbox(fileURL: fixture.file)
        XCTAssertEqual(relaunched.pendingBitsItems(), [item])
        XCTAssertEqual(
            try relaunched.enqueueBits(
                messageID: "paid-message",
                broadcasterID: "broadcaster",
                userName: "viewer",
                bits: 100,
                boostEnabled: false,
                query: "a song").item,
            item)
    }

    /// Paid-event tombstones are not subject to the 500-entry EventSub id cache: 500 later
    /// completions do not evict the oldest. Once `paidEventTombstoneRetention` passes, that
    /// id is accepted again.
    func testBitsTombstonesOutliveTransportCapacityAndPruneAfterHorizon()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let initialNow = Date(timeIntervalSince1970: 2_000)
        let clock = ThreadSafeBox(initialNow)
        let store = TwitchRedemptionResolutionOutbox(
            fileURL: fixture.file,
            nowProvider: { clock.value })

        func complete(_ messageID: String) throws {
            let result = try store.enqueueBits(
                messageID: messageID,
                broadcasterID: "broadcaster",
                userName: "viewer",
                bits: 100,
                boostEnabled: false,
                query: "a song")
            try store.acknowledgeBits(try XCTUnwrap(result.item).id)
        }

        try complete("oldest-paid-message")
        // The general EventSub cache holds 500 IDs. None of these paid IDs may
        // evict another before the timestamp acceptance horizon expires.
        for index in 0..<500 {
            try complete("busy-message-\(index)")
        }
        XCTAssertNil(
            try store.enqueueBits(
                messageID: "oldest-paid-message",
                broadcasterID: "broadcaster",
                userName: "viewer",
                bits: 100,
                boostEnabled: false,
                query: "a song").item)

        clock.value = initialNow.addingTimeInterval(
            TwitchRedemptionResolutionOutbox.paidEventTombstoneRetention + 1)
        let acceptedAgain = try store.enqueueBits(
            messageID: "oldest-paid-message",
            broadcasterID: "broadcaster",
            userName: "viewer",
            bits: 100,
            boostEnabled: false,
            query: "a song")
        XCTAssertTrue(acceptedAgain.inserted)
        XCTAssertNotNil(acceptedAgain.item)

        let relaunched = TwitchRedemptionResolutionOutbox(
            fileURL: fixture.file,
            nowProvider: { clock.value })
        XCTAssertEqual(
            relaunched.pendingBitsItems().map(\.messageID),
            ["oldest-paid-message"])
    }

    /// Acknowledging a redemption leaves a tombstone keyed on broadcaster, reward, and
    /// redemption id (exact match only). It persists across relaunch and is pruned after the
    /// retention horizon.
    func testAcknowledgementTombstoneIsAtomicExactAndPrunedAfterHorizon()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let initialNow = Date(timeIntervalSince1970: 3_000)
        let clock = ThreadSafeBox(initialNow)
        let store = TwitchRedemptionResolutionOutbox(
            fileURL: fixture.file,
            nowProvider: { clock.value })
        let item = try store.enqueue(
            broadcasterID: "broadcaster-a",
            rewardID: "reward-a",
            redemptionID: "redemption-a",
            resolution: .fulfilled,
            now: initialNow)

        try store.acknowledge(item.id, at: initialNow)
        XCTAssertTrue(store.pendingItems().isEmpty)
        XCTAssertTrue(
            store.hasAcknowledgedRedemption(
                broadcasterID: "broadcaster-a",
                rewardID: "reward-a",
                redemptionID: "redemption-a"))
        XCTAssertFalse(
            store.hasAcknowledgedRedemption(
                broadcasterID: "broadcaster-b",
                rewardID: "reward-a",
                redemptionID: "redemption-a"))
        XCTAssertFalse(
            store.hasAcknowledgedRedemption(
                broadcasterID: "broadcaster-a",
                rewardID: "reward-b",
                redemptionID: "redemption-a"))

        let relaunched = TwitchRedemptionResolutionOutbox(
            fileURL: fixture.file,
            nowProvider: { clock.value })
        XCTAssertTrue(
            relaunched.hasAcknowledgedRedemption(
                broadcasterID: "broadcaster-a",
                rewardID: "reward-a",
                redemptionID: "redemption-a"))

        clock.value = initialNow.addingTimeInterval(
            TwitchRedemptionResolutionOutbox.paidEventTombstoneRetention + 1)
        XCTAssertFalse(
            relaunched.hasAcknowledgedRedemption(
                broadcasterID: "broadcaster-a",
                rewardID: "reward-a",
                redemptionID: "redemption-a"))
        try relaunched.verifyIntakeStorage()
        XCTAssertFalse(
            TwitchRedemptionResolutionOutbox(
                fileURL: fixture.file,
                nowProvider: { clock.value })
                .hasAcknowledgedRedemption(
                    broadcasterID: "broadcaster-a",
                    rewardID: "reward-a",
                    redemptionID: "redemption-a"))
    }
}
