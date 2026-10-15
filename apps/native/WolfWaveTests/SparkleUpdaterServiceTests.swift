//
//  SparkleUpdaterServiceTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-03-19.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest
@testable import WolfWave

/// Sparkle feed resolution (DEBUG dev appcast vs Stable/Nightly channel) and the
/// persisted `UpdateChannel` preference. Subclasses `WolfWaveTestCase` because the
/// channel is stored in `DefaultsStore.store`.
@MainActor
final class SparkleUpdaterServiceTests: WolfWaveTestCase {

    // MARK: - Feed URL Tests

    func testDevAppcastIsBundledForDebugFeed() {
        // DEBUG builds route Sparkle at the bundled dev-appcast.xml so manual
        // "Check for Updates" exercises the real Sparkle UI against a dummy entry.
        // `feedURLString(for:)` hands exactly this lookup to the resolver, so a
        // missing resource would silently send DEBUG checks nowhere.
        let url = Bundle.main.url(forResource: "dev-appcast", withExtension: "xml")
        XCTAssertNotNil(url, "dev-appcast.xml should be bundled in the test host")
        XCTAssertEqual(url?.lastPathComponent, "dev-appcast.xml")
    }

    // MARK: - Default Property Tests

    func testAutomaticCheckDefaultsToTrueWhenUpdaterNil() {
        // The getter falls back to true when the underlying updater is unset.
        let service = SparkleUpdaterService()
        XCTAssertTrue(service.automaticCheckEnabled, "automaticCheckEnabled getter should default to true when updater is nil")
    }

    func testSparkleAutomaticChecksPolicyKeepsDebugOff() {
        XCTAssertFalse(SparkleUpdaterService.sparkleAutomaticChecks(preference: true, isDebug: true))
        XCTAssertFalse(SparkleUpdaterService.sparkleAutomaticChecks(preference: false, isDebug: true))
        XCTAssertTrue(SparkleUpdaterService.sparkleAutomaticChecks(preference: true, isDebug: false))
        XCTAssertFalse(SparkleUpdaterService.sparkleAutomaticChecks(preference: false, isDebug: false))
    }

    #if DEBUG
    func testEnablingAutomaticChecksInDebugPersistsButLeavesSparkleOff() throws {
        let service = SparkleUpdaterService()
        try XCTSkipIf(service.sparkleAutomaticallyChecksForUpdates == nil, "No Sparkle updater (Homebrew host)")

        service.automaticCheckEnabled = true

        XCTAssertEqual(service.sparkleAutomaticallyChecksForUpdates, false,
                       "DEBUG must never turn on Sparkle background checks")
        XCTAssertTrue(service.automaticCheckEnabled, "The toggle reflects the stored preference")
        XCTAssertTrue(DefaultsStore.store.bool(forKey: AppConstants.UserDefaults.updateCheckEnabled))

        service.automaticCheckEnabled = false
        XCTAssertFalse(service.automaticCheckEnabled)
        XCTAssertEqual(service.sparkleAutomaticallyChecksForUpdates, false)
    }
    #endif

    // MARK: - Feed Resolver Tests (channel selection)

    private let nightlyURL = "https://example.com/appcast-nightly.xml"
    private let devURL = "file:///tmp/dev-appcast.xml"

    func testResolverDebugAlwaysUsesDevAppcastRegardlessOfChannel() {
        // DEBUG builds must always exercise the bundled dev appcast, even if the
        // stored channel is Nightly. The DEBUG branch wins.
        for channel in UpdateChannel.allCases {
            let resolved = SparkleUpdaterService.resolveFeedURLString(
                channel: channel,
                isDebug: true,
                nightlyURL: nightlyURL,
                devAppcastURL: devURL
            )
            XCTAssertEqual(resolved, devURL, "DEBUG should use dev appcast for channel \(channel.rawValue)")
        }
    }

    func testResolverReleaseNightlyUsesNightlyFeed() {
        let resolved = SparkleUpdaterService.resolveFeedURLString(
            channel: .nightly,
            isDebug: false,
            nightlyURL: nightlyURL,
            devAppcastURL: devURL
        )
        XCTAssertEqual(resolved, nightlyURL)
    }

    func testResolverReleaseStableFallsBackToInfoPlistFeed() {
        // nil signals Sparkle to use SUFeedURL from Info.plist.
        let resolved = SparkleUpdaterService.resolveFeedURLString(
            channel: .stable,
            isDebug: false,
            nightlyURL: nightlyURL,
            devAppcastURL: devURL
        )
        XCTAssertNil(resolved)
    }

    // MARK: - Channel Persistence Tests

    func testChannelDefaultsToStable() {
        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.updateChannel)
        let service = SparkleUpdaterService()
        XCTAssertEqual(service.channel, .stable)
    }

    func testChannelPersistsRawValue() {
        let service = SparkleUpdaterService()
        defer { DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.updateChannel) }

        service.channel = .nightly
        XCTAssertEqual(
            DefaultsStore.store.string(forKey: AppConstants.UserDefaults.updateChannel),
            UpdateChannel.nightly.rawValue
        )
        XCTAssertEqual(service.channel, .nightly)

        service.channel = .stable
        XCTAssertEqual(service.channel, .stable)
    }
}
