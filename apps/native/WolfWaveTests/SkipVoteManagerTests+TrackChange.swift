//
//  SkipVoteManagerTests+TrackChange.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// Track-change and reset races: a track change or toggle landing while a vote target or poll is still being captured.
extension SkipVoteManagerTests {
    // MARK: - Track Change

    func testTrackChangeClearsChatTallySession() async {
        enableFeature(minVotes: 3)
        let manager = SkipVoteManager()
        _ = await manager.recordVote(context: context(userID: "1"))
        _ = await manager.recordVote(context: context(userID: "2"))
        let before = await manager.currentVoteState()
        XCTAssertEqual(before?.count, 2)

        await manager.trackDidChange()

        let after = await manager.currentVoteState()
        XCTAssertNil(after, "Votes against the old song must not carry over to the new one")
    }

    func testTrackChangeDoesNotStartCooldown() async {
        // A long cooldown would block the next vote if trackDidChange (wrongly)
        // ended the session the way window expiry does.
        enableFeature(minVotes: 3, cooldown: 60)
        let manager = SkipVoteManager()
        _ = await manager.recordVote(context: context(userID: "1"))

        await manager.trackDidChange()

        let outcome = await manager.recordVote(context: context(userID: "2"))
        XCTAssertEqual(
            outcome,
            .started(count: 1, needed: 3),
            "A fresh vote must open immediately after a track change; no cooldown applies"
        )
    }

    func testTrackChangeWithoutSessionIsNoOp() async {
        enableFeature(minVotes: 3, cooldown: 60)
        let manager = SkipVoteManager()

        await manager.trackDidChange()

        let outcome = await manager.recordVote(context: context(userID: "1"))
        XCTAssertEqual(outcome, .started(count: 1, needed: 3))
    }

    func testTrackChangeLeavesActivePollAlone() async {
        enableFeature(minVotes: 3)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: nil,
            sendChatMessage: nil,
            createPoll: { _, _ in .created(id: "poll-1") }
        )
        _ = await manager.recordVote(context: context(userID: "1", isModerator: true))

        await manager.trackDidChange()

        let active = await manager.isPollInProgress()
        XCTAssertTrue(
            active,
            "trackDidChange only ends chat-tally sessions; a live Twitch poll still resolves via poll.end"
        )
    }

    /// The manager is reentrant while it awaits the playback-target capture. A track change
    /// landing in that gap must make the first vote fail with `.playbackUnavailable` and
    /// leave no chat session open for the new track.
    func testTrackChangeDuringChatTargetCaptureDoesNotOpenSession() async {
        enableFeature(minVotes: 3)
        let manager = SkipVoteManager()
        let gate = PlaybackTargetCaptureGate()
        await manager.configure(
            capturePlaybackTarget: { await gate.capture() },
            performSkip: nil,
            sendChatMessage: nil,
            createPoll: nil
        )

        let vote = Task {
            await manager.recordVote(context: self.context(userID: "capture-chat"))
        }
        let reachedCapture = await waitUntil(timeout: .seconds(1)) {
            await gate.startedCount() == 1
        }
        XCTAssertTrue(reachedCapture)
        await manager.trackDidChange()
        await gate.release()

        let outcome = await vote.value
        XCTAssertEqual(outcome, .playbackUnavailable)
        let state = await manager.currentVoteState()
        XCTAssertNil(state)
    }

    /// Same gap as above, but `reset()` lands during capture: the late vote must not reopen a
    /// session.
    func testResetDuringChatTargetCaptureDoesNotReopenSession() async {
        enableFeature(minVotes: 3)
        let manager = SkipVoteManager()
        let gate = PlaybackTargetCaptureGate()
        await manager.configure(
            capturePlaybackTarget: { await gate.capture() },
            performSkip: nil,
            sendChatMessage: nil,
            createPoll: nil
        )

        let vote = Task {
            await manager.recordVote(context: self.context(userID: "capture-reset"))
        }
        let reachedCapture = await waitUntil(timeout: .seconds(1)) {
            await gate.startedCount() == 1
        }
        XCTAssertTrue(reachedCapture)
        await manager.reset()
        await gate.release()

        let outcome = await vote.value
        XCTAssertEqual(outcome, .playbackUnavailable)
        let state = await manager.currentVoteState()
        XCTAssertNil(state)
    }

    /// Poll mode: a track change during target capture returns `.pollTrackChanged` and the
    /// Twitch poll is never created.
    func testTrackChangeDuringPollTargetCaptureDoesNotCreatePoll() async {
        enableFeature(minVotes: 3)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        let gate = PlaybackTargetCaptureGate()
        let createCalls = ThreadSafeBox(0)
        await manager.configure(
            capturePlaybackTarget: { await gate.capture() },
            performSkip: nil,
            sendChatMessage: nil,
            createPoll: { _, _ in
                createCalls.mutate { $0 += 1 }
                return .created(id: "must-not-open")
            }
        )

        let vote = Task {
            await manager.recordVote(
                context: self.context(userID: "capture-poll", isModerator: true))
        }
        let reachedCapture = await waitUntil(timeout: .seconds(1)) {
            await gate.startedCount() == 1
        }
        XCTAssertTrue(reachedCapture)
        await manager.trackDidChange()
        await gate.release()

        let outcome = await vote.value
        XCTAssertEqual(outcome, .pollTrackChanged)
        XCTAssertEqual(createCalls.value, 0)
        let active = await manager.isPollInProgress()
        XCTAssertFalse(active)
    }

    /// Poll mode: `reset()` during target capture returns `.pollRequestCancelled` and no poll is
    /// created.
    func testResetDuringPollTargetCaptureDoesNotCreatePoll() async {
        enableFeature(minVotes: 3)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        let gate = PlaybackTargetCaptureGate()
        let createCalls = ThreadSafeBox(0)
        await manager.configure(
            capturePlaybackTarget: { await gate.capture() },
            performSkip: nil,
            sendChatMessage: nil,
            createPoll: { _, _ in
                createCalls.mutate { $0 += 1 }
                return .created(id: "must-not-open")
            }
        )

        let vote = Task {
            await manager.recordVote(
                context: self.context(userID: "capture-reset-poll", isModerator: true))
        }
        let reachedCapture = await waitUntil(timeout: .seconds(1)) {
            await gate.startedCount() == 1
        }
        XCTAssertTrue(reachedCapture)
        await manager.reset()
        await gate.release()

        let outcome = await vote.value
        XCTAssertEqual(outcome, .pollRequestCancelled)
        XCTAssertEqual(createCalls.value, 0)
        let active = await manager.isPollInProgress()
        XCTAssertFalse(active)
    }

    /// Two moderators vote while both are parked in target capture. Only one creates a poll
    /// (`.pollStarted`); the other gets `.pollInProgress`, since Twitch allows one active poll.
    func testConcurrentModeratorVotesCreateOnlyOnePoll() async {
        enableFeature(minVotes: 3)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        let gate = PlaybackTargetCaptureGate()
        let createCalls = ThreadSafeBox(0)
        await manager.configure(
            capturePlaybackTarget: { await gate.capture() },
            performSkip: nil,
            sendChatMessage: nil,
            createPoll: { _, _ in
                createCalls.mutate { $0 += 1 }
                return .created(id: "single-poll")
            }
        )

        let first = Task {
            await manager.recordVote(
                context: self.context(userID: "mod-1", isModerator: true))
        }
        let second = Task {
            await manager.recordVote(
                context: self.context(userID: "mod-2", isModerator: true))
        }
        let bothReachedCapture = await waitUntil(timeout: .seconds(1)) {
            await gate.startedCount() == 2
        }
        XCTAssertTrue(bothReachedCapture)
        await gate.release()

        let outcomes = [await first.value, await second.value]
        XCTAssertEqual(outcomes.filter { $0 == .pollStarted }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .pollInProgress }.count, 1)
        XCTAssertEqual(createCalls.value, 1)
    }

    /// The mode setting is re-read after capture: switching to Polls mid-capture means the
    /// chat-tally vote started under the old mode is abandoned (`.playbackUnavailable`, no
    /// session).
    func testChatModeToggleDuringTargetCaptureDoesNotOpenTally() async {
        enableFeature(minVotes: 3)
        let manager = SkipVoteManager()
        let gate = PlaybackTargetCaptureGate()
        await manager.configure(
            capturePlaybackTarget: { await gate.capture() },
            performSkip: nil,
            sendChatMessage: nil,
            createPoll: nil
        )

        let vote = Task {
            await manager.recordVote(context: self.context(userID: "mode-chat"))
        }
        let reachedCapture = await waitUntil(timeout: .seconds(1)) {
            await gate.startedCount() == 1
        }
        XCTAssertTrue(reachedCapture)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        await gate.release()

        let outcome = await vote.value
        XCTAssertEqual(outcome, .playbackUnavailable)
        let state = await manager.currentVoteState()
        XCTAssertNil(state)
    }

    /// Mirror of the chat toggle test: turning Polls mode off mid-capture cancels the poll request.
    func testPollModeToggleDuringTargetCaptureDoesNotCreatePoll() async {
        enableFeature(minVotes: 3)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        let gate = PlaybackTargetCaptureGate()
        let createCalls = ThreadSafeBox(0)
        await manager.configure(
            capturePlaybackTarget: { await gate.capture() },
            performSkip: nil,
            sendChatMessage: nil,
            createPoll: { _, _ in
                createCalls.mutate { $0 += 1 }
                return .created(id: "must-not-open")
            }
        )

        let vote = Task {
            await manager.recordVote(
                context: self.context(userID: "mode-poll", isModerator: true))
        }
        let reachedCapture = await waitUntil(timeout: .seconds(1)) {
            await gate.startedCount() == 1
        }
        XCTAssertTrue(reachedCapture)
        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        await gate.release()

        let outcome = await vote.value
        XCTAssertEqual(outcome, .pollRequestCancelled)
        XCTAssertEqual(createCalls.value, 0)
        let active = await manager.isPollInProgress()
        XCTAssertFalse(active)
    }

    /// Once a poll exists on Twitch it stays latched: turning Polls mode off afterwards does
    /// not let a chat tally start beside it (the next vote is `.pollInProgress`).
    func testActivePollBlocksChatTallyAfterPollModeIsDisabled() async {
        enableFeature(minVotes: 3)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        let createCalls = ThreadSafeBox(0)
        await manager.configure(
            capturePlaybackTarget: {
                PlaybackTarget(trackKey: "target\tartist", revision: 0)
            },
            performSkip: nil,
            sendChatMessage: nil,
            createPoll: { _, _ in
                createCalls.mutate { $0 += 1 }
                return .created(id: "latched")
            }
        )
        _ = await manager.recordVote(
            context: context(userID: "starter", isModerator: true))
        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.voteSkipUsePolls)

        let outcome = await manager.recordVote(context: context(userID: "viewer"))

        XCTAssertEqual(outcome, .pollInProgress)
        XCTAssertEqual(createCalls.value, 1)
        let chatState = await manager.currentVoteState()
        XCTAssertNil(chatState)
    }

    /// A poll that ends after vote-skip was switched off is drained but must not skip the track,
    /// even with a winning tally.
    func testPollEndDrainsWithoutSkippingAfterFeatureIsDisabled() async {
        enableFeature(minVotes: 1)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        let skipped = ThreadSafeBox(false)
        await manager.configure(
            capturePlaybackTarget: {
                PlaybackTarget(trackKey: "target\tartist", revision: 0)
            },
            performSkip: { _ in
                skipped.set(true)
                return true
            },
            sendChatMessage: nil,
            createPoll: { _, _ in .created(id: "disabled-result") }
        )
        _ = await manager.recordVote(
            context: context(userID: "starter", isModerator: true))
        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.voteSkipEnabled)

        await manager.handlePollEnded(
            pollID: "disabled-result", skipVotes: 10, keepVotes: 0)

        XCTAssertFalse(skipped.value)
        let active = await manager.isPollInProgress()
        XCTAssertFalse(active)
    }

    /// Disabling the feature during target capture yields `.disabled` and no open session.
    func testFeatureDisableDuringChatTargetCaptureDoesNotOpenTally() async {
        enableFeature(minVotes: 3)
        let manager = SkipVoteManager()
        let gate = PlaybackTargetCaptureGate()
        await manager.configure(
            capturePlaybackTarget: { await gate.capture() },
            performSkip: nil,
            sendChatMessage: nil,
            createPoll: nil
        )

        let vote = Task {
            await manager.recordVote(context: self.context(userID: "disable-chat"))
        }
        let reachedCapture = await waitUntil(timeout: .seconds(1)) {
            await gate.startedCount() == 1
        }
        XCTAssertTrue(reachedCapture)
        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.voteSkipEnabled)
        await gate.release()

        let outcome = await vote.value
        XCTAssertEqual(outcome, .disabled)
        let state = await manager.currentVoteState()
        XCTAssertNil(state)
    }

    /// Disabling the feature during target capture yields `.disabled` and creates no poll.
    func testFeatureDisableDuringPollTargetCaptureDoesNotCreatePoll() async {
        enableFeature(minVotes: 3)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        let gate = PlaybackTargetCaptureGate()
        let createCalls = ThreadSafeBox(0)
        await manager.configure(
            capturePlaybackTarget: { await gate.capture() },
            performSkip: nil,
            sendChatMessage: nil,
            createPoll: { _, _ in
                createCalls.mutate { $0 += 1 }
                return .created(id: "must-not-open")
            }
        )

        let vote = Task {
            await manager.recordVote(
                context: self.context(userID: "disable-poll", isModerator: true))
        }
        let reachedCapture = await waitUntil(timeout: .seconds(1)) {
            await gate.startedCount() == 1
        }
        XCTAssertTrue(reachedCapture)
        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.voteSkipEnabled)
        await gate.release()

        let outcome = await vote.value
        XCTAssertEqual(outcome, .disabled)
        XCTAssertEqual(createCalls.value, 0)
        let active = await manager.isPollInProgress()
        XCTAssertFalse(active)
    }
}
