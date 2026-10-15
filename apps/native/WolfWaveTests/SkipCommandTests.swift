//
//  SkipCommandTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-28.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// Covers `SkipCommand`: moderator/broadcaster gate, queue-empty reply, the
/// "now playing" handoff after a skip, and the "try again" reply when a skip
/// changed nothing.
@MainActor
final class SkipCommandTests: WolfWaveTestCase {

    // MARK: - Helpers

    /// Chat context for the broadcaster by default, or a moderator when `broadcaster` is false and
    /// `moderator` true.
    private func privilegedContext(
        broadcaster: Bool = true,
        moderator: Bool = false
    ) -> BotCommandContext {
        BotCommandContext(
            userID: "1", username: "streamer",
            isModerator: moderator, isBroadcaster: broadcaster,
            isSubscriber: false, isVIP: false, messageID: "m"
        )
    }

    /// Chat context for a plain viewer (no badges).
    private func viewerContext() -> BotCommandContext {
        BotCommandContext(
            userID: "2", username: "viewer",
            isModerator: false, isBroadcaster: false,
            isSubscriber: false, isVIP: false, messageID: "m"
        )
    }

    /// A service with an empty queue, an in-memory blocklist, and `MockAppleMusicController`.
    private func makeService() -> SongRequestService {
        SongRequestService(
            queue: SongRequestQueue(),
            blocklist: SongBlocklist(storage: InMemoryBlocklistStorage()),
            musicController: MockAppleMusicController()
        )
    }

    // MARK: - Metadata

    func testTriggers() {
        let command = SkipCommand()
        XCTAssertEqual(command.triggers, ["!skip", "!next"])
    }

    func testCooldowns() {
        let command = SkipCommand()
        XCTAssertEqual(command.globalCooldown, 3.0)
        XCTAssertEqual(command.userCooldown, 3.0)
    }

    func testEnabledKeyMatchesAppConstants() {
        let command = SkipCommand()
        XCTAssertEqual(command.enabledKey, AppConstants.UserDefaults.skipCommandEnabled)
    }

    func testAliasesKeyMatchesAppConstants() {
        let command = SkipCommand()
        XCTAssertEqual(command.aliasesKey, AppConstants.UserDefaults.skipCommandAliases)
    }

    // MARK: - Privilege Gate

    func testViewerCannotSkip() async {
        let command = SkipCommand()
        command.songRequestService = { self.makeService() }

        let reply = await command.execute(message: "!skip", context: viewerContext())
        XCTAssertNil(reply)
    }

    func testSubscriberAloneCannotSkip() async {
        let command = SkipCommand()
        command.songRequestService = { self.makeService() }
        let subscriber = BotCommandContext(
            userID: "3", username: "fan",
            isModerator: false, isBroadcaster: false,
            isSubscriber: true, isVIP: true, messageID: "m"
        )

        let reply = await command.execute(message: "!skip", context: subscriber)
        XCTAssertNil(reply)
    }

    // MARK: - Empty Queue

    func testBroadcasterSkipOnEmptyQueueReplies() async {
        let command = SkipCommand()
        command.songRequestService = { self.makeService() }

        let reply = await command.execute(message: "!skip", context: privilegedContext()) ?? ""
        XCTAssertTrue(reply.lowercased().contains("empty"))
    }

    // MARK: - Skip That Changed Nothing

    /// A failed playback command keeps the next request at the head, so the
    /// reply must not claim the queue drained.
    func testFailedPlaybackDoesNotClaimQueueIsEmpty() async {
        let queue = SongRequestQueue()
        _ = queue.add(makeTestRequestItem(title: "Current", artist: "Artist", requesterUsername: "first"))
        _ = queue.add(makeTestRequestItem(title: "Next", artist: "Artist", requesterUsername: "second"))
        queue.dequeue()
        let service = SongRequestService(
            queue: queue,
            blocklist: SongBlocklist(storage: InMemoryBlocklistStorage()),
            musicController: MockAppleMusicController(),
            playbackOverride: { _ in
                throw PlaybackError.commandFailed(command: "playNow", message: "timed out")
            }
        )
        let command = SkipCommand()
        command.songRequestService = { service }

        let reply = await command.execute(message: "!skip", context: privilegedContext()) ?? ""

        XCTAssertFalse(reply.lowercased().contains("empty"), "Got: \(reply)")
        XCTAssertEqual(reply, "Couldn't skip right now, try again.")
        XCTAssertEqual(queue.items.map(\.title), ["Next"])
    }

    func testReplyForEachOutcome() {
        let item = makeTestRequestItem(title: "Song", artist: "Band", requesterUsername: "fan")
        XCTAssertEqual(
            SkipCommand.reply(for: .started(item)),
            "Skipped. Now playing: \"Song\" by Band (requested by fan)")
        XCTAssertEqual(SkipCommand.reply(for: .drained), "Skipped. Queue is now empty.")
        XCTAssertEqual(SkipCommand.reply(for: .busy), "Couldn't skip right now, try again.")
        XCTAssertEqual(SkipCommand.reply(for: .retained), "Couldn't skip right now, try again.")
    }

    // MARK: - Missing Service

    func testMissingServiceIsSilent() async {
        let command = SkipCommand()
        command.songRequestService = { nil }

        let reply = await command.execute(message: "!skip", context: privilegedContext())
        XCTAssertNil(reply)
    }
}
