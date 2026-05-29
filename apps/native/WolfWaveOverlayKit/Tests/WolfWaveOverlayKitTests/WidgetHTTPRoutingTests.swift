import XCTest
@testable import WolfWaveOverlayKit

final class WidgetHTTPRoutingTests: XCTestCase {

    private func request(_ line: String) -> Data {
        Data("\(line)\r\nHost: localhost\r\n\r\n".utf8)
    }

    // MARK: - Routing

    func testRouteWidgetRoot() {
        XCTAssertEqual(OverlayWidgetHTTPServer.route(forRequest: request("GET / HTTP/1.1")), .widget)
        XCTAssertEqual(OverlayWidgetHTTPServer.route(forRequest: request("GET /?token=abc HTTP/1.1")), .widget)
    }

    func testRouteTokensJS() {
        XCTAssertEqual(
            OverlayWidgetHTTPServer.route(forRequest: request("GET /widget-tokens.generated.js HTTP/1.1")),
            .tokensJS
        )
    }

    func testRouteFavicon() {
        XCTAssertEqual(OverlayWidgetHTTPServer.route(forRequest: request("GET /favicon.ico HTTP/1.1")), .favicon)
        XCTAssertEqual(OverlayWidgetHTTPServer.route(forRequest: request("GET /favicon.png HTTP/1.1")), .favicon)
    }

    func testRouteNotFound() {
        XCTAssertEqual(OverlayWidgetHTTPServer.route(forRequest: request("GET /nope HTTP/1.1")), .notFound)
        XCTAssertEqual(OverlayWidgetHTTPServer.route(forRequest: request("POST / HTTP/1.1")), .notFound)
    }

    // MARK: - Rendering / token injection

    func testRenderInjectsTokenForLoopbackValidToken() {
        let html = "<html>var t='__WOLFWAVE_TOKEN__';</html>"
        let token = String(repeating: "a", count: 32)
        let out = OverlayWidgetHTTPServer.renderWidgetHTML(rawHTML: html, tokensJS: nil, token: token, isLoopback: true)
        XCTAssertTrue(out.contains("var t='\(token)';"))
        XCTAssertFalse(out.contains("__WOLFWAVE_TOKEN__"))
    }

    func testRenderDoesNotInjectForNonLoopback() {
        let html = "<html>var t='__WOLFWAVE_TOKEN__';</html>"
        let token = String(repeating: "a", count: 32)
        let out = OverlayWidgetHTTPServer.renderWidgetHTML(rawHTML: html, tokensJS: nil, token: token, isLoopback: false)
        XCTAssertTrue(out.contains("__WOLFWAVE_TOKEN__"))
    }

    func testRenderRefusesInvalidToken() {
        let html = "<html>var t='__WOLFWAVE_TOKEN__';</html>"
        let out = OverlayWidgetHTTPServer.renderWidgetHTML(rawHTML: html, tokensJS: nil, token: "</script>", isLoopback: true)
        XCTAssertTrue(out.contains("__WOLFWAVE_TOKEN__"))
        XCTAssertFalse(out.contains("</script>"))
    }

    func testRenderInlinesTokensJS() {
        let html = "<head><script src=\"widget-tokens.generated.js\"></script></head>"
        let out = OverlayWidgetHTTPServer.renderWidgetHTML(
            rawHTML: html, tokensJS: "window.WW_TOKENS={};", token: nil, isLoopback: true
        )
        XCTAssertTrue(out.contains("<script>\nwindow.WW_TOKENS={};\n</script>"))
        XCTAssertFalse(out.contains("src=\"widget-tokens.generated.js\""))
    }

    // MARK: - Bundled asset present

    func testBundledWidgetHTMLLoadsAndRenders() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "widget", withExtension: "html"))
        let raw = try String(contentsOf: url, encoding: .utf8)
        let token = String(repeating: "b", count: 64)
        let out = OverlayWidgetHTTPServer.renderWidgetHTML(rawHTML: raw, tokensJS: "X", token: token, isLoopback: true)
        XCTAssertFalse(out.contains("__WOLFWAVE_TOKEN__"), "token placeholder should be substituted")
    }
}
