//
//  StatsCommandTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-22.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation
@testable import WolfWave

/// Tests for the `!stats` Twitch command: trigger matching, the enabled gate
/// (which folds in stream-live state), and dispatcher routing.
@MainActor
@Suite("Stats Command Tests")
struct StatsCommandTests {

    // MARK: - Helpers

    /// A dispatcher with `!stats` wired to fixed info + enabled closures, through
    /// the async provider production uses.
    private func makeDispatcher(
        info: @escaping @Sendable () -> String,
        enabled: @escaping () -> Bool
    ) -> BotCommandDispatcher {
        let dispatcher = BotCommandDispatcher()
        dispatcher.setStatsInfoAsync { info() }
        dispatcher.setStatsCommandEnabled(callback: enabled)
        return dispatcher
    }

    // MARK: - Tests

    @Test("!stats replies with the stats string when enabled and live")
    func testRepliesWhenEnabled() async {
        let dispatcher = makeDispatcher(
            info: { "🐺 Today: 47 plays" },
            enabled: { true }
        )
        let reply = await dispatcher.processMessageAsync("!stats", userID: "u1", context: nil)
        #expect(reply == "🐺 Today: 47 plays")
    }

    @Test("!stats stays silent when the gate is closed (offline or disabled)")
    func testSilentWhenDisabled() async {
        let dispatcher = makeDispatcher(
            info: { "🐺 Today: 47 plays" },
            enabled: { false }
        )
        let reply = await dispatcher.processMessageAsync("!stats", userID: "u1", context: nil)
        #expect(reply == nil)
    }

    @Test("The !musicstats alias also works")
    func testAliasTrigger() async {
        let dispatcher = makeDispatcher(
            info: { "🐺 stats here" },
            enabled: { true }
        )
        #expect(await dispatcher.processMessageAsync("!musicstats", userID: "u1", context: nil) == "🐺 stats here")
    }

    @Test("Unrelated messages do not trigger !stats")
    func testNoFalseTrigger() async {
        let dispatcher = makeDispatcher(
            info: { "🐺 stats here" },
            enabled: { true }
        )
        #expect(await dispatcher.processMessageAsync("just chatting", userID: "u1", context: nil) == nil)
        #expect(await dispatcher.processMessageAsync("!song", userID: "u1", context: nil) != "🐺 stats here")
    }

    @Test("A very long stats string is truncated for chat")
    func testTruncation() async {
        let long = String(repeating: "x", count: 800)
        let dispatcher = makeDispatcher(info: { long }, enabled: { true })
        let reply = await dispatcher.processMessageAsync("!stats", userID: "u1", context: nil)
        #expect((reply?.count ?? 0) <= AppConstants.Twitch.maxMessageLength)
    }
}
