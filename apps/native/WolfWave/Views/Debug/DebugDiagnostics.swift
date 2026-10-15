//
//  DebugDiagnostics.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-26.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

#if DEBUG
import Foundation

/// DEBUG-only diagnostics snapshot + markdown formatter for the "Copy Diagnostics"
/// button in the Debug tab. Pure value type, no UI, no pasteboard: the caller
/// (`DebugSettingsView.copyDiagnostics()`) gathers the values and copies the result.
///
/// Covers similar ground to the `DiagnosticSnapshot` environment block used by
/// `BugReportURL` and the Advanced pane export, but it is a separate type with
/// its own fields (live connection state, preference toggles), so the two can
/// differ.
enum DebugDiagnostics {

    // MARK: - Snapshot

    /// Snapshot of app state at the moment "Copy Diagnostics" is clicked.
    ///
    /// Preferences and connections are deliberately separate. They used to be
    /// one "Service State" table fed from `@AppStorage` toggles plus a
    /// Keychain-token presence check, which meant a pasted issue could report
    /// "Discord | Yes" for someone whose RPC socket never connected, and
    /// "Twitch | Yes" purely because a stale token sat in the Keychain. A
    /// diagnostics blob that quietly reports intent as if it were fact sends
    /// debugging down the wrong path, which is the opposite of its job.
    struct Snapshot: Equatable {
        // Environment
        let appVersion: String
        let build: String
        let osVersion: String
        let arch: String
        /// Human label, "Homebrew" or "DMG".
        let installMethod: String
        /// Current log file size in bytes; formatted with `ByteFormatting` on output.
        let logSizeBytes: Int64
        let logLineCount: Int

        /// What the user asked for (`@AppStorage` toggles).
        let musicTrackingEnabled: Bool
        let discordPresenceEnabled: Bool
        let widgetHTTPEnabled: Bool

        /// What is actually true right now (live service state).
        let twitchConnected: Bool
        /// Raw value of `DiscordRPCService.ConnectionState` (for example "connected").
        let discordConnection: String
        /// Whether a Twitch access token is in the Keychain. Presence only: a stored
        /// token can still be expired or revoked, which is why it is listed next to
        /// `twitchConnected` instead of standing in for it.
        let twitchTokenStored: Bool
    }

    // MARK: - Formatting

    /// Returns a markdown blob suitable for pasting into a GitHub issue.
    ///
    /// Three tables: Environment, Connections (live state), and Preferences
    /// (what the user turned on). Keep Connections and Preferences apart; see
    /// `Snapshot` for why.
    ///
    /// - Parameter snapshot: Values captured at click time.
    /// - Returns: GitHub-flavored markdown.
    static func markdown(_ snapshot: Snapshot) -> String {
        let size = ByteFormatting.string(snapshot.logSizeBytes)
        return """
        ## Environment

        | Field | Value |
        |---|---|
        | App version | \(snapshot.appVersion) (build \(snapshot.build)) |
        | macOS | \(snapshot.osVersion) |
        | Architecture | \(snapshot.arch) |
        | Install method | \(snapshot.installMethod) |
        | Log file size | \(size) |
        | Log line count | \(snapshot.logLineCount) |

        ## Connections

        Live state, not settings.

        | Service | State |
        |---|---|
        | Twitch chat | \(snapshot.twitchConnected ? "connected" : "not connected") |
        | Discord RPC | \(snapshot.discordConnection) |
        | Twitch token in Keychain | \(yesNo(snapshot.twitchTokenStored)) |

        ## Preferences

        What the user turned on, which is not the same as whether it works.

        | Setting | Enabled |
        |---|---|
        | Music tracking | \(yesNo(snapshot.musicTrackingEnabled)) |
        | Discord presence | \(yesNo(snapshot.discordPresenceEnabled)) |
        | Widget HTTP server | \(yesNo(snapshot.widgetHTTPEnabled)) |
        """
    }

    /// "Yes" / "No" for table cells.
    private static func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }
}
#endif
