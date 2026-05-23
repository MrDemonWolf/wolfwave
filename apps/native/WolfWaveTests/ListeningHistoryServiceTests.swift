//
//  ListeningHistoryServiceTests.swift
//  wolfwave
//
//  Created by MrDemonWolf, Inc. on 5/22/26.
//

import Testing
import Foundation
@testable import WolfWave

/// Tests for the listening-history orchestrator: scrobble threshold, gating,
/// recording, clearing, and the disk-load path.
@Suite("Listening History Service Tests")
@MainActor
struct ListeningHistoryServiceTests {

    // MARK: - Helpers

    @MainActor private func makeTempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-svc-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor private func makeService(enabled: Bool, directory: URL) -> ListeningHistoryService {
        ListeningHistoryService(store: PlayLogStore(directory: directory), enabled: enabled)
    }

    // MARK: - Scrobble Threshold

    @Test("A track played past 50% qualifies")
    @MainActor func testQualifiesAtHalf() {
        #expect(ListeningHistoryService.qualifiesAsPlay(duration: 200, playedSeconds: 100))
        #expect(ListeningHistoryService.qualifiesAsPlay(duration: 200, playedSeconds: 199))
    }

    @Test("A track played under 50% does not qualify")
    @MainActor func testRejectedUnderHalf() {
        #expect(!ListeningHistoryService.qualifiesAsPlay(duration: 200, playedSeconds: 99))
        #expect(!ListeningHistoryService.qualifiesAsPlay(duration: 200, playedSeconds: 5))
    }

    @Test("Four minutes always qualifies regardless of track length")
    @MainActor func testAbsoluteThreshold() {
        // A 20-minute track played for 4 minutes is < 50% but still counts.
        #expect(ListeningHistoryService.qualifiesAsPlay(duration: 1200, playedSeconds: 240))
        // Unknown duration: only the absolute threshold can qualify it.
        #expect(ListeningHistoryService.qualifiesAsPlay(duration: 0, playedSeconds: 240))
        #expect(!ListeningHistoryService.qualifiesAsPlay(duration: 0, playedSeconds: 100))
    }

    @Test("Zero play time never qualifies")
    @MainActor func testZeroPlayRejected() {
        #expect(!ListeningHistoryService.qualifiesAsPlay(duration: 200, playedSeconds: 0))
    }

    // MARK: - Recording & Gating

    @Test("A qualifying play is recorded when enabled")
    @MainActor func testRecordsQualifyingPlay() {
        let dir = makeTempDirectory()
        let service = makeService(enabled: true, directory: dir)

        service.recordTrackChange(
            track: "Blinding Lights", artist: "The Weeknd", album: "After Hours",
            duration: 200, playedSeconds: 188
        )

        #expect(service.records.count == 1)
        #expect(service.snapshot.totalPlays == 1)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("A short play is dropped")
    @MainActor func testDropsShortPlay() {
        let dir = makeTempDirectory()
        let service = makeService(enabled: true, directory: dir)

        service.recordTrackChange(
            track: "Skipped", artist: "Someone", album: "",
            duration: 200, playedSeconds: 8
        )

        #expect(service.records.isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("Nothing is recorded while the feature is disabled")
    @MainActor func testGatingWhenDisabled() {
        let dir = makeTempDirectory()
        let service = makeService(enabled: false, directory: dir)

        service.recordTrackChange(
            track: "Ignored", artist: "Nobody", album: "",
            duration: 200, playedSeconds: 200
        )

        #expect(service.records.isEmpty)
        // Nothing should have been written to disk either.
        #expect(PlayLogStore(directory: dir).loadAll().isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("An empty track title is ignored")
    @MainActor func testEmptyTrackIgnored() {
        let dir = makeTempDirectory()
        let service = makeService(enabled: true, directory: dir)

        service.recordTrackChange(
            track: "   ", artist: "The Weeknd", album: "",
            duration: 200, playedSeconds: 200
        )

        #expect(service.records.isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Clear

    @Test("clearHistory empties records and snapshot")
    @MainActor func testClearHistory() {
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

    // MARK: - Disk Load

    @Test("loadFromDisk restores previously recorded plays")
    @MainActor func testLoadFromDisk() async {
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

    // MARK: - Chat Line

    @Test("statsChatLine is friendly when nothing has played")
    @MainActor func testStatsChatLineEmpty() {
        let dir = makeTempDirectory()
        let service = makeService(enabled: true, directory: dir)
        #expect(service.statsChatLine().contains("just getting started"))
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("statsChatLine reports today's top track")
    @MainActor func testStatsChatLineWithPlays() {
        let dir = makeTempDirectory()
        let service = makeService(enabled: true, directory: dir)
        service.recordTrackChange(
            track: "Blinding Lights", artist: "The Weeknd", album: "After Hours",
            duration: 200, playedSeconds: 200
        )
        let line = service.statsChatLine()
        #expect(line.contains("Blinding Lights"))
        #expect(line.contains("The Weeknd"))
        try? FileManager.default.removeItem(at: dir)
    }
}
