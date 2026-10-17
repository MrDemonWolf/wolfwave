//
//  TwitchTokenRefreshTests+FreshEventSub.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// Fresh EventSub sessions: recovering missed managed redemptions before subscribe and unpause.
extension TwitchTokenRefreshTests {
    // MARK: - Fresh EventSub managed-redemption reconciliation

    /// On a fresh EventSub session, redemptions missed while offline are recovered before
    /// the reward goes live again. The outbox already holds `missed-1`; Helix lists
    /// `missed-1` (twice) and `missed-2`. Each is canceled exactly once, and the order must be
    /// fetch, then cancels, then EventSub subscribe, then unpause (a viewer must not be able to
    /// redeem into a session that is not yet listening).
    func testFreshEventSubRecoversDuplicateMissedRedemptionsBeforeSubscribeAndUnpause()
        async throws {
        enableManagedReward(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "ACCESS", userID: "broadcaster")
        )

        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-redemption-reconcile")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"))
        _ = try outbox.enqueueIntake(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "missed-1")

        let operations = ThreadSafeBox<[String]>([])
        let channelHandler: MockURLProtocol.Handler = { request in
            let path = request.url?.path ?? ""
            let body = Self.bodyString(of: request)
            if path.hasSuffix("/channel_points/custom_rewards/redemptions") {
                if request.httpMethod == "GET" {
                    operations.mutate { $0.append("fetch-unfulfilled") }
                    return (
                        MockURLProtocol.httpResponse(for: request, status: 200),
                        Data(
                            #"{"data":[{"id":"missed-1"},{"id":"missed-2"},{"id":"missed-1"}],"pagination":{}}"#.utf8)
                    )
                }
                let redemptionID = Self.queryValue("id", in: request) ?? ""
                operations.mutate { $0.append("cancel:\(redemptionID)") }
                XCTAssertTrue(body.contains("CANCELED"))
                return (MockURLProtocol.httpResponse(for: request, status: 204), Data())
            }
            if request.httpMethod == "GET" {
                operations.mutate { $0.append("ensure-existing") }
                return (
                    MockURLProtocol.httpResponse(for: request, status: 200),
                    Data(#"{"data":[{"id":"reward"}]}"#.utf8)
                )
            }
            if body.contains(#""is_paused":true"#) {
                operations.mutate { $0.append("pause") }
            } else if body.contains(#""is_paused":false"#) {
                operations.mutate { $0.append("unpause") }
                XCTAssertTrue(body.contains(#""is_enabled":true"#))
            } else if body.contains(#""cost":"#) {
                operations.mutate { $0.append("cost") }
            }
            return (MockURLProtocol.httpResponse(for: request, status: 204), Data())
        }
        let eventSubHandler: MockURLProtocol.Handler = { request in
            operations.mutate { $0.append("subscribe") }
            return (
                MockURLProtocol.httpResponse(for: request, status: 202),
                Data(#"{"data":[{"id":"subscription"}]}"#.utf8)
            )
        }
        let service = TwitchChatService(
            eventSubHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession(handler: eventSubHandler)),
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: channelHandler)),
            redemptionResolutionOutbox: outbox,
            redemptionClientIDProvider: { "client" })
        await service.configureManagedRedemptionSessionForTesting()

        await service.subscribeToRedemptionsIfEnabled()

        XCTAssertTrue(outbox.pendingItems().isEmpty)
        XCTAssertEqual(
            RedemptionStatus(
                rawValue: DefaultsStore.store.string(
                    forKey: AppConstants.UserDefaults.songRequestRedemptionStatus) ?? ""),
            .ok)
        let completed = operations.value
        XCTAssertEqual(
            completed.filter { $0.hasPrefix("cancel:") }.sorted(),
            ["cancel:missed-1", "cancel:missed-2"])
        let fetchIndex = try XCTUnwrap(completed.firstIndex(of: "fetch-unfulfilled"))
        let firstCancelIndex = try XCTUnwrap(
            completed.indices.filter { completed[$0].hasPrefix("cancel:") }.min())
        let lastCancelIndex = try XCTUnwrap(
            completed.indices.filter { completed[$0].hasPrefix("cancel:") }.max())
        let subscribeIndex = try XCTUnwrap(completed.firstIndex(of: "subscribe"))
        let unpauseIndex = try XCTUnwrap(completed.firstIndex(of: "unpause"))
        XCTAssertLessThan(fetchIndex, firstCancelIndex)
        XCTAssertLessThan(lastCancelIndex, subscribeIndex)
        XCTAssertLessThan(subscribeIndex, unpauseIndex)
    }

    /// If the outbox cannot be written while recording missed redemptions (the second write
    /// fails), the reward stays paused, no EventSub subscription is made, nothing is canceled,
    /// and the status becomes `.storageUnavailable`.
    func testFreshEventSubStorageFailureKeepsRewardPausedAndSkipsSubscription()
        async throws {
        enum InjectedFailure: Error {
            case write
        }

        enableManagedReward(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "ACCESS", userID: "broadcaster")
        )
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-redemption-reconcile-store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = ThreadSafeBox(0)
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"),
            atomicWriter: { data, url in
                var attempt = 0
                writes.mutate {
                    $0 += 1
                    attempt = $0
                }
                if attempt == 2 { throw InjectedFailure.write }
                try data.write(to: url, options: .atomic)
            })
        let operations = ThreadSafeBox<[String]>([])
        let eventSubRequests = ThreadSafeBox(0)
        let channelHandler: MockURLProtocol.Handler = { request in
            let path = request.url?.path ?? ""
            let body = Self.bodyString(of: request)
            if path.hasSuffix("/channel_points/custom_rewards/redemptions") {
                operations.mutate { $0.append("fetch-unfulfilled") }
                return (
                    MockURLProtocol.httpResponse(for: request, status: 200),
                    Data(
                        #"{"data":[{"id":"missed"}],"pagination":{}}"#.utf8)
                )
            }
            if request.httpMethod == "GET" {
                return (
                    MockURLProtocol.httpResponse(for: request, status: 200),
                    Data(#"{"data":[{"id":"reward"}]}"#.utf8)
                )
            }
            if body.contains(#""is_paused":true"#) {
                operations.mutate { $0.append("pause") }
            } else if body.contains(#""is_paused":false"#) {
                operations.mutate { $0.append("unpause") }
            }
            return (MockURLProtocol.httpResponse(for: request, status: 204), Data())
        }
        let service = TwitchChatService(
            eventSubHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession { request in
                    eventSubRequests.mutate { $0 += 1 }
                    return (
                        MockURLProtocol.httpResponse(for: request, status: 202),
                        Data())
                }),
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: channelHandler)),
            redemptionResolutionOutbox: outbox,
            redemptionClientIDProvider: { "client" })
        await service.configureManagedRedemptionSessionForTesting()

        await service.subscribeToRedemptionsIfEnabled()

        XCTAssertEqual(writes.value, 2)
        XCTAssertTrue(outbox.intakeStorageIsUnavailable())
        XCTAssertTrue(outbox.pendingItems().isEmpty)
        XCTAssertEqual(eventSubRequests.value, 0)
        XCTAssertFalse(operations.value.contains("unpause"))
        XCTAssertFalse(operations.value.contains { $0.hasPrefix("cancel:") })
        XCTAssertTrue(operations.value.contains("pause"))
        XCTAssertEqual(
            RedemptionStatus(
                rawValue: DefaultsStore.store.string(
                    forKey: AppConstants.UserDefaults.songRequestRedemptionStatus) ?? ""),
            .storageUnavailable)
    }

    /// If listing unfulfilled redemptions fails (503), the reward stays paused, no
    /// subscription is made, and the status becomes `.subscribeFailed`. Storage is not blamed.
    func testFreshEventSubRecoveryAPIFailureKeepsRewardPausedAndSkipsSubscription()
        async throws {
        enableManagedReward(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "ACCESS", userID: "broadcaster")
        )
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-redemption-reconcile-api")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"))
        let operations = ThreadSafeBox<[String]>([])
        let eventSubRequests = ThreadSafeBox(0)
        let channelHandler: MockURLProtocol.Handler = { request in
            let path = request.url?.path ?? ""
            let body = Self.bodyString(of: request)
            if path.hasSuffix("/channel_points/custom_rewards/redemptions") {
                operations.mutate { $0.append("fetch-unfulfilled") }
                return (
                    MockURLProtocol.httpResponse(for: request, status: 503),
                    Data("temporary".utf8)
                )
            }
            if request.httpMethod == "GET" {
                return (
                    MockURLProtocol.httpResponse(for: request, status: 200),
                    Data(#"{"data":[{"id":"reward"}]}"#.utf8)
                )
            }
            if body.contains(#""is_paused":true"#) {
                operations.mutate { $0.append("pause") }
            } else if body.contains(#""is_paused":false"#) {
                operations.mutate { $0.append("unpause") }
            }
            return (MockURLProtocol.httpResponse(for: request, status: 204), Data())
        }
        let service = TwitchChatService(
            eventSubHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession { request in
                    eventSubRequests.mutate { $0 += 1 }
                    return (
                        MockURLProtocol.httpResponse(for: request, status: 202),
                        Data())
                }),
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: channelHandler)),
            redemptionResolutionOutbox: outbox,
            redemptionClientIDProvider: { "client" })
        await service.configureManagedRedemptionSessionForTesting()

        await service.subscribeToRedemptionsIfEnabled()

        XCTAssertEqual(eventSubRequests.value, 0)
        XCTAssertFalse(operations.value.contains("unpause"))
        XCTAssertTrue(operations.value.contains("pause"))
        XCTAssertTrue(outbox.pendingItems().isEmpty)
        XCTAssertFalse(outbox.intakeStorageIsUnavailable())
        XCTAssertEqual(
            RedemptionStatus(
                rawValue: DefaultsStore.store.string(
                    forKey: AppConstants.UserDefaults.songRequestRedemptionStatus) ?? ""),
            .subscribeFailed)
    }

    /// When the stored reward was deleted on Twitch (pause returns 404), a new one is
    /// created disabled, paused, fetched, subscribed, and only then unpaused, with the new id
    /// stored. The ordering assertions pin that the reward is never live before it is ready.
    func testFreshEventSubClearsDeletedStoredRewardAndRecreatesItHeld()
        async throws {
        enableManagedReward(rewardID: "stale-reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "ACCESS", userID: "broadcaster")
        )
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-redemption-recreate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"))
        let operations = ThreadSafeBox<[String]>([])
        let channelHandler: MockURLProtocol.Handler = { request in
            let path = request.url?.path ?? ""
            let rewardID = Self.queryValue("id", in: request) ?? ""
            let body = Self.bodyString(of: request)
            if path.hasSuffix("/channel_points/custom_rewards/redemptions") {
                operations.mutate { $0.append("fetch:\(Self.queryValue("reward_id", in: request) ?? "")") }
                return (
                    MockURLProtocol.httpResponse(for: request, status: 200),
                    Data(#"{"data":[],"pagination":{}}"#.utf8)
                )
            }
            if request.httpMethod == "POST" {
                operations.mutate { $0.append("create") }
                XCTAssertTrue(body.contains(#""is_enabled":false"#))
                return (
                    MockURLProtocol.httpResponse(for: request, status: 200),
                    Data(#"{"data":[{"id":"fresh-reward"}]}"#.utf8)
                )
            }
            if request.httpMethod == "GET" {
                operations.mutate { $0.append("unexpected-lookup") }
                return (
                    MockURLProtocol.httpResponse(for: request, status: 200),
                    Data(#"{"data":[]}"#.utf8)
                )
            }
            if body.contains(#""is_paused":true"#) {
                operations.mutate { $0.append("pause:\(rewardID)") }
                let status = rewardID == "stale-reward" ? 404 : 204
                return (MockURLProtocol.httpResponse(for: request, status: status), Data())
            }
            if body.contains(#""is_paused":false"#) {
                operations.mutate { $0.append("unpause:\(rewardID)") }
                XCTAssertTrue(body.contains(#""is_enabled":true"#))
            } else if body.contains(#""cost":"#) {
                operations.mutate { $0.append("cost:\(rewardID)") }
            }
            return (MockURLProtocol.httpResponse(for: request, status: 204), Data())
        }
        let eventSubHandler: MockURLProtocol.Handler = { request in
            operations.mutate { $0.append("subscribe") }
            return (
                MockURLProtocol.httpResponse(for: request, status: 202),
                Data(#"{"data":[{"id":"subscription"}]}"#.utf8)
            )
        }
        let service = TwitchChatService(
            eventSubHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession(handler: eventSubHandler)),
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: channelHandler)),
            redemptionResolutionOutbox: outbox,
            redemptionClientIDProvider: { "client" })
        await service.configureManagedRedemptionSessionForTesting()

        await service.subscribeToRedemptionsIfEnabled()

        XCTAssertEqual(
            DefaultsStore.store.string(
                forKey: AppConstants.UserDefaults.songRequestChannelPointsRewardID),
            "fresh-reward")
        XCTAssertTrue(outbox.pendingItems().isEmpty)
        let completed = operations.value
        XCTAssertFalse(completed.contains("unexpected-lookup"))
        let stalePause = try XCTUnwrap(completed.firstIndex(of: "pause:stale-reward"))
        let create = try XCTUnwrap(completed.firstIndex(of: "create"))
        let freshPause = try XCTUnwrap(completed.firstIndex(of: "pause:fresh-reward"))
        let fetch = try XCTUnwrap(completed.firstIndex(of: "fetch:fresh-reward"))
        let subscribe = try XCTUnwrap(completed.firstIndex(of: "subscribe"))
        let unpause = try XCTUnwrap(completed.firstIndex(of: "unpause:fresh-reward"))
        XCTAssertLessThan(stalePause, create)
        XCTAssertLessThan(create, freshPause)
        XCTAssertLessThan(freshPause, fetch)
        XCTAssertLessThan(fetch, subscribe)
        XCTAssertLessThan(subscribe, unpause)
    }

    /// A corrupt outbox file flags "opaque recovery risk"; a successful reconciliation
    /// clears that flag.
    func testHeldReconciliationClearsPersistentOpaqueRecoveryRisk() async throws {
        enableManagedReward(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "ACCESS",
                refreshToken: "REFRESH",
                username: "wolf",
                userID: "broadcaster"))
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-opaque-reconciliation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "outbox.json")
        try Data("not-json".utf8).write(to: file, options: .atomic)
        let outbox = TwitchRedemptionResolutionOutbox(fileURL: file)
        XCTAssertTrue(outbox.hasOpaqueRecoveryRisk())

        let channelHandler: MockURLProtocol.Handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "GET",
               path.hasSuffix("/redemptions") {
                return (
                    MockURLProtocol.httpResponse(for: request, status: 200),
                    Data(#"{"data":[],"pagination":{}}"#.utf8))
            }
            if request.httpMethod == "GET" {
                return (
                    MockURLProtocol.httpResponse(for: request, status: 200),
                    Data(#"{"data":[{"id":"reward"}]}"#.utf8))
            }
            return (
                MockURLProtocol.httpResponse(for: request, status: 204),
                Data())
        }
        let eventSubHandler: MockURLProtocol.Handler = { request in
            (
                MockURLProtocol.httpResponse(for: request, status: 202),
                Data(#"{"data":[{"id":"subscription"}]}"#.utf8))
        }
        let service = TwitchChatService(
            eventSubHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession(handler: eventSubHandler)),
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: channelHandler)),
            redemptionResolutionOutbox: outbox,
            redemptionClientIDProvider: { "client" })
        await service.configureManagedRedemptionSessionForTesting()

        await service.subscribeToRedemptionsIfEnabled()

        XCTAssertFalse(outbox.hasOpaqueRecoveryRisk())
        let leftChannel = await service.leaveChannel()
        XCTAssertTrue(leftChannel)
    }
}
