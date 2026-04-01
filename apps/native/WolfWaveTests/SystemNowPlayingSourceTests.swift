//
//  SystemNowPlayingSourceTests.swift
//  WolfWaveTests

import XCTest
@testable import WolfWave

final class SystemNowPlayingSourceTests: XCTestCase {

    // MARK: - Initialization

    func testInitializationDoesNotCrash() {
        // MediaRemote may or may not be available in the test environment
        let source = SystemNowPlayingSource()
        XCTAssertNotNil(source)
    }

    func testConformsToPlaybackSource() {
        let source = SystemNowPlayingSource()
        XCTAssertTrue((source as AnyObject) is any PlaybackSource)
    }

    // MARK: - Start / Stop

    func testStartTrackingDoesNotCrash() {
        let source = SystemNowPlayingSource()
        source.startTracking()
        source.stopTracking()
    }

    func testDoubleStartIsIdempotent() {
        let source = SystemNowPlayingSource()
        source.startTracking()
        source.startTracking() // second call should be a no-op
        source.stopTracking()
    }

    func testDoubleStopIsIdempotent() {
        let source = SystemNowPlayingSource()
        source.startTracking()
        source.stopTracking()
        source.stopTracking() // second call should be a no-op
    }

    // MARK: - Interval

    func testUpdateCheckIntervalDoesNotCrashWhenNotTracking() {
        let source = SystemNowPlayingSource()
        source.updateCheckInterval(10.0)
    }

    func testUpdateCheckIntervalDoesNotCrashWhenTracking() {
        let source = SystemNowPlayingSource()
        source.startTracking()
        source.updateCheckInterval(10.0)
        source.stopTracking()
    }

    // MARK: - Graceful Degradation

    func testDelegateWiringDoesNotCrash() {
        let source = SystemNowPlayingSource()
        let spy = StatusSpy()
        source.delegate = spy
        // If framework unavailable, delegate receives "System Now Playing unavailable" on main thread.
        // If available, startTracking proceeds silently. Either way, no crash.
        source.startTracking()
        source.stopTracking()
    }
}

// MARK: - Helpers

private class StatusSpy: PlaybackSourceDelegate {
    var statuses: [String] = []

    func playbackSource(_ source: any PlaybackSource, didUpdateTrack track: String, artist: String, album: String, duration: TimeInterval, elapsed: TimeInterval) {}

    func playbackSource(_ source: any PlaybackSource, didUpdateStatus status: String) {
        statuses.append(status)
    }
}
