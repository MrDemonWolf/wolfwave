//
//  RetryAfter.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-11.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Parses and bounds server-supplied retry delays (`Retry-After`, and any other
/// header expressed as a delta in seconds).
///
/// Every service that honors a server's back-off routes through here so the
/// same validation applies everywhere: a non-finite, negative, or unparseable
/// value is rejected, and anything past ``maximumServerDelay`` is capped. That
/// cap is what keeps a hostile or buggy `Retry-After: 1e308` from trapping in
/// `Duration.seconds(_:)` or parking a task for centuries.
///
/// Example:
/// ```swift
/// let wait = RetryAfter.duration(http.value(forHTTPHeaderField: "Retry-After"))
/// ```
nonisolated enum RetryAfter {

    // MARK: - Constants

    /// Maximum delay accepted from a server header. Five minutes matches the
    /// durable redemption backoff ceiling and prevents overflow traps or
    /// impractically long in-memory tasks.
    static let maximumServerDelay: TimeInterval = 300

    // MARK: - Public Methods

    /// Validates and caps a server delay before it becomes a Swift `Duration`.
    ///
    /// - Parameter seconds: A delay the server asked for, in seconds.
    /// - Returns: `seconds` capped at ``maximumServerDelay``, or `nil` when it
    ///   is non-finite or negative.
    static func bounded(_ seconds: TimeInterval) -> TimeInterval? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return min(seconds, maximumServerDelay)
    }

    /// Parses `Retry-After` delta-seconds or any RFC 9110 HTTP-date form into a
    /// finite, nonnegative, bounded number of seconds.
    ///
    /// - Parameters:
    ///   - value: The raw header value, or `nil` when the header was absent.
    ///   - now: The reference instant an HTTP-date is measured against.
    /// - Returns: The bounded delay, `0` for a date already in the past, or
    ///   `nil` when the value is absent or unparseable.
    static func seconds(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(trimmed) {
            return bounded(seconds)
        }
        for formatter in SharedFormatters.httpDate {
            if let date = formatter.date(from: trimmed) {
                return bounded(max(0, date.timeIntervalSince(now)))
            }
        }
        return nil
    }

    /// Parses `Retry-After` into a `Duration`, only after numeric range
    /// validation, so construction can never trap.
    ///
    /// - Parameters:
    ///   - value: The raw header value, or `nil` when the header was absent.
    ///   - now: The reference instant an HTTP-date is measured against.
    /// - Returns: The bounded delay, or `nil` when absent or unparseable.
    static func duration(_ value: String?, now: Date = Date()) -> Duration? {
        seconds(value, now: now).map(Duration.seconds)
    }
}
