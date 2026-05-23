//
//  SongRequestAccessTests.swift
//  WolfWaveTests
//
//  Created by MrDemonWolf, Inc. on 5/22/26.
//

import XCTest

@testable import WolfWave

// MARK: - RequestAudience

nonisolated final class RequestAudienceTests: XCTestCase {

    @MainActor func testEveryonePermitsAnyViewer() {
        XCTAssertTrue(
            RequestAudience.everyone.permits(
                isSubscriber: false, isVIP: false, isModerator: false, isBroadcaster: false))
    }

    @MainActor func testSubscribersBlocksRegularViewer() {
        XCTAssertFalse(
            RequestAudience.subscribers.permits(
                isSubscriber: false, isVIP: false, isModerator: false, isBroadcaster: false))
    }

    @MainActor func testSubscribersAllowsSubscriber() {
        XCTAssertTrue(
            RequestAudience.subscribers.permits(
                isSubscriber: true, isVIP: false, isModerator: false, isBroadcaster: false))
    }

    @MainActor func testSubscribersBlocksVIP() {
        XCTAssertFalse(
            RequestAudience.subscribers.permits(
                isSubscriber: false, isVIP: true, isModerator: false, isBroadcaster: false))
    }

    @MainActor func testVipsAndSubsAllowsVIPAndSubscriber() {
        let audience = RequestAudience.vipsAndSubs
        XCTAssertTrue(
            audience.permits(
                isSubscriber: false, isVIP: true, isModerator: false, isBroadcaster: false))
        XCTAssertTrue(
            audience.permits(
                isSubscriber: true, isVIP: false, isModerator: false, isBroadcaster: false))
    }

    @MainActor func testVipsAndSubsBlocksRegularViewer() {
        XCTAssertFalse(
            RequestAudience.vipsAndSubs.permits(
                isSubscriber: false, isVIP: false, isModerator: false, isBroadcaster: false))
    }

    @MainActor func testModsOnlyBlocksSubscriberAndVIP() {
        XCTAssertFalse(
            RequestAudience.modsOnly.permits(
                isSubscriber: true, isVIP: true, isModerator: false, isBroadcaster: false))
    }

    @MainActor func testModeratorAlwaysPermittedRegardlessOfAudience() {
        for audience in RequestAudience.allCases {
            XCTAssertTrue(
                audience.permits(
                    isSubscriber: false, isVIP: false, isModerator: true, isBroadcaster: false),
                "Moderator should bypass \(audience.rawValue)")
        }
    }

    @MainActor func testBroadcasterAlwaysPermittedRegardlessOfAudience() {
        for audience in RequestAudience.allCases {
            XCTAssertTrue(
                audience.permits(
                    isSubscriber: false, isVIP: false, isModerator: false, isBroadcaster: true),
                "Broadcaster should bypass \(audience.rawValue)")
        }
    }

    @MainActor func testRawValueRoundTrips() {
        for audience in RequestAudience.allCases {
            XCTAssertEqual(RequestAudience(rawValue: audience.rawValue), audience)
        }
    }
}

// MARK: - SongRequestPreset

nonisolated final class SongRequestPresetTests: XCTestCase {

    private nonisolated(unsafe) var defaults: UserDefaults!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: "SongRequestPresetTests")
        defaults.removePersistentDomain(forName: "SongRequestPresetTests")
    }

    @MainActor
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: "SongRequestPresetTests")
        defaults = nil
        try await super.tearDown()
    }

    @MainActor func testApplyOpenPresetWritesExpectedKeys() {
        SongRequestPreset.open.apply(to: defaults)

        XCTAssertEqual(defaults.bool(forKey: AppConstants.UserDefaults.srCommandEnabled), true)
        XCTAssertEqual(
            defaults.string(forKey: AppConstants.UserDefaults.songRequestChatAudience),
            RequestAudience.everyone.rawValue)
        XCTAssertTrue(
            defaults.bool(forKey: AppConstants.UserDefaults.songRequestChannelPointsEnabled))
        XCTAssertTrue(defaults.bool(forKey: AppConstants.UserDefaults.songRequestBitsEnabled))
    }

    @MainActor func testApplyPaidOnlyDisablesChatCommand() {
        SongRequestPreset.paidOnly.apply(to: defaults)
        XCTAssertFalse(defaults.bool(forKey: AppConstants.UserDefaults.srCommandEnabled))
        XCTAssertTrue(
            defaults.bool(forKey: AppConstants.UserDefaults.songRequestChannelPointsEnabled))
    }

    @MainActor func testApplySubsStrictDisablesRedemptions() {
        SongRequestPreset.subsStrict.apply(to: defaults)
        XCTAssertEqual(
            defaults.string(forKey: AppConstants.UserDefaults.songRequestChatAudience),
            RequestAudience.subscribers.rawValue)
        XCTAssertFalse(
            defaults.bool(forKey: AppConstants.UserDefaults.songRequestChannelPointsEnabled))
        XCTAssertFalse(defaults.bool(forKey: AppConstants.UserDefaults.songRequestBitsEnabled))
    }

    @MainActor func testCurrentDetectsAppliedPreset() {
        for preset in SongRequestPreset.allCases {
            preset.apply(to: defaults)
            XCTAssertEqual(
                SongRequestPreset.current(in: defaults), preset,
                "current() should detect \(preset.rawValue) after apply()")
        }
    }

    @MainActor func testCurrentReturnsNilForCustomConfiguration() {
        SongRequestPreset.open.apply(to: defaults)
        // Diverge from every preset: open audience but redemptions off.
        defaults.set(false, forKey: AppConstants.UserDefaults.songRequestChannelPointsEnabled)
        defaults.set(false, forKey: AppConstants.UserDefaults.songRequestBitsEnabled)
        XCTAssertNil(SongRequestPreset.current(in: defaults))
    }
}

// MARK: - RedemptionStatus

nonisolated final class RedemptionStatusTests: XCTestCase {

    @MainActor func testOkHasNoBanner() {
        XCTAssertNil(RedemptionStatus.ok.bannerMessage)
    }

    @MainActor func testProblemStatusesHaveBanner() {
        XCTAssertNotNil(RedemptionStatus.scopeMissing.bannerMessage)
        XCTAssertNotNil(RedemptionStatus.botAccount.bannerMessage)
        XCTAssertNotNil(RedemptionStatus.subscribeFailed.bannerMessage)
    }

    @MainActor func testRawValueRoundTrips() {
        XCTAssertEqual(RedemptionStatus(rawValue: "ok"), .ok)
        XCTAssertEqual(RedemptionStatus(rawValue: "botAccount"), .botAccount)
    }
}
