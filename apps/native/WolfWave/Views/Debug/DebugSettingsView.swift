//
//  DebugSettingsView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

#if DEBUG
import AppKit
import SwiftUI

/// Developer tools, displaying only the selected tool so inactive polling stops.
struct DebugSettingsView: View {

    // MARK: - Properties

    // Preference toggles, read only to fill the Preferences table of Copy
    // Diagnostics. Defaults must match the ones the owning panes use.
    @AppStorage(AppConstants.UserDefaults.trackingEnabled) private var musicTrackingEnabled = true
    @AppStorage(AppConstants.UserDefaults.discordPresenceEnabled)
    private var discordPresenceEnabled = AppConstants.UserDefaults.Defaults.discordPresenceEnabled
    @AppStorage(AppConstants.UserDefaults.widgetHTTPEnabled) private var widgetHTTPEnabled = false

    /// The selected tool is shared by the wide list and compact picker.
    @State private var selected: DebugSection = .inspectors

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if geometry.size.width >= Self.railThreshold {
                    toolList
                    Divider()
                }
                SettingsPaneScroll {
                    if geometry.size.width < Self.railThreshold {
                        Picker("Tool", selection: $selected) {
                            ForEach(DebugSection.allCases, id: \.self) { section in
                                Label(section.title, systemImage: section.icon).tag(section)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("debugToolPicker")
                    }
                    header
                    if selected == .previews || selected == .controls {
                        warningBanner
                    }
                    selectedTool
                        .id(selected)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("debugTool.\(selected.rawValue)")
                }
            }
        }
    }

    /// Leaves the detail column enough space for its controls before adding a rail.
    private static var railThreshold: CGFloat {
        DSDimension.Settings.navRailWidth + DSDimension.Settings.inlineActionsMinWidth
            + 2 * AppConstants.SettingsUI.contentPaddingH
    }

    private var toolList: some View {
        List(selection: Binding<DebugSection?>(
            get: { selected },
            set: { if let section = $0 { selected = section } }
        )) {
            ForEach(DebugSection.railGroups) { group in
                Section(group.title ?? "Tools") {
                    ForEach(group.sections, id: \.self) { section in
                        Label(section.title, systemImage: section.icon)
                            .tag(section)
                            .accessibilityIdentifier("debugNav.\(section.rawValue)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: DSDimension.Settings.navRailWidth)
        .accessibilityLabel("Debug tools")
    }

    @ViewBuilder
    private var selectedTool: some View {
        switch selected {
        case .inspectors: DebugInspectorsCard()
        case .metrics: DebugMetricsCard()
        case .logViewer: DebugLogViewerCard()
        case .logs: DebugLogsAndEventsCard()
        case .previews: DebugUIPreviewsCard()
        case .controls: DebugServiceControlsCard()
        case .components: DebugComponentGalleryCard()
        case .tokens: DebugTokenGalleryCard()
        }
    }

    // MARK: - Header

    /// Selected tool title and the shared diagnostics action.
    private var header: some View {
        VStack(alignment: .leading, spacing: DSSpace.s3) {
            Text(selected.title)
                .sectionHeader()
            AsyncActionButton(
                title: "Copy Diagnostics", systemImage: "doc.on.doc",
                accessibilityIdentifier: "debugCopyDiagnostics"
            ) {
                try await copyDiagnostics()
            }
            .help("Copy environment and service state for a GitHub issue.")
        }
    }

    // MARK: - Warning Banner

    /// Warning shown above the Active Controls group, whose buttons act on the
    /// running app (services, windows, stored state).
    private var warningBanner: some View {
        CalloutBanner(
            "These tools mutate live state. Use at your own risk.",
            strokeVisible: true
        )
    }

    // MARK: - Copy Diagnostics

    /// Builds the diagnostics blob and puts it on the pasteboard.
    ///
    /// The slow reads run off the main actor. `Log.logLineCount()` streams the
    /// whole log under `fileQueue.sync` and `KeychainService.loadTwitchToken()`
    /// is a synchronous `SecItemCopyMatching`; doing both on `@MainActor` beach-
    /// balled the pane on a large log, which is the exact stall
    /// `DebugLogsAndEventsCard` already documents moving off-main to avoid.
    ///
    /// Cancellation leaves the clipboard unchanged if the pane closes during the read.
    private func copyDiagnostics() async throws {
        // Live connection state, read on the main actor where the services live.
        // Captured before the detached hop so the snapshot reflects click time.
        let twitchConnected = AppDelegate.shared?.twitchService?.currentlyConnected == true
        let discordConnection = (AppDelegate.shared?.discordService?.stateSnapshot
            ?? .disconnected).rawValue
        let preferences = (
            music: musicTrackingEnabled,
            discord: discordPresenceEnabled,
            widget: widgetHTTPEnabled
        )

        let heavy = await Task.detached(priority: .userInitiated) {
            (
                size: Log.logFileSize(),
                lines: Log.logLineCount(),
                tokenStored: KeychainService.loadTwitchToken() != nil
            )
        }.value
        try Task.checkCancellation()

        let snapshot = DebugDiagnostics.Snapshot(
            appVersion: AppConstants.AppInfo.shortVersion,
            build: AppConstants.AppInfo.buildNumber,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            arch: BugReportURL.currentArch(),
            installMethod: Bundle.main.isHomebrewInstall ? "Homebrew" : "DMG",
            logSizeBytes: heavy.size,
            logLineCount: heavy.lines,
            musicTrackingEnabled: preferences.music,
            discordPresenceEnabled: preferences.discord,
            widgetHTTPEnabled: preferences.widget,
            twitchConnected: twitchConnected,
            discordConnection: discordConnection,
            twitchTokenStored: heavy.tokenStored
        )
        Pasteboard.copy(DebugDiagnostics.markdown(snapshot))
        Log.info("Copied diagnostics snapshot to pasteboard", category: .devTools)
    }
}

// MARK: - Debug Section

/// Tool identity shared by the wide navigation list and compact picker.
enum DebugSection: String, SettingsRailSection, CaseIterable {

    /// Rail layout. Hand-ordered because the grouping is editorial, but
    /// `DebugSectionCoverageTests` asserts every case appears exactly once, so
    /// adding a case without placing it here fails the suite instead of
    /// silently dropping the section out of the rail.
    static let railGroups: [SettingsRailGroup<DebugSection>] = [
        SettingsRailGroup(
            title: "State & Diagnostics",
            sections: [.inspectors, .metrics, .logViewer, .logs]),
        SettingsRailGroup(
            title: "Active Controls",
            sections: [.previews, .controls]),
        SettingsRailGroup(
            title: "Design System",
            sections: [.components, .tokens])
    ]

    // Raw values are not shown; they feed the rail's accessibility identifiers
    // (`debugNav.<rawValue>`) and group ids, so treat them as stable.
    case inspectors
    case metrics
    case logViewer
    case logs
    case previews
    case controls
    case components
    case tokens

    /// Visible label for the rail row and the section heading.
    var title: String {
        switch self {
        case .inspectors: return "State Inspectors"
        case .metrics: return "Performance"
        case .logViewer: return "Log Viewer"
        case .logs: return "Logs & Events"
        case .previews: return "UI Previews"
        case .controls: return "Service Controls"
        case .components: return "Components"
        case .tokens: return "Tokens"
        }
    }

    /// SF Symbol name for the rail row.
    var icon: String {
        switch self {
        case .inspectors: return "magnifyingglass"
        case .metrics: return "speedometer"
        case .logViewer: return "text.viewfinder"
        case .logs: return "doc.text"
        case .previews: return "rectangle.on.rectangle"
        case .controls: return "slider.horizontal.3"
        case .components: return "square.grid.2x2"
        case .tokens: return "paintpalette"
        }
    }
}

#Preview {
    DebugSettingsView()
        .frame(width: 820, height: 600)
}
#endif
