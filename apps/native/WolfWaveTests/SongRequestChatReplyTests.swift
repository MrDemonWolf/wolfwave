//
//  SongRequestChatReplyTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-30.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation
@testable import WolfWave

/// The kind of raw text a link resolver returns on failure.
private let rawLookupFailure = "oEmbed error (HTTP 503)"

/// Chat never sees raw lookup text: a failed search or link lookup becomes a
/// plain "song search isn't working" reply for `!sr`, channel points, and Bits,
/// while an audience denial keeps its own chat-ready words. Serialized because
/// each test sets the song-request switches it needs.
@Suite("Song request chat replies", .serialized, .isolatedSharedTestState)
@MainActor
struct SongRequestChatReplyTests {

    private let viewer = BotCommandContext(
        userID: "viewer-1",
        username: "viewer",
        isModerator: false,
        isBroadcaster: false,
        isSubscriber: false,
        isVIP: false,
        messageID: "m1")

    /// A live service whose every search fails with ``rawLookupFailure``.
    private func failingService() -> SongRequestService {
        let music = MockAppleMusicController()
        music.searchProvider = { _ in .error(rawLookupFailure) }
        return SongRequestService(
            blocklist: SongBlocklist(storage: InMemoryBlocklistStorage()),
            musicController: music)
    }

    /// `!sr` wired to ``failingService()``.
    private func requestCommand() -> SongRequestCommand {
        let service = failingService()
        let command = SongRequestCommand()
        command.songRequestService = { service }
        return command
    }

    @Test("the service keeps the raw failure as a log-only error")
    func serviceKeepsRawFailure() async {
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)

        let result = await failingService().processRequest(
            query: "any song", username: "viewer", source: .chatCommand(viewer))

        guard case .error(let message) = result else {
            Issue.record("Expected .error, got \(result)")
            return
        }
        #expect(message == rawLookupFailure)
    }

    @Test("!sr answers in plain words when the lookup fails")
    func requestReplyHidesRawFailure() async {
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)

        let reply = await requestCommand().execute(message: "!sr any song", context: viewer)

        #expect(reply == SongRequestCommand.lookupFailedReply)
    }

    @Test("!sr still sends the audience denial as written")
    func requestReplyKeepsDenial() async {
        let defaults = DefaultsStore.store
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)
        defaults.set(
            RequestAudience.subscribers.rawValue,
            forKey: AppConstants.UserDefaults.songRequestChatAudience)

        let reply = await requestCommand().execute(message: "!sr any song", context: viewer)

        #expect(reply == RequestAudience.subscribers.denialMessage)
    }

    @Test("channel-point and Bits replies hide the raw failure too")
    func redemptionRepliesHideRawFailure() async {
        let twitch = TwitchChatService()

        let points = await twitch.redemptionOutcome(for: .error(rawLookupFailure), username: "viewer")
        let bits = await twitch.bitsOutcomeMessage(for: .error(rawLookupFailure), username: "viewer")

        #expect(points.message == "@viewer song search isn't working right now. Refunding your points.")
        #expect(points.resolution == .canceled)
        #expect(bits == "@viewer song search isn't working right now.")
    }
}
