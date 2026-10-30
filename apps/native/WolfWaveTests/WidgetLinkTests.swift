//
//  WidgetLinkTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-30.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation
@testable import WolfWave

/// Widget Browser Source links. The page assumes the default WebSocket port,
/// so a link names any other port, and only a LAN link carries the token.
@Suite("Widget links")
struct WidgetLinkTests {

    private let widgetPort = AppConstants.WebSocketServer.widgetDefaultPort
    private let defaultWebSocketPort = AppConstants.WebSocketServer.defaultPort
    private let token = "wolfwave.overlay.abc123"

    @Test("on the default ports a loopback link is the bare address")
    func defaultPorts() {
        let link = WidgetLink.url(host: "localhost", widgetPort: widgetPort, webSocketPort: defaultWebSocketPort)
        #expect(link == "http://localhost:8766")
    }

    @Test("a custom WebSocket port rides along as port=")
    func customWebSocketPort() {
        let link = WidgetLink.url(host: "localhost", widgetPort: 9100, webSocketPort: 9000)
        #expect(link == "http://localhost:9100/?port=9000")
    }

    @Test("a LAN link carries the token")
    func networkLink() {
        let link = WidgetLink.url(
            host: "192.168.1.5", widgetPort: widgetPort, webSocketPort: defaultWebSocketPort, token: token)
        #expect(link == "http://192.168.1.5:8766/?token=wolfwave.overlay.abc123")
    }

    @Test("a LAN link on a custom port carries both")
    func networkLinkWithCustomPort() {
        let link = WidgetLink.url(host: "192.168.1.5", widgetPort: widgetPort, webSocketPort: 9000, token: token)
        #expect(link == "http://192.168.1.5:8766/?port=9000&token=wolfwave.overlay.abc123")
    }

    @Test("an empty token is left out")
    func emptyToken() {
        let link = WidgetLink.url(
            host: "localhost", widgetPort: widgetPort, webSocketPort: defaultWebSocketPort, token: "")
        #expect(link == "http://localhost:8766")
    }

    /// The page reads `port` with `URLSearchParams`; it has to come back out intact.
    @Test("the port parses back out of the link")
    func portRoundTrips() throws {
        let link = WidgetLink.url(host: "192.168.1.5", widgetPort: widgetPort, webSocketPort: 9000, token: token)
        let components = try #require(URLComponents(string: link))
        #expect(components.queryItems?.first { $0.name == "port" }?.value == "9000")
        #expect(components.queryItems?.first { $0.name == "token" }?.value == token)
    }
}

/// `WidgetLink.loopback` follows the ports saved in Settings. Serialized
/// because both tests write the same two keys.
@Suite("Widget loopback link", .serialized, .isolatedSharedTestState)
struct WidgetLoopbackLinkTests {

    @Test("the loopback link follows the saved ports")
    func followsSavedPorts() {
        let defaults = DefaultsStore.store
        defaults.set(9100, forKey: AppConstants.UserDefaults.widgetPort)
        defaults.set(9000, forKey: AppConstants.UserDefaults.websocketServerPort)
        #expect(WidgetLink.loopback == "http://localhost:9100/?port=9000")
    }

    @Test("unset ports give the bare default address")
    func unsetPorts() {
        let defaults = DefaultsStore.store
        defaults.removeObject(forKey: AppConstants.UserDefaults.widgetPort)
        defaults.removeObject(forKey: AppConstants.UserDefaults.websocketServerPort)
        #expect(WidgetLink.loopback == "http://localhost:8766")
    }
}
