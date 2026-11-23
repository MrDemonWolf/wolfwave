//
//  SongContentFilter.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-11-23.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// The streamer's content rules for a resolved song: explicit tracks and a
/// maximum length.
///
/// Pure and `nonisolated`, so the decision is testable without MusicKit. The
/// service reads the stored settings with ``current(in:)`` and asks
/// ``refusal(isExplicit:durationSeconds:)`` about each resolved song.
nonisolated struct SongContentFilter: Equatable, Sendable {
    /// Why a song was refused.
    enum Refusal: Equatable, Sendable {
        /// Apple Music marks the song explicit and the filter is on.
        case explicit
        /// The song runs longer than the limit. Both values are whole seconds.
        case tooLong(durationSeconds: Int, maxSeconds: Int)
    }

    /// Refuse songs Apple Music marks explicit.
    let blocksExplicit: Bool

    /// Longest allowed song in seconds. `0` means no limit.
    let maxSeconds: Int

    /// Reads the stored rules.
    ///
    /// - Parameter defaults: Store to read. Defaults to `DefaultsStore.store`.
    static func current(in defaults: Foundation.UserDefaults = DefaultsStore.store) -> SongContentFilter {
        let blocks = defaults.object(forKey: AppConstants.UserDefaults.songRequestBlockExplicit) as? Bool
            ?? AppConstants.UserDefaults.Defaults.songRequestBlockExplicit
        let maxSeconds = defaults.object(forKey: AppConstants.UserDefaults.songRequestMaxSongSeconds) as? Int
            ?? AppConstants.UserDefaults.Defaults.songRequestMaxSongSeconds
        return SongContentFilter(blocksExplicit: blocks, maxSeconds: max(0, maxSeconds))
    }

    /// Whether a song breaks a rule, and which one. Explicit is checked first.
    ///
    /// - Parameters:
    ///   - isExplicit: Apple Music's explicit flag for the song.
    ///   - durationSeconds: The song's length, or `nil` when Apple Music
    ///     didn't say. An unknown length never counts as too long.
    /// - Returns: The rule the song breaks, or `nil` when it's allowed.
    func refusal(isExplicit: Bool, durationSeconds: TimeInterval?) -> Refusal? {
        if blocksExplicit && isExplicit { return .explicit }
        if maxSeconds > 0, let durationSeconds, durationSeconds.isFinite,
           Int(durationSeconds.rounded()) > maxSeconds {
            return .tooLong(durationSeconds: Int(durationSeconds.rounded()), maxSeconds: maxSeconds)
        }
        return nil
    }

    /// Formats whole seconds as `m:ss` for chat, for example `9:41`.
    static func clock(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }
}
