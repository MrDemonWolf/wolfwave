//
//  WidgetHTTPService+Connections.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Network

/// Per-connection request handling for ``WidgetHTTPService``: bounded
/// header reassembly, request parsing, and routing to the response writers.
nonisolated extension WidgetHTTPService {

    // MARK: - Connection Handling

    /// Largest request-header block we will buffer before giving up. Bounds the
    /// reassembly below so a slow or hostile peer can't make us hold an unbounded
    /// buffer while we wait for `\r\n\r\n`.
    private static let maxHeaderBytes = 8192

    /// HTTP header terminator: a blank line (CRLF CRLF) ends the request headers.
    private static let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

    /// Accepts an inbound TCP connection, tracks it for lifecycle teardown,
    /// arms the header timeout, and begins reading the request headers.
    /// Connections refused by `shouldAcceptConnection` (global cap, per-peer
    /// cap, or the slots reserved for loopback) are cancelled immediately.
    func handleConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let isLoopback = WebSocketAuthToken.isLoopbackEndpoint(connection.endpoint)
        let peerKey = WebSocketAuthToken.peerKey(connection.endpoint)

        let refusal: ConnectionRefusal? = connectionsLock.withLock {
            let peerConnectionCount = activeConnections.values.lazy.filter {
                WebSocketAuthToken.peerKey($0.connection.endpoint) == peerKey
            }.count
            if let refusal = Self.connectionRefusal(
                activeCount: activeConnections.count,
                maximumCount: maxConcurrentConnections,
                isLoopback: isLoopback,
                peerConnectionCount: peerConnectionCount
            ) { return refusal }
            activeConnections[id] = TrackedConnection(connection: connection)
            return nil
        }
        if let refusal {
            let reason = refusal.logDescription(maximumCount: maxConcurrentConnections)
            Log.warn(
                "WidgetHTTPService: Refusing connection, \(reason)",
                category: .websocket
            )
            connection.cancel()
            return
        }

        // Untrack on any terminal state so the table cannot grow without bound.
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed:
                connection?.stateUpdateHandler = nil
                connection?.cancel()
                self?.removeConnection(id)
            case .cancelled:
                connection?.stateUpdateHandler = nil
                self?.removeConnection(id)
            default:
                break
            }
        }

        connection.start(queue: queue)
        scheduleHeaderTimeout(for: connection)
        readRequestHeaders(from: connection, accumulated: Data())
    }

    /// Why a new connection was refused, so the log names the limit that hit.
    enum ConnectionRefusal: Equatable {
        /// Negative counts or a non-positive maximum.
        case invalidCounts
        /// Every slot is in use.
        case totalLimit
        /// Only the slots reserved for loopback (local OBS) are left.
        case loopbackReserve
        /// This LAN host already holds its per-host maximum.
        case perHostLimit

        /// Log text for this refusal.
        func logDescription(maximumCount: Int) -> String {
            switch self {
            case .invalidCounts: "invalid connection counts"
            case .totalLimit: "\(maximumCount) already active"
            case .loopbackReserve: "remaining slots are reserved for local connections"
            case .perHostLimit: "host already has \(WidgetHTTPService.maxConnectionsPerHost) connections"
            }
        }
    }

    /// Concurrent connections one LAN host may hold.
    static let maxConnectionsPerHost = 4

    /// Admission policy for a new connection. Pure, so it is unit-testable.
    ///
    /// Loopback peers may use every slot up to `maximumCount`. LAN peers are
    /// held back from the last `min(4, max(1, maximumCount / 4))` slots, so a
    /// noisy LAN host can never lock out the local OBS, and are capped at
    /// ``maxConnectionsPerHost`` concurrent connections per host (see
    /// `WebSocketAuthToken.peerKey`). Negative counts or a non-positive
    /// maximum refuse.
    ///
    /// - Returns: `nil` to accept, or the reason for refusing.
    nonisolated static func connectionRefusal(
        activeCount: Int,
        maximumCount: Int,
        isLoopback: Bool,
        peerConnectionCount: Int
    ) -> ConnectionRefusal? {
        guard activeCount >= 0, maximumCount > 0, peerConnectionCount >= 0 else { return .invalidCounts }
        guard activeCount < maximumCount else { return .totalLimit }
        guard !isLoopback else { return nil }
        let reservedLoopbackConnections = min(4, max(1, maximumCount / 4))
        guard activeCount < maximumCount - reservedLoopbackConnections else { return .loopbackReserve }
        guard peerConnectionCount < maxConnectionsPerHost else { return .perHostLimit }
        return nil
    }

    /// Whether ``connectionRefusal(activeCount:maximumCount:isLoopback:peerConnectionCount:)``
    /// accepts the connection.
    nonisolated static func shouldAcceptConnection(
        activeCount: Int,
        maximumCount: Int,
        isLoopback: Bool,
        peerConnectionCount: Int
    ) -> Bool {
        connectionRefusal(
            activeCount: activeCount,
            maximumCount: maximumCount,
            isLoopback: isLoopback,
            peerConnectionCount: peerConnectionCount
        ) == nil
    }

    /// Arms the lifetime timeout for `connection`. Bounds headers and response
    /// writes together: completed sends cancel (and so untrack) the peer, so
    /// anything still tracked after `headerTimeout` seconds is cancelled.
    private func scheduleHeaderTimeout(for connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        queue.asyncAfter(deadline: .now() + headerTimeout) { [weak self, weak connection] in
            guard let self, let connection else { return }
            // Identity check guards against a recycled `ObjectIdentifier`.
            let stillAwaitingHeaders: Bool = self.connectionsLock.withLock {
                guard let tracked = self.activeConnections[id],
                      tracked.connection === connection else { return false }
                return true
            }
            guard stillAwaitingHeaders else { return }
            Log.warn(
                "WidgetHTTPService: Cancelling unfinished response after \(self.headerTimeout)s",
                category: .websocket
            )
            connection.cancel()
        }
    }

    /// Drops the tracking entry for a connection that reached a terminal state.
    private func removeConnection(_ id: ObjectIdentifier) {
        connectionsLock.withLock {
            _ = activeConnections.removeValue(forKey: id)
        }
    }

    /// Reads from `connection` until the `\r\n\r\n` header terminator is seen or
    /// the `maxHeaderBytes` cap is hit, reassembling across fragmented reads so a
    /// split first packet can't produce a false 404. Once the headers are complete
    /// (or the cap is reached) we parse the request line and Host together; Host is
    /// part of the loopback token-injection gate.
    private func readRequestHeaders(from connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            guard error == nil else { connection.cancel(); return }

            var buffer = accumulated
            if let data { buffer.append(data) }

            if buffer.isEmpty {
                // Peer closed without sending anything.
                connection.cancel()
                return
            }

            // Headers complete, cap reached, or peer finished sending: parse now.
            if buffer.range(of: Self.headerTerminator) != nil
                || buffer.count >= Self.maxHeaderBytes
                || isComplete {
                self.serveResponse(to: connection, requestData: buffer)
                return
            }

            // Need more bytes to complete the header block.
            self.readRequestHeaders(from: connection, accumulated: buffer)
        }
    }

    /// Parses the HTTP request line and routes to the matching handler.
    ///
    /// Routes:
    /// - `GET /` (or empty path, with or without query) → `serveWidget`
    /// - `GET /widget-tokens.generated.js` → `serveTokensJS`
    /// - `GET /favicon.ico` / `GET /favicon.png` → `serveFavicon`
    /// - Anything else → `send404`
    private func serveResponse(to connection: NWConnection, requestData: Data) {
        let requestString = String(data: requestData, encoding: .utf8) ?? ""
        let firstLine = requestString.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        let method = parts.count > 0 ? parts[0] : ""
        let rawPath = parts.count > 1 ? parts[1] : ""
        let path = rawPath.components(separatedBy: "?").first ?? rawPath
        let hostHeader = Self.headerValue(named: "host", in: requestString)

        if method == "GET" && (path == "/" || path.isEmpty) {
            serveWidget(to: connection, hostHeader: hostHeader)
        } else if method == "GET" && path == "/widget-tokens.generated.js" {
            serveTokensJS(to: connection)
        } else if method == "GET" && (path == "/favicon.ico" || path == "/favicon.png") {
            serveFavicon(to: connection)
        } else {
            send404(to: connection)
        }
    }
}
