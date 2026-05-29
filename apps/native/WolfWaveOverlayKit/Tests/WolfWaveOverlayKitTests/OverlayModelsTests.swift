import XCTest
@testable import WolfWaveOverlayKit

/// These round-trips prove the payloads survive the XPC boundary, which carries
/// them as JSON `Data`.
final class OverlayModelsTests: XCTestCase {

    func testNowPlayingPayloadRoundTrip() throws {
        let original = NowPlayingPayload(
            track: "Song", artist: "Artist", album: "Album",
            duration: 210.5, elapsed: 12.25, artworkURL: "https://example.com/a.jpg", isPaused: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NowPlayingPayload.self, from: data)
        XCTAssertEqual(decoded.track, original.track)
        XCTAssertEqual(decoded.artist, original.artist)
        XCTAssertEqual(decoded.album, original.album)
        XCTAssertEqual(decoded.duration, original.duration)
        XCTAssertEqual(decoded.elapsed, original.elapsed)
        XCTAssertEqual(decoded.artworkURL, original.artworkURL)
        XCTAssertEqual(decoded.isPaused, original.isPaused)
    }

    func testNowPlayingPayloadNilArtwork() throws {
        let original = NowPlayingPayload(
            track: "t", artist: "a", album: "al",
            duration: 0, elapsed: 0, artworkURL: nil, isPaused: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NowPlayingPayload.self, from: data)
        XCTAssertNil(decoded.artworkURL)
    }

    func testConfigRoundTrip() throws {
        let original = OverlayServerConfig(
            port: 8765, widgetPort: 8766, token: "deadbeefdeadbeef",
            appVersion: "1.2.3", widgetHTTPEnabled: true, appearance: .default
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OverlayServerConfig.self, from: data)
        XCTAssertEqual(decoded.port, 8765)
        XCTAssertEqual(decoded.widgetPort, 8766)
        XCTAssertEqual(decoded.token, "deadbeefdeadbeef")
        XCTAssertEqual(decoded.appVersion, "1.2.3")
        XCTAssertTrue(decoded.widgetHTTPEnabled)
        XCTAssertEqual(decoded.appearance, .default)
    }

    func testWidgetAppearanceDefault() {
        XCTAssertEqual(WidgetAppearance.default.theme, "Default")
        XCTAssertEqual(WidgetAppearance.default.layout, "Horizontal")
        XCTAssertEqual(WidgetAppearance.default.backgroundColor, "#1A1A2E")
    }
}
