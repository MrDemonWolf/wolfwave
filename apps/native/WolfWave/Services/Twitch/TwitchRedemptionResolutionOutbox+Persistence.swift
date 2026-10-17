//
//  TwitchRedemptionResolutionOutbox+Persistence.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Darwin
import Foundation

/// Tombstone normalization, the durable atomic write, and quarantine of
/// an unreadable store.
nonisolated extension TwitchRedemptionResolutionOutbox {

    // MARK: - Private Helpers

    /// Drops invalid and expired tombstones, clamps future-dated ones to `now`,
    /// keeps the newest per key, and sorts deterministically so an unchanged
    /// set compares equal (which is how init decides whether to rewrite).
    static func normalizedPaidEventTombstones(
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
    static func normalizedAcknowledgedRedemptionTombstones(
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
    func persist(
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
    func quarantineExistingStore() throws -> URL {
        let quarantineURL = makeQuarantineURL()
        try quarantineMover(fileURL, quarantineURL)
        return quarantineURL
    }

    /// Preserves recovery bytes without creating a window where no live queue
    /// exists. The caller may now atomically replace `fileURL` with salvaged
    /// items while a failed replacement leaves the original intact.
    func copyExistingStoreToQuarantine() throws -> URL {
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
