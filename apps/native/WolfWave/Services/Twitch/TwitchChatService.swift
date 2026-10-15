//
//  TwitchChatService.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-01-08.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Network

// MARK: - Helix Response Models

/// `GET /helix/users` response. Used by `fetchBotIdentity` and `resolveUsername`.
nonisolated struct HelixUsersResponse: Decodable {
    struct User: Decodable {
        let id: String
        let login: String
        let displayName: String?
    }
    let data: [User]
}

/// `GET https://id.twitch.tv/oauth2/validate` response. Used by `validateToken`.
///
/// `login` and `userID` are parsed so the app can tell a streamer they are
/// signed in as the wrong account. Without them, "you're signed in as your bot
/// account, not your broadcaster account" is unsayable outside the channel
/// points path, which models it as `RedemptionStatus.botAccount`.
nonisolated struct TwitchValidateResponse: Decodable {
    let clientID: String?
    let scopes: [String]?
    let login: String?
    let userID: String?

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case scopes
        case login
        case userID = "user_id"
    }
}

/// `POST /helix/chat/messages` response. Used by `sendMessage` to confirm delivery.
nonisolated struct HelixSendMessageResponse: Decodable {
    struct SentMessage: Decodable {
        let isSent: Bool
    }
    let data: [SentMessage]
}

/// `GET /helix/streams` response. Used by `seedStreamLiveState`.
nonisolated struct HelixStreamsResponse: Decodable {
    struct Stream: Decodable {
        let id: String
        /// ISO-8601 stream start time, e.g. `2026-06-08T18:04:21Z`. Anchors the
        /// `!stats` "This stream" window when seeding mid-broadcast. Decoded from
        /// the JSON `started_at` field via the snake-case key strategy.
        let startedAt: String?
    }
    let data: [Stream]
}

/// Maps an `HTTPClient.HTTPError` to the matching `TwitchChatService.ConnectionError`.
/// Preserves the existing 401 → `authenticationFailed` mapping; everything else
/// becomes `.networkError(...)` with the underlying description.
nonisolated func mapHelixError(_ error: Error) -> TwitchChatService.ConnectionError {
    if let httpError = error as? HTTPClient.HTTPError {
        switch httpError {
        case .unexpectedStatus(401, _):
            return .authenticationFailed
        case .unexpectedStatus(let code, _):
            return .networkError("HTTP \(code)")
        case .invalidResponse:
            return .networkError("No HTTP response")
        case .decodingFailed:
            return .networkError("Unable to decode response")
        case .transport(let underlying):
            return .networkError(underlying.localizedDescription)
        }
    }
    if let connectionError = error as? TwitchChatService.ConnectionError {
        return connectionError
    }
    return .networkError(error.localizedDescription)
}

/// What a live token-validation request proves about the Polls OAuth scope.
///
/// Only ``present`` and ``missing`` are proof. ``indeterminate`` (transport
/// error, non-401 failure status, or an unparseable body) must not be treated as
/// a missing scope, or a Twitch hiccup would turn off Polls-mode vote-skip.
nonisolated enum PollScopeValidation: Equatable, Sendable {
    /// Twitch confirmed the token carries the Polls scope.
    case present
    /// Twitch answered 401, or a 2xx scope list without the Polls scope. No
    /// token at all also maps here.
    case missing
    /// The check could not reach a verdict.
    case indeterminate
}

/// Service managing Twitch chat connection and bot commands via EventSub WebSocket.
///
/// Handles:
/// - WebSocket connection to Twitch EventSub
/// - EventSub subscriptions (channel.chat.message, channel.poll.end, redemptions)
/// - Chat message routing to bot commands
/// - Chat message sending and replies
/// - Token validation and user identity resolution
///
/// Concurrency:
/// - `actor`-isolated. The actor's own mutable state lives inside its isolation
///   domain with no locks. The only locks are in the `ProviderRegistry` mirror
///   class and the shared `Atomic` boxes that exist so the sync dispatcher
///   bridge can read state without re-entering the actor.
/// - Side-effect "callbacks" (chat messages, connection state, vote-skip poll
///   results) are surfaced as `AsyncStream`s on the `nonisolated` interface.
/// - Track-info providers (`!song`, `!last`, `!stats`) are async closures;
///   AppDelegate hops to `@MainActor` inside them.
/// - Rate-limit bookkeeping lives in a nested `RateLimiter` actor so heavy
///   request flows don't serialize the entire chat-message pipeline.
///
/// Usage:
/// ```swift
/// let service = TwitchChatService()
/// try await service.connectToChannel(
///     channelName: "streamer",
///     token: oauthToken,
///     clientID: clientID
/// )
/// try await service.sendMessage("Hello, chat!")
/// ```
actor TwitchChatService {

    // MARK: - Nested Types

    /// One `channel.chat.message` notification, reduced to what command
    /// dispatch and the chat stream need.
    struct ChatMessage: Sendable {
        /// Twitch's chat message ID; used as the reply parent and dedup key.
        let messageID: String
        /// Sender's display name (`chatter_user_name`), not the login.
        let username: String
        /// Sender's Twitch user ID.
        let userID: String
        /// Message text, trimmed.
        let message: String
        /// The broadcaster's user ID (`broadcaster_user_id`), not the channel
        /// name.
        let channel: String
        let badges: [Badge]
        let reply: Reply?

        /// One chat badge. `setID` is the badge family (`moderator`,
        /// `subscriber`, `vip`, ...) that role checks match on; `info` carries
        /// extra data such as the subscription month count.
        struct Badge: Sendable {
            let setID: String
            let id: String
            let info: String
        }

        /// Twitch chat roles derived from a sender's badges.
        ///
        /// Pure and testable so the song-request permission gate can't silently
        /// regress (e.g. dropping the `founder` synonym for `subscriber`).
        struct Roles: Sendable {
            let isModerator: Bool
            let isBroadcaster: Bool
            let isSubscriber: Bool
            let isVIP: Bool
        }

        /// Derives chat roles from the message's badge set.
        ///
        /// - Note: `founder` is the badge Twitch gives a channel's earliest
        ///   subscribers in place of `subscriber`; both count as a subscriber so
        ///   the subscriber-only request gate doesn't wrongly deny founders.
        var roles: Roles {
            Roles(
                isModerator: badges.contains { $0.setID == "moderator" },
                isBroadcaster: badges.contains { $0.setID == "broadcaster" },
                isSubscriber: badges.contains { $0.setID == "subscriber" || $0.setID == "founder" },
                isVIP: badges.contains { $0.setID == "vip" }
            )
        }

        /// The message this one replies to, when the viewer used Twitch's
        /// reply feature.
        struct Reply: Sendable {
            let parentMessageID: String
            let parentMessageBody: String
            let parentUserID: String
            let parentUsername: String
        }
    }

    /// Errors thrown by connection, identity lookup, and Helix calls.
    ///
    /// Only ``authenticationFailed`` implicates the stored token; callers use
    /// that distinction to decide whether to show the re-auth prompt.
    enum ConnectionError: LocalizedError {
        /// A required ID, channel name, or token was empty.
        case invalidCredentials
        /// No Twitch client ID was configured.
        case missingClientID
        /// Transport, decode, or unexpected-status failure, with a short reason.
        case networkError(String)
        /// Twitch answered 401: the token is invalid or expired.
        case authenticationFailed
        /// Twitch answered successfully and no such channel exists. Distinct
        /// from a failed lookup: the request worked, the answer was "nobody".
        case channelNotFound
        /// Twitch accepted the credentials but refused or could not serve the
        /// request (403, 429, 5xx). The token is fine; something else is wrong.
        case notPermitted(status: Int)

        /// Short user-facing text for logs and UI.
        var errorDescription: String? {
            switch self {
            case .invalidCredentials:
                return "Invalid Twitch credentials"
            case .missingClientID:
                return "Twitch Client ID is not configured"
            case .networkError(let msg):
                return "Network error: \(msg)"
            case .authenticationFailed:
                return "Failed to authenticate with Twitch"
            case .channelNotFound:
                return "No Twitch channel by that name"
            case .notPermitted(let status):
                return "Twitch refused the request (HTTP \(status))"
            }
        }
    }

    /// Result of one attempt to send a chat message.
    ///
    /// Only ``retryableFailure`` enters the bounded retry queue. A permanent
    /// rejection (bad request, missing permission, Automod drop, or an
    /// indeterminate success payload) must not be retried: doing so either wastes
    /// requests or risks posting a duplicate message after Twitch already
    /// accepted the original request.
    enum ChatSendOutcome: Sendable, Equatable {
        case sent
        case retryableFailure
        case permanentFailure
    }

    /// Classification for a final Helix HTTP response after the one inline
    /// rate-limit retry has already been attempted.
    enum HelixResponseDisposition: Sendable, Equatable {
        case success
        case authenticationFailure
        case retryableFailure
        case permanentFailure
    }

    /// Internal error used to preserve the retryability classification from the
    /// Helix HTTP layer through response decoding.
    enum HelixRequestError: Error {
        case retryableHTTP(statusCode: Int)
        case permanentHTTP(statusCode: Int)
    }

    /// The account the stored token belongs to, as resolved from
    /// `GET /helix/users`. `login` is the lowercase handle; `displayName` keeps
    /// the user's capitalization.
    struct BotIdentity: Sendable {
        let userID: String
        let login: String
        let displayName: String
    }

    /// Result of checking whether a Twitch channel exists.
    ///
    /// `GET /helix/users` requires no scope, so the split here is meaningful:
    /// a 401 is the only outcome that implicates the token. ``notPermitted``
    /// carries everything else Twitch refused (403, 429, 5xx), which means the
    /// sign-in was accepted and the lookup failed for another reason. Telling
    /// the user to reconnect in that case wastes their time.
    enum ChannelValidationResult: Sendable, Equatable {
        case exists
        case notFound
        case authenticationFailed
        /// Twitch accepted the token but refused or could not answer the lookup.
        case notPermitted(status: Int)
        case error(String)
    }

    /// Outcome of checking a stored OAuth token with Twitch.
    ///
    /// Only ``invalid`` authorizes callers to expire the local session. Network
    /// failures, rate limits, server errors, and malformed success payloads are
    /// deliberately ``temporarilyUnavailable`` so an outage cannot erase or
    /// revoke otherwise usable credentials.
    ///
    /// ``missingScopes(_:)`` is separate from ``invalid`` on purpose. A token
    /// that Twitch still honors but that lacks an optional scope is *live*:
    /// chat keeps working, and only the feature needing that scope is affected.
    /// Collapsing it into ``invalid`` told the user their session had expired,
    /// fired the re-auth notification, and — because the re-auth flag also
    /// stops the hourly validator — left the still-good token unchecked from
    /// then on.
    enum TokenValidationResult: Sendable, Equatable {
        case valid
        case invalid
        /// Token is accepted by Twitch but is missing these scopes.
        case missingScopes([String])
        case temporarilyUnavailable
    }

    /// Tuple-style payload posted on a `channel.poll.end` for a vote-skip poll.
    struct SkipPollResult: Sendable {
        let pollID: String
        let skipVotes: Int
        let keepVotes: Int
    }

    /// How a `revocation` EventSub message should be handled.
    ///
    /// Twitch revocation statuses have materially different recovery paths.
    /// Keeping those paths explicit prevents terminal permission/account states
    /// from entering an endless reconnect loop while still recovering transport
    /// and maintenance revocations with the normal bounded backoff.
    enum RevocationDisposition: Sendable, Equatable {
        /// Token is no longer valid; surface the re-auth banner and stop reconnecting.
        case reauth
        /// The Twitch account no longer exists; stop without asking for re-auth.
        case accountUnavailable
        /// Twitch retired the subscription version; a client update is required.
        case clientUpdateRequired
        /// Moderator/chat access was removed; the channel capability is terminal.
        case permissionLost
        /// Twitch maintenance or WebSocket delivery failure; reconnect with backoff.
        case reconnect
        /// Unrecognized status; do nothing (log only).
        case ignore
    }

    // MARK: - EventSub Decision Helpers (nonisolated, pure, testable)

    /// Lower bound, in seconds, of the keepalive timeout Twitch documents for
    /// `session_welcome`.
    private nonisolated static let minimumKeepaliveTimeoutSeconds: TimeInterval = 10
    /// Upper bound, in seconds, of the documented keepalive timeout.
    private nonisolated static let maximumKeepaliveTimeoutSeconds: TimeInterval = 600
    /// Largest watchdog deadline, in seconds: the maximum timeout plus the grace
    /// period. Any deadline above it is treated as corrupt.
    nonisolated static let maximumKeepaliveDeadlineSeconds: TimeInterval =
        maximumKeepaliveTimeoutSeconds + AppConstants.Twitch.keepaliveGraceSeconds

    /// Returns `seconds` when it is a finite whole number inside the documented
    /// 10...600 range, otherwise `nil`.
    private nonisolated static func validatedKeepaliveTimeout(
        _ seconds: TimeInterval
    ) -> TimeInterval? {
        guard seconds.isFinite,
              seconds.rounded(.towardZero) == seconds,
              seconds >= minimumKeepaliveTimeoutSeconds,
              seconds <= maximumKeepaliveTimeoutSeconds else { return nil }
        return seconds
    }

    /// Extracts a session reconnect URL from a `session_reconnect` message.
    ///
    /// Reads `payload.session.reconnect_url`. Returns the trimmed string only when
    /// it is a non-empty, well-formed absolute URL; otherwise `nil` so the caller
    /// falls back to the proven fresh-connect path.
    nonisolated static func reconnectURL(from json: [String: Any]) -> String? {
        guard let payload = json["payload"] as? [String: Any],
              let session = payload["session"] as? [String: Any],
              let raw = session["reconnect_url"] as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "wss",
              url.host != nil else {
            return nil
        }
        return trimmed
    }

    /// Reads `payload.session.keepalive_timeout_seconds` from a `session_welcome`
    /// message. Returns `nil` when the field is missing, non-integral, or outside
    /// the documented 10...600-second range so the caller uses a safe default.
    nonisolated static func keepaliveTimeoutSeconds(from json: [String: Any]) -> TimeInterval? {
        guard let payload = json["payload"] as? [String: Any],
              let session = payload["session"] as? [String: Any] else {
            return nil
        }
        // Twitch sends an integer, but tolerate a numeric string too.
        if let intValue = session["keepalive_timeout_seconds"] as? Int {
            guard intValue >= Int(minimumKeepaliveTimeoutSeconds),
                  intValue <= Int(maximumKeepaliveTimeoutSeconds) else { return nil }
            return TimeInterval(intValue)
        }
        if let doubleValue = session["keepalive_timeout_seconds"] as? Double {
            return validatedKeepaliveTimeout(doubleValue)
        }
        if let stringValue = session["keepalive_timeout_seconds"] as? String,
           let parsed = TimeInterval(
               stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return validatedKeepaliveTimeout(parsed)
        }
        return nil
    }

    /// Computes the keepalive watchdog deadline: the advertised timeout plus a
    /// grace period. Invalid values fall back to the protocol default, and the
    /// result is capped so watchdog sleep can never receive an unsafe duration.
    nonisolated static func keepaliveDeadline(
        timeoutSeconds: TimeInterval,
        grace: TimeInterval
    ) -> TimeInterval {
        let safeTimeout = validatedKeepaliveTimeout(timeoutSeconds)
            ?? AppConstants.Twitch.keepaliveDefaultTimeoutSeconds
        let safeGrace = grace.isFinite ? max(0, grace) : 0
        let deadline = safeTimeout + safeGrace
        guard deadline.isFinite else {
            return AppConstants.Twitch.keepaliveDefaultTimeoutSeconds
                + AppConstants.Twitch.keepaliveGraceSeconds
        }
        return min(deadline, maximumKeepaliveDeadlineSeconds)
    }

    /// Guards a stored watchdog deadline (in seconds) before it is used for a
    /// sleep. A value that is non-finite or outside the minimum timeout ...
    /// ``maximumKeepaliveDeadlineSeconds`` range is replaced with the default
    /// timeout plus grace, so a bad value can never yield an instant or endless
    /// sleep. Applied both when the watchdog is armed and on every sleep.
    nonisolated static func normalizedKeepaliveDeadline(
        _ seconds: TimeInterval
    ) -> TimeInterval {
        guard seconds.isFinite,
              seconds >= minimumKeepaliveTimeoutSeconds,
              seconds <= maximumKeepaliveDeadlineSeconds else {
            return keepaliveDeadline(
                timeoutSeconds: AppConstants.Twitch.keepaliveDefaultTimeoutSeconds,
                grace: AppConstants.Twitch.keepaliveGraceSeconds)
        }
        return seconds
    }

    /// Classifies a Helix response without conflating permanent client errors
    /// with transient capacity/transport failures.
    nonisolated static func helixResponseDisposition(
        for statusCode: Int
    ) -> HelixResponseDisposition {
        switch statusCode {
        case 200..<300:
            return .success
        case 401:
            return .authenticationFailure
        case 408, 425, 429, 500...599:
            return .retryableFailure
        default:
            return .permanentFailure
        }
    }

    /// Only explicitly transient outcomes may enter the bounded retry queue.
    nonisolated static func shouldRetryChatSend(_ outcome: ChatSendOutcome) -> Bool {
        outcome == .retryableFailure
    }

    /// Cheap off-MainActor prefilter for the command dispatcher. All built-in,
    /// alias, and custom triggers are normalized to a leading `!`. Skipping
    /// leading whitespace preserves the dispatcher's existing trim behavior.
    nonisolated static func isPotentialCommand(_ message: String) -> Bool {
        message.first(where: { !$0.isWhitespace }) == "!"
    }

    /// Maps a `revocation` subscription `(type, status)` to a disposition.
    ///
    /// `status` drives the decision; `type` is accepted for future per-type
    /// granularity and logging. The mapping follows Twitch's EventSub status
    /// table and deliberately separates terminal identity/version/permission
    /// outcomes from transient WebSocket and maintenance failures.
    nonisolated static func revocationDisposition(
        type: String,
        status: String
    ) -> RevocationDisposition {
        _ = type
        switch status {
        case "authorization_revoked":
            return .reauth
        case "user_removed":
            return .accountUnavailable
        case "version_removed":
            return .clientUpdateRequired
        case "moderator_removed", "chat_user_banned":
            return .permissionLost
        case "beta_maintenance",
             "websocket_disconnected",
             "websocket_failed_ping_pong",
             "websocket_received_inbound_traffic",
             "websocket_connection_unused",
             "websocket_internal_error",
             "websocket_network_timeout",
             "websocket_network_error",
             "websocket_failed_to_reconnect":
            return .reconnect
        default:
            return .ignore
        }
    }

    /// Time-limited store of seen EventSub `message_id`s, optionally count-capped.
    ///
    /// Twitch EventSub is at-least-once delivery: duplicate notification frames
    /// (especially around `session_reconnect`) would re-run chat commands,
    /// channel-point redemptions, and bits events. IDs are remembered for `ttl`
    /// seconds (matching the 10-minute replay-age window in
    /// `handleWebSocketMessage`). The general transport store is count-capped;
    /// command reservations use TTL-only retention so unrelated chat cannot
    /// evict them. A plain value type with an injectable clock keeps the
    /// insert/prune/duplicate contract testable without the actor or a socket.
    struct EventSubMessageDeduplicator {
        private struct Entry {
            let id: String
            let seenAt: Date
        }

        /// How long a message ID stays remembered. Matches the replay-age
        /// rejection window applied to `metadata.message_timestamp`.
        private let ttl: TimeInterval
        /// Optional maximum number of remembered IDs; oldest are evicted first.
        private let maxEntries: Int?
        /// Authoritative map of remembered ID to the time it was recorded.
        private var seen: [String: Date] = [:]
        /// Append-only insertion order with a moving head. This makes normal
        /// prune/evict operations O(1) amortized instead of filtering and sorting
        /// the complete dictionary for every busy-chat frame.
        private var insertionOrder: [Entry] = []
        /// Index of the oldest live node in `insertionOrder`; everything before
        /// it has been consumed and is reclaimed by
        /// `compactInsertionOrderIfNeeded()`.
        private var insertionHead = 0

        /// Number of IDs currently remembered. Exposed for tests.
        var entryCount: Int { seen.count }

        /// - Parameters:
        ///   - ttl: Seconds an ID stays remembered.
        ///   - maxEntries: Optional size cap; `nil` means TTL-only retention.
        ///     Values below 1 are clamped to 1.
        init(ttl: TimeInterval = 600, maxEntries: Int? = 500) {
            self.ttl = ttl
            self.maxEntries = maxEntries.map { max(1, $0) }
        }

        /// Records `id` as seen at `now` and reports whether it was already
        /// seen within the `ttl` window. Expired entries are pruned first; the
        /// optional size cap evicts the oldest entries after insertion.
        mutating func isDuplicate(_ id: String, now: Date = Date()) -> Bool {
            pruneExpired(now: now)
            if seen[id] != nil { return true }

            seen[id] = now
            insertionOrder.append(Entry(id: id, seenAt: now))

            if let maxEntries {
                while seen.count > maxEntries, insertionHead < insertionOrder.count {
                    let oldest = insertionOrder[insertionHead]
                    insertionHead += 1
                    // An ID can be reinserted after an earlier entry expired or was
                    // evicted. Remove only if this queue node is still authoritative.
                    if seen[oldest.id] == oldest.seenAt {
                        seen.removeValue(forKey: oldest.id)
                    }
                }
            }
            compactInsertionOrderIfNeeded()
            return false
        }

        /// Drops IDs older than `ttl` from the front of the insertion queue.
        /// Stops at the first unexpired node, which relies on `now` never moving
        /// backwards between calls (nodes are appended in time order).
        private mutating func pruneExpired(now: Date) {
            while insertionHead < insertionOrder.count {
                let oldest = insertionOrder[insertionHead]
                guard now.timeIntervalSince(oldest.seenAt) > ttl else { break }
                insertionHead += 1
                if seen[oldest.id] == oldest.seenAt {
                    seen.removeValue(forKey: oldest.id)
                }
            }
            compactInsertionOrderIfNeeded()
        }

        /// Periodically reclaims consumed prefix storage. The occasional O(n)
        /// copy is amortized over hundreds of O(1) frame operations.
        private mutating func compactInsertionOrderIfNeeded() {
            guard insertionHead >= 256,
                  insertionHead * 2 >= insertionOrder.count else { return }
            insertionOrder.removeFirst(insertionHead)
            insertionHead = 0
        }
    }

    /// Rate-limit bucket state for one Helix endpoint.
    struct RateLimitState: Sendable {
        /// Requests left in the current window (`Ratelimit-Remaining`).
        var remaining: Int = 0
        /// When the window refills, as Unix epoch seconds. Derived from
        /// `Ratelimit-Reset` with the wait bounded by `RetryAfter`.
        var resetTime: TimeInterval = 0
        /// Bucket size (`Ratelimit-Limit`).
        var limit: Int = 0
    }

    /// Pending message awaiting retry.
    struct PendingMessage: Sendable {
        let message: String
        let parentMessageID: String?
        /// Send attempts made so far; capped by `maxMessageRetries`.
        var attempts: Int
    }

    // MARK: - Static Constants

    /// Posted on `NotificationCenter.default` when the connected flag changes.
    nonisolated static let connectionStateChanged =
        Notification.Name.twitchConnectionStateChanged

    /// Title used for vote-skip Twitch polls. Also the match key for `channel.poll.end`.
    nonisolated static let skipPollTitle = "Skip the current song?"
    /// "Skip" choice label on a vote-skip poll.
    nonisolated static let skipPollSkipChoice = "Skip"
    /// "Keep playing" choice label on a vote-skip poll.
    nonisolated static let skipPollKeepChoice = "Keep playing"

    // MARK: - Configuration

    /// Helix root (`https://api.twitch.tv/helix`); endpoint paths are appended.
    let apiBaseURL = AppConstants.Twitch.apiBaseURL
    /// `BotCommandDispatcher` is `@MainActor` (project default). The actor
    /// holds it as `nonisolated` (it's auto-Sendable since it's MainActor) and
    /// hops to `MainActor.run` for every call into it.
    nonisolated let commandDispatcher: BotCommandDispatcher
    /// Helix wrapper for the managed "Request a Song" reward (create,
    /// reconcile, fulfill, cancel).
    let channelPointsService: TwitchChannelPointsService
    /// Disk-backed record of paid-event outcomes (fulfill / refund and Bits
    /// actions) that must be replayed until acknowledged.
    let redemptionResolutionOutbox: TwitchRedemptionResolutionOutbox
    /// Supplies the client ID for replayed redemption work, which can run
    /// when no channel is joined and `clientID` is `nil`.
    let redemptionClientIDProvider: @Sendable () -> String?
    /// Test seam that builds the EventSub socket. `nil` means `urlSession`
    /// creates it.
    let eventSubWebSocketFactory: (@Sendable (URL) -> URLSessionWebSocketTask)?
    /// Test seam for starting an EventSub socket; production calls `resume()`.
    let eventSubWebSocketResume: @Sendable (URLSessionWebSocketTask) -> Void
    /// Test seam for reading one EventSub frame; production calls `receive()`.
    let eventSubWebSocketReceive: @Sendable (URLSessionWebSocketTask) async throws
        -> URLSessionWebSocketTask.Message
    /// Per-endpoint Helix bucket tracker. Its own actor, so a request waiting
    /// for capacity does not hold this actor.
    private let rateLimiter = RateLimiter()

    /// Session for the EventSub socket and actor-owned requests. Waits for
    /// connectivity and never serves cached responses. Invalidated in `deinit`.
    let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
    /// Narrow injection seam for EventSub subscription POST/DELETE tests.
    let eventSubHTTPClient: HTTPClient
    /// Helix request client used by chat sends and other actor-owned API calls.
    let helixHTTPClient: HTTPClient

    /// Backoff attempts allowed per transport reconnect cycle.
    let maxReconnectionAttempts = AppConstants.Twitch.maxReconnectionAttempts
    /// Network-recovery cycles allowed inside one cooldown window.
    let maxNetworkReconnectCycles = AppConstants.Twitch.maxNetworkReconnectCycles
    /// Retries for a chat send that failed with a retryable outcome.
    let maxMessageRetries = AppConstants.Twitch.maxMessageRetries

    // MARK: - WebSocket / Session

    /// The current EventSub socket. During a `session_reconnect` handoff this
    /// is the replacement; the old one lives in `migrationSourceWebSocketTask`.
    var webSocketTask: URLSessionWebSocketTask?
    /// EventSub session ID from the latest `session_welcome`. Subscriptions are
    /// created against it.
    var sessionID: String?
    /// Receive loop for `webSocketTask`.
    var receiveTask: Task<Void, Never>?
    /// EventSub session where channel.poll.end is known to be subscribed.
    var pollSubscriptionSessionID: String?
    /// Session currently awaiting a poll-subscription POST.
    var pollSubscriptionAttemptSessionID: String?
    /// Narrow deterministic seams for live-toggle tests.
    var pollScopeValidationOverride: (@Sendable () async -> PollScopeValidation)?
    /// Test seam replacing the `channel.poll.end` subscription POST. Receives
    /// the session ID and returns whether the subscription succeeded.
    var pollSubscriptionOverride: (@Sendable (String) async -> Bool)?

    /// During Twitch's `session_reconnect` handoff the source socket must stay
    /// open and continue delivering events until the replacement sends welcome.
    /// These fields retain that source independently from the new current socket.
    var migrationSourceWebSocketTask: URLSessionWebSocketTask?
    /// Receive loop that keeps draining `migrationSourceWebSocketTask`.
    var migrationSourceReceiveTask: Task<Void, Never>?
    /// Socket that most recently completed the welcome handshake. Unlike
    /// `sessionID`, object identity distinguishes the old welcomed session from
    /// a replacement socket that is still waiting for its own welcome.
    var welcomedWebSocketTask: URLSessionWebSocketTask?

    /// One long-lived keepalive watchdog per EventSub session. Inbound frames
    /// update ``lastKeepaliveActivity`` instead of cancelling and allocating a
    /// new sleeping task for every busy-chat message.
    var keepaliveWatchdogTask: Task<Void, Never>?
    /// Monotonic time of the last inbound frame. The watchdog sleeps until this
    /// plus `keepaliveDeadlineSeconds`.
    var lastKeepaliveActivity: ContinuousClock.Instant?
    /// Invalidates a watchdog that was cancelled just before it re-entered the actor.
    var keepaliveGeneration: UInt64 = 0
    /// Diagnostic counter that also locks the one-task-per-session contract in tests.
    var keepaliveWatchdogTaskStarts = 0

    /// Current keepalive deadline (seconds), set from `session_welcome`.
    var keepaliveDeadlineSeconds: TimeInterval = AppConstants.Twitch.keepaliveDefaultTimeoutSeconds

    /// True while a `session_reconnect` migration is in flight. The resulting
    /// `session_welcome` then only re-arms the watchdog and flips connected,
    /// skipping the `subscribeTo*` calls because subscriptions migrate with the
    /// reconnect_url session.
    var isMigratingSession = false

    /// Dedup store for inbound EventSub frames. Twitch delivers at-least-once,
    /// so `handleWebSocketMessage` drops any frame whose `metadata.message_id`
    /// was already seen. Actor-isolated, mutated only on the actor.
    var messageDeduplicator = EventSubMessageDeduplicator()
    /// Command-shaped chat IDs retain the complete replay TTL. Ordinary chat
    /// volume must not evict a delayed duplicate before it can rerun a command.
    var commandMessageDeduplicator = EventSubMessageDeduplicator(maxEntries: nil)

    // MARK: - Credentials

    // Set together by a channel join and cleared together on leave. `nil`
    // means no channel is joined. Never persisted here; the Keychain owns them.

    /// Twitch user ID of the joined channel.
    var broadcasterID: String?
    /// Twitch user ID of the signed-in account that sends chat. Equal to
    /// `broadcasterID` when the streamer signed in as themselves, which the
    /// channel-points path requires.
    var botID: String?
    /// Access token used for Helix calls and EventSub subscriptions.
    var oauthToken: String?
    /// Twitch application client ID sent as `Client-Id`.
    var clientID: String?
    /// Login of the signed-in account. Note: only ever reset to `nil` on join;
    /// nothing in the service assigns it a value today.
    var botUsername: String?

    /// Live `SongRequestService`, used by the channel-point and bit redemption
    /// handlers. Set by `AppDelegate` via `setSongRequestServiceReference(_:)`.
    var songRequestService: SongRequestService?

    // MARK: - Toggles

    /// Whether a successful `channel.chat.message` subscription posts the
    /// "connected" chat message. A user-initiated join turns it on; the silent
    /// launch auto-reconnect turns it off so chat isn't spammed on every launch.
    var shouldSendConnectionMessageOnSubscribe = true
    /// Whether chat commands are dispatched. Always `true` in production; only
    /// `setCommandsEnabledForTesting(_:)` turns it off.
    private(set) var commandsEnabled = true

    // MARK: - Track-Info Providers (async, nonisolated)

    /// Providers live in a nonisolated lock-protected registry so AppDelegate
    /// can set them synchronously from MainActor, and the dispatcher closures
    /// wired in `joinChannel` (which run on MainActor) can read them without
    /// awaiting this actor.
    nonisolated private let providers = ProviderRegistry()

    // MARK: - UserDefaults-derived (read on demand)

    /// Whether the current song command is enabled (computed from UserDefaults on each access).
    nonisolated var currentSongCommandEnabled: Bool {
        Preferences.bool(AppConstants.UserDefaults.currentSongCommandEnabled, default: false)
    }

    /// Whether the last song command is enabled (computed from UserDefaults on each access).
    nonisolated var lastSongCommandEnabled: Bool {
        Preferences.bool(AppConstants.UserDefaults.lastSongCommandEnabled, default: false)
    }

    /// Whether the `!stats` command should respond. Both the Stats feature and
    /// the command itself must be enabled (computed from UserDefaults).
    nonisolated var statsCommandActive: Bool {
        let stats = DefaultsStore.store.bool(forKey: AppConstants.UserDefaults.statsEnabled)
        let command = DefaultsStore.store.bool(forKey: AppConstants.UserDefaults.statsCommandEnabled)
        return stats && command
    }

    // MARK: - Connection State

    /// Actor-owned connected flag. Written only through `setConnected(_:)`;
    /// every write is mirrored into `isConnectedSnapshot`.
    private var _connected = false {
        didSet { isConnectedSnapshot.set(_connected) }
    }
    /// Latch so the connection chat message goes out at most once per join.
    /// Reset on join and on disconnect.
    private var hasSentConnectionMessage = false
    /// Whether the channel is live, from Helix on connect and then the
    /// `stream.online` / `stream.offline` events. Gates `!stats`.
    var streamLive = false {
        didSet { streamLiveSnapshot.set(streamLive) }
    }

    /// When the current stream went live, or `nil` when offline. Anchors the
    /// `!stats` command's "This stream" window. Seeded from Helix `started_at` on
    /// connect and updated by the `stream.online` / `stream.offline` events.
    var streamLiveSince: Date? {
        didSet { streamSinceSnapshot.set(streamLiveSince) }
    }

    /// Nonisolated mirror of `_connected` so MainActor UI code (status chips,
    /// menu bar enable state) can read it without `await`.
    nonisolated let isConnectedSnapshot = Atomic(false)

    /// Nonisolated read of the connection state, mirroring the actor-isolated
    /// `isConnected`. Lets synchronous MainActor callers (menu bar, status
    /// chips, settings panes) check the connection without `await` instead of
    /// reaching through `isConnectedSnapshot.value` at every site.
    nonisolated var currentlyConnected: Bool { isConnectedSnapshot.value }

    /// Nonisolated mirror of `streamLive` so the synchronous dispatcher bridge
    /// (`!stats` enable check) can read it without re-entering the actor.
    nonisolated private let streamLiveSnapshot = Atomic(false)

    /// Nonisolated mirror of `streamLiveSince` so the synchronous `!stats`
    /// provider (MainActor) can read the stream's start time without `await`.
    nonisolated private let streamSinceSnapshot = Atomic<Date?>(nil)

    /// When the current stream went live, or `nil` when offline. Readable from any
    /// isolation (mirrors the actor-isolated `streamLiveSince`).
    nonisolated var currentStreamLiveSince: Date? { streamSinceSnapshot.value }

    /// Actor-isolated connection state. Turns `true` only after the session is
    /// welcomed and its chat subscription succeeds (or a migration completes).
    var isConnected: Bool { _connected }

    /// Raw write of the connected flag. Posts nothing; transitions that the UI
    /// must see go through `broadcastConnectionState(_:error:)`.
    func setConnected(_ value: Bool) {
        _connected = value
    }

    /// Broadcasts a connection-state transition to every consumer surface: the
    /// actor's `_connected` flag (and its atomic mirror), the NotificationCenter
    /// post observed by the UI, and every per-subscriber connection-state
    /// stream. The single write path for connection-state transitions.
    ///
    /// - Parameter error: Optional failure description attached to the
    ///   notification payload (transport errors only).
    func broadcastConnectionState(_ connected: Bool, error: String? = nil) {
        // State streams model transitions, not repeated teardown calls. Preserve
        // an explicit error notification even if the state was already false.
        guard _connected != connected || error != nil else { return }
        setConnected(connected)
        // Post on the main actor: this runs on the actor's background executor,
        // and SwiftUI panes observe via NotificationCenter.publisher + .onReceive,
        // which delivers synchronously on the posting thread with no main hop.
        // Mutating MainActor view state off-main is the documented executor-assert
        // SIGTRAP class, so hop here to cover every current and future observer.
        Task { @MainActor in
            NotificationCenter.default.postTwitchConnectionState(isConnected: connected, error: error)
        }
        connectionStateHub.yield(connected)
    }

    // MARK: - Disconnect / Network State

    /// True between a disconnect starting and the next connection attempt.
    /// Inbound frames, reconnect attempts, and queued chat retries bail out
    /// while it is set, so a teardown can't be raced by late work.
    var isProcessingDisconnect = false
    /// Synchronous signal observed by the receive loop after its socket is
    /// closed for credential teardown. Unlike cancelling the receive task, this
    /// lets a frame already awaiting actor admission finish paid-event intake.
    nonisolated let eventSubTeardownQuiescing = Atomic(false)
    /// Nesting count of in-flight `leaveChannel` calls. `eventSubTeardownQuiescing`
    /// is cleared only when the outermost one exits.
    var eventSubCredentialTeardownFenceDepth = 0
    /// Invalidates channel joins that resume after a leave or a newer connect attempt.
    var connectionGeneration: UInt64 = 0
    /// Changes only for an explicit public join/connect, not automatic transport
    /// reconnects. A leave suspended on its final reward pause uses this to avoid
    /// clearing a newer same-account user-initiated join.
    var channelOwnershipGeneration: UInt64 = 0

    /// Ownership captured by one EventSub receive loop. Both the logical
    /// generation and WebSocket object identity must still match after an await.
    struct EventSubReceiveContext: Sendable {
        let generation: UInt64
        let webSocketTask: URLSessionWebSocketTask
    }

    /// Whether work started by a receive loop may still act after an await.
    ///
    /// - Parameter context: The loop's captured ownership, or `nil` for work
    ///   not tied to a socket (only cancellation is checked then).
    /// - Returns: `false` once the task is cancelled, the connection attempt is
    ///   superseded or torn down, or the socket is neither the current one nor
    ///   the migration source still draining during a reconnect handoff.
    func receiveContextIsCurrent(_ context: EventSubReceiveContext?) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let context else { return true }
        return connectionAttemptIsCurrent(context.generation)
            && (webSocketTask === context.webSocketTask
                || migrationSourceWebSocketTask === context.webSocketTask)
    }
    /// Watches network reachability so a drop disconnects and a return
    /// reconnects. Callbacks run on `networkMonitorQueue`.
    var networkPathMonitor: NWPathMonitor?
    /// Feeds path updates from `networkMonitorQueue` into the ordered consumer.
    var networkPathContinuation: AsyncStream<Bool>.Continuation?
    /// The single consumer that applies reachability updates in arrival order.
    var networkPathTask: Task<Void, Never>?
    /// Invalidates callbacks already queued by a canceled/replaced path monitor.
    var networkMonitorGeneration: UInt64 = 0
    /// Serial queue `NWPathMonitor` requires for its callbacks.
    let networkMonitorQueue = DispatchQueue(
        label: "com.mrdemonwolf.wolfwave.networkmonitor")
    /// Last reachability seen. While `false`, reconnects are not scheduled.
    var isNetworkReachable = true

    // MARK: - Reconnection State

    /// Backoff attempts used in the current reconnect cycle. Reset once a
    /// session is usable (chat subscribed or migration done), on leave or a
    /// terminal stop, and on an accepted network-recovery cycle.
    var reconnectionAttempts = 0
    /// The pending backoff-then-reconnect task, if one is scheduled.
    var reconnectTask: Task<Void, Never>?
    /// Times out a socket that never sends `session_welcome`.
    var sessionWelcomeTask: Task<Void, Never>?
    /// Pending send of the one-time "connected" chat message.
    private var connectionMessageTask: Task<Void, Never>?

    /// Tracks total network-triggered reconnect cycles to prevent infinite loops
    /// when the network path flaps repeatedly.
    var networkReconnectCycles = 0
    /// Unix epoch seconds of the last accepted network-recovery cycle. The
    /// cycle counter resets once `networkReconnectCooldown` has passed.
    var lastNetworkReconnectTime: TimeInterval = 0

    // What an automatic reconnect rejoins with. Published by a channel join and
    // cleared on leave; `nil` channel means there is nothing to reconnect.

    /// Channel login the automatic reconnect rejoins.
    var reconnectChannelName: String?
    /// Access token for the automatic reconnect.
    var reconnectToken: String?
    /// Client ID for the automatic reconnect.
    var reconnectClientID: String?

    /// Single service seam for every live 401. The rejected access expectation
    /// is mandatory so an old request can never refresh a replacement account.
    private var reactiveTokenRefreshOperation: @Sendable (
        String,
        TwitchCredentialStore.AccessExpectation
    ) async throws -> TwitchTokenRefresher.RefreshResult = { clientID, expected in
        try await TwitchTokenRefresher.attemptReactiveRefresh(
            clientID: clientID,
            expected: expected
        )
    }

    /// Sleep used between redemption fulfill / refund retries. Injectable so
    /// tests don't wait real time.
    var redemptionResolutionSleep: @Sendable (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }

    /// Test seam: replaces the reactive 401 token refresher.
    func setReactiveTokenRefresh(
        _ operation: @escaping @Sendable (
            String,
            TwitchCredentialStore.AccessExpectation
        ) async throws -> TwitchTokenRefresher.RefreshResult
    ) {
        reactiveTokenRefreshOperation = operation
    }

    /// Runs the injectable refresher for the exact credential rejected by an
    /// earlier request.
    func reactiveTokenRefresh(
        _ clientID: String,
        expected: TwitchCredentialStore.AccessExpectation
    ) async throws -> TwitchTokenRefresher.RefreshResult {
        try await reactiveTokenRefreshOperation(clientID, expected)
    }

    /// Test seam: replaces `redemptionResolutionSleep`.
    func setRedemptionResolutionSleep(
        _ operation: @escaping @Sendable (Duration) async throws -> Void
    ) {
        redemptionResolutionSleep = operation
    }

    // MARK: - Pending Messages

    /// Chat sends waiting for a retry, oldest first.
    var pendingMessages: [PendingMessage] = []
    /// The task draining `pendingMessages`, if one is running.
    var pendingRetryTask: Task<Void, Never>?
    /// Invalidates a cancelled drain so its deferred cleanup cannot clear a newer task.
    var pendingRetryGeneration: UInt64 = 0

    /// Read-only lifecycle snapshots used by diagnostics and focused tests.
    var pendingMessageCount: Int { pendingMessages.count }
    var hasPendingMessageRetry: Bool { pendingRetryTask != nil }

    // MARK: - Command Tasks

    /// In-flight command pipelines. Each task awaits its command but does not
    /// block the serial EventSub receive loop, and is owned by one connection
    /// generation so reconnect/leave can cancel it deterministically.
    var commandTasks: [UUID: Task<Void, Never>] = [:]

    /// Number of in-flight command pipelines. Exposed for tests.
    var activeCommandTaskCount: Int { commandTasks.count }

    // MARK: - Redemption Pipeline Tasks

    /// Identity of one Bits event in the in-memory fallback: the EventSub
    /// message ID scoped to its channel.
    struct VolatileBitsFallbackKey: Hashable {
        let messageID: String
        let broadcasterID: String
    }

    /// A Bits event held in memory because the durable outbox write failed.
    struct VolatileBitsFallback {
        let item: TwitchRedemptionResolutionOutbox.BitsItem
        /// When the event was claimed; drives freshness-horizon pruning.
        let claimedAt: Date
        /// Whether the request / boost has already been applied. A completed
        /// entry stays as a duplicate guard until it ages out.
        var completed: Bool
    }

    /// Process-owned fallback used only when the atomic outbox write fails.
    /// Completed entries remain non-evicting for the full EventSub freshness
    /// horizon; incomplete entries remain until they can run or the process exits.
    var volatileBitsFallbacks:
        [VolatileBitsFallbackKey: VolatileBitsFallback] = [:]

    /// In-flight channel-point pipelines, keyed by their durable intake item so
    /// duplicate EventSub delivery cannot process the same payment twice.
    /// Like bits work, these pipelines survive socket reconnects: only their
    /// chat reply is generation-bound. Deinit still cancels them.
    var redemptionTasks: [UUID: Task<Void, Never>] = [:]
    /// Bits represent an irreversible viewer payment. Their request pipeline
    /// therefore outlives EventSub socket generations; only the eventual chat
    /// reply is gated to the originating session.
    var paidRedemptionTasks: [UUID: Task<Void, Never>] = [:]
    /// Number of in-flight Bits pipelines. Exposed for tests.
    var activePaidRedemptionTaskCount: Int { paidRedemptionTasks.count }
    /// Fulfillment/refund HTTP work outlives its originating EventSub session so
    /// reconnect/leave can never strand already-spent viewer points.
    var redemptionResolutionTasks: [UUID: Task<Void, Never>] = [:]
    /// Ownership token preventing a canceled worker's deferred cleanup from
    /// deleting a newer replay task for the same persisted item.
    var redemptionResolutionWorkerIDs: [UUID: UUID] = [:]

    // MARK: - AsyncStream Outputs

    /// Stream of chat messages received via EventSub `channel.chat.message`.
    nonisolated let chatMessages: AsyncStream<ChatMessage>
    /// Stream of finished vote-skip poll tallies.
    nonisolated let skipPollResults: AsyncStream<SkipPollResult>

    /// Write end of `chatMessages`. Finished in `deinit`.
    let chatMessagesContinuation: AsyncStream<ChatMessage>.Continuation
    /// Write end of `skipPollResults`. Finished in `deinit`.
    let skipPollResultsContinuation: AsyncStream<SkipPollResult>.Continuation

    /// Fan-out registry backing `connectionStateChanges()`. One continuation
    /// per live subscriber; `broadcastConnectionState` yields to all of them.
    nonisolated private let connectionStateHub = ConnectionStateHub()

    /// Returns a fresh stream of connection state transitions (`true` = connected).
    ///
    /// Each call registers its own subscriber, so multiple consumers all
    /// receive every transition, and cancelling one consumer (e.g. a settings
    /// window closing its view model) never finishes anyone else's stream.
    nonisolated func connectionStateChanges() -> AsyncStream<Bool> {
        connectionStateHub.subscribe()
    }

    // MARK: - Init / Deinit

    /// Marked `@MainActor` so `BotCommandDispatcher()` (a MainActor type under
    /// project default isolation) can be constructed at init time. AppDelegate
    /// runs on MainActor; tests call from MainActor (Swift Testing) or wrap.
    @MainActor init(
        eventSubHTTPClient: HTTPClient = .shared,
        helixHTTPClient: HTTPClient = .shared,
        channelPointsService: TwitchChannelPointsService = TwitchChannelPointsService(),
        redemptionResolutionOutbox: TwitchRedemptionResolutionOutbox = .shared,
        redemptionClientIDProvider: @escaping @Sendable () -> String? = {
            TwitchChatService.resolveClientID()
        },
        eventSubWebSocketFactory: (@Sendable (URL) -> URLSessionWebSocketTask)? = nil,
        eventSubWebSocketResume: @escaping @Sendable (URLSessionWebSocketTask) -> Void = {
            $0.resume()
        },
        eventSubWebSocketReceive: @escaping @Sendable (URLSessionWebSocketTask) async throws
            -> URLSessionWebSocketTask.Message = { try await $0.receive() }
    ) {
        let chat = AsyncStream.makeStream(
            of: ChatMessage.self,
            bufferingPolicy: .bufferingNewest(AppConstants.Twitch.chatMessageStreamBuffer))
        let skip = AsyncStream.makeStream(
            of: SkipPollResult.self,
            bufferingPolicy: .bufferingNewest(AppConstants.Twitch.controlStreamBuffer))

        self.chatMessages = chat.stream
        self.chatMessagesContinuation = chat.continuation
        self.skipPollResults = skip.stream
        self.skipPollResultsContinuation = skip.continuation
        self.commandDispatcher = BotCommandDispatcher()
        self.eventSubHTTPClient = eventSubHTTPClient
        self.helixHTTPClient = helixHTTPClient
        self.channelPointsService = channelPointsService
        self.redemptionResolutionOutbox = redemptionResolutionOutbox
        self.redemptionClientIDProvider = redemptionClientIDProvider
        self.eventSubWebSocketFactory = eventSubWebSocketFactory
        self.eventSubWebSocketResume = eventSubWebSocketResume
        self.eventSubWebSocketReceive = eventSubWebSocketReceive
    }

    /// Cancels every owned task and socket, finishes the output streams, and
    /// drops this service from the redemption teardown gate.
    deinit {
        // Synchronous cleanup only. Actor isolation forbids awaits in deinit.
        sessionWelcomeTask?.cancel()
        reconnectTask?.cancel()
        receiveTask?.cancel()
        migrationSourceReceiveTask?.cancel()
        keepaliveWatchdogTask?.cancel()
        connectionMessageTask?.cancel()
        pendingRetryTask?.cancel()
        commandTasks.values.forEach { $0.cancel() }
        redemptionTasks.values.forEach { $0.cancel() }
        paidRedemptionTasks.values.forEach { $0.cancel() }
        redemptionResolutionTasks.values.forEach { $0.cancel() }
        networkPathMonitor?.cancel()
        networkPathContinuation?.finish()
        networkPathTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        migrationSourceWebSocketTask?.cancel(with: .goingAway, reason: nil)
        chatMessagesContinuation.finish()
        connectionStateHub.finish()
        skipPollResultsContinuation.finish()
        // A URLSession that is never invalidated retains its internal state
        // until the process exits. Throwaway instances (resolveBotIdentityStatic)
        // would otherwise leak one session each per OAuth/re-auth.
        urlSession.invalidateAndCancel()
        TwitchRedemptionTeardownGate.removeService(
            serviceID: ObjectIdentifier(self))
    }

    // MARK: - Wiring (called once at app startup)

    /// Wire the song request service into the command dispatcher.
    /// Hops to `MainActor` because `BotCommandDispatcher` is `@MainActor`.
    func setSongRequestService(callback: @escaping @Sendable () -> SongRequestService?) async {
        await MainActor.run { commandDispatcher.setSongRequestService(callback: callback) }
    }

    /// Wire the song request queue into the command dispatcher.
    func setSongRequestQueue(callback: @escaping @Sendable () -> SongRequestQueue?) async {
        await MainActor.run { commandDispatcher.setSongRequestQueue(callback: callback) }
    }

    /// Wire the skip-vote manager into the command dispatcher.
    func setSkipVoteManager(callback: @escaping @Sendable () -> SkipVoteManager?) async {
        await MainActor.run { commandDispatcher.setSkipVoteManager(callback: callback) }
    }

    /// Set the live `SongRequestService` used by redemption handlers.
    ///
    /// Passing a non-nil service also replays Bits events that were persisted
    /// while no service was available to apply them.
    func setSongRequestServiceReference(_ service: SongRequestService?) {
        self.songRequestService = service
        if service != nil {
            replayPendingBitsEvents()
        }
    }

    /// Provide the `!song` lookup. Called from MainActor by AppDelegate.
    nonisolated func setCurrentSongInfoProvider(_ provider: (@Sendable () async -> String)?) {
        providers.setCurrent(provider)
    }

    /// Provide the `!last` lookup.
    nonisolated func setLastSongInfoProvider(_ provider: (@Sendable () async -> String)?) {
        providers.setLast(provider)
    }

    /// Provide the `!stats` lookup.
    nonisolated func setStatsInfoProvider(_ provider: (@Sendable () async -> String)?) {
        providers.setStats(provider)
    }

    /// Test seam: toggles whether bot commands are dispatched. No production
    /// caller; the app always dispatches commands.
    func setCommandsEnabledForTesting(_ enabled: Bool) {
        self.commandsEnabled = enabled
    }

    /// Toggle whether the connection confirmation message is sent on subscribe.
    /// `TwitchViewModel` turns it on for a user-initiated join; the launch
    /// auto-reconnect in `AppDelegate` turns it off. Set before connecting.
    func setShouldSendConnectionMessageOnSubscribe(_ value: Bool) {
        self.shouldSendConnectionMessageOnSubscribe = value
    }

    // Helix rate limiter (nested actor) lives in TwitchChatService+RateLimiter.swift

    // Network monitoring + reconnection lifecycle lives in TwitchChatService+Connection.swift

    // MARK: - Public Methods

    /// Joins a Twitch channel using pre-resolved IDs.
    ///
    /// - Parameters:
    ///   - broadcasterID: The broadcaster's Twitch user ID
    ///   - botID: The bot's Twitch user ID
    ///   - token: OAuth access token with chat scopes
    ///   - clientID: Twitch application client ID
    ///   - attemptGeneration: Generation from an outer `connectToChannel` call
    ///     that already began the attempt. `nil` means this is a direct join:
    ///     it starts a new attempt and takes channel ownership.
    ///   - credentialRevision: Keychain grant revision the join was resolved
    ///     against. When set, the join is cancelled if the stored grant changed
    ///     while it was suspended.
    /// - Throws: `ConnectionError` if credentials are invalid or missing;
    ///   `CancellationError` if a leave, a newer join, or an account change
    ///   superseded this attempt. Publishes credentials only on success.
    /// - Note: Does not open the EventSub socket. `connectToChannel` does that
    ///   after publishing reconnect ownership.
    func joinChannel(
        broadcasterID: String,
        botID: String,
        token: String,
        clientID: String,
        attemptGeneration: UInt64? = nil,
        credentialRevision: UInt64? = nil
    ) async throws {
        guard !broadcasterID.isEmpty, !botID.isEmpty, !token.isEmpty else {
            Log.error("TwitchChatService: Invalid credentials for channel join", category: .twitchChat)
            throw ConnectionError.invalidCredentials
        }
        guard !clientID.isEmpty else {
            Log.error("TwitchChatService: Missing client ID for channel join", category: .twitchChat)
            throw ConnectionError.missingClientID
        }
        if attemptGeneration == nil {
            // A new explicit connection supersedes a suspended account
            // teardown. The older leave observes the ownership-generation
            // change and preserves credentials instead of clearing this join.
            eventSubTeardownQuiescing.set(false)
            channelOwnershipGeneration &+= 1
            // A direct connection owns recovery now; a delayed backoff must not
            // wake and supersede the socket this call is about to establish.
            reconnectTask?.cancel()
            reconnectTask = nil
        }

        let generation: UInt64
        if let attemptGeneration {
            try ensureConnectionAttempt(attemptGeneration)
            generation = attemptGeneration
        } else {
            generation = beginConnectionAttempt()
        }

        // Defer publishing credentials and starting durable replay until every
        // suspension below has completed and the connection/account revisions
        // are still current. A superseded join must leave no stale actor state.

        // Wire dispatcher providers. The dispatcher is `@MainActor`, so wiring
        // hops to MainActor. Track-info providers are wired as async closures
        // and consumed via `processMessageAsync`. That avoids the deadlock
        // the previous `runSync` semaphore bridge introduced when an AppDelegate
        // provider hopped back to MainActor while MainActor was blocked on the
        // semaphore.
        let providers = self.providers
        let streamLiveSnapshot = self.streamLiveSnapshot
        let currentSongCommandEnabled: @Sendable () -> Bool = { [weak self] in
            self?.currentSongCommandEnabled ?? false
        }
        let lastSongCommandEnabled: @Sendable () -> Bool = { [weak self] in
            self?.lastSongCommandEnabled ?? false
        }
        // `!stats` now follows the same global gate as every other command;
        // its own enable state is just feature-on + command-on.
        let statsCommandActive: @Sendable () -> Bool = { [weak self] in
            self?.statsCommandActive ?? false
        }
        // Global "commands only while live" gate. Off → commands reply anytime.
        // On → every command (incl. !stats) waits for stream.online. Read per
        // message so toggling the setting or going live takes effect at once.
        let commandsGlobalGate: @Sendable () -> Bool = {
            guard DefaultsStore.store.bool(forKey: AppConstants.UserDefaults.commandsLiveOnly) else {
                return true
            }
            return streamLiveSnapshot.value
        }
        // Live values for custom-command variables (`$song`, `$lastsong`). Reuses
        // the same now-playing providers the built-in `!song` / `!last` commands
        // read, so a custom command like "!np → Now playing: $song" stays in sync.
        let customCommandVariables: @Sendable () async -> CustomCommandVariables = {
            let song: String
            if let provider = providers.current() { song = await provider() } else { song = "" }
            let last: String
            if let provider = providers.last() { last = await provider() } else { last = "" }
            return CustomCommandVariables(currentSong: song, lastSong: last)
        }
        await MainActor.run {
            commandDispatcher.setCurrentSongInfoAsync {
                Log.debug("Twitch provider: current song closure invoked", category: .twitchChat)
                guard let provider = providers.current() else {
                    Log.debug("Twitch provider: current song: no provider, default", category: .twitchChat)
                    return "No track currently playing"
                }
                let result = await provider()
                Log.debug("Twitch provider: current song returned \(result.prefix(40))", category: .twitchChat)
                return result
            }
            commandDispatcher.setLastSongInfoAsync {
                guard let provider = providers.last() else { return "No previous track available" }
                return await provider()
            }
            commandDispatcher.setStatsInfoAsync {
                guard let provider = providers.stats() else { return "No listening stats yet" }
                return await provider()
            }
            commandDispatcher.setCurrentSongCommandEnabled(callback: currentSongCommandEnabled)
            commandDispatcher.setLastSongCommandEnabled(callback: lastSongCommandEnabled)
            commandDispatcher.setStatsCommandEnabled(callback: statsCommandActive)
            commandDispatcher.setGlobalGate(callback: commandsGlobalGate)
            commandDispatcher.setCustomCommandVariablesProvider(customCommandVariables)
        }

        // `leaveChannel()` or a newer join may have run while MainActor was
        // wiring the dispatcher. Never let this superseded attempt open a socket.
        try ensureConnectionAttempt(generation)
        if let credentialRevision {
            guard TwitchCredentialStore.shared.revision(
                matchingAccessToken: token) == credentialRevision else {
                throw CancellationError()
            }
        }

        self.broadcasterID = broadcasterID
        self.botID = botID
        self.oauthToken = token
        self.clientID = clientID
        self.botUsername = nil
        self.hasSentConnectionMessage = false
        replayPendingRedemptionResolutions()

        // The caller publishes reconnect ownership before starting transport.
        // Connected state still waits for EventSub session_welcome.
    }

    /// Connects to a Twitch channel by name, resolving usernames to IDs.
    ///
    /// Resolves the signed-in account's user ID (from the stored grant, or
    /// Helix when the grant lacks one, committing it back to the Keychain),
    /// resolves `channelName` to a broadcaster ID, joins, records reconnect
    /// credentials, starts network monitoring, and opens the EventSub socket.
    /// Returns once the socket is started, not once it is connected.
    ///
    /// - Parameters:
    ///   - channelName: Channel login. Must match the channel stored with the
    ///     current Keychain grant for `token`, or the call is cancelled.
    ///   - token: OAuth access token.
    ///   - clientID: Twitch application client ID.
    ///   - attemptGeneration: Generation of an attempt already begun by the
    ///     reconnect path. `nil` for a user-initiated connect.
    ///   - expectedCredentialRevision: Grant revision the caller observed; a
    ///     mismatch cancels instead of connecting a different account.
    /// - Throws: `ConnectionError` for bad input or failed lookups;
    ///   `CancellationError` when superseded or the stored grant changed.
    func connectToChannel(
        channelName: String,
        token: String,
        clientID: String,
        attemptGeneration: UInt64? = nil,
        expectedCredentialRevision: UInt64? = nil
    ) async throws {
        guard !channelName.isEmpty, !token.isEmpty else {
            Log.error("TwitchChatService: Invalid channel name or token", category: .twitchChat)
            throw ConnectionError.invalidCredentials
        }
        guard !clientID.isEmpty else {
            Log.error("TwitchChatService: Missing client ID for channel connect", category: .twitchChat)
            throw ConnectionError.missingClientID
        }
        guard let credentialSnapshot = TwitchCredentialStore.shared.connectionSnapshot(
            matchingAccessToken: token
        ), credentialSnapshot.channelID == channelName else {
            throw CancellationError()
        }
        if let expectedCredentialRevision {
            guard credentialSnapshot.revision == expectedCredentialRevision else {
                throw CancellationError()
            }
        }
        let credentialRevision = credentialSnapshot.revision

        if attemptGeneration == nil {
            eventSubTeardownQuiescing.set(false)
            channelOwnershipGeneration &+= 1
            // A direct connection owns recovery now; a delayed backoff must not
            // wake and supersede the socket this call is about to establish.
            reconnectTask?.cancel()
            reconnectTask = nil
        }

        let generation: UInt64
        if let attemptGeneration {
            try ensureConnectionAttempt(attemptGeneration)
            generation = attemptGeneration
        } else {
            generation = beginConnectionAttempt()
        }

        var botUserID = credentialSnapshot.userID

        if botUserID?.isEmpty ?? true {
            let identity = try await fetchBotIdentity(token: token, clientID: clientID)
            try ensureConnectionAttempt(generation)
            botUserID = identity.userID
            let resolvedUsername = identity.displayName.isEmpty
                ? identity.login
                : identity.displayName
            guard try TwitchCredentialStore.shared.commitIdentity(
                username: resolvedUsername,
                userID: identity.userID,
                matchingAccessToken: token,
                expectedRevision: credentialRevision
            ) else {
                throw CancellationError()
            }
        }

        guard let botUserID else { throw ConnectionError.invalidCredentials }

        let broadcasterUserID = try await resolveUsername(
            channelName, token: token, clientID: clientID)
        try ensureConnectionAttempt(generation)
        guard TwitchCredentialStore.shared.revision(
            matchingAccessToken: token) == credentialRevision else {
            throw CancellationError()
        }

        guard !broadcasterUserID.isEmpty else {
            throw ConnectionError.networkError("Could not resolve channel name to user ID")
        }

        try await joinChannel(
            broadcasterID: broadcasterUserID,
            botID: botUserID,
            token: token,
            clientID: clientID,
            attemptGeneration: generation,
            credentialRevision: credentialRevision)

        try ensureConnectionAttempt(generation)
        guard TwitchCredentialStore.shared.revision(
            matchingAccessToken: token) == credentialRevision else {
            disconnectFromEventSub()
            throw CancellationError()
        }

        // Store credentials for automatic reconnection
        reconnectChannelName = channelName
        reconnectToken = token
        reconnectClientID = clientID

        if networkPathMonitor == nil {
            startNetworkMonitoring()
        }

        // Reconnect ownership must exist before a fast session_welcome can run
        // subscription setup and tear down this socket on a critical failure.
        connectToEventSub()

        Log.info("TwitchChatService: Connected to channel \(channelName)", category: .twitchChat)
    }

    /// Starts a new logical connection attempt and supersedes any older one.
    @discardableResult
    func beginConnectionAttempt() -> UInt64 {
        // A new logical attempt owns the transport, not just the receive
        // generation. Retire an existing socket immediately so a validation or
        // account-supersede failure cannot leave a ghost connection whose
        // frames are forever rejected by the new generation.
        if webSocketTask != nil || migrationSourceWebSocketTask != nil {
            disconnectFromEventSub()
        } else {
            invalidateSessionBoundChatWork()
        }
        isProcessingDisconnect = false
        return connectionGeneration
    }

    /// Invalidates chat work owned by the current EventSub session.
    ///
    /// Called both when starting a new attempt and as soon as any socket is
    /// disconnected/migrated. That closes the backoff window where an old
    /// command could otherwise finish before the replacement attempt begins.
    func invalidateSessionBoundChatWork() {
        connectionGeneration &+= 1
        connectionMessageTask?.cancel()
        connectionMessageTask = nil
        commandTasks.values.forEach { $0.cancel() }
        commandTasks.removeAll()
        // Channel-point redemptions represent spent viewer points. Their
        // durable-intake owner must finish across socket generations; dropping
        // it here would let replay refund while the old pipeline still mutates
        // the queue. Session-bound chat sends reject the stale generation.
        pendingRetryTask?.cancel()
        pendingRetryTask = nil
        pendingRetryGeneration &+= 1
        pendingMessages.removeAll(keepingCapacity: false)
    }

    /// Actor-isolated intent check used at every suspension boundary and by tests.
    func connectionAttemptIsCurrent(_ generation: UInt64) -> Bool {
        generation == connectionGeneration && !isProcessingDisconnect
    }

    /// True only while an async command still belongs to the active channel session.
    func commandReplyIsCurrent(generation: UInt64, broadcasterID: String) -> Bool {
        connectionAttemptIsCurrent(generation) && self.broadcasterID == broadcasterID
    }

    /// Throws `CancellationError` when `generation` is no longer current or the
    /// task was cancelled. Called after every suspension in the join path.
    private func ensureConnectionAttempt(_ generation: UInt64) throws {
        guard connectionAttemptIsCurrent(generation), !Task.isCancelled else {
            throw CancellationError()
        }
    }

    // Bot identity + token/username resolution lives in TwitchChatService+Auth.swift

    /// Leaves the current channel and disconnects from EventSub. The managed
    /// reward is held while this actor still owns the only credentials that can
    /// mutate it, before account teardown is allowed to clear those credentials.
    ///
    /// Order: pause the managed reward, close the socket without dropping a
    /// paid frame already queued on the actor, settle outstanding redemption
    /// work, then clear reconnect state, network monitoring, and credentials.
    /// Any step that finds a newer join or account aborts without clearing.
    ///
    /// - Parameter allowDiscardingOpaqueRedemptionRecovery: When `true`, skips
    ///   the guard that refuses teardown while the redemption outbox can't be
    ///   verified or holds quarantined recovery data. The user must have
    ///   explicitly agreed to lose that data.
    /// - Returns: `true` when the channel was left and credentials cleared;
    ///   `false` when teardown was refused or superseded (state is kept).
    @discardableResult
    func leaveChannel(
        allowDiscardingOpaqueRedemptionRecovery: Bool = false
    ) async -> Bool {
        Log.info("TwitchChatService:leaveChannel() called", category: .twitchChat)
        eventSubCredentialTeardownFenceDepth += 1
        eventSubTeardownQuiescing.set(true)
        defer {
            eventSubCredentialTeardownFenceDepth -= 1
            if eventSubCredentialTeardownFenceDepth == 0 {
                eventSubTeardownQuiescing.set(false)
            }
        }
        let teardownOwnershipGeneration = channelOwnershipGeneration
        let teardownConnectionGeneration = connectionGeneration
        let teardownRewardSnapshot = TwitchManagedRewardStore.snapshot()
        let storedRewardBroadcasterID: String?
        switch teardownRewardSnapshot {
        case let .owned(identity):
            storedRewardBroadcasterID = identity.broadcasterID
        case .none, .legacy, .corrupt:
            storedRewardBroadcasterID = nil
        }

        let teardownBroadcasterID = broadcasterID
        let teardownBotID = botID
        let teardownClientID = clientID
        let teardownManagedBroadcasterID = teardownBroadcasterID
            ?? storedRewardBroadcasterID
            ?? TwitchCredentialStore.shared.accessSnapshot()?.userID
        guard await pauseManagedRewardBeforeCredentialTeardown(
            allowDiscardingOpaqueRedemptionRecovery:
                allowDiscardingOpaqueRedemptionRecovery
        ) else {
            Log.error(
                "TwitchChatService: Refusing credential teardown while the managed reward may still accept redemptions",
                category: .twitchChat)
            return false
        }

        // `leaveChannel` now suspends for bounded setup/drain/pause work.
        // Reject a newer actor session or a reward owned by another broadcaster;
        // legacy/corrupt identities are never sufficient teardown authority.
        let rewardOwnershipIsCurrent: Bool
        switch TwitchManagedRewardStore.snapshot() {
        case .none:
            rewardOwnershipIsCurrent = true
        case let .owned(identity):
            rewardOwnershipIsCurrent =
                identity.broadcasterID == teardownManagedBroadcasterID
        case .legacy, .corrupt:
            rewardOwnershipIsCurrent = false
        }
        guard channelOwnershipGeneration == teardownOwnershipGeneration,
              connectionGeneration == teardownConnectionGeneration,
              rewardOwnershipIsCurrent,
              broadcasterID == teardownBroadcasterID,
              botID == teardownBotID,
              clientID == teardownClientID else {
            if let teardownManagedBroadcasterID {
                TwitchRedemptionTeardownGate.cancelTeardown(
                    serviceID: ObjectIdentifier(self),
                    broadcasterID: teardownManagedBroadcasterID,
                    generation: teardownOwnershipGeneration)
            }
            Log.info(
                "TwitchChatService: Account changed during reward pause; skipping stale teardown",
                category: .twitchChat)
            // A newer session owns any subsequent reconciliation.
            await refreshRedemptionSubscriptions()
            return false
        }

        // Close the socket without cancelling a receive task that may already
        // be queued on this actor with a paid frame. Only after that intake
        // boundary is quiescent can the final durable drain be authoritative.
        guard await quiesceEventSubReceiveBeforeCredentialTeardown(
            expectedOwnershipGeneration: teardownOwnershipGeneration,
            expectedConnectionGeneration: teardownConnectionGeneration
        ) else {
            if let teardownManagedBroadcasterID {
                TwitchRedemptionTeardownGate.cancelTeardown(
                    serviceID: ObjectIdentifier(self),
                    broadcasterID: teardownManagedBroadcasterID,
                    generation: teardownOwnershipGeneration)
            }
            return false
        }
        if let teardownManagedBroadcasterID {
            guard await settleRedemptionWorkBeforeCredentialTeardown(
                broadcasterID: teardownManagedBroadcasterID
            ) else {
                TwitchRedemptionTeardownGate.cancelTeardown(
                    serviceID: ObjectIdentifier(self),
                    broadcasterID: teardownManagedBroadcasterID,
                    generation: teardownOwnershipGeneration)
                Log.error(
                    "TwitchChatService: Refusing credential teardown because paid work arrived at the final EventSub intake boundary",
                    category: .twitchChat)
                return false
            }
        }

        guard eventSubTeardownQuiescing.value,
              channelOwnershipGeneration == teardownOwnershipGeneration,
              connectionGeneration == teardownConnectionGeneration,
              broadcasterID == teardownBroadcasterID,
              botID == teardownBotID,
              clientID == teardownClientID else {
            if let teardownManagedBroadcasterID {
                TwitchRedemptionTeardownGate.cancelTeardown(
                    serviceID: ObjectIdentifier(self),
                    broadcasterID: teardownManagedBroadcasterID,
                    generation: teardownOwnershipGeneration)
            }
            return false
        }

        isProcessingDisconnect = true
        disconnectFromEventSub(allowDuringCredentialTeardown: true)
        if let teardownManagedBroadcasterID {
            // Setup cannot restart for the old receive context after disconnect,
            // so the process-local fence can now be released without an unpause race.
            TwitchRedemptionTeardownGate.cancelTeardown(
                serviceID: ObjectIdentifier(self),
                broadcasterID: teardownManagedBroadcasterID,
                generation: teardownOwnershipGeneration)
        }

        // Clear reconnection credentials
        reconnectChannelName = nil
        reconnectToken = nil
        reconnectClientID = nil
        reconnectionAttempts = 0
        networkReconnectCycles = 0
        reconnectTask?.cancel()
        reconnectTask = nil

        // Network monitoring is needed only while a Twitch channel is active.
        // Recreate it on the next join rather than keeping a process-lifetime
        // path monitor after the integration is disabled.
        stopNetworkMonitoring()
        isNetworkReachable = true

        broadcasterID = nil
        botID = nil
        oauthToken = nil
        clientID = nil
        hasSentConnectionMessage = false

        Log.info("TwitchChatService: Left channel", category: .twitchChat)
        return true
    }

    // Token validation lives in TwitchChatService+Auth.swift

    /// Sends the connection confirmation message to the channel.
    ///
    /// Called automatically when the bot successfully subscribes to channel chat messages.
    func sendConnectionMessage() {
        connectionMessageTask?.cancel()
        guard let broadcasterID else { return }
        let generation = connectionGeneration
        connectionMessageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AppConstants.Twitch.connectionMessageDelay))
            if Task.isCancelled { return }
            await self?.sendConnectionMessageIfNeeded(
                generation: generation,
                broadcasterID: broadcasterID
            )
        }
    }

    /// Posts the connection message once per join, only while `generation` and
    /// `broadcasterID` still describe the live session.
    func sendConnectionMessageIfNeeded(
        generation: UInt64,
        broadcasterID: String
    ) async {
        guard !Task.isCancelled,
              commandReplyIsCurrent(
                generation: generation,
                broadcasterID: broadcasterID
              ),
              !hasSentConnectionMessage else { return }
        hasSentConnectionMessage = true
        await sendSessionBoundMessage(
            AppConstants.Twitch.connectionMessage,
            replyTo: nil,
            generation: generation,
            broadcasterID: broadcasterID)
    }

    // Message sending + retry queue lives in TwitchChatService+Sending.swift

    // EventSub message parsing (handleEventSubMessage) lives in TwitchChatService+EventSub.swift

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

    // WebSocket connection management lives in TwitchChatService+Connection.swift

    // Keepalive watchdog + WebSocket receive loop live in TwitchChatService+Connection.swift

    // EventSub message routing (handleWebSocketMessage, handleSessionReconnect,
    // handleRevocation, signalReauthNeededAndStop, handleSessionWelcome,
    // handleNotification, handlePollEndEvent) lives in TwitchChatService+EventSub.swift

    // Vote-skip polls, stream-state handling, and EventSub subscriptions
    // (createSkipPoll, subscribeToPollEvents, handleStreamStateNotification,
    // subscribeToChannelChatMessage, subscribeToStreamEvents, seedStreamLiveState,
    // postEventSubSubscription) live in TwitchChatService+EventSub.swift

    // Redemption EventSub subscriptions (subscribeToRedemptionsIfEnabled,
    // refreshRedemptionSubscriptions, ensureSongRequestRewardAndSubscribe,
    // pauseManagedRewardIfPossible, subscribeToChannelPointsRedemption,
    // subscribeToBitsUse) live in TwitchChatService+RedemptionSubscriptions.swift

    // Redemption event handlers (handleChannelPointsRedemption,
    // runChannelPointsRedemption, clearRedemptionTask, handleBitsUse,
    // startBitsEvent, applyPersistedBitsEvent, replayPendingBitsEvents) live in
    // TwitchChatService+RedemptionHandlers.swift

    // Redemption helpers (redemptionOutcome, bitsOutcomeMessage,
    // currentChannelPointCredentials, channelPointsCostSetting, bitsMinimumSetting,
    // setRedemptionStatus, cleanBitsMessage, stripLeadingCheermotes) live in
    // TwitchChatService+Redemptions.swift

    // Channel/username resolution (validateChannelExists, resolveUsername) lives in
    // TwitchChatService+Auth.swift

    /// Lock-protected registry for the three async track-info providers.
    ///
    /// Lives outside actor isolation so MainActor code can set and read
    /// providers without awaiting the actor. Tiny surface, single lock.
    /// Does not reintroduce the lock-sprawl the actor conversion removed.
    final class ProviderRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var _current: (@Sendable () async -> String)?
        private var _last: (@Sendable () async -> String)?
        private var _stats: (@Sendable () async -> String)?

        // Setters and getters for the `!song`, `!last`, and `!stats` providers.
        // `nil` means "not wired"; the dispatcher then replies with a default.

        func setCurrent(_ provider: (@Sendable () async -> String)?) {
            lock.withLock { _current = provider }
        }
        func setLast(_ provider: (@Sendable () async -> String)?) {
            lock.withLock { _last = provider }
        }
        func setStats(_ provider: (@Sendable () async -> String)?) {
            lock.withLock { _stats = provider }
        }
        func current() -> (@Sendable () async -> String)? { lock.withLock { _current } }
        func last() -> (@Sendable () async -> String)? { lock.withLock { _last } }
        func stats() -> (@Sendable () async -> String)? { lock.withLock { _stats } }
    }

    /// Lock-protected fan-out registry for connection-state subscribers.
    ///
    /// A single shared `AsyncStream` is unicast: the first consumer's
    /// cancellation finishes the shared continuation, silently dropping every
    /// later yield for the process lifetime, and two concurrent consumers
    /// split events arbitrarily. Instead, each `subscribe()` call returns a
    /// fresh stream backed by its own continuation, `yield(_:)` broadcasts to
    /// every live subscriber, and a stream's termination removes only that
    /// subscriber (mirrors `NetworkInfoService.pathUpdates()`). Its own type
    /// so the fan-out contract is unit-testable without the actor or a socket.
    final class ConnectionStateHub: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

        /// Returns a fresh connection-state stream for one subscriber. The
        /// subscriber is registered synchronously, so yields after this call
        /// returns are buffered even before iteration starts.
        func subscribe() -> AsyncStream<Bool> {
            AsyncStream(bufferingPolicy: .bufferingNewest(AppConstants.Twitch.controlStreamBuffer)) { continuation in
                let id = UUID()
                lock.withLock { continuations[id] = continuation }
                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }
                    self.lock.withLock { _ = self.continuations.removeValue(forKey: id) }
                }
            }
        }

        /// Yields `value` to every live subscriber.
        func yield(_ value: Bool) {
            let subscribers = lock.withLock { continuations }
            for continuation in subscribers.values { continuation.yield(value) }
        }

        /// Finishes every subscriber's stream and empties the registry.
        func finish() {
            let subscribers = lock.withLock {
                let snapshot = continuations
                continuations.removeAll()
                return snapshot
            }
            for continuation in subscribers.values { continuation.finish() }
        }
    }

}
