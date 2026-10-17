//
//  ListeningHistoryServiceTests+RollingWindow.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation

@testable import WolfWave

/// The rolling-window cap: overflow folding into the lifetime tally, sequence repair, and shutdown persistence.
extension ListeningHistoryServiceTests {
    // MARK: - Rolling Window Cap

    @Test("loadFromDisk trims to maxRetainedRecords and folds the rest into the lifetime tally")
    func testLoadFromDiskTrimsToCap() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cap = AppConstants.History.maxRetainedRecords
        let overflow = 5
        let total = cap + overflow

        // Seed the play log directly with `total` records, oldest first.
        let store = PlayLogStore(directory: dir)
        let base = Date().addingTimeInterval(-Double(total) * 60) // 1/min back
        var seeded: [PlayRecord] = []
        seeded.reserveCapacity(total)
        for i in 0..<total {
            seeded.append(PlayRecord(
                timestamp: base.addingTimeInterval(Double(i) * 60),
                track: "T\(i)", artist: "A\(i % 50)", album: "Al",
                duration: 200, playedSeconds: 200
            ))
        }
        store.replaceAll(with: seeded)

        let service = makeService(enabled: true, directory: dir)
        await service.loadFromDisk()

        #expect(service.records.count == cap)
        #expect(service.snapshot.totalPlays == total)
        // The newest record must still be present after trimming.
        #expect(service.records.last?.track == "T\(total - 1)")

        // The lifetime tally file must exist and reflect the trimmed overflow.
        let tallyOnDisk = LifetimeTallyStore(directory: dir).load()
        #expect(tallyOnDisk.trimmedPlayCount == overflow)
    }

    @Test("sequence high-water survives identical timestamps and a backward clock")
    func testSequenceHighWaterHandlesDuplicateAndBackwardTimestamps() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cap = AppConstants.History.maxRetainedRecords
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let seeded = (0..<(cap + 3)).map { index in
            PlayRecord(
                timestamp: index == 2
                    ? timestamp.addingTimeInterval(-3_600)
                    : timestamp,
                track: "T\(index)", artist: "Wolf", album: "",
                duration: 200, playedSeconds: 200,
                sequence: UInt64(index + 1))
        }
        let store = PlayLogStore(directory: dir)
        #expect(store.replaceAll(with: seeded))
        var tally = LifetimeTally.empty
        tally.fold(seeded[0])
        let tallyStore = LifetimeTallyStore(directory: dir)
        #expect(tallyStore.save(tally))

        let service = makeService(enabled: true, directory: dir)
        await service.loadFromDisk()

        let recovered = tallyStore.load()
        #expect(recovered.trimmedPlayCount == 3)
        #expect(recovered.lastFoldedSequence == 3)
        #expect(recovered.trackCounts["t0|wolf"]?.count == 1)
        #expect(recovered.trackCounts["t1|wolf"]?.count == 1)
        #expect(recovered.trackCounts["t2|wolf"]?.count == 1)
        #expect(service.snapshot.totalPlays == cap + 3)
        #expect(store.loadAll().count == cap)
    }

    @Test("legacy timestamp tally migrates to the assigned sequence boundary")
    func testLegacyTimestampTallyMigratesToSequence() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cap = AppConstants.History.maxRetainedRecords
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let seeded = (0..<(cap + 1)).map { index in
            PlayRecord(
                timestamp: base.addingTimeInterval(Double(index)),
                track: "T\(index)", artist: "Wolf", album: "",
                duration: 200, playedSeconds: 200)
        }
        let store = PlayLogStore(directory: dir)
        #expect(store.replaceAll(with: seeded))
        var legacyTally = LifetimeTally.empty
        legacyTally.fold(seeded[0])
        #expect(legacyTally.lastFoldedSequence == nil)
        let tallyStore = LifetimeTallyStore(directory: dir)
        #expect(tallyStore.save(legacyTally))

        let service = makeService(enabled: true, directory: dir)
        await service.loadFromDisk()

        let migrated = tallyStore.load()
        #expect(migrated.trimmedPlayCount == 1)
        #expect(migrated.lastFoldedSequence == 1)
        let compacted = store.loadAll()
        #expect(compacted.count == cap)
        #expect(compacted.allSatisfy { $0.sequence != nil })
        #expect(compacted.first?.sequence == 2)
    }

    @Test("failed tally save leaves overflow NDJSON intact")
    func testTallySaveFailureDoesNotRewriteLog() async throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logDir = root.appending(path: "log")
        let blockedTallyDirectory = root.appending(path: "blocked-tally")
        try FileManager.default.createDirectory(
            at: logDir, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: blockedTallyDirectory)

        let cap = AppConstants.History.maxRetainedRecords
        let seeded = (0..<(cap + 1)).map { index in
            PlayRecord(
                timestamp: Date(timeIntervalSince1970: Double(1_700_000_000 + index)),
                track: "T\(index)", artist: "Wolf", album: "",
                duration: 200, playedSeconds: 200,
                sequence: UInt64(index + 1))
        }
        let store = PlayLogStore(directory: logDir)
        #expect(store.replaceAll(with: seeded))
        let service = ListeningHistoryService(
            store: store,
            tallyStore: LifetimeTallyStore(directory: blockedTallyDirectory),
            enabled: true)

        await service.loadFromDisk()

        #expect(service.records.count == cap)
        #expect(store.loadAll().count == cap + 1)
    }

    @Test("failed log rewrite keeps source NDJSON after tally becomes durable")
    func testRewriteFailureLeavesRecoverableLog() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cap = AppConstants.History.maxRetainedRecords
        let seeded = (0..<(cap + 1)).map { index in
            PlayRecord(
                timestamp: Date(timeIntervalSince1970: Double(1_700_000_000 + index)),
                track: "T\(index)", artist: "Wolf", album: "",
                duration: 200, playedSeconds: 200,
                sequence: UInt64(index + 1))
        }
        let seeder = PlayLogStore(directory: dir)
        #expect(seeder.replaceAll(with: seeded))
        let failingStore = PlayLogStore(
            directory: dir,
            replaceAllOverride: { _ in false })
        let tallyStore = LifetimeTallyStore(directory: dir)
        let service = ListeningHistoryService(
            store: failingStore, tallyStore: tallyStore, enabled: true)

        await service.loadFromDisk()

        #expect(tallyStore.load().trimmedPlayCount == 1)
        #expect(tallyStore.load().lastFoldedSequence == 1)
        #expect(seeder.loadAll().count == cap + 1)

        let recovered = makeService(enabled: true, directory: dir)
        await recovered.loadFromDisk()
        #expect(recovered.snapshot.totalPlays == cap + 1)
        #expect(PlayLogStore(directory: dir).loadAll().count == cap)
    }

    @Test("legacy log recovery does not refold after a failed rewrite")
    func testLegacyRewriteFailureDoesNotDoubleFold() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cap = AppConstants.History.maxRetainedRecords
        let overflow = 3
        let seeded = (0..<(cap + overflow)).map { index in
            PlayRecord(
                timestamp: Date(timeIntervalSince1970: Double(1_700_000_000 + index)),
                track: "T\(index)", artist: "Wolf", album: "",
                duration: 200, playedSeconds: 200)
        }
        let durableStore = PlayLogStore(directory: dir)
        #expect(durableStore.replaceAll(with: seeded))
        #expect(durableStore.loadAll().allSatisfy { $0.sequence == nil })
        let tallyStore = LifetimeTallyStore(directory: dir)
        let firstLoad = ListeningHistoryService(
            store: PlayLogStore(
                directory: dir,
                replaceAllOverride: { _ in false }),
            tallyStore: tallyStore,
            enabled: true)

        await firstLoad.loadFromDisk()

        #expect(tallyStore.load().trimmedPlayCount == overflow)
        #expect(tallyStore.load().lastFoldedSequence == UInt64(overflow))
        #expect(durableStore.loadAll().allSatisfy { $0.sequence == nil })

        let recovered = makeService(enabled: true, directory: dir)
        await recovered.loadFromDisk()

        #expect(recovered.snapshot.totalPlays == cap + overflow)
        let recoveredTally = tallyStore.load()
        #expect(recoveredTally.trimmedPlayCount == overflow)
        #expect(recoveredTally.lastFoldedSequence == UInt64(overflow))
        #expect(recoveredTally.trackCounts["t0|wolf"]?.count == 1)
        #expect(recoveredTally.trackCounts["t1|wolf"]?.count == 1)
        #expect(recoveredTally.trackCounts["t2|wolf"]?.count == 1)
        let compacted = durableStore.loadAll()
        #expect(compacted.count == cap)
        #expect(compacted.first?.sequence == UInt64(overflow + 1))
        #expect(compacted.last?.sequence == UInt64(cap + overflow))
    }

    @Test("duplicate and non-monotonic sequences repair deterministically")
    func testMalformedSequencesRepairDeterministically() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let sourceSequences: [UInt64?] = [5, nil, 5, 4, 9]
        let seeded = sourceSequences.enumerated().map { index, sequence in
            PlayRecord(
                timestamp: timestamp.addingTimeInterval(Double(index)),
                track: "T\(index)", artist: "Wolf", album: "",
                duration: 200, playedSeconds: 200, sequence: sequence)
        }
        let durableStore = PlayLogStore(directory: dir)
        #expect(durableStore.replaceAll(with: seeded))
        let firstLoad = ListeningHistoryService(
            store: PlayLogStore(
                directory: dir,
                replaceAllOverride: { _ in false }),
            tallyStore: LifetimeTallyStore(directory: dir),
            enabled: true)

        await firstLoad.loadFromDisk()
        #expect(durableStore.loadAll().map(\.sequence) == sourceSequences)

        let recovered = makeService(enabled: true, directory: dir)
        await recovered.loadFromDisk()

        let expected: [UInt64?] = [5, 6, 7, 8, 9]
        #expect(recovered.records.map(\.sequence) == expected)
        #expect(durableStore.loadAll().map(\.sequence) == expected)
    }

    @Test("shutdown during scheduled load flushes deferred plays above disk watermark")
    func testShutdownDuringLoadFlushesDeferredRecords() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlayLogStore(directory: dir)
        #expect(store.replaceAll(with: [
            PlayRecord(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                track: "Existing", artist: "Wolf", album: "",
                duration: 200, playedSeconds: 200, sequence: 50)
        ]))
        let barrier = HistoryLoadBarrier()
        defer { barrier.release() }
        let service = makeService(
            enabled: true,
            directory: dir,
            loadReadBarrier: { barrier.blockAfterRead() })

        service.start()
        service.recordTrackChange(
            track: "During Load", artist: "Wolf", album: "",
            duration: 200, playedSeconds: 200)
        #expect(service.records.isEmpty)
        let reachedBarrier = await barrier.waitUntilBlocked()
        #expect(reachedBarrier)
        guard reachedBarrier else { return }

        service.shutdown()
        let beforeLoaderReturns = store.loadAll()
        #expect(beforeLoaderReturns.map(\.track) == ["Existing", "During Load"])
        #expect(beforeLoaderReturns.map(\.sequence) == [50, 51])

        barrier.release()
        let staleLoadDrained = await waitUntil(timeout: .seconds(1)) {
            service.isLoaded
        }
        #expect(staleLoadDrained)
        #expect(store.loadAll().map(\.track) == ["Existing", "During Load"])
    }

    @Test("overflow append defers tally persistence and shutdown reload keeps the evicted play")
    func testOverflowAppendDefersTallyPersistenceUntilShutdown() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cap = AppConstants.History.maxRetainedRecords

        // Seed the disk log with `cap` records via replaceAll (fast), then
        // load. Service is at the cap with no trimming required.
        let store = PlayLogStore(directory: dir)
        let base = Date().addingTimeInterval(-Double(cap) * 60)
        var seeded: [PlayRecord] = []
        seeded.reserveCapacity(cap)
        for i in 0..<cap {
            seeded.append(PlayRecord(
                timestamp: base.addingTimeInterval(Double(i) * 60),
                track: "T\(i)", artist: "Wolf", album: "Al",
                duration: 200, playedSeconds: 200
            ))
        }
        store.replaceAll(with: seeded)

        let service = makeService(enabled: true, directory: dir)
        await service.loadFromDisk()
        #expect(service.records.count == cap)

        // One more push should evict the oldest into the tally.
        service.recordTrackChange(
            track: "Overflow", artist: "Wolf", album: "",
            duration: 200, playedSeconds: 200
        )
        #expect(service.records.count == cap)
        #expect(service.records.last?.track == "Overflow")
        #expect(service.records.first?.track == "T1")
        #expect(service.snapshot.totalPlays == cap + 1)

        // The append hot path must not rewrite the full sidecar. Until a clean
        // shutdown, the evicted play remains recoverable from append-only NDJSON.
        let tallyStore = LifetimeTallyStore(directory: dir)
        #expect(tallyStore.load().isEmpty)

        service.shutdown()
        #expect(tallyStore.load().trimmedPlayCount == 1)
        #expect(tallyStore.load().trackCounts["t0|wolf"]?.count == 1)

        // A fresh process sees both the compacted live window and the tally.
        let reloaded = makeService(enabled: true, directory: dir)
        await reloaded.loadFromDisk()
        #expect(reloaded.records.count == cap)
        #expect(reloaded.snapshot.totalPlays == cap + 1)
        #expect(tallyStore.load().trackCounts["t0|wolf"]?.count == 1)
    }

    @Test("shutdown synchronously persists compaction + tally when window overflowed")
    func testShutdownPersistsCompaction() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cap = AppConstants.History.maxRetainedRecords
        let store = PlayLogStore(directory: dir)
        let base = Date().addingTimeInterval(-Double(cap) * 60)
        var seeded: [PlayRecord] = []
        seeded.reserveCapacity(cap)
        for i in 0..<cap {
            seeded.append(PlayRecord(
                timestamp: base.addingTimeInterval(Double(i) * 60),
                track: "T\(i)", artist: "Wolf", album: "Al",
                duration: 200, playedSeconds: 200
            ))
        }
        store.replaceAll(with: seeded)

        let service = makeService(enabled: true, directory: dir)
        await service.loadFromDisk()
        // Drive the service one record past the cap: fold + arm compaction.
        service.recordTrackChange(
            track: "Overflow", artist: "Wolf", album: "",
            duration: 200, playedSeconds: 200
        )

        // shutdown() must compact the NDJSON and persist the tally synchronously.
        service.shutdown()

        let onDisk = PlayLogStore(directory: dir).loadAll()
        #expect(onDisk.count == cap)
        #expect(onDisk.last?.track == "Overflow")
        #expect(onDisk.first?.track == "T1")

        let tally = LifetimeTallyStore(directory: dir).load()
        #expect(tally.trimmedPlayCount == 1)
        #expect(tally.trackCounts["t0|wolf"]?.count == 1)
    }
}
