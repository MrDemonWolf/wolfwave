//
//  OverlayModels.swift
//  WolfWaveOverlayKit
//
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Widget theme/customization the overlay broadcasts to connected clients as a
/// `widget_config` message. Previously read directly from `UserDefaults` inside
/// the server; now the app snapshots it and pushes it across XPC.
public struct WidgetAppearance: Codable, Sendable, Equatable {
    public var theme: String
    public var layout: String
    public var textColor: String
    public var backgroundColor: String
    public var fontFamily: String

    public init(
        theme: String,
        layout: String,
        textColor: String,
        backgroundColor: String,
        fontFamily: String
    ) {
        self.theme = theme
        self.layout = layout
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.fontFamily = fontFamily
    }

    /// Matches the prior in-server fallbacks.
    public static let `default` = WidgetAppearance(
        theme: "Default",
        layout: "Horizontal",
        textColor: "#FFFFFF",
        backgroundColor: "#1A1A2E",
        fontFamily: "System"
    )
}

/// Everything the server needs to run, supplied by the app over XPC. Replaces
/// the server's former direct reads of `UserDefaults` and `Bundle.main`.
public struct OverlayServerConfig: Codable, Sendable {
    public var port: UInt16
    public var widgetPort: UInt16
    public var token: String?
    public var appVersion: String
    public var widgetHTTPEnabled: Bool
    public var appearance: WidgetAppearance

    public init(
        port: UInt16,
        widgetPort: UInt16,
        token: String?,
        appVersion: String,
        widgetHTTPEnabled: Bool,
        appearance: WidgetAppearance
    ) {
        self.port = port
        self.widgetPort = widgetPort
        self.token = token
        self.appVersion = appVersion
        self.widgetHTTPEnabled = widgetHTTPEnabled
        self.appearance = appearance
    }
}

/// Now-playing snapshot pushed from the app to the server. JSON-encoded so it
/// crosses the XPC boundary as `Data` (no `NSSecureCoding` ceremony needed).
public struct NowPlayingPayload: Codable, Sendable {
    public var track: String
    public var artist: String
    public var album: String
    public var duration: Double
    public var elapsed: Double
    public var artworkURL: String?
    public var isPaused: Bool

    public init(
        track: String,
        artist: String,
        album: String,
        duration: Double,
        elapsed: Double,
        artworkURL: String?,
        isPaused: Bool
    ) {
        self.track = track
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsed = elapsed
        self.artworkURL = artworkURL
        self.isPaused = isPaused
    }
}
