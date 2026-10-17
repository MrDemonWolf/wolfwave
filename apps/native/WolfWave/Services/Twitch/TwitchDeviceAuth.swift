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

// MARK: - Credential Grant Store

/// Serializes whole OAuth-grant commits behind a monotonically increasing
/// account revision. A cancelled/superseded device flow can still receive a
/// network response, but it cannot persist either half of its credential pair.
///
/// Concurrency: `@unchecked Sendable` is backed by `lock`, which guards the
/// in-memory `revision` and is held across every Keychain read/write below, so
/// a revision check and the write it authorizes happen as one step. The
/// revision is process-local and starts at 0 on launch; it is never persisted.
/// Methods block on the lock and the Keychain, so call them off the main
/// thread where possible.
nonisolated final class TwitchCredentialStore: @unchecked Sendable {
    /// Exact access credential that owns an async operation. The revision
    /// distinguishes account lifecycles even if a provider ever reissues the
    /// same token string.
    struct AccessExpectation: Sendable, Equatable {
        let revision: UInt64
        let accessToken: String

        /// Same revision, new token. Used to check ownership of a refresh
        /// result, which rotates the token without advancing the revision.
        func replacingAccessToken(_ replacement: String) -> AccessExpectation {
            AccessExpectation(revision: revision, accessToken: replacement)
        }
    }

    /// One atomic connection snapshot. Identity is optional while a freshly
    /// committed device/manual grant is still waiting for its `/users` lookup.
    struct ConnectionSnapshot: Sendable, Equatable {
        let revision: UInt64
        let accessToken: String
        let username: String?
        let userID: String?
        /// The configured channel (a login name, despite the field name).
        let channelID: String?

        /// The ownership token async work carries across an `await`.
        var accessExpectation: AccessExpectation {
            AccessExpectation(revision: revision, accessToken: accessToken)
        }
    }

    /// The refresh token captured together with the access credential it
    /// belongs to, so a refresh can only be committed back onto that account.
    struct RefreshSnapshot: Sendable {
        let expectation: AccessExpectation
        let refreshToken: String
    }

    /// Result of `refreshSnapshot(matching:)`.
    enum RefreshSnapshotMatch: Sendable {
        /// The expectation still owns the record and it has a refresh token.
        case available(RefreshSnapshot)
        /// The expectation owns the record but there is no refresh token, so
        /// the only way forward is interactive re-auth.
        case missingRefreshToken
        /// The Keychain read threw. Treated as temporary, never as a logout.
        case unavailable
        /// The revision or access token changed since the expectation was taken.
        case superseded
    }

    /// Token plus resolved user ID, for work that needs both (Helix calls
    /// keyed on the broadcaster ID). Only produced once identity is resolved.
    struct AccessSnapshot: Sendable {
        let revision: UInt64
        let accessToken: String
        let userID: String

        /// The ownership token async work carries across an `await`.
        var accessExpectation: AccessExpectation {
            AccessExpectation(revision: revision, accessToken: accessToken)
        }
    }

    /// The process-wide store. Every credential writer must go through this
    /// instance; a second instance would have its own revision counter.
    static let shared = TwitchCredentialStore()

    /// Guards `revision` and serializes every Keychain access in this type.
    private let lock = NSLock()

    /// Account lifecycle counter. Advanced (wrapping) by `supersede()`,
    /// `clearCredentials`, and any channel change, which invalidates every
    /// `AccessExpectation` captured before it.
    private var revision: UInt64 = 0

    /// Invalidates every previously captured credential revision and returns
    /// the revision owned by the caller's new account operation. Call it when a
    /// sign-in starts so an older, still-polling device flow can no longer
    /// commit; pass the returned value to `commitDeviceGrant(_:channelID:expectedRevision:)`.
    /// Does not touch the Keychain.
    @discardableResult
    func supersede() -> UInt64 {
        lock.withLock {
            revision &+= 1
            return revision
        }
    }

    /// Captures the account revision only when `accessToken` is still the token
    /// stored for that account. This closes the old-token/new-revision TOCTOU.
    func revision(matchingAccessToken accessToken: String) -> UInt64? {
        connectionSnapshot(matchingAccessToken: accessToken)?.revision
    }

    /// Atomically captures token, revision, and optional identity. Passing an
    /// expected token makes a stale caller fail instead of adopting fields from
    /// a replacement account.
    ///
    /// - Parameter expectedAccessToken: When non-nil, the snapshot is returned
    ///   only if the stored token equals it.
    /// - Returns: `nil` when there is no non-empty access token, the token does
    ///   not match, or the Keychain read throws.
    func connectionSnapshot(
        matchingAccessToken expectedAccessToken: String? = nil
    ) -> ConnectionSnapshot? {
        lock.withLock {
            guard let grant = try? KeychainService.loadTwitchCredentialGrantChecked(),
                  let accessToken = grant.accessToken,
                  !accessToken.isEmpty,
                  expectedAccessToken == nil || accessToken == expectedAccessToken else {
                return nil
            }
            return ConnectionSnapshot(
                revision: revision,
                accessToken: accessToken,
                username: grant.username,
                userID: grant.userID,
                channelID: grant.channelID
            )
        }
    }

    /// Synchronous ownership check for results returning from an await.
    /// Returns `false` when the Keychain read throws, so an unreadable record
    /// is treated as "not ours" rather than authorizing a mutation.
    func matches(_ expectation: AccessExpectation) -> Bool {
        lock.withLock {
            guard let grant = try? KeychainService.loadTwitchCredentialGrantChecked() else {
                return false
            }
            return revision == expectation.revision
                && grant.accessToken == expectation.accessToken
        }
    }

    /// Captures the access token and resolved account identity under the same
    /// revision lock used by account replacement and logout. Returns `nil`
    /// until the `/users` lookup has stored a non-empty user ID.
    func accessSnapshot() -> AccessSnapshot? {
        lock.withLock {
            guard let grant = try? KeychainService.loadTwitchCredentialGrantChecked(),
                  let accessToken = grant.accessToken,
                  !accessToken.isEmpty,
                  let userID = grant.userID,
                  !userID.isEmpty else { return nil }
            return AccessSnapshot(
                revision: revision,
                accessToken: accessToken,
                userID: userID
            )
        }
    }

    /// Atomically validates ownership and persists a device-flow grant. Access,
    /// refresh, cleared identity, and the existing configured channel share one
    /// Keychain item, so replacement can never cross-pair account configuration.
    ///
    /// Does not advance the revision: the caller already did that with
    /// `supersede()` when the flow started.
    ///
    /// - Parameters:
    ///   - response: The token response from `pollForToken`.
    ///   - channelID: Channel name to store. `nil` keeps the current one.
    ///   - expectedRevision: The value `supersede()` returned for this flow.
    /// - Returns: `false` (nothing written) when the revision moved on or the
    ///   response has no refresh token.
    /// - Throws: Keychain write or validation errors.
    func commitDeviceGrant(
        _ response: TwitchTokenResponse,
        channelID: String? = nil,
        expectedRevision: UInt64
    ) throws -> Bool {
        try lock.withLock {
            guard revision == expectedRevision,
                  let refreshToken = response.refreshToken,
                  !refreshToken.isEmpty else { return false }
            // A new device grant may belong to a different Twitch account.
            // Identity stays nil until the revision-checked /users lookup.
            return try KeychainService.mutateTwitchCredentialGrant { current in
                current = .init(
                    accessToken: response.accessToken,
                    refreshToken: refreshToken,
                    channelID: channelID ?? current.channelID
                )
                return true
            }
        }
    }

    /// Captures the refresh token and account revision under the same lock used
    /// by clear/replace/commit operations. A stale expectation is distinguished
    /// from a current account that simply has no refresh grant, so callers never
    /// refresh or expire the replacement account in response to an old 401.
    func refreshSnapshot(
        matching expectation: AccessExpectation
    ) -> RefreshSnapshotMatch {
        lock.withLock {
            guard let grant = try? KeychainService.loadTwitchCredentialGrantChecked() else {
                return .unavailable
            }
            guard revision == expectation.revision,
                  grant.accessToken == expectation.accessToken else {
                return .superseded
            }
            guard let refreshToken = grant.refreshToken,
                  !refreshToken.isEmpty else { return .missingRefreshToken }
            return .available(
                RefreshSnapshot(
                    expectation: expectation,
                    refreshToken: refreshToken
                )
            )
        }
    }

    /// Commits a rotated refresh grant only if neither the account revision nor
    /// the exact source refresh token changed while the request was in flight.
    /// Identity and channel are kept, and the revision is not advanced, so
    /// in-flight work for the same account stays valid after a refresh.
    ///
    /// - Returns: `false` when ownership changed or the response has no
    ///   refresh token; nothing is written in that case.
    /// - Throws: Keychain write or validation errors.
    func commitRefreshGrant(
        _ response: TwitchTokenResponse,
        replacing sourceRefreshToken: String,
        expected expectation: AccessExpectation
    ) throws -> Bool {
        try lock.withLock {
            guard revision == expectation.revision,
                  let newRefreshToken = response.refreshToken,
                  !newRefreshToken.isEmpty else { return false }

            return try KeychainService.mutateTwitchCredentialGrant { current in
                guard current.accessToken == expectation.accessToken,
                      current.refreshToken == sourceRefreshToken else {
                    return false
                }
                current.accessToken = response.accessToken
                current.refreshToken = newRefreshToken
                return true
            }
        }
    }

    /// Changes only the configured channel and advances the account revision
    /// after the canonical write commits. In-flight connect/reconnect work tied
    /// to the old channel therefore fails its existing revision checks.
    /// Unconditional (no ownership check); a no-op write leaves the revision
    /// alone.
    func updateChannelID(_ channelID: String?) throws {
        try lock.withLock {
            let changed = try KeychainService.mutateTwitchCredentialGrant { grant in
                guard grant.channelID != channelID else { return false }
                grant.channelID = channelID
                return true
            }
            if changed {
                revision &+= 1
            }
        }
    }

    /// Commits a channel only if the validated access credential and account
    /// revision still own the canonical record. Returns the exact post-commit
    /// snapshot so the caller never reconnects from pre-commit fields.
    ///
    /// - Returns: The post-commit snapshot (carrying the new revision when the
    ///   channel actually changed), or `nil` when `expected` no longer owns the
    ///   record (revision, access token, or prior channel differ).
    /// - Throws: Keychain write or validation errors.
    func commitChannelID(
        _ channelID: String,
        expected: ConnectionSnapshot
    ) throws -> ConnectionSnapshot? {
        try lock.withLock {
            guard revision == expected.revision else { return nil }
            // The mutation returns `false` both for "not ours" and for "already
            // this channel"; `matched` tells the two apart so an unchanged
            // channel still yields a snapshot.
            var matched = false
            var committedGrant: KeychainService.TwitchCredentialGrant?
            let changed = try KeychainService.mutateTwitchCredentialGrant { grant in
                guard grant.accessToken == expected.accessToken,
                      grant.channelID == expected.channelID else {
                    return false
                }
                matched = true
                guard grant.channelID != channelID else {
                    committedGrant = grant
                    return false
                }
                grant.channelID = channelID
                committedGrant = grant
                return true
            }
            guard matched,
                  let committedGrant,
                  let accessToken = committedGrant.accessToken else { return nil }
            if changed {
                revision &+= 1
            }
            return ConnectionSnapshot(
                revision: revision,
                accessToken: accessToken,
                username: committedGrant.username,
                userID: committedGrant.userID,
                channelID: committedGrant.channelID
            )
        }
    }

    /// Clears Twitch account secrets while atomically invalidating every
    /// captured OAuth/refresh revision. The optional channel name is account
    /// configuration rather than a secret and is retained for re-auth flows.
    ///
    /// - Parameter includingChannel: `true` deletes the whole record (sign out
    ///   and forget the channel); `false` keeps only the channel name.
    /// - Throws: Keychain errors. The revision advances only after the write
    ///   succeeds, so a failed clear leaves existing expectations valid.
    func clearCredentials(includingChannel: Bool) throws {
        try lock.withLock {
            if includingChannel {
                // Legacy items are deleted before the authoritative v2 record,
                // so every failed clear keeps the complete account retryable.
                try KeychainService.deleteTwitchCredentialGrant()
            } else {
                // Preserve reauthentication UX without preserving any secret or
                // resolved identity: channel-only is one atomic replacement.
                try KeychainService.mutateTwitchCredentialGrant { current in
                    current = .init(channelID: current.channelID)
                    return true
                }
            }
            revision &+= 1
        }
    }

    /// Persists resolved account identity only while the same OAuth revision
    /// still owns the credential set. Does not advance the revision.
    ///
    /// - Returns: `false` when the revision moved on or the stored access token
    ///   is no longer `accessToken`; nothing is written in that case.
    /// - Throws: Keychain write or validation errors.
    func commitIdentity(
        username: String,
        userID: String,
        matchingAccessToken accessToken: String,
        expectedRevision: UInt64
    ) throws -> Bool {
        try lock.withLock {
            guard revision == expectedRevision else { return false }
            return try KeychainService.mutateTwitchCredentialGrant { grant in
                guard grant.accessToken == accessToken else { return false }
                grant.username = username
                grant.userID = userID
                return true
            }
        }
    }
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

    // MARK: - Token Parsing (nonisolated, pure, testable)

    /// Parses a Twitch OAuth token response body into a `TwitchTokenResponse`.
    ///
    /// Returns `nil` when the body is not a JSON object or lacks a non-empty
    /// `access_token`. `refresh_token` and `expires_in` are optional.
    nonisolated static func parseTokenResponse(_ data: Data) -> TwitchTokenResponse? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty else {
            return nil
        }
        let refreshToken = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let expiresIn = json["expires_in"] as? Int
        return TwitchTokenResponse(
            accessToken: accessToken, refreshToken: refreshToken, expiresIn: expiresIn)
    }

    /// Device-code and refresh grants are durable only when Twitch rotates a
    /// non-empty refresh token alongside the access token. Keeping this guard
    /// separate preserves the generic parser for diagnostics while preventing
    /// access-only 2xx responses from becoming a four-hour false success.
    nonisolated static func parseRotatingTokenResponse(_ data: Data) -> TwitchTokenResponse? {
        guard let response = parseTokenResponse(data), response.refreshToken != nil else {
            return nil
        }
        return response
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

// MARK: - Reactive Token Refresh

/// Coordinates one reactive OAuth token refresh from the live Twitch service.
///
/// On a 401, `TwitchChatService` (live connection) and the boot token
/// validation in `AppDelegate+Services` call `attemptReactiveRefresh` once per
/// failure (never in a loop). It reads the stored refresh token, exchanges it
/// for a fresh access token, persists both, and returns a typed outcome so
/// temporary outages never erase a valid local grant.
///
/// Concurrency: the actor single-flights refreshes. Concurrent callers for the
/// same `RefreshKey` join one task; a caller for a different key cancels the
/// old one first. Twitch refresh tokens rotate, so two parallel exchanges of
/// the same token would leave one caller holding a dead token.
actor TwitchTokenRefresher {

    /// The process-wide refresher. Single-flighting only works through it.
    static let shared = TwitchTokenRefresher()

    /// Outcome of one refresh attempt, already checked against the current
    /// account owner (see `normalized(_:for:)`).
    enum RefreshResult: Sendable, Equatable {
        /// Rotated grant committed; carries the new access token.
        case refreshed(String)
        /// Refresh token missing or rejected, or a non-retryable status:
        /// the caller should ask the user to sign in again.
        case invalid
        /// Keychain unreadable, retries exhausted, or the commit kept failing.
        /// The stored grant is left as is; try again later.
        case temporarilyUnavailable
        /// The access token or account revision changed before this result could
        /// authorize a refresh or any caller-side mutation.
        case superseded
    }

    /// Identifies one refresh: same app, same account lifecycle, same token
    /// pair. Two callers with equal keys share a single network exchange.
    private struct RefreshKey: Sendable, Equatable {
        let clientID: String
        let credentialRevision: UInt64
        let accessToken: String
        let sourceRefreshToken: String
    }

    /// The refresh currently running. `id` lets the starter clear only its
    /// own entry, never one a later caller installed.
    private struct InFlight: Sendable {
        let id: UUID
        let key: RefreshKey
        let task: Task<RefreshResult, Error>
    }

    /// At most one refresh runs at a time.
    private var inFlight: InFlight?

    /// A rotated grant Twitch already issued but the Keychain commit failed
    /// for. The old refresh token is likely spent server-side, so a retry for
    /// the same key re-commits this response instead of calling Twitch again.
    private struct PendingRotation: Sendable {
        let key: RefreshKey
        let response: TwitchTokenResponse
        let generation: UInt64
    }

    /// See `PendingRotation`. Cleared on a successful commit, a supersede, or
    /// `invalidate()`.
    private var pendingRotation: PendingRotation?

    /// Bumped by `invalidate()` and when a different key replaces an in-flight
    /// refresh. `persist` refuses to commit work started under an older value.
    private var refreshGeneration: UInt64 = 0

    /// Supersedes and cancels a refresh owned by a prior account session.
    static func invalidateSession() async {
        await shared.invalidate()
    }

    /// Advances the generation, cancels any in-flight refresh, and drops a
    /// held rotation so nothing from the old session can commit.
    private func invalidate() {
        refreshGeneration &+= 1
        inFlight?.task.cancel()
        inFlight = nil
        pendingRotation = nil
    }

    /// Attempts one credential-bound refresh. A stale expectation returns
    /// superseded before issuing network work. Production entry point; uses
    /// `URLSession.shared` and the default retry policy.
    ///
    /// - Parameters:
    ///   - clientID: Twitch app client ID. Empty yields `.invalid`.
    ///   - expected: The credential that was rejected with a 401.
    /// - Throws: `CancellationError` only when the calling task is cancelled.
    static func attemptReactiveRefresh(
        clientID: String,
        expected: TwitchCredentialStore.AccessExpectation
    ) async throws -> RefreshResult {
        try await shared.refresh(
            clientID: clientID,
            expected: expected,
            session: .shared
        )
    }

    /// Injectable convenience used by tests that begin from current storage.
    /// Takes the expectation from whatever is stored now; returns `.invalid`
    /// when there is no stored access token.
    ///
    /// - Parameters:
    ///   - maxTransientAttempts: Network attempts before `.temporarilyUnavailable` (min 1).
    ///   - sleep: Delay between attempts; tests pass a no-op.
    ///   - onJoinedExistingFlight: Called when this call joins an in-flight
    ///     refresh instead of starting one; lets tests prove single-flighting.
    static func attemptReactiveRefresh(
        clientID: String,
        session: URLSession,
        maxTransientAttempts: Int = 3,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        onJoinedExistingFlight: @escaping @Sendable () -> Void = {}
    ) async throws -> RefreshResult {
        guard let expected = TwitchCredentialStore.shared
            .connectionSnapshot()?.accessExpectation else {
            return .invalid
        }
        return try await attemptReactiveRefresh(
            clientID: clientID,
            expected: expected,
            session: session,
            maxTransientAttempts: maxTransientAttempts,
            sleep: sleep,
            onJoinedExistingFlight: onJoinedExistingFlight
        )
    }

    /// Injectable credential-bound variant used by race and single-flight tests.
    /// Parameters match the storage-based overload above.
    static func attemptReactiveRefresh(
        clientID: String,
        expected: TwitchCredentialStore.AccessExpectation,
        session: URLSession,
        maxTransientAttempts: Int = 3,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        onJoinedExistingFlight: @escaping @Sendable () -> Void = {}
    ) async throws -> RefreshResult {
        try await shared.refresh(
            clientID: clientID,
            expected: expected,
            session: session,
            maxTransientAttempts: maxTransientAttempts,
            sleep: sleep,
            onJoinedExistingFlight: onJoinedExistingFlight
        )
    }

    /// Single-flight core shared by every public entry point.
    ///
    /// 1. Re-reads the refresh token under the store lock; a stale `expected`
    ///    returns `.superseded` with no network call.
    /// 2. Joins an in-flight refresh with the same key, or cancels one with a
    ///    different key (bumping the generation) and recurses.
    /// 3. Otherwise starts a task that either re-commits a held
    ///    `PendingRotation` for this key or performs the network refresh.
    ///
    /// A cancelled refresh task maps to `.temporarilyUnavailable` (or
    /// `.superseded` if the account changed); `CancellationError` is thrown
    /// only when the caller's own task was cancelled.
    private func refresh(
        clientID: String,
        expected: TwitchCredentialStore.AccessExpectation,
        session: URLSession,
        maxTransientAttempts: Int = 3,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        onJoinedExistingFlight: @escaping @Sendable () -> Void = {}
    ) async throws -> RefreshResult {
        try Task.checkCancellation()
        let credentialSnapshot: TwitchCredentialStore.RefreshSnapshot
        switch TwitchCredentialStore.shared.refreshSnapshot(matching: expected) {
        case .available(let snapshot):
            credentialSnapshot = snapshot
        case .missingRefreshToken:
            Log.info(
                "TwitchTokenRefresher: No stored refresh token; cannot refresh",
                category: .twitchAuth)
            return .invalid
        case .unavailable:
            return .temporarilyUnavailable
        case .superseded:
            return .superseded
        }
        guard !clientID.isEmpty else { return .invalid }

        let sourceRefreshToken = credentialSnapshot.refreshToken
        let key = RefreshKey(
            clientID: clientID,
            credentialRevision: expected.revision,
            accessToken: expected.accessToken,
            sourceRefreshToken: sourceRefreshToken
        )

        if let existing = inFlight {
            if existing.key == key {
                onJoinedExistingFlight()
                do {
                    let result = try await existing.task.value
                    try Task.checkCancellation()
                    return normalized(result, for: expected)
                } catch is CancellationError {
                    if Task.isCancelled { throw CancellationError() }
                    return TwitchCredentialStore.shared.matches(expected)
                        ? .temporarilyUnavailable
                        : .superseded
                }
            }

            // The stored credentials changed while another account's refresh
            // was active. Supersede it before starting work for the new key;
            // its generation/CAS persistence guards make a late response inert.
            refreshGeneration &+= 1
            inFlight = nil
            existing.task.cancel()
            _ = try? await existing.task.value
            return try await refresh(
                clientID: clientID,
                expected: expected,
                session: session,
                maxTransientAttempts: maxTransientAttempts,
                sleep: sleep,
                onJoinedExistingFlight: onJoinedExistingFlight
            )
        }

        let generation = refreshGeneration
        let id = UUID()
        let held = pendingRotation
        let task = Task<RefreshResult, Error> {
            if let held, held.key == key, held.generation == generation {
                return try await self.persist(
                    held.response,
                    replacing: sourceRefreshToken,
                    expected: expected,
                    generation: generation,
                    clientID: clientID,
                    sleep: sleep)
            }
            return try await Self.performRefresh(
                clientID: clientID,
                sourceRefreshToken: sourceRefreshToken,
                expected: expected,
                session: session,
                maxTransientAttempts: maxTransientAttempts,
                sleep: sleep,
                generation: generation
            )
        }
        inFlight = InFlight(id: id, key: key, task: task)
        let result: RefreshResult
        do {
            result = try await task.value
        } catch is CancellationError {
            if inFlight?.id == id {
                inFlight = nil
            }
            if Task.isCancelled { throw CancellationError() }
            return TwitchCredentialStore.shared.matches(expected)
                ? .temporarilyUnavailable
                : .superseded
        } catch {
            if inFlight?.id == id {
                inFlight = nil
            }
            throw error
        }
        if inFlight?.id == id {
            inFlight = nil
        }
        try Task.checkCancellation()
        return normalized(result, for: expected)
    }

    /// Converts every late terminal result into superseded unless the exact
    /// account still owns it. Successful refreshes validate the rotated token;
    /// all other results validate the rejected token.
    private func normalized(
        _ result: RefreshResult,
        for expected: TwitchCredentialStore.AccessExpectation
    ) -> RefreshResult {
        switch result {
        case .refreshed(let replacement):
            return TwitchCredentialStore.shared.matches(
                expected.replacingAccessToken(replacement)
            ) ? result : .superseded
        case .invalid, .temporarilyUnavailable:
            return TwitchCredentialStore.shared.matches(expected)
                ? result
                : .superseded
        case .superseded:
            return .superseded
        }
    }

    /// Runs the network exchange with bounded retries, then hands a success to
    /// `persist`. Runs off the actor so the actor stays free for joiners.
    ///
    /// Retry policy: `invalidClient` and non-retryable HTTP statuses return
    /// `.invalid` at once. Malformed bodies, transport errors, and retryable
    /// statuses retry with exponential backoff (250 ms, 500 ms, ...), or the
    /// server's Retry-After when longer. Ownership is rechecked before every
    /// attempt and after every failure.
    private nonisolated static func performRefresh(
        clientID: String,
        sourceRefreshToken: String,
        expected: TwitchCredentialStore.AccessExpectation,
        session: URLSession,
        maxTransientAttempts: Int,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        generation: UInt64
    ) async throws -> RefreshResult {
        // Mirror the sign-in scope set so a refreshed token keeps the full grant
        // (chat + redemptions + bits + polls), never silently narrowing to chat.
        let auth = TwitchDeviceAuth(
            clientID: clientID,
            scopes: AppConstants.Twitch.allScopes,
            session: session
        )
        let attempts = max(1, maxTransientAttempts)
        for attempt in 1...attempts {
            try Task.checkCancellation()
            guard TwitchCredentialStore.shared.matches(expected) else {
                return .superseded
            }

            let retryDelay: Duration?
            do {
                let response = try await auth.refreshAccessToken(
                    refreshToken: sourceRefreshToken
                )
                return try await shared.persist(
                    response,
                    replacing: sourceRefreshToken,
                    expected: expected,
                    generation: generation,
                    clientID: clientID,
                    sleep: sleep
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch TwitchDeviceAuthError.invalidClient {
                return .invalid
            } catch TwitchDeviceAuthError.invalidResponse {
                retryDelay = nil
            } catch TwitchDeviceAuthError.http(let status, let retryAfter) {
                guard Self.isRetryableRefreshStatus(status) else { return .invalid }
                retryDelay = retryAfter
            } catch TwitchDeviceAuthError.transport(_) {
                retryDelay = nil
            } catch {
                retryDelay = nil
            }

            guard TwitchCredentialStore.shared.matches(expected) else {
                return .superseded
            }
            guard attempt < attempts else {
                Log.warn(
                    "TwitchTokenRefresher: Refresh temporarily unavailable after \(attempts) attempts",
                    category: .twitchAuth)
                return .temporarilyUnavailable
            }
            let fallback = Duration.milliseconds(250 * (1 << (attempt - 1)))
            let delay: Duration
            if let retryDelay, retryDelay > fallback {
                delay = retryDelay
            } else {
                delay = fallback
            }
            Log.warn(
                "TwitchTokenRefresher: Transient refresh failure; retrying (\(attempt)/\(attempts))",
                category: .twitchAuth)
            try await sleep(delay)
        }
        return .temporarilyUnavailable
    }

    /// Statuses worth retrying: request timeout, too early, rate limited, and
    /// any 5xx. Everything else (400/401 never reach here) means the grant
    /// will not succeed by waiting.
    nonisolated private static func isRetryableRefreshStatus(_ status: Int) -> Bool {
        status == 408 || status == 425 || status == 429 || (500..<600).contains(status)
    }

    /// Commits a rotated grant only while the initiating account session still
    /// owns both the actor generation and the exact source refresh token.
    ///
    /// The response is first held in `pendingRotation`, then the commit is
    /// tried up to three times (250 ms, 500 ms apart). If every write fails the
    /// rotation stays held and the result is `.temporarilyUnavailable`, so the
    /// next refresh for the same key re-commits it without spending another
    /// network exchange.
    private func persist(
        _ response: TwitchTokenResponse,
        replacing sourceRefreshToken: String,
        expected: TwitchCredentialStore.AccessExpectation,
        generation: UInt64,
        clientID: String,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) async throws -> RefreshResult {
        guard generation == refreshGeneration else {
            return .superseded
        }
        let key = RefreshKey(
            clientID: clientID, credentialRevision: expected.revision,
            accessToken: expected.accessToken, sourceRefreshToken: sourceRefreshToken)
        pendingRotation = PendingRotation(key: key, response: response, generation: generation)
        for attempt in 1...3 {
            try Task.checkCancellation()
            guard generation == refreshGeneration, TwitchCredentialStore.shared.matches(expected) else {
                if pendingRotation?.key == key, pendingRotation?.generation == generation {
                    pendingRotation = nil
                }
                return .superseded
            }
            do {
                let committed = try TwitchCredentialStore.shared.commitRefreshGrant(
                    response, replacing: sourceRefreshToken, expected: expected)
                if pendingRotation?.key == key, pendingRotation?.generation == generation {
                    pendingRotation = nil
                }
                return committed ? .refreshed(response.accessToken) : .superseded
            } catch {
                Log.warn("TwitchTokenRefresher: Rotated grant commit failed; retaining for retry",
                         category: .twitchAuth)
                if attempt < 3 { try await sleep(.milliseconds(250 * attempt)) }
            }
        }
        return .temporarilyUnavailable
    }
}
