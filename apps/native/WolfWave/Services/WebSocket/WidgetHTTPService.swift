//
//  WidgetHTTPService.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-03-18.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import Foundation
import Network
import os

// MARK: - Widget HTTP Service

/// Serves the bundled `widget.html` over a plain HTTP/1.1 connection.
///
/// Owned and driven by `WebSocketServerService`. Starts when the WS server starts,
/// stops when it stops. Binds to all interfaces so LAN peers (a second-PC OBS,
/// a phone browser) can fetch the widget for two-PC streaming setups.
///
/// ## Token injection
///
/// The bundled `widget.html` contains a `__WOLFWAVE_TOKEN__` sentinel. The
/// substitution runs **only when the requesting peer is loopback and the
/// `Host` header is a literal local address** (see `shouldInjectToken`) so a LAN
/// fetch, or a DNS-rebound origin, cannot lift the WebSocket credential out of
/// the served HTML. Other requests receive the raw template; the JS then uses
/// the `?token=` URL query string for the WebSocket handshake (a `?token=`
/// query also takes precedence over an injected token). Only the read-only
/// overlay token is ever injected, never the control token.
///
/// - `GET /` or `GET /?...` → `200 OK` with `widget.html` body
/// - `GET /widget-tokens.generated.js` → `200 OK` with generated design tokens JS
/// - `GET /favicon.ico` / `GET /favicon.png` → `200 OK` with app icon PNG
/// - All other requests → `404 Not Found`
///
/// ## Connection lifecycle
///
/// Accepted connections are tracked and bounded: at most
/// `maxConcurrentConnections` are served at once (extra accepts are cancelled
/// immediately), a connection that never delivers complete request headers is
/// cancelled after `headerTimeout`, and `stop()` cancels every tracked
/// connection along with the listener. Despite the name, `headerTimeout`
/// bounds the whole tracked lifetime (headers plus response write): any
/// connection still tracked when it fires is cancelled. Without this, a half-open LAN peer
/// (an OBS box losing power mid-connect) would pin an `NWConnection` and its
/// file descriptor for the app lifetime via the pending receive callback.
///
/// ## Threading
///
/// `@unchecked Sendable`: all mutable state is guarded by `readyLock`,
/// `listenerLock`, or `connectionsLock`, and every Network.framework callback
/// runs on the private serial `queue`. `generation` is bumped on every
/// `start()` / `stop()` so callbacks from an older listener become no-ops.
nonisolated final class WidgetHTTPService: @unchecked Sendable {

    // MARK: - Errors

    /// Thrown from `ready()` when the listener will never reach `.ready` for the
    /// current `start()` cycle: either the bind failed or the service was stopped
    /// before binding. Lets a caller distinguish "bound" from "shut down" instead
    /// of hanging forever.
    enum ReadyError: Error {
        /// The `NWListener` transitioned to `.failed` before becoming ready.
        case listenerFailed
        /// `stop()` ran before the listener became ready.
        case stopped
    }

    // MARK: - Properties

    /// Configured port; `0` asks the kernel for an ephemeral port (tests).
    private let port: UInt16
    /// Token baked into the served `widget.html` so OBS browser sources hit the
    /// WebSocket with a valid `wolfwave.overlay.<hex>` subprotocol without the user
    /// pasting a query string. `nil` ships the file un-substituted (test-only).
    private let overlayToken: String?
    /// Guards all reads and writes of `listener` so the state-callback queue and
    /// `stop()` callers cannot race on the reference.
    private let listenerLock = NSLock()
    /// Backing storage for `listener`; touch only through the accessor.
    private var _listener: NWListener?
    /// Thread-safe accessor for the underlying `NWListener`.
    private var listener: NWListener? {
        get { listenerLock.withLock { _listener } }
        set { listenerLock.withLock { _listener = newValue } }
    }
    /// Serial queue for the listener, every connection, header timeouts, and
    /// bind retries.
    let queue = DispatchQueue(
        label: "com.mrdemonwolf.wolfwave.widget-http",
        qos: .utility
    )

    /// Book-keeping for one accepted connection. Currently just the connection;
    /// the header timeout keys off whether the entry is still present.
    struct TrackedConnection {
        let connection: NWConnection
    }

    /// Guards all reads and writes of `activeConnections` so the connection
    /// callbacks on `queue` and `stop()` callers cannot race.
    let connectionsLock = NSLock()
    /// Accepted connections currently being served, keyed by identity so each
    /// connection's state callback removes exactly its own entry. Tracking lets
    /// `stop()` tear down in-flight connections and lets the header timeout
    /// find its peer.
    var activeConnections: [ObjectIdentifier: TrackedConnection] = [:]

    /// Upper bound on concurrently tracked connections. Extra accepts are
    /// cancelled immediately so a misbehaving LAN peer cannot exhaust file
    /// descriptors.
    let maxConcurrentConnections: Int

    /// Seconds an accepted connection may stay tracked before it is cancelled.
    /// Named for the slow-headers case, but it also bounds the response write,
    /// since a connection is only untracked once it is cancelled or fails.
    let headerTimeout: TimeInterval

    /// Number of connections currently tracked. Exposed so tests can await
    /// accepts deterministically instead of sleeping.
    var activeConnectionCount: Int {
        connectionsLock.withLock { activeConnections.count }
    }

    /// The port the listener actually bound, or `nil` before it binds. Differs
    /// from the configured `port` only when that was `0`, which asks the kernel
    /// for a free ephemeral port. Tests bind `0` and read this back so they can
    /// never collide with an unrelated process holding a hardcoded port.
    var boundPort: UInt16? {
        listener?.port?.rawValue
    }

    /// Guards the start/ready/retry state below (`isReady` through
    /// `readyWaiters`). The readiness latch lets callers (notably tests) await
    /// the listener actually binding the port instead of sleeping a fixed
    /// interval; the lock lets the `queue` state callback and an awaiting
    /// caller race safely.
    private let readyLock = NSLock()
    /// `true` once the current generation's listener reached `.ready`.
    private var isReady = false
    /// Why `ready()` should throw right now, if anything. Set to
    /// `.listenerFailed` once a bind failure has no retry left (or the port is
    /// invalid) and `.stopped` by `stop()`; cleared when a new listener is
    /// installed.
    private var terminalError: ReadyError?
    /// `true` between `start()` and `stop()`.
    private var isStarted = false
    /// Incremented on every `start()` / `stop()`. Callbacks capture the value
    /// they were created under and bail when it no longer matches.
    private var generation: UInt64 = 0
    /// Bind retries made so far this generation; capped at 5, reset on `.ready`.
    private var retryAttempt = 0
    /// The pending retry, cancelled by `stop()` or a newer retry.
    private var retryWork: DispatchWorkItem?
    /// First retry delay in seconds; doubles per attempt up to 30 s.
    private let retryBaseDelay: TimeInterval
    /// Listener factory; injectable so tests can force a bind failure.
    private let makeListener: @Sendable (NWParameters, NWEndpoint.Port) throws -> NWListener
    /// Callers suspended in `ready()`.
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    /// Process-wide favicon PNG, encoded at most once (even when the icon is
    /// missing, so a `nil` result is cached too). `count` tallies encodes.
    private static let faviconCache = OSAllocatedUnfairLock<(body: Data?, loaded: Bool, count: Int)>(
        initialState: (nil, false, 0)
    )
    /// How many times the favicon has been encoded. Test hook proving the
    /// cache holds (it should never exceed 1).
    static var faviconEncodingCount: Int { faviconCache.withLock { $0.count } }

    /// Sentinel string in the bundled `widget.html` that we replace with the
    /// live auth token before sending the response.
    private static let tokenPlaceholder = "__WOLFWAVE_TOKEN__"

    // MARK: - Init

    /// Creates a widget HTTP service.
    ///
    /// - Parameters:
    ///   - port: TCP port to listen on. Bound on all interfaces so LAN peers
    ///     can reach the widget for two-PC streaming setups. Pass `0` to let
    ///     the kernel pick a free port and read it back from ``boundPort``.
    ///   - overlayToken: read-only overlay token to inject into the served HTML
    ///     **for loopback requests only**. Pass `nil` to ship the file
    ///     untouched. Only useful for tests.
    ///   - headerTimeout: Seconds an accepted connection may take to deliver
    ///     its complete request headers before it is cancelled. Defaults to
    ///     10; override only in tests.
    ///   - maxConcurrentConnections: Upper bound on concurrently tracked
    ///     connections; extra accepts are cancelled immediately. Defaults to
    ///     32; override only in tests.
    ///   - retryBaseDelay: First bind-retry delay in seconds (floored at
    ///     0.01). Doubles per attempt, capped at 30 s, at most 5 retries.
    ///   - makeListener: Builds the `NWListener`. Tests inject a throwing
    ///     factory to exercise the retry and `ready()` failure paths.
    init(
        port: UInt16,
        overlayToken: String? = nil,
        headerTimeout: TimeInterval = 10,
        maxConcurrentConnections: Int = 32,
        retryBaseDelay: TimeInterval = 1,
        makeListener: @escaping @Sendable (NWParameters, NWEndpoint.Port) throws -> NWListener = {
            try NWListener(using: $0, on: $1)
        }
    ) {
        self.port = port
        self.overlayToken = overlayToken
        self.headerTimeout = headerTimeout
        self.maxConcurrentConnections = maxConcurrentConnections
        self.retryBaseDelay = max(retryBaseDelay, 0.01)
        self.makeListener = makeListener
    }

    /// Tears down the listener and any open connections.
    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Brings up the HTTP listener and begins accepting connections.
    /// Binds to all interfaces; per-request loopback gating is enforced in
    /// `serveWidget` for token injection. Idempotent. A second call while
    /// already running is a no-op.
    func start() {
        let current = readyLock.withLock { () -> UInt64? in
            guard !isStarted else { return nil }
            isStarted = true
            generation &+= 1
            retryAttempt = 0
            terminalError = nil
            return generation
        }
        guard let current else { return }
        startListener(generation: current)
    }

    /// Creates and starts one `NWListener` for generation `current`. Also the
    /// retry entry point. A create or bind failure schedules a retry (pending
    /// `ready()` waiters keep waiting); an invalid port fails without retrying.
    private func startListener(generation current: UInt64) {
        guard readyLock.withLock({ isStarted && generation == current }) else { return }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            Log.error("WidgetHTTPService: Invalid port \(port)", category: .websocket)
            failReadyWaiters(with: .listenerFailed, generation: current)
            return
        }

        let newListener: NWListener
        do {
            newListener = try makeListener(parameters, nwPort)
        } catch {
            Log.error("WidgetHTTPService: Failed to create listener: \(error)", category: .websocket)
            handleListenerFailure(generation: current)
            return
        }
        let installed = readyLock.withLock {
            guard isStarted, generation == current else { return false }
            terminalError = nil
            listener = newListener
            return true
        }
        guard installed else { newListener.cancel(); return }

        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, let newListener,
                  self.readyLock.withLock({ self.isStarted && self.generation == current
                      && self.listener === newListener }) else { return }
            switch state {
            case .ready:
                Log.info(
                    "WidgetHTTPService: Listening on port \(self.boundPort ?? self.port)",
                    category: .websocket
                )
                self.markReady(generation: current)
            case .failed(let error):
                Log.error("WidgetHTTPService: Listener failed: \(error)", category: .websocket)
                newListener.cancel()
                self.readyLock.withLock {
                    if self.listener === newListener { self.listener = nil }
                }
                self.handleListenerFailure(generation: current)
            default:
                break
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            guard let self, self.readyLock.withLock({ self.isStarted && self.generation == current }) else {
                connection.cancel()
                return
            }
            self.handleConnection(connection)
        }

        newListener.start(queue: queue)
    }

    /// Handles a create or bind failure for generation `current`: clears the
    /// readiness latch and schedules a retry. `ready()` waiters keep waiting
    /// while a retry is pending; they fail with `.listenerFailed` only once
    /// the retries are spent.
    private func handleListenerFailure(generation current: UInt64) {
        readyLock.withLock {
            guard isStarted, generation == current else { return }
            isReady = false
        }
        if !scheduleRetry(generation: current) {
            failReadyWaiters(with: .listenerFailed, generation: current)
        }
    }

    /// Schedules `startListener` again with exponential backoff
    /// (`retryBaseDelay * 2^attempt`, capped at 30 s), up to 5 attempts.
    /// After the fifth the service stays down until the next `start()`.
    ///
    /// - Returns: `true` when a retry was scheduled.
    @discardableResult
    private func scheduleRetry(generation current: UInt64) -> Bool {
        let delay = readyLock.withLock { () -> TimeInterval? in
            guard isStarted, generation == current, retryAttempt < 5 else { return nil }
            let delay = min(retryBaseDelay * pow(2, Double(retryAttempt)), 30)
            retryAttempt += 1
            retryWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.startListener(generation: current) }
            retryWork = work
            queue.asyncAfter(deadline: .now() + delay, execute: work)
            return delay
        }
        guard let delay else { return false }
        Log.info("WidgetHTTPService: Retrying in \(delay)s", category: .websocket)
        return true
    }

    /// Cancels the listener and tears down the bound port, then cancels every
    /// tracked connection so pending receive callbacks (which retain their
    /// connection) cannot outlive the service. Safe to call when the service
    /// was never started or has already stopped.
    func stop() {
        let (stoppedListener, waiters) = readyLock.withLock { () -> (NWListener?, [CheckedContinuation<Void, Error>]) in
            isStarted = false
            generation &+= 1
            isReady = false
            terminalError = .stopped
            retryWork?.cancel()
            retryWork = nil
            let current = listener
            listener = nil
            let waiters = readyWaiters
            readyWaiters.removeAll()
            return (current, waiters)
        }
        stoppedListener?.cancel()
        // Wake any caller still awaiting `ready()` so a stop-before-bind doesn't
        // leave them suspended forever.
        for waiter in waiters { waiter.resume(throwing: ReadyError.stopped) }
        let openConnections: [NWConnection] = connectionsLock.withLock {
            let open = activeConnections.values.map(\.connection)
            activeConnections.removeAll()
            return open
        }
        for connection in openConnections {
            connection.cancel()
        }
        Log.info("WidgetHTTPService: Server stopped", category: .websocket)
    }

    /// Suspends until the listener reaches `NWListener.State.ready` (the port
    /// is bound and accepting connections). Returns immediately if the service
    /// is already ready. Use this instead of a fixed `Thread.sleep` so callers
    /// (and tests) wait exactly as long as the bind takes and no longer.
    ///
    /// A bind failure with a retry pending keeps the caller waiting, so a
    /// recoverable failure is not reported as final.
    ///
    /// - Throws: `ReadyError.listenerFailed` once the bind has failed and no
    ///   retry remains (or the port is invalid), or `ReadyError.stopped` if
    ///   `stop()` runs before the listener binds. Retries are bounded (5, with
    ///   capped backoff), so the call always resolves instead of hanging on a
    ///   listener that will never reach `.ready`.
    func ready() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let result: Result<Void, ReadyError>? = readyLock.withLock {
                if let terminalError { return .failure(terminalError) }
                if isReady { return .success(()) }
                readyWaiters.append(continuation)
                return nil
            }
            if let result { continuation.resume(with: result.mapError { $0 as any Error }) }
        }
    }

    /// Latches readiness and resumes any callers awaiting `ready()`. Invoked on
    /// each `.ready` listener transition (on `queue`); only the first per
    /// generation has an effect.
    private func markReady(generation current: UInt64) {
        let waiters: [CheckedContinuation<Void, Error>] = readyLock.withLock {
            guard isStarted, generation == current, !isReady else { return [] }
            isReady = true
            terminalError = nil
            retryAttempt = 0
            let pending = readyWaiters
            readyWaiters.removeAll()
            return pending
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Resumes any pending `ready()` waiters with the given failure, records it
    /// as `terminalError`, and clears the queue. Invoked when the listener
    /// cannot be created or bound and no retry remains. (`stop()` resumes
    /// waiters itself.)
    /// A no-op for a stale generation or a stopped service.
    private func failReadyWaiters(with error: ReadyError, generation current: UInt64) {
        let waiters: [CheckedContinuation<Void, Error>] = readyLock.withLock {
            guard generation == current, isStarted else { return [] }
            isReady = false
            terminalError = error
            let pending = readyWaiters
            readyWaiters.removeAll()
            return pending
        }
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    // MARK: - Responses

    /// Writes the bundled `widget.html` as an HTTP/1.1 200 response and
    /// closes the connection. Falls back to a 404 when the asset is missing.
    ///
    /// Token injection requires both a loopback TCP peer and a literal local
    /// Host header. The second check closes the DNS-rebinding path where an
    /// attacker-controlled origin resolves to 127.0.0.1.
    func serveWidget(to connection: NWConnection, hostHeader: String?) {
        guard let url = Bundle.main.url(forResource: "widget", withExtension: "html"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            Log.error("WidgetHTTPService: widget.html not found in bundle", category: .websocket)
            send404(to: connection)
            return
        }

        let isLoopback = WebSocketAuthToken.isLoopbackEndpoint(connection.endpoint)
        let shouldInjectToken = Self.shouldInjectToken(
            loopbackPeer: isLoopback,
            hostHeader: hostHeader
        )
        var rendered: String
        var didInjectToken = false
        if shouldInjectToken, let token = overlayToken, WebSocketAuthToken.isValid(token) {
            // `isValid` gates the substitution on hex-only / bounded length so a
            // corrupted or hand-edited token can't inject `</script>` or other
            // characters that would break out of the JS string context.
            rendered = raw.replacingOccurrences(of: Self.tokenPlaceholder, with: token)
            didInjectToken = true
        } else {
            if shouldInjectToken, let token = overlayToken, !WebSocketAuthToken.isValid(token) {
                Log.warn(
                    "WidgetHTTPService: Refusing to inject non-hex auth token into widget.html",
                    category: .websocket
                )
            }
            rendered = raw
        }

        let body = Data(rendered.utf8)
        let cacheHeader = didInjectToken ? "Cache-Control: no-store" : "Cache-Control: no-cache"
        sendHTTPResponse(
            connection,
            contentType: "text/html; charset=utf-8",
            body: body,
            extraHeaders: [cacheHeader, "Referrer-Policy: no-referrer"]
        )
    }

    /// Writes the bundled `widget-tokens.generated.js` as an HTTP/1.1 200 response.
    /// Sourced from `design-system/tokens.json` via the token generator and bundled
    /// alongside `widget.html`. Falls back to 404 when the asset is missing.
    func serveTokensJS(to connection: NWConnection) {
        guard let url = Bundle.main.url(forResource: "widget-tokens.generated", withExtension: "js"),
              let body = try? Data(contentsOf: url) else {
            Log.error("WidgetHTTPService: widget-tokens.generated.js not found in bundle", category: .websocket)
            send404(to: connection)
            return
        }

        sendHTTPResponse(
            connection,
            contentType: "application/javascript; charset=utf-8",
            body: body,
            extraHeaders: ["Cache-Control: no-cache"])
    }

    /// Encodes the app icon as PNG and serves it with a one-day cache header.
    /// Used so browser tabs displaying the widget show a recognizable icon.
    func serveFavicon(to connection: NWConnection) {
        guard let body = Self.faviconData() else {
            send404(to: connection)
            return
        }

        sendHTTPResponse(
            connection,
            contentType: "image/png",
            body: body,
            extraHeaders: ["Cache-Control: public, max-age=86400"])
    }

    /// Returns the app icon as PNG, encoding it on first use and caching the
    /// result (including `nil` when `AppIcon` is missing) for the process.
    static func faviconData() -> Data? {
        faviconCache.withLock { state in
            guard !state.loaded else { return state.body }
            state.loaded = true
            state.count += 1
            state.body = NSImage(named: "AppIcon")?.pngData()
            return state.body
        }
    }

    // MARK: - Peer Inspection

    /// Extracts a case-insensitive HTTP header from a completed request block.
    ///
    /// Skips the request line, stops at the blank line, and returns the first
    /// match trimmed of whitespace, or `nil` when the header is absent.
    static func headerValue(named name: String, in request: String) -> String? {
        let prefix = name.lowercased() + ":"
        let headerEnd = request.range(of: "\r\n\r\n")?.lowerBound ?? request.endIndex
        let headerBlock = String(request[..<headerEnd])
        for line in headerBlock.components(separatedBy: "\r\n").dropFirst() {
            let lower = line.lowercased()
            guard lower.hasPrefix(prefix) else { continue }
            return String(line.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Pure policy seam used by integration tests and `serveWidget`.
    ///
    /// Both conditions are required: a loopback TCP peer (so a LAN host can't
    /// read the token) and a literal local `Host` header (so a browser page on
    /// an attacker origin rebound to 127.0.0.1 can't either).
    nonisolated static func shouldInjectToken(loopbackPeer: Bool, hostHeader: String?) -> Bool {
        loopbackPeer && isLiteralLocalHost(hostHeader)
    }

    /// Accepts localhost, 127.0.0.0/8, and bracketed ::1 with an optional
    /// numeric port. Hostnames that merely resolve to loopback are rejected.
    private nonisolated static func isLiteralLocalHost(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return false }

        if value == "localhost" { return true }
        if value.hasPrefix("localhost:") {
            return UInt16(String(value.dropFirst("localhost:".count))) != nil
        }
        if value == "[::1]" { return true }
        if value.hasPrefix("[::1]:") {
            return UInt16(String(value.dropFirst("[::1]:".count))) != nil
        }

        let pieces = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 1 || (pieces.count == 2 && UInt16(String(pieces[1])) != nil) else {
            return false
        }
        let octets = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "127" else { return false }
        return octets.allSatisfy { UInt8(String($0)) != nil }
    }

    /// Writes a raw HTTP/1.1 response and closes the connection. Centralizes the
    /// status line + `Content-Type` + `Content-Length` + `Connection: close`
    /// framing; there is no framework layer here, so the exact CRLF layout is
    /// load-bearing. `extraHeaders` (each without its trailing CRLF) are inserted
    /// before `Connection: close`.
    private func sendHTTPResponse(
        _ connection: NWConnection,
        status: String = "200 OK",
        contentType: String,
        body: Data,
        extraHeaders: [String] = []
    ) {
        var header = "HTTP/1.1 \(status)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(body.count)\r\n"
        for line in extraHeaders {
            header += line + "\r\n"
        }
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Writes a minimal `404 Not Found` plain-text response and closes the
    /// connection.
    func send404(to connection: NWConnection) {
        sendHTTPResponse(
            connection, status: "404 Not Found",
            contentType: "text/plain", body: Data("Not Found".utf8))
    }
}
