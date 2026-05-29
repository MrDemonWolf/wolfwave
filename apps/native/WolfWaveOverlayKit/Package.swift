// swift-tools-version: 6.0
import PackageDescription

// WolfWaveOverlayKit
//
// Shared overlay-server code used by three consumers:
//   - the WolfWave app (via the in-app `WebSocketServerService` facade that
//     drives the server over XPC),
//   - the `WolfWaveOverlayServer.xpc` service target (hosts the server),
//   - this package's own test target (exercises the pure logic).
//
// Deliberately has NO dependency on the app module: no UserDefaults, Keychain,
// Bundle.main, MetricsService, or AppConstants. Everything dynamic is injected
// via `OverlayServerConfig` / `updateWidgetConfig` / an injected resource Bundle.
let package = Package(
    name: "WolfWaveOverlayKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "WolfWaveOverlayKit", targets: ["WolfWaveOverlayKit"]),
    ],
    targets: [
        .target(
            name: "WolfWaveOverlayKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WolfWaveOverlayKitTests",
            dependencies: ["WolfWaveOverlayKit"],
            resources: [.copy("Resources/widget.html"), .copy("Resources/widget-tokens.generated.js")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
