//
//  PlaybackSourceDelegate.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-08-11.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

// MARK: - PlaybackSourceDelegate

/// Receives playback updates from any music source.
///
/// Implementations must be safe to call from the main actor. Concrete sources
/// (e.g. `AppleMusicSource`) marshal delegate callbacks onto the main actor
/// before invocation.
protocol PlaybackSourceDelegate: AnyObject {
    /// Called on every successful read of a loaded track (playing, paused,
    /// fast-forward, or rewind), not only when the track changes. Each
    /// notification, fallback poll, and forced refresh that finds a track
    /// re-sends it, so implementations should treat repeats as progress
    /// updates and dedupe track changes themselves.
    ///
    /// - Parameters:
    ///   - track: Track title.
    ///   - artist: Artist name.
    ///   - album: Album title (may be empty when unavailable).
    ///   - playlist: Current playlist name (may be empty when unavailable).
    ///   - duration: Total track duration in seconds.
    ///   - elapsed: Current playhead position in seconds.
    ///   - isPaused: `true` when the source reports the loaded track as paused
    ///     (Music.app `kPSp`). The track stays "loaded": Discord, the widget,
    ///     and the now-playing UI keep showing it but render a paused affordance.
    func playbackSource(
        didUpdateTrack track: String,
        artist: String,
        album: String,
        playlist: String,
        duration: TimeInterval,
        elapsed: TimeInterval,
        isPaused: Bool
    )

    /// Called when there is no track to show: Music is stopped, empty, quit,
    /// unreadable, or denied Automation access.
    ///
    /// A paused track does not come through here; it arrives via
    /// `playbackSource(didUpdateTrack:...)` with `isPaused == true`.
    ///
    /// - Parameter status: User-facing status string. `AppleMusicSource` sends
    ///   one of `"Music not running"`, `"No track playing"`, `"No track info"`,
    ///   `"Script error"`, or `"Music access denied"`.
    func playbackSource(didUpdateStatus status: String)
}
