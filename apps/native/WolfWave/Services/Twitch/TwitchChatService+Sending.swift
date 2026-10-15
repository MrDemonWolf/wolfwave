//
//  TwitchChatService+Sending.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-11.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Outbound chat: plain messages, threaded replies, announcements, and the
/// bounded retry queue for transient send failures. Every send is bound to the
/// channel session that requested it.
extension TwitchChatService {

    // MARK: - Message Sending

    /// Sends a message to the current channel. No-op when no channel is joined.
    func sendMessage(_ message: String) async {
        await sendMessage(message, replyTo: nil)
    }

    /// Sends a message that replies to another message.
    ///
    /// This is the public entry point used by command handlers. It delegates to
    /// `sendMessageOnce(_:replyTo:)` and queues only explicitly transient
    /// failures. Permanent/indeterminate failures stay dropped so a successful
    /// request with a malformed response can never produce duplicate chat text.
    func sendMessage(_ message: String, replyTo parentMessageID: String?) async {
        guard let broadcasterID else { return }
        await sendSessionBoundMessage(
            message,
            replyTo: parentMessageID,
            generation: connectionGeneration,
            broadcasterID: broadcasterID)
    }

    /// Sends a command response only to the session that received its command.
    ///
    /// The identity checks bracket the network suspension. If a disconnect or
    /// reconnect happens while command work or the send is in flight, the
    /// response cannot be queued for the replacement channel. Starting any new
    /// connection also clears the shared retry queue.
    func sendCommandReply(
        _ message: String,
        replyTo parentMessageID: String,
        generation: UInt64,
        broadcasterID: String
    ) async {
        await sendSessionBoundMessage(
            message,
            replyTo: parentMessageID,
            generation: generation,
            broadcasterID: broadcasterID)
    }

    /// Posts a custom-command response as a Twitch announcement.
    ///
    /// Returns `false` when Twitch refuses (missing scope, account not a mod,
    /// any other error) so the caller can fall back to a plain reply. Deliberately
    /// not routed through `sendMessageOnce`: a 401 here means one missing scope,
    /// not a dead session, so it must not trip the re-auth flag.
    func sendAnnouncement(
        _ message: String,
        generation: UInt64,
        broadcasterID: String
    ) async -> Bool {
        guard !Task.isCancelled,
              commandReplyIsCurrent(generation: generation, broadcasterID: broadcasterID),
              let botID, let token = oauthToken, let clientID else {
            return false
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let status: AnnounceStatus
        do {
            _ = try await sendAPIRequest(
                method: "POST",
                endpoint: "/chat/announcements?broadcaster_id=\(broadcasterID)&moderator_id=\(botID)",
                body: ["message": trimmed.truncatedForChat()],
                token: token,
                clientID: clientID)
            status = .ok
        } catch ConnectionError.authenticationFailed {
            // 401 is also Twitch's answer for a dead token. Only call it a scope
            // gap when validation says the token itself is fine; a dead token
            // surfaces through the fallback reply's own refresh/re-auth path.
            switch await validateToken(token, requiredScopes: [AppConstants.Twitch.announcementsScope]) {
            case .missingScopes: status = .scopeMissing
            case .valid: status = .notModerator
            case .invalid, .temporarilyUnavailable: status = .failed
            }
        } catch HelixRequestError.permanentHTTP(let code), HelixRequestError.retryableHTTP(let code) {
            status = AnnounceStatus.from(statusCode: code)
        } catch is CancellationError {
            return false
        } catch {
            status = .failed
        }
        // A stale task from a torn-down session must not overwrite live state.
        guard !Task.isCancelled,
              commandReplyIsCurrent(generation: generation, broadcasterID: broadcasterID) else {
            return false
        }
        Self.setAnnounceStatus(status)
        if status != .ok {
            Log.warn(
                "TwitchChatService: Announcement refused (\(status.rawValue)); falling back to a reply",
                category: .twitchChat)
        }
        return status == .ok
    }

    /// Persists the outcome of the last announcement for the settings banner.
    nonisolated static func setAnnounceStatus(_ status: AnnounceStatus) {
        DefaultsStore.store.set(
            status.rawValue, forKey: AppConstants.UserDefaults.customCommandAnnounceStatus)
    }

    /// Sends and optionally queues a message only while one exact channel
    /// generation owns it. Used for both command replies and the delayed
    /// connection greeting so neither can leak into a replacement channel.
    func sendSessionBoundMessage(
        _ message: String,
        replyTo parentMessageID: String?,
        generation: UInt64,
        broadcasterID: String
    ) async {
        guard !Task.isCancelled,
              commandReplyIsCurrent(generation: generation, broadcasterID: broadcasterID) else {
            return
        }

        let outcome = await sendMessageOnce(message, replyTo: parentMessageID)
        guard !Task.isCancelled,
              commandReplyIsCurrent(generation: generation, broadcasterID: broadcasterID) else {
            return
        }

        if Self.shouldRetryChatSend(outcome) {
            queueMessageForRetry(message: message, parentMessageID: parentMessageID, attempts: 0)
        }
    }

    /// Performs one send attempt without touching the retry queue. The outcome
    /// explicitly distinguishes transient failures from permanent rejections.
    /// Empty/whitespace-only text is a successful no-op.
    func sendMessageOnce(
        _ message: String,
        replyTo parentMessageID: String?
    ) async -> ChatSendOutcome {
        await sendMessageOnce(
            message,
            replyTo: parentMessageID,
            allowsRefreshRetry: true
        )
    }

    /// Internal bounded 401 retry. Twitch rejected the original request before
    /// delivery, so retrying it once with a newly-issued token is duplicate-safe.
    private func sendMessageOnce(
        _ message: String,
        replyTo parentMessageID: String?,
        allowsRefreshRetry: Bool
    ) async -> ChatSendOutcome {
        guard let broadcasterID,
              let botID,
              let token = oauthToken,
              let clientID else {
            Log.warn("TwitchChatService: Not connected, send attempt failed", category: .twitchChat)
            return .retryableFailure
        }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .sent }
        let generation = connectionGeneration
        let expectedCredential = TwitchCredentialStore.shared
            .connectionSnapshot(
                matchingAccessToken: token
            )?.accessExpectation

        let finalMessage = trimmed.truncatedForChat()

        var body: [String: Any] = [
            "broadcaster_id": broadcasterID,
            "sender_id": botID,
            "message": finalMessage,
        ]
        if let parentMessageID, !parentMessageID.isEmpty {
            body["reply_parent_message_id"] = parentMessageID
        }

        do {
            let data = try await sendAPIRequest(
                method: "POST",
                endpoint: "/chat/messages",
                body: body,
                token: token,
                clientID: clientID)
            do {
                let parsed = try JSONCoders.snakeCase.decode(HelixSendMessageResponse.self, from: data)
                guard let first = parsed.data.first else {
                    Log.warn(
                        "TwitchChatService: Send response contained no result; "
                            + "not retrying an indeterminate delivery",
                        category: .twitchChat)
                    return .permanentFailure
                }
                guard first.isSent else {
                    Log.warn(
                        "TwitchChatService: Message dropped by Twitch; "
                            + "not retrying a permanent rejection",
                        category: .twitchChat)
                    return .permanentFailure
                }
            } catch {
                Log.warn(
                    "TwitchChatService: Failed to decode send-message response; "
                        + "delivery is indeterminate and will not be retried - "
                        + error.localizedDescription,
                    category: .twitchChat)
                return .permanentFailure
            }
            return .sent
        } catch ConnectionError.authenticationFailed {
            Log.error(
                "TwitchChatService: Send rejected (401); attempting token refresh",
                category: .twitchChat)
            guard let expectedCredential else {
                return .permanentFailure
            }
            guard allowsRefreshRetry else {
                guard rejectedCredentialIsCurrent(
                    expectedCredential,
                    clientID: clientID,
                    generation: generation,
                    broadcasterID: broadcasterID
                ) else { return .permanentFailure }
                Log.error(
                    "TwitchChatService: Refreshed token was rejected by chat send",
                    category: .twitchChat)
                signalReauthNeededAndStop()
                return .permanentFailure
            }
            guard let recovery = await recoverRejectedAccessToken(
                expectedCredential,
                clientID: clientID,
                generation: generation,
                broadcasterID: broadcasterID
            ) else { return .permanentFailure }

            switch recovery {
            case .refreshed:
                return await sendMessageOnce(
                    message,
                    replyTo: parentMessageID,
                    allowsRefreshRetry: false
                )
            case .invalid:
                signalReauthNeededAndStop()
                return .permanentFailure
            case .temporarilyUnavailable:
                disconnectFromEventSub()
                if isNetworkReachable { scheduleReconnect() }
                return .retryableFailure
            case .superseded:
                return .permanentFailure
            }
        } catch HelixRequestError.permanentHTTP(let statusCode) {
            Log.error(
                "TwitchChatService: Chat send permanently rejected with HTTP \(statusCode)",
                category: .twitchChat)
            return .permanentFailure
        } catch HelixRequestError.retryableHTTP(let statusCode) {
            Log.warn(
                "TwitchChatService: Chat send transiently failed with HTTP \(statusCode)",
                category: .twitchChat)
            return .retryableFailure
        } catch {
            Log.error(
                "TwitchChatService: Failed to send message - \(error.localizedDescription)",
                category: .twitchChat)
            return .retryableFailure
        }
    }

    /// Applies the drop-oldest cap to a pending-message queue.
    ///
    /// Pure and `nonisolated` so it is unit-testable without spinning up the
    /// actor. Appends `pending` then trims the front until the queue is at most
    /// `cap` entries, returning the number of dropped (oldest) messages so the
    /// caller can log. With `cap <= 0` the queue ends up empty: the new
    /// element is appended, then trimmed away with everything else.
    nonisolated static func appendCapped<Element>(
        _ pending: Element, to queue: inout [Element], cap: Int
    ) -> Int {
        queue.append(pending)
        guard queue.count > cap else { return 0 }
        let overflow = queue.count - max(cap, 0)
        queue.removeFirst(overflow)
        return overflow
    }

    /// Pure decision for whether a just-failed send attempt should be requeued.
    ///
    /// `attempts` is the attempt number that just failed (1-based). The message
    /// is requeued only while `attempts < maxRetries`; once the count reaches the
    /// limit the message is dropped. `queueMessageForRetry` gates on it, and it is
    /// `nonisolated` so the bounded-retry contract is unit-testable without the
    /// actor or the network.
    nonisolated static func shouldRequeueAfterFailure(attempts: Int, maxRetries: Int) -> Bool {
        attempts < maxRetries
    }

    /// Queues a message for retry with exponential backoff.
    ///
    /// The queue is bounded by `AppConstants.Twitch.maxPendingMessages`
    /// (drop-oldest). A single long-lived drain loop (`pendingRetryTask`) walks
    /// the queue instead of one detached Task per retry.
    private func queueMessageForRetry(message: String, parentMessageID: String?, attempts: Int) {
        guard Self.shouldRequeueAfterFailure(attempts: attempts, maxRetries: maxMessageRetries) else {
            Log.error(
                "TwitchChatService: Message dropped after \(maxMessageRetries) retry attempts",
                category: .twitchChat)
            return
        }

        let pending = PendingMessage(
            message: message, parentMessageID: parentMessageID, attempts: attempts + 1)
        let dropped = Self.appendCapped(
            pending, to: &pendingMessages, cap: AppConstants.Twitch.maxPendingMessages)
        if dropped > 0 {
            Log.warn(
                "TwitchChatService: Retry queue full, dropped \(dropped) oldest message(s)",
                category: .twitchChat)
        }

        Log.debug(
            "TwitchChatService: Queued message retry \(attempts + 1)/\(maxMessageRetries) "
                + "(\(pendingMessages.count) pending)",
            category: .twitchChat)

        startRetryDrainLoopIfNeeded()
    }

    /// Starts the single long-lived drain loop if one is not already running.
    private func startRetryDrainLoopIfNeeded() {
        guard pendingRetryTask == nil else { return }
        pendingRetryGeneration &+= 1
        let generation = pendingRetryGeneration
        pendingRetryTask = Task { [weak self] in
            await self?.drainPendingMessages(generation: generation)
        }
    }

    /// Single long-lived drain loop. Walks the pending queue, sleeping per
    /// message according to that message's exponential backoff, until the queue
    /// drains. Exits (clearing `pendingRetryTask`) when empty so a future
    /// enqueue restarts it. Per-message attempt limits are preserved: the loop
    /// sends via `sendMessageOnce` (which never touches the queue) and, on
    /// failure, passes the current attempt count back through the queue helper
    /// (which stores the next count), dropping at `maxMessageRetries`. It must NOT call
    /// `sendMessage`, whose failure path requeues at `attempts: 0` and would
    /// reset the count, allowing unbounded retries.
    private func drainPendingMessages(generation: UInt64) async {
        defer {
            if pendingRetryGeneration == generation {
                pendingRetryTask = nil
            }
        }

        while !Task.isCancelled,
              pendingRetryGeneration == generation,
              !pendingMessages.isEmpty {
            let pending = pendingMessages.removeFirst()

            // Backoff is keyed off the prior attempt count. `attempts` here is
            // the next attempt number (1-based), so the delay matches the old
            // `pow(2, attempts)` schedule (attempt 1 -> 2^0 = 1s).
            let delay = pow(2.0, Double(pending.attempts - 1))
            do {
                try await Task.sleep(
                    for: .seconds(delay),
                    tolerance: .seconds(delay * 0.1))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  pendingRetryGeneration == generation,
                  !isProcessingDisconnect else { return }

            // Send without auto-queueing. On failure (missing credentials or a
            // failed request) requeue with the attempt count incremented, so a
            // persistently failing message stops at `maxMessageRetries` instead
            // of looping forever.
            let outcome = await sendMessageOnce(pending.message, replyTo: pending.parentMessageID)
            guard !Task.isCancelled,
                  pendingRetryGeneration == generation,
                  !isProcessingDisconnect else { return }
            if Self.shouldRetryChatSend(outcome) {
                queueMessageForRetry(
                    message: pending.message,
                    parentMessageID: pending.parentMessageID,
                    attempts: pending.attempts)
            }
        }
    }
}
