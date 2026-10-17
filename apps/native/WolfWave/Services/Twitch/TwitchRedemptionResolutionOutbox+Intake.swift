//
//  TwitchRedemptionResolutionOutbox+Intake.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Storage health checks plus channel-point intake, resolution updates,
/// and terminal acknowledgement.
nonisolated extension TwitchRedemptionResolutionOutbox {

    // MARK: - Storage Health

    /// Sticky circuit-breaker state. A failed mutation remains unavailable
    /// until `verifyIntakeStorage()` proves an atomic commit works again.
    func intakeStorageIsUnavailable() -> Bool {
        lock.withLock { existingStoreIsUnreadable || intakeStorageHasFailed }
    }

    /// True when unreadable or quarantined bytes may contain a redemption that
    /// cannot be reconstructed automatically. This survives relaunch by
    /// detecting same-directory quarantine files and blocks credential teardown
    /// until the streamer explicitly recovers or removes those artifacts.
    func hasOpaqueRecoveryRisk() -> Bool {
        lock.withLock { existingStoreIsUnreadable || opaqueRecoveryRisk }
    }

    /// Clears quarantined opaque bytes only after held Helix recovery has
    /// enumerated and resolved every remote redemption and the live queue is
    /// empty. Normal logout never calls this discard boundary.
    ///
    /// Deletes every `<store>.corrupt-*` file in the store's directory.
    ///
    /// - Throws: `StoreError.unresolvedRecoveryRisk` while any channel-point or
    ///   Bits item (dead letters included) remains, or the file is unreadable;
    ///   otherwise a `FileManager` error, in which case the flag stays set.
    func clearOpaqueRecoveryRiskAfterReconciliation() throws {
        try lock.withLock {
            guard !existingStoreIsUnreadable,
                  items.isEmpty,
                  bitsItems.isEmpty else {
                throw StoreError.unresolvedRecoveryRisk
            }
            let directory = fileURL.deletingLastPathComponent()
            let prefix = fileURL.lastPathComponent + ".corrupt-"
            let names: [String]
            if fileManager.fileExists(atPath: directory.path) {
                names = try fileManager.contentsOfDirectory(
                    atPath: directory.path)
            } else {
                names = []
            }
            for name in names where name.hasPrefix(prefix) {
                try fileManager.removeItem(
                    at: directory.appending(path: name))
            }
            opaqueRecoveryRisk = false
        }
    }

    /// Verifies that the current queue snapshot can be committed atomically.
    /// Call this before making the managed reward redeemable: a successful
    /// no-op rewrite proves intake can be persisted before any viewer spends
    /// points, while an unquarantined corrupt store remains protected.
    ///
    /// The only call that clears the sticky failure flag. Also persists any
    /// tombstone expiry pruned since the last write.
    func verifyIntakeStorage() throws {
        try lock.withLock {
            guard !existingStoreIsUnreadable else {
                throw StoreError.unreadableExistingStore
            }
            let now = nowProvider()
            let normalizedPaid = Self.normalizedPaidEventTombstones(
                paidEventTombstones, now: now)
            let normalizedAcknowledged =
                Self.normalizedAcknowledgedRedemptionTombstones(
                    acknowledgedRedemptionTombstones, now: now)
            try persist(
                items,
                bitsItems: bitsItems,
                paidEventTombstones: normalizedPaid,
                acknowledgedRedemptionTombstones: normalizedAcknowledged)
            paidEventTombstones = normalizedPaid
            acknowledgedRedemptionTombstones = normalizedAcknowledged
            intakeStorageHasFailed = false
        }
    }

    // MARK: - Channel-Point Intake and Resolution

    /// Persists an idempotent work item before any network request begins.
    /// Duplicate EventSub deliveries reuse the existing item, including a
    /// dead-lettered one.
    ///
    /// - Returns: The stored item and whether this call inserted it.
    func enqueueIntake(
        broadcasterID: String,
        rewardID: String,
        redemptionID: String,
        now: Date = Date()
    ) throws -> (item: Item, inserted: Bool) {
        try enqueue(
            broadcasterID: broadcasterID,
            rewardID: rewardID,
            redemptionID: redemptionID,
            resolutionRawValue: Item.intakeRawValue,
            now: now
        )
    }

    /// Persists a known resolution directly. Primarily used by replay fixtures;
    /// live redemption intake transitions via `updateResolution` instead.
    func enqueue(
        broadcasterID: String,
        rewardID: String,
        redemptionID: String,
        resolution: TwitchChannelPointsService.Resolution,
        now: Date = Date()
    ) throws -> Item {
        let result = try enqueue(
            broadcasterID: broadcasterID,
            rewardID: rewardID,
            redemptionID: redemptionID,
            resolutionRawValue: resolution.rawValue,
            now: now
        )
        return result.item
    }

    /// Atomically replaces an intake phase with its final Twitch resolution.
    /// Persistence happens before in-memory state changes, so a failed write
    /// deliberately leaves intake on disk and restart will refund it.
    ///
    /// - Returns: The updated item, or the current item unchanged when it
    ///   already has a resolution (same or different).
    func updateResolution(
        _ id: Item.ID,
        to resolution: TwitchChannelPointsService.Resolution
    ) throws -> Item {
        try lock.withLock {
            guard !existingStoreIsUnreadable else {
                throw StoreError.unreadableExistingStore
            }
            guard let index = items.firstIndex(where: { $0.id == id }) else {
                throw StoreError.missingItem
            }
            let current = items[index]
            if current.resolution == resolution { return current }
            // A confirmed resolution is immutable. A duplicate delivery must
            // never flip an already-persisted fulfil into a refund or vice versa.
            guard current.isIntake else { return current }
            let replacementItem = Item(
                id: current.id,
                broadcasterID: current.broadcasterID,
                rewardID: current.rewardID,
                redemptionID: current.redemptionID,
                resolutionRawValue: resolution.rawValue,
                createdAt: current.createdAt,
                isDeadLetter: current.isDeadLetter,
                failureAttempts: current.failureAttempts
            )
            var replacement = items
            replacement[index] = replacementItem
            try persist(
                replacement,
                bitsItems: bitsItems,
                paidEventTombstones: paidEventTombstones,
                acknowledgedRedemptionTombstones:
                    acknowledgedRedemptionTombstones)
            items = replacement
            return replacementItem
        }
    }

    /// Shared insert for intake and direct-resolution items. Lookup is by
    /// business key, so a duplicate returns the existing item untouched.
    private func enqueue(
        broadcasterID: String,
        rewardID: String,
        redemptionID: String,
        resolutionRawValue: String,
        now: Date
    ) throws -> (item: Item, inserted: Bool) {
        guard !broadcasterID.isEmpty, !rewardID.isEmpty, !redemptionID.isEmpty else {
            throw StoreError.invalidItem
        }

        return try lock.withLock {
            guard !existingStoreIsUnreadable else {
                throw StoreError.unreadableExistingStore
            }
            if let existing = items.first(where: {
                $0.broadcasterID == broadcasterID
                    && $0.rewardID == rewardID
                    && $0.redemptionID == redemptionID
            }) {
                return (existing, false)
            }

            let item = Item(
                id: UUID(),
                broadcasterID: broadcasterID,
                rewardID: rewardID,
                redemptionID: redemptionID,
                resolutionRawValue: resolutionRawValue,
                createdAt: now,
                isDeadLetter: false,
                failureAttempts: 0
            )
            guard item.isValid else { throw StoreError.invalidItem }
            let replacement = items + [item]
            try persist(
                replacement,
                bitsItems: bitsItems,
                paidEventTombstones: paidEventTombstones,
                acknowledgedRedemptionTombstones:
                    acknowledgedRedemptionTombstones)
            items = replacement
            return (item, true)
        }
    }

    /// Atomically removes a completed work item and records its exact business
    /// identity as terminal. A crash can therefore leave either replayable work
    /// or a tombstone, never an unprotected post-PATCH gap.
    ///
    /// No-op when the item is already gone. Works on dead letters too.
    ///
    /// - Parameter date: Tombstone timestamp; `nil` uses the injected clock.
    ///   Expiry pruning always uses the injected clock.
    func acknowledge(
        _ id: Item.ID,
        at date: Date? = nil
    ) throws {
        try lock.withLock {
            guard !existingStoreIsUnreadable else {
                throw StoreError.unreadableExistingStore
            }
            guard let item = items.first(where: { $0.id == id }) else {
                return
            }
            let acknowledgedAt = date ?? nowProvider()
            let now = nowProvider()
            let replacementItems = items.filter { $0.id != id }
            let key = RedemptionKey(
                broadcasterID: item.broadcasterID,
                rewardID: item.rewardID,
                redemptionID: item.redemptionID)
            var replacementAcknowledged =
                Self.normalizedAcknowledgedRedemptionTombstones(
                    acknowledgedRedemptionTombstones,
                    now: now)
                    .filter {
                        RedemptionKey(
                            broadcasterID: $0.broadcasterID,
                            rewardID: $0.rewardID,
                            redemptionID: $0.redemptionID) != key
                    }
            replacementAcknowledged.append(
                AcknowledgedRedemptionTombstone(
                    broadcasterID: item.broadcasterID,
                    rewardID: item.rewardID,
                    redemptionID: item.redemptionID,
                    acknowledgedAt: acknowledgedAt))
            replacementAcknowledged =
                Self.normalizedAcknowledgedRedemptionTombstones(
                    replacementAcknowledged,
                    now: now)
            let replacementPaid = Self.normalizedPaidEventTombstones(
                paidEventTombstones,
                now: now)
            try persist(
                replacementItems,
                bitsItems: bitsItems,
                paidEventTombstones: replacementPaid,
                acknowledgedRedemptionTombstones:
                    replacementAcknowledged)
            items = replacementItems
            paidEventTombstones = replacementPaid
            acknowledgedRedemptionTombstones =
                replacementAcknowledged
        }
    }

    /// Removes a pending item without marking its business transaction done.
    /// Production Helix acknowledgement uses `acknowledge(_:at:)`; nothing in
    /// the app calls this. It is a test seam for draining fixtures and for
    /// exercising the failed-write path without writing tombstones.
    func remove(_ id: Item.ID) throws {
        try lock.withLock {
            guard !existingStoreIsUnreadable else {
                throw StoreError.unreadableExistingStore
            }
            let replacement = items.filter { $0.id != id }
            guard replacement.count != items.count else { return }
            try persist(
                replacement,
                bitsItems: bitsItems,
                paidEventTombstones: paidEventTombstones,
                acknowledgedRedemptionTombstones:
                    acknowledgedRedemptionTombstones)
            items = replacement
        }
    }
}
