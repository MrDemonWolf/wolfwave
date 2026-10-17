//
//  TwitchChatService+ChannelLifecycle.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Channel join / connect / leave, connection-attempt generations, and the
/// one-time connection confirmation message.
extension TwitchChatService {

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
        self.hasSentConnectionMessage = false
        replayPendingRedemptionResolutions()

        // The caller publishes reconnect ownership before starting transport.
        // Connected state waits for `session_welcome` and a successful chat
        // subscription (see `handleSessionWelcome`).
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
}
