//
//  AppConstants+UserDefaultsExport.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Backup / iCloud-sync classification of the keys declared in
/// `AppConstants+UserDefaults.swift`: the import rule for every portable key,
/// plus the account-linked and runtime-state lists that never travel.
///
/// Every key constant stays in that file; add a new key there first, then
/// classify it here. `SettingsBackupKeyCoverageTests` fails until you do.
nonisolated extension AppConstants.UserDefaults {

    // MARK: Export / Import Classification

    /// The on-disk value shape and optional validation rule for one portable
    /// preference. This stays independent of `BackupValue` so the key
    /// catalog remains the source of truth while the backup coder performs
    /// the concrete tagged-value match.
    nonisolated enum ExportedIntegerDomain: Equatable, Sendable {
        /// Only these exact values (a picker's tags).
        case values(Set<Int>)
        /// `0` (meaning "use the default") or a value inside the range, such as a port.
        case zeroOrRange(ClosedRange<Int>)
    }

    /// Valid values for a slider-backed `Double`: finite, inside `range`,
    /// and on a `step` tick from `range.lowerBound`. Import enforces the
    /// step; `Preferences.resolvedDouble` only clamps to the range.
    nonisolated struct ExportedDoubleDomain: Equatable, Sendable {
        let range: ClosedRange<Double>
        let step: Double
    }

    /// JSON blobs stored as `Data`, each decoded and re-validated by its own
    /// model's import normalizer before it is accepted.
    nonisolated enum ExportedDataFormat: Equatable, Sendable {
        case customCommands, songRequestBlocklist
    }

    /// What an import accepts for one key. A value of the wrong type is
    /// rejected, never coerced; the checks run in `SettingsBackupCoder`.
    nonisolated enum ExportedValueRule: Equatable, Sendable {
        case bool
        case int(ExportedIntegerDomain)
        case double(ExportedDoubleDomain)
        /// Free text up to `maxLength` characters, or one of the given
        /// values when the set is non-`nil`.
        case string(Set<String>?, maxLength: Int)
        /// A string that must normalize through `Preferences.normalizedHTTPSURL`
        /// (empty clears it).
        case httpsURL(maxLength: Int)
        /// A non-empty comma-separated list whose every trimmed item is in the set.
        case stringList(Set<String>)
        case data(ExportedDataFormat)
    }

    /// One portable preference and the exact value shape an import accepts.
    nonisolated struct ExportablePreference: Equatable, Sendable {
        let key: String
        let rule: ExportedValueRule
    }

    // Builders for `exportablePreferences` entries, one per rule kind.

    /// A key that accepts any `Bool`.
    private static func portableBool(_ key: String) -> ExportablePreference {
        ExportablePreference(key: key, rule: .bool)
    }

    /// An integer key restricted to `allowedValues` (a picker's tag set).
    private static func portableInt(
        _ key: String,
        allowedValues: [Int]
    ) -> ExportablePreference {
        ExportablePreference(key: key, rule: .int(.values(Set(allowedValues))))
    }

    /// A port key: `0` (use the default) or a value within
    /// `WebSocketServer.minPort...maxPort`.
    private static func portablePort(_ key: String) -> ExportablePreference {
        ExportablePreference(
            key: key,
            rule: .int(.zeroOrRange(
                Int(AppConstants.WebSocketServer.minPort)...Int(AppConstants.WebSocketServer.maxPort)
            ))
        )
    }

    /// A slider-backed `Double` key that must sit on a `step` tick inside `range`.
    private static func portableDouble(
        _ key: String,
        in range: ClosedRange<Double>,
        step: Double
    ) -> ExportablePreference {
        ExportablePreference(
            key: key,
            rule: .double(ExportedDoubleDomain(range: range, step: step))
        )
    }

    /// A string key capped at 256 characters, optionally limited to `allowedValues`.
    private static func portableString(
        _ key: String,
        allowedValues: [String]? = nil
    ) -> ExportablePreference {
        ExportablePreference(
            key: key,
            rule: .string(allowedValues.map { Set($0) }, maxLength: 256))
    }

    /// A comma-separated list key whose items must all be in `allowedValues`.
    private static func portableStringList(
        _ key: String,
        allowedValues: [String]
    ) -> ExportablePreference {
        ExportablePreference(key: key, rule: .stringList(Set(allowedValues)))
    }

    /// A JSON `Data` key validated by the model behind `format`.
    private static func portableData(
        _ key: String,
        format: ExportedDataFormat
    ) -> ExportablePreference {
        ExportablePreference(key: key, rule: .data(format))
    }

    /// Portable preferences safe to export and restore, paired with their
    /// complete validation schema. No secrets, account identity, or
    /// per-install runtime state appears here. Anything not listed is
    /// deliberately excluded from backups.
    ///
    /// Invariant: every key in `allKeys` must appear in exactly one of
    /// `exportableKeys`, `accountLinkedKeys`, or `runtimeStateKeys`. Adding a
    /// new UserDefaults key forces a classification choice; the
    /// `SettingsBackupKeyCoverageTests` guard fails until it is placed.
    static let exportablePreferences: [ExportablePreference] = [
        // General / appearance
        portableBool(trackingEnabled),
        portableString(dockVisibility, allowedValues: [
            AppConstants.DockVisibility.menuOnly,
            AppConstants.DockVisibility.dockOnly,
            AppConstants.DockVisibility.both
        ]),
        portableBool(launchAtLogin),
        portableString(appearancePreference, allowedValues: [
            AppConstants.Appearance.system,
            AppConstants.Appearance.light,
            AppConstants.Appearance.dark
        ]),
        portableBool(streamerModeEnabled),
        portableBool(sponsorLinksEnabled),
        portableBool(shareDiagnosticsEnabled),
        portableBool(updateCheckEnabled),
        portableString(updateChannel, allowedValues: ["stable", "nightly"]),
        // Music monitor / song commands
        portableBool(currentSongCommandEnabled),
        portableBool(lastSongCommandEnabled),
        portableBool(commandsLiveOnly),
        portableData(customCommands, format: .customCommands),
        portableBool(songCommandSongLinkEnabled),
        portableDouble(songCommandGlobalCooldown, in: 0...30, step: 5),
        portableDouble(songCommandUserCooldown, in: 0...60, step: 5),
        portableString(songCommandAliases),
        portableDouble(lastSongCommandGlobalCooldown, in: 0...30, step: 5),
        portableDouble(lastSongCommandUserCooldown, in: 0...60, step: 5),
        portableString(lastSongCommandAliases),
        // WolfWave info command
        portableBool(wolfwaveCommandEnabled),
        portableDouble(wolfwaveCommandGlobalCooldown, in: 0...30, step: 5),
        portableDouble(wolfwaveCommandUserCooldown, in: 0...60, step: 5),
        portableString(wolfwaveCommandAliases),
        portableString(wolfwaveCommandReplyStyle, allowedValues: [
            "credit", "howto", "pitch", "short"
        ]),
        // Discord Rich Presence (local IPC, no account/login)
        portableBool(discordPresenceEnabled),
        portableBool(discordButton1Enabled),
        portableString(discordButton1Label),
        portableBool(discordButton2Enabled),
        portableString(discordButton2Label),
        portableBool(discordButtonsEnabled),
        portableBool(discordPlaylistEnabled),
        portableBool(discordPlaylistShowName),
        portableString(discordPlaylistStyle, allowedValues: ["artistLine", "iconTooltip"]),
        portableBool(discordShowIdleStatus),
        portableBool(discordClearWhilePaused),
        // Stream widgets / WebSocket (local server; auth token auto-regenerates)
        portableBool(websocketEnabled),
        portableBool(streamDeckControlEnabled),
        portablePort(websocketServerPort),
        portableBool(widgetHTTPEnabled),
        portablePort(widgetPort),
        portableString(widgetTheme, allowedValues: AppConstants.Widget.themes),
        portableString(widgetLayout, allowedValues: AppConstants.Widget.layouts),
        portableString(widgetTextColor),
        portableString(widgetBackgroundColor),
        portableString(widgetFontFamily),
        // Song requests
        portableBool(songRequestEnabled),
        portableInt(songRequestMaxQueueSize, allowedValues: [5, 10, 15, 20, 25, 50]),
        portableInt(songRequestPerUserLimit, allowedValues: [1, 2, 3, 5, 10, 15, 20]),
        portableBool(songRequestFairShare),
        portableString(songRequestPriorityMode, allowedValues: ["off", "cooldownSkip", "queueJump"]),
        portableBool(songRequestSubscriberOnly),
        portableBool(songRequestAutoAdvance),
        portableBool(songRequestAutoplayWhenEmpty),
        portableBool(songRequestApprovalRequired),
        portableData(songRequestBlocklist, format: .songRequestBlocklist),
        portableBool(srCommandEnabled),
        portableBool(queueCommandEnabled),
        portableBool(myQueueCommandEnabled),
        portableBool(skipCommandEnabled),
        portableBool(clearQueueCommandEnabled),
        portableString(srCommandAliases),
        portableString(queueCommandAliases),
        portableString(myQueueCommandAliases),
        portableString(skipCommandAliases),
        portableString(clearQueueCommandAliases),
        portableBool(songListCommandEnabled),
        portableString(songListCommandAliases),
        ExportablePreference(key: songRequestSongListURL, rule: .httpsURL(maxLength: 2_048)),
        portableDouble(songRequestGlobalCooldown, in: 0...30, step: 5),
        portableDouble(songRequestUserCooldown, in: 0...60, step: 5),
        portableString(songRequestFallbackPlaylist),
        portableBool(songRequestHoldEnabled),
        portableString(songRequestChatAudience, allowedValues: [
            "everyone", "subscribers", "vipsAndSubs", "modsOnly"
        ]),
        portableBool(songRequestChannelPointsEnabled),
        portableInt(
            songRequestChannelPointsCost,
            allowedValues: [100, 250, 500, 1_000, 2_500, 5_000]
        ),
        portableBool(songRequestBitsEnabled),
        portableInt(songRequestBitsMinimum, allowedValues: [1, 50, 100, 200, 500, 1_000]),
        portableBool(songRequestBitsBoostEnabled),
        portableBool(songRequestDisabledReplyEnabled),
        portableString(songRequestPolicyMode, allowedValues: [
            "open", "subsOnly", "channelPointsOnly", "custom"
        ]),
        portableString(songRequestLimitStackMode, allowedValues: ["highest", "stacked"]),
        portableInt(songRequestLimitSubscriber, allowedValues: [1, 2, 3, 5, 10, 15, 20]),
        portableInt(songRequestLimitVIP, allowedValues: [1, 2, 3, 5, 10, 15, 20]),
        portableInt(songRequestLimitModerator, allowedValues: [1, 2, 3, 5, 10, 15, 20]),
        // Vote skip
        portableBool(voteSkipEnabled),
        portableInt(voteSkipMinVotes, allowedValues: [2, 3, 5, 7, 10]),
        portableInt(voteSkipWindowSeconds, allowedValues: [30, 60, 90, 120]),
        portableDouble(voteSkipSessionCooldown, in: 0...120, step: 15),
        portableBool(voteSkipSubscriberOnly),
        portableBool(voteSkipCommandEnabled),
        portableString(voteSkipCommandAliases),
        portableBool(voteSkipUsePolls),
        portableInt(voteSkipPollDuration, allowedValues: [30, 60, 90, 120, 180, 300]),
        // Notifications
        portableBool(songChangeNotificationsEnabled),
        portableBool(skipVoteStartedNotificationsEnabled),
        portableBool(skipVotePassedNotificationsEnabled),
        // History & stats
        portableBool(listeningHistoryEnabled),
        portableBool(statsEnabled),
        portableBool(statsCommandEnabled),
        portableDouble(statsCommandGlobalCooldown, in: 0...60, step: 5),
        portableDouble(statsCommandUserCooldown, in: 0...60, step: 5),
        portableString(statsCommandAliases),
        portableString(statsCommandWindow, allowedValues: ["today", "session", "week", "allTime"]),
        portableStringList(statsCommandParts, allowedValues: [
            "plays", "listeningTime", "topTrack", "topArtist"
        ]),
        portableInt(historyRetentionDays, allowedValues: [0, 7, 30, 90, 180, 365])
    ]

    /// Keys safe to write to a backup, derived from the validation schema so
    /// classification and validation cannot drift into separate lists.
    static let exportableKeys: [String] = exportablePreferences.map(\.key)

    /// `exportablePreferences` keyed for lookup.
    private static let exportableRulesByKey: [String: ExportedValueRule] =
        Dictionary(uniqueKeysWithValues: exportablePreferences.map { ($0.key, $0.rule) })

    /// The declared value domain for `key`, or nil when the key is not
    /// portable (and so has no schema).
    ///
    /// Import validation is not the only consumer. `Preferences.resolvedInt`
    /// and `Preferences.resolvedDouble` clamp live reads against the same
    /// domains, so the allowed values for a setting are declared exactly
    /// once. A picker's tag list and the rule here disagreeing is precisely
    /// the bug class this exists to prevent.
    static func exportRule(for key: String) -> ExportedValueRule? {
        exportableRulesByKey[key]
    }

    /// Keys tied to a connected account. Restored only when the user opts to
    /// reconnect that integration during import. The actual credentials
    /// (Twitch OAuth token + user/channel IDs) live in Keychain and never
    /// enter a backup file; these UserDefaults entries are account identity
    /// and re-auth state, not secrets.
    ///
    /// Twitch is the only OAuth account in WolfWave. Discord Rich Presence is
    /// a local IPC connection and the WebSocket/widget server is a local
    /// server with an auto-regenerated token, so neither is account-linked.
    static let accountLinkedKeys: [String] = [
        twitchChannelName,
        twitchPendingImportedChannelName,
        twitchReauthNeeded
    ]

    /// Per-install runtime/UI state that must never travel in a backup:
    /// permission caches, last-seen markers, locally-derived status, and
    /// server-side resource IDs that belong to one specific account. These
    /// regenerate on the target machine.
    static let runtimeStateKeys: [String] = [
        lastResolvedMusicPermission,
        lastLaunchCrashed,
        lastCrashSummary,
        hasCompletedOnboarding,
        diagnosticsLaunchCount,
        updateSkippedVersion,
        lastSeenWhatsNewVersion,
        songRequestChannelPointsRewardID,
        songRequestChannelPointsRewardIdentity,
        songRequestRedemptionStatus,
        customCommandAnnounceStatus,
        songRequestSetupComplete,
        songRequestPlaylistStatus,
        songRequestPlaylistID,
        iCloudSettingsSyncEnabled,
        iCloudSettingsSyncLastAppliedAt
    ] + debugKeys
}
