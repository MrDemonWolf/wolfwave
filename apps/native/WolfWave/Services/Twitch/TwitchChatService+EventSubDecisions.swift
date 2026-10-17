//
//  TwitchChatService+EventSubDecisions.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Pure, `nonisolated` EventSub decision helpers: keepalive deadlines,
/// reconnect URLs, Helix response classification, and revocation handling.
extension TwitchChatService {

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
}
