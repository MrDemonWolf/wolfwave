//
//  OverlayConstants.swift
//  WolfWaveOverlayKit
//
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Constants for the overlay server. Mirrors the values that previously lived in
/// `AppConstants.WebSocketServer` / `AppConstants.DispatchQueues` so behavior is
/// identical after the move. The package cannot reference the app's
/// `AppConstants`, so the handful of values it needs are duplicated here.
public enum OverlayConstants {
    public static let defaultPort: UInt16 = 8765
    public static let widgetDefaultPort: UInt16 = 8766
    public static let minPort: UInt16 = 1024
    public static let maxPort: UInt16 = 65535
    public static let progressBroadcastInterval: TimeInterval = 1.0
    public static let retryDelay: TimeInterval = 5.0

    public static let websocketQueueLabel = "com.mrdemonwolf.wolfwave.websocketserver"
    public static let widgetHTTPQueueLabel = "com.mrdemonwolf.wolfwave.widget-http"

    /// Mach service name used by the XPC service bundle. Must match the
    /// `CFBundleIdentifier` of the embedded `WolfWaveOverlayServer.xpc`.
    public static let xpcServiceName = "com.mrdemonwolf.wolfwave.overlayserver"

    public static let logSubsystem = "com.mrdemonwolf.wolfwave.overlayserver"
}
