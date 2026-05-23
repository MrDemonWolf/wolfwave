//
//  PowerStateMonitorTests.swift
//  WolfWaveTests
//
//  Created by MrDemonWolf, Inc. on 2/27/26.
//

import XCTest
@testable import WolfWave

nonisolated final class PowerStateMonitorTests: XCTestCase {

    // MARK: - Initial State Tests

    @MainActor func testSharedInstanceExists() {
        let monitor = PowerStateMonitor.shared
        XCTAssertNotNil(monitor)
    }

    @MainActor func testSharedInstanceIsSingleton() {
        let a = PowerStateMonitor.shared
        let b = PowerStateMonitor.shared
        XCTAssertTrue(a === b)
    }

    // MARK: - State Property Tests

    @MainActor func testIsReducedModePropertyAccessible() {
        // isReducedMode should be readable without crashing
        let _ = PowerStateMonitor.shared.isReducedMode
    }

    @MainActor func testIsReducedModeDefaultsToFalse() {
        // On CI/test runners without Low Power Mode, isReducedMode should be false
        let value = PowerStateMonitor.shared.isReducedMode
        XCTAssertFalse(value, "Expected isReducedMode to be false in test environment")
    }
}
