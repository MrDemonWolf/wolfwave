//
//  TwitchChatService+RedemptionTeardown.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Credential-teardown boundary for paid work: settle redemption work and
/// pause the managed reward before the account's credentials go away.
extension TwitchChatService {

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
}
