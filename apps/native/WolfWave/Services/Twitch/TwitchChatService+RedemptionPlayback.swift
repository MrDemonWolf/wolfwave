//
//  TwitchChatService+RedemptionPlayback.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-11-23.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Keeps a channel-point redemption open while its song waits in the request
/// queue, then fulfils it when the song plays or refunds it when the song
/// leaves the queue without playing (undo, mod remove, decline, clear,
/// unplayable).
///
/// The redemption simply stays in the durable intake phase, so crash safety
/// is unchanged: the queue lives in memory, and after a quit or crash the
/// startup replay refunds every leftover intake item. While the app runs,
/// ``queuedRedemptionIntakeIDs`` marks those items as owned, so replay,
/// duplicate delivery, and reconcile leave them alone.
extension TwitchChatService {

    /// Whether a live pipeline or a waiting song owns this intake item. Owned
    /// intake is never refunded as "unknown".
    func intakeIsOwned(_ id: UUID) -> Bool {
        redemptionTasks[id] != nil || intakeAwaitsPlayback(id)
    }

    /// Whether this intake item belongs to a song still waiting to play.
    func intakeAwaitsPlayback(_ id: UUID) -> Bool {
        queuedRedemptionIntakeIDs.values.contains(id)
    }

    /// Whether a request result leaves the song waiting (queued, not yet
    /// playing, or held for approval), so its redemption should stay open.
    static func waitsForPlayback(_ result: SongRequestService.RequestResult) -> Bool {
        switch result {
        case let .added(_, _, wait):
            return wait != .playingNow
        case .pendingApproval:
            return true
        default:
            return false
        }
    }

    /// Marks an intake item as owned by its waiting song. Skipped when the
    /// queue already settled it (a song can start or be removed while the
    /// pipeline was still awaiting `processRequest`).
    func holdRedemptionUntilPlayback(_ intake: TwitchRedemptionResolutionOutbox.Item) {
        let current = redemptionResolutionOutbox.pendingItems().first { $0.id == intake.id }
        guard current?.isIntake == true else { return }
        queuedRedemptionIntakeIDs[intake.redemptionID] = intake.id
    }

    /// Drops the waiting-song mark for an item.
    func releasePlaybackHold(for item: TwitchRedemptionResolutionOutbox.Item) {
        if queuedRedemptionIntakeIDs[item.redemptionID] == item.id {
            queuedRedemptionIntakeIDs[item.redemptionID] = nil
        }
    }

    /// Resolves an intake item before credentials go away. A waiting song
    /// stays queued and will still play, but these credentials can't settle
    /// it later, so it's fulfilled now; any other intake is unknown and refunded.
    func settleIntakeForTeardown(_ item: TwitchRedemptionResolutionOutbox.Item) {
        if intakeAwaitsPlayback(item.id) {
            releasePlaybackHold(for: item)
            finalizeRedemptionIntake(item, as: .fulfilled)
        } else {
            resolveUnknownRedemptionIntake(item)
        }
    }

    /// Settles the redemption behind a queued song: fulfil when it played,
    /// refund when it left without playing. A no-op when the redemption is
    /// already resolved (resolutions are immutable), so a late or repeated
    /// report can't flip a fulfil into a refund.
    ///
    /// - Parameters:
    ///   - redemptionID: Twitch redemption ID from the queue item.
    ///   - rewardID: Reward ID from the queue item.
    ///   - played: `true` when the song started playing.
    func settleQueuedRedemption(redemptionID: String, rewardID: String, played: Bool) {
        guard let item = redemptionResolutionOutbox.pendingItems().first(where: {
            $0.redemptionID == redemptionID && $0.rewardID == rewardID && $0.isIntake
        }) else {
            queuedRedemptionIntakeIDs[redemptionID] = nil
            return
        }
        releasePlaybackHold(for: item)
        Log.info(
            "TwitchChatService: Queued redemption \(redemptionID) "
                + (played ? "played; fulfilling" : "left the queue; refunding"),
            category: .twitchRedeem)
        finalizeRedemptionIntake(item, as: played ? .fulfilled : .canceled)
    }
}
