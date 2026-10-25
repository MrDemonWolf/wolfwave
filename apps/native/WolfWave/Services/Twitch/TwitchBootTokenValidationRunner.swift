//
//  TwitchBootTokenValidationRunner.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-11.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

// MARK: - Twitch Token Validation

/// Bounded, dependency-injected app-lifetime validation policy. Validation
/// outages retry without expiring credentials; an invalid access token gets one
/// single-flight refresh before interactive re-auth is considered. The cadence
/// runner is the app's sole periodic owner, so opening Settings never creates a
/// second validation loop.
///
/// Every collaborator (validate, refresh, sleep, the credential read) is a
/// closure so tests drive the whole policy without network or real time.
/// `AppDelegate+Services` owns the production schedule.
nonisolated enum TwitchBootTokenValidationRunner {
    /// A token tied to the credential-store account revision that owns it.
    ///
    /// Equality covers both fields, so a refresh (same revision, new token)
    /// and an account switch (new revision) each read as "no longer current".
    struct Credential: Sendable, Equatable {
        let token: String
        let revision: UInt64

        /// Compare-and-swap guard for credential-store writes: the store only
        /// applies a change while this exact token and revision are still live.
        var accessExpectation: TwitchCredentialStore.AccessExpectation {
            TwitchCredentialStore.AccessExpectation(
                revision: revision,
                accessToken: token
            )
        }
    }

    /// How one ``run(initialCredential:maxValidationAttempts:validate:refresh:isCurrent:sleep:onValid:)``
    /// pass ended. Token payloads are the token the outcome applies to, which
    /// differs from the initial one when a refresh rotated it.
    enum Outcome: Sendable, Equatable {
        /// Twitch accepted this token (possibly a freshly refreshed one).
        case valid(String)
        /// Twitch rejected this token and the one allowed refresh did not
        /// produce a working replacement. Interactive re-auth territory.
        case invalid(String)
        /// Twitch honors the token; it just lacks these scopes. The session is
        /// live, so this must never expire credentials or stop the schedule.
        case missingScopes(String, [String])
        /// Validation (or the refresh) could not reach a verdict: network
        /// outage, 5xx, or retries exhausted. Credentials are left alone.
        case temporarilyUnavailable
        /// The credential changed underneath the run (refresh elsewhere,
        /// sign-out, account switch). Any result would be stale, so none is reported.
        case superseded
        /// The surrounding task was cancelled.
        case cancelled
    }

    // MARK: - Single Pass

    /// Validates one credential to a verdict.
    ///
    /// Policy: `.temporarilyUnavailable` from `validate` is retried with
    /// exponential backoff (250 ms, 500 ms, 1 s, ... capped at 2^10 x 250 ms)
    /// up to `maxValidationAttempts` total attempts. `.invalid` triggers at
    /// most one `refresh`; a refreshed token restarts the attempt budget, and a
    /// second `.invalid` after that refresh is final. `.missingScopes` returns
    /// immediately because a refresh can't add scopes.
    ///
    /// `isCurrent` is rechecked after every suspension point so a result for a
    /// credential that changed mid-flight is reported as `.superseded` instead
    /// of acting on stale state.
    ///
    /// - Parameters:
    ///   - initialCredential: The credential to validate.
    ///   - maxValidationAttempts: Total `validate` calls per token before
    ///     giving up as `.temporarilyUnavailable`. Clamped to at least 1.
    ///   - validate: Calls Twitch's validate endpoint for a token.
    ///   - refresh: Exchanges the refresh token for a new access token. A
    ///     thrown `CancellationError` maps to `.cancelled`; any other throw is
    ///     treated as an outage (`.temporarilyUnavailable`).
    ///   - isCurrent: Whether the credential is still the stored one.
    ///   - sleep: Backoff sleep; injected so tests don't wait. A throw ends the
    ///     run as `.cancelled`.
    ///   - onValid: Runs on the main actor before a `.valid` result is
    ///     returned. ``runSchedule(validationInterval:credentials:validate:refresh:retrySleep:cadenceSleep:onValid:onInvalid:onMissingScopes:onTemporarilyUnavailable:)``
    ///     does not use it; it reports through its own callbacks instead.
    /// - Returns: The verdict for the (possibly refreshed) credential.
    static func run(
        initialCredential: Credential,
        maxValidationAttempts: Int = 3,
        validate: @escaping @Sendable (String) async -> TwitchChatService.TokenValidationResult,
        refresh: @escaping @Sendable (Credential) async throws
            -> TwitchTokenRefresher.RefreshResult,
        isCurrent: @escaping @Sendable (Credential) -> Bool = { _ in true },
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        onValid: @escaping @MainActor @Sendable (Credential) async -> Void = { _ in }
    ) async -> Outcome {
        var credential = initialCredential
        var validationAttempt = 0
        var didAttemptRefresh = false
        let attemptLimit = max(1, maxValidationAttempts)

        while validationAttempt < attemptLimit {
            if Task.isCancelled { return .cancelled }
            guard isCurrent(credential) else { return .superseded }
            let validation = await validate(credential.token)
            if Task.isCancelled { return .cancelled }
            guard isCurrent(credential) else { return .superseded }

            switch validation {
            case .valid:
                await onValid(credential)
                if Task.isCancelled { return .cancelled }
                return isCurrent(credential)
                    ? .valid(credential.token)
                    : .superseded
            case .missingScopes(let scopes):
                // Refreshing cannot add a scope, and the token still works for
                // everything else. Report and stop, without touching the
                // credential.
                return isCurrent(credential)
                    ? .missingScopes(credential.token, scopes)
                    : .superseded
            case .invalid:
                guard !didAttemptRefresh else {
                    return .invalid(credential.token)
                }
                didAttemptRefresh = true
                do {
                    switch try await refresh(credential) {
                    case .refreshed(let replacement):
                        if Task.isCancelled { return .cancelled }
                        // The refresh keeps the account revision; only the
                        // token rotates. Validate the replacement from scratch.
                        credential = Credential(
                            token: replacement,
                            revision: credential.revision
                        )
                        guard isCurrent(credential) else { return .superseded }
                        validationAttempt = 0
                        continue
                    case .invalid:
                        if Task.isCancelled { return .cancelled }
                        return isCurrent(credential)
                            ? .invalid(credential.token)
                            : .superseded
                    case .temporarilyUnavailable:
                        if Task.isCancelled { return .cancelled }
                        return isCurrent(credential)
                            ? .temporarilyUnavailable
                            : .superseded
                    case .superseded:
                        return .superseded
                    }
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return isCurrent(credential)
                        ? .temporarilyUnavailable
                        : .superseded
                }
            case .temporarilyUnavailable:
                validationAttempt += 1
                guard validationAttempt < attemptLimit else {
                    return .temporarilyUnavailable
                }
                do {
                    // 250 ms doubling per retry; the shift is capped at 10 so
                    // a large attempt limit can't overflow.
                    let delay = Duration.milliseconds(
                        250 * (1 << min(validationAttempt - 1, 10))
                    )
                    try await sleep(delay)
                } catch {
                    return .cancelled
                }
                if Task.isCancelled { return .cancelled }
                guard isCurrent(credential) else { return .superseded }
            }
        }
        return .temporarilyUnavailable
    }

    // MARK: - App-Lifetime Schedule

    /// Runs validation immediately and then once per `validationInterval` for
    /// as long as the owning app task lives. A credential revision change is a
    /// new account lifecycle: stale work becomes inert and the first valid
    /// result for the replacement account is identified separately.
    ///
    /// The loop ends when `credentials()` returns `nil` (signed out), on an
    /// `.invalid` verdict (after `onInvalid`), or on cancellation. A
    /// superseded pass, or a callback that finds the credential changed,
    /// restarts immediately against the new credential without the cadence sleep.
    ///
    /// - Parameters:
    ///   - validationInterval: Gap between passes. Twitch asks apps to
    ///     validate hourly, hence the default.
    ///   - credentials: Reads the currently stored credential, or `nil` when
    ///     signed out. Runs on the concurrent executor, never the main actor.
    ///   - retrySleep: Backoff sleep inside a pass.
    ///   - cadenceSleep: Sleep between passes. A throw ends the schedule.
    ///   - onValid: `(credential, isFirstValidForRevision, rotatedFrom)`.
    ///     `isFirstValidForRevision` is true once per account revision, so the
    ///     caller can run one-time "account confirmed" work. `rotatedFrom` is
    ///     the pre-refresh credential when this pass refreshed the token.
    ///   - onInvalid: The token is dead and refresh failed. The schedule stops.
    ///   - onMissingScopes: The token works but lacks scopes. The schedule
    ///     keeps running.
    ///   - onTemporarilyUnavailable: No verdict this pass. The schedule keeps
    ///     running and tries again after the cadence sleep.
    @concurrent
    static func runSchedule(
        validationInterval: Duration = .seconds(3_600),
        credentials: @escaping @Sendable () -> Credential?,
        validate: @escaping @Sendable (String) async -> TwitchChatService.TokenValidationResult,
        refresh: @escaping @Sendable (Credential) async throws
            -> TwitchTokenRefresher.RefreshResult,
        retrySleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        cadenceSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        onValid: @escaping @MainActor @Sendable (
            Credential,
            Bool,
            Credential?
        ) async -> Void = { _, _, _ in },
        onInvalid: @escaping @MainActor @Sendable (Credential) async -> Void = { _ in },
        onMissingScopes: @escaping @MainActor @Sendable (Credential, [String]) async -> Void = { _, _ in },
        onTemporarilyUnavailable: @escaping @MainActor @Sendable (Credential) async -> Void = { _ in }
    ) async {
        // Revision that has already reported a valid (or missing-scopes)
        // verdict; drives `isFirstValidForRevision`.
        var validatedRevision: UInt64?

        while !Task.isCancelled {
            guard let credential = credentials() else { return }
            let outcome = await run(
                initialCredential: credential,
                validate: validate,
                refresh: refresh,
                isCurrent: { candidate in
                    credentials() == candidate
                },
                sleep: retrySleep
            )
            if Task.isCancelled { return }

            switch outcome {
            case .valid(let token):
                // Each branch re-reads the store before and after its callback:
                // a change during either await makes this verdict stale, so the
                // loop restarts against the new credential instead.
                let resolved = Credential(token: token, revision: credential.revision)
                guard credentials() == resolved else { continue }
                let isFirstValidForRevision = validatedRevision != resolved.revision
                let rotatedFrom = resolved.token == credential.token
                    ? nil
                    : credential
                await onValid(
                    resolved,
                    isFirstValidForRevision,
                    rotatedFrom
                )
                guard !Task.isCancelled else { return }
                guard credentials() == resolved else { continue }
                validatedRevision = resolved.revision
            case .invalid(let token):
                let resolved = Credential(token: token, revision: credential.revision)
                guard credentials() == resolved else { continue }
                await onInvalid(resolved)
                return
            case .missingScopes(let token, let scopes):
                let resolved = Credential(token: token, revision: credential.revision)
                guard credentials() == resolved else { continue }
                await onMissingScopes(resolved, scopes)
                guard !Task.isCancelled, credentials() == resolved else { continue }
                // Deliberately falls through to the cadence sleep rather than
                // returning: the token is live, so it keeps being re-checked
                // on the hourly schedule like any other working credential.
                validatedRevision = resolved.revision
            case .temporarilyUnavailable:
                guard credentials() == credential else { continue }
                await onTemporarilyUnavailable(credential)
                guard !Task.isCancelled, credentials() == credential else { continue }
            case .superseded:
                continue
            case .cancelled:
                return
            }

            do {
                try await cadenceSleep(validationInterval)
            } catch {
                return
            }
        }
    }
}
