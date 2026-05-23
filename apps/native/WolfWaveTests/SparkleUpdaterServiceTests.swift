//
//  SparkleUpdaterServiceTests.swift
//  WolfWaveTests
//
//  Created by MrDemonWolf, Inc. on 3/18/26.
//

import XCTest
@testable import WolfWave

nonisolated final class SparkleUpdaterServiceTests: XCTestCase {

    // MARK: - Initialization Tests

    @MainActor func testServiceInitializesWithoutCrash() {
        let service = SparkleUpdaterService()
        XCTAssertNotNil(service)
    }

    // MARK: - Feed URL Tests

    @MainActor func testFeedURLPointsAtBundledDevAppcastInDebug() {
        // DEBUG builds route Sparkle at the bundled dev-appcast.xml so manual
        // "Check for Updates" exercises the real Sparkle UI against a dummy entry.
        let service = SparkleUpdaterService()
        let url = service.feedURL
        XCTAssertNotNil(url, "feedURL should point at the bundled dev-appcast.xml in DEBUG builds")
        XCTAssertEqual(url?.lastPathComponent, "dev-appcast.xml")
    }

    // MARK: - Default Property Tests

    @MainActor func testAutomaticCheckDefaultsToTrueWhenUpdaterNil() {
        // The getter falls back to true when the underlying updater is unset.
        let service = SparkleUpdaterService()
        XCTAssertTrue(service.automaticCheckEnabled, "automaticCheckEnabled getter should default to true when updater is nil")
    }

    @MainActor func testUpdateCheckIntervalReturnsConstantWhenUpdaterNil() {
        let service = SparkleUpdaterService()
        XCTAssertEqual(
            service.updateCheckInterval,
            AppConstants.Update.checkInterval,
            "updateCheckInterval should return AppConstants.Update.checkInterval when updater is nil"
        )
    }

    // MARK: - Safe Operation Tests

    @MainActor func testCheckForUpdatesDoesNotCrash() {
        let service = SparkleUpdaterService()
        service.checkForUpdates()
    }

    @MainActor func testCheckForUpdatesInBackgroundDoesNotCrash() {
        let service = SparkleUpdaterService()
        service.checkForUpdatesInBackground()
    }

    // MARK: - SPUUpdaterDelegate Tests

    @MainActor func testServiceIsNSObjectForDelegateConformance() {
        let service = SparkleUpdaterService()
        XCTAssertTrue(service is NSObject, "SparkleUpdaterService should be an NSObject subclass to satisfy SPUUpdaterDelegate")
    }
}
