//
//  SongRequestGatedCommandTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-30.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation
@testable import WolfWave

/// The queue commands (`!queue`, `!myqueue`, `!skip`, `!clearqueue`, `!hold`)
/// go silent while the Song Requests master switch is off, so a moderator's
/// `!skip` can't start the fallback playlist for a feature the streamer turned
/// off. Serialized because each test sets the switch it needs.
@Suite("Song request commands follow the master switch", .serialized, .isolatedSharedTestState)
@MainActor
struct SongRequestGatedCommandTests {

    /// The gated commands, named by their first trigger.
    enum Gated: String, CaseIterable, Sendable {
        case queue = "!queue"
        case myQueue = "!myqueue"
        case skip = "!skip"
        case clearQueue = "!clearqueue"
        case hold = "!hold"

        /// A fresh instance. Commands aren't `Sendable`, so tests take the case.
        @MainActor
        func makeCommand() -> any SongRequestGatedCommand {
            switch self {
            case .queue: QueueCommand()
            case .myQueue: MyQueueCommand()
            case .skip: SkipCommand()
            case .clearQueue: ClearQueueCommand()
            case .hold: HoldCommand()
            }
        }
    }

    /// A moderator, so the mod-only commands are past `isAllowed`.
    private let moderator = BotCommandContext(
        userID: "mod-1",
        username: "mod",
        isModerator: true,
        isBroadcaster: false,
        isSubscriber: false,
        isVIP: false,
        messageID: "m1")

    @Test("each one refuses silently while song requests are off", arguments: Gated.allCases)
    func refusesWhileOff(_ gated: Gated) {
        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.songRequestEnabled)
        #expect(gated.makeCommand().preflightDenial(context: moderator) == .silent)
    }

    /// The "requests are off" reply is an `!sr` setting; these stay quiet.
    @Test("the requests-off reply setting doesn't make them answer", arguments: Gated.allCases)
    func staysSilentWithOffReplyOn(_ gated: Gated) {
        let defaults = DefaultsStore.store
        defaults.set(false, forKey: AppConstants.UserDefaults.songRequestEnabled)
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestDisabledReplyEnabled)
        #expect(gated.makeCommand().preflightDenial(context: moderator) == .silent)
    }

    @Test("each one proceeds while song requests are on", arguments: Gated.allCases)
    func proceedsWhileOn(_ gated: Gated) {
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)
        #expect(gated.makeCommand().preflightDenial(context: moderator) == nil)
    }

    /// Through the real dispatcher: the refusal neither answers nor claims the
    /// cooldown, so the same viewer gets an answer the moment requests are on.
    @Test("the dispatcher drops !queue while off without claiming its cooldown")
    func dispatcherDropsQueueWhileOff() async {
        let defaults = DefaultsStore.store
        let dispatcher = BotCommandDispatcher()
        let queue = SongRequestQueue()
        dispatcher.setSongRequestQueue { queue }
        let viewer = BotCommandContext(
            userID: "viewer-1",
            username: "viewer",
            isModerator: false,
            isBroadcaster: false,
            isSubscriber: false,
            isVIP: false,
            messageID: "m2")

        defaults.set(false, forKey: AppConstants.UserDefaults.songRequestEnabled)
        let whileOff = await dispatcher.processMessageAsync("!queue", userID: viewer.userID, context: viewer)
        #expect(whileOff == nil)

        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)
        let whileOn = await dispatcher.processMessageAsync("!queue", userID: viewer.userID, context: viewer)
        #expect(whileOn == "Queue is empty. Request a song with !sr <song name>")
    }
}
