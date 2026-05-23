//
//  WebSocketServerAuthTests.swift
//  WolfWaveTests
//
//  Created by MrDemonWolf, Inc. on 5/23/26.
//

import Network
import XCTest
@testable import WolfWave

/// Integration tests for the WebSocket auth-token gate.
///
/// Each test stands a real `WebSocketServerService` up on a fixed loopback port
/// (`59010`–`59013`), opens a client `NWConnection` configured with — or
/// deliberately missing — the `wolfwave.token.<hex>` subprotocol, and asserts
/// the service's `connectionCount` snapshot reflects whether the handshake
/// passed auth.
final class WebSocketServerAuthTests: XCTestCase, @unchecked Sendable {

    // MARK: - Helpers

    /// Spins the run-loop briefly to let Network.framework callbacks flush
    /// onto the service actor. Used after closing a client to let
    /// `removeConnection` settle.
    private func drain(seconds: TimeInterval = 0.5) {
        let exp = expectation(description: "drain")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 1)
    }

    /// Brings up the service, waits for `.listening`, then returns.
    private func startListening(_ service: WebSocketServerService) {
        let exp = expectation(description: "listening")
        let stream = service.stateChanges
        let observer = Task.detached {
            for await (state, _) in stream where state == .listening {
                exp.fulfill()
                return
            }
        }
        Task { await service.setEnabled(true) }
        wait(for: [exp], timeout: 10)
        observer.cancel()
    }

    /// Tears the service down. Best-effort — failures don't fail the test.
    private func shutdown(_ service: WebSocketServerService) {
        let exp = expectation(description: "stopped")
        let stream = service.stateChanges
        let observer = Task.detached {
            for await (state, _) in stream where state == .stopped {
                exp.fulfill()
                return
            }
        }
        Task { await service.setEnabled(false) }
        wait(for: [exp], timeout: 5)
        observer.cancel()
    }

    /// Opens a WebSocket client to the given loopback port with the supplied
    /// subprotocol (or none) and waits for the connection to reach `.ready`
    /// or `.failed` / `.cancelled`. Returns the final state.
    @discardableResult
    private func connectClient(
        port: UInt16,
        subprotocol: String?,
        readyTimeout: TimeInterval = 3
    ) -> NWConnection {
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        if let sub = subprotocol {
            wsOptions.setSubprotocols([sub])
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: parameters)

        let ready = expectation(description: "client settled")
        ready.assertForOverFulfill = false
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                ready.fulfill()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        wait(for: [ready], timeout: readyTimeout)
        return connection
    }

    // MARK: - Tests

    func testConnectionWithoutTokenIsRejected() {
        let service = WebSocketServerService(port: 59010, authToken: "expected-token-abc123")
        startListening(service)
        defer { shutdown(service) }

        let client = connectClient(port: 59010, subprotocol: nil)
        defer { client.cancel() }

        drain()

        XCTAssertEqual(service.connectionCount, 0,
                       "Connection without subprotocol must not join the active set")
    }

    func testConnectionWithWrongTokenIsRejected() {
        let service = WebSocketServerService(port: 59011, authToken: "expected-token-abc123")
        startListening(service)
        defer { shutdown(service) }

        let client = connectClient(port: 59011, subprotocol: "wolfwave.token.deadbeef")
        defer { client.cancel() }

        drain()

        XCTAssertEqual(service.connectionCount, 0,
                       "Connection with mismatched token must not join the active set")
    }

    func testConnectionWithMatchingTokenIsAccepted() {
        let token = "matching-token-xyz"
        let service = WebSocketServerService(port: 59012, authToken: token)
        startListening(service)
        defer { shutdown(service) }

        let client = connectClient(port: 59012, subprotocol: "wolfwave.token." + token)
        defer { client.cancel() }

        // Authorized clients flip the count snapshot once the actor processes the
        // .ready transition — give it a moment longer than the rejection path.
        let countExp = expectation(description: "client counted")
        let stream = service.stateChanges
        let observer = Task.detached {
            for await (_, count) in stream where count >= 1 {
                countExp.fulfill()
                return
            }
        }
        wait(for: [countExp], timeout: 5)
        observer.cancel()

        XCTAssertGreaterThanOrEqual(service.connectionCount, 1,
                                    "Connection with matching subprotocol must join the active set")
    }

    func testServiceInitWithoutTokenAcceptsAnyConnection() {
        // Legacy `init(port:)` (no token) is used by lifecycle tests — assert it
        // keeps accepting unauthenticated clients so we don't regress them.
        let service = WebSocketServerService(port: 59013)
        startListening(service)
        defer { shutdown(service) }

        let client = connectClient(port: 59013, subprotocol: nil)
        defer { client.cancel() }

        let countExp = expectation(description: "client counted")
        let stream = service.stateChanges
        let observer = Task.detached {
            for await (_, count) in stream where count >= 1 {
                countExp.fulfill()
                return
            }
        }
        wait(for: [countExp], timeout: 5)
        observer.cancel()

        XCTAssertGreaterThanOrEqual(service.connectionCount, 1)
    }
}
