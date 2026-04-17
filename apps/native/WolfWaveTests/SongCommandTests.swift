//
//  SongCommandTests.swift
//  WolfWaveTests
//
//  Created by MrDemonWolf, Inc. on 2/13/26.
//

import XCTest
@testable import WolfWave

final class SongCommandTests: TrackInfoCommandTestsBase {

    override var spec: Spec {
        Spec(
            triggers: ["!song", "!currentsong", "!nowplaying"],
            description: "Displays the currently playing track",
            defaultMessage: "No track currently playing",
            mixedCaseTrigger: "!Song",
            upperCaseTrigger: "!SONG",
            sampleTrackInfo: "Artist - Song",
            sampleCallbackValue: "Daft Punk - Around The World"
        )
    }

    // MARK: - Variant-specific edge cases

    func testNowPlayingCaseInsensitive() {
        command.getTrackInfo = { "Artist - Song" }
        XCTAssertNotNil(command.execute(message: "!NowPlaying"))
    }

    func testCallbackReturning501CharsTruncates() throws {
        let text = String(repeating: "b", count: 501)
        command.getTrackInfo = { text }
        let result = try XCTUnwrap(command.execute(message: "!song"))
        XCTAssertEqual(result.count, 500)
        XCTAssertTrue(result.hasSuffix("..."))
    }

    func testDefaultCooldownValues() throws {
        let cmd = try XCTUnwrap(command)
        XCTAssertEqual(cmd.globalCooldown, 15.0)
        XCTAssertEqual(cmd.userCooldown, 15.0)
    }
}
