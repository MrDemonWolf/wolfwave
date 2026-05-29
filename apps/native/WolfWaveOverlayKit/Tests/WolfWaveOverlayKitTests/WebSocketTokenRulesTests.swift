import XCTest
@testable import WolfWaveOverlayKit

final class WebSocketTokenRulesTests: XCTestCase {

    func testExpectedSubprotocolPrefixes() {
        XCTAssertEqual(WebSocketTokenRules.expectedSubprotocol(for: "abcd1234"), "wolfwave.token.abcd1234")
    }

    func testShouldAcceptNilTokenAllowsAny() {
        XCTAssertTrue(WebSocketTokenRules.shouldAccept(expectedToken: nil, offeredSubprotocols: []))
        XCTAssertTrue(WebSocketTokenRules.shouldAccept(expectedToken: nil, offeredSubprotocols: ["anything"]))
    }

    func testShouldAcceptMatchingSubprotocol() {
        let token = "deadbeefdeadbeef"
        let offered = [WebSocketTokenRules.expectedSubprotocol(for: token)]
        XCTAssertTrue(WebSocketTokenRules.shouldAccept(expectedToken: token, offeredSubprotocols: offered))
    }

    func testShouldRejectMissingOrMismatchedSubprotocol() {
        let token = "deadbeefdeadbeef"
        XCTAssertFalse(WebSocketTokenRules.shouldAccept(expectedToken: token, offeredSubprotocols: []))
        XCTAssertFalse(WebSocketTokenRules.shouldAccept(
            expectedToken: token,
            offeredSubprotocols: ["wolfwave.token.wrong0000wrong000"]
        ))
    }

    func testIsValidHexBounds() {
        XCTAssertTrue(WebSocketTokenRules.isValid(String(repeating: "a", count: 16)))
        XCTAssertTrue(WebSocketTokenRules.isValid(String(repeating: "F", count: 64)))
        XCTAssertTrue(WebSocketTokenRules.isValid(String(repeating: "0", count: 128)))
    }

    func testIsValidRejectsOutOfBoundsAndNonHex() {
        XCTAssertFalse(WebSocketTokenRules.isValid(String(repeating: "a", count: 15)))
        XCTAssertFalse(WebSocketTokenRules.isValid(String(repeating: "a", count: 129)))
        XCTAssertFalse(WebSocketTokenRules.isValid("zzzzzzzzzzzzzzzz"))
        XCTAssertFalse(WebSocketTokenRules.isValid("abcd</script>abcd"))
    }

    func testRedactKeepsFirstFour() {
        XCTAssertEqual(WebSocketTokenRules.redact("abcdef123456"), "abcd…")
        XCTAssertEqual(WebSocketTokenRules.redact("ab"), "…")
    }
}
