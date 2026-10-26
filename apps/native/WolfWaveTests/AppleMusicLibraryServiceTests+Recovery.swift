//
//  AppleMusicLibraryServiceTests+Recovery.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Testing

@testable import WolfWave

/// Playlist recovery: stale ids, missing-playlist retries, paged discovery, and coalesced ensures.
extension AppleMusicLibraryServiceTests {
    @Test("a stale cached playlist 404 re-resolves once and persists the new id")
    func staleCachedPlaylistRecoversOnce() async throws {
        let scratch = ThrowawayDefaults("AppleMusicLibraryServiceTests")
        defer { scratch.destroy() }
        let defaults = scratch.defaults
        let oldID = "p.deleted"
        let newID = "p.recovered"
        defaults.set(oldID, forKey: AppConstants.UserDefaults.songRequestPlaylistID)
        let oldData = try libraryData([
            (
                id: oldID,
                name: AppConstants.Music.requestsPlaylistName,
                description: "An edited description is still the persisted resource"
            )
        ])
        let newData = try libraryData([
            (
                id: newID,
                name: AppConstants.Music.requestsPlaylistName,
                description: AppConstants.Music.requestsPlaylistDescription
            )
        ])
        let transport = PlaylistRecoveryTransport(
            oldID: oldID,
            newID: newID,
            oldData: oldData,
            newData: newData,
            outcomes: [.missing, .success])
        let service = AppleMusicLibraryService(
            defaults: defaults,
            getOverride: { path in try await transport.get(path) },
            postOverride: { path, body in try await transport.post(path, body: body) })

        try await service.addCatalogSongIDToRequestsPlaylist("catalog-song")

        let calls = await transport.calls()
        #expect(calls.get == [
            "/me/library/playlists/\(oldID)",
            "/me/library/playlists?limit=100"
        ])
        #expect(calls.post == [
            "/me/library/playlists/\(oldID)/tracks",
            "/me/library/playlists/\(newID)/tracks"
        ])
        #expect(defaults.string(forKey: AppConstants.UserDefaults.songRequestPlaylistID) == newID)
    }

    @Test("concurrent stale 404s share one recovery and both retry the new id")
    func concurrentMissingPlaylistFailuresShareRecovery() async throws {
        let scratch = ThrowawayDefaults("AppleMusicLibraryServiceTests")
        defer { scratch.destroy() }
        let defaults = scratch.defaults
        let oldID = "p.deleted"
        let newID = "p.recovered"
        defaults.set(oldID, forKey: AppConstants.UserDefaults.songRequestPlaylistID)
        let oldData = try libraryData([
            (
                id: oldID,
                name: AppConstants.Music.requestsPlaylistName,
                description: "Edited after ownership was established"
            )
        ])
        let newData = try libraryData([
            (
                id: newID,
                name: AppConstants.Music.requestsPlaylistName,
                description: AppConstants.Music.requestsPlaylistDescription
            )
        ])
        let transport = ConcurrentPlaylistRecoveryTransport(
            oldID: oldID,
            newID: newID,
            oldData: oldData,
            newData: newData)
        let service = AppleMusicLibraryService(
            defaults: defaults,
            getOverride: { path in try await transport.get(path) },
            postOverride: { path, body in try await transport.post(path, body: body) })

        async let first: Void = service.addCatalogSongIDToRequestsPlaylist("song-one")
        async let second: Void = service.addCatalogSongIDToRequestsPlaylist("song-two")
        await transport.waitUntilRecoveryLookupStarted()

        await transport.releaseRecoveryLookup()
        _ = try await first
        _ = try await second

        let counts = await transport.callCounts()
        #expect(counts.oldTrackPosts == 2)
        #expect(counts.recoveryGets == 1)
        #expect(counts.newTrackPosts == 2)
        #expect(defaults.string(forKey: AppConstants.UserDefaults.songRequestPlaylistID) == newID)
    }

    @Test("a non-404 track failure never resets or retries the playlist")
    func nonMissingTrackFailureDoesNotRetry() async throws {
        let scratch = ThrowawayDefaults("AppleMusicLibraryServiceTests")
        defer { scratch.destroy() }
        let defaults = scratch.defaults
        let playlistID = "p.current"
        defaults.set(playlistID, forKey: AppConstants.UserDefaults.songRequestPlaylistID)
        let data = try libraryData([
            (
                id: playlistID,
                name: AppConstants.Music.requestsPlaylistName,
                description: "User edited"
            )
        ])
        let transport = PlaylistRecoveryTransport(
            oldID: playlistID,
            newID: "p.unused",
            oldData: data,
            newData: data,
            outcomes: [.transient])
        let service = AppleMusicLibraryService(
            defaults: defaults,
            getOverride: { path in try await transport.get(path) },
            postOverride: { path, body in try await transport.post(path, body: body) })

        var sawTransientFailure = false
        do {
            try await service.addCatalogSongIDToRequestsPlaylist("catalog-song")
        } catch AppleMusicLibraryTestError.transient {
            sawTransientFailure = true
        }

        #expect(sawTransientFailure)
        let calls = await transport.calls()
        #expect(calls.get == ["/me/library/playlists/\(playlistID)"])
        #expect(calls.post == ["/me/library/playlists/\(playlistID)/tracks"])
        #expect(defaults.string(forKey: AppConstants.UserDefaults.songRequestPlaylistID) == playlistID)
    }

    @Test("a second missing-playlist failure propagates without a retry loop")
    func secondMissingPlaylistFailureDoesNotLoop() async throws {
        let scratch = ThrowawayDefaults("AppleMusicLibraryServiceTests")
        defer { scratch.destroy() }
        let defaults = scratch.defaults
        let oldID = "p.deleted"
        let newID = "p.also-deleted"
        defaults.set(oldID, forKey: AppConstants.UserDefaults.songRequestPlaylistID)
        let oldData = try libraryData([
            (
                id: oldID,
                name: AppConstants.Music.requestsPlaylistName,
                description: nil
            )
        ])
        let newData = try libraryData([
            (
                id: newID,
                name: AppConstants.Music.requestsPlaylistName,
                description: AppConstants.Music.requestsPlaylistDescription
            )
        ])
        let transport = PlaylistRecoveryTransport(
            oldID: oldID,
            newID: newID,
            oldData: oldData,
            newData: newData,
            outcomes: [.missing, .missing])
        let service = AppleMusicLibraryService(
            defaults: defaults,
            getOverride: { path in try await transport.get(path) },
            postOverride: { path, body in try await transport.post(path, body: body) })

        var sawMissingFailure = false
        do {
            try await service.addCatalogSongIDToRequestsPlaylist("catalog-song")
        } catch AppleMusicLibraryError.playlistMissing {
            sawMissingFailure = true
        }

        #expect(sawMissingFailure)
        let calls = await transport.calls()
        #expect(calls.post == [
            "/me/library/playlists/\(oldID)/tracks",
            "/me/library/playlists/\(newID)/tracks"
        ])
        #expect(defaults.string(forKey: AppConstants.UserDefaults.songRequestPlaylistID) == newID)
    }

    @Test("playlist discovery follows pagination beyond twenty pages")
    func discoveryHasNoFixedPageCap() async throws {
        let scratch = ThrowawayDefaults("AppleMusicLibraryServiceTests")
        defer { scratch.destroy() }
        let defaults = scratch.defaults
        let targetPage = 21
        let targetID = "p.page-21"
        var responses: [String: Data] = [:]
        for page in 0...targetPage {
            let path = page == 0
                ? "/me/library/playlists?limit=100"
                : "/me/library/playlists?offset=\(page)"
            let next = page < targetPage
                ? "/v1/me/library/playlists?offset=\(page + 1)"
                : nil
            let resources: [(id: String, name: String, description: String?)] = page == targetPage
                ? [(
                    id: targetID,
                    name: AppConstants.Music.requestsPlaylistName,
                    description: AppConstants.Music.requestsPlaylistDescription
                )]
                : []
            responses[path] = try libraryData(resources, next: next)
        }
        let transport = PagingPlaylistTransport(responses: responses)
        let service = AppleMusicLibraryService(
            defaults: defaults,
            getOverride: { path in try await transport.get(path) },
            postOverride: { path, body in try await transport.post(path, body: body) })

        #expect(try await service.ensureRequestsPlaylist() == targetID)
        #expect(await transport.callCounts() == (get: targetPage + 1, post: 0))
    }

    @Test("a repeated pagination next path terminates and creates once")
    func repeatedNextPathCannotLoop() async throws {
        let scratch = ThrowawayDefaults("AppleMusicLibraryServiceTests")
        defer { scratch.destroy() }
        let defaults = scratch.defaults
        let path = "/me/library/playlists?limit=100"
        let response = try libraryData([], next: "/v1\(path)")
        let transport = PagingPlaylistTransport(responses: [path: response])
        let service = AppleMusicLibraryService(
            defaults: defaults,
            getOverride: { path in try await transport.get(path) },
            postOverride: { path, body in try await transport.post(path, body: body) })

        #expect(try await service.ensureRequestsPlaylist() == "p.created")
        #expect(await transport.callCounts() == (get: 1, post: 1))
    }

    @Test("concurrent first ensures share one lookup and creation")
    func concurrentEnsuresAreCoalesced() async throws {
        let scratch = ThrowawayDefaults("AppleMusicLibraryServiceTests")
        defer { scratch.destroy() }
        let defaults = scratch.defaults
        let transport = CoalescingPlaylistTransport()
        let service = AppleMusicLibraryService(
            defaults: defaults,
            getOverride: { path in try await transport.get(path) },
            postOverride: { path, body in try await transport.post(path, body: body) })

        async let firstID = service.ensureRequestsPlaylist()
        async let secondID = service.ensureRequestsPlaylist()
        await transport.waitUntilLookupStarted()
        await transport.releaseLookup()

        let ids = try await (firstID, secondID)
        #expect(ids.0 == "p.created")
        #expect(ids.1 == "p.created")
        let counts = await transport.callCounts()
        #expect(counts.get == 1)
        #expect(counts.post == 1)
    }

    @Test("failed ensure clears the shared task so a later call can retry")
    func failedEnsureCanRetry() async throws {
        let scratch = ThrowawayDefaults("AppleMusicLibraryServiceTests")
        defer { scratch.destroy() }
        let defaults = scratch.defaults
        let recoveredData = try libraryData([
            (
                id: "p.retry",
                name: AppConstants.Music.requestsPlaylistName,
                description: AppConstants.Music.requestsPlaylistDescription
            )
        ])
        let transport = RetryPlaylistTransport(recoveredData: recoveredData)
        let service = AppleMusicLibraryService(
            defaults: defaults,
            getOverride: { path in try await transport.get(path) },
            postOverride: { path, body in try await transport.post(path, body: body) })

        var firstCallFailed = false
        do {
            _ = try await service.ensureRequestsPlaylist()
        } catch {
            firstCallFailed = true
        }
        #expect(firstCallFailed)
        #expect(try await service.ensureRequestsPlaylist() == "p.retry")
        #expect(await transport.getCallCount() == 2)
    }

    @Test("reset cancels an old ensure without clearing a newer result")
    func resetInvalidatesInFlightEnsure() async throws {
        let scratch = ThrowawayDefaults("AppleMusicLibraryServiceTests")
        defer { scratch.destroy() }
        let defaults = scratch.defaults
        defaults.set("p.old", forKey: AppConstants.UserDefaults.songRequestPlaylistID)
        let newData = try libraryData([
            (
                id: "p.new",
                name: AppConstants.Music.requestsPlaylistName,
                description: AppConstants.Music.requestsPlaylistDescription
            )
        ])
        let transport = ResetRacePlaylistTransport(newData: newData)
        let service = AppleMusicLibraryService(
            defaults: defaults,
            getOverride: { path in try await transport.get(path) },
            postOverride: { path, body in try await transport.post(path, body: body) })

        let staleEnsure = Task { try await service.ensureRequestsPlaylist() }
        await transport.waitUntilFirstLookupStarted()
        service.resetCachedPlaylistID()
        #expect(defaults.string(forKey: AppConstants.UserDefaults.songRequestPlaylistID) == nil)

        let currentEnsure = Task { try await service.ensureRequestsPlaylist() }
        #expect(try await currentEnsure.value == "p.new")
        await transport.releaseFirstLookup()

        var staleWasCancelled = false
        do {
            _ = try await staleEnsure.value
        } catch is CancellationError {
            staleWasCancelled = true
        } catch {}
        #expect(staleWasCancelled)
        #expect(defaults.string(forKey: AppConstants.UserDefaults.songRequestPlaylistID) == "p.new")
    }
}
