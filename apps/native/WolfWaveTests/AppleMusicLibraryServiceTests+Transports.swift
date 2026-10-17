//
//  AppleMusicLibraryServiceTests+Transports.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Testing

@testable import WolfWave

/// Errors thrown by the playlist transport fakes: a transient failure, or a request to a path the
/// test did not expect.
enum AppleMusicLibraryTestError: Error {
    case transient
    case unexpectedPath(String)
}

/// Playlist transport whose listing GET parks until `releaseLookup()`, and which counts GETs and
/// POSTs, to prove concurrent lookups share one request and one create.
actor CoalescingPlaylistTransport {
    private var getCalls = 0
    private var postCalls = 0
    private var lookupStarted = false
    private var lookupReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func get(_ path: String) async throws -> Data? {
        guard path == "/me/library/playlists?limit=100" else {
            throw AppleMusicLibraryTestError.unexpectedPath(path)
        }
        getCalls += 1
        lookupStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !lookupReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return Data("{\"data\":[]}".utf8)
    }

    func post(_ path: String, body _: Data) throws -> Data {
        guard path == "/me/library/playlists" else {
            throw AppleMusicLibraryTestError.unexpectedPath(path)
        }
        postCalls += 1
        return Data("{\"data\":[{\"id\":\"p.created\",\"type\":\"library-playlists\"}]}".utf8)
    }

    func waitUntilLookupStarted() async {
        guard !lookupStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseLookup() {
        lookupReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func callCounts() -> (get: Int, post: Int) {
        (getCalls, postCalls)
    }
}

/// Playlist transport whose first listing GET throws a transient error and whose later GETs return
/// the recovered data.
actor RetryPlaylistTransport {
    private let recoveredData: Data
    private var getCalls = 0

    init(recoveredData: Data) {
        self.recoveredData = recoveredData
    }

    func get(_ path: String) throws -> Data? {
        guard path == "/me/library/playlists?limit=100" else {
            throw AppleMusicLibraryTestError.unexpectedPath(path)
        }
        getCalls += 1
        if getCalls == 1 {
            throw AppleMusicLibraryTestError.transient
        }
        return recoveredData
    }

    func post(_ path: String, body _: Data) throws -> Data {
        throw AppleMusicLibraryTestError.unexpectedPath(path)
    }

    func getCallCount() -> Int {
        getCalls
    }
}

/// Playlist transport that parks the first lookup (of the old playlist id) until released, then
/// checks cancellation. Models a reset landing mid-lookup, after which the new playlist data must
/// win.
actor ResetRacePlaylistTransport {
    private let newData: Data
    private var getCalls = 0
    private var firstLookupStarted = false
    private var firstLookupReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(newData: Data) {
        self.newData = newData
    }

    func get(_ path: String) async throws -> Data? {
        getCalls += 1
        if getCalls == 1 {
            guard path == "/me/library/playlists/p.old" else {
                throw AppleMusicLibraryTestError.unexpectedPath(path)
            }
            firstLookupStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if !firstLookupReleased {
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }
            try Task.checkCancellation()
            return nil
        }
        guard path == "/me/library/playlists?limit=100" else {
            throw AppleMusicLibraryTestError.unexpectedPath(path)
        }
        return newData
    }

    func post(_ path: String, body _: Data) throws -> Data {
        throw AppleMusicLibraryTestError.unexpectedPath(path)
    }

    func waitUntilFirstLookupStarted() async {
        guard !firstLookupStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstLookup() {
        firstLookupReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

/// Scripted result of one track POST: success, the playlist is gone, or a transient failure.
enum TrackPostOutcome: Sendable {
    case success
    case missing
    case transient
}

/// Playlist transport that serves old and new playlist ids and answers track POSTs from a scripted
/// `TrackPostOutcome` list, recording every GET/POST path.
actor PlaylistRecoveryTransport {
    private let oldID: String
    private let newID: String
    private let oldData: Data
    private let newData: Data
    private var outcomes: [TrackPostOutcome]
    private var getPaths: [String] = []
    private var postPaths: [String] = []

    init(
        oldID: String,
        newID: String,
        oldData: Data,
        newData: Data,
        outcomes: [TrackPostOutcome]
    ) {
        self.oldID = oldID
        self.newID = newID
        self.oldData = oldData
        self.newData = newData
        self.outcomes = outcomes
    }

    func get(_ path: String) throws -> Data? {
        getPaths.append(path)
        switch path {
        case "/me/library/playlists/\(oldID)":
            return oldData
        case "/me/library/playlists?limit=100":
            return newData
        default:
            throw AppleMusicLibraryTestError.unexpectedPath(path)
        }
    }

    func post(_ path: String, body _: Data) throws -> Data {
        postPaths.append(path)
        guard path == "/me/library/playlists/\(oldID)/tracks"
            || path == "/me/library/playlists/\(newID)/tracks",
            !outcomes.isEmpty
        else {
            throw AppleMusicLibraryTestError.unexpectedPath(path)
        }
        switch outcomes.removeFirst() {
        case .success:
            return Data()
        case .missing:
            throw AppleMusicLibraryError.playlistMissing
        case .transient:
            throw AppleMusicLibraryTestError.transient
        }
    }

    func calls() -> (get: [String], post: [String]) {
        (getPaths, postPaths)
    }
}

/// Like `PlaylistRecoveryTransport`, but the recovery lookup parks until released so concurrent
/// recoveries can be observed sharing it.
actor ConcurrentPlaylistRecoveryTransport {
    private let oldID: String
    private let newID: String
    private let oldData: Data
    private let newData: Data
    private var oldTrackPosts = 0
    private var newTrackPosts = 0
    private var recoveryGets = 0
    private var firstOldPostWaiter: CheckedContinuation<Void, Never>?
    private var recoveryStarted = false
    private var recoveryReleased = false
    private var recoveryStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var recoveryReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(oldID: String, newID: String, oldData: Data, newData: Data) {
        self.oldID = oldID
        self.newID = newID
        self.oldData = oldData
        self.newData = newData
    }

    func get(_ path: String) async throws -> Data? {
        switch path {
        case "/me/library/playlists/\(oldID)":
            return oldData
        case "/me/library/playlists?limit=100":
            recoveryGets += 1
            recoveryStarted = true
            let waiters = recoveryStartWaiters
            recoveryStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if !recoveryReleased {
                await withCheckedContinuation { continuation in
                    recoveryReleaseWaiters.append(continuation)
                }
            }
            return newData
        default:
            throw AppleMusicLibraryTestError.unexpectedPath(path)
        }
    }

    func post(_ path: String, body _: Data) async throws -> Data {
        switch path {
        case "/me/library/playlists/\(oldID)/tracks":
            oldTrackPosts += 1
            if oldTrackPosts == 1 {
                await withCheckedContinuation { continuation in
                    firstOldPostWaiter = continuation
                }
            } else {
                firstOldPostWaiter?.resume()
                firstOldPostWaiter = nil
            }
            throw AppleMusicLibraryError.playlistMissing
        case "/me/library/playlists/\(newID)/tracks":
            newTrackPosts += 1
            return Data()
        default:
            throw AppleMusicLibraryTestError.unexpectedPath(path)
        }
    }

    func waitUntilRecoveryLookupStarted() async {
        guard !recoveryStarted else { return }
        await withCheckedContinuation { continuation in
            recoveryStartWaiters.append(continuation)
        }
    }

    func releaseRecoveryLookup() {
        recoveryReleased = true
        let waiters = recoveryReleaseWaiters
        recoveryReleaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func recoveryLookupCount() -> Int {
        recoveryGets
    }

    func callCounts() -> (
        oldTrackPosts: Int,
        recoveryGets: Int,
        newTrackPosts: Int
    ) {
        (oldTrackPosts, recoveryGets, newTrackPosts)
    }
}

/// Playlist transport that answers the listing with paged results (`next` links) and counts GETs
/// and POSTs.
actor PagingPlaylistTransport {
    private let responses: [String: Data]

    private var getCalls = 0
    private var postCalls = 0

    init(responses: [String: Data]) {
        self.responses = responses
    }

    func get(_ path: String) throws -> Data? {
        getCalls += 1
        guard let response = responses[path] else {
            throw AppleMusicLibraryTestError.unexpectedPath(path)
        }
        return response
    }

    func post(_ path: String, body _: Data) throws -> Data {
        guard path == "/me/library/playlists" else {
            throw AppleMusicLibraryTestError.unexpectedPath(path)
        }
        postCalls += 1
        return Data("{\"data\":[{\"id\":\"p.created\",\"type\":\"library-playlists\"}]}".utf8)
    }

    func callCounts() -> (get: Int, post: Int) {
        (getCalls, postCalls)
    }
}
