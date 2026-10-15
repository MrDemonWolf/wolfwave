//
//  Preferences.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-28.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Typed accessors for the non-boolean preference values persisted in
/// `UserDefaults` (strings, ints, and "may not be set yet" objects).
///
/// Sibling to ``FeatureFlags`` (which covers booleans). Centralizes the
/// repeated `string(forKey:)` / `integer(forKey:)` pattern so default semantics and
/// fallbacks live in one place. Adding a new pref means one property here
/// rather than hunting for the matching read/write across `AppDelegate+*`,
/// `WolfWaveApp`, and the settings views.
///
/// Conventions:
/// - Read-only computed properties expose the current value with the right
///   default.
/// - Mutating writes are exposed as plain `static func set…(…)` so call sites
///   are searchable and intent is explicit.
/// - Every read and write goes through ``DefaultsStore/store`` (never
///   `UserDefaults.standard`), so tests hit their isolated suite.
nonisolated enum Preferences {

    /// The one `UserDefaults` every accessor reads and writes.
    private static var defaults: Foundation.UserDefaults { DefaultsStore.store }

    // MARK: - Defaulted Primitive Reads

    /// Reads an integer preference, substituting `defaultValue` when the key is
    /// unset or stored as a non-positive sentinel (`0`).
    ///
    /// Centralizes the `let stored = …integer(forKey:); stored > 0 ? stored : default`
    /// idiom that was duplicated across the queue, vote, and request services.
    static func int(_ key: String, default defaultValue: Int) -> Int {
        let stored = defaults.integer(forKey: key)
        return stored > 0 ? stored : defaultValue
    }

    /// Reads a boolean preference, substituting `defaultValue` when the key has
    /// never been written.
    ///
    /// Distinct from `defaults.bool(forKey:)`, which collapses "unset" to
    /// `false`. Use this when the default is `true` or when "unset" must be
    /// distinguished from an explicit `false`.
    static func bool(_ key: String, default defaultValue: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    /// Reads a double preference, substituting `defaultValue` when the key has
    /// never been written.
    static func double(_ key: String, default defaultValue: Double) -> Double {
        defaults.object(forKey: key) as? Double ?? defaultValue
    }

    // MARK: - Twitch

    /// Backup-restored channel waiting for a successful OAuth grant. This value
    /// is presentation/input state only; connection code reads canonical
    /// Keychain credentials instead.
    static var pendingImportedTwitchChannelName: String {
        defaults.string(
            forKey: AppConstants.UserDefaults.twitchPendingImportedChannelName
        ) ?? ""
    }

    /// Drops the pending backup-restored channel, typically once OAuth has
    /// committed a real channel to the Keychain grant.
    static func clearPendingImportedTwitchChannelName() {
        defaults.removeObject(
            forKey: AppConstants.UserDefaults.twitchPendingImportedChannelName
        )
    }

    /// Public song-list URL echoed by the `!playlist` command (plus any
    /// user-configured aliases; see `SongListCommand`). Whitespace-trimmed;
    /// empty when the streamer hasn't shared one.
    static var songRequestSongListURL: String {
        normalizedHTTPSURL(defaults.string(forKey: AppConstants.UserDefaults.songRequestSongListURL) ?? "") ?? ""
    }

    /// Empty clears an optional link; configured links must be bounded HTTPS URLs.
    ///
    /// - Parameters:
    ///   - value: Raw user input or stored value. Trimmed of whitespace.
    ///   - maxLength: Upper bound in characters, checked before trimming.
    /// - Returns: `""` for blank input, the normalized absolute string for a
    ///   valid `https` URL with a host, or `nil` when the value is too long,
    ///   not `https`, or has no host.
    static func normalizedHTTPSURL(_ value: String, maxLength: Int = 2_048) -> String? {
        guard value.count <= maxLength else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url.absoluteString
    }

    /// Whether the most recent EventSub connection failed in a way that
    /// requires the user to re-authorize Twitch.
    static var twitchReauthNeeded: Bool {
        defaults.bool(forKey: AppConstants.UserDefaults.twitchReauthNeeded)
    }

    /// Persists the re-auth flag. Callers that need observers to react also
    /// post `.twitchReauthNeededChanged`; this setter does not.
    static func setTwitchReauthNeeded(_ value: Bool) {
        defaults.set(value, forKey: AppConstants.UserDefaults.twitchReauthNeeded)
    }

    // MARK: - WebSocket / Widget

    /// Port the embedded WebSocket server should listen on. `0` means "use the
    /// default": callers substitute `AppConstants.WebSocketServer.defaultPort`.
    static var websocketServerPort: Int {
        defaults.integer(forKey: AppConstants.UserDefaults.websocketServerPort)
    }

    /// Port the embedded widget HTTP server should listen on. `0` means "use
    /// the default": callers substitute `AppConstants.WebSocketServer.widgetDefaultPort`.
    static var widgetPort: Int {
        defaults.integer(forKey: AppConstants.UserDefaults.widgetPort)
    }

    /// The effective WebSocket server port as a `UInt16`, ready to bind.
    ///
    /// Resolves ``websocketServerPort``: unset/zero falls back to
    /// `AppConstants.WebSocketServer.defaultPort`, and any out-of-range stored
    /// value (a hand-edited plist or corrupted backup) is clamped instead of
    /// trapping. The single source of truth for this conversion; do not
    /// re-derive it at call sites.
    static var resolvedWebSocketServerPort: UInt16 {
        resolvePort(websocketServerPort, default: AppConstants.WebSocketServer.defaultPort)
    }

    /// The effective widget HTTP server port as a `UInt16`, ready to bind.
    ///
    /// Resolves ``widgetPort`` with the same semantics as
    /// ``resolvedWebSocketServerPort``, falling back to
    /// `AppConstants.WebSocketServer.widgetDefaultPort`.
    static var resolvedWidgetPort: UInt16 {
        resolvePort(widgetPort, default: AppConstants.WebSocketServer.widgetDefaultPort)
    }

    /// Shared port resolution: non-positive means "use the default"; anything
    /// else is clamped into `UInt16` range so a bad stored value can never trap.
    static func resolvePort(_ stored: Int, default defaultPort: UInt16) -> UInt16 {
        stored > 0 ? UInt16(clamping: stored) : defaultPort
    }

    // MARK: - Domain-Resolved Reads

    /// `stored` when it is one of `allowed`, otherwise `defaultValue`.
    ///
    /// Pure, so the UI layer can share it. See ``resolvedInt(_:default:)`` for
    /// why an out-of-domain value has to be caught before it reaches a control.
    static func resolveAllowed(_ stored: Int, allowed: Set<Int>, default defaultValue: Int) -> Int {
        allowed.contains(stored) ? stored : defaultValue
    }

    /// `stored` clamped into `range`; non-finite falls back to `defaultValue`.
    ///
    /// The `isFinite` check is the load-bearing half. `Int(Double.nan)` and
    /// `Int(1e300)` both trap, and a `Double` read out of `UserDefaults` is
    /// attacker-shaped in the sense that anything can put it there.
    static func resolveClamped(
        _ stored: Double,
        range: ClosedRange<Double>,
        default defaultValue: Double
    ) -> Double {
        stored.isFinite ? min(max(stored, range.lowerBound), range.upperBound) : defaultValue
    }

    /// Reads an integer preference validated against the domain declared for
    /// `key` in `AppConstants.UserDefaults.exportablePreferences`.
    ///
    /// Import validation already rejects out-of-domain values, but nothing
    /// guards a value that arrives another way: a hand-edited plist,
    /// `defaults write`, a key written by an older build, or a test process
    /// sharing the app's domain. Such a value reaching a SwiftUI `Picker` as its
    /// selection is not a cosmetic problem. The segmented style traps inside
    /// SwiftUI ("Double value cannot be converted to Int"), taking the whole
    /// settings window with it, after logging only
    /// `Picker: the selection "1" is invalid and does not have an associated tag`.
    ///
    /// Keys without a declared domain keep ``int(_:default:)`` semantics.
    static func resolvedInt(_ key: String, default defaultValue: Int) -> Int {
        guard case .int(let domain)? = AppConstants.UserDefaults.exportRule(for: key) else {
            return int(key, default: defaultValue)
        }
        // `integer(forKey:)` bridges a stored huge Double or string through
        // `NSNumber` without trapping, so the domain check below is what
        // actually rejects it.
        let stored = defaults.integer(forKey: key)
        switch domain {
        case .values(let allowed):
            return resolveAllowed(stored, allowed: allowed, default: defaultValue)
        case .zeroOrRange(let range):
            return stored == 0
                ? defaultValue
                : min(max(stored, range.lowerBound), range.upperBound)
        }
    }

    /// The `Double` sibling of ``resolvedInt(_:default:)``.
    ///
    /// NaN and infinity resolve to `defaultValue`; a finite value clamps into
    /// the declared range. Step is deliberately not enforced: import validation
    /// owns step, and clamping alone is what makes a downstream `Int(…)` total.
    static func resolvedDouble(_ key: String, default defaultValue: Double) -> Double {
        let stored = double(key, default: defaultValue)
        guard case .double(let domain)? = AppConstants.UserDefaults.exportRule(for: key) else {
            return stored.isFinite ? stored : defaultValue
        }
        return resolveClamped(stored, range: domain.range, default: defaultValue)
    }

    /// Writes the shared WebSocket server switch read by ``FeatureFlags/websocketEnabled``.
    /// Does not start or stop the server; callers post the change notification.
    static func setWebSocketEnabled(_ value: Bool) {
        defaults.set(value, forKey: AppConstants.UserDefaults.websocketEnabled)
    }

    /// Writes the widget HTTP server switch read by ``FeatureFlags/widgetHTTPEnabled``.
    /// Does not start or stop the server.
    static func setWidgetHTTPEnabled(_ value: Bool) {
        defaults.set(value, forKey: AppConstants.UserDefaults.widgetHTTPEnabled)
    }

    // MARK: - Settings / UI

    /// Dock visibility mode persisted by the App Visibility setting (raw value).
    static var dockVisibility: String? {
        defaults.string(forKey: AppConstants.UserDefaults.dockVisibility)
    }

    // MARK: - Onboarding / What's New

    /// Whether the first-launch wizard finished (completed or skipped). Default `false`.
    static var hasCompletedOnboarding: Bool {
        defaults.bool(forKey: AppConstants.UserDefaults.hasCompletedOnboarding)
    }

    /// The What's New feature version (`AppConstants.AppInfo.whatsNewVersion`)
    /// last shown; empty before the first one. Compared at launch by `checkWhatsNew()`.
    static var lastSeenWhatsNewVersion: String {
        defaults.string(forKey: AppConstants.UserDefaults.lastSeenWhatsNewVersion) ?? ""
    }

    /// Records that What's New for `version` has been shown.
    static func setLastSeenWhatsNewVersion(_ version: String) {
        defaults.set(version, forKey: AppConstants.UserDefaults.lastSeenWhatsNewVersion)
    }

    // MARK: - Tracking First-Launch Default

    /// First-launch default for music tracking: writes `true` when the key has
    /// never been written, so later plain `bool(forKey:)` reads (the tray
    /// toggle) see `true` rather than "unset = false".
    ///
    /// - Returns: `true` only on the call that seeded the value; `false` once
    ///   any value (including an explicit `false`) is stored.
    @discardableResult
    static func seedTrackingEnabledDefaultIfNeeded() -> Bool {
        let key = AppConstants.UserDefaults.trackingEnabled
        if defaults.object(forKey: key) == nil {
            defaults.set(true, forKey: key)
            return true
        }
        return false
    }
}
