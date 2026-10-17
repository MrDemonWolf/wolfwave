//
//  TwitchChatService+RedemptionResolution.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Durable redemption resolution: replays persisted fulfill / refund items
/// and retries them through HTTP failures, 401s, and conflicts until acked.
extension TwitchChatService {

    /// Replays every durable item not already owned by a live worker. Safe to
    /// call at app startup, after OAuth, and after each channel join.
    func replayPendingRedemptionResolutions() {
        replayPendingBitsEvents()
        // A credential transition must wake items that were sleeping while no
        // matching account was available. Disk is authoritative, so replacing
        // the in-memory workers cannot lose work.
        redemptionResolutionTasks.values.forEach { $0.cancel() }
        redemptionResolutionTasks.removeAll()
        redemptionResolutionWorkerIDs.removeAll()
        for item in redemptionResolutionOutbox.pendingItems() {
            if item.isIntake {
                // Never race a live queue pipeline with a refund. Its owner will
                // persist the real outcome or leave intake for a later replay.
                guard redemptionTasks[item.id] == nil else { continue }
                resolveUnknownRedemptionIntake(item)
            } else {
                startPersistedRedemptionResolution(item)
            }
        }
    }

    /// Starts a worker that applies a persisted fulfill / refund, unless one
    /// is already running for `item`. The worker outlives socket reconnects.
    func startPersistedRedemptionResolution(
        _ item: TwitchRedemptionResolutionOutbox.Item
    ) {
        guard redemptionResolutionTasks[item.id] == nil else { return }
        let workerID = UUID()
        redemptionResolutionWorkerIDs[item.id] = workerID
        redemptionResolutionTasks[item.id] = Task { [weak self] in
            await self?.runPersistedRedemptionResolution(item)
            await self?.clearRedemptionResolutionTask(
                item.id,
                workerID: workerID
            )
        }
    }

    /// Applies one persisted outcome, retrying until Twitch accepts it, the
    /// failure is terminal, or the task is cancelled.
    ///
    /// Waits (60 s steps) while the stored account isn't this item's
    /// broadcaster. Transport errors and retryable statuses back off;
    /// malformed responses and unverified reward ownership stop and leave the
    /// item on disk for a later replay.
    private func runPersistedRedemptionResolution(
        _ item: TwitchRedemptionResolutionOutbox.Item
    ) async {
        guard let resolution = item.resolution else {
            Log.error(
                "TwitchChatService: Invalid persisted redemption resolution \(item.resolutionRawValue)",
                category: .twitchRedeem)
            return
        }

        var transientAttempt = 0
        while !Task.isCancelled {
            guard !Task.isCancelled else { return }
            guard let snapshot = TwitchCredentialStore.shared.accessSnapshot(),
                  snapshot.userID == item.broadcasterID,
                  let resolvedClientID = clientID ?? redemptionClientIDProvider(),
                  !resolvedClientID.isEmpty else {
                Log.warn(
                    "TwitchChatService: Keeping redemption \(item.redemptionID) "
                        + "pending until its broadcaster credentials are available",
                    category: .twitchRedeem)
                transientAttempt += 1
                guard await sleepBeforeRedemptionRetry(
                    attempt: transientAttempt,
                    retryAfter: .seconds(60)
                ) else { return }
                continue
            }

            let credentials = TwitchChannelPointsService.Credentials(
                broadcasterID: item.broadcasterID,
                token: snapshot.accessToken,
                clientID: resolvedClientID
            )

            do {
                try await channelPointsService.resolveRedemptionWithMetadata(
                    credentials: credentials,
                    rewardID: item.rewardID,
                    redemptionID: item.redemptionID,
                    as: resolution
                )
                acknowledgeRedemptionResolution(item)
                return
            } catch is CancellationError {
                return
            } catch let error as TwitchChannelPointsService.RedemptionResolutionError {
                switch error {
                case let .http(status, _, retryAfter):
                    guard let nextAttempt = await retryRedemptionAfterHTTPFailure(
                        status: status,
                        retryAfter: retryAfter,
                        item: item,
                        credentials: credentials,
                        snapshot: snapshot,
                        clientID: resolvedClientID,
                        transientAttempt: transientAttempt
                    ) else { return }
                    transientAttempt = nextAttempt
                case .transport:
                    transientAttempt += 1
                    guard await sleepBeforeRedemptionRetry(
                        attempt: transientAttempt,
                        retryAfter: nil
                    ) else { return }
                case .malformedResponse:
                    Log.error(
                        "TwitchChatService: Keeping unresolved redemption "
                            + "\(item.redemptionID) after a malformed response",
                        category: .twitchRedeem)
                    return
                case .ownershipUnverified:
                    Log.error(
                        "TwitchChatService: Keeping unresolved redemption "
                            + "\(item.redemptionID) because managed reward ownership "
                            + "is no longer verified",
                        category: .twitchRedeem)
                    return
                }
            } catch {
                Log.error(
                    "TwitchChatService: Keeping unresolved redemption "
                        + "\(item.redemptionID): \(error.localizedDescription)",
                    category: .twitchRedeem)
                return
            }
        }
    }

    /// Decides what to do after a fulfill / refund PATCH failed with `status`.
    ///
    /// 404 acknowledges the item (already resolved or gone) when the reward is
    /// still ours. 401 / 403 try a token refresh. 400 / 409 / 422 check whether
    /// the redemption is still unfulfilled. Other retryable statuses back off;
    /// anything else stops and shows the "stuck" banner.
    ///
    /// - Returns: The next transient-attempt count to retry with, or `nil` to
    ///   stop this worker.
    private func retryRedemptionAfterHTTPFailure(
        status: Int,
        retryAfter: Duration?,
        item: TwitchRedemptionResolutionOutbox.Item,
        credentials: TwitchChannelPointsService.Credentials,
        snapshot: TwitchCredentialStore.AccessSnapshot,
        clientID: String,
        transientAttempt: Int
    ) async -> Int? {
        if status == 404 {
            let identity = TwitchManagedRewardStore.Identity(
                rewardID: item.rewardID,
                broadcasterID: item.broadcasterID)
            guard TwitchManagedRewardStore.matches(identity) else {
                Log.error(
                    "TwitchChatService: Keeping redemption \(item.redemptionID) "
                        + "because the managed reward owner changed before the 404 terminal",
                    category: .twitchRedeem)
                return nil
            }
            acknowledgeRedemptionResolution(item)
            return nil
        }
        if status == 401 || status == 403 {
            return await retryRedemptionAfterUnauthorized(
                snapshot: snapshot,
                clientID: clientID,
                retryAfter: retryAfter,
                transientAttempt: transientAttempt)
        }
        if [400, 409, 422].contains(status) {
            return await retryRedemptionConflict(
                status: status,
                retryAfter: retryAfter,
                item: item,
                credentials: credentials,
                transientAttempt: transientAttempt)
        }
        guard Self.shouldRetryRedemptionResolution(status: status) else {
            if TwitchCredentialStore.shared.matches(snapshot.accessExpectation) {
                setRedemptionStatus(.resolutionStuck)
            }
            Log.error(
                "TwitchChatService: Keeping unresolved redemption \(item.redemptionID) after HTTP \(status)",
                category: .twitchRedeem)
            return nil
        }
        let nextAttempt = transientAttempt + 1
        guard await sleepBeforeRedemptionRetry(attempt: nextAttempt, retryAfter: retryAfter) else {
            return nil
        }
        return nextAttempt
    }

    /// Handles a 401 / 403 on a redemption PATCH by trying one token refresh.
    ///
    /// - Returns: `0` to retry at once with an adopted refreshed token, the
    ///   next attempt count after a backoff, or `nil` to stop (re-auth needed,
    ///   superseded, or cancelled).
    private func retryRedemptionAfterUnauthorized(
        snapshot: TwitchCredentialStore.AccessSnapshot,
        clientID: String,
        retryAfter: Duration?,
        transientAttempt: Int
    ) async -> Int? {
        do {
            switch try await reactiveTokenRefresh(
                clientID,
                expected: snapshot.accessExpectation
            ) {
            case let .refreshed(accessToken):
                let adopted = adoptRefreshedAccessCredential(
                    snapshot.accessExpectation.replacingAccessToken(accessToken),
                    replacing: snapshot.accessExpectation)
                return adopted ? 0 : nil
            case .invalid:
                guard TwitchCredentialStore.shared.matches(snapshot.accessExpectation) else {
                    return nil
                }
                signalReauthNeededAndStop()
                return nil
            case .temporarilyUnavailable:
                break
            case .superseded:
                return nil
            }
        } catch is CancellationError {
            return nil
        } catch {
            // Leave the durable item for a later retry after a transient refresh failure.
        }
        let nextAttempt = transientAttempt + 1
        guard await sleepBeforeRedemptionRetry(attempt: nextAttempt, retryAfter: retryAfter) else {
            return nil
        }
        return nextAttempt
    }

    /// Handles 400 / 409 / 422 on a redemption PATCH.
    ///
    /// If Twitch reports the redemption is no longer unfulfilled, the work is
    /// done and the item is acknowledged. Otherwise the failure is counted on
    /// disk; the fifth one moves the item to the dead-letter store and shows
    /// the "stuck" banner.
    ///
    /// - Returns: The next attempt count after a backoff, or `nil` to stop.
    private func retryRedemptionConflict(
        status: Int,
        retryAfter: Duration?,
        item: TwitchRedemptionResolutionOutbox.Item,
        credentials: TwitchChannelPointsService.Credentials,
        transientAttempt: Int
    ) async -> Int? {
        do {
            let isUnfulfilled = try await channelPointsService.isRedemptionUnfulfilled(
                credentials: credentials,
                rewardID: item.rewardID,
                redemptionID: item.redemptionID)
            guard isUnfulfilled else {
                acknowledgeRedemptionResolution(item)
                return nil
            }
        } catch {
            Log.error(
                "TwitchChatService: Could not verify redemption \(item.redemptionID) "
                    + "after HTTP \(status): \(error.localizedDescription)",
                category: .twitchRedeem)
        }

        let failureAttempts: Int
        do {
            failureAttempts = try redemptionResolutionOutbox.recordFailureAttempt(item.id)
        } catch {
            setRedemptionStatus(.storageUnavailable)
            Log.error(
                "TwitchChatService: Could not record failed resolution attempt for "
                    + "redemption \(item.redemptionID): \(error.localizedDescription)",
                category: .twitchRedeem)
            return nil
        }
        if failureAttempts >= 5 {
            do {
                try redemptionResolutionOutbox.moveToDeadLetter(item.id)
                setRedemptionStatus(.resolutionStuck)
            } catch {
                setRedemptionStatus(.storageUnavailable)
                Log.error(
                    "TwitchChatService: Could not dead-letter redemption \(item.redemptionID): "
                        + error.localizedDescription,
                    category: .twitchRedeem)
            }
            return nil
        }
        let nextAttempt = transientAttempt + 1
        guard await sleepBeforeRedemptionRetry(attempt: nextAttempt, retryAfter: retryAfter) else {
            return nil
        }
        return nextAttempt
    }

    /// Removes a resolved item from the outbox and clears a "stuck" banner.
    /// If the delete fails, storage-failure containment pauses the reward;
    /// a later replay of the item is safe (see the comment in the catch).
    private func acknowledgeRedemptionResolution(
        _ item: TwitchRedemptionResolutionOutbox.Item
    ) {
        do {
            try redemptionResolutionOutbox.acknowledge(item.id)
            if RedemptionStatus(
                rawValue: DefaultsStore.store.string(
                    forKey: AppConstants.UserDefaults.songRequestRedemptionStatus) ?? ""
            ) == .resolutionStuck {
                setRedemptionStatus(.ok)
            }
        } catch {
            // A replay may repeat the already-applied PATCH, which is safe: the
            // 404 terminal above then retries this local acknowledgement.
            Log.error(
                "TwitchChatService: Resolved redemption \(item.redemptionID) but "
                    + "could not acknowledge its outbox item: "
                    + error.localizedDescription,
                category: .twitchRedeem)
            beginRedemptionStorageFailureContainment(
                broadcasterID: item.broadcasterID,
                rewardID: item.rewardID,
                redemptionID: item.redemptionID,
                resolution: nil)
        }
    }

    /// Focused regression seam for an acknowledgement write that fails after
    /// Twitch has already accepted the resolution.
    #if DEBUG
    func acknowledgeRedemptionResolutionForTesting(
        _ item: TwitchRedemptionResolutionOutbox.Item
    ) {
        acknowledgeRedemptionResolution(item)
    }
    #endif

    /// Backs off before a redemption retry: 1, 2, 4, ... up to 256 s by
    /// attempt, or the server's `retryAfter` when that is longer.
    ///
    /// - Returns: `false` when the sleep was cancelled; the caller stops.
    func sleepBeforeRedemptionRetry(
        attempt: Int,
        retryAfter: Duration?
    ) async -> Bool {
        let exponent = min(max(0, attempt - 1), 8)
        let fallback = Duration.seconds(min(300, 1 << exponent))
        let delay = if let retryAfter, retryAfter > fallback {
            retryAfter
        } else {
            fallback
        }
        do {
            try await redemptionResolutionSleep(delay)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    /// Statuses worth retrying with backoff: 408, 425, 429, and 5xx.
    nonisolated static func shouldRetryRedemptionResolution(status: Int) -> Bool {
        status == 408 || status == 425 || status == 429 || (500...599).contains(status)
    }

    /// Clears a finished worker's slot unless a newer worker has replaced it.
    private func clearRedemptionResolutionTask(_ id: UUID, workerID: UUID) {
        guard redemptionResolutionWorkerIDs[id] == workerID else { return }
        redemptionResolutionTasks[id] = nil
        redemptionResolutionWorkerIDs[id] = nil
    }

    /// Whether a redemption's chat reply still belongs to the live session.
    /// The paid work itself is not gated by this; only its reply is.
}
