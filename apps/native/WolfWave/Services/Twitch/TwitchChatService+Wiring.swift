//
//  TwitchChatService+Wiring.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Startup wiring: song-request collaborators, track-info providers, and
/// the toggles AppDelegate and the view model set before connecting.
extension TwitchChatService {

    // MARK: - Wiring (called once at app startup)

    /// Wire the song request service into the command dispatcher.
    /// Hops to `MainActor` because `BotCommandDispatcher` is `@MainActor`.
    func setSongRequestService(callback: @escaping @Sendable () -> SongRequestService?) async {
        await MainActor.run { commandDispatcher.setSongRequestService(callback: callback) }
    }

    /// Wire the song request queue into the command dispatcher.
    func setSongRequestQueue(callback: @escaping @Sendable () -> SongRequestQueue?) async {
        await MainActor.run { commandDispatcher.setSongRequestQueue(callback: callback) }
    }

    /// Wire the skip-vote manager into the command dispatcher.
    func setSkipVoteManager(callback: @escaping @Sendable () -> SkipVoteManager?) async {
        await MainActor.run { commandDispatcher.setSkipVoteManager(callback: callback) }
    }

    /// Set the live `SongRequestService` used by redemption handlers.
    ///
    /// Passing a non-nil service also replays Bits events that were persisted
    /// while no service was available to apply them.
    func setSongRequestServiceReference(_ service: SongRequestService?) {
        self.songRequestService = service
        if service != nil {
            replayPendingBitsEvents()
        }
    }

    /// Provide the `!song` lookup. Called from MainActor by AppDelegate.
    nonisolated func setCurrentSongInfoProvider(_ provider: (@Sendable () async -> String)?) {
        providers.setCurrent(provider)
    }

    /// Provide the `!last` lookup.
    nonisolated func setLastSongInfoProvider(_ provider: (@Sendable () async -> String)?) {
        providers.setLast(provider)
    }

    /// Provide the `!stats` lookup.
    nonisolated func setStatsInfoProvider(_ provider: (@Sendable () async -> String)?) {
        providers.setStats(provider)
    }

    /// Toggle whether the connection confirmation message is sent on subscribe.
    /// `TwitchViewModel` turns it on for a user-initiated join; the launch
    /// auto-reconnect in `AppDelegate` turns it off. Set before connecting.
    func setShouldSendConnectionMessageOnSubscribe(_ value: Bool) {
        self.shouldSendConnectionMessageOnSubscribe = value
    }
}
