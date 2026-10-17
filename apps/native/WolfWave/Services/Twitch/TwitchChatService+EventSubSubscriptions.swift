//
//  TwitchChatService+EventSubSubscriptions.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// EventSub subscription POSTs that follow a fresh welcome: chat messages,
/// stream events, the live-state seed, and conflicting-subscription cleanup.
extension TwitchChatService {

    // MARK: - EventSub Subscriptions

    /// Builds a version-1 EventSub subscription body over the WebSocket
    /// transport. The `condition` always carries `broadcaster_user_id`; pass
    /// `extraCondition` for events (e.g. `channel.chat.message`) that need more
    /// condition keys. Serialized via `JSONSerialization`, so key order is
    /// irrelevant. Centralizes the version/transport scaffolding every
    /// subscription otherwise hand-builds.
    nonisolated static func eventSubBody(
        type: String,
        broadcasterID: String,
        sessionID: String,
        extraCondition: [String: String] = [:]
    ) -> [String: Any] {
        var condition: [String: String] = ["broadcaster_user_id": broadcasterID]
        condition.merge(extraCondition) { _, new in new }
        return [
            "type": type,
            "version": "1",
            "condition": condition,
            "transport": ["method": "websocket", "session_id": sessionID]
        ]
    }

    /// Subscribes to the channel.chat.message EventSub event.
    ///
    /// This subscription is what makes a session usable. On failure the socket
    /// is always torn down. A 401 first tries one token refresh; a definitive
    /// invalid token asks for re-auth, otherwise a reconnect is scheduled if
    /// the stored grant still belongs to the same user.
    ///
    /// - Returns: `true` when Twitch accepted the subscription.
    @discardableResult
    func subscribeToChannelChatMessage(
        receiveContext: EventSubReceiveContext? = nil
    ) async -> Bool {
        guard receiveContextIsCurrent(receiveContext) else { return false }
        guard let sessionID,
              let broadcasterID,
              let botID,
              let token = oauthToken,
              let clientID else {
            Log.error(
                "TwitchChatService: Missing credentials for EventSub subscription",
                category: .twitchEvents)
            disconnectFromEventSub()
            return false
        }

        let body = Self.eventSubBody(
            type: "channel.chat.message",
            broadcasterID: broadcasterID,
            sessionID: sessionID,
            extraCondition: ["user_id": botID])

        // Shares the EventSub POST scaffolding with every other subscription.
        // The chat subscription is the critical one: its extra success
        // side-effect is the connection confirmation message, and a failure
        // tears the connection back down.
        let expectedCredential = TwitchCredentialStore.shared
            .connectionSnapshot(
                matchingAccessToken: token
            )?.accessExpectation
        var failureStatus: Int?
        let subscribed = await postEventSubSubscription(
            body: body,
            token: token,
            clientID: clientID,
            label: "channel.chat.message",
            receiveContext: receiveContext,
            onSuccess: {
                Log.info("TwitchChatService: Connected to chat", category: .twitchEvents)
                if shouldSendConnectionMessageOnSubscribe {
                    sendConnectionMessage()
                }
            },
            onFailureStatus: { status in
                failureStatus = status
            }
        )

        guard receiveContextIsCurrent(receiveContext) else { return false }
        guard !subscribed else { return true }

        if failureStatus == 401 {
            let generation = receiveContext?.generation ?? connectionGeneration
            Log.error(
                "TwitchChatService: Chat subscription returned 401; attempting token refresh",
                category: .twitchEvents)
            if let expectedCredential {
                let recovery = await recoverRejectedAccessToken(
                    expectedCredential,
                    clientID: clientID,
                    generation: generation,
                    broadcasterID: broadcasterID
                )
                guard receiveContextIsCurrent(receiveContext) else { return false }
                if case .invalid? = recovery {
                    signalReauthNeededAndStop()
                    return false
                }
            }
        }

        let reconnectCredentialIsReady = prepareCurrentStoredCredentialForReconnect(
            replacing: token,
            clientID: clientID,
            broadcasterID: broadcasterID,
            authorizedUserID: botID)
        // No welcomed socket may survive without the critical chat subscription.
        // If the stored grant rotated for this broadcaster, adopt it before
        // scheduling; a different/unresolved account remains disconnected.
        disconnectFromEventSub()
        if reconnectCredentialIsReady, isNetworkReachable { scheduleReconnect() }
        return false
    }

    #if DEBUG
    /// Test seam for the private chat subscription path.
    func subscribeToChannelChatMessageForTesting(
        receiveContext: EventSubReceiveContext
    ) async -> Bool {
        await subscribeToChannelChatMessage(receiveContext: receiveContext)
    }
    #endif

    /// Subscribes to `stream.online` / `stream.offline` so `streamLive` stays current.
    func subscribeToStreamEvents(
        receiveContext: EventSubReceiveContext? = nil
    ) async {
        guard receiveContextIsCurrent(receiveContext) else { return }
        guard let sessionID,
              let broadcasterID,
              let token = oauthToken,
              let clientID else { return }

        for eventType in ["stream.online", "stream.offline"] {
            let body = Self.eventSubBody(
                type: eventType, broadcasterID: broadcasterID, sessionID: sessionID)
            await postEventSubSubscription(
                body: body,
                token: token,
                clientID: clientID,
                label: eventType,
                receiveContext: receiveContext
            )
            guard receiveContextIsCurrent(receiveContext) else { return }
        }
    }

    /// Seeds `streamLive` with a single Helix "Get Streams" call.
    ///
    /// Twitch returns an empty list when the channel is offline. On a request
    /// failure the current state is left as is.
    func seedStreamLiveState(
        receiveContext: EventSubReceiveContext? = nil
    ) async {
        guard receiveContextIsCurrent(receiveContext) else { return }
        guard let broadcasterID,
              let token = oauthToken,
              let clientID,
              var components = URLComponents(string: apiBaseURL + "/streams") else { return }
        components.queryItems = [URLQueryItem(name: "user_id", value: broadcasterID)]
        guard let url = components.url else { return }

        do {
            let response: HelixStreamsResponse = try await HTTPClient.shared.get(
                url: url,
                headers: HelixClient.headers(for: .init(token: token, clientID: clientID)))
            guard receiveContextIsCurrent(receiveContext) else { return }
            let live = !response.data.isEmpty
            // Anchor "This stream" to the real start time when available, else now.
            // The anchor is set before `streamLive` flips true (and cleared after
            // it flips false) so snapshot readers never see live=true with no anchor.
            if live {
                let startedAt = response.data.first?.startedAt
                    .flatMap { SharedFormatters.iso8601.date(from: $0) }
                streamLiveSince = startedAt ?? Date()
                streamLive = true
            } else {
                streamLive = false
                streamLiveSince = nil
            }
            Log.info("TwitchChatService: Seeded stream-live state: live=\(live)", category: .twitchEvents)
        } catch {
            guard receiveContextIsCurrent(receiveContext) else { return }
            Log.debug(
                "TwitchChatService: Stream-live seed request failed - \(error.localizedDescription)",
                category: .twitchEvents)
        }
    }

    /// Posts an EventSub subscription request. Logs success/failure and updates
    /// redemption status on 403 (scope) / non-2xx (subscribeFailed).
    ///
    /// A 409 is not success for WebSocket transport: the existing subscription
    /// may belong to the superseded socket. Twitch includes that subscription's
    /// exact ID in the error body, so delete it and retry the POST once.
    ///
    /// - Parameters:
    ///   - label: Name used in logs. The exact labels `"channel-point
    ///     redemptions"` and `"bit usage"` also drive the redemption status
    ///     banner, so keep them in sync with the callers.
    ///   - onSuccess: Side effect run once on a 2xx response. Defaults to a
    ///     no-op; `subscribeToChannelChatMessage` uses it to send the connection
    ///     confirmation message.
    ///   - onFailureStatus: Receives the HTTP status of a rejected POST, or of
    ///     a failed conflict DELETE. Not called for transport errors.
    /// - Returns: `true` only after Twitch accepts the subscription POST.
    @discardableResult
    func postEventSubSubscription(
        body: [String: Any],
        token: String,
        clientID: String,
        label: String,
        receiveContext: EventSubReceiveContext? = nil,
        onSuccess: () -> Void = {},
        onFailureStatus: (Int) -> Void = { _ in }
    ) async -> Bool {
        guard receiveContextIsCurrent(receiveContext) else { return false }
        guard let url = URL(string: apiBaseURL + "/eventsub/subscriptions") else { return false }

        var recoveredConflict = false
        while true {
            let request: URLRequest
            do {
                request = try HelixClient.buildRequest(
                    url: url, method: "POST",
                    credentials: .init(token: token, clientID: clientID), body: body)
            } catch {
                guard receiveContextIsCurrent(receiveContext) else { return false }
                Log.error(
                    "TwitchChatService: Failed to serialize \(label) subscription - \(error.localizedDescription)",
                    category: .twitchEvents)
                return false
            }

            do {
                let (data, http) = try await eventSubHTTPClient.send(request)
                guard receiveContextIsCurrent(receiveContext) else { return false }
                if (200..<300).contains(http.statusCode) {
                    Log.info("TwitchChatService: Subscribed to \(label)", category: .twitchEvents)
                    onSuccess()
                    return true
                }
                if http.statusCode == 409,
                   !recoveredConflict,
                   let conflictingID = Self.conflictingSubscriptionID(from: data) {
                    recoveredConflict = true
                    let removed = await deleteConflictingEventSubSubscription(
                        id: conflictingID,
                        token: token,
                        clientID: clientID,
                        receiveContext: receiveContext,
                        onFailureStatus: onFailureStatus)
                    guard receiveContextIsCurrent(receiveContext), removed else { return false }
                    continue
                }

                let responseText = String(data: data, encoding: .utf8) ?? "No response"
                Log.error(
                    "TwitchChatService: EventSub subscription failed",
                    category: .twitchEvents,
                    fields: [
                        "subscription": label,
                        "status": http.statusCode,
                        "response": responseText
                    ])
                if label == "channel-point redemptions" || label == "bit usage" {
                    setRedemptionStatus(http.statusCode == 403 ? .scopeMissing : .subscribeFailed)
                }
                onFailureStatus(http.statusCode)
                return false
            } catch {
                guard receiveContextIsCurrent(receiveContext) else { return false }
                Log.error(
                    "TwitchChatService: \(label) subscription error - \(error.localizedDescription)",
                    category: .twitchEvents)
                return false
            }
        }
    }

    /// Twitch's Create EventSub 409 response exposes the conflicting
    /// subscription as a top-level `id`. Tolerate the regular `data[0].id`
    /// envelope too so mocked/local Twitch-compatible endpoints work as well.
    nonisolated static func conflictingSubscriptionID(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let candidate = (json["id"] as? String)
            ?? ((json["data"] as? [[String: Any]])?.first?["id"] as? String)
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Deletes the subscription named in a 409 so the POST can be retried.
    ///
    /// - Returns: `true` on 204, or 404 (already gone).
    private func deleteConflictingEventSubSubscription(
        id: String,
        token: String,
        clientID: String,
        receiveContext: EventSubReceiveContext?,
        onFailureStatus: (Int) -> Void
    ) async -> Bool {
        guard receiveContextIsCurrent(receiveContext),
              var components = URLComponents(string: apiBaseURL + "/eventsub/subscriptions") else {
            return false
        }
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        guard let url = components.url else { return false }

        do {
            let request = try HelixClient.buildRequest(
                url: url,
                method: "DELETE",
                credentials: .init(token: token, clientID: clientID))
            let (_, response) = try await eventSubHTTPClient.send(request)
            guard receiveContextIsCurrent(receiveContext) else { return false }
            if response.statusCode == 204 || response.statusCode == 404 {
                Log.info(
                    "TwitchChatService: Removed conflicting EventSub subscription \(id)",
                    category: .twitchEvents)
                return true
            }
            onFailureStatus(response.statusCode)
            Log.error(
                "TwitchChatService: Could not remove conflicting EventSub subscription",
                category: .twitchEvents,
                fields: ["status": response.statusCode])
            return false
        } catch {
            guard receiveContextIsCurrent(receiveContext) else { return false }
            Log.error(
                "TwitchChatService: Conflicting EventSub delete failed - \(error.localizedDescription)",
                category: .twitchEvents)
            return false
        }
    }
}
