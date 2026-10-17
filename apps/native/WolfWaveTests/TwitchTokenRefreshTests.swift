//
//  TwitchTokenRefreshTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-06-06.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

// MARK: - TwitchTokenRefreshTests

/// Covers refresh-token resilience:
/// - `TwitchDeviceAuth.parseTokenResponse` (pure parse, with/without refresh).
/// - `refreshAccessToken` over `grant_type=refresh_token` (success + failure),
///   driven by `MockURLProtocol`.
/// - `TwitchTokenRefresher.attemptReactiveRefresh` persisting the new tokens via
///   the injectable in-memory Keychain backend (never the real Keychain).
///
/// The live socket orchestration around the refresh is not integration-tested
/// here; a second 401 requests re-auth while transient failures keep backing off.
@MainActor
final class TwitchTokenRefreshTests: WolfWaveTestCase {

    var previousBackend: KeychainBackend!
    var backend: InMemoryKeychainBackend!
    let handlerStore = MockURLProtocol.HandlerStore()

    override func setUp() async throws {
        try await super.setUp()
        handlerStore.handler = nil
        Self.resetRedemptionDefaults()
        previousBackend = KeychainService.backend
        backend = InMemoryKeychainBackend()
        KeychainService.backend = backend
    }

    override func tearDown() async throws {
        Self.resetRedemptionDefaults()
        handlerStore.handler = nil
        KeychainService.backend = previousBackend
        try await super.tearDown()
    }

    /// Removes the Song Request and managed-reward keys these tests write, so each test starts from
    /// defaults.
    nonisolated private static func resetRedemptionDefaults() {
        let defaults = DefaultsStore.store
        [
            AppConstants.UserDefaults.songRequestEnabled,
            AppConstants.UserDefaults.songRequestChannelPointsEnabled,
            AppConstants.UserDefaults.songRequestBitsEnabled,
            AppConstants.UserDefaults.songRequestChannelPointsRewardID,
            AppConstants.UserDefaults.songRequestChannelPointsRewardIdentity,
            AppConstants.UserDefaults.songRequestChannelPointsCost,
            AppConstants.UserDefaults.songRequestRedemptionStatus
        ].forEach { defaults.removeObject(forKey: $0) }
    }

    /// Records `rewardID` as the managed "Request a Song" reward for `broadcasterID` through
    /// `TwitchManagedRewardStore`.
    func storeManagedRewardIdentity(
        rewardID: String,
        broadcasterID: String = "broadcaster"
    ) {
        XCTAssertTrue(
            TwitchManagedRewardStore.store(
                .init(
                    rewardID: rewardID,
                    broadcasterID: broadcasterID),
                replacing: TwitchManagedRewardStore.snapshot()))
    }

    /// Turns on Song Requests and channel-point redemptions (Bits off) and stores `rewardID`, so
    /// `subscribeToRedemptionsIfEnabled()` has a managed reward to reconcile.
    func enableManagedReward(rewardID: String) {
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)
        DefaultsStore.store.set(
            true,
            forKey: AppConstants.UserDefaults.songRequestChannelPointsEnabled)
        DefaultsStore.store.set(
            false,
            forKey: AppConstants.UserDefaults.songRequestBitsEnabled)
        storeManagedRewardIdentity(rewardID: rewardID)
    }

    /// Canned empty page for the "list unfulfilled redemptions" GET, or nil for any other request,
    /// so a handler can answer that fetch and handle only the call it cares about itself.
    nonisolated static func emptyUnfulfilledRedemptionsResponse(
        for request: URLRequest
    ) -> (HTTPURLResponse, Data)? {
        guard request.httpMethod == "GET",
              request.url?.path.hasSuffix("/redemptions") == true else {
            return nil
        }
        return (
            MockURLProtocol.httpResponse(for: request, status: 200),
            Data(#"{"data":[],"pagination":{}}"#.utf8))
    }

    /// A `TwitchDeviceAuth` whose HTTP goes through `handlerStore`'s mock handler.
    func makeAuth(clientID: String = "test-client") -> TwitchDeviceAuth {
        TwitchDeviceAuth(
            clientID: clientID,
            scopes: ["user:read:chat"],
            session: MockURLProtocol.makeSession(handlerStore: handlerStore)
        )
    }

    // MARK: - parseTokenResponse

    func testParseTokenResponseWithRefreshAndExpiry() {
        let json = #"{"access_token":"AT","refresh_token":"RT","expires_in":14400}"#
        let parsed = TwitchDeviceAuth.parseTokenResponse(Data(json.utf8))
        XCTAssertEqual(parsed?.accessToken, "AT")
        XCTAssertEqual(parsed?.refreshToken, "RT")
        XCTAssertEqual(parsed?.expiresIn, 14400)
    }

    func testParseTokenResponseMissingRefreshIsNil() {
        let json = #"{"access_token":"AT"}"#
        let parsed = TwitchDeviceAuth.parseTokenResponse(Data(json.utf8))
        XCTAssertEqual(parsed?.accessToken, "AT")
        XCTAssertNil(parsed?.refreshToken)
        XCTAssertNil(parsed?.expiresIn)
    }

    func testParseTokenResponseEmptyRefreshTreatedAsNil() {
        let json = #"{"access_token":"AT","refresh_token":""}"#
        XCTAssertNil(TwitchDeviceAuth.parseTokenResponse(Data(json.utf8))?.refreshToken)
    }

    func testParseTokenResponseMissingAccessTokenReturnsNil() {
        let json = #"{"refresh_token":"RT"}"#
        XCTAssertNil(TwitchDeviceAuth.parseTokenResponse(Data(json.utf8)))
    }

    func testParseTokenResponseGarbageReturnsNil() {
        XCTAssertNil(TwitchDeviceAuth.parseTokenResponse(Data("not json".utf8)))
    }

    // MARK: - refreshAccessToken

    func testRefreshAccessTokenSuccess() async throws {
        handlerStore.handler = { request in
            let json = #"{"access_token":"NEW_AT","refresh_token":"NEW_RT","expires_in":14400}"#
            return (MockURLProtocol.httpResponse(for: request, status: 200), Data(json.utf8))
        }

        let response = try await makeAuth().refreshAccessToken(refreshToken: "OLD_RT")
        XCTAssertEqual(response.accessToken, "NEW_AT")
        XCTAssertEqual(response.refreshToken, "NEW_RT")
    }

    /// Reads a URLProtocol-intercepted request body. Prefers `httpBody` when the
    /// transport set it; otherwise falls back to draining `httpBodyStream` (how
    /// `URLProtocol` typically exposes the body), so the assertion is robust
    /// across either representation.
    nonisolated static func bodyString(of request: URLRequest) -> String {
        if let body = request.httpBody, !body.isEmpty {
            return String(data: body, encoding: .utf8) ?? ""
        }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var buffer = Data()
        let size = 1024
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { bytes.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(bytes, maxLength: size)
            if read > 0 { buffer.append(bytes, count: read) }
            if read <= 0 { break }
        }
        return String(data: buffer, encoding: .utf8) ?? ""
    }

    /// First query-string value named `name` in the request URL, or nil.
    nonisolated static func queryValue(
        _ name: String,
        in request: URLRequest
    ) -> String? {
        request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }?.queryItems?.first(where: { $0.name == name })?.value
    }

    func testRefreshAccessTokenSendsGrantTypeRefreshToken() async throws {
        nonisolated(unsafe) var captured = ""
        handlerStore.handler = { request in
            captured = Self.bodyString(of: request)
            let json = #"{"access_token":"NEW_AT","refresh_token":"NEW_RT"}"#
            return (MockURLProtocol.httpResponse(for: request, status: 200), Data(json.utf8))
        }

        _ = try await makeAuth().refreshAccessToken(refreshToken: "OLD_RT")

        XCTAssertTrue(captured.contains("grant_type=refresh_token"), "body: \(captured)")
        XCTAssertTrue(captured.contains("refresh_token=OLD_RT"), "body: \(captured)")
    }

    func testRefreshAccessTokenEmptyRefreshThrows() async {
        do {
            _ = try await makeAuth().refreshAccessToken(refreshToken: "")
            XCTFail("Expected throw")
        } catch TwitchDeviceAuthError.invalidResponse {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRefreshAccessTokenDeadRefreshThrowsInvalidClient() async {
        handlerStore.handler = { request in
            let json = #"{"error":"invalid_grant","message":"Invalid refresh token"}"#
            return (MockURLProtocol.httpResponse(for: request, status: 400), Data(json.utf8))
        }

        do {
            _ = try await makeAuth().refreshAccessToken(refreshToken: "DEAD")
            XCTFail("Expected throw")
        } catch TwitchDeviceAuthError.invalidClient {
            // expected: caller falls back to interactive re-auth
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRefreshAccessTokenServerErrorPreservesStatus() async {
        handlerStore.handler = { request in
            (MockURLProtocol.httpResponse(for: request, status: 500), Data("boom".utf8))
        }

        do {
            _ = try await makeAuth().refreshAccessToken(refreshToken: "RT")
            XCTFail("Expected throw")
        } catch TwitchDeviceAuthError.http(let status, let retryAfter) {
            XCTAssertEqual(status, 500)
            XCTAssertNil(retryAfter)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRefreshAccessTokenRequiresRotatedRefreshToken() async {
        handlerStore.handler = { request in
            (
                MockURLProtocol.httpResponse(for: request, status: 200),
                Data(#"{"access_token":"NEW_AT"}"#.utf8))
        }

        do {
            _ = try await makeAuth().refreshAccessToken(refreshToken: "OLD_RT")
            XCTFail("Expected .invalidResponse")
        } catch TwitchDeviceAuthError.invalidResponse {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Keychain accessor round-trip

    /// If the Keychain write for the rotated grant fails once, the commit is retried
    /// locally: the refresh succeeds with a single network call, and the new refresh token is
    /// stored.
    func testRefreshCommitRetriesOnKeychainFailure() async throws {
        await TwitchTokenRefresher.invalidateSession()
        let failingBackend = InspectableKeychainBackend()
        KeychainService.backend = failingBackend
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "old-access", refreshToken: "old-refresh"))
        failingBackend.failNextSave(for: KeychainService.twitchCredentialGrantAccount)
        let calls = ThreadSafeBox(0)
        handlerStore.handler = { request in
            calls.mutate { $0 += 1 }
            return (MockURLProtocol.httpResponse(for: request, status: 200),
                    Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8))
        }
        let result = try await TwitchTokenRefresher.attemptReactiveRefresh(
            clientID: "test-client", session: MockURLProtocol.makeSession(handlerStore: handlerStore),
            sleep: { _ in })
        XCTAssertEqual(result, .refreshed("new-access"))
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant().refreshToken, "new-refresh")
        XCTAssertEqual(calls.value, 1)
    }

    /// Refresh tokens are single-use, so a rotated pair that could not be stored is kept in
    /// memory. After a refresh reports `.temporarilyUnavailable`, the next call commits the held
    /// tokens without another network request (one call total) instead of spending the dead old
    /// token.
    func testHeldRotatedTokenCommittedBeforeNextRefresh() async throws {
        await TwitchTokenRefresher.invalidateSession()
        let failingBackend = InspectableKeychainBackend()
        KeychainService.backend = failingBackend
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "old-access", refreshToken: "old-refresh"))
        failingBackend.failNextSave(for: KeychainService.twitchCredentialGrantAccount)
        let calls = ThreadSafeBox(0)
        handlerStore.handler = { request in
            calls.mutate { $0 += 1 }
            return (MockURLProtocol.httpResponse(for: request, status: 200),
                    Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8))
        }
        let session = MockURLProtocol.makeSession(handlerStore: handlerStore)
        let first = try await TwitchTokenRefresher.attemptReactiveRefresh(
            clientID: "test-client", session: session,
            sleep: { _ in
                failingBackend.failNextSave(for: KeychainService.twitchCredentialGrantAccount)
            })
        XCTAssertEqual(first, .temporarilyUnavailable)
        let second = try await TwitchTokenRefresher.attemptReactiveRefresh(
            clientID: "test-client", session: session, sleep: { _ in })
        XCTAssertEqual(second, .refreshed("new-access"))
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant().refreshToken, "new-refresh")
    }

    func testRefreshTokenKeychainRoundTrip() throws {
        XCTAssertNil(KeychainService.loadTwitchCredentialGrant().refreshToken)
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "AT-123", refreshToken: "RT-123")
        )
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant().refreshToken, "RT-123")
        try KeychainService.deleteTwitchCredentialGrant()
        XCTAssertNil(KeychainService.loadTwitchCredentialGrant().refreshToken)
    }
}

/// The actor's active and reconnect tokens, read through `refreshActorStateForTesting()`.
nonisolated struct TwitchRefreshActorSnapshot: Sendable {
    let oauthToken: String?
    let reconnectToken: String?
}

/// The identity fields the managed-redemption flow runs under, read through
/// `managedRedemptionIdentityForTesting()`.
nonisolated struct ManagedRedemptionIdentitySnapshot: Sendable {
    let broadcasterID: String?
    let botID: String?
    let oauthToken: String?
    let clientID: String?
}

/// Which of two EventSub sockets is the live one, and whether a reconnect task is pending.
nonisolated struct EventSubTransportSnapshot: Sendable {
    let sourceIsCurrent: Bool
    let targetIsCurrent: Bool
    let hasReconnectTask: Bool
}

/// Test-only seams on `TwitchChatService` (same-module access to actor state) for the
/// redemption teardown gate: run a reward unpause under a setup lease, install a fake
/// live intake task, and await paid-redemption tasks.
extension TwitchChatService {
    /// Unpauses `rewardID` while holding a `TwitchRedemptionTeardownGate` setup lease, the way
    /// setup does, so a teardown must wait for it. Throws `CancellationError` if the service has no
    /// identity yet.
    func runManagedRewardUnpauseUnderSetupLeaseForTesting(
        rewardID: String
    ) async throws {
        guard let broadcasterID,
              let oauthToken,
              let clientID,
              let lease = TwitchRedemptionTeardownGate.beginSetup(
                serviceID: ObjectIdentifier(self),
                broadcasterID: broadcasterID,
                generation: channelOwnershipGeneration) else {
            throw CancellationError()
        }
        defer { TwitchRedemptionTeardownGate.endSetup(lease) }
        try await channelPointsService.setRewardPaused(
            credentials: .init(
                broadcasterID: broadcasterID,
                token: oauthToken,
                clientID: clientID),
            rewardID: rewardID,
            paused: false)
    }

    /// Registers `operation` as the in-flight live intake task for `item`, removed again when it
    /// finishes.
    func installTeardownLiveIntakeForTesting(
        item: TwitchRedemptionResolutionOutbox.Item,
        operation: @escaping @Sendable () async -> Void
    ) {
        redemptionTasks[item.id] = Task { [weak self] in
            await operation()
            await self?.finishTeardownLiveIntakeForTesting(item.id)
        }
    }

    func finishTeardownLiveIntakeForTesting(_ id: UUID) {
        redemptionTasks[id] = nil
    }

    /// Waits for every task in `paidRedemptionTasks`.
    func awaitPaidRedemptionTasksForTeardownTesting() async {
        let tasks = Array(paidRedemptionTasks.values)
        for task in tasks {
            await task.value
        }
    }

    /// Waits for every fulfill/refund worker task, so assertions run after replay has settled.
    func awaitRedemptionResolutionWorkersForTesting() async {
        let workers = Array(redemptionResolutionTasks.values)
        for worker in workers {
            await worker.value
        }
    }

    /// Starts a connection attempt and sets the identity (broadcaster doubles as bot), token,
    /// client id, and EventSub session id that managed-reward setup reads.
    func configureManagedRedemptionSessionForTesting(
        broadcasterID: String = "broadcaster",
        token: String = "ACCESS",
        clientID: String = "client",
        sessionID: String = "eventsub-session"
    ) {
        _ = beginConnectionAttempt()
        self.broadcasterID = broadcasterID
        botID = broadcasterID
        oauthToken = token
        self.clientID = clientID
        self.sessionID = sessionID
    }

    func managedRedemptionIdentityForTesting() -> ManagedRedemptionIdentitySnapshot {
        ManagedRedemptionIdentitySnapshot(
            broadcasterID: broadcasterID,
            botID: botID,
            oauthToken: oauthToken,
            clientID: clientID)
    }

    func reconnectChannelForTesting() -> String? {
        reconnectChannelName
    }

    /// Sets the active and reconnect token to `token`. If `staleReconnectCancelled` is given, also
    /// parks a reconnect task that sets it when it is cancelled (proving adoption replaced it).
    func installRefreshAdoptionStateForTesting(
        token: String,
        staleReconnectCancelled: ThreadSafeBox<Bool>? = nil
    ) {
        oauthToken = token
        reconnectToken = token
        reconnectChannelName = "channel"
        reconnectClientID = "client"
        guard let staleReconnectCancelled else { return }
        reconnectTask = Task {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                // Cancellation is the expected signal when adoption reschedules.
            }
            if Task.isCancelled {
                staleReconnectCancelled.set(true)
            }
        }
    }

    func refreshActorStateForTesting() -> TwitchRefreshActorSnapshot {
        TwitchRefreshActorSnapshot(
            oauthToken: oauthToken,
            reconnectToken: reconnectToken
        )
    }

    func cancelRefreshReconnectForTesting() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    func hasReconnectTaskForTesting() -> Bool {
        reconnectTask != nil
    }

    /// Bumps the channel-ownership generation, as a newer join or leave would, so in-flight work
    /// becomes stale.
    func supersedeChannelOwnershipForTesting() {
        channelOwnershipGeneration &+= 1
    }

    /// Installs `source` as a connected, welcomed chat session with the given identity and a
    /// reconnect channel. Returns its receive context.
    func installLiveChatSessionForTesting(
        _ source: URLSessionWebSocketTask,
        actorToken: String = "OLD_AT",
        broadcasterID: String = "broadcaster",
        botID: String = "bot-user",
        clientID: String = "client",
        reconnectChannel: String = "channel"
    ) -> EventSubReceiveContext {
        _ = beginConnectionAttempt()
        self.broadcasterID = broadcasterID
        self.botID = botID
        oauthToken = actorToken
        self.clientID = clientID
        reconnectChannelName = reconnectChannel
        reconnectToken = actorToken
        reconnectClientID = clientID
        webSocketTask = source
        welcomedWebSocketTask = source
        sessionID = "source-session"
        setConnected(true)
        return EventSubReceiveContext(
            generation: connectionGeneration,
            webSocketTask: source)
    }

    func eventSubTransportSnapshotForTesting(
        source: URLSessionWebSocketTask,
        target: URLSessionWebSocketTask
    ) -> EventSubTransportSnapshot {
        EventSubTransportSnapshot(
            sourceIsCurrent: webSocketTask === source,
            targetIsCurrent: webSocketTask === target,
            hasReconnectTask: reconnectTask != nil)
    }
}

/// Parks the caller in `suspend()` until the test calls `resume()`, so a test can hold
/// an OAuth identity step open and change state at that actor-reentrancy point.
/// `suspended` flips true once the caller has parked.
actor OAuthIdentityGate {
    private(set) var suspended = false
    private var released = false
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        suspended = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            resumeWaiters.append(continuation)
        }
    }

    func resume() {
        released = true
        resumeWaiters.forEach { $0.resume() }
        resumeWaiters.removeAll()
    }
}
