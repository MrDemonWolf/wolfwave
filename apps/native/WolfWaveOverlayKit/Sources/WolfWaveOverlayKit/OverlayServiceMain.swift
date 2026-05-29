//
//  OverlayServiceMain.swift
//  WolfWaveOverlayKit
//
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//
//  XPC service side. The `WolfWaveOverlayServer.xpc` target's `main.swift` is a
//  one-liner: `import WolfWaveOverlayKit; OverlayServiceMain.start()`.
//

import Foundation
import os

/// Bridges incoming `OverlayServerXPC` messages to the `OverlayWebSocketServer`
/// actor, and forwards the server's state changes back to the host app over the
/// connection's `OverlayServerHostXPC` proxy.
final class OverlayServerXPCAdapter: NSObject, OverlayServerXPC, OverlayServerDelegate, @unchecked Sendable {

    private let log = Logger(subsystem: OverlayConstants.logSubsystem, category: "XPCAdapter")
    private let server: OverlayWebSocketServer
    private weak var connection: NSXPCConnection?
    private let decoder = JSONDecoder()

    init(connection: NSXPCConnection) {
        self.connection = connection
        // Bundle.main here is the .xpc bundle — it must contain widget.html +
        // widget-tokens.generated.js (Copy Bundle Resources in the xpc target).
        self.server = OverlayWebSocketServer(resourceBundle: .main, delegate: nil)
        super.init()
        let s = server
        Task { await s.setDelegate(self) }
    }

    // MARK: OverlayServerDelegate (server -> host)

    func overlayServer(stateDidChange rawState: String, clientCount: Int) {
        guard let proxy = connection?.remoteObjectProxy as? OverlayServerHostXPC else { return }
        proxy.serverStateChanged(rawState, clientCount: clientCount)
    }

    // MARK: OverlayServerXPC (host -> server)

    func configure(_ configJSON: Data, withReply reply: @escaping () -> Void) {
        guard let cfg = try? decoder.decode(OverlayServerConfig.self, from: configJSON) else {
            log.error("configure: failed to decode OverlayServerConfig")
            reply()
            return
        }
        Task { await server.configure(cfg); reply() }
    }

    func setEnabled(_ on: Bool) { Task { await server.setEnabled(on) } }
    func setWidgetHTTPEnabled(_ on: Bool) { Task { await server.setWidgetHTTPEnabled(on) } }
    func updatePort(_ port: UInt16) { Task { await server.updatePort(port) } }
    func updateAuthToken(_ token: String) { Task { await server.updateAuthToken(token) } }
    func updateProgressInterval(_ seconds: Double) { Task { await server.updateProgressInterval(seconds) } }
    func updateArtworkURL(_ url: String) { Task { await server.updateArtworkURL(url) } }
    func clearNowPlaying() { Task { await server.clearNowPlaying() } }

    func updateNowPlaying(_ payloadJSON: Data) {
        guard let p = try? decoder.decode(NowPlayingPayload.self, from: payloadJSON) else {
            log.error("updateNowPlaying: failed to decode NowPlayingPayload")
            return
        }
        Task { await server.updateNowPlaying(p) }
    }

    func updateWidgetConfig(_ appearanceJSON: Data) {
        guard let a = try? decoder.decode(WidgetAppearance.self, from: appearanceJSON) else {
            log.error("updateWidgetConfig: failed to decode WidgetAppearance")
            return
        }
        Task { await server.updateWidgetConfig(a) }
    }
}

/// Per-connection listener delegate. One adapter (and one server) per connection.
final class OverlayServiceConnectionHandler: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: OverlayServerXPC.self)
        connection.exportedObject = OverlayServerXPCAdapter(connection: connection)
        connection.remoteObjectInterface = NSXPCInterface(with: OverlayServerHostXPC.self)
        connection.resume()
        return true
    }
}

/// Entry point for the XPC service executable.
public enum OverlayServiceMain {
    private static let handler = OverlayServiceConnectionHandler()

    /// Starts the XPC service run loop. For `NSXPCListener.service()`, `resume()`
    /// does not return.
    public static func start() {
        let listener = NSXPCListener.service()
        listener.delegate = handler
        listener.resume()
    }
}
