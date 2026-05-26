//
//  DebugDiagnostics.swift
//  wolfwave
//
//  Created by MrDemonWolf, Inc. on 5/25/26.
//

#if DEBUG
import Foundation

/// DEBUG-only diagnostics snapshot + markdown formatter for the "Copy Diagnostics"
/// button in the Debug tab. Pure value type — no UI, no pasteboard. Mirrors the
/// environment block built by `BugReportURL.make(…)` but routes to the pasteboard
/// for quick pasting into a GitHub issue.
enum DebugDiagnostics {

    /// Snapshot of app + service state at the moment "Copy Diagnostics" is clicked.
    struct Snapshot: Equatable {
        let appVersion: String
        let build: String
        let osVersion: String
        let arch: String
        let installMethod: String
        let logSizeBytes: Int64
        let logLineCount: Int
        let twitchConnected: Bool
        let discordConnected: Bool
        let widgetEnabled: Bool
        let musicTrackingEnabled: Bool
    }

    /// Returns a markdown blob suitable for pasting into a GitHub issue.
    static func markdown(_ s: Snapshot) -> String {
        let size = ByteCountFormatter.string(fromByteCount: s.logSizeBytes, countStyle: .file)
        return """
        ## Environment

        | Field | Value |
        |---|---|
        | App version | \(s.appVersion) (build \(s.build)) |
        | macOS | \(s.osVersion) |
        | Architecture | \(s.arch) |
        | Install method | \(s.installMethod) |
        | Log file size | \(size) |
        | Log line count | \(s.logLineCount) |

        ## Service State

        | Service | State |
        |---|---|
        | Twitch | \(yesNo(s.twitchConnected)) |
        | Discord | \(yesNo(s.discordConnected)) |
        | Widget HTTP | \(yesNo(s.widgetEnabled)) |
        | Music tracking | \(yesNo(s.musicTrackingEnabled)) |
        """
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }
}
#endif
