//
//  TwitchChatService+APIRequests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Rate-limited Helix API requests with a single 429 retry.
extension TwitchChatService {

    // MARK: - API Requests

    /// Sends an API request to the Twitch Helix API.
    ///
    /// Blocks (via `Task.sleep`) when the local rate-limit accountant says the
    /// endpoint is saturated; records returned `Ratelimit-*` headers.
    ///
    /// A 429 gets exactly one retry after the server's reset time.
    ///
    /// - Parameters:
    ///   - endpoint: Path appended to `apiBaseURL`, e.g. `/chat/messages`. Also
    ///     the rate-limit bucket key.
    ///   - body: JSON body, or `nil`.
    /// - Returns: The response body of a 2xx response.
    /// - Throws: `ConnectionError.authenticationFailed` on 401;
    ///   `HelixRequestError.retryableHTTP` (408, 425, 429, 5xx) or
    ///   `.permanentHTTP` (other non-2xx); transport errors and
    ///   `CancellationError` as thrown.
    func sendAPIRequest(
        method: String,
        endpoint: String,
        body: [String: Any]?,
        token: String,
        clientID: String
    ) async throws -> Data {
        // Wait for rate-limit capacity before sending.
        if let waitTime = await rateLimiter.waitTimeIfRateLimited(endpoint: endpoint) {
            Log.info(
                "TwitchChatService: Request queued due to rate limit. Retry after \(String(format: "%.1f", waitTime))s",
                category: .twitchChat)
            try await rateLimiter.awaitCapacity(endpoint: endpoint)
        }

        guard let url = URL(string: apiBaseURL + endpoint) else {
            throw ConnectionError.networkError("Invalid URL")
        }

        let request: URLRequest
        do {
            request = try HelixClient.buildRequest(
                url: url, method: method,
                credentials: .init(token: token, clientID: clientID), body: body)
        } catch {
            Log.error(
                "TwitchChatService: Failed to serialize request body - \(error.localizedDescription)",
                category: .twitchChat)
            throw ConnectionError.networkError("Failed to serialize request body")
        }

        try Task.checkCancellation()
        var (data, http) = try await helixHTTPClient.send(request)

        await rateLimiter.updateRateLimitState(
            endpoint: endpoint, from: http.allHeaderFields)

        // Reactive 429: honor the server's reset, wait for capacity, then do
        // exactly ONE bounded retry. Never loop, so a persistent 429 can't spin.
        if http.statusCode == 429 {
            let wait = RateLimiter.retryWaitSeconds(
                from: http.allHeaderFields, now: Date().timeIntervalSince1970)
            if let wait {
                Log.info(
                    "TwitchChatService: API \(endpoint) hit 429; waiting \(String(format: "%.1f", wait))s before one retry",
                    category: .twitchChat)
                await rateLimiter.noteRateLimited(
                    endpoint: endpoint, untilEpoch: Date().timeIntervalSince1970 + wait)
                try await rateLimiter.awaitCapacity(endpoint: endpoint)
            } else {
                Log.info(
                    "TwitchChatService: API \(endpoint) hit 429 without a reset header; one immediate retry",
                    category: .twitchChat)
            }

            try Task.checkCancellation()
            (data, http) = try await helixHTTPClient.send(request)
            await rateLimiter.updateRateLimitState(
                endpoint: endpoint, from: http.allHeaderFields)
        }

        let disposition = Self.helixResponseDisposition(for: http.statusCode)
        guard disposition == .success else {
            let responseText = String(data: data, encoding: .utf8) ?? "No response body"
            Log.warn(
                "TwitchChatService: API \(endpoint) returned HTTP \(http.statusCode) - \(responseText)",
                category: .twitchChat)

            switch disposition {
            case .success:
                return data
            case .authenticationFailure:
                throw ConnectionError.authenticationFailed
            case .retryableFailure:
                throw HelixRequestError.retryableHTTP(statusCode: http.statusCode)
            case .permanentFailure:
                throw HelixRequestError.permanentHTTP(statusCode: http.statusCode)
            }
        }

        return data
    }
}
