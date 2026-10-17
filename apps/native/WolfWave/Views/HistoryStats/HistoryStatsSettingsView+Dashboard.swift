//
//  HistoryStatsSettingsView+Dashboard.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Dashboard cards for the History & Stats pane: the tracking toggles, summary,
/// today's top track, the top leaderboard, and recent plays.
extension HistoryStatsSettingsView {

    // MARK: - Toggles

    /// Listening History + Show Stats & Charts switches. Both disable while
    /// Music access is denied; Stats also needs History on.
    var togglesCard: some View {
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
    var summaryCard: some View {
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
    var todaysTopTrackCard: some View {
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
    var topListCard: some View {
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
    var unifiedRecentCard: some View {
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
}
