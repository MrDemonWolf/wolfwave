//
//  OnboardingOBSWidgetStepView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-02-20.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// OBS overlay step. One toggle drives both the WebSocket feed and the widget
/// HTTP server so streamers see a single, useful Browser Source URL instead of
/// chaining two switches. Advanced users can split them later in Settings.
struct OnboardingOBSWidgetStepView: View {

    // MARK: - Properties

    /// The `websocketEnabled` preference, owned by `OnboardingView`.
    @Binding var websocketEnabled: Bool

    /// When on, the URL is masked and Copy is disabled (on-camera safety).
    @AppStorage(AppConstants.UserDefaults.streamerModeEnabled)
    private var streamerMode = false

    @AppStorage(AppConstants.UserDefaults.widgetHTTPEnabled)
    private var widgetHTTPEnabled = false

    /// Widget HTTP port as stored. Read through `@AppStorage` so the URL
    /// updates live; resolved below exactly as the server resolves it.
    @AppStorage(AppConstants.UserDefaults.widgetPort)
    private var storedWidgetPort: Int = Int(AppConstants.WebSocketServer.widgetDefaultPort)

    /// Loopback Browser Source URL for the widget. Carries no token: the widget
    /// server injects the overlay token itself for loopback requests. The port
    /// goes through `Preferences.resolvePort`, the same fallback and clamping
    /// the server binds with, so the URL always names the port it listens on.
    private var overlayURL: String {
        let port = Preferences.resolvePort(
            storedWidgetPort,
            default: AppConstants.WebSocketServer.widgetDefaultPort
        )
        return "http://localhost:\(String(port))/"
    }

    /// Combined state. The step treats the two servers as one user-facing feature,
    /// so it reads as off unless both are on (for example after a user turned
    /// only one on in Settings).
    private var overlayEnabled: Bool {
        websocketEnabled && widgetHTTPEnabled
    }

    // MARK: - Body

    var body: some View {
        OnboardingStepScaffold(
            title: "Show your song on stream",
            description: "Turn it on and paste one link into OBS.",
            icon: {
                BrandTile(
                    background: AnyShapeStyle(
                        LinearGradient(
                            colors: [AppConstants.Brand.obsGradientStart, AppConstants.Brand.obsGradientEnd],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    ),
                    glowColor: Color.black,
                    glyph: BrandTileGlyph.asset("OBSLogo")
                )
            },
            extras: {
                VStack(spacing: DSSpace.s4) {
                    overlayToggleCard
                    urlReveal
                }
                .motionSafe(.easeInOut(duration: DSMotion.Duration.base), value: overlayEnabled)
            }
        )
    }

    // MARK: - Toggle Card

    /// The single Stream Widgets switch, wrapped in the accent-tinted shell.
    private var overlayToggleCard: some View {
        ToggleSettingRow(
            title: "Stream overlay",
            subtitle: overlayEnabled ? "On. Copy the link below." : "A now-playing card for OBS or any streaming app.",
            isOn: Binding(
                get: { overlayEnabled },
                set: { setOverlayEnabled($0) }
            ),
            controlSize: .regular,
            accessibilityLabel: "Stream overlay",
            accessibilityIdentifier: "onboardingOverlayToggle"
        )
        .onboardingTintedToggleShell(
            isOn: overlayEnabled,
            tint: .accentColor,
            fillOpacity: 0.08,
            glowOpacity: 0.16,
            glowRadius: 16,
            glowYOffset: 4
        )
    }

    // MARK: - URL Reveal

    /// Browser Source URL with Copy, shown only while the overlay is on. Slides in
    /// from the top when it appears.
    @ViewBuilder
    private var urlReveal: some View {
        if overlayEnabled {
            VStack(alignment: .leading, spacing: DSSpace.s3) {
                HStack(spacing: DSSpace.s2) {
                    Text("Overlay link")
                        .sectionEyebrow()
                    if streamerMode { StreamerModeBadge() }
                }

                HStack(spacing: DSSpace.s2) {
                    Text(verbatim: StreamerMode.mask(overlayURL, style: .url, isOn: streamerMode))
                        .font(.system(size: DSFont.Size.md, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    CopyButton(
                        text: overlayURL,
                        isDisabled: streamerMode,
                        accessibilityLabel: "Copy overlay URL"
                    )
                }
                .padding(.horizontal, DSSpace.s4)
                .padding(.vertical, DSSpace.s3)
                .background(
                    RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )

                Text("In OBS: Sources → + → Browser, then paste this link. Styles: Settings → Stream Widgets.")
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DSSpace.s4)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Private Helpers

    /// Flip both servers as one. Notifications fire in the same order
    /// `AppDelegate` listens for them.
    ///
    /// Both preferences are written before either notification posts, so each
    /// server's handler already sees the final state of the other.
    private func setOverlayEnabled(_ enabled: Bool) {
        websocketEnabled = enabled
        widgetHTTPEnabled = enabled

        NotificationCenter.default.postWebSocketServerChanged()
        NotificationCenter.default.post(name: .widgetHTTPServerChanged, object: nil)
    }
}

// MARK: - Preview

#Preview {
    OnboardingOBSWidgetStepView(websocketEnabled: .constant(true))
        .frame(width: 600, height: 480)
}
