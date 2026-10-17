//
//  TwitchTokenRefresher.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

// MARK: - Reactive Token Refresh

/// Coordinates one reactive OAuth token refresh from the live Twitch service.
///
/// On a 401, `TwitchChatService` (live connection) and the boot token
/// validation in `AppDelegate+Services` call `attemptReactiveRefresh` once per
/// failure (never in a loop). It reads the stored refresh token, exchanges it
/// for a fresh access token, persists both, and returns a typed outcome so
/// temporary outages never erase a valid local grant.
///
/// Concurrency: the actor single-flights refreshes. Concurrent callers for the
/// same `RefreshKey` join one task; a caller for a different key cancels the
/// old one first. Twitch refresh tokens rotate, so two parallel exchanges of
/// the same token would leave one caller holding a dead token.
actor TwitchTokenRefresher {

    /// The process-wide refresher. Single-flighting only works through it.
    static let shared = TwitchTokenRefresher()

    /// Outcome of one refresh attempt, already checked against the current
    /// account owner (see `normalized(_:for:)`).
    enum RefreshResult: Sendable, Equatable {
        /// Rotated grant committed; carries the new access token.
        case refreshed(String)
        /// Refresh token missing or rejected, or a non-retryable status:
        /// the caller should ask the user to sign in again.
        case invalid
        /// Keychain unreadable, retries exhausted, or the commit kept failing.
        /// The stored grant is left as is; try again later.
        case temporarilyUnavailable
        /// The access token or account revision changed before this result could
        /// authorize a refresh or any caller-side mutation.
        case superseded
    }

    /// Identifies one refresh: same app, same account lifecycle, same token
    /// pair. Two callers with equal keys share a single network exchange.
    private struct RefreshKey: Sendable, Equatable {
        let clientID: String
        let credentialRevision: UInt64
        let accessToken: String
        let sourceRefreshToken: String
    }

    /// The refresh currently running. `id` lets the starter clear only its
    /// own entry, never one a later caller installed.
    private struct InFlight: Sendable {
        let id: UUID
        let key: RefreshKey
        let task: Task<RefreshResult, Error>
    }

    /// At most one refresh runs at a time.
    private var inFlight: InFlight?

    /// A rotated grant Twitch already issued but the Keychain commit failed
    /// for. The old refresh token is likely spent server-side, so a retry for
    /// the same key re-commits this response instead of calling Twitch again.
    private struct PendingRotation: Sendable {
        let key: RefreshKey
        let response: TwitchTokenResponse
        let generation: UInt64
    }

    /// See `PendingRotation`. Cleared on a successful commit, a supersede, or
    /// `invalidate()`.
    private var pendingRotation: PendingRotation?

    /// Bumped by `invalidate()` and when a different key replaces an in-flight
    /// refresh. `persist` refuses to commit work started under an older value.
    private var refreshGeneration: UInt64 = 0

    /// Supersedes and cancels a refresh owned by a prior account session.
    static func invalidateSession() async {
        await shared.invalidate()
    }

    /// Advances the generation, cancels any in-flight refresh, and drops a
    /// held rotation so nothing from the old session can commit.
    private func invalidate() {
        refreshGeneration &+= 1
        inFlight?.task.cancel()
        inFlight = nil
        pendingRotation = nil
    }

    /// Attempts one credential-bound refresh. A stale expectation returns
    /// superseded before issuing network work. Production entry point; uses
    /// `URLSession.shared` and the default retry policy.
    ///
    /// - Parameters:
    ///   - clientID: Twitch app client ID. Empty yields `.invalid`.
    ///   - expected: The credential that was rejected with a 401.
    /// - Throws: `CancellationError` only when the calling task is cancelled.
    static func attemptReactiveRefresh(
        clientID: String,
        expected: TwitchCredentialStore.AccessExpectation
    ) async throws -> RefreshResult {
        try await shared.refresh(
            clientID: clientID,
            expected: expected,
            session: .shared
        )
    }

    /// Injectable convenience used by tests that begin from current storage.
    /// Takes the expectation from whatever is stored now; returns `.invalid`
    /// when there is no stored access token.
    ///
    /// - Parameters:
    ///   - maxTransientAttempts: Network attempts before `.temporarilyUnavailable` (min 1).
    ///   - sleep: Delay between attempts; tests pass a no-op.
    ///   - onJoinedExistingFlight: Called when this call joins an in-flight
    ///     refresh instead of starting one; lets tests prove single-flighting.
    static func attemptReactiveRefresh(
        clientID: String,
        session: URLSession,
        maxTransientAttempts: Int = 3,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        onJoinedExistingFlight: @escaping @Sendable () -> Void = {}
    ) async throws -> RefreshResult {
        guard let expected = TwitchCredentialStore.shared
            .connectionSnapshot()?.accessExpectation else {
            return .invalid
        }
        return try await attemptReactiveRefresh(
            clientID: clientID,
            expected: expected,
            session: session,
            maxTransientAttempts: maxTransientAttempts,
            sleep: sleep,
            onJoinedExistingFlight: onJoinedExistingFlight
        )
    }

    /// Injectable credential-bound variant used by race and single-flight tests.
    /// Parameters match the storage-based overload above.
    static func attemptReactiveRefresh(
        clientID: String,
        expected: TwitchCredentialStore.AccessExpectation,
        session: URLSession,
        maxTransientAttempts: Int = 3,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        onJoinedExistingFlight: @escaping @Sendable () -> Void = {}
    ) async throws -> RefreshResult {
        try await shared.refresh(
            clientID: clientID,
            expected: expected,
            session: session,
            maxTransientAttempts: maxTransientAttempts,
            sleep: sleep,
            onJoinedExistingFlight: onJoinedExistingFlight
        )
    }

    /// Single-flight core shared by every public entry point.
    ///
    /// 1. Re-reads the refresh token under the store lock; a stale `expected`
    ///    returns `.superseded` with no network call.
    /// 2. Joins an in-flight refresh with the same key, or cancels one with a
    ///    different key (bumping the generation) and recurses.
    /// 3. Otherwise starts a task that either re-commits a held
    ///    `PendingRotation` for this key or performs the network refresh.
    ///
    /// A cancelled refresh task maps to `.temporarilyUnavailable` (or
    /// `.superseded` if the account changed); `CancellationError` is thrown
    /// only when the caller's own task was cancelled.
    private func refresh(
        clientID: String,
        expected: TwitchCredentialStore.AccessExpectation,
        session: URLSession,
        maxTransientAttempts: Int = 3,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        onJoinedExistingFlight: @escaping @Sendable () -> Void = {}
    ) async throws -> RefreshResult {
        try Task.checkCancellation()
        let credentialSnapshot: TwitchCredentialStore.RefreshSnapshot
        switch TwitchCredentialStore.shared.refreshSnapshot(matching: expected) {
        case .available(let snapshot):
            credentialSnapshot = snapshot
        case .missingRefreshToken:
            Log.info(
                "TwitchTokenRefresher: No stored refresh token; cannot refresh",
                category: .twitchAuth)
            return .invalid
        case .unavailable:
            return .temporarilyUnavailable
        case .superseded:
            return .superseded
        }
        guard !clientID.isEmpty else { return .invalid }

        let sourceRefreshToken = credentialSnapshot.refreshToken
        let key = RefreshKey(
            clientID: clientID,
            credentialRevision: expected.revision,
            accessToken: expected.accessToken,
            sourceRefreshToken: sourceRefreshToken
        )

        if let existing = inFlight {
            if existing.key == key {
                onJoinedExistingFlight()
                do {
                    let result = try await existing.task.value
                    try Task.checkCancellation()
                    return normalized(result, for: expected)
                } catch is CancellationError {
                    if Task.isCancelled { throw CancellationError() }
                    return TwitchCredentialStore.shared.matches(expected)
                        ? .temporarilyUnavailable
                        : .superseded
                }
            }

            // The stored credentials changed while another account's refresh
            // was active. Supersede it before starting work for the new key;
            // its generation/CAS persistence guards make a late response inert.
            refreshGeneration &+= 1
            inFlight = nil
            existing.task.cancel()
            _ = try? await existing.task.value
            return try await refresh(
                clientID: clientID,
                expected: expected,
                session: session,
                maxTransientAttempts: maxTransientAttempts,
                sleep: sleep,
                onJoinedExistingFlight: onJoinedExistingFlight
            )
        }

        let generation = refreshGeneration
        let id = UUID()
        let held = pendingRotation
        let task = Task<RefreshResult, Error> {
            if let held, held.key == key, held.generation == generation {
                return try await self.persist(
                    held.response,
                    replacing: sourceRefreshToken,
                    expected: expected,
                    generation: generation,
                    clientID: clientID,
                    sleep: sleep)
            }
            return try await Self.performRefresh(
                clientID: clientID,
                sourceRefreshToken: sourceRefreshToken,
                expected: expected,
                session: session,
                maxTransientAttempts: maxTransientAttempts,
                sleep: sleep,
                generation: generation
            )
        }
        inFlight = InFlight(id: id, key: key, task: task)
        let result: RefreshResult
        do {
            result = try await task.value
        } catch is CancellationError {
            if inFlight?.id == id {
                inFlight = nil
            }
            if Task.isCancelled { throw CancellationError() }
            return TwitchCredentialStore.shared.matches(expected)
                ? .temporarilyUnavailable
                : .superseded
        } catch {
            if inFlight?.id == id {
                inFlight = nil
            }
            throw error
        }
        if inFlight?.id == id {
            inFlight = nil
        }
        try Task.checkCancellation()
        return normalized(result, for: expected)
    }

    /// Converts every late terminal result into superseded unless the exact
    /// account still owns it. Successful refreshes validate the rotated token;
    /// all other results validate the rejected token.
    private func normalized(
        _ result: RefreshResult,
        for expected: TwitchCredentialStore.AccessExpectation
    ) -> RefreshResult {
        switch result {
        case .refreshed(let replacement):
            return TwitchCredentialStore.shared.matches(
                expected.replacingAccessToken(replacement)
            ) ? result : .superseded
        case .invalid, .temporarilyUnavailable:
            return TwitchCredentialStore.shared.matches(expected)
                ? result
                : .superseded
        case .superseded:
            return .superseded
        }
    }

    /// Runs the network exchange with bounded retries, then hands a success to
    /// `persist`. Runs off the actor so the actor stays free for joiners.
    ///
    /// Retry policy: `invalidClient` and non-retryable HTTP statuses return
    /// `.invalid` at once. Malformed bodies, transport errors, and retryable
    /// statuses retry with exponential backoff (250 ms, 500 ms, ...), or the
    /// server's Retry-After when longer. Ownership is rechecked before every
    /// attempt and after every failure.
    private nonisolated static func performRefresh(
        clientID: String,
        sourceRefreshToken: String,
        expected: TwitchCredentialStore.AccessExpectation,
        session: URLSession,
        maxTransientAttempts: Int,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        generation: UInt64
    ) async throws -> RefreshResult {
        // Mirror the sign-in scope set so a refreshed token keeps the full grant
        // (chat + redemptions + bits + polls), never silently narrowing to chat.
        let auth = TwitchDeviceAuth(
            clientID: clientID,
            scopes: AppConstants.Twitch.allScopes,
            session: session
        )
        let attempts = max(1, maxTransientAttempts)
        for attempt in 1...attempts {
            try Task.checkCancellation()
            guard TwitchCredentialStore.shared.matches(expected) else {
                return .superseded
            }

            let retryDelay: Duration?
            do {
                let response = try await auth.refreshAccessToken(
                    refreshToken: sourceRefreshToken
                )
                return try await shared.persist(
                    response,
                    replacing: sourceRefreshToken,
                    expected: expected,
                    generation: generation,
                    clientID: clientID,
                    sleep: sleep
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch TwitchDeviceAuthError.invalidClient {
                return .invalid
            } catch TwitchDeviceAuthError.invalidResponse {
                retryDelay = nil
            } catch TwitchDeviceAuthError.http(let status, let retryAfter) {
                guard Self.isRetryableRefreshStatus(status) else { return .invalid }
                retryDelay = retryAfter
            } catch TwitchDeviceAuthError.transport(_) {
                retryDelay = nil
            } catch {
                retryDelay = nil
            }

            guard TwitchCredentialStore.shared.matches(expected) else {
                return .superseded
            }
            guard attempt < attempts else {
                Log.warn(
                    "TwitchTokenRefresher: Refresh temporarily unavailable after \(attempts) attempts",
                    category: .twitchAuth)
                return .temporarilyUnavailable
            }
            let fallback = Duration.milliseconds(250 * (1 << (attempt - 1)))
            let delay: Duration
            if let retryDelay, retryDelay > fallback {
                delay = retryDelay
            } else {
                delay = fallback
            }
            Log.warn(
                "TwitchTokenRefresher: Transient refresh failure; retrying (\(attempt)/\(attempts))",
                category: .twitchAuth)
            try await sleep(delay)
        }
        return .temporarilyUnavailable
    }

    /// Statuses worth retrying: request timeout, too early, rate limited, and
    /// any 5xx. Everything else (400/401 never reach here) means the grant
    /// will not succeed by waiting.
    nonisolated private static func isRetryableRefreshStatus(_ status: Int) -> Bool {
        status == 408 || status == 425 || status == 429 || (500..<600).contains(status)
    }

    /// Commits a rotated grant only while the initiating account session still
    /// owns both the actor generation and the exact source refresh token.
    ///
    /// The response is first held in `pendingRotation`, then the commit is
    /// tried up to three times (250 ms, 500 ms apart). If every write fails the
    /// rotation stays held and the result is `.temporarilyUnavailable`, so the
    /// next refresh for the same key re-commits it without spending another
    /// network exchange.
    private func persist(
        _ response: TwitchTokenResponse,
        replacing sourceRefreshToken: String,
        expected: TwitchCredentialStore.AccessExpectation,
        generation: UInt64,
        clientID: String,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) async throws -> RefreshResult {
        guard generation == refreshGeneration else {
            return .superseded
        }
        let key = RefreshKey(
            clientID: clientID, credentialRevision: expected.revision,
            accessToken: expected.accessToken, sourceRefreshToken: sourceRefreshToken)
        pendingRotation = PendingRotation(key: key, response: response, generation: generation)
        for attempt in 1...3 {
            try Task.checkCancellation()
            guard generation == refreshGeneration, TwitchCredentialStore.shared.matches(expected) else {
                if pendingRotation?.key == key, pendingRotation?.generation == generation {
                    pendingRotation = nil
                }
                return .superseded
            }
            do {
                let committed = try TwitchCredentialStore.shared.commitRefreshGrant(
                    response, replacing: sourceRefreshToken, expected: expected)
                if pendingRotation?.key == key, pendingRotation?.generation == generation {
                    pendingRotation = nil
                }
                return committed ? .refreshed(response.accessToken) : .superseded
            } catch {
                Log.warn("TwitchTokenRefresher: Rotated grant commit failed; retaining for retry",
                         category: .twitchAuth)
                if attempt < 3 { try await sleep(.milliseconds(250 * attempt)) }
            }
        }
        return .temporarilyUnavailable
    }
}
