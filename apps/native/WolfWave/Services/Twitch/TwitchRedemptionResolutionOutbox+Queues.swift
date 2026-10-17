//
//  TwitchRedemptionResolutionOutbox+Queues.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Channel-point and Bits queue reads and mutations: replay snapshots,
/// failure accounting, dead letters, and Bits acknowledgement.
nonisolated extension TwitchRedemptionResolutionOutbox {

    // MARK: - Channel-Point Queue

    /// Returns a stable oldest-first snapshot for replay. Excludes dead letters.
    func pendingItems() -> [Item] {
        lock.withLock {
            items.filter { !$0.deadLetter }.sorted { $0.createdAt < $1.createdAt }
        }
    }

    /// Read-only snapshot of dead-lettered items, oldest first. A test and
    /// diagnostics seam: ``pendingItems()`` excludes dead letters, so this is
    /// the only way to assert dead-letter state. Not shown in the UI.
    func deadLetterItems() -> [Item] {
        lock.withLock { items.filter(\.deadLetter).sorted { $0.createdAt < $1.createdAt } }
    }

    /// Durably increments the item's failure count. The retry worker calls this
    /// after a conflict it could not resolve and dead-letters the item once the
    /// returned count reaches its limit.
    ///
    /// - Returns: The new count, or the unchanged count for a dead letter.
    /// - Throws: `StoreError.missingItem`, `.unreadableExistingStore`, or the
    ///   write error (memory is left unchanged).
    @discardableResult
    func recordFailureAttempt(_ id: Item.ID) throws -> Int {
        try lock.withLock {
            guard !existingStoreIsUnreadable else {
                throw StoreError.unreadableExistingStore
            }
            guard let index = items.firstIndex(where: { $0.id == id }) else {
                throw StoreError.missingItem
            }
            let current = items[index]
            guard !current.deadLetter else { return current.attemptCount }
            let attempts = current.attemptCount + 1
            var replacement = items
            replacement[index] = Item(
                id: current.id,
                broadcasterID: current.broadcasterID,
                rewardID: current.rewardID,
                redemptionID: current.redemptionID,
                resolutionRawValue: current.resolutionRawValue,
                createdAt: current.createdAt,
                isDeadLetter: current.isDeadLetter,
                failureAttempts: attempts)
            try persist(
                replacement,
                bitsItems: bitsItems,
                paidEventTombstones: paidEventTombstones,
                acknowledgedRedemptionTombstones: acknowledgedRedemptionTombstones)
            items = replacement
            return attempts
        }
    }

    /// Parks an item so replay stops retrying it. The item keeps its business
    /// key, so a redelivery of the same redemption finds it via ``enqueueIntake``
    /// and is not re-processed. Beyond ``maximumDeadLetterItems`` the earliest
    /// dead letters in array (insertion) order are dropped.
    ///
    /// No-op for an item already dead-lettered.
    func moveToDeadLetter(_ id: Item.ID) throws {
        try lock.withLock {
            guard !existingStoreIsUnreadable else {
                throw StoreError.unreadableExistingStore
            }
            guard let index = items.firstIndex(where: { $0.id == id }) else {
                throw StoreError.missingItem
            }
            let current = items[index]
            guard !current.deadLetter else { return }
            var replacement = items
            replacement[index] = Item(
                id: current.id,
                broadcasterID: current.broadcasterID,
                rewardID: current.rewardID,
                redemptionID: current.redemptionID,
                resolutionRawValue: current.resolutionRawValue,
                createdAt: current.createdAt,
                isDeadLetter: true,
                failureAttempts: current.failureAttempts)
            while replacement.filter(\.deadLetter).count > Self.maximumDeadLetterItems {
                guard let oldest = replacement.firstIndex(where: \.deadLetter) else { break }
                replacement.remove(at: oldest)
            }
            try persist(
                replacement,
                bitsItems: bitsItems,
                paidEventTombstones: paidEventTombstones,
                acknowledgedRedemptionTombstones: acknowledgedRedemptionTombstones)
            items = replacement
        }
    }

    // MARK: - Bits Queue

    /// Returns stable oldest-first replayable Bits events, optionally scoped to
    /// one broadcaster during account teardown.
    func pendingBitsItems(
        broadcasterID: String? = nil
    ) -> [BitsItem] {
        lock.withLock {
            bitsItems
                .filter {
                    broadcasterID == nil
                        || $0.broadcasterID == broadcasterID
                }
                .sorted { $0.createdAt < $1.createdAt }
        }
    }

    /// Persists the complete Bits action before touching the volatile request
    /// queue. A terminal tombstone suppresses only work already acknowledged;
    /// a pending duplicate resumes the same durable item.
    ///
    /// Expired tombstones are pruned in memory as a side effect; that prune is
    /// only written to disk when a new item is inserted.
    ///
    /// - Returns: `(nil, false)` when a tombstone says the message was already
    ///   handled; `(existing, false)` for a pending duplicate; `(new, true)`
    ///   after a successful durable insert.
    /// - Throws: `StoreError.invalidItem`, `.unreadableExistingStore`, or the
    ///   write error.
    func enqueueBits(
        messageID: String,
        broadcasterID: String,
        userName: String,
        bits: Int,
        boostEnabled: Bool,
        query: String,
        userLogin: String? = nil
    ) throws -> (item: BitsItem?, inserted: Bool) {
        guard !messageID.isEmpty,
              !broadcasterID.isEmpty,
              !userName.isEmpty,
              bits > 0 else {
            throw StoreError.invalidItem
        }

        return try lock.withLock {
            guard !existingStoreIsUnreadable else {
                throw StoreError.unreadableExistingStore
            }
            let now = nowProvider()
            let normalizedPaid = Self.normalizedPaidEventTombstones(
                paidEventTombstones,
                now: now)
            let normalizedAcknowledged =
                Self.normalizedAcknowledgedRedemptionTombstones(
                    acknowledgedRedemptionTombstones,
                    now: now)
            let key = PaidEventKey(
                messageID: messageID,
                broadcasterID: broadcasterID,
                kind: .bitsUse)
            if normalizedPaid.contains(where: {
                PaidEventKey(
                    messageID: $0.messageID,
                    broadcasterID: $0.broadcasterID,
                    kind: $0.kind) == key
            }) {
                paidEventTombstones = normalizedPaid
                acknowledgedRedemptionTombstones =
                    normalizedAcknowledged
                return (nil, false)
            }
            if let existing = bitsItems.first(where: {
                $0.messageID == messageID
                    && $0.broadcasterID == broadcasterID
            }) {
                paidEventTombstones = normalizedPaid
                acknowledgedRedemptionTombstones =
                    normalizedAcknowledged
                return (existing, false)
            }

            let item = BitsItem(
                id: UUID(),
                messageID: messageID,
                broadcasterID: broadcasterID,
                userName: userName,
                bits: bits,
                boostEnabled: boostEnabled,
                query: query,
                createdAt: now,
                userLogin: userLogin)
            let replacementBitsItems = bitsItems + [item]
            try persist(
                items,
                bitsItems: replacementBitsItems,
                paidEventTombstones: normalizedPaid,
                acknowledgedRedemptionTombstones:
                    normalizedAcknowledged)
            bitsItems = replacementBitsItems
            paidEventTombstones = normalizedPaid
            acknowledgedRedemptionTombstones =
                normalizedAcknowledged
            return (item, true)
        }
    }

    /// Commits completion by atomically replacing replayable Bits intake with a
    /// TTL-bound transport tombstone. A missing item is already complete.
    ///
    /// - Parameter date: Tombstone timestamp; `nil` uses the injected clock.
    func acknowledgeBits(
        _ id: BitsItem.ID,
        at date: Date? = nil
    ) throws {
        try lock.withLock {
            guard !existingStoreIsUnreadable else {
                throw StoreError.unreadableExistingStore
            }
            guard let item = bitsItems.first(where: { $0.id == id }) else {
                return
            }
            let now = date ?? nowProvider()
            let key = PaidEventKey(
                messageID: item.messageID,
                broadcasterID: item.broadcasterID,
                kind: .bitsUse)
            let replacementBitsItems = bitsItems.filter { $0.id != id }
            var replacementPaid = Self.normalizedPaidEventTombstones(
                paidEventTombstones,
                now: now)
                .filter {
                    PaidEventKey(
                        messageID: $0.messageID,
                        broadcasterID: $0.broadcasterID,
                        kind: $0.kind) != key
                }
            replacementPaid.append(
                PaidEventTombstone(
                    messageID: item.messageID,
                    broadcasterID: item.broadcasterID,
                    kind: .bitsUse,
                    acceptedAt: now))
            replacementPaid = Self.normalizedPaidEventTombstones(
                replacementPaid,
                now: now)
            let normalizedAcknowledged =
                Self.normalizedAcknowledgedRedemptionTombstones(
                    acknowledgedRedemptionTombstones,
                    now: now)
            try persist(
                items,
                bitsItems: replacementBitsItems,
                paidEventTombstones: replacementPaid,
                acknowledgedRedemptionTombstones:
                    normalizedAcknowledged)
            bitsItems = replacementBitsItems
            paidEventTombstones = replacementPaid
            acknowledgedRedemptionTombstones =
                normalizedAcknowledged
        }
    }

    /// True only for the exact business transaction that already reached a
    /// terminal Helix acknowledgement. This remains separate from transport
    /// message IDs so another account or reward is never suppressed.
    ///
    /// Prunes expired tombstones in memory (not on disk) as a side effect.
    func hasAcknowledgedRedemption(
        broadcasterID: String,
        rewardID: String,
        redemptionID: String
    ) -> Bool {
        guard !broadcasterID.isEmpty,
              !rewardID.isEmpty,
              !redemptionID.isEmpty else {
            return false
        }
        return lock.withLock {
            let normalized =
                Self.normalizedAcknowledgedRedemptionTombstones(
                    acknowledgedRedemptionTombstones,
                    now: nowProvider())
            acknowledgedRedemptionTombstones = normalized
            let key = RedemptionKey(
                broadcasterID: broadcasterID,
                rewardID: rewardID,
                redemptionID: redemptionID)
            return normalized.contains {
                RedemptionKey(
                    broadcasterID: $0.broadcasterID,
                    rewardID: $0.rewardID,
                    redemptionID: $0.redemptionID) == key
            }
        }
    }
}
