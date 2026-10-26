//
//  SettingsBackupServiceTests+Collections.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// Malformed portable collections, the unsafe song-request gate, and Twitch import staging.
extension SettingsBackupServiceTests {
    /// Malformed command or blocklist payloads are ignored before reaching the owners (zero
    /// replace calls), so live and persisted data are unchanged and both are counted as ignored.
    func testMalformedPortableCollectionsPreserveLiveAndPersistedState() async throws {
        let scratch = ThrowawayDefaults("SettingsBackupMalformedCollections")
        defer { scratch.destroy() }
        let defaults = scratch.defaults

        let priorCommands = [CustomCommand(trigger: "!keep", response: "Kept")]
        let priorBlocklist = [BlocklistItem(value: "Keep Artist", type: .artist)]
        let priorCommandsData = try JSONCoders.defaultEncoder.encode(priorCommands)
        let priorBlocklistData = try JSONCoders.camelCaseEncoder.encode(priorBlocklist)
        let expectedBlocklist = try JSONCoders.camelCase.decode(
            [BlocklistItem].self,
            from: priorBlocklistData
        )
        defaults.set(priorCommandsData, forKey: AppConstants.UserDefaults.customCommands)
        defaults.set(priorBlocklistData, forKey: AppConstants.UserDefaults.songRequestBlocklist)
        let commandStore = CustomCommandStore(defaults: defaults)
        let blocklist = SongBlocklist(
            storage: UserDefaultsBlocklistStorage(defaults: defaults)
        )
        let customReplacementCalls = ThreadSafeBox(0)
        let blocklistReplacementCalls = ThreadSafeBox(0)
        let service = SettingsBackupService(
            defaults: defaults,
            center: NotificationCenter(),
            twitchChannelProvider: { nil },
            replaceCustomCommands: { data in
                customReplacementCalls.mutate { value in value += 1 }
                return commandStore.replaceFromImportedData(data)
            },
            replaceSongRequestBlocklist: { data in
                blocklistReplacementCalls.mutate { value in value += 1 }
                return await blocklist.replaceFromImportedData(data)
            }
        )
        let keys = AppConstants.UserDefaults.self
        let backup = SettingsBackup(
            format: SettingsBackup.currentFormat,
            schemaVersion: SettingsBackup.currentSchemaVersion,
            appVersion: "1.0.0",
            appBuild: "1",
            exportedAt: Date(timeIntervalSince1970: 0),
            settings: [
                keys.customCommands: .data(Data("not-json".utf8)),
                keys.songRequestBlocklist: .data(Data("{}".utf8))
            ],
            integrations: .init(twitch: nil)
        )

        let summary = await service.apply(
            backup,
            choices: .init(reconnectTwitch: false)
        )

        XCTAssertEqual(summary.restoredCount, 0)
        XCTAssertEqual(summary.ignoredCount, 2)
        XCTAssertEqual(customReplacementCalls.value, 0)
        XCTAssertEqual(blocklistReplacementCalls.value, 0)
        XCTAssertEqual(commandStore.commands, priorCommands)
        let liveBlocklist = await blocklist.allEntries
        XCTAssertEqual(liveBlocklist, expectedBlocklist)
        XCTAssertEqual(
            defaults.data(forKey: AppConstants.UserDefaults.customCommands),
            priorCommandsData
        )
        XCTAssertEqual(
            defaults.data(forKey: AppConstants.UserDefaults.songRequestBlocklist),
            priorBlocklistData
        )
    }

    /// Importing Song Requests as enabled while setup is incomplete turns them off immediately,
    /// before the (suspended) blocklist replacement finishes, so requests are never live without
    /// their blocklist.
    func testApplyDisablesUnsafeSongRequestsBeforePortableOwnerSuspends() async throws {
        let scratch = ThrowawayDefaults("SettingsBackupSongRequestSafety")
        defer { scratch.destroy() }
        let defaults = scratch.defaults
        let blocklistData = try JSONCoders.camelCaseEncoder.encode([
            BlocklistItem(value: "Blocked Song", type: .song)
        ])
        let keys = AppConstants.UserDefaults.self
        let backup = SettingsBackup(
            format: SettingsBackup.currentFormat,
            schemaVersion: SettingsBackup.currentSchemaVersion,
            appVersion: "1.0.0",
            appBuild: "1",
            exportedAt: Date(timeIntervalSince1970: 0),
            settings: [
                keys.songRequestEnabled: .bool(true),
                keys.songRequestSetupComplete: .bool(false),
                keys.songRequestBlocklist: .data(blocklistData)
            ],
            integrations: .init(twitch: nil)
        )
        let gate = SettingsBackupAsyncGate()
        let service = SettingsBackupService(
            defaults: defaults,
            center: NotificationCenter(),
            twitchChannelProvider: { nil },
            replaceCustomCommands: { _ in false },
            replaceSongRequestBlocklist: { _ in
                await gate.suspend()
                return true
            }
        )

        let applyTask = Task {
            await service.apply(backup, choices: .init(reconnectTwitch: false))
        }
        let replacementSuspended = await waitUntil { await gate.suspended }

        XCTAssertTrue(replacementSuspended)
        XCTAssertFalse(defaults.bool(forKey: keys.songRequestEnabled))

        await gate.resume()
        _ = await applyTask.value
    }

    func testBackupFailsInsteadOfSilentlyOmittingChannelOnKeychainReadError() throws {
        let failingBackend = InspectableKeychainBackend()
        KeychainService.backend = failingBackend
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "ACCESS", channelID: "canonical_channel")
        )
        failingBackend.failNextLoad(
            for: KeychainService.twitchCredentialGrantAccount
        )

        XCTAssertThrowsError(try SettingsBackupService().makeBackup())
        XCTAssertNotNil(
            failingBackend.rawValue(
                account: KeychainService.twitchCredentialGrantAccount)
        )
    }

    /// An imported Twitch channel is staged only as a pending hint. The stored grant is
    /// unchanged, the legacy channel key is cleared, and the re-auth flag is raised.
    func testTwitchImportStagesPendingChannelWithoutMutatingCanonicalGrant() async throws {
        let scratch = ThrowawayDefaults("SettingsBackupPendingChannel")
        defer { scratch.destroy() }
        let defaults = scratch.defaults
        let original = KeychainService.TwitchCredentialGrant(
            accessToken: "ACCESS",
            refreshToken: "REFRESH",
            username: "wolf",
            userID: "123",
            channelID: "canonical_channel"
        )
        try KeychainService.saveTwitchCredentialGrant(original)
        defaults.set("legacy-stale", forKey: AppConstants.UserDefaults.twitchChannelName)
        let backup = SettingsBackup(
            format: SettingsBackup.currentFormat,
            schemaVersion: SettingsBackup.currentSchemaVersion,
            appVersion: "1.0.0",
            appBuild: "1",
            exportedAt: Date(timeIntervalSince1970: 0),
            settings: [:],
            integrations: .init(
                twitch: .init(channelName: "imported_channel")
            )
        )

        let summary = await SettingsBackupService(
            defaults: defaults,
            center: NotificationCenter(),
            replaceCustomCommands: { _ in false },
            replaceSongRequestBlocklist: { _ in false }
        ).apply(backup, choices: .init(reconnectTwitch: true))

        XCTAssertTrue(summary.reconnectedTwitch)
        XCTAssertEqual(
            defaults.string(
                forKey: AppConstants.UserDefaults.twitchPendingImportedChannelName),
            "imported_channel"
        )
        XCTAssertNil(defaults.string(forKey: AppConstants.UserDefaults.twitchChannelName))
        XCTAssertTrue(defaults.bool(forKey: AppConstants.UserDefaults.twitchReauthNeeded))
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant(), original)
    }
}
