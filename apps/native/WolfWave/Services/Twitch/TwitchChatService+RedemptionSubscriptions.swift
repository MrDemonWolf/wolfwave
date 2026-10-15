//
//  TwitchChatService+RedemptionSubscriptions.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-11.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Managed-reward lifecycle and the redemption EventSub subscriptions: create
/// or reuse the "Request a Song" reward, reconcile redemptions missed while
/// offline, subscribe, unpause, and pause it again before credentials are
/// torn down.
extension TwitchChatService {

    // MARK: - Redemption EventSub Subscriptions

    /// Subscribes to channel-point and/or bit EventSub events when the matching
    /// song-request features are enabled. Channel-point and bit subscriptions
    /// require the signed-in account to be the broadcaster. When a separate bot
    /// account is in use they are skipped and the UI is notified.
    func subscribeToRedemptionsIfEnabled(
        receiveContext: EventSubReceiveContext? = nil
    ) async {
        guard receiveContextIsCurrent(receiveContext) else { return }
        let defaults = DefaultsStore.store

        // Channel-point and bit toggles are independent of the master switch, so
        // skip every redemption subscription while the feature as a whole is off.
        // Pause the managed reward first so it can't be redeemed at the source.
        guard defaults.bool(forKey: AppConstants.UserDefaults.songRequestEnabled) else {
            await pauseManagedRewardIfPossible(receiveContext: receiveContext)
            guard receiveContextIsCurrent(receiveContext) else { return }
            setRedemptionStatus(.ok)
            return
        }

        let channelPointsEnabled = defaults.bool(
            forKey: AppConstants.UserDefaults.songRequestChannelPointsEnabled)
        let bitsEnabled = defaults.bool(forKey: AppConstants.UserDefaults.songRequestBitsEnabled)

        // Channel points off but a reward may still exist on the channel: pause it
        // so viewers can't spend points on a request WolfWave would only refund.
        if !channelPointsEnabled {
            await pauseManagedRewardIfPossible(receiveContext: receiveContext)
            guard receiveContextIsCurrent(receiveContext) else { return }
        }

        guard channelPointsEnabled || bitsEnabled else {
            setRedemptionStatus(.ok)
            return
        }

        // Channel-point and bit EventSub require the broadcaster's own token.
        guard let broadcasterID, let botID, broadcasterID == botID else {
            Log.warn(
                "TwitchChatService: Redemption events need the broadcaster account, skipping",
                category: .twitchRedeem)
            setRedemptionStatus(.botAccount)
            return
        }

        var intakeStorageAvailable = true
        if channelPointsEnabled {
            do {
                try redemptionResolutionOutbox.verifyIntakeStorage()
            } catch {
                intakeStorageAvailable = false
                setRedemptionStatus(.storageUnavailable)
                Log.error(
                    "TwitchChatService: Channel-point reward held because redemption "
                        + "storage is unavailable - \(error.localizedDescription)",
                    category: .twitchRedeem)
                await pauseManagedRewardIfPossible(receiveContext: receiveContext)
                guard receiveContextIsCurrent(receiveContext) else { return }
            }
        }

        if intakeStorageAvailable {
            setRedemptionStatus(.ok)
        }

        if channelPointsEnabled, intakeStorageAvailable {
            await ensureSongRequestRewardAndSubscribe(receiveContext: receiveContext)
            guard receiveContextIsCurrent(receiveContext) else { return }
        }
        if bitsEnabled {
            await subscribeToBitsUse(receiveContext: receiveContext)
            guard receiveContextIsCurrent(receiveContext) else { return }
        }
        if channelPointsEnabled,
           intakeStorageAvailable,
           await holdManagedRewardIfIntakeStorageUnavailable(receiveContext: receiveContext) {
            return
        }

        // A bits-subscription failure may set its own shared redemption status.
        // The unsafe channel-point intake state is the more urgent condition and
        // must stay visible until a later storage probe succeeds.
        if !intakeStorageAvailable {
            setRedemptionStatus(.storageUnavailable)
        }
    }

    /// Re-evaluates redemption subscriptions against the current settings.
    /// Called by the settings UI after the streamer changes a redemption toggle.
    func refreshRedemptionSubscriptions() async {
        guard isConnected, let webSocketTask else { return }
        let receiveContext = EventSubReceiveContext(
            generation: connectionGeneration,
            webSocketTask: webSocketTask
        )
        await subscribeToRedemptionsIfEnabled(receiveContext: receiveContext)
    }

    /// Ensures the WolfWave channel-point reward exists, syncs its cost, and
    /// subscribes to its redemption events.
    private func ensureSongRequestRewardAndSubscribe(
        receiveContext: EventSubReceiveContext? = nil
    ) async {
        guard receiveContextIsCurrent(receiveContext) else { return }
        guard let credentials = currentChannelPointCredentials() else { return }
        let setupGeneration = channelOwnershipGeneration
        guard let setupLease = TwitchRedemptionTeardownGate.beginSetup(
            serviceID: ObjectIdentifier(self),
            broadcasterID: credentials.broadcasterID,
            generation: setupGeneration
        ) else {
            return
        }
        defer { TwitchRedemptionTeardownGate.endSetup(setupLease) }

        guard await pauseStoredManagedRewardForReconciliation(
            credentials: credentials,
            receiveContext: receiveContext
        ) else {
            guard receiveContextIsCurrent(receiveContext) else { return }
            guard channelPointCredentialsAreCurrent(credentials) else { return }
            setRedemptionStatus(.subscribeFailed)
            return
        }
        guard receiveContextIsCurrent(receiveContext) else { return }
        guard channelPointCredentialsAreCurrent(credentials) else { return }

        let cost = channelPointsCostSetting()
        do {
            guard let prepared = try await prepareManagedRewardForSubscription(
                credentials: credentials,
                cost: cost,
                receiveContext: receiveContext
            ) else { return }
            try await activateManagedRewardSubscription(
                credentials: prepared.credentials,
                rewardID: prepared.rewardID,
                receiveContext: receiveContext)
        } catch {
            guard receiveContextIsCurrent(receiveContext) else { return }
            guard channelPointCredentialsAreCurrent(credentials) else { return }
            if await holdManagedRewardIfIntakeStorageUnavailable(
                receiveContext: receiveContext) { return }
            Log.error(
                "TwitchChatService: Failed to set up channel-point reward - \(error.localizedDescription)",
                category: .twitchRedeem)
            if case TwitchChannelPointsService.RewardError.http(status: 403, body: _) = error {
                setRedemptionStatus(.notAffiliate)
                return
            }
            setRedemptionStatus(.subscribeFailed)
        }
    }

    /// Readies the managed reward before any subscription: ensures it exists,
    /// pauses it, resolves every redemption left UNFULFILLED while WolfWave
    /// wasn't listening, and syncs its cost (a cost failure is only logged).
    ///
    /// - Returns: The credentials and reward ID to activate with, or `nil` when
    ///   the session or account changed, or intake storage failed, partway.
    /// - Throws: Errors from creating or pausing the reward.
    private func prepareManagedRewardForSubscription(
        credentials: TwitchChannelPointsService.Credentials,
        cost: Int,
        receiveContext: EventSubReceiveContext?
    ) async throws -> (
        credentials: TwitchChannelPointsService.Credentials,
        rewardID: String
    )? {
        let rewardID = try await channelPointsService.ensureReward(
            credentials: credentials,
            cost: cost)
        guard receiveContextIsCurrent(receiveContext),
              channelPointCredentialsAreCurrent(
                credentials,
                rewardID: rewardID) else { return nil }

        // Every fresh session starts from a held reward. EventSub reconnects do
        // not replay notifications missed while disconnected, so reconcile
        // pending Helix state before live intake.
        try await channelPointsService.setRewardPaused(
            credentials: credentials,
            rewardID: rewardID,
            paused: true)
        guard receiveContextIsCurrent(receiveContext),
              channelPointCredentialsAreCurrent(
                credentials,
                rewardID: rewardID) else { return nil }
        if await holdManagedRewardIfIntakeStorageUnavailable(
            receiveContext: receiveContext) { return nil }

        guard let reconciledCredentials = await reconcileManagedRewardRedemptions(
            credentials: credentials,
            rewardID: rewardID,
            receiveContext: receiveContext
        ) else { return nil }
        guard receiveContextIsCurrent(receiveContext),
              channelPointCredentialsAreCurrent(
                reconciledCredentials,
                rewardID: rewardID) else { return nil }

        do {
            try await channelPointsService.updateRewardCost(
                credentials: reconciledCredentials,
                rewardID: rewardID,
                cost: cost)
            guard receiveContextIsCurrent(receiveContext) else { return nil }
        } catch {
            guard receiveContextIsCurrent(receiveContext) else { return nil }
            Log.warn(
                "TwitchChatService: Couldn't sync channel-point reward cost; "
                    + "the reward still works at its current cost - "
                    + error.localizedDescription,
                category: .twitchRedeem)
        }
        guard channelPointCredentialsAreCurrent(
            reconciledCredentials,
            rewardID: rewardID) else { return nil }
        if await holdManagedRewardIfIntakeStorageUnavailable(
            receiveContext: receiveContext) { return nil }
        return (reconciledCredentials, rewardID)
    }

    /// Subscribes to redemptions of the prepared reward, then unpauses it.
    /// The reward stays paused unless the subscription succeeded, so viewers
    /// can't spend points on redemptions nobody is listening for.
    ///
    /// - Throws: Errors from unpausing the reward.
    private func activateManagedRewardSubscription(
        credentials: TwitchChannelPointsService.Credentials,
        rewardID: String,
        receiveContext: EventSubReceiveContext?
    ) async throws {
        let subscribed = await subscribeToChannelPointsRedemption(
            receiveContext: receiveContext)
        guard receiveContextIsCurrent(receiveContext),
              channelPointCredentialsAreCurrent(
                credentials,
                rewardID: rewardID) else { return }
        guard subscribed else {
            setRedemptionStatus(.subscribeFailed)
            return
        }
        if await holdManagedRewardIfIntakeStorageUnavailable(
            receiveContext: receiveContext) { return }
        guard channelPointCredentialsAreCurrent(
            credentials,
            rewardID: rewardID) else { return }

        try await channelPointsService.setRewardPaused(
            credentials: credentials,
            rewardID: rewardID,
            paused: false)
        guard receiveContextIsCurrent(receiveContext),
              channelPointCredentialsAreCurrent(
                credentials,
                rewardID: rewardID) else { return }
        if await holdManagedRewardIfIntakeStorageUnavailable(
            receiveContext: receiveContext) { return }
        setRedemptionStatus(.ok)
    }

    /// Best-effort closes the gap before `ensureReward` resolves the canonical
    /// managed reward ID. A missing stale ID is safe to continue because the
    /// resolved reward is held again before reconciliation starts.
    private func pauseStoredManagedRewardForReconciliation(
        credentials: TwitchChannelPointsService.Credentials,
        receiveContext: EventSubReceiveContext?
    ) async -> Bool {
        do {
            guard let identity = try await channelPointsService
                .managedRewardIdentity(credentials: credentials) else {
                return true
            }
            do {
                try await channelPointsService.setRewardPaused(
                    credentials: credentials,
                    rewardID: identity.rewardID,
                    paused: true)
            } catch let TwitchChannelPointsService.RewardError.http(status, _)
                where status == 404 {
                guard receiveContextIsCurrent(receiveContext),
                      channelPointCredentialsAreCurrent(
                        credentials,
                        rewardID: identity.rewardID),
                      TwitchManagedRewardStore.matches(identity) else {
                    return false
                }
                guard await settleRedemptionWorkBeforeCredentialTeardown(
                    broadcasterID: identity.broadcasterID) else {
                    return false
                }
                return TwitchManagedRewardStore.remove(matching: identity)
            }
            return receiveContextIsCurrent(receiveContext)
                && channelPointCredentialsAreCurrent(
                    credentials,
                    rewardID: identity.rewardID)
        } catch {
            guard receiveContextIsCurrent(receiveContext) else { return false }
            Log.error(
                "TwitchChatService: Could not hold stored channel-point reward before recovery - "
                    + error.localizedDescription,
                category: .twitchRedeem)
            return false
        }
    }

    /// Fetches, persists, and drains every unresolved managed redemption before
    /// the fresh EventSub session may subscribe or make the reward redeemable.
    /// Existing outbox items are included so duplicate Helix results remain
    /// idempotent and prior crash recovery completes under the same hold.
    func reconcileManagedRewardRedemptions(
        credentials: TwitchChannelPointsService.Credentials,
        rewardID: String,
        receiveContext: EventSubReceiveContext?
    ) async -> TwitchChannelPointsService.Credentials? {
        guard let redemptionIDs = await fetchUnfulfilledRedemptionsForRecovery(
            credentials: credentials,
            rewardID: rewardID,
            receiveContext: receiveContext
        ) else { return nil }
        guard receiveContextIsCurrent(receiveContext),
              channelPointCredentialsAreCurrent(
                credentials,
                rewardID: rewardID
              ) else { return nil }

        do {
            for redemptionID in redemptionIDs {
                guard !redemptionResolutionOutbox.hasAcknowledgedRedemption(
                    broadcasterID: credentials.broadcasterID,
                    rewardID: rewardID,
                    redemptionID: redemptionID
                ) else { continue }
                _ = try redemptionResolutionOutbox.enqueueIntake(
                    broadcasterID: credentials.broadcasterID,
                    rewardID: rewardID,
                    redemptionID: redemptionID)
            }
        } catch {
            setRedemptionStatus(.storageUnavailable)
            Log.error(
                "TwitchChatService: Could not persist missed redemption recovery - "
                    + error.localizedDescription,
                category: .twitchRedeem)
            return nil
        }

        let recoveryItems = redemptionResolutionOutbox.pendingItems().filter {
            $0.broadcasterID == credentials.broadcasterID
                && $0.rewardID == rewardID
        }
        let recoveryItemIDs = Set(recoveryItems.map(\.id))
        if !recoveryItemIDs.isEmpty {
            let liveWorkers = recoveryItemIDs.compactMap { redemptionTasks[$0] }
            for worker in liveWorkers {
                await worker.value
            }
            replayPendingRedemptionResolutions()
            let workers = recoveryItemIDs.compactMap {
                redemptionResolutionTasks[$0]
            }
            for worker in workers {
                await worker.value
            }
        }

        guard receiveContextIsCurrent(receiveContext),
              channelPointCredentialsAreCurrent(
                credentials,
                rewardID: rewardID
              ) else { return nil }
        let recoveryIncomplete = redemptionResolutionOutbox.pendingItems().contains {
            recoveryItemIDs.contains($0.id)
        }
        guard !recoveryIncomplete else {
            if redemptionResolutionOutbox.intakeStorageIsUnavailable() {
                setRedemptionStatus(.storageUnavailable)
            } else {
                setRedemptionStatus(.subscribeFailed)
            }
            Log.error(
                "TwitchChatService: Managed redemption recovery remains incomplete; keeping reward paused",
                category: .twitchRedeem)
            return nil
        }
        guard !redemptionResolutionOutbox.intakeStorageIsUnavailable() else {
            setRedemptionStatus(.storageUnavailable)
            return nil
        }
        if redemptionResolutionOutbox.hasOpaqueRecoveryRisk() {
            do {
                try redemptionResolutionOutbox
                    .clearOpaqueRecoveryRiskAfterReconciliation()
            } catch {
                setRedemptionStatus(.storageUnavailable)
                Log.error(
                    "TwitchChatService: Held redemption recovery could not clear quarantined data - "
                        + error.localizedDescription,
                    category: .twitchRedeem)
                return nil
            }
        }
        return credentials
    }

    /// Applies the same expectation-bound 401 handling as other live Twitch
    /// requests. A refresh starts a fresh socket instead of continuing recovery
    /// on a session authenticated with the rejected token.
    private func fetchUnfulfilledRedemptionsForRecovery(
        credentials: TwitchChannelPointsService.Credentials,
        rewardID: String,
        receiveContext: EventSubReceiveContext?
    ) async -> [String]? {
        let expectedCredential = TwitchCredentialStore.shared
            .connectionSnapshot(matchingAccessToken: credentials.token)?
            .accessExpectation
        do {
            return try await channelPointsService.unfulfilledRedemptionIDs(
                credentials: credentials,
                rewardID: rewardID)
        } catch let TwitchChannelPointsService.RewardError.http(status, _)
            where status == 401 {
            guard receiveContextIsCurrent(receiveContext),
                  let expectedCredential else { return nil }
            let generation = receiveContext?.generation ?? connectionGeneration
            let recovery = await recoverRejectedAccessToken(
                expectedCredential,
                clientID: credentials.clientID,
                generation: generation,
                broadcasterID: credentials.broadcasterID)
            guard receiveContextIsCurrent(receiveContext) else { return nil }
            switch recovery {
            case .refreshed?:
                disconnectFromEventSub()
                if isNetworkReachable { scheduleReconnect() }
            case .invalid?:
                signalReauthNeededAndStop()
            case .temporarilyUnavailable?:
                disconnectFromEventSub()
                if isNetworkReachable { scheduleReconnect() }
            case .superseded?, nil:
                break
            }
            return nil
        } catch {
            guard receiveContextIsCurrent(receiveContext) else { return nil }
            guard channelPointCredentialsAreCurrent(
                credentials,
                rewardID: rewardID
            ) else { return nil }
            Log.error(
                "TwitchChatService: Could not reconcile unfulfilled channel-point redemptions - "
                    + error.localizedDescription,
                category: .twitchRedeem)
            setRedemptionStatus(.subscribeFailed)
            return nil
        }
    }

    /// Revalidates every identity component after a setup suspension. The
    /// stored reward ID is part of the guard so a concurrent recreation cannot
    /// authorize recovery or unpause against the wrong reward.
    private func channelPointCredentialsAreCurrent(
        _ credentials: TwitchChannelPointsService.Credentials,
        rewardID: String
    ) -> Bool {
        let identity = TwitchManagedRewardStore.Identity(
            rewardID: rewardID,
            broadcasterID: credentials.broadcasterID)
        return channelPointCredentialsAreCurrent(credentials)
            && TwitchManagedRewardStore.matches(identity)
    }

    /// Revalidates the account independently of reward storage, for failures
    /// that occur before `ensureReward` has resolved a canonical reward ID.
    private func channelPointCredentialsAreCurrent(
        _ credentials: TwitchChannelPointsService.Credentials
    ) -> Bool {
        return !Task.isCancelled
            && broadcasterID == credentials.broadcasterID
            && botID == credentials.broadcasterID
            && oauthToken == credentials.token
            && clientID == credentials.clientID
    }

    /// Returns credentials only when the live actor and atomic Keychain grant
    /// agree with the expected managed-reward owner.
    private func managedRewardTeardownCredentials(
        expectedBroadcasterID: String?
    ) -> TwitchChannelPointsService.Credentials? {
        if let currentCredentials = currentChannelPointCredentials(),
           botID == currentCredentials.broadcasterID,
           expectedBroadcasterID == nil
                || expectedBroadcasterID == currentCredentials.broadcasterID {
            return currentCredentials
        }

        guard let snapshot = TwitchCredentialStore.shared.accessSnapshot(),
              let resolvedClientID = clientID ?? reconnectClientID
                ?? redemptionClientIDProvider(),
              !resolvedClientID.isEmpty,
              expectedBroadcasterID == nil
                || expectedBroadcasterID == snapshot.userID else {
            return nil
        }
        let actorBroadcasterID = broadcasterID.flatMap { $0.isEmpty ? nil : $0 }
        let actorBotID = botID.flatMap { $0.isEmpty ? nil : $0 }
        guard actorBroadcasterID == nil || actorBroadcasterID == snapshot.userID,
              actorBotID == nil || actorBotID == snapshot.userID else {
            return nil
        }
        return TwitchChannelPointsService.Credentials(
            broadcasterID: snapshot.userID,
            token: snapshot.accessToken,
            clientID: resolvedClientID)
    }

    /// Re-probes transient write failures but never treats opaque quarantined
    /// bytes as an empty queue during the last credential teardown boundary.
    private func redemptionStorageIsSafeForCredentialTeardown() -> Bool {
        do {
            try redemptionResolutionOutbox.verifyIntakeStorage()
        } catch {
            Log.error(
                "TwitchChatService: Refusing credential teardown because redemption storage cannot be verified - "
                    + error.localizedDescription,
                category: .twitchRedeem)
            return false
        }
        guard !redemptionResolutionOutbox.hasOpaqueRecoveryRisk() else {
            Log.error(
                "TwitchChatService: Refusing credential teardown while quarantined redemption recovery data remains",
                category: .twitchRedeem)
            return false
        }
        return true
    }

    /// Waits for setup work from this ownership generation to finish so its
    /// create or unpause response cannot land after teardown's final pause.
    private func awaitManagedRewardSetupsBeforeCredentialTeardown(
        broadcasterID: String,
        generation: UInt64,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while TwitchRedemptionTeardownGate.hasActiveSetup(
            serviceID: ObjectIdentifier(self),
            broadcasterID: broadcasterID,
            through: generation
        ) {
            guard clock.now < deadline else {
                Log.error(
                    "TwitchChatService: Timed out waiting for managed reward setup before credential teardown",
                    category: .twitchRedeem)
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return false
            }
        }
        return TwitchRedemptionTeardownGate.teardownIsCurrent(
            serviceID: ObjectIdentifier(self),
            broadcasterID: broadcasterID,
            generation: generation)
            && channelOwnershipGeneration == generation
    }

    /// Waits for live intake to record an outcome, then replays and drains the
    /// durable work for one broadcaster. Polling task ownership keeps this
    /// boundary bounded even when a network worker is sleeping or wedged.
    func settleRedemptionWorkBeforeCredentialTeardown(
        broadcasterID: String,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        guard !broadcasterID.isEmpty else { return false }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        replayPendingBitsEvents()

        while true {
            let pendingItems = redemptionResolutionOutbox.pendingItems().filter {
                $0.broadcasterID == broadcasterID
            }
            let pendingBits = redemptionResolutionOutbox.pendingBitsItems(
                broadcasterID: broadcasterID)
            let volatileBits = pendingVolatileBitsFallbackItems(
                broadcasterID: broadcasterID)
            let hasContainment = TwitchRedemptionTeardownGate.hasContainment(
                serviceID: ObjectIdentifier(self),
                broadcasterID: broadcasterID)
            if pendingItems.isEmpty,
               pendingBits.isEmpty,
               volatileBits.isEmpty,
               !hasContainment {
                return true
            }
            let hasLiveIntake = pendingItems.contains {
                redemptionTasks[$0.id] != nil
            }
            let hasBitsWorker = pendingBits.contains {
                paidRedemptionTasks[$0.id] != nil
            }
            let hasVolatileBitsWorker = volatileBits.contains {
                paidRedemptionTasks[$0.id] != nil
            }
            guard hasLiveIntake
                    || hasBitsWorker
                    || hasVolatileBitsWorker
                    || hasContainment else {
                break
            }
            guard clock.now < deadline else {
                Log.error(
                    "TwitchChatService: Timed out waiting for live paid-event intake before credential teardown",
                    category: .twitchRedeem)
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return false
            }
        }

        // Wake only this broadcaster's durable work. Replacing a sleeping
        // redemption worker is safe because disk remains authoritative.
        let replayItems = redemptionResolutionOutbox.pendingItems().filter {
            $0.broadcasterID == broadcasterID
        }
        for item in replayItems {
            redemptionResolutionTasks[item.id]?.cancel()
            redemptionResolutionTasks[item.id] = nil
            redemptionResolutionWorkerIDs[item.id] = nil
            if item.isIntake {
                resolveUnknownRedemptionIntake(item)
            } else {
                startPersistedRedemptionResolution(item)
            }
        }
        replayPendingBitsEvents()

        while true {
            let pendingItems = redemptionResolutionOutbox.pendingItems().filter {
                $0.broadcasterID == broadcasterID
            }
            let pendingBits = redemptionResolutionOutbox.pendingBitsItems(
                broadcasterID: broadcasterID)
            let volatileBits = pendingVolatileBitsFallbackItems(
                broadcasterID: broadcasterID)
            let hasContainment = TwitchRedemptionTeardownGate.hasContainment(
                serviceID: ObjectIdentifier(self),
                broadcasterID: broadcasterID)
            if pendingItems.isEmpty,
               pendingBits.isEmpty,
               volatileBits.isEmpty,
               !hasContainment {
                return true
            }

            let hasLiveIntake = pendingItems.contains {
                redemptionTasks[$0.id] != nil
            }
            let hasResolutionWorker = pendingItems.contains {
                redemptionResolutionTasks[$0.id] != nil
            }
            let hasBitsWorker = pendingBits.contains {
                paidRedemptionTasks[$0.id] != nil
            }
            let hasVolatileBitsWorker = volatileBits.contains {
                paidRedemptionTasks[$0.id] != nil
            }
            guard hasLiveIntake
                    || hasResolutionWorker
                    || hasBitsWorker
                    || hasVolatileBitsWorker
                    || hasContainment else {
                Log.error(
                    "TwitchChatService: Persisted paid-event work could not be drained before credential teardown",
                    category: .twitchRedeem)
                return false
            }
            guard clock.now < deadline else {
                Log.error(
                    "TwitchChatService: Timed out draining persisted paid-event work before credential teardown",
                    category: .twitchRedeem)
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return false
            }
        }
    }

    /// Holds the managed reward while a verified actor or stored grant still owns
    /// the credentials that can mutate it. Account deletion/replacement awaits
    /// this bounded attempt before clearing actor or Keychain state; transport
    /// reconnects do not call it and continue to rely on fresh-session reconciliation.
    func pauseManagedRewardBeforeCredentialTeardown(
        allowDiscardingOpaqueRedemptionRecovery: Bool = false
    ) async -> Bool {
        // Probe before any fast path. If a reward can still be proven below we
        // pause it first, but no branch may clear credentials while this is false.
        let redemptionStorageIsSafe = allowDiscardingOpaqueRedemptionRecovery
            || redemptionStorageIsSafeForCredentialTeardown()

        guard let credentials = managedRewardTeardownCredentials(
            expectedBroadcasterID: nil
        ) else {
            let rewardSnapshot = TwitchManagedRewardStore.snapshot()
            let hasPendingWork =
                !redemptionResolutionOutbox.pendingItems().isEmpty
                    || !redemptionResolutionOutbox.pendingBitsItems().isEmpty
                    || !pendingVolatileBitsFallbackItems().isEmpty
            let hasManagedReward = rewardSnapshot != .none
            if !hasManagedReward, !hasPendingWork {
                return redemptionStorageIsSafe
            }
            Log.error(
                "TwitchChatService: Refusing credential teardown because the "
                    + "old broadcaster credentials cannot be proven",
                category: .twitchRedeem)
            return false
        }

        let serviceID = ObjectIdentifier(self)
        let teardownGeneration = channelOwnershipGeneration
        guard TwitchRedemptionTeardownGate.beginTeardown(
            serviceID: serviceID,
            broadcasterID: credentials.broadcasterID,
            generation: teardownGeneration
        ) else {
            return false
        }
        var teardownSucceeded = false
        defer {
            if !teardownSucceeded {
                TwitchRedemptionTeardownGate.cancelTeardown(
                    serviceID: serviceID,
                    broadcasterID: credentials.broadcasterID,
                    generation: teardownGeneration)
            }
        }

        guard await awaitManagedRewardSetupsBeforeCredentialTeardown(
            broadcasterID: credentials.broadcasterID,
            generation: teardownGeneration) else {
            return false
        }

        // Setup may have created or migrated the reward while teardown waited,
        // so identity and durable ownership must be read only after that fence.
        let rewardSnapshot = TwitchManagedRewardStore.snapshot()
        guard rewardSnapshot != .corrupt else {
            Log.error(
                "TwitchChatService: Refusing credential teardown because the managed reward identity is corrupt",
                category: .twitchRedeem)
            return false
        }

        let pendingBroadcasterIDs = Set(
            redemptionResolutionOutbox.pendingItems().map(\.broadcasterID)
                + redemptionResolutionOutbox.pendingBitsItems()
                    .map(\.broadcasterID)
                + pendingVolatileBitsFallbackItems()
                    .map(\.broadcasterID))
        guard pendingBroadcasterIDs.count <= 1,
              pendingBroadcasterIDs.first == nil
                || pendingBroadcasterIDs.first == credentials.broadcasterID else {
            Log.error(
                "TwitchChatService: Refusing credential teardown because "
                    + "persisted redemption ownership conflicts with the old broadcaster",
                category: .twitchRedeem)
            return false
        }

        guard rewardSnapshot != .none else {
            guard redemptionStorageIsSafe else {
                return false
            }
            let settled = await settleRedemptionWorkBeforeCredentialTeardown(
                broadcasterID: credentials.broadcasterID)
            teardownSucceeded = settled
            return settled
        }

        let identity: TwitchManagedRewardStore.Identity
        do {
            guard let resolvedIdentity = try await channelPointsService
                .managedRewardIdentity(credentials: credentials),
                  resolvedIdentity.broadcasterID == credentials.broadcasterID,
                  TwitchManagedRewardStore.matches(resolvedIdentity) else {
                return false
            }
            identity = resolvedIdentity
        } catch {
            Log.error(
                "TwitchChatService: Refusing credential teardown because "
                    + "managed reward ownership could not be verified - "
                    + error.localizedDescription,
                category: .twitchRedeem)
            return false
        }

        // A caller canceling its UI task must not cancel the last request that
        // can make the old account reward safe. Waiting for the setup lease
        // above makes this pause the final mutation from the old generation.
        let channelPointsService = self.channelPointsService
        let result = await Task.detached(priority: .userInitiated) {
            do {
                try await channelPointsService.setRewardPaused(
                    credentials: credentials,
                    rewardID: identity.rewardID,
                    paused: true,
                    requestTimeout: 5)
                return (
                    safe: true,
                    rewardMissing: false,
                    failureDescription: nil as String?)
            } catch let error as TwitchChannelPointsService.RewardError {
                if case .http(status: 404, body: _) = error {
                    return (
                        safe: true,
                        rewardMissing: true,
                        failureDescription: nil as String?)
                }
                return (
                    safe: false,
                    rewardMissing: false,
                    failureDescription: error.localizedDescription)
            } catch {
                return (
                    safe: false,
                    rewardMissing: false,
                    failureDescription: error.localizedDescription)
            }
        }.value

        guard result.safe else {
            Log.error(
                "TwitchChatService: Could not pause managed reward before credential teardown - "
                    + (result.failureDescription ?? "unknown failure"),
                category: .twitchRedeem)
            return false
        }
        guard redemptionStorageIsSafe else {
            return false
        }
        if !result.rewardMissing {
            do {
                let unfulfilledIDs = try await channelPointsService
                    .unfulfilledRedemptionIDs(
                        credentials: credentials,
                        rewardID: identity.rewardID,
                        requestTimeout: 5)
                for redemptionID in unfulfilledIDs {
                    guard !redemptionResolutionOutbox
                        .hasAcknowledgedRedemption(
                            broadcasterID: identity.broadcasterID,
                            rewardID: identity.rewardID,
                            redemptionID: redemptionID) else {
                        continue
                    }
                    _ = try redemptionResolutionOutbox.enqueueIntake(
                        broadcasterID: identity.broadcasterID,
                        rewardID: identity.rewardID,
                        redemptionID: redemptionID)
                }
            } catch {
                setRedemptionStatus(.storageUnavailable)
                Log.error(
                    "TwitchChatService: Could not capture the final paused-reward "
                        + "redemption snapshot before credential teardown - "
                        + error.localizedDescription,
                    category: .twitchRedeem)
                return false
            }
        }
        guard await settleRedemptionWorkBeforeCredentialTeardown(
            broadcasterID: identity.broadcasterID) else {
            return false
        }

        if result.rewardMissing {
            guard TwitchManagedRewardStore.remove(matching: identity) else {
                return false
            }
            Log.info(
                "TwitchChatService: Managed reward was already absent during credential teardown",
                category: .twitchRedeem)
        } else {
            Log.info(
                "TwitchChatService: Paused managed reward and drained redemptions before credential teardown",
                category: .twitchRedeem)
        }
        teardownSucceeded = true
        return true
    }

    /// Pauses the WolfWave-managed channel-point reward so it can't be redeemed
    /// while channel-point requests are off. No-op when no reward was ever
    /// created or broadcaster credentials are unavailable.
    private func pauseManagedRewardIfPossible(
        receiveContext: EventSubReceiveContext? = nil
    ) async {
        guard receiveContextIsCurrent(receiveContext),
              let credentials = currentChannelPointCredentials() else {
            return
        }
        do {
            guard let identity = try await channelPointsService
                .managedRewardIdentity(credentials: credentials) else {
                return
            }
            guard receiveContextIsCurrent(receiveContext),
                  channelPointCredentialsAreCurrent(
                    credentials,
                    rewardID: identity.rewardID) else {
                return
            }
            try await channelPointsService.setRewardPaused(
                credentials: credentials,
                rewardID: identity.rewardID,
                paused: true)
            guard receiveContextIsCurrent(receiveContext) else { return }
            Log.info(
                "TwitchChatService: Paused channel-point reward (requests off)",
                category: .twitchRedeem)
        } catch {
            guard receiveContextIsCurrent(receiveContext) else { return }
            Log.error(
                "TwitchChatService: Failed to pause channel-point reward - \(error.localizedDescription)",
                category: .twitchRedeem)
        }
    }

    /// Re-checks the sticky outbox circuit breaker after each setup suspension.
    /// If an EventSub delivery failed intake while an unpause was in flight, a
    /// fresh pause here is ordered after that response and therefore wins.
    private func holdManagedRewardIfIntakeStorageUnavailable(
        receiveContext: EventSubReceiveContext? = nil
    ) async -> Bool {
        guard redemptionResolutionOutbox.intakeStorageIsUnavailable() else {
            return false
        }
        setRedemptionStatus(.storageUnavailable)
        await pauseManagedRewardIfPossible(receiveContext: receiveContext)
        guard receiveContextIsCurrent(receiveContext) else { return true }
        setRedemptionStatus(.storageUnavailable)
        return true
    }

    /// POSTs the channel-point redemption subscription for this session.
    ///
    /// - Returns: `true` when Twitch accepted it.
    private func subscribeToChannelPointsRedemption(
        receiveContext: EventSubReceiveContext? = nil
    ) async -> Bool {
        guard receiveContextIsCurrent(receiveContext) else { return false }
        guard let broadcasterID, let token = oauthToken,
              let clientID, let sessionID else { return false }
        let body = Self.eventSubBody(
            type: AppConstants.Twitch.eventSubChannelPointsRedemption,
            broadcasterID: broadcasterID, sessionID: sessionID)
        return await postEventSubSubscription(
            body: body,
            token: token,
            clientID: clientID,
            label: "channel-point redemptions",
            receiveContext: receiveContext
        )
    }

    /// POSTs the `channel.bits.use` subscription for this session. Failure is
    /// reported through the redemption status banner by
    /// `postEventSubSubscription`.
    private func subscribeToBitsUse(
        receiveContext: EventSubReceiveContext? = nil
    ) async {
        guard receiveContextIsCurrent(receiveContext) else { return }
        guard let broadcasterID, let token = oauthToken, let clientID, let sessionID else { return }
        let body = Self.eventSubBody(
            type: AppConstants.Twitch.eventSubBitsUse,
            broadcasterID: broadcasterID, sessionID: sessionID)
        _ = await postEventSubSubscription(
            body: body,
            token: token,
            clientID: clientID,
            label: "bit usage",
            receiveContext: receiveContext
        )
    }
}
