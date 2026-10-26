//
//  GeneralSettingsView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-03-18.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// General application settings interface: Music Sync (hero now-playing +
/// integrations dashboard), App Visibility, Appearance, and Notifications.
///
/// A single scrollable column of sections, top to bottom. Each sub-view supplies
/// its own section header, so no extra headings are layered on top. (This pane
/// has no jump-nav rail; it is short enough to scroll directly.)
struct GeneralSettingsView: View {

    // MARK: - Properties

    /// Called when a "Configure" row in the integrations dashboard is tapped.
    /// `SettingsView` maps the target to a sidebar section; the default no-op
    /// keeps previews self-contained.
    var configure: (IntegrationDashboardView.Section) -> Void = { _ in }

    /// Master music-tracking switch. Read here only to drive the header chip;
    /// the toggle itself lives in `MusicMonitorSettingsView`.
    @AppStorage(AppConstants.UserDefaults.trackingEnabled)
    private var trackingEnabled = true

    // MARK: - Body

    var body: some View {
        SettingsPaneScroll {
            header

            MusicMonitorSettingsView(configure: configure)
                .deepLinkSection("music")

            AppVisibilitySettingsView()
                .deepLinkSection("visibility")

            AppearanceSettingsView()
                .deepLinkSection("appearance")

            NotificationsSettingsView()
                .deepLinkSection("notifications")
        }
    }

    // MARK: - Header

    /// Pane title plus a "Music on" / "Music off" chip mirroring `trackingEnabled`.
    private var header: some View {
        SectionHeaderWithStatus(
            title: "General",
            subtitle: "Manage how WolfWave tracks your music and where it shows up.",
            statusText: trackingEnabled ? "Music on" : "Music off",
            statusColor: trackingEnabled ? DSColor.success : DSColor.neutral
        )
        .accessibilityIdentifier("generalSettings.header")
    }
}

#Preview("General Settings") {
    GeneralSettingsView()
        .frame(width: 820, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Dark Mode") {
    GeneralSettingsView()
        .frame(width: 820, height: 600)
        .preferredColorScheme(.dark)
        .background(Color(nsColor: .windowBackgroundColor))
}
