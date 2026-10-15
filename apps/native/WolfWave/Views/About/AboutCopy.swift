//
//  AboutCopy.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-28.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import Foundation

/// Shared identity, version, and legal copy used by every surface that shows
/// "About". The system standard About panel (opened from the menu bar) and
/// the rich `AboutSettingsView` (Settings sidebar tab). Keeps both entry
/// points in sync so trademark + copyright strings don't drift.
enum AboutCopy {

    // MARK: - Bundle Info

    /// Display name from the bundle (`CFBundleDisplayName`, then `CFBundleName`),
    /// falling back to the constant. Resolves to "WolfWave Dev" in Debug builds.
    static var appName: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleName"] as? String
            ?? AppConstants.AppInfo.displayName
    }

    /// Marketing version (`CFBundleShortVersionString`).
    static var version: String { AppConstants.AppInfo.shortVersion }

    /// Build number (`CFBundleVersion`). CI stamps this from `scripts/version.sh`.
    static var build: String { AppConstants.AppInfo.buildNumber }

    /// User-facing version label, e.g. `Version 1.2.3 (45)`.
    static var versionString: String {
        "Version \(version) (\(build))"
    }

    /// Clipboard payload for the version pill in `AboutSettingsView`.
    static var versionClipboardPayload: String {
        "\(appName) \(version) (build \(build))"
    }

    // MARK: - Legal Copy

    /// Non-affiliation statement shown in the About pane footer.
    static let independenceNotice =
        "WolfWave is an independent, open-source project. It is not affiliated with, endorsed by, or sponsored by Apple, Twitch, Discord, or Odesli. WolfWave connects to Twitch and Discord via their official public APIs, and reads Apple Music playback locally on your Mac via macOS ScriptingBridge. No listening history is collected or sent to any external service."

    /// Third-party trademark attributions. Shown in the About pane footer and
    /// as the credits of the standard About panel. Add a line here whenever a
    /// new brand is named in the UI.
    static let trademarkNotice =
        "Apple Music and iTunes are trademarks of Apple Inc. Twitch is a trademark of Twitch Interactive, Inc. Discord is a trademark of Discord Inc. song.link is a trademark of Song, Inc. (Odesli). Spotify is a trademark of Spotify AB. YouTube is a trademark of Google LLC. Elgato and Stream Deck are trademarks of Corsair Memory, Inc. OBS is a trademark of OBS Project."

    /// Copyright line for the About pane. The year comes from the bundle's
    /// `NSHumanReadableCopyright` (the line the standard panel shows), so the
    /// two can't drift; the holder stays `copyrightHolder`, so a fork's
    /// `COPYRIGHT_HOLDER` override still applies here.
    static var copyrightLine: String {
        copyrightLine(
            bundleCopyright: Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String,
            holder: AppConstants.AppInfo.copyrightHolder
        )
    }

    /// Testable builder for `copyrightLine`.
    ///
    /// - Parameters:
    ///   - bundleCopyright: The raw `NSHumanReadableCopyright` value, if any.
    ///   - holder: Legal entity named in the line.
    ///   - fallbackYear: Used when `bundleCopyright` holds no four-digit year.
    static func copyrightLine(
        bundleCopyright: String?,
        holder: String,
        fallbackYear: Int = Calendar.current.component(.year, from: Date())
    ) -> String {
        let year = bundleCopyright.flatMap(copyrightYear(in:)) ?? String(fallbackYear)
        return "© \(year) \(holder) All rights reserved."
    }

    /// The year (or year range, e.g. `2025-2026`) in a copyright string, or
    /// `nil` when it has none.
    static func copyrightYear(in copyright: String) -> String? {
        guard let match = copyright.firstMatch(of: /\d{4}(?:\s*[-–]\s*\d{4})?/) else { return nil }
        return String(match.output)
    }

    // MARK: - Standard About Panel

    /// Options dictionary for `NSApplication.orderFrontStandardAboutPanel(options:)`.
    /// Supplies a centered trademark notice as credits; the copyright line comes
    /// from `Info.plist`'s `NSHumanReadableCopyright`, which the panel renders
    /// automatically alongside the icon, name, and version.
    static func standardAboutPanelOptions() -> [NSApplication.AboutPanelOptionKey: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let credits = NSAttributedString(
            string: trademarkNotice,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]
        )

        return [
            .credits: credits,
            .applicationVersion: version,
            .version: build
        ]
    }
}
