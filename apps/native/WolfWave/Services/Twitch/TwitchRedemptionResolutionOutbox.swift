//
//  TwitchRedemptionResolutionOutbox.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-08-12.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Darwin
import Foundation

/// Atomic disk-backed state for paid Twitch event intake and completion.
///
/// Channel-point work is retained through its terminal Helix acknowledgement;
/// Bits work is persisted before queue mutation and replaced atomically by an
/// exact EventSub tombstone afterward. Exact channel-point business tombstones
/// and Bits message tombstones close late-redelivery, reconnect, and relaunch
/// windows without relying on the bounded transport dedup cache.
///
/// Thread safety: all mutable state is guarded by ``lock``, which is why the
/// class is `@unchecked Sendable`. Every mutation writes the full replacement
/// state to disk first and only then swaps it into memory, so a failed write
/// leaves memory matching the last durable file.
///
/// Failure modes: an unreadable file is quarantined (renamed aside) on init; if
/// even that fails, ``existingStoreIsUnreadable`` makes every mutation throw
/// rather than overwrite bytes that may hold paid work. Any failed write sets a
/// sticky flag cleared only by ``verifyIntakeStorage()``.
nonisolated final class TwitchRedemptionResolutionOutbox: @unchecked Sendable {
    // MARK: - Types

    /// One channel-point redemption awaiting a terminal Helix PATCH. Identified
    /// for business purposes by (broadcaster, reward, redemption); `id` is a
    /// local handle only.
    struct Item: Codable, Equatable, Identifiable, Sendable {
        /// Sentinel stored in `resolutionRawValue` while the outcome is still
        /// unknown. Not a Twitch status, so it never reaches Helix.
        static let intakeRawValue = "WOLFWAVE_INTAKE"

        let id: UUID
        let broadcasterID: String
        let rewardID: String
        let redemptionID: String
        /// Either ``intakeRawValue`` or a `Resolution` raw value
        /// (`FULFILLED` / `CANCELED`).
        let resolutionRawValue: String
        let createdAt: Date

        /// Optional so files written before dead-lettering existed still decode.
        /// Read through ``deadLetter``.
        var isDeadLetter: Bool? = nil
        /// Optional for the same reason. Read through ``attemptCount``.
        var failureAttempts: Int? = nil

        /// True once the retry worker gave up. Excluded from ``pendingItems()``.
        var deadLetter: Bool { isDeadLetter == true }
        /// Recorded conflict failures, clamped to non-negative.
        var attemptCount: Int { max(0, failureAttempts ?? 0) }

        /// The final outcome, or `nil` while still in the intake phase.
        var resolution: TwitchChannelPointsService.Resolution? {
            TwitchChannelPointsService.Resolution(rawValue: resolutionRawValue)
        }

        /// Persisted before song lookup or queue mutation. If the process exits
        /// while this phase remains, replay refunds because the in-memory song
        /// request outcome cannot be reconstructed safely.
        var isIntake: Bool { resolutionRawValue == Self.intakeRawValue }

        /// All IDs non-empty and the raw value is intake or a known resolution.
        /// Invalid items found on load trigger the copy-then-salvage path.
        var isValid: Bool {
            !broadcasterID.isEmpty
                && !rewardID.isEmpty
                && !redemptionID.isEmpty
                && (isIntake || resolution != nil)
        }
    }

    /// A complete Bits cheer action (request and/or boost), persisted before the
    /// request queue is touched so it can be replayed after a relaunch. Keyed
    /// by the EventSub `messageID` plus broadcaster.
    struct BitsItem: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let messageID: String
        let broadcasterID: String
        let userName: String
        let bits: Int
        let boostEnabled: Bool
        /// The song query parsed from the cheer message. May be empty.
        let query: String
        let createdAt: Date
        /// Optional so older files decode; newer intake records the login.
        var userLogin: String? = nil

        /// Same rule ``enqueueBits`` enforces on input. `query` may be empty.
        var isValid: Bool {
            !messageID.isEmpty
                && !broadcasterID.isEmpty
                && !userName.isEmpty
                && bits > 0
        }
    }

    /// Which EventSub subscription a paid-event tombstone belongs to, so equal
    /// message IDs from different event types never collide.
    enum PaidEventKind: String, Codable, Equatable, Hashable, Sendable {
        case channelPointRedemption
        case bitsUse
    }

    /// Marks a paid EventSub message as fully processed. Kept for
    /// ``paidEventTombstoneRetention`` so a redelivery inside Twitch's replay
    /// window is dropped. Today only Bits writes these.
    struct PaidEventTombstone: Codable, Equatable, Sendable {
        let messageID: String
        let broadcasterID: String
        let kind: PaidEventKind
        let acceptedAt: Date

        var isValid: Bool {
            !messageID.isEmpty && !broadcasterID.isEmpty
        }
    }

    /// Marks a channel-point redemption whose terminal Helix PATCH succeeded.
    /// Keyed by business identity, not EventSub message ID, so a redelivery
    /// under a new message ID is still recognized.
    struct AcknowledgedRedemptionTombstone: Codable, Equatable, Sendable {
        let broadcasterID: String
        let rewardID: String
        let redemptionID: String
        let acknowledgedAt: Date

        var isValid: Bool {
            !broadcasterID.isEmpty
                && !rewardID.isEmpty
                && !redemptionID.isEmpty
        }
    }

    /// Twitch accepts frames from 10 minutes ago and allows 30 seconds of
    /// forward clock skew. Paid-event tombstones therefore remain durable for
    /// that complete local acceptance horizon without a count cap that busy
    /// channels could evict early.
    /// Seconds. Applies to both tombstone kinds.
    static let paidEventTombstoneRetention: TimeInterval = 10 * 60 + 30
    /// Cap on retained dead letters; ``moveToDeadLetter(_:)`` evicts the
    /// earliest-inserted ones beyond this.
    static let maximumDeadLetterItems = 100

    /// On-disk JSON shape. Version 0 was a bare `[Item]` array and is migrated
    /// on load; any other version is treated as unreadable and quarantined.
    private struct PersistedState: Codable {
        static let currentVersion = 1

        let version: Int
        let items: [Item]
        let bitsItems: [BitsItem]
        let paidEventTombstones: [PaidEventTombstone]
        let acknowledgedRedemptionTombstones:
            [AcknowledgedRedemptionTombstone]
    }

    /// Business identity of a channel-point redemption.
    private struct RedemptionKey: Hashable {
        let broadcasterID: String
        let rewardID: String
        let redemptionID: String
    }

    /// Transport identity of a paid EventSub message.
    private struct PaidEventKey: Hashable {
        let messageID: String
        let broadcasterID: String
        let kind: PaidEventKind
    }

    /// Load-time structural failures. Both route to quarantine.
    private enum DecodeError: Error {
        case unsupportedVersion
        case duplicateRedemption
    }

    /// Errors thrown by mutating calls.
    enum StoreError: Error {
        /// Empty IDs, non-positive bits, or an otherwise invalid record.
        case invalidItem
        /// No item with that local ID (already acknowledged or never stored).
        case missingItem
        /// The file on disk could not be read or quarantined; writes are refused.
        case unreadableExistingStore
        /// Opaque recovery cannot be cleared while work is still queued.
        case unresolvedRecoveryRisk
    }

    // MARK: - Properties

    /// The app-wide instance backed by `State/twitch-redemption-resolution-outbox.json`.
    static let shared = TwitchRedemptionResolutionOutbox()

    /// Guards every `var` below and serializes disk writes.
    private let lock = NSLock()
    private let fileURL: URL
    private let fileManager: FileManager
    /// Injected so tests can simulate a failed write; production uses
    /// ``durableAtomicWrite(_:to:)``.
    private let atomicWriter: (Data, URL) throws -> Void
    /// Moves an unreadable file aside. Injected so tests can fail quarantine.
    private let quarantineMover: (URL, URL) throws -> Void
    /// Copies a partially valid file aside before the salvage rewrite.
    private let quarantineCopier: (URL, URL) throws -> Void
    /// Clock for tombstone expiry and new item timestamps. Injected for tests.
    private let nowProvider: @Sendable () -> Date
    private var items: [Item]
    private var bitsItems: [BitsItem]
    private var paidEventTombstones: [PaidEventTombstone]
    private var acknowledgedRedemptionTombstones:
        [AcknowledgedRedemptionTombstone]
    /// Set when the file could not be read AND could not be quarantined. Every
    /// mutation then throws so the unread bytes are never overwritten.
    private var existingStoreIsUnreadable = false
    /// Sticky after any failed ``persist``; cleared only by
    /// ``verifyIntakeStorage()``. Reported by ``intakeStorageIsUnavailable()``.
    private var intakeStorageHasFailed = false
    /// True while quarantine files exist beside the store. Re-derived from the
    /// directory on init, so it survives relaunch.
    private var opaqueRecoveryRisk = false

    // MARK: - Lifecycle

    /// Loads, validates, and if needed migrates or salvages the store.
    ///
    /// Outcomes, in order:
    /// - No file: empty state.
    /// - Unreadable, unsupported version, or duplicate keys: the file is
    ///   renamed to a `.corrupt-<UUID>` sibling and state starts empty.
    /// - Some invalid records: the original is copied aside, then the valid
    ///   subset is rewritten.
    /// - Version-0 format or expired/clamped tombstones: rewritten in place.
    ///
    /// Does synchronous file I/O; ``shared`` is created lazily on first use.
    ///
    /// - Parameters:
    ///   - quarantineMover: `nil` uses `FileManager.moveItem`.
    ///   - quarantineCopier: `nil` uses `FileManager.copyItem`.
    init(
        fileURL: URL = AppContainer.directory("State")
            .appending(path: "twitch-redemption-resolution-outbox.json"),
        fileManager: FileManager = .default,
        atomicWriter: @escaping (Data, URL) throws -> Void = { data, url in
            try TwitchRedemptionResolutionOutbox.durableAtomicWrite(data, to: url)
        },
        quarantineMover: ((URL, URL) throws -> Void)? = nil,
        quarantineCopier: ((URL, URL) throws -> Void)? = nil,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.atomicWriter = atomicWriter
        self.quarantineMover = quarantineMover ?? { source, destination in
            try fileManager.moveItem(at: source, to: destination)
        }
        self.quarantineCopier = quarantineCopier ?? { source, destination in
            try fileManager.copyItem(at: source, to: destination)
        }
        self.nowProvider = nowProvider
        self.items = []
        self.bitsItems = []
        self.paidEventTombstones = []
        self.acknowledgedRedemptionTombstones = []
        // Quarantine files left by an earlier launch still count as risk.
        let quarantinePrefix = fileURL.lastPathComponent + ".corrupt-"
        self.opaqueRecoveryRisk = (
            try? fileManager.contentsOfDirectory(
                atPath: fileURL.deletingLastPathComponent().path)
        )?.contains {
            $0.hasPrefix(quarantinePrefix)
        } ?? false
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        var decodedItems: [Item] = []
        var decodedBitsItems: [BitsItem] = []
        var decodedPaidEventTombstones: [PaidEventTombstone] = []
        var decodedAcknowledgedTombstones:
            [AcknowledgedRedemptionTombstone] = []
        var needsFormatMigration = false
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            if let state = try? decoder.decode(
                PersistedState.self,
                from: data
            ) {
                guard state.version == PersistedState.currentVersion else {
                    throw DecodeError.unsupportedVersion
                }
                decodedItems = state.items
                decodedBitsItems = state.bitsItems
                decodedPaidEventTombstones = state.paidEventTombstones
                decodedAcknowledgedTombstones =
                    state.acknowledgedRedemptionTombstones
            } else {
                // Version-zero files stored only the pending item array.
                decodedItems = try decoder.decode([Item].self, from: data)
                needsFormatMigration = true
            }

            // Duplicate keys mean the file cannot be trusted to say which copy
            // is current, so they fail the whole load rather than one record.
            var itemIDs = Set<Item.ID>()
            var businessKeys = Set<RedemptionKey>()
            for item in decodedItems {
                guard itemIDs.insert(item.id).inserted else {
                    throw DecodeError.duplicateRedemption
                }
                let key = RedemptionKey(
                    broadcasterID: item.broadcasterID,
                    rewardID: item.rewardID,
                    redemptionID: item.redemptionID)
                guard businessKeys.insert(key).inserted else {
                    throw DecodeError.duplicateRedemption
                }
            }
            var bitsItemIDs = Set<BitsItem.ID>()
            var bitsKeys = Set<PaidEventKey>()
            for item in decodedBitsItems {
                let key = PaidEventKey(
                    messageID: item.messageID,
                    broadcasterID: item.broadcasterID,
                    kind: .bitsUse)
                guard bitsItemIDs.insert(item.id).inserted,
                      bitsKeys.insert(key).inserted else {
                    throw DecodeError.duplicateRedemption
                }
            }
        } catch {
            do {
                let quarantineURL = try quarantineExistingStore()
                opaqueRecoveryRisk = true
                Log.error(
                    "Twitch redemption outbox was quarantined at \(quarantineURL.lastPathComponent): \(error.localizedDescription)",
                    category: .twitchRedeem
                )
            } catch let quarantineError {
                // If recovery bytes cannot be preserved, refuse to overwrite
                // them. This rare filesystem failure remains visible in logs.
                self.existingStoreIsUnreadable = true
                Log.error(
                    "Twitch redemption outbox quarantine failed: \(quarantineError.localizedDescription)",
                    category: .twitchRedeem
                )
            }
            return
        }

        let validItems = decodedItems.filter(\.isValid)
        let validBitsItems = decodedBitsItems.filter(\.isValid)
        let now = nowProvider()
        let validPaidEventTombstones = Self.normalizedPaidEventTombstones(
            decodedPaidEventTombstones,
            now: now)
        let validAcknowledgedTombstones =
            Self.normalizedAcknowledgedRedemptionTombstones(
                decodedAcknowledgedTombstones,
                now: now)
        let containsInvalidData =
            validItems.count != decodedItems.count
                || validBitsItems.count != decodedBitsItems.count
                || decodedPaidEventTombstones.contains { !$0.isValid }
                || decodedAcknowledgedTombstones.contains { !$0.isValid }

        self.items = validItems
        self.bitsItems = validBitsItems
        self.paidEventTombstones = validPaidEventTombstones
        self.acknowledgedRedemptionTombstones =
            validAcknowledgedTombstones

        if containsInvalidData {
            do {
                // Copy before replacing the live file. If the atomic rewrite
                // fails, the original remains available for another salvage.
                let quarantineURL = try copyExistingStoreToQuarantine()
                opaqueRecoveryRisk = true
                do {
                    try persist(
                        validItems,
                        bitsItems: validBitsItems,
                        paidEventTombstones: validPaidEventTombstones,
                        acknowledgedRedemptionTombstones:
                            validAcknowledgedTombstones)
                } catch {
                    Log.error(
                        "Twitch redemption outbox valid subset could not be restored: \(error.localizedDescription)",
                        category: .twitchRedeem
                    )
                }
                Log.error(
                    "Twitch redemption outbox contained invalid records; original quarantined at \(quarantineURL.lastPathComponent)",
                    category: .twitchRedeem
                )
            } catch {
                existingStoreIsUnreadable = true
                Log.error(
                    "Twitch redemption outbox quarantine failed: \(error.localizedDescription)",
                    category: .twitchRedeem
                )
            }
            return
        }

        let needsRewrite =
            needsFormatMigration
                || validPaidEventTombstones != decodedPaidEventTombstones
                || validAcknowledgedTombstones
                    != decodedAcknowledgedTombstones
        guard needsRewrite else { return }
        do {
            try persist(
                validItems,
                bitsItems: validBitsItems,
                paidEventTombstones: validPaidEventTombstones,
                acknowledgedRedemptionTombstones:
                    validAcknowledgedTombstones)
        } catch {
            Log.error(
                "Twitch redemption outbox maintenance write failed: \(error.localizedDescription)",
                category: .twitchRedeem)
        }
    }

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

    // MARK: - Private Helpers

    /// Drops invalid and expired tombstones, clamps future-dated ones to `now`,
    /// keeps the newest per key, and sorts deterministically so an unchanged
    /// set compares equal (which is how init decides whether to rewrite).
    private static func normalizedPaidEventTombstones(
        _ tombstones: [PaidEventTombstone],
        now: Date
    ) -> [PaidEventTombstone] {
        let oldestAcceptedAt = now.addingTimeInterval(
            -paidEventTombstoneRetention)
        var newestByKey: [PaidEventKey: PaidEventTombstone] = [:]
        for original in tombstones where original.isValid {
            // A tombstone dated after `now` means the wall clock moved
            // backwards since it was written. Dropping it would reopen the
            // duplicate-delivery window for a paid event, so keep it and
            // restart its retention from now instead.
            let tombstone = original.acceptedAt > now
                ? PaidEventTombstone(
                    messageID: original.messageID,
                    broadcasterID: original.broadcasterID,
                    kind: original.kind,
                    acceptedAt: now)
                : original
            guard tombstone.acceptedAt >= oldestAcceptedAt else { continue }
            let key = PaidEventKey(
                messageID: tombstone.messageID,
                broadcasterID: tombstone.broadcasterID,
                kind: tombstone.kind)
            if let existing = newestByKey[key],
               existing.acceptedAt >= tombstone.acceptedAt {
                continue
            }
            newestByKey[key] = tombstone
        }
        return newestByKey.values.sorted {
            if $0.acceptedAt != $1.acceptedAt {
                return $0.acceptedAt < $1.acceptedAt
            }
            if $0.broadcasterID != $1.broadcasterID {
                return $0.broadcasterID < $1.broadcasterID
            }
            if $0.kind != $1.kind {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.messageID < $1.messageID
        }
    }

    /// Same normalization as ``normalizedPaidEventTombstones(_:now:)`` for
    /// acknowledged-redemption tombstones.
    private static func normalizedAcknowledgedRedemptionTombstones(
        _ tombstones: [AcknowledgedRedemptionTombstone],
        now: Date
    ) -> [AcknowledgedRedemptionTombstone] {
        let oldestAcknowledgedAt = now.addingTimeInterval(
            -paidEventTombstoneRetention)
        var newestByKey:
            [RedemptionKey: AcknowledgedRedemptionTombstone] = [:]
        for original in tombstones where original.isValid {
            // Same rule as paid-event tombstones: a future date means the
            // clock moved backwards, so clamp to now rather than forget it.
            let tombstone = original.acknowledgedAt > now
                ? AcknowledgedRedemptionTombstone(
                    broadcasterID: original.broadcasterID,
                    rewardID: original.rewardID,
                    redemptionID: original.redemptionID,
                    acknowledgedAt: now)
                : original
            guard tombstone.acknowledgedAt >= oldestAcknowledgedAt else { continue }
            let key = RedemptionKey(
                broadcasterID: tombstone.broadcasterID,
                rewardID: tombstone.rewardID,
                redemptionID: tombstone.redemptionID)
            if let existing = newestByKey[key],
               existing.acknowledgedAt >= tombstone.acknowledgedAt {
                continue
            }
            newestByKey[key] = tombstone
        }
        return newestByKey.values.sorted {
            if $0.acknowledgedAt != $1.acknowledgedAt {
                return $0.acknowledgedAt < $1.acknowledgedAt
            }
            if $0.broadcasterID != $1.broadcasterID {
                return $0.broadcasterID < $1.broadcasterID
            }
            if $0.rewardID != $1.rewardID {
                return $0.rewardID < $1.rewardID
            }
            return $0.redemptionID < $1.redemptionID
        }
    }

    /// Encodes and durably writes the complete state. Caller must hold ``lock``
    /// and must assign the new values to memory only after this returns.
    ///
    /// Any failure sets ``intakeStorageHasFailed`` before rethrowing.
    private func persist(
        _ replacement: [Item],
        bitsItems: [BitsItem],
        paidEventTombstones: [PaidEventTombstone],
        acknowledgedRedemptionTombstones:
            [AcknowledgedRedemptionTombstone]
    ) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let state = PersistedState(
                version: PersistedState.currentVersion,
                items: replacement,
                bitsItems: bitsItems,
                paidEventTombstones: paidEventTombstones,
                acknowledgedRedemptionTombstones:
                    acknowledgedRedemptionTombstones)
            let data = try JSONEncoder().encode(state)
            try atomicWriter(data, fileURL)
        } catch {
            intakeStorageHasFailed = true
            throw error
        }
    }

    // MARK: Durable write

    /// The production writer: temp file, full flush to the platter, rename
    /// over the live file, then flush the directory entry.
    ///
    /// `Data.write(options: .atomic)` renames but never flushes, so a power
    /// loss right after a paid intake was "persisted" could leave the old file
    /// (or an empty one) on disk. This queue is what refunds or replays paid
    /// events, so it pays for `F_FULLFSYNC`.
    ///
    /// - Throws: The underlying file or POSIX error. The temp file is removed
    ///   on failure and the live file is left untouched.
    static func durableAtomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let tempURL = directory.appending(
            path: ".\(url.lastPathComponent).tmp-\(UUID().uuidString)",
            directoryHint: .notDirectory)
        guard FileManager.default.createFile(
            atPath: tempURL.path, contents: nil,
            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: tempURL)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            // F_FULLFSYNC asks the drive itself to flush; plain fsync on
            // macOS only reaches the drive's cache. Fall back when the
            // filesystem does not support it.
            if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 {
                try handle.synchronize()
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        guard rename(tempURL.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: tempURL)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        // Persist the rename itself. Best effort: the data is already safe in
        // the renamed inode, and some filesystems refuse fsync on a directory.
        let directoryDescriptor = open(directory.path, O_RDONLY)
        if directoryDescriptor >= 0 {
            _ = fsync(directoryDescriptor)
            close(directoryDescriptor)
        }
    }

    /// Same-directory rename is atomic on the app-container volume and retains
    /// every byte for diagnostics/manual recovery.
    private func quarantineExistingStore() throws -> URL {
        let quarantineURL = makeQuarantineURL()
        try quarantineMover(fileURL, quarantineURL)
        return quarantineURL
    }

    /// Preserves recovery bytes without creating a window where no live queue
    /// exists. The caller may now atomically replace `fileURL` with salvaged
    /// items while a failed replacement leaves the original intact.
    private func copyExistingStoreToQuarantine() throws -> URL {
        let quarantineURL = makeQuarantineURL()
        try quarantineCopier(fileURL, quarantineURL)
        return quarantineURL
    }

    /// `<store>.corrupt-<UUID>` in the same directory. The prefix is what init
    /// and ``clearOpaqueRecoveryRiskAfterReconciliation()`` scan for.
    private func makeQuarantineURL() -> URL {
        fileURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
    }
}
