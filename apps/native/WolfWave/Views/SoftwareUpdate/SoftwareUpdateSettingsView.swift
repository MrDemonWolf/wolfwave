//
//  SoftwareUpdateSettingsView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-28.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import SwiftUI

/// Software Update settings pane.
///
/// Shows the current version, update availability, and lets users toggle
/// automatic checks or trigger a manual check. Routes to the Homebrew-flavored
/// card for Homebrew installs (Sparkle disabled) and to the Sparkle-flavored
/// card for DMG installs.
struct SoftwareUpdateSettingsView: View {
    // MARK: - State

    /// True when the last `updateStateChanged` reported a newer build that the
    /// user hasn't skipped.
    @State private var updateAvailable = false
    /// Newest version Sparkle reported, `nil` until the first result this session.
    @State private var latestVersion: String?

    /// Version the user chose to skip in Sparkle's dialog; an update matching
    /// it is not shown as available.
    @AppStorage(AppConstants.UserDefaults.updateSkippedVersion)
    private var skippedVersion: String = ""

    /// Mirror of the automatic-check preference, used only for the status chip
    /// and the callouts. The toggle itself writes through `SparkleUpdaterService`.
    @AppStorage(AppConstants.UserDefaults.updateCheckEnabled)
    private var updateCheckEnabled = AppConstants.UserDefaults.Defaults.updateCheckEnabled

    /// Persisted `UpdateChannel` raw value. Read through `UpdateChannel.from`
    /// so an unknown stored string falls back safely.
    @AppStorage(AppConstants.UserDefaults.updateChannel)
    private var storedChannel = UpdateChannel.stable.rawValue

    /// True from a "Check Now" tap until the next `updateStateChanged`.
    @State private var isCheckingForUpdates = false
    /// Homebrew-managed install: Sparkle is disabled and the pane shows the
    /// `brew upgrade` card instead. Resolved on appear.
    @State private var isHomebrewInstall = false
    /// Presents the confirm-before-Nightly alert.
    @State private var showNightlyWarning = false

    /// The running app delegate (`nil` in previews); owns `sparkleUpdater`.
    private var appDelegate: AppDelegate? { AppDelegate.shared }

    /// Marketing version of the running build.
    private var currentVersion: String { AppConstants.AppInfo.shortVersion }

    /// The channel currently persisted, used to drive the picker and banner.
    private var selectedChannel: UpdateChannel { UpdateChannel.from(rawValue: storedChannel) }

    /// Picker binding that gates the switch to Nightly behind a warning alert.
    /// Switching to Stable is safe and commits immediately.
    private var channelBinding: Binding<UpdateChannel> {
        Binding(
            get: { UpdateChannel.from(rawValue: storedChannel) },
            set: { newValue in
                switch newValue {
                case .nightly:
                    // Don't commit yet. The alert's confirm button applies it,
                    // so Cancel leaves the picker reverted to its stored value.
                    if UpdateChannel.from(rawValue: storedChannel) != .nightly {
                        showNightlyWarning = true
                    }
                case .stable:
                    applyChannel(.stable)
                }
            }
        )
    }

    /// Persists the channel via the updater and silently re-checks the new feed.
    private func applyChannel(_ channel: UpdateChannel) {
        appDelegate?.sparkleUpdater?.channel = channel
        appDelegate?.sparkleUpdater?.recheckAfterChannelChange()
    }

    /// Every fixed label `status` can return, so the chip keeps one width.
    /// The "vX.Y.Z ready" label varies; a typical version stands in for it.
    private static let statusLabels = [
        "Homebrew", "Checking…", "Update ready", "v88.88.88 ready", "Up to date", "Auto on", "Auto off"
    ]

    /// Header chip derived from live update state, first match wins:
    /// Homebrew install, checking, update ready, up to date, then the
    /// automatic-check switch.
    private var status: StatusChip.Descriptor {
        if isHomebrewInstall {
            return .init(text: "Homebrew", color: DSColor.neutral, symbol: "shippingbox")
        }
        if isCheckingForUpdates {
            return .init(text: "Checking…", color: DSColor.warning, symbol: StatusChip.StateGlyph.starting)
        }
        if updateAvailable {
            // Stays .accentColor: an available update is the one state that
            // should follow the user's system accent rather than a fixed blue.
            return .init(
                text: latestVersion.map { "v\($0) ready" } ?? "Update ready",
                color: .accentColor,
                symbol: "arrow.down.circle.fill"
            )
        }
        if latestVersion != nil {
            return .init(text: "Up to date", color: DSColor.success, symbol: StatusChip.StateGlyph.on)
        }
        return updateCheckEnabled
            ? .init(text: "Auto on", color: DSColor.success, symbol: StatusChip.StateGlyph.on)
            : .init(text: "Auto off", color: DSColor.neutral, symbol: StatusChip.StateGlyph.off)
    }

    private var updateStatus: some View {
        StatusChip(status, sizingLabels: Self.statusLabels)
            .accessibilityLabel("Software Update status: \(status.text)")
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: AppConstants.SettingsUI.sectionSpacing) {
            Text("Check for new versions and manage automatic updates.")
                .fieldSubtitle()

            softwareUpdateCard
                .deepLinkSection("updates")
        }
        .onAppear {
            isHomebrewInstall = Bundle.main.isHomebrewInstall
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.updateStateChanged)) { notification in
            isCheckingForUpdates = false
            if let update = notification.updateState {
                latestVersion = update.latestVersion
                updateAvailable = update.isUpdateAvailable && skippedVersion != update.latestVersion
            }
        }
    }

    // MARK: - Software Update Card

    /// Homebrew installs get the `brew upgrade` card; everything else the
    /// Sparkle card.
    @ViewBuilder
    private var softwareUpdateCard: some View {
        if isHomebrewInstall {
            homebrewUpdateCard
        } else {
            sparkleUpdateCard
        }
    }

    /// Version line, a "managed by Homebrew" callout, and a copyable
    /// `brew upgrade wolfwave` command.
    @ViewBuilder
    private var homebrewUpdateCard: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            updateStatus

            Text("Version \(currentVersion)")
                .font(.system(size: DSFont.Size.base, weight: .semibold))

            CalloutBanner(
                "Use Homebrew to check for and install updates.",
                title: "Homebrew installation detected",
                style: .info
            )

            HStack(spacing: DSSpace.s2) {
                Text("$ brew upgrade wolfwave")
                    .font(.system(size: DSFont.Size.body, design: .monospaced))
                    .foregroundStyle(.primary)

                Spacer()

                CopyButton(
                    text: "brew upgrade wolfwave",
                    buttonStyle: .borderless,
                    accessibilityLabel: "Copy brew command"
                )
            }
            .padding(.horizontal, DSSpace.s3)
            .padding(.vertical, DSSpace.s2)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm))
        }
        .cardStyle()
    }

    /// Version + availability, channel picker (Nightly behind a confirm alert),
    /// the automatic-check toggle, and Check Now. In DEBUG builds the picker
    /// and toggle are disabled; Check Now stays live and checks the bundled
    /// dev-appcast.xml.
    @ViewBuilder
    private var sparkleUpdateCard: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            // Version, live status, and the manual check on one row: the
            // three things you look at together. The chip used to sit on its
            // own line and Check Now hung alone at the bottom of the card.
            HStack(alignment: .center, spacing: DSSpace.s4) {
                VStack(alignment: .leading, spacing: DSSpace.s1) {
                    Text("Version \(currentVersion)")
                        .font(.system(size: DSFont.Size.base, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    if updateAvailable, let version = latestVersion {
                        Text("Version \(version) is ready to install.")
                            .font(.system(size: DSFont.Size.body))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: DSSpace.s2)

                updateStatus

                Button {
                    // The `updateStateChanged` notification observer resets
                    // `isCheckingForUpdates` when Sparkle's delegate reports
                    // a result, so no fixed timer is needed. A check Sparkle
                    // ignored never reports, so don't start the spinner then.
                    isCheckingForUpdates = appDelegate?.sparkleUpdater?.checkForUpdates() ?? false
                } label: {
                    if isCheckingForUpdates {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 14, height: 14)
                    } else {
                        Text("Check Now")
                            .font(.system(size: DSFont.Size.body, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isCheckingForUpdates)
                .pointerCursor()
                .accessibilityLabel("Check for updates now")
                .accessibilityHint("Manually checks for a newer version of WolfWave")
                .accessibilityValue(isCheckingForUpdates ? "Checking" : "Idle")
            }

            if selectedChannel == .nightly {
                CalloutBanner(
                    "You're on Nightly. These are dev builds off main and can be unstable. Switch back to Stable below, then reinstall the latest Stable build.",
                    title: "Nightly channel",
                    style: .warning,
                    systemImage: "flask.fill"
                )
                .transition(.opacity)
            }

            #if DEBUG
            CalloutBanner(
                "Development build. Update checks use dev-appcast.xml",
                style: .warning,
                systemImage: "hammer.fill"
            )
            #endif

            Divider()

            VStack(alignment: .leading, spacing: DSSpace.s2) {
                Text("Update Channel")
                    .font(.system(size: DSFont.Size.body, weight: .medium))

                Picker("Update Channel", selection: channelBinding) {
                    Text("Stable").tag(UpdateChannel.stable)
                    Text("Nightly (dev)").tag(UpdateChannel.nightly)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Update channel")
                .accessibilityHint("Stable ships releases. Nightly is opt-in dev builds off main.")
                .accessibilityValue(selectedChannel.title)
                #if DEBUG
                .disabled(true)
                .opacity(0.5)
                #endif

                Text(selectedChannel == .nightly
                    ? "Dev builds straight off main. Newer, but can be unstable."
                    : "Shipped releases. Recommended for most people.")
                    .font(.system(size: DSFont.Size.body))
                    .foregroundStyle(.secondary)
            }

            Divider()

            ToggleSettingRow(
                title: "Check automatically",
                subtitle: "Looks for new versions in the background.",
                isOn: Binding(
                    get: { appDelegate?.sparkleUpdater?.automaticCheckEnabled ?? true },
                    set: { newValue in
                        appDelegate?.sparkleUpdater?.automaticCheckEnabled = newValue
                    }
                ),
                accessibilityLabel: "Check for updates automatically",
                accessibilityIdentifier: "updateCheckToggle",
                accessibilityHint: "Enables periodic background checks for new versions"
            )
            #if DEBUG
            .disabled(true)
            #endif

        }
        .cardStyle()
        .motionSafe(.easeInOut(duration: DSMotion.Duration.base), value: updateAvailable)
        .motionSafe(.easeInOut(duration: DSMotion.Duration.base), value: updateCheckEnabled)
        .motionSafe(.easeInOut(duration: DSMotion.Duration.base), value: selectedChannel)
        .alert("Switch to Nightly builds?", isPresented: $showNightlyWarning) {
            Button("Switch to Nightly", role: .destructive) {
                applyChannel(.nightly)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nightly builds come straight off main. They're newer but can be buggy, get no support, and update often.\n\nTo go back to Stable later, pick Stable here, then reinstall the latest Stable build.")
        }
    }
}

// MARK: - Preview

#Preview("Default") {
    SoftwareUpdateSettingsView()
        .padding()
        .frame(width: 700)
}
