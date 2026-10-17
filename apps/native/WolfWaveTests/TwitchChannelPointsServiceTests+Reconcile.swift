//
//  TwitchChannelPointsServiceTests+Reconcile.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// Reward reconcile diffing, error mapping, and the enum descriptions.
extension TwitchChannelPointsServiceTests {
    // MARK: - Reconcile Diff

    /// A stored reward id is verified with one GET (manageable rewards only) and reused; no POST is
    /// made.
    func testEnsureRewardReturnsStoredIDWhenHelixConfirmsExistence() async throws {
        DefaultsStore.store.set("existing_id", forKey: storageKey)

        struct State { var callCount = 0; var lastMethod: String?; var lastURL: URL? }
        let state = ThreadSafeBox(State())

        handlerStore.handler = { request in
            state.mutate { stored in
                stored.callCount += 1
                stored.lastMethod = request.httpMethod
                stored.lastURL = request.url
            }
            let body: [String: Any] = ["data": [["id": "existing_id"]]]
            return (
                MockURLProtocol.httpResponse(for: request, status: 200),
                Self.encodeJSON(body)
            )
        }

        let rewardID = try await makeService().ensureReward(credentials: creds, cost: 500)

        XCTAssertEqual(rewardID, "existing_id")
        XCTAssertEqual(
            TwitchManagedRewardStore.snapshot(),
            .owned(
                .init(
                    rewardID: "existing_id",
                    broadcasterID: "12345")))
        let snap = state.value
        XCTAssertEqual(snap.callCount, 1, "Should not POST when GET confirms reward")
        XCTAssertEqual(snap.lastMethod, "GET")
        let comps = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(snap.lastURL), resolvingAgainstBaseURL: false))
        let items = Dictionary(
            uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["only_manageable_rewards"], "true")
        XCTAssertEqual(items["id"], "existing_id")
    }

    /// A reward id from before owner tracking (a "legacy" id) that returns 404 is never
    /// replaced, because ownership cannot be proven: `.ownershipUnverified`, one GET, id kept.
    func testLegacyReward404StaysOwnerlessAndIsNotReplaced() async {
        DefaultsStore.store.set("stale_id", forKey: storageKey)
        let methods = ThreadSafeBox<[String]>([])

        handlerStore.handler = { request in
            methods.mutate { $0.append(request.httpMethod ?? "") }
            return (
                MockURLProtocol.httpResponse(for: request, status: 404),
                Data("not found".utf8)
            )
        }

        do {
            _ = try await makeService().ensureReward(
                credentials: creds,
                cost: 200)
            XCTFail("Expected .ownershipUnverified")
        } catch TwitchChannelPointsService.RewardError.ownershipUnverified {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(methods.value, ["GET"])
        XCTAssertEqual(
            TwitchManagedRewardStore.snapshot(),
            .legacy(rewardID: "stale_id"))
        XCTAssertEqual(
            DefaultsStore.store.string(forKey: storageKey),
            "stale_id")
    }

    /// For a reward with a recorded owner, a 404 means it was deleted, so a new one is
    /// created (GET then POST) and stored.
    func testEnsureRewardTreatsOwned404AsMissingAndRecreates() async throws {
        storeManagedReward("gone_id")
        let methods = ThreadSafeBox<[String]>([])

        handlerStore.handler = { request in
            methods.mutate { $0.append(request.httpMethod ?? "") }
            if request.httpMethod == "GET" {
                return (
                    MockURLProtocol.httpResponse(for: request, status: 404),
                    Data("not found".utf8)
                )
            }
            let body: [String: Any] = ["data": [["id": "recreated_id"]]]
            return (
                MockURLProtocol.httpResponse(for: request, status: 200),
                Self.encodeJSON(body)
            )
        }

        let rewardID = try await makeService().ensureReward(credentials: creds, cost: 200)

        XCTAssertEqual(rewardID, "recreated_id")
        XCTAssertEqual(methods.value, ["GET", "POST"])
        XCTAssertEqual(
            TwitchManagedRewardStore.snapshot(),
            .owned(
                .init(
                    rewardID: "recreated_id",
                    broadcasterID: "12345")))
    }

    /// Credentials for a different broadcaster cannot ensure, update, or remove the stored
    /// reward (`.ownershipUnverified`, no network requests), and ownership stays with account A.
    func testCrossAccountCannotInspectMutateOrClearManagedReward() async {
        storeManagedReward("reward_a", broadcasterID: "account_a")
        let requestCount = ThreadSafeBox(0)
        handlerStore.handler = { request in
            requestCount.mutate { $0 += 1 }
            return (
                MockURLProtocol.httpResponse(for: request, status: 204),
                Data())
        }
        let accountB = TwitchChannelPointsService.Credentials(
            broadcasterID: "account_b",
            token: "token_b",
            clientID: "client_xyz")

        do {
            _ = try await makeService().ensureReward(
                credentials: accountB,
                cost: 200)
            XCTFail("Expected .ownershipUnverified")
        } catch TwitchChannelPointsService.RewardError.ownershipUnverified {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            try await makeService().updateRewardCost(
                credentials: accountB,
                rewardID: "reward_a",
                cost: 300)
            XCTFail("Expected .ownershipUnverified")
        } catch TwitchChannelPointsService.RewardError.ownershipUnverified {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(
            TwitchManagedRewardStore.remove(
                matching: .init(
                    rewardID: "reward_a",
                    broadcasterID: "account_b")))
        XCTAssertEqual(requestCount.value, 0)
        XCTAssertEqual(
            TwitchManagedRewardStore.snapshot(),
            .owned(
                .init(
                    rewardID: "reward_a",
                    broadcasterID: "account_a")))
    }

    func testOwnedSnapshotRepairsMirrorAfterInterruptedRemoval() {
        storeManagedReward("reward_a", broadcasterID: "account_a")

        // Removal writes the mirror first and authoritative owner record last.
        // This simulates a process exit between those operations.
        DefaultsStore.store.removeObject(forKey: storageKey)

        XCTAssertEqual(
            TwitchManagedRewardStore.snapshot(),
            .owned(
                .init(
                    rewardID: "reward_a",
                    broadcasterID: "account_a")))
        XCTAssertEqual(
            DefaultsStore.store.string(forKey: storageKey),
            "reward_a")
        XCTAssertTrue(
            TwitchManagedRewardStore.remove(
                matching: .init(
                    rewardID: "reward_a",
                    broadcasterID: "account_a")))
        XCTAssertEqual(TwitchManagedRewardStore.snapshot(), .none)
    }

    // MARK: - Errors

    func testCreateRewardMalformedResponseThrows() async {
        DefaultsStore.store.removeObject(forKey: storageKey)
        handlerStore.handler = { request in
            let body: [String: Any] = ["data": []]
            return (
                MockURLProtocol.httpResponse(for: request, status: 200),
                Self.encodeJSON(body)
            )
        }

        do {
            _ = try await makeService().ensureReward(credentials: creds, cost: 200)
            XCTFail("Expected .malformedResponse")
        } catch TwitchChannelPointsService.RewardError.malformedResponse {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNon2xxStatusThrowsHTTPError() async {
        storeManagedReward("x")
        handlerStore.handler = { request in
            (
                MockURLProtocol.httpResponse(for: request, status: 401),
                Data("unauthorized".utf8)
            )
        }

        do {
            try await makeService().updateRewardCost(
                credentials: creds, rewardID: "x", cost: 1)
            XCTFail("Expected .http")
        } catch TwitchChannelPointsService.RewardError.http(let status, let body) {
            XCTAssertEqual(status, 401)
            XCTAssertEqual(body, "unauthorized")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTransportFailureThrowsTransportError() async {
        storeManagedReward("x")
        struct StubError: Error {}
        handlerStore.handler = { _ in throw StubError() }

        do {
            try await makeService().updateRewardCost(
                credentials: creds, rewardID: "x", cost: 1)
            XCTFail("Expected .transport")
        } catch TwitchChannelPointsService.RewardError.transport {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Enum / Description

    func testResolutionRawValuesMatchHelix() {
        XCTAssertEqual(TwitchChannelPointsService.Resolution.fulfilled.rawValue, "FULFILLED")
        XCTAssertEqual(TwitchChannelPointsService.Resolution.canceled.rawValue, "CANCELED")
    }

    func testRewardErrorDescriptions() {
        let http = TwitchChannelPointsService.RewardError.http(status: 404, body: "oops")
        XCTAssertTrue(http.errorDescription?.contains("404") ?? false)
        XCTAssertTrue(http.errorDescription?.contains("oops") ?? false)

        struct StubError: LocalizedError { var errorDescription: String? { "boom" } }
        let transport = TwitchChannelPointsService.RewardError.transport(underlying: StubError())
        XCTAssertTrue(transport.errorDescription?.contains("boom") ?? false)

        let malformed = TwitchChannelPointsService.RewardError.malformedResponse
        XCTAssertNotNil(malformed.errorDescription)

        let ownership = TwitchChannelPointsService.RewardError.ownershipUnverified
        XCTAssertNotNil(ownership.errorDescription)
    }
}
