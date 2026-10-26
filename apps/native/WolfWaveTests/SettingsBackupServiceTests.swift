//
//  SettingsBackupServiceTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-07-30.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// `SettingsBackupService` export/import orchestration: file limits, validation, apply ordering,
/// and side effects. `setUp` swaps in an `InMemoryKeychainBackend` and restores the previous one in
/// a teardown block; `WolfWaveTestCase` holds the shared-state lock for the duration.
@MainActor
final class SettingsBackupServiceTests: WolfWaveTestCase {

    override func setUp() async throws {
        // Acquires the shared-state lock (released by a teardown block) and
        // resets settings before the backend swap below.
        try await super.setUp()
        let previousBackend = KeychainService.backend
        KeychainService.backend = InMemoryKeychainBackend()
        addTeardownBlock { KeychainService.backend = previousBackend }
    }

    func testOversizedFileRejectedWithTooLarge() async throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "wolfwave-backup-oversized-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 0x20, count: 1_048_577).write(to: file)

        do {
            _ = try await SettingsBackupService().decode(fileURL: file)
            XCTFail("Expected oversized backup rejection")
        } catch let error as SettingsBackupCoder.BackupError {
            XCTAssertEqual(error, .tooLarge)
        }
    }

    /// Applying a backup posts one `websocketServerChanged` notification carrying the fully
    /// resolved overlay config: port 0 resolves to the default WebSocket port, and the widget
    /// port and enabled flags come through. Uses a private `NotificationCenter` and defaults suite.
    func testApplyBroadcastsCompleteResolvedOverlayConfiguration() async {
        let scratch = ThrowawayDefaults("SettingsBackupServiceTests")
        defer { scratch.destroy() }
        let defaults = scratch.defaults

        let center = NotificationCenter()
        let received = ThreadSafeBox<Notification?>(nil)
        let observer = center.addObserver(
            forName: .websocketServerChanged,
            object: nil,
            queue: nil
        ) { notification in
            received.mutate { $0 = notification }
        }
        defer { center.removeObserver(observer) }

        let keys = AppConstants.UserDefaults.self
        let backup = SettingsBackup(
            format: SettingsBackup.currentFormat,
            schemaVersion: SettingsBackup.currentSchemaVersion,
            appVersion: "1.0.0",
            appBuild: "1",
            exportedAt: Date(timeIntervalSince1970: 0),
            settings: [
                keys.websocketEnabled: .bool(true),
                keys.widgetHTTPEnabled: .bool(true),
                keys.websocketServerPort: .int(0),
                keys.widgetPort: .int(9_123)
            ],
            integrations: .init(twitch: nil)
        )

        let service = SettingsBackupService(
            defaults: defaults,
            center: center,
            twitchChannelProvider: { nil },
            replaceCustomCommands: { _ in false },
            replaceSongRequestBlocklist: { _ in false }
        )
        _ = await service.apply(
            backup,
            choices: .init(reconnectTwitch: false)
        )

        XCTAssertEqual(received.value?.enabledFlag, true)
        XCTAssertEqual(received.value?.widgetHTTPEnabledFlag, true)
        XCTAssertEqual(received.value?.portValue, AppConstants.WebSocketServer.defaultPort)
        XCTAssertEqual(received.value?.widgetPortValue, 9_123)
    }

    func testBackupUsesCanonicalChannelProviderInsteadOfLegacyDefault() throws {
        let scratch = ThrowawayDefaults("SettingsBackupCanonicalChannel")
        defer { scratch.destroy() }
        let defaults = scratch.defaults
        defaults.set("stale-channel", forKey: AppConstants.UserDefaults.twitchChannelName)
        let service = SettingsBackupService(
            defaults: defaults,
            center: NotificationCenter(),
            twitchChannelProvider: { "canonical_channel" }
        )

        let backup = try service.makeBackup(exportedAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(backup.integrations.twitch?.channelName, "canonical_channel")
    }

    /// Custom commands and the blocklist survive export then import through their live owners
    /// (`CustomCommandStore`, `SongBlocklist`), replacing stale local data, in memory and in
    /// persisted storage.
    func testBackupRoundTripsPortableCollectionsThroughLiveOwners() async throws {
        let scratch = ThrowawayDefaults("SettingsBackupCollections")
        defer { scratch.destroy() }
        let defaults = scratch.defaults

        let importedCommands = [
            CustomCommand(trigger: "!hello", response: "Hi!")
        ]
        let importedBlocklist = [
            BlocklistItem(value: "Blocked Artist", type: .artist)
        ]
        let importedCommandsData = try JSONCoders.defaultEncoder.encode(importedCommands)
        let importedBlocklistData = try JSONCoders.camelCaseEncoder.encode(importedBlocklist)
        let expectedBlocklist = try JSONCoders.camelCase.decode(
            [BlocklistItem].self,
            from: importedBlocklistData
        )
        defaults.set(importedCommandsData, forKey: AppConstants.UserDefaults.customCommands)
        defaults.set(importedBlocklistData, forKey: AppConstants.UserDefaults.songRequestBlocklist)

        let exportService = SettingsBackupService(
            defaults: defaults,
            center: NotificationCenter(),
            twitchChannelProvider: { nil },
            replaceCustomCommands: { _ in false },
            replaceSongRequestBlocklist: { _ in false }
        )
        let encoded = try exportService.makeBackupData(exportedAt: Date(timeIntervalSince1970: 0))

        let staleCommands = [CustomCommand(trigger: "!stale", response: "Old")]
        let staleBlocklist = [BlocklistItem(value: "Stale Song", type: .song)]
        defaults.set(
            try JSONCoders.defaultEncoder.encode(staleCommands),
            forKey: AppConstants.UserDefaults.customCommands
        )
        defaults.set(
            try JSONCoders.camelCaseEncoder.encode(staleBlocklist),
            forKey: AppConstants.UserDefaults.songRequestBlocklist
        )
        let commandStore = CustomCommandStore(defaults: defaults)
        let blocklist = SongBlocklist(
            storage: UserDefaultsBlocklistStorage(defaults: defaults)
        )
        let importService = SettingsBackupService(
            defaults: defaults,
            center: NotificationCenter(),
            twitchChannelProvider: { nil },
            replaceCustomCommands: { data in
                commandStore.replaceFromImportedData(data)
            },
            replaceSongRequestBlocklist: { data in
                await blocklist.replaceFromImportedData(data)
            }
        )
        let backup = try importService.decode(encoded)

        let summary = await importService.apply(
            backup,
            choices: .init(reconnectTwitch: false)
        )

        XCTAssertEqual(summary.restoredCount, 2)
        XCTAssertEqual(summary.ignoredCount, 0)
        XCTAssertEqual(commandStore.commands, importedCommands)
        let liveBlocklist = await blocklist.allEntries
        XCTAssertEqual(liveBlocklist, expectedBlocklist)
        let persistedCommandsData = try XCTUnwrap(
            defaults.data(forKey: AppConstants.UserDefaults.customCommands)
        )
        XCTAssertEqual(
            try JSONCoders.default.decode(
                [CustomCommand].self,
                from: persistedCommandsData
            ),
            importedCommands
        )
        let persistedBlocklistData = try XCTUnwrap(
            defaults.data(forKey: AppConstants.UserDefaults.songRequestBlocklist)
        )
        XCTAssertEqual(
            try JSONCoders.camelCase.decode(
                [BlocklistItem].self,
                from: persistedBlocklistData
            ),
            expectedBlocklist
        )

        let expectedImportedBlockID = try XCTUnwrap(expectedBlocklist.first?.id)
        try await assertSubsequentMutationsRetainImportedState(
            commandStore: commandStore,
            blocklist: blocklist,
            defaults: defaults,
            importedCommands: importedCommands,
            importedBlockID: expectedImportedBlockID
        )
    }

    /// After an import, adds a command and a blocklist entry through the live owners and
    /// checks the persisted commands are the imported ones plus the new one, and the persisted
    /// blocklist holds both the imported entry and the new entry.
    private func assertSubsequentMutationsRetainImportedState(
        commandStore: CustomCommandStore,
        blocklist: SongBlocklist,
        defaults: UserDefaults,
        importedCommands: [CustomCommand],
        importedBlockID: UUID
    ) async throws {
        let laterCommand = CustomCommand(trigger: "!later", response: "Still here")
        let laterBlockedSong = BlocklistItem(value: "Later Song", type: .song)
        commandStore.add(laterCommand)
        await blocklist.add(laterBlockedSong)

        let persistedCommandsData = try XCTUnwrap(
            defaults.data(forKey: AppConstants.UserDefaults.customCommands)
        )
        let persistedCommands = try JSONCoders.default.decode(
            [CustomCommand].self,
            from: persistedCommandsData
        )
        let persistedBlocklistData = try XCTUnwrap(
            defaults.data(forKey: AppConstants.UserDefaults.songRequestBlocklist)
        )
        let persistedBlocklist = try JSONCoders.camelCase.decode(
            [BlocklistItem].self,
            from: persistedBlocklistData
        )

        XCTAssertEqual(persistedCommands, importedCommands + [laterCommand])
        XCTAssertTrue(persistedBlocklist.contains { item in
            item.id == importedBlockID
        })
        XCTAssertTrue(persistedBlocklist.contains { item in
            item.id == laterBlockedSong.id
        })
    }

    /// A backup of the current format with the given settings and no Twitch integration.
    func makeBackup(settings: [String: BackupValue]) -> SettingsBackup {
        SettingsBackup(
            format: SettingsBackup.currentFormat,
            schemaVersion: SettingsBackup.currentSchemaVersion,
            appVersion: "1.0.0",
            appBuild: "1",
            exportedAt: Date(timeIntervalSince1970: 0),
            settings: settings,
            integrations: .init(twitch: nil)
        )
    }
}

/// Parks a caller in `suspend()` until `resume()`, so a test can hold an import step open.
actor SettingsBackupAsyncGate {
    private(set) var suspended = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        suspended = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func resume() {
        released = true
        waiters.forEach { continuation in continuation.resume() }
        waiters.removeAll()
    }
}
