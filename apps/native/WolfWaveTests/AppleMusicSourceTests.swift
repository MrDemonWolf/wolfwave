//
//  AppleMusicSourceTests.swift
//  WolfWaveTests
//
//  Created by MrDemonWolf, Inc. on 2/27/26.
//

import XCTest
@testable import WolfWave

nonisolated final class AppleMusicSourceTests: XCTestCase {
    nonisolated(unsafe) var monitor: AppleMusicSource!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        monitor = AppleMusicSource()
    }

    @MainActor
    override func tearDown() async throws {
        monitor.stopTracking()
        monitor = nil
        try await super.tearDown()
    }

    // MARK: - Initialization Tests

    @MainActor func testMonitorInitialization() {
        XCTAssertNotNil(monitor)
    }

    @MainActor func testDelegateIsNilByDefault() {
        XCTAssertNil(monitor.delegate)
    }

    // MARK: - Start/Stop Tests

    @MainActor func testStartTrackingDoesNotCrash() {
        monitor.startTracking()
        // If Music.app is not running, we should get a status update
    }

    @MainActor func testStopTrackingDoesNotCrash() {
        monitor.startTracking()
        monitor.stopTracking()
    }

    @MainActor func testDoubleStartDoesNotCrash() {
        monitor.startTracking()
        monitor.startTracking()
        monitor.stopTracking()
    }

    @MainActor func testDoubleStopDoesNotCrash() {
        monitor.startTracking()
        monitor.stopTracking()
        monitor.stopTracking()
    }

    // MARK: - Update Interval Tests

    @MainActor func testUpdateCheckIntervalBeforeStartDoesNotCrash() {
        monitor.updateCheckInterval(10.0)
    }

    @MainActor func testUpdateCheckIntervalWhileTrackingDoesNotCrash() {
        monitor.startTracking()
        monitor.updateCheckInterval(10.0)
        monitor.stopTracking()
    }
}
