//
//  RetryAfterTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-11.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Testing
@testable import WolfWave

/// Pins the shared `Retry-After` parser every back-off path routes through:
/// Twitch OAuth, Helix redemption resolution, the chat rate limiter, and
/// iTunes artwork lookups.
@Suite("Retry-After")
struct RetryAfterTests {

    /// `Sun, 06 Nov 1994 08:49:37 GMT`, twelve seconds before the RFC 9110
    /// example date.
    private let now = Date(timeIntervalSince1970: 784_111_777)

    // MARK: - Delta seconds

    @Test("Delta-seconds parse, tolerating surrounding whitespace")
    func deltaSeconds() {
        #expect(RetryAfter.seconds("12") == 12)
        #expect(RetryAfter.seconds("  12\n") == 12)
        #expect(RetryAfter.duration("12") == .seconds(12))
        #expect(RetryAfter.seconds("0") == 0)
    }

    @Test("An absent or unparseable header yields nil")
    func absentOrGarbage() {
        #expect(RetryAfter.seconds(nil) == nil)
        #expect(RetryAfter.seconds("") == nil)
        #expect(RetryAfter.seconds("soon") == nil)
        #expect(RetryAfter.duration("not-a-number") == nil)
    }

    // MARK: - HTTP-date

    @Test(
        "Every RFC 9110 HTTP-date form resolves against now",
        arguments: [
            "Sun, 06 Nov 1994 08:49:49 GMT",  // IMF-fixdate
            "Sunday, 06-Nov-94 08:49:49 GMT", // obsolete RFC 850
            "Sun Nov  6 08:49:49 1994"        // ANSI C asctime
        ])
    func httpDateForms(_ value: String) {
        #expect(RetryAfter.duration(value, now: now) == .seconds(12))
    }

    @Test("asctime with a two-digit day parses")
    func asctimeTwoDigitDay() {
        let later = now.addingTimeInterval(10 * 86_400)
        #expect(RetryAfter.seconds("Wed Nov 16 08:49:49 1994", now: later) == 12)
    }

    @Test("A date already in the past means retry now, not never")
    func pastDateIsZero() {
        #expect(RetryAfter.seconds(
            "Sun, 06 Nov 1994 08:49:00 GMT", now: now) == 0)
    }

    @Test("A far-future date is capped at the ceiling")
    func farFutureDateIsCapped() {
        #expect(RetryAfter.seconds(
            "Fri, 01 Jan 2100 00:00:00 GMT", now: now)
            == RetryAfter.maximumServerDelay)
    }

    // MARK: - Bounds

    @Test("Huge, non-finite and negative values never reach Duration")
    func boundsRejectAndCap() {
        #expect(RetryAfter.duration("1e308") == .seconds(300))
        #expect(RetryAfter.duration("1e309") == nil)
        #expect(RetryAfter.duration("nan") == nil)
        #expect(RetryAfter.duration("-1") == nil)
    }

    @Test("bounded rejects non-finite and negative input and caps the rest")
    func boundedHelper() {
        #expect(RetryAfter.bounded(.infinity) == nil)
        #expect(RetryAfter.bounded(.nan) == nil)
        #expect(RetryAfter.bounded(-0.5) == nil)
        #expect(RetryAfter.bounded(0) == 0)
        #expect(RetryAfter.bounded(42) == 42)
        #expect(RetryAfter.bounded(10_000) == RetryAfter.maximumServerDelay)
    }

    @Test("The ceiling is five minutes")
    func ceiling() {
        #expect(RetryAfter.maximumServerDelay == 300)
    }
}
