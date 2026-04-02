//
//  KnownMusicAppsTests.swift
//  WolfWaveTests

import XCTest
@testable import WolfWave

final class KnownMusicAppsTests: XCTestCase {

    // MARK: - displayName

    func testDisplayNameAppleMusic() {
        XCTAssertEqual(AppConstants.KnownMusicApps.displayName(for: "com.apple.Music"), "Apple Music")
    }

    func testDisplayNameSpotify() {
        XCTAssertEqual(AppConstants.KnownMusicApps.displayName(for: "com.spotify.client"), "Spotify")
    }

    func testDisplayNameiTunes() {
        XCTAssertEqual(AppConstants.KnownMusicApps.displayName(for: "com.apple.iTunes"), "iTunes")
    }

    func testDisplayNameChrome() {
        XCTAssertEqual(AppConstants.KnownMusicApps.displayName(for: "com.google.Chrome"), "Chrome")
    }

    func testDisplayNameFirefox() {
        XCTAssertEqual(AppConstants.KnownMusicApps.displayName(for: "org.mozilla.firefox"), "Firefox")
    }

    func testDisplayNameUnknownFallsBackToMusic() {
        XCTAssertEqual(AppConstants.KnownMusicApps.displayName(for: "com.unknown.app"), "Music")
    }

    func testDisplayNameNilFallsBackToMusic() {
        XCTAssertEqual(AppConstants.KnownMusicApps.displayName(for: nil), "Music")
    }

    // MARK: - discordAssetName

    func testDiscordAssetAppleMusic() {
        XCTAssertEqual(AppConstants.KnownMusicApps.discordAssetName(for: "com.apple.Music"), "apple_music")
    }

    func testDiscordAssetiTunes() {
        XCTAssertEqual(AppConstants.KnownMusicApps.discordAssetName(for: "com.apple.iTunes"), "apple_music")
    }

    func testDiscordAssetSpotify() {
        XCTAssertEqual(AppConstants.KnownMusicApps.discordAssetName(for: "com.spotify.client"), "spotify")
    }

    func testDiscordAssetChrome() {
        XCTAssertEqual(AppConstants.KnownMusicApps.discordAssetName(for: "com.google.Chrome"), "youtube")
    }

    func testDiscordAssetFirefox() {
        XCTAssertEqual(AppConstants.KnownMusicApps.discordAssetName(for: "org.mozilla.firefox"), "youtube")
    }

    func testDiscordAssetBrave() {
        XCTAssertEqual(AppConstants.KnownMusicApps.discordAssetName(for: "com.brave.Browser"), "youtube")
    }

    func testDiscordAssetUnknownFallsBackToGeneric() {
        XCTAssertEqual(AppConstants.KnownMusicApps.discordAssetName(for: "com.unknown.app"), "music_generic")
    }

    func testDiscordAssetNilFallsBackToGeneric() {
        XCTAssertEqual(AppConstants.KnownMusicApps.discordAssetName(for: nil), "music_generic")
    }

    // MARK: - isAppleMusic

    func testIsAppleMusicTrue() {
        XCTAssertTrue(AppConstants.KnownMusicApps.isAppleMusic("com.apple.Music"))
    }

    func testIsAppleMusicFalseForSpotify() {
        XCTAssertFalse(AppConstants.KnownMusicApps.isAppleMusic("com.spotify.client"))
    }

    func testIsAppleMusicFalseForNil() {
        XCTAssertFalse(AppConstants.KnownMusicApps.isAppleMusic(nil))
    }

    // MARK: - isBrowser

    func testIsBrowserChrome() {
        XCTAssertTrue(AppConstants.KnownMusicApps.isBrowser("com.google.Chrome"))
    }

    func testIsBrowserFirefox() {
        XCTAssertTrue(AppConstants.KnownMusicApps.isBrowser("org.mozilla.firefox"))
    }

    func testIsBrowserFalseForSpotify() {
        XCTAssertFalse(AppConstants.KnownMusicApps.isBrowser("com.spotify.client"))
    }

    func testIsBrowserFalseForNil() {
        XCTAssertFalse(AppConstants.KnownMusicApps.isBrowser(nil))
    }
}
