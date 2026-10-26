//
//  PlaylistVisibilityWait.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-26.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// A bounded wait for Music.app to see the `WolfWave Requests` playlist.
///
/// The playlist is created in the Apple Music **cloud** library, and Music.app
/// only picks it up through iCloud sync a few seconds later. Probing once,
/// straight after the create, almost always answers `.notVisible` and blames
/// Sync Library for what is really sync latency. This re-probes on a fixed
/// interval until Music sees the playlist or the time budget runs out, so a
/// warning only appears once the playlist has stayed missing long enough to
/// mean something.
///
/// Only `.notVisible` keeps the wait going. `.visible` is the answer we want,
/// and `.unknown` (Music closed, probe timed out) will not turn into a verdict
/// by asking again, so both end the wait at once.
///
/// The probe and the sleep are injected, so the state machine runs in tests
/// with no Music.app and no real time passing.
struct PlaylistVisibilityWait: Equatable, Sendable {

    // MARK: - Properties

    /// Pause between probes.
    var interval: Duration
    /// Most probes to run, including the first. `1` means a single probe and no
    /// waiting.
    var maxAttempts: Int

    // MARK: - Presets

    /// Every 2 seconds for about 40 seconds: long enough for normal iCloud sync,
    /// short enough that a real Sync Library problem still surfaces quickly.
    static let standard = PlaylistVisibilityWait(interval: .seconds(2), maxAttempts: 21)

    /// One probe, no wait. For a playlist already known to be missing from
    /// Music, where waiting again would only repeat the same answer.
    static let singleProbe = PlaylistVisibilityWait(interval: .zero, maxAttempts: 1)

    // MARK: - Running

    /// The production sleep: `Task.sleep`, which throws on cancellation.
    static let taskSleep: @Sendable (Duration) async throws -> Void = { duration in
        try await Task.sleep(for: duration)
    }

    /// Probes until Music sees the playlist, gives a non-answer, or the attempts
    /// run out, and returns the last answer.
    ///
    /// - Parameters:
    ///   - probe: Asks Music.app once (`AppleMusicControlling.requestsPlaylistLocalVisibility`).
    ///   - sleep: Waits between probes. Throws `CancellationError` when the
    ///     caller goes away, which ends the wait without a verdict.
    /// - Returns: The final visibility answer.
    /// - Throws: Whatever `sleep` throws (cancellation in production).
    func run(
        probe: () async -> PlaylistLocalVisibility,
        sleep: (Duration) async throws -> Void = PlaylistVisibilityWait.taskSleep
    ) async throws -> PlaylistLocalVisibility {
        let attempts = max(1, maxAttempts)
        var answer = await probe()
        var attempt = 1
        while answer == .notVisible, attempt < attempts {
            try await sleep(interval)
            try Task.checkCancellation()
            attempt += 1
            answer = await probe()
        }
        return answer
    }
}
