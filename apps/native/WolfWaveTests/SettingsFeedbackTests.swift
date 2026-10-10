//
//  SettingsFeedbackTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-08.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import XCTest
@testable import WolfWave

@MainActor
final class SettingsFeedbackTests: XCTestCase {
    func testSongRequestPermissionTargetIsSeparateFromAutomation() {
        XCTAssertTrue(AppConstants.URLs.systemMusicSettings.hasSuffix("Privacy_Media"))
        XCTAssertNotEqual(AppConstants.URLs.systemMusicSettings, AppConstants.URLs.systemAutomationSettings)
    }

    func testStillOffShownOnlyWhenDenied() async {
        let denied = await MusicPermissionRecheckButton.recheckFeedback(using: { .denied })
        XCTAssertTrue(denied?.hasPrefix("Still off") == true)
        let granted = await MusicPermissionRecheckButton.recheckFeedback(using: { .granted })
        XCTAssertNil(granted)
    }

    func testUnknownStateSuggestsOpeningMusic() async {
        let unknown = await MusicPermissionRecheckButton.recheckFeedback(using: { .unknown })
        XCTAssertEqual(unknown, "Open Music, then try again.")
        XCTAssertFalse(unknown?.contains("Still off") == true)
    }

    func testResetAbortSetsUserFacingError() async {
        let error = await SettingsView.twitchResetError(clearCredentials: { false })
        XCTAssertEqual(error?.id, "settings.resetAborted.twitch")
        XCTAssertTrue(error?.message.contains("nothing was erased") == true)
        let success = await SettingsView.twitchResetError(clearCredentials: { true })
        XCTAssertNil(success)
    }

    func testLaunchAtLoginFailureSurfacesError() {
        let failure = AppVisibilitySettingsView.requestLaunchAtLogin(true, register: { enabled in
            XCTAssertTrue(enabled)
            return .failure
        })
        XCTAssertEqual(failure.outcome, .failure)
        XCTAssertNotNil(failure.error)
        let accepted = AppVisibilitySettingsView.requestLaunchAtLogin(true, register: { _ in .requiresApproval })
        XCTAssertEqual(accepted.outcome, .requiresApproval)
        XCTAssertNil(accepted.error)
    }

    func testShareCancellationRemovesOnlyItsTemporaryFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("wrap".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let coordinator = SharePickerButton.Coordinator(
            makeItems: { [url] }, onCompletion: MonthlyWrapView.removeShareFiles)
        coordinator.prepareSharing([url])
        let picker = NSSharingServicePicker(items: [url])
        // Selection must not delete the file before the service consumes it.
        let service = NSSharingService(title: "Test", image: NSImage(), alternateImage: nil, handler: {})
        coordinator.sharingServicePicker(picker, didChoose: service)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        coordinator.sharingServicePicker(picker, didChoose: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testShareCompletionRunsOnce() {
        var calls = 0
        let coordinator = SharePickerButton.Coordinator(makeItems: { ["wrap"] }, onCompletion: { _ in calls += 1 })
        coordinator.prepareSharing(["wrap"])
        let service = NSSharingService(title: "Test", image: NSImage(), alternateImage: nil, handler: {})
        coordinator.sharingService(service, didShareItems: ["wrap"])
        coordinator.sharingService(service, didFailToShareItems: ["wrap"], error: NSError(domain: "test", code: 1))
        XCTAssertEqual(calls, 1)
    }
}
