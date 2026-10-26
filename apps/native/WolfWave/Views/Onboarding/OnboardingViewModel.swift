//
//  OnboardingViewModel.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-02-06.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Observation

/// Manages step navigation and completion persistence for the onboarding wizard.
///
/// Owns only the wizard's position and its ending. Each step's own settings are
/// written by that step's view (through `@AppStorage` bindings or services), so
/// leaving the wizard early keeps whatever the user already changed.
@MainActor
@Observable
final class OnboardingViewModel {

    // MARK: - Step Definition

    /// Ordered onboarding steps.
    ///
    /// Core first: Apple Music access is the one thing WolfWave can't work
    /// without, so it comes straight after Welcome. Then the three integrations
    /// (Discord, Twitch, overlay), then alerts and Mac settings. Permissions and
    /// Notifications stay two screens so each has one job. "Find WolfWave in the
    /// menu bar" lives on the completion screen, which every ending reaches.
    ///
    /// Raw values must stay contiguous from `0`: navigation steps by `rawValue ± 1`
    /// and the progress header reports `rawValue + 1` as the step number.
    enum OnboardingStep: Int, CaseIterable {
        case welcome = 0
        case permissions = 1
        case discordConnect = 2
        case twitchConnect = 3
        case obsWidget = 4
        case notifications = 5
        case preferences = 6

        /// Short name shown beside the progress dots and spoken by VoiceOver
        /// (e.g. "Step 4 of 7: Twitch").
        nonisolated var accessibilityTitle: String {
            switch self {
            case .welcome: return "Welcome"
            case .permissions: return "Apple Music"
            case .discordConnect: return "Discord"
            case .twitchConnect: return "Twitch"
            case .obsWidget: return "Stream overlay"
            case .notifications: return "Alerts"
            case .preferences: return "Mac settings"
            }
        }

        /// "Step 4 of 7", for the progress header.
        nonisolated var progressText: String {
            "Step \(rawValue + 1) of \(Self.allCases.count)"
        }
    }

    // MARK: - Observable State

    /// The step on screen. Changes go through `goToNextStep()` / `goToPreviousStep()`.
    var currentStep: OnboardingStep = .welcome
    /// `true` once `completeOnboarding(skipped:)` runs; swaps the wizard for
    /// `OnboardingCompletionView`.
    var showCompletion = false
    /// `true` when the wizard ended through Skip setup, so the completion screen
    /// can use its lighter "Skipped" copy.
    private(set) var completedBySkipping = false

    // MARK: - Navigation

    /// Whether the wizard is on its first step (Back is hidden there).
    var isFirstStep: Bool {
        currentStep == OnboardingStep.allCases.first
    }

    /// Whether the wizard is on its last step (Next becomes Finish, Skip setup hides).
    var isLastStep: Bool {
        currentStep == OnboardingStep.allCases.last
    }

    /// Advances to the next step if one exists. A no-op on the last step.
    func goToNextStep() {
        guard let next = OnboardingStep(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
    }

    /// Returns to the previous step if one exists. A no-op on the first step.
    func goToPreviousStep() {
        guard let prev = OnboardingStep(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prev
    }

    // MARK: - Completion

    /// Persists the onboarding-completed flag so the wizard won't show again.
    ///
    /// The flag is written before the completion screen appears, so quitting
    /// during the celebration still counts as completed. Skip setup writes the
    /// same flag: a skipped wizard does not come back on the next launch.
    ///
    /// - Parameter skipped: Pass `true` when the user chose Skip setup, so the
    ///   completion screen shows the lighter "Skipped" ending.
    func completeOnboarding(skipped: Bool = false) {
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.hasCompletedOnboarding)
        completedBySkipping = skipped
        showCompletion = true
        Log.info(
            skipped ? "OnboardingViewModel: Onboarding skipped" : "OnboardingViewModel: Onboarding completed",
            category: .app
        )
    }

    /// Whether onboarding has been completed on a previous launch.
    ///
    /// Read by `AppDelegate` at launch to decide whether to open the wizard.
    static var hasCompletedOnboarding: Bool {
        Preferences.hasCompletedOnboarding
    }
}
