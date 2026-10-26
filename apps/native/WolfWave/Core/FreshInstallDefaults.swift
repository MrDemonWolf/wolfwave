//
//  FreshInstallDefaults.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-26.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Day-one settings for a brand-new install, written once as explicit values.
///
/// A new default can't just change what an unset key reads as: every existing
/// install that never touched that switch would flip on the next update (for
/// example `!song` suddenly replying in someone's chat). So the unset reading
/// stays where it was (`AppConstants.UserDefaults.Defaults`), and this writes
/// explicit values instead, one time per install:
///
/// - **Fresh install**: each key in ``values`` that is still unset gets its
///   new day-one value.
/// - **Existing install** (onboarding already finished, or a Twitch channel
///   already saved): each still-unset key is pinned to the value it already
///   read as, so nothing changes for that user.
///
/// Keys the user already set are never touched. The applied version is stored
/// in `freshInstallDefaultsVersion`, so the pass runs once. A factory reset
/// wipes that marker along with everything else, and the next launch is a
/// fresh install again.
nonisolated enum FreshInstallDefaults {

    // MARK: - Values

    /// One setting whose day-one value differs from its unset reading.
    struct Entry: Equatable, Sendable {
        /// The `UserDefaults` key.
        let key: String
        /// What a fresh install gets.
        let freshValue: Bool
        /// What the key read as before this existed; pinned on existing installs.
        let legacyValue: Bool
    }

    /// Bump when ``values`` gains an entry, so existing installs run the pass
    /// again for the new key only (keys already set are skipped).
    static let version = 1

    /// Every setting a fresh install gets differently from an upgrade.
    static let values: [Entry] = [
        // A streamer who connects Twitch expects the bot to answer !song.
        Entry(
            key: AppConstants.UserDefaults.currentSongCommandEnabled,
            freshValue: true,
            legacyValue: AppConstants.UserDefaults.Defaults.currentSongCommandEnabled
        ),
        Entry(
            key: AppConstants.UserDefaults.lastSongCommandEnabled,
            freshValue: true,
            legacyValue: AppConstants.UserDefaults.Defaults.lastSongCommandEnabled
        )
    ]

    // MARK: - Apply

    /// Applies the day-one values once. Call at launch before any service
    /// reads these keys. Idempotent: a second call is a no-op.
    ///
    /// - Parameter defaults: The store to write. Production passes
    ///   `DefaultsStore.store`; tests pass a throwaway suite.
    static func apply(to defaults: UserDefaults = DefaultsStore.store) {
        let applied = defaults.integer(forKey: AppConstants.UserDefaults.freshInstallDefaultsVersion)
        guard applied < version else { return }

        let existing = isExistingInstall(defaults)
        for entry in values where defaults.object(forKey: entry.key) == nil {
            defaults.set(existing ? entry.legacyValue : entry.freshValue, forKey: entry.key)
        }
        defaults.set(version, forKey: AppConstants.UserDefaults.freshInstallDefaultsVersion)
        let kind = existing ? "kept existing install's settings" : "fresh install"
        Log.info("FreshInstallDefaults: applied v\(version) (\(kind))", category: .app)
    }

    /// Whether this store belongs to an install that predates the pass:
    /// onboarding finished, or a Twitch channel already saved.
    static func isExistingInstall(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: AppConstants.UserDefaults.hasCompletedOnboarding)
            || !(defaults.string(forKey: AppConstants.UserDefaults.twitchChannelName) ?? "").isEmpty
    }
}
