//
//  TwitchSettingsView+SignedIn.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

// The signed-in account card shown by the Twitch settings pane.

// MARK: - Sub-Views

/// View displayed when the user is signed in, showing bot info and channel controls.
///
/// A pure presentation of values passed in by ``TwitchSettingsView``; every
/// action is a closure back to the view model.
struct SignedInView: View {
    // MARK: - Properties

    /// Validation indicator animation collapses under Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Masks the username and channel, and swaps the channel field for a
    /// read-only masked label.
    @AppStorage(AppConstants.UserDefaults.streamerModeEnabled)
    private var streamerMode = false

    /// Signed-in login the bot posts as; empty until resolved.
    let botUsername: String
    /// Channel to join. Editable only while not joined and not expired; the
    /// field lowercases and trims as the user types.
    @Binding var channelID: String
    /// Whether the bot is currently joined to the channel.
    let isChannelConnected: Bool
    /// A join is in flight; disables the field and the join button.
    let isConnecting: Bool
    /// Token expired: swaps Join/Leave for "Reconnect with Twitch".
    let reauthNeeded: Bool
    /// A grant is stored. Lets Join proceed before the username resolves.
    let credentialsSaved: Bool
    /// Sign-out or account switch is tearing down; locks every action.
    let isAccountTeardownInProgress: Bool
    /// Result of the live channel lookup, shown under the field.
    let channelValidationState: TwitchViewModel.ChannelValidationState
    /// Clears the token and starts a fresh sign-in.
    var onReauth: () -> Void
    /// Signs out (after confirmation).
    var onClearCredentials: () -> Void
    /// Joins the typed channel.
    var onJoinChannel: () -> Void
    /// Leaves the channel (after confirmation); stays signed in.
    var onLeaveChannel: () -> Void
    /// Called when the normalized channel text actually changes, so the view
    /// model can reset validation.
    var onChannelIDChanged: () -> Void
    /// Presents the leave-channel confirmation.
    @State private var showingDisconnectConfirmation = false
    /// Presents the sign-out confirmation.
    @State private var showingLogOutConfirmation = false

    /// Shared height for every button in the action row. Pinning all of them to
    /// one value keeps Join/Leave and Log Out visually aligned;
    /// without it, the taller `checkmark.circle.fill` glyph makes the connect
    /// button a hair taller than its neighbors.
    private static let actionButtonHeight: CGFloat = 22

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            botAccountSection
            Divider()
                .padding(.leading, AppConstants.SettingsUI.cardPadding)
            channelSection
            Divider()
                .padding(.leading, AppConstants.SettingsUI.cardPadding)
            actionButtonsSection
            Divider()
                .padding(.leading, AppConstants.SettingsUI.cardPadding)
            logOutSection
        }
        .cardStyleUnpadded()
    }

    // MARK: - Sections

    /// Signed-in Twitch username, masked under Streamer Mode so it is safe on
    /// camera. Empty stays "Not set" so the empty state still reads clearly.
    private var displayUsername: String {
        guard !botUsername.isEmpty else { return "Not set" }
        return StreamerMode.mask(botUsername, style: .channel, isOn: streamerMode)
    }

    /// Row showing the signed-in Twitch username and a status icon.
    private var botAccountSection: some View {
        HStack(alignment: .center, spacing: DSSpace.s4) {
            VStack(alignment: .leading, spacing: DSSpace.s0) {
                Text("Bot account")
                    .font(.system(size: DSFont.Size.sm, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(displayUsername)
                    .font(.system(size: DSFont.Size.base, weight: .semibold))
                Text("WolfWave posts chat replies as this account.")
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            statusIcon(reauthNeeded: reauthNeeded)
        }
        .padding(.horizontal, AppConstants.SettingsUI.cardPadding)
        .padding(.vertical, DSSpace.s4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bot account: \(displayUsername)")
        .accessibilityValue(reauthNeeded ? "Sign-in expired" : "Signed in")
    }

    /// Row with the channel name input field (or label when connected) and validation indicator.
    private var channelSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: DSSpace.s4) {
                VStack(alignment: .leading, spacing: DSSpace.s0) {
                    Text("Channel")
                        .font(.system(size: DSFont.Size.sm, weight: .medium))
                        .foregroundStyle(.secondary)
                    channelInputView
                }
                Spacer()
                connectionIcon
            }

            channelValidationIndicator
                .animation(reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.base), value: channelValidationState)
        }
        .padding(.horizontal, AppConstants.SettingsUI.cardPadding)
        .padding(.vertical, DSSpace.s4)
    }

    /// Small inline indicator below the channel field showing validation progress or result.
    ///
    /// Uses the shared ``FieldValidationRow`` so the glyphs and tints match
    /// every other field, and so a failed check shows its real reason inline
    /// instead of hiding it in a hover tooltip.
    @ViewBuilder
    private var channelValidationIndicator: some View {
        if channelValidationRowState != .idle {
            FieldValidationRow(state: channelValidationRowState)
                .padding(.top, DSSpace.s2)
        }
    }

    /// Maps the view model's channel check onto the shared field states.
    private var channelValidationRowState: FieldValidationRow.State {
        switch channelValidationState {
        case .idle:
            return .idle
        case .validating:
            return .validating("Verifying channel\u{2026}")
        case .valid:
            return .valid("Channel verified")
        case .invalid:
            return .invalid("Channel not found")
        case .error(let message):
            return .failed(UserFacingError(
                id: "twitch.channelCheckFailed",
                title: "Couldn't check channel",
                cause: message,
                severity: .warning
            ))
        }
    }

    /// Either a read-only label (when connected or reauth needed) or an editable text field.
    @ViewBuilder
    private var channelInputView: some View {
        switch (isChannelConnected, reauthNeeded) {
        case (true, _):
            HStack(spacing: DSSpace.s2) {
                Text(channelID.isEmpty ? "Not set" : StreamerMode.mask(channelID, style: .channel, isOn: streamerMode))
                    .font(.system(size: DSFont.Size.base, weight: .semibold))
                if !channelID.isEmpty {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(DSColor.info)
                        .font(.system(size: DSFont.Size.base))
                        .accessibilityLabel("Verified channel")
                }
                if streamerMode { StreamerModeBadge() }
            }
        case (false, true):
            HStack(spacing: DSSpace.s2) {
                Text(channelID.isEmpty ? "Not set" : StreamerMode.mask(channelID, style: .channel, isOn: streamerMode))
                    .font(.system(size: DSFont.Size.base, weight: .semibold))
                    .foregroundStyle(.secondary)
                if streamerMode { StreamerModeBadge() }
            }
        case (false, false):
            if streamerMode {
                HStack(spacing: DSSpace.s2) {
                    Text(channelID.isEmpty ? "Not set" : StreamerMode.mask(channelID, style: .channel, isOn: true))
                        .font(.system(size: DSFont.Size.base, weight: .semibold))
                        .foregroundStyle(.secondary)
                    StreamerModeBadge()
                }
            } else {
                TextField("Channel Name", text: $channelID)
                    .font(.system(size: DSFont.Size.base))
                    .textFieldStyle(.plain)
                    .disabled(isConnecting || isAccountTeardownInProgress)
                    .accessibilityLabel("Twitch channel name")
                    .accessibilityHint("Enter your Twitch channel name")
                    .accessibilityIdentifier("twitchChannelTextField")
                    .onSubmit {
                        if !shouldDisableConnectButton {
                            onJoinChannel()
                        }
                    }
                    .onChange(of: channelID) { oldValue, newValue in
                        let sanitized = newValue.lowercased().trimmingCharacters(
                            in: CharacterSet.whitespacesAndNewlines)
                        if sanitized != newValue {
                            channelID = sanitized
                        }
                        if oldValue.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                            != sanitized
                        {
                            onChannelIDChanged()
                        }
                    }
            }
        }
    }

    /// Wi-Fi icon reflecting current channel connection state.
    @ViewBuilder
    private var connectionIcon: some View {
        switch (isChannelConnected, reauthNeeded) {
        case (true, _):
            Image(systemName: "wifi")
                .foregroundStyle(DSColor.success)
                .font(.system(size: DSFont.Size.md))
                .accessibilityLabel("Connected to channel")
        case (false, true):
            Image(systemName: "wifi.slash")
                .foregroundStyle(DSColor.warning)
                .font(.system(size: DSFont.Size.md))
                .accessibilityLabel("Disconnected, sign-in expired")
        case (false, false):
            EmptyView()
        }
    }

    /// Bottom row with the Reconnect (when re-auth is needed) or Join/Leave
    /// Channel button, plus a trailing Spacer. Log Out lives in `logOutSection`.
    private var actionButtonsSection: some View {
        HStack(spacing: DSSpace.s3) {
            if reauthNeeded {
                Button(action: onReauth) {
                    Label("Reconnect with Twitch", systemImage: "arrow.clockwise.circle.fill")
                        .font(.system(size: DSFont.Size.body, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(DSColor.warning)
                .controlSize(.small)
                .frame(height: Self.actionButtonHeight)
                .pointerCursor()
                .accessibilityLabel("Reconnect with Twitch")
                .accessibilityHint("Clears credentials and starts a new sign-in")
                .accessibilityIdentifier("twitchReauthButton")
                .disabled(isAccountTeardownInProgress)
            } else {
                Button(action: {
                    if isChannelConnected {
                        showingDisconnectConfirmation = true
                    } else {
                        onJoinChannel()
                    }
                }) {
                    if isConnecting {
                        HStack(spacing: DSSpace.s1h) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.mini)
                            Text("Connecting\u{2026}")
                                .font(.system(size: DSFont.Size.body))
                        }
                    } else {
                        Label(
                            isChannelConnected ? "Leave Channel" : "Join Channel",
                            systemImage: isChannelConnected
                                ? "xmark.circle.fill" : "checkmark.circle.fill"
                        )
                        .font(.system(size: DSFont.Size.body, weight: .medium))
                        .foregroundStyle(isChannelConnected ? DSColor.error : Color.primary)
                    }
                }
                .disabled(shouldDisableConnectButton)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .stableWidth {
                    Label("Join Channel", systemImage: "checkmark.circle.fill")
                        .font(.system(size: DSFont.Size.body, weight: .medium))
                    Label("Leave Channel", systemImage: "xmark.circle.fill")
                        .font(.system(size: DSFont.Size.body, weight: .medium))
                    HStack(spacing: DSSpace.s1h) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                        Text("Connecting\u{2026}")
                            .font(.system(size: DSFont.Size.body))
                    }
                }
                .frame(height: Self.actionButtonHeight)
                .pointerCursor()
                .accessibilityLabel(
                    isChannelConnected ? "Leave channel" : "Join channel"
                )
                .accessibilityHint(
                    isChannelConnected ? "Removes the bot from the Twitch channel" : "Adds the bot to the Twitch channel"
                )
                .accessibilityValue(isChannelConnected ? "Connected" : "Disconnected")
                .accessibilityIdentifier("twitchConnectButton")
            }

            Spacer()
        }
        .padding(.horizontal, AppConstants.SettingsUI.cardPadding)
        .padding(.vertical, DSSpace.s4)
        .confirmationDialog(
            "Disconnect from channel?", isPresented: $showingDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                onLeaveChannel()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will disconnect the bot from the current channel but keep you logged in.")
        }
    }

    /// Quiet sign-out row, kept on its own line below the everyday Join/Leave
    /// action so the destructive Log Out never shares a row with the reversible
    /// channel controls.
    private var logOutSection: some View {
        HStack(alignment: .center, spacing: DSSpace.s4) {
            VStack(alignment: .leading, spacing: DSSpace.s0) {
                Text("Sign out")
                    .font(.system(size: DSFont.Size.sm, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Chat commands stop until you sign in again.")
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button("Log Out") { showingLogOutConfirmation = true }
                .font(.system(size: DSFont.Size.body))
                .buttonStyle(.bordered)
                .tint(DSColor.error)
                .controlSize(.small)
                .frame(height: Self.actionButtonHeight)
                .pointerCursor()
                .accessibilityLabel("Clear saved Twitch credentials")
                .accessibilityHint("Signs out of your Twitch account")
                .accessibilityIdentifier("twitchClearCredentialsButton")
                .disabled(isAccountTeardownInProgress)
        }
        .padding(.horizontal, AppConstants.SettingsUI.cardPadding)
        .padding(.vertical, DSSpace.s4)
        .confirmationDialog(
            "Sign out of Twitch?", isPresented: $showingLogOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive, action: onClearCredentials)
                .accessibilityIdentifier("twitchConfirmSignOutButton")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Chat commands stop until you sign in again.")
        }
    }

    /// Whether the Connect button should be grayed out (missing channel name or still connecting).
    private var shouldDisableConnectButton: Bool {
        let validChannel = !channelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isConnecting || isAccountTeardownInProgress { return true }
        // If credentials are saved we can attempt to connect even if the
        // bot username hasn't been resolved yet, rely on saved token.
        if credentialsSaved {
            return !validChannel
        }
        return botUsername.isEmpty || !validChannel
    }

    /// Builds the connection-status SF Symbol (warning exclamation for
    /// re-auth needed, success checkmark otherwise).
    ///
    /// - Parameter reauthNeeded: When `true`, returns the warning icon.
    /// - Returns: A pre-sized status icon view.
    @ViewBuilder
    private func statusIcon(reauthNeeded: Bool) -> some View {
        Image(systemName: reauthNeeded ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
            .foregroundStyle(reauthNeeded ? DSColor.warning : DSColor.success)
            .font(.system(size: DSFont.Size.md))
    }
}
