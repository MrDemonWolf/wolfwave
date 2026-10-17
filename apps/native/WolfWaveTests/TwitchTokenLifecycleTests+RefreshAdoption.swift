//
//  TwitchTokenLifecycleTests+RefreshAdoption.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// Hourly rotation and refresh adoption into live chat sessions.
extension TwitchTokenLifecycleTests {
    /// After an hourly token rotation, `adoptRefreshedAccessCredential` updates both the
    /// chat service's active token and its pending reconnect token, and cancels a stale
    /// reconnect task that was holding the old token.
    func testHourlyRotationAdoptsActiveAndPendingReconnectTokens() async throws {
        await TwitchTokenRefresher.invalidateSession()
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "OLD_AT",
                refreshToken: "OLD_RT",
                username: "wolf",
                userID: "user"
            )
        )
        let rejected = try XCTUnwrap(
            TwitchCredentialStore.shared
                .connectionSnapshot(
                    matchingAccessToken: "OLD_AT"
                )?.accessExpectation
        )
        XCTAssertTrue(
            try TwitchCredentialStore.shared.commitRefreshGrant(
                TwitchTokenResponse(
                    accessToken: "NEW_AT",
                    refreshToken: "NEW_RT",
                    expiresIn: nil
                ),
                replacing: "OLD_RT",
                expected: rejected
            )
        )
        let refreshed = rejected.replacingAccessToken("NEW_AT")

        let staleReconnectCancelled = ThreadSafeBox(false)
        let service = TwitchChatService()
        await service.installRefreshAdoptionStateForTesting(
            token: "OLD_AT",
            staleReconnectCancelled: staleReconnectCancelled
        )

        let adopted = await service.adoptRefreshedAccessCredential(
            refreshed,
            replacing: rejected
        )
        let actorState = await service.refreshActorStateForTesting()
        let cancellationObserved = await waitUntil {
            staleReconnectCancelled.value
        }
        await service.cancelRefreshReconnectForTesting()

        XCTAssertTrue(adopted)
        XCTAssertEqual(actorState.oauthToken, "NEW_AT")
        XCTAssertEqual(actorState.reconnectToken, "NEW_AT")
        XCTAssertTrue(cancellationObserved)
    }

    /// A rotation for an account that has since been replaced is refused and leaves the
    /// actor's tokens unchanged.
    func testStaleHourlyRotationCannotMutateReplacementActorState() async throws {
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "OLD_AT", refreshToken: "OLD_RT")
        )
        let rejected = try XCTUnwrap(
            TwitchCredentialStore.shared
                .connectionSnapshot(
                    matchingAccessToken: "OLD_AT"
                )?.accessExpectation
        )

        let replacementRevision = TwitchCredentialStore.shared.supersede()
        XCTAssertTrue(
            try TwitchCredentialStore.shared.commitDeviceGrant(
                TwitchTokenResponse(
                    accessToken: "ACCOUNT_B_AT",
                    refreshToken: "ACCOUNT_B_RT",
                    expiresIn: nil
                ),
                expectedRevision: replacementRevision
            )
        )

        let service = TwitchChatService()
        await service.installRefreshAdoptionStateForTesting(token: "OLD_AT")
        let adopted = await service.adoptRefreshedAccessCredential(
            rejected.replacingAccessToken("STALE_ROTATION"),
            replacing: rejected
        )
        let actorState = await service.refreshActorStateForTesting()

        XCTAssertFalse(adopted)
        XCTAssertEqual(actorState.oauthToken, "OLD_AT")
        XCTAssertEqual(actorState.reconnectToken, "OLD_AT")
    }

    /// Adopting a refreshed token while a live EventSub socket is up retires that socket
    /// and reconnects once on a new one, with Helix calls using the new bearer token.
    func testDefaultRefreshAdoptionRetiresLiveSocketAndReconnectsWithNewToken()
        async throws {
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "OLD_AT",
                refreshToken: "OLD_RT",
                username: "bot",
                userID: "bot-user",
                channelID: "channel"))
        let rejected = try XCTUnwrap(
            TwitchCredentialStore.shared.connectionSnapshot(
                matchingAccessToken: "OLD_AT")?.accessExpectation)
        XCTAssertTrue(
            try TwitchCredentialStore.shared.commitRefreshGrant(
                TwitchTokenResponse(
                    accessToken: "NEW_AT",
                    refreshToken: "NEW_RT",
                    expiresIn: nil),
                replacing: "OLD_RT",
                expected: rejected))
        let refreshed = rejected.replacingAccessToken("NEW_AT")

        let socketSession = URLSession(configuration: .ephemeral)
        defer { socketSession.invalidateAndCancel() }
        let source = socketSession.webSocketTask(
            with: try XCTUnwrap(URL(string: "wss://eventsub.wss.twitch.tv/source")))
        let target = socketSession.webSocketTask(
            with: try XCTUnwrap(URL(string: "wss://eventsub.wss.twitch.tv/target")))
        let helixAuthorization = ThreadSafeBox<[String]>([])
        let factoryCalls = ThreadSafeBox(0)
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-live-adoption")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TwitchChatService(
            helixHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession { request in
                    helixAuthorization.mutate {
                        $0.append(
                            request.value(forHTTPHeaderField: "Authorization") ?? "")
                    }
                    return (
                        MockURLProtocol.httpResponse(for: request, status: 200),
                        Data(
                            #"{"data":[{"id":"broadcaster","login":"channel","display_name":"Channel"}]}"#.utf8))
                }),
            redemptionResolutionOutbox: TwitchRedemptionResolutionOutbox(
                fileURL: directory.appending(path: "outbox.json")),
            eventSubWebSocketFactory: { _ in
                factoryCalls.mutate { $0 += 1 }
                return target
            },
            eventSubWebSocketResume: { _ in },
            eventSubWebSocketReceive: { _ in
                try await Task.sleep(for: .seconds(3_600))
                throw CancellationError()
            })
        _ = await service.installLiveChatSessionForTesting(
            source,
            actorToken: "OLD_AT")

        let adopted = await service.adoptRefreshedAccessCredential(
            refreshed,
            replacing: rejected)
        let reconnected = await waitUntil(timeout: .seconds(4)) {
            factoryCalls.value == 1
        }

        XCTAssertTrue(adopted)
        XCTAssertTrue(reconnected)
        XCTAssertEqual(helixAuthorization.value, ["Bearer NEW_AT"])
        let transport = await service.eventSubTransportSnapshotForTesting(
            source: source,
            target: target)
        XCTAssertFalse(transport.sourceIsCurrent)
        XCTAssertTrue(transport.targetIsCurrent)
        let actorState = await service.refreshActorStateForTesting()
        XCTAssertEqual(actorState.oauthToken, "NEW_AT")
        XCTAssertEqual(actorState.reconnectToken, "NEW_AT")
        await service.leaveChannel()
    }

    #if DEBUG
    /// A 401 on the chat subscription, when the stored grant belongs to the same bot with
    /// a newer token, adopts it and reconnects (no re-auth banner).
    /// Needs the DEBUG-only test seams, hence the `#if DEBUG`.
    func testChatSubscription401AdoptsStoredSameBotRotationAndReconnects()
        async throws {
        Preferences.setTwitchReauthNeeded(false)
        defer { Preferences.setTwitchReauthNeeded(false) }
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "NEW_AT",
                refreshToken: "NEW_RT",
                username: "bot",
                userID: "bot-user",
                channelID: "channel"))

        let socketSession = URLSession(configuration: .ephemeral)
        defer { socketSession.invalidateAndCancel() }
        let source = socketSession.webSocketTask(
            with: try XCTUnwrap(URL(string: "wss://eventsub.wss.twitch.tv/source")))
        let target = socketSession.webSocketTask(
            with: try XCTUnwrap(URL(string: "wss://eventsub.wss.twitch.tv/target")))
        let subscriptionAuthorization = ThreadSafeBox<[String]>([])
        let helixAuthorization = ThreadSafeBox<[String]>([])
        let factoryCalls = ThreadSafeBox(0)
        let eventSubClient = HTTPClient(
            session: MockURLProtocol.makeSession { request in
                subscriptionAuthorization.mutate {
                    $0.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
                }
                return (
                    MockURLProtocol.httpResponse(for: request, status: 401),
                    Data("unauthorized".utf8))
            })
        let helixClient = HTTPClient(
            session: MockURLProtocol.makeSession { request in
                helixAuthorization.mutate {
                    $0.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
                }
                return (
                    MockURLProtocol.httpResponse(for: request, status: 200),
                    Data(
                        #"{"data":[{"id":"broadcaster","login":"channel","display_name":"Channel"}]}"#.utf8))
            })
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-eventsub-chat-rotation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TwitchChatService(
            eventSubHTTPClient: eventSubClient,
            helixHTTPClient: helixClient,
            redemptionResolutionOutbox: TwitchRedemptionResolutionOutbox(
                fileURL: directory.appending(path: "outbox.json")),
            eventSubWebSocketFactory: { _ in
                factoryCalls.mutate { $0 += 1 }
                return target
            },
            eventSubWebSocketResume: { _ in },
            eventSubWebSocketReceive: { _ in
                try await Task.sleep(for: .seconds(3_600))
                throw CancellationError()
            })
        let context = await service.installLiveChatSessionForTesting(
            source,
            actorToken: "OLD_AT")

        let subscribed = await service.subscribeToChannelChatMessageForTesting(
            receiveContext: context)
        let reconnected = await waitUntil(timeout: .seconds(4)) {
            factoryCalls.value == 1
        }

        XCTAssertFalse(subscribed)
        XCTAssertTrue(reconnected)
        XCTAssertEqual(subscriptionAuthorization.value, ["Bearer OLD_AT"])
        XCTAssertEqual(helixAuthorization.value, ["Bearer NEW_AT"])
        let transport = await service.eventSubTransportSnapshotForTesting(
            source: source,
            target: target)
        XCTAssertFalse(transport.sourceIsCurrent)
        XCTAssertTrue(transport.targetIsCurrent)
        let actorState = await service.refreshActorStateForTesting()
        XCTAssertEqual(actorState.oauthToken, "NEW_AT")
        XCTAssertEqual(actorState.reconnectToken, "NEW_AT")
        XCTAssertFalse(Preferences.twitchReauthNeeded)
        await service.leaveChannel()
    }

    /// A 401 where the stored grant belongs to a different user must not be adopted: no
    /// reconnect, and the actor keeps its token.
    func testChatSubscription401RejectsStoredDifferentUserWithoutReconnect()
        async throws {
        Preferences.setTwitchReauthNeeded(false)
        defer { Preferences.setTwitchReauthNeeded(false) }
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "OTHER_AT",
                refreshToken: "OTHER_RT",
                username: "other",
                userID: "other-user"))

        let socketSession = URLSession(configuration: .ephemeral)
        defer { socketSession.invalidateAndCancel() }
        let source = socketSession.webSocketTask(
            with: try XCTUnwrap(URL(string: "wss://eventsub.wss.twitch.tv/source")))
        let target = socketSession.webSocketTask(
            with: try XCTUnwrap(URL(string: "wss://eventsub.wss.twitch.tv/target")))
        let factoryCalls = ThreadSafeBox(0)
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-eventsub-chat-account-switch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TwitchChatService(
            eventSubHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession { request in
                    return (
                        MockURLProtocol.httpResponse(for: request, status: 401),
                        Data("unauthorized".utf8))
                }),
            redemptionResolutionOutbox: TwitchRedemptionResolutionOutbox(
                fileURL: directory.appending(path: "outbox.json")),
            eventSubWebSocketFactory: { _ in
                factoryCalls.mutate { $0 += 1 }
                return target
            },
            eventSubWebSocketResume: { _ in },
            eventSubWebSocketReceive: { _ in
                try await Task.sleep(for: .seconds(3_600))
                throw CancellationError()
            })
        let context = await service.installLiveChatSessionForTesting(
            source,
            actorToken: "OLD_AT")

        let subscribed = await service.subscribeToChannelChatMessageForTesting(
            receiveContext: context)

        XCTAssertFalse(subscribed)
        XCTAssertEqual(factoryCalls.value, 0)
        let transport = await service.eventSubTransportSnapshotForTesting(
            source: source,
            target: target)
        XCTAssertFalse(transport.sourceIsCurrent)
        XCTAssertFalse(transport.targetIsCurrent)
        XCTAssertFalse(transport.hasReconnectTask)
        let actorState = await service.refreshActorStateForTesting()
        XCTAssertEqual(actorState.oauthToken, "OLD_AT")
        XCTAssertEqual(actorState.reconnectToken, "OLD_AT")
        XCTAssertFalse(Preferences.twitchReauthNeeded)
        await service.leaveChannel()
    }
    #endif
}
