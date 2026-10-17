//
//  AppleMusicController+Search.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import MusicKit

/// MusicKit catalog search and Apple Music link resolution.
extension AppleMusicController {

    // MARK: - Search (MusicKit)

    /// Search the Apple Music catalog for a song by text query.
    ///
    /// Auto-requests authorization if not yet determined.
    /// - Parameter query: The search text (song name, artist, etc.).
    /// - Returns: The search result.
    func search(query: String) async -> SearchResult {
        let result = await searchCandidates(query: query, limit: 1)
        if let error = result.error { return .error(error) }
        if let song = result.songs.first { return .found(song) }
        return .notFound
    }

    /// Catalog search returning several matches for link-metadata scoring.
    ///
    /// Auto-requests authorization if not yet determined.
    ///
    /// - Parameters:
    ///   - query: Search term.
    ///   - limit: Requested result count, clamped to 1...10.
    /// - Returns: The songs in MusicKit's relevance order, or an empty list and a
    ///   user-facing error string when unauthorized or the request throws.
    func searchCandidates(query: String, limit: Int) async -> (songs: [Song], error: String?) {
        guard await ensureAuthorized() else {
            return ([], "Apple Music access not authorized. Enable it in Settings → Song Requests.")
        }

        do {
            var request = MusicCatalogSearchRequest(term: query, types: [Song.self])
            request.limit = max(1, min(limit, 10))
            let response = try await request.response()

            return (Array(response.songs), nil)
        } catch {
            return ([], "Search failed: \(error.localizedDescription)")
        }
    }

    /// Resolve an Apple Music URL to a Song object.
    ///
    /// Called for links `LinkResolverService` classified as Apple Music. Tries an
    /// exact catalog-ID lookup first; if that throws or finds nothing, a link
    /// with a slug falls back to a text search on the slug words.
    ///
    /// - Returns: `.notFound` when neither the ID nor a slug search yields a song
    ///   (slug-less and album links have no slug to fall back on).
    func resolve(url: URL) async -> SearchResult {
        guard await ensureAuthorized() else {
            return .error("Apple Music access not authorized. Enable it in Settings → Song Requests.")
        }

        if let catalogID = Self.appleMusicCatalogID(for: url) {
            do {
                let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(catalogID))
                let response = try await request.response()
                if let song = response.items.first {
                    return .found(song)
                }
            } catch {
                Log.debug(
                    "AppleMusicController: Failed to resolve catalog ID, falling back to URL search: \(error)",
                    category: .songRequest)
            }
        }

        let pathComponents = url.path.split(separator: "/").map(String.init)
        // Only a link with a slug has words to search; a slug-less link's
        // third component is the numeric catalog ID.
        if pathComponents.count >= 4, pathComponents[1] == "song",
           let songSlug = pathComponents.dropFirst(2).first {
            let searchTerm = songSlug.replacingOccurrences(of: "-", with: " ")
            return await search(query: searchTerm)
        }

        return .notFound
    }

    /// Extracts the numeric catalog ID from an Apple Music share link.
    ///
    /// Handles `/<storefront>/song/<slug>/<id>`, slug-less `/<storefront>/song/<id>`,
    /// and `/<storefront>/album/<slug>/<id>?i=<trackID>` (the `i` item is the track;
    /// the path ID is the album and is ignored).
    ///
    /// - Returns: The song's catalog ID, or `nil` for any other shape.
    static func appleMusicCatalogID(for url: URL) -> String? {
        let path = url.path.split(separator: "/").map(String.init)
        guard path.count >= 3 else { return nil }
        if path[1] == "song", path.count == 4, UInt64(path[3]) != nil {
            return path[3]
        }
        // Slug-less song link: /<storefront>/song/<id>
        if path[1] == "song", path.count == 3, UInt64(path[2]) != nil {
            return path[2]
        }
        if path[1] == "album",
           let itemID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "i" })?.value,
           UInt64(itemID) != nil {
            return itemID
        }
        return nil
    }
}
