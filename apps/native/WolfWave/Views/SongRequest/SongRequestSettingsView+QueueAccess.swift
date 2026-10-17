//
//  SongRequestSettingsView+QueueAccess.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

// Queue limits and request-access cards for the Song Requests settings pane.

// MARK: - Queue Config

/// Ordering (fair share, Sub/VIP priority), max queue size, and per-role
/// request limits with how they combine for multi-role viewers.
struct SongRequestQueueConfigCard: View {
    /// Total queue capacity.
    @AppStorage(AppConstants.UserDefaults.songRequestMaxQueueSize)
    private var maxQueueSize = AppConstants.UserDefaults.Defaults.songRequestMaxQueueSize

    // Per-role limits. "Everyone" reuses the original per-user-limit key so
    // existing setups keep their value.
    @AppStorage(AppConstants.UserDefaults.songRequestPerUserLimit)
    private var everyoneLimit = AppConstants.UserDefaults.Defaults.songRequestPerUserLimit
    // Optional so "never set" (nil) stays distinct from a chosen value: under
    // Stacked an unset role adds nothing, under Highest it reads as 2.
    @AppStorage(AppConstants.UserDefaults.songRequestLimitSubscriber)
    private var subLimit: Int?
    @AppStorage(AppConstants.UserDefaults.songRequestLimitVIP)
    private var vipLimit: Int?
    @AppStorage(AppConstants.UserDefaults.songRequestLimitModerator)
    private var modLimit: Int?

    /// How limits combine when a viewer holds several roles.
    @AppStorage(AppConstants.UserDefaults.songRequestLimitStackMode)
    private var stackMode: QueueLimitMode = .highest

    /// Round-robin by requester instead of plain FIFO.
    @AppStorage(AppConstants.UserDefaults.songRequestFairShare)
    private var fairShare = AppConstants.UserDefaults.Defaults.songRequestFairShare

    /// Sub/VIP priority perk.
    @AppStorage(AppConstants.UserDefaults.songRequestPriorityMode)
    private var priorityMode: SongRequestPriorityMode = .off

    /// Allowed max queue sizes (picker tags and snap set).
    fileprivate static let maxQueueSizeOptions = [5, 10, 15, 20, 25, 50]

    /// The Everyone limit, snapped so a stored value outside the picker's tags
    /// renders as the default rather than reaching the picker unmatched.
    private var everyoneSelection: Binding<Int> {
        $everyoneLimit.snapped(
            to: SongRequestLimits.roleLimitValues,
            fallback: AppConstants.UserDefaults.Defaults.songRequestPerUserLimit)
    }

    /// A role limit's picker binding. The getter resolves through
    /// `SongRequestLimits.rolePickerValue`, so it always lands on one of the
    /// current mode's tags and shows what the limit math will actually do.
    private func roleSelection(_ stored: Binding<Int?>) -> Binding<Int> {
        let mode = stackMode
        return Binding(
            get: { SongRequestLimits.rolePickerValue(stored: stored.wrappedValue, mode: mode) },
            set: { stored.wrappedValue = $0 }
        )
    }

    /// Role picker tags for the current mode ("None" first under Stacked).
    private var roleOptions: [Int] { SongRequestLimits.rolePickerOptions(for: stackMode) }

    /// Role picker labels for the current mode ("None" / "+N" under Stacked).
    private var roleLabel: (Int) -> String {
        let mode = stackMode
        return { SongRequestLimits.rolePickerLabel($0, mode: mode) }
    }

    /// One labelled per-role limit picker row.
    ///
    /// `selection` must already resolve to one of `options` (see
    /// `everyoneSelection` / `roleSelection(_:)`).
    @ViewBuilder
    private func limitRow(
        _ title: String,
        selection: Binding<Int>,
        options: [Int],
        label: @escaping (Int) -> String = { "\($0)" },
        id: String
    ) -> some View {
        HStack {
            Text(title).font(.system(size: DSFont.Size.body))
            Spacer()
            Picker("\(title) queue limit", selection: selection) {
                ForEach(options, id: \.self) { limit in
                    Text(label(limit)).tag(limit)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 80)
            .accessibilityIdentifier("songRequests.limit.\(id)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            Text("Queue Settings")
                .font(.system(size: DSFont.Size.base, weight: .semibold))

            ToggleSettingRow(
                title: "Fair-Share Ordering",
                subtitle: "Round-robin so everyone's first request plays before anyone's second. Off = classic first-in, first-out.",
                isOn: $fairShare,
                accessibilityLabel: "Fair-share round-robin ordering",
                accessibilityIdentifier: "songRequests.fairShare"
            )

            HStack {
                VStack(alignment: .leading, spacing: DSSpace.s0) {
                    Text("Sub / VIP priority")
                        .font(.system(size: DSFont.Size.body))
                    Text(priorityMode.summary)
                        .font(.system(size: DSFont.Size.xs))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Picker("Sub and VIP request priority", selection: $priorityMode) {
                    ForEach(SongRequestPriorityMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 150)
                .accessibilityIdentifier("songRequests.priorityMode")
            }

            Divider()

            HStack {
                Text("Max queue size").font(.system(size: DSFont.Size.body))
                Spacer()
                Picker(
                    "Max queue size",
                    selection: $maxQueueSize.snapped(
                        to: Self.maxQueueSizeOptions,
                        fallback: AppConstants.UserDefaults.Defaults.songRequestMaxQueueSize)
                ) {
                    ForEach(Self.maxQueueSizeOptions, id: \.self) { size in
                        Text("\(size)").tag(size)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 80)
            }

            Divider()

            VStack(alignment: .leading, spacing: DSSpace.s1h) {
                Text("Per-user limits")
                    .font(.system(size: DSFont.Size.body, weight: .medium))
                Text(stackMode == .stacked
                    ? "How many songs each viewer can have queued at once. Roles add extra slots."
                    : "How many songs each viewer can have queued at once, by role.")
                    .font(.system(size: DSFont.Size.xs))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            limitRow(
                "Everyone",
                selection: everyoneSelection,
                options: SongRequestLimits.roleLimitValues,
                id: "everyone")
            limitRow(
                "Subscribers", selection: roleSelection($subLimit),
                options: roleOptions, label: roleLabel, id: "subscriber")
            limitRow(
                "VIPs", selection: roleSelection($vipLimit),
                options: roleOptions, label: roleLabel, id: "vip")
            limitRow(
                "Moderators", selection: roleSelection($modLimit),
                options: roleOptions, label: roleLabel, id: "moderator")

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: DSSpace.s0) {
                    Text("When a viewer has more than one role")
                        .font(.system(size: DSFont.Size.body))
                    Text(stackMode.summary)
                        .font(.system(size: DSFont.Size.xs))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Picker("How role limits combine", selection: $stackMode) {
                    ForEach(QueueLimitMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 130)
                .accessibilityIdentifier("songRequests.limitStackMode")
            }
        }
        .cardStyle()
    }
}

// MARK: - Access (Who Can Request)

/// Request policy presets (Open, Sub Only, Channel Point Only, Custom), the
/// approval-screening switch, the custom `!sr` audience, and a read-only
/// summary of the paid request paths.
struct SongRequestAccessCard: View {
    /// `!sr` audience; editable only under the Custom preset.
    @AppStorage(AppConstants.UserDefaults.songRequestChatAudience)
    private var audience: RequestAudience = .everyone

    // The active chip is stored explicitly, so observing the mode key is enough
    // to refresh the highlight (and to show/hide the audience dropdown).
    @AppStorage(AppConstants.UserDefaults.songRequestPolicyMode)
    private var policyMode: SongRequestPreset = .open

    // Read-only here: the Channel Points & Bits card is the one place these are
    // switched. Access only summarizes them and links there.
    @AppStorage(AppConstants.UserDefaults.songRequestChannelPointsEnabled)
    private var channelPointsEnabled = false
    @AppStorage(AppConstants.UserDefaults.songRequestBitsEnabled)
    private var bitsEnabled = false

    /// Screening: hold every request for approval before it queues.
    @AppStorage(AppConstants.UserDefaults.songRequestApprovalRequired)
    private var approvalRequired = false

    /// The preset matching the stored settings.
    private var activePreset: SongRequestPreset { SongRequestPreset.current() }

    /// Applies a preset and re-evaluates redemption subscriptions (presets flip
    /// the channel-point / bit toggles, so the managed reward must be reconciled).
    private func apply(_ preset: SongRequestPreset) {
        preset.apply()
        refreshRedemptions()
    }

    /// Reconciles the managed Twitch reward / EventSub subscriptions after a
    /// channel-point or bit toggle changes.
    private func refreshRedemptions() {
        if let service = AppDelegate.shared?.twitchService {
            Task { await service.refreshRedemptionSubscriptions() }
        }
    }

    /// Scrolls the pane to the Channel Points & Bits card and flashes it.
    private func showRedemptions() {
        SettingsNavigation.shared.pending = SettingsDeepLink(pane: .songRequests, section: "redemptions")
    }

    /// "Channel points on · Bits off", the read-only summary of the paid paths.
    private var redemptionSummary: String {
        "Channel points \(channelPointsEnabled ? "on" : "off") · Bits \(bitsEnabled ? "on" : "off")"
    }

    /// One preset chip. Filled when it's the active policy, outlined otherwise.
    @ViewBuilder
    private func presetButton(_ preset: SongRequestPreset) -> some View {
        let isActive = activePreset == preset
        let label = Text(preset.displayName)
            .font(.system(size: DSFont.Size.sm, weight: isActive ? .semibold : .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)

        Group {
            if isActive {
                Button { apply(preset) } label: { label }
                    .buttonStyle(.borderedProminent)
            } else {
                Button { apply(preset) } label: { label }
                    .buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .accessibilityIdentifier("songRequests.preset.\(preset.rawValue)")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            Text("Who Can Request")
                .font(.system(size: DSFont.Size.base, weight: .semibold))

            Text("Pick a preset, or choose Custom to fine-tune who can use the !sr command.")
                .font(.system(size: DSFont.Size.sm))
                .foregroundStyle(.secondary)

            // Preset chips. The active one is filled (borderedProminent) so the
            // current request policy reads at a glance; the rest stay outlined.
            HStack(spacing: DSSpace.s1h) {
                ForEach(SongRequestPreset.allCases) { preset in
                    presetButton(preset)
                }
            }

            HStack(alignment: .top, spacing: DSSpace.s1h) {
                Image(systemName: activePreset == .custom ? "slider.horizontal.3" : "checkmark.circle.fill")
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(activePreset == .custom ? Color.secondary : DSColor.success)
                // Markdown bolds the active preset name (a plain string literal is
                // a LocalizedStringKey, so ** renders).
                Text("**\(activePreset.displayName):** \(activePreset.summary)")
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Screening applies to every request path (chat, points, bits), so it
            // sits above the per-preset controls and shows for all presets.
            Divider()

            ToggleSettingRow(
                title: "Require My Approval",
                subtitle: "New requests wait in the queue above until you approve or decline them.",
                isOn: $approvalRequired,
                accessibilityLabel: "Require approval before requests queue",
                accessibilityIdentifier: "songRequests.access.requireApproval"
            )

            // The audience dropdown is the fine-tune control, so it only appears
            // under Custom. Open is always "everyone"; Sub Only and Channel Point
            // Only are fixed policies.
            if activePreset == .custom {
                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: DSSpace.s0) {
                        Text("!sr command audience").font(.system(size: DSFont.Size.body))
                        Text("Mods and you can always request.")
                            .font(.system(size: DSFont.Size.xs))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Picker("!sr command audience", selection: $audience) {
                        ForEach(RequestAudience.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 170)
                    .accessibilityIdentifier("songRequests.audience")
                }
            }

            Divider()

            // Read-only summary. The toggles live only in Channel Points & Bits,
            // so there is one place to switch them and no two cards to keep in sync.
            HStack(spacing: DSSpace.s2) {
                VStack(alignment: .leading, spacing: DSSpace.s0) {
                    Text("Paid requests").font(.system(size: DSFont.Size.body))
                    Text(redemptionSummary)
                        .font(.system(size: DSFont.Size.xs))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer()
                Button("Channel Points & Bits") { showRedemptions() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Turn channel point and bit requests on or off")
                    .accessibilityHint("Jumps to the Channel Points & Bits settings")
                    .accessibilityIdentifier("songRequests.access.redemptionsLink")
            }
        }
        .cardStyle()
    }
}
