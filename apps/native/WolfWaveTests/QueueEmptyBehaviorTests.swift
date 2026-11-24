//
//  QueueEmptyBehaviorTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-11-23.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
@testable import WolfWave

/// The "When the queue empties" picker over the two stored settings the
/// service reads: existing settings map to the right choice, and each choice
/// writes values the service plays the same way.
@Suite("Queue empty behavior")
struct QueueEmptyBehaviorTests {

    @Test(
        "stored settings resolve to one choice; a fallback playlist wins",
        arguments: [
            (true, "", QueueEmptyBehavior.autoPlay),
            (false, "", .stop),
            (true, "Gaming Vibes", .playlist),
            (false, "Gaming Vibes", .playlist),
            (true, "   ", .autoPlay)
        ])
    func resolve(autoplay: Bool, fallback: String, expected: QueueEmptyBehavior) {
        #expect(QueueEmptyBehavior.resolve(autoplayWhenEmpty: autoplay, fallbackPlaylist: fallback) == expected)
    }

    @Test("each choice writes values that resolve back to itself")
    func roundTrip() {
        for choice in QueueEmptyBehavior.allCases {
            let stored = choice.storedValues(playlistName: "Gaming Vibes")
            #expect(QueueEmptyBehavior.resolve(
                autoplayWhenEmpty: stored.autoplayWhenEmpty,
                fallbackPlaylist: stored.fallbackPlaylist) == choice)
        }
    }

    @Test("a playlist choice with no name yet means silence, not AutoPlay")
    func blankPlaylistIsSilent() {
        let stored = QueueEmptyBehavior.playlist.storedValues(playlistName: "")
        #expect(stored.autoplayWhenEmpty == false)
        #expect(stored.fallbackPlaylist.isEmpty)
    }
}
