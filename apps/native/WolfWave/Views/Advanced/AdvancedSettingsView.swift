//
//  AdvancedSettingsView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-01-13.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Advanced settings: diagnostics and the one destructive reset operation.
///
/// Cards, top to bottom: rerun the setup wizard, log diagnostics (export /
/// copy / reveal / clear), artwork cache (size + clear), opt-in MetricKit
/// "Share Diagnostics" card, settings backup (export / import), and the Danger
/// Zone, which holds only the full erase-and-reset. Clearing logs and the
/// artwork cache are routine upkeep, so they live in their own cards.
///
/// `showingResetAlert` is a @Binding from the parent `SettingsView` because the
/// actual reset is performed by `SettingsView.resetSettings()` after the alert
/// confirms. Everything else uses local @State.
struct AdvancedSettingsView: View {
    // MARK: - Environment

    /// Drops the copy-feedback fade when Reduce Motion is on.
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    // MARK: - State

    /// Whether the reset confirmation alert is currently shown.
    ///
    /// Passed as binding from parent to control alert visibility.
    @Binding var showingResetAlert: Bool

    /// True when the previous run left a crash breadcrumb (set at launch in
    /// `applicationDidFinishLaunching`). Drives the "Recovered from a crash"
    /// callout at the top of this pane.
    @AppStorage(AppConstants.UserDefaults.lastLaunchCrashed) private var lastLaunchCrashed = false

    /// Mirrors the opt-in MetricKit diagnostics toggle so the crash callout can
    /// point the user at it without enabling anything on their behalf.
    @AppStorage(AppConstants.UserDefaults.shareDiagnosticsEnabled) private var shareDiagnosticsEnabled = false

    /// Whether the onboarding reset confirmation alert is shown.
    @State private var showingOnboardingResetAlert = false

    /// Whether the clear-logs confirmation alert is shown.
    @State private var showingClearLogsAlert = false

    /// Formatted log file size (e.g. "248 KB"). Refreshed on appear and after diagnostics actions.
    @State var logSizeText: String = "N/A"

    /// Formatted log line count (e.g. "4,512 lines").
    @State var logLineCountText: String = "N/A"

    /// Whether the "Copied!" feedback row is shown after copying logs.
    @State var showingCopyFeedback = false

    /// Whether the clear-artwork-cache confirmation alert is shown.
    @State private var showingClearArtworkAlert = false

    /// Formatted artwork cache summary (e.g. "42 tracks · 18 KB").
    @State var artworkStatsText: String = "N/A"

    /// The decoded backup awaiting the user's import confirmation.
    @State var pendingBackup: SettingsBackup?

    /// Whether the import review sheet is shown.
    @State var showingImportSheet = false

    /// Message shown when an import file can't be read.
    @State var importErrorMessage: String?

    /// Whether the import error alert is shown.
    @State var showingImportError = false

    /// Message shown after a successful import.
    @State var importSuccessMessage: String?

    /// Whether the import success alert is shown.
    @State var showingImportSuccess = false

    /// Message shown when an export can't be built or saved.
    @State var exportErrorMessage: String?

    /// Whether the export error alert is shown.
    @State var showingExportError = false

    // MARK: - Crash Recovery

    /// "Recovered from a crash" callout shown at the top of the pane after the
    /// previous run crashed. The breadcrumb that drives it is written by
    /// `CrashReporter`; reporting a bug or dismissing clears the flag.
    @ViewBuilder
    private var crashRecoveryCallout: some View {
        CalloutBanner(
            shareDiagnosticsEnabled
                ? "WolfWave closed unexpectedly last time. If it keeps happening, send a bug report so we can dig in."
                : "WolfWave closed unexpectedly last time. If it keeps happening, send a bug report."
                    + " You can also turn on the private, on-device diagnostics below. Nothing leaves your Mac.",
            title: "Recovered from a crash",
            style: .warning
        ) {
            Button("Report a Bug\u{2026}") {
                AppDelegate.shared?.reportBug()
                lastLaunchCrashed = false
            }
            .buttonStyle(.bordered)
            .pointerCursor()
            Button("Dismiss") { lastLaunchCrashed = false }
                .buttonStyle(.bordered)
                .pointerCursor()
        }
    }

    // MARK: - Body

    /// Main view body with setup wizard, diagnostics, and danger zone sections.
    var body: some View {
        VStack(alignment: .leading, spacing: AppConstants.SettingsUI.sectionSpacing) {
            SectionHeaderWithStatus(
                title: "Advanced",
                subtitle: "Diagnostics and reset options."
            )

            if lastLaunchCrashed {
                crashRecoveryCallout
            }

            // Onboarding Card
            VStack(alignment: .leading, spacing: DSSpace.s4) {
                VStack(alignment: .leading, spacing: DSSpace.s1) {
                    Text("Setup Wizard")
                        .font(.system(size: DSFont.Size.base, weight: .semibold))

                    Text("Walk through the setup steps again to review your connections.")
                        .font(.system(size: DSFont.Size.body))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: { showingOnboardingResetAlert = true }) {
                    Label("Rerun Setup Wizard", systemImage: "arrow.counterclockwise")
                        .font(.system(size: DSFont.Size.base, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .pointerCursor()
                .accessibilityHint("Opens the setup wizard")
            }
            .cardStyle()
            .alert("Rerun Setup Wizard?", isPresented: $showingOnboardingResetAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Open Wizard") {
                    DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.hasCompletedOnboarding)
                    Log.info("Onboarding reset by user", category: .onboarding)
                    AppDelegate.shared?.showOnboarding()
                }
            } message: {
                Text("This will open the setup wizard. Your current settings will not be changed.")
            }

            // Diagnostics Card
            diagnosticsCard
                .deepLinkSection("diagnostics")

            // Artwork Cache Card
            artworkCacheCard
                .deepLinkSection("artwork-cache")

            // Diagnostics & Privacy (on-device MetricKit opt-in)
            DiagnosticsShareCardView()

            // Back Up / Restore Settings Card
            backupCard
                .deepLinkSection("backup")

            Divider()
                .padding(.vertical, DSSpace.s1)

            // Danger Zone Card
            VStack(alignment: .leading, spacing: DSSpace.s6) {
                VStack(alignment: .leading, spacing: DSSpace.s2) {
                    HStack(spacing: DSSpace.s2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: DSFont.Size.md))
                            .foregroundStyle(DSColor.error)
                        Text("Danger Zone")
                            .font(.system(size: DSFont.Size.md, weight: .semibold))
                            .foregroundStyle(DSColor.error)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Danger Zone")
                    .accessibilityAddTraits(.isHeader)

                    Text("Wipes every setting, sign-in, log, and cache, then restarts the app. This can't be undone.")
                        .font(.system(size: DSFont.Size.body))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: DSSpace.s2) {
                    DestructiveButton(
                        title: "Erase All Data & Reset",
                        systemImage: "trash",
                        accessibilityIdentifier: "resetAllSettingsButton",
                        action: { showingResetAlert = true }
                    )
                    .accessibilityHint("Permanently erase all settings, credentials, logs, listening history, and caches, then relaunch")
                }
            }
            .cardStyle()
            .deepLinkSection("danger-zone")
        }
    }

    // MARK: - Diagnostics Card

    /// Log size / line count plus Export, Copy, Reveal, and Clear (confirmed).
    /// Stats refresh on appear and after export / clear.
    @ViewBuilder
    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            VStack(alignment: .leading, spacing: DSSpace.s1) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Diagnostics")
                        .font(.system(size: DSFont.Size.base, weight: .semibold))
                    Spacer()
                    Text("\(logSizeText) · \(logLineCountText)")
                        .font(.system(size: DSFont.Size.sm, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Log file size \(logSizeText), \(logLineCountText)")
                }

                Text("Export logs, copy them, reveal the file in Finder, or clear it.")
                    .font(.system(size: DSFont.Size.body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Uniform 2-up action grid keeps the read actions visually quiet
            // and aligned, instead of one bright full-width bar plus two
            // smaller ones at mixed control sizes.
            ActionGrid {
                GridRow {
                    ActionGridButton(
                        title: "Export Logs",
                        systemImage: "square.and.arrow.up",
                        action: exportLogs,
                        accessibilityIdentifier: "exportLogsButton"
                    )
                    ActionGridButton(
                        title: "Copy to Clipboard",
                        systemImage: "doc.on.clipboard",
                        action: copyLogsToClipboard,
                        accessibilityIdentifier: "copyLogsButton"
                    )
                }
                GridRow {
                    ActionGridButton(
                        title: "Reveal in Finder",
                        systemImage: "folder",
                        action: revealLogsInFinder,
                        accessibilityIdentifier: "revealLogsButton"
                    )
                    // Routine upkeep that asks before it acts, so it sits with
                    // the other log actions. The Danger Zone is reserved for
                    // the full wipe.
                    ActionGridButton(
                        title: "Clear Logs",
                        systemImage: "trash",
                        action: { showingClearLogsAlert = true },
                        accessibilityIdentifier: "clearLogsButton"
                    )
                }
            }

            if showingCopyFeedback {
                SuccessFeedbackRow(text: "Copied to clipboard!")
                    .transition(.opacity)
            }
        }
        .cardStyle()
        .alert("Clear logs?", isPresented: $showingClearLogsAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { clearLogs() }
        } message: {
            Text("The current log file will be erased. This can't be undone.")
        }
        .onAppear { refreshLogStats() }
    }

    // MARK: - Artwork Cache Card

    /// Artwork cache entry count + disk size with a confirmed Clear action.
    @ViewBuilder
    private var artworkCacheCard: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            VStack(alignment: .leading, spacing: DSSpace.s1) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Artwork Cache")
                        .font(.system(size: DSFont.Size.base, weight: .semibold))
                    Spacer()
                    Text(artworkStatsText)
                        .font(.system(size: DSFont.Size.sm, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Artwork cache: \(artworkStatsText)")
                }

                Text("Saved album art links so tracks don't reload every launch.")
                    .font(.system(size: DSFont.Size.body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ActionGrid {
                GridRow {
                    ActionGridButton(
                        title: "Clear Artwork Cache",
                        systemImage: "trash",
                        action: { showingClearArtworkAlert = true },
                        accessibilityIdentifier: "clearArtworkCacheButton"
                    )
                    .gridCellColumns(2)
                }
            }
        }
        .cardStyle()
        .alert("Clear artwork cache?", isPresented: $showingClearArtworkAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                Task { await clearArtworkCache() }
            }
        } message: {
            Text("Saved album art links will be erased. They'll be fetched again as tracks play.")
        }
        .onAppear { refreshArtworkStats() }
    }

    // MARK: - Backup Card

    /// Opt-in iCloud mirror switch. Changes also post
    /// `iCloudSettingsSyncSettingChanged` so `SettingsSyncService` starts or stops.
    @AppStorage(AppConstants.UserDefaults.iCloudSettingsSyncEnabled)
    private var iCloudSettingsSyncEnabled = false

    /// Seconds since 1970 of the last iCloud payload applied here; `0` means never.
    @AppStorage(AppConstants.UserDefaults.iCloudSettingsSyncLastAppliedAt)
    private var iCloudSettingsSyncLastAppliedAt = 0.0

    /// "Last synced …" once a sync has been applied while enabled, otherwise
    /// the explainer line.
    private var iCloudSyncSubtitle: String {
        guard iCloudSettingsSyncEnabled, iCloudSettingsSyncLastAppliedAt > 0 else {
            return "Settings follow you to other Macs. Accounts stay on this one."
        }
        let date = Date(timeIntervalSince1970: iCloudSettingsSyncLastAppliedAt)
        return "Last synced \(date.formatted(date: .abbreviated, time: .shortened))."
    }

    /// iCloud sync toggle plus file Export / Import. Import goes through
    /// `chooseImportFile` → `loadImportFile` → `SettingsImportSheet` →
    /// `applyImport`, and every failure lands in one of the alerts here.
    @ViewBuilder
    private var backupCard: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            VStack(alignment: .leading, spacing: DSSpace.s1) {
                Text("Back Up Settings")
                    .font(.system(size: DSFont.Size.base, weight: .semibold))

                Text("Save your preferences to a file, or restore them on another Mac. Accounts and permissions aren't included, so after importing you'll reconnect Twitch and re-grant access like Apple Music control.")
                    .font(.system(size: DSFont.Size.body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ToggleSettingRow(
                title: "Sync with iCloud",
                subtitle: iCloudSyncSubtitle,
                isOn: $iCloudSettingsSyncEnabled,
                accessibilityLabel: "Sync settings with iCloud",
                accessibilityIdentifier: "iCloudSettingsSyncToggle",
                onChange: { enabled in
                    NotificationCenter.default.postEnabled(
                        .iCloudSettingsSyncSettingChanged, enabled: enabled)
                }
            )

            ActionGrid {
                GridRow {
                    ActionGridButton(
                        title: "Export Settings",
                        systemImage: "square.and.arrow.up",
                        action: exportSettings,
                        accessibilityIdentifier: "exportSettingsButton"
                    )
                    ActionGridButton(
                        title: "Import Settings",
                        systemImage: "square.and.arrow.down",
                        action: chooseImportFile,
                        accessibilityIdentifier: "importSettingsButton"
                    )
                }
            }
        }
        .cardStyle()
        .sheet(isPresented: $showingImportSheet) {
            if let backup = pendingBackup {
                SettingsImportSheet(
                    backup: backup,
                    restorableCount: SettingsBackupService().restorableCount(backup),
                    onConfirm: applyImport,
                    onCancel: {
                        showingImportSheet = false
                        pendingBackup = nil
                    }
                )
            }
        }
        .alert("Couldn't Import", isPresented: $showingImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "That file couldn't be read.")
        }
        .alert("Settings Imported", isPresented: $showingImportSuccess) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importSuccessMessage ?? "Your settings were restored.")
        }
        .alert("Couldn't Complete Action", isPresented: $showingExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "Couldn't save your backup.")
        }
    }

}

// MARK: - Preview

#Preview("Default State") {
    @Previewable @State var showingResetAlert = false
    AdvancedSettingsView(showingResetAlert: $showingResetAlert)
        .padding()
        .frame(width: 700)
}
