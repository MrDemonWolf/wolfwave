//
//  TwitchTokenRefreshTests+CredentialClear.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// Sign-out and credential clear: the managed-reward pause gate and the outbox blockers.
extension TwitchTokenRefreshTests {
    /// Signing out first pauses the managed reward on Twitch (a PATCH with `is_paused:true`
    /// and a 5 s timeout, using the old token). The Keychain token must still exist while that
    /// request is in flight and only be removed after it completes.
    func testCredentialClearWaitsForManagedRewardPauseBeforeDeletingKeychain()
        async throws {
        enableManagedReward(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "OLD_ACCESS",
                refreshToken: "OLD_REFRESH",
                username: "wolf",
                userID: "broadcaster"))
        let pauseEntered = DispatchSemaphore(value: 0)
        let releasePause = DispatchSemaphore(value: 0)
        let captured = ThreadSafeBox<URLRequest?>(nil)
        let channelHandler: MockURLProtocol.Handler = { request in
            if let response = Self.emptyUnfulfilledRedemptionsResponse(
                for: request) {
                return response
            }
            captured.value = request
            pauseEntered.signal()
            guard releasePause.wait(timeout: .now() + 2) == .success else {
                throw URLError(.timedOut)
            }
            return (MockURLProtocol.httpResponse(for: request, status: 204), Data())
        }
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-redemption-teardown")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: channelHandler)),
            redemptionResolutionOutbox: TwitchRedemptionResolutionOutbox(
                fileURL: directory.appending(path: "outbox.json")),
            redemptionClientIDProvider: { "client" })
        await service.configureManagedRedemptionSessionForTesting(
            token: "OLD_ACCESS")
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {})
        viewModel.twitchService = service

        let clearing = Task { @MainActor in
            await viewModel.clearCredentials()
        }
        let didEnterPause = await waitForSemaphore(
            pauseEntered,
            timeout: .now() + 2)
        XCTAssertTrue(didEnterPause)
        XCTAssertEqual(KeychainService.loadTwitchToken(), "OLD_ACCESS")
        XCTAssertEqual(
            TwitchCredentialStore.shared.connectionSnapshot()?.accessToken,
            "OLD_ACCESS")

        releasePause.signal()
        _ = await clearing.value

        XCTAssertNil(KeychainService.loadTwitchToken())
        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.timeoutInterval, 5)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer OLD_ACCESS")
        XCTAssertTrue(Self.bodyString(of: request).contains(#""is_paused":true"#))
    }

    /// If the reward pause fails (503), sign-out is refused: credentials and the service's
    /// identity stay, a sign-out-disconnect error shows, and token validation restarts.
    func testCredentialClearRefusesFailedRewardPauseAndRestartsValidation() async throws {
        enableManagedReward(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "OLD_ACCESS",
                refreshToken: "OLD_REFRESH",
                username: "wolf",
                userID: "broadcaster"))
        let captured = ThreadSafeBox<URLRequest?>(nil)
        let channelHandler: MockURLProtocol.Handler = { request in
            if let response = Self.emptyUnfulfilledRedemptionsResponse(
                for: request) {
                return response
            }
            captured.value = request
            return (
                MockURLProtocol.httpResponse(for: request, status: 503),
                Data("unavailable".utf8))
        }
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-redemption-teardown-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: channelHandler)),
            redemptionResolutionOutbox: TwitchRedemptionResolutionOutbox(
                fileURL: directory.appending(path: "outbox.json")),
            redemptionClientIDProvider: { "client" })
        await service.configureManagedRedemptionSessionForTesting(
            token: "OLD_ACCESS")
        let restarts = ThreadSafeBox(0)
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {
                restarts.mutate { $0 += 1 }
            })
        viewModel.twitchService = service

        let cleared = await viewModel.clearCredentials()

        XCTAssertFalse(cleared)
        XCTAssertEqual(KeychainService.loadTwitchToken(), "OLD_ACCESS")
        XCTAssertEqual(
            TwitchCredentialStore.shared.connectionSnapshot()?.accessToken,
            "OLD_ACCESS")
        let state = await service.managedRedemptionIdentityForTesting()
        XCTAssertEqual(state.oauthToken, "OLD_ACCESS")
        XCTAssertEqual(state.broadcasterID, "broadcaster")
        XCTAssertEqual(viewModel.connectionError?.id, "twitch.signOutDisconnectFailed")
        XCTAssertEqual(restarts.value, 1)
        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(request.timeoutInterval, 5)
        XCTAssertTrue(Self.bodyString(of: request).contains(#""is_paused":true"#))
    }

    /// With no Twitch service to pause the reward, sign-out is refused and the stored
    /// grant and reward id are kept rather than orphaning a live reward.
    func testCredentialClearWithoutServicePreservesManagedRewardOwner() async throws {
        enableManagedReward(rewardID: "reward")
        let grant = KeychainService.TwitchCredentialGrant(
            accessToken: "ACCESS",
            refreshToken: "REFRESH",
            username: "wolf",
            userID: "broadcaster")
        try KeychainService.saveTwitchCredentialGrant(grant)
        let restarts = ThreadSafeBox(0)
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {
                restarts.mutate { $0 += 1 }
            })
        viewModel.twitchService = nil

        let cleared = await viewModel.clearCredentials()

        XCTAssertFalse(cleared)
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant(), grant)
        XCTAssertEqual(
            DefaultsStore.store.string(
                forKey: AppConstants.UserDefaults.songRequestChannelPointsRewardID),
            "reward")
        XCTAssertEqual(restarts.value, 1)
        XCTAssertEqual(viewModel.connectionError?.id, "twitch.signOutDisconnectFailed")
    }

    /// A service that is not connected still pauses the reward before sign-out, using the
    /// stored grant's token and the stored client id.
    func testDisconnectedServiceUsesStoredBroadcasterGrantToPauseBeforeClear()
        async throws {
        enableManagedReward(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "STORED_ACCESS",
                refreshToken: "STORED_REFRESH",
                username: "wolf",
                userID: "broadcaster"))
        let captured = ThreadSafeBox<URLRequest?>(nil)
        let channelHandler: MockURLProtocol.Handler = { request in
            if let response = Self.emptyUnfulfilledRedemptionsResponse(
                for: request) {
                return response
            }
            captured.value = request
            return (MockURLProtocol.httpResponse(for: request, status: 204), Data())
        }
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-disconnected-redemption-teardown")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: channelHandler)),
            redemptionResolutionOutbox: TwitchRedemptionResolutionOutbox(
                fileURL: directory.appending(path: "outbox.json")),
            redemptionClientIDProvider: { "stored-client" })
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {})
        viewModel.twitchService = service

        let cleared = await viewModel.clearCredentials()

        XCTAssertTrue(cleared)
        XCTAssertNil(KeychainService.loadTwitchToken())
        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer STORED_ACCESS")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Client-Id"),
            "stored-client")
        XCTAssertEqual(Self.queryValue("broadcaster_id", in: request), "broadcaster")
        XCTAssertEqual(Self.queryValue("id", in: request), "reward")
        XCTAssertTrue(Self.bodyString(of: request).contains(#""is_paused":true"#))
    }

    /// A 404 on the pause means the reward is already gone, so sign-out proceeds and
    /// the stored reward id is cleared.
    func testMissingManagedRewardIsSafeToClearAndForgetsStoredID() async throws {
        enableManagedReward(rewardID: "missing-reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "ACCESS",
                refreshToken: "REFRESH",
                username: "wolf",
                userID: "broadcaster"))
        let channelHandler: MockURLProtocol.Handler = { request in
            return (
                MockURLProtocol.httpResponse(for: request, status: 404),
                Data("missing".utf8))
        }
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-missing-redemption-teardown")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: channelHandler)),
            redemptionResolutionOutbox: TwitchRedemptionResolutionOutbox(
                fileURL: directory.appending(path: "outbox.json")),
            redemptionClientIDProvider: { "client" })
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {})
        viewModel.twitchService = service

        let cleared = await viewModel.clearCredentials()

        XCTAssertTrue(cleared)
        XCTAssertNil(KeychainService.loadTwitchToken())
        XCTAssertNil(
            DefaultsStore.store.string(
                forKey: AppConstants.UserDefaults.songRequestChannelPointsRewardID))
    }

    /// A sign-out that loses channel ownership mid-pause (a newer session took over) must
    /// not delete the Keychain grant: the newer owner keeps its identity and token, and a
    /// sign-out-disconnect error is reported.
    func testSupersededLeavePreservesKeychainAndNewerSameAccountOwner() async throws {
        enableManagedReward(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "OLD_ACCESS",
                refreshToken: "OLD_REFRESH",
                username: "wolf",
                userID: "broadcaster"))
        let pauseEntered = DispatchSemaphore(value: 0)
        let releasePause = DispatchSemaphore(value: 0)
        let channelHandler: MockURLProtocol.Handler = { request in
            if let response = Self.emptyUnfulfilledRedemptionsResponse(
                for: request) {
                return response
            }
            pauseEntered.signal()
            guard releasePause.wait(timeout: .now() + 2) == .success else {
                throw URLError(.timedOut)
            }
            return (MockURLProtocol.httpResponse(for: request, status: 204), Data())
        }
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-redemption-stale-leave")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: channelHandler)),
            redemptionResolutionOutbox: TwitchRedemptionResolutionOutbox(
                fileURL: directory.appending(path: "outbox.json")))
        await service.configureManagedRedemptionSessionForTesting(
            token: "OLD_ACCESS")

        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {})
        viewModel.twitchService = service
        let clearing = Task { @MainActor in
            await viewModel.clearCredentials()
        }
        let didEnterPause = await waitForSemaphore(
            pauseEntered,
            timeout: .now() + 2)
        XCTAssertTrue(didEnterPause)

        await service.supersedeChannelOwnershipForTesting()
        releasePause.signal()
        _ = await clearing.value

        let state = await service.managedRedemptionIdentityForTesting()
        XCTAssertEqual(state.broadcasterID, "broadcaster")
        XCTAssertEqual(state.botID, "broadcaster")
        XCTAssertEqual(KeychainService.loadTwitchToken(), "OLD_ACCESS")
        XCTAssertEqual(viewModel.connectionError?.id, "twitch.signOutDisconnectFailed")
        XCTAssertEqual(state.oauthToken, "OLD_ACCESS")
        XCTAssertEqual(state.clientID, "client")
    }

    /// `leaveChannel()` is superseded while its pause request is parked. When the stale
    /// pause finishes, the new live session is repaired: the reward is resubscribed and
    /// unpaused (in that order), and the stale leave reports failure while still connected.
    func testSupersededLeaveReconcilesAfterItsStalePauseCompletes() async throws {
        enableManagedReward(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "ACCESS",
                refreshToken: "REFRESH",
                username: "wolf",
                userID: "broadcaster"))
        let firstPauseEntered = DispatchSemaphore(value: 0)
        let releaseFirstPause = DispatchSemaphore(value: 0)
        let patchCount = ThreadSafeBox(0)
        let operations = ThreadSafeBox<[String]>([])
        let channelHandler: MockURLProtocol.Handler = { request in
            let body = Self.bodyString(of: request)
            let path = request.url?.path ?? ""
            if request.httpMethod == "PATCH" {
                var attempt = 0
                patchCount.mutate {
                    $0 += 1
                    attempt = $0
                }
                if attempt == 1 {
                    operations.mutate { $0.append("stale-pause") }
                    firstPauseEntered.signal()
                    guard releaseFirstPause.wait(timeout: .now() + 2) == .success else {
                        throw URLError(.timedOut)
                    }
                } else if body.contains(#""is_paused":false"#) {
                    operations.mutate { $0.append("repair-unpause") }
                } else if body.contains(#""is_paused":true"#) {
                    operations.mutate { $0.append("repair-pause") }
                } else if body.contains(#""cost":"#) {
                    operations.mutate { $0.append("repair-cost") }
                }
                return (MockURLProtocol.httpResponse(for: request, status: 204), Data())
            }
            if request.httpMethod == "GET", path.hasSuffix("/redemptions") {
                operations.mutate { $0.append("repair-fetch") }
                return (
                    MockURLProtocol.httpResponse(for: request, status: 200),
                    Data(#"{"data":[],"pagination":{}}"#.utf8))
            }
            if request.httpMethod == "GET" {
                operations.mutate { $0.append("repair-lookup") }
                return (
                    MockURLProtocol.httpResponse(for: request, status: 200),
                    Data(#"{"data":[{"id":"reward"}]}"#.utf8))
            }
            return (MockURLProtocol.httpResponse(for: request, status: 500), Data())
        }
        let eventSubHandler: MockURLProtocol.Handler = { request in
            operations.mutate { $0.append("repair-subscribe") }
            return (
                MockURLProtocol.httpResponse(for: request, status: 202),
                Data(#"{"data":[{"id":"subscription"}]}"#.utf8))
        }
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-stale-pause-repair")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TwitchChatService(
            eventSubHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession(handler: eventSubHandler)),
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: channelHandler)),
            redemptionResolutionOutbox: TwitchRedemptionResolutionOutbox(
                fileURL: directory.appending(path: "outbox.json")),
            redemptionClientIDProvider: { "client" })
        await service.configureManagedRedemptionSessionForTesting(token: "ACCESS")

        let leaving = Task { await service.leaveChannel() }
        let entered = await waitForSemaphore(
            firstPauseEntered,
            timeout: .now() + 2)
        XCTAssertTrue(entered)

        let socketSession = URLSession(configuration: .ephemeral)
        defer { socketSession.invalidateAndCancel() }
        let replacement = socketSession.webSocketTask(
            with: try XCTUnwrap(URL(string: "wss://eventsub.wss.twitch.tv/replacement")))
        _ = await service.installLiveChatSessionForTesting(
            replacement,
            actorToken: "ACCESS",
            botID: "broadcaster")
        await service.supersedeChannelOwnershipForTesting()
        releaseFirstPause.signal()

        let left = await leaving.value

        XCTAssertFalse(left)
        XCTAssertTrue(service.currentlyConnected)
        XCTAssertEqual(operations.value.last, "repair-unpause")
        let subscribe = try XCTUnwrap(
            operations.value.firstIndex(of: "repair-subscribe"))
        let unpause = try XCTUnwrap(
            operations.value.firstIndex(of: "repair-unpause"))
        XCTAssertLessThan(subscribe, unpause)

        DefaultsStore.store.removeObject(
            forKey: AppConstants.UserDefaults.songRequestChannelPointsRewardID)
        await service.leaveChannel()
    }

    /// An outbox item belonging to another broadcaster blocks sign-out even with no
    /// reward stored: credentials stay, the item stays pending, and no request is sent.
    func testNoRewardForeignBroadcasterOutboxBlocksCredentialClear() async throws {
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "ACCESS-B",
                refreshToken: "REFRESH-B",
                username: "account-b",
                userID: "account-b"))
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-foreign-outbox-teardown")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"))
        _ = try outbox.enqueue(
            broadcasterID: "account-a",
            rewardID: "reward-a",
            redemptionID: "redemption-a",
            resolution: .canceled)
        let requests = ThreadSafeBox(0)
        let handler: MockURLProtocol.Handler = { request in
            requests.mutate { $0 += 1 }
            return (
                MockURLProtocol.httpResponse(for: request, status: 204),
                Data())
        }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: handler)),
            redemptionResolutionOutbox: outbox,
            redemptionClientIDProvider: { "client" })
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {})
        viewModel.twitchService = service

        let cleared = await viewModel.clearCredentials()

        XCTAssertFalse(cleared)
        XCTAssertEqual(KeychainService.loadTwitchToken(), "ACCESS-B")
        XCTAssertEqual(outbox.pendingItems().count, 1)
        XCTAssertEqual(requests.value, 0)
    }
}
