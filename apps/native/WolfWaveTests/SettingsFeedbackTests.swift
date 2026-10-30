//
//  SettingsFeedbackTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-10.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import XCTest
@testable import WolfWave

/// Settings feedback paths: Music permission copy, aborted or incomplete factory reset, login-item
/// failure, and share temp-file cleanup.
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

    func testContainerWipeFailureSurfacesIncompleteResetError() {
        var attempts = 0
        let error = SettingsView.containerWipeError(wipe: {
            attempts += 1
            return false
        })
        XCTAssertEqual(attempts, 2, "A failed wipe is retried exactly once")
        XCTAssertEqual(error?.id, SettingsView.resetIncompleteErrorID)
        XCTAssertFalse(error?.message.contains("nothing was erased") == true)
        XCTAssertTrue(error?.message.contains("history and logs") == true)
    }

    func testContainerWipeSuccessReturnsNoError() {
        var attempts = 0
        XCTAssertNil(SettingsView.containerWipeError(wipe: {
            attempts += 1
            return true
        }))
        XCTAssertEqual(attempts, 1)

        attempts = 0
        XCTAssertNil(SettingsView.containerWipeError(wipe: {
            attempts += 1
            return attempts > 1
        }), "A wipe that succeeds on the retry is not an error")
        XCTAssertEqual(attempts, 2)
    }

    func testKeychainResetErrorSaysNothingWasErased() {
        let error = SettingsView.keychainResetError()
        XCTAssertEqual(error.id, "settings.resetAborted")
        XCTAssertTrue(error.message.contains("nothing was erased"))
    }

    /// The reset alert shows its message as plain text, so a Markdown marker in any reset
    /// error would print literally (the `**nothing was erased**` regression).
    func testResetErrorsCarryNoMarkdown() async throws {
        let twitchError = await SettingsView.twitchResetError(clearCredentials: { false })
        let twitch = try XCTUnwrap(twitchError)
        let incomplete = try XCTUnwrap(SettingsView.containerWipeError(wipe: { false }))
        for error in [twitch, SettingsView.keychainResetError(), incomplete] {
            XCTAssertFalse(error.message.contains("**"), "\(error.id) would show literal asterisks")
            XCTAssertFalse(error.message.contains("`"), "\(error.id) would show literal backticks")
        }
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

    func testNewShareEndsAShareWhoseServiceNeverCalledBack() {
        var finished: [String] = []
        let coordinator = SharePickerButton.Coordinator(
            makeItems: { nil }, onCompletion: { items in finished += items.compactMap { $0 as? String } })
        coordinator.prepareSharing(["first"])
        // A service was chosen but never reports success or failure.
        let service = NSSharingService(title: "Test", image: NSImage(), alternateImage: nil, handler: {})
        coordinator.sharingServicePicker(NSSharingServicePicker(items: ["first"]), didChoose: service)
        XCTAssertTrue(finished.isEmpty)

        // The next click must not be ignored: it ends the stale share, then starts.
        coordinator.prepareSharing(["second"])
        XCTAssertEqual(finished, ["first"])
        coordinator.sharingService(service, didShareItems: ["second"])
        XCTAssertEqual(finished, ["first", "second"])
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
