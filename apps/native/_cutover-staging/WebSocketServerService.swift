//
//  WebSocketServerService.swift  (FACADE — app target)
//  WolfWave
//
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//
//  ┌───────────────────────────────────────────────────────────────────────┐
//  │ STAGED FILE — add to the WolfWave APP target during cutover.            │
//  │ Replaces the old in-process WebSocketServerService.swift +              │
//  │ WidgetHTTPService.swift (delete those from the app target). Keeps the    │
//  │ same public surface so AppDelegate call sites are unchanged; forwards    │
//  │ over XPC to WolfWaveOverlayServer.xpc. See CUTOVER.md.                    │
//  └───────────────────────────────────────────────────────────────────────┘
//
//  Ordering guarantee: every public method first `await ensureConfigured()`,
//  which sends `configure` and waits on its reply before anything else reaches
//  the service. Without this the service could `setEnabled` (start listening)
//  before the auth token is applied and accept UNAUTHENTICATED clients.
//

import Foundation
import WolfWaveOverlayKit

actor WebSocketServerService {

    typealias ServerState = OverlayWebSocketServer.ServerState

    // MARK: - Nonisolated snapshot (synchronous reads from SwiftUI / menu bar)

    private nonisolated let snapshotLock = NSLock()
    nonisolated(unsafe) private var _state: ServerState = .stopped
    nonisolated(unsafe) private var _clients: Int = 0

    nonisolated var state: ServerState { snapshotLock.withLock { _state } }
    nonisolated var connectionCount: Int { snapshotLock.withLock { _clients } }
    nonisolated var connectedClientCount: Int { connectionCount }

    // MARK: - State change stream (re-published from the XPC host callback)

    nonisolated let stateChanges: AsyncStream<(ServerState, Int)>
    private nonisolated let stateContinuation: AsyncStream<(ServerState, Int)>.Continuation

    // MARK: - Config the facade owns

    private var port: UInt16
    private var authToken: String?
    private var widgetHTTPEnabled: Bool

    // MARK: - Replayable state for crash recovery

    private var isEnabled = false
    private var lastPayload: NowPlayingPayload?

    // MARK: - XPC

    private var connection: NSXPCConnection?
    private var host: HostCallback?
    private var configureTask: Task<Void, Never>?
    /// Bumped each time a new NSXPCConnection is created; lets termination
    /// handlers ignore callbacks from a connection we already replaced.
    private var connectionGeneration = 0

    // MARK: - Init

    init(port: UInt16 = OverlayConstants.defaultPort) {
        self.port = port
        self.authToken = nil
        self.widgetHTTPEnabled = UserDefaults.standard.object(
            forKey: AppConstants.UserDefaults.widgetHTTPEnabled
        ) as? Bool ?? false
        let (stream, continuation) = AsyncStream<(ServerState, Int)>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self.stateChanges = stream
        self.stateContinuation = continuation
    }

    init(port: UInt16, authToken: String) {
        self.port = port
        self.authToken = authToken
        self.widgetHTTPEnabled = UserDefaults.standard.object(
            forKey: AppConstants.UserDefaults.widgetHTTPEnabled
        ) as? Bool ?? false
        let (stream, continuation) = AsyncStream<(ServerState, Int)>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self.stateChanges = stream
        self.stateContinuation = continuation
    }

    deinit {
        stateContinuation.finish()
        connection?.invalidate()
    }

    // MARK: - Public API (unchanged surface)

    func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        await ensureConfigured()
        remote?.setEnabled(enabled)
    }

    func setWidgetHTTPEnabled(_ enabled: Bool) async {
        widgetHTTPEnabled = enabled
        await ensureConfigured()
        remote?.setWidgetHTTPEnabled(enabled)
    }

    func updateAuthToken(_ newToken: String) async {
        authToken = newToken
        await ensureConfigured()
        remote?.updateAuthToken(newToken)
    }

    func updatePort(_ newPort: UInt16) async {
        guard newPort >= OverlayConstants.minPort, newPort <= OverlayConstants.maxPort else { return }
        port = newPort
        await ensureConfigured()
        remote?.updatePort(newPort)
    }

    func updateNowPlaying(
        track: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        elapsed: TimeInterval,
        artworkURL: String? = nil,
        isPaused: Bool = false
    ) async {
        let payload = NowPlayingPayload(
            track: track, artist: artist, album: album,
            duration: duration, elapsed: elapsed, artworkURL: artworkURL, isPaused: isPaused
        )
        lastPayload = payload
        await ensureConfigured()
        if let data = try? JSONEncoder().encode(payload) { remote?.updateNowPlaying(data) }
    }

    func updateArtworkURL(_ url: String) async {
        lastPayload?.artworkURL = url
        await ensureConfigured()
        remote?.updateArtworkURL(url)
    }

    func broadcastWidgetConfig() async {
        await ensureConfigured()
        if let data = try? JSONEncoder().encode(currentAppearance()) { remote?.updateWidgetConfig(data) }
    }

    func updateProgressInterval(_ interval: TimeInterval) async {
        await ensureConfigured()
        remote?.updateProgressInterval(interval)
    }

    func clearNowPlaying() async {
        lastPayload = nil
        await ensureConfigured()
        remote?.clearNowPlaying()
    }

    // MARK: - Connection + configuration

    private var remote: OverlayServerXPC? {
        connection?.remoteObjectProxyWithErrorHandler { _ in } as? OverlayServerXPC
    }

    /// Idempotent. Builds the connection (if needed) and waits for `configure`
    /// to be applied before any other message takes effect.
    private func ensureConfigured() async {
        if let task = configureTask { await task.value; return }
        let task = Task { await self.performConfigure() }
        configureTask = task
        await task.value
    }

    private func performConfigure() async {
        connectIfNeeded()
        guard let conn = connection, let data = try? JSONEncoder().encode(currentConfig()) else {
            configureTask = nil   // allow a later retry
            return
        }
        // NSXPC guarantees exactly one of the reply or the error handler fires.
        // Resume from whichever runs (resume-once guard) so a connection failure
        // can't leave ensureConfigured() suspended forever.
        let succeeded = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = ResumeGuard()
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in
                if once.fire() { cont.resume(returning: false) }
            }) as? OverlayServerXPC else {
                if once.fire() { cont.resume(returning: false) }
                return
            }
            proxy.configure(data) {
                if once.fire() { cont.resume(returning: true) }
            }
        }
        if !succeeded {
            // configure didn't apply (connection error) — clear so callers retry.
            configureTask = nil
        }
    }

    private func connectIfNeeded() {
        guard connection == nil else { return }
        connectionGeneration += 1
        let generation = connectionGeneration
        let conn = NSXPCConnection(serviceName: OverlayConstants.xpcServiceName)
        conn.remoteObjectInterface = NSXPCInterface(with: OverlayServerXPC.self)
        conn.exportedInterface = NSXPCInterface(with: OverlayServerHostXPC.self)
        let callback = HostCallback(owner: self)
        conn.exportedObject = callback
        conn.interruptionHandler = { [weak self] in
            Task { await self?.handleTermination(generation: generation) }
        }
        conn.invalidationHandler = { [weak self] in
            Task { await self?.handleTermination(generation: generation) }
        }
        conn.resume()
        self.connection = conn
        self.host = callback
    }

    /// Service crashed or was killed. Drop the stale connection and re-establish
    /// from last-known state so the overlay recovers without user action.
    /// `generation` guards against a stale callback tearing down a connection we
    /// already replaced.
    private func handleTermination(generation: Int) async {
        guard generation == connectionGeneration else { return }
        connection?.invalidate()
        connection = nil
        host = nil
        configureTask = nil
        // Re-establish only if we were actively serving.
        guard isEnabled else { return }
        await ensureConfigured()
        remote?.setEnabled(true)
        if widgetHTTPEnabled { remote?.setWidgetHTTPEnabled(true) }
        if let payload = lastPayload, let data = try? JSONEncoder().encode(payload) {
            remote?.updateNowPlaying(data)
        }
    }

    // MARK: - Config snapshots (read app state to push across XPC)

    private func currentConfig() -> OverlayServerConfig {
        let defaults = UserDefaults.standard
        let storedWidgetPort = defaults.integer(forKey: AppConstants.UserDefaults.widgetPort)
        let widgetPort: UInt16 = storedWidgetPort > 0
            ? (UInt16(exactly: storedWidgetPort) ?? OverlayConstants.widgetDefaultPort)
            : OverlayConstants.widgetDefaultPort
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return OverlayServerConfig(
            port: port,
            widgetPort: widgetPort,
            token: authToken,
            appVersion: version,
            widgetHTTPEnabled: widgetHTTPEnabled,
            appearance: currentAppearance()
        )
    }

    private func currentAppearance() -> WidgetAppearance {
        let d = UserDefaults.standard
        return WidgetAppearance(
            theme: d.string(forKey: AppConstants.UserDefaults.widgetTheme) ?? "Default",
            layout: d.string(forKey: AppConstants.UserDefaults.widgetLayout) ?? "Horizontal",
            textColor: d.string(forKey: AppConstants.UserDefaults.widgetTextColor) ?? "#FFFFFF",
            backgroundColor: d.string(forKey: AppConstants.UserDefaults.widgetBackgroundColor) ?? "#1A1A2E",
            fontFamily: d.string(forKey: AppConstants.UserDefaults.widgetFontFamily) ?? "System"
        )
    }

    // MARK: - Host callback (service -> app)

    /// Receives state changes from the service over XPC and re-publishes them on
    /// the facade's snapshot + AsyncStream + NotificationCenter, and records the
    /// client-count metric (the only metric the in-process server used to emit).
    fileprivate func ingestStateChange(rawState: String, clientCount: Int) {
        let parsed = ServerState(rawValue: rawState) ?? .stopped
        snapshotLock.withLock {
            _state = parsed
            _clients = clientCount
        }
        stateContinuation.yield((parsed, clientCount))
        MetricsService.shared.recordWebSocketClients(clientCount)
        Task { @MainActor in
            NotificationCenter.default.post(
                name: Notification.Name.websocketServerStateChanged,
                object: nil,
                userInfo: ["state": rawState, "clients": clientCount]
            )
        }
    }
}

/// NSXPC exported object. Forwards `serverStateChanged` into the actor.
private final class HostCallback: NSObject, OverlayServerHostXPC, @unchecked Sendable {
    private weak var owner: WebSocketServerService?
    init(owner: WebSocketServerService) { self.owner = owner }

    func serverStateChanged(_ rawState: String, clientCount: Int) {
        guard let owner else { return }
        Task { await owner.ingestStateChange(rawState: rawState, clientCount: clientCount) }
    }
}

/// Lets exactly one of the XPC reply / error handler resume a continuation.
/// Both run off-actor on arbitrary threads, so the flag is lock-guarded.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
