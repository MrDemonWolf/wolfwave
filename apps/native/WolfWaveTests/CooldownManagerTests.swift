//
//  CooldownManagerTests.swift
//  WolfWaveTests
//
//  Created by MrDemonWolf, Inc. on 2/27/26.
//

import XCTest
@testable import WolfWave

nonisolated final class CooldownManagerTests: XCTestCase {
    nonisolated(unsafe) var manager: CooldownManager!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        manager = CooldownManager()
    }

    @MainActor
    override func tearDown() async throws {
        manager = nil
        try await super.tearDown()
    }

    // MARK: - No Cooldown Tests

    @MainActor func testFirstUseIsNotOnCooldown() {
        let result = manager.isOnCooldown(
            trigger: "!song", userID: "user1", isModerator: false,
            globalCooldown: 5.0, userCooldown: 10.0
        )
        XCTAssertFalse(result)
    }

    @MainActor func testZeroCooldownsNeverBlock() {
        manager.recordUse(trigger: "!song", userID: "user1")
        let result = manager.isOnCooldown(
            trigger: "!song", userID: "user1", isModerator: false,
            globalCooldown: 0, userCooldown: 0
        )
        XCTAssertFalse(result)
    }

    // MARK: - Global Cooldown Tests

    @MainActor func testGlobalCooldownBlocksAllUsers() {
        manager.recordUse(trigger: "!song", userID: "user1")
        let result = manager.isOnCooldown(
            trigger: "!song", userID: "user2", isModerator: false,
            globalCooldown: 60.0, userCooldown: 0
        )
        XCTAssertTrue(result)
    }

    @MainActor func testGlobalCooldownDoesNotBlockDifferentTrigger() {
        manager.recordUse(trigger: "!song", userID: "user1")
        let result = manager.isOnCooldown(
            trigger: "!last", userID: "user1", isModerator: false,
            globalCooldown: 60.0, userCooldown: 0
        )
        XCTAssertFalse(result)
    }

    // MARK: - Per-User Cooldown Tests

    @MainActor func testUserCooldownBlocksSameUser() {
        manager.recordUse(trigger: "!song", userID: "user1")
        let result = manager.isOnCooldown(
            trigger: "!song", userID: "user1", isModerator: false,
            globalCooldown: 0, userCooldown: 60.0
        )
        XCTAssertTrue(result)
    }

    @MainActor func testUserCooldownDoesNotBlockDifferentUser() {
        manager.recordUse(trigger: "!song", userID: "user1")
        let result = manager.isOnCooldown(
            trigger: "!song", userID: "user2", isModerator: false,
            globalCooldown: 0, userCooldown: 60.0
        )
        XCTAssertFalse(result)
    }

    // MARK: - Moderator Bypass Tests

    @MainActor func testModeratorBypassesGlobalCooldown() {
        manager.recordUse(trigger: "!song", userID: "user1")
        let result = manager.isOnCooldown(
            trigger: "!song", userID: "mod1", isModerator: true,
            globalCooldown: 60.0, userCooldown: 0
        )
        XCTAssertFalse(result)
    }

    @MainActor func testModeratorBypassesUserCooldown() {
        manager.recordUse(trigger: "!song", userID: "mod1")
        let result = manager.isOnCooldown(
            trigger: "!song", userID: "mod1", isModerator: true,
            globalCooldown: 0, userCooldown: 60.0
        )
        XCTAssertFalse(result)
    }

    @MainActor func testModeratorBypassesBothCooldowns() {
        manager.recordUse(trigger: "!song", userID: "mod1")
        let result = manager.isOnCooldown(
            trigger: "!song", userID: "mod1", isModerator: true,
            globalCooldown: 60.0, userCooldown: 60.0
        )
        XCTAssertFalse(result)
    }

    // MARK: - Reset Tests

    @MainActor func testResetClearsAllCooldowns() {
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

    @MainActor func testRemainingCooldownForNeverUsedTrigger() {
        let remaining = manager.remainingCooldown(
            trigger: "!unused", userID: "user1",
            globalCooldown: 15.0, userCooldown: 15.0
        )
        XCTAssertEqual(remaining.global, 0)
        XCTAssertEqual(remaining.perUser, 0)
    }

    @MainActor func testRemainingCooldownForRecentlyUsedTrigger() {
        manager.recordUse(trigger: "!song", userID: "user1")
        let remaining = manager.remainingCooldown(
            trigger: "!song", userID: "user1",
            globalCooldown: 60.0, userCooldown: 60.0
        )
        XCTAssertGreaterThan(remaining.global, 0)
        XCTAssertGreaterThan(remaining.perUser, 0)
    }

    @MainActor func testResetThenIsOnCooldownReturnsFalse() {
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
}
