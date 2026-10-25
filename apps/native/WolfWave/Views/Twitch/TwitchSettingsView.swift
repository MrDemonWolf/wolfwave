//
//  TwitchSettingsView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-01-08.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

// MARK: - Twitch Settings View

/// Settings panel for Twitch bot auth, channel connection, and account management.
///
/// Switches between sign-in, authorizing, connected, and error states
/// driven by ``TwitchViewModel/integrationState``. Failures render once, in an
/// ``ErrorCallout`` above the auth card, whose actions this view maps back
/// onto the view model (reconnect, retry, report, docs).
///
/// Leaving the pane (`onDisappear`) cancels a pending re-auth and any OAuth
/// flow this Settings presentation owns.
struct TwitchSettingsView: View {
    // MARK: - Properties

    /// The shared Twitch state manager driving this view.
    @Bindable var viewModel: TwitchViewModel
    /// Stable owner supplied by the containing Settings presentation.
    let oauthOwner: TwitchViewModel.OAuthPresentationOwner
    /// Whether the one-time keychain + service wiring has run for this view model instance.
    @State private var didLoadCredentials = false
    /// Owns re-authentication teardown so closing Settings cannot start OAuth later.
    @State private var reauthTask: Task<Void, Never>?
    /// Global "commands only while live" switch. Applies to every chat command.
    @AppStorage(AppConstants.UserDefaults.commandsLiveOnly)
    private var commandsLiveOnly = false

    /// Collapses card and status transitions under Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: AppConstants.SettingsUI.sectionSpacing) {
            headerView

            connectionStatus
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.base),
                    value: viewModel.connectionError)

            authCard
                .deepLinkSection("account")
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(
                    reduceMotion ? nil : DSMotion.Spring.snappy,
                    value: (viewModel.credentialsSaved || viewModel.channelConnected
                        || viewModel.authState.isInProgress))

            chatCommandsCard
                .deepLinkSection("live-only")
        }
        .onAppear {
            // Keychain reads + AppDelegate wiring run once per view model instance.
            // Re-entering the Twitch settings pane shouldn't repeat them. TwitchViewModel
            // is owned by the parent SettingsView and survives section switches.
            guard !didLoadCredentials else { return }
            didLoadCredentials = true

            // Defer the @Observable mutations past the current SwiftUI view-update
            // tick. Mutating `botUsername`, `oauthToken`, `credentialsSaved`,
            // `channelID`, `reauthNeeded`, `channelConnected` inline during
            // `onAppear` re-invalidates the header + auth-card body that already
            // depend on them, which races AppKit layout and triggers the
            // `layoutSubtreeIfNeeded on a view which is already being laid out`
            // recursion that has been associated with the post-onboarding hang.
            Task { @MainActor in
                Log.debug("TwitchSettingsView: onAppear first-mount, loading credentials", category: .twitch)
                viewModel.loadSavedCredentials()

                if viewModel.twitchService == nil {
                    if let appDelegate = AppDelegate.shared {
                        viewModel.twitchService = appDelegate.twitchService
                        if viewModel.twitchService == nil {
                            Log.error(
                                "TwitchSettingsView: AppDelegate.twitchService is nil!",
                                category: .twitch)
                        }
                    } else {
                        Log.error("TwitchSettingsView: AppDelegate.shared is nil", category: .twitch)
                    }
                }

                if let svc = viewModel.twitchService {
                    viewModel.channelConnected = svc.currentlyConnected
                }

                if viewModel.reauthNeeded && viewModel.channelConnected {
                    viewModel.leaveChannel()
                }
            }
        }
        .onDisappear {
            reauthTask?.cancel()
            reauthTask = nil
            viewModel.requestOAuthCancellation(ifOwnedBy: oauthOwner)
        }
    }

    // MARK: - Subviews

    /// Section header showing "Twitch" title, subtitle, and a colored status chip.
    private var headerView: some View {
        SectionHeaderWithStatus(
            title: "Twitch",
            subtitle: "Let people use chat commands to see what's playing.",
            statusText: viewModel.statusChipText,
            statusColor: viewModel.statusChipColor
        )
    }

    /// Global "commands only while live" switch. Applies to every chat command
    /// (`!song`, `!last`, `!stats`, `!sr`, `!queue`, …) in one place.
    private var chatCommandsCard: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            CardEyebrowHeader("Chat commands", systemImage: "bubble.left.and.bubble.right")

            ToggleSettingRow(
                title: "Only reply while live",
                subtitle: commandsLiveOnly
                    ? "Every chat command stays quiet until you go live."
                    : "Chat commands reply anytime, live or not.",
                isOn: $commandsLiveOnly,
                accessibilityLabel: "Toggle replying to chat commands only while live",
                accessibilityIdentifier: "commandsLiveOnlyToggle"
            )
        }
        .padding(AppConstants.SettingsUI.cardPadding)
        .cardStyleUnpadded()
    }

    /// Title text for the auth card header, adapts to reauth/signed-in/signed-out states.
    private var authCardHeaderTitle: String {
        if viewModel.reauthNeeded {
            return "Sign in again"
        } else if viewModel.credentialsSaved && viewModel.botUsername != "" {
            return "All set"
        } else if viewModel.authState.isInProgress {
            return "Authorize WolfWave with Twitch"
        } else {
            return "Connect WolfWave to your Twitch account"
        }
    }

    /// Subtitle text for the auth card header with a short call-to-action.
    private var authCardHeaderSubtitle: String {
        if viewModel.reauthNeeded {
            return "Your sign-in expired. Reconnect to keep chat commands working."
        } else if viewModel.credentialsSaved && viewModel.botUsername != "" {
            return ""
        } else if viewModel.authState.isInProgress {
            return "Enter the code below at twitch.tv/activate to finish signing in."
        } else {
            return "Sign in so WolfWave can post chat commands and read redemptions."
        }
    }

    /// The modelled failure and in-flight progress, rendered above the auth
    /// card so both are visible in every integration state.
    ///
    /// This is the surface the old `statusMessage` claimed to have and never
    /// did: roughly forty failure messages were written to a property no view
    /// read, so a failed join or a Keychain write error showed the user nothing.
    @ViewBuilder
    private var connectionStatus: some View {
        if let error = viewModel.connectionError {
            ErrorCallout(error: error) { action in
                switch action {
                case .reconnectTwitch:
                    viewModel.connectionError = nil
                    viewModel.startOAuth(owner: oauthOwner)
                case .retry:
                    viewModel.connectionError = nil
                    retry(TwitchViewModel.retryTarget(for: error))
                case .reportBug:
                    BugReportURL.openPrefilledIssue()
                case .openDocs(let anchor):
                    ExternalLink.open("\(AppConstants.URLs.docs)/docs/troubleshooting#\(anchor)")
                default:
                    viewModel.connectionError = nil
                }
            }
        } else if !viewModel.progressMessage.isEmpty, !viewModel.authState.isInProgress {
            // While signing in, the auth card's own status row carries this
            // text, so it isn't shown twice.
            LoadingRow(text: viewModel.progressMessage)
                .accessibilityIdentifier("twitch-settings.progress")
        }
    }

    /// Re-runs whatever the failed banner was about.
    private func retry(_ target: TwitchViewModel.RetryTarget) {
        switch target {
        case .signIn:
            viewModel.startOAuth(owner: oauthOwner)
        case .signOut:
            Task { @MainActor in await viewModel.clearCredentials() }
        case .joinChannel:
            viewModel.joinChannel()
        }
    }

    /// Whether the auth card shows the signed-in controls. A failure while
    /// still signed in (a sign-out that didn't finish) keeps them; the error
    /// banner above explains it.
    private var showsSignedInCard: Bool {
        switch viewModel.integrationState {
        case .connected: true
        case .error: viewModel.credentialsSaved
        case .notConnected, .authorizing: false
        }
    }

    /// The signed-in card.
    ///
    /// `SignedInView` is already a full card (own header rows + single
    /// border). Wrapping it in the outer `.cardStyle()` shell would draw
    /// a second outline around it, so the connected state stands alone
    /// with one outline, matching the Bot Commands cards below.
    private var signedInCard: some View {
        connectedContent
            .animation(reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.base), value: viewModel.integrationState)
    }

    /// Main card that switches content based on integration state.
    ///
    /// Shows one of: sign-in button, device-code flow, or connected controls.
    /// After a failure it shows the sign-in button again; the reason itself
    /// renders once, in ``connectionStatus``.
    @ViewBuilder
    private var authCard: some View {
        // One branch for both signed-in shapes, so moving between them keeps
        // the card's identity instead of swapping views.
        if showsSignedInCard {
            signedInCard
        } else {
            VStack(spacing: DSSpace.s5) {
                // Card header is always present for non-connected states so the
                // card never collapses its top section mid-transition.
                VStack(alignment: .leading, spacing: DSSpace.s0) {
                    Text(authCardHeaderTitle)
                        .font(.system(size: DSFont.Size.base, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)

                    Text(authCardHeaderSubtitle)
                        .font(.system(size: DSFont.Size.sm))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)

                // Main content switches by integration state. Card sizes to fit
                // each state. The outer `.animation` interpolates height when the
                // device-code panel drops in or back out.
                Group {
                    switch viewModel.integrationState {
                    case .notConnected:
                        notConnectedContent
                    case .authorizing:
                        authorizingContent
                    case .error:
                        // The reason renders once, in the ErrorCallout above.
                        // Here the card just offers the way back in.
                        notConnectedContent
                    case .connected:
                        EmptyView()  // Handled by the standalone branch above.
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .cardStyle()
            .animation(reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.base), value: viewModel.integrationState)
        }
    }

    // MARK: - State Content Subviews

    /// "Get a new code" right after a code timed out, so the button says what
    /// it does; "Connect with Twitch" otherwise.
    private var signInButtonTitle: String {
        viewModel.connectionError?.id == "twitch.deviceCodeExpired"
            ? "Get a new code"
            : "Connect with Twitch"
    }

    /// Sign-in CTA shown when no token is stored.
    private var notConnectedContent: some View {
        VStack(spacing: DSSpace.s4) {
            Button(action: {
                viewModel.startOAuth(owner: oauthOwner)
            }) {
                HStack(spacing: DSSpace.s2) {
                    Image("TwitchLogo")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                        .foregroundStyle(.white)
                    Text(signInButtonTitle)
                        .font(.system(size: DSFont.Size.base, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 32)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .pointerCursor()
            .scaleEffect(viewModel.authState.isInProgress ? 0.995 : 1.0)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.fast),
                value: viewModel.authState.isInProgress
            )
            .accessibilityLabel(signInButtonTitle)
            .accessibilityHint("Starts the Twitch authorization flow")
            .accessibilityIdentifier("twitchSignInButton")
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Status line beside the spinner while signing in.
    private var authorizingStatusText: String {
        if case .requestingCode = viewModel.authState {
            return "Getting your code\u{2026}"
        }
        let progress = viewModel.progressMessage
        return progress.isEmpty ? "Waiting for you to approve on Twitch\u{2026}" : progress
    }

    /// Device-code flow with copy + cancel affordances.
    private var authorizingContent: some View {
        VStack(spacing: DSSpace.s4) {
            if case .waitingForAuth(let code, let uri) = viewModel.authState {
                DeviceCodeView(
                    userCode: code, verificationURI: uri,
                    onCopy: {
                        viewModel.progressMessage = "Code copied"
                    },
                    expiresAt: viewModel.deviceCodeExpiresAt,
                    onRequestNewCode: {
                        viewModel.startOAuth(owner: oauthOwner)
                    }
                )
                // Symmetric transition (same shape in and out) so the card
                // doesn't snap on dismissal.
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(reduceMotion ? nil : DSMotion.Spring.snappy, value: viewModel.authState.userCode)
            }

            // Always-visible spinner + cancel row once device code is shown
            HStack(spacing: DSSpace.s2) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)

                Text(authorizingStatusText)
                    .font(.system(size: DSFont.Size.base))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("twitch-settings.authStatus")

                Spacer()

                Button("Cancel") {
                    viewModel.requestOAuthCancellation(ifOwnedBy: oauthOwner)
                }
                .buttonStyle(.bordered)
                .tint(DSColor.error)
                .controlSize(.small)
                .pointerCursor()
                .accessibilityLabel("Cancel authorization")
                .accessibilityHint("Stops the Twitch sign-in process")
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Signed-in dashboard with bot + channel + actions.
    private var connectedContent: some View {
        SignedInView(
            botUsername: viewModel.botUsername,
            channelID: $viewModel.channelID,
            isChannelConnected: viewModel.channelConnected,
            isConnecting: viewModel.isConnecting,
            reauthNeeded: viewModel.reauthNeeded,
            credentialsSaved: viewModel.credentialsSaved,
            isAccountTeardownInProgress: viewModel.isAccountTeardownInProgress,
            channelValidationState: viewModel.channelValidationState,
            onReauth: {
                reauthTask?.cancel()
                reauthTask = Task { @MainActor in
                    defer { reauthTask = nil }
                    guard await viewModel.clearAuthOnly(), !Task.isCancelled else { return }
                    viewModel.startOAuth(owner: oauthOwner)
                }
            },
            onClearCredentials: {
                Task { @MainActor in await viewModel.clearCredentials() }
            },
            onJoinChannel: { viewModel.joinChannel() },
            onLeaveChannel: { viewModel.leaveChannel() },
            onChannelIDChanged: { viewModel.channelDraftChanged() }
        )
        .transition(.opacity)
    }
}

// MARK: - Preview

#Preview("Not Connected") {
    let mockViewModel: TwitchViewModel = {
        let vm = TwitchViewModel()
        vm.credentialsSaved = false
        vm.channelConnected = false
        return vm
    }()
    TwitchSettingsView(viewModel: mockViewModel, oauthOwner: .settings(UUID()))
        .padding()
        .frame(width: 700)
}

#Preview("Connected State") {
    let mockViewModel: TwitchViewModel = {
        let vm = TwitchViewModel()
        vm.botUsername = "MrDemonWolf"
        vm.channelID = "mrdemonwolf"
        vm.credentialsSaved = true
        vm.channelConnected = true
        vm.progressMessage = "Connected to mrdemonwolf"
        return vm
    }()
    TwitchSettingsView(viewModel: mockViewModel, oauthOwner: .settings(UUID()))
        .padding()
        .frame(width: 700)
}

#Preview("Requesting Code") {
    let mockViewModel: TwitchViewModel = {
        let vm = TwitchViewModel()
        vm.authState = .requestingCode
        return vm
    }()
    TwitchSettingsView(viewModel: mockViewModel, oauthOwner: .settings(UUID()))
        .padding()
        .frame(width: 700)
}

#Preview("Authorizing State") {
    let mockViewModel: TwitchViewModel = {
        let vm = TwitchViewModel()
        vm.authState = .waitingForAuth(
            userCode: "ABCD-WXYZ",
            verificationURI: "https://www.twitch.tv/activate"
        )
        vm.deviceCodeExpiresAt = Date().addingTimeInterval(14 * 60)
        return vm
    }()
    TwitchSettingsView(viewModel: mockViewModel, oauthOwner: .settings(UUID()))
        .padding()
        .frame(width: 700)
}

#Preview("Connected - Not Joined Channel") {
    let mockViewModel: TwitchViewModel = {
        let vm = TwitchViewModel()
        vm.botUsername = "MrDemonWolf"
        vm.channelID = ""
        vm.credentialsSaved = true
        vm.channelConnected = false
        return vm
    }()
    TwitchSettingsView(viewModel: mockViewModel, oauthOwner: .settings(UUID()))
        .padding()
        .frame(width: 700)
}

#Preview("Reauth Needed") {
    let mockViewModel: TwitchViewModel = {
        let vm = TwitchViewModel()
        vm.botUsername = "MrDemonWolf"
        vm.channelID = "mrdemonwolf"
        vm.credentialsSaved = true
        vm.channelConnected = false
        vm.reauthNeeded = true
        return vm
    }()
    TwitchSettingsView(viewModel: mockViewModel, oauthOwner: .settings(UUID()))
        .padding()
        .frame(width: 700)
}

#Preview("Error State") {
    let mockViewModel: TwitchViewModel = {
        let vm = TwitchViewModel()
        vm.authState = .error("That sign-in code expired. Codes last only a few minutes.")
        vm.connectionError = TwitchViewModel.Failure.deviceCodeExpired()
        return vm
    }()
    TwitchSettingsView(viewModel: mockViewModel, oauthOwner: .settings(UUID()))
        .padding()
        .frame(width: 700)
}

#Preview("Validating Channel") {
    let mockViewModel: TwitchViewModel = {
        let vm = TwitchViewModel()
        vm.botUsername = "MrDemonWolf"
        vm.channelID = "mrdemonwolf"
        vm.credentialsSaved = true
        vm.channelConnected = false
        vm.channelValidationState = .validating
        return vm
    }()
    TwitchSettingsView(viewModel: mockViewModel, oauthOwner: .settings(UUID()))
        .padding()
        .frame(width: 700)
}

#Preview("Channel Verified") {
    let mockViewModel: TwitchViewModel = {
        let vm = TwitchViewModel()
        vm.botUsername = "MrDemonWolf"
        vm.channelID = "mrdemonwolf"
        vm.credentialsSaved = true
        vm.channelConnected = false
        vm.channelValidationState = .valid
        return vm
    }()
    TwitchSettingsView(viewModel: mockViewModel, oauthOwner: .settings(UUID()))
        .padding()
        .frame(width: 700)
}

#Preview("Channel Invalid") {
    let mockViewModel: TwitchViewModel = {
        let vm = TwitchViewModel()
        vm.botUsername = "MrDemonWolf"
        vm.channelID = "invalidchannel123"
        vm.credentialsSaved = true
        vm.channelConnected = false
        vm.channelValidationState = .invalid
        return vm
    }()
    TwitchSettingsView(viewModel: mockViewModel, oauthOwner: .settings(UUID()))
        .padding()
        .frame(width: 700)
}
