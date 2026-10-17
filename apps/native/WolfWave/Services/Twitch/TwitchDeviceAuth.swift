//
//  TwitchDeviceAuth.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-01-08.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

// MARK: - Device Code Response

/// Response structure from Twitch's device authorization endpoint.
///
/// Built only by `TwitchDeviceAuth.requestDeviceCode()`, which has already
/// range-checked `expiresIn` and `interval` against the local safety bounds,
/// so callers can pass both straight to `pollForToken`.
nonisolated struct TwitchDeviceCodeResponse: Sendable {
    /// The device verification code used for polling
    let deviceCode: String
    
    /// The short code the user must enter at the verification URL
    let userCode: String
    
    /// The URL where the user must authorize the application
    let verificationURI: String
    
    /// Optional complete URI that includes the user code (for QR codes)
    let verificationURIComplete: String?
    
    /// How long (in seconds) the device code remains valid
    let expiresIn: Int
    
    /// Minimum interval (in seconds) between polling attempts
    let interval: Int
}

// MARK: - Token Response

/// Parsed fields from a Twitch OAuth token response (device-code grant or
/// refresh-token grant). `refreshToken` and `expiresIn` are optional because
/// some grant variants omit them.
nonisolated struct TwitchTokenResponse: Sendable, Equatable {
    /// The OAuth access token.
    let accessToken: String

    /// The refresh token, when the response includes one.
    let refreshToken: String?

    /// Access-token lifetime in seconds, when present.
    let expiresIn: Int?
}

// MARK: - Device Auth Errors

/// Errors that can occur during the OAuth Device Code flow and the refresh
/// grant. Cancellation is never wrapped here: every entry point rethrows a
/// plain `CancellationError` (including `URLError.cancelled`).
///
/// `invalidClient` is overloaded: besides a bad client ID it is what
/// `refreshAccessToken` throws for a rejected refresh token (HTTP 400/401),
/// and what `pollForToken` throws for an empty device code. Callers treat it
/// as "sign in again".
enum TwitchDeviceAuthError: LocalizedError, Sendable {
    /// Server returned an invalid or unparseable response
    case invalidResponse
    
    /// User denied the authorization request
    case accessDenied
    
    /// Device code expired before user completed authorization
    case expiredToken
    
    /// Authorization is pending - user hasn't completed the flow yet
    case authorizationPending
    
    /// Client is polling too quickly - increase the polling interval when received
    case slowDown
    
    /// Invalid client credentials provided
    case invalidClient

    /// Refresh endpoint failure with status and server-directed retry delay.
    case http(status: Int, retryAfter: Duration?)

    /// Refresh transport failure. Kept distinct from permanent protocol errors.
    case transport(String)
    
    /// Other unknown error with message
    case unknown(String)

    /// Short text used in logs. `TwitchViewModel.handleOAuthError` writes its
    /// own copy for the common cases and shows this text only as a fallback.
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Twitch"
        case .accessDenied:
            return "Access denied by user"
        case .expiredToken:
            return "Device code expired"
        case .authorizationPending:
            return "Waiting for user authorization"
        case .slowDown:
            return "Polling too quickly"
        case .invalidClient:
            return "Invalid client credentials"
        case let .http(status, _):
            return "Twitch OAuth request failed with HTTP \(status)"
        case let .transport(message):
            return "Twitch OAuth network error: \(message)"
        case .unknown(let msg):
            return msg
        }
    }
}

// MARK: - Twitch Device Auth

/// Implements OAuth Device Code flow for Twitch authentication.
///
/// This flow is suitable for public clients (like desktop apps) where a client secret
/// cannot be securely embedded. Instead of running a local HTTP server, the user
/// enters a short code at Twitch's verification URL.
///
/// **OAuth Device Code Flow:**
/// 1. Request a device code from Twitch
/// 2. Display the user code and verification URL to the user
/// 3. Poll Twitch's token endpoint until the user authorizes
/// 4. Receive the access/refresh token pair. This type never persists it; the
///    caller commits it through `TwitchCredentialStore.commitDeviceGrant`.
///
/// Also performs the refresh-token grant (`refreshAccessToken`), which
/// `TwitchTokenRefresher` drives. The type is stateless apart from its
/// injected dependencies, so it is safe to share across tasks.
///
/// **Usage:**
/// ```swift
/// let auth = TwitchDeviceAuth(
///     clientID: "your-client-id",
///     scopes: ["user:read:chat", "user:write:chat", "channel:manage:polls"]
/// )
///
/// let response = try await auth.requestDeviceCode()
/// // Show user: response.userCode and response.verificationURI
///
/// let token = try await auth.pollForToken(
///     deviceCode: response.deviceCode,
///     interval: response.interval
/// ) { progress in
///     print(progress)
/// }
/// ```
///
/// **References:**
/// - [Twitch OAuth Device Code Flow](https://dev.twitch.tv/docs/authentication/getting-tokens-oauth/#device-code-grant-flow)
nonisolated final class TwitchDeviceAuth: Sendable {

    /// RFC 8628 default when an authorization response omits `interval`.
    private nonisolated static let defaultPollingInterval = 5

    /// Product safety bounds for untrusted device-flow timing metadata. Twitch
    /// currently issues 1,800-second codes with a five-second poll interval.
    /// A longer `expires_in` is rejected as `invalidResponse`, not clamped.
    private nonisolated static let maximumDeviceCodeLifetime = 3_600
    /// Local deadline (seconds) when `pollForToken` is called without `expiresIn`.
    private nonisolated static let fallbackDeviceCodeLifetime = 600
    /// Ceiling (seconds) for any single poll delay, including after backoff.
    private nonisolated static let maximumPollingInterval = 300
    
    // MARK: - Properties
    
    /// The Twitch client ID for this application
    private let clientID: String
    
    /// The OAuth scopes to request (e.g., "user:read:chat", "user:write:chat")
    private let scopes: [String]

    /// URL session used for OAuth HTTP requests. Injectable for testing.
    private let session: URLSession

    /// Monotonic time source used to enforce the original device-code expiry.
    private let pollingNow: @Sendable () -> ContinuousClock.Instant

    /// Cancellation-aware sleep operation. Injectable so polling tests never
    /// wait on wall time.
    private let pollingSleep: @Sendable (Duration, Duration?) async throws -> Void

    // MARK: - Initialization

    /// Creates a new Twitch Device Auth instance.
    ///
    /// - Parameters:
    ///   - clientID: Your Twitch application's client ID.
    ///   - scopes: Array of OAuth scope strings to request.
    ///   - session: URL session for HTTP requests. Defaults to `.shared`.
    ///   - pollingNow: Monotonic clock source used by token polling.
    ///   - pollingSleep: Cancellation-aware polling delay operation.
    init(
        clientID: String,
        scopes: [String],
        session: URLSession = .shared,
        pollingNow: @escaping @Sendable () -> ContinuousClock.Instant = {
            ContinuousClock.now
        },
        pollingSleep: @escaping @Sendable (Duration, Duration?) async throws -> Void = {
            duration, tolerance in
            let clock = ContinuousClock()
            try await clock.sleep(
                until: clock.now.advanced(by: duration),
                tolerance: tolerance)
        }
    ) {
        self.clientID = clientID
        self.scopes = scopes
        self.session = session
        self.pollingNow = pollingNow
        self.pollingSleep = pollingSleep
    }
    
    // MARK: - Public Methods
    
    /// Requests a device code from Twitch, initiating Device Code Grant flow.
    ///
    /// RFC 8628 Compliance: Implements Twitch Device Code Grant per RFC 8628.
    /// No client secret is used; suitable for public client applications.
    ///
    /// User Flow:
    /// 1. Call this method to get device code and user code
    /// 2. Display user_code to user and provide verification_uri or verification_uri_complete
    /// 3. User visits URL and enters user_code
    /// 4. Call pollForToken() while waiting for approval
    /// 5. Token is returned when user completes approval
    ///
    /// Response Fields:
    /// - deviceCode: Server-side code; passed to pollForToken()
    /// - userCode: 8-character code shown to user for verification
    /// - verificationURI: URL base for approval (append user_code if needed)
    /// - verificationURIComplete: Complete URL including user_code (preferred)
    /// - expiresIn: Device code validity in seconds (currently 1,800s)
    /// - interval: Recommended polling interval in seconds (usually 5s)
    ///
    /// Network Details:
    /// - 15s timeout for reliability
    /// - Requires internet connectivity; no retry logic
    ///
    /// Thread Safety: Can be called from any thread.
    ///
    /// Error Handling:
    /// - Throws `invalidClient` if the client ID is empty or Twitch answers 401
    /// - Throws `invalidResponse` if the body is malformed, `interval` is not an
    ///   integer, or `expires_in` / `interval` fall outside the local bounds
    /// - Throws `unknown` for any other non-2xx status (body text as message)
    ///   or a transport error
    /// - Throws `CancellationError` when the task is cancelled
    ///
    /// - Returns: Device code response containing codes and polling parameters
    /// - Throws: `TwitchDeviceAuthError` if the request fails
    func requestDeviceCode() async throws -> TwitchDeviceCodeResponse {
        guard !clientID.isEmpty else {
            throw TwitchDeviceAuthError.invalidClient
        }
        
        guard let url = URL(string: AppConstants.API.twitchOAuthDevice) else {
            throw TwitchDeviceAuthError.invalidResponse
        }

        let params: [String: String] = [
            "client_id": clientID,
            "scopes": scopes.joined(separator: " ")
        ]

        let request = makeFormPOST(url: url, params: params)

        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw TwitchDeviceAuthError.invalidResponse
            }

            guard (200..<300).contains(http.statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                
                if http.statusCode == 401 {
                    throw TwitchDeviceAuthError.invalidClient
                }
                throw TwitchDeviceAuthError.unknown(message)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let deviceCode = json["device_code"] as? String,
                let userCode = json["user_code"] as? String,
                let verificationURI = json["verification_uri"] as? String,
                let expiresIn = json["expires_in"] as? Int
            else {
                throw TwitchDeviceAuthError.invalidResponse
            }

            // A missing `interval` gets the RFC default; a present but
            // non-integer one is a malformed response, not a default.
            let interval: Int
            if let rawInterval = json["interval"] {
                guard let parsedInterval = rawInterval as? Int else {
                    throw TwitchDeviceAuthError.invalidResponse
                }
                interval = parsedInterval
            } else {
                interval = Self.defaultPollingInterval
            }
            guard expiresIn > 0,
                  expiresIn <= Self.maximumDeviceCodeLifetime,
                  interval > 0,
                  interval <= Self.maximumPollingInterval else {
                throw TwitchDeviceAuthError.invalidResponse
            }

            let verificationURIComplete = json["verification_uri_complete"] as? String
            return TwitchDeviceCodeResponse(
                deviceCode: deviceCode,
                userCode: userCode,
                verificationURI: verificationURI,
                verificationURIComplete: verificationURIComplete,
                expiresIn: expiresIn,
                interval: interval
            )
        } catch let error as TwitchDeviceAuthError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw TwitchDeviceAuthError.unknown(error.localizedDescription)
        }
    }
    
    /// Polls Twitch for token completion using RFC 8628's bounded retry behavior.
    ///
    /// Polling Strategy:
    /// - Polls at `interval` seconds, respecting Twitch slow_down requests
    /// - Increases interval by 5 seconds when slow_down is received (per Twitch spec)
    /// - Uses a monotonic `expiresIn` deadline that backoff never extends
    /// - Task cancellation is checked each iteration; cancellation is respected immediately
    ///
    /// Progress Callback:
    /// - Called every 10 polling attempts or on first poll
    /// - Called on background thread; dispatch to main if updating UI
    ///
    /// Network Details:
    /// - 15s timeout per request for reliability
    /// - Retries transient transport failures and HTTP 429/5xx responses
    /// - Permanent OAuth failures (`access_denied`, `expired_token`, etc.) stop immediately
    ///
    /// Thread Safety: Can be called from any thread. Cancellation-safe.
    ///
    /// Error Handling:
    /// - Throws `invalidClient` if `deviceCode` is empty
    /// - Throws `expiredToken` at the original deadline or the no-expiry fallback cap
    /// - Throws `accessDenied` if the user rejects authorization
    /// - Throws `invalidResponse` if a success response is malformed or lacks a
    ///   refresh token, or if `interval` / `expiresIn` are out of bounds
    /// - Throws `invalidClient` on HTTP 401 or an `invalid_client` error
    /// - Throws `unknown` for any other OAuth error or a non-transient transport error
    /// - Throws `CancellationError` when the task is cancelled
    ///
    /// - Parameters:
    ///   - deviceCode: The device code from requestDeviceCode()
    ///   - interval: Initial polling interval in seconds (from requestDeviceCode())
    ///   - expiresIn: Device code lifetime in seconds. When omitted, polling
    ///     uses a local ten-minute deadline as a defensive fallback.
    ///   - progress: Called periodically with status messages
    /// - Returns: The complete OAuth grant on successful authorization. The
    ///   caller owns persistence after validating its account/session revision.
    /// - Throws: TwitchDeviceAuthError describing the failure
    func pollForToken(
        deviceCode: String,
        interval: Int,
        expiresIn: Int? = nil,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> TwitchTokenResponse
    {
        guard !deviceCode.isEmpty else {
            throw TwitchDeviceAuthError.invalidClient
        }
        guard interval > 0, interval <= Self.maximumPollingInterval else {
            throw TwitchDeviceAuthError.invalidResponse
        }
        if let expiresIn, expiresIn <= 0 {
            throw TwitchDeviceAuthError.expiredToken
        }
        if let expiresIn, expiresIn > Self.maximumDeviceCodeLifetime {
            throw TwitchDeviceAuthError.invalidResponse
        }

        var currentInterval = interval
        guard let tokenURL = URL(string: AppConstants.API.twitchOAuthToken) else {
            throw TwitchDeviceAuthError.invalidResponse
        }
        let grantType = "urn:ietf:params:oauth:grant-type:device_code"
        var pollAttempts = 0
        let pollingStartedAt = pollingNow()
        let effectiveLifetime = expiresIn ?? Self.fallbackDeviceCodeLifetime
        let expiryDeadline = pollingStartedAt.advanced(by: .seconds(effectiveLifetime))

        while true {
            try Task.checkCancellation()
            if pollingNow() >= expiryDeadline {
                Log.error(
                    "TwitchDeviceAuth: Device code expired before the next poll",
                    category: .twitchAuth)
                throw TwitchDeviceAuthError.expiredToken
            }

            pollAttempts += 1

            if pollAttempts % 10 == 0 {
                // Update UI every 10 polls
                progress("Still waiting on Twitch. Check your browser tab.")
            } else if pollAttempts == 1 {
                progress("Waiting for you to approve on Twitch\u{2026}")
            }

            let params: [String: String] = [
                "client_id": clientID,
                "grant_type": grantType,
                "device_code": deviceCode,
                "scopes": scopes.joined(separator: " ")
            ]

            var request = makeFormPOST(url: tokenURL, params: params)
            // Never let a single request outlive the device code: shrink the
            // 15s timeout to whatever time is left before the deadline.
            let remaining = pollingNow().duration(to: expiryDeadline)
            let remainingSeconds = Self.seconds(in: remaining)
            guard remainingSeconds > 0 else {
                throw TwitchDeviceAuthError.expiredToken
            }
            request.timeoutInterval = min(request.timeoutInterval, remainingSeconds)

            // One-shot server-directed delay (Retry-After on a 5xx). Unlike
            // `currentInterval` it does not carry over to later polls.
            var nextDelayOverride: Int?
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                if pollingNow() >= expiryDeadline {
                    throw TwitchDeviceAuthError.expiredToken
                }
                guard let http = response as? HTTPURLResponse else {
                    throw TwitchDeviceAuthError.invalidResponse
                }

                if (200..<300).contains(http.statusCode) {
                    guard let parsed = TwitchDeviceAuth.parseRotatingTokenResponse(data) else {
                        Log.error(
                            "TwitchDeviceAuth: Failed to parse access token from response", category: .twitchAuth)
                        throw TwitchDeviceAuthError.invalidResponse
                    }
                    Log.info("TwitchDeviceAuth: Device code token obtained successfully", category: .twitchAuth)
                    return parsed
                }

                switch Self.pollFailureDisposition(
                    data: data,
                    statusCode: http.statusCode,
                    retryAfter: http.value(forHTTPHeaderField: "Retry-After")
                ) {
                case .retry(let retryAfter):
                    nextDelayOverride = retryAfter
                    Log.debug(
                        "TwitchDeviceAuth: Authorization pending or service temporarily unavailable",
                        category: .twitchAuth)
                case .slowDown:
                    currentInterval = try Self.increasedPollingInterval(currentInterval)
                    Log.info(
                        "TwitchDeviceAuth: Received slow_down; increasing poll interval to \(currentInterval)s",
                        category: .twitchAuth)
                case .rateLimited(let retryAfter):
                    currentInterval = try Self.rateLimitBackoffInterval(
                        currentInterval,
                        retryAfter: retryAfter
                    )
                    Log.info(
                        "TwitchDeviceAuth: Rate limited; increasing poll interval to \(currentInterval)s",
                        category: .twitchAuth)
                case .terminal(let error):
                    Log.error(
                        "TwitchDeviceAuth: Terminal device-code error - \(error.localizedDescription)",
                        category: .twitchAuth)
                    throw error
                }
            } catch let error as TwitchDeviceAuthError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                guard Self.isTransientTransportError(error) else {
                    throw TwitchDeviceAuthError.unknown(error.localizedDescription)
                }
                // Only a timeout doubles the cadence; other transient errors
                // retry at the current interval.
                if (error as? URLError)?.code == .timedOut {
                    currentInterval = try Self.timeoutBackoffInterval(currentInterval)
                }
                Log.warn(
                    "TwitchDeviceAuth: Transient polling failure; retrying - \(error.localizedDescription)",
                    category: .twitchAuth)
            }

            try await sleepBeforeNextPoll(
                seconds: max(currentInterval, nextDelayOverride ?? 0),
                expiryDeadline: expiryDeadline)
        }
    }

    // MARK: - Polling Helpers

    /// What `pollForToken` does after a non-2xx token response. Retry-After
    /// values are already bounded by `RetryAfter.seconds` (300 s cap) and
    /// rounded up to whole seconds.
    private enum PollFailureDisposition {
        /// Poll again at the current interval or a one-shot server delay.
        case retry(retryAfter: Int?)

        /// Poll again after permanently increasing the interval by five seconds.
        case slowDown

        /// HTTP 429; respect Retry-After and never poll faster than a five-second
        /// increase over the prior cadence.
        case rateLimited(retryAfter: Int?)

        /// Stop polling and surface the OAuth failure.
        case terminal(TwitchDeviceAuthError)
    }

    /// Classifies every non-success token response. Only the two RFC 8628
    /// polling signals plus HTTP 429/5xx continue; every other OAuth response
    /// is terminal.
    ///
    /// Twitch's device-flow errors arrive as `{"status":400,"message":"..."}`
    /// rather than RFC 6749's `error` field, so the code is read from either
    /// key and matched case-insensitively. `"invalid device code"` (with
    /// spaces) is Twitch's own wording for an expired or used code.
    nonisolated private static func pollFailureDisposition(
        data: Data,
        statusCode: Int,
        retryAfter: String?
    ) -> PollFailureDisposition {
        let boundedRetry = RetryAfter.seconds(retryAfter).map {
            Int($0.rounded(.up))
        }
        if statusCode == 429 {
            return .rateLimited(retryAfter: boundedRetry)
        }
        if (500..<600).contains(statusCode) {
            return .retry(retryAfter: boundedRetry)
        }
        if statusCode == 401 {
            return .terminal(.invalidClient)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawCode = (json["error"] as? String) ?? (json["message"] as? String) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            let detail = responseBody.isEmpty
                ? "HTTP \(statusCode)"
                : String(responseBody.prefix(200))
            return .terminal(.unknown(detail))
        }

        let code = rawCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let message = (json["error_description"] as? String)
            ?? (json["message"] as? String)
            ?? rawCode

        switch code {
        case "authorization_pending":
            return .retry(retryAfter: nil)
        case "slow_down":
            return .slowDown
        case "access_denied":
            return .terminal(.accessDenied)
        case "expired_token", "invalid_grant", "invalid_device_code", "invalid device code":
            return .terminal(.expiredToken)
        case "invalid_client":
            return .terminal(.invalidClient)
        default:
            return .terminal(.unknown(message))
        }
    }

    /// Adds the RFC 8628 five-second `slow_down` increment, saturating at the
    /// local safety ceiling instead of constructing an unbounded sleep.
    nonisolated private static func increasedPollingInterval(_ interval: Int) throws -> Int {
        guard interval > 0, interval <= maximumPollingInterval else {
            throw TwitchDeviceAuthError.invalidResponse
        }
        return min(interval + 5, maximumPollingInterval)
    }

    /// Doubles the interval after a connection timeout, capped at the local
    /// safety ceiling used for exponential network backoff.
    nonisolated private static func timeoutBackoffInterval(_ interval: Int) throws -> Int {
        guard interval > 0, interval <= maximumPollingInterval else {
            throw TwitchDeviceAuthError.invalidResponse
        }
        return min(interval * 2, maximumPollingInterval)
    }

    /// New cadence after HTTP 429: the `slow_down` increase, or the server's
    /// Retry-After when that is longer. Unlike a 5xx Retry-After, this one
    /// becomes the ongoing interval.
    nonisolated private static func rateLimitBackoffInterval(
        _ interval: Int,
        retryAfter: Int?
    ) throws -> Int {
        let increased = try increasedPollingInterval(interval)
        guard let retryAfter, retryAfter > 0 else { return increased }
        return max(increased, retryAfter)
    }

    /// Converts a `Duration` to fractional seconds for `URLRequest.timeoutInterval`.
    nonisolated private static func seconds(in duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    /// Returns whether a URL loading failure can reasonably recover without
    /// user action. Cancellation is deliberately excluded.
    nonisolated private static func isTransientTransportError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet,
             .resourceUnavailable,
             .backgroundSessionWasDisconnected:
            return true
        default:
            return false
        }
    }

    /// Sleeps until the next poll without ever extending the deadline captured
    /// when polling began. The injected operation keeps multi-attempt tests
    /// deterministic and the production clock sleep throws on cancellation.
    ///
    /// A delay that would cross the deadline is shortened to end exactly at it
    /// (with no tolerance), so the post-sleep check throws `expiredToken`
    /// on time instead of after a full interval.
    ///
    /// - Parameter seconds: Requested delay; must be in `1...maximumPollingInterval`.
    /// - Throws: `invalidResponse` for an out-of-range delay, `expiredToken`
    ///   when the deadline has passed, or `CancellationError`.
    private func sleepBeforeNextPoll(
        seconds: Int,
        expiryDeadline: ContinuousClock.Instant
    ) async throws {
        try Task.checkCancellation()
        guard seconds > 0, seconds <= Self.maximumPollingInterval else {
            throw TwitchDeviceAuthError.invalidResponse
        }

        let currentTime = pollingNow()
        let requestedDelay: Duration = .seconds(seconds)
        var delay = requestedDelay
        var tolerance: Duration? = .seconds(Double(seconds) * 0.1)

        guard currentTime < expiryDeadline else {
            throw TwitchDeviceAuthError.expiredToken
        }
        if currentTime.advanced(by: requestedDelay) >= expiryDeadline {
            delay = currentTime.duration(to: expiryDeadline)
            tolerance = nil
        }

        try await pollingSleep(delay, tolerance)
        try Task.checkCancellation()

        if pollingNow() >= expiryDeadline {
            throw TwitchDeviceAuthError.expiredToken
        }
    }

    // MARK: - Refresh Token Grant

    /// Exchanges a refresh token for a fresh access token via
    /// `grant_type=refresh_token`. Used for one reactive refresh before falling
    /// back to interactive re-auth. Performs a single request; never loops
    /// (`TwitchTokenRefresher.performRefresh` owns the retry policy). Does not
    /// persist anything.
    ///
    /// - Parameter refreshToken: The stored OAuth refresh token.
    /// - Returns: A parsed access/rotated-refresh token pair.
    /// - Throws: `invalidClient` for an empty client ID or HTTP 400/401 (the
    ///   refresh token is dead); `http(status:retryAfter:)` for any other
    ///   non-2xx; `invalidResponse` for an empty refresh token or a body without
    ///   a rotated refresh token; `transport` for network failures;
    ///   `CancellationError` when cancelled.
    func refreshAccessToken(refreshToken: String) async throws -> TwitchTokenResponse {
        guard !clientID.isEmpty else { throw TwitchDeviceAuthError.invalidClient }
        guard !refreshToken.isEmpty else { throw TwitchDeviceAuthError.invalidResponse }
        guard let tokenURL = URL(string: AppConstants.API.twitchOAuthToken) else {
            throw TwitchDeviceAuthError.invalidResponse
        }

        let params: [String: String] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        let request = makeFormPOST(url: tokenURL, params: params)

        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw TwitchDeviceAuthError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 401 || http.statusCode == 400 {
                    // Refresh token is invalid/expired: caller falls back to re-auth.
                    throw TwitchDeviceAuthError.invalidClient
                }
                throw TwitchDeviceAuthError.http(
                    status: http.statusCode,
                    retryAfter: RetryAfter.duration(
                        http.value(forHTTPHeaderField: "Retry-After")))
            }
            guard let parsed = TwitchDeviceAuth.parseRotatingTokenResponse(data) else {
                throw TwitchDeviceAuthError.invalidResponse
            }
            return parsed
        } catch let error as TwitchDeviceAuthError {
            throw error
        } catch {
            if error is CancellationError
                || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let urlError = error as? URLError {
                throw TwitchDeviceAuthError.transport(urlError.localizedDescription)
            }
            throw TwitchDeviceAuthError.transport(error.localizedDescription)
        }
    }

    // MARK: - Private Helpers

    /// Builds a form-URL-encoded POST with the shared user-agent and the standard
    /// 15s auth timeout. Centralizes the request scaffolding repeated by the three
    /// OAuth calls (device-code request, token poll, refresh).
    private func makeFormPOST(url: URL, params: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(HTTPClient.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = HTTPClient.formURLEncodedBody(params)
        request.timeoutInterval = 15
        return request
    }
}
