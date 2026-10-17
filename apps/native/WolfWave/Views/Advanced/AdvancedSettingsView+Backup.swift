//
//  AdvancedSettingsView+Backup.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings backup export and import actions for the Advanced pane.
extension AdvancedSettingsView {

    // MARK: - Backup Actions

    /// Exports portable settings to a user-chosen JSON file. Accounts and
    /// secrets are excluded. See `AppConstants.UserDefaults.exportableKeys`.
    /// Build or write failures surface the export error alert.
    @MainActor
    func exportSettings() {
        let service = SettingsBackupService()
        let data: Data
        do {
            data = try service.makeBackupData()
        } catch {
            Log.error("Failed to build settings backup: \(error.localizedDescription)", category: .app)
            exportErrorMessage = "Couldn't save your backup. \(error.localizedDescription)"
            showingExportError = true
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "wolfwave-settings-\(Self.fileDateStamp()).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                Log.info("Settings exported to \(url.lastPathComponent)", category: .app)
            } catch {
                Log.error("Failed to write settings backup: \(error.localizedDescription)", category: .app)
                exportErrorMessage = "Couldn't save your backup. \(error.localizedDescription)"
                showingExportError = true
            }
        }

        if let window = hostWindow() {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    /// Presents an open panel to pick a backup file, then decodes it.
    @MainActor
    func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            loadImportFile(url)
        }

        if let window = hostWindow() {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    /// Reads and validates a backup file, then opens the review sheet or shows
    /// an error alert.
    @MainActor
    private func loadImportFile(_ url: URL) {
        Task { @MainActor in
            do {
                pendingBackup = try await SettingsBackupService().decode(fileURL: url)
                showingImportSheet = true
            } catch let error as SettingsBackupCoder.BackupError {
                importErrorMessage = Self.message(for: error)
                showingImportError = true
            } catch {
                importErrorMessage = "That file couldn't be read."
                showingImportError = true
            }
        }
    }

    /// Applies the reviewed backup with the user's per-account choices.
    @MainActor
    func applyImport(_ choices: SettingsBackupCoder.ImportChoices) {
        guard let backup = pendingBackup else { return }
        showingImportSheet = false
        pendingBackup = nil
        Task { @MainActor in
            let summary = await SettingsBackupService().apply(backup, choices: choices)
            importSuccessMessage = Self.successMessage(summary)
            showingImportSuccess = true
            Log.info(
                "Settings imported (\(summary.restoredCount) restored, twitch=\(summary.reconnectedTwitch))",
                category: .app
            )
        }
    }

    /// Cached: `DateFormatter` allocation is expensive and this runs per export.
    private static let fileDateStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// `yyyy-MM-dd` stamp for the default export filename.
    private static func fileDateStamp() -> String {
        fileDateStampFormatter.string(from: Date())
    }

    /// Human-readable message for a backup decode error.
    private static func message(for error: SettingsBackupCoder.BackupError) -> String {
        switch error {
        case .notReadable:
            return "That file couldn't be read. It may be damaged or not a WolfWave backup."
        case .notWolfWaveFile:
            return "That's not a WolfWave settings file."
        case .unsupportedOlderSchema:
            return "This backup uses an unsupported settings format."
        case .unsupportedNewerSchema:
            return "This backup was made by a newer version of WolfWave. Update WolfWave, then try again."
        case .tooLarge:
            return "That backup is too large to import. Choose a file under 1 MB."
        }
    }

    /// Confirmation message summarizing an applied import.
    private static func successMessage(_ summary: SettingsBackupService.ApplySummary) -> String {
        let noun = SettingsBackupService.ApplySummary.preferenceNoun(summary.restoredCount)
        var message = "Restored \(summary.restoredCount) \(noun)."
        if summary.reconnectedTwitch {
            message += " Open the Twitch tab to finish signing in."
        }
        if !summary.warnings.isEmpty {
            message += " " + summary.warnings.joined(separator: " ")
        }
        return message
    }
}
