//
//  TwitchChatService+Redemptions.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-07-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Process-local lifecycle fence for reward setup and unpersisted redemption
/// containment. Disk remains authoritative for persisted work; this gate only
/// supplies the bounded ordering that UserDefaults and task dictionaries cannot.
nonisolated enum TwitchRedemptionTeardownGate {
    struct SetupLease: @unchecked Sendable {
        let id: UUID
        fileprivate let owner: Owner
        fileprivate let generation: UInt64
    }

    fileprivate struct Owner: Hashable {
        let serviceID: ObjectIdentifier
        let broadcasterID: String
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var setups: [UUID: SetupLease] = [:]
    private nonisolated(unsafe) static var teardownGenerations: [Owner: UInt64] = [:]
    private nonisolated(unsafe) static var containments: [UUID: Owner] = [:]

    static func beginSetup(
        serviceID: ObjectIdentifier,
        broadcasterID: String,
        generation: UInt64
    ) -> SetupLease? {
        lock.withLock {
            let owner = Owner(
                serviceID: serviceID,
                broadcasterID: broadcasterID)
            if let teardownGeneration = teardownGenerations[owner] {
                guard generation > teardownGeneration else { return nil }
                teardownGenerations[owner] = nil
            }
            let lease = SetupLease(
                id: UUID(),
                owner: owner,
                generation: generation)
            setups[lease.id] = lease
            return lease
        }
    }

    static func endSetup(_ lease: SetupLease) {
        lock.withLock {
            guard setups[lease.id]?.generation == lease.generation else {
                return
            }
            setups[lease.id] = nil
        }
    }

    static func beginTeardown(
        serviceID: ObjectIdentifier,
        broadcasterID: String,
        generation: UInt64
    ) -> Bool {
        lock.withLock {
            let owner = Owner(
                serviceID: serviceID,
                broadcasterID: broadcasterID)
            if let existing = teardownGenerations[owner],
               existing > generation {
                return false
            }
            teardownGenerations[owner] = generation
            return true
        }
    }

    static func teardownIsCurrent(
        serviceID: ObjectIdentifier,
        broadcasterID: String,
        generation: UInt64
    ) -> Bool {
        lock.withLock {
            teardownGenerations[
                Owner(
                    serviceID: serviceID,
                    broadcasterID: broadcasterID)
            ] == generation
        }
    }

    static func cancelTeardown(
        serviceID: ObjectIdentifier,
        broadcasterID: String,
        generation: UInt64
    ) {
        lock.withLock {
            let owner = Owner(
                serviceID: serviceID,
                broadcasterID: broadcasterID)
            guard teardownGenerations[owner] == generation else { return }
            teardownGenerations[owner] = nil
        }
    }

    static func hasActiveSetup(
        serviceID: ObjectIdentifier,
        broadcasterID: String,
        through generation: UInt64
    ) -> Bool {
        lock.withLock {
            setups.values.contains {
                $0.owner.serviceID == serviceID
                    && $0.owner.broadcasterID == broadcasterID
                    && $0.generation <= generation
            }
        }
    }

    static func beginContainment(
        id: UUID,
        serviceID: ObjectIdentifier,
        broadcasterID: String
    ) {
        lock.withLock {
            containments[id] = Owner(
                serviceID: serviceID,
                broadcasterID: broadcasterID)
        }
    }

    static func endContainment(id: UUID) {
        lock.withLock {
            containments[id] = nil
        }
    }

    static func removeService(serviceID: ObjectIdentifier) {
        lock.withLock {
            setups = setups.filter {
                $0.value.owner.serviceID != serviceID
            }
            teardownGenerations = teardownGenerations.filter {
                $0.key.serviceID != serviceID
            }
            containments = containments.filter {
                $0.value.serviceID != serviceID
            }
        }
    }

    static func hasContainment(
        serviceID: ObjectIdentifier,
        broadcasterID: String
    ) -> Bool {
        lock.withLock {
            containments.values.contains {
                $0.serviceID == serviceID
                    && $0.broadcasterID == broadcasterID
            }
        }
    }
}

/// Result of one storage-failure containment attempt.
private enum RedemptionContainmentOutcome {
    /// The pause and (when requested) the refund were both confirmed.
    case settled
    /// A transient failure. The paid redemption still needs this containment.
    case retry
    /// No live account can act on this redemption any more (reward identity
    /// replaced, or the broadcaster credentials were torn down). Retrying with
    /// the same captured inputs can never succeed, so containment ends here.
    /// The refund is not dropped: Twitch still holds the redemption as
    /// UNFULFILLED, and `reconcileManagedRewardRedemptions` enqueues and drains
    /// every unfulfilled ID before the reward is redeemable again.
    case accountGone
}

extension TwitchChatService {

    // Redemption EventSub subscriptions live in TwitchChatService+RedemptionSubscriptions.swift
    // Redemption event handlers live in TwitchChatService+RedemptionHandlers.swift

    // MARK: - Redemption Helpers

    /// Durably trips the local circuit breaker before launching HTTP cleanup.
    /// The task is tracked with other paid work so socket reconnects cannot
    /// cancel the pause/refund sequence after a viewer has spent points.
    func beginRedemptionStorageFailureContainment(
        broadcasterID: String,
        rewardID: String,
        redemptionID: String,
        resolution: TwitchChannelPointsService.Resolution?
    ) {
        setRedemptionStatus(.storageUnavailable)
        let taskID = UUID()
        TwitchRedemptionTeardownGate.beginContainment(
            id: taskID,
            serviceID: ObjectIdentifier(self),
            broadcasterID: broadcasterID)
        // Detached so `[weak self]` means what it says. An unstructured `Task`
        // started here would inherit this actor's isolation and retain the
        // service for its whole life, so an unsettled containment would keep a
        // dropped service (and its retry loop) alive after every owner is gone.
        paidRedemptionTasks[taskID] = Task.detached { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let outcome = await self?
                    .pauseRewardAndResolveUnpersistedIntake(
                        broadcasterID: broadcasterID,
                        rewardID: rewardID,
                        redemptionID: redemptionID,
                        resolution: resolution) else {
                    TwitchRedemptionTeardownGate.endContainment(id: taskID)
                    return
                }
                switch outcome {
                case .settled, .accountGone:
                    // `.accountGone` releases the gate too: it can only be
                    // reached once no live credential owns this redemption, so
                    // holding the gate would block teardown forever while doing
                    // nothing for the viewer's points.
                    await self?.clearContainmentTask(
                        taskID,
                        releasingGate: true)
                    return
                case .retry:
                    break
                }

                attempt += 1
                guard let shouldRetry = await self?.sleepBeforeRedemptionRetry(
                    attempt: attempt,
                    retryAfter: nil),
                      shouldRetry else {
                    await self?.clearContainmentTask(
                        taskID,
                        releasingGate: false)
                    return
                }
            }
            await self?.clearContainmentTask(
                taskID,
                releasingGate: false)
        }
    }

    /// Pauses at the source first, then applies the conservative refund
    /// requested by intake/outcome failures. The containment remains unresolved
    /// until both operations are confirmed (with 404 treated idempotently).
    private func pauseRewardAndResolveUnpersistedIntake(
        broadcasterID eventBroadcasterID: String,
        rewardID: String,
        redemptionID: String,
        resolution: TwitchChannelPointsService.Resolution?
    ) async -> RedemptionContainmentOutcome {
        let identity = TwitchManagedRewardStore.Identity(
            rewardID: rewardID,
            broadcasterID: eventBroadcasterID)
        guard TwitchManagedRewardStore.matches(identity),
              let activeBroadcasterID = broadcasterID,
              let activeBotID = botID,
              activeBroadcasterID == eventBroadcasterID,
              activeBotID == eventBroadcasterID,
              let credentials = currentChannelPointCredentials(),
              credentials.broadcasterID == eventBroadcasterID else {
            // Every Helix call this containment could make is authorized by
            // credentials that no longer exist, so a retry with the same inputs
            // is guaranteed to land here again. Ending it hands the redemption
            // to the session-join reconcile, which reads Twitch's own
            // UNFULFILLED list and refunds from there.
            Log.error(
                "TwitchChatService: Storage failed for redemption \(redemptionID) and the "
                    + "broadcaster credentials that could resolve it are gone; ending containment. "
                    + "The next session for this reward refunds it from its unfulfilled list",
                category: .twitchRedeem)
            return .accountGone
        }

        let sourceIsSafe: Bool
        do {
            try await channelPointsService.setRewardPaused(
                credentials: credentials,
                rewardID: rewardID,
                paused: true)
            sourceIsSafe = true
            Log.info(
                "TwitchChatService: Paused channel-point reward after redemption storage failure",
                category: .twitchRedeem)
        } catch let TwitchChannelPointsService.RewardError.http(status, _)
            where status == 404 {
            sourceIsSafe = true
        } catch is CancellationError {
            return .retry
        } catch {
            sourceIsSafe = false
            Log.error(
                "TwitchChatService: Could not pause channel-point reward after storage failure - "
                    + error.localizedDescription,
                category: .twitchRedeem)
        }

        guard let resolution else {
            return sourceIsSafe ? .settled : .retry
        }

        let redemptionIsSettled: Bool
        do {
            try await channelPointsService.resolveRedemptionWithMetadata(
                credentials: credentials,
                rewardID: rewardID,
                redemptionID: redemptionID,
                as: resolution)
            redemptionIsSettled = true
        } catch let TwitchChannelPointsService.RedemptionResolutionError.http(
            status,
            _,
            _
        ) where status == 404 {
            redemptionIsSettled = TwitchManagedRewardStore.matches(identity)
        } catch is CancellationError {
            return .retry
        } catch {
            redemptionIsSettled = false
            Log.error(
                "TwitchChatService: Could not apply \(resolution.rawValue) to redemption "
                    + "\(redemptionID) after storage failure - \(error.localizedDescription)",
                category: .twitchRedeem)
        }
        return sourceIsSafe && redemptionIsSettled ? .settled : .retry
    }

    /// Atomically records a known outcome before starting any Helix request.
    func finalizeRedemptionIntake(
        _ intake: TwitchRedemptionResolutionOutbox.Item,
        as resolution: TwitchChannelPointsService.Resolution
    ) {
        do {
            let item = try redemptionResolutionOutbox.updateResolution(
                intake.id,
                to: resolution)
            startPersistedRedemptionResolution(item)
        } catch {
            Log.error(
                "TwitchChatService: Could not persist \(resolution.rawValue) outcome "
                    + "for redemption \(intake.redemptionID); intake remains for a "
                    + "startup refund: \(error.localizedDescription)",
                category: .twitchRedeem)
            beginRedemptionStorageFailureContainment(
                broadcasterID: intake.broadcasterID,
                rewardID: intake.rewardID,
                redemptionID: intake.redemptionID,
                resolution: resolution)
        }
    }

    /// Intake has no reconstructible queue result after a process exit or a
    /// canceled live pipeline. Persist the conservative refund before Helix.
    func resolveUnknownRedemptionIntake(
        _ intake: TwitchRedemptionResolutionOutbox.Item
    ) {
        finalizeRedemptionIntake(intake, as: .canceled)
    }

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

    nonisolated static func shouldRetryRedemptionResolution(status: Int) -> Bool {
        status == 408 || status == 425 || status == 429 || (500...599).contains(status)
    }

    private func clearRedemptionResolutionTask(_ id: UUID, workerID: UUID) {
        guard redemptionResolutionWorkerIDs[id] == workerID else { return }
        redemptionResolutionTasks[id] = nil
        redemptionResolutionWorkerIDs[id] = nil
    }

    func redemptionWorkIsCurrent(
        generation: UInt64,
        broadcasterID: String
    ) -> Bool {
        !Task.isCancelled
            && !broadcasterID.isEmpty
            && commandReplyIsCurrent(
                generation: generation,
                broadcasterID: broadcasterID
            )
    }

    /// Maps a request result to a chat message and a redemption resolution.
    func redemptionOutcome(
        for result: SongRequestService.RequestResult,
        username: String
    ) -> (message: String, resolution: TwitchChannelPointsService.Resolution) {
        switch result {
        case .cancelled:
            return ("", .canceled)
        case let .added(item, position):
            return (
                "@\(username) added \"\(item.title)\" by \(item.artist), #\(position) in queue",
                .fulfilled)
        case let .pendingApproval(item):
            // ponytail: fulfill on submit-to-review. A later reject can't refund
            // points once the redemption is resolved, so approval-mode redemptions
            // consume points on request, not on approval.
            return (
                "@\(username) sent \"\(item.title)\" by \(item.artist) to the streamer for approval.",
                .fulfilled)
        case let .queueFull(max):
            return ("@\(username) the queue is full (\(max)). Refunding your points.", .canceled)
        case let .userLimitReached(max):
            return ("@\(username) you already have \(max) songs queued. Refunding your points.", .canceled)
        case .alreadyInQueue:
            return ("@\(username) that song is already queued. Refunding your points.", .canceled)
        case .blocked:
            return ("@\(username) that song is on the blocklist. Refunding your points.", .canceled)
        case let .notFound(query):
            let truncated = StringFormatting.truncatedWithEllipsis(query)
            return ("@\(username) no results for \"\(truncated)\". Refunding your points.", .canceled)
        case .linkNotFound:
            return ("@\(username) couldn't find that on Apple Music. Refunding your points.", .canceled)
        case .notAuthorized:
            return ("@\(username) song requests aren't available right now. Refunding your points.", .canceled)
        case .featureDisabled:
            return ("@\(username) song requests are off right now. Refunding your points.", .canceled)
        case let .error(message):
            return ("@\(username) \(message) Refunding your points.", .canceled)
        }
    }

    /// Builds a chat reply for a bit-cheer song request.
    func bitsOutcomeMessage(
        for result: SongRequestService.RequestResult,
        username: String
    ) -> String {
        switch result {
        case .cancelled:
            return ""
        case let .added(item, position):
            return "@\(username) added \"\(item.title)\" by \(item.artist), #\(position) in queue. Thanks for the bits!"
        case let .pendingApproval(item):
            return "@\(username) sent \"\(item.title)\" by \(item.artist) to the streamer for approval. Thanks for the bits!"
        case let .queueFull(max):
            return "@\(username) the queue is full (\(max)/\(max)). Try again soon!"
        case let .userLimitReached(max):
            return "@\(username) you already have \(max) songs queued."
        case .alreadyInQueue:
            return "@\(username) that song is already in the queue."
        case .blocked:
            return "@\(username) sorry, that song/artist is on the blocklist."
        case let .notFound(query):
            let truncated = StringFormatting.truncatedWithEllipsis(query)
            return "@\(username) no results for \"\(truncated)\"."
        case .linkNotFound:
            return "@\(username) couldn't find that on Apple Music."
        case .notAuthorized:
            return "@\(username) song requests aren't available right now."
        case .featureDisabled:
            return "@\(username) song requests are off right now."
        case let .error(message):
            return "@\(username) \(message)"
        }
    }

    /// Current broadcaster credentials for Helix channel-point calls, or `nil`
    /// when any credential is missing.
    func currentChannelPointCredentials() -> TwitchChannelPointsService.Credentials? {
        guard let broadcasterID, let token = oauthToken, let clientID,
              !broadcasterID.isEmpty, !token.isEmpty, !clientID.isEmpty else { return nil }
        return TwitchChannelPointsService.Credentials(
            broadcasterID: broadcasterID, token: token, clientID: clientID)
    }

    /// Configured channel-point cost for the managed reward (default 500).
    nonisolated func channelPointsCostSetting() -> Int {
        Preferences.int(AppConstants.UserDefaults.songRequestChannelPointsCost, default: AppConstants.UserDefaults.Defaults.songRequestChannelPointsCost)
    }

    /// Configured minimum bits required to trigger a request (default 100).
    nonisolated func bitsMinimumSetting() -> Int {
        Preferences.int(AppConstants.UserDefaults.songRequestBitsMinimum, default: AppConstants.UserDefaults.Defaults.songRequestBitsMinimum)
    }

    /// Persists the redemption integration health for the settings UI.
    nonisolated func setRedemptionStatus(_ status: RedemptionStatus) {
        DefaultsStore.store.set(
            status.rawValue, forKey: AppConstants.UserDefaults.songRequestRedemptionStatus)
    }

    /// Extracts the viewer's song query from a `channel.bits.use` message,
    /// dropping cheermote tokens.
    nonisolated static func cleanBitsMessage(_ message: [String: Any]?) -> String {
        guard let message else { return "" }

        if let fragments = message["fragments"] as? [[String: Any]] {
            let textParts = fragments.compactMap { fragment -> String? in
                guard (fragment["type"] as? String) == "text" else { return nil }
                return fragment["text"] as? String
            }
            let joined = textParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { return joined }
        }

        let raw = (message["text"] as? String) ?? ""
        return stripLeadingCheermotes(raw)
    }

    /// Cached compiled pattern for the leading-cheermote strip. Compiling it per call on the
    /// hot chat path was wasteful. NSRegularExpression is thread-safe for matching.
    private nonisolated static let cheermotePrefixRegex = try? NSRegularExpression(
        pattern: "^(?:[Cc]heer[0-9]+\\s*)+")

    /// Removes leading `Cheer<amount>` tokens from a raw cheer message.
    nonisolated static func stripLeadingCheermotes(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let regex = cheermotePrefixRegex,
            let match = regex.firstMatch(
                in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
            let range = Range(match.range, in: trimmed)
        else {
            return trimmed
        }
        var stripped = trimmed
        stripped.removeSubrange(range)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
