//
//  SettingsBackupServiceTests+SystemPreferences.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// System-backed preferences (login item, appearance, updates) and song-request setup gating.
extension SettingsBackupServiceTests {
    /// Launch at Login, appearance, and update preferences are pushed through the injected
    /// `SideEffects` (the real login item, `NSApp`, and Sparkle are never touched) and counted as
    /// restored.
    func testApplyEnactsSystemBackedPreferences() async throws {
        let scratch = ThrowawayDefaults("SettingsBackupServiceTests.sideEffects")
        defer { scratch.destroy() }
        let defaults = scratch.defaults

        var launchAtLoginEnabled = false
        var launchRequests: [Bool] = []
        var appliedAppearances: [String] = []
        var appliedUpdates: [SettingsBackupService.UpdatePreferences] = []
        let sideEffects = SettingsBackupService.SideEffects(
            isLaunchAtLoginEnabled: { launchAtLoginEnabled },
            setLaunchAtLogin: { enabled in
                launchRequests.append(enabled)
                launchAtLoginEnabled = enabled
                return .success
            },
            applyAppearance: { appliedAppearances.append($0) },
            applyUpdatePreferences: { appliedUpdates.append($0) }
        )
        let keys = AppConstants.UserDefaults.self
        let backup = SettingsBackup(
            format: SettingsBackup.currentFormat,
            schemaVersion: SettingsBackup.currentSchemaVersion,
            appVersion: "1.0.0",
            appBuild: "1",
            exportedAt: Date(timeIntervalSince1970: 0),
            settings: [
                keys.launchAtLogin: .bool(true),
                keys.appearancePreference: .string(AppConstants.Appearance.dark),
                keys.updateCheckEnabled: .bool(false),
                keys.updateChannel: .string(UpdateChannel.nightly.rawValue)
            ],
            integrations: .init(twitch: nil)
        )

        let summary = await SettingsBackupService(
            defaults: defaults,
            center: NotificationCenter(),
            replaceCustomCommands: { _ in false },
            replaceSongRequestBlocklist: { _ in false },
            sideEffects: sideEffects
        ).apply(backup, choices: .init())

        XCTAssertEqual(launchRequests, [true])
        XCTAssertEqual(appliedAppearances, [AppConstants.Appearance.dark])
        XCTAssertEqual(
            appliedUpdates,
            [.init(automaticCheckEnabled: false, channel: .nightly)]
        )
        XCTAssertEqual(summary.restoredCount, 4)
        XCTAssertTrue(summary.warnings.isEmpty)
    }

    /// If the system refuses the login-item change, the stored value reverts to off, nothing
    /// counts as restored, and a warning explains it.
    func testApplyReconcilesRejectedLaunchAtLoginChange() async throws {
        let scratch = ThrowawayDefaults("SettingsBackupServiceTests.loginFailure")
        defer { scratch.destroy() }
        let defaults = scratch.defaults

        var launchRequests: [Bool] = []
        let sideEffects = SettingsBackupService.SideEffects(
            isLaunchAtLoginEnabled: { false },
            setLaunchAtLogin: { enabled in
                launchRequests.append(enabled)
                return .failure
            },
            applyAppearance: { _ in },
            applyUpdatePreferences: { _ in }
        )
        let key = AppConstants.UserDefaults.launchAtLogin
        let backup = SettingsBackup(
            format: SettingsBackup.currentFormat,
            schemaVersion: SettingsBackup.currentSchemaVersion,
            appVersion: "1.0.0",
            appBuild: "1",
            exportedAt: Date(timeIntervalSince1970: 0),
            settings: [key: .bool(true)],
            integrations: .init(twitch: nil)
        )

        let summary = await SettingsBackupService(
            defaults: defaults,
            center: NotificationCenter(),
            replaceCustomCommands: { _ in false },
            replaceSongRequestBlocklist: { _ in false },
            sideEffects: sideEffects
        ).apply(backup, choices: .init())

        XCTAssertEqual(launchRequests, [true])
        XCTAssertFalse(defaults.bool(forKey: key))
        XCTAssertEqual(summary.restoredCount, 0)
        XCTAssertEqual(
            summary.warnings,
            ["Launch at Login couldn't be restored and remains off."]
        )
    }
    /// A login item that needs approval in System Settings is kept on and counted, with a warning
    /// about approval.
    func testApplyCountsPendingLaunchAtLoginAndWarnsAboutSystemApproval() async {
        let scratch = ThrowawayDefaults("SettingsBackupServiceTests.loginApproval")
        defer { scratch.destroy() }
        let defaults = scratch.defaults

        var launchAtLoginEnabled = false
        let sideEffects = SettingsBackupService.SideEffects(
            isLaunchAtLoginEnabled: { launchAtLoginEnabled },
            setLaunchAtLogin: { enabled in
                launchAtLoginEnabled = enabled
                return .requiresApproval
            },
            applyAppearance: { _ in },
            applyUpdatePreferences: { _ in }
        )
        let key = AppConstants.UserDefaults.launchAtLogin
        let backup = makeBackup(settings: [key: .bool(true)])

        let summary = await SettingsBackupService(
            defaults: defaults,
            center: NotificationCenter(),
            sideEffects: sideEffects
        ).apply(backup, choices: .init())

        XCTAssertTrue(defaults.bool(forKey: key))
        XCTAssertEqual(summary.restoredCount, 1)
        XCTAssertEqual(
            summary.warnings,
            ["Launch at Login requires approval in System Settings → General → Login Items."]
        )
    }

    /// Song Request settings are neither previewed nor restored on a Mac whose Song Request
    /// setup is incomplete; the key is forced off, ignored, and a warning is given.
    func testSongRequestsAreNotPreviewedOrRestoredBeforeSetupCompletes() async {
        let scratch = ThrowawayDefaults("SettingsBackupServiceTests.songRequestSetup")
        defer { scratch.destroy() }
        let defaults = scratch.defaults

        let keys = AppConstants.UserDefaults.self
        defaults.set(true, forKey: keys.songRequestEnabled)
        defaults.set(false, forKey: keys.songRequestSetupComplete)
        let backup = makeBackup(settings: [keys.songRequestEnabled: .bool(true)])
        let service = SettingsBackupService(defaults: defaults, center: NotificationCenter())

        XCTAssertEqual(service.restorableCount(backup), 0)
        let summary = await service.apply(backup, choices: .init())

        XCTAssertFalse(defaults.bool(forKey: keys.songRequestEnabled))
        XCTAssertEqual(summary.restoredCount, 0)
        XCTAssertEqual(summary.ignoredCount, 1)
        XCTAssertEqual(
            summary.warnings,
            ["Song Requests weren't restored because setup isn't complete on this Mac."]
        )
    }

    /// The import sheet opens with local sharing settings off, so its
    /// "replaces N settings" count must leave those keys out.
    func testRestorableCountMatchesImportSheetDefaults() {
        let scratch = ThrowawayDefaults("SettingsBackupServiceTests.restorableLocal")
        defer { scratch.destroy() }
        let defaults = scratch.defaults

        let keys = AppConstants.UserDefaults.self
        let backup = makeBackup(settings: [
            keys.discordPresenceEnabled: .bool(true),
            keys.websocketEnabled: .bool(true),
            keys.updateChannel: .string("nightly")
        ])
        let service = SettingsBackupService(defaults: defaults, center: NotificationCenter())

        XCTAssertEqual(service.restorableCount(backup), 1)
        XCTAssertEqual(
            service.restorableCount(
                backup, choices: .init(includeLocalSharingSettings: true)),
            3)
    }

    func testSongRequestsArePreviewedAndRestoredAfterSetupCompletes() async {
        let scratch = ThrowawayDefaults("SettingsBackupServiceTests.songRequestReady")
        defer { scratch.destroy() }
        let defaults = scratch.defaults

        let keys = AppConstants.UserDefaults.self
        defaults.set(true, forKey: keys.songRequestSetupComplete)
        let backup = makeBackup(settings: [keys.songRequestEnabled: .bool(true)])
        let service = SettingsBackupService(defaults: defaults, center: NotificationCenter())

        XCTAssertEqual(service.restorableCount(backup), 1)
        let summary = await service.apply(backup, choices: .init())

        XCTAssertTrue(defaults.bool(forKey: keys.songRequestEnabled))
        XCTAssertEqual(summary.restoredCount, 1)
        XCTAssertTrue(summary.warnings.isEmpty)
    }
}
