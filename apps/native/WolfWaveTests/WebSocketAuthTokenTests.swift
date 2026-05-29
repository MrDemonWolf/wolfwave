//
//  WebSocketAuthTokenTests.swift
//  WolfWaveTests
//
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// Direct unit tests for the `WebSocketAuthToken` type — creation, Keychain
/// persistence, rotation, validation, and redaction. The handshake / accept
/// path is covered separately by `WebSocketServerAuthTests`.
final class WebSocketAuthTokenTests: XCTestCase {

    /// The real on-disk token captured in setUp so the suite can restore it and
    /// not clobber a developer's running install.
    private var savedToken: String?

    override func setUp() {
        super.setUp()
        savedToken = KeychainService.loadToken()
        KeychainService.deleteToken()
    }

    override func tearDown() {
        if let savedToken {
            try? KeychainService.saveToken(savedToken)
        } else {
            KeychainService.deleteToken()
        }
        savedToken = nil
        super.tearDown()
    }

    // MARK: - Creation + persistence

    func testCurrentOrCreateMintsAndPersists() {
        XCTAssertNil(KeychainService.loadToken(), "precondition: no token stored")

        let created = WebSocketAuthToken.currentOrCreate()

        XCTAssertEqual(created.count, 64, "fresh token is 32 random bytes / 64 hex chars")
        XCTAssertTrue(WebSocketAuthToken.isValid(created))
        XCTAssertEqual(KeychainService.loadToken(), created, "token must be persisted")
    }

    func testCurrentOrCreateReturnsSameTokenOnSecondCall() {
        let first = WebSocketAuthToken.currentOrCreate()
        let second = WebSocketAuthToken.currentOrCreate()
        XCTAssertEqual(first, second, "existing token must be reused, not regenerated")
    }

    // MARK: - Rotation

    func testRotateReplacesStoredToken() {
        let original = WebSocketAuthToken.currentOrCreate()
        let rotated = WebSocketAuthToken.rotate()

        XCTAssertNotEqual(rotated, original, "rotation must mint a new value")
        XCTAssertEqual(rotated.count, 64)
        XCTAssertEqual(KeychainService.loadToken(), rotated, "rotated token must be persisted")
    }

    func testRotateProducesDistinctTokens() {
        var seen = Set<String>()
        for _ in 0..<20 {
            seen.insert(WebSocketAuthToken.rotate())
        }
        XCTAssertEqual(seen.count, 20, "rotation must not repeat tokens")
    }

    // MARK: - Subprotocol

    func testExpectedSubprotocolPrefixesToken() {
        XCTAssertEqual(
            WebSocketAuthToken.expectedSubprotocol(for: "abc123"),
            "wolfwave.token.abc123"
        )
    }

    // MARK: - Validation

    func testIsValidAcceptsHexInLengthRange() {
        XCTAssertTrue(WebSocketAuthToken.isValid(String(repeating: "a", count: 16)))
        XCTAssertTrue(WebSocketAuthToken.isValid(String(repeating: "F", count: 64)))
        XCTAssertTrue(WebSocketAuthToken.isValid(String(repeating: "0", count: 128)))
    }

    func testIsValidRejectsOutOfRangeLengths() {
        XCTAssertFalse(WebSocketAuthToken.isValid(String(repeating: "a", count: 15)))
        XCTAssertFalse(WebSocketAuthToken.isValid(String(repeating: "a", count: 129)))
        XCTAssertFalse(WebSocketAuthToken.isValid(""))
    }

    func testIsValidRejectsNonHexCharacters() {
        // Long enough but contains characters that could break out of a JS
        // string when substituted into widget.html.
        XCTAssertFalse(WebSocketAuthToken.isValid("zzzzzzzzzzzzzzzz"))
        XCTAssertFalse(WebSocketAuthToken.isValid("</script>aaaaaaaa"))
        XCTAssertFalse(WebSocketAuthToken.isValid("abcdef0123456789 "))
    }

    func testGeneratedTokenIsValid() {
        XCTAssertTrue(WebSocketAuthToken.isValid(WebSocketAuthToken.currentOrCreate()))
    }

    // MARK: - Redaction

    func testRedactKeepsFirstFourCharsOnly() {
        XCTAssertEqual(WebSocketAuthToken.redact("a1b2c3d4e5f6"), "a1b2…")
    }

    func testRedactCollapsesShortTokens() {
        XCTAssertEqual(WebSocketAuthToken.redact("ab"), "…")
        XCTAssertEqual(WebSocketAuthToken.redact("abcd"), "…")
    }

    func testRedactNeverLeaksFullToken() {
        let token = WebSocketAuthToken.currentOrCreate()
        let redacted = WebSocketAuthToken.redact(token)
        XCTAssertFalse(redacted.contains(String(token.dropFirst(4))))
        XCTAssertLessThanOrEqual(redacted.count, 5)
    }
}
