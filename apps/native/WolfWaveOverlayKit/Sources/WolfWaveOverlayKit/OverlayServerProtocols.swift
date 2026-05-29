//
//  OverlayServerProtocols.swift
//  WolfWaveOverlayKit
//
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

// MARK: - XPC Interfaces

/// App → service. Structured payloads cross as JSON `Data` (Codable), which NSXPC
/// allows without a custom interface allow-list. Scalars cross natively.
@objc public protocol OverlayServerXPC {
    /// Supplies the full `OverlayServerConfig` (JSON). Reply confirms the service
    /// applied it — the facade waits on this before sending playback updates.
    func configure(_ configJSON: Data, withReply reply: @escaping () -> Void)
    func setEnabled(_ on: Bool)
    func setWidgetHTTPEnabled(_ on: Bool)
    func updatePort(_ port: UInt16)
    func updateAuthToken(_ token: String)
    func updateProgressInterval(_ seconds: Double)
    /// `NowPlayingPayload` JSON.
    func updateNowPlaying(_ payloadJSON: Data)
    func updateArtworkURL(_ url: String)
    /// `WidgetAppearance` JSON.
    func updateWidgetConfig(_ appearanceJSON: Data)
    func clearNowPlaying()
}

/// Service → app. Replaces the in-process `stateChanges` AsyncStream; the facade
/// re-publishes these onto its own AsyncStream + NotificationCenter.
@objc public protocol OverlayServerHostXPC {
    func serverStateChanged(_ rawState: String, clientCount: Int)
}

// MARK: - In-process delegate

/// How `OverlayWebSocketServer` reports state without knowing about XPC or
/// NotificationCenter. The XPC adapter forwards these to the host proxy; tests
/// can observe directly.
public protocol OverlayServerDelegate: AnyObject, Sendable {
    func overlayServer(stateDidChange rawState: String, clientCount: Int)
}
