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
        var isDeadLetter: Bool?
        /// Optional for the same reason. Read through ``attemptCount``.
        var failureAttempts: Int?

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
        var userLogin: String?

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
    struct PersistedState: Codable {
        static let currentVersion = 1

        let version: Int
        let items: [Item]
        let bitsItems: [BitsItem]
        let paidEventTombstones: [PaidEventTombstone]
        let acknowledgedRedemptionTombstones:
            [AcknowledgedRedemptionTombstone]
    }

    /// Business identity of a channel-point redemption.
    struct RedemptionKey: Hashable {
        let broadcasterID: String
        let rewardID: String
        let redemptionID: String
    }

    /// Transport identity of a paid EventSub message.
    struct PaidEventKey: Hashable {
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
    let lock = NSLock()
    let fileURL: URL
    let fileManager: FileManager
    /// Injected so tests can simulate a failed write; production uses
    /// ``durableAtomicWrite(_:to:)``.
    let atomicWriter: (Data, URL) throws -> Void
    /// Moves an unreadable file aside. Injected so tests can fail quarantine.
    let quarantineMover: (URL, URL) throws -> Void
    /// Copies a partially valid file aside before the salvage rewrite.
    let quarantineCopier: (URL, URL) throws -> Void
    /// Clock for tombstone expiry and new item timestamps. Injected for tests.
    let nowProvider: @Sendable () -> Date
    var items: [Item]
    var bitsItems: [BitsItem]
    var paidEventTombstones: [PaidEventTombstone]
    var acknowledgedRedemptionTombstones:
        [AcknowledgedRedemptionTombstone]
    /// Set when the file could not be read AND could not be quarantined. Every
    /// mutation then throws so the unread bytes are never overwritten.
    var existingStoreIsUnreadable = false
    /// Sticky after any failed ``persist``; cleared only by
    /// ``verifyIntakeStorage()``. Reported by ``intakeStorageIsUnavailable()``.
    var intakeStorageHasFailed = false
    /// True while quarantine files exist beside the store. Re-derived from the
    /// directory on init, so it survives relaunch.
    var opaqueRecoveryRisk = false

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
}
