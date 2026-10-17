//
//  TwitchDeviceAuthNetworkTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-22.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// A monotonic clock/sleeper pair that advances instantly when production code
/// asks it to sleep. This makes multi-poll OAuth tests deterministic.
nonisolated final class DeviceAuthVirtualClock: @unchecked Sendable {
    private struct State {
        var instant: ContinuousClock.Instant
        var delays: [Duration] = []
    }

    private let state = ThreadSafeBox(State(instant: ContinuousClock.now))

    var now: ContinuousClock.Instant {
        state.value.instant
    }

    var delays: [Duration] {
        state.value.delays
    }

    func advance(by duration: Duration) {
        state.mutate {
            $0.instant = $0.instant.advanced(by: duration)
        }
    }

    func sleep(for delay: Duration, tolerance _: Duration?) async throws {
        try Task.checkCancellation()
        state.mutate {
            $0.instant = $0.instant.advanced(by: delay)
            $0.delays.append(delay)
        }
        await Task.yield()
        try Task.checkCancellation()
    }
}

// MARK: - TwitchDeviceAuthNetworkTests

/// Covers `TwitchDeviceAuth` OAuth Device Code networking: device-code
/// requests and deadline-bounded multi-shot token polling, driven by
/// `MockURLProtocol` and a virtual monotonic clock.
@MainActor
final class TwitchDeviceAuthNetworkTests: XCTestCase {

    let handlerStore = MockURLProtocol.HandlerStore()

    override func setUp() {
        super.setUp()
        handlerStore.handler = nil
    }

    override func tearDown() {
        handlerStore.handler = nil
        super.tearDown()
    }

    func makeAuth(
        clientID: String = "test-client",
        clock: DeviceAuthVirtualClock = DeviceAuthVirtualClock()
    ) -> TwitchDeviceAuth {
        TwitchDeviceAuth(
            clientID: clientID,
            scopes: ["user:read:chat"],
            session: MockURLProtocol.makeSession(handlerStore: handlerStore),
            pollingNow: { clock.now },
            pollingSleep: { delay, tolerance in
                try await clock.sleep(for: delay, tolerance: tolerance)
            }
        )
    }

    nonisolated static func nextAttempt(_ counter: ThreadSafeBox<Int>) -> Int {
        var next = 0
        counter.mutate {
            $0 += 1
            next = $0
        }
        return next
    }

    // MARK: - requestDeviceCode

    func testRequestDeviceCodeParsesResponse() async throws {
        let requestBody = ThreadSafeBox("")
        handlerStore.handler = { request in
            requestBody.value = requestBodyString(request)
            let json = #"{"device_code":"DEV","user_code":"WXYZ","verification_uri":"https://twitch.tv/activate","verification_uri_complete":"https://twitch.tv/activate?code=WXYZ","expires_in":600,"interval":5}"#
            return (MockURLProtocol.httpResponse(for: request, status: 200), Data(json.utf8))
        }

        let response = try await makeAuth().requestDeviceCode()

        XCTAssertEqual(response.deviceCode, "DEV")
        XCTAssertEqual(response.userCode, "WXYZ")
        XCTAssertEqual(response.verificationURI, "https://twitch.tv/activate")
        XCTAssertEqual(response.verificationURIComplete, "https://twitch.tv/activate?code=WXYZ")
        XCTAssertEqual(response.expiresIn, 600)
        XCTAssertEqual(response.interval, 5)
        let scopes = URLComponents(
            string: "https://localhost/?\(requestBody.value)"
        )?.queryItems?.first(where: { $0.name == "scopes" })?.value
        XCTAssertEqual(scopes, "user:read:chat")
    }

    func testRequestDeviceCodeDefaultsMissingIntervalToRFCValue() async throws {
        handlerStore.handler = { request in
            let json = #"""
            {
              "device_code": "DEV",
              "user_code": "WXYZ",
              "verification_uri": "https://twitch.tv/activate",
              "expires_in": 1800
            }
            """#
            return (MockURLProtocol.httpResponse(for: request, status: 200), Data(json.utf8))
        }

        let response = try await makeAuth().requestDeviceCode()

        XCTAssertEqual(response.interval, 5)
    }

    /// A device-code response whose `expires_in` or `interval` is `Int64.max` is rejected as
    /// `.invalidResponse` instead of overflowing later timing math.
    func testRequestDeviceCodeRejectsUnsafeTimingMetadata() async {
        let responses = [
            #"""
            {"device_code":"DEV","user_code":"WXYZ","verification_uri":"https://twitch.tv/activate",
             "expires_in":9223372036854775807,"interval":5}
            """#,
            #"""
            {"device_code":"DEV","user_code":"WXYZ","verification_uri":"https://twitch.tv/activate",
             "expires_in":1800,"interval":9223372036854775807}
            """#
        ]

        for json in responses {
            handlerStore.handler = { request in
                (MockURLProtocol.httpResponse(for: request, status: 200), Data(json.utf8))
            }
            do {
                _ = try await makeAuth().requestDeviceCode()
                XCTFail("Expected .invalidResponse")
            } catch TwitchDeviceAuthError.invalidResponse {
                // expected
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRequestDeviceCodeEmptyClientIDThrowsInvalidClient() async {
        do {
            _ = try await makeAuth(clientID: "").requestDeviceCode()
            XCTFail("Expected .invalidClient")
        } catch TwitchDeviceAuthError.invalidClient {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRequestDeviceCode401ThrowsInvalidClient() async {
        handlerStore.handler = { request in
            (MockURLProtocol.httpResponse(for: request, status: 401), Data("unauthorized".utf8))
        }

        do {
            _ = try await makeAuth().requestDeviceCode()
            XCTFail("Expected .invalidClient")
        } catch TwitchDeviceAuthError.invalidClient {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRequestDeviceCodeMalformedJSONThrowsInvalidResponse() async {
        handlerStore.handler = { request in
            (MockURLProtocol.httpResponse(for: request, status: 200),
             Data(#"{"device_code":"only-this"}"#.utf8))
        }

        do {
            _ = try await makeAuth().requestDeviceCode()
            XCTFail("Expected .invalidResponse")
        } catch TwitchDeviceAuthError.invalidResponse {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
