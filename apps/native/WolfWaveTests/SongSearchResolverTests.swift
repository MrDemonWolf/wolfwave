//
//  SongSearchResolverTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-22.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import MusicKit
import XCTest

@testable import WolfWave

// MARK: - SongSearchResolverTests

/// Covers `SongSearchResolver` routing (plain text vs. link queries) using
/// `MockAppleMusicController` (declared in `SongRequestServiceTests`) and a
/// `MockURLProtocol`-backed `LinkResolverService`.
///
/// MusicKit song fixtures verify candidate matching without catalog requests.
@MainActor
final class SongSearchResolverTests: XCTestCase {

    private var controller: MockAppleMusicController!
    private let handlerStore = MockURLProtocol.HandlerStore()

    override func setUp() async throws {
        try await super.setUp()
        handlerStore.handler = nil
        controller = MockAppleMusicController()
    }

    override func tearDown() async throws {
        handlerStore.handler = nil
        controller = nil
        try await super.tearDown()
    }

    private func makeResolver() -> SongSearchResolver {
        SongSearchResolver(
            linkResolver: LinkResolverService(session: MockURLProtocol.makeSession(handlerStore: handlerStore)),
            musicController: controller
        )
    }

    func testEmptyQueryReturnsError() async {
        let result = await makeResolver().resolve(query: "   ")

        guard case .error = result else {
            XCTFail("Expected .error, got \(result)")
            return
        }
    }

    func testPlainTextQueryRoutesToCatalogSearch() async {
        // MockAppleMusicController.search always reports .notFound.
        let result = await makeResolver().resolve(query: "some song name")

        guard case .notFound(let query) = result else {
            XCTFail("Expected .notFound, got \(result)")
            return
        }
        XCTAssertEqual(query, "some song name")
    }

    func testAppleMusicLinkRoutesToControllerResolve() async {
        // controller.resolve reports .notFound → resolveLink maps to .linkNotFound.
        let result = await makeResolver()
            .resolve(query: "check https://music.apple.com/us/song/x/1")

        guard case .linkNotFound = result else {
            XCTFail("Expected .linkNotFound, got \(result)")
            return
        }
    }

    func testSpotifyLinkResolvesViaOEmbedThenSearchesCatalog() async {
        handlerStore.handler = { request in
            (MockURLProtocol.httpResponse(for: request, status: 200),
             Data(#"{"title":"Tune","author_name":"Band"}"#.utf8))
        }

        let result = await makeResolver()
            .resolve(query: "https://open.spotify.com/track/abc")

        // oEmbed yields "Tune" + "Band" → catalog search for "Tune Band".
        guard case .linkNotFound = result else {
            XCTFail("Expected .linkNotFound, got \(result)")
            return
        }
    }

    func testOembedPicksBestMatchNotFirst() async {
        handlerStore.handler = { request in
            (MockURLProtocol.httpResponse(for: request, status: 200),
             Data(#"{"title":"Tune","author_name":"Band"}"#.utf8))
        }
        controller.candidateSearchProvider = { query, limit in
            XCTAssertEqual(query, "Tune Band")
            XCTAssertEqual(limit, 10)
            return ([makeTestSong(id: "wrong", title: "Other", artist: "Band"),
                     makeTestSong(id: "right", title: "Tune", artist: "Band")], nil)
        }
        let result = await makeResolver().resolve(query: "https://open.spotify.com/track/abc")
        guard case .found(let song) = result else { XCTFail("Expected confident match"); return }
        XCTAssertEqual(song.id.rawValue, "right")
    }

    func testLowConfidenceReturnsLinkNotFound() async {
        handlerStore.handler = { request in
            (MockURLProtocol.httpResponse(for: request, status: 200), Data(#"{"title":"Tune"}"#.utf8))
        }
        controller.candidateSearchProvider = { _, _ in
            ([makeTestSong(id: "one", title: "Tune", artist: "Band A"),
              makeTestSong(id: "two", title: "Tune", artist: "Band B")], nil)
        }
        let result = await makeResolver().resolve(query: "https://open.spotify.com/track/abc")
        guard case .linkNotFound = result else { XCTFail("Ambiguous titles must not pick an artist"); return }
    }

    func testYouTubeTitleStripsOfficialSuffix() async {
        handlerStore.handler = { request in
            (MockURLProtocol.httpResponse(for: request, status: 200),
             Data(#"{"title":"Band - Tune (Official Video) [Lyrics]","author_name":"Band - Topic"}"#.utf8))
        }
        controller.candidateSearchProvider = { _, _ in
            ([makeTestSong(id: "right", title: "Tune", artist: "Band")], nil)
        }
        let result = await makeResolver().resolve(query: "https://www.youtube.com/watch?v=abc")
        guard case .found(let song) = result else { XCTFail("Expected normalized YouTube match"); return }
        XCTAssertEqual(song.id.rawValue, "right")
    }
}
