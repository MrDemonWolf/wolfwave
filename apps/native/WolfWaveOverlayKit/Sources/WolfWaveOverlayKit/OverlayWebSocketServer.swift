//
//  OverlayWebSocketServer.swift
//  WolfWaveOverlayKit
//
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//
//  Port of the app's `WebSocketServerService`. Differences after the move:
//   - All config (port, widgetPort, token, appVersion, widgetHTTPEnabled,
//     appearance) is injected via `configure(_:)` / `update*` instead of read
//     from `UserDefaults` / `Bundle.main`.
//   - State changes go to an `OverlayServerDelegate` instead of an AsyncStream +
//     NotificationCenter (the app facade re-publishes those).
//   - `os.Logger` instead of the app `Log`. Per-message byte metrics dropped
//     (client-count metric is preserved app-side via state changes).
//   - `WebSocketTokenRules` instead of `WebSocketAuthToken`.
//

import Foundation
import Network
import os

public actor OverlayWebSocketServer {

    // MARK: - Types

    public enum ServerState: String, Sendable {
        case stopped, starting, listening, error
    }

    // MARK: - Snapshot (nonisolated reads)

    private nonisolated let snapshotLock = NSLock()
    nonisolated(unsafe) private var _stateSnapshot: ServerState = .stopped
    nonisolated(unsafe) private var _connectionCountSnapshot: Int = 0

    public nonisolated var state: ServerState { snapshotLock.withLock { _stateSnapshot } }
    public nonisolated var connectionCount: Int { snapshotLock.withLock { _connectionCountSnapshot } }

    private func writeStateSnapshot(_ newState: ServerState) {
        snapshotLock.withLock { _stateSnapshot = newState }
    }
    private func writeConnectionCountSnapshot(_ count: Int) {
        snapshotLock.withLock { _connectionCountSnapshot = count }
    }

    // MARK: - Dependencies

    private let log = Logger(subsystem: OverlayConstants.logSubsystem, category: "WebSocket")
    private let resourceBundle: Bundle
    private weak var delegate: OverlayServerDelegate?

    // MARK: - Config-derived state

    private var port: UInt16 = OverlayConstants.defaultPort
    private var widgetPort: UInt16 = OverlayConstants.widgetDefaultPort
    private var authToken: String?
    private var appVersion: String = "unknown"
    private var widgetHTTPEnabledOnStart = false
    private var appearance: WidgetAppearance = .default

    // MARK: - Runtime

    private let networkQueue = DispatchQueue(label: OverlayConstants.websocketQueueLabel, qos: .utility)
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var isEnabled = false
    private var widgetHTTP: OverlayWidgetHTTPServer?
    private var retryTask: Task<Void, Never>?

    // MARK: - Playback state

    private var currentTrack: String?
    private var currentArtist: String?
    private var currentAlbum: String?
    private var currentDuration: TimeInterval = 0
    private var currentElapsed: TimeInterval = 0
    private var isPlaying = false
    private var currentArtworkURL: String?
    private var lastElapsedUpdate: Date?
    private var progressTask: Task<Void, Never>?
    private var currentProgressInterval: TimeInterval = OverlayConstants.progressBroadcastInterval

    // MARK: - Init

    public init(resourceBundle: Bundle, delegate: OverlayServerDelegate?) {
        self.resourceBundle = resourceBundle
        self.delegate = delegate
    }

    // MARK: - Configuration

    /// Applies the full config from the app. Does not start the server.
    /// Sets the state-change delegate after init (the XPC adapter wires itself
    /// here once `self` is available).
    public func setDelegate(_ delegate: OverlayServerDelegate?) {
        self.delegate = delegate
    }

    public func configure(_ config: OverlayServerConfig) {
        port = config.port
        widgetPort = config.widgetPort
        authToken = config.token
        appVersion = config.appVersion
        widgetHTTPEnabledOnStart = config.widgetHTTPEnabled
        appearance = config.appearance
    }

    public func updateWidgetConfig(_ appearance: WidgetAppearance) {
        self.appearance = appearance
        broadcastWidgetConfig()
    }

    // MARK: - Public API (mirrors the former WebSocketServerService)

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled { startServer() } else { stopServer() }
    }

    public func setWidgetHTTPEnabled(_ enabled: Bool) {
        if enabled {
            // Persist desired state so a listener restart (updateAuthToken /
            // updatePort -> stop/start) re-creates the widget HTTP server.
            widgetHTTPEnabledOnStart = true
            guard state == .listening, widgetHTTP == nil else { return }
            widgetHTTP = OverlayWidgetHTTPServer(port: widgetPort, authToken: authToken, resourceBundle: resourceBundle)
            widgetHTTP?.start()
            log.info("Widget HTTP server started")
        } else {
            widgetHTTPEnabledOnStart = false
            widgetHTTP?.stop()
            widgetHTTP = nil
            log.info("Widget HTTP server stopped")
        }
    }

    /// Swaps the auth token, restarting the listener if running so connected
    /// clients must re-handshake with the new credential.
    public func updateAuthToken(_ newToken: String) {
        authToken = newToken
        guard listener != nil else { return }
        stopServer()
        startServer()
    }

    public func updatePort(_ newPort: UInt16) {
        guard newPort >= OverlayConstants.minPort, newPort <= OverlayConstants.maxPort else { return }
        let wasListening = state == .listening
        port = newPort
        if wasListening {
            stopServer()
            startServer()
        }
    }

    public func updateNowPlaying(_ p: NowPlayingPayload) {
        currentTrack = p.track
        currentArtist = p.artist
        currentAlbum = p.album
        currentDuration = p.duration
        currentElapsed = p.elapsed
        isPlaying = !p.isPaused
        lastElapsedUpdate = Date()
        if let artworkURL = p.artworkURL { currentArtworkURL = artworkURL }

        broadcastNowPlaying()
        if p.isPaused { stopProgressTimer() } else { startProgressTimer() }
    }

    public func updateArtworkURL(_ url: String) {
        currentArtworkURL = url
        broadcastNowPlaying()
    }

    public func broadcastWidgetConfig() {
        broadcastJSON(widgetConfigMessage())
    }

    public func updateProgressInterval(_ interval: TimeInterval) {
        currentProgressInterval = interval
        if progressTask != nil { startProgressTimer() }
    }

    public func clearNowPlaying() {
        isPlaying = false
        lastElapsedUpdate = nil
        stopProgressTimer()
        broadcastPlaybackState()
    }

    // MARK: - Server Lifecycle

    private func startServer() {
        guard listener == nil else { return }
        transition(to: .starting)

        let parameters = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true

        let expectedToken = authToken
        wsOptions.setClientRequestHandler(networkQueue) { subprotocols, _ in
            let accept = WebSocketTokenRules.shouldAccept(
                expectedToken: expectedToken,
                offeredSubprotocols: subprotocols
            )
            if accept {
                let selected: String? = expectedToken.map(WebSocketTokenRules.expectedSubprotocol(for:))
                    ?? subprotocols.first
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: selected, additionalHeaders: nil)
            }
            return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil, additionalHeaders: nil)
        }

        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                log.error("Invalid port \(self.port)")
                transition(to: .error)
                return
            }
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            log.error("Failed to create listener: \(error.localizedDescription)")
            transition(to: .error)
            scheduleRetry()
            return
        }

        listener?.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            Task { await self.handleListenerState(newState) }
        }
        listener?.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handleNewConnection(connection) }
        }
        listener?.start(queue: networkQueue)

        if widgetHTTPEnabledOnStart {
            widgetHTTP = OverlayWidgetHTTPServer(port: widgetPort, authToken: authToken, resourceBundle: resourceBundle)
            widgetHTTP?.start()
        }
    }

    private func handleListenerState(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            log.info("Listening on port \(self.port)")
            transition(to: .listening)
        case .failed(let error):
            log.error("Listener failed: \(error.localizedDescription)")
            listener = nil
            transition(to: .error)
            scheduleRetry()
        case .cancelled:
            transition(to: .stopped)
        default:
            break
        }
    }

    private func stopServer() {
        retryTask?.cancel()
        retryTask = nil
        widgetHTTP?.stop()
        widgetHTTP = nil
        stopProgressTimer()
        listener?.cancel()
        listener = nil

        let conns = connections
        connections.removeAll()
        writeConnectionCountSnapshot(0)
        for conn in conns { conn.cancel() }

        transition(to: .stopped)
        log.info("Server stopped")
    }

    private func scheduleRetry() {
        guard isEnabled else { return }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(OverlayConstants.retryDelay))
            guard !Task.isCancelled else { return }
            await self?.attemptRetry()
        }
    }

    private func attemptRetry() {
        guard isEnabled, listener == nil else { return }
        startServer()
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleConnectionState(connection, state: state) }
        }
        connection.start(queue: networkQueue)
    }

    private func handleConnectionState(_ connection: NWConnection, state: NWConnection.State) {
        switch state {
        case .ready:
            // A late .ready callback can arrive after stopServer() cleared the
            // connection set. Don't re-add (which would inflate the count) — the
            // server is no longer listening, so drop the connection.
            // (`state` the param is NWConnection.State, so qualify with self.)
            guard self.state == .listening else { connection.cancel(); return }
            connections.append(connection)
            writeConnectionCountSnapshot(connections.count)
            log.info("Client connected (\(self.connections.count) total)")
            notifyStateChange()
            sendWelcome(to: connection)
            sendCurrentState(to: connection)
            sendWidgetConfig(to: connection)
            Self.receiveMessage(from: connection)
        case .failed(let error):
            log.debug("Client failed: \(error.localizedDescription)")
            removeConnection(connection)
        case .cancelled:
            removeConnection(connection)
        default:
            break
        }
    }

    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
        writeConnectionCountSnapshot(connections.count)
        log.debug("Client disconnected (\(self.connections.count) remaining)")
        notifyStateChange()
    }

    private static func receiveMessage(from connection: NWConnection) {
        connection.receiveMessage { _, _, _, error in
            if error != nil { return }
            receiveMessage(from: connection)
        }
    }

    // MARK: - Messaging

    private func widgetConfigMessage() -> [String: Any] {
        [
            "type": "widget_config",
            "data": [
                "theme": appearance.theme,
                "layout": appearance.layout,
                "textColor": appearance.textColor,
                "backgroundColor": appearance.backgroundColor,
                "fontFamily": appearance.fontFamily,
            ],
        ]
    }

    private func sendWelcome(to connection: NWConnection) {
        Self.sendJSON(["type": "welcome", "server": "WolfWave", "version": appVersion], to: connection)
    }

    private func sendWidgetConfig(to connection: NWConnection) {
        Self.sendJSON(widgetConfigMessage(), to: connection)
    }

    private func sendCurrentState(to connection: NWConnection) {
        guard let track = currentTrack, let artist = currentArtist, let album = currentAlbum else {
            log.debug("No playback state to replay on connect")
            return
        }
        let message: [String: Any] = [
            "type": "now_playing",
            "data": [
                "track": track, "artist": artist, "album": album,
                "duration": currentDuration, "elapsed": estimatedElapsed(),
                "isPlaying": isPlaying, "artworkURL": currentArtworkURL ?? "",
            ],
        ]
        Self.sendJSON(message, to: connection)
    }

    private func broadcastNowPlaying() {
        guard let track = currentTrack, let artist = currentArtist, let album = currentAlbum else { return }
        broadcastJSON([
            "type": "now_playing",
            "data": [
                "track": track, "artist": artist, "album": album,
                "duration": currentDuration, "elapsed": currentElapsed,
                "isPlaying": isPlaying, "artworkURL": currentArtworkURL ?? "",
            ],
        ])
    }

    private func broadcastPlaybackState() {
        broadcastJSON([
            "type": "playback_state",
            "data": [
                "isPlaying": isPlaying,
                "track": currentTrack ?? "",
                "artist": currentArtist ?? "",
                "album": currentAlbum ?? "",
            ],
        ])
    }

    private func broadcastProgress() {
        guard isPlaying, !connections.isEmpty else { return }
        broadcastJSON([
            "type": "progress",
            "data": ["elapsed": estimatedElapsed(), "duration": currentDuration, "isPlaying": isPlaying],
        ])
    }

    private func estimatedElapsed() -> TimeInterval {
        guard let lastUpdate = lastElapsedUpdate, isPlaying else { return currentElapsed }
        return min(currentElapsed + Date().timeIntervalSince(lastUpdate), currentDuration)
    }

    // MARK: - Progress Timer

    private func startProgressTimer() {
        stopProgressTimer()
        let interval = currentProgressInterval
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.1))
                if Task.isCancelled { return }
                await self?.broadcastProgress()
            }
        }
    }

    private func stopProgressTimer() {
        progressTask?.cancel()
        progressTask = nil
    }

    // MARK: - JSON

    private static func sendJSON(_ dict: [String: Any], to connection: NWConnection) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "websocket", metadata: [metadata])
        connection.send(
            content: jsonString.data(using: .utf8),
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    private func broadcastJSON(_ dict: [String: Any]) {
        let conns = connections
        for connection in conns { Self.sendJSON(dict, to: connection) }
    }

    // MARK: - State Notification

    private func transition(to newState: ServerState) {
        writeStateSnapshot(newState)
        notifyStateChange()
    }

    private func notifyStateChange() {
        let currentState = state
        let count = connectionCount
        delegate?.overlayServer(stateDidChange: currentState.rawValue, clientCount: count)
    }
}
