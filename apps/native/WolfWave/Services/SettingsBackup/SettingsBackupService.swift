//
//  SettingsBackupService.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-06-02.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Main-actor adapter that wires the pure `SettingsBackupCoder` to live app
/// state: it snapshots and writes `UserDefaults`, stamps the running app
/// version, and broadcasts the service notifications that non-view components
/// (Discord RPC, WebSocket server, song-request pipeline, etc.) listen for.
///
/// File dialogs (`NSSavePanel` / `NSOpenPanel`) stay in the view layer, mirroring
/// how `AdvancedSettingsView.exportLogs()` already presents panels. This type
/// performs no UI. Its only file I/O is reading a user-picked backup in
/// ``decode(fileURL:)``; writing the export is the caller's job. System-backed
/// preferences are applied through the injectable `SideEffects` adapter.
///
/// Also the payload source for `SettingsSyncService`, which reuses
/// ``makeBackupData(exportedAt:)``, ``decode(_:)``, and ``apply(_:choices:)``.
@MainActor
struct SettingsBackupService {
    /// Outcome of an import, surfaced to the user in the completion message.
    struct ApplySummary: Equatable {
        /// Number of portable preferences written.
        var restoredCount: Int
        /// Whether Twitch identity was restored and re-auth was triggered.
        var reconnectedTwitch: Bool
        /// The restored Twitch channel name, when reconnecting.
        var twitchChannel: String?
        /// Backup keys ignored because they are unknown, non-portable, or invalid.
        var ignoredCount: Int
        /// Non-fatal system-setting failures that need the user's attention.
        var warnings: [String]

        /// The correctly pluralized noun for a preference count
        /// (`preference` for 1, `preferences` otherwise). Shared by the import
        /// preview summary and the post-import confirmation message.
        static func preferenceNoun(_ count: Int) -> String {
            count == 1 ? "preference" : "preferences"
        }
    }

    /// Sparkle settings restored from a backup. A `nil` field was not in the
    /// plan and must be left unchanged.
    struct UpdatePreferences: Equatable {
        var automaticCheckEnabled: Bool?
        var channel: UpdateChannel?
    }

    /// Preferences whose stored value alone does nothing: each needs a system
    /// or app call to take effect. Injectable so tests never register a real
    /// login item, change the app appearance, or touch Sparkle.
    struct SideEffects {
        var isLaunchAtLoginEnabled: @MainActor () -> Bool
        var setLaunchAtLogin: @MainActor (Bool) -> LaunchAtLoginService.RegistrationOutcome
        var applyAppearance: @MainActor (String) -> Void
        var applyUpdatePreferences: @MainActor (UpdatePreferences) -> Void

        /// Production wiring. Automatic update checks are left alone in DEBUG,
        /// where Sparkle runs without background checks by design.
        static let live = SideEffects(
            isLaunchAtLoginEnabled: { LaunchAtLoginService.isEnabled },
            setLaunchAtLogin: { LaunchAtLoginService.setEnabled($0) },
            applyAppearance: { AppearanceController.apply($0) },
            applyUpdatePreferences: { preferences in
                guard let updater = AppDelegate.shared?.sparkleUpdater else { return }
                #if !DEBUG
                if let enabled = preferences.automaticCheckEnabled {
                    updater.automaticCheckEnabled = enabled
                }
                #endif
                if let channel = preferences.channel {
                    updater.channel = channel
                    updater.recheckAfterChannelChange()
                }
            }
        )
    }

    /// Outcome of ``applySideEffects(for:)``. `failedKeys` are subtracted from
    /// the restored count; `warnings` are shown to the user.
    private struct SideEffectResult {
        var failedKeys: Set<String> = []
        var warnings: [String] = []
    }

    /// An apply plan after incorporating state that exists only on this Mac.
    /// Preview and apply share it so their restored counts cannot disagree.
    private struct ResolvedImportPlan {
        var plan: SettingsBackupCoder.ApplyPlan
        /// Write `songRequestEnabled = false` even though the key was removed
        /// from the plan, so a previously-on value on this Mac is turned off too.
        var forceSongRequestsOff = false
        var warnings: [String] = []
    }

    private let defaults: Foundation.UserDefaults
    private let center: NotificationCenter
    private let twitchChannelProvider: () throws -> String?
    private let replaceCustomCommands:
        @MainActor @Sendable (Data) -> Bool
    private let replaceSongRequestBlocklist:
        @MainActor @Sendable (Data) async -> Bool
    private let sideEffects: SideEffects
    private let coder = SettingsBackupCoder()

    /// Creates the adapter. Every dependency defaults to the live app; tests
    /// inject fakes.
    ///
    /// - Parameters:
    ///   - defaults: Store to snapshot and write. Defaults to `DefaultsStore.store`
    ///     (an isolated suite under test).
    ///   - center: Where the post-import service notifications go.
    ///   - twitchChannelProvider: Reads the configured channel from the Twitch
    ///     Keychain grant for export. Throws when the Keychain read fails, which
    ///     fails the export rather than silently dropping the channel.
    ///   - replaceCustomCommands: Commits imported custom commands through their
    ///     live store. Returns `false` if the store rejected the data.
    ///   - replaceSongRequestBlocklist: Same for the song-request blocklist.
    ///   - sideEffects: System-backed preference adapter.
    init(
        defaults: Foundation.UserDefaults = DefaultsStore.store,
        center: NotificationCenter = .default,
        twitchChannelProvider: @escaping () throws -> String? = {
            try KeychainService.loadTwitchCredentialGrantChecked().channelID
        },
        replaceCustomCommands: @escaping @MainActor @Sendable (Data) -> Bool = {
            CustomCommandStore.shared.replaceFromImportedData($0)
        },
        replaceSongRequestBlocklist: @escaping @MainActor @Sendable
            (Data) async -> Bool = { data in
            let blocklist = AppDelegate.shared?.songRequestService?.blocklist
                ?? SongBlocklist()
            // `replaceFromImportedData` is synchronous. The closure's type stays
            // `async` so an injected implementation may suspend; this default
            // one has nothing to await.
            return blocklist.replaceFromImportedData(data)
        },
        sideEffects: SideEffects = .live
    ) {
        self.defaults = defaults
        self.center = center
        self.twitchChannelProvider = twitchChannelProvider
        self.replaceCustomCommands = replaceCustomCommands
        self.replaceSongRequestBlocklist = replaceSongRequestBlocklist
        self.sideEffects = sideEffects
    }

    // MARK: - Export

    /// Builds a backup of the current portable preferences.
    ///
    /// - Throws: Whatever `twitchChannelProvider` throws (a Keychain read failure).
    func makeBackup(exportedAt: Date = Date()) throws -> SettingsBackup {
        coder.makeBackup(
            snapshot: snapshot(),
            exportablePreferences: AppConstants.UserDefaults.exportablePreferences,
            twitchChannelName: try twitchChannelProvider(),
            appVersion: Self.appVersion,
            appBuild: Self.appBuild,
            exportedAt: exportedAt
        )
    }

    /// Builds a backup and serializes it to pretty-printed JSON for writing.
    func makeBackupData(exportedAt: Date = Date()) throws -> Data {
        try coder.encode(try makeBackup(exportedAt: exportedAt))
    }

    /// Reads the current value of every exportable key from UserDefaults.
    private func snapshot() -> [String: Any] {
        var dict: [String: Any] = [:]
        for key in AppConstants.UserDefaults.exportableKeys {
            if let value = defaults.object(forKey: key) {
                dict[key] = value
            }
        }
        return dict
    }

    // MARK: - Import

    /// Decodes and validates backup data. Throws `SettingsBackupCoder.BackupError`.
    func decode(_ data: Data) throws -> SettingsBackup {
        try coder.decode(data)
    }

    /// Reads and decodes a backup file off the main actor.
    ///
    /// Files over 1 MiB are refused before and after the read (the size
    /// attribute can be missing or stale), so a huge or hostile pick can't
    /// stall the app.
    ///
    /// - Throws: `SettingsBackupCoder.BackupError.tooLarge`, a file-system
    ///   error from the read, or the other `BackupError` cases from decoding.
    func decode(fileURL: URL) async throws -> SettingsBackup {
        try await Task.detached(priority: .userInitiated) {
            let maximumSize = 1_048_576
            let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard fileSize <= maximumSize else {
                throw SettingsBackupCoder.BackupError.tooLarge
            }
            let data = try Data(contentsOf: fileURL)
            guard data.count <= maximumSize else {
                throw SettingsBackupCoder.BackupError.tooLarge
            }
            return try SettingsBackupCoder().decode(data)
        }.value
    }

    /// How many preferences a backup would restore (for the review summary).
    ///
    /// Uses default ``SettingsBackupCoder/ImportChoices`` (local-sharing keys
    /// included), so it can exceed what an import with that option off writes.
    func restorableCount(_ backup: SettingsBackup) -> Int {
        resolvedImportPlan(
            backup: backup,
            choices: SettingsBackupCoder.ImportChoices()
        ).plan.set.count
    }

    /// Applies a backup using the user's per-integration choices.
    ///
    /// Writes portable preferences, optionally restores the Twitch channel and
    /// flags re-auth, then broadcasts the service toggles so background
    /// components pick up the new state without a relaunch.
    ///
    /// Never removes a key. The restored Twitch channel is stored only as a
    /// pending hint and the live channel name is cleared; no token is written,
    /// so the user must sign in again before the channel becomes authoritative.
    ///
    /// - Returns: Counts for the confirmation message. A collection its store
    ///   rejected, or a system setting that could not be applied, moves from
    ///   restored to ignored.
    @discardableResult
    func apply(
        _ backup: SettingsBackup,
        choices: SettingsBackupCoder.ImportChoices
    ) async -> ApplySummary {
        let resolved = resolvedImportPlan(backup: backup, choices: choices)
        let plan = resolved.plan
        let keys = AppConstants.UserDefaults.self
        var customCommandsData: Data?
        if let value = plan.set[keys.customCommands],
           case .data(let data) = value {
            customCommandsData = data
        }
        var songRequestBlocklistData: Data?
        if let value = plan.set[keys.songRequestBlocklist],
           case .data(let data) = value {
            songRequestBlocklistData = data
        }

        // Publish every scalar preference and its safety correction before the
        // first suspension. Encoded collections are committed by their live
        // owners below so actor-queued edits cannot overwrite an imported value.
        for (key, value) in plan.set
        where key != keys.customCommands
            && key != keys.songRequestBlocklist {
            defaults.set(value.userDefaultsValue, forKey: key)
        }

        if resolved.forceSongRequestsOff {
            defaults.set(false, forKey: keys.songRequestEnabled)
        }

        var shouldPostTwitchReauth = false
        if plan.reconnectTwitch, let channel = plan.twitchChannelName {
            // Keep the imported channel pending and non-authoritative. The token
            // is not in the backup; OAuth later commits token + channel together.
            defaults.set(
                channel,
                forKey: AppConstants.UserDefaults.twitchPendingImportedChannelName
            )
            defaults.removeObject(forKey: AppConstants.UserDefaults.twitchChannelName)
            defaults.set(true, forKey: AppConstants.UserDefaults.twitchReauthNeeded)
            shouldPostTwitchReauth = true
        }

        let sideEffectResult = applySideEffects(for: plan)
        var restoredCount = plan.set.count - sideEffectResult.failedKeys.count
        var ignoredCount = plan.ignoredKeyCount
        if let customCommandsData,
           !replaceCustomCommands(customCommandsData) {
            restoredCount -= 1
            ignoredCount += 1
        }
        if let songRequestBlocklistData,
           !(await replaceSongRequestBlocklist(songRequestBlocklistData)) {
            restoredCount -= 1
            ignoredCount += 1
        }

        if shouldPostTwitchReauth {
            center.post(name: .twitchReauthNeededChanged, object: nil)
        }
        broadcastServiceState()

        return ApplySummary(
            restoredCount: restoredCount,
            reconnectedTwitch: plan.reconnectTwitch,
            twitchChannel: plan.twitchChannelName,
            ignoredCount: ignoredCount,
            warnings: resolved.warnings + sideEffectResult.warnings
        )
    }

    /// Builds the coder's plan, then applies rules that depend on this Mac.
    ///
    /// Today that is one rule: a backup cannot turn Song Requests on when this
    /// Mac hasn't finished Song Requests setup (the setup gate would otherwise
    /// be bypassed). The key is dropped, counted as ignored, and forced off.
    private func resolvedImportPlan(
        backup: SettingsBackup,
        choices: SettingsBackupCoder.ImportChoices
    ) -> ResolvedImportPlan {
        var plan = coder.makeApplyPlan(
            backup: backup,
            choices: choices,
            exportablePreferences: AppConstants.UserDefaults.exportablePreferences
        )
        let keys = AppConstants.UserDefaults.self
        guard
            case .bool(true)? = plan.set[keys.songRequestEnabled],
            !defaults.bool(forKey: keys.songRequestSetupComplete)
        else {
            return ResolvedImportPlan(plan: plan)
        }

        plan.set.removeValue(forKey: keys.songRequestEnabled)
        plan.ignoredKeyCount += 1
        return ResolvedImportPlan(
            plan: plan,
            forceSongRequestsOff: true,
            warnings: [
                "Song Requests weren't restored because setup isn't complete on this Mac.",
            ]
        )
    }

    /// Applies the plan's system-backed preferences: Launch at Login,
    /// appearance, and Sparkle's automatic checks and channel.
    ///
    /// Launch at Login is only touched when it differs from the live state. If
    /// registration fails, the stored value is corrected to the real state so
    /// the toggle doesn't lie.
    private func applySideEffects(for plan: SettingsBackupCoder.ApplyPlan) -> SideEffectResult {
        let keys = AppConstants.UserDefaults.self
        var result = SideEffectResult()

        if case .bool(let desired)? = plan.set[keys.launchAtLogin],
           sideEffects.isLaunchAtLoginEnabled() != desired {
            switch sideEffects.setLaunchAtLogin(desired) {
            case .success:
                break
            case .requiresApproval:
                result.warnings.append(
                    "Launch at Login requires approval in System Settings → General → Login Items."
                )
            case .failure:
                let actual = sideEffects.isLaunchAtLoginEnabled()
                defaults.set(actual, forKey: keys.launchAtLogin)
                if actual != desired {
                    result.failedKeys.insert(keys.launchAtLogin)
                    result.warnings.append(
                        "Launch at Login couldn't be restored and remains \(actual ? "on" : "off")."
                    )
                }
            }
        }

        if case .string(let appearance)? = plan.set[keys.appearancePreference] {
            sideEffects.applyAppearance(appearance)
        }

        let automaticChecks: Bool?
        if case .bool(let enabled)? = plan.set[keys.updateCheckEnabled] {
            automaticChecks = enabled
        } else {
            automaticChecks = nil
        }
        let channel: UpdateChannel?
        if case .string(let rawChannel)? = plan.set[keys.updateChannel] {
            channel = UpdateChannel.from(rawValue: rawChannel)
        } else {
            channel = nil
        }
        if automaticChecks != nil || channel != nil {
            sideEffects.applyUpdatePreferences(
                UpdatePreferences(automaticCheckEnabled: automaticChecks, channel: channel)
            )
        }
        return result
    }

    // MARK: - Service Notifications

    /// Re-broadcasts the toggles that background services observe, so an import
    /// takes effect live. Mirrors the notifications the menu and settings views
    /// post when these values change individually.
    private func broadcastServiceState() {
        let keys = AppConstants.UserDefaults.self

        center.postEnabled(.trackingSettingChanged, enabled: defaults.bool(forKey: keys.trackingEnabled))
        center.postEnabled(.discordPresenceChanged, enabled: defaults.bool(forKey: keys.discordPresenceEnabled))
        center.post(name: .discordPresenceSettingsChanged, object: nil)
        center.postEnabled(.songRequestSettingChanged, enabled: defaults.bool(forKey: keys.songRequestEnabled))
        center.postEnabled(.listeningHistorySettingChanged, enabled: defaults.bool(forKey: keys.listeningHistoryEnabled))
        center.postEnabled(.streamerModeChanged, enabled: defaults.bool(forKey: keys.streamerModeEnabled))
        center.postDockVisibility(mode: defaults.string(forKey: keys.dockVisibility) ?? AppConstants.DockVisibility.default)

        // Always send both resolved ports. A stored zero means "use default";
        // omitting it left an already-running custom-port listener unchanged.
        center.postWebSocketServerChanged(
            enabled: defaults.bool(forKey: keys.websocketEnabled),
            widgetHTTPEnabled: defaults.bool(forKey: keys.widgetHTTPEnabled),
            port: Preferences.resolvePort(
                defaults.integer(forKey: keys.websocketServerPort),
                default: AppConstants.WebSocketServer.defaultPort
            ),
            widgetPort: Preferences.resolvePort(
                defaults.integer(forKey: keys.widgetPort),
                default: AppConstants.WebSocketServer.widgetDefaultPort
            )
        )
    }

    // MARK: - App Version

    /// Running app marketing version (`CFBundleShortVersionString`).
    static var appVersion: String { AppConstants.AppInfo.shortVersion }

    /// Running app build number (`CFBundleVersion`).
    static var appBuild: String { AppConstants.AppInfo.buildNumber }
}
