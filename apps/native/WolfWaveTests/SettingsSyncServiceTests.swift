//
//  SettingsSyncServiceTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-09-22.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// In-memory stand-in for `NSUbiquitousKeyValueStore`. Never touches iCloud.
private final class FakeSyncStore: SettingsSyncStore {
    var storage: [String: Data] = [:]
    var writes = 0
    var acceptsWrites = true
    var synchronizeResult = true
    let externalChangeNotificationName = Notification.Name("FakeSyncStore.changed")

    func data(forKey key: String) -> Data? { storage[key] }
    func set(_ data: Data?, forKey key: String) {
        writes += 1
        if acceptsWrites { storage[key] = data }
    }
    func synchronize() -> Bool { synchronizeResult }
}

/// `SettingsSyncService`, the opt-in iCloud KVS mirror of the settings backup.
/// Runs against `FakeSyncStore` (in-memory `SettingsSyncStore`), a throwaway
/// `UserDefaults` suite, and a private `NotificationCenter`, so it never touches
/// real iCloud or the live defaults domain. Covers push/pull ordering
/// (last-write-wins by `exportedAt`), no-echo of its own push, retry after a failed
/// synchronize, delayed startup payloads, and `flush()` only when a change is pending.
@MainActor
final class SettingsSyncServiceTests: WolfWaveTestCase {

    private var scratch: ThrowawayDefaults!
    private var defaults: UserDefaults!
    private var center: NotificationCenter!
    private var store: FakeSyncStore!
    private var backup: SettingsBackupService!

    override func setUp() async throws {
        try await super.setUp()
        scratch = ThrowawayDefaults("SettingsSyncServiceTests")
        defaults = scratch.defaults
        center = NotificationCenter()
        store = FakeSyncStore()
        backup = SettingsBackupService(
            defaults: defaults,
            center: center,
            twitchChannelProvider: { nil },
            replaceCustomCommands: { _ in false },
            replaceSongRequestBlocklist: { _ in false },
            sideEffects: SettingsBackupService.SideEffects(
                isLaunchAtLoginEnabled: { false },
                setLaunchAtLogin: { _ in .success },
                applyAppearance: { _ in },
                applyUpdatePreferences: { _ in }
            )
        )
    }

    override func tearDown() async throws {
        scratch.destroy()
        try await super.tearDown()
    }

    /// A service wired to this test's fake store, backup service, defaults, and center. Defaults to
    /// zero debounce and a 60 s start-up re-check delay (the production default
    /// is 10 s), so the delayed re-check does not fire during a test.
    private func makeService(
        debounce: Duration = .zero,
        initialSyncDelay: Duration = .seconds(60)
    ) -> SettingsSyncService {
        SettingsSyncService(
            store: store,
            backup: backup,
            defaults: defaults,
            center: center,
            debounce: debounce,
            initialSyncDelay: initialSyncDelay)
    }

    /// Encoded backup as the cloud copy would hold it: one Discord setting, stamped `exportedAt`.
    private func cloudPayload(exportedAt: Date, discordEnabled: Bool) throws -> Data {
        let payload = SettingsBackup(
            format: SettingsBackup.currentFormat,
            schemaVersion: SettingsBackup.currentSchemaVersion,
            appVersion: "1.0.0",
            appBuild: "1",
            exportedAt: exportedAt,
            settings: [AppConstants.UserDefaults.discordPresenceEnabled: .bool(discordEnabled)],
            integrations: .init(twitch: nil)
        )
        return try SettingsBackupCoder().encode(payload)
    }

    // MARK: Tests

    func testDisabledServiceNeverWrites() {
        let service = makeService()
        service.push()
        XCTAssertEqual(store.writes, 0)
    }

    func testPushWritesEncodedBackup() throws {
        defaults.set(true, forKey: AppConstants.UserDefaults.discordPresenceEnabled)
        let service = makeService()
        service.setEnabled(true)
        service.push(now: Date(timeIntervalSince1970: 100))

        let data = try XCTUnwrap(store.storage[SettingsSyncService.payloadKey])
        let decoded = try SettingsBackupCoder().decode(data)
        XCTAssertEqual(decoded.settings[AppConstants.UserDefaults.discordPresenceEnabled], .bool(true))
        XCTAssertEqual(
            defaults.double(forKey: AppConstants.UserDefaults.iCloudSettingsSyncLastAppliedAt), 100)
    }

    func testPushSkipsWhenNothingChanged() {
        let service = makeService()
        service.setEnabled(true)
        service.push(now: Date(timeIntervalSince1970: 100))
        let writes = store.writes
        service.push(now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(store.writes, writes)
    }

    func testPushUsesTimestampAfterFutureWatermark() throws {
        defaults.set(true, forKey: AppConstants.UserDefaults.discordPresenceEnabled)
        defaults.set(
            500.0, forKey: AppConstants.UserDefaults.iCloudSettingsSyncLastAppliedAt)
        let service = makeService()
        service.setEnabled(true)

        service.push(now: Date(timeIntervalSince1970: 100))

        let data = try XCTUnwrap(store.storage[SettingsSyncService.payloadKey])
        let exportedAt = try SettingsBackupCoder().decode(data).exportedAt.timeIntervalSince1970
        XCTAssertGreaterThan(exportedAt, 500)
        XCTAssertEqual(
            defaults.double(forKey: AppConstants.UserDefaults.iCloudSettingsSyncLastAppliedAt),
            exportedAt)
    }

    func testFailedSynchronizationLeavesPushRetryable() throws {
        defaults.set(true, forKey: AppConstants.UserDefaults.discordPresenceEnabled)
        store.synchronizeResult = false
        let service = makeService()
        service.setEnabled(true)

        service.push(now: Date(timeIntervalSince1970: 100))
        store.synchronizeResult = true
        service.push(now: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(store.writes, 2)
        XCTAssertEqual(
            defaults.double(forKey: AppConstants.UserDefaults.iCloudSettingsSyncLastAppliedAt), 200)
        let data = try XCTUnwrap(store.storage[SettingsSyncService.payloadKey])
        XCTAssertEqual(
            try SettingsBackupCoder().decode(data)
                .settings[AppConstants.UserDefaults.discordPresenceEnabled],
            .bool(true))
    }

    func testPullAppliesNewerCloudPayload() async throws {
        store.storage[SettingsSyncService.payloadKey] = try cloudPayload(
            exportedAt: Date(timeIntervalSince1970: 500), discordEnabled: true)
        let service = makeService()

        let applied = await service.pull()

        XCTAssertTrue(applied)
        XCTAssertTrue(defaults.bool(forKey: AppConstants.UserDefaults.discordPresenceEnabled))
        XCTAssertEqual(
            defaults.double(forKey: AppConstants.UserDefaults.iCloudSettingsSyncLastAppliedAt), 500)
    }

    func testPullIgnoresOlderCloudPayload() async throws {
        defaults.set(1_000.0, forKey: AppConstants.UserDefaults.iCloudSettingsSyncLastAppliedAt)
        store.storage[SettingsSyncService.payloadKey] = try cloudPayload(
            exportedAt: Date(timeIntervalSince1970: 500), discordEnabled: true)
        let service = makeService()

        let applied = await service.pull()

        XCTAssertFalse(applied)
        XCTAssertFalse(defaults.bool(forKey: AppConstants.UserDefaults.discordPresenceEnabled))
    }

    func testOwnPushIsNotReappliedOnPull() async {
        let service = makeService()
        service.setEnabled(true)
        service.push(now: Date(timeIntervalSince1970: 100))
        let applied = await service.pull()
        XCTAssertFalse(applied)
    }

    func testLocalChangeSchedulesPush() async throws {
        let service = makeService()
        service.setEnabled(true)
        // Drain the start-up pull so the write counter is stable.
        await Task.yield()
        service.push(now: Date(timeIntervalSince1970: 100))
        let writes = store.writes

        defaults.set(true, forKey: AppConstants.UserDefaults.discordPresenceEnabled)
        center.post(name: UserDefaults.didChangeNotification, object: defaults)
        await service.pendingPush?.value

        XCTAssertEqual(store.writes, writes + 1)
    }

    func testExternalChangeTriggersPull() async throws {
        let service = makeService()
        service.setEnabled(true)
        store.storage[SettingsSyncService.payloadKey] = try cloudPayload(
            exportedAt: Date.distantFuture, discordEnabled: true)

        center.post(name: store.externalChangeNotificationName, object: store)
        // The observer hops through a Task, so poll for the observable result.
        let applied = await waitUntil(timeout: .seconds(2)) {
            defaults.bool(forKey: AppConstants.UserDefaults.discordPresenceEnabled)
        }

        XCTAssertTrue(applied)
    }

    func testDelayedStartupPayloadIsAppliedWithoutOverwritingCloud() async throws {
        let service = makeService(initialSyncDelay: .milliseconds(100))
        service.setEnabled(true)
        try await Task.sleep(for: .milliseconds(10))
        store.storage[SettingsSyncService.payloadKey] = try cloudPayload(
            exportedAt: Date.distantFuture, discordEnabled: true)

        center.post(name: store.externalChangeNotificationName, object: store)
        await service.pullTask?.value

        XCTAssertEqual(store.writes, 0)
        XCTAssertTrue(defaults.bool(forKey: AppConstants.UserDefaults.discordPresenceEnabled))
    }

    func testOlderExternalPayloadReassertsCurrentLocalSettings() async throws {
        defaults.set(true, forKey: AppConstants.UserDefaults.discordPresenceEnabled)
        let service = makeService()
        service.setEnabled(true)
        service.push(now: Date(timeIntervalSince1970: 100))
        store.storage[SettingsSyncService.payloadKey] = try cloudPayload(
            exportedAt: Date(timeIntervalSince1970: 50), discordEnabled: false)

        center.post(name: store.externalChangeNotificationName, object: store)
        await service.pullTask?.value

        XCTAssertEqual(store.writes, 2)
        let data = try XCTUnwrap(store.storage[SettingsSyncService.payloadKey])
        XCTAssertEqual(
            try SettingsBackupCoder().decode(data)
                .settings[AppConstants.UserDefaults.discordPresenceEnabled],
            .bool(true))
    }

    // MARK: Local sharing settings

    /// Encoded cloud payload carrying a portable key plus machine-specific ones
    /// (server switches, a port, the update channel).
    private func cloudPayloadWithLocalSharing(exportedAt: Date) throws -> Data {
        let keys = AppConstants.UserDefaults.self
        let payload = SettingsBackup(
            format: SettingsBackup.currentFormat,
            schemaVersion: SettingsBackup.currentSchemaVersion,
            appVersion: "1.0.0",
            appBuild: "1",
            exportedAt: exportedAt,
            settings: [
                keys.discordPresenceEnabled: .bool(true),
                keys.websocketEnabled: .bool(true),
                keys.widgetHTTPEnabled: .bool(true),
                keys.websocketServerPort: .int(9_123),
                keys.updateChannel: .string("nightly")
            ],
            integrations: .init(twitch: nil)
        )
        return try SettingsBackupCoder().encode(payload)
    }

    /// A pull matches manual import's default: local sharing and server
    /// settings from another Mac are never applied.
    func testPullNeverAppliesLocalSharingSettings() async throws {
        let keys = AppConstants.UserDefaults.self
        store.storage[SettingsSyncService.payloadKey] = try cloudPayloadWithLocalSharing(
            exportedAt: Date(timeIntervalSince1970: 500))
        let service = makeService()

        let applied = await service.pull()

        XCTAssertTrue(applied)
        XCTAssertTrue(defaults.bool(forKey: keys.discordPresenceEnabled))
        XCTAssertNil(defaults.object(forKey: keys.websocketEnabled))
        XCTAssertNil(defaults.object(forKey: keys.widgetHTTPEnabled))
        XCTAssertNil(defaults.object(forKey: keys.websocketServerPort))
        XCTAssertNil(defaults.object(forKey: keys.updateChannel))
    }

    /// Settings that only differ in local sharing keys are not a change worth
    /// pushing, so two Macs with different servers don't upload back and forth.
    func testLocalSharingDifferencesDoNotTriggerPush() async throws {
        store.storage[SettingsSyncService.payloadKey] = try cloudPayloadWithLocalSharing(
            exportedAt: Date(timeIntervalSince1970: 500))
        let service = makeService()
        service.setEnabled(true)
        await service.pullTask?.value
        let writes = store.writes

        service.push(now: Date(timeIntervalSince1970: 1_000))
        center.post(name: store.externalChangeNotificationName, object: store)
        await service.pullTask?.value

        XCTAssertEqual(store.writes, writes)
    }

    // MARK: Flush on quit

    func testFlushPushesPendingChanges() throws {
        // A long debounce keeps the scheduled push parked, like a quit that
        // lands inside the debounce window.
        let service = makeService(debounce: .seconds(60))
        service.setEnabled(true)
        service.push(now: Date(timeIntervalSince1970: 100))
        let writes = store.writes

        defaults.set(true, forKey: AppConstants.UserDefaults.discordPresenceEnabled)
        center.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertNotNil(service.pendingPush)

        service.flush(now: Date(timeIntervalSince1970: 200))

        XCTAssertNil(service.pendingPush)
        XCTAssertEqual(store.writes, writes + 1)
        let data = try XCTUnwrap(store.storage[SettingsSyncService.payloadKey])
        XCTAssertEqual(
            try SettingsBackupCoder().decode(data)
                .settings[AppConstants.UserDefaults.discordPresenceEnabled],
            .bool(true))
    }

    func testFlushWithoutPendingChangeDoesNotWrite() {
        let service = makeService(debounce: .seconds(60))
        service.setEnabled(true)

        service.flush(now: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(store.writes, 0)
    }

    func testFlushWhenDisabledNeverWrites() {
        let service = makeService(debounce: .seconds(60))
        service.flush(now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(store.writes, 0)
    }
}
