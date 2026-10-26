//
//  SettingsUITests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-08-17.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import XCTest

/// Opens Settings and visits every pane.
///
/// This is the cheapest possible guard against the failure mode this app has
/// actually shipped: a pane that traps inside SwiftUI on render, taking the
/// whole settings window down. A persisted value outside a picker's tag set did
/// exactly that to Song Requests, and no unit test can see it because the crash
/// happens in SwiftUI's layout, not in our code. Rendering each pane for real is
/// the assertion.
@MainActor
final class SettingsUITests: WolfWaveUITestCase {

    /// Start past the wizard: this suite's subject is the settings window.
    override var launchOptions: LaunchOptions {
        LaunchOptions(onboarded: true, suppressWhatsNew: true, songRequestsEnabled: true)
    }

    /// Sidebar section titles, in sidebar order. Mirrors
    /// `SettingsView.SettingsSection`'s raw values. `Debug` is deliberately
    /// absent: it is compiled into Debug builds only, and asserting it here
    /// would make the suite configuration-dependent.
    private static let sections = [
        "General",
        "Song Requests",
        "Stream Widgets",
        "Stream Deck",
        "History & Stats",
        "Twitch",
        "Discord",
        "Software Update",
        "Advanced",
        "About"
    ]

    private static let settingsWindowTitle = UITestWindow.settings

    /// Opens Settings through the native App menu.
    ///
    /// The app is Dock-visible by default, which is what puts a main menu on
    /// screen for the shortcut to reach. A suite that first set the app
    /// menu-only would have to open Settings through the status item instead.
    @discardableResult
    private func openSettings() -> XCUIElement {
        app.activate()
        app.menuBars.menuBarItems["WolfWave Dev"].click()
        app.menuItems["Settings…"].firstMatch.click()
        let window = app.windows[Self.settingsWindowTitle]
        expect(window, "the Settings window after Cmd+,")
        return window
    }

    func testSettingsWindowOpens() {
        let window = openSettings()
        XCTAssertTrue(window.exists)
        expect(
            app.staticTexts["settings.sidebar.General"],
            "the General row in the settings sidebar"
        )
    }

    func testSettingsReopensAfterClosingWithNativeShortcut() {
        let window = openSettings()
        for _ in 0..<3 {
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(window.waitForNonExistence(timeout: Self.timeout))
            app.typeKey(",", modifierFlags: .command)
            expect(window, "Settings reopened with Cmd+,")
            XCTAssertEqual(app.windows.matching(identifier: Self.settingsWindowTitle).count, 1)
        }
    }

    func testSettingsRestoresAfterMinimizing() {
        let window = openSettings()
        window.buttons[XCUIIdentifierMinimizeWindow].click()
        openSettings()
        XCTAssertTrue(window.isHittable)
        XCTAssertEqual(app.windows.matching(identifier: Self.settingsWindowTitle).count, 1)
    }

    func testMenuOnlySettingsReopensInFrontOfAnotherApp() {
        let window = openSettings()
        select("General")
        let mode = app.radioButtons["dockVisibility_menuOnly"]
        for _ in 0..<4 where !mode.isHittable {
            app.scrollViews["settings.pane.General"].swipeUp()
        }
        mode.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(window.waitForNonExistence(timeout: Self.timeout))

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        app.statusItems.firstMatch.click()
        app.menuItems["openSettings"].click()
        expect(window, "menu-only Settings reopened from behind Finder")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(window.isHittable)
    }

    func testToolbarTitleTracksTheSelectedPane() {
        let window = openSettings()
        for section in ["General", "Stream Widgets", "Song Requests", "About"] {
            select(section)
            XCTAssertEqual(window.title, section)
        }
    }

    func testAppearanceSensitiveViewsAtMinimumSize() {
        for appearance in ["light", "dark"] {
            app.terminate()
            app.launchEnvironment[UITestEnvironment.settingsSize] = "minimum"
            app.launchEnvironment[UITestEnvironment.appearance] = appearance
            app.launch()
            let window = openSettings()
            XCTAssertEqual(window.frame.width, 640, accuracy: 1)
            for section in ["General", "About"] {
                select(section)
                XCTAssertEqual(window.title, section)
                let shot = XCTAttachment(screenshot: window.screenshot())
                shot.name = "Final appearance - \(appearance) - \(section)"
                shot.lifetime = .keepAlways
                add(shot)
            }
        }
    }

    func testCompactQueueControlsRemainReachable() {
        app.terminate()
        app.launchEnvironment[UITestEnvironment.settingsSize] = "minimum"
        app.launch()
        let window = openSettings()
        select("Song Requests")
        XCTAssertEqual(window.frame.width, 640, accuracy: 1)
        let hold = app.buttons["songRequestQueue.hold"]
        let clear = app.buttons["songRequestQueue.clearRequests"]
        expect(hold, "Hold before any requests arrive")
        XCTAssertTrue(hold.isHittable)
        XCTAssertTrue(clear.isHittable)
        XCTAssertLessThanOrEqual(clear.frame.maxX, window.frame.maxX)
        hold.click()
        let resumedLabel = NSPredicate(format: "label CONTAINS %@", "Resume")
        expectation(for: resumedLabel, evaluatedWith: hold)
        waitForExpectations(timeout: Self.timeout)
        XCTAssertTrue(app.descendants(matching: .any)["songRequestQueue.empty"].exists)
    }

    func testEveryPaneRenders() {
        openSettings()

        for section in Self.sections {
            select(section)

            // The window surviving the click is the assertion. A pane that traps
            // during layout takes the process with it, so the next query fails
            // against a dead app rather than returning a wrong answer.
            XCTAssertTrue(
                app.windows[Self.settingsWindowTitle].exists,
                "The Settings window went away while rendering \(section)"
            )
            assertStillRunning(rendering: section)
        }
    }

    func testSidebarSupportsKeyboardNavigation() {
        openSettings()
        select("General")
        XCTAssertEqual(app.state, .runningForeground)
        let sidebar = app.descendants(matching: .any)["settings.sidebar"].firstMatch
        sidebar.typeKey(.downArrow, modifierFlags: [])
        expect(app.descendants(matching: .any)["settings.pane.Twitch"], "Twitch after Down Arrow")
        sidebar.typeKey(.upArrow, modifierFlags: [])
        expect(app.descendants(matching: .any)["settings.pane.General"], "General after Up Arrow")
    }

    func testNativeQuitShortcutTerminatesTheApp() {
        openSettings()
        app.activate()
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: Self.timeout))
    }

    func testDiscordEnabledLayoutAtMinimumSize() {
        app.terminate()
        app.launchEnvironment[UITestEnvironment.settingsSize] = "minimum"
        app.launch()
        let window = openSettings()
        select("Discord")
        let toggle = app.descendants(matching: .any)["discordPresenceToggle"].firstMatch
        expect(toggle, "the Discord presence toggle")
        toggle.click()
        expect(app.staticTexts["Show buttons"], "the enabled Discord configuration")
        let preview = app.staticTexts["statusChip.Offline"]
        app.activate()
        app.scrollViews["settings.pane.Discord"].swipeUp()
        expect(preview, "the Discord preview")
        for _ in 0..<4 where !preview.isHittable {
            app.activate()
            app.scrollViews["settings.pane.Discord"].swipeUp()
        }
        XCTAssertTrue(preview.isHittable)
        XCTAssertLessThanOrEqual(preview.frame.maxX, window.frame.maxX)
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = "Settings - minimum - Discord enabled"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testRequestPlaylistClearRequiresConfirmation() {
        openSettings()
        select("Song Requests")
        let clear = app.buttons["songRequestQueue.clearRequests"]
        expect(clear, "Clear Requests")
        for _ in 0..<4 where !clear.isHittable {
            app.scrollViews["settings.pane.Song Requests"].swipeUp()
        }
        XCTAssertTrue(clear.isHittable)
        clear.click()
        let cancel = app.buttons["songRequestQueue.cancelClear"]
        expect(cancel, "the request playlist clear confirmation")
        cancel.click()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(clear.isHittable)
    }

    func testHistoryPaneIncludesItsHeading() {
        openSettings()
        select("History & Stats")
        let heading = app.descendants(matching: .any)["historyStats.header"]
        expect(heading, "the History & Stats pane heading")
        XCTAssertGreaterThan(heading.frame.height, 0)
    }

    func testRequestQueuePrecedesConfiguration() {
        openSettings()
        select("Song Requests")
        let clear = app.buttons["songRequestQueue.clearRequests"]
        let enable = app.descendants(matching: .any)["songRequests.enableToggle"]
        expect(clear, "the request queue action")
        expect(enable, "the request configuration toggle")
        XCTAssertGreaterThan(clear.frame.height, 0)
        XCTAssertLessThan(clear.frame.maxY, enable.frame.minY)
    }

    /// Attaches every pane at minimum/ideal size in Light and Dark.
    ///
    /// Width and pane-containment assertions catch clipped layouts. The images
    /// still need visual review: a narrow card can fit inside the pane while
    /// disagreeing with its neighbors, as Stream Deck's setup card once did.
    /// Export the matrix from CI or a local run with:
    ///
    ///     make test-ui
    ///     xcrun xcresulttool export attachments \
    ///       --path DerivedData/Tests/Logs/Test/<newest>.xcresult \
    ///       --output-path /tmp/panes
    ///
    /// The exported files are named by UUID; `manifest.json` beside them maps
    /// each one back to its pane.
    ///
    /// Writing the PNGs straight to a path instead would not work: the runner is
    /// sandboxed into its own container, so anywhere a reader would think to
    /// look is `Operation not permitted`. Attachments are the way out.
    func testCapturesEveryPane() {
        // Mirrors SettingsUI tokens; the out-of-process UI bundle cannot import the app.
        let sizes: [(name: String, width: CGFloat, height: CGFloat)] = [
            ("minimum", 640, 620), ("ideal", 1240, 780)
        ]
        for size in sizes {
            for appearance in ["light", "dark"] {
                app.terminate()
                app.launchEnvironment[UITestEnvironment.settingsSize] = size.name
                app.launchEnvironment[UITestEnvironment.appearance] = appearance
                app.launch()
                app.activate()
                let window = openSettings()
                // macOS clamps a window to the screen, and CI runners have a
                // 1024-point display, so the ideal width can't always fit.
                let screenWidth = NSScreen.main?.visibleFrame.width ?? size.width
                XCTAssertEqual(window.frame.width, min(size.width, screenWidth), accuracy: 1)
                let screenHeight = NSScreen.main?.visibleFrame.height ?? size.height
                XCTAssertGreaterThanOrEqual(window.frame.height, min(size.height, screenHeight) - 1)

                for section in Self.sections {
                    select(section)
                    let sidebar = app.descendants(matching: .any)["settings.sidebar"].firstMatch
                    // Accessibility includes native list chrome around the content frame.
                    XCTAssertGreaterThanOrEqual(sidebar.frame.width, 230)
                    let pane = app.descendants(matching: .any)["settings.pane.\(section)"]
                    XCTAssertGreaterThan(pane.frame.width, 0)
                    XCTAssertLessThanOrEqual(pane.frame.maxX, window.frame.maxX + 1)
                    let shot = XCTAttachment(screenshot: window.screenshot())
                    shot.name = "Settings - \(size.name) - \(appearance) - \(section)"
                    shot.lifetime = .keepAlways
                    add(shot)
                }
            }
        }
    }

    /// Walks the panes twice. Several panes start observers or timers on appear,
    /// and a teardown that under-releases only shows up on the second visit.
    func testPanesSurviveRepeatedVisits() {
        openSettings()

        for _ in 0..<2 {
            for section in Self.sections {
                select(section)
            }
        }

        assertStillRunning(rendering: "the panes on a second pass")
        XCTAssertTrue(app.windows[Self.settingsWindowTitle].exists)
    }

    func testSidebarRepeatedlyHidesAndShowsWithoutChangingPane() {
        let window = openSettings()
        let toggle = window.buttons["sidebarToggleButton"]
        expect(toggle, "the sidebar toggle")

        var sections = ["General", "About"]
        if app.staticTexts["settings.sidebar.Debug"].exists {
            sections.append("Debug")
        }
        for section in sections {
            select(section)
            let row = app.staticTexts["settings.sidebar.\(section)"]
            let pane = app.descendants(matching: .any)["settings.pane.\(section)"]
            for _ in 0..<3 {
                toggle.click()
                XCTAssertTrue(row.waitForNonExistence(timeout: Self.timeout))
                XCTAssertTrue(pane.exists, "Hiding the sidebar changed the selected pane")
                toggle.click()
                expect(row, "the \(section) row after showing the sidebar")
                XCTAssertTrue(pane.exists, "Showing the sidebar changed the selected pane")
            }
        }
        assertStillRunning(rendering: "repeated sidebar toggles")
    }

    // MARK: - Helpers

    /// Clicks one sidebar row, activating first.
    ///
    /// The activation is not decoration. An inactive macOS app reports its whole
    /// window tree as disabled: the row is still *found*, so the query succeeds,
    /// and the click then fails with "Not hittable" or "Unable to find hit
    /// point". That reads as a layout bug and is not one, it just means
    /// something else took focus, which anything from a notification to a second
    /// copy of WolfWave Dev can do at any point in a multi-minute run.
    private func select(
        _ section: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        app.activate()
        let row = app.staticTexts["settings.sidebar.\(section)"]
        XCTAssertTrue(
            row.waitForExistence(timeout: Self.timeout),
            "Timed out waiting for the \(section) sidebar row",
            file: file,
            line: line
        )
        row.click()

        // The click is asynchronous. Waiting on the row proves only that the row
        // exists, so without this every caller races the pane it just asked for:
        // `testEveryPaneRenders` could assert against the outgoing pane, and
        // `testCapturesEveryPane` could screenshot it. The detail pane carries an
        // identifier naming whichever section is on screen, so waiting for the
        // one we asked for is the navigation-finished signal.
        //
        // Queried across every element type on purpose: SwiftUI decides what
        // kind of accessibility element the pane becomes, and it is not a
        // `group`, so `app.groups[...]` finds nothing and times out.
        let pane = app.descendants(matching: .any)["settings.pane.\(section)"]
        XCTAssertTrue(
            pane.waitForExistence(timeout: Self.timeout),
            "Timed out waiting for the \(section) pane to come on screen",
            file: file,
            line: line
        )
    }

    /// Asserts the app is still alive.
    ///
    /// Deliberately *not* `state == .runningForeground`. What these tests are
    /// checking is that rendering a pane did not take the process down, and
    /// losing focus is not that: any other app activating (a notification, a
    /// second copy of WolfWave Dev left over from Xcode) drops the app to
    /// `.runningBackground` and would fail a foreground assertion for a reason
    /// that has nothing to do with the pane.
    private func assertStillRunning(
        rendering section: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNotEqual(
            app.state, .notRunning,
            "The app died rendering \(section)",
            file: file,
            line: line
        )
    }
}
