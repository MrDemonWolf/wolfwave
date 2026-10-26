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
    /// Shows feedback while the playlist health probe is in progress.
    @State private var isCheckingPlaylistHealth = false

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
        SettingsPaneScroll {
            SongRequestHeader()
            if playlistStatus != .ok {
                SongRequestHealthBanner(
                    status: playlistStatus,
                    onAction: { await handleHealthAction(playlistStatus) }
                )
            }

            if isCheckingPlaylistHealth {
                LoadingRow(text: "Checking Apple Music playlist…")
            }
            twitchNotice
            if songRequestEnabled && setupComplete {
                SongRequestQueueView()
                    .deepLinkSection("queue")
            }
            SongRequestMasterToggleCard(
                isTwitchConnected: isTwitchConnected,
                setupComplete: setupComplete,
                onSetUp: { openSetup(at: .intro) }
            )

            // Vote-skip works without a request queue, so it stays reachable
            // whether or not song requests are on.
            VoteSkipCard()
                .deepLinkSection("vote-skip")

            // The configuration cards only appear once setup is finished and
            // the feature is on. Apple Music access is handled inside the
            // setup sheet, so there's no inline auth card here anymore.
            if songRequestEnabled && setupComplete {
                VStack(alignment: .leading, spacing: DSSpace.s4) {
                    Text("Request setup")
                        .sectionHeader()
                        .accessibilityAddTraits(.isHeader)
                    SongRequestAccessCard()
                        .deepLinkSection("access")
                    SongRequestCommandsCard(onManageLink: { openSetup(at: .shareLink) })
                        .deepLinkSection("commands")
                    SongRequestRedemptionsCard()
                        .deepLinkSection("redemptions")
                }

                VStack(alignment: .leading, spacing: DSSpace.s4) {
                    Text("Queue behavior")
                        .sectionHeader()
                        .accessibilityAddTraits(.isHeader)
                    SongRequestQueueConfigCard()
                        .deepLinkSection("queue-settings")
                    SongRequestPlaybackCard()
                        .deepLinkSection("playback")
                }

                VStack(alignment: .leading, spacing: DSSpace.s4) {
                    Text("Moderation")
                        .sectionHeader()
                        .accessibilityAddTraits(.isHeader)
                    SongRequestBlocklistCard(
                        blocklistProvider: { appDelegate?.songRequestService?.blocklist })
                        .deepLinkSection("blocklist")
                }
            }
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
    ///
    /// - Parameter forceWait: Wait the full time for Music to see the playlist,
    ///   even when it is already known to be missing ("Check Again").
    private func runHealthCheck(forceWait: Bool = false) async {
        guard !isCheckingPlaylistHealth else { return }
        isCheckingPlaylistHealth = true
        defer { isCheckingPlaylistHealth = false }
        await appDelegate?.songRequestService?.runSetupHealthCheck(forceWait: forceWait)
    }

    /// Routes the health banner's primary action to the right fix: re-grant
    /// Apple Music access inline, re-open the share step, or redo full setup.
    /// Awaited by the banner button, which shows a spinner until it returns.
    private func handleHealthAction(_ status: PlaylistSetupStatus) async {
        switch status {
        case .ok:
            break
        case .musicAccessLost:
            _ = await MusicAuthorization.request()
            await runHealthCheck()
        case .playlistMissing:
            openSetup(at: .intro)
        case .linkUnshared:
            openSetup(at: .shareLink)
        case .playlistNotInMusic:
            // Only the streamer can turn Sync Library on, so the action is to
            // re-probe once they have, waiting for sync to catch up.
            await runHealthCheck(forceWait: true)
        }
    }
}

// MARK: - Health Banner

/// Top-of-pane banner shown when the requests playlist is broken. Pairs the
/// `PlaylistSetupStatus` message with its fix, inside the callout, so the
/// streamer can jump straight to it.
fileprivate struct SongRequestHealthBanner: View {
    /// Current playlist health; the parent only shows this for non-`.ok`.
    let status: PlaylistSetupStatus
    /// Runs the fix for `status` (see `handleHealthAction`). The button shows
    /// a spinner until it returns, so a "Check Again" wait is visible.
    let onAction: () async -> Void

    var body: some View {
        Group {
            if let label = status.actionLabel {
                CalloutBanner(
                    status.bannerMessage ?? "",
                    style: status.isError ? .error : .warning
                ) {
                    AsyncActionButton(
                        title: label,
                        style: .borderedProminent,
                        showsSuccess: false,
                        accessibilityIdentifier: "songRequests.healthBanner.action"
                    ) {
                        await onAction()
                    }
                }
            } else {
                CalloutBanner(
                    status.bannerMessage ?? "",
                    style: status.isError ? .error : .warning
                )
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

            DisclosureGroup("How it works") {
                CalloutBanner(
                "Viewers type **!sr song name** in your Twitch chat. WolfWave finds the song on Apple Music and adds it to the queue. Songs play one by one in your Music.app. No window pops up, it just plays quietly in the background. You stay in control: use **!skip** to jump to the next song, or **!clearqueue** to wipe the queue. Only you and your mods can skip or clear.",
                    title: "How it works",
                    style: .info
                )
            }
            .font(.system(size: DSFont.Size.base))
            .accessibilityIdentifier("songRequests.howItWorks")
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

                // A real bordered button, like the pane's other secondary
                // actions (Manage, Open Stream Widgets). It used to be plain grey
                // text with nothing saying it could be clicked.
                Button("Run Setup Again", systemImage: "arrow.counterclockwise") { onSetUp() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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

// MARK: - Preview

#Preview("Song Request Settings") {
    SongRequestSettingsView()
        .padding()
        .frame(width: 700)
}
