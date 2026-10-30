//
//  SettingsImportSheet.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-06-02.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Review sheet shown after the user picks a settings backup to import.
///
/// Portable preferences are always restored. For each account the backup had
/// configured (Twitch is the only OAuth account in WolfWave), the user opts in
/// to restore it and reconnect; leaving it off skips that account entirely. The
/// backup never contains credentials, so reconnecting always means signing in
/// again afterward.
struct SettingsImportSheet: View {

    // MARK: - Input

    /// The decoded backup being reviewed.
    let backup: SettingsBackup

    /// How many portable preferences will be restored.
    let restorableCount: Int

    /// Called with the user's choices when they confirm the import.
    let onConfirm: (SettingsBackupCoder.ImportChoices) -> Void

    /// Called when the user cancels.
    let onCancel: () -> Void

    // MARK: - State

    /// Whether to restore the Twitch channel and prompt re-sign-in.
    @State private var reconnectTwitch = false
    /// Opt-in for the security-relevant keys (diagnostics sharing, update
    /// channel, widget / Stream Deck servers). Off by default so importing a
    /// backup never silently opens a server or changes what is shared.
    @State private var includeLocalSharingSettings = false

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s6) {
            header

            Text(summaryLine)
                .font(.system(size: DSFont.Size.base))
                .fixedSize(horizontal: false, vertical: true)

            accountsSection

            VStack(alignment: .leading, spacing: DSSpace.s2) {
                Text("These change what WolfWave shares or opens")
                    .sectionEyebrow()
                ToggleSettingRow(
                    title: "Import local sharing and server settings",
                    subtitle: "Includes diagnostics sharing, automatic update checks, the update channel, "
                        + "and local widget or Stream Deck servers.",
                    isOn: $includeLocalSharingSettings,
                    accessibilityLabel: "Import local sharing and server settings",
                    accessibilityIdentifier: "importLocalSharingSettingsToggle"
                )
                .cardStyle()
            }

            Text("Permissions don't carry over either. You may need to re-grant access like Apple Music control after importing.")
                .font(.system(size: DSFont.Size.body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            buttons
        }
        .padding(DSSpace.s7)
        .frame(width: 460)
    }

    // MARK: - Sections

    /// Title plus where the backup came from (date, version, build).
    private var header: some View {
        VStack(alignment: .leading, spacing: DSSpace.s1) {
            Text("Import Settings")
                .sectionHeader()
            Text(sourceLine)
                .font(.system(size: DSFont.Size.body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Reconnect Twitch" opt-in when the backup names a channel; otherwise a
    /// note that only preferences will be imported.
    @ViewBuilder
    private var accountsSection: some View {
        if let twitch = backup.integrations.twitch {
            VStack(alignment: .leading, spacing: DSSpace.s2) {
                Text("Accounts")
                    .sectionEyebrow()

                ToggleSettingRow(
                    title: "Reconnect Twitch",
                    subtitle: "Was connected to \(channelDisplay(twitch.channelName)). Turn on to sign in again after import. Your login isn't in the backup.",
                    isOn: $reconnectTwitch,
                    accessibilityLabel: "Reconnect Twitch",
                    accessibilityIdentifier: "importReconnectTwitchToggle"
                )
                .cardStyle()
            }
        } else {
            Text("No connected accounts to restore. Only your preferences will be imported.")
                .font(.system(size: DSFont.Size.body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Cancel (Escape) and Import (Return). Import hands both toggles to
    /// `onConfirm` as `ImportChoices`.
    private var buttons: some View {
        HStack(spacing: DSSpace.s3) {
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
                .pointerCursor()
            Button("Import") {
                onConfirm(SettingsBackupCoder.ImportChoices(
                    reconnectTwitch: reconnectTwitch,
                    includeLocalSharingSettings: includeLocalSharingSettings))
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .pointerCursor()
            .accessibilityIdentifier("confirmImportButton")
        }
    }

    // MARK: - Copy Helpers

    /// "This replaces the N matching settings…" line built from `restorableCount`.
    private var summaryLine: String {
        "This replaces the \(restorableCount) matching settings on this Mac. "
            + "Anything not in the backup stays as is."
    }

    /// Provenance line: export date (localized), app version, and build.
    private var sourceLine: String {
        let date = backup.exportedAt.formatted(date: .abbreviated, time: .shortened)
        return "From a backup made \(date), WolfWave \(backup.appVersion) (\(backup.appBuild))."
    }

    /// Prefixes the channel with `#` unless the stored name already has one.
    private func channelDisplay(_ name: String) -> String {
        name.hasPrefix("#") ? name : "#\(name)"
    }
}

// MARK: - Preview

#Preview("With Twitch") {
    SettingsImportSheet(
        backup: SettingsBackup(
            format: SettingsBackup.currentFormat,
            schemaVersion: SettingsBackup.currentSchemaVersion,
            appVersion: "1.4.0",
            appBuild: "140",
            exportedAt: Date(),
            settings: [:],
            integrations: SettingsBackup.Integrations(
                twitch: SettingsBackup.Integrations.Twitch(channelName: "mrdemonwolf")
            )
        ),
        restorableCount: 42,
        onConfirm: { _ in },
        onCancel: {}
    )
}

#Preview("No Accounts") {
    SettingsImportSheet(
        backup: SettingsBackup(
            format: SettingsBackup.currentFormat,
            schemaVersion: SettingsBackup.currentSchemaVersion,
            appVersion: "1.4.0",
            appBuild: "140",
            exportedAt: Date(),
            settings: [:],
            integrations: SettingsBackup.Integrations(twitch: nil)
        ),
        restorableCount: 18,
        onConfirm: { _ in },
        onCancel: {}
    )
}
