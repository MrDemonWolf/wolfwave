//
//  TwitchChatService+Types.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Nested value types and helper classes of `TwitchChatService`: chat
/// message and error models, EventSub dedup, rate-limit and retry state,
/// the track-info provider registry, and the connection-state fan-out hub.
extension TwitchChatService {

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

    /// Lock-protected registry for the async track-info providers.
    ///
    /// Lives outside actor isolation so MainActor code can set and read
    /// providers without awaiting the actor. Tiny surface, single lock.
    /// Does not reintroduce the lock-sprawl the actor conversion removed.
    final class ProviderRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var _current: (@Sendable () async -> String)?
        private var _last: (@Sendable () async -> String)?
        private var _stats: (@Sendable () async -> String)?
        private var _customVariables: (@Sendable () async -> CustomCommandVariables)?

        // Setters and getters for the `!song`, `!last`, and `!stats` providers
        // and the custom-command `$song` / `$lastsong` values. `nil` means
        // "not wired"; the dispatcher then falls back to a default.

        func setCurrent(_ provider: (@Sendable () async -> String)?) {
            lock.withLock { _current = provider }
        }
        func setLast(_ provider: (@Sendable () async -> String)?) {
            lock.withLock { _last = provider }
        }
        func setStats(_ provider: (@Sendable () async -> String)?) {
            lock.withLock { _stats = provider }
        }
        func setCustomVariables(_ provider: (@Sendable () async -> CustomCommandVariables)?) {
            lock.withLock { _customVariables = provider }
        }
        func current() -> (@Sendable () async -> String)? { lock.withLock { _current } }
        func last() -> (@Sendable () async -> String)? { lock.withLock { _last } }
        func stats() -> (@Sendable () async -> String)? { lock.withLock { _stats } }
        func customVariables() -> (@Sendable () async -> CustomCommandVariables)? {
            lock.withLock { _customVariables }
        }
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
