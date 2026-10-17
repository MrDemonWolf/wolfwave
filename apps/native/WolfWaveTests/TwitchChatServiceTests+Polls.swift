//
//  TwitchChatServiceTests+Polls.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation

@testable import WolfWave

/// Twitch Polls: create-poll outcomes, scope validation, and live subscription.
extension TwitchChatServiceTests {
    @Test("Enabling polls live subscribes the current session exactly once")
    func testLivePollEnableSubscribesCurrentSessionIdempotently() async {
        let defaults = DefaultsStore.store
        defer {
            defaults.removeObject(forKey: AppConstants.UserDefaults.voteSkipEnabled)
            defaults.removeObject(forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        }
        defaults.set(true, forKey: AppConstants.UserDefaults.voteSkipEnabled)
        defaults.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let subscriptions = PollSubscriptionGate()
        let service = TwitchChatService()
        await service.configurePollRefreshTestState(
            sessionID: "session-live",
            scopeValidation: { .present },
            subscription: { sessionID in
                await subscriptions.subscribe(sessionID: sessionID)
            })

        let first = Task {
            await service.refreshPollSubscriptionIfNeeded(enabled: true)
        }
        await subscriptions.waitUntilStarted()
        let overlapping = Task {
            await service.refreshPollSubscriptionIfNeeded(enabled: true)
        }
        await overlapping.value
        await subscriptions.release()
        await first.value
        await service.refreshPollSubscriptionIfNeeded(enabled: true)

        #expect(await subscriptions.subscribedSessions() == ["session-live"])
        #expect(await service.pollSubscriptionSessionForTesting() == "session-live")
    }

    @Test("Poll subscription in flight during migration retries on the target session")
    func testInFlightPollSubscriptionRetriesAfterMigration() async throws {
        let defaults = DefaultsStore.store
        defer {
            defaults.removeObject(forKey: AppConstants.UserDefaults.voteSkipEnabled)
            defaults.removeObject(forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        }
        defaults.set(true, forKey: AppConstants.UserDefaults.voteSkipEnabled)
        defaults.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let source = session.webSocketTask(
            with: try #require(URL(string: "wss://eventsub.wss.twitch.tv/source")))
        let target = session.webSocketTask(
            with: try #require(URL(string: "wss://eventsub.wss.twitch.tv/target")))
        let sourceGate = DeterministicAsyncGate()
        let subscribedSessions = ThreadSafeBox<[String]>([])
        let service = TwitchChatService(
            eventSubWebSocketFactory: { _ in target },
            eventSubWebSocketResume: { _ in },
            eventSubWebSocketReceive: { _ in
                try await Task.sleep(for: .seconds(3_600))
                throw CancellationError()
            }
        )
        let sourceContext = await service.installPollMigrationSourceForTesting(source)
        await service.configurePollRefreshTestState(
            sessionID: "source-session",
            scopeValidation: { .present },
            subscription: { sessionID in
                subscribedSessions.mutate { $0.append(sessionID) }
                if sessionID == "source-session" {
                    await sourceGate.suspend()
                }
                return true
            })

        let sourceAttempt = Task {
            await service.refreshPollSubscriptionIfNeeded(enabled: true)
        }
        #expect(await waitUntil { await sourceGate.suspended })

        let reconnect = try Self.eventSubEnvelope(
            messageType: "session_reconnect",
            messageID: "poll-migration-reconnect",
            payload: [
                "session": [
                    "id": "source-session",
                    "reconnect_url": "wss://eventsub.wss.twitch.tv/target"
                ]
            ])
        await service.handleWebSocketMessage(reconnect, receiveContext: sourceContext)

        let targetContext = await service.pollMigrationContextForTesting(target)
        let welcome = try Self.eventSubEnvelope(
            messageType: "session_welcome",
            messageID: "poll-migration-welcome",
            payload: [
                "session": [
                    "id": "target-session",
                    "keepalive_timeout_seconds": 10
                ]
            ])
        await service.handleWebSocketMessage(welcome, receiveContext: targetContext)
        await sourceGate.resume()
        await sourceAttempt.value

        #expect(subscribedSessions.value == ["source-session", "target-session"])
        #expect(await service.pollSubscriptionSessionForTesting() == "target-session")
        await service.disconnectFromEventSub()
    }

    @Test("Missing polls scope requests reauthorization without subscribing")
    func testLivePollEnableMissingScopeSignalsReauthorization() async {
        // `twitchReauthNeeded` is a process-global default that parallel suites
        // also write, so the assertion below only holds under the shared
        // credential-state lock.
        await SharedTestStateIsolation.withIsolatedSharedState {
            let defaults = DefaultsStore.store
            defer {
                defaults.removeObject(forKey: AppConstants.UserDefaults.voteSkipEnabled)
                defaults.removeObject(forKey: AppConstants.UserDefaults.voteSkipUsePolls)
            }
            defaults.set(true, forKey: AppConstants.UserDefaults.voteSkipEnabled)
            defaults.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
            let subscriptionCount = ThreadSafeBox(0)
            let service = TwitchChatService()
            await service.configurePollRefreshTestState(
                sessionID: "session-missing-scope",
                scopeValidation: { .missing },
                subscription: { _ in
                    subscriptionCount.mutate { $0 += 1 }
                    return true
                })

            await service.refreshPollSubscriptionIfNeeded(enabled: true)

            #expect(Preferences.twitchReauthNeeded)
            #expect(subscriptionCount.value == 0)
            #expect(await service.pollSubscriptionSessionForTesting() == nil)
        }
    }

    @Test("Poll-end parser preserves ID and rejects missing identity")
    func testSkipPollEndParsing() {
        let choices: [[String: Any]] = [
            ["title": TwitchChatService.skipPollSkipChoice, "votes": 7],
            ["title": TwitchChatService.skipPollKeepChoice, "votes": 2]
        ]
        let valid: [String: Any] = [
            "event": [
                "id": "poll-123",
                "title": TwitchChatService.skipPollTitle,
                "choices": choices
            ]
        ]
        let result = TwitchChatService.skipPollResult(from: valid)

        #expect(result?.pollID == "poll-123")
        #expect(result?.skipVotes == 7)
        #expect(result?.keepVotes == 2)

        let missingID: [String: Any] = [
            "event": [
                "title": TwitchChatService.skipPollTitle,
                "choices": choices
            ]
        ]
        #expect(TwitchChatService.skipPollResult(from: missingID) == nil)
    }

    @Test("Only a second 401 after token refresh requires re-authentication")
    func testRefreshedReconnectFailureDisposition() {
        #expect(TwitchChatService.refreshedReconnectFailureDisposition(
            for: TwitchChatService.ConnectionError.authenticationFailed
        ) == .authenticationFailure)
        #expect(TwitchChatService.refreshedReconnectFailureDisposition(
            for: CancellationError()
        ) == .cancelled)
        #expect(TwitchChatService.refreshedReconnectFailureDisposition(
            for: TwitchChatService.ConnectionError.networkError("offline")
        ) == .retryableFailure)
        #expect(TwitchChatService.refreshedReconnectFailureDisposition(
            for: TwitchChatService.ConnectionError.invalidCredentials
        ) == .retryableFailure)
    }
}
