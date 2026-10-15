//
//  OnboardingCompletionViewTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-26.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest
import SwiftUI
@testable import WolfWave

/// `OnboardingCompletionView`: the dismiss timing, the VoiceOver rule (no auto-dismiss while it is
/// running), and the Skipped vs Completed copy.
@MainActor
final class OnboardingCompletionViewTests: XCTestCase {

    // MARK: - Dismiss Contract

    /// The view auto-dismisses after the animation window. Window is ~1.8s
    /// under normal motion (280ms hero + 1500ms text hold) and ~1.2s under
    /// Reduce Motion. Test the contract with a generous timeout.
    func testOnDismissFiresAfterAnimationWindow() async {
        let expectation = expectation(description: "onDismiss invoked")
        expectation.assertForOverFulfill = false

        let view = OnboardingCompletionView {
            expectation.fulfill()
        }

        // Render off-screen to trigger `.task`.
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        // Force a layout pass so the task modifier fires.
        host.layoutSubtreeIfNeeded()

        await fulfillment(of: [expectation], timeout: 3.0)
    }

    // MARK: - VoiceOver Policy

    func testAutoDismissIsOffWhileVoiceOverRuns() {
        XCTAssertFalse(OnboardingCompletionView.shouldAutoDismiss(voiceOverEnabled: true))
    }

    func testAutoDismissIsOnWithoutVoiceOver() {
        XCTAssertTrue(OnboardingCompletionView.shouldAutoDismiss(voiceOverEnabled: false))
    }

    // MARK: - Style Copy

    func testSkippedStyleUsesLighterCopy() {
        XCTAssertEqual(OnboardingCompletionView.Style.skipped.title, "Skipped.")
        XCTAssertTrue(OnboardingCompletionView.Style.skipped.message.contains("Settings"))
    }

    func testCompletedAndSkippedCopyDiffer() {
        let completed = OnboardingCompletionView.Style.completed
        let skipped = OnboardingCompletionView.Style.skipped
        XCTAssertNotEqual(completed.title, skipped.title)
        XCTAssertNotEqual(completed.message, skipped.message)
        XCTAssertNotEqual(completed.accessibilitySummary, skipped.accessibilitySummary)
    }

    // MARK: - Copyright

    /// The footer names the configured holder, not a hardcoded one, so a fork
    /// that sets `COPYRIGHT_HOLDER` sees its own name.
    func testCopyrightLineUsesConfiguredHolder() {
        XCTAssertEqual(
            OnboardingCompletionView.copyrightLine(year: 2030, holder: "Fork Co."),
            "© 2030 Fork Co."
        )
        XCTAssertEqual(
            OnboardingCompletionView.copyrightLine(year: 2030),
            "© 2030 \(AppConstants.AppInfo.copyrightHolder)"
        )
    }
}
