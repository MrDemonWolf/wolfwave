//
//  BotCommandDispatcherTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-02-13.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest
@testable import WolfWave

@MainActor
final class BotCommandDispatcherTests: WolfWaveTestCase {
    var dispatcher: BotCommandDispatcher!

    override func setUp() async throws {
        try await super.setUp()
        dispatcher = BotCommandDispatcher()
    }

    override func tearDown() async throws {
        dispatcher = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Runs `message` through the production dispatch path
    /// (`processMessageReplyAsync`) without a chat context.
    private func dispatch(
        _ message: String,
        userID: String = "",
        isModerator: Bool = false
    ) async -> String? {
        await dispatcher.processMessageAsync(message, userID: userID, isModerator: isModerator, context: nil)
    }

    // MARK: - Default Command Tests

    func testDefaultSongCommandRegistered() async {
        dispatcher.setCurrentSongInfoAsync { "Artist - Song" }
        let result = await dispatch("!song")
        XCTAssertEqual(result, "Artist - Song")
    }

    func testDefaultLastCommandRegistered() async {
        dispatcher.setLastSongInfoAsync { "Previous Artist - Song" }
        let result = await dispatch("!last")
        XCTAssertEqual(result, "Previous Artist - Song")
    }

    // MARK: - Non-Command Messages

    func testNonCommandReturnsNil() async {
        let result = await dispatch("hello")
        XCTAssertNil(result)
    }

    func testEmptyStringReturnsNil() async {
        let result = await dispatch("")
        XCTAssertNil(result)
    }

    func testOverLengthMessageReturnsNil() async {
        let longMessage = String(repeating: "a", count: 501)
        let result = await dispatch(longMessage)
        XCTAssertNil(result)
    }

    func testExactly500CharsProcessed() async {
        // "!song" + space + filler = 500 chars. Routing matches on the first
        // whitespace token, so the trailing filler must be separated by a space
        // to register as a real command invocation.
        let message = "!song " + String(repeating: "x", count: 494)
        dispatcher.setCurrentSongInfoAsync { "Artist - Song" }
        let result = await dispatch(message)
        XCTAssertNotNil(result)
    }

    func testWhitespaceOnlyReturnsNil() async {
        let result = await dispatch("   ")
        XCTAssertNil(result)
    }

    // MARK: - Callback Wiring Tests

    func testSetCurrentSongInfoCallback() async {
        dispatcher.setCurrentSongInfoAsync { "Test Track" }
        let result = await dispatch("!song")
        XCTAssertEqual(result, "Test Track")
    }

    func testSetLastSongInfoCallback() async {
        dispatcher.setLastSongInfoAsync { "Previous Track" }
        let result = await dispatch("!last")
        XCTAssertEqual(result, "Previous Track")
    }

    func testDisableCurrentSongCommand() async {
        dispatcher.setCurrentSongInfoAsync { "Artist - Song" }
        dispatcher.setCurrentSongCommandEnabled { false }
        let result = await dispatch("!song")
        XCTAssertNil(result)
    }

    func testDisableLastSongCommand() async {
        dispatcher.setLastSongInfoAsync { "Artist - Song" }
        dispatcher.setLastSongCommandEnabled { false }
        let result = await dispatch("!last")
        XCTAssertNil(result)
    }

    func testAsyncCommandIsAwaitedAndReturned() async {
        let command = AwaitedTestCommand()
        dispatcher.register(command)
        let context = BotCommandContext(
            userID: "viewer-1",
            username: "Viewer",
            isModerator: false,
            isBroadcaster: false,
            isSubscriber: false,
            isVIP: false,
            messageID: "message-1")

        let result = await dispatcher.processMessageAsync(
            "!awaited",
            userID: context.userID,
            context: context)

        XCTAssertTrue(command.didExecute)
        XCTAssertEqual(result, "awaited response")
    }

    func testDeniedServiceCommandDoesNotConsumeCooldown() async {
        let command = PrivilegedCooldownTestCommand()
        dispatcher.register(command)
        let viewer = BotCommandContext(
            userID: "viewer-1",
            username: "Viewer",
            isModerator: false,
            isBroadcaster: false,
            isSubscriber: false,
            isVIP: false,
            messageID: "message-1")
        let broadcaster = BotCommandContext(
            userID: "broadcaster-1",
            username: "Broadcaster",
            isModerator: false,
            isBroadcaster: true,
            isSubscriber: false,
            isVIP: false,
            messageID: "message-2")

        let denied = await dispatcher.processMessageAsync(
            "!privileged-cooldown",
            userID: viewer.userID,
            context: viewer)
        let allowed = await dispatcher.processMessageAsync(
            "!privileged-cooldown",
            userID: broadcaster.userID,
            context: broadcaster)

        XCTAssertNil(denied)
        XCTAssertEqual(allowed, "privileged response")
        XCTAssertEqual(command.executionCount, 1)
    }

    // MARK: - Whitespace Handling

    func testLeadingWhitespaceTrimmed() async {
        dispatcher.setCurrentSongInfoAsync { "Track" }
        let result = await dispatch("  !song")
        XCTAssertEqual(result, "Track")
    }

    func testTrailingWhitespaceTrimmed() async {
        dispatcher.setCurrentSongInfoAsync { "Track" }
        let result = await dispatch("!song  ")
        XCTAssertEqual(result, "Track")
    }

    // MARK: - Alias Cooldown Grouping Tests

    func testSongAliasesShareCooldown() async {
        dispatcher.setCurrentSongInfoAsync { "Artist - Song" }

        // Set a non-zero cooldown so the second call is blocked
        let defaults = DefaultsStore.store
        defaults.set(15.0, forKey: AppConstants.UserDefaults.songCommandGlobalCooldown)
        defaults.set(15.0, forKey: AppConstants.UserDefaults.songCommandUserCooldown)
        defer {
            defaults.removeObject(forKey: AppConstants.UserDefaults.songCommandGlobalCooldown)
            defaults.removeObject(forKey: AppConstants.UserDefaults.songCommandUserCooldown)
        }

        let first = await dispatch("!song", userID: "user1")
        XCTAssertNotNil(first, "First !song call should succeed")

        let second = await dispatch("!currentsong", userID: "user1")
        XCTAssertNil(second, "!currentsong should be blocked by shared cooldown with !song")

        let third = await dispatch("!nowplaying", userID: "user1")
        XCTAssertNil(third, "!nowplaying should be blocked by shared cooldown with !song")
    }

    func testBroadcasterAlwaysBypassesCooldown() async {
        dispatcher.setCurrentSongInfoAsync { "Artist - Song" }

        let defaults = DefaultsStore.store
        defaults.set(15.0, forKey: AppConstants.UserDefaults.songCommandGlobalCooldown)
        defaults.set(15.0, forKey: AppConstants.UserDefaults.songCommandUserCooldown)
        defer {
            defaults.removeObject(forKey: AppConstants.UserDefaults.songCommandGlobalCooldown)
            defaults.removeObject(forKey: AppConstants.UserDefaults.songCommandUserCooldown)
        }

        // Broadcaster always bypasses cooldowns (isModerator: true)
        let first = await dispatch("!song", userID: "broadcaster1", isModerator: true)
        XCTAssertNotNil(first, "First !song call should succeed")

        let second = await dispatch("!song", userID: "broadcaster1", isModerator: true)
        XCTAssertNotNil(second, "Broadcaster should always bypass cooldown")
    }

    func testLastSongAliasesShareCooldown() async {
        dispatcher.setLastSongInfoAsync { "Previous Artist - Song" }

        let defaults = DefaultsStore.store
        defaults.set(15.0, forKey: AppConstants.UserDefaults.lastSongCommandGlobalCooldown)
        defaults.set(15.0, forKey: AppConstants.UserDefaults.lastSongCommandUserCooldown)
        defer {
            defaults.removeObject(forKey: AppConstants.UserDefaults.lastSongCommandGlobalCooldown)
            defaults.removeObject(forKey: AppConstants.UserDefaults.lastSongCommandUserCooldown)
        }

        let first = await dispatch("!last", userID: "user1")
        XCTAssertNotNil(first, "First !last call should succeed")

        let second = await dispatch("!lastsong", userID: "user1")
        XCTAssertNil(second, "!lastsong should be blocked by shared cooldown with !last")

        let third = await dispatch("!prevsong", userID: "user1")
        XCTAssertNil(third, "!prevsong should be blocked by shared cooldown with !last")
    }

    // MARK: - Concurrent Dispatch

    /// Two `!song` messages that overlap while the first is suspended in its
    /// provider: the global cooldown must hold the second back. Before the slot
    /// was claimed ahead of the `await`, both passed the check and both replied.
    func testConcurrentSongCommandsRespectGlobalCooldown() async throws {
        let provider = HeldTrackProvider()
        dispatcher.setCurrentSongInfoAsync { await provider.next() }

        let defaults = DefaultsStore.store
        defaults.set(5.0, forKey: AppConstants.UserDefaults.songCommandGlobalCooldown)
        defaults.set(0.0, forKey: AppConstants.UserDefaults.songCommandUserCooldown)
        defer {
            defaults.removeObject(forKey: AppConstants.UserDefaults.songCommandGlobalCooldown)
            defaults.removeObject(forKey: AppConstants.UserDefaults.songCommandUserCooldown)
        }

        let dispatcher = try XCTUnwrap(self.dispatcher)
        let first = Task {
            await dispatcher.processMessageAsync("!song", userID: "viewer-1", context: nil)
        }
        await provider.waitUntilFirstCallParked()

        // The first message is parked mid-command. A second viewer's !song must
        // be refused now, not pass the check and race to a reply.
        let second = await dispatch("!song", userID: "viewer-2")
        await provider.release()
        let firstResult = await first.value

        XCTAssertEqual(firstResult, "Artist - Song")
        XCTAssertNil(second, "Overlapping !song must be held back by the global cooldown")
        let callCount = await provider.callCount
        XCTAssertEqual(callCount, 1, "The refused message must never reach the provider")
    }

    /// A track command that produces no reply gives its cooldown slot back, so
    /// the next message is not blocked by a reply that was never sent.
    func testSilentTrackCommandReleasesCooldown() async {
        dispatcher.setCurrentSongInfoAsync { "Artist - Song" }
        var enabled = false
        dispatcher.setCurrentSongCommandEnabled { enabled }

        let defaults = DefaultsStore.store
        defaults.set(15.0, forKey: AppConstants.UserDefaults.songCommandGlobalCooldown)
        defaults.set(15.0, forKey: AppConstants.UserDefaults.songCommandUserCooldown)
        defer {
            defaults.removeObject(forKey: AppConstants.UserDefaults.songCommandGlobalCooldown)
            defaults.removeObject(forKey: AppConstants.UserDefaults.songCommandUserCooldown)
        }

        let silent = await dispatch("!song", userID: "user1")
        XCTAssertNil(silent)

        enabled = true
        let replied = await dispatch("!song", userID: "user1")
        XCTAssertEqual(replied, "Artist - Song", "A silent !song must not warm the cooldown")
    }

    // MARK: - Reply delivery

    func testReplyDeliveryFollowsMatchedCommand() async {
        let store = CustomCommandStore.shared
        let before = store.commands
        defer {
            store.clearAll()
            before.forEach { store.add($0) }
        }
        store.clearAll()
        store.add(CustomCommand(trigger: "hype", response: "HYPE", delivery: .announce))
        dispatcher.setCurrentSongInfoAsync { "Artist - Song" }
        let context = BotCommandContext(
            userID: "1", username: "v", isModerator: false, isBroadcaster: false,
            isSubscriber: false, isVIP: false, messageID: "m")

        let custom = await dispatcher.processMessageReplyAsync("!hype", userID: "1", context: context)
        XCTAssertEqual(custom, CommandReply(text: "HYPE", delivery: .announce))

        let builtin = await dispatcher.processMessageReplyAsync("!song", userID: "1", context: context)
        XCTAssertEqual(builtin?.delivery, .reply)
        XCTAssertEqual(builtin?.text, "Artist - Song")
    }

    func testAnnounceStatusFromHTTPStatus() {
        XCTAssertEqual(AnnounceStatus.from(statusCode: 204), .ok)
        XCTAssertEqual(AnnounceStatus.from(statusCode: 401), .scopeMissing)
        XCTAssertEqual(AnnounceStatus.from(statusCode: 403), .notModerator)
        XCTAssertEqual(AnnounceStatus.from(statusCode: 500), .failed)
        XCTAssertNil(AnnounceStatus.ok.bannerMessage)
        XCTAssertNotNil(AnnounceStatus.notModerator.bannerMessage)
    }

}

@MainActor
private final class AwaitedTestCommand: @MainActor AsyncBotCommand {
    let triggers = ["!awaited"]
    let description = "Test structured async dispatch"
    let globalCooldown: TimeInterval = 0
    let userCooldown: TimeInterval = 0
    private(set) var didExecute = false

    func execute(message: String, context: BotCommandContext) async -> String? {
        await Task.yield()
        didExecute = true
        return "awaited response"
    }
}

@MainActor
private final class PrivilegedCooldownTestCommand: @MainActor ServiceBoundCommand {
    let triggers = ["!privileged-cooldown"]
    let description = "Test privileged cooldown reservation"
    let globalCooldown: TimeInterval = 60
    let userCooldown: TimeInterval = 60
    var songRequestService: (() -> SongRequestService?)?
    private(set) var executionCount = 0

    func execute(message: String, context: BotCommandContext) async -> String? {
        // Mirrors the production commands' execute-time privilege defense.
        guard context.isPrivileged else { return nil }
        executionCount += 1
        return "privileged response"
    }
}

/// Track provider whose first call parks until `release()`. Later calls answer
/// at once, so a second dispatch that wrongly reaches the provider returns a
/// reply the test can see instead of hanging.
private actor HeldTrackProvider {
    private(set) var callCount = 0
    private var parked: CheckedContinuation<Void, Never>?
    private var parkWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func next() async -> String {
        callCount += 1
        if callCount == 1, !isReleased {
            await withCheckedContinuation { continuation in
                parked = continuation
                parkWaiters.forEach { $0.resume() }
                parkWaiters.removeAll()
            }
        }
        return "Artist - Song"
    }

    /// Returns once the first call is parked inside `next()`.
    func waitUntilFirstCallParked() async {
        if parked != nil || isReleased { return }
        await withCheckedContinuation { parkWaiters.append($0) }
    }

    func release() {
        isReleased = true
        parked?.resume()
        parked = nil
    }
}
