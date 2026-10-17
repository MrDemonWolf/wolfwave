//
//  SkipVoteManagerTests+Polls.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// Twitch Polls mode: poll creation, outcomes, stale-poll rejection, and the poll timeout fallback.
extension SkipVoteManagerTests {
    // MARK: - Polls Mode

    func testPollsModeRejectsNonModerator() async {
        enableFeature(minVotes: 3)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        let outcome = await manager.recordVote(context: context(userID: "1"))
        XCTAssertEqual(outcome, .pollNotAllowed)
    }

    func testPollsModeStartsPollForModerator() async {
        enableFeature(minVotes: 3)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: nil,
            sendChatMessage: nil,
            createPoll: { _, _ in .created(id: "poll-1") }
        )
        let outcome = await manager.recordVote(context: context(userID: "1", isModerator: true))
        XCTAssertEqual(outcome, .pollStarted)
    }

    func testPollsModeDoesNotCallTwitchWithoutVerifiedPlaybackTarget() async {
        enableFeature(minVotes: 3)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        let createCalls = ThreadSafeBox(0)
        await manager.configure(
            capturePlaybackTarget: { nil },
            performSkip: nil,
            sendChatMessage: nil,
            createPoll: { _, _ in
                createCalls.mutate { $0 += 1 }
                return .created(id: "should-not-exist")
            })

        let outcome = await manager.recordVote(
            context: context(userID: "1", isModerator: true))

        XCTAssertEqual(outcome, .playbackUnavailable)
        XCTAssertEqual(createCalls.value, 0)
    }

    func testPollsModeFallsBackToChatTallyOnFailure() async {
        enableFeature(minVotes: 3)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        let chatMessages = ThreadSafeBox<[String]>([])
        let createCalls = ThreadSafeBox(0)
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: nil,
            sendChatMessage: { message in chatMessages.mutate { $0.append(message) } },
            createPoll: { _, _ in
                createCalls.mutate { $0 += 1 }
                return .definitiveFailure
            }
        )
        let outcome = await manager.recordVote(context: context(userID: "1", isBroadcaster: true))
        XCTAssertEqual(outcome, .started(count: 1, needed: 3), "Failed poll should fall back to a chat tally")
        let second = await manager.recordVote(context: context(userID: "2"))
        XCTAssertEqual(second, .counted(count: 2, needed: 3))
        XCTAssertEqual(createCalls.value, 1)
        XCTAssertEqual(
            chatMessages.value,
            ["📊 Twitch couldn't open a poll, counting chat votes instead."])
    }

    func testExistingNativePollLatchesWithoutOpeningChatFallback() async {
        enableFeature(minVotes: 3)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager(pollTimeoutDuration: .seconds(30))
        let chatMessages = ThreadSafeBox<[String]>([])
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: nil,
            sendChatMessage: { message in chatMessages.mutate { $0.append(message) } },
            createPoll: { _, _ in .pollAlreadyActive })

        let outcome = await manager.recordVote(
            context: context(userID: "1", isBroadcaster: true))
        let isPollActive = await manager.isPollInProgress()
        let chatState = await manager.currentVoteState()

        XCTAssertEqual(outcome, .pollInProgress)
        XCTAssertTrue(isPollActive)
        XCTAssertNil(chatState)
        XCTAssertTrue(chatMessages.value.isEmpty)
    }

    /// When poll creation's result is unknown (`.indeterminate`) the poll may exist on Twitch,
    /// so the manager latches as in-progress (blocks a chat fallback tally) until its timeout
    /// (shortened to 50 ms here) clears it; only then may another attempt create a poll.
    func testIndeterminatePollCreationLatchesUntilTimeoutAndBlocksFallback() async {
        enableFeature(minVotes: 3)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager(pollTimeoutDuration: .milliseconds(50))
        let createCalls = ThreadSafeBox(0)
        let chatMessages = ThreadSafeBox<[String]>([])
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: nil,
            sendChatMessage: { message in
                chatMessages.mutate { $0.append(message) }
            },
            createPoll: { _, _ in
                createCalls.mutate { $0 += 1 }
                return .indeterminate
            }
        )

        let outcome = await manager.recordVote(
            context: context(userID: "1", isModerator: true))
        XCTAssertEqual(outcome, .pollStatusUnknown)
        let active = await manager.isPollInProgress()
        let chatState = await manager.currentVoteState()
        XCTAssertTrue(active)
        XCTAssertNil(chatState)
        XCTAssertTrue(chatMessages.value.isEmpty)

        let blocked = await manager.recordVote(
            context: context(userID: "2", isModerator: true))
        XCTAssertEqual(blocked, .pollInProgress)
        XCTAssertEqual(createCalls.value, 1)
        let blockedChatState = await manager.currentVoteState()
        XCTAssertNil(blockedChatState)

        let timedOut = await waitUntil(timeout: .seconds(1)) {
            await manager.isPollInProgress() == false
        }
        XCTAssertTrue(timedOut)

        let afterTimeout = await manager.recordVote(
            context: context(userID: "3", isModerator: true))
        XCTAssertEqual(afterTimeout, .pollStatusUnknown)
        XCTAssertEqual(createCalls.value, 2)
    }

    func testPollEndedSkipsWhenSkipWins() async {
        enableFeature(minVotes: 3)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        let skipped = ThreadSafeBox(false)
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: { _ in skipped.set(true); return true },
            sendChatMessage: nil,
            createPoll: { _, _ in .created(id: "poll-1") }
        )
        _ = await manager.recordVote(context: context(userID: "1", isModerator: true))
        await manager.handlePollEnded(pollID: "poll-1", skipVotes: 5, keepVotes: 2)
        XCTAssertTrue(skipped.value)
    }

    /// A passing poll skips the track captured when it opened, not whatever plays now. If
    /// that mutation is stale (the skip reports false after the supplied target changed), no
    /// success chat message or `.passed` event is emitted.
    func testPollPassUsesOpeningTargetAndDoesNotClaimSuccessWhenMutationIsStale() async {
        enableFeature(minVotes: 1)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        let openingTarget = PlaybackTarget(trackKey: "Opening\tArtist", revision: 7)
        let suppliedTarget = ThreadSafeBox(openingTarget)
        let gate = TargetedSkipGate(result: false)
        let chatMessages = ThreadSafeBox<[String]>([])
        let events = ThreadSafeBox<[String]>([])
        await manager.configure(
            capturePlaybackTarget: { suppliedTarget.value },
            performSkip: { target in await gate.perform(target: target) },
            sendChatMessage: { message in chatMessages.mutate { $0.append(message) } },
            createPoll: { _, _ in .created(id: "poll-opening") },
            onVoteEvent: { event in
                if case .passed = event { events.mutate { $0.append("passed") } }
            }
        )
        _ = await manager.recordVote(context: context(userID: "1", isModerator: true))

        let ending = Task {
            await manager.handlePollEnded(
                pollID: "poll-opening", skipVotes: 10, keepVotes: 0)
        }
        await gate.waitUntilStarted()
        suppliedTarget.set(PlaybackTarget(trackKey: "Replacement\tArtist", revision: 8))
        await gate.release()
        await ending.value

        let receivedTarget = await gate.receivedTarget()
        XCTAssertEqual(receivedTarget, openingTarget)
        XCTAssertTrue(chatMessages.value.isEmpty)
        XCTAssertTrue(events.value.isEmpty)
    }

    /// Same for the chat tally: the skip is applied to the opening target, and a stale
    /// mutation yields `.skipUnavailable` with only the `started` event.
    func testChatTallyBindsOpeningTargetAndDoesNotReportPassedForStaleMutation() async {
        enableFeature(minVotes: 2)
        let manager = SkipVoteManager()
        let openingTarget = PlaybackTarget(trackKey: "Opening\tArtist", revision: 4)
        let suppliedTarget = ThreadSafeBox(openingTarget)
        let receivedTarget = ThreadSafeBox<PlaybackTarget?>(nil)
        let events = ThreadSafeBox<[String]>([])
        await manager.configure(
            capturePlaybackTarget: { suppliedTarget.value },
            performSkip: { target in
                receivedTarget.set(target)
                return false
            },
            sendChatMessage: nil,
            createPoll: nil,
            onVoteEvent: { event in
                switch event {
                case .started: events.mutate { $0.append("started") }
                case .passed: events.mutate { $0.append("passed") }
                case .pollStarted: break
                }
            }
        )

        let first = await manager.recordVote(context: context(userID: "1"))
        suppliedTarget.set(PlaybackTarget(trackKey: "Replacement\tArtist", revision: 5))
        let second = await manager.recordVote(context: context(userID: "2"))

        XCTAssertEqual(first, .started(count: 1, needed: 2))
        XCTAssertEqual(second, .skipUnavailable)
        XCTAssertEqual(receivedTarget.value, openingTarget)
        XCTAssertEqual(events.value, ["started"])
    }

    func testPollEndedDoesNotSkipBelowMinimum() async {
        enableFeature(minVotes: 10)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        let skipped = ThreadSafeBox(false)
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: { _ in skipped.set(true); return true },
            sendChatMessage: nil,
            createPoll: { _, _ in .created(id: "poll-1") }
        )
        _ = await manager.recordVote(context: context(userID: "1", isModerator: true))
        await manager.handlePollEnded(pollID: "poll-1", skipVotes: 5, keepVotes: 2)
        XCTAssertFalse(skipped.value, "Skip wins but is below the minimum vote threshold")
    }

    func testPollEndedDoesNotSkipWhenKeepWins() async {
        enableFeature(minVotes: 1)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        let skipped = ThreadSafeBox(false)
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: { _ in skipped.set(true); return true },
            sendChatMessage: nil,
            createPoll: { _, _ in .created(id: "poll-1") }
        )
        _ = await manager.recordVote(context: context(userID: "1", isModerator: true))
        await manager.handlePollEnded(pollID: "poll-1", skipVotes: 2, keepVotes: 9)
        XCTAssertFalse(skipped.value)
    }

    /// A `poll.end` for some other poll id is ignored: the active poll, its timer, and the
    /// track are untouched. The right id then drains it.
    func testWrongPollIDDoesNotClearOrApplyActivePoll() async {
        enableFeature(minVotes: 1)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        let skipped = ThreadSafeBox(false)
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: { _ in skipped.set(true); return true },
            sendChatMessage: nil,
            createPoll: { _, _ in .created(id: "poll-active") }
        )
        _ = await manager.recordVote(context: context(userID: "1", isModerator: true))

        await manager.handlePollEnded(
            pollID: "poll-other", skipVotes: 99, keepVotes: 0)

        XCTAssertFalse(skipped.value)
        let stillActive = await manager.isPollInProgress()
        XCTAssertTrue(stillActive, "An unrelated poll.end must not clear the active poll or its timer")

        await manager.handlePollEnded(
            pollID: "poll-active", skipVotes: 0, keepVotes: 1)
        let inactive = await manager.isPollInProgress()
        XCTAssertFalse(inactive)
    }

    func testPollForPreviousTrackCannotSkipReplacementTrack() async {
        enableFeature(minVotes: 1)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        let skipped = ThreadSafeBox(false)
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: { _ in skipped.set(true); return true },
            sendChatMessage: nil,
            createPoll: { _, _ in .created(id: "poll-old-track") }
        )
        _ = await manager.recordVote(context: context(userID: "1", isModerator: true))

        await manager.trackDidChange()
        await manager.handlePollEnded(
            pollID: "poll-old-track", skipVotes: 10, keepVotes: 0)

        XCTAssertFalse(skipped.value, "A poll against the outgoing track must never skip its replacement")
        let active = await manager.isPollInProgress()
        XCTAssertFalse(active, "The matching stale poll result should still drain active state")
    }

    /// A poll that was created on Twitch while the track changed stays latched (Twitch
    /// allows one poll at a time, so no chat tally fallback) and its eventual result never skips
    /// the new track.
    func testTrackChangeDuringPollCreationRetainsSuccessfulRemotePollUntilDrain() async {
        enableFeature(minVotes: 1)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        let gate = PollCreationGate(result: .created(id: "poll-delayed"))
        let skipped = ThreadSafeBox(false)
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: { _ in skipped.set(true); return true },
            sendChatMessage: nil,
            createPoll: { _, _ in await gate.create() }
        )

        let creation = Task {
            await manager.recordVote(context: self.context(userID: "1", isModerator: true))
        }
        await gate.waitUntilStarted()
        await manager.trackDidChange()
        await gate.release()

        let outcome = await creation.value
        XCTAssertEqual(outcome, .pollTrackChanged)
        let active = await manager.isPollInProgress()
        XCTAssertTrue(active, "A remotely-created poll must stay latched until Twitch drains it")

        let newAttempt = await manager.recordVote(
            context: context(userID: "2", isModerator: true))
        XCTAssertEqual(
            newAttempt, .pollInProgress,
            "Twitch allows only one active poll; do not fall back to a simultaneous chat tally")

        await manager.handlePollEnded(
            pollID: "poll-delayed", skipVotes: 10, keepVotes: 0)
        XCTAssertFalse(skipped.value)
        let drained = await manager.isPollInProgress()
        XCTAssertFalse(drained)
    }

    /// If poll creation definitively fails after the track already changed, the outgoing track's
    /// failure must not seed a chat vote on the new track.
    func testTrackChangeDuringFailedPollCreationDoesNotFallbackVote() async {
        enableFeature(minVotes: 3)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        let gate = PollCreationGate(result: .definitiveFailure)
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: nil,
            sendChatMessage: nil,
            createPoll: { _, _ in await gate.create() }
        )

        let creation = Task {
            await manager.recordVote(context: self.context(userID: "1", isModerator: true))
        }
        await gate.waitUntilStarted()
        await manager.trackDidChange()
        await gate.release()

        let outcome = await creation.value
        XCTAssertEqual(outcome, .pollTrackChanged)
        let chatState = await manager.currentVoteState()
        XCTAssertNil(chatState, "The outgoing track's failed poll must not seed a vote on the new track")
        let active = await manager.isPollInProgress()
        XCTAssertFalse(active)
    }

    /// Disabling the feature while a poll creation is failing returns `.disabled`: no chat
    /// fallback, no skip, no chat message.
    func testDisableDuringDefinitivePollFailureDoesNotFallbackOrSkip() async {
        enableFeature(minVotes: 1)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        let gate = PollCreationGate(result: .definitiveFailure)
        let skipped = ThreadSafeBox(false)
        let chatMessages = ThreadSafeBox<[String]>([])
        await manager.configure(
            capturePlaybackTarget: {
                PlaybackTarget(trackKey: "target\tartist", revision: 0)
            },
            performSkip: { _ in
                skipped.set(true)
                return true
            },
            sendChatMessage: { message in
                chatMessages.mutate { $0.append(message) }
            },
            createPoll: { _, _ in await gate.create() }
        )

        let creation = Task {
            await manager.recordVote(
                context: self.context(userID: "disabled-create", isModerator: true))
        }
        let createStarted = await waitUntil(timeout: .seconds(1)) {
            await gate.started()
        }
        XCTAssertTrue(createStarted)
        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.voteSkipEnabled)
        await gate.release()

        let outcome = await creation.value
        XCTAssertEqual(outcome, .disabled)
        XCTAssertFalse(skipped.value)
        XCTAssertTrue(chatMessages.value.isEmpty)
        let chatState = await manager.currentVoteState()
        let pollActive = await manager.isPollInProgress()
        XCTAssertNil(chatState)
        XCTAssertFalse(pollActive)
    }

    // MARK: - Polls Mode Timeout Fallback

    /// `reset()` during poll creation returns `.pollRequestCancelled` quietly, with no fallback
    /// tally and no chat message.
    func testResetDuringPollCreationReturnsSilentCancellationWithoutFallback() async {
        enableFeature(minVotes: 3)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        let gate = PollCreationGate(result: .indeterminate)
        let chatMessages = ThreadSafeBox<[String]>([])
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: nil,
            sendChatMessage: { message in
                chatMessages.mutate { $0.append(message) }
            },
            createPoll: { _, _ in await gate.create() }
        )

        let creation = Task {
            await manager.recordVote(
                context: self.context(userID: "1", isModerator: true))
        }
        await gate.waitUntilStarted()
        await manager.reset()
        await gate.release()

        let outcome = await creation.value
        XCTAssertEqual(outcome, .pollRequestCancelled)
        let active = await manager.isPollInProgress()
        let chatState = await manager.currentVoteState()
        XCTAssertFalse(active)
        XCTAssertNil(chatState)
        XCTAssertTrue(chatMessages.value.isEmpty)
    }

    func testPollTimeoutClearsStuckPoll() async {
        enableFeature(minVotes: 3)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        // Inject a sub-100ms fallback timeout so the "poll.end never arrived"
        // path is observed in milliseconds instead of pollDuration plus grace.
        let manager = SkipVoteManager(pollTimeoutDuration: .milliseconds(50))
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: nil,
            sendChatMessage: nil,
            createPoll: { _, _ in .created(id: "poll-1") }
        )

        let outcome = await manager.recordVote(context: context(userID: "1", isModerator: true))
        XCTAssertEqual(outcome, .pollStarted)
        let activeBefore = await manager.isPollInProgress()
        XCTAssertTrue(activeBefore)

        // EventSub never delivers channel.poll.end (e.g. a WebSocket drop).
        // The fallback timer must clear the latched poll state.
        let cleared = await waitUntil(timeout: .seconds(1)) {
            await manager.isPollInProgress() == false
        }
        XCTAssertTrue(cleared, "A missed poll.end must not latch pollActive forever")

        // The stuck state is gone, so a fresh poll can start.
        let next = await manager.recordVote(context: context(userID: "2", isModerator: true))
        XCTAssertEqual(next, .pollStarted)
    }

    func testPollEndedCancelsTimeoutFallback() async {
        enableFeature(minVotes: 1)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager(pollTimeoutDuration: .milliseconds(50))
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: nil,
            sendChatMessage: nil,
            createPoll: { _, _ in .created(id: "poll-1") }
        )

        _ = await manager.recordVote(context: context(userID: "1", isModerator: true))
        await manager.handlePollEnded(pollID: "poll-1", skipVotes: 0, keepVotes: 1)
        let active = await manager.isPollInProgress()
        XCTAssertFalse(active, "poll.end must clear the active poll")

        // Give the cancelled fallback timer time to have fired if it were still
        // alive; state must stay clear and a fresh poll must start cleanly.
        try? await Task.sleep(for: .milliseconds(120))
        let stillInactive = await manager.isPollInProgress()
        XCTAssertFalse(stillInactive)
        let next = await manager.recordVote(context: context(userID: "2", isModerator: true))
        XCTAssertEqual(next, .pollStarted)
    }

    func testResetClearsActivePoll() async {
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
        let activeBefore = await manager.isPollInProgress()
        XCTAssertTrue(activeBefore)

        await manager.reset()
        let activeAfter = await manager.isPollInProgress()
        XCTAssertFalse(activeAfter, "reset (e.g. on disconnect) must clear a latched poll")
        let next = await manager.recordVote(context: context(userID: "2", isModerator: true))
        XCTAssertEqual(next, .pollStarted)
    }
}
