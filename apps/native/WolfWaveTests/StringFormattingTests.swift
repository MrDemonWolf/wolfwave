//
//  StringFormattingTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-11.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
@testable import WolfWave

/// Pins the shared chat-reply truncation to Twitch's real limit, which counts
/// Unicode code points rather than Swift `Character`s.
@Suite("StringFormatting")
struct StringFormattingTests {

    private let limit = AppConstants.Twitch.maxMessageLength
    private let suffix = AppConstants.Twitch.messageTruncationSuffix

    @Test("a message within the limit is returned unchanged")
    func fitsUnchanged() {
        let exact = String(repeating: "a", count: limit)
        #expect(exact.truncatedForChat() == exact)
        #expect("hello".truncatedForChat() == "hello")
    }

    @Test("ASCII truncation keeps the full limit including the suffix")
    func asciiTruncation() {
        let result = String(repeating: "a", count: limit + 100).truncatedForChat()
        #expect(result.count == limit)
        #expect(result.hasSuffix(suffix))
    }

    @Test("truncation counts scalars, not graphemes")
    func truncationCountsScalarsNotGraphemes() {
        // Family emoji: one Character, seven scalars (four people + three ZWJ).
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        #expect(family.count == 1)
        #expect(family.unicodeScalars.count == 7)

        // 100 graphemes but 700 scalars: under the old Character count this
        // passed through untouched and Twitch rejected it.
        let families = String(repeating: family, count: 100)
        let truncated = families.truncatedForChat()
        #expect(truncated.unicodeScalars.count <= limit)
        #expect(truncated.hasSuffix(suffix))
        // Never splits an emoji: everything before the suffix is whole families.
        let body = truncated.dropLast(suffix.count)
        #expect(body.allSatisfy { $0 == Character(family) })
        #expect(body.count == (limit - suffix.unicodeScalars.count) / 7)
    }

    @Test("flags are two scalars each and are never cut in half")
    func flagsStayWhole() {
        let flag = "\u{1F1FA}\u{1F1F8}"
        #expect(flag.count == 1)
        let flags = String(repeating: flag, count: 300)  // 600 scalars
        let truncated = flags.truncatedForChat()
        #expect(truncated.unicodeScalars.count <= limit)
        let body = truncated.dropLast(suffix.count)
        #expect(body.allSatisfy { $0 == Character(flag) })
        #expect(body.unicodeScalars.count % 2 == 0)
    }

    @Test("a grapheme-short but scalar-long message is still truncated")
    func scalarOverflowTriggersTruncation() {
        let accent = "e\u{0301}"  // one Character, two scalars
        let text = String(repeating: accent, count: 300)
        #expect(text.count == 300)
        #expect(text.truncatedForChat() != text)
    }

    @Test("ellipsis helper shortens long queries only")
    func ellipsisHelper() {
        #expect(StringFormatting.truncatedWithEllipsis("short") == "short")
        let long = String(repeating: "q", count: 40)
        #expect(StringFormatting.truncatedWithEllipsis(long) == String(repeating: "q", count: 30) + "...")
    }
}
