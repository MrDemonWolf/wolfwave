//
//  AdvancedSettingsView+LogActions.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Log and artwork-cache actions for the Advanced pane: export, reveal, copy,
/// and clear the log, plus the artwork cache stats.
extension AdvancedSettingsView {

    // MARK: - Log Actions

    /// Returns the current log file URL, or `nil` after logging a warning whose
    /// suffix is `reason` (e.g. "for export", "to reveal", "to copy"). The
    /// `nil` path also raises the "No logs yet." alert, so callers just return.
    private func requireLogFile(orWarn reason: String) -> URL? {
        guard let logURL = Log.exportLogFile() else {
            Log.warn("No log file available \(reason)", category: .app)
            exportErrorMessage = "No logs yet."
            showingExportError = true
            return nil
        }
        return logURL
    }

    /// Opens a save panel to export the diagnostics bundle: the environment
    /// header, the last crash summary, and every rotated log, oldest first
    /// (see `DiagnosticsBundle`). The live log file only gates availability.
    ///
    /// Presents the panel as a sheet on the settings window when available,
    /// falling back to a modal run loop. Previously used `panel.begin` with
    /// no host window, which crashed when the menu bar was the only frontmost
    /// UI (no key window).
    @MainActor
    func exportLogs() {
        guard let logURL = requireLogFile(orWarn: "for export") else { return }

        _ = logURL // presence already validated above

        let panel = NSSavePanel()
        panel.nameFieldStringValue = DiagnosticsBundle.suggestedFilename(date: Date())
        let logType = UTType(filenameExtension: "log") ?? .plainText
        panel.allowedContentTypes = [logType, .plainText]
        panel.canCreateDirectories = true

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            // Composition reads every rotated log, so it happens off the main
            // actor. A bare copyItem used to ship only the live file, which is
            // nearly empty right after a rotation.
            Task {
                // Capture on the main actor (it reads Bundle + defaults), then
                // do the file reading and joining off it.
                let snapshot = DiagnosticSnapshot.capture(logSizeBytes: Log.logFileSize())
                let crash = DefaultsStore.store.string(
                    forKey: AppConstants.UserDefaults.lastCrashSummary)

                let text = await Task.detached(priority: .userInitiated) {
                    DiagnosticsBundle.compose(
                        snapshot: snapshot,
                        crash: crash,
                        logs: DiagnosticsBundle.logFilesOldestFirst()
                    )
                }.value

                do {
                    try Data(text.utf8).write(to: destination, options: .atomic)
                    Log.info(
                        "Diagnostics exported",
                        category: .app,
                        fields: ["file": destination.lastPathComponent, "bytes": text.utf8.count])
                    refreshLogStats()
                } catch {
                    exportErrorMessage = "Couldn't export logs. \(error.localizedDescription)"
                    showingExportError = true
                    Log.error(
                        "Failed to export diagnostics",
                        category: .app,
                        fields: ["error": error.localizedDescription])
                }
            }
        }

        if let window = hostWindow() {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            let response = panel.runModal()
            completion(response)
        }
    }

    /// Reveals the current log file in Finder.
    func revealLogsInFinder() {
        guard let logURL = requireLogFile(orWarn: "to reveal") else { return }
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    /// Copies the tail of the live log file, prefixed with the environment
    /// header, to the system clipboard and flashes "Copied" for two seconds.
    ///
    /// Limited to the last 64 K characters (not bytes; the cut is on
    /// `Character` count) to avoid pasteboard overload. Rotated logs are not
    /// included; use Export for those.
    func copyLogsToClipboard() {
        guard let logURL = requireLogFile(orWarn: "to copy") else { return }

        do {
            let contents = try String(contentsOf: logURL, encoding: .utf8)
            let maxChars = 64 * 1024
            let trimmed: String
            if contents.count > maxChars {
                let startIndex = contents.index(contents.endIndex, offsetBy: -maxChars)
                trimmed = "… (truncated to last 64KB)\n" + String(contents[startIndex...])
            } else {
                trimmed = contents
            }

            // Prepend the environment block. A pasted log tail with no version
            // or OS cannot be attributed to a build, which is most of what makes
            // it useful in an issue.
            let header = DiagnosticSnapshot.capture(logSizeBytes: Int64(contents.utf8.count))
                .exportHeader
            Pasteboard.copy("\(header)\n\n\(trimmed)")

            withAnimation(reduceMotion ? nil : .default) { showingCopyFeedback = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                withAnimation(reduceMotion ? nil : .default) { showingCopyFeedback = false }
            }
            Log.info("Logs copied to clipboard", category: .app)
        } catch {
            Log.error("Failed to copy logs: \(error.localizedDescription)", category: .app)
            exportErrorMessage = "Couldn't copy logs. \(error.localizedDescription)"
            showingExportError = true
        }
    }

    /// Clears the current log file (truncates in place and writes a fresh
    /// header line). Rotated logs are left alone.
    func clearLogs() {
        Log.clearLogFile()
        Log.info("Logs cleared by user", category: .app)
        refreshLogStats()
    }

    /// Refreshes the displayed log size + line count from the Log singleton.
    ///
    /// The read is offloaded to a detached task: `logLineCount()` drains queued
    /// writes then streams the whole log file (up to the 5 MB rotation cap)
    /// through `fileQueue.sync`, which would stall first paint on a big log if
    /// run on the main thread. State is assigned back on the MainActor. Mirrors
    /// `DebugLogsAndEventsCard`.
    func refreshLogStats() {
        Task { @MainActor in
            let stats = await Task.detached(priority: .userInitiated) {
                (bytes: Log.logFileSize(), lines: Log.logLineCount())
            }.value

            logSizeText = ByteFormatting.string(stats.bytes)

            let numberFormatter = NumberFormatter()
            numberFormatter.numberStyle = .decimal
            let formattedLines = numberFormatter.string(from: NSNumber(value: stats.lines)) ?? String(stats.lines)
            logLineCountText = "\(formattedLines) lines"
        }
    }

    /// Clears the persisted artwork links cache (memory + disk).
    func clearArtworkCache() async {
        await ArtworkService.shared.clearCache()
        Log.info("Artwork cache cleared by user", category: .app)
        refreshArtworkStats()
    }

    /// Refreshes the displayed artwork cache entry count + disk size.
    /// Synchronous; `cacheStats()` is cheap enough to read on the main actor.
    func refreshArtworkStats() {
        let stats = ArtworkService.shared.cacheStats()
        let size = ByteFormatting.string(stats.diskBytes)
        let trackWord = stats.entryCount == 1 ? "track" : "tracks"
        artworkStatsText = "\(stats.entryCount) \(trackWord) · \(size)"
    }

    /// Returns the host window for sheet presentation, or nil if none is visible.
    /// Prefers the key window, then any visible window that isn't a status-bar
    /// window. Callers fall back to `runModal()` on `nil`.
    @MainActor
    func hostWindow() -> NSWindow? {
        if let key = NSApp.keyWindow { return key }
        return NSApp.windows.first { $0.isVisible && !$0.className.contains("NSStatusBar") }
    }
}
