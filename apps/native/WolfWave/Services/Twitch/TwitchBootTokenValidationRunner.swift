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
nonisolated enum TwitchBootTokenValidationRunner {
    /// A token tied to the credential-store account revision that owns it.
    struct Credential: Sendable, Equatable {
        let token: String
        let revision: UInt64

        var accessExpectation: TwitchCredentialStore.AccessExpectation {
            TwitchCredentialStore.AccessExpectation(
                revision: revision,
                accessToken: token
            )
        }
    }

    enum Outcome: Sendable, Equatable {
        case valid(String)
        case invalid(String)
        /// Twitch honors the token; it just lacks these scopes. The session is
        /// live, so this must never expire credentials or stop the schedule.
        case missingScopes(String, [String])
        case temporarilyUnavailable
        case superseded
        case cancelled
    }

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

    /// Runs validation immediately and then once per `validationInterval` for
    /// as long as the owning app task lives. A credential revision change is a
    /// new account lifecycle: stale work becomes inert and the first valid
    /// result for the replacement account is identified separately.
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
