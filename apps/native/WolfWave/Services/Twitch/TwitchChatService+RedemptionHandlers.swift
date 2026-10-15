//
//  TwitchChatService+RedemptionHandlers.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-11.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Handlers for paid EventSub events: channel-point redemptions of the managed
/// reward, and Bits cheers. Each records its intent on disk before touching
/// the song queue, and its work outlives socket reconnects.
extension TwitchChatService {

    // MARK: - Redemption Event Handlers

    /// Handles a channel-point reward redemption. Ignores redemptions for any
    /// reward other than the WolfWave-managed one, routes the viewer's input
    /// into the song-request pipeline, then fulfils the redemption on success
    /// or cancels it (refunding the points) on failure.
    ///
    /// Synchronous: validates and records intake, then hands the queue work to
    /// a task tracked in `redemptionTasks`. Redemptions that are not
    /// UNFULFILLED, already acknowledged, or already owned by a live pipeline
    /// are skipped.
    func handleChannelPointsRedemption(_ payload: [String: Any]) {
        // Note: the enabled check happens inside the Task below (after we confirm
        // this is our reward), so a redemption that arrives while the feature is
        // off is refunded rather than silently swallowed.
        guard let event = payload["event"] as? [String: Any] else { return }

        let rewardID = ((event["reward"] as? [String: Any])?["id"] as? String) ?? ""
        let eventBroadcasterID = ((event["broadcaster_user_id"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rewardID.isEmpty,
              !eventBroadcasterID.isEmpty,
              TwitchManagedRewardStore.matches(
                TwitchManagedRewardStore.Identity(
                    rewardID: rewardID,
                    broadcasterID: eventBroadcasterID)
              ) else {
            return
        }

        let redemptionID = (event["id"] as? String) ?? ""
        let requesterLogin = (event["user_login"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let userName = ((event["user_name"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let userInput = ((event["user_input"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !redemptionID.isEmpty, !userName.isEmpty else { return }

        if let status = event["status"] as? String,
           status.caseInsensitiveCompare("unfulfilled") != .orderedSame {
            Log.info(
                "TwitchChatService: Skipping channel-point redemption \(redemptionID) with status \(status)",
                category: .twitchRedeem)
            return
        }

        if redemptionResolutionOutbox.hasAcknowledgedRedemption(
            broadcasterID: eventBroadcasterID,
            rewardID: rewardID,
            redemptionID: redemptionID
        ) {
            return
        }
        let songRequestService = self.songRequestService
        let generation = connectionGeneration

        // Once a storage write fails, every later delivery is contained without
        // touching the song queue. The reward pause closes future intake at
        // Twitch; any redemption already in flight is refunded best-effort.
        if redemptionResolutionOutbox.intakeStorageIsUnavailable() {
            beginRedemptionStorageFailureContainment(
                broadcasterID: eventBroadcasterID,
                rewardID: rewardID,
                redemptionID: redemptionID,
                resolution: .canceled)
            return
        }

        let intake: TwitchRedemptionResolutionOutbox.Item
        let inserted: Bool
        do {
            let result = try redemptionResolutionOutbox.enqueueIntake(
                broadcasterID: eventBroadcasterID,
                rewardID: rewardID,
                redemptionID: redemptionID
            )
            intake = result.item
            inserted = result.inserted
        } catch {
            // Do not touch the volatile queue unless the recovery intent is on
            // disk first. A write failure is safer than consuming points and
            // losing the only record that they still need to be resolved.
            Log.error(
                "TwitchChatService: Could not persist redemption intake \(redemptionID): \(error.localizedDescription)",
                category: .twitchRedeem)
            beginRedemptionStorageFailureContainment(
                broadcasterID: eventBroadcasterID,
                rewardID: rewardID,
                redemptionID: redemptionID,
                resolution: .canceled)
            return
        }

        if !inserted {
            // A live pipeline owns intake until it records the queue outcome.
            // Otherwise this is a duplicate delivery after a crash/cancel: an
            // unknown outcome must refund, while a known outcome can resume.
            guard redemptionTasks[intake.id] == nil else { return }
            if intake.isIntake {
                resolveUnknownRedemptionIntake(intake)
            } else {
                startPersistedRedemptionResolution(intake)
            }
            return
        }

        redemptionTasks[intake.id] = Task { [weak self] in
            await self?.runChannelPointsRedemption(
                intake: intake,
                rewardID: rewardID,
                redemptionID: redemptionID,
                userName: userName,
                userLogin: requesterLogin,
                userInput: userInput,
                service: songRequestService,
                generation: generation,
                broadcasterID: eventBroadcasterID)
            await self?.clearRedemptionTask(intake.id)
        }
    }

    /// Runs the channel-point redemption pipeline. Cancellation (disconnect or
    /// teardown) suppresses chat replies only; the redemption itself is always
    /// resolved (fulfil/refund is Helix HTTP, independent of the chat socket),
    /// so viewer points never strand in the pending state.
    private func runChannelPointsRedemption(
        intake: TwitchRedemptionResolutionOutbox.Item,
        rewardID: String,
        redemptionID: String,
        userName: String,
        userLogin: String?,
        userInput: String,
        service: SongRequestService?,
        generation: UInt64,
        broadcasterID: String
    ) async {
        guard let service,
              redemptionWorkIsCurrent(
                generation: generation,
                broadcasterID: broadcasterID
              ) else {
            // Service not wired up, or cancelled before starting: the points
            // were already spent, so refund rather than strand the redemption
            // in the pending state forever.
            finalizeRedemptionIntake(intake, as: .canceled)
            return
        }

        // Channel-point requests off (toggle flipped between subscribe and
        // redemption, or the reward wasn't paused in time): refund.
        guard DefaultsStore.store.bool(
            forKey: AppConstants.UserDefaults.songRequestChannelPointsEnabled) else {
            finalizeRedemptionIntake(intake, as: .canceled)
            await sendSessionBoundMessage(
                "@\(userName) channel-point song requests are off right now. Refunding your points.",
                replyTo: nil,
                generation: generation,
                broadcasterID: broadcasterID)
            return
        }

        if userInput.isEmpty {
            finalizeRedemptionIntake(intake, as: .canceled)
            await sendSessionBoundMessage(
                "@\(userName) add a song name when you redeem. Refunding your points.",
                replyTo: nil,
                generation: generation,
                broadcasterID: broadcasterID)
            return
        }

        let result = await service.processRequest(
            query: userInput,
            username: userLogin.flatMap { $0.isEmpty ? nil : $0 } ?? userName,
            source: .channelPoints(redemptionID: redemptionID, rewardID: rewardID),
            displayName: userName)
        let (message, resolution) = redemptionOutcome(for: result, username: userName)
        // Record the queue outcome before another suspension. If the process
        // exits while sending chat, replay still knows whether to fulfil or
        // refund instead of guessing from volatile queue state.
        finalizeRedemptionIntake(intake, as: resolution)
        if !message.isEmpty {
            await sendSessionBoundMessage(
                message,
                replyTo: nil,
                generation: generation,
                broadcasterID: broadcasterID)
        }
    }

    /// Drops a finished redemption pipeline task from the tracking table.
    private func clearRedemptionTask(_ id: UUID) {
        redemptionTasks[id] = nil
    }

    /// Handles a `channel.bits.use` event. The complete action is durable
    /// before queue mutation, so a crash replays pending work instead of losing
    /// a paid request or relying on the bounded transport dedup cache.
    ///
    /// Only `cheer`-type events from the joined channel at or above the
    /// configured minimum count. If the outbox write fails, the event runs from
    /// an in-memory fallback instead of being dropped.
    ///
    /// - Parameter eventSubMessageID: The frame's `message_id`, used as the
    ///   durable dedup key for this cheer.
    func handleBitsUse(
        _ payload: [String: Any],
        eventSubMessageID: String
    ) {
        let defaults = DefaultsStore.store
        guard
            defaults.bool(forKey: AppConstants.UserDefaults.songRequestBitsEnabled),
            let event = payload["event"] as? [String: Any],
            event["type"] as? String == "cheer"
        else { return }

        let bits = (event["bits"] as? Int) ?? 0
        guard bits > 0, bits >= bitsMinimumSetting() else { return }

        let userName = ((event["user_name"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let eventBroadcasterID = ((event["broadcaster_user_id"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userName.isEmpty,
              !eventBroadcasterID.isEmpty,
              eventBroadcasterID == broadcasterID else {
            return
        }

        guard !volatileBitsFallbackIsClaimed(
            messageID: eventSubMessageID,
            broadcasterID: eventBroadcasterID
        ) else {
            return
        }

        let boostEnabled = defaults.bool(
            forKey: AppConstants.UserDefaults.songRequestBitsBoostEnabled)
        let query = Self.cleanBitsMessage(event["message"] as? [String: Any])
        let userLogin = (event["user_login"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        do {
            let result = try redemptionResolutionOutbox.enqueueBits(
                messageID: eventSubMessageID,
                broadcasterID: eventBroadcasterID,
                userName: userName,
                bits: bits,
                boostEnabled: boostEnabled,
                query: query,
                userLogin: userLogin)
            guard let item = result.item else { return }
            startBitsEvent(
                item,
                requiresDurableAcknowledgement: true,
                generation: connectionGeneration)
        } catch {
            setRedemptionStatus(.storageUnavailable)
            Log.error(
                "TwitchChatService: Could not persist Bits intake "
                    + "\(eventSubMessageID); using process-owned fallback - "
                    + error.localizedDescription,
                category: .twitchRedeem)
            guard let fallback = claimVolatileBitsFallback(
                messageID: eventSubMessageID,
                broadcasterID: eventBroadcasterID,
                userName: userName,
                bits: bits,
                boostEnabled: boostEnabled,
                query: query,
                userLogin: userLogin
            ) else {
                return
            }
            startBitsEvent(
                fallback,
                requiresDurableAcknowledgement: false,
                generation: connectionGeneration)
        }
    }

    /// Drops completed fallbacks older than the paid-event tombstone window.
    /// Incomplete ones, and any with a running task, are kept.
    private func pruneVolatileBitsFallbacks(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(
            -TwitchRedemptionResolutionOutbox.paidEventTombstoneRetention)
        volatileBitsFallbacks = volatileBitsFallbacks.filter {
            !$0.value.completed
                || $0.value.claimedAt >= cutoff
                || paidRedemptionTasks[$0.value.item.id] != nil
        }
    }

    /// Whether this cheer is already held in the in-memory fallback, which
    /// means it was seen while the outbox was failing and must not run again.
    private func volatileBitsFallbackIsClaimed(
        messageID: String,
        broadcasterID: String
    ) -> Bool {
        pruneVolatileBitsFallbacks()
        return volatileBitsFallbacks[
            VolatileBitsFallbackKey(
                messageID: messageID,
                broadcasterID: broadcasterID)
        ] != nil
    }

    /// Records a cheer in the in-memory fallback.
    ///
    /// - Returns: The new item to run, or `nil` when this cheer was already
    ///   claimed.
    private func claimVolatileBitsFallback(
        messageID: String,
        broadcasterID: String,
        userName: String,
        bits: Int,
        boostEnabled: Bool,
        query: String,
        userLogin: String? = nil
    ) -> TwitchRedemptionResolutionOutbox.BitsItem? {
        pruneVolatileBitsFallbacks()
        let key = VolatileBitsFallbackKey(
            messageID: messageID,
            broadcasterID: broadcasterID)
        guard volatileBitsFallbacks[key] == nil else { return nil }
        let now = Date()
        let item = TwitchRedemptionResolutionOutbox.BitsItem(
            id: UUID(),
            messageID: messageID,
            broadcasterID: broadcasterID,
            userName: userName,
            bits: bits,
            boostEnabled: boostEnabled,
            query: query,
            createdAt: now,
            userLogin: userLogin)
        volatileBitsFallbacks[key] = VolatileBitsFallback(
            item: item,
            claimedAt: now,
            completed: false)
        return item
    }

    /// Marks a fallback as applied so it is kept only as a duplicate guard.
    /// Ignored if the stored entry is a different item for the same key.
    private func completeVolatileBitsFallback(
        _ item: TwitchRedemptionResolutionOutbox.BitsItem
    ) {
        let key = VolatileBitsFallbackKey(
            messageID: item.messageID,
            broadcasterID: item.broadcasterID)
        guard var fallback = volatileBitsFallbacks[key],
              fallback.item.id == item.id else {
            return
        }
        fallback.completed = true
        volatileBitsFallbacks[key] = fallback
    }

    /// In-memory Bits items not yet applied, oldest first, optionally limited
    /// to one broadcaster. Teardown checks these before clearing credentials.
    func pendingVolatileBitsFallbackItems(
        broadcasterID: String? = nil
    ) -> [TwitchRedemptionResolutionOutbox.BitsItem] {
        pruneVolatileBitsFallbacks()
        return volatileBitsFallbacks.values
            .filter {
                !$0.completed
                    && (broadcasterID == nil
                        || $0.item.broadcasterID == broadcasterID)
            }
            .map(\.item)
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Replays pending Bits work only for the active broadcaster. The request
    /// queue is intentionally process-local, so a process crash after queue
    /// mutation loses that volatile mutation and replay applies it exactly once
    /// to the fresh queue. In-process workers are retained until acknowledgement.
    func replayPendingBitsEvents() {
        guard let broadcasterID, songRequestService != nil else { return }
        pruneVolatileBitsFallbacks()
        let generation = connectionGeneration
        for item in redemptionResolutionOutbox.pendingBitsItems(
            broadcasterID: broadcasterID
        ) {
            startBitsEvent(
                item,
                requiresDurableAcknowledgement: true,
                generation: generation)
        }
        for fallback in volatileBitsFallbacks.values
        where fallback.item.broadcasterID == broadcasterID
            && !fallback.completed {
            startBitsEvent(
                fallback.item,
                requiresDurableAcknowledgement: false,
                generation: generation)
        }
    }

    /// Starts a task that applies one Bits item, unless one is already running
    /// for it, there is no song request service, or it is for another channel.
    ///
    /// After applying, a durable item is acknowledged in the outbox (with
    /// retries) and a fallback item is marked complete. Only then is the chat
    /// reply sent, and only to the session given by `generation`.
    private func startBitsEvent(
        _ item: TwitchRedemptionResolutionOutbox.BitsItem,
        requiresDurableAcknowledgement: Bool,
        generation: UInt64
    ) {
        guard paidRedemptionTasks[item.id] == nil,
              let service = songRequestService,
              broadcasterID == item.broadcasterID else {
            return
        }
        paidRedemptionTasks[item.id] = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.applyPersistedBitsEvent(
                item,
                service: service)
            guard outcome.applied else {
                await self.clearPaidRedemptionTask(item.id)
                return
            }
            if requiresDurableAcknowledgement {
                guard await self.acknowledgeBitsEventWithRetry(item) else {
                    await self.clearPaidRedemptionTask(item.id)
                    return
                }
            } else {
                await self.completeVolatileBitsFallback(item)
            }
            if let message = outcome.message, !message.isEmpty {
                await self.sendSessionBoundMessage(
                    message,
                    replyTo: nil,
                    generation: generation,
                    broadcasterID: item.broadcasterID)
            }
            await self.clearPaidRedemptionTask(item.id)
        }
    }

    /// Performs the Bits action: boost the viewer's oldest queued song when
    /// boost is on and they have one, otherwise request the cheer's text.
    ///
    /// - Returns: `applied` is `false` when cancelled or the request pipeline
    ///   returned `.cancelled`, so the item stays pending. `message` is the
    ///   chat reply, if any.
    private func applyPersistedBitsEvent(
        _ item: TwitchRedemptionResolutionOutbox.BitsItem,
        service: SongRequestService
    ) async -> (applied: Bool, message: String?) {
        guard !Task.isCancelled else { return (false, nil) }

        if item.boostEnabled,
           let boosted = await service.boost(username: item.userLogin.flatMap { $0.isEmpty ? nil : $0 } ?? item.userName) {
            return (
                true,
                "@\(item.userName) boosted \"\(boosted.title)\" to the front of the queue! (\(item.bits) bits)")
        }

        guard !Task.isCancelled else { return (false, nil) }
        guard !item.query.isEmpty else {
            let message = item.boostEnabled
                ? "@\(item.userName) no song of yours to boost. Include a song name in your cheer to request one."
                : nil
            return (true, message)
        }

        let result = await service.processRequest(
            query: item.query,
            username: item.userLogin.flatMap { $0.isEmpty ? nil : $0 } ?? item.userName,
            source: .bits(amount: item.bits),
            displayName: item.userName)
        if case .cancelled = result {
            return (false, nil)
        }
        return (
            true,
            bitsOutcomeMessage(for: result, username: item.userName))
    }

    /// Retries only the local atomic acknowledgement; the paid queue action is
    /// never repeated in-process after it has been applied.
    private func acknowledgeBitsEventWithRetry(
        _ item: TwitchRedemptionResolutionOutbox.BitsItem
    ) async -> Bool {
        var attempt = 0
        while !Task.isCancelled {
            do {
                try redemptionResolutionOutbox.acknowledgeBits(item.id)
                return true
            } catch {
                setRedemptionStatus(.storageUnavailable)
                Log.error(
                    "TwitchChatService: Bits action \(item.messageID) completed "
                        + "but its durable acknowledgement failed - "
                        + error.localizedDescription,
                    category: .twitchRedeem)
                attempt += 1
                guard await sleepBeforeRedemptionRetry(
                    attempt: attempt,
                    retryAfter: nil
                ) else {
                    return false
                }
            }
        }
        return false
    }

    /// Drops a finished Bits task from `paidRedemptionTasks`.
    private func clearPaidRedemptionTask(_ id: UUID) {
        paidRedemptionTasks[id] = nil
    }

    /// Drops a finished containment task. Releases its teardown-gate entry only
    /// when `releasingGate` is `true` (the containment settled or can never
    /// act); an unsettled one stays registered so teardown keeps waiting.
    func clearContainmentTask(
        _ id: UUID,
        releasingGate: Bool
    ) {
        paidRedemptionTasks[id] = nil
        if releasingGate {
            TwitchRedemptionTeardownGate.endContainment(id: id)
        }
    }
}
