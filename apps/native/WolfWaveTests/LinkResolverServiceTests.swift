//
//  LinkResolverServiceTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-22.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

// MARK: - LinkResolverServiceTests

/// Covers `LinkResolverService` link detection and oEmbed resolution, driving
/// the network layer with `MockURLProtocol`.
@MainActor
final class LinkResolverServiceTests: XCTestCase {

    private var resolver: LinkResolverService!
    private let handlerStore = MockURLProtocol.HandlerStore()

    override func setUp() async throws {
        try await super.setUp()
        handlerStore.handler = nil
        resolver = LinkResolverService(session: MockURLProtocol.makeSession(handlerStore: handlerStore))
    }

    override func tearDown() async throws {
        handlerStore.handler = nil
        resolver = nil
        try await super.tearDown()
    }

    // MARK: - Link Detection

    func testDetectsSpotifyLink() {
        XCTAssertEqual(LinkResolverService.detectedService(in: "https://open.spotify.com/track/abc"), .spotify)
        XCTAssertEqual(LinkResolverService.detectedService(in: "https://open.spotify.com/intl-fr/track/abc"), .spotify)
        XCTAssertEqual(LinkResolverService.detectedService(in: "https://spotify.link/abc"), .spotify)
        XCTAssertNotEqual(LinkResolverService.detectedService(in: "https://example.com/track"), .spotify)
        XCTAssertNotEqual(LinkResolverService.detectedService(in: "https://open.spotify.com.evil.test/track/abc"), .spotify)
    }

    func testDetectsYouTubeLink() {
        XCTAssertEqual(LinkResolverService.detectedService(in: "https://youtu.be/abc"), .youtube)
        XCTAssertEqual(LinkResolverService.detectedService(in: "https://www.youtube.com/watch?v=abc"), .youtube)
        XCTAssertNotEqual(LinkResolverService.detectedService(in: "https://www.youtube.com/watch"), .youtube)
        XCTAssertNotEqual(LinkResolverService.detectedService(in: "https://www.youtube.com/watch?v="), .youtube)
        XCTAssertNotEqual(LinkResolverService.detectedService(in: "https://example.com"), .youtube)
        XCTAssertNotEqual(LinkResolverService.detectedService(in: "https://notyoutube.com/watch?v=abc"), .youtube)
    }

    func testDetectsAppleMusicLink() {
        XCTAssertEqual(LinkResolverService.detectedService(in: "https://music.apple.com/us/album/x/1?i=2"), .appleMusic)
        XCTAssertEqual(LinkResolverService.detectedService(in: "https://music.apple.com/gb/song/x/2"), .appleMusic)
        XCTAssertNotEqual(LinkResolverService.detectedService(in: "https://music.apple.com/us/album/x/1"), .appleMusic)
        XCTAssertNotEqual(LinkResolverService.detectedService(in: "https://example.com"), .appleMusic)
        XCTAssertNotEqual(LinkResolverService.detectedService(in: "http://music.apple.com/us/album/x/1"), .appleMusic)
        XCTAssertNotEqual(LinkResolverService.detectedService(in: "https://music.apple.com.evil.test/us/album/x/1"), .appleMusic)
        XCTAssertNotEqual(LinkResolverService.detectedService(in: "https://evil.test/music.apple.com/us/album/x/1"), .appleMusic)
        XCTAssertNotEqual(LinkResolverService.detectedService(in: "https://music.apple.com/us/browse"), .appleMusic)
        XCTAssertNotEqual(LinkResolverService.detectedService(in: "https://music.apple.com/usa/album/x/1"), .appleMusic)
        XCTAssertNotEqual(LinkResolverService.detectedService(in: "https://music.apple.com/us/album/x/not-an-id"), .appleMusic)
    }

    func testExtractURLFindsFirstSupportedURLAndTrimsPunctuation() {
        XCTAssertEqual(
            LinkResolverService.extractURL(
                from: "ignore https://example.com/info, play (https://open.spotify.com/track/abc)."
            ),
            "https://open.spotify.com/track/abc"
        )
        XCTAssertNil(LinkResolverService.extractURL(from: "no link here"))
        XCTAssertNil(LinkResolverService.extractURL(from: "https://example.com/not-music"))
    }

    // MARK: - Resolution

    func testResolveAppleMusicReturnsURLWithoutNetwork() async {
        let expected = "https://music.apple.com/us/album/x/123?i=456"
        let result = await resolver.resolve(url: expected)

        guard case .appleMusicURL(let url) = result else {
            XCTFail("Expected .appleMusicURL, got \(result)")
            return
        }
        XCTAssertEqual(url.absoluteString, expected)
    }

    func testResolveRejectsAppleMusicLookalikeHost() async {
        let result = await resolver.resolve(
            url: "https://example.com/music.apple.com/us/album/x/123"
        )

        guard case .notFound = result else {
            XCTFail("Expected .notFound, got \(result)")
            return
        }
    }

    func testResolveRejectsAppleMusicUserInfoAndInsecureTransport() async {
        let rejectedURLs = [
            "https://attacker@music.apple.com/us/album/x/123",
            "http://music.apple.com/us/album/x/123"
        ]

        for url in rejectedURLs {
            let result = await resolver.resolve(url: url)
            guard case .notFound = result else {
                XCTFail("Expected .notFound for \(url), got \(result)")
                continue
            }
        }
    }

    func testResolveSpotifyParsesOEmbedResponse() async {
        handlerStore.handler = { request in
            (MockURLProtocol.httpResponse(for: request, status: 200),
             Data(#"{"title":"Song Name","author_name":"Artist Name"}"#.utf8))
        }

        let result = await resolver.resolve(url: "https://open.spotify.com/track/abc")

        guard case .found(let title, let artist) = result else {
            XCTFail("Expected .found, got \(result)")
            return
        }
        XCTAssertEqual(title, "Song Name")
        XCTAssertEqual(artist, "Artist Name")
    }

    func testResolveOEmbed404IsNotFound() async {
        handlerStore.handler = { request in
            (MockURLProtocol.httpResponse(for: request, status: 404), Data())
        }

        let result = await resolver.resolve(url: "https://open.spotify.com/track/abc")

        guard case .notFound = result else {
            XCTFail("Expected .notFound, got \(result)")
            return
        }
    }

    func testResolveOEmbedServerErrorIsError() async {
        handlerStore.handler = { request in
            (MockURLProtocol.httpResponse(for: request, status: 500), Data())
        }

        let result = await resolver.resolve(url: "https://youtu.be/abc")

        guard case .error = result else {
            XCTFail("Expected .error, got \(result)")
            return
        }
    }

    func testResolveUnknownLinkIsNotFound() async {
        let result = await resolver.resolve(url: "https://example.com/whatever")

        guard case .notFound = result else {
            XCTFail("Expected .notFound, got \(result)")
            return
        }
    }
}

// MARK: - Test Helpers

extension LinkResolverService {
    /// Per-service detection for a chat message, through the production
    /// entry points: ``extractURL(from:)`` finds the first supported URL and
    /// ``service(for:)`` names its service. `nil` when nothing is supported.
    static func detectedService(in text: String) -> MusicService? {
        extractURL(from: text)
            .flatMap { URL(string: $0) }
            .flatMap { service(for: $0) }
    }
}
