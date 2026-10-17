//
//  TwitchChannelPointsServiceTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-23.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

// MARK: - TwitchChannelPointsServiceTests

/// Covers `TwitchChannelPointsService` Helix request construction and reward
/// reconciliation, driven by `MockURLProtocol`. No real network traffic.
final class TwitchChannelPointsServiceTests: WolfWaveTestCase {

    private let storageKey = AppConstants.UserDefaults.songRequestChannelPointsRewardID
    private let handlerStore = MockURLProtocol.HandlerStore()

    private let creds = TwitchChannelPointsService.Credentials(
        broadcasterID: "12345",
        token: "tok_abc",
        clientID: "client_xyz"
    )

    override func setUp() {
        super.setUp()
        handlerStore.handler = nil
        resetAllSettings()
    }

    override func tearDown() {
        handlerStore.handler = nil
        resetAllSettings()
        super.tearDown()
    }

    // MARK: - Helpers

    /// A service whose HTTP goes through `handlerStore`.
    private func makeService() -> TwitchChannelPointsService {
        TwitchChannelPointsService(session: MockURLProtocol.makeSession(handlerStore: handlerStore))
    }

    /// Records `rewardID` as the managed reward owned by `broadcasterID` (default "12345", matching
    /// `creds`).
    private func storeManagedReward(
        _ rewardID: String,
        broadcasterID: String = "12345"
    ) {
        let expected = TwitchManagedRewardStore.snapshot()
        XCTAssertTrue(
            TwitchManagedRewardStore.store(
                .init(
                    rewardID: rewardID,
                    broadcasterID: broadcasterID),
                replacing: expected))
    }

    /// The request's JSON body as a dictionary, read from `httpBodyStream`.
    private static func bodyJSON(_ request: URLRequest) -> [String: Any] {
        // URLProtocol exposes the body via `httpBodyStream`, not `httpBody`.
        guard let stream = request.httpBodyStream else { return [:] }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buf, maxLength: 4096)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Serializes a fixture object; a failure here is a test bug, so it traps.
    private static func encodeJSON(_ object: Any) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Request Construction

    /// With no stored reward, `ensureReward` POSTs a new one with the right auth headers and
    /// body (title, cost, user input required, created disabled), then stores its id and owner.
    func testEnsureRewardCreatesRewardWhenNoStoredID() async throws {
        let captured = ThreadSafeBox<URLRequest?>(nil)
        handlerStore.handler = { request in
            captured.value = request
            let body: [String: Any] = ["data": [["id": "reward_new"]]]
            return (
                MockURLProtocol.httpResponse(for: request, status: 200),
                Self.encodeJSON(body)
            )
        }

        let service = makeService()
        let rewardID = try await service.ensureReward(credentials: creds, cost: 500)

        XCTAssertEqual(rewardID, "reward_new")
        XCTAssertEqual(DefaultsStore.store.string(forKey: storageKey), "reward_new")
        XCTAssertEqual(
            TwitchManagedRewardStore.snapshot(),
            .owned(
                .init(
                    rewardID: "reward_new",
                    broadcasterID: "12345")))

        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(request.httpMethod, "POST")
        let url = try XCTUnwrap(request.url)
        XCTAssertTrue(url.path.hasSuffix("/channel_points/custom_rewards"))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.queryItems?.first(where: { $0.name == "broadcaster_id" })?.value, "12345")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok_abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Client-Id"), "client_xyz")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let payload = Self.bodyJSON(request)
        XCTAssertEqual(payload["title"] as? String, AppConstants.Twitch.songRequestRewardTitle)
        XCTAssertEqual(payload["cost"] as? Int, 500)
        XCTAssertEqual(payload["is_user_input_required"] as? Bool, true)
        XCTAssertEqual(payload["is_enabled"] as? Bool, false)
        XCTAssertNotNil(payload["prompt"] as? String)
    }

    /// Listing unfulfilled redemptions asks for oldest-first pages of 50 for this reward,
    /// follows the pagination cursor, and returns each id once even if it repeats across pages.
    func testUnfulfilledRedemptionsPaginatesOldestFirstAndDeduplicates() async throws {
        storeManagedReward("reward_abc")
        let captured = ThreadSafeBox<[URLRequest]>([])
        handlerStore.handler = { request in
            captured.mutate { $0.append(request) }
            let components = request.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)
            }
            let after = components?.queryItems?.first(where: { $0.name == "after" })?.value
            let body: [String: Any]
            if after == nil {
                body = [
                    "data": [
                        ["id": "redemption-1"],
                        ["id": "redemption-2"]
                    ],
                    "pagination": ["cursor": "next-page"]
                ]
            } else {
                body = [
                    "data": [
                        ["id": "redemption-2"],
                        ["id": "redemption-3"]
                    ],
                    "pagination": [String: Any]()
                ]
            }
            return (
                MockURLProtocol.httpResponse(for: request, status: 200),
                Self.encodeJSON(body)
            )
        }

        let ids = try await makeService().unfulfilledRedemptionIDs(
            credentials: creds,
            rewardID: "reward_abc")

        XCTAssertEqual(ids, ["redemption-1", "redemption-2", "redemption-3"])
        XCTAssertEqual(captured.value.count, 2)
        let requests = captured.value
        for request in requests {
            XCTAssertEqual(request.httpMethod, "GET")
            let components = try XCTUnwrap(
                URLComponents(
                    url: try XCTUnwrap(request.url),
                    resolvingAgainstBaseURL: false))
            XCTAssertTrue(
                components.path.hasSuffix(
                    "/channel_points/custom_rewards/redemptions"))
            let items = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map {
                    ($0.name, $0.value ?? "")
                })
            XCTAssertEqual(items["broadcaster_id"], "12345")
            XCTAssertEqual(items["reward_id"], "reward_abc")
            XCTAssertEqual(items["status"], "UNFULFILLED")
            XCTAssertEqual(items["sort"], "OLDEST")
            XCTAssertEqual(items["first"], "50")
        }
        let first = try XCTUnwrap(
            URLComponents(
                url: try XCTUnwrap(requests.first?.url),
                resolvingAgainstBaseURL: false))
        let second = try XCTUnwrap(
            URLComponents(
                url: try XCTUnwrap(requests.last?.url),
                resolvingAgainstBaseURL: false))
        XCTAssertNil(first.queryItems?.first(where: { $0.name == "after" }))
        XCTAssertEqual(
            second.queryItems?.first(where: { $0.name == "after" })?.value,
            "next-page")
    }

    func testUnfulfilledRedemptionsRejectsMalformedCursor() async {
        storeManagedReward("reward_abc")
        handlerStore.handler = { request in
            let body: [String: Any] = [
                "data": [["id": "redemption"]],
                "pagination": ["cursor": 42]
            ]
            return (
                MockURLProtocol.httpResponse(for: request, status: 200),
                Self.encodeJSON(body)
            )
        }

        do {
            _ = try await makeService().unfulfilledRedemptionIDs(
                credentials: creds,
                rewardID: "reward_abc")
            XCTFail("Expected .malformedResponse")
        } catch TwitchChannelPointsService.RewardError.malformedResponse {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// `isRedemptionUnfulfilled` is true only while Helix reports `UNFULFILLED`.
    func testRedemptionStatusLookupDistinguishesUnfulfilledAndResolved() async throws {
        storeManagedReward("reward_abc")
        let status = ThreadSafeBox("UNFULFILLED")
        handlerStore.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "id" })?.value,
                "redemption_123")
            return (
                MockURLProtocol.httpResponse(for: request, status: 200),
                Self.encodeJSON(["data": [["id": "redemption_123", "status": status.value]]])
            )
        }

        let service = makeService()
        let isUnfulfilled = try await service.isRedemptionUnfulfilled(
            credentials: creds,
            rewardID: "reward_abc",
            redemptionID: "redemption_123")
        XCTAssertTrue(isUnfulfilled)
        status.value = "FULFILLED"
        let isStillUnfulfilled = try await service.isRedemptionUnfulfilled(
            credentials: creds,
            rewardID: "reward_abc",
            redemptionID: "redemption_123")
        XCTAssertFalse(isStillUnfulfilled)
    }

    /// A Helix failure on the status lookup throws `RedemptionResolutionError`,
    /// the same type as the ownership check before it.
    func testRedemptionStatusLookupThrowsResolutionErrorOnHelixFailure() async {
        storeManagedReward("reward_abc")
        handlerStore.handler = { request in
            (MockURLProtocol.httpResponse(for: request, status: 500), Data("boom".utf8))
        }

        let service = makeService()
        do {
            _ = try await service.isRedemptionUnfulfilled(
                credentials: creds,
                rewardID: "reward_abc",
                redemptionID: "redemption_123")
            XCTFail("Expected an error")
        } catch let TwitchChannelPointsService.RedemptionResolutionError.http(status, _, _) {
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testUnfulfilledRedemptionsRejectsRepeatedCursor() async {
        storeManagedReward("reward_abc")
        handlerStore.handler = { request in
            let body: [String: Any] = [
                "data": [["id": UUID().uuidString]],
                "pagination": ["cursor": "stuck"]
            ]
            return (
                MockURLProtocol.httpResponse(for: request, status: 200),
                Self.encodeJSON(body)
            )
        }

        do {
            _ = try await makeService().unfulfilledRedemptionIDs(
                credentials: creds,
                rewardID: "reward_abc")
            XCTFail("Expected .malformedResponse")
        } catch TwitchChannelPointsService.RewardError.malformedResponse {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUpdateRewardCostSendsPatchWithCorrectQueryAndBody() async throws {
        storeManagedReward("reward_abc")
        let captured = ThreadSafeBox<URLRequest?>(nil)
        handlerStore.handler = { request in
            captured.value = request
            return (MockURLProtocol.httpResponse(for: request, status: 204), Data())
        }

        try await makeService().updateRewardCost(
            credentials: creds, rewardID: "reward_abc", cost: 1000)

        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(request.httpMethod, "PATCH")
        let comps = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let items = Dictionary(
            uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["broadcaster_id"], "12345")
        XCTAssertEqual(items["id"], "reward_abc")

        let payload = Self.bodyJSON(request)
        XCTAssertEqual(payload["cost"] as? Int, 1000)
    }

    /// Resolving as `.fulfilled` PATCHes the redemption (by broadcaster, reward, and id) with
    /// status `FULFILLED`.
    func testResolveRedemptionFulfilledSendsFULFILLED() async throws {
        storeManagedReward("reward_abc")
        let captured = ThreadSafeBox<URLRequest?>(nil)
        handlerStore.handler = { request in
            captured.value = request
            return (MockURLProtocol.httpResponse(for: request, status: 204), Data())
        }

        try await makeService().resolveRedemptionWithMetadata(
            credentials: creds,
            rewardID: "reward_abc",
            redemptionID: "redemp_1",
            as: .fulfilled
        )

        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(request.httpMethod, "PATCH")
        let comps = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertTrue(comps.path.hasSuffix("/channel_points/custom_rewards/redemptions"))
        let items = Dictionary(
            uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["broadcaster_id"], "12345")
        XCTAssertEqual(items["reward_id"], "reward_abc")
        XCTAssertEqual(items["id"], "redemp_1")

        XCTAssertEqual(Self.bodyJSON(request)["status"] as? String, "FULFILLED")
    }

    func testResolveRedemptionCanceledSendsCANCELED() async throws {
        storeManagedReward("reward_abc")
        let captured = ThreadSafeBox<URLRequest?>(nil)
        handlerStore.handler = { request in
            captured.value = request
            return (MockURLProtocol.httpResponse(for: request, status: 204), Data())
        }

        try await makeService().resolveRedemptionWithMetadata(
            credentials: creds,
            rewardID: "reward_abc",
            redemptionID: "redemp_2",
            as: .canceled
        )

        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(Self.bodyJSON(request)["status"] as? String, "CANCELED")
    }

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
