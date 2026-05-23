//
//  OnboardingViewModelTests.swift
//  WolfWaveTests
//
//  Created by MrDemonWolf, Inc. on 2/13/26.
//

import XCTest
@testable import WolfWave

nonisolated final class OnboardingViewModelTests: XCTestCase {
    nonisolated(unsafe) var viewModel: OnboardingViewModel!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        viewModel = OnboardingViewModel()
        UserDefaults.standard.removeObject(forKey: AppConstants.UserDefaults.hasCompletedOnboarding)
    }

    @MainActor
    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: AppConstants.UserDefaults.hasCompletedOnboarding)
        viewModel = nil
        try await super.tearDown()
    }

    // MARK: - Initial State

    @MainActor func testInitialStepIsWelcome() {
        XCTAssertEqual(viewModel.currentStep, .welcome)
    }

    @MainActor func testTotalStepsEquals7() {
        XCTAssertEqual(viewModel.totalSteps, 7)
    }

    @MainActor func testIsFirstStepAtWelcome() {
        XCTAssertTrue(viewModel.isFirstStep)
    }

    @MainActor func testIsNotLastStepAtWelcome() {
        XCTAssertFalse(viewModel.isLastStep)
    }

    // MARK: - Forward Navigation

    @MainActor func testGoToNextStepFromWelcomeReachesDiscord() {
        viewModel.goToNextStep()
        XCTAssertEqual(viewModel.currentStep, .discordConnect)
    }

    @MainActor func testTwoNextStepsReachesTwitch() {
        viewModel.goToNextStep()
        viewModel.goToNextStep()
        XCTAssertEqual(viewModel.currentStep, .twitchConnect)
    }

    @MainActor func testThreeNextStepsReachesOBS() {
        viewModel.goToNextStep()
        viewModel.goToNextStep()
        viewModel.goToNextStep()
        XCTAssertEqual(viewModel.currentStep, .obsWidget)
    }

    @MainActor func testFourNextStepsReachesPreferences() {
        for _ in 0..<4 { viewModel.goToNextStep() }
        XCTAssertEqual(viewModel.currentStep, .preferences)
    }

    @MainActor func testFiveNextStepsReachesAppleMusic() {
        for _ in 0..<5 { viewModel.goToNextStep() }
        XCTAssertEqual(viewModel.currentStep, .appleMusicAccess)
    }

    @MainActor func testSixNextStepsReachesMenuBarPointer() {
        for _ in 0..<6 { viewModel.goToNextStep() }
        XCTAssertEqual(viewModel.currentStep, .menuBarPointer)
    }

    @MainActor func testGoToNextStepAtLastStepStays() {
        for _ in 0..<10 { viewModel.goToNextStep() }
        XCTAssertEqual(viewModel.currentStep, .menuBarPointer)
    }

    // MARK: - Backward Navigation

    @MainActor func testGoToPreviousStepAtFirstStepStays() {
        viewModel.goToPreviousStep()
        XCTAssertEqual(viewModel.currentStep, .welcome)
    }

    @MainActor func testGoToPreviousStepFromDiscord() {
        viewModel.goToNextStep()
        viewModel.goToPreviousStep()
        XCTAssertEqual(viewModel.currentStep, .welcome)
    }

    @MainActor func testGoToPreviousStepFromTwitch() {
        viewModel.goToNextStep()
        viewModel.goToNextStep()
        viewModel.goToPreviousStep()
        XCTAssertEqual(viewModel.currentStep, .discordConnect)
    }

    // MARK: - Step Properties

    @MainActor func testIsNotFirstStepAtDiscord() {
        viewModel.goToNextStep()
        XCTAssertFalse(viewModel.isFirstStep)
    }

    @MainActor func testIsNotLastStepInMiddle() {
        for _ in 0..<3 { viewModel.goToNextStep() }
        XCTAssertFalse(viewModel.isLastStep)
    }

    @MainActor func testIsLastStepAtMenuBarPointer() {
        for _ in 0..<6 { viewModel.goToNextStep() }
        XCTAssertTrue(viewModel.isLastStep)
    }

    // MARK: - Completion

    @MainActor func testCompleteOnboardingSetsFlag() {
        viewModel.completeOnboarding()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: AppConstants.UserDefaults.hasCompletedOnboarding))
    }

    @MainActor func testHasCompletedOnboardingReadsTrue() {
        UserDefaults.standard.set(true, forKey: AppConstants.UserDefaults.hasCompletedOnboarding)
        XCTAssertTrue(OnboardingViewModel.hasCompletedOnboarding)
    }

    @MainActor func testHasCompletedOnboardingReadsFalse() {
        UserDefaults.standard.set(false, forKey: AppConstants.UserDefaults.hasCompletedOnboarding)
        XCTAssertFalse(OnboardingViewModel.hasCompletedOnboarding)
    }

    @MainActor func testHasCompletedOnboardingDefaultsFalse() {
        UserDefaults.standard.removeObject(forKey: AppConstants.UserDefaults.hasCompletedOnboarding)
        XCTAssertFalse(OnboardingViewModel.hasCompletedOnboarding)
    }

    // MARK: - Full Navigation Cycle

    @MainActor func testFullNavigationCycleForwardAndBack() {
        XCTAssertEqual(viewModel.currentStep, .welcome)

        let order: [OnboardingViewModel.OnboardingStep] = [
            .discordConnect, .twitchConnect, .obsWidget, .preferences, .appleMusicAccess, .menuBarPointer
        ]

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
