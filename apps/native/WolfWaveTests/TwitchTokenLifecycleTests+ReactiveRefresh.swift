//
//  TwitchTokenLifecycleTests+ReactiveRefresh.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// Reactive refresh: single flight, Retry-After, malformed responses, and stale credentials.
extension TwitchTokenLifecycleTests {
    /// A reactive refresh stores both new tokens and keeps the stored channel.
    func testReactiveRefreshPersistsNewTokens() async throws {
        await TwitchTokenRefresher.invalidateSession()
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "OLD_AT", refreshToken: "OLD_RT", channelID: "channel")
        )
        handlerStore.handler = { request in
            let json = #"{"access_token":"NEW_AT","refresh_token":"NEW_RT"}"#
            return (MockURLProtocol.httpResponse(for: request, status: 200), Data(json.utf8))
        }

        let result = try await TwitchTokenRefresher.attemptReactiveRefresh(
            clientID: "test-client",
            session: MockURLProtocol.makeSession(handlerStore: handlerStore),
            maxTransientAttempts: 1
        )

        XCTAssertEqual(result, .refreshed("NEW_AT"))
        XCTAssertEqual(KeychainService.loadTwitchToken(), "NEW_AT")
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant().refreshToken, "NEW_RT")
        XCTAssertEqual(KeychainService.loadTwitchChannelID(), "channel")
    }

    /// A second caller arriving while a refresh is in flight joins it (one network
    /// request, same result for both), because refresh tokens are single-use.
    func testConcurrentRefreshCallersShareOneNetworkFlight() async throws {
        await TwitchTokenRefresher.invalidateSession()
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "OLD_AT", refreshToken: "OLD_RT")
        )
        let requestEntered = DispatchSemaphore(value: 0)
        let releaseResponse = DispatchSemaphore(value: 0)
        let secondJoined = DispatchSemaphore(value: 0)
        let attempts = ThreadSafeBox(0)
        let handler: MockURLProtocol.Handler = { request in
            attempts.mutate { $0 += 1 }
            requestEntered.signal()
            guard releaseResponse.wait(timeout: .now() + 2) == .success else {
                throw URLError(.timedOut)
            }
            return (
                MockURLProtocol.httpResponse(for: request, status: 200),
                Data(#"{"access_token":"NEW_AT","refresh_token":"NEW_RT"}"#.utf8)
            )
        }
        let session = MockURLProtocol.makeSession(handler: handler)

        let first = Task {
            try await TwitchTokenRefresher.attemptReactiveRefresh(
                clientID: "test-client",
                session: session
            )
        }
        let entered = await waitForSemaphore(
            requestEntered,
            timeout: .now() + 2
        )
        XCTAssertTrue(entered)

        let second = Task {
            try await TwitchTokenRefresher.attemptReactiveRefresh(
                clientID: "test-client",
                session: session,
                onJoinedExistingFlight: { secondJoined.signal() }
            )
        }
        let joined = await waitForSemaphore(
            secondJoined,
            timeout: .now() + 2
        )
        XCTAssertTrue(joined)
        releaseResponse.signal()

        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult, .refreshed("NEW_AT"))
        XCTAssertEqual(secondResult, .refreshed("NEW_AT"))
        XCTAssertEqual(attempts.value, 1)
    }

    /// A refresh response that lands after the account was replaced is discarded
    /// (`.superseded`) and the replacement account's tokens stay stored.
    func testStaleRefreshResponseCannotOverwriteReplacementAccount() async throws {
        await TwitchTokenRefresher.invalidateSession()
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "OLD_AT", refreshToken: "OLD_RT")
        )
        let expected = try XCTUnwrap(
            TwitchCredentialStore.shared
                .connectionSnapshot(
                    matchingAccessToken: "OLD_AT"
                )?.accessExpectation
        )
        let requestEntered = DispatchSemaphore(value: 0)
        let releaseResponse = DispatchSemaphore(value: 0)
        let handler: MockURLProtocol.Handler = { request in
            requestEntered.signal()
            guard releaseResponse.wait(timeout: .now() + 2) == .success else {
                throw URLError(.timedOut)
            }
            return (
                MockURLProtocol.httpResponse(for: request, status: 200),
                Data(#"{"access_token":"STALE_AT","refresh_token":"STALE_RT"}"#.utf8)
            )
        }

        let session = MockURLProtocol.makeSession(handler: handler)
        let refresh = Task {
            try await TwitchTokenRefresher.attemptReactiveRefresh(
                clientID: "test-client",
                expected: expected,
                session: session
            )
        }
        let entered = await waitForSemaphore(
            requestEntered,
            timeout: .now() + 2
        )
        XCTAssertTrue(entered)

        let replacementRevision = TwitchCredentialStore.shared.supersede()
        let replacement = TwitchTokenResponse(
            accessToken: "NEW_ACCOUNT_AT",
            refreshToken: "NEW_ACCOUNT_RT",
            expiresIn: nil
        )
        XCTAssertTrue(
            try TwitchCredentialStore.shared.commitDeviceGrant(
                replacement,
                expectedRevision: replacementRevision
            )
        )
        releaseResponse.signal()

        let result = try await refresh.value
        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(KeychainService.loadTwitchToken(), "NEW_ACCOUNT_AT")
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant().refreshToken, "NEW_ACCOUNT_RT")
    }

    /// A 429 with `Retry-After: 12` is waited out via the injected sleeper (no real delay), then
    /// the retry succeeds.
    func testReactiveRefreshHonorsRetryAfterThenSucceeds() async throws {
        await TwitchTokenRefresher.invalidateSession()
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "OLD_AT", refreshToken: "OLD_RT")
        )
        let attempts = ThreadSafeBox(0)
        let delays = ThreadSafeBox<[Duration]>([])
        let handler: MockURLProtocol.Handler = { request in
            let attempt = attempts.value
            attempts.value = attempt + 1
            if attempt == 0 {
                return (
                    MockURLProtocol.httpResponse(
                        for: request, status: 429, headers: ["Retry-After": "12"]),
                    Data())
            }
            return (
                MockURLProtocol.httpResponse(for: request, status: 200),
                Data(#"{"access_token":"NEW_AT","refresh_token":"NEW_RT"}"#.utf8))
        }

        let result = try await TwitchTokenRefresher.attemptReactiveRefresh(
            clientID: "test-client",
            session: MockURLProtocol.makeSession(handler: handler),
            sleep: { delay in delays.mutate { $0.append(delay) } })

        XCTAssertEqual(result, .refreshed("NEW_AT"))
        XCTAssertEqual(delays.value, [.seconds(12)])
    }

    /// A 403 from the token endpoint is permanent: one attempt, no backoff sleep, result
    /// `.invalid`, and the stored refresh token is kept.
    func testReactiveRefreshDoesNotRetryPermanentStatus() async throws {
        await TwitchTokenRefresher.invalidateSession()
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "OLD_AT", refreshToken: "OLD_RT")
        )
        let attempts = ThreadSafeBox(0)
        let delays = ThreadSafeBox<[Duration]>([])
        handlerStore.handler = { request in
            attempts.mutate { $0 += 1 }
            return (MockURLProtocol.httpResponse(for: request, status: 403), Data())
        }

        let result = try await TwitchTokenRefresher.attemptReactiveRefresh(
            clientID: "test-client",
            session: MockURLProtocol.makeSession(handlerStore: handlerStore),
            sleep: { delay in delays.mutate { $0.append(delay) } })

        XCTAssertEqual(result, .invalid)
        XCTAssertEqual(attempts.value, 1)
        XCTAssertTrue(delays.value.isEmpty)
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant().refreshToken, "OLD_RT")
    }

    /// A 200 that lacks a refresh token is treated as a transient failure: retried with
    /// backoff (250 ms, then 500 ms) and, when it never completes, reports
    /// `.temporarilyUnavailable` while the stored grant is left as it was.
    func testMalformedRefreshSuccessRetriesWithoutReplacingStoredGrant() async throws {
        await TwitchTokenRefresher.invalidateSession()
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "OLD_AT", refreshToken: "OLD_RT")
        )
        let attempts = ThreadSafeBox(0)
        let delays = ThreadSafeBox<[Duration]>([])
        handlerStore.handler = { request in
            attempts.mutate { $0 += 1 }
            return (
                MockURLProtocol.httpResponse(for: request, status: 200),
                Data(#"{"access_token":"NEW_AT"}"#.utf8))
        }

        let result = try await TwitchTokenRefresher.attemptReactiveRefresh(
            clientID: "test-client",
            session: MockURLProtocol.makeSession(handlerStore: handlerStore),
            maxTransientAttempts: 3,
            sleep: { delay in delays.mutate { $0.append(delay) } }
        )

        XCTAssertEqual(result, .temporarilyUnavailable)
        XCTAssertEqual(attempts.value, 3)
        XCTAssertEqual(delays.value, [.milliseconds(250), .milliseconds(500)])
        XCTAssertEqual(KeychainService.loadTwitchToken(), "OLD_AT")
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant().refreshToken, "OLD_RT")
    }

    /// Same malformed first response, but a valid second response is adopted after one backoff.
    func testMalformedRefreshSuccessRecoversOnValidRetry() async throws {
        await TwitchTokenRefresher.invalidateSession()
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "OLD_AT", refreshToken: "OLD_RT")
        )
        let attempts = ThreadSafeBox(0)
        let delays = ThreadSafeBox<[Duration]>([])
        handlerStore.handler = { request in
            let attempt = attempts.value
            attempts.mutate { $0 += 1 }
            let body = attempt == 0
                ? #"{"access_token":"INCOMPLETE_AT"}"#
                : #"{"access_token":"NEW_AT","refresh_token":"NEW_RT"}"#
            return (
                MockURLProtocol.httpResponse(for: request, status: 200),
                Data(body.utf8)
            )
        }

        let result = try await TwitchTokenRefresher.attemptReactiveRefresh(
            clientID: "test-client",
            session: MockURLProtocol.makeSession(handlerStore: handlerStore),
            maxTransientAttempts: 3,
            sleep: { delay in delays.mutate { $0.append(delay) } }
        )

        XCTAssertEqual(result, .refreshed("NEW_AT"))
        XCTAssertEqual(attempts.value, 2)
        XCTAssertEqual(delays.value, [.milliseconds(250)])
        XCTAssertEqual(KeychainService.loadTwitchToken(), "NEW_AT")
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant().refreshToken, "NEW_RT")
    }

    func testReactiveRefreshReturnsInvalidWithoutStoredRefreshToken() async throws {
        await TwitchTokenRefresher.invalidateSession()
        XCTAssertNil(KeychainService.loadTwitchCredentialGrant().refreshToken)
        // No handler is installed, so any network attempt would surface as a
        // transport failure rather than `.invalid`.
        let result = try await TwitchTokenRefresher.attemptReactiveRefresh(
            clientID: "test-client",
            session: MockURLProtocol.makeSession(handlerStore: handlerStore)
        )
        XCTAssertEqual(result, .invalid)
    }

    func testReactiveRefreshReturnsInvalidWithEmptyClientID() async throws {
        await TwitchTokenRefresher.invalidateSession()
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "AT", refreshToken: "RT")
        )
        let result = try await TwitchTokenRefresher.attemptReactiveRefresh(
            clientID: "",
            session: MockURLProtocol.makeSession(handlerStore: handlerStore)
        )
        XCTAssertEqual(result, .invalid)
    }

    /// If the caller's expected credential is already replaced, the refresher returns
    /// `.superseded` without making any network request, so it can never spend the new
    /// account's refresh token.
    func testStaleExpectedCredentialDoesNotStartReplacementAccountRefresh() async throws {
        await TwitchTokenRefresher.invalidateSession()
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "OLD_AT", refreshToken: "OLD_RT")
        )
        let expected = try XCTUnwrap(
            TwitchCredentialStore.shared
                .connectionSnapshot(
                    matchingAccessToken: "OLD_AT"
                )?.accessExpectation
        )

        let replacementRevision = TwitchCredentialStore.shared.supersede()
        XCTAssertTrue(
            try TwitchCredentialStore.shared.commitDeviceGrant(
                TwitchTokenResponse(
                    accessToken: "NEW_ACCOUNT_AT",
                    refreshToken: "NEW_ACCOUNT_RT",
                    expiresIn: nil
                ),
                expectedRevision: replacementRevision
            )
        )

        let attempts = ThreadSafeBox(0)
        let result = try await TwitchTokenRefresher.attemptReactiveRefresh(
            clientID: "test-client",
            expected: expected,
            session: MockURLProtocol.makeSession { request in
                attempts.mutate { $0 += 1 }
                return (
                    MockURLProtocol.httpResponse(for: request, status: 500),
                    Data()
                )
            }
        )

        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(attempts.value, 0)
        XCTAssertEqual(KeychainService.loadTwitchToken(), "NEW_ACCOUNT_AT")
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant().refreshToken, "NEW_ACCOUNT_RT")
    }
}
