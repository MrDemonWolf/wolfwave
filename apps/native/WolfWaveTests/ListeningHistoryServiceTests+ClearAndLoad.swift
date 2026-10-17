//
//  ListeningHistoryServiceTests+ClearAndLoad.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation

@testable import WolfWave

/// Clearing history (including partial-clear recovery) and loading it back from disk.
extension ListeningHistoryServiceTests {
    // MARK: - Clear

    @Test("clearHistory empties records and snapshot")
    func testClearHistory() {
        let dir = makeTempDirectory()
        let service = makeService(enabled: true, directory: dir)
        service.recordTrackChange(
            track: "Doomed", artist: "Bring Me the Horizon", album: "amo",
            duration: 230, playedSeconds: 230
        )
        #expect(service.records.count == 1)

        service.clearHistory()
        #expect(service.records.isEmpty)
        #expect(service.snapshot.totalPlays == 0)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("Clear marker creation failure leaves disk and UI untouched")
    func testClearMarkerCreationFailureMutatesNothing() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = seedClearFixture(directory: dir)
        let marker = HistoryClearMarkerStore(
            directory: dir,
            beginOverride: { false })
        let service = ListeningHistoryService(
            store: fixture.log,
            tallyStore: fixture.tally,
            clearMarkerStore: marker,
            enabled: true)
        await service.loadFromDisk()
        let recordsBefore = service.records

        let cleared = service.clearHistory()

        #expect(!cleared)
        #expect(service.records == recordsBefore)
        #expect(fixture.log.loadAll().map(\.track) == ["On Disk"])
        #expect(!fixture.tally.load().isEmpty)
        #expect(!marker.isPending)
    }

    @Test("Failed log clear leaves a marker that relaunch recovery completes")
    func testLogClearFailureRecoversOnRelaunch() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = seedClearFixture(directory: dir)
        let failingLog = PlayLogStore(
            directory: dir,
            replaceAllOverride: { records in !records.isEmpty })
        let marker = HistoryClearMarkerStore(directory: dir)
        let service = ListeningHistoryService(
            store: failingLog,
            tallyStore: fixture.tally,
            clearMarkerStore: marker,
            enabled: true)
        await service.loadFromDisk()

        let cleared = service.clearHistory()

        #expect(!cleared)
        #expect(service.records.isEmpty)
        #expect(fixture.log.loadAll().map(\.track) == ["On Disk"])
        #expect(fixture.tally.load().isEmpty)
        #expect(marker.isPending)

        let recovered = makeService(enabled: true, directory: dir)
        await recovered.loadFromDisk()

        #expect(recovered.records.isEmpty)
        #expect(fixture.log.loadAll().isEmpty)
        #expect(fixture.tally.load().isEmpty)
        #expect(!HistoryClearMarkerStore(directory: dir).isPending)
    }

    @Test("Failed tally clear leaves a marker that relaunch recovery completes")
    func testTallyClearFailureRecoversOnRelaunch() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = seedClearFixture(directory: dir)
        let marker = HistoryClearMarkerStore(directory: dir)
        let service = ListeningHistoryService(
            store: fixture.log,
            tallyStore: LifetimeTallyStore(
                directory: dir,
                clearOverride: { false }),
            clearMarkerStore: marker,
            enabled: true)
        await service.loadFromDisk()

        let cleared = service.clearHistory()

        #expect(!cleared)
        #expect(service.records.isEmpty)
        #expect(fixture.log.loadAll().isEmpty)
        #expect(!fixture.tally.load().isEmpty)
        #expect(marker.isPending)

        let recovered = makeService(enabled: true, directory: dir)
        await recovered.loadFromDisk()

        #expect(recovered.records.isEmpty)
        #expect(fixture.log.loadAll().isEmpty)
        #expect(fixture.tally.load().isEmpty)
        #expect(!HistoryClearMarkerStore(directory: dir).isPending)
    }

    @Test("A play is rejected while a partial clear remains pending")
    func testRecordAfterPartialClearIsNotAppendedBehindMarker() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = seedClearFixture(directory: dir)
        let failingLog = PlayLogStore(
            directory: dir,
            replaceAllOverride: { records in !records.isEmpty })
        let marker = HistoryClearMarkerStore(directory: dir)
        let service = ListeningHistoryService(
            store: failingLog,
            tallyStore: fixture.tally,
            clearMarkerStore: marker,
            enabled: true)
        await service.loadFromDisk()
        #expect(!service.clearHistory())

        service.recordTrackChange(
            track: "After Clear", artist: "Wolf", album: "",
            duration: 200, playedSeconds: 200)

        #expect(service.records.isEmpty)
        #expect(fixture.log.loadAll().map(\.track) == ["On Disk"])
        #expect(marker.isPending)
    }

    @Test("Marker removal failure blocks appends and relaunch retries deletion")
    func testMarkerRemovalFailureRecoversOnRelaunch() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = seedClearFixture(directory: dir)
        let marker = HistoryClearMarkerStore(
            directory: dir,
            completeOverride: { false })
        let service = ListeningHistoryService(
            store: fixture.log,
            tallyStore: fixture.tally,
            clearMarkerStore: marker,
            enabled: true)
        await service.loadFromDisk()

        #expect(!service.clearHistory())
        #expect(fixture.log.loadAll().isEmpty)
        #expect(fixture.tally.load().isEmpty)
        #expect(marker.isPending)

        service.recordTrackChange(
            track: "After Marker Failure", artist: "Wolf", album: "",
            duration: 200, playedSeconds: 200)
        #expect(service.records.isEmpty)
        #expect(fixture.log.loadAll().isEmpty)

        let recovered = makeService(enabled: true, directory: dir)
        await recovered.loadFromDisk()

        #expect(recovered.records.isEmpty)
        #expect(!HistoryClearMarkerStore(directory: dir).isPending)
    }

    // MARK: - Disk Load

    @Test("loadFromDisk restores previously recorded plays")
    func testLoadFromDisk() async {
        let dir = makeTempDirectory()

        // First session: record two plays.
        let first = makeService(enabled: true, directory: dir)
        first.recordTrackChange(track: "One", artist: "A", album: "", duration: 200, playedSeconds: 200)
        first.recordTrackChange(track: "Two", artist: "B", album: "", duration: 200, playedSeconds: 200)
        first.shutdown()

        // Second session: a fresh service should load both from disk.
        let second = makeService(enabled: true, directory: dir)
        await second.loadFromDisk()

        #expect(second.records.count == 2)
        #expect(second.isLoaded)
        #expect(second.snapshot.totalPlays == 2)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("clear during load discards stale disk data and pre-clear buffer")
    func testClearDuringLoadWinsAndFlushesOnlyPostClearRecords() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PlayLogStore(directory: dir)
        store.replaceAll(with: [
            PlayRecord(
                timestamp: Date().addingTimeInterval(-60),
                track: "On Disk", artist: "Old", album: "",
                duration: 200, playedSeconds: 200)
        ])

        let barrier = HistoryLoadBarrier()
        defer { barrier.release() }
        // Share the store instance: the post-clear play is flushed by an async
        // append and this test asserts the log without a shutdown() flush, so
        // the read must be enqueued behind that append on the same serial queue.
        let service = makeService(
            enabled: true,
            directory: dir,
            store: store,
            loadReadBarrier: { barrier.blockAfterRead() }
        )
        let load = Task { await service.loadFromDisk() }
        let reachedBarrier = await barrier.waitUntilBlocked()
        #expect(reachedBarrier)
        guard reachedBarrier else {
            load.cancel()
            return
        }

        service.recordTrackChange(
            track: "Buffered Before Clear", artist: "Old", album: "",
            duration: 200, playedSeconds: 200)
        service.clearHistory()
        service.recordTrackChange(
            track: "Buffered After Clear", artist: "New", album: "",
            duration: 200, playedSeconds: 200)

        barrier.release()
        await load.value

        #expect(service.records.map(\.track) == ["Buffered After Clear"])
        #expect(service.snapshot.totalPlays == 1)
        #expect(LifetimeTallyStore(directory: dir).load().isEmpty)
        #expect(store.loadAll().map(\.track) == ["Buffered After Clear"])
    }

    @Test("finite retention uses retained records only and clears undated lifetime tally")
    func testFiniteRetentionExcludesLifetimeTally() async {
        let dir = makeTempDirectory()
        defer {
            DefaultsStore.store.removeObject(
                forKey: AppConstants.UserDefaults.historyRetentionDays)
            try? FileManager.default.removeItem(at: dir)
        }
        DefaultsStore.store.set(
            30, forKey: AppConstants.UserDefaults.historyRetentionDays)

        let old = PlayRecord(
            timestamp: Date().addingTimeInterval(-60 * 86_400),
            track: "Expired", artist: "Old Artist", album: "",
            duration: 200, playedSeconds: 200)
        let recent = PlayRecord(
            timestamp: Date().addingTimeInterval(-60),
            track: "Retained", artist: "New Artist", album: "",
            duration: 200, playedSeconds: 200)
        let store = PlayLogStore(directory: dir)
        store.replaceAll(with: [old, recent])

        var staleLifetime = LifetimeTally.empty
        staleLifetime.fold(PlayRecord(
            timestamp: Date().addingTimeInterval(-90 * 86_400),
            track: "Previously Trimmed", artist: "Old Artist", album: "",
            duration: 200, playedSeconds: 200))
        let tallyStore = LifetimeTallyStore(directory: dir)
        tallyStore.save(staleLifetime)

        let service = makeService(enabled: true, directory: dir)
        await service.loadFromDisk()

        #expect(service.records.map(\.track) == ["Retained"])
        #expect(service.snapshot.totalPlays == 1)
        #expect(service.snapshot.topTracks.first?.name == "Retained")
        #expect(tallyStore.load().isEmpty)
        #expect(store.loadAll().map(\.track) == ["Retained"])
    }

    @Test("finite retention retries tally deletion before rewriting source log")
    func testFiniteRetentionClearFailureDefersRewriteUntilShutdownRetry() async {
        let dir = makeTempDirectory()
        defer {
            DefaultsStore.store.removeObject(
                forKey: AppConstants.UserDefaults.historyRetentionDays)
            try? FileManager.default.removeItem(at: dir)
        }
        DefaultsStore.store.set(
            30, forKey: AppConstants.UserDefaults.historyRetentionDays)
        let old = PlayRecord(
            timestamp: Date().addingTimeInterval(-60 * 86_400),
            track: "Expired", artist: "Old", album: "",
            duration: 200, playedSeconds: 200, sequence: 1)
        let recent = PlayRecord(
            timestamp: Date().addingTimeInterval(-60),
            track: "Retained", artist: "New", album: "",
            duration: 200, playedSeconds: 200, sequence: 2)
        let store = PlayLogStore(directory: dir)
        #expect(store.replaceAll(with: [old, recent]))
        var stale = LifetimeTally.empty
        stale.fold(old)
        let durableTallyStore = LifetimeTallyStore(directory: dir)
        #expect(durableTallyStore.save(stale))
        let failOnce = FailOnceTallyClear(fileURL: durableTallyStore.fileURL)
        let service = ListeningHistoryService(
            store: store,
            tallyStore: LifetimeTallyStore(
                directory: dir,
                clearOverride: { failOnce.clear() }),
            enabled: true)

        await service.loadFromDisk()

        #expect(service.records.map(\.track) == ["Retained"])
        #expect(store.loadAll().map(\.track) == ["Expired", "Retained"])
        #expect(!durableTallyStore.load().isEmpty)

        service.shutdown()

        #expect(failOnce.attempts == 2)
        #expect(durableTallyStore.load().isEmpty)
        #expect(store.loadAll().map(\.track) == ["Retained"])
    }
}
