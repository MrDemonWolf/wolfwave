//
//  WidgetLink.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-30.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Browser Source links for the OBS widget page.
///
/// The page connects to the WebSocket server on the default port unless its
/// URL names another, so every link WolfWave hands out (Copy Link, the menu
/// bar, setup) is built here and carries `port=` when the server runs
/// somewhere else.
nonisolated enum WidgetLink {

    // MARK: - Public Methods

    /// The widget page URL.
    ///
    /// - Parameters:
    ///   - host: `localhost` for OBS on this Mac, or a LAN address.
    ///   - widgetPort: The widget HTTP server's port.
    ///   - webSocketPort: The WebSocket server's port. Added as `port=` only
    ///     when it differs from the default the page assumes.
    ///   - token: The overlay token, for a link opened on another device.
    ///     Loopback links leave it out: `WidgetHTTPService` injects it.
    /// - Returns: The link, like `http://localhost:8766` or
    ///   `http://192.168.1.5:8766/?port=9000&token=…`.
    static func url(
        host: String,
        widgetPort: UInt16,
        webSocketPort: UInt16,
        token: String? = nil
    ) -> String {
        var query: [String] = []
        if webSocketPort != AppConstants.WebSocketServer.defaultPort {
            query.append("port=\(webSocketPort)")
        }
        if let token, !token.isEmpty {
            query.append("token=\(token)")
        }
        let base = "http://\(host):\(widgetPort)"
        return query.isEmpty ? base : "\(base)/?\(query.joined(separator: "&"))"
    }

    /// The loopback link for the ports saved in Settings, resolved the way the
    /// servers bind them.
    static var loopback: String {
        url(
            host: "localhost",
            widgetPort: Preferences.resolvedWidgetPort,
            webSocketPort: Preferences.resolvedWebSocketServerPort)
    }
}
