//
//  OnboardingView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-02-06.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// First-launch onboarding wizard: a progress header, the current step, and a
/// navigation bar with one primary button.
///
/// Steps: Welcome → Apple Music → Discord → Twitch → Stream overlay → Alerts →
/// Mac settings, then `OnboardingCompletionView` (which also shows where
/// WolfWave lives in the menu bar). Hosted in a dedicated `NSWindow` created by
/// `AppDelegate.showOnboarding()`. Closing that window before Finish / Skip
/// setup leaves the completed flag unset, so the wizard opens again on the next
/// launch.
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
    private var discordPresenceEnabled = AppConstants.UserDefaults.Defaults.discordPresenceEnabled

    @AppStorage(AppConstants.UserDefaults.websocketEnabled)
    private var websocketEnabled = false

    @AppStorage(AppConstants.UserDefaults.launchAtLogin)
    private var launchAtLogin = false

    /// Called when onboarding completes to dismiss the window.
    var onComplete: () -> Void

    /// Tracks navigation direction for slide transitions.
    @State private var navigationDirection: Edge = .trailing

    /// Re-read on every step change so the primary button's "Skip" label stays
    /// in sync with permission grants without each step publishing state up.
    /// Seeded from the last persisted decision (a cheap defaults read) and then
    /// filled by an off-main probe (see `refreshMusicPermissionState()`), so
    /// building the view never blocks on the Apple Events check.
    @State private var musicPermissionState: MusicPermissionState =
        MusicPermissionChecker.loadPersisted() ?? .unknown

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
                    progressHeader
                        .padding(.top, DSSpace.s7)
                        .padding(.bottom, DSSpace.s4)

                    GeometryReader { geo in
                        ScrollView(.vertical) {
                            stepContent
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: geo.size.height, alignment: .top)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .animation(reduceMotion ? nil : DSMotion.Spring.snappy, value: viewModel.currentStep)
                    }

                    Divider()

                    navigationBar
                        .padding(.horizontal, DSSpace.s8)
                        .padding(.vertical, DSSpace.s5)
                }
            }
        }
        .frame(
            width: AppConstants.OnboardingUI.windowWidth,
            height: AppConstants.OnboardingUI.windowHeight
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(
            reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.slow),
            value: viewModel.showCompletion
        )
        .task(id: viewModel.currentStep) {
            await refreshMusicPermissionState()
        }
        .onDisappear {
            twitchViewModel.requestOAuthCancellation(ifOwnedBy: twitchOAuthOwner)
        }
    }

    // MARK: - Progress Header

    /// One dot per step plus "Step N of M · Name", so it's always clear how
    /// much is left. VoiceOver reads the whole header as one element.
    private var progressHeader: some View {
        VStack(spacing: DSSpace.s2) {
            HStack(spacing: DSSpace.s1h) {
                ForEach(OnboardingViewModel.OnboardingStep.allCases, id: \.rawValue) { step in
                    Capsule()
                        .fill(dotColor(for: step))
                        .frame(
                            width: step == viewModel.currentStep ? DSSpace.s6 : DSSpace.s1h,
                            height: DSSpace.s1h
                        )
                        .motionSafe(DSMotion.Spring.gentle, value: viewModel.currentStep)
                }
            }

            Text("\(viewModel.currentStep.progressText) · \(viewModel.currentStep.accessibilityTitle)")
                .font(.system(size: DSFont.Size.sm, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        // One element whose label is the whole sentence. A label (rather than
        // a value on a "Setup progress" label) is what both VoiceOver and the
        // UI tests read reliably for a non-control element on macOS.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progressLabel)
        .accessibilityIdentifier("onboarding.progress")
    }

    /// "Setup progress. Step 2 of 7: Apple Music", spoken as one sentence.
    private var progressLabel: String {
        let step = viewModel.currentStep
        return "Setup progress. \(step.progressText): \(step.accessibilityTitle)"
    }

    /// Done steps and the current one take the accent; steps ahead stay grey.
    private func dotColor(for step: OnboardingViewModel.OnboardingStep) -> Color {
        step.rawValue <= viewModel.currentStep.rawValue
            ? Color.accentColor
            : Color.secondary.opacity(0.3)
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
            case .permissions:
                OnboardingPermissionsStepView()
            case .discordConnect:
                OnboardingDiscordStepView(presenceEnabled: $discordPresenceEnabled)
            case .twitchConnect:
                OnboardingTwitchStepView(
                    twitchViewModel: twitchViewModel,
                    oauthOwner: twitchOAuthOwner
                )
            case .obsWidget:
                OnboardingOBSWidgetStepView(websocketEnabled: $websocketEnabled)
            case .notifications:
                OnboardingNotificationsStepView()
            case .preferences:
                OnboardingPreferencesStepView(launchAtLogin: $launchAtLogin)
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

    /// Back and Skip setup on the left; one primary button on the right.
    ///
    /// The primary button reads **Skip** while a step's main action (Twitch
    /// sign-in, Apple Music access) is still undone, **Next** otherwise, and
    /// **Finish** on the last step. One button, so there is never a Skip and a
    /// Next side by side that do the same thing.
    ///
    /// Every exit path calls `cancelTwitchOAuthIfNeeded()` first, so a pending
    /// device-code poll never outlives the Twitch step.
    private var navigationBar: some View {
        HStack(spacing: DSSpace.s4) {
            // Back is laid out (hidden) on step one so the bar never shifts.
            Button("Back") {
                navigationDirection = .leading
                cancelTwitchOAuthIfNeeded()
                viewModel.goToPreviousStep()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            // Escape steps back. Never bound to anything that ends setup.
            .keyboardShortcut(viewModel.isFirstStep ? nil : .cancelAction)
            .pointerCursor()
            .opacity(viewModel.isFirstStep ? 0 : 1)
            .disabled(viewModel.isFirstStep)
            .accessibilityHidden(viewModel.isFirstStep)
            .accessibilityLabel("Back")
            .accessibilityHint("Returns to the previous step")
            .accessibilityIdentifier("onboarding.back")

            Spacer()

            if !viewModel.isLastStep {
                Button("Skip setup") {
                    finishOnboarding(skipped: true)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .pointerCursor()
                .accessibilityHint("Ends setup now. You can change everything later in Settings.")
                .accessibilityIdentifier("onboarding.skipAll")
            }

            primaryButton
        }
        // Keep the bar still while the step content animates; only the content
        // area should move on a step change.
        .transaction { $0.animation = nil }
    }

    /// Next / Skip / Finish. Bound to Return except on the Twitch step, whose
    /// channel field owns Return (it submits the join, and would otherwise also
    /// advance the wizard before the join result is shown).
    @ViewBuilder
    private var primaryButton: some View {
        if viewModel.isLastStep {
            Button("Finish") {
                finishOnboarding()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .pointerCursor()
            .accessibilityHint("Finishes setup")
            .accessibilityIdentifier("onboarding.finish")
        } else {
            Button(shouldOfferSkip ? "Skip" : "Next") {
                navigationDirection = .trailing
                cancelTwitchOAuthIfNeeded()
                viewModel.goToNextStep()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(nextShortcut)
            .pointerCursor()
            .accessibilityHint(
                shouldOfferSkip
                    ? "Moves on without finishing this step. You can do it later in Settings."
                    : "Goes to the next step"
            )
            .accessibilityIdentifier("onboarding.next")
        }
    }

    // MARK: - Helpers

    /// Return-key shortcut for Next. Nil on the Twitch step, whose channel
    /// field owns Return.
    private var nextShortcut: KeyboardShortcut? {
        viewModel.currentStep == .twitchConnect ? nil : .defaultAction
    }

    /// Whether the primary button should read "Skip": the step's main action is
    /// a sign-in or a system grant that hasn't happened yet.
    ///
    /// Twitch: until a sign-in is saved. Apple Music: until the Automation grant
    /// is `.granted`, read from `musicPermissionState`, which is refreshed on
    /// each step change rather than live.
    private var shouldOfferSkip: Bool {
        switch viewModel.currentStep {
        case .twitchConnect:
            return !twitchViewModel.credentialsSaved
        case .permissions:
            return musicPermissionState != .granted
        default:
            return false
        }
    }

    /// Re-probes the Music Automation grant on a detached task, because the
    /// Apple Events check can take tens of milliseconds, then applies the
    /// result back on the main actor.
    private func refreshMusicPermissionState() async {
        let state = await Task.detached(priority: .userInitiated) {
            MusicPermissionChecker.currentState()
        }.value
        musicPermissionState = state
    }

    /// Cancels any in-progress Twitch OAuth polling when leaving the Twitch step.
    private func cancelTwitchOAuthIfNeeded() {
        guard viewModel.currentStep == .twitchConnect else { return }
        if case .authorizing = twitchViewModel.integrationState {
            twitchViewModel.requestOAuthCancellation(ifOwnedBy: twitchOAuthOwner)
        }
    }

    /// Persists the completion flag and shows the ending screen. Skip setup
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
