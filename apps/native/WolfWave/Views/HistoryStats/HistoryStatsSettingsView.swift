//
//  HistoryStatsSettingsView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-22.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI
import AppKit

/// Settings pane for the opt-in Listening History & Stats feature.
///
/// Two interlocked toggles: *Listening History* records plays to disk; *Stats &
/// Charts* visualizes them and unlocks the `!stats` command. Stats can't be
/// enabled until History is on, and turning History off cascades Stats (and
/// the `!stats` command) off. Both are blocked while Music Automation access
/// is denied, since nothing could be recorded.
///
/// Owns its own centered scroll column (it bypasses the shell's
/// `standardDetailScroll`). Data comes from `AppDelegate.historyService`,
/// which is `@Observable`, so the dashboard updates live as plays land.
struct HistoryStatsSettingsView: View {

    // MARK: - Navigation

    /// Jumps the settings shell to the Twitch pane. Wired by `SettingsView`. The
    /// `!stats` command gate uses it because this pane has no Twitch auth card of
    /// its own to point "above" at. A `var` with a default keeps the `#Preview`
    /// (and any param-less call site) compiling.
    var openTwitchSettings: () -> Void = {}

    /// Starts the Twitch reconnect from the `!stats` expired-sign-in notice.
    /// Wired by `SettingsView`; `nil` (previews) leaves the notice as a plain
    /// note, and the "Open Twitch settings" link stays as the way out.
    var reconnectTwitch: (@MainActor () -> Void)?

    // MARK: - User Settings

    /// Records plays to disk. Changes post `listeningHistorySettingChanged`
    /// (see `handleHistoryChange`).
    @AppStorage(AppConstants.UserDefaults.listeningHistoryEnabled)
    var historyEnabled = false

    /// Shows the dashboard band and unlocks `!stats` + Monthly Wrap.
    @AppStorage(AppConstants.UserDefaults.statsEnabled)
    var statsEnabled = false

    /// `!stats` chat command switch.
    @AppStorage(AppConstants.UserDefaults.statsCommandEnabled)
    var statsCommandEnabled = AppConstants.UserDefaults.Defaults.statsCommandEnabled

    /// Channel-wide `!stats` cooldown, in seconds.
    @AppStorage(AppConstants.UserDefaults.statsCommandGlobalCooldown)
    var statsGlobalCooldown: Double = AppConstants.UserDefaults.Defaults.commandCooldown

    /// Per-viewer `!stats` cooldown, in seconds.
    @AppStorage(AppConstants.UserDefaults.statsCommandUserCooldown)
    var statsUserCooldown: Double = AppConstants.UserDefaults.Defaults.commandCooldown

    /// Comma-separated extra triggers for `!stats`.
    @AppStorage(AppConstants.UserDefaults.statsCommandAliases)
    var statsCommandAliases = ""

    /// `StatsWindow` raw value the reply covers.
    @AppStorage(AppConstants.UserDefaults.statsCommandWindow)
    var statsCommandWindow = StatsWindow.default.rawValue

    /// Encoded `StatsPart` list (see `StatsPart.encode` / `decode`).
    @AppStorage(AppConstants.UserDefaults.statsCommandParts)
    var statsCommandParts = StatsPart.encode(StatsPart.defaults)

    /// Days of history to keep; `0` means forever.
    @AppStorage(AppConstants.UserDefaults.historyRetentionDays)
    var historyRetentionDays = 0

    /// Allowed retention values, matching the picker tags. A stored value
    /// outside this list displays as Forever.
    static let retentionOptions = [0, 7, 30, 90, 180, 365]

    // MARK: - State

    /// Presents `MonthlyWrapView`.
    @State var showWrapSheet = false
    /// Confirm-before-clear alert.
    @State var showClearAlert = false
    /// Shown when `clearHistory()` couldn't finish removing the files.
    @State private var showClearFailureAlert = false
    /// Confirm alert for a shorter retention that would delete existing plays.
    @State private var showRetentionAlert = false
    /// Retention choice awaiting confirmation.
    @State private var pendingRetentionDays = 0
    /// How many plays `pendingRetentionDays` would remove (for the alert title).
    @State private var pendingExpiredCount = 0
    /// Music Automation grant. Seeded from the session cache, then re-probed
    /// on appear and whenever the app becomes active.
    @State var musicPermission: MusicPermissionState = MusicPermissionCache.read() ?? .unknown
    /// How many recent plays the list shows; grows by `recentPageStep` per
    /// "Load more" and resets when History is turned off.
    @State var visibleRecentCount: Int = AppConstants.History.recentDisplayCount

    /// Live Twitch connection state, mirrored from the shared service so the
    /// `!stats` command card can gate itself the same way the Twitch and Song
    /// Requests panes do.
    @State var isTwitchConnected = false

    /// Whether the stored Twitch token expired. Seeded from the same `UserDefaults`
    /// key the Twitch view model writes, so the gate flips to the orange "reconnect"
    /// warning the moment the sign-in ages out.
    @State var twitchReauthNeeded = DefaultsStore.store.bool(
        forKey: AppConstants.UserDefaults.twitchReauthNeeded)

    /// Which leaderboard the "Top" card is showing. Lets one card surface
    /// artists, tracks, and albums in the footprint that previously showed
    /// only artists.
    @State var topListKind: TopListKind = .artists

    /// Source list for the segmented "Top" card.
    enum TopListKind: String, CaseIterable, Identifiable {
        case artists, tracks, albums
        /// Stable `ForEach` identity.
        var id: String { rawValue }
        /// Segment title.
        var label: String {
            switch self {
            case .artists: return "Artists"
            case .tracks: return "Tracks"
            case .albums: return "Albums"
            }
        }
    }

    /// The shared history service. Accessed as a computed property so the
    /// Observation framework tracks property reads each time `body` runs.
    var service: ListeningHistoryService? {
        AppDelegate.shared?.historyService
    }

    /// The running app delegate (`nil` in previews).
    var appDelegate: AppDelegate? { AppDelegate.shared }

    /// `!stats` only fires when chat is connected and the sign-in hasn't expired.
    /// Drives the gate banner + "Open Twitch settings" button on the command card.
    var twitchReady: Bool {
        isTwitchConnected && !twitchReauthNeeded
    }

    /// Current rollup, or `.empty` when the service isn't available.
    var snapshot: StatsSnapshot {
        service?.snapshot ?? .empty
    }

    /// True until `ListeningHistoryService` finishes loading from disk. Drives
    /// the `.skeleton` placeholder on derived content cards.
    private var isLoadingHistory: Bool {
        guard historyEnabled, statsEnabled else { return false }
        return service?.isLoaded == false
    }

    // MARK: - Music Permission

    /// Refreshes ``musicPermission`` with a live Apple Events probe. The probe
    /// can take tens of milliseconds, so it runs detached to keep the main
    /// thread free; the result is applied back on the main actor.
    private func probeMusicPermission() {
        Task {
            let state = await Task.detached(priority: .userInitiated) {
                MusicPermissionChecker.currentState()
            }.value
            musicPermission = state
        }
    }

    // MARK: - Body

    var body: some View {
        unifiedLayout
        .onAppear {
            probeMusicPermission()
            refreshTwitchState()
            refreshReauthState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            probeMusicPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.twitchConnectionStateChanged)) { notification in
            if let connected = notification.isConnectedFlag {
                isTwitchConnected = connected
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.twitchReauthNeededChanged)) { _ in
            refreshReauthState()
        }
        .sheet(isPresented: $showWrapSheet) {
            if let service {
                MonthlyWrapView(service: service)
            }
        }
        .alert("Clear listening history?", isPresented: $showClearAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                if let service, !service.clearHistory() {
                    showClearFailureAlert = true
                }
            }
            .accessibilityIdentifier("clearHistoryConfirmButton")
        } message: {
            Text("This permanently deletes every recorded play. Can't be undone.")
        }
        .alert("Couldn't finish clearing history", isPresented: $showClearFailureAlert) {
            Button("OK") {}
        } message: {
            Text("WolfWave will retry before saving any new plays.")
        }
        .alert("Remove \(pendingExpiredCount) plays older than \(pendingRetentionDays) days?", isPresented: $showRetentionAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                applyRetentionDays(pendingRetentionDays)
            }
            .accessibilityIdentifier("historyRetentionConfirmButton")
        } message: {
            Text("These plays will be removed from history and statistics. Can't be undone.")
        }
    }

    // MARK: - Retention Actions

    /// Picker setter for retention. A shorter window that would delete existing
    /// plays asks first (`showRetentionAlert`); anything else applies at once.
    func chooseRetentionDays(_ days: Int) {
        let shorter = days > 0 && (historyRetentionDays == 0 || days < historyRetentionDays)
        let count = service?.expiredRecordCount(retentionDays: days) ?? 0
        if shorter, count > 0 {
            pendingRetentionDays = days
            pendingExpiredCount = count
            showRetentionAlert = true
        } else {
            applyRetentionDays(days)
        }
    }

    /// Persists the retention and tells the service to prune now.
    private func applyRetentionDays(_ days: Int) {
        historyRetentionDays = days
        service?.setRetentionDays(days)
    }

    // MARK: - Layout

    /// One centered, width-clamped scroll column for every state. Mirrors the
    /// shell's `standardDetailScroll` geometry (the pane bypasses it to own the
    /// full detail width). The dashboard band (summary / charts / top), the
    /// `!stats` command, and the Monthly Wrap action surface inline once both
    /// features are on, so the pane reads top-to-bottom without a jump-nav rail.
    private var unifiedLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppConstants.SettingsUI.sectionSpacing) {
                intro
                permissionBanner
                togglesCard
                    .deepLinkSection("tracking")

                if !historyEnabled {
                    firstRunExplainer
                }

                // Dashboard band: lead with the insights, two columns when the
                // settings window is wide enough (collapses to a stack when not).
                // Render while the service is still loading too, so the skeleton
                // placeholders hold the band's footprint instead of popping in and
                // resizing the pane the moment disk load finishes (#281).
                if historyEnabled, statsEnabled, snapshot.hasData || isLoadingHistory {
                    ResponsiveRow {
                        summaryCard
                    } right: {
                        todaysTopTrackCard
                    }
                    .skeleton(isLoadingHistory)

                    ResponsiveRow {
                        WeekChartCard(snapshot: snapshot)
                    } right: {
                        HourChartCard(snapshot: snapshot)
                    }
                    .skeleton(isLoadingHistory)

                    topListCard
                        .skeleton(isLoadingHistory)
                }

                unifiedRecentCard
                    .skeleton(isLoadingHistory)

                if historyEnabled, statsEnabled {
                    statsCommandCard
                        .deepLinkSection("stats-command")
                }

                if historyEnabled {
                    manageBlock
                        .deepLinkSection("retention")
                    dangerCard
                        .deepLinkSection("danger-zone")
                }
            }
            .frame(maxWidth: AppConstants.SettingsUI.maxContentWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, AppConstants.SettingsUI.contentPaddingH)
            .padding(.vertical, AppConstants.SettingsUI.contentPaddingV)
        }
    }

    /// Retention card, plus the Monthly Wrap action when Stats is on. Retention
    /// stands alone (single column) when only History is on; the actions column
    /// joins once Stats unlocks the wrap.
    @ViewBuilder
    private var manageBlock: some View {
        if statsEnabled {
            ResponsiveRow {
                retentionCard
            } right: {
                actionsCard
            }
        } else {
            retentionCard
        }
    }

    /// Apple Music automation-denied banner, shown above the toggles in both
    /// layouts when access is blocked.
    @ViewBuilder
    private var permissionBanner: some View {
        if musicPermission == .denied {
            MusicPermissionBanner(
                message: "WolfWave needs Apple Music automation access to record what you play. Enable it in System Settings → Privacy & Security → Automation."
            )
        }
    }

    // MARK: - Intro

    /// Pane heading and privacy promise above the toggles.
    private var intro: some View {
        SectionHeaderWithStatus(
            title: "History & Stats",
            subtitle: "WolfWave can remember what you play, kept on this Mac, never uploaded."
        )
        .accessibilityIdentifier("historyStats.header")
    }

    // MARK: - Twitch State

    /// Pulls the current connection flag from the live Twitch service.
    private func refreshTwitchState() {
        isTwitchConnected = appDelegate?.twitchService?.currentlyConnected ?? false
    }

    /// Re-reads the reauth flag the Twitch view model persists.
    private func refreshReauthState() {
        twitchReauthNeeded = DefaultsStore.store.bool(
            forKey: AppConstants.UserDefaults.twitchReauthNeeded)
    }

}

// MARK: - Preview

#Preview {
    HistoryStatsSettingsView()
        .padding()
        .frame(width: 720, height: 600)
}
