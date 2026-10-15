//
//  DiagnosticsBundle.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-08-14.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Composes everything a person debugging this install would need into one file.
///
/// "Export Logs" used to be a bare `copyItem` of `wolfwave.log`. Two problems
/// fell out of that. The exported file carried no version, OS, or install
/// method, so it could not be attributed to a build. And it silently excluded
/// the rotated backups, so if rotation had just fired the user exported a nearly
/// empty file while the lines describing their bug sat in `wolfwave.log.1`.
///
/// Now the export is: environment header, the crash breadcrumb if the last
/// launch died, then every rotated log oldest-first followed by the live one.
nonisolated enum DiagnosticsBundle {

    /// Separator between sections. Distinctive enough to find by eye or by grep,
    /// and it can never collide with a log line, which always starts with a
    /// digit.
    private static let rule = String(repeating: "=", count: 72)

    /// Builds the full bundle text.
    ///
    /// - Parameters:
    ///   - snapshot: Environment block for the header.
    ///   - crash: Crash breadcrumb from the last launch, if any. Normally read
    ///     at launch and cleared, so callers pass what they stored.
    ///   - logs: Log files, oldest first. See ``logFilesOldestFirst()``.
    /// - Returns: The composed file contents. A log that cannot be read as
    ///   UTF-8 appears as `(unreadable)` rather than failing the whole export.
    static func compose(
        snapshot: DiagnosticSnapshot,
        crash: String?,
        logs: [URL]
    ) -> String {
        var parts: [String] = [
            section("ENVIRONMENT", snapshot.exportHeader)
        ]

        if let crash, !crash.isEmpty {
            parts.append(section("LAST CRASH", crash))
        }

        if logs.isEmpty {
            parts.append(section("LOG", "(no log file)"))
        } else {
            for url in logs {
                let body = (try? String(contentsOf: url, encoding: .utf8)) ?? "(unreadable)"
                parts.append(section("LOG \(url.lastPathComponent)", body))
            }
        }

        return parts.joined(separator: "\n\n")
    }

    /// Every log file that exists, oldest first, so the composed file reads in
    /// chronological order: rotated backups from the deepest
    /// (`wolfwave.log.N`) down to `.1`, then the live `wolfwave.log`.
    ///
    /// Synchronous: both calls hop onto `Log`'s serial file queue, and the live
    /// file is flushed to disk before its URL is returned.
    static func logFilesOldestFirst() -> [URL] {
        var files = Log.rotatedLogFiles()
        if let live = Log.exportLogFile() { files.append(live) }
        return files
    }

    /// Default filename for the save panel, stamped so successive exports do not
    /// silently overwrite each other.
    static func suggestedFilename(date: Date) -> String {
        "wolfwave-diagnostics-\(SharedFormatters.exportStamp.string(from: date)).log"
    }

    /// Wraps one section in the ``rule`` banner: rule, title, rule, then the body.
    private static func section(_ title: String, _ body: String) -> String {
        "\(rule)\n\(title)\n\(rule)\n\(body)"
    }
}
