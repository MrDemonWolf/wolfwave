//
//  TwitchTokenRefreshTests+RedemptionReplay.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// Durable redemption resolution replay: retry, 401/403 token adoption, and ownership checks.
extension TwitchTokenRefreshTests {
    // MARK: - Durable redemption resolution replay

    /// An intake record with no known outcome (the app died before deciding) is refunded
    /// (`CANCELED`) on startup replay and drained from the outbox.
    func testUnknownPersistedRedemptionIntakeRefundsOnStartupAndDrains() async throws {
        storeManagedRewardIdentity(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "ACCESS", userID: "broadcaster")
        )

        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-redemption-intake-replay")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"))
        _ = try outbox.enqueueIntake(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption"
        )
        let requests = ThreadSafeBox<[URLRequest]>([])
        let handler: MockURLProtocol.Handler = { request in
            requests.mutate { $0.append(request) }
            return (
                MockURLProtocol.httpResponse(for: request, status: 204),
                Data()
            )
        }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: handler)),
            redemptionResolutionOutbox: outbox,
            redemptionClientIDProvider: { "client" }
        )

        await service.replayPendingRedemptionResolutions()
        await service.awaitRedemptionResolutionWorkersForTesting()

        XCTAssertTrue(outbox.pendingItems().isEmpty)
        let request = try XCTUnwrap(requests.value.first)
        XCTAssertEqual(requests.value.count, 1)
        XCTAssertTrue(Self.bodyString(of: request).contains("CANCELED"))
    }

    /// A 404 on a persisted resolution counts as already-handled and drains the item, but only
    /// when the item's broadcaster and reward match the stored managed reward owner.
    func testPersistedRedemption404DrainsOnlyForExactManagedOwner() async throws {
        storeManagedRewardIdentity(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "ACCESS",
                refreshToken: "REFRESH",
                username: "wolf",
                userID: "broadcaster"))
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-redemption-owner-404")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"))
        _ = try outbox.enqueue(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption",
            resolution: .canceled)
        let handler: MockURLProtocol.Handler = { request in
            (
                MockURLProtocol.httpResponse(for: request, status: 404),
                Data("not found".utf8))
        }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: handler)),
            redemptionResolutionOutbox: outbox,
            redemptionClientIDProvider: { "client" })

        await service.replayPendingRedemptionResolutions()
        await service.awaitRedemptionResolutionWorkersForTesting()

        XCTAssertTrue(outbox.pendingItems().isEmpty)
    }

    /// A 404 only drains an outbox item while the managed reward owner is still the one that
    /// queued it. If the owner changes while the PATCH is in flight (reward removed, a
    /// different account's reward stored), the item stays pending.
    func testPersistedRedemption404StaysPendingAfterManagedOwnerChanges()
        async throws {
        storeManagedRewardIdentity(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "ACCESS",
                refreshToken: "REFRESH",
                username: "wolf",
                userID: "broadcaster"))
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-redemption-stale-owner-404")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"))
        _ = try outbox.enqueue(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption",
            resolution: .canceled)
        let patchEntered = DispatchSemaphore(value: 0)
        let releasePatch = DispatchSemaphore(value: 0)
        let handler: MockURLProtocol.Handler = { request in
            patchEntered.signal()
            guard releasePatch.wait(timeout: .now() + 2) == .success else {
                throw URLError(.timedOut)
            }
            return (
                MockURLProtocol.httpResponse(for: request, status: 404),
                Data("not found".utf8))
        }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: handler)),
            redemptionResolutionOutbox: outbox,
            redemptionClientIDProvider: { "client" })

        await service.replayPendingRedemptionResolutions()
        let patchDidStart = await waitForSemaphore(
            patchEntered,
            timeout: .now() + 2)
        XCTAssertTrue(patchDidStart)
        let oldIdentity = TwitchManagedRewardStore.Identity(
            rewardID: "reward",
            broadcasterID: "broadcaster")
        XCTAssertTrue(TwitchManagedRewardStore.remove(matching: oldIdentity))
        XCTAssertTrue(
            TwitchManagedRewardStore.store(
                .init(
                    rewardID: "replacement",
                    broadcasterID: "other-account"),
                replacing: .none))
        releasePatch.signal()
        await service.awaitRedemptionResolutionWorkersForTesting()

        XCTAssertEqual(outbox.pendingItems().count, 1)
        XCTAssertEqual(
            TwitchManagedRewardStore.snapshot(),
            .owned(
                .init(
                    rewardID: "replacement",
                    broadcasterID: "other-account")))
    }

    /// A 409 on the PATCH is checked with a follow-up GET; if Twitch already shows the
    /// redemption as `CANCELED`, the item is acknowledged (requests are PATCH then GET).
    func testPatch409WithResolvedStatusAcknowledgesOutboxItem() async throws {
        storeManagedRewardIdentity(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "ACCESS", userID: "broadcaster"))
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-redemption-409-resolved")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"))
        _ = try outbox.enqueue(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption",
            resolution: .canceled)
        let requests = ThreadSafeBox<[URLRequest]>([])
        handlerStore.handler = { request in
            requests.mutate { $0.append(request) }
            if request.httpMethod == "PATCH" {
                return (MockURLProtocol.httpResponse(for: request, status: 409), Data())
            }
            return (
                MockURLProtocol.httpResponse(for: request, status: 200),
                Data(#"{"data":[{"id":"redemption","status":"CANCELED"}]}"#.utf8))
        }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handlerStore: handlerStore)),
            redemptionResolutionOutbox: outbox,
            redemptionClientIDProvider: { "client" })

        await service.replayPendingRedemptionResolutions()
        await service.awaitRedemptionResolutionWorkersForTesting()

        XCTAssertTrue(outbox.pendingItems().isEmpty)
        XCTAssertEqual(requests.value.map(\.httpMethod), ["PATCH", "GET"])
    }

    /// A redemption that keeps failing (400) while Twitch still shows it `UNFULFILLED` is
    /// dead-lettered after 5 attempts and flags `.resolutionStuck`. Acknowledging the
    /// dead letter returns the status to `.ok`.
    func testPatch400StillUnfulfilledDeadLettersAfterFiveAttempts() async throws {
        storeManagedRewardIdentity(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "ACCESS", userID: "broadcaster"))
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-redemption-400-unfulfilled")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"))
        _ = try outbox.enqueue(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption",
            resolution: .canceled)
        let requests = ThreadSafeBox<[URLRequest]>([])
        handlerStore.handler = { request in
            requests.mutate { $0.append(request) }
            if request.httpMethod == "PATCH" {
                return (MockURLProtocol.httpResponse(for: request, status: 400), Data())
            }
            return (
                MockURLProtocol.httpResponse(for: request, status: 200),
                Data(#"{"data":[{"id":"redemption","status":"UNFULFILLED"}]}"#.utf8))
        }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handlerStore: handlerStore)),
            redemptionResolutionOutbox: outbox,
            redemptionClientIDProvider: { "client" })
        await service.setRedemptionResolutionSleep { _ in }

        await service.replayPendingRedemptionResolutions()
        await service.awaitRedemptionResolutionWorkersForTesting()

        let deadLetter = try XCTUnwrap(outbox.deadLetterItems().first)
        XCTAssertEqual(deadLetter.attemptCount, 5)
        XCTAssertTrue(outbox.pendingItems().isEmpty)
        XCTAssertEqual(
            RedemptionStatus(rawValue: DefaultsStore.store.string(
                forKey: AppConstants.UserDefaults.songRequestRedemptionStatus) ?? ""),
            .resolutionStuck)

        await service.acknowledgeRedemptionResolutionForTesting(deadLetter)
        XCTAssertEqual(
            RedemptionStatus(rawValue: DefaultsStore.store.string(
                forKey: AppConstants.UserDefaults.songRequestRedemptionStatus) ?? ""),
            .ok)
    }

    func testPersistedRedemption401AdoptsRotatedTokenBeforeRetry() async throws {
        try await assertPersistedRedemptionAdoptsRotatedToken(status: 401)
    }

    func testPersistedRedemption403AdoptsRotatedTokenBeforeRetry() async throws {
        try await assertPersistedRedemptionAdoptsRotatedToken(status: 403)
    }

    /// Shared body for the 401 and 403 cases. The first PATCH is rejected with
    /// `unauthorizedStatus`; the injected reactive refresh commits a rotated token, which the
    /// service adopts (actor token and reconnect token, stale reconnect cancelled, new one
    /// scheduled).
    /// The retry must go out with `Bearer NEW_ACCESS` and drain the outbox.
    private func assertPersistedRedemptionAdoptsRotatedToken(status unauthorizedStatus: Int) async throws {
        storeManagedRewardIdentity(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "OLD_ACCESS",
                refreshToken: "OLD_REFRESH",
                username: "wolf",
                userID: "broadcaster"))
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-redemption-refresh-adopt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"))
        _ = try outbox.enqueue(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption",
            resolution: .canceled)

        let attempts = ThreadSafeBox(0)
        let authorizationHeaders = ThreadSafeBox<[String]>([])
        let handler: MockURLProtocol.Handler = { request in
            authorizationHeaders.mutate {
                $0.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            }
            var attempt = 0
            attempts.mutate {
                $0 += 1
                attempt = $0
            }
            let status = attempt == 1 ? unauthorizedStatus : 204
            return (MockURLProtocol.httpResponse(for: request, status: status), Data())
        }
        let staleReconnectCancelled = ThreadSafeBox(false)
        let refreshedExpectation = ThreadSafeBox<
            TwitchCredentialStore.AccessExpectation?>(nil)
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: handler)),
            redemptionResolutionOutbox: outbox,
            redemptionClientIDProvider: { "client" })
        await service.installRefreshAdoptionStateForTesting(
            token: "OLD_ACCESS",
            staleReconnectCancelled: staleReconnectCancelled)
        await service.setReactiveTokenRefresh { _, expected in
            let committed = try TwitchCredentialStore.shared.commitRefreshGrant(
                TwitchTokenResponse(
                    accessToken: "NEW_ACCESS",
                    refreshToken: "NEW_REFRESH",
                    expiresIn: nil),
                replacing: "OLD_REFRESH",
                expected: expected)
            guard committed else { return .superseded }
            let refreshed = expected.replacingAccessToken("NEW_ACCESS")
            refreshedExpectation.value = refreshed
            return .refreshed("NEW_ACCESS")
        }

        await service.replayPendingRedemptionResolutions()
        await service.awaitRedemptionResolutionWorkersForTesting()

        let actorState = await service.refreshActorStateForTesting()
        let reconnectWasRescheduled = await service.hasReconnectTaskForTesting()
        let staleReconnectWasCancelled = await waitUntil {
            staleReconnectCancelled.value
        }
        await service.cancelRefreshReconnectForTesting()
        XCTAssertEqual(attempts.value, 2)
        XCTAssertEqual(
            authorizationHeaders.value,
            ["Bearer OLD_ACCESS", "Bearer NEW_ACCESS"])
        XCTAssertEqual(KeychainService.loadTwitchToken(), "NEW_ACCESS")
        XCTAssertEqual(actorState.oauthToken, "NEW_ACCESS")
        XCTAssertEqual(actorState.reconnectToken, "NEW_ACCESS")
        XCTAssertEqual(
            TwitchCredentialStore.shared.connectionSnapshot()?.accessExpectation,
            refreshedExpectation.value)
        XCTAssertTrue(staleReconnectWasCancelled)
        XCTAssertTrue(reconnectWasRescheduled)
        XCTAssertTrue(outbox.pendingItems().isEmpty)
    }

    /// A 429 with `Retry-After: 12` makes replay wait 12 s (recorded by the injected sleeper,
    /// not slept) and retry, after which the item drains.
    func testPersistedRedemptionReplayHonorsRetryAfterAndDrains() async throws {
        storeManagedRewardIdentity(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "ACCESS", userID: "broadcaster")
        )

        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-redemption-replay")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"))
        _ = try outbox.enqueue(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption",
            resolution: .canceled
        )

        let attempts = ThreadSafeBox(0)
        let delays = ThreadSafeBox<[Duration]>([])
        let requests = ThreadSafeBox<[URLRequest]>([])
        let handler: MockURLProtocol.Handler = { request in
            requests.mutate { $0.append(request) }
            var attempt = 0
            attempts.mutate {
                $0 += 1
                attempt = $0
            }
            if attempt == 1 {
                return (
                    MockURLProtocol.httpResponse(
                        for: request,
                        status: 429,
                        headers: ["Retry-After": "12"]),
                    Data()
                )
            }
            return (
                MockURLProtocol.httpResponse(for: request, status: 204),
                Data()
            )
        }

        let channelPoints = TwitchChannelPointsService(
            session: MockURLProtocol.makeSession(handler: handler))
        let service = TwitchChatService(
            channelPointsService: channelPoints,
            redemptionResolutionOutbox: outbox,
            redemptionClientIDProvider: { "client" }
        )
        await service.setRedemptionResolutionSleep { delay in
            delays.mutate { $0.append(delay) }
        }
        await service.replayPendingRedemptionResolutions()
        await service.awaitRedemptionResolutionWorkersForTesting()

        XCTAssertEqual(attempts.value, 2)
        XCTAssertEqual(delays.value, [.seconds(12)])
        XCTAssertTrue(outbox.pendingItems().isEmpty)
        let captured = requests.value
        XCTAssertEqual(captured.count, 2)
        let first = try XCTUnwrap(captured.first)
        XCTAssertEqual(first.httpMethod, "PATCH")
        XCTAssertEqual(first.value(forHTTPHeaderField: "Authorization"), "Bearer ACCESS")
    }

    /// Four straight 503s do not give up: replay backs off 1, 2, 4, 8 s and succeeds on the fifth
    /// attempt.
    func testPersistedRedemptionKeepsRetryingAfterInitialTransientBurst() async throws {
        storeManagedRewardIdentity(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "ACCESS", userID: "broadcaster")
        )

        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-redemption-long-drain")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"))
        _ = try outbox.enqueue(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption",
            resolution: .fulfilled
        )

        let attempts = ThreadSafeBox(0)
        let delays = ThreadSafeBox<[Duration]>([])
        let handler: MockURLProtocol.Handler = { request in
            var attempt = 0
            attempts.mutate {
                $0 += 1
                attempt = $0
            }
            let status = attempt <= 4 ? 503 : 204
            return (MockURLProtocol.httpResponse(for: request, status: status), Data())
        }

        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: handler)),
            redemptionResolutionOutbox: outbox,
            redemptionClientIDProvider: { "client" }
        )
        await service.setRedemptionResolutionSleep { delay in
            delays.mutate { $0.append(delay) }
        }
        await service.replayPendingRedemptionResolutions()
        await service.awaitRedemptionResolutionWorkersForTesting()

        XCTAssertEqual(attempts.value, 5)
        XCTAssertEqual(
            delays.value,
            [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]
        )
        XCTAssertTrue(outbox.pendingItems().isEmpty)
    }

    /// A 401 for account A that arrives after the user signed in as account B must not
    /// refresh B's tokens or raise the re-auth flag. The item stays pending, and only one request
    /// was made.
    func testRedemption401CannotRefreshOrExpireReplacementAccount() async throws {
        storeManagedRewardIdentity(rewardID: "reward")
        await TwitchTokenRefresher.invalidateSession()
        Preferences.setTwitchReauthNeeded(false)
        defer { Preferences.setTwitchReauthNeeded(false) }
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "ACCESS-A",
                refreshToken: "REFRESH-A",
                username: "account-a",
                userID: "broadcaster"
            )
        )

        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-redemption-account-switch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"))
        _ = try outbox.enqueue(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption",
            resolution: .canceled
        )

        let patchEntered = DispatchSemaphore(value: 0)
        let releasePatch = DispatchSemaphore(value: 0)
        let requests = ThreadSafeBox(0)
        let handler: MockURLProtocol.Handler = { request in
            requests.mutate { $0 += 1 }
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer ACCESS-A"
            )
            patchEntered.signal()
            guard releasePatch.wait(timeout: .now() + 2) == .success else {
                throw URLError(.timedOut)
            }
            return (
                MockURLProtocol.httpResponse(for: request, status: 401),
                Data()
            )
        }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: handler)),
            redemptionResolutionOutbox: outbox,
            redemptionClientIDProvider: { "client" }
        )

        await service.replayPendingRedemptionResolutions()
        let entered = await waitForSemaphore(
            patchEntered,
            timeout: .now() + 2
        )
        XCTAssertTrue(entered)

        // Switch accounts through the production device-flow path: supersede
        // advances the revision, then the new grant replaces the old atomically.
        let replacementRevision = TwitchCredentialStore.shared.supersede()
        XCTAssertTrue(
            try TwitchCredentialStore.shared.commitDeviceGrant(
                TwitchTokenResponse(
                    accessToken: "ACCESS-B",
                    refreshToken: "REFRESH-B",
                    expiresIn: nil
                ),
                expectedRevision: replacementRevision
            )
        )
        releasePatch.signal()
        await service.awaitRedemptionResolutionWorkersForTesting()

        XCTAssertEqual(KeychainService.loadTwitchToken(), "ACCESS-B")
        XCTAssertFalse(Preferences.twitchReauthNeeded)
        XCTAssertEqual(requests.value, 1)
        XCTAssertEqual(outbox.pendingItems().count, 1)
    }

    /// Clearing credentials while the channel lookup is in flight makes `connectToChannel`
    /// throw `CancellationError` before any socket is opened; the service is not connected and
    /// keeps no reconnect channel.
    func testClearingCredentialsDuringChannelLookupCancelsJoinBeforeSocket() async throws {
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "ACCESS",
                username: "Bot",
                userID: "bot-user",
                channelID: "channel"
            )
        )

        let requestEntered = DispatchSemaphore(value: 0)
        let releaseResponse = DispatchSemaphore(value: 0)
        let requests = ThreadSafeBox<[URLRequest]>([])
        let handler: MockURLProtocol.Handler = { request in
            requests.mutate { $0.append(request) }
            requestEntered.signal()
            guard releaseResponse.wait(timeout: .now() + 2) == .success else {
                throw URLError(.timedOut)
            }
            return (
                MockURLProtocol.httpResponse(for: request, status: 200),
                Data(#"{"data":[{"id":"broadcaster","login":"channel","display_name":"Channel"}]}"#.utf8)
            )
        }

        let service = TwitchChatService(
            helixHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession(handler: handler)))
        let connection = Task {
            do {
                try await service.connectToChannel(
                    channelName: "channel",
                    token: "ACCESS",
                    clientID: "client"
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        let entered = await waitForSemaphore(
            requestEntered,
            timeout: .now() + 2
        )
        XCTAssertTrue(entered)
        try TwitchCredentialStore.shared.clearCredentials(includingChannel: false)
        releaseResponse.signal()

        let wasCancelled = await connection.value
        XCTAssertTrue(wasCancelled)
        XCTAssertFalse(service.currentlyConnected)
        let reconnectChannel = await service.reconnectChannelForTesting()
        XCTAssertNil(reconnectChannel)
        let captured = requests.value
        XCTAssertEqual(captured.count, 1)
        let request = try XCTUnwrap(captured.first)
        XCTAssertTrue(request.url?.absoluteString.contains("login=channel") == true)
    }
}
