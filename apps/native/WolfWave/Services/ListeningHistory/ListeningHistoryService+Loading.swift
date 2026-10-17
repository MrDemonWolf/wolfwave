//
//  ListeningHistoryService+Loading.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// The background disk load: retention, the rolling-window cap with lifetime
/// folding, sequence repair, crash-safe clear recovery, and the ordered flush
/// of plays recorded while the read was in flight.
extension ListeningHistoryService {

    // MARK: - Disk Load

    /// Loads history from disk on a background task, applies retention and the
    /// rolling-window cap (folding evicted records into the lifetime tally),
    /// then publishes the result on the main actor.
    ///
    /// Internal rather than private so tests can await it directly.
    func loadFromDisk() async {
        if let loadTask {
            await loadTask.value
            return
        }
        isLoading = true
        await loadFromDisk(generation: historyGeneration)
    }

    /// Performs one load owned by `generation`. `scheduleLoad()` passes the
    /// generation captured before its task is spawned so a same-turn clear can
    /// invalidate work that has not begun executing yet.
    func loadFromDisk(generation: Int) async {
        let store = self.store
        let tallyStore = self.tallyStore
        let clearMarkerStore = self.clearMarkerStore
        let loadReadBarrier = self.loadReadBarrier
        let retentionDays = DefaultsStore.store.integer(
            forKey: AppConstants.UserDefaults.historyRetentionDays
        )
        let cap = AppConstants.History.maxRetainedRecords

        /// Everything the detached reader decided, applied on the main actor
        /// only if no clear happened meanwhile. `should…` flags are deferred
        /// writes; the reader itself only reads, except for finishing a
        /// pending clear.
        struct LoadResult: Sendable {
            let records: [PlayRecord]
            let tally: LifetimeTally
            let retentionExpiredCount: Int
            let foldedCount: Int
            let shouldRewrite: Bool
            let shouldClearTally: Bool
            let shouldSaveTally: Bool
            let nextSequence: UInt64
            let clearRecoveryPending: Bool
        }

        let result = await Task.detached(priority: .utility) { () -> LoadResult in
            let preserveLifetime = retentionDays <= 0
            if clearMarkerStore.isPending {
                let logCleared = store.clear()
                let tallyCleared = tallyStore.clear()
                let completed = logCleared && tallyCleared
                    && clearMarkerStore.complete()
                guard completed else {
                    return LoadResult(
                        records: [], tally: .empty,
                        retentionExpiredCount: 0, foldedCount: 0,
                        shouldRewrite: false, shouldClearTally: false,
                        shouldSaveTally: false, nextSequence: 1,
                        clearRecoveryPending: true)
                }
            }
            var all = store.loadAll()
            var tally = preserveLifetime ? tallyStore.load() : .empty
            loadReadBarrier?()
            var shouldRewrite = false
            var shouldSaveTally = false
            var retentionExpiredCount = 0

            // Normalize legacy/malformed sequence values deterministically from
            // file order alone. This must not depend on the persisted tally:
            // when a tally save succeeds but the matching log rewrite fails,
            // the same source lines must receive the same sequences next launch
            // so the tally high-water mark prevents a second fold.
            var previousSequence: UInt64 = 0
            for index in all.indices {
                if let sequence = all[index].sequence,
                   sequence > previousSequence {
                    previousSequence = sequence
                } else if previousSequence < UInt64.max {
                    previousSequence += 1
                    all[index] = all[index].assigningSequence(previousSequence)
                    shouldRewrite = true
                }
            }
            let highestSequence = Swift.max(
                previousSequence, tally.lastFoldedSequence ?? 0)

            // 1. Day-based retention (existing behavior. These records are
            //    *expired* by the user's setting, so they're dropped, NOT
            //    folded into the lifetime tally).
            if retentionDays > 0 {
                let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
                let kept = all.filter { $0.timestamp >= cutoff }
                if kept.count != all.count {
                    retentionExpiredCount = all.count - kept.count
                    all = kept
                    shouldRewrite = true
                }
            }

            // 2. Rolling-window cap. Fold the oldest overflow into the tally.
            //    Only fold records newer than the tally's high-water mark: after
            //    a clean shutdown the NDJSON was compacted so the overflow is all
            //    genuinely new, but after an unclean exit (crash / Force Quit /
            //    kill) the NDJSON can still hold records already folded into the
            //    persisted tally. Re-folding those would double-count lifetime
            //    stats, so skip anything at or before the mark while still
            //    trimming it out of the in-memory window (and off disk below).
            var foldedCount = 0
            let overflow = Swift.max(0, all.count - cap)
            let evicted = Array(all.prefix(overflow))

            // Legacy tallies used timestamps as their crash-recovery marker.
            // Translate that one time into the sequence boundary represented by
            // the currently-evicted prefix. Future equal-timestamp records are
            // then distinguished exactly by sequence.
            if preserveLifetime,
               tally.lastFoldedSequence == nil,
               !tally.isEmpty || tally.lastFoldedTimestamp != nil {
                let baseline: UInt64
                if let firstSequence = all.first?.sequence {
                    baseline = firstSequence > 0 ? firstSequence - 1 : 0
                } else {
                    baseline = highestSequence
                }
                var migratedMark = baseline
                if let timestampMark = tally.lastFoldedTimestamp {
                    for record in evicted {
                        guard record.timestamp <= timestampMark else { break }
                        migratedMark = record.sequence ?? migratedMark
                    }
                }
                tally.lastFoldedSequence = migratedMark
                shouldSaveTally = true
            }

            if all.count > cap {
                all.removeFirst(overflow)
                if preserveLifetime {
                    let mark = tally.lastFoldedSequence ?? 0
                    let toFold = evicted.filter { ($0.sequence ?? 0) > mark }
                    tally.fold(toFold)
                    foldedCount = toFold.count
                    shouldSaveTally = shouldSaveTally || !toFold.isEmpty
                }
                shouldRewrite = true
            }

            let nextSequence = highestSequence < UInt64.max
                ? highestSequence + 1
                : UInt64.max

            return LoadResult(
                records: all, tally: tally,
                retentionExpiredCount: retentionExpiredCount,
                foldedCount: foldedCount,
                shouldRewrite: shouldRewrite,
                shouldClearTally: !preserveLifetime,
                shouldSaveTally: preserveLifetime && shouldSaveTally,
                nextSequence: nextSequence,
                clearRecoveryPending: false)
        }.value

        guard generation == historyGeneration else {
            // A user clear won while the detached read was suspended. Never
            // publish or persist the stale result; only flush post-clear plays.
            isLoaded = true
            finishLoading()
            Log.info(
                "ListeningHistoryService: Discarded stale disk load after history clear",
                category: .history)
            return
        }

        if result.clearRecoveryPending {
            records = []
            lifetime = .empty
            nextSequence = 1
            isLoaded = true
            needsCompaction = false
            needsTallyPersistence = false
            if completePendingClear() {
                finishLoading()
            } else {
                // Records captured while deletion is unresolved cannot be
                // appended behind the tombstone; recovery would erase them.
                deferredDuringLoad.removeAll()
                isLoading = false
                rebuildSnapshot()
            }
            Log.error(
                "ListeningHistoryService: History clear still pending after launch recovery",
                category: .history)
            return
        }
        clearIsPending = false

        var tallyIsDurable = true
        if result.shouldClearTally {
            tallyIsDurable = tallyStore.clear()
        } else if result.shouldSaveTally {
            tallyIsDurable = tallyStore.save(result.tally)
        }
        var rewriteSucceeded = !result.shouldRewrite
        if result.shouldRewrite, tallyIsDurable {
            rewriteSucceeded = store.replaceAll(with: result.records)
        }
        records = result.records
        lifetime = result.tally
        nextSequence = result.nextSequence
        isLoaded = true
        needsTallyPersistence = (result.shouldClearTally || result.shouldSaveTally)
            && !tallyIsDurable
        needsCompaction = result.shouldRewrite && !rewriteSucceeded
        finishLoading()
        if DefaultsStore.store.integer(forKey: AppConstants.UserDefaults.historyRetentionDays) != retentionDays {
            prune()
        }

        if result.foldedCount > 0 {
            Log.info(
                "ListeningHistoryService: Folded \(result.foldedCount) old plays into lifetime tally (cap \(cap))",
                category: .history
            )
        }
        if result.retentionExpiredCount > 0 {
            Log.info(
                "ListeningHistoryService: Expired \(result.retentionExpiredCount) plays under finite retention",
                category: .history
            )
        }
        Log.info(
            "ListeningHistoryService: Loaded \(result.records.count) plays from disk",
            category: .history
        )
    }

    /// Ends load mode and flushes records captured while the disk read was in
    /// flight, preserving their arrival order.
    private func finishLoading() {
        // No await separates clearing the flag, taking the buffer, and appending
        // it, so a live record cannot interleave with this ordered flush.
        isLoading = false
        let buffered = deferredDuringLoad
        deferredDuringLoad.removeAll()
        for record in buffered {
            appendRecord(record)
        }
        rebuildSnapshot()
    }
}
