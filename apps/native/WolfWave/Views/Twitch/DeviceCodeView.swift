//
//  DeviceCodeView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-01-13.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Native macOS device authorization code display.
/// Clean, minimal, system-native presentation for inline use in settings.
///
/// Follows macOS design principles:
/// - No heavy styling or borders
/// - Calm, trustworthy appearance
/// - Smooth interaction feedback
/// - Supports dark and light modes naturally
struct DeviceCodeView: View {

    // MARK: - Properties

    /// The device-flow user code to type on twitch.tv/activate.
    let userCode: String
    /// Activation page URL from Twitch (may already carry the device code).
    let verificationURI: String
    /// Called after the code is copied (the copy itself is done by `CopyButton`).
    let onCopy: () -> Void
    /// Called only when the activation URL actually opened in the browser.
    var onActivate: (() -> Void)? = nil
    /// When the code stops working. `nil` hides the countdown, which keeps
    /// call sites that don't track expiry (onboarding) unchanged.
    var expiresAt: Date?
    /// Starts a fresh device flow. Offered once `expiresAt` has passed.
    var onRequestNewCode: (() -> Void)?

    /// Disables the code-change spring under Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            // Header: subtle label
            Text("Your code")
                .font(.system(size: DSFont.Size.sm, weight: .medium))
                .foregroundStyle(.secondary)
                .transition(.move(edge: .top).combined(with: .opacity))


            // Code container - monospaced, larger and calm
            HStack(spacing: DSSpace.s2) {
                Text(userCode)
                    .font(.system(size: DSFont.Size.x2xl, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityLabel("Sign-in code")
                    .accessibilityValue(userCode)
                    .accessibilityIdentifier("deviceCodeText")

                // Always-visible copy button. CopyButton owns the checkmark
                // confirmation + reset timer; `action` forwards onCopy.
                CopyButton(
                    text: userCode,
                    buttonStyle: .borderless,
                    accessibilityLabel: "Copy sign-in code",
                    accessibilityIdentifier: "copyDeviceCodeButton",
                    feedbackDuration: 1.3,
                    isSensitive: true,
                    action: onCopy
                )
                .help("Copy code")
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .padding(DSSpace.s4)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.md)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.md))

            // Primary action: open activation URL with subtler, smaller button
            Button(action: openActivationURL) {
                HStack(spacing: DSSpace.s1h) {
                    Text("Open twitch.tv/activate")
                        .font(.system(size: DSFont.Size.body, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: DSFont.Size.xs, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .pointerCursor()
            .accessibilityLabel("Open twitch.tv/activate")
            .accessibilityHint("Opens the Twitch activation page in your browser so you can approve WolfWave")
            .accessibilityIdentifier("openTwitchButton")

            if let expiresAt {
                expiryRow(expiresAt)
            }
        }
        .animation(reduceMotion ? nil : DSMotion.Spring.snappy, value: userCode)
    }

    // MARK: - Expiry

    /// "Expires in about N min", re-evaluated every five seconds, turning into
    /// a "Get a new code" button once the code is dead (the button only shows
    /// when `onRequestNewCode` is set).
    private func expiryRow(_ expiresAt: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let remaining = expiresAt.timeIntervalSince(context.date)
            if let text = TwitchViewModel.deviceCodeExpiryText(remaining: remaining) {
                Text(text)
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityIdentifier("deviceCodeExpiry")
            } else {
                HStack(spacing: DSSpace.s2) {
                    Text("This code expired.")
                        .font(.system(size: DSFont.Size.sm))
                        .foregroundStyle(DSColor.warning)
                    Spacer()
                    if let onRequestNewCode {
                        Button("Get a new code", action: onRequestNewCode)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .pointerCursor()
                            .accessibilityIdentifier("deviceCodeGetNewCode")
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Opens the Twitch device activation URL in the user's default browser
    /// and forwards the action to the parent via `onActivate`.
    private func openActivationURL() {
        if ExternalLink.open(verificationURI) {
            onActivate?()
        }
    }
}

#Preview("Standard Code") {
    VStack(spacing: DSSpace.s8) {
        DeviceCodeView(
            userCode: "ABCD-EFGH",
            verificationURI: "https://www.twitch.tv/activate?device_code=test",
            onCopy: { }
        )

        Divider()

        DeviceCodeView(
            userCode: "WXYZ-QRST",
            verificationURI: "https://www.twitch.tv/activate?device_code=test2",
            onCopy: { }
        )
    }
    .padding(DSSpace.s8)
    .frame(width: 500)
}
#Preview("With Expiry") {
    DeviceCodeView(
        userCode: "ABCD-EFGH",
        verificationURI: "https://www.twitch.tv/activate",
        onCopy: { },
        expiresAt: Date().addingTimeInterval(8 * 60),
        onRequestNewCode: { }
    )
    .padding(DSSpace.s8)
    .frame(width: 500)
}

#Preview("Long Code") {
    DeviceCodeView(
        userCode: "ABCDEFGH-IJKLMNOP",
        verificationURI: "https://www.twitch.tv/activate",
        onCopy: { }
    )
    .padding(DSSpace.s8)
    .frame(width: 500)
}

#Preview("Compact Card") {
    VStack(alignment: .leading, spacing: DSSpace.s4) {
        Text("Enter this code on Twitch")
            .font(.system(size: DSFont.Size.base))
            .foregroundStyle(.secondary)
        
        DeviceCodeView(
            userCode: "MNOP-QRST",
            verificationURI: "https://www.twitch.tv/activate",
            onCopy: { },
            onActivate: { }
        )
    }
    .padding()
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg2))
    .padding(DSSpace.s8)
    .frame(width: 400)
}
