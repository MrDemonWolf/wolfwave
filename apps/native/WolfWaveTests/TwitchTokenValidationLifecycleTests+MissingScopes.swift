//
//  TwitchTokenValidationLifecycleTests+MissingScopes.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// Missing-scope handling: a scope gap is reported without spending a refresh or touching the Keychain.
extension TwitchTokenValidationLifecycleTests {
    // MARK: - Missing Scopes

    /// A scope gap is not an expired session. Refreshing cannot add a scope, so
    /// the runner must report it without spending a refresh or touching the
    /// credential.
    func testMissingScopesReportsWithoutRefreshing() async {
        let refreshCount = ThreadSafeBox(0)

        let outcome = await Runner.run(
            initialCredential: Runner.Credential(token: "token-a", revision: 1),
            validate: { _ in .missingScopes(["channel:manage:polls"]) },
            refresh: { _ in
                refreshCount.mutate { $0 += 1 }
                return .invalid
            },
            sleep: { _ in }
        )

        XCTAssertEqual(outcome, .missingScopes("token-a", ["channel:manage:polls"]))
        XCTAssertEqual(refreshCount.value, 0)
    }

    /// The bug this split exists to fix.
    ///
    /// A live token missing one optional scope used to return `.invalid`, which
    /// fired `onInvalid` (setting the re-auth flag, showing the "session has
    /// expired" notification) and returned from `runSchedule` outright. Because
    /// the re-auth flag also stops the validator, the still-good token was then
    /// never re-checked. It must instead keep the hourly cadence.
    func testMissingScopesKeepsTheHourlyScheduleRunning() async {
        let credential = ThreadSafeBox<Runner.Credential?>(
            Runner.Credential(token: "token-a", revision: 1)
        )
        let validatedTokens = ThreadSafeBox<[String]>([])
        let invalidCalls = ThreadSafeBox(0)
        let scopeReports = ThreadSafeBox<[[String]]>([])
        let sleeper = TokenValidationControlledSleeper()

        let task = Task {
            await Runner.runSchedule(
                credentials: { credential.value },
                validate: { token in
                    validatedTokens.mutate { $0.append(token) }
                    return .missingScopes(["bits:read"])
                },
                refresh: { _ in .invalid },
                cadenceSleep: { delay in await sleeper.sleep(for: delay) },
                onInvalid: { _ in invalidCalls.mutate { $0 += 1 } },
                onMissingScopes: { _, scopes in scopeReports.mutate { $0.append(scopes) } }
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

        // Releasing the cadence must produce a SECOND validation. Under the old
        // behavior the schedule had already returned and this never happens.
        await sleeper.resumeNext()
        let reachedSecondCadence = await waitUntil { await sleeper.sleepCount >= 2 }
        XCTAssertTrue(reachedSecondCadence, "A scope gap must not stop hourly validation")

        task.cancel()
        await sleeper.releaseAll()
        _ = await task.value

        XCTAssertEqual(validatedTokens.value, ["token-a", "token-a"])
        XCTAssertEqual(invalidCalls.value, 0, "A live token must never report as invalid")
        XCTAssertEqual(scopeReports.value, [["bits:read"], ["bits:read"]])
    }

    /// Granting the scope clears the condition without any reconnect.
    func testRegainingScopeResumesNormalValidation() async {
        let credential = ThreadSafeBox<Runner.Credential?>(
            Runner.Credential(token: "token-a", revision: 1)
        )
        let scopeGranted = ThreadSafeBox(false)
        let accepted = ThreadSafeBox<[String]>([])
        let scopeReports = ThreadSafeBox(0)
        let sleeper = TokenValidationControlledSleeper()

        let task = Task {
            await Runner.runSchedule(
                credentials: { credential.value },
                validate: { _ in
                    scopeGranted.value ? .valid : .missingScopes(["bits:read"])
                },
                refresh: { _ in .invalid },
                cadenceSleep: { delay in await sleeper.sleep(for: delay) },
                onValid: { current, _, _ in accepted.mutate { $0.append(current.token) } },
                onMissingScopes: { _, _ in scopeReports.mutate { $0 += 1 } }
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

        scopeGranted.set(true)
        await sleeper.resumeNext()
        let reachedSecondCadence = await waitUntil { await sleeper.sleepCount >= 2 }
        XCTAssertTrue(reachedSecondCadence)

        task.cancel()
        await sleeper.releaseAll()
        _ = await task.value

        XCTAssertEqual(scopeReports.value, 1)
        XCTAssertEqual(accepted.value, ["token-a"])
    }

    /// When the hourly check rejects the old token and a refresh rotates it within the same
    /// account revision, `onValid` receives the new token (not first-for-account) plus the token it
    /// rotated from.
    func testHourlyValidationPropagatesSameAccountTokenRotation() async {
        let credential = ThreadSafeBox<Runner.Credential?>(
            Runner.Credential(token: "token-a", revision: 7)
        )
        let shouldRejectOldToken = ThreadSafeBox(false)
        let validatedTokens = ThreadSafeBox<[String]>([])
        let refreshInputs = ThreadSafeBox<[String]>([])
        let accepted = ThreadSafeBox<[String]>([])
        let rotations = ThreadSafeBox<[String]>([])
        let sleeper = TokenValidationControlledSleeper()
        let task = Task {
            await Runner.runSchedule(
                credentials: { credential.value },
                validate: { token in
                    validatedTokens.mutate { $0.append(token) }
                    return token == "token-a" && shouldRejectOldToken.value
                        ? .invalid
                        : .valid
                },
                refresh: { rejected in
                    refreshInputs.mutate {
                        $0.append("\(rejected.token)@\(rejected.revision)")
                    }
                    credential.set(
                        Runner.Credential(token: "token-b", revision: rejected.revision)
                    )
                    return .refreshed("token-b")
                },
                cadenceSleep: { delay in await sleeper.sleep(for: delay) },
                onValid: { current, isFirstValidForAccount, rotatedFrom in
                    accepted.mutate {
                        $0.append("\(current.token):\(isFirstValidForAccount)")
                    }
                    if let rotatedFrom {
                        rotations.mutate {
                            $0.append("\(rotatedFrom.token)->\(current.token)")
                        }
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
        shouldRejectOldToken.set(true)
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

        XCTAssertEqual(validatedTokens.value, ["token-a", "token-a", "token-b"])
        XCTAssertEqual(refreshInputs.value, ["token-a@7"])
        XCTAssertEqual(accepted.value, ["token-a:true", "token-b:false"])
        XCTAssertEqual(rotations.value, ["token-a->token-b"])
    }
}
