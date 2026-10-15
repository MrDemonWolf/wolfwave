//
//  OnboardingView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-02-06.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// First-launch onboarding wizard with progress dots, step content, and navigation.
///
/// Steps: Welcome → Discord → Twitch → OBS → Preferences → Permissions → Notifications → Menu bar pointer.
/// Hosted in a dedicated `NSWindow` created by `AppDelegate.showOnboarding()`.
/// Closing that window before Finish / Skip All leaves the completed flag unset,
/// so the wizard opens again on the next launch.
struct OnboardingView: View {

    // MARK: - State

    /// Wizard position and completion state.
    @State private var viewModel = OnboardingViewModel()
    /// The app-wide Twitch view model, shared with the Settings pane so a sign-in
    /// started here is the same one Settings shows.
    @State private var twitchViewModel = TwitchViewModel.shared
    /// Stable identity for this Onboarding presentation.
    ///
    /// Passed to `requestOAuthCancellation(ifOwnedBy:)` so leaving the wizard only
    /// cancels a device-code sign-in that this window started, never one that the
    /// Settings window owns.
    @State private var twitchOAuthOwner =
        TwitchViewModel.OAuthPresentationOwner.onboarding(UUID())

    // Settings the Discord, OBS, and Preferences steps toggle, passed down as
    // bindings. Writes persist immediately, even if the wizard is abandoned.

    @AppStorage(AppConstants.UserDefaults.discordPresenceEnabled)
    private var discordPresenceEnabled = false

    @AppStorage(AppConstants.UserDefaults.websocketEnabled)
    private var websocketEnabled = false

    @AppStorage(AppConstants.UserDefaults.launchAtLogin)
    private var launchAtLogin = false

    /// Called when onboarding completes to dismiss the window.
    var onComplete: () -> Void

    /// Tracks navigation direction for slide transitions.
    @State private var navigationDirection: Edge = .trailing

    /// Re-read on every step change so the Skip button stays in sync with
    /// permission grants without needing each step view to publish state up.
    @State private var musicPermissionState: MusicPermissionState = MusicPermissionChecker.currentState()

    /// Swaps the step slide for a cross-fade when on.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Body

    var body: some View {
        Group {
            if viewModel.showCompletion {
                OnboardingCompletionView(
                    onDismiss: onComplete,
                    style: viewModel.completedBySkipping ? .skipped : .completed
                )
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    progressDots
                        .padding(.top, DSSpace.s7)
                        .padding(.bottom, DSSpace.s6)

                    GeometryReader { geo in
                        ScrollView(.vertical, showsIndicators: false) {
                            stepContent
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: geo.size.height)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .animation(DSMotion.Spring.snappy, value: viewModel.currentStep)
                    }

                    Divider()

                    navigationBar
                        .padding(.horizontal, DSSpace.s8)
                        .padding(.vertical, DSSpace.s6)
                        .background(.regularMaterial)
                }
            }
        }
        .frame(
            width: AppConstants.OnboardingUI.windowWidth,
            height: AppConstants.OnboardingUI.windowHeight
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: DSMotion.Duration.slow), value: viewModel.showCompletion)
        .onChange(of: viewModel.currentStep) { _, _ in
            musicPermissionState = MusicPermissionChecker.currentState()
        }
        .onDisappear {
            twitchViewModel.requestOAuthCancellation(ifOwnedBy: twitchOAuthOwner)
        }
    }

    // MARK: - Progress Dots

    /// One dot per step, the current one enlarged and accent-filled. Visual only:
    /// VoiceOver reads the whole row as a single "Step N of M: name" element.
    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingViewModel.OnboardingStep.allCases, id: \.rawValue) { step in
                ZStack {
                    Circle()
                        .fill(step == viewModel.currentStep
                            ? Color.accentColor
                            : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .scaleEffect(step == viewModel.currentStep ? 1.3 : 1.0)
                        .shadow(
                            color: step == viewModel.currentStep ? Color.accentColor.opacity(0.40) : .clear,
                            radius: 3, x: 0, y: 1
                        )
                        .animation(DSMotion.Spring.gentle, value: viewModel.currentStep)
                }
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setup progress")
        .accessibilityValue("Step \(viewModel.currentStep.rawValue + 1) of \(OnboardingViewModel.OnboardingStep.allCases.count): \(viewModel.currentStep.accessibilityTitle)")
        .accessibilityHint("Shows how far you are through WolfWave setup. Use Back and Next to move between steps.")
    }

    // MARK: - Step Content

    /// The current step's view. `.id(currentStep)` gives each step a fresh
    /// identity, so a step change is a removal plus insertion and the slide
    /// transition runs in `navigationDirection`.
    @ViewBuilder
    private var stepContent: some View {
        Group {
            switch viewModel.currentStep {
            case .welcome:
                OnboardingWelcomeStepView()
            case .discordConnect:
                OnboardingDiscordStepView(presenceEnabled: $discordPresenceEnabled)
            case .twitchConnect:
                OnboardingTwitchStepView(
                    twitchViewModel: twitchViewModel,
                    oauthOwner: twitchOAuthOwner
                )
            case .obsWidget:
                OnboardingOBSWidgetStepView(websocketEnabled: $websocketEnabled)
            case .preferences:
                OnboardingPreferencesStepView(launchAtLogin: $launchAtLogin)
            case .permissions:
                OnboardingPermissionsStepView()
            case .notifications:
                OnboardingNotificationsStepView()
            case .menuBarPointer:
                OnboardingMenuBarPointerStepView()
            }
        }
        .id(viewModel.currentStep)
        .transition(reduceMotion
            ? AnyTransition.opacity
            : .asymmetric(
                insertion: .move(edge: navigationDirection).combined(with: .opacity),
                removal: .move(edge: navigationDirection == .trailing ? .leading : .trailing).combined(with: .opacity)
            )
        )
    }

    // MARK: - Navigation Bar

    /// Back / Skip All on the left, Skip and Next / Finish on the right.
    ///
    /// Every exit path calls `cancelTwitchOAuthIfNeeded()` first, so a pending
    /// device-code poll never outlives the Twitch step.
    private var navigationBar: some View {
        HStack {
            // Left: Back (≥step 2) + Skip All (when not on the last step).
            // Back is rendered as a hidden placeholder on step 1 so the rest of
            // the bar doesn't shift horizontally between steps.
            HStack(spacing: 8) {
                Button("Back") {
                    navigationDirection = .leading
                    cancelTwitchOAuthIfNeeded()
                    viewModel.goToPreviousStep()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .pointerCursor()
                .opacity(viewModel.isFirstStep ? 0 : 1)
                .disabled(viewModel.isFirstStep)
                .accessibilityHidden(viewModel.isFirstStep)
                .accessibilityLabel("Go back")
                .accessibilityHint("Returns to the previous setup step")
                .accessibilityIdentifier("onboarding.back")

                Button("Skip All") {
                    finishOnboarding(skipped: true)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .pointerCursor()
                .opacity(viewModel.isLastStep ? 0 : 1)
                .disabled(viewModel.isLastStep)
                .accessibilityHidden(viewModel.isLastStep)
                .accessibilityLabel("Skip all steps")
                .accessibilityHint("Skips the setup wizard and uses default settings")
                .accessibilityIdentifier("onboarding.skipAll")
            }

            Spacer()

            // Right: Skip (toggled via opacity to keep layout stable) + Next/Finish.
            Button("Skip") {
                navigationDirection = .trailing
                cancelTwitchOAuthIfNeeded()
                viewModel.goToNextStep()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .pointerCursor()
            .opacity(shouldShowSkip ? 1 : 0)
            .disabled(!shouldShowSkip)
            .accessibilityLabel("Skip this step")
            .accessibilityHint("Skips the current setup step without making changes")
            .accessibilityIdentifier("onboarding.skip")

            if viewModel.isLastStep {
                Button("Finish") {
                    finishOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
                .pointerCursor()
                .accessibilityLabel("Finish setup")
                .accessibilityHint("Completes the setup wizard and starts using WolfWave")
                .accessibilityIdentifier("onboarding.finish")
            } else {
                Button("Next") {
                    navigationDirection = .trailing
                    cancelTwitchOAuthIfNeeded()
                    viewModel.goToNextStep()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                // Not on the Twitch step: Return in its channel field submits
                // the join, and would otherwise also advance the wizard before
                // the join result (or a "channel not found") is shown.
                .keyboardShortcut(nextShortcut)
                .pointerCursor()
                .accessibilityLabel("Next step")
                .accessibilityHint("Continues to the next setup step")
                .accessibilityIdentifier("onboarding.next")
            }
        }
        // Keep the bar still while the step content animates; only the content
        // area should move on a step change.
        .transaction { $0.animation = nil }
    }

    // MARK: - Helpers

    /// Return-key shortcut for Next. Nil on the Twitch step, whose channel
    /// field owns Return.
    private var nextShortcut: KeyboardShortcut? {
        viewModel.currentStep == .twitchConnect ? nil : .defaultAction
    }

    /// Returns `true` only for steps where Skip means something different from
    /// "Next with the toggle off" (i.e. OAuth and system permissions).
    ///
    /// Twitch: shown until a sign-in is saved. Permissions: shown until the Music
    /// Automation grant is `.granted`, read from `musicPermissionState`, which is
    /// refreshed on each step change rather than live.
    private var shouldShowSkip: Bool {
        switch viewModel.currentStep {
        case .twitchConnect:
            return !twitchViewModel.credentialsSaved
        case .permissions:
            return musicPermissionState != .granted
        default:
            return false
        }
    }

    /// Cancels any in-progress Twitch OAuth polling when leaving the Twitch step.
    private func cancelTwitchOAuthIfNeeded() {
        guard viewModel.currentStep == .twitchConnect else { return }
        if case .authorizing = twitchViewModel.integrationState {
            twitchViewModel.requestOAuthCancellation(ifOwnedBy: twitchOAuthOwner)
        }
    }

    /// Persists the completion flag and shows the ending screen. Skip All
    /// passes `skipped: true` for the lighter copy.
    private func finishOnboarding(skipped: Bool = false) {
        cancelTwitchOAuthIfNeeded()
        viewModel.completeOnboarding(skipped: skipped)
    }
}

// MARK: - Previews

#Preview {
    OnboardingView(onComplete: {})
}
