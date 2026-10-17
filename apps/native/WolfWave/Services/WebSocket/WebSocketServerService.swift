//
//  WebSocketServerService.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-02-20.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Network

// MARK: - WebSocket Server Service

/// Broadcasts now-playing data to stream overlay clients over a local WebSocket connection.
///
/// Built on `NWListener` (Network.framework). Overlay clients such as OBS browser sources
/// connect and receive JSON messages for track changes, progress ticks, and playback state.
/// State is actor-confined; a small snapshot is exposed for synchronous `nonisolated` reads
/// from SwiftUI views, and a `stateChanges` `AsyncStream` replaces the legacy callback.
///
/// ## Security model
///
/// - The listener binds to all interfaces so LAN peers (a second-PC OBS, a phone
///   browser) can reach the widget. Two-PC setups would otherwise be impossible.
/// - Overlay clients authenticate with a read-only `wolfwave.overlay.<hex>`
///   subprotocol. They receive state broadcasts but cannot execute commands.
/// - Stream Deck authenticates with a separate `wolfwave.control.<hex>`
///   subprotocol. Control-role connections are accepted only from a literal
///   loopback IP, and only that role can execute commands.
/// - Local widgets get the overlay token for free: `WidgetHTTPService` injects it into
///   the served `widget.html` only for a loopback TCP peer with a literal-local
///   Host header, so same-Mac OBS Browser Sources "just work" without exposing
///   the credential to DNS-rebinding requests. Remote browsers use `?token=…`
///   as bootstrap for the WebSocket subprotocol.
/// - Connections without a valid role-specific subprotocol are rejected before
///   they can receive playback frames.
/// - Rotating either credential restarts the listener so authorized clients are dropped.
/// - The initializer that omits credentials exists for lifecycle tests and
///   grants only the read-only overlay role.
actor WebSocketServerService {

    /// Hard receive bound applied by Network.framework before a complete
    /// WebSocket message is materialized. Current control frames are tiny;
    /// 16 KiB leaves generous protocol headroom without permitting an
    /// authenticated peer to force an unbounded fragmented-message allocation.
    nonisolated static let maximumInboundMessageSize = 16 * 1024
    /// Cap on accepted-but-unauthenticated connections from all peers.
    nonisolated static let maximumPendingConnectionCount = 16
    /// Cap on pending connections from non-loopback peers. Lower than the
    /// overall cap so the LAN can never fill every handshake slot.
    nonisolated static let maximumRemotePendingConnectionCount = 12
    /// Pending connections allowed per LAN host (`WebSocketAuthToken.peerKey`).
    nonisolated static let maximumPendingConnectionsPerRemotePeer = 2
    /// Cap on active plus pending connections.
    nonisolated static let maximumConnectionCount = 64
    /// Active-connection cap for non-loopback peers. The 4 slots held back are
    /// reserved for same-Mac clients (OBS, Stream Deck).
    nonisolated static let maximumRemoteConnectionCount = maximumConnectionCount - 4
    /// How long an accepted TCP peer has to finish the authenticated WebSocket
    /// handshake (reach `.ready`) before it is cancelled.
    static let handshakeTimeout: Duration = .seconds(10)

    // MARK: - Types

    /// Listener lifecycle. Raw values are posted in the server-state
    /// notification (`postWebSocketServerState`).
    ///
    /// `.error` means the listener could not be created or failed; a retry is
    /// scheduled after `AppConstants.WebSocketServer.retryDelay` while enabled
    /// (an invalid port goes to `.error` without a retry).
    enum ServerState: String, Sendable {
        case stopped, starting, listening, error
    }

    /// Lightweight snapshot of one queued request for the overlay's queue
    /// ticker. Deliberately decoupled from `SongRequestItem` (which carries a
    /// MusicKit `Song` this actor should never import) — mirrors the existing
    /// `count`/`pending` decoupling in `broadcastQueueState`.
    struct QueueUpcomingItem: Sendable, Equatable {
        let title: String
        let requesterUsername: String
    }

    // MARK: - Nonisolated Snapshot

    /// Protects the snapshot variables read from outside the actor.
    /// Writes happen only from the actor (`write*Snapshot`); reads may come
    /// from any thread through the `nonisolated` accessors below.
    private nonisolated let snapshotLock = NSLock()
    /// Mirror of the actor's lifecycle state; guarded by `snapshotLock`.
    nonisolated(unsafe) private var _stateSnapshot: ServerState = .stopped
    /// Mirror of `connections.count`; guarded by `snapshotLock`.
    nonisolated(unsafe) private var _connectionCountSnapshot: Int = 0
    /// Mirror of `isOverlayVisible`; guarded by `snapshotLock`.
    nonisolated(unsafe) private var _overlayVisibleSnapshot = true

    /// Latest server state, safe to read synchronously from any thread.
    nonisolated var state: ServerState {
        snapshotLock.withLock { _stateSnapshot }
    }

    /// Latest connected-client count, safe to read synchronously from any thread.
    nonisolated var connectionCount: Int {
        snapshotLock.withLock { _connectionCountSnapshot }
    }

    /// Whether playback cards are currently allowed to render. Stream Deck uses
    /// this visibility switch instead of stopping the shared command transport.
    nonisolated var overlayVisible: Bool {
        snapshotLock.withLock { _overlayVisibleSnapshot }
    }

    /// Publishes `newState` to the snapshot. Prefer `transition(to:)`, which
    /// also notifies observers.
    private func writeStateSnapshot(_ newState: ServerState) {
        snapshotLock.withLock { _stateSnapshot = newState }
    }

    /// Publishes the authenticated client count to the snapshot.
    func writeConnectionCountSnapshot(_ count: Int) {
        snapshotLock.withLock { _connectionCountSnapshot = count }
    }

    /// Publishes overlay-card visibility to the snapshot.
    private func writeOverlayVisibleSnapshot(_ visible: Bool) {
        snapshotLock.withLock { _overlayVisibleSnapshot = visible }
    }

    // MARK: - State Change Stream

    /// Replaces the legacy `onStateChange` callback. Consumers iterate
    /// `for await (state, clientCount) in service.stateChanges`.
    ///
    /// Single-consumer (an `AsyncStream` delivers each element to one
    /// iterator). Buffers the newest 64 events and finishes in `deinit`.
    nonisolated let stateChanges: AsyncStream<(ServerState, Int)>
    /// Producer side of `stateChanges`; yielded to by `notifyStateChange()`.
    private nonisolated let stateContinuation: AsyncStream<(ServerState, Int)>.Continuation

    /// Number of currently-connected authenticated clients (overlay and
    /// control alike). Safe to call from any thread. Used by the tray menu's
    /// "Stream Widgets" status subtitle.
    nonisolated var connectedClientCount: Int { connectionCount }

    /// The port the listener actually bound, or `nil` before it binds. Differs
    /// from the configured port only when that was `0`, which asks the kernel
    /// for a free ephemeral port. Tests bind `0` and read this back so they can
    /// never collide with an unrelated process holding a hardcoded port.
    var boundPort: UInt16? {
        listener?.port?.rawValue
    }

    // MARK: - Properties

    /// WebSocket port. `0` asks the kernel for an ephemeral port (tests).
    var port: UInt16
    /// Read-only credential used by OBS widgets and other state consumers.
    /// `nil` only in lifecycle tests that construct the legacy initializer.
    var overlayToken: String?
    /// Privileged credential used by same-Mac Stream Deck clients.
    /// `nil` only in lifecycle tests that construct the legacy initializer.
    var controlToken: String?
    /// The active listener, or `nil` while stopped or between retries.
    var listener: NWListener?
    /// Authenticated clients that reached `.ready` and passed the role checks.
    /// Every broadcast fans out over this list (or a role-filtered subset).
    var connections: [NWConnection] = []
    /// The authenticated role of each entry in ``connections``.
    ///
    /// Overlay and control clients want different things from the same server:
    /// hiding the overlay cards must stop the browser source rendering, but a
    /// Stream Deck still needs to know what is playing. Keeping the role lets
    /// the playback fan-out address one audience without the other.
    var connectionRoles: [ObjectIdentifier: WebSocketAuthToken.Role] = [:]
    /// Accepted TCP peers that have not completed the authenticated WebSocket
    /// handshake. They are capped, timed out, and owned across listener stop.
    var pendingConnections: [NWConnection] = []
    /// One `handshakeTimeout` task per pending connection, cancelled when the
    /// connection is promoted or removed.
    var handshakeTimeoutTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Bumped on every start, stop, and listener failure. Network.framework
    /// callbacks capture the value they were wired under and are ignored (or
    /// cancel their connection) once it no longer matches, so a late event
    /// from a torn-down listener can't touch the current one.
    var listenerGeneration: UInt64 = 0
    /// Dispatch queue used only for Network.framework callbacks. All state is actor-confined.
    nonisolated let networkQueue = DispatchQueue(
        label: AppConstants.DispatchQueues.websocketServer,
        qos: .utility
    )
    /// The user's on/off intent from `setEnabled(_:)`. Gates retries and the
    /// progress timer independently of whether a listener is currently up.
    var isEnabled = false
    /// The companion HTTP server for `widget.html`, owned by this actor. It is
    /// started and stopped with the listener and rebuilt on every start, so a
    /// rotated overlay token reaches the served HTML.
    var widgetHTTP: WidgetHTTPService?
    /// Port `widgetHTTP` was started on, or `nil` when it is not running.
    var widgetHTTPPort: UInt16?
    /// Pending listener restart after a failure; cancelled by `stopServer()`.
    var retryTask: Task<Void, Never>?

    /// Handler invoked for each inbound Stream Deck command, returning the ack to
    /// send back on the originating connection. Set by AppDelegate via
    /// ``setCommandHandler(_:)``; the service itself knows nothing about the
    /// app's services, keeping this layer decoupled and testable.
    var onCommand: (@Sendable (StreamDeckCommand) async -> CommandAck)?

    // MARK: - Playback State

    // Last-known track, replayed to new clients. `nil` track fields mean
    // nothing is loaded (initial state, or after `clearNowPlaying()`).
    var currentTrack: String?
    var currentArtist: String?
    var currentAlbum: String?
    /// Track length in seconds; `0` when unknown or cleared.
    var currentDuration: TimeInterval = 0
    /// Elapsed seconds as of `lastElapsedUpdate`; see `estimatedElapsed()`.
    var currentElapsed: TimeInterval = 0
    /// `false` while paused or stopped.
    var isPlaying = false
    /// Whether overlay clients may render the playback card. Toggled by the
    /// Stream Deck `overlay_toggle` key; it never stops the transport.
    var isOverlayVisible = true
    /// Artwork for the current track; `nil` until its async lookup lands.
    var currentArtworkURL: String?
    /// Wall-clock time `currentElapsed` was last set, for interpolation.
    var lastElapsedUpdate: Date?
    /// The running progress loop, or `nil` when `shouldRunProgressTimer` is false.
    var progressTask: Task<Void, Never>?
    /// Seconds between `progress` frames.
    var currentProgressInterval: TimeInterval = AppConstants.WebSocketServer.progressBroadcastInterval

    /// Last-broadcast upcoming-queue snapshot, replayed to freshly-connected
    /// clients the same way `currentTrack` is. Unlike `broadcastQueueState`
    /// (counts only, never replayed), the ticker needs replay-on-connect so an
    /// OBS Browser Source reload doesn't show an empty/stale ticker until the
    /// next queue mutation.
    private var currentQueueUpcoming: [QueueUpcomingItem] = []

    // MARK: - Init

    /// Legacy credential-less initializer for lifecycle tests. With no tokens,
    /// every handshake is accepted as the read-only overlay role and no client
    /// can run commands.
    init(port: UInt16 = AppConstants.WebSocketServer.defaultPort) {
        self.port = port
        self.overlayToken = nil
        self.controlToken = nil
        let (stream, continuation) = AsyncStream<(ServerState, Int)>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self.stateChanges = stream
        self.stateContinuation = continuation
    }

    /// Production initializer. Enforces role-specific credentials on every handshake.
    ///
    /// The service starts stopped; call `setEnabled(true)` to bind. Callers are
    /// expected to pass two different tokens (AppDelegate rotates the control
    /// token if they collide); equal tokens only ever authenticate as overlay.
    init(port: UInt16, overlayToken: String, controlToken: String) {
        self.port = port
        self.overlayToken = overlayToken
        self.controlToken = controlToken
        let (stream, continuation) = AsyncStream<(ServerState, Int)>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self.stateChanges = stream
        self.stateContinuation = continuation
    }

    deinit {
        // Cancel the NWListener and all open NWConnections before the actor is
        // deallocated. Not calling these would leave the OS-level socket open
        // until Network.framework released it, and active NWConnections would retain their
        // send/receive closures (keeping the object graph alive longer than
        // expected). `stateContinuation.finish()` must come last so any
        // consumer still iterating `stateChanges` sees the stream end.
        retryTask?.cancel()
        progressTask?.cancel()
        listener?.cancel()
        for conn in connections {
            conn.stateUpdateHandler = nil
            conn.cancel()
        }
        for conn in pendingConnections {
            conn.stateUpdateHandler = nil
            conn.cancel()
        }
        for task in handshakeTimeoutTasks.values { task.cancel() }
        widgetHTTP?.stop()
        stateContinuation.finish()
    }

    // MARK: - Public API

    /// Starts or stops the server based on the given flag.
    ///
    /// Enabling is idempotent while a listener exists. Disabling also cancels
    /// any pending retry and drops every client.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            startServer()
            reconcileProgressTimer()
        } else {
            stopServer()
        }
    }

    /// Installs the inbound-command handler. Called once at setup by AppDelegate.
    func setCommandHandler(_ handler: @escaping @Sendable (StreamDeckCommand) async -> CommandAck) {
        onCommand = handler
    }

    /// Starts or stops the widget HTTP server independently.
    ///
    /// Enabling is a no-op unless the WebSocket listener is `.listening`; in
    /// that case `startServer()` picks up `FeatureFlags.widgetHTTPEnabled` on
    /// the next start instead.
    func setWidgetHTTPEnabled(_ enabled: Bool) {
        if enabled {
            // Only start if WebSocket server is listening and HTTP isn't already running
            guard state == .listening, widgetHTTP == nil else { return }
            let resolvedPort = Preferences.resolvedWidgetPort
            widgetHTTPPort = resolvedPort
            widgetHTTP = WidgetHTTPService(port: resolvedPort, overlayToken: overlayToken)
            widgetHTTP?.start()
            Log.info("WebSocketServerService: Widget HTTP server started", category: .websocket)
        } else {
            widgetHTTP?.stop()
            widgetHTTP = nil
            widgetHTTPPort = nil
            Log.info("WebSocketServerService: Widget HTTP server stopped", category: .websocket)
        }
    }

    /// Restarts only the widget HTTP listener when its configured port changes.
    /// The WebSocket listener and connected OBS/Stream Deck clients stay intact.
    /// Out-of-range ports are ignored. If the widget server wasn't running, or
    /// the WebSocket server isn't `.listening`, it stays down.
    func updateWidgetPort(_ newPort: UInt16) {
        guard newPort >= AppConstants.WebSocketServer.minPort,
              newPort <= AppConstants.WebSocketServer.maxPort else { return }
        guard widgetHTTPPort != newPort else { return }

        let wasRunning = widgetHTTP != nil
        widgetHTTP?.stop()
        widgetHTTP = nil
        widgetHTTPPort = nil

        guard wasRunning, state == .listening else { return }
        widgetHTTPPort = newPort
        widgetHTTP = WidgetHTTPService(port: newPort, overlayToken: overlayToken)
        widgetHTTP?.start()
        Log.info(
            "WebSocketServerService: Widget HTTP port changed to \(newPort), listener restarted",
            category: .websocket
        )
    }

    /// Swaps the overlay credential and restarts an active listener so every
    /// client must re-authenticate. The caller persists it first.
    func updateOverlayToken(_ newToken: String) {
        guard overlayToken != newToken else { return }
        overlayToken = newToken
        restartIfListening()
    }

    /// Swaps the control credential and restarts an active listener so every
    /// client must re-authenticate. The caller persists it first.
    func updateControlToken(_ newToken: String) {
        guard controlToken != newToken else { return }
        controlToken = newToken
        restartIfListening()
    }

    /// Stops and restarts the listener (if one exists) so new credentials take
    /// effect and every client re-authenticates. `startServer()` also rebuilds
    /// `widgetHTTP`, so the served HTML picks up the new overlay token.
    private func restartIfListening() {
        guard listener != nil else { return }
        stopServer()
        startServer()
    }

    /// Changes the listening port. Restarts the server if it was already running
    /// or still starting (a port change during `.starting` would otherwise bind
    /// the old port and silently ignore the new value). Out-of-range ports are
    /// ignored. Note a server in `.error` awaiting retry has no listener, so it
    /// just picks up the new port on the retry.
    func updatePort(_ newPort: UInt16) {
        guard newPort >= AppConstants.WebSocketServer.minPort,
              newPort <= AppConstants.WebSocketServer.maxPort else { return }
        guard port != newPort else { return }

        let needsRestart = listener != nil
        port = newPort

        if needsRestart {
            Log.info(
                "WebSocketServerService: Port changed to \(newPort) while listener active, restarting",
                category: .websocket
            )
            stopServer()
            startServer()
        }
    }

    /// Stores new track metadata and broadcasts a `now_playing` message to all clients.
    ///
    /// - Parameter isPaused: `true` when the underlying source reports the
    ///   loaded track as paused. The broadcast still goes out so overlay
    ///   clients can render a paused affordance; the progress ticker is
    ///   suspended while paused and resumed on the next non-paused update.
    func updateNowPlaying(
        track: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        elapsed: TimeInterval,
        artworkURL: String? = nil,
        isPaused: Bool = false
    ) {
        let identityChanged = currentTrack != track || currentArtist != artist

        // Steady-state dedup: the source re-emits the same track every ~5s. When
        // only elapsed advanced (no track/pause/artwork change), refresh the
        // progress baseline and skip the full rebroadcast + progress-timer
        // restart. The timer is already in the correct state because isPaused is
        // unchanged; overlay clients keep ticking locally from the last frame.
        let unchanged = currentTrack == track
            && currentArtist == artist
            && currentAlbum == album
            && currentDuration == duration
            && isPlaying == !isPaused
            && (artworkURL == nil || artworkURL == currentArtworkURL)
        if unchanged {
            currentElapsed = elapsed
            lastElapsedUpdate = Date()
            reconcileProgressTimer()
            return
        }

        currentTrack = track
        currentArtist = artist
        currentAlbum = album
        currentDuration = duration
        currentElapsed = elapsed
        isPlaying = !isPaused
        lastElapsedUpdate = Date()
        if identityChanged {
            // Never let a new track inherit the previous track's artwork while
            // its own asynchronous lookup is still in flight.
            currentArtworkURL = artworkURL
        } else if let artworkURL {
            currentArtworkURL = artworkURL
        }

        broadcastNowPlaying()
        reconcileProgressTimer()
    }

    /// Applies an asynchronous artwork result only if its track is still current.
    /// Returns `false` when a late or duplicate result was ignored.
    @discardableResult
    func updateArtworkURL(_ url: String, track: String, artist: String) -> Bool {
        guard currentTrack == track, currentArtist == artist else {
            Log.debug(
                "WebSocketServerService: Ignoring stale artwork result for \(track) — \(artist)",
                category: .websocket
            )
            return false
        }
        guard currentArtworkURL != url else { return false }
        currentArtworkURL = url
        broadcastNowPlaying()
        return true
    }

    /// Toggles only playback-card visibility while leaving the authenticated
    /// WebSocket transport alive for Stream Deck commands and acknowledgements.
    ///
    /// - Returns: The new visibility.
    @discardableResult
    func toggleOverlayVisibility() -> Bool {
        setOverlayVisibility(!isOverlayVisible)
        return isOverlayVisible
    }

    /// Sets playback-card visibility and broadcasts an `overlay_visibility`
    /// frame. On show, it replays the current state to every client so the
    /// card repaints immediately instead of waiting for the next track event.
    func setOverlayVisibility(_ visible: Bool) {
        guard visible != isOverlayVisible else { return }
        isOverlayVisible = visible
        writeOverlayVisibleSnapshot(visible)
        broadcastOverlayVisibility()
        if visible {
            if currentTrack == nil {
                broadcastPlaybackState()
            } else {
                broadcastNowPlaying()
            }
        }
        reconcileProgressTimer()
    }

    /// Builds the `widget_config` message from the persisted widget-appearance
    /// prefs. Shared by the broadcast-to-all and send-to-one paths so the two
    /// snapshots can never drift.
    func widgetConfigPayload() -> [String: Any] {
        let defaults = DefaultsStore.store
        return [
            "type": "widget_config",
            "data": [
                "theme": defaults.string(forKey: AppConstants.UserDefaults.widgetTheme) ?? AppConstants.Widget.Defaults.theme,
                "layout": defaults.string(forKey: AppConstants.UserDefaults.widgetLayout) ?? AppConstants.Widget.Defaults.layout,
                "textColor": defaults.string(forKey: AppConstants.UserDefaults.widgetTextColor) ?? AppConstants.Widget.Defaults.textColor,
                "backgroundColor": defaults.string(forKey: AppConstants.UserDefaults.widgetBackgroundColor) ?? AppConstants.Widget.Defaults.backgroundColor,
                "fontFamily": defaults.string(forKey: AppConstants.UserDefaults.widgetFontFamily) ?? AppConstants.Widget.Defaults.fontFamily
            ]
        ]
    }

    /// Broadcasts widget theme/customization config to all connected clients.
    func broadcastWidgetConfig() {
        broadcastJSON(widgetConfigPayload())
    }

    /// Broadcasts request-queue counts and hold state so a Stream Deck counter
    /// or hold key renders without polling. Values are supplied by the caller
    /// (AppDelegate) to keep this actor decoupled from the song-request services.
    ///
    /// `held` exists so the hold key can show real state instead of guessing:
    /// without it a plugin has to track its own optimistic toggle, which drifts
    /// the moment hold is changed from the tray, chat (`!hold`), or Settings.
    ///
    /// `audience` is the raw `RequestAudience` value. Same reasoning as `held`:
    /// the audience is changeable from Settings and from a key, so the key has
    /// to render what the app says rather than what it last sent.
    func broadcastQueueState(count: Int, pending: Int, held: Bool, audience: String) {
        broadcastJSON([
            "type": "queue_state",
            "data": [
                "count": count, "pending": pending, "held": held, "audience": audience
            ]
        ])
    }

    /// Builds the `queue_upcoming` message from the cached snapshot. Shared by
    /// the broadcast-to-all and send-to-one paths, same reasoning as
    /// `widgetConfigPayload()`.
    private func queueUpcomingPayload() -> [String: Any] {
        [
            "type": "queue_upcoming",
            "data": ["items": currentQueueUpcoming.map {
                ["title": $0.title, "requesterUsername": $0.requesterUsername]
            }]
        ]
    }

    /// Caches and broadcasts the next few queued requests so the overlay's
    /// queue ticker renders without polling. Caller (AppDelegate) is
    /// responsible for capping to `AppConstants.WebSocketServer.queueTickerMaxItems`.
    /// An empty array is a valid, meaningful state: "the queue is open."
    func broadcastQueueUpcoming(items: [QueueUpcomingItem]) {
        currentQueueUpcoming = items
        broadcastJSON(queueUpcomingPayload())
    }

    /// Replays the cached `queue_upcoming` snapshot to one new client.
    func sendQueueUpcoming(to connection: NWConnection) {
        Self.sendJSON(queueUpcomingPayload(), to: connection)
    }

    /// Broadcasts aggregate connection health for a Stream Deck status key.
    /// Not cached or replayed on connect; the caller re-broadcasts on change.
    /// Shape is mirrored by `HealthData` in the plugin's `protocol.ts`.
    func broadcastHealth(
        music: Bool, twitch: Bool, discord: Bool, discordState: String, overlay: Bool
    ) {
        broadcastJSON(Self.healthPayload(
            music: music, twitch: twitch, discord: discord,
            discordState: discordState, overlay: overlay))
    }

    /// Pure payload builder for the `health` frame. `discord` is the legacy
    /// boolean (enabled AND connected); `discordState` is additive and keeps
    /// "off" distinguishable from "disconnected" / "connecting".
    nonisolated static func healthPayload(
        music: Bool, twitch: Bool, discord: Bool, discordState: String, overlay: Bool
    ) -> [String: Any] {
        [
            "type": "health",
            "data": [
                "music": music, "twitch": twitch, "discord": discord,
                "discordState": discordState, "overlay": overlay
            ] as [String: Any]
        ]
    }

    /// Updates the progress broadcast interval and restarts the timer if currently broadcasting.
    ///
    /// - Parameter interval: New broadcast interval in seconds. Not validated;
    ///   the caller supplies a sane positive value.
    func updateProgressInterval(_ interval: TimeInterval) {
        currentProgressInterval = interval
        if progressTask != nil {
            startProgressTimer()
        }
    }

    /// Marks playback as fully stopped and broadcasts the state change.
    ///
    /// Called when Music.app quits, permission is revoked, or the source
    /// errors, never on a plain pause (that path keeps the track and goes
    /// through `updateNowPlaying`). Clears the cached track so a stale song
    /// can't leak into a later `now_playing` re-broadcast, and so overlay
    /// clients hide the card instead of lingering on the last track.
    func clearNowPlaying() {
        isPlaying = false
        lastElapsedUpdate = nil
        currentTrack = nil
        currentArtist = nil
        currentAlbum = nil
        currentArtworkURL = nil
        currentDuration = 0
        currentElapsed = 0

        stopProgressTimer()
        broadcastPlaybackState()
    }

    // MARK: - State Notification

    /// Updates the snapshot, yields onto `stateChanges`, and posts a
    /// `NotificationCenter` event on the main actor.
    func transition(to newState: ServerState) {
        writeStateSnapshot(newState)
        notifyStateChange()
    }

    /// Yields the current snapshot (state, client count) onto `stateChanges`
    /// and posts the server-state notification on the main actor.
    func notifyStateChange() {
        let currentState = state
        let count = connectionCount
        stateContinuation.yield((currentState, count))

        Task { @MainActor in
            NotificationCenter.default.postWebSocketServerState(currentState.rawValue, clients: count)
        }
    }
}
