//
//  SongDebugPlaceholderTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import MusicKit
import Testing

@testable import WolfWave

/// `Song.debugPlaceholder` builds its resource with `JSONSerialization`, so
/// fixture text needing JSON escaping must round-trip instead of trapping.
@Suite("Song Debug Placeholder Tests")
struct SongDebugPlaceholderTests {

    @Test("Quotes and backslashes in fixture text round-trip")
    func testEscapedTextRoundTrips() {
        let song = Song.debugPlaceholder(
            id: "42",
            title: #"Howl "Live" \ Remix"#,
            artist: #"Gray "Timber" Wolf"#,
            album: #"Den\Moon"#
        )

        #expect(song.title == #"Howl "Live" \ Remix"#)
        #expect(song.artistName == #"Gray "Timber" Wolf"#)
        #expect(song.albumTitle == #"Den\Moon"#)
        #expect(song.id == MusicItemID("42"))
    }
}
