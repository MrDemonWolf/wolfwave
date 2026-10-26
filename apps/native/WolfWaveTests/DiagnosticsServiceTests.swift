//
//  DiagnosticsServiceTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-22.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import MetricKit
import XCTest

@testable import WolfWave

// MARK: - DiagnosticsServiceTests

/// Covers `DiagnosticsService` opt-in state and the anonymous launch counter.
/// Each test uses an isolated `UserDefaults` suite; the MetricKit subscription
/// itself is not exercised (it has process-wide side effects), but the
/// `didReceive(_:)` callbacks are invoked directly off-main, the way MetricKit
/// delivers them.
@MainActor
final class DiagnosticsServiceTests: WolfWaveTestCase {

    private var scratch: ThrowawayDefaults!
    private var defaults: UserDefaults!
    private var service: DiagnosticsService!

    override func setUp() async throws {
        try await super.setUp()
        scratch = ThrowawayDefaults("DiagnosticsServiceTests")
        defaults = scratch.defaults
        service = DiagnosticsService(defaults: defaults)
    }

    override func tearDown() async throws {
        service = nil
        scratch.destroy()
        defaults = nil
        scratch = nil
        cleanupTrackedTempDirs()
        try await super.tearDown()
    }

    func testDiagnosticsAreDisabledByDefault() {
        XCTAssertFalse(service.isEnabled, "Diagnostics opt-in must default to off")
    }

    func testIsEnabledReflectsStoredPreference() {
        defaults.set(true, forKey: AppConstants.UserDefaults.shareDiagnosticsEnabled)
        XCTAssertTrue(service.isEnabled)
    }

    func testRecordAppLaunchIncrementsCounter() {
        // Launch counting is gated on the diagnostics opt-in (see #338).
        defaults.set(true, forKey: AppConstants.UserDefaults.shareDiagnosticsEnabled)
        XCTAssertEqual(service.launchCount, 0)

        service.recordAppLaunch()
        service.recordAppLaunch()
        service.recordAppLaunch()

        XCTAssertEqual(service.launchCount, 3)
    }

    func testRecordAppLaunchIsNoOpWhenDisabled() {
        XCTAssertFalse(service.isEnabled)

        service.recordAppLaunch()
        service.recordAppLaunch()

        XCTAssertEqual(service.launchCount, 0, "Launches must not be counted while diagnostics are off")
    }

    func testPayloadDirectoryIsScopedToWolfWave() {
        let path = service.payloadDirectory.path
        XCTAssertTrue(path.contains("WolfWave/Diagnostics"), "Unexpected payload path: \(path)")
    }

    func testDiagnosticSummaryStartsNil() {
        XCTAssertNil(service.diagnosticSummary)
    }

    // MARK: - Off-Main Payload Delivery

    func testDidReceiveIsSafeOffMain() {
        // MetricKit delivers payloads on a background queue. This test invokes
        // both subscriber callbacks off-main exactly the way MetricKit does.
        // DiagnosticsService must stay `nonisolated`: if it regressed to the
        // module's MainActor default, the nonisolated closure below would not
        // compile, and at runtime the @objc thunks would trap on real payload
        // delivery for any opted-in user.
        defaults.set(true, forKey: AppConstants.UserDefaults.shareDiagnosticsEnabled)
        guard let service else {
            XCTFail("Service was not initialized in setUp")
            return
        }

        let delivered = expectation(description: "didReceive completed off-main")
        DispatchQueue.global(qos: .utility).async {
            service.didReceive([] as [MXMetricPayload])
            service.didReceive([] as [MXDiagnosticPayload])
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 5)

        XCTAssertNotNil(
            service.diagnosticSummary,
            "Diagnostic callback should have recorded a summary from the background queue"
        )
    }

    // MARK: - Payload Retention

    /// Writes `count` payload files, one day apart, newest first by mtime.
    private func seedPayloads(in dir: URL, count: Int, now: Date) throws -> [URL] {
        try (0..<count).map { index in
            let url = dir.appending(path: "metric-\(index).json")
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-Double(index) * 86_400)],
                ofItemAtPath: url.path)
            return url
        }
    }

    func testMetricKitPayloadsPrunedToLimit() throws {
        let dir = makeTempDir()
        let pruning = DiagnosticsService(
            defaults: defaults,
            payloadDirectory: dir,
            maxStoredPayloads: 3,
            maxPayloadAge: 365 * 86_400)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let urls = try seedPayloads(in: dir, count: 5, now: now)

        pruning.prunePayloads(now: now)

        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(kept, urls.prefix(3).map(\.lastPathComponent).sorted(), "Newest three must survive")
    }

    func testMetricKitPayloadsOlderThanMaxAgeArePruned() throws {
        let dir = makeTempDir()
        let pruning = DiagnosticsService(
            defaults: defaults,
            payloadDirectory: dir,
            maxStoredPayloads: 100,
            maxPayloadAge: 2.5 * 86_400)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let urls = try seedPayloads(in: dir, count: 5, now: now)

        pruning.prunePayloads(now: now)

        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(kept, urls.prefix(3).map(\.lastPathComponent).sorted(), "Day 0, 1, 2 are inside the window")
    }

    func testOptingOutDeletesStoredPayloads() throws {
        let dir = makeTempDir().appending(path: "Diagnostics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appending(path: "diagnostic-1.json"))
        let optOut = DiagnosticsService(defaults: defaults, payloadDirectory: dir)

        // Never subscribed, so this only exercises the delete path; MetricKit
        // itself is untouched.
        optOut.setEnabled(false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testConcurrentEnableRegistersWithMetricKitOnce() {
        let manager = CountingMetricManager()
        let concurrent = DiagnosticsService(defaults: defaults, metricManager: manager)

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            concurrent.setEnabled(true)
        }

        XCTAssertEqual(manager.addCount, 1, "Concurrent opt-ins must register the subscriber exactly once")

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            concurrent.setEnabled(false)
        }

        XCTAssertEqual(manager.removeCount, 1, "Concurrent opt-outs must remove the subscriber exactly once")
    }
}

// MARK: - CountingMetricManager

/// Counts registrations instead of touching the process-wide `MXMetricManager`.
/// Each call sleeps briefly so a non-atomic check-then-set reliably races.
private final class CountingMetricManager: MetricKitRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private var adds = 0
    private var removes = 0

    var addCount: Int { lock.withLock { adds } }
    var removeCount: Int { lock.withLock { removes } }

    func add(_ subscriber: any MXMetricManagerSubscriber) {
        Thread.sleep(forTimeInterval: 0.005)
        lock.withLock { adds += 1 }
    }

    func remove(_ subscriber: any MXMetricManagerSubscriber) {
        Thread.sleep(forTimeInterval: 0.005)
        lock.withLock { removes += 1 }
    }
}
