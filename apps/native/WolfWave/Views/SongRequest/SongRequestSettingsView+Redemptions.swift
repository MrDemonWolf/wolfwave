//
//  SongRequestSettingsView+Redemptions.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

// Channel Points and Bits redemption card for the Song Requests settings pane.

// MARK: - Redemptions (Channel Points & Bits)

/// The one place channel-point and Bits requests are switched on: reward cost,
/// reward repair, minimum Bits, and the boost option. Every change asks the
/// Twitch service to reconcile the managed reward and EventSub subscriptions.
struct SongRequestRedemptionsCard: View {
    /// Health of the redemption integration (missing scope, wrong account,
    /// stuck resolution, …) as last reported by the Twitch side; drives the banner.
    @AppStorage(AppConstants.UserDefaults.songRequestRedemptionStatus)
    private var redemptionStatus: RedemptionStatus = .ok

    /// Channel-point requests switch (WolfWave manages the reward).
    @AppStorage(AppConstants.UserDefaults.songRequestChannelPointsEnabled)
    private var channelPointsEnabled = false
    /// Reward cost in channel points.
    @AppStorage(AppConstants.UserDefaults.songRequestChannelPointsCost)
    private var channelPointsCost = AppConstants.UserDefaults.Defaults.songRequestChannelPointsCost
    /// Display mirror of the managed reward's ID. Shown only; the canonical
    /// owner record lives in the Twitch service.
    @AppStorage(AppConstants.UserDefaults.songRequestChannelPointsRewardID)
    private var rewardID = ""

    /// Bits requests switch.
    @AppStorage(AppConstants.UserDefaults.songRequestBitsEnabled)
    private var bitsEnabled = false
    /// Minimum cheer that counts as a request.
    @AppStorage(AppConstants.UserDefaults.songRequestBitsMinimum)
    private var bitsMinimum = AppConstants.UserDefaults.Defaults.songRequestBitsMinimum

    /// Allowed reward costs (picker tags and snap set).
    fileprivate static let channelPointsCostOptions = [100, 250, 500, 1000, 2500, 5000]
    /// Allowed Bits minimums (picker tags and snap set).
    fileprivate static let bitsMinimumOptions = [1, 50, 100, 200, 500, 1000]
    /// A cheer boosts the cheerer's queued song instead of adding a new one.
    @AppStorage(AppConstants.UserDefaults.songRequestBitsBoostEnabled)
    private var bitsBoostEnabled = false

    /// Masks the reward ID on camera.
    @AppStorage(AppConstants.UserDefaults.streamerModeEnabled)
    private var streamerMode = false

    /// Presents the Repair Reward confirmation.
    @State private var showRecreateAlert = false

    /// Asks the Twitch service to reconcile the reward and subscriptions with
    /// the current settings. No-op without a service.
    private func refresh() {
        if let service = AppDelegate.shared?.twitchService {
            Task { await service.refreshRedemptionSubscriptions() }
        }
    }

    /// Repair is a reconcile: the service verifies the reward and recreates it
    /// only if Twitch no longer has it.
    private func repairReward() {
        // Reconciliation proves the stored broadcaster/reward pair before it
        // pauses, replaces, or forgets anything. Never delete the legacy UI
        // mirror directly; the canonical owner record remains authoritative.
        refresh()
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            Text("Channel Points & Bits")
                .font(.system(size: DSFont.Size.base, weight: .semibold))

            Text("Let viewers redeem a song with channel points or a bit cheer.")
                .font(.system(size: DSFont.Size.sm))
                .foregroundStyle(.secondary)

            if let banner = redemptionStatus.bannerMessage {
                CalloutBanner(banner)
                    .accessibilityIdentifier("songRequests.redemptionBanner")
            }

            // Channel Points
            ToggleSettingRow(
                title: "Channel Point Requests",
                subtitle: "WolfWave adds a \u{201C}Request a Song\u{201D} reward to your channel",
                isOn: $channelPointsEnabled,
                accessibilityLabel: "Enable channel point song requests",
                accessibilityIdentifier: "songRequests.channelPointsEnabled",
                onChange: { _ in refresh() }
            )

            if channelPointsEnabled {
                HStack {
                    Text("Reward cost").font(.system(size: DSFont.Size.body))
                    Spacer()
                    Picker(
                        "Reward cost",
                        selection: $channelPointsCost.snapped(
                            to: Self.channelPointsCostOptions,
                            fallback: AppConstants.UserDefaults.Defaults.songRequestChannelPointsCost)
                    ) {
                        ForEach(Self.channelPointsCostOptions, id: \.self) { cost in
                            Text("\(cost)").tag(cost)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 90)
                    .accessibilityIdentifier("songRequests.channelPointsCost")
                }
                .onChange(of: channelPointsCost) { _, _ in refresh() }

                Text("Failed requests (song not found, blocked, queue full) refund the points automatically.")
                    .font(.system(size: DSFont.Size.xs))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: DSSpace.s2) {
                    VStack(alignment: .leading, spacing: DSSpace.s0) {
                        Text("Managed reward ID")
                            .font(.system(size: DSFont.Size.xs))
                            .foregroundStyle(.tertiary)
                        Text(rewardID.isEmpty
                            ? "Not created yet"
                            : StreamerMode.mask(rewardID, style: .channel, isOn: streamerMode))
                            .font(.system(size: DSFont.Size.xs, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button {
                        showRecreateAlert = true
                    } label: {
                        Label("Repair Reward", systemImage: "arrow.clockwise")
                            .font(.system(size: DSFont.Size.sm))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("songRequests.recreateReward")
                }
            }

            Divider()

            // Bits
            ToggleSettingRow(
                title: "Bit Requests",
                subtitle: "Viewers cheer with a song name to request it",
                isOn: $bitsEnabled,
                accessibilityLabel: "Enable bit song requests",
                accessibilityIdentifier: "songRequests.bitsEnabled",
                onChange: { _ in refresh() }
            )

            if bitsEnabled {
                HStack {
                    Text("Minimum bits").font(.system(size: DSFont.Size.body))
                    Spacer()
                    Picker(
                        "Minimum bits",
                        selection: $bitsMinimum.snapped(
                            to: Self.bitsMinimumOptions,
                            fallback: AppConstants.UserDefaults.Defaults.songRequestBitsMinimum)
                    ) {
                        ForEach(Self.bitsMinimumOptions, id: \.self) { amount in
                            Text("\(amount)").tag(amount)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 90)
                    .accessibilityIdentifier("songRequests.bitsMinimum")
                }

                ToggleSettingRow(
                    title: "Boost With Bits",
                    subtitle: "A cheer bumps the cheerer's queued song to the front instead of adding a new one",
                    isOn: $bitsBoostEnabled,
                    accessibilityLabel: "Boost queued song with bits",
                    accessibilityIdentifier: "songRequests.bitsBoost"
                )
            }
        }
        .cardStyle()
        .alert("Repair Channel Point reward?", isPresented: $showRecreateAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Repair") { repairReward() }
        } message: {
            Text(
                "Verifies the managed reward with Twitch. If it was deleted, "
                    + "WolfWave will safely create a fresh \u{201C}Request a Song\u{201D} reward on Twitch. "
                    + "Use this if you deleted the reward manually."
            )
        }
    }
}
