//
//  TwitchTokenValidationLifecycleTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-08-12.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

// MARK: - Twitch Token Validation Lifecycle Tests

/// Deterministic coverage for the app-lifetime startup + hourly Twitch token
/// validation policy. Every suspension point is controlled by a continuation;
/// the suite performs no wall-clock sleeps and no live network requests.
@MainActor
final class TwitchTokenValidationLifecycleTests: XCTestCase {
    typealias Runner = TwitchBootTokenValidationRunner

    func testScheduledCredentialReadsStayOffTheMainThread() async {
        let readOnMainThread = ThreadSafeBox<Bool?>(nil)
        await Runner.runSchedule(
            credentials: {
                readOnMainThread.mutate { $0 = Thread.isMainThread }
                return nil
            },
            validate: { _ in .temporarilyUnavailable },
            refresh: { _ in .invalid }
        )
        XCTAssertEqual(readOnMainThread.value, false)
    }

    func testTransientValidationRetriesAreBoundedWithExponentialDelays() async {
        let validationCount = ThreadSafeBox(0)
        let refreshCount = ThreadSafeBox(0)
        let delays = ThreadSafeBox<[Duration]>([])

        let outcome = await Runner.run(
            initialCredential: Runner.Credential(token: "token-a", revision: 1),
            validate: { _ in
                validationCount.mutate { $0 += 1 }
                return .temporarilyUnavailable
            },
            refresh: { _ in
                refreshCount.mutate { $0 += 1 }
                return .invalid
            },
            sleep: { delay in delays.mutate { $0.append(delay) } }
        )

        XCTAssertEqual(outcome, .temporarilyUnavailable)
        XCTAssertEqual(validationCount.value, 3)
        XCTAssertEqual(refreshCount.value, 0)
        XCTAssertEqual(delays.value, [.milliseconds(250), .milliseconds(500)])
    }

    /// An invalid token triggers exactly one refresh, and the refreshed token is validated
    /// again before `onValid` is called with it.
    func testInvalidTokenRefreshesOnceThenRevalidatesReplacement() async {
        let currentToken = ThreadSafeBox("token-a")
        let validatedTokens = ThreadSafeBox<[String]>([])
        let refreshCount = ThreadSafeBox(0)
        let acceptedTokens = ThreadSafeBox<[String]>([])

        let outcome = await Runner.run(
            initialCredential: Runner.Credential(token: "token-a", revision: 1),
            validate: { token in
                validatedTokens.mutate { $0.append(token) }
                return token == "token-a" ? .invalid : .valid
            },
            refresh: { _ in
                refreshCount.mutate { $0 += 1 }
                currentToken.set("token-b")
                return .refreshed("token-b")
            },
            isCurrent: { $0.token == currentToken.value },
            onValid: { credential in
                acceptedTokens.mutate { $0.append(credential.token) }
            }
        )

        XCTAssertEqual(outcome, .valid("token-b"))
        XCTAssertEqual(validatedTokens.value, ["token-a", "token-b"])
        XCTAssertEqual(refreshCount.value, 1)
        XCTAssertEqual(acceptedTokens.value, ["token-b"])
    }

    func testSecondInvalidResultStopsAfterSingleRefresh() async {
        let currentToken = ThreadSafeBox("token-a")
        let validatedTokens = ThreadSafeBox<[String]>([])
        let refreshCount = ThreadSafeBox(0)

        let outcome = await Runner.run(
            initialCredential: Runner.Credential(token: "token-a", revision: 1),
            validate: { token in
                validatedTokens.mutate { $0.append(token) }
                return .invalid
            },
            refresh: { _ in
                refreshCount.mutate { $0 += 1 }
                currentToken.set("token-b")
                return .refreshed("token-b")
            },
            isCurrent: { $0.token == currentToken.value }
        )

        XCTAssertEqual(outcome, .invalid("token-b"))
        XCTAssertEqual(validatedTokens.value, ["token-a", "token-b"])
        XCTAssertEqual(refreshCount.value, 1)
    }

    func testRefreshOutageKeepsCurrentCredentialTemporarilyUnavailable() async {
        let refreshCount = ThreadSafeBox(0)
        let acceptedTokens = ThreadSafeBox<[String]>([])

        let outcome = await Runner.run(
            initialCredential: Runner.Credential(token: "token-a", revision: 1),
            validate: { _ in .invalid },
            refresh: { _ in
                refreshCount.mutate { $0 += 1 }
                return .temporarilyUnavailable
            },
            onValid: { credential in
                acceptedTokens.mutate { $0.append(credential.token) }
            }
        )

        XCTAssertEqual(outcome, .temporarilyUnavailable)
        XCTAssertEqual(refreshCount.value, 1)
        XCTAssertTrue(acceptedTokens.value.isEmpty)
    }

    func testSupersededRefreshResultCannotValidateOrExpireCredential() async {
        let acceptedTokens = ThreadSafeBox<[String]>([])

        let outcome = await Runner.run(
            initialCredential: Runner.Credential(token: "token-a", revision: 1),
            validate: { _ in .invalid },
            refresh: { _ in .superseded },
            onValid: { credential in
                acceptedTokens.mutate { $0.append(credential.token) }
            }
        )

        XCTAssertEqual(outcome, .superseded)
        XCTAssertTrue(acceptedTokens.value.isEmpty)
    }

    /// Cancelling while `validate` is suspended yields `.cancelled` and never calls `onValid`, even
    /// though validation returned `.valid`.
    func testCancellationDuringValidateSuppressesValidCallback() async {
        let gate = TokenValidationSuspensionGate()
        let acceptedTokens = ThreadSafeBox<[String]>([])
        let task = Task {
            await Runner.run(
                initialCredential: Runner.Credential(token: "token-a", revision: 1),
                validate: { _ in
                    await gate.suspend()
                    return .valid
                },
                refresh: { _ in .invalid },
                onValid: { credential in
                    acceptedTokens.mutate { $0.append(credential.token) }
                }
            )
        }

        let didSuspend = await waitUntil { await gate.hasSuspended }
        XCTAssertTrue(didSuspend)
        guard didSuspend else {
            task.cancel()
            await gate.release()
            _ = await task.value
            return
        }
        task.cancel()
        await gate.release()
        let outcome = await task.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(acceptedTokens.value.isEmpty)
    }

    /// Cancelling during the retry backoff sleep stops the run after the first validation attempt.
    func testCancellationDuringRetrySleepStopsBeforeNextValidation() async {
        let gate = TokenValidationSuspensionGate()
        let validationCount = ThreadSafeBox(0)
        let task = Task {
            await Runner.run(
                initialCredential: Runner.Credential(token: "token-a", revision: 1),
                validate: { _ in
                    validationCount.mutate { $0 += 1 }
                    return .temporarilyUnavailable
                },
                refresh: { _ in .invalid },
                sleep: { _ in await gate.suspend() }
            )
        }

        let didSuspend = await waitUntil { await gate.hasSuspended }
        XCTAssertTrue(didSuspend)
        guard didSuspend else {
            task.cancel()
            await gate.release()
            _ = await task.value
            return
        }
        task.cancel()
        await gate.release()
        let outcome = await task.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(validationCount.value, 1)
    }

    /// Cancelling while `onValid` is suspended reports `.cancelled`, not success, and the
    /// callback records nothing.
    func testCancellationDuringOnValidCannotReportSuccess() async {
        let gate = TokenValidationSuspensionGate()
        let acceptedTokens = ThreadSafeBox<[String]>([])
        let task = Task {
            await Runner.run(
                initialCredential: Runner.Credential(token: "token-a", revision: 1),
                validate: { _ in .valid },
                refresh: { _ in .invalid },
                onValid: { credential in
                    await gate.suspend()
                    guard !Task.isCancelled else { return }
                    acceptedTokens.mutate { $0.append(credential.token) }
                }
            )
        }

        let didSuspend = await waitUntil { await gate.hasSuspended }
        XCTAssertTrue(didSuspend)
        guard didSuspend else {
            task.cancel()
            await gate.release()
            _ = await task.value
            return
        }
        task.cancel()
        await gate.release()
        let outcome = await task.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(acceptedTokens.value.isEmpty)
    }

    /// If the stored token changes while validation is suspended, the result is `.superseded` and
    /// `onValid` does not run for the stale token.
    func testOnValidRunsOnlyForStillCurrentToken() async {
        let gate = TokenValidationSuspensionGate()
        let currentToken = ThreadSafeBox("token-a")
        let acceptedTokens = ThreadSafeBox<[String]>([])
        let task = Task {
            await Runner.run(
                initialCredential: Runner.Credential(token: "token-a", revision: 1),
                validate: { _ in
                    await gate.suspend()
                    return .valid
                },
                refresh: { _ in .invalid },
                isCurrent: { $0.token == currentToken.value },
                onValid: { credential in
                    acceptedTokens.mutate { $0.append(credential.token) }
                }
            )
        }

        let didSuspend = await waitUntil { await gate.hasSuspended }
        XCTAssertTrue(didSuspend)
        guard didSuspend else {
            task.cancel()
            await gate.release()
            _ = await task.value
            return
        }
        currentToken.set("token-b")
        await gate.release()
        let outcome = await task.value

        XCTAssertEqual(outcome, .superseded)
        XCTAssertTrue(acceptedTokens.value.isEmpty)
    }

    /// The schedule validates immediately and then sleeps 3600 s between rounds. When the
    /// credential revision changes, the new account's first valid result is flagged as the first
    /// for that account.
    func testScheduleValidatesImmediatelyHourlyAndResetsForAccountRevision() async {
        let credential = ThreadSafeBox<Runner.Credential?>(
            Runner.Credential(token: "token-a", revision: 1)
        )
        let validatedTokens = ThreadSafeBox<[String]>([])
        let accepted = ThreadSafeBox<[String]>([])
        let sleeper = TokenValidationControlledSleeper()
        let task = Task {
            await Runner.runSchedule(
                credentials: { credential.value },
                validate: { token in
                    validatedTokens.mutate { $0.append(token) }
                    return .valid
                },
                refresh: { _ in .invalid },
                cadenceSleep: { delay in await sleeper.sleep(for: delay) },
                onValid: { current, isFirstValidForAccount, _ in
                    accepted.mutate {
                        $0.append("\(current.token):\(isFirstValidForAccount)")
                    }
                }
            )
        }

        let reachedFirstCadence = await waitUntil { await sleeper.sleepCount >= 1 }
        XCTAssertTrue(reachedFirstCadence)
        guard reachedFirstCadence else {
            task.cancel()
            await sleeper.releaseAll()
            _ = await task.value
            return
        }
        credential.set(Runner.Credential(token: "token-b", revision: 2))
        await sleeper.resumeNext()
        let reachedSecondCadence = await waitUntil { await sleeper.sleepCount >= 2 }
        XCTAssertTrue(reachedSecondCadence)
        guard reachedSecondCadence else {
            task.cancel()
            await sleeper.releaseAll()
            _ = await task.value
            return
        }
        task.cancel()
        await sleeper.resumeNext()
        _ = await task.value
        let delays = await sleeper.recordedDelays()

        XCTAssertEqual(validatedTokens.value, ["token-a", "token-b"])
        XCTAssertEqual(accepted.value, ["token-a:true", "token-b:true"])
        XCTAssertEqual(delays, [.seconds(3_600), .seconds(3_600)])
    }
}

// MARK: - Deterministic Suspension Helpers

/// One-shot continuation gate used to pause validation at a specific await.
actor TokenValidationSuspensionGate {
    private(set) var hasSuspended = false
    private var isReleased = false
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        hasSuspended = true
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            resumeWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        resumeWaiters.forEach { $0.resume() }
        resumeWaiters.removeAll()
    }
}

/// Multi-cycle virtual sleeper for the hourly scheduler. Tests explicitly
/// resume each cadence, so account switches and cancellation are race-free.
actor TokenValidationControlledSleeper {
    private(set) var sleepCount = 0
    private var delays: [Duration] = []
    private var passThrough = false
    private var sleepWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(for delay: Duration) async {
        delays.append(delay)
        sleepCount += 1
        guard !passThrough else { return }
        await withCheckedContinuation { continuation in
            sleepWaiters.append(continuation)
        }
    }

    func resumeNext() {
        guard !sleepWaiters.isEmpty else { return }
        let continuation = sleepWaiters.removeFirst()
        continuation.resume()
    }

    func releaseAll() {
        passThrough = true
        sleepWaiters.forEach { $0.resume() }
        sleepWaiters.removeAll()
    }

    func recordedDelays() -> [Duration] { delays }
}
