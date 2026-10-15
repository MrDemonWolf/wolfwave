//
//  FeatureFlags.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-28.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Typed accessors for the boolean feature toggles persisted in `UserDefaults`.
///
/// Centralizes the repeated `bool(forKey: AppConstants.UserDefaults.…)` pattern
/// so default semantics are defined once. Adding a new toggle means adding
/// one computed property here rather than hunting for every read site.
///
/// Every read goes through ``DefaultsStore/store``, never `UserDefaults.standard`,
/// so a hosted test or UI-test launch reads its isolated suite. Plain
/// `defaults.bool` reads report `false` for a key that was never written; a flag
/// whose default is `true` must go through `Preferences.bool(_:default:)` instead.
/// `@AppStorage` bindings in the views write the same keys directly.
nonisolated enum FeatureFlags {
    /// The one `UserDefaults` every flag reads.
    private static var defaults: Foundation.UserDefaults { DefaultsStore.store }

    // MARK: Integrations

    /// Discord Rich Presence preference. Default `false`. This is the stored
    /// setting, not whether the IPC socket is actually connected.
    static var discordEnabled: Bool {
        defaults.bool(forKey: AppConstants.UserDefaults.discordPresenceEnabled)
    }

    /// The shared overlay / Stream Deck WebSocket server switch. Default `false`.
    static var websocketEnabled: Bool {
        defaults.bool(forKey: AppConstants.UserDefaults.websocketEnabled)
    }

    /// Whether exportable preferences mirror to iCloud Key-Value Storage. Per Mac, never synced itself.
    static var iCloudSettingsSyncEnabled: Bool {
        defaults.bool(forKey: AppConstants.UserDefaults.iCloudSettingsSyncEnabled)
    }

    /// Whether the Stream Deck plugin may run commands. Independent of
    /// ``websocketEnabled``: the server keeps serving overlays when this is off,
    /// it just refuses every command with `error:"disabled"`.
    ///
    /// Reads through the explicit default rather than `defaults.bool`, which
    /// would report `false` for "never set" and disarm every Stream Deck already
    /// in the field on the first launch after update.
    static var streamDeckControlEnabled: Bool {
        Preferences.bool(
            AppConstants.UserDefaults.streamDeckControlEnabled,
            default: AppConstants.UserDefaults.Defaults.streamDeckControlEnabled
        )
    }

    /// Show an "Idle" Discord activity when nothing is playing instead of
    /// clearing the profile. Defaults to `true` on first launch; once
    /// `discordShowIdleStatus` has been explicitly written it returns the
    /// stored value.
    static var discordShowIdleStatus: Bool {
        Preferences.bool(AppConstants.UserDefaults.discordShowIdleStatus, default: true)
    }

    /// Opt-in: clear Discord presence while paused rather than keeping the
    /// loaded track on the profile. Default false.
    static var discordClearWhilePaused: Bool {
        defaults.bool(forKey: AppConstants.UserDefaults.discordClearWhilePaused)
    }

    /// The static widget HTTP server (serves `widget.html`). Default `false`.
    /// Read through `Preferences.bool` for consistency with the other
    /// defaulted flags; with a `false` default it behaves like `defaults.bool`.
    static var widgetHTTPEnabled: Bool {
        Preferences.bool(AppConstants.UserDefaults.widgetHTTPEnabled, default: false)
    }

    /// Whether to show sponsorship links (menu bar, app menu, About pane).
    /// Defaults to `true`; the About pane keeps the toggle so it can be turned
    /// back on after opting out.
    static var sponsorLinksEnabled: Bool {
        Preferences.bool(
            AppConstants.UserDefaults.sponsorLinksEnabled,
            default: AppConstants.UserDefaults.Defaults.sponsorLinksEnabled
        )
    }

    // MARK: Tracking & history

    /// Music tracking. Defaults to `true` on first launch; once `trackingEnabled`
    /// has been explicitly written it returns the stored value.
    static var trackingEnabled: Bool {
        Preferences.bool(AppConstants.UserDefaults.trackingEnabled, default: true)
    }

    /// Opt-in on-device listening history (play log + History & Stats). Default `false`.
    static var listeningHistoryEnabled: Bool {
        defaults.bool(forKey: AppConstants.UserDefaults.listeningHistoryEnabled)
    }

    // MARK: Song request

    /// Master switch for song requests from chat, channel points, and Bits.
    /// Default `false`.
    static var songRequestEnabled: Bool {
        defaults.bool(forKey: AppConstants.UserDefaults.songRequestEnabled)
    }

    /// Whether the request queue is held: new requests buffer without
    /// auto-playing. Default false (queue plays through).
    static var songRequestHoldEnabled: Bool {
        defaults.bool(forKey: AppConstants.UserDefaults.songRequestHoldEnabled)
    }

    /// Whether `!song` / `!last` replies append a song.link URL. Default `false`.
    static var songCommandSongLinkEnabled: Bool {
        defaults.bool(forKey: AppConstants.UserDefaults.songCommandSongLinkEnabled)
    }

    /// Opt-in macOS banner on every track change. Default `false`.
    static var songChangeNotificationsEnabled: Bool {
        defaults.bool(forKey: AppConstants.UserDefaults.songChangeNotificationsEnabled)
    }

    /// Master toggle for chat vote-to-skip. Gates the skip-vote notifications too.
    static var voteSkipEnabled: Bool {
        defaults.bool(forKey: AppConstants.UserDefaults.voteSkipEnabled)
    }

    /// Banner when a chat skip vote starts. Only honored while ``voteSkipEnabled`` is on.
    static var skipVoteStartedNotificationsEnabled: Bool {
        defaults.bool(forKey: AppConstants.UserDefaults.skipVoteStartedNotificationsEnabled)
    }

    /// Banner when a chat skip vote passes. Only honored while ``voteSkipEnabled`` is on.
    static var skipVotePassedNotificationsEnabled: Bool {
        defaults.bool(forKey: AppConstants.UserDefaults.skipVotePassedNotificationsEnabled)
    }

    // MARK: UI

    /// Streamer Mode: masks sensitive values on screen. UI-only; never changes
    /// what services send. Default `false`.
    static var streamerModeEnabled: Bool {
        defaults.bool(forKey: AppConstants.UserDefaults.streamerModeEnabled)
    }
}
