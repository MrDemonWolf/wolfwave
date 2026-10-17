//
//  SkipVoteManager+Configuration.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Vote-skip settings, read fresh from the preference store on every access
/// so a settings change applies to the next vote without reconfiguring the actor.
extension SkipVoteManager {

    // MARK: - Configuration

    /// Preference store, read fresh on every access so settings changes apply
    /// to the next vote without reconfiguring the actor.
    private nonisolated var defaults: Foundation.UserDefaults { DefaultsStore.store }

    /// Whether the vote-skip feature is enabled.
    nonisolated var isEnabled: Bool {
        defaults.bool(forKey: AppConstants.UserDefaults.voteSkipEnabled)
    }

    /// Minimum unique voters required to skip. A stored value of 0 or less reads
    /// as the default (via `Preferences.int`), so it is always at least 1.
    ///
    /// Deliberately *not* snapped to the settings picker's allowlist. Both this
    /// and ``windowSeconds`` are used as plain integers, so neither can trap the
    /// way a `Double` feeding `Int(_:)` can, and narrowing them would silently
    /// move a working threshold (a stored `1` becoming `3`) for anyone whose
    /// value predates the current picker. The allowlist guards the control,
    /// which is where the crash was; the service keeps accepting any positive
    /// value.
    nonisolated var minVotes: Int {
        Preferences.int(AppConstants.UserDefaults.voteSkipMinVotes, default: AppConstants.UserDefaults.Defaults.voteSkipMinVotes)
    }

    /// How long a chat-tally session stays open, in seconds. Non-positive
    /// stored values fall back to the default.
    nonisolated var windowSeconds: Int {
        Preferences.int(AppConstants.UserDefaults.voteSkipWindowSeconds, default: AppConstants.UserDefaults.Defaults.voteSkipWindowSeconds)
    }

    /// Cooldown between sessions, in seconds. May legitimately be `0`.
    ///
    /// Clamped to `0...3600`: the key is user-writable (exportable settings
    /// backup, `defaults write`) and unclamped it flows into `Int(ceil(...))`
    /// at the cooldown branch, which traps on a non-finite/overflow value.
    nonisolated var sessionCooldown: TimeInterval {
        let value = Preferences.double(AppConstants.UserDefaults.voteSkipSessionCooldown, default: AppConstants.UserDefaults.Defaults.voteSkipSessionCooldown)
        return value.isFinite ? min(max(value, 0), 3600) : 0
    }

    /// Whether only subscribers may vote.
    nonisolated var isSubscriberOnly: Bool {
        defaults.bool(forKey: AppConstants.UserDefaults.voteSkipSubscriberOnly)
    }

    /// Whether vote-skip uses native Twitch Polls instead of a chat tally.
    nonisolated var usePolls: Bool {
        defaults.bool(forKey: AppConstants.UserDefaults.voteSkipUsePolls)
    }

    /// Twitch poll duration in seconds. Clamped to Twitch's 15-1800 range.
    nonisolated var pollDuration: Int {
        let value = Preferences.int(AppConstants.UserDefaults.voteSkipPollDuration, default: AppConstants.UserDefaults.Defaults.voteSkipPollDuration)
        return min(max(value, 15), 1800)
    }
}
