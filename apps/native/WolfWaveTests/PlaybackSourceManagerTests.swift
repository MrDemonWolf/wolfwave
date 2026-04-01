//
//  PlaybackSourceManagerTests.swift
//  WolfWaveTests

import XCTest
@testable import WolfWave

final class PlaybackSourceManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "playbackSourceMode")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "playbackSourceMode")
        super.tearDown()
    }

    // MARK: - Default Mode

    func testDefaultModeIsAppleMusic() {
        let manager = PlaybackSourceManager()
        XCTAssertEqual(manager.currentMode, .appleMusic)
    }

    func testDefaultModePersistedModeIsRestored() {
        UserDefaults.standard.set("systemNowPlaying", forKey: "playbackSourceMode")
        let manager = PlaybackSourceManager()
        XCTAssertEqual(manager.currentMode, .systemNowPlaying)
    }

    func testInvalidPersistedModeFallsBackToAppleMusic() {
        UserDefaults.standard.set("invalidMode", forKey: "playbackSourceMode")
        let manager = PlaybackSourceManager()
        XCTAssertEqual(manager.currentMode, .appleMusic)
    }

    // MARK: - Mode Switching

    func testSwitchModeUpdatesCurrentMode() {
        let manager = PlaybackSourceManager()
        manager.switchMode(.systemNowPlaying)
        XCTAssertEqual(manager.currentMode, .systemNowPlaying)
    }

    func testSwitchModeToSameModeIsNoOp() {
        let manager = PlaybackSourceManager()
        // Should not crash or change anything
        manager.switchMode(.appleMusic)
        XCTAssertEqual(manager.currentMode, .appleMusic)
    }

    func testSwitchModePersistsToUserDefaults() {
        let manager = PlaybackSourceManager()
        manager.switchMode(.systemNowPlaying)
        let stored = UserDefaults.standard.string(forKey: "playbackSourceMode")
        XCTAssertEqual(stored, "systemNowPlaying")
    }

    // MARK: - Delegate Forwarding

    func testDelegateReceivesTrackUpdate() {
        let manager = PlaybackSourceManager()
        let spy = PlaybackSourceDelegateSpy()
        manager.delegate = spy

        // Simulate a source calling back into the manager
        manager.playbackSource(MockPlaybackSource(), didUpdateTrack: "Song", artist: "Artist", album: "Album", duration: 200, elapsed: 30)

        XCTAssertTrue(spy.didReceiveTrackUpdate)
        XCTAssertEqual(spy.lastTrack, "Song")
        XCTAssertEqual(spy.lastArtist, "Artist")
    }

    func testDelegateReceivesStatusUpdate() {
        let manager = PlaybackSourceManager()
        let spy = PlaybackSourceDelegateSpy()
        manager.delegate = spy

        manager.playbackSource(MockPlaybackSource(), didUpdateStatus: "No track playing")

        XCTAssertTrue(spy.didReceiveStatusUpdate)
        XCTAssertEqual(spy.lastStatus, "No track playing")
    }

    // MARK: - updateCheckInterval

    func testUpdateCheckIntervalDoesNotCrashWhenNotTracking() {
        let manager = PlaybackSourceManager()
        // Should not crash when no active source
        manager.updateCheckInterval(10.0)
    }
}

// MARK: - Test Helpers

private class PlaybackSourceDelegateSpy: PlaybackSourceDelegate {
    var didReceiveTrackUpdate = false
    var lastTrack: String?
    var lastArtist: String?
    var didReceiveStatusUpdate = false
    var lastStatus: String?

    func playbackSource(_ source: any PlaybackSource, didUpdateTrack track: String, artist: String, album: String, duration: TimeInterval, elapsed: TimeInterval) {
        didReceiveTrackUpdate = true
        lastTrack = track
        lastArtist = artist
    }

    func playbackSource(_ source: any PlaybackSource, didUpdateStatus status: String) {
        didReceiveStatusUpdate = true
        lastStatus = status
    }
}

private class MockPlaybackSource: PlaybackSource {
    weak var delegate: PlaybackSourceDelegate?
    func startTracking() {}
    func stopTracking() {}
    func updateCheckInterval(_ interval: TimeInterval) {}
}
