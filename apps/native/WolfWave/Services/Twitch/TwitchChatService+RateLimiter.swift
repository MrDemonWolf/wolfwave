//
//  TwitchChatService+RateLimiter.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-11.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

extension TwitchChatService {

    // MARK: - Rate Limiter (nested actor)

    /// Tracks Helix per-endpoint rate-limit headers and waits for the bucket to
    /// reset when saturated. Lives in its own isolation domain so heavy API
    /// usage doesn't block the chat-message receive loop.
    actor RateLimiter {
        /// Last known bucket per endpoint path. Process-local; starts empty,
        /// so the first request to an endpoint never waits.
        private var states: [String: RateLimitState] = [:]

        /// Returns the seconds to wait before retrying when the local accountant
        /// believes `endpoint` is currently saturated, or `nil` if no wait is needed.
        func waitTimeIfRateLimited(endpoint: String) -> TimeInterval? {
            guard let state = states[endpoint] else { return nil }
            let now = Date().timeIntervalSince1970
            let timeUntilReset = state.resetTime - now
            if state.remaining <= 0 && timeUntilReset > 0 {
                return timeUntilReset
            }
            return nil
        }

        /// Sleeps until `endpoint`'s bucket has capacity. Loops in case multiple
        /// callers race for the same window.
        func awaitCapacity(endpoint: String) async throws {
            while let wait = waitTimeIfRateLimited(endpoint: endpoint) {
                try await Task.sleep(for: .seconds(wait))
            }
            try Task.checkCancellation()
        }

        /// Records a hard 429 backoff: marks `endpoint` saturated until
        /// `resetEpoch` (seconds since 1970) so ``awaitCapacity(endpoint:)``
        /// sleeps until the bucket is allowed to refill. Used by the reactive
        /// 429 retry path after parsing `Ratelimit-Reset` / `Retry-After`.
        func noteRateLimited(endpoint: String, untilEpoch resetEpoch: TimeInterval) {
            let now = Date().timeIntervalSince1970
            let delta = resetEpoch - now
            guard delta.isFinite,
                  let wait = RetryAfter.bounded(max(0, delta)) else {
                return
            }
            var state = states[endpoint] ?? RateLimitState()
            state.remaining = 0
            state.resetTime = now + wait
            states[endpoint] = state
        }

        /// Parses the seconds to wait after a `429 Too Many Requests` response.
        ///
        /// Parses `Retry-After` (delta or HTTP date) and `Ratelimit-Reset`
        /// (epoch seconds), choosing the later bounded signal so a retry never
        /// fires before either server deadline.
        ///
        /// `nonisolated` + `static` so it is unit-testable without the actor or a
        /// live socket.
        nonisolated static func retryWaitSeconds(
            from headers: [AnyHashable: Any],
            now: TimeInterval
        ) -> TimeInterval? {
            func headerValue(_ name: String) -> String? {
                if let direct = headers[name] as? String { return direct }
                // Header lookups are case-insensitive in practice; scan keys.
                for (key, value) in headers {
                    if let keyString = key as? String,
                       keyString.caseInsensitiveCompare(name) == .orderedSame,
                       let stringValue = value as? String {
                        return stringValue
                    }
                }
                return nil
            }

            let retryAfterSeconds = headerValue("Retry-After").flatMap {
                RetryAfter.seconds(
                    $0,
                    now: Date(timeIntervalSince1970: now))
            }
            let resetSeconds: TimeInterval? = headerValue("Ratelimit-Reset").flatMap { reset in
                guard let resetEpoch = TimeInterval(
                    reset.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    return nil
                }
                let delta = resetEpoch - now
                guard delta.isFinite else { return nil }
                return RetryAfter.bounded(max(0, delta))
            }
            return [retryAfterSeconds, resetSeconds].compactMap { $0 }.max()
        }

        /// Records Twitch's `Ratelimit-*` headers after a Helix response.
        func updateRateLimitState(endpoint: String, from headers: [AnyHashable: Any]) {
            var state = states[endpoint] ?? RateLimitState()

            if let remaining = headers["Ratelimit-Remaining"] as? String,
               let remainingInt = Int(remaining) {
                state.remaining = remainingInt
            }
            if let reset = headers["Ratelimit-Reset"] as? String,
               let resetInt = TimeInterval(reset) {
                let now = Date().timeIntervalSince1970
                let delta = resetInt - now
                if delta.isFinite,
                   let wait = RetryAfter.bounded(max(0, delta)) {
                    state.resetTime = now + wait
                }
            }
            if let limit = headers["Ratelimit-Limit"] as? String,
               let limitInt = Int(limit) {
                state.limit = limitInt
            }

            states[endpoint] = state

            if state.remaining <= 5 && state.remaining > 0 {
                Log.warn(
                    "TwitchChatService: Approaching rate limit on \(endpoint): \(state.remaining)/\(state.limit) remaining",
                    category: .twitchChat)
            }

            MetricsService.shared.recordTwitchRateLimit(
                endpoint: endpoint,
                remaining: state.remaining,
                limit: state.limit,
                resetTime: state.resetTime
            )
        }
    }
}
