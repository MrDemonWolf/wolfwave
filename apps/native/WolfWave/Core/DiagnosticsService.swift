//
//  DiagnosticsService.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-22.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import MetricKit

// MARK: - MetricKit Seam

/// The two `MXMetricManager` calls `DiagnosticsService` makes. A seam so a
/// test can count registrations without a process-wide MetricKit subscription.
nonisolated protocol MetricKitRegistering: AnyObject {
    func add(_ subscriber: any MXMetricManagerSubscriber)
    func remove(_ subscriber: any MXMetricManagerSubscriber)
}

nonisolated extension MXMetricManager: MetricKitRegistering {}

// MARK: - Diagnostics Service

/// Privacy-preserving, on-device diagnostics using Apple's MetricKit.
///
/// When the user opts in, this service subscribes to `MXMetricManager` and
/// persists crash, hang, and performance payloads as JSON under Application
/// Support. **No data ever leaves the device.** There is no network code
/// here. It also keeps a local, anonymous app-launch counter.
///
/// Use `DiagnosticsService.shared`. The initializer is internal so tests can
/// inject an isolated `UserDefaults`.
///
/// Marked `@unchecked Sendable` because all mutable state is lock-guarded;
/// MetricKit invokes the subscriber callbacks off the main thread.
///
/// `nonisolated` is load-bearing. The module defaults to `MainActor`
/// isolation, and MetricKit delivers both `didReceive(_:)` callbacks on a
/// background queue; a MainActor-isolated class would make the `@objc`
/// thunks assert the main-actor executor and trap on payload delivery.
/// Everything this class touches is safe off-main: lock-guarded state,
/// `UserDefaults`, `FileManager`, `Log`, and `SharedFormatters.iso8601`.
/// Mirrors the `MetricsService` / `PlayLogStore` pattern.
nonisolated final class DiagnosticsService: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {

    // MARK: - Singleton

    /// Shared instance used across the app.
    static let shared = DiagnosticsService()

    // MARK: - Properties

    /// Holds the opt-in flag and the launch counter.
    private let defaults: UserDefaults
    /// Injected payload directory (tests). `nil` in production.
    private let payloadDirectoryOverride: URL?
    /// Cap on payload files kept after each write (clamped to `>= 0`).
    private let maxStoredPayloads: Int
    /// Age cutoff for payload files, in seconds.
    private let maxPayloadAge: TimeInterval
    /// Where the subscriber is registered. `MXMetricManager.shared` in production.
    private let metricManager: any MetricKitRegistering
    /// Guards ``isSubscribed`` and ``lastDiagnosticSummary``.
    private let lock = NSLock()
    /// Serializes `setEnabled`, so the subscription check, the MetricKit
    /// call, and the flag update happen as one step. Separate from `lock`
    /// so a MetricKit callback can never wait behind a registration.
    private let subscriptionLock = NSLock()
    /// Whether `self` is currently registered with `MXMetricManager`.
    private var isSubscribed = false
    /// Summary of the latest diagnostic batch; in memory only, so it resets
    /// each launch.
    private var lastDiagnosticSummary: String?

    // MARK: - Init

    /// Internal so unit tests can inject an isolated `UserDefaults` and a temp
    /// payload directory; app code uses `shared`.
    ///
    /// - Parameters:
    ///   - defaults: Preference store holding the opt-in and launch counter.
    ///   - payloadDirectory: Where payloads are written. `nil` uses
    ///     `Application Support/WolfWave/Diagnostics`.
    ///   - maxStoredPayloads: Newest payload files kept after each write.
    ///   - maxPayloadAge: Payload files older than this are deleted after each
    ///     write.
    ///   - metricManager: Where the subscriber registers. Tests inject a fake.
    init(
        defaults: UserDefaults = DefaultsStore.store,
        payloadDirectory: URL? = nil,
        maxStoredPayloads: Int = 50,
        maxPayloadAge: TimeInterval = 30 * 24 * 60 * 60,
        metricManager: any MetricKitRegistering = MXMetricManager.shared
    ) {
        self.metricManager = metricManager
        self.defaults = defaults
        self.payloadDirectoryOverride = payloadDirectory
        self.maxStoredPayloads = max(0, maxStoredPayloads)
        self.maxPayloadAge = maxPayloadAge
        super.init()
    }

    // MARK: - Opt-In

    /// Whether the user has opted in to on-device diagnostics collection.
    var isEnabled: Bool {
        defaults.bool(forKey: AppConstants.UserDefaults.shareDiagnosticsEnabled)
    }

    /// Registers or removes the MetricKit subscriber to match the stored opt-in
    /// preference. Call once at launch.
    func applyEnabledState() {
        setEnabled(isEnabled)
    }

    /// Subscribes to or unsubscribes from MetricKit payloads.
    ///
    /// Turning it off also deletes every stored payload: opting out means the
    /// data goes too, not just that collection stops. The one exception is a
    /// test harness with no injected directory, which skips the delete so it
    /// cannot wipe the developer's real payloads. Deletion runs on every
    /// "off" call, even when not currently subscribed.
    ///
    /// - Parameter enabled: `true` to start collecting on-device diagnostics.
    func setEnabled(_ enabled: Bool) {
        // A test harness (hosted unit tests, or a UI test driving the dev app)
        // shares the dev app's container, so it only ever deletes an injected
        // directory, never the developer's real payloads.
        if !enabled, payloadDirectoryOverride != nil || !UITestMode.isUnderTestHarness {
            deleteStoredPayloads()
        }

        // Check, register, and record under one lock so two concurrent
        // calls can't both see "not subscribed" and register twice.
        subscriptionLock.withLock {
            let alreadySubscribed = lock.withLock { isSubscribed }

            if enabled, !alreadySubscribed {
                metricManager.add(self)
                lock.withLock { isSubscribed = true }
                Log.info("DiagnosticsService: MetricKit subscriber registered (opt-in on)", category: .diagnostics)
            } else if !enabled, alreadySubscribed {
                metricManager.remove(self)
                lock.withLock { isSubscribed = false }
                Log.info("DiagnosticsService: MetricKit subscriber removed (opt-in off)", category: .diagnostics)
            }
        }
    }

    // MARK: - Anonymous Usage

    /// Increments the local app-launch counter in `defaults`. The count never
    /// leaves the device.
    ///
    /// Only counts when the user has opted in to diagnostics.
    func recordAppLaunch() {
        guard isEnabled else { return }
        let next = defaults.integer(forKey: AppConstants.UserDefaults.diagnosticsLaunchCount) + 1
        defaults.set(next, forKey: AppConstants.UserDefaults.diagnosticsLaunchCount)
    }

    /// Total app launches recorded on this device (only launches made while
    /// opted in are counted).
    var launchCount: Int {
        defaults.integer(forKey: AppConstants.UserDefaults.diagnosticsLaunchCount)
    }

    /// Human-readable summary of the most recent MetricKit diagnostic payload,
    /// or `nil` if none has been received this session.
    var diagnosticSummary: String? {
        lock.withLock { lastDiagnosticSummary }
    }

    /// On-device directory where MetricKit payloads are persisted.
    var payloadDirectory: URL {
        payloadDirectoryOverride ?? AppContainer.directory("Diagnostics")
    }

    /// Deletes payload files beyond the newest `maxStoredPayloads` and any
    /// older than `maxPayloadAge`. Runs after every write so the folder can't
    /// grow without bound on a Mac that stays opted in for years.
    ///
    /// - Parameter now: Reference time for the age cutoff. Tests pin it.
    func prunePayloads(now: Date = Date()) {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: payloadDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let dated = urls
            .filter { $0.pathExtension == "json" }
            .map { url in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return (url: url, modified: modified)
            }
            .sorted { $0.modified > $1.modified } // newest first

        let cutoff = now.addingTimeInterval(-maxPayloadAge)
        var removed = 0
        for (index, entry) in dated.enumerated()
        where index >= maxStoredPayloads || entry.modified < cutoff {
            if (try? fileManager.removeItem(at: entry.url)) != nil {
                removed += 1
            }
        }
        if removed > 0 {
            Log.info(
                "DiagnosticsService: Pruned old payloads",
                category: .diagnostics,
                fields: ["removed": "\(removed)"]
            )
        }
    }

    // MARK: - MXMetricManagerSubscriber

    /// MetricKit's daily metric batch. Called on a background queue; persisted
    /// as `metric-<stamp>-<n>.json` only while opted in.
    func didReceive(_ payloads: [MXMetricPayload]) {
        guard isEnabled else { return }
        persist(payloads.map { $0.jsonRepresentation() }, prefix: "metric")
    }

    /// MetricKit's diagnostic batch (crashes, hangs, CPU and disk-write
    /// exceptions), typically delivered on the launch after the event. Called on
    /// a background queue. Persists `diagnostic-<stamp>-<n>.json` files and
    /// updates ``diagnosticSummary``, only while opted in.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard isEnabled else { return }
        persist(payloads.map { $0.jsonRepresentation() }, prefix: "diagnostic")

        let summary = Self.summarize(payloads)
        lock.withLock { lastDiagnosticSummary = summary }
        Log.info("DiagnosticsService: \(summary)", category: .diagnostics)
    }

    // MARK: - Private Helpers

    /// Writes raw payload JSON to the on-device payload directory, then prunes.
    ///
    /// Filenames are `<prefix>-<ISO-8601 stamp with ':' replaced by '-'>-<index>.json`
    /// (colons are not safe in filenames). A failure is logged, and the rest
    /// of the batch is skipped.
    private func persist(_ payloads: [Data], prefix: String) {
        guard !payloads.isEmpty else { return }
        let dir = payloadDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = SharedFormatters.iso8601.string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            for (index, data) in payloads.enumerated() {
                let url = dir.appending(path: "\(prefix)-\(stamp)-\(index).json")
                try data.write(to: url)
            }
            prunePayloads()
        } catch {
            Log.error(
                "DiagnosticsService: Failed to persist \(prefix) payload: \(error.localizedDescription)",
                category: .diagnostics
            )
        }
    }

    /// Removes the whole payload folder (not just `.json` files). No-op when it
    /// doesn't exist; a failure is logged, not thrown.
    private func deleteStoredPayloads() {
        let dir = payloadDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.removeItem(at: dir)
            Log.info("DiagnosticsService: Deleted stored payloads (opt-in off)", category: .diagnostics)
        } catch {
            Log.error(
                "DiagnosticsService: Failed to delete stored payloads: \(error.localizedDescription)",
                category: .diagnostics
            )
        }
    }

    /// Builds a one-line count summary across a batch of diagnostic payloads.
    private static func summarize(_ payloads: [MXDiagnosticPayload]) -> String {
        var crashes = 0, hangs = 0, cpu = 0, diskWrites = 0
        for payload in payloads {
            crashes += payload.crashDiagnostics?.count ?? 0
            hangs += payload.hangDiagnostics?.count ?? 0
            cpu += payload.cpuExceptionDiagnostics?.count ?? 0
            diskWrites += payload.diskWriteExceptionDiagnostics?.count ?? 0
        }
        return "\(crashes) crash · \(hangs) hang · \(cpu) CPU · \(diskWrites) disk-write"
    }
}
