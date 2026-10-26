//
//  DiscordNotPlayingChoice.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-26.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// The Discord pane's "When you pause" choice. Picker tags over the stored
/// `discordClearWhilePaused` Bool, which stays the key so backups and existing
/// choices carry over unchanged.
nonisolated enum DiscordPauseChoice: String, CaseIterable, Sendable {
    /// The song stays on the profile with a paused badge (`clearWhilePaused == false`).
    case keepSong
    /// The paused song is hidden and the profile shows the stop choice
    /// (`clearWhilePaused == true`).
    case hideSong

    /// The choice a stored `discordClearWhilePaused` value means.
    init(clearWhilePaused: Bool) {
        self = clearWhilePaused ? .hideSong : .keepSong
    }

    /// The value written back to `discordClearWhilePaused`.
    var clearWhilePaused: Bool { self == .hideSong }
}

/// The Discord pane's "When music stops" choice. Picker tags over the stored
/// `discordShowIdleStatus` Bool.
nonisolated enum DiscordStopChoice: String, CaseIterable, Sendable {
    /// A song-less "Listening to WolfWave" activity (`showIdleStatus == true`).
    case showWolfWave
    /// The Discord status is cleared (`showIdleStatus == false`).
    case showNothing

    /// The choice a stored `discordShowIdleStatus` value means.
    init(showIdleStatus: Bool) {
        self = showIdleStatus ? .showWolfWave : .showNothing
    }

    /// The value written back to `discordShowIdleStatus`.
    var showIdleStatus: Bool { self == .showWolfWave }
}

/// What the Discord profile actually shows for a playback situation, given
/// both choices. Mirrors `DiscordRPCService.updatePresence` /
/// `applyNoTrackPreference`, so the pane's copy can be tested against it.
nonisolated enum DiscordProfileOutcome: Equatable, Sendable {
    /// The track, live or with a paused badge.
    case song
    /// The song-less "Listening to WolfWave" activity.
    case listeningToWolfWave
    /// No activity at all.
    case nothing

    /// Resolves the outcome.
    ///
    /// - Parameters:
    ///   - isPaused: A track is loaded but paused. `false` means playing.
    ///   - isStopped: Nothing is loaded (stopped, or Music closed).
    ///   - pause: The "When you pause" choice.
    ///   - stop: The "When music stops" choice.
    static func resolve(
        isPaused: Bool,
        isStopped: Bool,
        pause: DiscordPauseChoice,
        stop: DiscordStopChoice
    ) -> DiscordProfileOutcome {
        if !isStopped && !(isPaused && pause == .hideSong) {
            return .song
        }
        return stop == .showWolfWave ? .listeningToWolfWave : .nothing
    }
}
