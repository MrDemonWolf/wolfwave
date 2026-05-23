//
//  TwitchBitsParsingTests.swift
//  WolfWaveTests
//
//  Created by MrDemonWolf, Inc. on 5/22/26.
//

import XCTest

@testable import WolfWave

nonisolated final class TwitchBitsParsingTests: XCTestCase {

    // MARK: - cleanBitsMessage with fragments

    @MainActor func testCleanBitsMessageJoinsTextFragments() {
        let message: [String: Any] = [
            "text": "Cheer100 Bohemian Rhapsody",
            "fragments": [
                ["type": "cheermote", "text": "Cheer100"],
                ["type": "text", "text": " Bohemian Rhapsody"],
            ],
        ]
        XCTAssertEqual(
            TwitchChatService.cleanBitsMessage(message), "Bohemian Rhapsody")
    }

    @MainActor func testCleanBitsMessageHandlesMultipleTextFragments() {
        let message: [String: Any] = [
            "text": "Cheer50 take Cheer100 on me",
            "fragments": [
                ["type": "cheermote", "text": "Cheer50"],
                ["type": "text", "text": " take "],
                ["type": "cheermote", "text": "Cheer100"],
                ["type": "text", "text": " on me"],
            ],
        ]
        XCTAssertEqual(
            TwitchChatService.cleanBitsMessage(message), "take  on me")
    }

    @MainActor func testCleanBitsMessageReturnsEmptyForNil() {
        XCTAssertEqual(TwitchChatService.cleanBitsMessage(nil), "")
    }

    @MainActor func testCleanBitsMessageFallsBackToStrippingWhenFragmentsMissing() {
        let message: [String: Any] = ["text": "Cheer250 Africa by Toto"]
        XCTAssertEqual(
            TwitchChatService.cleanBitsMessage(message), "Africa by Toto")
    }

    // MARK: - stripLeadingCheermotes

    @MainActor func testStripLeadingCheermotesRemovesSingleToken() {
        XCTAssertEqual(
            TwitchChatService.stripLeadingCheermotes("Cheer100 Bohemian Rhapsody"),
            "Bohemian Rhapsody")
    }

    @MainActor func testStripLeadingCheermotesRemovesMultipleTokens() {
        XCTAssertEqual(
            TwitchChatService.stripLeadingCheermotes("Cheer100 Cheer50 Africa"), "Africa")
    }

    @MainActor func testStripLeadingCheermotesIsCaseInsensitive() {
        XCTAssertEqual(
            TwitchChatService.stripLeadingCheermotes("cheer250 Wonderwall"), "Wonderwall")
    }

    @MainActor func testStripLeadingCheermotesLeavesNonCheermoteTextUnchanged() {
        XCTAssertEqual(
            TwitchChatService.stripLeadingCheermotes("Bohemian Rhapsody"), "Bohemian Rhapsody")
    }

    @MainActor func testStripLeadingCheermotesDoesNotStripMidString() {
        // "U2 One" should NOT be treated as a cheermote — the strip only matches at the start.
        XCTAssertEqual(
            TwitchChatService.stripLeadingCheermotes("Beautiful Day by U2"), "Beautiful Day by U2")
    }
}
