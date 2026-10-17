//
//  HistoryStatsSettingsView+Management.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// The `!stats` command card, retention, actions, and the danger zone for the
/// History & Stats pane, plus the toggle-change handlers.
extension HistoryStatsSettingsView {

    // MARK: - !stats Command

    /// `!stats` switch, the Twitch connection gate, and (when on) cooldowns,
    /// aliases, window, facts, and a live preview of the reply.
    var statsCommandCard: some View {
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
    var retentionCard: some View {
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
    var actionsCard: some View {
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
    var firstRunExplainer: some View {
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
    var dangerCard: some View {
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
    func handleHistoryChange(_ enabled: Bool) {
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
    func handleStatsChange(_ enabled: Bool) {
        if !enabled {
            statsCommandEnabled = false
        }
    }
}
