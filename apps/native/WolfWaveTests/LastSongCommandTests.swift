//
//  LastSongCommandTests.swift
//  WolfWaveTests
//
//  Created by MrDemonWolf, Inc. on 2/13/26.
//

import XCTest
@testable import WolfWave

final class LastSongCommandTests: TrackInfoCommandTestsBase {

    override var spec: Spec {
        Spec(
            triggers: ["!last", "!lastsong", "!prevsong"],
            description: "Displays the last played track",
            defaultMessage: "No previous track available",
            mixedCaseTrigger: "!LastSong",
            upperCaseTrigger: "!LAST",
            sampleTrackInfo: "Previous Artist - Previous Song",
            sampleCallbackValue: "Daft Punk - One More Time"
        )
    }

    // MARK: - Variant-specific edge cases

    func testPrevSongCaseInsensitive() {
        command.getTrackInfo = { "Artist - Song" }
        XCTAssertNotNil(command.execute(message: "!PREVSONG"))
    }
}
