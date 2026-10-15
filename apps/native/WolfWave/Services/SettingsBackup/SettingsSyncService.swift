//
//  SettingsSyncService.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-09-22.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

// MARK: - Store seam

/// The slice of `NSUbiquitousKeyValueStore` the sync service touches.
///
/// Exists so tests run against an in-memory store: a hosted test must never
/// write to the developer's real iCloud, the same rule `KeychainService`
/// follows. The only production conformer is `NSUbiquitousKeyValueStore`.
protocol SettingsSyncStore: AnyObject {
    /// The stored blob for `key`, or `nil` when absent.
    func data(forKey key: String) -> Data?
    /// Writes (or with `nil`, removes) the blob for `key` locally.
    func set(_ data: Data?, forKey key: String)
    /// Flushes local writes and fetches remote ones. `false` means the store
    /// is unavailable (for example, no iCloud key-value entitlement).
    @discardableResult func synchronize() -> Bool
    /// Posted (with `object == self`) when another device changed the store.
    var externalChangeNotificationName: Notification.Name { get }
}

/// The production store. The other requirements are already methods on it.
extension NSUbiquitousKeyValueStore: SettingsSyncStore {
    var externalChangeNotificationName: Notification.Name {
        NSUbiquitousKeyValueStore.didChangeExternallyNotification
    }
}

// MARK: - Service

// ponytail: LWW on whole blob; per-key merge if two Macs edit simultaneously becomes a real complaint.
/// Mirrors the settings-backup payload to iCloud Key-Value Storage.
///
/// Reuses `SettingsBackupService` wholesale: the cloud copy is byte-for-byte
/// the same JSON an Export writes, so the exportable / account-linked /
/// runtime key classification is the sync boundary too. Accounts and tokens
/// never leave the Mac. Twitch is never auto-reconnected on a pull.
///
/// Conflict rule: last write wins on the whole blob, ordered by
/// `SettingsBackup.exportedAt`. The newest timestamp this Mac pushed or applied
/// is kept in `iCloudSettingsSyncLastAppliedAt` (seconds since 1970); a cloud
/// payload at or below it is never applied.
///
/// A pull applies with ``SettingsBackupCoder/ImportChoices/reviewDefault``,
/// manual import's default: local sharing settings (server switches, ports,
/// update channel, diagnostics sharing) stay per Mac and are never applied
/// from another one. They still ride along in the payload, but differences in
/// them never count as a change worth pushing.
///
/// Main-actor isolated: notification observers run on the main queue and hop
/// in with `MainActor.assumeIsolated`.
@MainActor
final class SettingsSyncService {

    // MARK: Properties

    /// KVS key holding the encoded `SettingsBackup`.
    static let payloadKey = "settings.v1"

    private let store: SettingsSyncStore
    private let backup: SettingsBackupService
    private let defaults: Foundation.UserDefaults
    private let center: NotificationCenter
    /// Quiet period after the last local defaults change before pushing.
    private let debounce: Duration
    /// How long after `start()` to re-check the store when the first pull
    /// found nothing newer, giving iCloud time to deliver the remote copy.
    private let initialSyncDelay: Duration
    /// Notification tokens registered in `start()`, removed in `stop()`.
    private var observers: [NSObjectProtocol] = []
    /// The synced settings (local-sharing keys stripped) this Mac last pushed
    /// or applied. `push()` skips the write when the current synced settings
    /// equal it, so unrelated defaults churn (window frames, runtime state, a
    /// local server toggle) doesn't upload anything. Reset to `nil` to force
    /// the next push.
    private var lastPushedSettings: [String: BackupValue]?
    /// Set while a pull is writing defaults so the local-change observer
    /// doesn't echo a cloud payload straight back up.
    private var isApplying = false

    /// Whether mirroring is running (observers installed).
    private(set) var isEnabled = false
    /// The debounced push in flight, if any. Tests await it.
    private(set) var pendingPush: Task<Void, Never>?
    /// The current pull, from start-up or an external-change notification. A
    /// newer notification cancels the older one. Tests await it.
    private(set) var pullTask: Task<Void, Never>?

    // MARK: Init

    /// Creates a stopped service. Call ``setEnabled(_:)`` to start mirroring.
    ///
    /// - Parameters:
    ///   - store: Key-value store. Defaults to the real iCloud store; tests pass
    ///     an in-memory one.
    ///   - backup: Payload builder and applier shared with Export / Import.
    ///   - defaults: Store observed for local changes and holding the
    ///     last-applied timestamp.
    ///   - center: Where store and defaults notifications are observed.
    ///   - debounce: Push delay after a local change.
    ///   - initialSyncDelay: Delay before the start-up re-check.
    init(
        store: SettingsSyncStore = NSUbiquitousKeyValueStore.default,
        backup: SettingsBackupService = SettingsBackupService(),
        defaults: Foundation.UserDefaults = DefaultsStore.store,
        center: NotificationCenter = .default,
        debounce: Duration = .seconds(2),
        initialSyncDelay: Duration = .seconds(10)
    ) {
        self.store = store
        self.backup = backup
        self.defaults = defaults
        self.center = center
        self.debounce = debounce
        self.initialSyncDelay = initialSyncDelay
    }

    // MARK: Public Methods

    /// Starts or stops mirroring. Turning it off leaves the cloud copy alone.
    func setEnabled(_ enabled: Bool) {
        if enabled {
            start()
        } else {
            stop()
        }
    }

    /// Applies the cloud payload if it is newer than what this Mac last
    /// applied or pushed. Returns `true` when settings changed.
    ///
    /// Does not check ``isEnabled``; callers gate it. An unreadable payload
    /// (corrupt, foreign, or from a newer schema) is ignored. Twitch is never
    /// reconnected from a pull, and local sharing settings are never applied.
    @discardableResult
    func pull() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let data = store.data(forKey: Self.payloadKey),
              let cloud = try? backup.decode(data)
        else { return false }
        let lastApplied = defaults.double(
            forKey: AppConstants.UserDefaults.iCloudSettingsSyncLastAppliedAt)
        guard cloud.exportedAt.timeIntervalSince1970 > lastApplied else { return false }
        guard !Task.isCancelled else { return false }

        isApplying = true
        defer { isApplying = false }
        let summary = await backup.apply(
            cloud, choices: .reviewDefault)
        lastPushedSettings = SettingsBackupCoder.syncedSettings(cloud.settings)
        markApplied(cloud.exportedAt)
        Log.info(
            "SettingsSync: applied cloud settings",
            category: .app,
            fields: ["restored": "\(summary.restoredCount)"]
        )
        return true
    }

    /// Uploads the current exportable preferences now, skipping the write when
    /// nothing exportable changed since the last push.
    ///
    /// The payload is stamped strictly after the last applied timestamp, so a
    /// push always outranks the copy it was built on even when the clocks of
    /// two Macs disagree. Nothing is recorded when `synchronize()` fails, so the
    /// next change retries.
    ///
    /// - Parameter now: Clock for the `exportedAt` stamp (injectable for tests).
    func push(now: Date = Date()) {
        guard isEnabled else { return }
        let lastApplied = defaults.double(
            forKey: AppConstants.UserDefaults.iCloudSettingsSyncLastAppliedAt)
        // ISO-8601 encoding stores whole seconds, so advance by a full second.
        let exportedAtSeconds = max(
            now.timeIntervalSince1970.rounded(.down), lastApplied + 1)
        let exportedAt = Date(
            timeIntervalSince1970: exportedAtSeconds)
        guard let payload = try? backup.makeBackup(exportedAt: exportedAt) else { return }
        let synced = SettingsBackupCoder.syncedSettings(payload.settings)
        guard synced != lastPushedSettings else { return }
        guard let data = try? SettingsBackupCoder().encode(payload) else { return }
        store.set(data, forKey: Self.payloadKey)
        guard store.synchronize() else { return }
        lastPushedSettings = synced
        // `markApplied` writes defaults, which would schedule another push.
        isApplying = true
        markApplied(payload.exportedAt)
        isApplying = false
        Log.info("SettingsSync: pushed settings to iCloud", category: .app)
    }

    /// Pushes a debounced local change right now instead of waiting out the
    /// debounce. Call on quit, before logging shuts down, so a setting changed
    /// in the last couple of seconds still reaches iCloud.
    ///
    /// Only pushes when a local change is actually pending. With nothing
    /// pending there is nothing new to say, and pushing anyway could stamp an
    /// unchanged local copy over a newer cloud payload this launch has not
    /// pulled yet.
    func flush(now: Date = Date()) {
        guard let pending = pendingPush else { return }
        pending.cancel()
        pendingPush = nil
        guard isEnabled else { return }
        push(now: now)
    }

    // MARK: Private Helpers

    /// Installs the iCloud and defaults observers, then pulls. If the first
    /// pull applied nothing, it re-checks once after `initialSyncDelay`, which
    /// may push this Mac's copy when the cloud is empty or older.
    private func start() {
        guard !isEnabled else { return }
        isEnabled = true
        observers.append(center.addObserver(
            forName: store.externalChangeNotificationName,
            object: store,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in
                self?.pullTask?.cancel()
                self?.pullTask = Task { [weak self] in
                    await self?.handleExternalChange()
                }
            }
        })
        observers.append(center.addObserver(
            forName: Foundation.UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in
                self?.schedulePush()
            }
        })
        store.synchronize()
        pullTask = Task { [weak self, initialSyncDelay] in
            guard let self else { return }
            if await pull() { return }
            try? await Task.sleep(for: initialSyncDelay)
            guard !Task.isCancelled, isEnabled else { return }
            await handleExternalChange()
        }
    }

    /// Removes observers and cancels any pending push or pull. The cloud copy
    /// and the last-applied timestamp are left as they are.
    private func stop() {
        guard isEnabled else { return }
        isEnabled = false
        observers.forEach(center.removeObserver)
        observers.removeAll()
        pendingPush?.cancel()
        pendingPush = nil
        pullTask?.cancel()
        pullTask = nil
    }

    /// Restarts the debounce timer for a push. Ignored while a pull is writing
    /// defaults, so an applied cloud payload isn't echoed back.
    private func schedulePush() {
        guard isEnabled, !isApplying else { return }
        pendingPush?.cancel()
        pendingPush = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.push()
        }
    }

    /// Reconciles after iCloud reports a remote change (and once at start-up).
    ///
    /// - Cloud missing or unreadable: push this Mac's copy to repair it.
    /// - Cloud newer than last applied: pull it.
    /// - Otherwise: push only if the local synced settings differ from the
    ///   cloud copy's (local-sharing keys are ignored).
    private func handleExternalChange() async {
        guard isEnabled, !Task.isCancelled else { return }
        guard let data = store.data(forKey: Self.payloadKey),
              let cloud = try? backup.decode(data)
        else {
            lastPushedSettings = nil
            push()
            return
        }

        let lastApplied = defaults.double(
            forKey: AppConstants.UserDefaults.iCloudSettingsSyncLastAppliedAt)
        if cloud.exportedAt.timeIntervalSince1970 > lastApplied {
            await pull()
            return
        }

        guard let local = try? backup.makeBackup(),
              SettingsBackupCoder.syncedSettings(local.settings)
                != SettingsBackupCoder.syncedSettings(cloud.settings)
        else { return }
        lastPushedSettings = nil
        push()
    }

    /// Records `date` as the newest payload this Mac has pushed or applied.
    private func markApplied(_ date: Date) {
        defaults.set(
            date.timeIntervalSince1970,
            forKey: AppConstants.UserDefaults.iCloudSettingsSyncLastAppliedAt)
    }
}
