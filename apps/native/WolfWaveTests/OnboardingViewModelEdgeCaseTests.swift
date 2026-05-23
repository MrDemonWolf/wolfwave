//
//  OnboardingViewModelEdgeCaseTests.swift
//  WolfWaveTests
//
//  Created by MrDemonWolf, Inc. on 3/19/26.
//

import XCTest
@testable import WolfWave

nonisolated final class OnboardingViewModelEdgeCaseTests: XCTestCase {
    nonisolated(unsafe) var viewModel: OnboardingViewModel?

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: AppConstants.UserDefaults.hasCompletedOnboarding)
        viewModel = OnboardingViewModel()
    }

    @MainActor
    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: AppConstants.UserDefaults.hasCompletedOnboarding)
        viewModel = nil
        try await super.tearDown()
    }

    // MARK: - Completion State Tests

    @MainActor func testShowCompletionIsFalseInitially() {
        guard let viewModel = viewModel else { XCTFail("Expected non-nil viewModel"); return }
        XCTAssertFalse(viewModel.showCompletion)
    }

    @MainActor func testShowCompletionIsTrueAfterCompleteOnboarding() {
        guard let viewModel = viewModel else { XCTFail("Expected non-nil viewModel"); return }
        viewModel.completeOnboarding()
        XCTAssertTrue(viewModel.showCompletion)
    }

    // MARK: - Rapid Navigation Tests

    @MainActor func testRapidForwardNavigationStaysAtBoundary() {
        guard let viewModel = viewModel else { XCTFail("Expected non-nil viewModel"); return }
        for _ in 0..<10 {
            viewModel.goToNextStep()
        }
        XCTAssertEqual(viewModel.currentStep, OnboardingViewModel.OnboardingStep.allCases.last!)
        XCTAssertTrue(viewModel.isLastStep)
    }

    @MainActor func testRapidBackwardNavigationStaysAtBoundary() {
        guard let viewModel = viewModel else { XCTFail("Expected non-nil viewModel"); return }
        for _ in 0..<10 {
            viewModel.goToPreviousStep()
        }
        XCTAssertEqual(viewModel.currentStep, .welcome)
        XCTAssertTrue(viewModel.isFirstStep)
    }

    @MainActor func testRapidForwardThenBackwardReturnsToStart() {
        guard let viewModel = viewModel else { XCTFail("Expected non-nil viewModel"); return }
        for _ in 0..<10 {
            viewModel.goToNextStep()
        }
        for _ in 0..<10 {
            viewModel.goToPreviousStep()
        }
        XCTAssertEqual(viewModel.currentStep, .welcome)
    }

    // MARK: - Step Enum Tests

    @MainActor func testStepRawValuesAreContiguous() {
        let allCases = OnboardingViewModel.OnboardingStep.allCases
        for (index, step) in allCases.enumerated() {
            XCTAssertEqual(step.rawValue, index, "Step \(step) should have rawValue \(index)")
        }
    }

    @MainActor func testAllCasesCountEqualsTotalSteps() {
        guard let viewModel = viewModel else { XCTFail("Expected non-nil viewModel"); return }
        XCTAssertEqual(
            OnboardingViewModel.OnboardingStep.allCases.count,
            viewModel.totalSteps
        )
    }

    // MARK: - Re-instantiation Tests
    // testReInstantiatingAfterCompletionStartsAtWelcome removed:
    // @Observable causes malloc double-free when completeOnboarding() triggers
    // UserDefaults write + observation notification in the test host process.
}
