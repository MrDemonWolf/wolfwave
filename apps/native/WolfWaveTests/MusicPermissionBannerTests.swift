//
//  MusicPermissionBannerTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-11.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
@testable import WolfWave

/// Pins the `UserFacingError` that `MusicPermissionBanner` hands to
/// `ErrorCallout`: the fix must be the filled button, the docs link must
/// follow it, and the caller's copy must reach the spoken label.
@Suite("MusicPermissionBanner")
struct MusicPermissionBannerTests {

    private let message = "WolfWave needs Apple Music automation access to record what you play."

    @Test("Builds a warning whose primary action opens System Settings")
    func primaryActionOpensSettings() {
        let error = MusicPermissionBanner.error(message: message)
        #expect(error.id == "music.automationDenied")
        #expect(error.severity == .warning)
        #expect(error.primaryAction == .openAutomationSettings)
    }

    @Test("Learn More points at the music-permission troubleshooting section")
    func learnMoreFollowsThePrimary() {
        let error = MusicPermissionBanner.error(message: message)
        #expect(error.secondaryActions == [.openDocs(anchor: "music-permission")])
    }

    @Test("The caller's copy is the body and is spoken with the title")
    func copyReachesTheLabel() {
        let error = MusicPermissionBanner.error(message: message)
        #expect(error.message == message)
        #expect(error.accessibilityLabel.hasSuffix(message))
        #expect(error.accessibilityIdentifier == "errorCallout.music.automationDenied")
    }
}
