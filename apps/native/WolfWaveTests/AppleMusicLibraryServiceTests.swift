//
//  AppleMusicLibraryServiceTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-06-08.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Testing

@testable import WolfWave

/// Covers request building, playlist ownership matching, persisted-id recovery,
/// and the concurrency around first-use playlist creation. Transport seams keep
/// these tests deterministic without a live MusicKit user token.
@MainActor
@Suite("Apple Music Library Service", .serialized, .isolatedSharedTestState)
struct AppleMusicLibraryServiceTests {

    @Test("endpoint builds a versioned Apple Music API URL")
    func endpointBuildsVersionedURL() throws {
        let url = try AppleMusicLibraryService.endpoint("/me/library/playlists")
        #expect(url.absoluteString == "https://api.music.apple.com/v1/me/library/playlists")
    }

    @Test("endpoint embeds a playlist id in the tracks path")
    func endpointEmbedsPlaylistID() throws {
        let url = try AppleMusicLibraryService.endpoint("/me/library/playlists/p.ABC123/tracks")
        #expect(url.absoluteString == "https://api.music.apple.com/v1/me/library/playlists/p.ABC123/tracks")
    }

    @Test("add-tracks body carries the catalog song id with type songs")
    func addTracksBodyShape() throws {
        let data = try AppleMusicLibraryService.addTracksBody(forCatalogSongID: "1440889742")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let array = json?["data"] as? [[String: Any]]
        #expect(array?.count == 1)
        #expect(array?.first?["id"] as? String == "1440889742")
        // Catalog songs are added with the catalog resource type "songs".
        #expect(array?.first?["type"] as? String == "songs")
    }

    @Test("create-playlist body names and describes the WolfWave Requests playlist")
    func createPlaylistBodyShape() throws {
        let data = try AppleMusicLibraryService.createPlaylistBody()
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let attributes = json?["attributes"] as? [String: Any]
        #expect(attributes?["name"] as? String == AppConstants.Music.requestsPlaylistName)
        #expect((attributes?["description"] as? String)?.isEmpty == false)
        #expect(attributes?["authorDisplayName"] == nil)
    }

    @Test("API base and playlist name constants are stable")
    func constantsAreStable() {
        #expect(AppConstants.Music.requestsPlaylistName == "WolfWave Requests")
        #expect(AppConstants.Music.apiBaseURL == "https://api.music.apple.com/v1")
    }

    // MARK: - Playlist identity and ensure lifecycle

    @Test("ownership matching requires the exact WolfWave description marker")
    func ownershipMatchingRequiresMarker() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let data = try libraryData([
            (
                id: "p.user",
                name: AppConstants.Music.requestsPlaylistName,
                description: "My personal playlist"
            ),
            (
                id: "p.owned",
                name: AppConstants.Music.requestsPlaylistName,
                description: AppConstants.Music.requestsPlaylistDescription
            )
        ])
        let transport = PagingPlaylistTransport(
            responses: ["/me/library/playlists?limit=100": data])
        let service = AppleMusicLibraryService(
            defaults: defaults,
            getOverride: { path in try await transport.get(path) },
            postOverride: { path, body in try await transport.post(path, body: body) })

        #expect(try await service.ensureRequestsPlaylist() == "p.owned")
        #expect(await transport.callCounts() == (get: 1, post: 0))
    }

    @Test("same-name user playlist without marker is ignored")
    func sameNameWithoutMarkerIsIgnored() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let data = try libraryData([
            (
                id: "p.user",
                name: AppConstants.Music.requestsPlaylistName,
                description: nil
            )
        ])
        let transport = PagingPlaylistTransport(
            responses: ["/me/library/playlists?limit=100": data])
        let service = AppleMusicLibraryService(
            defaults: defaults,
            getOverride: { path in try await transport.get(path) },
            postOverride: { path, body in try await transport.post(path, body: body) })

        // Discovery must not adopt the user's playlist; it creates its own.
        #expect(try await service.ensureRequestsPlaylist() == "p.created")
        #expect(await transport.callCounts() == (get: 1, post: 1))
    }

    @Test("persisted playlist id survives a user-edited description")
    func persistedPlaylistIDAllowsEditedDescription() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let playlistID = "p.persisted"
        defaults.set(playlistID, forKey: AppConstants.UserDefaults.songRequestPlaylistID)
        let ownedData = try libraryData([
            (
                id: playlistID,
                name: AppConstants.Music.requestsPlaylistName,
                description: "Streamer edited this description"
            )
        ])
        let service = AppleMusicLibraryService(
            defaults: defaults,
            getOverride: { path in
                guard path == "/me/library/playlists/\(playlistID)" else {
                    throw AppleMusicLibraryTestError.unexpectedPath(path)
                }
                return ownedData
            },
            postOverride: { path, _ in
                throw AppleMusicLibraryTestError.unexpectedPath(path)
            })

        #expect(try await service.ensureRequestsPlaylist() == playlistID)
        #expect(defaults.string(forKey: AppConstants.UserDefaults.songRequestPlaylistID) == playlistID)
    }

    @Test("stale persisted id falls back to owned playlist scan")
    func stalePersistedIDRecoversFromScan() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("p.deleted", forKey: AppConstants.UserDefaults.songRequestPlaylistID)
        let recoveredID = "p.recovered"
        let recoveredData = try libraryData([
            (
                id: recoveredID,
                name: AppConstants.Music.requestsPlaylistName,
                description: AppConstants.Music.requestsPlaylistDescription
            )
        ])
        let service = AppleMusicLibraryService(
            defaults: defaults,
            getOverride: { path in
                switch path {
                case "/me/library/playlists/p.deleted":
                    return nil
                case "/me/library/playlists?limit=100":
                    return recoveredData
                default:
                    throw AppleMusicLibraryTestError.unexpectedPath(path)
                }
            },
            postOverride: { path, _ in
                throw AppleMusicLibraryTestError.unexpectedPath(path)
            })

        #expect(try await service.ensureRequestsPlaylist() == recoveredID)
        #expect(defaults.string(forKey: AppConstants.UserDefaults.songRequestPlaylistID) == recoveredID)
    }

    // MARK: - Share URL resolution parsing

    @Test("share URL is extracted from a catalog playlist response")
    func parseShareURLFromCatalog() {
        let json = """
        {"data":[{"id":"pl.u-abc","type":"playlists","attributes":{"name":"WolfWave Requests","url":"https://music.apple.com/us/playlist/wolfwave-requests/pl.u-abc"}}]}
        """
        let url = AppleMusicLibraryService.parseShareURL(fromCatalogData: Data(json.utf8))
        #expect(url == "https://music.apple.com/us/playlist/wolfwave-requests/pl.u-abc")
    }

    @Test("an empty catalog response yields no share URL")
    func parseShareURLEmpty() {
        #expect(AppleMusicLibraryService.parseShareURL(fromCatalogData: Data("{\"data\":[]}".utf8)) == nil)
    }

    @Test("globalId is read from a published library playlist")
    func parseGlobalIDPublished() {
        let json = """
        {"data":[{"id":"p.xyz","type":"library-playlists","attributes":{"name":"WolfWave Requests","playParams":{"id":"p.xyz","isLibrary":true,"globalId":"pl.u-abc"}}}]}
        """
        #expect(AppleMusicLibraryService.parseGlobalID(fromLibraryData: Data(json.utf8)) == "pl.u-abc")
    }

    @Test("a private library playlist has no globalId")
    func parseGlobalIDPrivate() {
        let json = """
        {"data":[{"id":"p.xyz","type":"library-playlists","attributes":{"name":"WolfWave Requests","playParams":{"id":"p.xyz","isLibrary":true}}}]}
        """
        #expect(AppleMusicLibraryService.parseGlobalID(fromLibraryData: Data(json.utf8)) == nil)
    }

    @Test("storefront id is read from the storefront response")
    func parseStorefrontID() {
        let json = """
        {"data":[{"id":"us","type":"storefronts","attributes":{"name":"United States"}}]}
        """
        #expect(AppleMusicLibraryService.parseStorefront(fromData: Data(json.utf8)) == "us")
    }

    // MARK: - Fixtures

    /// A throwaway `UserDefaults` suite (emptied before use) and its name; the caller removes it.
    func isolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "AppleMusicLibraryServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    /// Builds a library-playlists JSON page from `(id, name, description)` tuples. `next` adds a
    /// pagination link.
    func libraryData(
        _ resources: [(id: String, name: String, description: String?)],
        next: String? = nil
    ) throws -> Data {
        let jsonResources: [[String: Any]] = resources.map { resource in
            var attributes: [String: Any] = ["name": resource.name]
            if let description = resource.description {
                attributes["description"] = ["standard": description]
            }
            return [
                "id": resource.id,
                "type": "library-playlists",
                "attributes": attributes
            ]
        }
        var page: [String: Any] = ["data": jsonResources]
        if let next {
            page["next"] = next
        }
        return try JSONSerialization.data(withJSONObject: page)
    }
}
