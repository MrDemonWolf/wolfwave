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
///
/// Keys are (service instance, broadcaster). Generations are the service's
/// `channelOwnershipGeneration`, which only grows on an explicit join, so a
/// teardown at generation N blocks setup from N and earlier but not from a
/// newer join. All state sits behind one lock, so every member is safe to call
/// from any isolation.
nonisolated enum TwitchRedemptionTeardownGate {
    /// Proof that a reward setup is in progress. Pass it back to `endSetup`.
    /// `@unchecked` only because `Owner` holds an `ObjectIdentifier`; the
    /// fields are immutable.
    struct SetupLease: @unchecked Sendable {
        let id: UUID
        fileprivate let owner: Owner
        fileprivate let generation: UInt64
    }

    /// One service instance acting for one broadcaster.
    fileprivate struct Owner: Hashable {
        let serviceID: ObjectIdentifier
        let broadcasterID: String
    }

    /// Guards the three tables below. `nonisolated(unsafe)` is sound only
    /// because every access goes through this lock.
    private static let lock = NSLock()
    /// Reward setups in flight, by lease ID.
    private nonisolated(unsafe) static var setups: [UUID: SetupLease] = [:]
    /// The ownership generation each owner is currently tearing down.
    private nonisolated(unsafe) static var teardownGenerations: [Owner: UInt64] = [:]
    /// Storage-failure containment tasks in flight, by task ID.
    private nonisolated(unsafe) static var containments: [UUID: Owner] = [:]

    /// Registers a reward setup.
    ///
    /// - Returns: `nil` when a teardown at this generation or later is in
    ///   progress, so setup must not start. A newer generation clears an
    ///   older teardown record and proceeds.
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

    /// Releases a lease from `beginSetup`.
    static func endSetup(_ lease: SetupLease) {
        lock.withLock {
            guard setups[lease.id]?.generation == lease.generation else {
                return
            }
            setups[lease.id] = nil
        }
    }

    /// Records a teardown at `generation`.
    ///
    /// - Returns: `false` when a teardown for a newer generation is already
    ///   recorded; this older one must not proceed.
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

    /// Whether the recorded teardown for this owner is still `generation`
    /// (not cancelled or replaced).
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

    /// Clears the teardown record, but only if it is still `generation`.
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

    /// Whether any setup started at `generation` or earlier is still running.
    /// Teardown waits for these before its final pause.
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

    /// Registers a storage-failure containment task so teardown waits for it.
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

    /// Unregisters a containment task.
    static func endContainment(id: UUID) {
        lock.withLock {
            containments[id] = nil
        }
    }

    /// Drops every record for a service instance. Called from its `deinit`,
    /// since an `ObjectIdentifier` can be reused by a later allocation.
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

    /// Whether a containment task for this owner is still running.
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

/// Paid-event plumbing shared by channel-point and Bits handling: durable
/// outcome replay, fulfill / refund retries, storage-failure containment, and
/// the chat copy for each request result.
extension TwitchChatService {

    // Redemption EventSub subscriptions live in TwitchChatService+RedemptionSubscriptions.swift
    // Redemption event handlers live in TwitchChatService+RedemptionHandlers.swift

    // MARK: - Redemption Helpers

    /// Durably trips the local circuit breaker before launching HTTP cleanup.
    /// The task is tracked with other paid work so socket reconnects cannot
    /// cancel the pause/refund sequence after a viewer has spent points.
    ///
    /// Used when the outbox can't record an outcome. Sets the
    /// `storageUnavailable` banner, then loops (with backoff) pausing the reward
    /// and applying `resolution` until both are confirmed or no live account
    /// can act on the redemption.
    ///
    /// - Parameter resolution: Outcome to apply to the redemption, or `nil` to
    ///   only pause the reward (the redemption was already resolved).
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
    ///
    /// On success the outcome is replayed until Twitch accepts it. If the
    /// write fails the intake record stays on disk (refunded at next startup)
    /// and storage-failure containment starts.
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
    ///
    /// Added and sent-for-approval fulfill (points are spent); every refusal
    /// refunds. `.cancelled` refunds with an empty message, meaning no reply.
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
        case let .denied(message):
            return ("@\(username) \(message) Refunding your points.", .canceled)
        // The raw lookup text is logged by the service, never sent to chat.
        case .error:
            return ("@\(username) song search isn't working right now. Refunding your points.", .canceled)
        }
    }

    /// Builds a chat reply for a bit-cheer song request.
    ///
    /// Bits can't be refunded, so unlike `redemptionOutcome` there is no
    /// refund wording. Returns an empty string (no reply) for `.cancelled`.
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
        case let .denied(message):
            return "@\(username) \(message)"
        // The raw lookup text is logged by the service, never sent to chat.
        case .error:
            return "@\(username) song search isn't working right now."
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
