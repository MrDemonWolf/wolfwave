//
//  SongRequestSettingsView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-04-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import MusicKit
import SwiftUI

/// Settings view for the song request system.
///
/// Decomposed into per-card subviews so each `@AppStorage` change only re-renders one card
/// instead of the whole screen.
///
/// Owns its own centered scroll column (bypassing the shell's `standardDetailScroll`).
/// Until the guided setup has been completed, the master toggle is replaced by a setup
/// call to action; the configuration cards appear only once setup is done and the
/// feature is on. Vote-skip is always visible because it also works without a queue.
struct SongRequestSettingsView: View {
    // MARK: - Properties

    /// Jumps the settings shell to the Twitch pane. Wired by `SettingsView`.
    var openTwitchSettings: () -> Void = {}
    /// Starts the Twitch reconnect from the expired-sign-in notice. Wired by
    /// `SettingsView`; `nil` (previews) leaves the notice as a plain note.
    var reconnectTwitch: (@MainActor () -> Void)?
    /// Master switch; gates the configuration cards.
    @AppStorage(AppConstants.UserDefaults.songRequestEnabled)
    private var songRequestEnabled = false

    /// The setup gate. Until this is true the master toggle is replaced by a
    /// "Set up Song Requests" call to action that launches the guided sheet.
    @AppStorage(AppConstants.UserDefaults.songRequestSetupComplete)
    private var setupComplete = false

    /// Playlist health. Anything other than `.ok` shows the top-of-pane banner.
    @AppStorage(AppConstants.UserDefaults.songRequestPlaylistStatus)
    private var playlistStatus: PlaylistSetupStatus = .ok

    /// Live Twitch connection, from the service and `twitchConnectionStateChanged`.
    @State private var isTwitchConnected = false
    /// Mirrors the Twitch pane's reauth flag so this pane can surface the same
    /// "sign-in expired" warning instead of the calmer "connect" info note.
    @State private var twitchReauthNeeded = DefaultsStore.store.bool(
        forKey: AppConstants.UserDefaults.twitchReauthNeeded)

    /// Drives the guided setup sheet. `setupStartStep` lets the broken-playlist
    /// banner jump straight to the right step (re-share vs full redo).
    @State private var showSetupSheet = false
    /// Step the sheet opens on.
    @State private var setupStartStep: SongRequestSetupViewModel.Step = .intro

    /// The running app delegate (`nil` in previews).
    private var appDelegate: AppDelegate? { AppDelegate.shared }

    // MARK: - Body

    /// One plain scrollable column, matching the Twitch/Discord/Notifications
    /// panes. The explainer + master toggle always show; the rest of the
    /// configuration unfolds below only once the feature is on. (There used to be
    /// a second in-pane side-nav rail here, which read as a confusing nested
    /// sidebar next to the main settings sidebar.)
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.s8) {
                // Broken-playlist banner sits above everything so a "needs setup
                // again" state is the first thing the streamer sees.
                if playlistStatus != .ok {
                    SongRequestHealthBanner(
                        status: playlistStatus,
                        onAction: { handleHealthAction(playlistStatus) }
                    )
                }

                SongRequestHeader()
                twitchNotice
                SongRequestMasterToggleCard(
                    isTwitchConnected: isTwitchConnected,
                    setupComplete: setupComplete,
                    onSetUp: { openSetup(at: .intro) }
                )

                // Vote-skip skips the live Apple Music track even with no request
                // queue, so it stays reachable whether or not song requests are on.
                VoteSkipCard()
                    .deepLinkSection("vote-skip")

                // The configuration cards only appear once setup is finished and
                // the feature is on. Apple Music access is handled inside the
                // setup sheet, so there's no inline auth card here anymore.
                if songRequestEnabled && setupComplete {
                    // The live queue sits up top: it's the thing you check and act
                    // on mid-stream (skip/hold/clear), so it leads. The set-once
                    // configuration cards follow below.
                    SongRequestQueueView()
                        .deepLinkSection("queue")
                    SongRequestAccessCard()
                        .deepLinkSection("access")
                    SongRequestQueueConfigCard()
                        .deepLinkSection("queue-settings")
                    SongRequestPlaybackCard()
                        .deepLinkSection("playback")
                    SongRequestCommandsCard(onManageLink: { openSetup(at: .shareLink) })
                        .deepLinkSection("commands")
                    SongRequestRedemptionsCard()
                        .deepLinkSection("redemptions")
                    SongRequestBlocklistCard(
                        blocklistProvider: { appDelegate?.songRequestService?.blocklist })
                        .deepLinkSection("blocklist")
                }
            }
            .frame(maxWidth: AppConstants.SettingsUI.maxContentWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, AppConstants.SettingsUI.contentPaddingH)
            .padding(.vertical, AppConstants.SettingsUI.contentPaddingV)
        }
        .onAppear {
            refreshTwitchState()
            refreshReauthState()
        }
        .task {
            // Verify the playlist is still present and shared when the pane opens
            // so the banner reflects reality (deleted / un-shared between visits).
            await runHealthCheck()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.twitchConnectionStateChanged)) { notification in
            if let connected = notification.isConnectedFlag {
                updateTwitchState(connected)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.twitchReauthNeededChanged)) { _ in
            refreshReauthState()
        }
        .sheet(isPresented: $showSetupSheet, onDismiss: { Task { await runHealthCheck() } }) {
            SongRequestSetupView(startAt: setupStartStep, openTwitchSettings: openTwitchSettings)
        }
    }

    /// Shown when Twitch isn't ready. An expired sign-in gets the orange warning
    /// (matching the Twitch pane); a never-connected state gets the calm info
    /// note. Hidden once connected (the master toggle stays disabled until then
    /// via `SongRequestMasterToggleCard`).
    private var twitchNotice: some View {
        TwitchConnectionNotice(
            isConnected: isTwitchConnected,
            reauthNeeded: twitchReauthNeeded,
            expiredMessage: "Song requests are paused until you reconnect.",
            disconnectedMessage: "Connect with Twitch to enable song requests.",
            onReconnect: reconnectTwitch
        )
    }

    /// Reloads the reauth flag from the shared `UserDefaults` key the Twitch view
    /// model writes, so the notice flips to the warning style the moment the
    /// token expires (or back once it's renewed).
    private func refreshReauthState() {
        twitchReauthNeeded = DefaultsStore.store.bool(
            forKey: AppConstants.UserDefaults.twitchReauthNeeded)
    }

    /// Refreshes the Twitch-connected flag from the live service so the
    /// song-request UI accurately reflects whether requests can flow in.
    private func refreshTwitchState() {
        updateTwitchState(appDelegate?.twitchService?.currentlyConnected ?? false)
    }

    /// Updates `isTwitchConnected`. Deliberately does NOT flip the persisted
    /// `songRequestEnabled` setting on disconnect: a transient drop (network
    /// blip, the service's own reconnect cycle) used to permanently turn the
    /// feature off, forcing the streamer to re-enable it by hand after every
    /// hiccup. The `twitchNotice` warning plus the master toggle's disabled
    /// state already communicate that requests can't flow while disconnected,
    /// and the feature resumes on its own once Twitch reconnects.
    ///
    /// - Parameter connected: New Twitch connection state.
    private func updateTwitchState(_ connected: Bool) {
        isTwitchConnected = connected
    }

    /// Opens the guided setup sheet at the given step.
    private func openSetup(at step: SongRequestSetupViewModel.Step) {
        setupStartStep = step
        showSetupSheet = true
    }

    /// Re-checks playlist health via the live service so the banner stays honest.
    private func runHealthCheck() async {
        await appDelegate?.songRequestService?.runSetupHealthCheck()
    }

    /// Routes the health banner's primary action to the right fix: re-grant
    /// Apple Music access inline, re-open the share step, or redo full setup.
    private func handleHealthAction(_ status: PlaylistSetupStatus) {
        switch status {
        case .ok:
            break
        case .musicAccessLost:
            Task {
                _ = await MusicAuthorization.request()
                await runHealthCheck()
            }
        case .playlistMissing:
            openSetup(at: .intro)
        case .linkUnshared:
            openSetup(at: .shareLink)
        case .playlistNotInMusic:
            // Only the streamer can turn Sync Library on, so the action is simply
            // to re-probe once they have.
            Task { await runHealthCheck() }
        }
    }
}

// MARK: - Health Banner

/// Top-of-pane banner shown when the requests playlist is broken. Pairs the
/// `PlaylistSetupStatus` message with a primary action button (CalloutBanner is
/// text-only), so the streamer can jump straight to the fix.
fileprivate struct SongRequestHealthBanner: View {
    /// Current playlist health; the parent only shows this for non-`.ok`.
    let status: PlaylistSetupStatus
    /// Runs the fix for `status` (see `handleHealthAction`).
    let onAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s2) {
            CalloutBanner(
                status.bannerMessage ?? "",
                style: status.isError ? .error : .warning
            )
            if let label = status.actionLabel {
                Button(label) { onAction() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("songRequests.healthBanner.action")
            }
        }
        .accessibilityIdentifier("songRequests.healthBanner")
    }
}

// MARK: - Header

/// Pane title plus the "How it works" explainer.
fileprivate struct SongRequestHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s1h) {
            SectionHeaderWithStatus(
                title: "Song Requests",
                subtitle: "Let your Twitch viewers request songs via chat commands.",
                statusText: "Twitch",
                statusColor: .purple
            )
            .accessibilityAddTraits(.isHeader)

            CalloutBanner(
                "Viewers type **!sr song name** in your Twitch chat. WolfWave finds the song on Apple Music and adds it to the queue. Songs play one by one in your Music.app. No window pops up, it just plays quietly in the background. You stay in control: use **!skip** to jump to the next song, or **!clearqueue** to wipe the queue. Only you and your mods can skip or clear.",
                title: "How it works",
                style: .info
            )
        }
        // `.contain`, not `.combine`: VoiceOver reaches the heading and the
        // "How it works" callout as separate elements instead of one long
        // label that hid the callout entirely.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("songRequests.header")
    }
}

// MARK: - Master Toggle

/// The enable switch (or, before setup, the setup call to action) plus the
/// "Reply When Off" option. Both the switch and the setup button are disabled
/// until Twitch is connected.
fileprivate struct SongRequestMasterToggleCard: View {
    /// Master switch. Changes post `songRequestSettingChanged`.
    @AppStorage(AppConstants.UserDefaults.songRequestEnabled)
    private var songRequestEnabled = false

    // Lives here, not in the commands card, so it stays reachable when the
    // feature is off, which is exactly when it takes effect.
    @AppStorage(AppConstants.UserDefaults.songRequestDisabledReplyEnabled)
    private var disabledReplyEnabled = false

    /// Disables enabling (or starting setup) while Twitch is offline.
    let isTwitchConnected: Bool
    /// When false, the enable toggle is replaced by a "Set up" call to action.
    let setupComplete: Bool
    /// Launches the guided setup sheet.
    let onSetUp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            if setupComplete {
                ToggleSettingRow(
                    title: "Enable Song Requests",
                    subtitle: "Viewers can request songs with !sr in Twitch chat",
                    isOn: $songRequestEnabled,
                    isDisabled: !isTwitchConnected,
                    accessibilityLabel: "Enable song requests",
                    accessibilityIdentifier: "songRequests.enableToggle",
                    onChange: { enabled in
                        NotificationCenter.default.postEnabled(.songRequestSettingChanged, enabled: enabled)
                    }
                )

                Button("Re-run setup") { onSetUp() }
                    .buttonStyle(.plain)
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.secondary)
                    .pointerCursor()
                    .accessibilityIdentifier("songRequests.rerunSetup")
            } else {
                VStack(alignment: .leading, spacing: DSSpace.s3) {
                    HStack(spacing: DSSpace.s3) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: DSFont.Size.x2xl))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: DSSpace.s0) {
                            Text("Set up Song Requests")
                                .font(.system(size: DSFont.Size.base, weight: .semibold))
                            Text("A quick guided setup. About a minute.")
                                .font(.system(size: DSFont.Size.sm))
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: DSSpace.s1) {
                        setupChecklistItem("Connect Twitch")
                        setupChecklistItem("Allow Apple Music access")
                        setupChecklistItem("Create your requests playlist")
                    }

                    Button("Set Up Song Requests") { onSetUp() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(!isTwitchConnected)
                        .pointerCursor()
                        .accessibilityIdentifier("songRequests.setUp")
                }
            }

            Divider()

            ToggleSettingRow(
                title: "Reply When Off",
                subtitle: "Tell chat \u{201C}Song requests are off right now.\u{201D} when someone uses !sr while the feature is off. Default: stay silent.",
                isOn: $disabledReplyEnabled,
                accessibilityLabel: "Reply when song requests are off",
                accessibilityIdentifier: "songRequests.disabledReply"
            )
        }
        .cardStyle()
    }

    /// One "what you'll set up" bullet in the pre-setup call to action.
    @ViewBuilder
    private func setupChecklistItem(_ text: String) -> some View {
        HStack(spacing: DSSpace.s2) {
            Image(systemName: "circle.dashed")
                .font(.system(size: DSFont.Size.sm))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: DSFont.Size.sm))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Chat Vote-Skip

/// Chat vote-to-skip settings: chat tally (window + cooldown) or Twitch Polls
/// (duration), minimum votes, subscriber-only voting, and the `!voteskip`
/// command. Every picker reads through `snapped(to:fallback:)` / `clamped`.
fileprivate struct VoteSkipCard: View {
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
                    accessibilityIdentifier: "voteSkip.usePolls"
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

                    HintRow("Turning this on may ask you to sign in to Twitch again to grant poll permission.")
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

// MARK: - Queue Config

/// Ordering (fair share, Sub/VIP priority), max queue size, and per-role
/// request limits with how they combine for multi-role viewers.
fileprivate struct SongRequestQueueConfigCard: View {
    /// Total queue capacity.
    @AppStorage(AppConstants.UserDefaults.songRequestMaxQueueSize)
    private var maxQueueSize = AppConstants.UserDefaults.Defaults.songRequestMaxQueueSize

    // Per-role limits. "Everyone" reuses the original per-user-limit key so
    // existing setups keep their value.
    @AppStorage(AppConstants.UserDefaults.songRequestPerUserLimit)
    private var everyoneLimit = AppConstants.UserDefaults.Defaults.songRequestPerUserLimit
    @AppStorage(AppConstants.UserDefaults.songRequestLimitSubscriber)
    private var subLimit = 2
    @AppStorage(AppConstants.UserDefaults.songRequestLimitVIP)
    private var vipLimit = 2
    @AppStorage(AppConstants.UserDefaults.songRequestLimitModerator)
    private var modLimit = 2

    /// How limits combine when a viewer holds several roles.
    @AppStorage(AppConstants.UserDefaults.songRequestLimitStackMode)
    private var stackMode: QueueLimitMode = .highest

    /// Round-robin by requester instead of plain FIFO.
    @AppStorage(AppConstants.UserDefaults.songRequestFairShare)
    private var fairShare = AppConstants.UserDefaults.Defaults.songRequestFairShare

    /// Sub/VIP priority perk.
    @AppStorage(AppConstants.UserDefaults.songRequestPriorityMode)
    private var priorityMode: SongRequestPriorityMode = .off

    /// Allowed per-role limits (picker tags and snap set).
    private let limitOptions = [1, 2, 3, 5, 10, 15, 20]
    /// Allowed max queue sizes (picker tags and snap set).
    fileprivate static let maxQueueSizeOptions = [5, 10, 15, 20, 25, 50]

    /// One labelled per-role limit stepper row.
    ///
    /// Snaps the selection so a stored value outside `limitOptions` renders as
    /// `fallback` rather than reaching the picker with no matching tag.
    @ViewBuilder
    private func limitRow(
        _ title: String,
        selection: Binding<Int>,
        fallback: Int,
        id: String
    ) -> some View {
        HStack {
            Text(title).font(.system(size: DSFont.Size.body))
            Spacer()
            Picker("\(title) queue limit", selection: selection.snapped(to: limitOptions, fallback: fallback)) {
                ForEach(limitOptions, id: \.self) { limit in
                    Text("\(limit)").tag(limit)
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
                Text("How many songs each viewer can have queued at once, by role.")
                    .font(.system(size: DSFont.Size.xs))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            limitRow(
                "Everyone",
                selection: $everyoneLimit,
                fallback: AppConstants.UserDefaults.Defaults.songRequestPerUserLimit,
                id: "everyone")
            limitRow("Subscribers", selection: $subLimit, fallback: 2, id: "subscriber")
            limitRow("VIPs", selection: $vipLimit, fallback: 2, id: "vip")
            limitRow("Moderators", selection: $modLimit, fallback: 2, id: "moderator")

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
fileprivate struct SongRequestAccessCard: View {
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

// MARK: - Redemptions (Channel Points & Bits)

/// The one place channel-point and Bits requests are switched on: reward cost,
/// reward repair, minimum Bits, and the boost option. Every change asks the
/// Twitch service to reconcile the managed reward and EventSub subscriptions.
fileprivate struct SongRequestRedemptionsCard: View {
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

// MARK: - Playback

/// Hold, auto-advance, autoplay-when-empty, and the fallback playlist.
fileprivate struct SongRequestPlaybackCard: View {
    /// Play the next request when a song ends. Changes ask the service to
    /// start or stop its playback monitor.
    @AppStorage(AppConstants.UserDefaults.songRequestAutoAdvance)
    private var autoAdvance = true

    /// Hand back to Apple Music autoplay when the queue runs dry.
    @AppStorage(AppConstants.UserDefaults.songRequestAutoplayWhenEmpty)
    private var autoplayWhenEmpty = true

    /// Exact Music playlist name to play when the queue is empty; blank = silence.
    @AppStorage(AppConstants.UserDefaults.songRequestFallbackPlaylist)
    private var fallbackPlaylist = ""

    /// Hold mode. Mirrors the queue view's Hold / Resume; changes go through
    /// `SongRequestService.setHold(_:)`.
    @AppStorage(AppConstants.UserDefaults.songRequestHoldEnabled)
    private var holdEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            Text("Playback")
                .font(.system(size: DSFont.Size.base, weight: .semibold))

            ToggleSettingRow(
                title: "Hold Queue",
                subtitle: "Requests still queue, but nothing plays until you resume",
                isOn: $holdEnabled,
                accessibilityLabel: "Hold the request queue",
                accessibilityIdentifier: "songRequests.holdEnabled",
                onChange: { enabled in
                    if let service = AppDelegate.shared?.songRequestService {
                        Task { await service.setHold(enabled) }
                    }
                }
            )

            ToggleSettingRow(
                title: "Auto-Advance Queue",
                subtitle: "Automatically play the next request when a song ends",
                isOn: $autoAdvance,
                accessibilityLabel: "Auto-advance queue",
                accessibilityIdentifier: "songRequests.autoAdvance",
                onChange: { _ in
                    AppDelegate.shared?.songRequestService?.reconcilePlaybackMonitoring()
                }
            )

            ToggleSettingRow(
                title: "Resume Autoplay When Empty",
                subtitle: "Let Apple Music's autoplay take over when the queue is empty",
                isOn: $autoplayWhenEmpty,
                accessibilityLabel: "Resume autoplay when queue is empty",
                accessibilityIdentifier: "songRequests.autoplayWhenEmpty"
            )

            Divider()

            VStack(alignment: .leading, spacing: DSSpace.s1h) {
                Text("Fallback playlist")
                    .font(.system(size: DSFont.Size.body, weight: .medium))
                TextField("e.g. Gaming Vibes", text: $fallbackPlaylist)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: DSFont.Size.body))
                VStack(alignment: .leading, spacing: DSSpace.s0) {
                    Text("Plays an Apple Music playlist when the queue is empty.")
                    Text("Type the playlist name exactly as it appears in Music.")
                    Text("Leave blank for silence.")
                }
                .font(.system(size: DSFont.Size.xs))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardStyle()
    }
}

// MARK: - Commands

/// Per-command switches and aliases for the song-request chat commands, the
/// `!sr` cooldowns, and the `!playlist` link status.
fileprivate struct SongRequestCommandsCard: View {
    // Command switches (all default on except `!playlist`).
    @AppStorage(AppConstants.UserDefaults.srCommandEnabled) private var srCommandEnabled = true
    @AppStorage(AppConstants.UserDefaults.queueCommandEnabled) private var queueCommandEnabled = true
    @AppStorage(AppConstants.UserDefaults.myQueueCommandEnabled) private var myQueueCommandEnabled = true
    @AppStorage(AppConstants.UserDefaults.skipCommandEnabled) private var skipCommandEnabled = true
    @AppStorage(AppConstants.UserDefaults.clearQueueCommandEnabled) private var clearQueueCommandEnabled = true

    // Comma-separated extra triggers per command.
    @AppStorage(AppConstants.UserDefaults.srCommandAliases) private var srAliases = ""
    @AppStorage(AppConstants.UserDefaults.queueCommandAliases) private var queueAliases = ""
    @AppStorage(AppConstants.UserDefaults.myQueueCommandAliases) private var myQueueAliases = ""
    @AppStorage(AppConstants.UserDefaults.skipCommandAliases) private var skipAliases = ""
    @AppStorage(AppConstants.UserDefaults.clearQueueCommandAliases) private var clearQueueAliases = ""

    // `!sr` cooldowns, in seconds: channel-wide and per viewer.
    @AppStorage(AppConstants.UserDefaults.songRequestGlobalCooldown) private var globalCooldown: Double = 5.0
    @AppStorage(AppConstants.UserDefaults.songRequestUserCooldown) private var userCooldown: Double = 30.0

    // `!playlist` switch, aliases, and the public link it shares.
    @AppStorage(AppConstants.UserDefaults.songListCommandEnabled) private var songListCommandEnabled = false
    @AppStorage(AppConstants.UserDefaults.songListCommandAliases) private var songListAliases = ""
    @AppStorage(AppConstants.UserDefaults.songRequestSongListURL) private var songListURL = ""

    /// Opens the setup sheet's share step so the streamer can (re)configure the
    /// public !playlist link without leaving the pane.
    let onManageLink: () -> Void

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s6) {
            SectionHeaderWithStatus(
                title: "Song Request Commands",
                subtitle: "Toggle commands on/off and add custom aliases (comma-separated, without !).",
                prominence: .section
            )

            VStack(spacing: 1) {
                CommandSettingRow(
                    title: "!sr Command",
                    triggers: "!sr  ·  !request  ·  !songrequest",
                    isOn: $srCommandEnabled,
                    accessibilityLabel: "Enable song request command",
                    accessibilityIdentifier: "srCommandToggle",
                    cooldown: .init(global: $globalCooldown, user: $userCooldown),
                    aliases: $srAliases,
                    aliasPlaceholder: "e.g. play, add",
                    aliasAccessibilityIdentifier: "srCommandAliases"
                )

                CommandSettingRow(
                    title: "!queue Command",
                    triggers: "!queue  ·  !songlist  ·  !requests",
                    isOn: $queueCommandEnabled,
                    accessibilityLabel: "Enable queue command",
                    accessibilityIdentifier: "queueCommandToggle",
                    aliases: $queueAliases,
                    aliasPlaceholder: "e.g. q, upnext",
                    aliasAccessibilityIdentifier: "queueCommandAliases"
                )

                CommandSettingRow(
                    title: "!myqueue Command",
                    triggers: "!myqueue  ·  !mysongs",
                    isOn: $myQueueCommandEnabled,
                    accessibilityLabel: "Enable my queue command",
                    accessibilityIdentifier: "myQueueCommandToggle",
                    aliases: $myQueueAliases,
                    aliasPlaceholder: "e.g. mine, mysr",
                    aliasAccessibilityIdentifier: "myQueueCommandAliases"
                )

                CommandSettingRow(
                    title: "!skip Command",
                    triggers: "!skip  ·  !next  (mod only)",
                    isOn: $skipCommandEnabled,
                    accessibilityLabel: "Enable skip command",
                    accessibilityIdentifier: "skipCommandToggle",
                    aliases: $skipAliases,
                    aliasPlaceholder: "e.g. nextsong, ns",
                    aliasAccessibilityIdentifier: "skipCommandAliases"
                )

                CommandSettingRow(
                    title: "!clearqueue Command",
                    triggers: "!clearqueue  ·  !cq  (mod only)",
                    isOn: $clearQueueCommandEnabled,
                    accessibilityLabel: "Enable clear queue command",
                    accessibilityIdentifier: "clearQueueCommandToggle",
                    aliases: $clearQueueAliases,
                    aliasPlaceholder: "e.g. wipe, clearsr",
                    aliasAccessibilityIdentifier: "clearQueueCommandAliases"
                )

                CommandSettingRow(
                    title: "!playlist Command",
                    triggers: "!playlist  ·  links your request playlist",
                    isOn: $songListCommandEnabled,
                    accessibilityLabel: "Enable playlist link command",
                    accessibilityIdentifier: "songListCommandToggle",
                    aliases: $songListAliases,
                    aliasPlaceholder: "e.g. list, amplaylist",
                    aliasAccessibilityIdentifier: "songListCommandAliases",
                    isLast: true
                )
            }
            .cardStyleUnpadded()

            // Slim song-list link status. The full guided flow (open in Music,
            // share, fetch the link) now lives in the setup sheet; this row just
            // shows whether a link is set and offers a way back into that step.
            VStack(alignment: .leading, spacing: DSSpace.s2) {
                HStack {
                    Text("Song list link")
                        .font(.system(size: DSFont.Size.body, weight: .medium))
                    Spacer()
                    songListLinkChip
                    Button("Manage") { onManageLink() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("songRequests.manageSongList")
                }

                Text("!playlist drops a link to your requests playlist in chat. Set it up in the guided steps.")
                    .font(.system(size: DSFont.Size.xs))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HintRow("Cooldowns don't apply to you or your mods.")
        }
    }

    /// Song-list link status. "Ready" only for a link `!playlist` will
    /// actually post: `Preferences.songListURL` drops anything that doesn't
    /// normalize through `normalizedHTTPSURL`, so this chip does too.
    @ViewBuilder
    private var songListLinkChip: some View {
        let trimmed = songListURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            StatusChip(text: "Needs setup", color: DSColor.neutral, systemImage: StatusChip.StateGlyph.off)
        } else if Preferences.normalizedHTTPSURL(trimmed) == nil {
            StatusChip(text: "Invalid link", color: DSColor.warning, systemImage: StatusChip.StateGlyph.error)
        } else {
            StatusChip(text: "Ready", color: DSColor.success, systemImage: StatusChip.StateGlyph.on)
        }
    }
}

// MARK: - Blocklist

/// Add / remove / clear blocklist entries (song, artist, or requester).
/// The list is an `@State` copy of the actor-owned `SongBlocklist`, re-read
/// after every mutation.
fileprivate struct SongRequestBlocklistCard: View {
    /// Resolves the live blocklist on each use, so a service restarted under
    /// the pane is picked up. `nil` (no service) makes every action a no-op.
    let blocklistProvider: () -> SongBlocklist?

    /// Text being typed for a new entry.
    @State private var blocklistText = ""
    /// Kind of entry the next Add creates.
    @State private var blocklistType: BlocklistItem.BlockType = .song
    /// Snapshot of the blocklist for display.
    @State private var blocklist: [BlocklistItem] = []
    /// Presents the Clear All confirmation.
    @State private var showClearAllAlert = false

    /// Field placeholder for the selected entry type.
    private var blocklistPlaceholder: String {
        switch blocklistType {
        case .song: "Song title..."
        case .artist: "Artist name..."
        case .requester: "Twitch username..."
        }
    }

    /// Row glyph for an entry type.
    private static func blocklistSymbol(for type: BlocklistItem.BlockType) -> String {
        switch type {
        case .song: "music.note"
        case .artist: "person.fill"
        case .requester: "person.slash.fill"
        }
    }

    /// Adds the typed value as the selected entry type. Shared by the Add
    /// button and Return in the text field, so both paths behave the same.
    private func addEntry() async {
        let trimmed = blocklistText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let item = BlocklistItem(value: trimmed, type: blocklistType)
        let provider = blocklistProvider()
        blocklistText = ""
        await provider?.add(item)
        blocklist = await provider?.allEntries ?? []
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            HStack {
                Text("Blocklist")
                    .font(.system(size: DSFont.Size.base, weight: .semibold))

                Spacer()

                Button(role: .destructive) {
                    showClearAllAlert = true
                } label: {
                    Label("Clear All", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(blocklist.isEmpty)
                .accessibilityIdentifier("blocklist.clearAll")
            }

            Text("Block specific songs, artists, or people from being requested.")
                .font(.system(size: DSFont.Size.sm))
                .foregroundStyle(.secondary)

            HStack(spacing: DSSpace.s2) {
                Picker("Blocklist entry type", selection: $blocklistType) {
                    Text("Song").tag(BlocklistItem.BlockType.song)
                    Text("Artist").tag(BlocklistItem.BlockType.artist)
                    Text("Person").tag(BlocklistItem.BlockType.requester)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)

                TextField(blocklistPlaceholder, text: $blocklistText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: DSFont.Size.body))
                    .onSubmit { Task { await addEntry() } }
                    .accessibilityLabel("Blocklist entry")
                    .accessibilityIdentifier("songRequests.blocklist.field")

                AsyncActionButton(
                    title: "Add",
                    style: .borderedProminent,
                    isDisabled: blocklistText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    showsSuccess: false,
                    accessibilityIdentifier: "songRequests.blocklist.add"
                ) {
                    await addEntry()
                }
            }

            if !blocklist.isEmpty {
                VStack(alignment: .leading, spacing: DSSpace.s1) {
                    ForEach(blocklist) { item in
                        HStack {
                            Image(systemName: Self.blocklistSymbol(for: item.type))
                                .font(.system(size: DSFont.Size.xs))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)

                            Text(item.value).font(.system(size: DSFont.Size.body))

                            Text(item.type.displayName)
                                .font(.system(size: DSFont.Size.xs))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, DSSpace.s2)
                                .padding(.vertical, DSSpace.s0)
                                .background(.quaternary)
                                .clipShape(Capsule())

                            Spacer()

                            DSIconButton(
                                systemImage: "xmark",
                                action: {
                                    let provider = blocklistProvider()
                                    Task {
                                        await provider?.remove(id: item.id)
                                        blocklist = await provider?.allEntries ?? []
                                    }
                                },
                                accessibilityLabel: "Remove \(item.value) from blocklist",
                                accessibilityIdentifier: "songRequests.blocklist.remove"
                            )
                            .help("Remove from blocklist")
                        }
                        .padding(.vertical, DSSpace.s0)
                    }
                }
                .padding(.top, DSSpace.s1)
            }
        }
        .cardStyle()
        .task {
            blocklist = await blocklistProvider()?.allEntries ?? []
        }
        .alert("Clear blocklist?", isPresented: $showClearAllAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                let provider = blocklistProvider()
                Task {
                    await provider?.clearAll()
                    blocklist = await provider?.allEntries ?? []
                }
            }
        } message: {
            Text("This removes every entry from your song-request blocklist. This cannot be undone.")
        }
    }
}

// MARK: - Preview

#Preview("Song Request Settings") {
    SongRequestSettingsView()
        .padding()
        .frame(width: 700)
}
