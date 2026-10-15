//
//  SongRequestSetupViewModel.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-06-08.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Observation

/// Drives the guided Song Requests setup sheet: step navigation, per-step
/// "can I move on yet" gating, and writing the completion flag.
///
/// Setup must clear three essentials before the feature can be enabled (Twitch
/// connected, Apple Music access, and the WolfWave Requests playlist created).
/// The public share link for `!playlist` is an optional fourth step that never
/// blocks finishing. The steps push their live state up into this model so the
/// Next-button gating stays here and stays testable. Mirrors
/// `OnboardingViewModel`.
@MainActor
@Observable
final class SongRequestSetupViewModel {

    // MARK: - Step Definition

    /// Ordered setup steps. `shareLink` is optional and always skippable.
    /// Raw values are the order; navigation steps by `rawValue ± 1`.
    enum Step: Int, CaseIterable {
        /// Explains the feature; gates on a live Twitch connection.
        case intro = 0
        /// Gates on the MusicKit / Automation grant.
        case appleMusic = 1
        /// Gates on the WolfWave Requests playlist existing.
        case playlist = 2
        /// Optional public link for `!playlist`.
        case shareLink = 3
        /// Summary and Finish.
        case done = 4

        /// Short spoken name for the progress indicator's accessibility value.
        nonisolated var accessibilityTitle: String {
            switch self {
            case .intro: return "Intro"
            case .appleMusic: return "Apple Music"
            case .playlist: return "Playlist"
            case .shareLink: return "Song list link"
            case .done: return "Done"
            }
        }

        /// Friendlier label shown under the progress dots (e.g. "Apple Music access").
        nonisolated var progressTitle: String {
            switch self {
            case .intro: return "Get started"
            case .appleMusic: return "Apple Music access"
            case .playlist: return "Requests playlist"
            case .shareLink: return "Share link (optional)"
            case .done: return "All set"
            }
        }
    }

    // MARK: - Observable State

    /// The step on screen.
    var currentStep: Step

    /// Live inputs the step views update so the Next gate lives in one place and
    /// is unit-testable without rendering.
    /// Gates `.intro`.
    var isTwitchConnected = false
    /// Gates `.appleMusic`.
    var musicAuthorized = false
    /// Gates `.playlist`.
    var playlistReady = false

    // MARK: - Init

    /// - Parameter startAt: The step to open on. The pane opens at `.intro` for a
    ///   fresh setup, or `.shareLink` when the streamer taps "Re-share Playlist"
    ///   on the broken-playlist banner.
    init(startAt: Step = .intro) {
        self.currentStep = startAt
    }

    // MARK: - Navigation

    /// Hides Back on the first step.
    var isFirstStep: Bool { currentStep == Step.allCases.first }
    /// Swaps Next for Finish on the last step.
    var isLastStep: Bool { currentStep == Step.allCases.last }
    /// Step count for the progress indicator.
    var totalSteps: Int { Step.allCases.count }

    /// Whether the wizard may advance from the current step. The optional
    /// `shareLink` step never blocks; the three essentials each gate on their
    /// own live state.
    var canAdvance: Bool {
        switch currentStep {
        case .intro: return isTwitchConnected
        case .appleMusic: return musicAuthorized
        case .playlist: return playlistReady
        case .shareLink, .done: return true
        }
    }

    /// Moves forward one step; no-op on the last. Does not check `canAdvance`;
    /// the Next button is disabled by the view instead.
    func goToNextStep() {
        guard let next = Step(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
    }

    /// Moves back one step; no-op on the first.
    func goToPreviousStep() {
        guard let prev = Step(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prev
    }

    // MARK: - Completion

    /// Records the gate, clears any stale health banner, and turns the feature
    /// on. Finishing the wizard is an explicit "go" signal, so the master toggle
    /// flips on; the streamer can turn it off in the pane afterward. The pane
    /// re-runs the playlist health check on dismiss to confirm the optimistic
    /// `.ok` status.
    ///
    /// Posts `songRequestSettingChanged` (enabled) so the service starts.
    ///
    /// - Parameter defaults: Store to write to; injectable for tests.
    func complete(defaults: Foundation.UserDefaults = DefaultsStore.store) {
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestSetupComplete)
        defaults.set(PlaylistSetupStatus.ok.rawValue, forKey: AppConstants.UserDefaults.songRequestPlaylistStatus)
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)
        NotificationCenter.default.postEnabled(.songRequestSettingChanged, enabled: true)
        Log.info("SongRequestSetupViewModel: Setup completed", category: .songRequest)
    }
}
