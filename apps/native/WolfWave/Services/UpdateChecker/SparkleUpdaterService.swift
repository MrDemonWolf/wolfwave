//
//  SparkleUpdaterService.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-03-18.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

/// Service that manages automatic updates via the Sparkle framework.
///
/// Sparkle handles:
/// - Automatic update checking on a configurable schedule
/// - Downloading and verifying update packages
/// - Installing updates with user confirmation
/// - Delta updates (only downloading changed files)
/// - Code signature verification for security
///
/// Architecture:
/// - Wraps Sparkle's `SPUStandardUpdaterController`
/// - Provides a simplified API for the app to trigger manual checks
/// - Respects user preferences for automatic checking
/// - Posts `updateStateChanged` (via `postUpdateState`) to keep the Software
///   Update pane in sync
/// - Never downloads before the user clicks Install
///   (`automaticallyDownloadsUpdates = false`)
///
/// Homebrew installs:
/// - Sparkle is never created; every check is a logged no-op because the
///   cask manages updates.
///
/// Thread Safety:
/// - The class is `@MainActor` (matches `SPUUpdaterDelegate`'s `NS_SWIFT_UI_ACTOR`).
/// - All Sparkle APIs and notification posts run on the main actor.
///
/// DEBUG builds:
/// - The controller is created with `startingUpdater: false`, automatic
///   checks are forced off, and the updater is then started manually. A
///   never-started updater ignores `checkForUpdates()`, so this keeps manual
///   "Check for Updates" working while background checks stay disabled.
/// - The delegate points the feed at the bundled `dev-appcast.xml` so manual
///   "Check for Updates" exercises the full Sparkle UI against a dummy entry.

import Foundation
import Sparkle

// MARK: - SparkleUpdaterService

/// Sparkle wrapper owned by `AppDelegate`; see the overview at the top of
/// this file for behavior, threading, Homebrew, and DEBUG rules.
@MainActor
final class SparkleUpdaterService: NSObject {
    // MARK: - Properties

    /// Sparkle's updater controller (manages the update process). `nil` for
    /// Homebrew installs, where Sparkle is never set up.
    private var updaterController: SPUStandardUpdaterController?

    /// Whether the current update cycle already surfaced a found update.
    /// Sparkle calls `didFinishUpdateCycleFor` with an error after
    /// `failedToDownloadUpdate` in the same session; without this flag that
    /// error path would post `isUpdateAvailable: false` and wipe the
    /// already-announced update from the settings pane.
    private var didSurfaceUpdateThisCycle = false

    /// The updater instance (for manual checks and configuration); `nil`
    /// whenever ``updaterController`` is.
    private var updater: SPUUpdater? {
        updaterController?.updater
    }

    /// Whether automatic update checking is enabled.
    ///
    /// Reports `true` when there is no updater (Homebrew). In Release it reads
    /// Sparkle's live value; in DEBUG it reads the stored preference, because
    /// Sparkle's own flag is held off there. Setting it persists the choice
    /// under `AppConstants.UserDefaults.updateCheckEnabled`, which
    /// ``setupSparkle()`` reads on the next launch, and hands Sparkle
    /// ``sparkleAutomaticChecks(preference:isDebug:)``, so DEBUG never starts
    /// background checks. Without an updater the write is dropped and logged,
    /// and nothing is persisted.
    var automaticCheckEnabled: Bool {
        get {
            guard let updater else { return true }
            if Self.isDebugBuild {
                return Preferences.bool(
                    AppConstants.UserDefaults.updateCheckEnabled,
                    default: AppConstants.UserDefaults.Defaults.updateCheckEnabled)
            }
            return updater.automaticallyChecksForUpdates
        }
        set {
            guard let updater else {
                Log.warn(
                    "SparkleUpdaterService: automaticCheckEnabled ignored: updater not initialized",
                    category: .update)
                return
            }
            updater.automaticallyChecksForUpdates = Self.sparkleAutomaticChecks(
                preference: newValue, isDebug: Self.isDebugBuild)
            DefaultsStore.store.set(newValue, forKey: AppConstants.UserDefaults.updateCheckEnabled)
            Log.info(
                "SparkleUpdaterService: Automatic checking \(newValue ? "enabled" : "disabled")",
                category: .update)
        }
    }

    /// The selected update channel (Stable or Nightly).
    ///
    /// Persisted under `AppConstants.UserDefaults.updateChannel`. Changing it
    /// re-points the appcast feed on the next check via `feedURLString(for:)`.
    /// Call `recheckAfterChannelChange()` to consult the new feed immediately.
    var channel: UpdateChannel {
        get {
            UpdateChannel.from(rawValue: DefaultsStore.store.string(forKey: AppConstants.UserDefaults.updateChannel))
        }
        set {
            DefaultsStore.store.set(newValue.rawValue, forKey: AppConstants.UserDefaults.updateChannel)
            Log.info("SparkleUpdaterService: Update channel set to \(newValue.rawValue)", category: .update)
        }
    }

    /// Silently re-checks the (possibly new) channel's feed after a channel switch.
    ///
    /// Uses a background check so the user isn't shown a modal when already up to
    /// date. No-op in DEBUG (background checks are disabled) and for Homebrew.
    func recheckAfterChannelChange() {
        checkForUpdatesInBackground()
    }

    /// Whether the app was installed via Homebrew. Fixed at init; when true,
    /// Sparkle is never created and every check is a no-op.
    private let isHomebrewInstall: Bool

    // MARK: - Initialization

    /// Detects the install method and, unless it is Homebrew, creates and
    /// configures Sparkle (which starts the update cycle in Release).
    override init() {
        // Detect install method before initializing Sparkle
        self.isHomebrewInstall = Bundle.main.isHomebrewInstall

        super.init()

        if isHomebrewInstall {
            Log.info("SparkleUpdaterService: Homebrew installation detected: Sparkle disabled", category: .update)
            return
        }

        setupSparkle()
    }

    // MARK: - Setup

    /// Initializes and configures the Sparkle updater controller.
    private func setupSparkle() {
        Log.info("SparkleUpdaterService: Initializing Sparkle framework", category: .update)

        // In DEBUG, instantiate the controller without starting the background
        // update cycle; the updater is started manually below with automatic
        // checks forced off. Manual "Check for Updates" is routed at the
        // bundled dev-appcast.xml via `feedURLString(for:)`.
        #if DEBUG
        let startingUpdater = false
        #else
        let startingUpdater = true
        #endif

        updaterController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        // Configure updater preferences
        if let updater = updater {
            // Respect user's update check preference (defaults to true)
            let checkEnabled = Preferences.bool(AppConstants.UserDefaults.updateCheckEnabled, default: AppConstants.UserDefaults.Defaults.updateCheckEnabled)
            updater.automaticallyChecksForUpdates = Self.sparkleAutomaticChecks(
                preference: checkEnabled, isDebug: Self.isDebugBuild)

            // Set check interval (24 hours)
            updater.updateCheckInterval = AppConstants.Update.checkInterval

            // Require explicit user consent before downloading. Combined with
            // `updaterShouldPromptForPermissionToCheck` returning false, this
            // ensures Sparkle never moves bytes onto the user's disk until they
            // click "Install" in the update dialog. Auto-download would silently
            // commit network + storage before consent.
            updater.automaticallyDownloadsUpdates = false

            Log.info(
                "SparkleUpdaterService: Configuration complete",
                category: .update,
                fields: [
                    "autoCheck": checkEnabled,
                    "seconds": Int(AppConstants.Update.checkInterval),
                    "starting": startingUpdater
                ])
        }

        #if DEBUG
        // A never-started updater silently ignores `checkForUpdates()`
        // (Sparkle guards on having been started), which made the documented
        // dev-appcast manual check a no-op while `checkForUpdates()` still
        // returned true. Force automatic checks off first (background checks
        // stay disabled in DEBUG), then start the updater so manual
        // "Check for Updates" works. Skipped under XCTest: unit tests build
        // multiple service instances and must not start real Sparkle updaters
        // in the shared test host.
        if !WolfWaveApp.isRunningTests {
            updater?.automaticallyChecksForUpdates = false
            updaterController?.startUpdater()
            Log.info("SparkleUpdaterService: DEBUG updater started (manual checks only)", category: .update)
        }
        #endif
    }

    // MARK: - Public API

    /// Manually triggers an update check.
    ///
    /// Shows Sparkle's update dialog with results. If an update is available,
    /// the user can choose to download and install it immediately.
    ///
    /// - Returns: `true` when Sparkle handled the request and presented its UI;
    ///   `false` when the call was a no-op (Homebrew install or uninitialized
    ///   updater) so callers can open a fallback URL instead of failing silently.
    @discardableResult
    func checkForUpdates() -> Bool {
        guard !isHomebrewInstall else {
            Log.warn("SparkleUpdaterService: Manual check ignored: app is managed by Homebrew", category: .update)
            return false
        }

        guard let updater = updater else {
            Log.error("SparkleUpdaterService: Cannot check for updates: updater not initialized", category: .update)
            return false
        }

        Log.info("SparkleUpdaterService: Manual update check triggered", category: .update)
        updater.checkForUpdates()
        return true
    }

    /// Checks for updates silently in the background.
    ///
    /// If an update is available, Sparkle notifies the user; it does not
    /// download until they choose Install (`automaticallyDownloadsUpdates` is
    /// off). No dialog is shown if the app is already up to date. No-op for
    /// Homebrew installs and in DEBUG builds.
    func checkForUpdatesInBackground() {
        guard !isHomebrewInstall else { return }

        #if DEBUG
        Log.debug("SparkleUpdaterService: Background check skipped: debug build", category: .update)
        #else
        guard let updater = updater else {
            Log.error("SparkleUpdaterService: Cannot check for updates: updater not initialized", category: .update)
            return
        }

        Log.debug("SparkleUpdaterService: Background update check triggered", category: .update)
        updater.checkForUpdatesInBackground()
        #endif
    }

    // MARK: - Automatic Check Policy

    /// Whether this is a DEBUG build.
    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Sparkle's live `automaticallyChecksForUpdates`, or `nil` without an
    /// updater. Read-only; exposed so tests can confirm DEBUG keeps it off.
    var sparkleAutomaticallyChecksForUpdates: Bool? {
        updater?.automaticallyChecksForUpdates
    }

    /// The value handed to Sparkle's `automaticallyChecksForUpdates` for a
    /// given user preference.
    ///
    /// DEBUG always returns `false`: background checks stay off there and only
    /// manual "Check for Updates" runs against the dev appcast. The user's
    /// choice is still persisted so it carries into a Release build.
    static func sparkleAutomaticChecks(preference: Bool, isDebug: Bool) -> Bool {
        isDebug ? false : preference
    }

    // MARK: - Feed Resolution

    /// Pure resolver for the appcast feed Sparkle should request.
    ///
    /// Extracted from `feedURLString(for:)` so the channel-vs-DEBUG decision is
    /// unit-testable without instantiating Sparkle or a real bundle.
    ///
    /// Order of precedence:
    /// 1. DEBUG builds always use the bundled dev appcast, regardless of channel.
    /// 2. Nightly channel uses the nightly feed.
    /// 3. Stable channel returns `nil` so Sparkle falls back to `SUFeedURL`.
    ///
    /// - Returns: a feed URL string, or `nil` to use `SUFeedURL` from Info.plist.
    static func resolveFeedURLString(
        channel: UpdateChannel,
        isDebug: Bool,
        nightlyURL: String,
        devAppcastURL: String?
    ) -> String? {
        if isDebug {
            return devAppcastURL
        }
        switch channel {
        case .nightly:
            return nightlyURL
        case .stable:
            return nil
        }
    }
}

// MARK: - SPUUpdaterDelegate

extension SparkleUpdaterService: SPUUpdaterDelegate {
    /// Returns the appcast feed URL for the given updater.
    ///
    /// - DEBUG: the bundled `dev-appcast.xml` so manual checks exercise the
    ///   Sparkle UI against a dummy v99.0.0 entry.
    /// - Release + Nightly channel: the nightly appcast feed.
    /// - Release + Stable channel: `nil` to use `SUFeedURL` from Info.plist.
    func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        return Self.resolveFeedURLString(
            channel: channel,
            isDebug: isDebug,
            nightlyURL: AppConstants.Update.nightlyFeedURL,
            devAppcastURL: Bundle.main.url(forResource: "dev-appcast", withExtension: "xml")?.absoluteString
        )
    }

    /// Called when Sparkle schedules its next automatic check. Logs the delay.
    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        Log.debug("SparkleUpdaterService: Next check scheduled in \(Int(delay))s", category: .update)
    }

    /// Called when an update check finds a newer version.
    ///
    /// Marks the cycle as having surfaced an update (see
    /// ``didSurfaceUpdateThisCycle``) and posts the update state with the
    /// item's info URL (empty when the appcast has none).
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Log.info("SparkleUpdaterService: Update found", category: .update, fields: ["version": version])

        didSurfaceUpdateThisCycle = true
        NotificationCenter.default.postUpdateState(
            isUpdateAvailable: true,
            latestVersion: version,
            releaseURL: item.infoURL?.absoluteString ?? ""
        )
    }

    /// Called when an update check completes without finding a newer version.
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Log.info("SparkleUpdaterService: No update available: app is up to date", category: .update)

        NotificationCenter.default.postUpdateState(
            isUpdateAvailable: false,
            latestVersion: AppConstants.AppInfo.shortVersion
        )
    }

    /// Called when an update check cycle finishes, successfully or not.
    ///
    /// A failed check (offline, DNS failure, malformed feed) never reaches
    /// `didFindValidUpdate` or `updaterDidNotFindUpdate`, so without this hook
    /// no `updateStateChanged` fires and the settings pane's Check Now spinner
    /// sticks forever. Mirrors `updaterDidNotFindUpdate`'s payload so the UI
    /// resets to the current version.
    ///
    /// The reset is skipped when this cycle already surfaced an update:
    /// Sparkle also finishes the cycle with an error after a failed download,
    /// and wiping the state then would hide the update the user just saw.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        let surfacedUpdate = didSurfaceUpdateThisCycle
        didSurfaceUpdateThisCycle = false
        guard let error else { return }
        Log.info(
            "SparkleUpdaterService: Update check finished with error",
            category: .update,
            fields: ["error": error.localizedDescription])

        guard !surfacedUpdate else { return }
        NotificationCenter.default.postUpdateState(
            isUpdateAvailable: false,
            latestVersion: AppConstants.AppInfo.shortVersion
        )
    }

    /// Called when a found update fails to download (network error, bad payload, etc.)
    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        Log.error(
            "SparkleUpdaterService: Failed to download update",
            category: .update,
            fields: ["error": error.localizedDescription])
    }

    /// Called when an update is about to be installed.
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Log.info("SparkleUpdaterService: Installing update", category: .update, fields: ["version": version])
    }

    /// Determines whether Sparkle should postpone the relaunch for an update
    /// that's ready to install.
    ///
    /// Always returns `false`: the relaunch proceeds immediately and
    /// `installHandler` is never retained.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        return false
    }

    /// Called after an update has been successfully installed and the app is about to relaunch.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        Log.info("SparkleUpdaterService: Update installed successfully: relaunching app", category: .update)
    }

    /// Allows customization of update permission prompts.
    ///
    /// Returns `false`. `SUEnableAutomaticChecks` (`true`) in Info.plist
    /// provides the answer, and onboarding handles user consent explicitly.
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        return false
    }

    /// Disables Sparkle's system-profile telemetry beam.
    ///
    /// Sparkle can attach OS version, CPU arch, and bundle metadata to the
    /// appcast request as query parameters. Returning an empty array opts out
    /// entirely so no environmental data leaves the user's machine on update
    /// checks. The release pipeline already publishes a static appcast, so the
    /// telemetry would only inform analytics, not update targeting.
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? {
        return []
    }

    /// Called when the user makes a choice (skip / install / dismiss) about a found update.
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        switch choice {
        case .skip:
            Log.info(
                "SparkleUpdaterService: User skipped update",
                category: .update,
                fields: ["version": updateItem.displayVersionString])
        case .install:
            Log.info(
                "SparkleUpdaterService: User chose to install update",
                category: .update,
                fields: ["version": updateItem.displayVersionString])
        case .dismiss:
            Log.info("SparkleUpdaterService: User dismissed update dialog", category: .update)
        @unknown default:
            break
        }
    }
}
