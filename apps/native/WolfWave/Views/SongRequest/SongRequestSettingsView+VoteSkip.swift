//
//  SongRequestSettingsView+VoteSkip.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

// Chat vote-to-skip card for the Song Requests settings pane.

// MARK: - Chat Vote-Skip

/// Chat vote-to-skip settings: chat tally (window + cooldown) or Twitch Polls
/// (duration), minimum votes, subscriber-only voting, and the `!voteskip`
/// command. Every picker reads through `snapped(to:fallback:)` / `clamped`.
struct VoteSkipCard: View {
    /// Master switch. Turning it off resets any running vote; turning it on
    /// with Polls selected re-requests the poll subscription.
    @AppStorage(AppConstants.UserDefaults.voteSkipEnabled)
    private var voteSkipEnabled = false

    /// Votes needed to pass.
    @AppStorage(AppConstants.UserDefaults.voteSkipMinVotes)
    private var minVotes = AppConstants.UserDefaults.Defaults.voteSkipMinVotes

    /// Chat-tally vote window, in seconds.
    @AppStorage(AppConstants.UserDefaults.voteSkipWindowSeconds)
    private var windowSeconds = AppConstants.UserDefaults.Defaults.voteSkipWindowSeconds

    /// Cooldown between chat-tally votes, in seconds.
    @AppStorage(AppConstants.UserDefaults.voteSkipSessionCooldown)
    private var sessionCooldown = AppConstants.UserDefaults.Defaults.voteSkipSessionCooldown

    /// Only subscribers' votes count.
    @AppStorage(AppConstants.UserDefaults.voteSkipSubscriberOnly)
    private var subscriberOnly = false

    /// Use a native Twitch Poll instead of a chat tally (Affiliate/Partner).
    /// Changes post `voteSkipPollsSettingChanged`.
    @AppStorage(AppConstants.UserDefaults.voteSkipUsePolls)
    private var usePolls = false

    /// Poll length, in seconds.
    @AppStorage(AppConstants.UserDefaults.voteSkipPollDuration)
    private var pollDuration = AppConstants.UserDefaults.Defaults.voteSkipPollDuration

    /// `!voteskip` / `!vs` switch.
    @AppStorage(AppConstants.UserDefaults.voteSkipCommandEnabled)
    private var commandEnabled = true

    /// Comma-separated extra triggers for `!voteskip`.
    @AppStorage(AppConstants.UserDefaults.voteSkipCommandAliases)
    private var commandAliases = ""

    // Shared by each `ForEach` and its matching `snapped(to:fallback:)`, so a
    // tag can never exist in one and not the other.
    private static let minVotesOptions = [2, 3, 5, 7, 10]
    private static let pollDurationOptions = [30, 60, 90, 120, 180, 300]
    private static let windowOptions = [30, 60, 90, 120]
    private static let cooldownRange: ClosedRange<Double> = 0...120

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s6) {
            voteSkipHeader
            voteSkipCard
        }
    }

    /// The segmented picker that crashed the settings window when
    /// `voteSkipWindowSeconds` held a value outside its tags (a stored `1`).
    private var voteWindowRow: some View {
        let window = $windowSeconds.snapped(
            to: Self.windowOptions,
            fallback: AppConstants.UserDefaults.Defaults.voteSkipWindowSeconds)
        return VStack(alignment: .leading, spacing: DSSpace.s0) {
            Text("Vote window: \(window.wrappedValue)s")
                .font(.system(size: DSFont.Size.sm))
                .foregroundStyle(.secondary)
            Picker("Vote window in seconds", selection: window) {
                ForEach(Self.windowOptions, id: \.self) { seconds in
                    Text("\(seconds)s").tag(seconds)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Reads the clamped binding, not the raw one, so the two `Int(…)`
    /// conversions below are total. `Int(Double.nan)` and `Int(1e300)` trap.
    private var voteCooldownRow: some View {
        let cooldown = $sessionCooldown.clamped(
            to: Self.cooldownRange,
            fallback: AppConstants.UserDefaults.Defaults.voteSkipSessionCooldown)
        return VStack(alignment: .leading, spacing: DSSpace.s0) {
            Text("Cooldown between votes: \(Int(cooldown.wrappedValue))s")
                .font(.system(size: DSFont.Size.sm))
                .foregroundStyle(.secondary)
            Slider(value: cooldown, in: Self.cooldownRange, step: 15)
                .controlSize(.small)
                .accessibilityLabel("Cooldown between votes")
                .accessibilityValue("\(Int(cooldown.wrappedValue)) seconds")
        }
    }

    /// Section header for the card.
    private var voteSkipHeader: some View {
        SectionHeaderWithStatus(
            title: "Chat Vote-Skip",
            subtitle: "Let your Twitch chat vote to skip the current song. Skips the request queue when one is playing, otherwise it skips the current Apple Music track.",
            prominence: .section
        )
    }

    /// The settings card; everything below the master switch shows only
    /// while it is on.
    private var voteSkipCard: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            ToggleSettingRow(
                title: "Enable Vote-Skip",
                subtitle: "Viewers vote with !voteskip in Twitch chat",
                isOn: $voteSkipEnabled,
                accessibilityLabel: "Enable vote-skip",
                accessibilityIdentifier: "voteSkip.enableToggle"
            )
            .onChange(of: voteSkipEnabled) { _, enabled in
                if !enabled {
                    if let manager = AppDelegate.shared?.skipVoteManager {
                        Task { await manager.reset() }
                    }
                    return
                }
                // Polls may remain selected while the master switch is off.
                // Re-enabling must subscribe the already-connected EventSub
                // session even though the Polls setting itself did not change.
                guard usePolls else { return }
                NotificationCenter.default.postEnabled(
                    .voteSkipPollsSettingChanged,
                    enabled: true)
            }

            if voteSkipEnabled {
                Divider()

                HStack {
                    Text("Minimum votes to skip").font(.system(size: DSFont.Size.body))
                    Spacer()
                    Picker(
                        "Minimum votes to skip",
                        selection: $minVotes.snapped(
                            to: Self.minVotesOptions,
                            fallback: AppConstants.UserDefaults.Defaults.voteSkipMinVotes)
                    ) {
                        ForEach(Self.minVotesOptions, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 80)
                }

                ToggleSettingRow(
                    title: "Subscriber-Only Voting",
                    subtitle: "Only subscribers can cast skip votes",
                    isOn: $subscriberOnly,
                    accessibilityLabel: "Subscriber-only voting",
                    accessibilityIdentifier: "voteSkip.subscriberOnly"
                )

                ToggleSettingRow(
                    title: "Use Twitch Polls",
                    subtitle: "Affiliate/Partner only. Shows a native poll on stream instead of a chat tally",
                    isOn: $usePolls,
                    accessibilityLabel: "Use Twitch polls for vote-skip",
                    accessibilityIdentifier: "voteSkip.usePolls",
                    hint: "Turning this on may ask you to sign in to Twitch again to grant poll permission."
                )
                .onChange(of: usePolls) { _, enabled in
                    NotificationCenter.default.postEnabled(
                        .voteSkipPollsSettingChanged,
                        enabled: enabled)
                }

                if usePolls {
                    HStack {
                        Text("Poll duration").font(.system(size: DSFont.Size.body))
                        Spacer()
                        Picker(
                            "Poll duration",
                            selection: $pollDuration.snapped(
                                to: Self.pollDurationOptions,
                                fallback: AppConstants.UserDefaults.Defaults.voteSkipPollDuration)
                        ) {
                            ForEach(Self.pollDurationOptions, id: \.self) { seconds in
                                Text("\(seconds)s").tag(seconds)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 80)
                    }
                } else {
                    Divider()

                    voteWindowRow
                    voteCooldownRow
                }

                Divider()

                ToggleSettingRow(
                    title: "!voteskip Command",
                    subtitle: "!voteskip  ·  !vs",
                    isOn: $commandEnabled,
                    accessibilityLabel: "Enable vote-skip command",
                    accessibilityIdentifier: "voteSkip.commandToggle"
                )

                if commandEnabled {
                    CommandAliasField(
                        aliases: $commandAliases,
                        placeholder: "e.g. skipvote, sv",
                        accessibilityLabel: "Vote-skip command aliases",
                        accessibilityIdentifier: "voteSkip.commandAliases"
                    )
                }
            }
        }
        .cardStyle()
    }
}
