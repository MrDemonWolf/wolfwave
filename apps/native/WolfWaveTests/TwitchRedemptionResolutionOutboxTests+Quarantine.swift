//
//  TwitchRedemptionResolutionOutboxTests+Quarantine.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import XCTest

@testable import WolfWave

/// Duplicate and legacy stores, retryable statuses, future-dated tombstones, and the default writer.
extension TwitchRedemptionResolutionOutboxTests {
    /// Two stored items with the same broadcaster/reward/redemption would double-resolve, so the
    /// store is quarantined: nothing is pending and the recovery-risk flag is set.
    func testDuplicateBusinessKeyIsQuarantinedInsteadOfReplayedTwice()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = TwitchRedemptionResolutionOutbox.Item(
            id: UUID(),
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption",
            resolutionRawValue:
                TwitchChannelPointsService.Resolution.fulfilled.rawValue,
            createdAt: Date(timeIntervalSince1970: 1))
        let duplicate = TwitchRedemptionResolutionOutbox.Item(
            id: UUID(),
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption",
            resolutionRawValue:
                TwitchChannelPointsService.Resolution.canceled.rawValue,
            createdAt: Date(timeIntervalSince1970: 2))
        try JSONEncoder().encode([first, duplicate]).write(
            to: fixture.file,
            options: .atomic)

        let store = TwitchRedemptionResolutionOutbox(fileURL: fixture.file)

        XCTAssertTrue(store.pendingItems().isEmpty)
        XCTAssertTrue(store.hasOpaqueRecoveryRisk())
    }

    /// Two stored items sharing one item id would collide in the resolution workers, so the
    /// store is quarantined the same way.
    func testDuplicateItemUUIDIsQuarantinedInsteadOfCollidingWorkers()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let duplicateID = UUID()
        let first = TwitchRedemptionResolutionOutbox.Item(
            id: duplicateID,
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption-a",
            resolutionRawValue:
                TwitchChannelPointsService.Resolution.fulfilled.rawValue,
            createdAt: Date(timeIntervalSince1970: 1))
        let duplicate = TwitchRedemptionResolutionOutbox.Item(
            id: duplicateID,
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption-b",
            resolutionRawValue:
                TwitchChannelPointsService.Resolution.canceled.rawValue,
            createdAt: Date(timeIntervalSince1970: 2))
        try JSONEncoder().encode([first, duplicate]).write(
            to: fixture.file,
            options: .atomic)

        let store = TwitchRedemptionResolutionOutbox(fileURL: fixture.file)

        XCTAssertTrue(store.pendingItems().isEmpty)
        XCTAssertTrue(store.hasOpaqueRecoveryRisk())
    }

    func testLegacyItemArrayMigratesWithoutLosingPendingWork() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let item = TwitchRedemptionResolutionOutbox.Item(
            id: UUID(),
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption",
            resolutionRawValue:
                TwitchChannelPointsService.Resolution.canceled.rawValue,
            createdAt: Date())
        try JSONEncoder().encode([item]).write(
            to: fixture.file,
            options: .atomic)

        let migrated = TwitchRedemptionResolutionOutbox(fileURL: fixture.file)
        XCTAssertEqual(migrated.pendingItems(), [item])
        XCTAssertFalse(migrated.hasOpaqueRecoveryRisk())
        XCTAssertEqual(
            TwitchRedemptionResolutionOutbox(fileURL: fixture.file)
                .pendingItems(),
            [item])
    }

    func testOnlyTransientResolutionStatusesRetry() {
        for status in [408, 425, 429, 500, 503, 599] {
            XCTAssertTrue(TwitchChatService.shouldRetryRedemptionResolution(status: status))
        }
        for status in [200, 400, 401, 403, 404, 409, 600] {
            XCTAssertFalse(TwitchChatService.shouldRetryRedemptionResolution(status: status))
        }
    }

    /// If the wall clock jumps back an hour, tombstones written "in the future" are clamped
    /// to now rather than dropped, so they still suppress duplicates, and they expire on the
    /// corrected clock.
    func testFutureDatedTombstoneClampedNotDropped() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let writtenAt = Date(timeIntervalSince1970: 100_000)
        let clock = ThreadSafeBox(writtenAt)
        let store = TwitchRedemptionResolutionOutbox(
            fileURL: fixture.file,
            nowProvider: { clock.value })

        let bits = try store.enqueueBits(
            messageID: "paid-message",
            broadcasterID: "broadcaster",
            userName: "viewer",
            bits: 100,
            boostEnabled: false,
            query: "a song")
        try store.acknowledgeBits(try XCTUnwrap(bits.item).id)
        let item = try store.enqueue(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption",
            resolution: .fulfilled,
            now: writtenAt)
        try store.acknowledge(item.id, at: writtenAt)

        // The wall clock jumps back an hour, far past the forward-skew window.
        // The tombstones now look future-dated; they must still suppress.
        let rewound = writtenAt.addingTimeInterval(-3_600)
        clock.value = rewound
        let relaunched = TwitchRedemptionResolutionOutbox(
            fileURL: fixture.file,
            nowProvider: { clock.value })
        XCTAssertTrue(
            relaunched.hasAcknowledgedRedemption(
                broadcasterID: "broadcaster",
                rewardID: "reward",
                redemptionID: "redemption"))
        XCTAssertNil(
            try relaunched.enqueueBits(
                messageID: "paid-message",
                broadcasterID: "broadcaster",
                userName: "viewer",
                bits: 100,
                boostEnabled: false,
                query: "a song").item)

        // Retention restarts from the clamped time, so the tombstones still
        // expire once the horizon passes on the corrected clock.
        clock.value = rewound.addingTimeInterval(
            TwitchRedemptionResolutionOutbox.paidEventTombstoneRetention + 1)
        XCTAssertFalse(
            relaunched.hasAcknowledgedRedemption(
                broadcasterID: "broadcaster",
                rewardID: "reward",
                redemptionID: "redemption"))
        XCTAssertTrue(
            try relaunched.enqueueBits(
                messageID: "paid-message",
                broadcasterID: "broadcaster",
                userName: "viewer",
                bits: 100,
                boostEnabled: false,
                query: "a song").inserted)
    }

    /// The default `durableAtomicWrite` writer creates and overwrites the file, works through
    /// the store, and leaves no `.tmp-` files behind.
    func testDefaultWriterRoundTrips() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        // Direct: a fresh write, then an overwrite of the live file.
        try TwitchRedemptionResolutionOutbox.durableAtomicWrite(
            Data("first".utf8), to: fixture.file)
        try TwitchRedemptionResolutionOutbox.durableAtomicWrite(
            Data("second".utf8), to: fixture.file)
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data("second".utf8))

        // Through the store, using the default writer. The plain "second"
        // bytes are not a valid store, so start from no file.
        try FileManager.default.removeItem(at: fixture.file)
        let fresh = TwitchRedemptionResolutionOutbox(fileURL: fixture.file)
        let intake = try fresh.enqueueIntake(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption",
            now: Date(timeIntervalSince1970: 100))
        let relaunched = TwitchRedemptionResolutionOutbox(fileURL: fixture.file)
        XCTAssertEqual(relaunched.pendingItems(), [intake.item])

        // No temp files are left behind next to the live store.
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: fixture.directory.path)
            .filter { $0.contains(".tmp-") }
        XCTAssertEqual(leftovers, [])
    }

    func testDefaultWriterFailureLeavesLiveFileUntouched() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try TwitchRedemptionResolutionOutbox.durableAtomicWrite(
            Data("live".utf8), to: fixture.file)

        // A destination inside a missing directory cannot be written.
        let missing = fixture.directory
            .appending(path: "missing-dir")
            .appending(path: "outbox.json")
        XCTAssertThrowsError(
            try TwitchRedemptionResolutionOutbox.durableAtomicWrite(
                Data("nope".utf8), to: missing))
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data("live".utf8))
    }
}
