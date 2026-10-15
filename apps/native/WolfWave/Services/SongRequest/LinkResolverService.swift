//
//  LinkResolverService.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-04-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Resolves Spotify, YouTube, and Apple Music links to song metadata.
///
/// Uses the public oEmbed endpoints (no auth or API key) for Spotify and YouTube.
/// Apple Music links are returned directly for MusicKit resolution.
///
/// `nonisolated` (opting out of the module's default `MainActor`) because it
/// holds only an immutable `HTTPClient` and does pure parsing plus one network
/// call, so it can run off the main thread.
///
/// Chat text is untrusted: only `https` URLs on an exact host allow-list with a
/// service-specific path shape ever reach MusicKit or an outbound oEmbed request.
nonisolated final class LinkResolverService {
    // MARK: - Types

    /// Supported destination identified from a validated URL.
    ///
    /// Internal (not private) only so tests can assert per-service detection
    /// through ``service(for:)``.
    enum MusicService: Equatable, Sendable {
        /// `open.spotify.com/track/…` (optionally `intl-xx/` prefixed) or a `spotify.link` short link.
        case spotify
        /// `youtube.com/watch?v=…` on the www / m / music hosts, or a `youtu.be` short link.
        case youtube
        /// A `music.apple.com` song link, or an album link pinned to a track with `?i=`.
        case appleMusic
    }

    /// Result of resolving a music link.
    enum ResolveResult {
        /// Extracted song title and artist from the link.
        case found(title: String, artist: String?)

        /// The link is an Apple Music URL. Resolve directly via MusicKit.
        case appleMusicURL(URL)

        /// Could not extract metadata from the link.
        case notFound

        /// The oEmbed request failed (non-404 HTTP status, undecodable body, or
        /// transport error). The message is short and shown in chat.
        case error(String)
    }

    /// Minimal oEmbed response shape (`title` + optional `author_name`).
    private struct OEmbedResponse: Decodable {
        let title: String?
        let authorName: String?
    }

    // MARK: - Properties

    /// HTTP client with a snake-case decoder so `author_name` maps to `authorName`.
    private let http: HTTPClient

    // MARK: - Init

    /// - Parameter session: Session for oEmbed requests; tests inject a stubbed one.
    init(session: URLSession = .shared) {
        // Use a dedicated HTTPClient configured to decode `author_name` → `authorName`.
        self.http = HTTPClient(session: session, decoder: JSONCoders.snakeCase)
    }

    // MARK: - Link Detection

    /// Extract the first supported music URL from a chat message.
    ///
    /// Unsupported links earlier in the message are skipped, so
    /// "check this https://example.com then https://open.spotify.com/track/…" still resolves.
    ///
    /// - Parameter text: Raw chat text.
    /// - Returns: The first URL that passes ``service(for:)``, or `nil` if none does.
    static func extractURL(from text: String) -> String? {
        detectedURLs(in: text)
            .first { service(for: $0) != nil }?
            .absoluteString
    }

    // MARK: - Resolution

    /// Resolve a music link to song metadata.
    ///
    /// - Parameter url: The music service URL to resolve.
    /// - Returns: The resolution result with title/artist or Apple Music URL.
    ///   `.notFound` for a string that is not a supported URL; this re-validates
    ///   even when the caller already went through ``extractURL(from:)``.
    func resolve(url: String) async -> ResolveResult {
        guard let sourceURL = URL(string: url),
              let service = Self.service(for: sourceURL)
        else { return .notFound }

        switch service {
        case .appleMusic:
            return .appleMusicURL(sourceURL)
        case .spotify:
            return await resolveViaOEmbed(
                base: AppConstants.API.spotifyOEmbed,
                sourceURL: sourceURL.absoluteString,
                includeFormat: false
            )
        case .youtube:
            return await resolveViaOEmbed(
                base: AppConstants.API.youtubeOEmbed,
                sourceURL: sourceURL.absoluteString,
                includeFormat: true
            )
        }
    }

    // MARK: - Private Helpers

    /// Finds URL-shaped content in natural-language chat text using
    /// Foundation's system data detector. URL parsing below remains the
    /// validation boundary, as recommended by Foundation.
    private static func detectedURLs(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: range)
            .compactMap { $0.url }
    }

    /// Validates transport, exact host, and service-specific path before a URL
    /// can enter either MusicKit or an oEmbed request.
    ///
    /// Internal (not private) so tests can assert per-service detection
    /// without stubbing the oEmbed network path.
    static func service(for url: URL) -> MusicService? {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              let host = url.host?.lowercased()
        else { return nil }

        let path = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        switch host {
        case "open.spotify.com":
            guard isSpotifyTrackPath(path) else { return nil }
            return .spotify
        case "spotify.link":
            guard path.count == 1 else { return nil }
            return .spotify
        case "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com":
            guard
                path == ["watch"],
                let videoID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "v" })?
                    .value,
                !videoID.isEmpty
            else { return nil }
            return .youtube
        case "youtu.be":
            guard path.count == 1 else { return nil }
            return .youtube
        case "music.apple.com":
            guard isAppleMusicTrackPath(path, url: url) else { return nil }
            return .appleMusic
        default:
            return nil
        }
    }

    /// Spotify emits both canonical track links and locale-prefixed web links.
    ///
    /// Accepts `track/<id>` and `intl-<locale>/track/<id>`. Albums, playlists,
    /// and podcasts are rejected because they don't name a single song.
    private static func isSpotifyTrackPath(_ path: [String]) -> Bool {
        if path.count == 2 {
            return path[0] == "track"
        }
        guard path.count == 3,
              path[0].hasPrefix("intl-"),
              path[0].count > "intl-".count
        else { return false }
        return path[1] == "track"
    }

    /// Apple Music share links use:
    /// /<storefront>/(album|song)/<slug>/<numeric catalog id>
    /// Song links may also drop the slug: /<storefront>/song/<numeric catalog id>
    ///
    /// The storefront must be two lowercase ASCII letters. An album link only
    /// counts when its `?i=<numeric id>` query names the track inside the album,
    /// since a bare album isn't a single song.
    private static func isAppleMusicTrackPath(_ path: [String], url: URL) -> Bool {
        guard path.count >= 3,
              path[0].utf8.count == 2,
              path[0].utf8.allSatisfy({ (97...122).contains(Int($0)) })
        else { return false }
        if path.count == 3 {
            return path[1] == "song" && UInt64(path[2]) != nil
        }
        guard path.count == 4,
              path[1] == "album" || path[1] == "song",
              !path[2].isEmpty
        else { return false }
        guard UInt64(path[3]) != nil else { return false }
        if path[1] == "song" { return true }
        guard let itemID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "i" })?.value else { return false }
        return UInt64(itemID) != nil
    }

    /// Resolve a link via an oEmbed endpoint.
    ///
    /// - Parameters:
    ///   - base: oEmbed endpoint (`AppConstants.API.spotifyOEmbed` / `youtubeOEmbed`).
    ///   - sourceURL: The validated share URL, sent as the `url` query item.
    ///   - includeFormat: Adds `format=json` (sent for YouTube only).
    /// - Returns: `.found` with the oEmbed `title` and `author_name`; `.notFound`
    ///   for a 404 or an empty title (deleted / private item); `.error` otherwise.
    private func resolveViaOEmbed(base: String, sourceURL: String, includeFormat: Bool) async -> ResolveResult {
        guard var components = URLComponents(string: base) else {
            return .error("Invalid oEmbed URL")
        }
        var items = [URLQueryItem(name: "url", value: sourceURL)]
        if includeFormat {
            items.append(URLQueryItem(name: "format", value: "json"))
        }
        components.queryItems = items
        guard let requestURL = components.url else {
            return .error("Invalid oEmbed URL")
        }

        do {
            let response: OEmbedResponse = try await http.get(url: requestURL)
            if let title = response.title, !title.isEmpty {
                return .found(title: title, artist: response.authorName)
            }
            return .notFound
        } catch HTTPClient.HTTPError.unexpectedStatus(let code, _) where code == 404 {
            return .notFound
        } catch HTTPClient.HTTPError.unexpectedStatus(let code, _) {
            return .error("oEmbed error (HTTP \(code))")
        } catch HTTPClient.HTTPError.decodingFailed {
            return .error("Failed to parse oEmbed response")
        } catch {
            return .error("Network error: \(error.localizedDescription)")
        }
    }
}
