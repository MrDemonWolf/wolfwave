//
//  SongRequestService+Corrections.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-11-23.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Fixing the queue from chat (`!wrongsong`, `!removesong`) and the rough
/// wait time a viewer sees when their request is added.
extension SongRequestService {

    // MARK: - Wait Estimate

    /// Roughly how long until a request plays, for the chat reply.
    nonisolated enum RequestWait: Equatable, Sendable {
        /// It's playing now.
        case playingNow
        /// Less than a minute away.
        case upNext
        /// About this many minutes away (at least 1).
        case minutes(Int)
        /// Requests are on hold, so there's no estimate.
        case onHold
        /// Music isn't open; it plays once the music starts.
        case whenMusicStarts
    }

    /// The rough wait for a request at a 1-based live-queue position: the time
    /// left in the current track plus the songs ahead of it.
    ///
    /// - Parameters:
    ///   - item: The request, used to spot one that already started.
    ///   - position: Its 1-based position when it was added.
    func estimatedWait(for item: SongRequestItem, position: Int) -> RequestWait {
        if queue.nowPlaying?.id == item.id { return .playingNow }
        return estimatedWait(forPosition: position)
    }

    /// The rough wait for whatever sits at a 1-based live-queue position.
    func estimatedWait(forPosition position: Int) -> RequestWait {
        if isHoldEnabled { return .onHold }
        guard musicController.isMusicAppRunning else { return .whenMusicStarts }
        let remaining = currentTrackRemaining?() ?? 0
        return Self.wait(forSeconds: max(0, remaining) + queue.secondsAhead(ofPosition: position))
    }

    /// Buckets a wait in seconds: under a minute is "up next", otherwise whole
    /// minutes rounded to the nearest.
    nonisolated static func wait(forSeconds seconds: TimeInterval) -> RequestWait {
        guard seconds.isFinite, seconds >= 60 else { return .upNext }
        return .minutes(Int((seconds / 60).rounded()))
    }

    // MARK: - Viewer Undo

    /// What `!wrongsong` did.
    enum UndoOutcome: Equatable {
        /// The viewer's latest waiting request was removed. A channel-point
        /// request is refunded through the queue's settlement hook.
        case removed(SongRequestItem)
        /// They have nothing waiting to undo.
        case nothingToUndo
    }

    /// Removes the viewer's most recent request that hasn't started playing.
    /// Channel points spent on it are refunded (the redemption stays open
    /// until the song plays, and the queue reports the removal).
    ///
    /// - Parameter requesterLogin: The viewer's Twitch login.
    func undoLatestRequest(requesterLogin: String) -> UndoOutcome {
        guard let latest = queue.latestWaiting(requester: requesterLogin),
              let removed = queue.removeWaiting(id: latest.id) else { return .nothingToUndo }
        Log.info("SongRequestService: \(requesterLogin) undid \"\(removed.title)\"", category: .songRequest)
        return .removed(removed)
    }

    // MARK: - Mod Remove

    /// Which requests `!removesong` targets.
    nonisolated enum RemoveTarget: Equatable, Sendable {
        /// The live-queue song at this 1-based position.
        case position(Int)
        /// Every waiting request from this Twitch login.
        case requester(String)
    }

    /// Removes the targeted requests. The now-playing song is never removed
    /// here; mods use `!skip` for that.
    ///
    /// - Returns: The removed items (empty when nothing matched).
    @discardableResult
    func removeRequests(_ target: RemoveTarget) -> [SongRequestItem] {
        let removed: [SongRequestItem]
        switch target {
        case .position(let position):
            removed = queue.remove(atPosition: position).map { [$0] } ?? []
        case .requester(let login):
            removed = queue.removeAll(requester: login)
        }
        if !removed.isEmpty {
            Log.info("SongRequestService: Mod removed \(removed.count) request(s)", category: .songRequest)
        }
        return removed
    }
}
