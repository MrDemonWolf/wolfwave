//
//  TwitchCredentialStore.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

// MARK: - Credential Grant Store

/// Serializes whole OAuth-grant commits behind a monotonically increasing
/// account revision. A cancelled/superseded device flow can still receive a
/// network response, but it cannot persist either half of its credential pair.
///
/// Concurrency: `@unchecked Sendable` is backed by `lock`, which guards the
/// in-memory `revision` and is held across every Keychain read/write below, so
/// a revision check and the write it authorizes happen as one step. The
/// revision is process-local and starts at 0 on launch; it is never persisted.
/// Methods block on the lock and the Keychain, so call them off the main
/// thread where possible.
nonisolated final class TwitchCredentialStore: @unchecked Sendable {
    /// Exact access credential that owns an async operation. The revision
    /// distinguishes account lifecycles even if a provider ever reissues the
    /// same token string.
    struct AccessExpectation: Sendable, Equatable {
        let revision: UInt64
        let accessToken: String

        /// Same revision, new token. Used to check ownership of a refresh
        /// result, which rotates the token without advancing the revision.
        func replacingAccessToken(_ replacement: String) -> AccessExpectation {
            AccessExpectation(revision: revision, accessToken: replacement)
        }
    }

    /// One atomic connection snapshot. Identity is optional while a freshly
    /// committed device/manual grant is still waiting for its `/users` lookup.
    struct ConnectionSnapshot: Sendable, Equatable {
        let revision: UInt64
        let accessToken: String
        let username: String?
        let userID: String?
        /// The configured channel (a login name, despite the field name).
        let channelID: String?

        /// The ownership token async work carries across an `await`.
        var accessExpectation: AccessExpectation {
            AccessExpectation(revision: revision, accessToken: accessToken)
        }
    }

    /// The refresh token captured together with the access credential it
    /// belongs to, so a refresh can only be committed back onto that account.
    struct RefreshSnapshot: Sendable {
        let expectation: AccessExpectation
        let refreshToken: String
    }

    /// Result of `refreshSnapshot(matching:)`.
    enum RefreshSnapshotMatch: Sendable {
        /// The expectation still owns the record and it has a refresh token.
        case available(RefreshSnapshot)
        /// The expectation owns the record but there is no refresh token, so
        /// the only way forward is interactive re-auth.
        case missingRefreshToken
        /// The Keychain read threw. Treated as temporary, never as a logout.
        case unavailable
        /// The revision or access token changed since the expectation was taken.
        case superseded
    }

    /// Token plus resolved user ID, for work that needs both (Helix calls
    /// keyed on the broadcaster ID). Only produced once identity is resolved.
    struct AccessSnapshot: Sendable {
        let revision: UInt64
        let accessToken: String
        let userID: String

        /// The ownership token async work carries across an `await`.
        var accessExpectation: AccessExpectation {
            AccessExpectation(revision: revision, accessToken: accessToken)
        }
    }

    /// The process-wide store. Every credential writer must go through this
    /// instance; a second instance would have its own revision counter.
    static let shared = TwitchCredentialStore()

    /// Guards `revision` and serializes every Keychain access in this type.
    private let lock = NSLock()

    /// Account lifecycle counter. Advanced (wrapping) by `supersede()`,
    /// `clearCredentials`, and any channel change, which invalidates every
    /// `AccessExpectation` captured before it.
    private var revision: UInt64 = 0

    /// Invalidates every previously captured credential revision and returns
    /// the revision owned by the caller's new account operation. Call it when a
    /// sign-in starts so an older, still-polling device flow can no longer
    /// commit; pass the returned value to `commitDeviceGrant(_:channelID:expectedRevision:)`.
    /// Does not touch the Keychain.
    @discardableResult
    func supersede() -> UInt64 {
        lock.withLock {
            revision &+= 1
            return revision
        }
    }

    /// Captures the account revision only when `accessToken` is still the token
    /// stored for that account. This closes the old-token/new-revision TOCTOU.
    func revision(matchingAccessToken accessToken: String) -> UInt64? {
        connectionSnapshot(matchingAccessToken: accessToken)?.revision
    }

    /// Atomically captures token, revision, and optional identity. Passing an
    /// expected token makes a stale caller fail instead of adopting fields from
    /// a replacement account.
    ///
    /// - Parameter expectedAccessToken: When non-nil, the snapshot is returned
    ///   only if the stored token equals it.
    /// - Returns: `nil` when there is no non-empty access token, the token does
    ///   not match, or the Keychain read throws.
    func connectionSnapshot(
        matchingAccessToken expectedAccessToken: String? = nil
    ) -> ConnectionSnapshot? {
        lock.withLock {
            guard let grant = try? KeychainService.loadTwitchCredentialGrantChecked(),
                  let accessToken = grant.accessToken,
                  !accessToken.isEmpty,
                  expectedAccessToken == nil || accessToken == expectedAccessToken else {
                return nil
            }
            return ConnectionSnapshot(
                revision: revision,
                accessToken: accessToken,
                username: grant.username,
                userID: grant.userID,
                channelID: grant.channelID
            )
        }
    }

    /// Synchronous ownership check for results returning from an await.
    /// Returns `false` when the Keychain read throws, so an unreadable record
    /// is treated as "not ours" rather than authorizing a mutation.
    func matches(_ expectation: AccessExpectation) -> Bool {
        lock.withLock {
            guard let grant = try? KeychainService.loadTwitchCredentialGrantChecked() else {
                return false
            }
            return revision == expectation.revision
                && grant.accessToken == expectation.accessToken
        }
    }

    /// Captures the access token and resolved account identity under the same
    /// revision lock used by account replacement and logout. Returns `nil`
    /// until the `/users` lookup has stored a non-empty user ID.
    func accessSnapshot() -> AccessSnapshot? {
        lock.withLock {
            guard let grant = try? KeychainService.loadTwitchCredentialGrantChecked(),
                  let accessToken = grant.accessToken,
                  !accessToken.isEmpty,
                  let userID = grant.userID,
                  !userID.isEmpty else { return nil }
            return AccessSnapshot(
                revision: revision,
                accessToken: accessToken,
                userID: userID
            )
        }
    }

    /// Atomically validates ownership and persists a device-flow grant. Access,
    /// refresh, cleared identity, and the existing configured channel share one
    /// Keychain item, so replacement can never cross-pair account configuration.
    ///
    /// Does not advance the revision: the caller already did that with
    /// `supersede()` when the flow started.
    ///
    /// - Parameters:
    ///   - response: The token response from `pollForToken`.
    ///   - channelID: Channel name to store. `nil` keeps the current one.
    ///   - expectedRevision: The value `supersede()` returned for this flow.
    /// - Returns: `false` (nothing written) when the revision moved on or the
    ///   response has no refresh token.
    /// - Throws: Keychain write or validation errors.
    func commitDeviceGrant(
        _ response: TwitchTokenResponse,
        channelID: String? = nil,
        expectedRevision: UInt64
    ) throws -> Bool {
        try lock.withLock {
            guard revision == expectedRevision,
                  let refreshToken = response.refreshToken,
                  !refreshToken.isEmpty else { return false }
            // A new device grant may belong to a different Twitch account.
            // Identity stays nil until the revision-checked /users lookup.
            return try KeychainService.mutateTwitchCredentialGrant { current in
                current = .init(
                    accessToken: response.accessToken,
                    refreshToken: refreshToken,
                    channelID: channelID ?? current.channelID
                )
                return true
            }
        }
    }

    /// Captures the refresh token and account revision under the same lock used
    /// by clear/replace/commit operations. A stale expectation is distinguished
    /// from a current account that simply has no refresh grant, so callers never
    /// refresh or expire the replacement account in response to an old 401.
    func refreshSnapshot(
        matching expectation: AccessExpectation
    ) -> RefreshSnapshotMatch {
        lock.withLock {
            guard let grant = try? KeychainService.loadTwitchCredentialGrantChecked() else {
                return .unavailable
            }
            guard revision == expectation.revision,
                  grant.accessToken == expectation.accessToken else {
                return .superseded
            }
            guard let refreshToken = grant.refreshToken,
                  !refreshToken.isEmpty else { return .missingRefreshToken }
            return .available(
                RefreshSnapshot(
                    expectation: expectation,
                    refreshToken: refreshToken
                )
            )
        }
    }

    /// Commits a rotated refresh grant only if neither the account revision nor
    /// the exact source refresh token changed while the request was in flight.
    /// Identity and channel are kept, and the revision is not advanced, so
    /// in-flight work for the same account stays valid after a refresh.
    ///
    /// - Returns: `false` when ownership changed or the response has no
    ///   refresh token; nothing is written in that case.
    /// - Throws: Keychain write or validation errors.
    func commitRefreshGrant(
        _ response: TwitchTokenResponse,
        replacing sourceRefreshToken: String,
        expected expectation: AccessExpectation
    ) throws -> Bool {
        try lock.withLock {
            guard revision == expectation.revision,
                  let newRefreshToken = response.refreshToken,
                  !newRefreshToken.isEmpty else { return false }

            return try KeychainService.mutateTwitchCredentialGrant { current in
                guard current.accessToken == expectation.accessToken,
                      current.refreshToken == sourceRefreshToken else {
                    return false
                }
                current.accessToken = response.accessToken
                current.refreshToken = newRefreshToken
                return true
            }
        }
    }

    /// Changes only the configured channel and advances the account revision
    /// after the canonical write commits. In-flight connect/reconnect work tied
    /// to the old channel therefore fails its existing revision checks.
    /// Unconditional (no ownership check); a no-op write leaves the revision
    /// alone.
    func updateChannelID(_ channelID: String?) throws {
        try lock.withLock {
            let changed = try KeychainService.mutateTwitchCredentialGrant { grant in
                guard grant.channelID != channelID else { return false }
                grant.channelID = channelID
                return true
            }
            if changed {
                revision &+= 1
            }
        }
    }

    /// Commits a channel only if the validated access credential and account
    /// revision still own the canonical record. Returns the exact post-commit
    /// snapshot so the caller never reconnects from pre-commit fields.
    ///
    /// - Returns: The post-commit snapshot (carrying the new revision when the
    ///   channel actually changed), or `nil` when `expected` no longer owns the
    ///   record (revision, access token, or prior channel differ).
    /// - Throws: Keychain write or validation errors.
    func commitChannelID(
        _ channelID: String,
        expected: ConnectionSnapshot
    ) throws -> ConnectionSnapshot? {
        try lock.withLock {
            guard revision == expected.revision else { return nil }
            // The mutation returns `false` both for "not ours" and for "already
            // this channel"; `matched` tells the two apart so an unchanged
            // channel still yields a snapshot.
            var matched = false
            var committedGrant: KeychainService.TwitchCredentialGrant?
            let changed = try KeychainService.mutateTwitchCredentialGrant { grant in
                guard grant.accessToken == expected.accessToken,
                      grant.channelID == expected.channelID else {
                    return false
                }
                matched = true
                guard grant.channelID != channelID else {
                    committedGrant = grant
                    return false
                }
                grant.channelID = channelID
                committedGrant = grant
                return true
            }
            guard matched,
                  let committedGrant,
                  let accessToken = committedGrant.accessToken else { return nil }
            if changed {
                revision &+= 1
            }
            return ConnectionSnapshot(
                revision: revision,
                accessToken: accessToken,
                username: committedGrant.username,
                userID: committedGrant.userID,
                channelID: committedGrant.channelID
            )
        }
    }

    /// Clears Twitch account secrets while atomically invalidating every
    /// captured OAuth/refresh revision. The optional channel name is account
    /// configuration rather than a secret and is retained for re-auth flows.
    ///
    /// - Parameter includingChannel: `true` deletes the whole record (sign out
    ///   and forget the channel); `false` keeps only the channel name.
    /// - Throws: Keychain errors. The revision advances only after the write
    ///   succeeds, so a failed clear leaves existing expectations valid.
    func clearCredentials(includingChannel: Bool) throws {
        try lock.withLock {
            if includingChannel {
                // Legacy items are deleted before the authoritative v2 record,
                // so every failed clear keeps the complete account retryable.
                try KeychainService.deleteTwitchCredentialGrant()
            } else {
                // Preserve reauthentication UX without preserving any secret or
                // resolved identity: channel-only is one atomic replacement.
                try KeychainService.mutateTwitchCredentialGrant { current in
                    current = .init(channelID: current.channelID)
                    return true
                }
            }
            revision &+= 1
        }
    }

    /// Persists resolved account identity only while the same OAuth revision
    /// still owns the credential set. Does not advance the revision.
    ///
    /// - Returns: `false` when the revision moved on or the stored access token
    ///   is no longer `accessToken`; nothing is written in that case.
    /// - Throws: Keychain write or validation errors.
    func commitIdentity(
        username: String,
        userID: String,
        matchingAccessToken accessToken: String,
        expectedRevision: UInt64
    ) throws -> Bool {
        try lock.withLock {
            guard revision == expectedRevision else { return false }
            return try KeychainService.mutateTwitchCredentialGrant { grant in
                guard grant.accessToken == accessToken else { return false }
                grant.username = username
                grant.userID = userID
                return true
            }
        }
    }
}
