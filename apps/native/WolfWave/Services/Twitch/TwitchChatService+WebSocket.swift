//
//  TwitchChatService+WebSocket.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// The EventSub socket: connect / disconnect, the `session_welcome`
/// timeout, the keepalive watchdog, and the receive loop.
extension TwitchChatService {

    // MARK: - WebSocket Management

    /// Default Twitch EventSub WebSocket endpoint.
    private static let defaultEventSubURL = "wss://eventsub.wss.twitch.tv/ws"

    /// Connects to a Twitch EventSub WebSocket endpoint.
    ///
    /// - Parameter urlString: Endpoint to connect to. Defaults to the standard
    ///   EventSub URL; a `session_reconnect` migration passes the server-provided
    ///   `reconnect_url` instead so subscriptions carry over to the new session.
    func connectToEventSub(urlString: String = TwitchChatService.defaultEventSubURL) {
        guard !eventSubTeardownQuiescing.value else { return }
        guard let url = URL(string: urlString) else {
            Log.error("TwitchChatService: Invalid EventSub URL", category: .twitchEvents)
            disconnectFromEventSub()
            return
        }

        // Defensively cancel any pre-existing task before reassigning. Call
        // paths currently route through `disconnectFromEventSub()` first, but a
        // direct double-connect would otherwise orphan a live task.
        webSocketTask?.cancel(with: .goingAway, reason: nil)

        let task = eventSubWebSocketFactory?(url) ?? urlSession.webSocketTask(with: url)
        webSocketTask = task

        Log.info("TwitchChatService: Starting EventSub WebSocket connection", category: .twitchEvents)
        eventSubWebSocketResume(task)

        startSessionWelcomeTimeout(
            receiveContext: EventSubReceiveContext(
                generation: connectionGeneration,
                webSocketTask: task
            )
        )
        startReceiveLoop()
    }

    /// Starts a timeout task that fires if `session_welcome` doesn't arrive in time.
    private func startSessionWelcomeTimeout(receiveContext: EventSubReceiveContext) {
        sessionWelcomeTask?.cancel()
        sessionWelcomeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AppConstants.Twitch.sessionWelcomeTimeout))
            if Task.isCancelled { return }
            await self?.handleSessionWelcomeTimeout(receiveContext: receiveContext)
        }
    }

    /// Cancels the session welcome timeout.
    func cancelSessionWelcomeTimeout() {
        sessionWelcomeTask?.cancel()
        sessionWelcomeTask = nil
    }

    // MARK: - Keepalive Watchdog

    /// Arms one watchdog for the EventSub session. Subsequent inbound frames move
    /// the monotonic activity timestamp; they do not cancel/recreate the task.
    func armKeepaliveWatchdog(deadlineSeconds: TimeInterval) {
        keepaliveDeadlineSeconds = Self.normalizedKeepaliveDeadline(deadlineSeconds)
        let clock = ContinuousClock()
        lastKeepaliveActivity = clock.now

        guard keepaliveWatchdogTask == nil else { return }
        keepaliveGeneration &+= 1
        let generation = keepaliveGeneration
        keepaliveWatchdogTaskStarts += 1
        keepaliveWatchdogTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let snapshot = await self?.keepaliveSleepSnapshot(generation: generation) else {
                    return
                }
                do {
                    try await clock.sleep(
                        until: snapshot.deadline,
                        tolerance: .seconds(snapshot.tolerance))
                } catch {
                    return
                }
                if Task.isCancelled { return }

                // Validate the session generation and expiry in one actor hop.
                // Cancellation alone is cooperative: a superseded task may have
                // passed its local check just before a new socket was armed.
                guard let shouldStop = await self?.handleKeepaliveExpiry(
                    generation: generation,
                    at: clock.now
                ) else { return }
                if shouldStop { return }
            }
        }
    }

    /// Records proof of life in O(1). No-op until `session_welcome` arms the
    /// watchdog.
    func resetKeepaliveWatchdog() {
        guard keepaliveWatchdogTask != nil else { return }
        lastKeepaliveActivity = ContinuousClock().now
    }

    /// Where the watchdog should sleep until: last activity plus the deadline,
    /// with up to 10% (max 1 s) timer tolerance. `nil` tells a superseded
    /// watchdog to exit.
    private func keepaliveSleepSnapshot(generation: UInt64) -> (
        deadline: ContinuousClock.Instant,
        tolerance: TimeInterval
    )? {
        guard generation == keepaliveGeneration,
              let lastKeepaliveActivity else { return nil }
        let deadlineSeconds = Self.normalizedKeepaliveDeadline(keepaliveDeadlineSeconds)
        return (
            lastKeepaliveActivity.advanced(by: .seconds(deadlineSeconds)),
            min(1, deadlineSeconds * 0.1)
        )
    }

    /// Cancels the keepalive watchdog.
    func cancelKeepaliveWatchdog() {
        keepaliveGeneration &+= 1
        keepaliveWatchdogTask?.cancel()
        keepaliveWatchdogTask = nil
        lastKeepaliveActivity = nil
    }

    /// Called when no frame arrived before the keepalive deadline. Treated like a
    /// transport error: tear down and reconnect fresh (which re-subscribes).
    /// Returns `true` when the calling watchdog must terminate. A stale
    /// generation terminates without touching the current socket.
    func handleKeepaliveExpiry(
        generation: UInt64,
        at now: ContinuousClock.Instant
    ) -> Bool {
        guard generation == keepaliveGeneration else { return true }
        guard let snapshot = keepaliveSleepSnapshot(generation: generation) else { return true }
        guard now >= snapshot.deadline else { return false }

        Log.warn(
            "TwitchChatService: Keepalive watchdog fired, reconnecting",
            category: .twitchEvents,
            fields: ["seconds": Int(keepaliveDeadlineSeconds)])
        disconnectFromEventSub()

        if let channelName = reconnectChannelName,
           let token = reconnectToken,
           let clientID = reconnectClientID,
           !channelName.isEmpty, !token.isEmpty, !clientID.isEmpty,
           isNetworkReachable {
            scheduleReconnect()
        }
        return true
    }

    /// Called when session_welcome timeout expires.
    private func handleSessionWelcomeTimeout(
        receiveContext: EventSubReceiveContext
    ) async {
        guard !eventSubTeardownQuiescing.value,
              receiveContextIsCurrent(receiveContext) else { return }
        guard welcomedWebSocketTask !== receiveContext.webSocketTask else { return }

        // A welcome that never arrived means the (possibly migration) socket is
        // dead and we fall back to a fresh reconnect. Clear the migration flag so
        // the next fresh `session_welcome` re-subscribes normally. (disconnectFromEventSub
        // below also clears it, but reset here too so the contract is explicit and
        // independent of teardown ordering.)
        isMigratingSession = false

        Log.error(
            "TwitchChatService: Session welcome timeout - WebSocket may not be responding",
            category: .twitchEvents)
        disconnectFromEventSub()

        if let channelName = reconnectChannelName,
           let token = reconnectToken,
           let clientID = reconnectClientID,
           !channelName.isEmpty, !token.isEmpty, !clientID.isEmpty,
           isNetworkReachable {
            Log.info(
                "TwitchChatService: Attempting reconnection after session welcome timeout",
                category: .twitchEvents)
            scheduleReconnect()
        }
    }

    /// Disconnects from the EventSub WebSocket and clears session state.
    ///
    /// Bumps the connection generation (cancelling session-bound command and
    /// chat-retry work), closes both the current and migration-source sockets,
    /// stops the welcome timeout and keepalive watchdog, and broadcasts
    /// "disconnected". Does not clear reconnect credentials or schedule a
    /// reconnect; callers decide that.
    ///
    /// - Parameters:
    ///   - error: Optional reason attached to the connection-state notification.
    ///   - allowDuringCredentialTeardown: Only `leaveChannel` passes `true`.
    ///     Otherwise the call is skipped while a teardown is quiescing, so a
    ///     late error path can't race it.
    func disconnectFromEventSub(
        error: String? = nil,
        allowDuringCredentialTeardown: Bool = false
    ) {
        guard allowDuringCredentialTeardown
                || !eventSubTeardownQuiescing.value else {
            Log.debug(
                "TwitchChatService: Deferring EventSub disconnect during credential teardown",
                category: .twitchEvents)
            return
        }
        invalidateSessionBoundChatWork()
        let task = webSocketTask
        let migrationSourceTask = migrationSourceWebSocketTask
        webSocketTask = nil
        migrationSourceWebSocketTask = nil
        sessionID = nil
        pollSubscriptionSessionID = nil
        pollSubscriptionAttemptSessionID = nil
        welcomedWebSocketTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        migrationSourceTask?.cancel(with: .goingAway, reason: nil)

        sessionWelcomeTask?.cancel()
        sessionWelcomeTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        migrationSourceReceiveTask?.cancel()
        migrationSourceReceiveTask = nil
        cancelKeepaliveWatchdog()
        isMigratingSession = false
        broadcastConnectionState(false, error: error)

        Log.debug("TwitchChatService: EventSub WebSocket disconnected", category: .twitchEvents)
    }

    /// Stops the socket at the receive boundary without cancelling a receive
    /// task that may already be waiting to enter this actor with a paid frame.
    /// Once both loops finish, every frame returned by `receive()` has either
    /// completed routing or been rejected before the teardown cutoff.
    ///
    /// Polls every 25 ms until both receive loops have exited.
    ///
    /// - Returns: `false` on timeout, cancellation, or if a newer join or
    ///   connection attempt took over while waiting.
    func quiesceEventSubReceiveBeforeCredentialTeardown(
        expectedOwnershipGeneration: UInt64,
        expectedConnectionGeneration: UInt64,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        guard eventSubTeardownQuiescing.value,
              channelOwnershipGeneration == expectedOwnershipGeneration,
              connectionGeneration == expectedConnectionGeneration else {
            return false
        }
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        migrationSourceWebSocketTask?.cancel(with: .goingAway, reason: nil)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while receiveTask != nil || migrationSourceReceiveTask != nil {
            guard eventSubTeardownQuiescing.value,
                  channelOwnershipGeneration == expectedOwnershipGeneration,
                  connectionGeneration == expectedConnectionGeneration else {
                return false
            }
            guard clock.now < deadline else {
                Log.error(
                    "TwitchChatService: Timed out quiescing EventSub paid-event intake before credential teardown",
                    category: .twitchEvents)
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return false
            }
        }
        return true
    }

    /// Drives the WebSocket receive loop. Replaces the recursive
    /// `task.receive { ... }` callback chain with a structured async loop
    /// that keeps frame ordering and integrates cleanly with actor isolation.
    private func startReceiveLoop() {
        receiveTask?.cancel()
        let task = webSocketTask
        let generation = connectionGeneration
        let receive = eventSubWebSocketReceive
        receiveTask = Task { [weak self] in
            guard let task else { return }
            let context = EventSubReceiveContext(
                generation: generation,
                webSocketTask: task
            )
            while !Task.isCancelled {
                do {
                    let message = try await receive(task)
                    if Task.isCancelled { break }
                    switch message {
                    case .string(let text):
                        await self?.handleWebSocketMessage(text, receiveContext: context)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            await self?.handleWebSocketMessage(text, receiveContext: context)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    // A teardown path (session migration, leaveChannel, reconnect)
                    // is the only thing that cancels this task, and cancelling the
                    // socket makes the suspended receive() throw. Bail so the
                    // orphaned loop doesn't run handleReceiveError against a socket
                    // that is already being replaced: doing so would reset
                    // isMigratingSession, flip the UI to disconnected, and schedule
                    // a reconnect that tears down the healthy migrated session.
                    if Task.isCancelled
                        || self?.eventSubTeardownQuiescing.value == true {
                        break
                    }
                    await self?.handleReceiveError(error, receiveContext: context)
                    break
                }
            }
            await self?.finishEventSubReceiveLoop(context)
        }
    }

    /// Clears the finished loop's task slot, but only if the slot still points
    /// at that loop's socket (a newer loop may already own it).
    private func finishEventSubReceiveLoop(
        _ context: EventSubReceiveContext
    ) {
        if webSocketTask === context.webSocketTask {
            receiveTask = nil
        }
        if migrationSourceWebSocketTask === context.webSocketTask {
            migrationSourceReceiveTask = nil
        }
    }

    /// Handles a WebSocket receive error: logs, updates state, and attempts reconnect.
    private func handleReceiveError(
        _ error: Error,
        receiveContext: EventSubReceiveContext
    ) async {
        // Checked here on the actor, not in the receive loop: a separate
        // pre-check before the `handleReceiveError` await would race with
        // `leaveChannel()` flipping the flag between the two suspension points.
        guard !eventSubTeardownQuiescing.value,
              receiveContextIsCurrent(receiveContext) else { return }

        // Twitch explicitly allows the source socket to close after it has sent
        // `session_reconnect`. The replacement remains authoritative; an error
        // from the retained source must not tear it down or flip UI state.
        if isMigratingSession,
           migrationSourceWebSocketTask === receiveContext.webSocketTask {
            migrationSourceWebSocketTask?.cancel(with: .goingAway, reason: nil)
            migrationSourceWebSocketTask = nil
            migrationSourceReceiveTask = nil
            Log.info(
                "TwitchChatService: Migration source socket closed; awaiting replacement welcome",
                category: .twitchEvents)
            return
        }

        // A receive error on a migration socket leads to a fresh `scheduleReconnect`
        // below, NOT a reconnect_url migration. Clear the migration flag so the
        // resulting fresh `session_welcome` runs the normal `subscribeTo*` path
        // instead of being mistaken for a carried-over migrated session.
        isMigratingSession = false

        let nsError = error as NSError
        let errorCode = nsError.code
        let errorDomain = nsError.domain

        if errorDomain == NSURLErrorDomain && errorCode == NSURLErrorTimedOut {
            Log.error(
                "TwitchChatService: WebSocket connection timed out. This may be due to network issues, firewall blocking, or Twitch service problems.",
                category: .twitchEvents)
        } else {
            Log.error(
                "TwitchChatService: WebSocket connection error",
                category: .twitchEvents,
                fields: [
                    "error": error.localizedDescription,
                    "domain": errorDomain,
                    "code": errorCode
                ])
        }

        disconnectFromEventSub(error: error.localizedDescription)

        if let channelName = reconnectChannelName,
           let token = reconnectToken,
           let clientID = reconnectClientID,
           !channelName.isEmpty, !token.isEmpty, !clientID.isEmpty,
           isNetworkReachable {
            Log.info("TwitchChatService: Attempting automatic reconnection", category: .twitchEvents)
            scheduleReconnect()
        }
    }

    #if DEBUG
    /// Test seam: starts the ordered reachability consumer without a real
    /// `NWPathMonitor`. Yield values into the returned continuation in place of
    /// path updates; `finish()` it and await `networkPathTask` to drain.
    func startNetworkPathConsumerForTesting() -> AsyncStream<Bool>.Continuation {
        stopNetworkMonitoring()
        let (stream, continuation) = AsyncStream.makeStream(
            of: Bool.self, bufferingPolicy: .unbounded)
        startNetworkPathConsumer(stream: stream, continuation: continuation)
        return continuation
    }

    /// Test seam: delivers a receive error as if it came from `webSocketTask`'s
    /// loop under the current generation.
    func handleQueuedReceiveErrorForTesting(
        webSocketTask: URLSessionWebSocketTask
    ) async {
        await handleReceiveError(
            URLError(.networkConnectionLost),
            receiveContext: EventSubReceiveContext(
                generation: connectionGeneration,
                webSocketTask: webSocketTask))
    }
    #endif
}
