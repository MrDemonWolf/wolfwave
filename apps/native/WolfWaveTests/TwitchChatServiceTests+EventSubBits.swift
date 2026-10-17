//
//  TwitchChatServiceTests+EventSubBits.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation

@testable import WolfWave

/// EventSub reconnect and quiesce behavior, and Bits event handling.
extension TwitchChatServiceTests {
    // MARK: - Initialization Tests

    @Test("EventSub 409 deletes the exact stale subscription and retries POST once")
    func testEventSubConflictRecovery() async {
        let requests = ThreadSafeBox<[URLRequest]>([])
        let requestNumber = ThreadSafeBox(0)
        handlerStore.handler = { request in
            requests.mutate { $0.append(request) }
            let number = requestNumber.value
            requestNumber.value = number + 1
            switch number {
            case 0:
                return (
                    MockURLProtocol.httpResponse(for: request, status: 409),
                    Data(#"{"id":"stale-subscription"}"#.utf8))
            case 1:
                return (MockURLProtocol.httpResponse(for: request, status: 204), Data())
            default:
                return (
                    MockURLProtocol.httpResponse(for: request, status: 202),
                    Data(#"{"data":[{"id":"replacement"}]}"#.utf8))
            }
        }
        defer { handlerStore.handler = nil }

        let service = TwitchChatService(
            eventSubHTTPClient: HTTPClient(session: MockURLProtocol.makeSession(handlerStore: handlerStore)))
        let success = ThreadSafeBox(false)
        let onSuccess: @Sendable () -> Void = { success.value = true }
        let subscribed = await service.postEventSubSubscription(
            body: ["type": "channel.chat.message"],
            token: "token",
            clientID: "client",
            label: "chat messages",
            onSuccess: onSuccess)

        #expect(subscribed)
        #expect(success.value)
        #expect(requests.value.map(\.httpMethod) == ["POST", "DELETE", "POST"])
        #expect(
            requests.value[1].url?.query?.contains("id=stale-subscription") == true)
    }

    @Test("EventSub 409 without a subscription ID fails instead of claiming success")
    func testEventSubConflictWithoutIDFailsClosed() async {
        let count = ThreadSafeBox(0)
        handlerStore.handler = { request in
            count.mutate { $0 += 1 }
            return (
                MockURLProtocol.httpResponse(for: request, status: 409),
                Data(#"{"error":"Conflict","status":409}"#.utf8))
        }
        defer { handlerStore.handler = nil }

        let service = TwitchChatService(
            eventSubHTTPClient: HTTPClient(session: MockURLProtocol.makeSession(handlerStore: handlerStore)))
        let subscribed = await service.postEventSubSubscription(
            body: ["type": "channel.chat.message"],
            token: "token",
            clientID: "client",
            label: "chat messages")

        #expect(!subscribed)
        #expect(count.value == 1)
    }

    @Test("Suspended connection greeting cannot queue into a replacement channel")
    func testConnectionGreetingIsGenerationScoped() async {
        let requestStarted = DispatchSemaphore(value: 0)
        let releaseRequest = DispatchSemaphore(value: 0)
        let handler: MockURLProtocol.Handler = { request in
            requestStarted.signal()
            _ = releaseRequest.wait(timeout: .now() + 2)
            return (MockURLProtocol.httpResponse(for: request, status: 503), Data())
        }
        defer { handlerStore.handler = nil }

        let service = TwitchChatService(
            helixHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession(handler: handler)))
        let generation = await service.configureChatSendForTesting(
            broadcasterID: "old-channel")
        let greeting = Task {
            await service.sendConnectionMessageIfNeeded(
                generation: generation,
                broadcasterID: "old-channel")
        }

        let started = await waitForSemaphore(
            requestStarted,
            timeout: .now() + 2
        )
        #expect(started)
        _ = await service.beginConnectionAttempt()
        await service.switchBroadcasterForTesting(to: "new-channel")
        releaseRequest.signal()
        await greeting.value

        #expect(await service.pendingMessageCount == 0)
    }

    @Test("Canceled generic chat send never enters the retry queue")
    func testCanceledGenericSendDoesNotQueue() async {
        let requestStarted = DispatchSemaphore(value: 0)
        let releaseRequest = DispatchSemaphore(value: 0)
        let handler: MockURLProtocol.Handler = { request in
            requestStarted.signal()
            _ = releaseRequest.wait(timeout: .now() + 2)
            return (MockURLProtocol.httpResponse(for: request, status: 503), Data())
        }
        defer { handlerStore.handler = nil }

        let service = TwitchChatService(
            helixHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession(handler: handler)))
        _ = await service.configureChatSendForTesting(broadcasterID: "channel")
        let send = Task { await service.sendMessage("hello") }
        let started = await waitForSemaphore(
            requestStarted,
            timeout: .now() + 2
        )
        #expect(started)
        send.cancel()
        releaseRequest.signal()
        await send.value

        #expect(await service.pendingMessageCount == 0)
    }

    @Test("Bits processing survives an EventSub reconnect and only suppresses stale chat")
    func testBitsProcessingSurvivesReconnect() async {
        let directory = makeIsolatedTempDirectory(prefix: "bits-reconnect")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"))
        let gate = DeterministicAsyncGate()
        let searches = ThreadSafeBox(0)
        let music = MockAppleMusicController()
        music.searchProvider = { _ in
            searches.mutate { $0 += 1 }
            await gate.suspend()
            return .notFound
        }
        let requests = SongRequestService(musicController: music)
        let service = TwitchChatService(redemptionResolutionOutbox: outbox)

        let defaults = DefaultsStore.store
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestBitsEnabled)
        defaults.set(1, forKey: AppConstants.UserDefaults.songRequestBitsMinimum)
        defer {
            defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestEnabled)
            defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestBitsEnabled)
            defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestBitsMinimum)
        }

        _ = await service.configureChatSendForTesting(broadcasterID: "channel")
        await service.setSongRequestServiceReference(requests)
        await service.handleBitsUse(
            [
                "event": [
                    "type": "cheer",
                    "bits": 100,
                    "broadcaster_user_id": "channel",
                    "user_name": "Viewer",
                    "message": ["text": "Cheer100 a song"]
                ]
            ],
            eventSubMessageID: "bits-reconnect")

        #expect(await waitUntil { await gate.suspended })
        #expect(await service.activePaidRedemptionTaskCount == 1)
        _ = await service.beginConnectionAttempt()
        await gate.resume()
        #expect(await waitUntil { await service.activePaidRedemptionTaskCount == 0 })
        #expect(searches.value == 1)
        #expect(await service.pendingMessageCount == 0)
    }

    @Test("Durable Bits completion survives EventSub cache eviction and relaunch")
    func testBitsCompletionSurvivesDedupEvictionAndRelaunch() async throws {
        let directory = makeIsolatedTempDirectory(prefix: "bits-durable-dedup")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "outbox.json")
        let searches = ThreadSafeBox(0)
        let music = MockAppleMusicController()
        music.searchProvider = { _ in
            searches.mutate { $0 += 1 }
            return .notFound
        }
        let requests = SongRequestService(musicController: music)
        let chatHandler: MockURLProtocol.Handler = { request in
            (
                MockURLProtocol.httpResponse(for: request, status: 200),
                Data(#"{"data":[{"is_sent":true}]}"#.utf8)
            )
        }
        let chatClient = HTTPClient(
            session: MockURLProtocol.makeSession(handler: chatHandler))
        let defaults = DefaultsStore.store
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestBitsEnabled)
        defaults.set(1, forKey: AppConstants.UserDefaults.songRequestBitsMinimum)
        defer {
            defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestEnabled)
            defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestBitsEnabled)
            defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestBitsMinimum)
        }

        let paidEnvelope = try Self.eventSubEnvelope(
            messageType: "notification",
            messageID: "durable-paid-message",
            payload: [
                "subscription": [
                    "type": AppConstants.Twitch.eventSubBitsUse
                ],
                "event": [
                    "type": "cheer",
                    "bits": 100,
                    "broadcaster_user_id": "channel",
                    "user_name": "Viewer",
                    "message": ["text": "Cheer100 a song"]
                ]
            ])
        let firstOutbox = TwitchRedemptionResolutionOutbox(fileURL: file)
        let firstService = TwitchChatService(
            helixHTTPClient: chatClient,
            redemptionResolutionOutbox: firstOutbox)
        _ = await firstService.configureChatSendForTesting(
            broadcasterID: "channel")
        await firstService.setSongRequestServiceReference(requests)

        await firstService.handleWebSocketMessage(paidEnvelope)
        await firstService.awaitPaidRedemptionTasksForTesting()
        #expect(searches.value == 1)
        #expect(firstOutbox.pendingBitsItems().isEmpty)

        // The transport cache holds 500 IDs; overflow it so only the durable
        // terminal record can suppress the late at-least-once delivery.
        for index in 0..<500 {
            await firstService.handleWebSocketMessage(
                try Self.eventSubEnvelope(
                    messageType: "session_keepalive",
                    messageID: "cache-fill-\(index)",
                    payload: [:]))
        }
        await firstService.handleWebSocketMessage(paidEnvelope)
        await firstService.awaitPaidRedemptionTasksForTesting()
        #expect(searches.value == 1)

        let relaunchedOutbox = TwitchRedemptionResolutionOutbox(fileURL: file)
        let relaunchedService = TwitchChatService(
            helixHTTPClient: chatClient,
            redemptionResolutionOutbox: relaunchedOutbox)
        _ = await relaunchedService.configureChatSendForTesting(
            broadcasterID: "channel")
        await relaunchedService.setSongRequestServiceReference(requests)
        await relaunchedService.handleWebSocketMessage(paidEnvelope)
        await relaunchedService.awaitPaidRedemptionTasksForTesting()

        #expect(searches.value == 1)
        #expect(relaunchedOutbox.pendingBitsItems().isEmpty)
    }

    #if DEBUG
    @Test("Leave drains a paid frame already returned at the receive boundary")
    func testLeaveDrainsPaidFrameAtReceiveBoundary() async throws {
        let directory = makeIsolatedTempDirectory(prefix: "bits-leave-boundary")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"))
        let searches = ThreadSafeBox(0)
        let receiveCalls = ThreadSafeBox(0)
        let receiveGate = DeterministicAsyncGate()
        let music = MockAppleMusicController()
        music.searchProvider = { _ in
            searches.mutate { $0 += 1 }
            return .notFound
        }
        let requests = SongRequestService(musicController: music)
        let paidEnvelope = try Self.eventSubEnvelope(
            messageType: "notification",
            messageID: "leave-boundary-paid-message",
            payload: [
                "subscription": [
                    "type": AppConstants.Twitch.eventSubBitsUse
                ],
                "event": [
                    "type": "cheer",
                    "bits": 100,
                    "broadcaster_user_id": "channel",
                    "user_name": "Viewer",
                    "message": ["text": "Cheer100 a song"]
                ]
            ])
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let socket = session.webSocketTask(
            with: try #require(URL(string: "wss://eventsub.wss.twitch.tv/leave")))
        let chatHandler: MockURLProtocol.Handler = { request in
            (
                MockURLProtocol.httpResponse(for: request, status: 200),
                Data(#"{"data":[{"is_sent":true}]}"#.utf8)
            )
        }
        let service = TwitchChatService(
            helixHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession(handler: chatHandler)),
            redemptionResolutionOutbox: outbox,
            eventSubWebSocketFactory: { _ in socket },
            eventSubWebSocketResume: { _ in },
            eventSubWebSocketReceive: { _ in
                var call = 0
                receiveCalls.mutate {
                    $0 += 1
                    call = $0
                }
                if call == 1 {
                    await receiveGate.suspend()
                    return .string(paidEnvelope)
                }
                throw URLError(.networkConnectionLost)
            })
        let defaults = DefaultsStore.store
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestBitsEnabled)
        defaults.set(1, forKey: AppConstants.UserDefaults.songRequestBitsMinimum)
        defer {
            defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestEnabled)
            defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestBitsEnabled)
            defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestBitsMinimum)
        }

        _ = await service.configureChatSendForTesting(broadcasterID: "channel")
        await service.setSongRequestServiceReference(requests)
        await service.connectToEventSub()
        #expect(await waitUntil { await receiveGate.suspended })

        let generationBeforeLeave = await service.connectionGeneration
        let leaving = Task { await service.leaveChannel() }
        #expect(await waitUntil {
            service.eventSubTeardownQuiescing.value
                && socket.state != .suspended
        })

        // Models the catch pre-check racing with leave: the actor-side guard
        // must still reject the queued lifecycle error without invalidating the
        // receive context that owns the paid frame.
        await service.handleQueuedReceiveErrorForTesting(webSocketTask: socket)
        #expect(await service.connectionGeneration == generationBeforeLeave)
        await receiveGate.resume()

        #expect(await leaving.value)
        #expect(searches.value == 1)
        #expect(outbox.pendingBitsItems().isEmpty)
        #expect(await service.broadcasterID == nil)
    }

    @Test("Explicit join during quiesce supersedes stale leave")
    func testExplicitJoinDuringQuiesceSupersedesLeave() async throws {
        let directory = makeIsolatedTempDirectory(prefix: "leave-supersession")
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldReceiveGate = DeterministicAsyncGate()
        let socketFactoryCalls = ThreadSafeBox(0)
        let receiveCalls = ThreadSafeBox(0)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let oldSocket = session.webSocketTask(
            with: try #require(URL(string: "wss://eventsub.wss.twitch.tv/old")))
        let replacementSocket = session.webSocketTask(
            with: try #require(URL(string: "wss://eventsub.wss.twitch.tv/new")))
        let service = TwitchChatService(
            redemptionResolutionOutbox: TwitchRedemptionResolutionOutbox(
                fileURL: directory.appending(path: "outbox.json")),
            eventSubWebSocketFactory: { _ in
                var call = 0
                socketFactoryCalls.mutate {
                    $0 += 1
                    call = $0
                }
                return call == 1 ? oldSocket : replacementSocket
            },
            eventSubWebSocketResume: { _ in },
            eventSubWebSocketReceive: { _ in
                var call = 0
                receiveCalls.mutate {
                    $0 += 1
                    call = $0
                }
                if call == 1 {
                    await oldReceiveGate.suspend()
                    try Task.checkCancellation()
                    throw URLError(.cancelled)
                }
                try await Task.sleep(for: .seconds(3_600))
                throw CancellationError()
            })

        try await service.joinChannel(
            broadcasterID: "old-channel",
            botID: "old-channel",
            token: "old-token",
            clientID: "old-client")
        await service.connectToEventSub()
        #expect(await waitUntil { await oldReceiveGate.suspended })

        let leaving = Task { await service.leaveChannel() }
        #expect(await waitUntil {
            service.eventSubTeardownQuiescing.value
                && oldSocket.state != .suspended
        })

        try await service.joinChannel(
            broadcasterID: "new-channel",
            botID: "new-channel",
            token: "new-token",
            clientID: "new-client")
        await service.connectToEventSub()
        await oldReceiveGate.resume()

        #expect(!(await leaving.value))
        #expect(await service.broadcasterID == "new-channel")
        #expect(await service.clientID == "new-client")
        #expect(await service.hasEventSubTransportForTesting)
        await service.disconnectFromEventSub()
    }
    #endif
}
