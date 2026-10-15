//
//  CooldownManagerTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-02-27.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest
@testable import WolfWave

/// `CooldownManager` global and per-user cooldowns, including the moderator bypass and reset.
@MainActor
final class CooldownManagerTests: XCTestCase {
    var manager: CooldownManager!

    override func setUp() async throws {
        try await super.setUp()
        manager = CooldownManager()
    }

    override func tearDown() async throws {
        manager = nil
        try await super.tearDown()
    }

    // MARK: - No Cooldown Tests

    func testFirstUseIsNotOnCooldown() {
        let result = manager.isOnCooldown(
            trigger: "!song", userID: "user1", isModerator: false,
            globalCooldown: 5.0, userCooldown: 10.0
        )
        XCTAssertFalse(result)
    }

    func testZeroCooldownsNeverBlock() {
        manager.recordUse(trigger: "!song", userID: "user1")
        let result = manager.isOnCooldown(
            trigger: "!song", userID: "user1", isModerator: false,
            globalCooldown: 0, userCooldown: 0
        )
        XCTAssertFalse(result)
    }

    // MARK: - Global Cooldown Tests

    func testGlobalCooldownBlocksAllUsers() {
        manager.recordUse(trigger: "!song", userID: "user1")
        let result = manager.isOnCooldown(
            trigger: "!song", userID: "user2", isModerator: false,
            globalCooldown: 60.0, userCooldown: 0
        )
        XCTAssertTrue(result)
    }

    func testGlobalCooldownDoesNotBlockDifferentTrigger() {
        manager.recordUse(trigger: "!song", userID: "user1")
        let result = manager.isOnCooldown(
            trigger: "!last", userID: "user1", isModerator: false,
            globalCooldown: 60.0, userCooldown: 0
        )
        XCTAssertFalse(result)
    }

    // MARK: - Per-User Cooldown Tests

    func testUserCooldownBlocksSameUser() {
        manager.recordUse(trigger: "!song", userID: "user1")
        let result = manager.isOnCooldown(
            trigger: "!song", userID: "user1", isModerator: false,
            globalCooldown: 0, userCooldown: 60.0
        )
        XCTAssertTrue(result)
    }

    func testUserCooldownDoesNotBlockDifferentUser() {
        manager.recordUse(trigger: "!song", userID: "user1")
        let result = manager.isOnCooldown(
            trigger: "!song", userID: "user2", isModerator: false,
            globalCooldown: 0, userCooldown: 60.0
        )
        XCTAssertFalse(result)
    }

    // MARK: - Moderator Bypass Tests

    func testModeratorBypassesGlobalCooldown() {
        manager.recordUse(trigger: "!song", userID: "user1")
        let result = manager.isOnCooldown(
            trigger: "!song", userID: "mod1", isModerator: true,
            globalCooldown: 60.0, userCooldown: 0
        )
        XCTAssertFalse(result)
    }

    func testModeratorBypassesUserCooldown() {
        manager.recordUse(trigger: "!song", userID: "mod1")
        let result = manager.isOnCooldown(
            trigger: "!song", userID: "mod1", isModerator: true,
            globalCooldown: 0, userCooldown: 60.0
        )
        XCTAssertFalse(result)
    }

    func testModeratorBypassesBothCooldowns() {
        manager.recordUse(trigger: "!song", userID: "mod1")
        let result = manager.isOnCooldown(
            trigger: "!song", userID: "mod1", isModerator: true,
            globalCooldown: 60.0, userCooldown: 60.0
        )
        XCTAssertFalse(result)
    }

    // MARK: - Reset Tests

    func testResetClearsAllCooldowns() {
        manager.recordUse(trigger: "!song", userID: "user1")
        manager.recordUse(trigger: "!last", userID: "user2")
        manager.reset()

        XCTAssertFalse(manager.isOnCooldown(
            trigger: "!song", userID: "user1", isModerator: false,
            globalCooldown: 60.0, userCooldown: 60.0
        ))
        XCTAssertFalse(manager.isOnCooldown(
            trigger: "!last", userID: "user2", isModerator: false,
            globalCooldown: 60.0, userCooldown: 60.0
        ))
    }

    // MARK: - Remaining Cooldown Tests

    func testRemainingCooldownForNeverUsedTrigger() {
        let remaining = manager.remainingCooldown(
            trigger: "!unused", userID: "user1",
            globalCooldown: 15.0, userCooldown: 15.0
        )
        XCTAssertEqual(remaining.global, 0)
        XCTAssertEqual(remaining.perUser, 0)
    }

    func testRemainingCooldownForRecentlyUsedTrigger() {
        manager.recordUse(trigger: "!song", userID: "user1")
        let remaining = manager.remainingCooldown(
            trigger: "!song", userID: "user1",
            globalCooldown: 60.0, userCooldown: 60.0
        )
        XCTAssertGreaterThan(remaining.global, 0)
        XCTAssertGreaterThan(remaining.perUser, 0)
    }

    func testResetThenIsOnCooldownReturnsFalse() {
        manager.recordUse(trigger: "!song", userID: "user1")
        XCTAssertTrue(manager.isOnCooldown(
            trigger: "!song", userID: "user1", isModerator: false,
            globalCooldown: 60.0, userCooldown: 60.0
        ))

        manager.reset()

        XCTAssertFalse(manager.isOnCooldown(
            trigger: "!song", userID: "user1", isModerator: false,
            globalCooldown: 60.0, userCooldown: 60.0
        ))
    }

    // MARK: - Pruning

    /// Pruning (which starts past 100 per-user entries) must not forget a
    /// cooldown longer than 5 minutes while it is still running.
    func testPruningKeepsCooldownLongerThanFiveMinutes() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let manager = CooldownManager(now: { clock })
        let longCooldown: TimeInterval = 600

        XCTAssertNotNil(manager.tryClaim(
            trigger: "!long", userID: "victim", isModerator: false,
            globalCooldown: 0, userCooldown: longCooldown))

        clock = clock.addingTimeInterval(400)
        for index in 0..<150 {
            _ = manager.tryClaim(
                trigger: "!long", userID: "chatter\(index)", isModerator: false,
                globalCooldown: 0, userCooldown: longCooldown)
        }

        XCTAssertTrue(manager.isOnCooldown(
            trigger: "!long", userID: "victim", isModerator: false,
            globalCooldown: 0, userCooldown: longCooldown))
    }

    /// Entries older than every cooldown in force are still pruned.
    func testPruningDropsEntriesPastLongestCooldown() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let manager = CooldownManager(now: { clock })

        XCTAssertNotNil(manager.tryClaim(
            trigger: "!song", userID: "old", isModerator: false,
            globalCooldown: 0, userCooldown: 30))
        clock = clock.addingTimeInterval(31)
        for index in 0..<150 {
            _ = manager.tryClaim(
                trigger: "!song", userID: "chatter\(index)", isModerator: false,
                globalCooldown: 0, userCooldown: 30)
        }

        // Asked with a longer window: a pruned entry reports nothing remaining.
        XCTAssertEqual(manager.remainingCooldown(
            trigger: "!song", userID: "old", globalCooldown: 0, userCooldown: 600).perUser, 0)
    }
}
