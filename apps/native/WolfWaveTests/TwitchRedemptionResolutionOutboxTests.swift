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

    /// Creates a unique temp directory and returns it with the `outbox.json` path inside it.
    /// Callers remove the directory in a `defer`.
    func makeFixture() throws -> (directory: URL, file: URL) {
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
