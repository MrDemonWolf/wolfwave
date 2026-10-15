//
//  TwitchRedemptionResolutionOutboxTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-08-12.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import XCTest

@testable import WolfWave

/// `TwitchRedemptionResolutionOutbox` durability: intake survives relaunch and dedupes, failed
/// writes leave replayable items, corrupt stores are quarantined, a failed acknowledgement trips
/// the circuit breaker, and Bits actions replay until acknowledged. Uses injected writers and temp
/// storage, never the live Application Support directory.
final class TwitchRedemptionResolutionOutboxTests: XCTestCase {
    /// An intake record is written before its outcome is known and survives a relaunch as
    /// one unknown item (startup can then refund it). A duplicate delivery is not inserted
    /// again, and once an outcome is recorded a later conflicting one cannot reverse it.
    func testIntakePersistsAndDeduplicatesAcrossRelaunchUntilOutcomeKnown() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let firstStore = TwitchRedemptionResolutionOutbox(fileURL: fixture.file)
        let first = try firstStore.enqueueIntake(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption",
            now: Date(timeIntervalSince1970: 100)
        )
        XCTAssertTrue(first.inserted)
        XCTAssertTrue(first.item.isIntake)

        // Models relaunch before processing and relaunch after an in-memory
        // queue mutation but before its result was durably recorded. Both must
        // retain one unknown intake that startup can conservatively refund.
        let relaunched = TwitchRedemptionResolutionOutbox(fileURL: fixture.file)
        XCTAssertEqual(relaunched.pendingItems(), [first.item])
        let duplicate = try relaunched.enqueueIntake(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption",
            now: Date(timeIntervalSince1970: 200)
        )
        XCTAssertFalse(duplicate.inserted)
        XCTAssertEqual(duplicate.item, first.item)

        let fulfilled = try relaunched.updateResolution(first.item.id, to: .fulfilled)
        XCTAssertEqual(fulfilled.resolution, .fulfilled)
        // Once known, duplicate delivery cannot reverse the queue outcome.
        let conflicting = try relaunched.updateResolution(first.item.id, to: .canceled)
        XCTAssertEqual(conflicting.resolution, .fulfilled)

        let knownRelaunch = TwitchRedemptionResolutionOutbox(fileURL: fixture.file)
        XCTAssertEqual(knownRelaunch.pendingItems(), [fulfilled])
    }

    /// If recording the outcome fails to write, the earlier intake stays on disk and in memory,
    /// and intake storage is flagged unavailable until `verifyIntakeStorage()` succeeds again.
    func testFailedOutcomeWriteLeavesDurableIntakeForStartupRefund() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let failWrites = ThreadSafeBox(false)
        let store = TwitchRedemptionResolutionOutbox(
            fileURL: fixture.file,
            atomicWriter: { data, url in
                if failWrites.value { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url, options: .atomic)
            }
        )
        let intake = try store.enqueueIntake(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption"
        ).item

        failWrites.value = true
        XCTAssertThrowsError(try store.updateResolution(intake.id, to: .fulfilled))
        XCTAssertTrue(store.intakeStorageIsUnavailable())
        XCTAssertEqual(store.pendingItems(), [intake])
        XCTAssertEqual(
            TwitchRedemptionResolutionOutbox(fileURL: fixture.file).pendingItems(),
            [intake]
        )

        failWrites.value = false
        let canceled = try store.updateResolution(intake.id, to: .canceled)
        XCTAssertTrue(store.intakeStorageIsUnavailable())
        XCTAssertNoThrow(try store.verifyIntakeStorage())
        XCTAssertFalse(store.intakeStorageIsUnavailable())
        XCTAssertEqual(canceled.resolution, .canceled)
        XCTAssertEqual(
            TwitchRedemptionResolutionOutbox(fileURL: fixture.file).pendingItems(),
            [canceled]
        )
    }

    /// Five recorded failures persist the attempt count; moving the item to the dead-letter
    /// list removes it from `pendingItems()` (what teardown checks) and keeps it across relaunch.
    func testDeadLetterDoesNotBlockCredentialTeardown() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = TwitchRedemptionResolutionOutbox(fileURL: fixture.file)
        let item = try store.enqueue(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption",
            resolution: .fulfilled)

        for expectedAttempt in 1...5 {
            XCTAssertEqual(try store.recordFailureAttempt(item.id), expectedAttempt)
        }
        XCTAssertEqual(
            TwitchRedemptionResolutionOutbox(fileURL: fixture.file)
                .pendingItems().first?.attemptCount,
            5)

        try store.moveToDeadLetter(item.id)

        XCTAssertTrue(store.pendingItems().isEmpty)
        XCTAssertEqual(store.deadLetterItems().map(\.id), [item.id])
        XCTAssertEqual(
            TwitchRedemptionResolutionOutbox(fileURL: fixture.file).deadLetterItems().map(\.id),
            [item.id])
    }

    /// `verifyIntakeStorage()` goes through the injected atomic writer: a failed probe marks
    /// storage unavailable, and a later successful probe clears the flag and creates the file.
    func testStorageProbeUsesInjectedAtomicWriterAndCanRecover() throws {
        enum InjectedFailure: Error {
            case write
        }

        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let failWrites = ThreadSafeBox(true)
        let writes = ThreadSafeBox(0)
        let store = TwitchRedemptionResolutionOutbox(
            fileURL: fixture.file,
            atomicWriter: { data, url in
                writes.mutate { $0 += 1 }
                if failWrites.value { throw InjectedFailure.write }
                try data.write(to: url, options: .atomic)
            }
        )

        XCTAssertThrowsError(try store.verifyIntakeStorage())
        XCTAssertEqual(writes.value, 1)
        XCTAssertTrue(store.intakeStorageIsUnavailable())
        XCTAssertTrue(store.pendingItems().isEmpty)

        failWrites.value = false
        XCTAssertNoThrow(try store.verifyIntakeStorage())
        XCTAssertEqual(writes.value, 2)
        XCTAssertFalse(store.intakeStorageIsUnavailable())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    /// A failed write while removing an acknowledged item keeps the item and marks storage
    /// unavailable, which a later successful probe clears.
    func testFailedAcknowledgementWriteTripsCircuitBreakerAndKeepsItem() throws {
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
            }
        )
        let item = try store.enqueue(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption",
            resolution: .canceled)

        failWrites.value = true
        XCTAssertThrowsError(try store.remove(item.id))
        XCTAssertTrue(store.intakeStorageIsUnavailable())
        XCTAssertEqual(store.pendingItems(), [item])

        failWrites.value = false
        XCTAssertNoThrow(try store.verifyIntakeStorage())
        XCTAssertFalse(store.intakeStorageIsUnavailable())
    }

    /// Enqueueing the same redemption twice returns the original item (first resolution wins).
    /// The item survives a relaunch and is gone after removal.
    func testPersistsDeduplicatesAndAcknowledgesAcrossInstances() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let firstStore = TwitchRedemptionResolutionOutbox(fileURL: fixture.file)
        let first = try firstStore.enqueue(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption",
            resolution: .fulfilled,
            now: Date(timeIntervalSince1970: 100)
        )
        let duplicate = try firstStore.enqueue(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption",
            resolution: .canceled,
            now: Date(timeIntervalSince1970: 200)
        )
        XCTAssertEqual(duplicate.id, first.id)
        XCTAssertEqual(duplicate.resolution, .fulfilled)

        let relaunched = TwitchRedemptionResolutionOutbox(fileURL: fixture.file)
        XCTAssertEqual(relaunched.pendingItems(), [first])
        try relaunched.remove(first.id)

        let drained = TwitchRedemptionResolutionOutbox(fileURL: fixture.file)
        XCTAssertTrue(drained.pendingItems().isEmpty)
    }

    /// An unparseable store file is moved aside to `<name>.corrupt-*` with its bytes preserved,
    /// a fresh queue works, and the "opaque recovery risk" flag survives relaunch until it is
    /// cleared explicitly after reconciliation.
    func testCorruptStoreIsQuarantinedAndFreshQueueStillWorks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Data("not-json".utf8).write(to: fixture.file, options: .atomic)

        let store = TwitchRedemptionResolutionOutbox(fileURL: fixture.file)
        XCTAssertTrue(store.hasOpaqueRecoveryRisk())
        let item = try store.enqueue(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "new-redemption",
            resolution: .canceled
        )
        XCTAssertEqual(store.pendingItems(), [item])
        try store.remove(item.id)
        XCTAssertTrue(store.pendingItems().isEmpty)

        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixture.directory.path)
        let quarantine = try XCTUnwrap(names.first {
            $0.hasPrefix(fixture.file.lastPathComponent + ".corrupt-")
        })
        let preserved = try Data(
            contentsOf: fixture.directory.appending(path: quarantine))
        XCTAssertEqual(preserved, Data("not-json".utf8))

        let relaunched = TwitchRedemptionResolutionOutbox(fileURL: fixture.file)
        XCTAssertTrue(relaunched.hasOpaqueRecoveryRisk())

        try relaunched.clearOpaqueRecoveryRiskAfterReconciliation()
        XCTAssertFalse(relaunched.hasOpaqueRecoveryRisk())
        let recovered = TwitchRedemptionResolutionOutbox(fileURL: fixture.file)
        XCTAssertFalse(recovered.hasOpaqueRecoveryRisk())
    }

    /// If the corrupt file cannot be moved aside, nothing is overwritten: the probe and new
    /// intake throw `unreadableExistingStore`, the risk flag stays set, and the original bytes
    /// remain.
    func testQuarantineFailureBlocksStorageProbeAndFutureIntake() throws {
        enum InjectedFailure: Error {
            case quarantine
        }

        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = Data("not-json".utf8)
        try original.write(to: fixture.file, options: .atomic)
        let store = TwitchRedemptionResolutionOutbox(
            fileURL: fixture.file,
            quarantineMover: { _, _ in throw InjectedFailure.quarantine }
        )

        XCTAssertThrowsError(try store.verifyIntakeStorage()) { error in
            guard case TwitchRedemptionResolutionOutbox.StoreError.unreadableExistingStore = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(store.intakeStorageIsUnavailable())
        XCTAssertTrue(store.hasOpaqueRecoveryRisk())
        XCTAssertThrowsError(try store.enqueueIntake(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption"
        ))
        XCTAssertTrue(store.pendingItems().isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.file), original)
    }

    func testUnknownResolutionIsQuarantinedInsteadOfPoisoningReplay() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let unknown = TwitchRedemptionResolutionOutbox.Item(
            id: UUID(),
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "old-redemption",
            resolutionRawValue: "UNKNOWN_FUTURE_VALUE",
            createdAt: Date()
        )
        try JSONEncoder().encode([unknown]).write(to: fixture.file, options: .atomic)

        let store = TwitchRedemptionResolutionOutbox(fileURL: fixture.file)
        XCTAssertTrue(store.pendingItems().isEmpty)
        _ = try store.enqueue(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "new-redemption",
            resolution: .fulfilled
        )
        XCTAssertEqual(store.pendingItems().count, 1)
    }

    /// A store holding one valid and one invalid item (empty broadcaster, unknown resolution)
    /// keeps the valid one live, quarantines the original, and still reports the recovery risk
    /// after relaunch.
    func testMixedInvalidStoreRestoresValidItemsToLiveQueue() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let valid = TwitchRedemptionResolutionOutbox.Item(
            id: UUID(),
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "valid-redemption",
            resolutionRawValue: TwitchChannelPointsService.Resolution.fulfilled.rawValue,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let invalid = TwitchRedemptionResolutionOutbox.Item(
            id: UUID(),
            broadcasterID: "",
            rewardID: "reward",
            redemptionID: "invalid-redemption",
            resolutionRawValue: "UNKNOWN",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        try JSONEncoder().encode([valid, invalid]).write(
            to: fixture.file,
            options: .atomic
        )

        let store = TwitchRedemptionResolutionOutbox(fileURL: fixture.file)
        XCTAssertEqual(store.pendingItems(), [valid])
        XCTAssertTrue(store.hasOpaqueRecoveryRisk())
        let relaunched = TwitchRedemptionResolutionOutbox(fileURL: fixture.file)
        XCTAssertEqual(relaunched.pendingItems(), [valid])
        XCTAssertTrue(relaunched.hasOpaqueRecoveryRisk())

        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixture.directory.path)
        XCTAssertTrue(names.contains {
            $0.hasPrefix(fixture.file.lastPathComponent + ".corrupt-")
        })
    }

    /// If rewriting the salvaged valid items fails, the original file is left untouched
    /// and the valid item is still served from memory and after relaunch.
    func testMixedInvalidStoreKeepsOriginalLiveWhenSalvageWriteFails() throws {
        enum InjectedFailure: Error {
            case write
        }

        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let valid = TwitchRedemptionResolutionOutbox.Item(
            id: UUID(),
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "valid-redemption",
            resolutionRawValue: TwitchChannelPointsService.Resolution.fulfilled.rawValue,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let invalid = TwitchRedemptionResolutionOutbox.Item(
            id: UUID(),
            broadcasterID: "",
            rewardID: "reward",
            redemptionID: "invalid-redemption",
            resolutionRawValue: "UNKNOWN",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let original = try JSONEncoder().encode([valid, invalid])
        try original.write(to: fixture.file, options: .atomic)

        let failedRecovery = TwitchRedemptionResolutionOutbox(
            fileURL: fixture.file,
            atomicWriter: { _, _ in throw InjectedFailure.write }
        )

        XCTAssertEqual(failedRecovery.pendingItems(), [valid])
        XCTAssertEqual(try Data(contentsOf: fixture.file), original)

        let relaunched = TwitchRedemptionResolutionOutbox(fileURL: fixture.file)
        XCTAssertEqual(relaunched.pendingItems(), [valid])
    }

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

    /// Creates a unique temp directory and returns it with the `outbox.json` path inside it.
    /// Callers remove the directory in a `defer`.
    private func makeFixture() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "wolfwave-redemption-outbox-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return (
            directory,
            directory.appending(path: "outbox.json")
        )
    }
}
