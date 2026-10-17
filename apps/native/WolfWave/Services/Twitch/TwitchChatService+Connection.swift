//
//  TwitchChatService+Connection.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-07-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Network

/// Connection lifecycle: reachability monitoring, bounded reconnect backoff,
/// reactive 401 token refresh, the EventSub socket, the `session_welcome`
/// timeout, the keepalive watchdog, and the receive loop.
extension TwitchChatService {

    // MARK: - Reconnect Decisions

    /// What to do when the reconnect that follows a successful token refresh
    /// still fails.
    enum RefreshedReconnectFailureDisposition: Sendable, Equatable {
        /// A second 401: the refreshed token was rejected too; ask for re-auth.
        case authenticationFailure
        /// Anything else; resume the normal reconnect backoff.
        case retryableFailure
        /// The attempt was superseded; do nothing.
        case cancelled
    }

    /// Separates a second 401 from cancellation and transient connection errors
    /// after a reactive token refresh.
    nonisolated static func refreshedReconnectFailureDisposition(
        for error: Error
    ) -> RefreshedReconnectFailureDisposition {
        if error is CancellationError { return .cancelled }
        if let connectionError = error as? ConnectionError,
           case .authenticationFailed = connectionError {
            return .authenticationFailure
        }
        return .retryableFailure
    }

    /// True only while the rejected credential still owns both durable storage
    /// and the actor session that issued the request.
    func rejectedCredentialIsCurrent(
        _ expected: TwitchCredentialStore.AccessExpectation,
        clientID: String,
        generation: UInt64,
        broadcasterID expectedBroadcasterID: String?
    ) -> Bool {
        !Task.isCancelled
            && connectionAttemptIsCurrent(generation)
            && oauthToken == expected.accessToken
            && self.clientID == clientID
            && (expectedBroadcasterID == nil || broadcasterID == expectedBroadcasterID)
            && TwitchCredentialStore.shared.matches(expected)
    }

    /// Reconnect-specific ownership check used when no active OAuth actor field
    /// has been published yet.
    private func reconnectCredentialIsCurrent(
        _ expected: TwitchCredentialStore.AccessExpectation,
        channelName: String,
        clientID: String,
        generation: UInt64
    ) -> Bool {
        !Task.isCancelled
            && connectionAttemptIsCurrent(generation)
            && reconnectChannelName == channelName
            && reconnectToken == expected.accessToken
            && reconnectClientID == clientID
            && TwitchCredentialStore.shared.matches(expected)
    }

    /// CAS-adopts a persisted access-token rotation into the active and reconnect
    /// state. If a backoff task captured the old token, reschedule it so it cannot
    /// wake, fail its stale-configuration guard, and silently end recovery.
    ///
    /// - Parameters:
    ///   - refreshed: The new token, which must already be the stored grant.
    ///   - rejected: The token being replaced; must share `refreshed`'s revision.
    ///   - restartPendingReconnect: When `true`, a live socket on the old token
    ///     is dropped, and it or a pending backoff on the old token is replaced
    ///     by a fresh reconnect. Callers that reconnect on their own pass `false`.
    /// - Returns: `false` when the store no longer holds `refreshed`, or this
    ///   actor holds some third token (another account owns it now).
    @discardableResult
    func adoptRefreshedAccessCredential(
        _ refreshed: TwitchCredentialStore.AccessExpectation,
        replacing rejected: TwitchCredentialStore.AccessExpectation,
        restartPendingReconnect: Bool = true
    ) -> Bool {
        guard refreshed.revision == rejected.revision,
              TwitchCredentialStore.shared.matches(refreshed) else {
            return false
        }

        let ownsRejected = oauthToken == rejected.accessToken
            || reconnectToken == rejected.accessToken
        let alreadyAdopted = oauthToken == refreshed.accessToken
            || reconnectToken == refreshed.accessToken
        guard ownsRejected || alreadyAdopted
                || (oauthToken == nil && reconnectToken == nil) else {
            return false
        }

        let hadPendingReconnect = reconnectTask != nil
            && reconnectToken == rejected.accessToken
        let hadLiveSession = webSocketTask != nil
            && oauthToken == rejected.accessToken
        if oauthToken == rejected.accessToken {
            oauthToken = refreshed.accessToken
        }
        if reconnectToken == rejected.accessToken {
            reconnectToken = refreshed.accessToken
        }
        if restartPendingReconnect && (hadPendingReconnect || hadLiveSession) {
            if hadLiveSession {
                // EventSub subscriptions are authorized for the token/session
                // pair that created them. A rotation starts a fresh generation.
                disconnectFromEventSub()
            }
            if isNetworkReachable { scheduleReconnect() }
        }
        return true
    }

    /// Adopts a stored rotation only when it still belongs to the actor's
    /// authorized chat user; broadcaster ownership is checked separately. A
    /// different or unresolved account remains disconnected so an old socket cannot outlive credential replacement.
    ///
    /// - Returns: `true` when the reconnect token already matches the stored
    ///   grant for this user, or the stored rotation was adopted.
    func prepareCurrentStoredCredentialForReconnect(
        replacing staleToken: String,
        clientID: String,
        broadcasterID: String,
        authorizedUserID: String
    ) -> Bool {
        guard self.clientID == clientID,
              self.broadcasterID == broadcasterID,
              botID == authorizedUserID else { return false }
        let reconnectCandidate = reconnectToken ?? staleToken
        if let matching = TwitchCredentialStore.shared.connectionSnapshot(
            matchingAccessToken: reconnectCandidate),
           matching.userID == authorizedUserID {
            return true
        }
        guard let current = TwitchCredentialStore.shared.connectionSnapshot(),
              current.userID == authorizedUserID else { return false }
        let stale = TwitchCredentialStore.AccessExpectation(
            revision: current.revision,
            accessToken: staleToken)
        return adoptRefreshedAccessCredential(
            current.accessExpectation,
            replacing: stale,
            restartPendingReconnect: false)
    }

    /// Runs the shared credential-keyed refresh decision for a 401 emitted by
    /// live chat or EventSub HTTP work. Every post-await result is revalidated
    /// before it may mutate actor state or authorize re-auth.
    ///
    /// - Returns: The refresh result when it still applies to this session
    ///   (a `.refreshed` token has already been adopted). `nil` when the work
    ///   was cancelled, superseded, or the account changed meanwhile; the
    ///   caller must then do nothing.
    func recoverRejectedAccessToken(
        _ expected: TwitchCredentialStore.AccessExpectation,
        clientID: String,
        generation: UInt64,
        broadcasterID expectedBroadcasterID: String?
    ) async -> TwitchTokenRefresher.RefreshResult? {
        guard rejectedCredentialIsCurrent(
            expected,
            clientID: clientID,
            generation: generation,
            broadcasterID: expectedBroadcasterID
        ) else { return nil }

        let result: TwitchTokenRefresher.RefreshResult
        do {
            result = try await reactiveTokenRefresh(clientID, expected: expected)
        } catch is CancellationError {
            return nil
        } catch {
            result = .temporarilyUnavailable
        }

        switch result {
        case .refreshed(let refreshedToken):
            let refreshed = expected.replacingAccessToken(refreshedToken)
            guard !Task.isCancelled,
                  connectionAttemptIsCurrent(generation),
                  oauthToken == expected.accessToken,
                  self.clientID == clientID,
                  expectedBroadcasterID == nil
                    || broadcasterID == expectedBroadcasterID,
                  TwitchCredentialStore.shared.matches(refreshed) else {
                return nil
            }
            guard adoptRefreshedAccessCredential(
                refreshed,
                replacing: expected,
                restartPendingReconnect: false
            ) else { return nil }
            return result
        case .invalid, .temporarilyUnavailable:
            guard rejectedCredentialIsCurrent(
                expected,
                clientID: clientID,
                generation: generation,
                broadcasterID: expectedBroadcasterID
            ) else { return nil }
            return result
        case .superseded:
            return nil
        }
    }

    // MARK: - Network Monitoring

    /// Starts monitoring network connectivity and sets up automatic reconnection.
    ///
    /// Path updates arrive on `networkMonitorQueue`. They are funneled through
    /// one `AsyncStream` drained by a single consumer task, so the actor applies
    /// them in the order the monitor reported them. Spawning one `Task` per
    /// update gave no ordering guarantee: on a fast flap (Wi-Fi roam, VPN
    /// switch) a stale "unreachable" could land last and leave
    /// `isNetworkReachable` false while the network was up, suppressing every
    /// reconnect until the next path event.
    func startNetworkMonitoring() {
        stopNetworkMonitoring()

        let (stream, continuation) = AsyncStream.makeStream(
            of: Bool.self, bufferingPolicy: .unbounded)
        let monitor = NWPathMonitor()
        networkPathMonitor = monitor
        monitor.pathUpdateHandler = { path in
            continuation.yield(path.status == .satisfied)
        }
        startNetworkPathConsumer(stream: stream, continuation: continuation)

        monitor.start(queue: networkMonitorQueue)
    }

    /// Tears down the path monitor and its ordered consumer, and invalidates any
    /// update still in flight from them. Safe to call when nothing is running.
    func stopNetworkMonitoring() {
        networkPathMonitor?.pathUpdateHandler = nil
        networkPathMonitor?.cancel()
        networkPathMonitor = nil
        networkPathContinuation?.finish()
        networkPathContinuation = nil
        networkPathTask?.cancel()
        networkPathTask = nil
        networkMonitorGeneration &+= 1
    }

    /// Starts the single task that applies reachability values in arrival order.
    ///
    /// The task captures `self` weakly so it never keeps the actor alive; it ends
    /// when the stream finishes (teardown or `deinit`) or the actor is gone.
    func startNetworkPathConsumer(
        stream: AsyncStream<Bool>,
        continuation: AsyncStream<Bool>.Continuation
    ) {
        let generation = networkMonitorGeneration
        networkPathContinuation = continuation
        networkPathTask = Task { [weak self] in
            for await isReachable in stream {
                guard let self else { return }
                await self.applyNetworkPathReachability(isReachable, generation: generation)
            }
        }
    }

    /// Applies one path update unless its monitor has since been replaced or
    /// torn down.
    private func applyNetworkPathReachability(_ isReachable: Bool, generation: UInt64) async {
        guard generation == networkMonitorGeneration else { return }
        await handleNetworkReachabilityChange(isReachable)
    }

    /// Handles a reachability change and triggers reconnection if needed.
    ///
    /// Rate-limits network-triggered reconnects to prevent infinite loops when
    /// the network path flaps rapidly between available/unavailable states.
    ///
    /// Boolean seam shared by the path monitor and lifecycle tests.
    func handleNetworkReachabilityChange(_ isReachable: Bool) async {
        let wasReachable = isNetworkReachable
        isNetworkReachable = isReachable

        if !wasReachable && isReachable {
            let now = Date().timeIntervalSince1970
            // Reset cycle counter if enough time has passed
            if now - lastNetworkReconnectTime > AppConstants.Twitch.networkReconnectCooldown {
                networkReconnectCycles = 0
            }

            guard networkReconnectCycles < maxNetworkReconnectCycles else {
                Log.error(
                    "TwitchChatService: Max network reconnect cycles reached, not reconnecting",
                    category: .twitchEvents)
                return
            }

            networkReconnectCycles += 1
            lastNetworkReconnectTime = now
            // An accepted network-recovery cycle gets its own bounded attempt
            // budget. Without this reset, a prior exhausted transport cycle
            // could never recover after connectivity actually returned.
            reconnectionAttempts = 0
            scheduleReconnect()
        } else if wasReachable && !isReachable {
            Log.warn("TwitchChatService: Network unavailable, disconnecting", category: .twitchEvents)
            // Do this before tearing down the socket so a delayed backoff task
            // cannot wake and consume an attempt while the machine is offline.
            reconnectTask?.cancel()
            reconnectTask = nil
            disconnectFromEventSub()
        }
    }

    // MARK: - Reconnection

    /// Schedules a reconnection attempt with exponential backoff. Cancels any
    /// existing scheduled attempt so we never have two pending at once.
    ///
    /// Delays are 1, 2, 4, 8, 16 s (capped). Once `maxReconnectionAttempts` is
    /// reached it keeps trying every 60-65 s and tells the UI it is still
    /// retrying. No-op during credential teardown, while offline, while
    /// re-auth is needed, or when there is no channel to rejoin.
    func scheduleReconnect() {
        guard !eventSubTeardownQuiescing.value else { return }
        guard isNetworkReachable, !Preferences.twitchReauthNeeded else { return }
        guard let channelName = reconnectChannelName,
              let token = reconnectToken,
              let clientID = reconnectClientID else {
            Log.debug("TwitchChatService: Cannot reconnect - missing credentials", category: .twitchEvents)
            return
        }

        let attempts = reconnectionAttempts

        if attempts >= maxReconnectionAttempts {
            Log.error(
                "TwitchChatService: Max reconnection attempts reached",
                category: .twitchEvents,
                fields: ["limit": maxReconnectionAttempts])
            broadcastConnectionState(
                false,
                error: "Twitch is still unavailable. Retrying in about a minute.")
        }

        // Exponential backoff: 1s, 2s, 4s, 8s, 16s
        let delaySeconds = attempts >= maxReconnectionAttempts
            ? 60 + Double.random(in: 0...5)
            : min(pow(2.0, Double(attempts)), 16.0)

        Log.info(
            "TwitchChatService: Scheduling reconnection",
            category: .twitchEvents,
            fields: [
                "attempt": attempts + 1,
                "limit": maxReconnectionAttempts,
                "after": String(format: "%.1fs", delaySeconds)
            ])

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            // Backoff timing tolerates 10% jitter, lets the wakeup coalesce.
            try? await Task.sleep(for: .seconds(delaySeconds), tolerance: .seconds(delaySeconds * 0.1))
            if Task.isCancelled { return }
            await self?.attemptReconnect(channelName: channelName, token: token, clientID: clientID)
        }
    }

    /// A wake starts a fresh fast tier without changing credential ownership.
    func handleSystemWake() {
        reconnectionAttempts = 0
        networkReconnectCycles = 0
        lastNetworkReconnectTime = 0
        if !isConnected, isNetworkReachable { scheduleReconnect() }
    }

    /// Body of a scheduled reconnect. Rechecks that the captured channel and
    /// credentials are still the configured ones, then runs `connectToChannel`
    /// under a fresh attempt generation. A 401 goes to the one-shot refresh
    /// path; other failures reschedule while the network is up.
    private func attemptReconnect(channelName: String, token: String, clientID: String) async {
        guard !Task.isCancelled else {
            Log.debug(
                "TwitchChatService: Scheduled reconnect cancelled before starting",
                category: .twitchEvents)
            return
        }
        guard !isProcessingDisconnect else {
            Log.debug(
                "TwitchChatService: Disconnect in progress, skipping scheduled reconnect",
                category: .twitchEvents)
            return
        }
        guard reconnectChannelName == channelName,
              reconnectToken == token,
              reconnectClientID == clientID else {
            Log.info(
                "TwitchChatService: Connection configuration changed, skipping stale reconnect",
                category: .twitchEvents)
            return
        }
        guard isNetworkReachable else {
            Log.info(
                "TwitchChatService: Network unavailable, skipping scheduled reconnect",
                category: .twitchEvents)
            return
        }
        guard let expected = TwitchCredentialStore.shared
            .connectionSnapshot(
                matchingAccessToken: token
            )?.accessExpectation else {
            Log.info(
                "TwitchChatService: Stored credential changed, skipping stale reconnect",
                category: .twitchEvents)
            return
        }
        let attemptNumber = min(reconnectionAttempts + 1, maxReconnectionAttempts)
        reconnectionAttempts = attemptNumber
        let generation = beginConnectionAttempt()

        do {
            try await connectToChannel(
                channelName: channelName,
                token: token,
                clientID: clientID,
                attemptGeneration: generation)
            Log.info(
                "TwitchChatService: Reconnection transport started, awaiting session_welcome",
                category: .twitchEvents,
                fields: ["attempt": attemptNumber, "limit": maxReconnectionAttempts])
        } catch ConnectionError.authenticationFailed {
            guard !Task.isCancelled, connectionAttemptIsCurrent(generation) else { return }
            // A 401 means the stored token is dead. Retrying with the same token
            // only burns `maxReconnectionAttempts` and never succeeds, so stop the
            // loop and surface the re-auth banner. Try one reactive token refresh
            // first; only fall back to interactive re-auth when that fails.
            Log.error(
                "TwitchChatService: Reconnect failed with 401; token is invalid or expired",
                category: .twitchEvents)
            await handleAuthenticationFailureDuringReconnect(
                expected: expected,
                channelName: channelName,
                clientID: clientID,
                attemptGeneration: generation)
        } catch is CancellationError {
            // A leave or newer connection attempt deliberately superseded this one.
            return
        } catch {
            guard connectionAttemptIsCurrent(generation) else { return }
            Log.warn(
                "TwitchChatService: Reconnection attempt failed",
                category: .twitchEvents,
                fields: ["attempt": attemptNumber, "error": error.localizedDescription])
            if isNetworkReachable {
                scheduleReconnect()
            } else if !isNetworkReachable {
                Log.info(
                    "TwitchChatService: Network no longer reachable, stopping reconnection attempts",
                    category: .twitchEvents)
            }
        }
    }

    /// Handles a 401 during reconnect. Attempts exactly ONE reactive token
    /// refresh (no loop). A second 401 signals interactive re-auth; a non-auth
    /// connection failure resumes the existing bounded reconnect backoff.
    private func handleAuthenticationFailureDuringReconnect(
        expected: TwitchCredentialStore.AccessExpectation,
        channelName: String,
        clientID: String,
        attemptGeneration: UInt64
    ) async {
        guard reconnectCredentialIsCurrent(
            expected,
            channelName: channelName,
            clientID: clientID,
            generation: attemptGeneration
        ) else { return }

        let refreshResult: TwitchTokenRefresher.RefreshResult
        do {
            refreshResult = try await reactiveTokenRefresh(
                clientID,
                expected: expected
            )
        } catch is CancellationError {
            return
        } catch {
            refreshResult = .temporarilyUnavailable
        }

        switch refreshResult {
        case .refreshed(let refreshedToken):
            let refreshed = expected.replacingAccessToken(refreshedToken)
            guard !Task.isCancelled,
                  connectionAttemptIsCurrent(attemptGeneration),
                  reconnectChannelName == channelName,
                  reconnectToken == expected.accessToken,
                  reconnectClientID == clientID,
                  TwitchCredentialStore.shared.matches(refreshed),
                  adoptRefreshedAccessCredential(
                    refreshed,
                    replacing: expected,
                    restartPendingReconnect: false
                  ) else { return }

            Log.info(
                "TwitchChatService: Reactive token refresh succeeded; reconnecting",
                category: .twitchEvents)
            let refreshedGeneration = beginConnectionAttempt()
            do {
                try await connectToChannel(
                    channelName: channelName,
                    token: refreshedToken,
                    clientID: clientID,
                    attemptGeneration: refreshedGeneration)
                Log.info(
                    "TwitchChatService: Reconnection transport started after token refresh; awaiting session_welcome",
                    category: .twitchEvents)
                return
            } catch {
                guard reconnectCredentialIsCurrent(
                    refreshed,
                    channelName: channelName,
                    clientID: clientID,
                    generation: refreshedGeneration
                ) else { return }
                switch Self.refreshedReconnectFailureDisposition(for: error) {
                case .cancelled:
                    return
                case .authenticationFailure:
                    Log.error(
                        "TwitchChatService: Refreshed token was rejected with 401",
                        category: .twitchEvents)
                    signalReauthNeededAndStop()
                    return
                case .retryableFailure:
                    Log.warn(
                        "TwitchChatService: Reconnect after refresh failed transiently - "
                            + error.localizedDescription,
                        category: .twitchEvents)
                    if isNetworkReachable {
                        scheduleReconnect()
                    } else if !isNetworkReachable {
                        Log.info(
                            "TwitchChatService: Network no longer reachable, "
                                + "stopping reconnection attempts",
                            category: .twitchEvents)
                    }
                    return
                }
            }
        case .invalid:
            guard reconnectCredentialIsCurrent(
                expected,
                channelName: channelName,
                clientID: clientID,
                generation: attemptGeneration
            ) else { return }
            signalReauthNeededAndStop()
        case .temporarilyUnavailable:
            guard reconnectCredentialIsCurrent(
                expected,
                channelName: channelName,
                clientID: clientID,
                generation: attemptGeneration
            ) else { return }
            Log.warn(
                "TwitchChatService: Token refresh temporarily unavailable; keeping credentials",
                category: .twitchEvents
            )
            if isNetworkReachable {
                scheduleReconnect()
            }
        case .superseded:
            return
        }
    }

}
