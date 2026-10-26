//
//  DebugToolsUITests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-26.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

/// Verifies tool switching replaces the previous tool at both supported layouts.
@MainActor
final class DebugToolsUITests: WolfWaveUITestCase {
    override var launchOptions: LaunchOptions {
        LaunchOptions(onboarded: true, suppressWhatsNew: true)
    }

    func testOnlySelectedToolIsMountedAtBothWindowSizes() throws {
        for size in ["minimum", "ideal"] {
            app.terminate()
            app.launchEnvironment[UITestEnvironment.settingsSize] = size
            app.launch()
            app.activate()
            app.typeKey(",", modifierFlags: .command)
            let debug = app.staticTexts["settings.sidebar.Debug"]
            expect(debug, "Debug pane in the Debug configuration")
            debug.click()
            let inspectors = app.descendants(matching: .any)["debugTool.inspectors"].firstMatch
            expect(inspectors, "initial inspector tool")
            let metrics = app.descendants(matching: .any)["debugTool.metrics"].firstMatch
            XCTAssertFalse(metrics.exists)
            captureTool("inspectors", size: size)

            if size == "minimum" {
                let picker = app.popUpButtons["debugToolPicker"]
                expect(picker, "compact tool picker")
                picker.click()
                app.menuItems["Performance"].click()
            } else {
                app.staticTexts["debugNav.metrics"].click()
            }
            expect(metrics, "selected performance tool")
            XCTAssertTrue(inspectors.waitForNonExistence(timeout: Self.timeout))
            expect(app.buttons["debugCopyDiagnostics"], "diagnostics action")
            captureTool("metrics", size: size)
        }
    }

    private func captureTool(_ tool: String, size: String) {
        let shot = XCTAttachment(screenshot: app.windows[UITestWindow.settings].screenshot())
        shot.name = "Debug - \(size) - \(tool)"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
