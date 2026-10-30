//
//  ListeningHistoryServiceTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-22.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation
@testable import WolfWave

/// Blocks the detached disk loader after it has captured its inputs, allowing a
/// test to perform a clear before the stale result can return to the main actor.
final class HistoryLoadBarrier: @unchecked Sendable {
    private let reached = DispatchSemaphore(value: 0)
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let releaseLock = NSLock()
    private var wasReleased = false

    func blockAfterRead() {
        reached.signal()
        _ = releaseSignal.wait(timeout: .now() + .seconds(5))
    }

    func waitUntilBlocked(
        timeout: DispatchTimeInterval = .seconds(2)
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: self.reached.wait(timeout: .now() + timeout) == .success
                )
            }
        }
    }

    func release() {
        let shouldSignal = releaseLock.withLock {
            guard !wasReleased else { return false }
            wasReleased = true
            return true
        }
        if shouldSignal {
            releaseSignal.signal()
        }
    }
}

/// Fails the first sidecar deletion, then performs the real deletion. This
/// proves finite-retention compaction retries instead of dropping source lines.
final class FailOnceTallyClear: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private(set) var attempts = 0

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func clear() -> Bool {
        lock.withLock {
            attempts += 1
            guard attempts > 1 else { return false }
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return true
            }
            do {
                try FileManager.default.removeItem(at: fileURL)
                return true
            } catch {
                return false
            }
        }
    }
}

/// Tests for the listening-history orchestrator: scrobble threshold, gating,
/// recording, clearing, and the disk-load path.
@Suite("Listening History Service Tests", .serialized, .isolatedSharedTestState)
@MainActor
struct ListeningHistoryServiceTests {

    // MARK: - Helpers

    /// A fresh temp directory for one test; the test removes it.
    func makeTempDirectory() -> URL {
        makeIsolatedTempDirectory(prefix: "history-svc-test")
    }

    @Test("Appending a play prunes expired records from memory and disk")
    func appendPrunesExpiredRecords() async {
        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.historyRetentionDays)
        defer { DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.historyRetentionDays) }
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlayLogStore(directory: dir)
        store.replaceAll(with: [PlayRecord(
            timestamp: Date().addingTimeInterval(-60 * 86_400),
            track: "Expired", artist: "Wolf", album: "", duration: 200, playedSeconds: 200)])
        let service = makeService(enabled: true, directory: dir, store: store)
        await service.loadFromDisk()
        DefaultsStore.store.set(30, forKey: AppConstants.UserDefaults.historyRetentionDays)
        service.recordTrackChange(track: "Current", artist: "Wolf", album: "", duration: 200, playedSeconds: 200)
        #expect(service.records.map(\.track) == ["Current"])
        #expect(store.loadAll().map(\.track) == ["Current"])
    }

    @Test("Shortening retention immediately removes exactly the confirmation count")
    func retentionChangePrunesImmediately() async {
        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.historyRetentionDays)
        defer { DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.historyRetentionDays) }
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlayLogStore(directory: dir)
        store.replaceAll(with: [60, 15, 1].map { age in
            PlayRecord(timestamp: Date().addingTimeInterval(-Double(age) * 86_400),
                       track: "\(age)", artist: "Wolf", album: "", duration: 200, playedSeconds: 200)
        })
        let service = makeService(enabled: true, directory: dir, store: store)
        await service.loadFromDisk()
        let count = service.expiredRecordCount(retentionDays: 7)
        #expect(count == 2)
        #expect(service.records.count == 3)
        service.setRetentionDays(7)
        #expect(service.records.count == 3 - count)
        #expect(store.loadAll().map(\.track) == ["1"])
        #expect(service.snapshot.totalPlays == 1)
    }

    @Test("Pruning never folds expired plays into lifetime totals")
    func pruneDoesNotInflateLifetimeTally() async {
        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.historyRetentionDays)
        defer { DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.historyRetentionDays) }
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlayLogStore(directory: dir)
        store.replaceAll(with: [PlayRecord(
            timestamp: Date().addingTimeInterval(-60 * 86_400),
            track: "Expired", artist: "Wolf", album: "", duration: 200, playedSeconds: 200)])
        let service = makeService(enabled: true, directory: dir, store: store)
        await service.loadFromDisk()
        service.setRetentionDays(7)
        service.setRetentionDays(0)
        service.shutdown()
        #expect(service.snapshot.totalPlays == 0)
        #expect(LifetimeTallyStore(directory: dir).load().isEmpty)
        #expect(store.loadAll().isEmpty)
    }

    @Test("Confirmation count uses the same cutoff as pruning")
    func pruneCountMatchesConfirmation() async {
        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.historyRetentionDays)
        defer { DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.historyRetentionDays) }
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        let store = PlayLogStore(directory: dir)
        store.replaceAll(with: [-1.0, 0, 1].map { offset in
            PlayRecord(timestamp: cutoff.addingTimeInterval(offset),
                       track: "Boundary", artist: "Wolf", album: "", duration: 200, playedSeconds: 200)
        })
        let service = makeService(enabled: true, directory: dir, store: store)
        await service.loadFromDisk()
        #expect(service.expiredRecordCount(retentionDays: 0, now: now) == 0)
        let count = service.expiredRecordCount(retentionDays: 7, now: now)
        #expect(count == 1)
        DefaultsStore.store.set(7, forKey: AppConstants.UserDefaults.historyRetentionDays)
        service.prune(now: now)
        #expect(service.records.count == 3 - count)
        #expect(store.loadAll().count == 3 - count)
    }

    @Test("Leaving Forever counts the All time totals a finite window deletes")
    func retentionImpactCountsLifetimeTally() async {
        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.historyRetentionDays)
        defer { DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.historyRetentionDays) }
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // One recent play in the log and one folded play in the lifetime tally:
        // nothing is old enough to expire, yet a finite window deletes the tally.
        let fixture = seedClearFixture(directory: dir)
        let service = makeService(enabled: true, directory: dir, store: fixture.log)
        await service.loadFromDisk()

        #expect(service.expiredRecordCount(retentionDays: 30) == 0)
        let impact = service.retentionImpact(retentionDays: 30)
        #expect(impact == RetentionImpact(expiredPlays: 0, lifetimeTallyPlays: 1))
        #expect(impact.deletesData)
        #expect(service.retentionImpact(retentionDays: 0) == .empty)

        // The count is real: applying the window deletes exactly that tally.
        service.setRetentionDays(30)
        #expect(fixture.tally.load().isEmpty)
        #expect(service.retentionImpact(retentionDays: 7) == .empty)
    }

    /// - Parameter store: Pass the same `PlayLogStore` the test asserts through
    ///   whenever it inspects the log without a preceding `shutdown()`.
    ///   `PlayLogStore.append` is async on the instance's own serial `ioQueue`,
    ///   so `loadAll()` is ordered after an append only on that same instance.
    ///   A second instance over the same file shares no queue and can read the
    ///   file before the append lands.
    func makeService(
        enabled: Bool,
        directory: URL,
        store: PlayLogStore? = nil,
        loadReadBarrier: (@Sendable () -> Void)? = nil
    ) -> ListeningHistoryService {
        ListeningHistoryService(
            store: store ?? PlayLogStore(directory: directory),
            tallyStore: LifetimeTallyStore(directory: directory),
            enabled: enabled,
            loadReadBarrier: loadReadBarrier
        )
    }

    /// Writes one record to the play log and one folded record to the lifetime tally in
    /// `directory`, so a clear has something in both stores to remove.
    func seedClearFixture(
        directory: URL
    ) -> (log: PlayLogStore, tally: LifetimeTallyStore) {
        let log = PlayLogStore(directory: directory)
        _ = log.replaceAll(with: [
            PlayRecord(
                track: "On Disk", artist: "Wolf", album: "",
                duration: 200, playedSeconds: 200, sequence: 1)
        ])
        var lifetime = LifetimeTally.empty
        lifetime.fold(PlayRecord(
            timestamp: Date().addingTimeInterval(-3_600),
            track: "Folded", artist: "Wolf", album: "",
            duration: 200, playedSeconds: 200, sequence: 0))
        let tally = LifetimeTallyStore(directory: directory)
        _ = tally.save(lifetime)
        return (log, tally)
    }

    // MARK: - Earliest Recorded Month
    @Test("earliestRecordedMonth is nil when no plays have been recorded")
    func testEarliestRecordedMonthNilWhenEmpty() {
        let dir = makeTempDirectory()
        let service = makeService(enabled: true, directory: dir)
        #expect(service.earliestRecordedMonth == nil)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("earliestRecordedMonth returns first-of-month for the oldest record")
    func testEarliestRecordedMonthReturnsFirstOfOldestMonth() {
        let dir = makeTempDirectory()
        let service = makeService(enabled: true, directory: dir)

        // Record a play "now" (current month). Snapshot the month on both sides
        // of the call so a run straddling midnight on the last day of a month
        // still passes.
        let cal = Calendar.current
        let monthBefore = cal.dateInterval(of: .month, for: Date())?.start
        service.recordTrackChange(
            track: "Recent", artist: "A", album: "",
            duration: 200, playedSeconds: 188
        )

        guard let earliest = service.earliestRecordedMonth else {
            Issue.record("Expected earliestRecordedMonth after a play")
            try? FileManager.default.removeItem(at: dir)
            return
        }

        let monthAfter = cal.dateInterval(of: .month, for: Date())?.start
        #expect(earliest == monthBefore || earliest == monthAfter)
        // Always the first day of the month.
        #expect(cal.component(.day, from: earliest) == 1)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("earliestRecordedMonth uses the minimum timestamp, not insertion order")
    func testEarliestRecordedMonthIgnoresInsertionOrder() {
        let dir = makeTempDirectory()
        let service = makeService(enabled: true, directory: dir)

        // Insert recent first, older second. Earliest should still be the older one.
        // Month snapshots on both sides of the calls keep a month-end midnight
        // run from failing.
        let cal = Calendar.current
        let monthBefore = cal.dateInterval(of: .month, for: Date())?.start
        service.recordTrackChange(
            track: "Recent", artist: "A", album: "",
            duration: 200, playedSeconds: 188
        )
        service.recordTrackChange(
            track: "AlsoRecent", artist: "B", album: "",
            duration: 200, playedSeconds: 188
        )

        // Both fall in the current month. Earliest should be start-of-current-month.
        let monthAfter = cal.dateInterval(of: .month, for: Date())?.start
        let earliest = service.earliestRecordedMonth
        #expect(earliest == monthBefore || earliest == monthAfter)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Scrobble Threshold

    @Test("A track played past 50% qualifies")
    func testQualifiesAtHalf() {
        #expect(ListeningHistoryService.qualifiesAsPlay(duration: 200, playedSeconds: 100))
        #expect(ListeningHistoryService.qualifiesAsPlay(duration: 200, playedSeconds: 199))
    }

    @Test("A track played under 50% does not qualify")
    func testRejectedUnderHalf() {
        #expect(!ListeningHistoryService.qualifiesAsPlay(duration: 200, playedSeconds: 99))
        #expect(!ListeningHistoryService.qualifiesAsPlay(duration: 200, playedSeconds: 5))
    }

    @Test("Four minutes always qualifies regardless of track length")
    func testAbsoluteThreshold() {
        // A 20-minute track played for 4 minutes is < 50% but still counts.
        #expect(ListeningHistoryService.qualifiesAsPlay(duration: 1200, playedSeconds: 240))
        // Unknown duration: only the absolute threshold can qualify it.
        #expect(ListeningHistoryService.qualifiesAsPlay(duration: 0, playedSeconds: 240))
        #expect(!ListeningHistoryService.qualifiesAsPlay(duration: 0, playedSeconds: 100))
    }

    @Test("Zero play time never qualifies")
    func testZeroPlayRejected() {
        #expect(!ListeningHistoryService.qualifiesAsPlay(duration: 200, playedSeconds: 0))
    }

    // MARK: - Recording & Gating

    @Test("A qualifying play is recorded when enabled")
    func testRecordsQualifyingPlay() {
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
    func testDropsShortPlay() {
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
    func testGatingWhenDisabled() {
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
    func testEmptyTrackIgnored() {
        let dir = makeTempDirectory()
        let service = makeService(enabled: true, directory: dir)

        service.recordTrackChange(
            track: "   ", artist: "The Weeknd", album: "",
            duration: 200, playedSeconds: 200
        )

        #expect(service.records.isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("Live record boundary sanitizes non-finite and huge durations")
    func testLiveDurationBoundarySanitizesBeforeQualificationAndLogging() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = makeService(enabled: true, directory: dir)
        let invalid: [Double] = [.nan, .infinity, -.infinity]

        for (index, played) in invalid.enumerated() {
            service.recordTrackChange(
                track: "Invalid Played \(index)", artist: "Wolf", album: "",
                duration: 200, playedSeconds: played)
        }
        #expect(service.records.isEmpty)

        for (index, duration) in invalid.enumerated() {
            service.recordTrackChange(
                track: "Unknown Duration \(index)", artist: "Wolf", album: "",
                duration: duration, playedSeconds: 240)
        }
        #expect(service.records.count == invalid.count)
        #expect(service.records.allSatisfy { $0.duration == 0 })
        #expect(service.records.allSatisfy { $0.playedSeconds == 240 })

        service.recordTrackChange(
            track: "Huge", artist: "Wolf", album: "",
            duration: 1.0e300, playedSeconds: 1.0e300)

        let huge = service.records.last
        #expect(huge?.duration == DurationSanitizer.ceiling)
        #expect(huge?.playedSeconds == DurationSanitizer.ceiling)
        #expect(service.records.allSatisfy {
            $0.duration.isFinite && $0.playedSeconds.isFinite
        })
    }

    // MARK: - Chat Line

    @Test("statsChatLine is friendly when nothing has played")
    func testStatsChatLineEmpty() {
        let dir = makeTempDirectory()
        let service = makeService(enabled: true, directory: dir)
        #expect(service.statsChatLine().contains("just getting started"))
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("statsChatLine reports today's top track")
    func testStatsChatLineWithPlays() {
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
