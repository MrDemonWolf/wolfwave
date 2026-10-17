//
//  TwitchChatService+Polls.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Vote-skip polls (create, subscribe, refresh) and stream online/offline
/// state handling.
extension TwitchChatService {

    // MARK: - Vote-Skip Polls

    /// Creates a native Twitch poll asking chat to vote on skipping the current song.
    ///
    /// Requires the `channel:manage:polls` scope and Affiliate/Partner status.
    /// A definitive rejection permits chat fallback; an ambiguous transport,
    /// server, rate-limit, or malformed-success result stays latched so WolfWave
    /// cannot accidentally run two voting mechanisms.
    ///
    /// - Parameters:
    ///   - title: Poll title; cut to Twitch's 60-character limit.
    ///   - durationSeconds: Clamped to Twitch's 15...1800 second range.
    /// - Returns: How the create request ended; see `skipPollCreationOutcome`.
    func createSkipPoll(
        title: String,
        durationSeconds: Int
    ) async -> SkipPollCreationOutcome {
        guard let broadcasterID,
              let token = oauthToken,
              let clientID else {
            Log.warn("TwitchChatService: Cannot create poll: missing credentials", category: .twitchEvents)
            return .definitiveFailure
        }

        guard let url = URL(string: apiBaseURL + "/polls") else {
            return .definitiveFailure
        }

        let duration = min(max(durationSeconds, 15), 1800)
        let body: [String: Any] = [
            "broadcaster_id": broadcasterID,
            "title": String(title.prefix(60)),
            "choices": [
                ["title": TwitchChatService.skipPollSkipChoice],
                ["title": TwitchChatService.skipPollKeepChoice]
            ],
            "duration": duration
        ]

        let request: URLRequest
        do {
            request = try HelixClient.buildRequest(
                url: url, method: "POST",
                credentials: .init(token: token, clientID: clientID), body: body)
        } catch {
            Log.error(
                "TwitchChatService: Failed to serialize poll body - \(error.localizedDescription)",
                category: .twitchEvents)
            return .definitiveFailure
        }

        do {
            let (data, http) = try await HTTPClient.shared.send(request)
            let outcome = Self.skipPollCreationOutcome(
                statusCode: http.statusCode,
                responseData: data)
            switch outcome {
            case .created(let pollID):
                Log.info(
                    "TwitchChatService: Vote-skip poll \(pollID) created",
                    category: .twitchEvents)
            case .definitiveFailure:
                let text = String(data: data, encoding: .utf8) ?? "No response"
                Log.warn(
                    "TwitchChatService: Poll creation rejected",
                    category: .twitchEvents,
                    fields: ["status": http.statusCode, "response": text])
            case .pollAlreadyActive:
                Log.info(
                    "TwitchChatService: Poll creation rejected because a native poll is already active",
                    category: .twitchEvents)
            case .indeterminate where (200..<300).contains(http.statusCode):
                Log.warn(
                    "TwitchChatService: Poll creation succeeded without a usable poll ID",
                    category: .twitchEvents)
            case .indeterminate:
                Log.warn(
                    "TwitchChatService: Poll creation status is unknown",
                    category: .twitchEvents,
                    fields: ["status": http.statusCode])
            }
            return outcome
        } catch {
            Log.error(
                "TwitchChatService: Poll creation request outcome is unknown - \(error.localizedDescription)",
                category: .twitchEvents)
            return .indeterminate
        }
    }

    /// Classifies create-poll results without conflating "rejected" with
    /// "Twitch may have accepted it." A missing status models transport failure.
    ///
    /// 2xx with a poll ID is created; 400 is "already active" or a definitive
    /// failure depending on the message; 401/403/404/422 are definitive;
    /// everything else (429, 5xx, 2xx without an ID) is indeterminate.
    nonisolated static func skipPollCreationOutcome(
        statusCode: Int?,
        responseData: Data?
    ) -> SkipPollCreationOutcome {
        guard let statusCode else { return .indeterminate }
        if (200..<300).contains(statusCode) {
            guard let responseData,
                  let pollID = skipPollID(from: responseData) else {
                return .indeterminate
            }
            return .created(id: pollID)
        }
        if statusCode == 400 {
            return isActivePollConflict(responseData)
                ? .pollAlreadyActive
                : .definitiveFailure
        }
        switch statusCode {
        case 401, 403, 404, 422:
            return .definitiveFailure
        default:
            return .indeterminate
        }
    }

    /// Twitch uses HTTP 400 both for ordinary validation rejection and for the
    /// special case where the broadcaster already has a poll running. Only the
    /// latter means chat fallback would overlap a live native poll.
    nonisolated static func isActivePollConflict(_ data: Data?) -> Bool {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String else {
            return false
        }
        let normalized = message.lowercased()
        return normalized.contains("poll")
            && normalized.contains("already")
            && (normalized.contains("active")
                || normalized.contains("running")
                || normalized.contains("in progress"))
    }

    /// Extracts the poll ID from Twitch's create-poll response.
    nonisolated static func skipPollID(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let polls = object["data"] as? [[String: Any]],
              let pollID = polls.first?["id"] as? String,
              !pollID.isEmpty else {
            return nil
        }
        return pollID
    }

    /// Subscribes to `channel.poll.end` so finished vote-skip polls can be tallied.
    ///
    /// Only when vote-skip and Polls mode are both on. At most one POST per
    /// session: `pollSubscriptionAttemptSessionID` blocks a concurrent second
    /// attempt and `pollSubscriptionSessionID` records success. A result that
    /// lands after the session changed is discarded.
    func subscribeToPollEvents(
        receiveContext: EventSubReceiveContext? = nil
    ) async {
        guard receiveContextIsCurrent(receiveContext) else { return }
        guard FeatureFlags.voteSkipEnabled,
              DefaultsStore.store.bool(forKey: AppConstants.UserDefaults.voteSkipUsePolls) else { return }

        guard let sessionID,
              let broadcasterID,
              let token = oauthToken,
              let clientID else {
            Log.warn(
                "TwitchChatService: Missing credentials for poll EventSub subscription",
                category: .twitchEvents)
            return
        }
        guard pollSubscriptionSessionID != sessionID,
              pollSubscriptionAttemptSessionID != sessionID else {
            return
        }
        pollSubscriptionAttemptSessionID = sessionID

        let body = Self.eventSubBody(
            type: "channel.poll.end", broadcasterID: broadcasterID, sessionID: sessionID)
        let subscribed: Bool
        if let pollSubscriptionOverride {
            subscribed = await pollSubscriptionOverride(sessionID)
        } else {
            subscribed = await postEventSubSubscription(
                body: body,
                token: token,
                clientID: clientID,
                label: "channel.poll.end",
                receiveContext: receiveContext
            )
        }
        guard pollSubscriptionAttemptSessionID == sessionID else { return }
        pollSubscriptionAttemptSessionID = nil
        guard receiveContextIsCurrent(receiveContext),
              subscribed,
              self.sessionID == sessionID else { return }
        pollSubscriptionSessionID = sessionID
    }

    /// Revalidates Polls scope and subscribes the current EventSub session when
    /// the setting is enabled after connection. Safe to call repeatedly.
    func refreshPollSubscriptionIfNeeded(enabled: Bool) async {
        guard enabled, sessionID != nil else { return }
        switch await validateLivePollScope() {
        case .present:
            await subscribeToPollEvents()
        case .missing:
            Log.warn(
                "TwitchChatService: Polls scope missing after live enable; reauthorization required",
                category: .twitchEvents)
            signalReauthNeededAndStop()
        case .indeterminate:
            Log.warn(
                "TwitchChatService: Polls scope refresh was inconclusive; keeping the current session",
                category: .twitchEvents)
        }
    }

    /// Narrow state injection used by focused live-toggle tests.
    func configurePollRefreshTestState(
        sessionID: String,
        scopeValidation: @escaping @Sendable () async -> PollScopeValidation,
        subscription: @escaping @Sendable (String) async -> Bool
    ) {
        self.sessionID = sessionID
        broadcasterID = "broadcaster"
        oauthToken = "token"
        clientID = "client"
        pollScopeValidationOverride = scopeValidation
        pollSubscriptionOverride = subscription
        pollSubscriptionSessionID = nil
        pollSubscriptionAttemptSessionID = nil
    }

    /// Test seam: the session the poll subscription is recorded against.
    func pollSubscriptionSessionForTesting() -> String? {
        pollSubscriptionSessionID
    }

    /// Updates `streamLive` from a `stream.online` / `stream.offline` event.
    func handleStreamStateNotification(type: String) {
        switch type {
        case "stream.online":
            // Anchor the "This stream" stats window before flipping `streamLive`
            // so a synchronous snapshot reader can never observe live=true with
            // a nil anchor. The event payload carries no start time here, so
            // the moment we're notified is close enough.
            streamLiveSince = Date()
            streamLive = true
            Log.info("TwitchChatService: Stream went live", category: .twitchEvents)
        case "stream.offline":
            streamLive = false
            streamLiveSince = nil
            Log.info("TwitchChatService: Stream went offline", category: .twitchEvents)
        default:
            Log.debug("TwitchChatService: Ignoring unexpected EventSub type: \(type)", category: .twitchEvents)
        }
    }
}
