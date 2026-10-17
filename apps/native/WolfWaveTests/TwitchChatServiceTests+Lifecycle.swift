//
//  TwitchChatServiceTests+Lifecycle.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation

@testable import WolfWave

/// Command dispatch, keepalive, reconnect budgets, network path changes, and suspended commands.
extension TwitchChatServiceTests {
    @Test("First non-whitespace character must be an exclamation for command dispatch")
    func testPotentialCommandPrefilter() {
        #expect(TwitchChatService.isPotentialCommand("!song"))
        #expect(TwitchChatService.isPotentialCommand("!custom argument"))
        #expect(TwitchChatService.isPotentialCommand("  !song"))
        #expect(TwitchChatService.isPotentialCommand("\t!song"))
        #expect(!TwitchChatService.isPotentialCommand("hello chat"))
        #expect(!TwitchChatService.isPotentialCommand("   "))
        #expect(!TwitchChatService.isPotentialCommand(""))
    }

    @Test("Inbound frames reuse one keepalive watchdog task")
    func testKeepaliveResetDoesNotRecreateTask() async {
        let service = TwitchChatService()
        await service.armKeepaliveWatchdog(deadlineSeconds: 60)
        for _ in 0..<100 {
            await service.resetKeepaliveWatchdog()
        }

        #expect(await service.keepaliveWatchdogTaskStarts == 1)
        await service.disconnectFromEventSub()
        #expect(await service.lastKeepaliveActivity == nil)
    }

    @Test("A stale keepalive expiry cannot tear down a rearmed session")
    func testStaleKeepaliveExpiryAfterRearmIsIgnored() async {
        let service = TwitchChatService()
        await service.armKeepaliveWatchdog(deadlineSeconds: 60)
        let staleGeneration = await service.keepaliveGeneration

        await service.disconnectFromEventSub()
        await service.armKeepaliveWatchdog(deadlineSeconds: 60)
        let activeGeneration = await service.keepaliveGeneration

        let staleTaskShouldStop = await service.handleKeepaliveExpiry(
            generation: staleGeneration,
            at: ContinuousClock().now.advanced(by: .seconds(3_600)))

        #expect(staleTaskShouldStop)
        #expect(await service.keepaliveGeneration == activeGeneration)
        #expect(await service.lastKeepaliveActivity != nil)
        await service.disconnectFromEventSub()
    }

    @Test("Leaving invalidates an in-flight connection intent")
    func testLeaveInvalidatesConnectionAttempt() async {
        let service = TwitchChatService()
        let generation = await service.beginConnectionAttempt()
        #expect(await service.connectionAttemptIsCurrent(generation))

        await service.leaveChannel()

        #expect(!(await service.connectionAttemptIsCurrent(generation)))
    }

    @Test("A new logical connection attempt retires the previous transport")
    func testNewConnectionAttemptRetiresPreviousTransport() async {
        let service = TwitchChatService(
            eventSubWebSocketFactory: { url in
                URLSession(configuration: .ephemeral).webSocketTask(with: url)
            },
            eventSubWebSocketResume: { _ in }
        )

        await service.connectToEventSub()
        #expect(await service.hasEventSubTransportForTesting)

        _ = await service.beginConnectionAttempt()

        #expect(!(await service.hasEventSubTransportForTesting))
    }

    @Test("session_welcome is the event that resets reconnect attempts")
    func testSessionWelcomeResetsReconnectAttempts() async throws {
        let service = TwitchChatService()
        await service.configureReconnectStateForTesting(attempts: 3, migrating: true)

        let message: [String: Any] = [
            "metadata": [
                "message_type": "session_welcome",
                "message_id": "welcome-reset-test",
                "message_timestamp": ISO8601DateFormatter().string(from: Date())
            ],
            "payload": [
                "session": [
                    "id": "test-session",
                    "keepalive_timeout_seconds": 60
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: message)
        let text = String(decoding: data, as: UTF8.self)
        await service.handleWebSocketMessage(text)

        #expect(await service.reconnectionAttempts == 0)
        await service.disconnectFromEventSub()
    }

    @Test("Network loss broadcasts disconnected to stream consumers")
    func testNetworkLossBroadcastsDisconnected() async {
        let service = TwitchChatService()
        let stream = service.connectionStateChanges()
        let received = Task {
            await collectFirst(1, from: stream)?.first
        }

        await service.setConnected(true)
        await service.handleNetworkReachabilityChange(false)

        let disconnected = await received.value
        #expect(disconnected == false)
    }

    @Test("Network loss cancels a delayed reconnect")
    func testNetworkLossCancelsScheduledReconnect() async {
        let service = TwitchChatService()
        await service.configureReconnectCredentialsForTesting()
        await service.scheduleReconnect()
        #expect(await service.hasScheduledReconnectForTesting)

        await service.handleNetworkReachabilityChange(false)

        #expect(!(await service.hasScheduledReconnectForTesting))
    }

    @Test("Accepted network recovery starts a fresh bounded attempt cycle")
    func testNetworkRecoveryResetsExhaustedAttempts() async {
        let service = TwitchChatService()
        await service.configureNetworkRecoveryForTesting(
            attempts: AppConstants.Twitch.maxReconnectionAttempts)

        await service.handleNetworkReachabilityChange(true)

        #expect(await service.reconnectionAttempts == 0)
        #expect(await service.networkReconnectCycles == 1)
    }

    @Test("Path updates are applied in the order the monitor reported them")
    func testNetworkPathUpdatesApplyInOrder() async {
        let service = TwitchChatService()
        await service.configureReconnectCredentialsForTesting()
        await service.configureNetworkRecoveryForTesting(attempts: 0)
        let path = await service.startNetworkPathConsumerForTesting()

        // A fast flap that ends reachable: two offline→online edges.
        path.yield(true)
        path.yield(false)
        path.yield(true)
        path.finish()
        await service.networkPathTask?.value

        #expect(await service.isNetworkReachable)
        #expect(await service.networkReconnectCycles == 2)
        #expect(await service.hasScheduledReconnectForTesting)
        await service.handleNetworkReachabilityChange(false)
    }

    @Test("Exhausted fast reconnect budget enters the slow tier")
    func reconnectEntersSlowTierAfterFastBudget() async {
        let service = TwitchChatService()
        await service.configureReconnectCredentialsForTesting()
        await service.configureExhaustedReconnectForTesting()
        await service.scheduleReconnect()
        #expect(await service.hasScheduledReconnectForTesting)
        #expect(await service.reconnectionAttempts == AppConstants.Twitch.maxReconnectionAttempts)
        await service.handleNetworkReachabilityChange(false)
    }

    @Test("System wake resets the reconnect budget")
    func wakeResetsReconnectBudget() async {
        let service = TwitchChatService()
        await service.configureReconnectCredentialsForTesting()
        await service.configureExhaustedReconnectForTesting()
        await service.handleSystemWake()
        #expect(await service.reconnectionAttempts == 0)
        #expect(await service.hasScheduledReconnectForTesting)
        await service.handleNetworkReachabilityChange(false)
    }

    @Test("Leaving cancels and clears the pending message retry lifecycle")
    func testLeaveClearsPendingMessageRetry() async {
        handlerStore.handler = { request in
            (MockURLProtocol.httpResponse(for: request, status: 503), Data())
        }
        defer { handlerStore.handler = nil }
        let networkedService = TwitchChatService(
            helixHTTPClient: HTTPClient(session: MockURLProtocol.makeSession(handlerStore: handlerStore)))
        _ = await networkedService.configureChatSendForTesting(broadcasterID: "channel")

        await networkedService.sendMessage("queued reply")
        #expect(await networkedService.hasPendingMessageRetry)

        await networkedService.leaveChannel()
        #expect(!(await networkedService.hasPendingMessageRetry))
        #expect(await networkedService.pendingMessageCount == 0)
    }

    @Test("A suspended command does not block EventSub and reconnect cancels it")
    func testTrackedCommandDoesNotBlockReceiveAndCancelsOnReconnect() async {
        let service = TwitchChatService()
        let gate = SuspendedCommandGate()
        service.commandDispatcher.register(SuspendedTestCommand(gate: gate))
        let generation = await service.configureCommandSessionForTesting(
            broadcasterID: "channel-1")

        await service.handleEventSubMessage(Self.chatEvent(
            id: "command-message", text: "!suspend", broadcasterID: "channel-1"))

        #expect(await waitUntil { await gate.started })
        #expect(await service.activeCommandTaskCount == 1)

        // A later event must be parsed and yielded while the command remains
        // suspended; the WebSocket receive task must not await command work.
        await service.handleEventSubMessage(Self.chatEvent(
            id: "later-message", text: "still responsive", broadcasterID: "channel-1"))
        let messages = await collectFirst(2, from: service.chatMessages)
        #expect(messages?.map(\.messageID) == ["command-message", "later-message"])

        _ = await service.beginConnectionAttempt()
        #expect(await waitUntil { await gate.wasCancelled })
        #expect(await waitUntil { await service.activeCommandTaskCount == 0 })
        #expect(!(await service.commandReplyIsCurrent(
            generation: generation, broadcasterID: "channel-1")))
        #expect(await service.pendingMessageCount == 0)
    }

    @Test("Duplicate command IDs start only one asynchronous command")
    func testDuplicateCommandIDStartsOneTask() async {
        let service = TwitchChatService()
        let gate = SuspendedCommandGate()
        service.commandDispatcher.register(SuspendedTestCommand(gate: gate))
        _ = await service.configureCommandSessionForTesting(
            broadcasterID: "channel-1")

        await service.handleEventSubMessage(Self.chatEvent(
            id: "duplicate-command",
            text: "!suspend",
            broadcasterID: "channel-1"))
        #expect(await waitUntil { await gate.started })

        await service.handleEventSubMessage(Self.chatEvent(
            id: "duplicate-command",
            text: "!suspend",
            broadcasterID: "channel-1"))
        await Task.yield()
        #expect(await service.activeCommandTaskCount == 1)

        _ = await service.beginConnectionAttempt()
        #expect(await waitUntil { await gate.wasCancelled })
    }

    @Test("A command seen while disabled cannot execute from delayed redelivery")
    func testDisabledCommandIDIsStillReserved() async {
        let service = TwitchChatService()
        let gate = SuspendedCommandGate()
        service.commandDispatcher.register(SuspendedTestCommand(gate: gate))
        _ = await service.configureCommandSessionForTesting(
            broadcasterID: "channel-1")
        await service.setCommandsEnabledForTesting(false)
        await service.handleEventSubMessage(Self.chatEvent(
            id: "disabled-command",
            text: "!suspend",
            broadcasterID: "channel-1"))
        await service.setCommandsEnabledForTesting(true)
        await service.handleEventSubMessage(Self.chatEvent(
            id: "disabled-command",
            text: "!suspend",
            broadcasterID: "channel-1"))
        await Task.yield()

        #expect(!(await gate.started))
        #expect(await service.activeCommandTaskCount == 0)
    }

    /// A `channel.chat.message` event from "Viewer" with the given id, text, and broadcaster.
    nonisolated private static func chatEvent(
        id: String,
        text: String,
        broadcasterID: String
    ) -> [String: Any] {
        [
            "event": [
                "message_id": id,
                "chatter_user_name": "Viewer",
                "chatter_user_login": "viewer",
                "chatter_user_id": "viewer-1",
                "broadcaster_user_id": broadcasterID,
                "message": ["text": text],
                "badges": []
            ]
        ]
    }

    @Test("Requester limits use login across localized display names")
    func limitsKeyedOnLoginNotDisplayName() async {
        let defaults = DefaultsStore.store
        let keys = [
            AppConstants.UserDefaults.songRequestEnabled,
            AppConstants.UserDefaults.songRequestHoldEnabled,
            AppConstants.UserDefaults.songRequestPerUserLimit,
            AppConstants.UserDefaults.songRequestGlobalCooldown,
            AppConstants.UserDefaults.songRequestUserCooldown,
            AppConstants.UserDefaults.srCommandEnabled
        ]
        defer { keys.forEach { defaults.removeObject(forKey: $0) } }
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestHoldEnabled)
        defaults.set(true, forKey: AppConstants.UserDefaults.srCommandEnabled)
        defaults.set(1, forKey: AppConstants.UserDefaults.songRequestPerUserLimit)
        defaults.set(0, forKey: AppConstants.UserDefaults.songRequestGlobalCooldown)
        defaults.set(0, forKey: AppConstants.UserDefaults.songRequestUserCooldown)
        let music = MockAppleMusicController()
        music.stubSearchSuccess()
        let requests = SongRequestService(musicController: music)
        let service = TwitchChatService()
        service.commandDispatcher.setSongRequestService(callback: { requests })
        _ = await service.configureCommandSessionForTesting(broadcasterID: "channel")
        for (index, displayName) in ["視聴者", "Viewer Renamed"].enumerated() {
            await service.handleEventSubMessage([
                "event": [
                    "message_id": "identity-\(index)", "chatter_user_name": displayName,
                    "chatter_user_login": "viewer", "chatter_user_id": "viewer-1",
                    "broadcaster_user_id": "channel", "message": ["text": "!sr song-\(index)"],
                    "badges": []
                ]
            ])
            #expect(await waitUntil { await service.activeCommandTaskCount == 0 })
        }
        #expect(requests.queue.items.count == 1)
        #expect(requests.queue.items.first?.requesterUsername == "viewer")
        await service.leaveChannel()
    }
}
