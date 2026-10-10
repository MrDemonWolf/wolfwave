//
//  SongSearchResolver.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-04-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import MusicKit

/// Multi-source song search resolver.
///
/// Handles four search paths:
/// 1. **Plain text** → MusicKit catalog search directly
/// 2. **Spotify link** → oEmbed API → extract title/artist → MusicKit search
/// 3. **YouTube link** → oEmbed API → extract title/artist → MusicKit search
/// 4. **Apple Music link** → MusicKit resolve directly
///
/// Always returns a MusicKit `Song` on success for consistent playback.
final class SongSearchResolver {
    // MARK: - Types

    /// Result of a search resolution.
    enum Result {
        case found(Song)
        case notFound(query: String)
        case linkNotFound
        case error(String)
    }

    // MARK: - Properties

    private let linkResolver: LinkResolverService
    private let musicController: any AppleMusicControlling

    // MARK: - Init

    init(linkResolver: LinkResolverService = LinkResolverService(), musicController: any AppleMusicControlling) {
        self.linkResolver = linkResolver
        self.musicController = musicController
    }

    // MARK: - Public API

    /// Resolve a search query to a MusicKit Song.
    func resolve(query: String) async -> Result {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return .error("No search query provided")
        }

        if let musicURL = LinkResolverService.extractURL(from: trimmed) {
            return await resolveLink(musicURL)
        }

        return await resolveText(trimmed)
    }

    // MARK: - Private Helpers

    /// Resolves a validated Apple Music, Spotify, or YouTube URL into a catalog
    /// track via `LinkResolverService` + MusicKit.
    ///
    /// - Parameter urlString: The validated music URL extracted from chat text.
    /// - Returns: `.found`, `.linkNotFound`, or `.error`.
    private func resolveLink(_ urlString: String) async -> Result {
        Log.debug("SongSearchResolver: Resolving link: \(urlString)", category: .songRequest)

        let result = await linkResolver.resolve(url: urlString)

        switch result {
        case .appleMusicURL(let url):
            // Resolve Apple Music URL directly via MusicKit
            let musicResult = await musicController.resolve(url: url)
            switch musicResult {
            case .found(let song):
                return .found(song)
            case .notFound:
                return .linkNotFound
            case .error(let message):
                return .error(message)
            }

        case .found(let title, let artist):
            let searchQuery = artist.map { "\(title) \($0)" } ?? title
            Log.debug("SongSearchResolver: oEmbed resolved to: \(searchQuery)", category: .songRequest)
            let candidates = await musicController.searchCandidates(query: searchQuery, limit: 10)
            if let error = candidates.error { return .error(error) }
            let host = URL(string: urlString)?.host ?? ""
            let youtube = host.hasSuffix("youtube.com") || host == "youtu.be"
            let pieces = TrackTextNormalizer.title(title).components(separatedBy: " - ")
            let expectedTitle = youtube && pieces.count == 2 ? pieces[1] : TrackTextNormalizer.title(title)
            let expectedArtist = youtube && pieces.count == 2 ? pieces[0] : artist.map(TrackTextNormalizer.title)
            guard !expectedTitle.isEmpty else { return .linkNotFound }
            let expectedWords = Set(expectedTitle.split(separator: " "))
            let scored = candidates.songs.map { song -> (song: Song, score: Double) in
                let words = Set(TrackTextNormalizer.title(song.title).split(separator: " "))
                let titleScore = Double(words.intersection(expectedWords).count)
                    / Double(max(1, words.union(expectedWords).count))
                let score: Double
                if let expectedArtist, !expectedArtist.isEmpty {
                    score = titleScore * 0.8 + (TrackTextNormalizer.title(song.artistName) == expectedArtist ? 0.2 : 0)
                } else {
                    score = titleScore
                }
                return (song, score)
            }.sorted { $0.score > $1.score }
            guard let best = scored.first, best.score >= 0.9,
                  scored.count == 1 || best.score > scored[1].score else { return .linkNotFound }
            return .found(best.song)

        case .notFound:
            return .linkNotFound

        case .error(let message):
            return .error(message)
        }
    }

    /// Searches the Apple Music catalog for the best match for a plain-text
    /// query and maps the controller response into a `Result`.
    ///
    /// - Parameter query: Search string (song name, artist, etc.).
    /// - Returns: `.found`, `.notFound`, or `.error`.
    private func resolveText(_ query: String) async -> Result {
        Log.debug("SongSearchResolver: Searching Apple Music for: \(query)", category: .songRequest)

        let searchResult = await musicController.search(query: query)

        switch searchResult {
        case .found(let song):
            return .found(song)
        case .notFound:
            return .notFound(query: query)
        case .error(let message):
            return .error(message)
        }
    }
}
