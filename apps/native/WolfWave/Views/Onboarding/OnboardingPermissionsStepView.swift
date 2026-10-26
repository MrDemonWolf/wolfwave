//
//  OnboardingPermissionsStepView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-30.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Music Sync uses Apple Events for the current track; optional Song Requests
/// use separate MusicKit access for catalog and playlist operations.
/// Second step, right after Welcome: everything else builds on this grant.
///
/// This step only handles the Apple Events (Automation) grant for Music.app.
/// The state shows one of three layouts: a grant button (`.unknown`), a
/// confirmation (`.granted`), or fix-it steps with Check again (`.denied`).
struct OnboardingPermissionsStepView: View {

    // MARK: - Apple Music State

    /// Current Automation grant. Seeded from the last persisted decision (a
    /// cheap defaults read), then replaced by an off-main Apple Events probe
    /// when the step appears, and refreshed by Recheck, by the grant prompt,
    /// and whenever the app becomes active again.
    @State private var permissionState: MusicPermissionState =
        MusicPermissionChecker.loadPersisted() ?? .unknown
    /// `true` while the system prompt is pending; disables the grant button.
    @State private var isRequesting = false
    /// `true` while a recheck is in flight; also guards against overlapping rechecks.
    @State private var isRechecking = false

    /// Drops the state-change animations when Reduce Motion is on.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Body

    var body: some View {
        OnboardingStepScaffold(
            title: "Let WolfWave see your music",
            description: "WolfWave needs to see what's playing in Apple Music. Everything else builds on this.",
            icon: {
                BrandTile(
                    background: AnyShapeStyle(
                        LinearGradient(
                            colors: [
                                AppConstants.Brand.appleMusicGradientStart,
                                AppConstants.Brand.appleMusicGradientEnd
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    ),
                    glowColor: AppConstants.Brand.appleMusicGradientEnd,
                    glyph: Image(systemName: "music.note")
                        .font(BrandTileGlyph.font)
                        .foregroundStyle(.white)
                )
            },
            extras: {
                appleMusicSection
                    .motionSafe(.easeInOut(duration: DSMotion.Duration.base), value: permissionState)
            }
        )
        // The Apple Events probe can take tens of milliseconds, so it runs
        // detached rather than on the main actor while the step builds.
        .task {
            let state = await Task.detached(priority: .userInitiated) {
                MusicPermissionChecker.currentState()
            }.value
            permissionState = state
        }
        // The usual fix happens in System Settings, so re-probe when the user
        // switches back to WolfWave instead of making them press Recheck.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recheckTapped()
        }
    }

    // MARK: - Apple Music Section

    /// The layout for the current `permissionState`: a grant button, a done
    /// row, or the fix-it steps.
    @ViewBuilder
    private var appleMusicSection: some View {
        switch permissionState {
        case .granted:
            HStack(spacing: DSSpace.s3) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: DSFont.Size.lg))
                    .foregroundStyle(DSColor.success)
                    .accessibilityHidden(true)
                Text("Done. WolfWave can see what's playing.")
                    .font(.system(size: DSFont.Size.base, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .padding(DSSpace.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("onboardingAppleMusic.granted")

        case .denied:
            VStack(spacing: DSSpace.s4) {
                CalloutBanner(
                    "In System Settings, open **Privacy & Security → Automation** and turn on "
                        + "**Music** under WolfWave. Then come back here.",
                    title: "macOS blocked it",
                    style: .warning
                )

                HStack(spacing: DSSpace.s2) {
                    Button("Open System Settings") {
                        MusicPermissionChecker.openAutomationSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .pointerCursor()
                    .accessibilityHint("Opens Privacy and Security so you can allow Apple Music access")
                    .accessibilityIdentifier("onboardingAppleMusic.openSystemSettingsButton")

                    Button(action: recheckTapped) {
                        HStack(spacing: DSSpace.s1h) {
                            if isRechecking {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .controlSize(.small)
                            }
                            Text("Check again")
                        }
                    }
                    .buttonStyle(.bordered)
                    .pointerCursor()
                    .disabled(isRechecking)
                    .accessibilityLabel("Check Apple Music access again")
                    .accessibilityIdentifier("onboardingAppleMusic.recheckButton")
                }
            }

        case .unknown:
            VStack(spacing: DSSpace.s3) {
                PillButton(
                    background: AnyShapeStyle(
                        LinearGradient(
                            colors: [
                                AppConstants.Brand.appleMusicGradientStart,
                                AppConstants.Brand.appleMusicGradientEnd
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    ),
                    disabled: isRequesting,
                    action: requestAccess,
                    label: {
                        HStack(spacing: DSSpace.s2) {
                            if isRequesting {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                            Text("Allow Apple Music access")
                        }
                    }
                )
                .accessibilityLabel("Allow Apple Music access")
                .accessibilityIdentifier("onboardingAppleMusicGrant")

                Text("macOS asks once. Click OK.")
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Apple Music Actions

    /// Re-queries Apple Music automation permission with a brief spinner so
    /// the user gets visible feedback even when the state doesn't change.
    /// The minimum spinner time comes from `MusicPermissionChecker.recheck()`;
    /// the probe itself runs off the main actor. A no-op while one is running.
    private func recheckTapped() {
        guard !isRechecking else { return }
        withMotionSafeAnimation(.easeInOut(duration: DSMotion.Duration.fast), reduceMotion: reduceMotion) {
            isRechecking = true
        }
        Task {
            let next = await MusicPermissionChecker.recheck()
            await MainActor.run {
                withMotionSafeAnimation(.easeInOut(duration: DSMotion.Duration.base), reduceMotion: reduceMotion) {
                    permissionState = next
                    isRechecking = false
                }
            }
        }
    }

    /// Prompts the user for Apple Music automation permission via
    /// `MusicPermissionChecker.requestAccess()` and refreshes the UI state.
    ///
    /// May launch Music.app in the background first, because macOS only shows
    /// the prompt for a running target. Waits until the user answers.
    private func requestAccess() {
        isRequesting = true
        Task {
            let resolved = await MusicPermissionChecker.requestAccess()
            permissionState = resolved
            isRequesting = false
        }
    }
}

// MARK: - Preview

#Preview {
    OnboardingPermissionsStepView()
        .frame(width: 600, height: 520)
}
