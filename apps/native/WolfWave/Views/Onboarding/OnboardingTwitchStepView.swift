//
//  OnboardingTwitchStepView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-02-06.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Twitch connection step with branded tile, pill CTA, and reused `DeviceCodeView`
/// for the OAuth Device Code flow. Optional, can be skipped from the nav bar.
///
/// All auth and join state lives in the shared `TwitchViewModel`; this view
/// only picks a layout per `integrationState` and forwards button presses.
/// Signing in is two steps: authorize the account, then join a channel.
/// Return in the channel field submits Join, which is why `OnboardingView`
/// drops its Return shortcut for Next on this step.
struct OnboardingTwitchStepView: View {

    // MARK: - Properties

    /// The app-wide Twitch view model (`TwitchViewModel.shared` in production).
    @Bindable var twitchViewModel: TwitchViewModel
    /// Stable owner supplied by the containing Onboarding presentation.
    let oauthOwner: TwitchViewModel.OAuthPresentationOwner

    /// `!song`. Unset reads as off; a fresh install was given `true` at launch.
    @AppStorage(AppConstants.UserDefaults.currentSongCommandEnabled)
    private var currentSongCommandEnabled = AppConstants.UserDefaults.Defaults.currentSongCommandEnabled

    /// `!last`. Same rule as `!song`.
    @AppStorage(AppConstants.UserDefaults.lastSongCommandEnabled)
    private var lastSongCommandEnabled = AppConstants.UserDefaults.Defaults.lastSongCommandEnabled

    // MARK: - Body

    var body: some View {
        OnboardingStepScaffold(
            title: "Answer !song in your Twitch chat",
            description: "Viewers type !song and WolfWave replies with what's playing.",
            icon: {
                BrandTile(
                    background: AnyShapeStyle(AppConstants.Brand.twitch),
                    glowColor: AppConstants.Brand.twitch,
                    glyph: BrandTileGlyph.asset("TwitchLogo")
                )
            },
            extras: {
                VStack(spacing: DSSpace.s5) {
                    Group {
                        if twitchViewModel.isLoadingSavedCredentials {
                            LoadingRow(text: "Loading Twitch account…")
                        } else {
                            switch twitchViewModel.integrationState {
                            case .notConnected:
                                notConnectedContent
                            case .authorizing:
                                authorizingContent
                            case .connected:
                                connectedContent
                            case .error(let message):
                                errorContent(message: message)
                            }
                        }
                    }

                    // Hidden while the device code is up, so that screen has
                    // one job: finish signing in.
                    if !isAuthorizing {
                        commandsCard
                    }
                }
                .motionSafe(.easeInOut(duration: DSMotion.Duration.base), value: stateKey)
            }
        )
        // Load any stored sign-in (so a returning user lands on Connected), and
        // attach the running chat service if the view model has none yet, so
        // Join can actually connect.
        .task {
            await twitchViewModel.loadSavedCredentials()
            if twitchViewModel.twitchService == nil {
                if let appDelegate = AppDelegate.shared {
                    twitchViewModel.twitchService = appDelegate.twitchService
                }
            }
            prefillChannelIfNeeded()
        }
        .onChange(of: twitchViewModel.botUsername) { _, _ in
            prefillChannelIfNeeded()
        }
    }

    // MARK: - States

    /// Signed out: the Connect pill that starts the device-code flow.
    private var notConnectedContent: some View {
        VStack(spacing: DSSpace.s3) {
            PillButton(
                background: AnyShapeStyle(AppConstants.Brand.twitch),
                action: {
                    twitchViewModel.startOAuth(owner: oauthOwner)
                },
                label: {
                    HStack(spacing: 8) {
                        Image("TwitchLogo")
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                            .foregroundStyle(.white)
                        Text("Connect with Twitch")
                    }
                }
            )
            .accessibilityLabel("Connect with Twitch")
            .accessibilityHint("Opens Twitch in your browser to authorize WolfWave")

            Text("Opens Twitch in your browser. Takes about 10 seconds.")
                .font(.system(size: DSFont.Size.sm))
                .foregroundStyle(.secondary)
        }
    }

    /// Device-code flow in progress: the code card (once Twitch has issued one),
    /// a waiting row, and Cancel. Cancel only stops a flow this window owns.
    private var authorizingContent: some View {
        VStack(spacing: 12) {
            if case .waitingForAuth(let code, let uri) = twitchViewModel.authState {
                DeviceCodeView(
                    userCode: code,
                    verificationURI: uri,
                    onCopy: {
                        twitchViewModel.progressMessage = "Code copied"
                    },
                    expiresAt: twitchViewModel.deviceCodeExpiresAt,
                    onRequestNewCode: {
                        twitchViewModel.startOAuth(owner: oauthOwner)
                    }
                )
            }

            HStack(spacing: 12) {
                LoadingRow(text: "Waiting for Twitch\u{2026}")

                Spacer()

                Button("Cancel") {
                    twitchViewModel.requestOAuthCancellation(ifOwnedBy: oauthOwner)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointerCursor()
                .accessibilityLabel("Cancel authorization")
            }
        }
    }

    /// Signed in: the account card, then the channel card.
    private var connectedContent: some View {
        VStack(spacing: DSSpace.s4) {
            accountCard
            channelCard
        }
    }

    /// The "Connected as @bot" identity card with a Sign Out action.
    /// Sign Out clears the stored Twitch credentials, so it is disabled while an
    /// account teardown is already running.
    private var accountCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(DSColor.success)
                    .frame(width: 36, height: 36)
                    .shadow(color: DSColor.success.opacity(0.40), radius: 8, x: 0, y: 4)

                Image(systemName: "checkmark")
                    .font(.system(size: DSFont.Size.lg, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Connected")
                    .sectionEyebrow()

                Text("@\(twitchViewModel.botUsername)")
                    .font(.system(size: DSFont.Size.base, weight: .semibold))
            }

            Spacer()

            Button("Sign Out") {
                Task { @MainActor in
                    await twitchViewModel.clearCredentials()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointerCursor()
            .disabled(twitchViewModel.isAccountTeardownInProgress)
        }
        .padding(DSSpace.s5)
        .cardStyleUnpadded()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Twitch connected as \(twitchViewModel.botUsername).")
    }

    /// Channel name field + Join button so the bot actually joins a chat.
    /// Once joined, collapses to a green "In #channel" confirmation row.
    @ViewBuilder
    private var channelCard: some View {
        VStack(alignment: .leading, spacing: DSSpace.s3) {
            if twitchViewModel.channelConnected {
                HStack(spacing: DSSpace.s2) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DSColor.success)
                        .font(.system(size: DSFont.Size.md))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("In your chat")
                            .sectionEyebrow()
                        Text("#\(twitchViewModel.channelID)")
                            .font(.system(size: DSFont.Size.base, weight: .semibold))
                    }
                    Spacer()
                    Button("Change") {
                        twitchViewModel.leaveChannel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("WolfWave is in channel \(twitchViewModel.channelID).")
            } else {
                Text("Which channel should WolfWave join?")
                    .sectionEyebrow()

                HStack(spacing: DSSpace.s2) {
                    TextField("yourchannel", text: $twitchViewModel.channelID)
                        .font(.system(size: DSFont.Size.base))
                        .textFieldStyle(.roundedBorder)
                        .disabled(twitchViewModel.isConnecting)
                        .accessibilityLabel("Twitch channel name")
                        .accessibilityHint("Enter the channel WolfWave should join")
                        .onSubmit(joinChannelIfPossible)
                        // Twitch logins are lowercase with no surrounding whitespace,
                        // so normalize as the user types. Only a change in the
                        // normalized value marks the draft as edited; rewriting the
                        // field itself re-enters this handler as a no-op.
                        .onChange(of: twitchViewModel.channelID) { oldValue, newValue in
                            let sanitized = newValue.lowercased()
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if sanitized != newValue {
                                twitchViewModel.channelID = sanitized
                            }
                            if oldValue.lowercased()
                                .trimmingCharacters(in: .whitespacesAndNewlines) != sanitized {
                                twitchViewModel.channelDraftChanged()
                            }
                        }

                    Button(action: joinChannelIfPossible) {
                        if twitchViewModel.isConnecting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                        } else {
                            Text("Join")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .pointerCursor()
                    .disabled(joinDisabled)
                }

                channelValidationIndicator
                    .motionSafe(
                        .easeInOut(duration: DSMotion.Duration.base),
                        value: twitchViewModel.channelValidationState)
            }
        }
        .padding(DSSpace.s5)
        .cardStyleUnpadded()
    }

    /// Inline feedback below the channel field mirroring the settings pane.
    /// `.valid` shows nothing because a successful join swaps the whole card
    /// for the "In your chat" row. The `.error` reason is shown inline, not
    /// hidden in a tooltip.
    @ViewBuilder
    private var channelValidationIndicator: some View {
        switch twitchViewModel.channelValidationState {
        case .idle, .valid:
            EmptyView()
        case .validating:
            HStack(spacing: DSSpace.s1) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                Text("Checking the channel\u{2026}")
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.secondary)
            }
        case .invalid:
            HStack(spacing: DSSpace.s1) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(DSColor.error)
                    .font(.system(size: DSFont.Size.sm))
                    .accessibilityHidden(true)
                Text("No Twitch channel by that name. Check the spelling.")
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(DSColor.error)
            }
            .accessibilityElement(children: .combine)
        case .error(let message):
            HStack(alignment: .top, spacing: DSSpace.s1) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DSColor.warning)
                    .font(.system(size: DSFont.Size.sm))
                    .accessibilityHidden(true)
                Text("Couldn't check the channel: \(message)")
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Error-state subview shown when the Twitch device-code flow fails.
    /// Displays a warning icon plus a wrap-friendly explanation message.
    ///
    /// - Parameter message: Localized error string from the auth flow.
    @ViewBuilder
    private func errorContent(message: String) -> some View {
        VStack(spacing: DSSpace.s3) {
            HStack(alignment: .top, spacing: DSSpace.s2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DSColor.warning)
                Text(message)
                    .font(.system(size: DSFont.Size.base))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DSSpace.s4)
            .cardStyleUnpadded()

            Button("Try Again") {
                twitchViewModel.startOAuth(owner: oauthOwner)
            }
            .buttonStyle(.bordered)
            .pointerCursor()
        }
    }

    // MARK: - Chat Commands

    /// The two song commands, on for a fresh install (`FreshInstallDefaults`),
    /// each one tap to turn off. Cooldowns and the rest live in Settings → Twitch.
    private var commandsCard: some View {
        VStack(alignment: .leading, spacing: AppConstants.SettingsUI.cardRowSpacing) {
            Text("Chat commands")
                .sectionEyebrow()

            ToggleSettingRow(
                title: "!song",
                subtitle: "Replies with the song playing now.",
                isOn: $currentSongCommandEnabled,
                accessibilityLabel: "!song command",
                accessibilityIdentifier: "onboardingSongCommandToggle"
            )

            Divider()

            ToggleSettingRow(
                title: "!last",
                subtitle: "Replies with the song before it.",
                isOn: $lastSongCommandEnabled,
                accessibilityLabel: "!last command",
                accessibilityIdentifier: "onboardingLastSongCommandToggle"
            )

            HintRow("Each one runs at most once every \(Self.cooldownSeconds) seconds. More in Settings → Twitch.")
        }
        .padding(DSSpace.s5)
        .cardStyleUnpadded()
    }

    // MARK: - Helpers

    /// The default command cooldown, in whole seconds, for the hint line.
    private static let cooldownSeconds = Int(AppConstants.UserDefaults.Defaults.commandCooldown)

    /// `true` while the device-code flow is on screen.
    private var isAuthorizing: Bool {
        if case .authorizing = twitchViewModel.integrationState { return true }
        return false
    }

    /// Whether the Join button should be disabled (empty channel or busy).
    private var joinDisabled: Bool {
        twitchViewModel.isConnecting
            || twitchViewModel.channelID
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Joins the typed channel if it's non-empty and no join is in flight.
    /// Shared by the Join button and Return in the field.
    private func joinChannelIfPossible() {
        guard !joinDisabled else { return }
        twitchViewModel.joinChannel()
    }

    /// Seeds the channel field with the bot's own login as a sensible default,
    /// so a streamer using one account just clicks Join. Only fills when empty.
    private func prefillChannelIfNeeded() {
        guard twitchViewModel.channelID
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !twitchViewModel.botUsername.isEmpty
        else { return }
        twitchViewModel.channelID = twitchViewModel.botUsername
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        twitchViewModel.channelDraftChanged()
    }

    /// A stable integer per `integrationState` case, ignoring associated values,
    /// so the content animates only when the case changes (not when an error
    /// message's text changes).
    private var stateKey: Int {
        switch twitchViewModel.integrationState {
        case .notConnected: return 0
        case .authorizing: return 1
        case .connected: return 2
        case .error: return 3
        }
    }
}

// MARK: - Previews

#Preview("Not connected") {
    OnboardingTwitchStepView(
        twitchViewModel: TwitchViewModel(),
        oauthOwner: .onboarding(UUID())
    )
        .frame(
            width: AppConstants.OnboardingUI.windowWidth,
            height: AppConstants.OnboardingUI.windowHeight
        )
}
