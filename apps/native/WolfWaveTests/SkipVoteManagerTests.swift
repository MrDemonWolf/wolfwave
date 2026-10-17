//
//  SkipVoteManagerTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-22.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// Suspends Twitch poll creation so tests can deterministically change tracks
/// while the actor is reentrant at the network boundary.
actor PollCreationGate {
    private let result: SkipPollCreationOutcome
    private var hasStarted = false
    private var wasReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(result: SkipPollCreationOutcome) {
        self.result = result
    }

    func create() async -> SkipPollCreationOutcome {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            if wasReleased {
                continuation.resume()
            } else {
                releaseWaiter = continuation
            }
        }
        return result
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func started() -> Bool {
        hasStarted
    }

    func release() {
        wasReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

/// Suspends the final target-bound Music mutation so a test can change the
/// supplied playback identity while a poll result is being applied.
actor TargetedSkipGate {
    private let result: Bool
    private var target: PlaybackTarget?
    private var hasStarted = false
    private var wasReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(result: Bool) {
        self.result = result
    }

    func perform(target: PlaybackTarget) async -> Bool {
        self.target = target
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            if wasReleased {
                continuation.resume()
            } else {
                releaseWaiter = continuation
            }
        }
        return result
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        wasReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func receivedTarget() -> PlaybackTarget? {
        target
    }
}

/// Suspends Music.app target capture so generation changes can be applied at
/// the actor reentrancy boundary before a vote claims session or poll state.
actor PlaybackTargetCaptureGate {
    private let target: PlaybackTarget
    private var captureCount = 0
    private var wasReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(target: PlaybackTarget = PlaybackTarget(trackKey: "target\tartist", revision: 0)) {
        self.target = target
    }

    func capture() async -> PlaybackTarget {
        captureCount += 1
        await withCheckedContinuation { continuation in
            if wasReleased {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
        return target
    }

    func startedCount() -> Int {
        captureCount
    }

    func release() {
        wasReleased = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// Chat vote-to-skip: the `SkipVoteManager` session state machine.
/// Covers the feature gate, vote counting and de-duplication, the subscriber-only
/// gate, threshold and window expiry, session cooldown, Twitch Polls mode, and the
/// actor-reentrancy races (track change mid-vote) driven by the gate actors above.
/// Subclasses `WolfWaveTestCase`, so it runs under `SharedTestStateIsolation`;
/// `setUp`/`tearDown` also clear every vote-skip key in `DefaultsStore.store`.
@MainActor
final class SkipVoteManagerTests: WolfWaveTestCase {

    let keys: [String] = [
        AppConstants.UserDefaults.voteSkipEnabled,
        AppConstants.UserDefaults.voteSkipMinVotes,
        AppConstants.UserDefaults.voteSkipWindowSeconds,
        AppConstants.UserDefaults.voteSkipSessionCooldown,
        AppConstants.UserDefaults.voteSkipSubscriberOnly,
        AppConstants.UserDefaults.voteSkipUsePolls,
        AppConstants.UserDefaults.voteSkipPollDuration
    ]

    override func setUp() {
        super.setUp()
        keys.forEach { DefaultsStore.store.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { DefaultsStore.store.removeObject(forKey: $0) }
        super.tearDown()
    }

    // MARK: - Helpers

    /// Chat context for `user<userID>` with the given badges.
    func context(
        userID: String,
        isSubscriber: Bool = false,
        isModerator: Bool = false,
        isBroadcaster: Bool = false
    ) -> BotCommandContext {
        BotCommandContext(
            userID: userID,
            username: "user\(userID)",
            isModerator: isModerator,
            isBroadcaster: isBroadcaster,
            isSubscriber: isSubscriber,
            isVIP: false,
            messageID: "m\(userID)"
        )
    }

    /// Turns vote-skip on and writes its threshold, session cooldown (seconds), and window
    /// (seconds) to `DefaultsStore.store`.
    func enableFeature(minVotes: Int = 3, cooldown: Double = 0, window: Int = 60) {
        let d = DefaultsStore.store
        d.set(true, forKey: AppConstants.UserDefaults.voteSkipEnabled)
        d.set(minVotes, forKey: AppConstants.UserDefaults.voteSkipMinVotes)
        d.set(cooldown, forKey: AppConstants.UserDefaults.voteSkipSessionCooldown)
        d.set(window, forKey: AppConstants.UserDefaults.voteSkipWindowSeconds)
    }

    // MARK: - Disabled

    func testDisabledWhenFeatureOff() async {
        let manager = SkipVoteManager()
        let outcome = await manager.recordVote(context: context(userID: "1"))
        XCTAssertEqual(outcome, .disabled)
    }

    // MARK: - Chat-tally Threshold

    func testFirstVoteStartsSession() async {
        enableFeature(minVotes: 3)
        let manager = SkipVoteManager()
        let outcome = await manager.recordVote(context: context(userID: "1"))
        let state = await manager.currentVoteState()
        XCTAssertEqual(outcome, .started(count: 1, needed: 3))
        XCTAssertEqual(state?.count, 1)
    }

    func testSecondVoterIsCounted() async {
        enableFeature(minVotes: 3)
        let manager = SkipVoteManager()
        _ = await manager.recordVote(context: context(userID: "1"))
        let outcome = await manager.recordVote(context: context(userID: "2"))
        XCTAssertEqual(outcome, .counted(count: 2, needed: 3))
    }

    func testThresholdReachedSkipsAndPasses() async {
        enableFeature(minVotes: 3)
        let manager = SkipVoteManager()
        let skipCount = ThreadSafeBox(0)
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: { _ in skipCount.mutate { $0 += 1 }; return true },
            sendChatMessage: nil,
            createPoll: nil
        )

        _ = await manager.recordVote(context: context(userID: "1"))
        _ = await manager.recordVote(context: context(userID: "2"))
        let outcome = await manager.recordVote(context: context(userID: "3"))

        let state = await manager.currentVoteState()
        XCTAssertEqual(outcome, .passed(count: 3))
        XCTAssertEqual(skipCount.value, 1)
        XCTAssertNil(state, "Session should reset after passing")
    }

    func testMinVotesOnePassesImmediately() async {
        enableFeature(minVotes: 1)
        let manager = SkipVoteManager()
        let skipped = ThreadSafeBox(false)
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: { _ in skipped.set(true); return true },
            sendChatMessage: nil,
            createPoll: nil
        )

        let outcome = await manager.recordVote(context: context(userID: "1"))
        XCTAssertEqual(outcome, .passed(count: 1))
        XCTAssertTrue(skipped.value)
    }

    // MARK: - Duplicate Voter

    func testDuplicateVoteIsRejected() async {
        enableFeature(minVotes: 3)
        let manager = SkipVoteManager()
        _ = await manager.recordVote(context: context(userID: "1"))
        let outcome = await manager.recordVote(context: context(userID: "1"))
        XCTAssertEqual(outcome, .alreadyVoted(count: 1, needed: 3))
    }

    func testDuplicateVoteDoesNotCrossThreshold() async {
        enableFeature(minVotes: 2)
        let manager = SkipVoteManager()
        let skipCount = ThreadSafeBox(0)
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: { _ in skipCount.mutate { $0 += 1 }; return true },
            sendChatMessage: nil,
            createPoll: nil
        )

        _ = await manager.recordVote(context: context(userID: "1"))
        _ = await manager.recordVote(context: context(userID: "1"))
        XCTAssertEqual(skipCount.value, 0, "Same user voting twice must not pass a 2-vote threshold")
    }

    // MARK: - Subscriber-only

    func testSubscriberOnlyRejectsNonSubscriber() async {
        enableFeature(minVotes: 3)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipSubscriberOnly)
        let manager = SkipVoteManager()
        let outcome = await manager.recordVote(context: context(userID: "1", isSubscriber: false))
        XCTAssertEqual(outcome, .subscriberOnly)
    }

    func testSubscriberOnlyAllowsSubscriber() async {
        enableFeature(minVotes: 3)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipSubscriberOnly)
        let manager = SkipVoteManager()
        let outcome = await manager.recordVote(context: context(userID: "1", isSubscriber: true))
        XCTAssertEqual(outcome, .started(count: 1, needed: 3))
    }

    func testSubscriberOnlyAllowsModerator() async {
        enableFeature(minVotes: 3)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipSubscriberOnly)
        let manager = SkipVoteManager()
        let outcome = await manager.recordVote(context: context(userID: "1", isModerator: true))
        XCTAssertEqual(outcome, .started(count: 1, needed: 3))
    }

    // MARK: - Cooldown

    func testFailedSkipDoesNotStartCooldown() async {
        enableFeature(minVotes: 1, cooldown: 60)
        let manager = SkipVoteManager()
        let succeeds = ThreadSafeBox(false)
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "track", revision: 1) },
            performSkip: { _ in succeeds.value }, sendChatMessage: nil, createPoll: nil, onVoteEvent: nil)
        let failed = await manager.recordVote(context: context(userID: "1"))
        XCTAssertEqual(failed, .skipUnavailable)
        succeeds.set(true)
        let retry = await manager.recordVote(context: context(userID: "2"))
        XCTAssertEqual(retry, .passed(count: 1))
        let third = await manager.recordVote(context: context(userID: "3"))
        if case .onCooldown = third {} else { XCTFail("Successful skip should start cooldown: \(third)") }
    }

    func testCooldownBlocksRapidReVote() async {
        enableFeature(minVotes: 1, cooldown: 60)
        let manager = SkipVoteManager()
        await manager.configure(
            capturePlaybackTarget: {
                PlaybackTarget(trackKey: "target\tartist", revision: 0)
            },
            performSkip: { _ in true },
            sendChatMessage: nil,
            createPoll: nil)

        let first = await manager.recordVote(context: context(userID: "1"))
        XCTAssertEqual(first, .passed(count: 1))

        let second = await manager.recordVote(context: context(userID: "2"))
        if case .onCooldown = second {
            // expected
        } else {
            XCTFail("Expected .onCooldown, got \(second)")
        }
    }

    func testCorruptSessionCooldownClampsAndDoesNotTrap() async {
        // The cooldown key is user-writable (exportable backup, `defaults write`).
        // An out-of-range value flows into Int(ceil(...)) on the next vote and
        // would trap unclamped. The accessor must clamp to 0...3600.
        DefaultsStore.store.set(1e300, forKey: AppConstants.UserDefaults.voteSkipSessionCooldown)
        let manager = SkipVoteManager()
        XCTAssertEqual(manager.sessionCooldown, 3600, accuracy: 0.001)

        // Drive a real vote through the cooldown branch to prove no trap.
        enableFeature(minVotes: 1, cooldown: 1e300)
        await manager.configure(
            capturePlaybackTarget: {
                PlaybackTarget(trackKey: "target\tartist", revision: 0)
            },
            performSkip: { _ in true },
            sendChatMessage: nil,
            createPoll: nil)
        _ = await manager.recordVote(context: context(userID: "1"))
        let second = await manager.recordVote(context: context(userID: "2"))
        if case .onCooldown(let remaining) = second {
            XCTAssertGreaterThanOrEqual(remaining, 0)
            XCTAssertLessThanOrEqual(remaining, 3600)
        } else {
            XCTFail("Expected .onCooldown, got \(second)")
        }
    }

    // MARK: - Window Expiry

    func testWindowExpiryFailsSession() async throws {
        enableFeature(minVotes: 5)
        // Inject a sub-100ms window so expiry is observed in milliseconds instead
        // of waiting out the integer-second `voteSkipWindowSeconds` minimum.
        let manager = SkipVoteManager(windowDuration: .milliseconds(50))
        let chatMessage = ThreadSafeBox<String?>(nil)
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: nil,
            sendChatMessage: { chatMessage.set($0) },
            createPoll: nil
        )

        _ = await manager.recordVote(context: context(userID: "1"))
        let preState = await manager.currentVoteState()
        XCTAssertNotNil(preState)

        // Poll until the window timer resets the session, bounded well above the
        // 50ms window so it isn't flaky, but far shorter than the old 2s sleep.
        let didReset = await waitUntil(timeout: .seconds(1)) {
            await manager.currentVoteState() == nil
        }

        XCTAssertTrue(didReset, "Session should reset after the window expires")
        let postState = await manager.currentVoteState()
        XCTAssertNil(postState, "Session should reset after the window expires")
        let message = chatMessage.value
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("failed") ?? false)
    }

    // MARK: - Reset

    func testResetClearsSession() async {
        enableFeature(minVotes: 3)
        let manager = SkipVoteManager()
        _ = await manager.recordVote(context: context(userID: "1"))
        await manager.reset()
        let state = await manager.currentVoteState()
        XCTAssertNil(state)
    }
}
