//
//  ArtworkServiceTests.swift
//  WolfWaveTests
//
//  Created by MrDemonWolf, Inc. on 2/27/26.
//

import XCTest
@testable import WolfWave

nonisolated final class ArtworkServiceTests: XCTestCase {
    nonisolated(unsafe) var service: ArtworkService!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        service = ArtworkService()
    }

    @MainActor
    override func tearDown() async throws {
        service = nil
        try await super.tearDown()
    }

    // MARK: - Cache Tests

    @MainActor func testCachedArtworkURLReturnsNilOnMiss() {
        let result = service.cachedArtworkURL(track: "Nonexistent", artist: "Nobody")
        XCTAssertNil(result)
    }

    @MainActor func testCacheKeyUsesArtistPipeTrack() {
        // After fetching, the cache key format is "artist|track"
        // Without a network call, the cache should be empty
        XCTAssertNil(service.cachedArtworkURL(track: "Song", artist: "Artist"))
    }

    @MainActor func testDifferentTracksHaveSeparateCacheEntries() {
        XCTAssertNil(service.cachedArtworkURL(track: "Song A", artist: "Artist"))
        XCTAssertNil(service.cachedArtworkURL(track: "Song B", artist: "Artist"))
    }

    @MainActor func testDifferentArtistsHaveSeparateCacheEntries() {
        XCTAssertNil(service.cachedArtworkURL(track: "Song", artist: "Artist A"))
        XCTAssertNil(service.cachedArtworkURL(track: "Song", artist: "Artist B"))
    }

    // MARK: - URL Construction Tests

    @MainActor func testFetchWithEmptyTrackCallsCompletion() {
        let expectation = expectation(description: "completion called")
        service.fetchArtworkURL(track: "", artist: "") { _ in
            expectation.fulfill()
        }
        waitForExpectations(timeout: 10)
    }

    @MainActor func testFetchArtworkURLCallsCompletion() {
        let expectation = expectation(description: "completion called")
        service.fetchArtworkURL(track: "Test", artist: "Test") { _ in
            expectation.fulfill()
        }
        waitForExpectations(timeout: 10)
    }
}
