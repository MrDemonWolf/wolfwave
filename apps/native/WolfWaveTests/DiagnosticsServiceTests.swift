//
//  DiagnosticsServiceTests.swift
//  WolfWaveTests
//
//  Created by MrDemonWolf, Inc. on 5/22/26.
//

import XCTest

@testable import WolfWave

// MARK: - DiagnosticsServiceTests

/// Covers `DiagnosticsService` opt-in state and the anonymous launch counter.
/// Each test uses an isolated `UserDefaults` suite; the MetricKit subscription
/// itself is not exercised (it has process-wide side effects).
nonisolated final class DiagnosticsServiceTests: XCTestCase {

    private nonisolated(unsafe) var suiteName: String!
    private nonisolated(unsafe) var defaults: UserDefaults!
    private nonisolated(unsafe) var service: DiagnosticsService!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        suiteName = "DiagnosticsServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        service = DiagnosticsService(defaults: defaults)
    }

    @MainActor
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        service = nil
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    @MainActor func testDiagnosticsAreDisabledByDefault() {
        XCTAssertFalse(service.isEnabled, "Diagnostics opt-in must default to off")
    }

    @MainActor func testIsEnabledReflectsStoredPreference() {
        defaults.set(true, forKey: AppConstants.UserDefaults.shareDiagnosticsEnabled)
        XCTAssertTrue(service.isEnabled)
    }

    @MainActor func testRecordAppLaunchIncrementsCounter() {
        XCTAssertEqual(service.launchCount, 0)

        service.recordAppLaunch()
        service.recordAppLaunch()
        service.recordAppLaunch()

        XCTAssertEqual(service.launchCount, 3)
    }

    @MainActor func testPayloadDirectoryIsScopedToWolfWave() {
        let path = service.payloadDirectory.path
        XCTAssertTrue(path.contains("WolfWave/Diagnostics"), "Unexpected payload path: \(path)")
    }

    @MainActor func testDiagnosticSummaryStartsNil() {
        XCTAssertNil(service.diagnosticSummary)
    }
}
