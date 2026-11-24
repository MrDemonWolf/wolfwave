//
//  QueueEmptyBehavior.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-11-23.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// What plays when the request queue runs dry: the one choice behind the
/// Playback card's "When the queue empties" picker.
///
/// It's a view over the two stored settings the service already reads,
/// `songRequestAutoplayWhenEmpty` and `songRequestFallbackPlaylist` (a
/// non-empty fallback wins), so no migration is needed.
nonisolated enum QueueEmptyBehavior: String, CaseIterable, Identifiable, Sendable {
    /// Hand playback back to Apple Music AutoPlay.
    case autoPlay
    /// Play a named Apple Music playlist.
    case playlist
    /// Go quiet.
    case stop

    var id: String { rawValue }

    /// Picker label.
    var title: String {
        switch self {
        case .autoPlay: "Apple Music AutoPlay"
        case .playlist: "Play a Playlist"
        case .stop: "Stop"
        }
    }

    /// One-line explanation under the picker.
    var summary: String {
        switch self {
        case .autoPlay: "Music keeps going with AutoPlay. Turn on AutoPlay in Music's Playing Next."
        case .playlist: "Plays the playlist below. Type its name exactly as it appears in Music."
        case .stop: "Music goes quiet until the next request."
        }
    }

    /// The choice the stored settings add up to. A non-empty fallback
    /// playlist wins, matching the service.
    static func resolve(autoplayWhenEmpty: Bool, fallbackPlaylist: String) -> QueueEmptyBehavior {
        if !fallbackPlaylist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .playlist }
        return autoplayWhenEmpty ? .autoPlay : .stop
    }

    /// The stored settings for this choice. `.playlist` keeps the given
    /// name and turns AutoPlay off, so a blank name means silence.
    func storedValues(playlistName: String) -> (autoplayWhenEmpty: Bool, fallbackPlaylist: String) {
        switch self {
        case .autoPlay: (true, "")
        case .playlist: (false, playlistName)
        case .stop: (false, "")
        }
    }
}
