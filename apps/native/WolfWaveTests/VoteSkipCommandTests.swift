//
//  VoteSkipCommandTests.swift
//  WolfWaveTests
//
//  Created by MrDemonWolf, Inc. on 5/22/26.
//

import XCTest

@testable import WolfWave

nonisolated final class VoteSkipCommandTests: XCTestCase {

    private nonisolated(unsafe) let keys: [String] = [
        AppConstants.UserDefaults.voteSkipEnabled,
        AppConstants.UserDefaults.voteSkipMinVotes,
        AppConstants.UserDefaults.voteSkipSessionCooldown,
        AppConstants.UserDefaults.voteSkipCommandEnabled,
        AppConstants.UserDefaults.voteSkipCommandAliases,
    ]

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    @MainActor
    override func tearDown() async throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        try await super.tearDown()
    }

    @MainActor private func context(userID: String) -> BotCommandContext {
        BotCommandContext(
            userID: userID, username: "user\(userID)",
            isModerator: false, isBroadcaster: false,
            isSubscriber: false, isVIP: false, messageID: "m\(userID)"
        )
    }

    // MARK: - Triggers & Configuration

    @MainActor func testTriggers() {
        XCTAssertEqual(VoteSkipCommand().triggers, ["!voteskip", "!vs"])
    }

    @MainActor func testZeroCooldowns() {
        let command = VoteSkipCommand()
        XCTAssertEqual(command.globalCooldown, 0)
        XCTAssertEqual(command.userCooldown, 0)
    }

    @MainActor func testDefaultEnabled() {
        XCTAssertTrue(VoteSkipCommand().isCommandEnabled)
    }

    @MainActor func testDisabledViaUserDefaults() {
        UserDefaults.standard.set(false, forKey: AppConstants.UserDefaults.voteSkipCommandEnabled)
        XCTAssertFalse(VoteSkipCommand().isCommandEnabled)
    }

    @MainActor func testCustomAliasesAppendToTriggers() {
        UserDefaults.standard.set("skipvote, sv", forKey: AppConstants.UserDefaults.voteSkipCommandAliases)
        let triggers = VoteSkipCommand().allTriggers
        XCTAssertTrue(triggers.contains("!skipvote"))
        XCTAssertTrue(triggers.contains("!sv"))
    }

    @MainActor func testSyncExecuteReturnsNil() {
        XCTAssertNil(VoteSkipCommand().execute(message: "!voteskip"))
    }

    // MARK: - Reply Formatting

    @MainActor func testFormatDisabledIsSilent() {
        XCTAssertNil(VoteSkipCommand.format(.disabled))
    }

    @MainActor func testFormatStartedAndCountedShowProgress() {
        XCTAssertEqual(VoteSkipCommand.format(.started(count: 1, needed: 3))?.contains("1/3"), true)
        XCTAssertEqual(VoteSkipCommand.format(.counted(count: 2, needed: 3))?.contains("2/3"), true)
    }

    @MainActor func testFormatPassedAndCooldown() {
        XCTAssertEqual(VoteSkipCommand.format(.passed(count: 3))?.isEmpty, false)
        XCTAssertEqual(VoteSkipCommand.format(.onCooldown(remaining: 12))?.contains("12"), true)
    }

    @MainActor func testFormatNonDisabledOutcomesProduceReplies() {
        let outcomes: [SkipVoteManager.VoteOutcome] = [
            .subscriberOnly,
            .alreadyVoted(count: 1, needed: 3),
            .pollStarted,
            .pollInProgress,
            .pollNotAllowed,
        ]
        for outcome in outcomes {
            XCTAssertNotNil(VoteSkipCommand.format(outcome), "\(outcome) should produce a reply")
        }
    }

    // MARK: - Execution

    @MainActor func testExecuteRepliesWhenVotePasses() {
        UserDefaults.standard.set(true, forKey: AppConstants.UserDefaults.voteSkipEnabled)
        UserDefaults.standard.set(1, forKey: AppConstants.UserDefaults.voteSkipMinVotes)

        let manager = SkipVoteManager()
        manager.performSkip = {}
        let command = VoteSkipCommand()
        command.skipVoteManager = { manager }

        let replied = expectation(description: "reply delivered")
        command.execute(message: "!voteskip", context: context(userID: "1")) { response in
            XCTAssertFalse(response.isEmpty)
            replied.fulfill()
        }
        wait(for: [replied], timeout: 2)
    }

    @MainActor func testExecuteStaysSilentWhenFeatureDisabled() {
        // voteSkipEnabled is unset → feature off → manager returns .disabled → no reply.
        let manager = SkipVoteManager()
        let command = VoteSkipCommand()
        command.skipVoteManager = { manager }

        let noReply = expectation(description: "no reply")
        noReply.isInverted = true
        command.execute(message: "!voteskip", context: context(userID: "1")) { _ in
            noReply.fulfill()
        }
        wait(for: [noReply], timeout: 1)
    }
}
