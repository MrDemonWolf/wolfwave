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
    private var historyEnabled = false

    /// Shows the dashboard band and unlocks `!stats` + Monthly Wrap.
    @AppStorage(AppConstants.UserDefaults.statsEnabled)
    private var statsEnabled = false

    /// `!stats` chat command switch.
    @AppStorage(AppConstants.UserDefaults.statsCommandEnabled)
    private var statsCommandEnabled = false

    /// Channel-wide `!stats` cooldown, in seconds.
    @AppStorage(AppConstants.UserDefaults.statsCommandGlobalCooldown)
    private var statsGlobalCooldown: Double = 15

    /// Per-viewer `!stats` cooldown, in seconds.
    @AppStorage(AppConstants.UserDefaults.statsCommandUserCooldown)
    private var statsUserCooldown: Double = 15

    /// Comma-separated extra triggers for `!stats`.
    @AppStorage(AppConstants.UserDefaults.statsCommandAliases)
    private var statsCommandAliases = ""

    /// `StatsWindow` raw value the reply covers.
    @AppStorage(AppConstants.UserDefaults.statsCommandWindow)
    private var statsCommandWindow = StatsWindow.default.rawValue

    /// Encoded `StatsPart` list (see `StatsPart.encode` / `decode`).
    @AppStorage(AppConstants.UserDefaults.statsCommandParts)
    private var statsCommandParts = StatsPart.encode(StatsPart.defaults)

    /// Days of history to keep; `0` means forever.
    @AppStorage(AppConstants.UserDefaults.historyRetentionDays)
    private var historyRetentionDays = 0

    /// Allowed retention values, matching the picker tags. A stored value
    /// outside this list displays as Forever.
    fileprivate static let retentionOptions = [0, 7, 30, 90, 180, 365]

    // MARK: - State

    /// Presents `MonthlyWrapView`.
    @State private var showWrapSheet = false
    /// Confirm-before-clear alert.
    @State private var showClearAlert = false
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
    @State private var musicPermission: MusicPermissionState = MusicPermissionCache.read() ?? .unknown
    /// How many recent plays the list shows; grows by `recentPageStep` per
    /// "Load more" and resets when History is turned off.
    @State private var visibleRecentCount: Int = AppConstants.History.recentDisplayCount

    /// Live Twitch connection state, mirrored from the shared service so the
    /// `!stats` command card can gate itself the same way the Twitch and Song
    /// Requests panes do.
    @State private var isTwitchConnected = false

    /// Whether the stored Twitch token expired. Seeded from the same `UserDefaults`
    /// key the Twitch view model writes, so the gate flips to the orange "reconnect"
    /// warning the moment the sign-in ages out.
    @State private var twitchReauthNeeded = DefaultsStore.store.bool(
        forKey: AppConstants.UserDefaults.twitchReauthNeeded)

    /// Which leaderboard the "Top" card is showing. Lets one card surface
    /// artists, tracks, and albums in the footprint that previously showed
    /// only artists.
    @State private var topListKind: TopListKind = .artists

    /// Source list for the segmented "Top" card.
    private enum TopListKind: String, CaseIterable, Identifiable {
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
    private var service: ListeningHistoryService? {
        AppDelegate.shared?.historyService
    }

    /// The running app delegate (`nil` in previews).
    private var appDelegate: AppDelegate? { AppDelegate.shared }

    /// `!stats` only fires when chat is connected and the sign-in hasn't expired.
    /// Drives the gate banner + "Open Twitch settings" button on the command card.
    private var twitchReady: Bool {
        isTwitchConnected && !twitchReauthNeeded
    }

    /// Current rollup, or `.empty` when the service isn't available.
    private var snapshot: StatsSnapshot {
        service?.snapshot ?? .empty
    }

    /// True until `ListeningHistoryService` finishes loading from disk. Drives
    /// the `.skeleton` placeholder on derived content cards.
    private var isLoadingHistory: Bool {
        guard historyEnabled, statsEnabled else { return false }
        return service?.isLoaded == false
    }

    // MARK: - Body

    var body: some View {
        unifiedLayout
        .onAppear {
            musicPermission = MusicPermissionChecker.currentState()
            refreshTwitchState()
            refreshReauthState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            musicPermission = MusicPermissionChecker.currentState()
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
    private func chooseRetentionDays(_ days: Int) {
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

    /// One-line privacy promise above the toggles.
    private var intro: some View {
        Text("WolfWave can remember what you play, kept on this Mac, never uploaded.")
            .font(.system(size: DSFont.Size.body))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Toggles

    /// Listening History + Show Stats & Charts switches. Both disable while
    /// Music access is denied; Stats also needs History on.
    private var togglesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToggleSettingRow(
                title: "Listening History",
                subtitle: musicPermission == .denied
                    ? "Apple Music access required. See banner above."
                    : "Keep a private log of the tracks you play.",
                isOn: $historyEnabled,
                isDisabled: musicPermission == .denied,
                accessibilityLabel: "Toggle Listening History",
                accessibilityIdentifier: "listeningHistoryToggle",
                onChange: { handleHistoryChange($0) }
            )
            .padding(AppConstants.SettingsUI.cardPadding)

            Divider().padding(.horizontal, AppConstants.SettingsUI.cardPadding)

            ToggleSettingRow(
                title: "Show Stats & Charts",
                subtitle: historyEnabled
                    ? "Charts, top artists, listening by hour, and your Monthly Wrap."
                    : "Turn on Listening History first.",
                isOn: $statsEnabled,
                isDisabled: !historyEnabled || musicPermission == .denied,
                accessibilityLabel: "Toggle Show Stats and Charts",
                accessibilityIdentifier: "statsEnabledToggle",
                onChange: { handleStatsChange($0) }
            )
            .padding(AppConstants.SettingsUI.cardPadding)
        }
        .cardStyleUnpadded()
    }

    // MARK: - Summary

    /// This week / Today / All time play counts with listening time.
    private var summaryCard: some View {
        HStack(spacing: 0) {
            StatTile(
                value: "\(snapshot.playsThisWeek)",
                secondary: HistoryFormat.listeningTime(snapshot.listeningSecondsThisWeek),
                caption: "This week"
            )
            Divider().frame(height: 40)
            StatTile(
                value: "\(snapshot.playsToday)",
                secondary: HistoryFormat.listeningTime(snapshot.listeningSecondsToday),
                caption: "Today"
            )
            Divider().frame(height: 40)
            StatTile(
                value: "\(snapshot.totalPlays)",
                secondary: HistoryFormat.listeningTime(snapshot.totalListeningSeconds),
                caption: "All time"
            )
        }
        .frame(maxWidth: .infinity)
        .padding(AppConstants.SettingsUI.cardPadding)
        .cardStyleUnpadded()
    }

    // MARK: - Today's Top Track

    /// Highlights the single most-played track recorded today. Surfaces
    /// `snapshot.topTrackToday`, which the pane previously computed but never
    /// showed. Pairs beside the summary tiles in the dashboard band.
    private var todaysTopTrackCard: some View {
        VStack(alignment: .leading, spacing: DSSpace.s3) {
            CardEyebrowHeader("Today's top track", systemImage: "star")

            // Reserve a steady height so the card doesn't grow/shrink when the
            // single-line "nothing yet" copy is replaced by the two-line track
            // row (matters in the stacked single-column layout).
            Group {
                if let top = snapshot.topTrackToday {
                    HStack(spacing: DSSpace.s3) {
                        Image(systemName: "music.note")
                            .font(.system(size: DSFont.Size.lg))
                            .foregroundStyle(.secondary)
                            .frame(width: DSFont.Size.x2xl)
                        VStack(alignment: .leading, spacing: DSSpace.s0) {
                            Text(top.name)
                                .font(.system(size: DSFont.Size.base, weight: .medium))
                                .lineLimit(1)
                            if let detail = top.detail {
                                Text(detail)
                                    .font(.system(size: DSFont.Size.sm))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(HistoryFormat.playCount(top.count))
                            .font(.system(size: DSFont.Size.sm))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Nothing played yet today.")
                        .font(.system(size: DSFont.Size.sm))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: DSDimension.HistoryStats.topTrackMinHeight,
                alignment: .leading
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppConstants.SettingsUI.cardPadding)
        .cardStyleUnpadded()
    }

    // MARK: - Top Leaderboard

    /// The leaderboard for the selected segment.
    private var topListItems: [CountedItem] {
        switch topListKind {
        case .artists: return snapshot.topArtists
        case .tracks: return snapshot.topTracks
        case .albums: return snapshot.topAlbums
        }
    }

    /// One card whose segmented header switches between top artists, tracks,
    /// and albums. Replaces the old artists-only card and surfaces the
    /// `topTracks` / `topAlbums` lists that were computed but never displayed.
    private var topListCard: some View {
        VStack(alignment: .leading, spacing: DSSpace.s3) {
            HStack(spacing: DSSpace.s3) {
                CardEyebrowHeader("Top", systemImage: "trophy")
                Spacer()
                Picker("Top list", selection: $topListKind) {
                    ForEach(TopListKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("topListPicker")
            }

            // Reserve a full five-row height so flipping the segmented control
            // between Artists / Tracks / Albums (each a different length) or
            // filling in after load never resizes the card.
            topListContent
                .frame(
                    maxWidth: .infinity,
                    minHeight: DSDimension.HistoryStats.topListMinHeight,
                    alignment: .top
                )
        }
        .padding(AppConstants.SettingsUI.cardPadding)
        .cardStyleUnpadded()
    }

    /// Up to five ranked rows, or a "Not enough plays" note.
    @ViewBuilder
    private var topListContent: some View {
        let items = topListItems
        if items.isEmpty {
            Text("Not enough plays yet.")
                .font(.system(size: DSFont.Size.sm))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: DSSpace.s3) {
                ForEach(Array(items.prefix(5).enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: DSSpace.s3) {
                        Text("\(index + 1)")
                            .font(.system(size: DSFont.Size.body, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .leading)
                        VStack(alignment: .leading, spacing: DSSpace.s0) {
                            Text(item.name)
                                .font(.system(size: DSFont.Size.base))
                                .lineLimit(1)
                            if let detail = item.detail {
                                Text(detail)
                                    .font(.system(size: DSFont.Size.sm))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(HistoryFormat.playCount(item.count))
                            .font(.system(size: DSFont.Size.body))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Recent

    /// Single recently-played card whose outer frame stays a consistent size
    /// across off / empty / populated states. Prevents the settings window
    /// from resizing when the user flips Listening History on or off.
    private var unifiedRecentCard: some View {
        VStack(alignment: .leading, spacing: DSSpace.s3) {
            CardEyebrowHeader("Recently played", systemImage: "clock.arrow.circlepath")

            Group {
                if !historyEnabled {
                    emptyStateContent(
                        title: "Nothing is being recorded",
                        subtitle: "Turn on Listening History to start tracking your plays."
                    )
                } else if service?.records.isEmpty ?? true {
                    emptyStateContent(
                        title: "Nothing recorded yet",
                        subtitle: "Play something in Apple Music and it'll show up here."
                    )
                } else {
                    recentPlaysList
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: DSDimension.HistoryStats.recentCardMinHeight,
                alignment: .top
            )
        }
        .padding(AppConstants.SettingsUI.cardPadding)
        .cardStyleUnpadded()
    }

    /// Centered icon + title + subtitle filling the recent card's reserved height.
    @ViewBuilder
    private func emptyStateContent(title: String, subtitle: String) -> some View {
        VStack(spacing: DSSpace.s2) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: DSFont.Size.xl, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: DSFont.Size.base, weight: .medium))
            Text(subtitle)
                .font(.system(size: DSFont.Size.sm))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Newest-first list of the last `visibleRecentCount` plays in a fixed-height
    /// scroll box, with "Load more" while older plays remain.
    private var recentPlaysList: some View {
        // `records` is append-ordered (chronological), so newest-first is a
        // bounded reverse of the tail, not a full O(n log n) sort of up to
        // ~10k records on every body evaluation.
        let records = service?.records ?? []
        let total = records.count
        let visible = Array(records.suffix(visibleRecentCount).reversed())
        let hasMore = visible.count < total
        // Fixed-height scroll box so the card never grows with the list. Newest
        // plays sit at the top; *Load more* appends below and the user scrolls.
        return ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.s3) {
                ForEach(visible, id: \.self) { play in
                    HStack(spacing: DSSpace.s3) {
                        Image(systemName: "music.note")
                            .font(.system(size: DSFont.Size.sm))
                            .foregroundStyle(.secondary)
                            .frame(width: DSSpace.s6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(play.track)
                                .font(.system(size: DSFont.Size.base))
                                .lineLimit(1)
                            Text(play.artist)
                                .font(.system(size: DSFont.Size.sm))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(HistoryFormat.relative(play.timestamp))
                            .font(.system(size: DSFont.Size.sm))
                            .foregroundStyle(.tertiary)
                    }
                }
                if hasMore {
                    Button {
                        visibleRecentCount += AppConstants.History.recentPageStep
                    } label: {
                        Label("Load \(AppConstants.History.recentPageStep) more", systemImage: "arrow.down.circle")
                            .font(.system(size: DSFont.Size.sm))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Load \(AppConstants.History.recentPageStep) more plays")
                    .accessibilityIdentifier("loadMoreHistoryButton")
                    .padding(.top, DSSpace.s1)
                }
            }
            .padding(.trailing, DSSpace.s2)
        }
        .frame(height: DSDimension.HistoryStats.recentCardMinHeight)
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

    // MARK: - !stats Command

    /// `!stats` switch, the Twitch connection gate, and (when on) cooldowns,
    /// aliases, window, facts, and a live preview of the reply.
    private var statsCommandCard: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            HStack(spacing: DSSpace.s3) {
                CardEyebrowHeader("Chat command", systemImage: "text.bubble")
                Spacer()
                StatusChip(text: "Twitch", color: .purple)
            }

            ToggleSettingRow(
                title: "!stats command",
                subtitle: "Lets chat pull up your listening stats. Pick the window and what to show below. Set live-only for all commands in Twitch settings.",
                isOn: $statsCommandEnabled,
                accessibilityLabel: "Toggle the stats Twitch command",
                accessibilityIdentifier: "statsCommandToggle"
            )

            if !twitchReady {
                TwitchConnectionNotice(
                    isConnected: isTwitchConnected,
                    reauthNeeded: twitchReauthNeeded,
                    expiredMessage: "The !stats command is paused until you reconnect.",
                    disconnectedMessage:
                        "Connect with Twitch to let chat use the !stats command.",
                    onReconnect: reconnectTwitch
                )

                // The actionable expired notice carries its own Reconnect
                // button, so this link only covers the other cases.
                if !twitchReauthNeeded || reconnectTwitch == nil {
                    Button(action: openTwitchSettings) {
                        Label("Open Twitch settings", systemImage: "arrow.up.forward.app")
                            .font(.system(size: DSFont.Size.body))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("statsOpenTwitchSettingsButton")
                }
            }

            if statsCommandEnabled {
                Divider()
                CooldownSliderPair(
                    everyone: .init(
                        label: "Everyone",
                        value: $statsGlobalCooldown,
                        accessibilityIdentifier: "cooldown.Global cooldown"
                    ),
                    perPerson: .init(
                        label: "Per person",
                        value: $statsUserCooldown,
                        accessibilityIdentifier: "cooldown.Per-user cooldown"
                    )
                )

                CommandAliasField(
                    aliases: $statsCommandAliases,
                    placeholder: "e.g. nowstats, mystats",
                    accessibilityLabel: "Stats command aliases",
                    accessibilityIdentifier: "statsCommandAliases"
                )

                Divider()
                statsWindowRow
                statsPartsRow
                statsPreviewRow
            }
        }
        .padding(AppConstants.SettingsUI.cardPadding)
        .cardStyleUnpadded()
    }

    /// Picks the time window the `!stats` reply covers.
    private var statsWindowRow: some View {
        HStack(spacing: DSSpace.s2) {
            Text("Window")
                .sectionEyebrow()
            Spacer()
            Picker(
                "Stats window",
                selection: $statsCommandWindow.snapped(
                    to: StatsWindow.allCases.map(\.rawValue),
                    fallback: StatsWindow.default.rawValue)
            ) {
                ForEach(StatsWindow.allCases) { window in
                    Text(window.pickerLabel).tag(window.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: AppConstants.SettingsUI.inlineFieldMaxWidth)
            .accessibilityLabel("Stats command window")
            .accessibilityIdentifier("statsCommandWindow")
        }
    }

    /// Toggle chips choosing which facts the `!stats` reply includes. At least one
    /// stays selected so the command never replies empty.
    /// Chip-style multi-select (`.toggleStyle(.button)`) on purpose: this is a
    /// compact fact picker, not a settings switch row, so it is exempt from the
    /// `ToggleSettingRow` convention.
    private var statsPartsRow: some View {
        VStack(alignment: .leading, spacing: DSSpace.s2) {
            Text("Include")
                .sectionEyebrow()
            HStack(spacing: DSSpace.s2) {
                ForEach(StatsPart.allCases) { part in
                    // The last selected chip is disabled outright instead of
                    // silently ignoring the click (the binding still guards it).
                    let isLastSelected = selectedParts.count == 1 && selectedParts.contains(part)
                    Toggle(part.label, isOn: partBinding(for: part))
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .disabled(isLastSelected)
                        .help(isLastSelected ? Self.keepOneHint : "")
                        .accessibilityHint(isLastSelected ? Self.keepOneHint : "")
                        .accessibilityIdentifier("statsPart.\(part.rawValue)")
                }
            }
            if selectedParts.count == 1 {
                HintRow(Self.keepOneHint, systemImage: "lock.fill")
            }
        }
    }

    /// A live preview of the exact chat line, built from the real history so the
    /// streamer sees what viewers will get for the current window + facts.
    private var statsPreviewRow: some View {
        VStack(alignment: .leading, spacing: DSSpace.s1) {
            Text("Example reply")
                .sectionEyebrow()
            Text(statsPreview)
                .font(.system(size: DSFont.Size.body))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("statsCommandPreview")
        }
    }

    // MARK: - !stats Command Helpers

    /// Why the last selected fact chip is locked.
    private static let keepOneHint = "Keep at least one."

    /// The currently-selected facts, parsed from the stored comma list.
    private var selectedParts: [StatsPart] {
        StatsPart.decode(statsCommandParts)
    }

    /// A bool binding for one fact chip. Refuses to clear the last selected fact
    /// so the reply can't become empty.
    private func partBinding(for part: StatsPart) -> Binding<Bool> {
        Binding(
            get: { selectedParts.contains(part) },
            set: { isOn in
                var parts = Set(selectedParts)
                if isOn {
                    parts.insert(part)
                } else {
                    guard parts.count > 1 else { return }
                    parts.remove(part)
                }
                statsCommandParts = StatsPart.encode(Array(parts))
            }
        )
    }

    /// Builds the live preview from the real listening history. The session
    /// window uses Twitch's live-since time; while offline the service falls
    /// back to today.
    private var statsPreview: String {
        let window = StatsWindow(rawValue: statsCommandWindow) ?? .default
        let sessionStart = appDelegate?.twitchService?.currentStreamLiveSince
        return service?.statsChatLine(
            window: window,
            parts: selectedParts,
            sessionStart: sessionStart
        ) ?? "🐺 Listening stats aren't turned on right now"
    }

    // MARK: - Retention

    /// Picker for how many days of listening history `ListeningHistoryService`
    /// keeps on disk before pruning. `0` means keep forever.
    private var retentionCard: some View {
        VStack(alignment: .leading, spacing: DSSpace.s3) {
            CardEyebrowHeader("Keep history", systemImage: "calendar")

            HStack {
                Text("Keep for")
                    .font(.system(size: DSFont.Size.body))
                Spacer()
                // `0` is a real tag here ("Forever"), not an unset sentinel, so
                // this snaps against the allowlist rather than going through
                // `Preferences.int`, whose "non-positive means unset" rule
                // would be wrong for this key.
                Picker(
                    "Keep for",
                    selection: Binding(
                        get: { Self.retentionOptions.contains(historyRetentionDays) ? historyRetentionDays : 0 },
                        set: { chooseRetentionDays($0) })
                ) {
                    Text("Forever").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("180 days").tag(180)
                    Text("365 days").tag(365)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 120)
                .accessibilityIdentifier("historyRetentionDays")
                .disabled(service?.isLoaded != true)
            }

            Text("Old plays clear automatically.")
                .font(.system(size: DSFont.Size.xs))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(AppConstants.SettingsUI.cardPadding)
        .cardStyleUnpadded()
    }

    // MARK: - Actions

    /// Monthly Wrap action card. Sits beside the retention card in the
    /// two-column tail when Stats is on. The destructive Clear History action
    /// lives in the danger zone below, not here.
    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: DSSpace.s3) {
            CardEyebrowHeader("Recap", systemImage: "sparkles")

            Button {
                showWrapSheet = true
            } label: {
                Label("Monthly Wrap", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .pointerCursor()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(AppConstants.SettingsUI.cardPadding)
        .cardStyleUnpadded()
    }

    /// First-run explainer shown when Listening History is off, so the default
    /// state teaches what the feature does and offers a one-tap enable instead
    /// of looking blank.
    private var firstRunExplainer: some View {
        VStack(alignment: .leading, spacing: DSSpace.s3) {
            CardEyebrowHeader("What you'll get", systemImage: "sparkles")

            Text("Stats & Charts add a weekly view, your top artists, listening by hour, and a monthly wrap. Everything is computed on this Mac.")
                .font(.system(size: DSFont.Size.body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                guard musicPermission != .denied else { return }
                historyEnabled = true
                handleHistoryChange(true)
            } label: {
                Label("Turn on history", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .pointerCursor()
            .disabled(musicPermission == .denied)
            .accessibilityIdentifier("turnOnHistoryButton")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppConstants.SettingsUI.cardPadding)
        .cardStyleUnpadded()
    }

    /// Red danger zone holding the irreversible Clear History action, matching
    /// the Advanced pane's danger-zone treatment so destructive actions read
    /// the same everywhere.
    private var dangerCard: some View {
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

                Text("Permanently deletes every recorded play. Can't be undone.")
                    .font(.system(size: DSFont.Size.body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DestructiveButton(
                title: "Clear History",
                systemImage: "trash",
                accessibilityIdentifier: "clearHistoryButton",
                action: { showClearAlert = true }
            )
            .disabled(snapshot.totalPlays == 0)
            .accessibilityHint("Permanently deletes every recorded play")
        }
        .cardStyle()
    }

    // MARK: - Helpers

    /// Cascades Stats off when History is turned off, then notifies the app
    /// delegate so recording starts or stops. Turning History on while Music
    /// access is denied is reverted without posting anything.
    private func handleHistoryChange(_ enabled: Bool) {
        if enabled, musicPermission == .denied {
            historyEnabled = false
            return
        }
        if !enabled {
            statsEnabled = false
            statsCommandEnabled = false
            visibleRecentCount = AppConstants.History.recentDisplayCount
        }
        NotificationCenter.default.postEnabled(.listeningHistorySettingChanged, enabled: enabled)
    }

    /// Cascades the `!stats` command off when Stats is turned off.
    private func handleStatsChange(_ enabled: Bool) {
        if !enabled {
            statsCommandEnabled = false
        }
    }
}

// MARK: - Preview

#Preview {
    HistoryStatsSettingsView()
        .padding()
        .frame(width: 720, height: 600)
}
