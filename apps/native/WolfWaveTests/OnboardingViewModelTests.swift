//
//  OnboardingViewModelTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-02-13.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest
@testable import WolfWave

/// `OnboardingViewModel` step order and navigation, and its persistence in `DefaultsStore.store`.
/// The step count and order are pinned here, so adding a step means updating these tests.
@MainActor
final class OnboardingViewModelTests: WolfWaveTestCase {
    var viewModel: OnboardingViewModel!

    override func setUp() async throws {
        try await super.setUp()
        viewModel = OnboardingViewModel()
        resetAllSettings()
    }

    override func tearDown() async throws {
        resetAllSettings()
        viewModel = nil
        try await super.tearDown()
    }

    // MARK: - Initial State

    func testInitialStepIsWelcome() {
        XCTAssertEqual(viewModel.currentStep, .welcome)
    }

    func testTotalStepsEquals7() {
        XCTAssertEqual(OnboardingViewModel.OnboardingStep.allCases.count, 7)
    }

    /// Apple Music access is step two: everything else depends on it.
    func testAppleMusicComesStraightAfterWelcome() {
        XCTAssertEqual(OnboardingViewModel.OnboardingStep.allCases.first, .welcome)
        XCTAssertEqual(OnboardingViewModel.OnboardingStep(rawValue: 1), .permissions)
    }

    /// Permissions and Notifications stay two separate screens.
    func testPermissionsAndNotificationsAreSeparateSteps() {
        XCTAssertNotEqual(
            OnboardingViewModel.OnboardingStep.permissions,
            OnboardingViewModel.OnboardingStep.notifications
        )
    }

    func testProgressTextCountsFromOne() {
        XCTAssertEqual(OnboardingViewModel.OnboardingStep.welcome.progressText, "Step 1 of 7")
        XCTAssertEqual(OnboardingViewModel.OnboardingStep.preferences.progressText, "Step 7 of 7")
    }

    func testEveryStepHasADistinctName() {
        let names = OnboardingViewModel.OnboardingStep.allCases.map(\.accessibilityTitle)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertFalse(names.contains(""))
    }

    func testIsFirstStepAtWelcome() {
        XCTAssertTrue(viewModel.isFirstStep)
    }

    func testIsNotLastStepAtWelcome() {
        XCTAssertFalse(viewModel.isLastStep)
    }

    // MARK: - Forward Navigation

    /// Forward order, step by step: `next` calls from Welcome reach each step.
    private static let forwardOrder: [OnboardingViewModel.OnboardingStep] = [
        .permissions, .discordConnect, .twitchConnect, .obsWidget, .notifications, .preferences
    ]

    func testEachNextStepFollowsTheOrder() {
        for (index, expected) in Self.forwardOrder.enumerated() {
            viewModel.goToNextStep()
            XCTAssertEqual(viewModel.currentStep, expected, "Next #\(index + 1)")
        }
    }

    func testGoToNextStepAtLastStepStays() {
        for _ in 0..<10 { viewModel.goToNextStep() }
        XCTAssertEqual(viewModel.currentStep, .preferences)
    }

    // MARK: - Backward Navigation

    func testGoToPreviousStepAtFirstStepStays() {
        viewModel.goToPreviousStep()
        XCTAssertEqual(viewModel.currentStep, .welcome)
    }

    func testGoToPreviousStepFromAppleMusic() {
        viewModel.goToNextStep()
        viewModel.goToPreviousStep()
        XCTAssertEqual(viewModel.currentStep, .welcome)
    }

    func testGoToPreviousStepFromTwitch() {
        for _ in 0..<3 { viewModel.goToNextStep() }
        XCTAssertEqual(viewModel.currentStep, .twitchConnect)
        viewModel.goToPreviousStep()
        XCTAssertEqual(viewModel.currentStep, .discordConnect)
    }

    // MARK: - Step Properties

    func testIsNotFirstStepAtAppleMusic() {
        viewModel.goToNextStep()
        XCTAssertFalse(viewModel.isFirstStep)
    }

    func testIsNotLastStepInMiddle() {
        for _ in 0..<3 { viewModel.goToNextStep() }
        XCTAssertFalse(viewModel.isLastStep)
    }

    func testIsLastStepAtPreferences() {
        for _ in 0..<6 { viewModel.goToNextStep() }
        XCTAssertEqual(viewModel.currentStep, .preferences)
        XCTAssertTrue(viewModel.isLastStep)
    }

    // MARK: - Completion

    func testCompleteOnboardingSetsFlag() {
        viewModel.completeOnboarding()
        XCTAssertTrue(DefaultsStore.store.bool(forKey: AppConstants.UserDefaults.hasCompletedOnboarding))
    }

    func testHasCompletedOnboardingReadsTrue() {
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.hasCompletedOnboarding)
        XCTAssertTrue(OnboardingViewModel.hasCompletedOnboarding)
    }

    func testHasCompletedOnboardingReadsFalse() {
        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.hasCompletedOnboarding)
        XCTAssertFalse(OnboardingViewModel.hasCompletedOnboarding)
    }

    func testHasCompletedOnboardingDefaultsFalse() {
        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.hasCompletedOnboarding)
        XCTAssertFalse(OnboardingViewModel.hasCompletedOnboarding)
    }

    // MARK: - Full Navigation Cycle

    func testFullNavigationCycleForwardAndBack() {
        XCTAssertEqual(viewModel.currentStep, .welcome)

        let order = Self.forwardOrder

        for expected in order {
            viewModel.goToNextStep()
            XCTAssertEqual(viewModel.currentStep, expected)
        }

        for expected in order.dropLast().reversed() + [.welcome] {
            viewModel.goToPreviousStep()
            XCTAssertEqual(viewModel.currentStep, expected)
        }
    }
}
