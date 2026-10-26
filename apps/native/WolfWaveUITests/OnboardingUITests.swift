//
//  OnboardingUITests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-08-17.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

/// Drives the first-launch wizard end to end through its real windows.
///
/// The unit suite already covers `OnboardingViewModel`'s step order and its
/// persistence. What it cannot see is whether the wizard is reachable at all:
/// the window opening, the buttons being hit-testable, and the flag actually
/// closing the loop so the next launch skips it. That whole path is what breaks
/// in practice, and only a real launch exercises it.
@MainActor
final class OnboardingUITests: WolfWaveUITestCase {

    /// Identifiers declared by the wizard's navigation bar. Behaviour, not
    /// decoration: renaming one here without renaming it in the app is a test
    /// that silently stops testing.
    private enum ID {
        static let next = "onboarding.next"
        static let finish = "onboarding.finish"
        static let back = "onboarding.back"
        static let skipAll = "onboarding.skipAll"
        static let done = "onboarding.done"
        static let progress = "onboarding.progress"
    }

    /// Upper bound on wizard steps. Guards the walk loop against an infinite
    /// spin if `finish` never appears; the failure then names the real problem
    /// rather than hanging the run until the scheme timeout.
    private static let maxSteps = 20

    func testFirstLaunchOpensTheWizard() {
        let window = app.windows[UITestWindow.onboarding]
        expect(window, "the onboarding window on a first launch")
        expect(app.buttons[ID.next], "the wizard's Next button")
    }

    func testWalkingEveryStepFinishesOnboarding() {
        expect(app.buttons[ID.next], "the wizard's Next button")

        var steps = 0
        while !app.buttons[ID.finish].exists {
            XCTAssertLessThan(
                steps, Self.maxSteps,
                "Walked \(Self.maxSteps) steps without reaching the last one. "
                    + "Either a step stopped advancing or `onboarding.finish` is gone."
            )
            let next = app.buttons[ID.next]
            XCTAssertTrue(next.isHittable, "Next was not hittable on step \(steps + 1)")
            next.click()
            steps += 1
        }

        // The wizard has more than a couple of steps; reaching `finish`
        // immediately would mean the walk never actually advanced.
        XCTAssertGreaterThan(steps, 1, "Reached the last step without advancing through the wizard")

        app.buttons[ID.finish].click()
        XCTAssertTrue(
            app.windows[UITestWindow.onboarding].waitForNonExistence(timeout: Self.timeout),
            "The onboarding window stayed open after Finish"
        )
    }

    func testBackReturnsToThePreviousStep() {
        expect(app.buttons[ID.next], "the wizard's Next button")

        // The wizard keeps Back mounted on step one for layout stability but
        // marks it `accessibilityHidden`, so it is genuinely absent from the
        // tree until step two. Its appearing and disappearing IS the signal
        // that the step changed.
        XCTAssertFalse(app.buttons[ID.back].exists, "Back was exposed on the first step")
        app.buttons[ID.next].click()

        let back = app.buttons[ID.back]
        XCTAssertTrue(back.waitForExistence(timeout: Self.timeout), "Back never appeared on step two")
        back.click()
        XCTAssertTrue(
            app.buttons[ID.back].waitForNonExistence(timeout: Self.timeout),
            "Back stayed exposed after returning to the first step"
        )
    }

    /// Escape steps back, and is never bound to anything that ends setup.
    func testEscapeGoesBackAStep() {
        expect(app.buttons[ID.next], "the wizard's Next button")
        app.buttons[ID.next].click()
        expect(app.buttons[ID.back], "Back on step two")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            app.buttons[ID.back].waitForNonExistence(timeout: Self.timeout),
            "Escape did not return to the first step"
        )
        XCTAssertTrue(app.windows[UITestWindow.onboarding].exists, "Escape closed the wizard")
    }

    /// The progress header says where you are, in words, not just dots.
    func testProgressHeaderNamesTheStep() {
        let progress = app.descendants(matching: .any)[ID.progress]
        expect(progress, "the progress header")
        XCTAssertEqual(progress.label, "Setup progress. Step 1 of 7: Welcome")

        app.buttons[ID.next].click()
        let advanced = NSPredicate(format: "label == %@", "Setup progress. Step 2 of 7: Apple Music")
        let moved = expectation(for: advanced, evaluatedWith: progress)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: Self.timeout), .completed)
    }

    func testSkipAllClosesTheWizard() {
        let skipAll = app.buttons[ID.skipAll]
        expect(skipAll, "the wizard's Skip All button")
        skipAll.click()
        XCTAssertTrue(
            app.windows[UITestWindow.onboarding].waitForNonExistence(timeout: Self.timeout),
            "The onboarding window stayed open after Skip All"
        )
    }

    // MARK: - Screenshot Capture

    /// Attaches a screenshot of every wizard step and both endings, in light
    /// and dark appearance.
    ///
    /// Assertion-light on purpose, like `SettingsUITests.testCapturesEveryPane`:
    /// layout, hierarchy, and contrast are things a person has to look at. Export
    /// the PNGs with
    ///
    ///     xcrun xcresulttool export attachments \
    ///       --path DerivedData/Tests/Logs/Test/<newest>.xcresult \
    ///       --output-path /tmp/onboarding
    ///
    /// `manifest.json` beside the exported files maps each UUID back to its name.
    func testCapturesEveryStep() {
        for appearance in ["light", "dark"] {
            launch(with: LaunchOptions(appearance: appearance, holdCompletion: true))
            let window = app.windows[UITestWindow.onboarding]
            expect(window, "the onboarding window in \(appearance) appearance")
            waitUntilHittable(app.buttons[ID.next], "the wizard's Next button")

            var step = 1
            while true {
                capture(window, named: "Onboarding \(appearance) \(String(format: "%02d", step))")
                if app.buttons[ID.finish].exists { break }
                XCTAssertLessThan(step, Self.maxSteps, "Never reached the last step")
                app.buttons[ID.next].click()
                step += 1
                // Let the step transition settle so the shot is not mid-slide.
                Thread.sleep(forTimeInterval: 0.6)
            }

            app.buttons[ID.finish].click()
            // `holdCompletion` keeps the ending up; wait for Done, then let the
            // entrance animation finish.
            expect(app.buttons[ID.done], "the completion screen's Done button")
            Thread.sleep(forTimeInterval: 1.0)
            capture(window, named: "Onboarding \(appearance) \(String(format: "%02d", step + 1)) completed")

            launch(with: LaunchOptions(appearance: appearance, holdCompletion: true))
            let skipAll = app.buttons[ID.skipAll]
            waitUntilHittable(skipAll, "the wizard's Skip All button")
            skipAll.click()
            expect(app.buttons[ID.done], "the skipped ending's Done button")
            Thread.sleep(forTimeInterval: 1.0)
            capture(app.windows[UITestWindow.onboarding], named: "Onboarding \(appearance) \(String(format: "%02d", step + 2)) skipped")
        }
    }

    /// Activates the app and waits until `element` can take a click. An
    /// inactive app reports everything as unhittable, and a window shot taken
    /// then is of whatever covers it.
    private func waitUntilHittable(_ element: XCUIElement, _ description: String) {
        app.activate()
        let hittable = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [hittable], timeout: Self.timeout), .completed,
            "Timed out waiting for \(description) to be clickable"
        )
    }

    /// Adds `window`'s screenshot as a kept attachment. Activates first so the
    /// onboarding window is frontmost: `screenshot()` grabs screen pixels.
    private func capture(_ window: XCUIElement, named name: String) {
        app.activate()
        Thread.sleep(forTimeInterval: 0.3)
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = name
        // XCTest drops attachments from passing tests unless told otherwise.
        shot.lifetime = .keepAlways
        add(shot)
    }
}
