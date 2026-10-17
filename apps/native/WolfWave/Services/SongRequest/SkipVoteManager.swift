//
//  SkipVoteManager.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-22.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// What WolfWave can prove after asking Twitch to create a skip poll.
///
/// Anything short of `.definitiveFailure` keeps the poll latch held until
/// poll.end or the timeout, so a chat tally and a native poll never run at once.
nonisolated enum SkipPollCreationOutcome: Equatable, Sendable {
    /// Twitch confirmed creation and returned the poll's Helix identity.
    case created(id: String)
    /// The request was invalid or Twitch safely rejected it, so no poll exists.
    case definitiveFailure
    /// Twitch rejected creation because a native poll is already running.
    case pollAlreadyActive
    /// Twitch may have created the poll, but transport/server ambiguity or a
    /// malformed success response means WolfWave cannot prove its identity.
    case indeterminate
}

/// Coordinates chat vote-to-skip sessions.
///
/// Two modes, selected by the `voteSkipUsePolls` preference:
/// - **Chat tally**: each `!voteskip` is a vote. Unique voters are counted inside
///   a time window; once the minimum is reached the current song is skipped.
/// - **Twitch Polls**: a moderator's `!voteskip` opens a native Twitch poll and the
///   `channel.poll.end` result drives the skip.
///
/// State is observed via `.voteSkipStateChanged`, so this type does not adopt
/// `@Observable`. Implemented as an `actor` so mutation safety
/// is enforced by the compiler. Replaces the prior `final class + NSLock`.
///
/// Every vote binds to an exact `PlaybackTarget` captured from Music.app when
/// the session or poll opens, and the skip only fires against that target.
/// Because the actor suspends while reading Music.app and calling Helix, each
/// await is followed by generation checks (`trackGeneration`,
/// `lifecycleGeneration`, `pollGeneration`) so a track change, reset, or newer
/// poll that happened meanwhile turns the old request into a no-op.
actor SkipVoteManager {

    // MARK: - Wiring

    /// Captures the exact Music track before a native poll is created.
    private var capturePlaybackTarget: (@Sendable () async -> PlaybackTarget?)?

    /// Skips only the supplied poll target. Wired by `AppDelegate` to
    /// `SongRequestService.voteSkip(target:)`.
    private var performSkip: (@Sendable (PlaybackTarget) async -> Bool)?

    /// Sends a message to Twitch chat (for window-expiry and poll-result notices,
    /// which have no triggering message to reply to). Wired by `AppDelegate`.
    private var sendChatMessage: (@Sendable (String) -> Void)?

    /// Creates a Twitch poll and reports whether Twitch proved creation,
    /// definitively rejected it, or left the result ambiguous. Wired by
    /// `AppDelegate` to `TwitchChatService.createSkipPoll(...)`.
    private var createPoll: (@Sendable (_ title: String, _ durationSeconds: Int) async
        -> SkipPollCreationOutcome)?

    /// Lifecycle hook for vote events (start / poll-start / pass). Wired by
    /// `AppDelegate` to post macOS notifications. The manager does no gating here.
    private var onVoteEvent: (@Sendable (VoteEvent) -> Void)?

    /// Installs the closures used to skip, send chat messages, create polls, and
    /// report vote events. Called once at startup from
    /// `AppDelegate.setupSkipVoteManager()` so the actor's mutable closure
    /// properties are only assigned from inside the actor.
    func configure(
        capturePlaybackTarget: (@Sendable () async -> PlaybackTarget?)?,
        performSkip: (@Sendable (PlaybackTarget) async -> Bool)?,
        sendChatMessage: (@Sendable (String) -> Void)?,
        createPoll: (@Sendable (_ title: String, _ durationSeconds: Int) async
            -> SkipPollCreationOutcome)?,
        onVoteEvent: (@Sendable (VoteEvent) -> Void)? = nil
    ) {
        self.capturePlaybackTarget = capturePlaybackTarget
        self.performSkip = performSkip
        self.sendChatMessage = sendChatMessage
        self.createPoll = createPoll
        self.onVoteEvent = onVoteEvent
    }

    // MARK: - Init

    /// Optional override for the chat-tally window duration. When set, it takes
    /// precedence over the `voteSkipWindowSeconds` preference. Tests inject a
    /// sub-100ms window so window-expiry assertions don't wait whole seconds.
    private let windowOverride: Duration?

    /// Optional override for the poll-end fallback timeout. When set, it takes
    /// precedence over `pollDuration` plus the grace period. Tests inject a
    /// sub-100ms timeout so missed-poll-end assertions don't wait whole minutes.
    private let pollTimeoutOverride: Duration?

    /// Creates a skip-vote manager.
    ///
    /// - Parameters:
    ///   - windowDuration: Overrides the chat-tally window length read from
    ///     preferences. Defaults to `nil` (use the preference).
    ///   - pollTimeoutDuration: Overrides the poll-end fallback timeout
    ///     (normally the poll duration plus a grace period). Defaults to `nil`.
    init(windowDuration: Duration? = nil, pollTimeoutDuration: Duration? = nil) {
        self.windowOverride = windowDuration
        self.pollTimeoutOverride = pollTimeoutDuration
    }

    // MARK: - State

    /// Twitch user IDs that voted in the open chat tally. IDs, not logins, so
    /// a renamed viewer can't vote twice.
    private var voters: Set<String> = []
    /// When the open chat tally started; `nil` means no tally is running.
    private var sessionStart: Date?
    /// Exact Music track captured when the active chat tally opened.
    private var activeChatTarget: PlaybackTarget?
    /// Expiry timer for the open chat tally.
    private var windowTask: Task<Void, Never>?
    /// When the last tally ended (passed or expired). Drives the inter-session
    /// cooldown; `nil` means no cooldown applies.
    private var lastSessionEnd: Date?
    /// Latched from just before the Helix create call until poll.end, a
    /// definitive creation failure, the timeout, or `reset()`. Blocks new
    /// chat tallies and second polls, even if the Polls toggle changes.
    private var pollActive = false
    /// Fallback timer that clears `pollActive` if poll.end never arrives.
    private var pollTimeoutTask: Task<Void, Never>?
    /// Helix ID of the active native poll. Poll-end events must match exactly.
    private var activePollID: String?
    /// Track generation captured before the create-poll request suspends.
    private var activePollTrackGeneration: Int?
    /// Exact Music track captured before the active poll was created.
    private var activePollTarget: PlaybackTarget?

    /// Monotonic identity of the track vote-skip currently targets. This advances
    /// for every observed track change, even when no chat-tally session exists,
    /// so a native poll can never skip the song that replaced its original target.
    private var trackGeneration = 0

    /// Monotonic id bumped each time a new chat-tally session opens. The window
    /// timer captures the id at spawn time and checks it before expiring, so a
    /// stale timer (whose sleep ran past a fast pass + immediate re-open with a
    /// zero cooldown) can't clear the session that replaced it.
    private var sessionGeneration = 0

    /// Invalidates a chat-vote target capture when Twitch disconnects or the
    /// manager is reset while the Music.app read is suspended. Kept separate
    /// from `sessionGeneration` so two concurrent first votes can still join
    /// the same newly-opened tally instead of treating each other as a reset.
    private var lifecycleGeneration = 0

    /// Monotonic id bumped each time a new Twitch poll opens. The poll-end
    /// fallback timer captures the id at spawn time and checks it before firing,
    /// so a stale timer can't clear the poll that replaced it. Mirrors
    /// `sessionGeneration` for the chat-tally window timer.
    private var pollGeneration = 0

    /// Extra seconds granted past `pollDuration` before the poll-end fallback
    /// timer assumes the `channel.poll.end` event was missed.
    private static let pollEndGraceSeconds = 15

    // MARK: - Public API

    /// Records a `!voteskip` from `context` and returns the outcome.
    ///
    /// Routing: an active poll latch always wins (`.pollInProgress`); an open
    /// chat tally keeps counting even in Polls mode (it is the fallback for a
    /// failed poll create); otherwise the `voteSkipUsePolls` preference picks
    /// the mode. May suspend to read Music.app and to call Helix.
    ///
    /// - Parameter context: The chat sender. `userID` is the vote identity.
    /// - Returns: What happened, for `VoteSkipCommand` to phrase.
    func recordVote(context: BotCommandContext) async -> VoteOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard isEnabled else { return .disabled }
        // A native poll remains remote state even if the local mode toggle is
        // changed. Never open a simultaneous chat tally while it is latched.
        if pollActive { return .pollInProgress }
        // A definitive Helix failure may have opened the chat fallback while
        // Polls remains selected. Keep counting that session instead of trying
        // to start a native poll beside it.
        if sessionStart != nil { return await recordChatVote(context: context) }
        if usePolls {
            return await handlePollVote(context: context)
        }
        return await recordChatVote(context: context)
    }

    /// Reports the active session's progress, or `nil` when no session is running.
    ///
    /// Read-only state check. Its only callers are unit tests
    /// (`SkipVoteManagerTests`); the app observes progress through
    /// `.voteSkipStateChanged` instead.
    func currentVoteState() -> (count: Int, needed: Int)? {
        guard sessionStart != nil else { return nil }
        return (voters.count, minVotes)
    }

    /// Reports whether a vote-skip Twitch poll is in flight (created, but its
    /// `channel.poll.end` result not yet received or timed out).
    ///
    /// Read-only state check. Its only callers are unit tests
    /// (`SkipVoteManagerTests`).
    func isPollInProgress() -> Bool {
        pollActive
    }

    /// Handles a finished Twitch poll (from the `channel.poll.end` EventSub event).
    ///
    /// Ignored unless `pollID` matches the latched poll. The latch is always
    /// released for a matching poll; the skip then needs the poll to still
    /// target the current track, vote-skip to be on, and `skipVotes` to beat
    /// `keepVotes` and reach `minVotes`. Posts the result to chat.
    ///
    /// - Parameters:
    ///   - pollID: Helix poll ID from the event.
    ///   - skipVotes: Vote count for the "Skip" choice.
    ///   - keepVotes: Vote count for the "Keep playing" choice.
    func handlePollEnded(pollID: String, skipVotes: Int, keepVotes: Int) async {
        guard pollActive, activePollID == pollID else {
            Log.debug(
                "SkipVoteManager: Ignoring poll.end for non-active poll \(pollID)",
                category: .songRequest
            )
            return
        }

        let appliesToCurrentTrack = activePollTrackGeneration == trackGeneration
        let target = activePollTarget
        clearPollState()
        guard appliesToCurrentTrack, let target else {
            Log.info(
                "SkipVoteManager: Poll \(pollID) targeted an earlier track; result ignored",
                category: .songRequest
            )
            return
        }

        guard isEnabled else {
            Log.info(
                "SkipVoteManager: Poll \(pollID) drained after vote-skip was disabled",
                category: .songRequest
            )
            return
        }

        let needed = minVotes
        if skipVotes > keepVotes && skipVotes >= needed {
            guard await performSkip?(target) == true else {
                Log.info(
                    "SkipVoteManager: Poll \(pollID) target became stale before mutation",
                    category: .songRequest
                )
                return
            }
            sendChatMessage?("✅ The vote passed, skipping! (\(skipVotes) skip / \(keepVotes) keep)")
            onVoteEvent?(.passed)
        } else {
            sendChatMessage?("📊 Vote over, the song stays. (\(skipVotes) skip / \(keepVotes) keep)")
        }
    }

    /// Ends any open chat-tally session because the current song changed.
    ///
    /// Votes cast against the outgoing song must not carry over to the new
    /// one, so the session is discarded. Unlike window expiry, the
    /// inter-session cooldown does NOT start: the vote never ran its course,
    /// so chat can open a fresh vote on the new song right away. A stale
    /// window timer is defused the same way `windowExpired` handles it
    /// (cancelled here, and its `sessionStart != nil` / generation guards
    /// no-op it if the sleep already ran). Twitch polls are left alone: a
    /// native poll runs on Twitch's side and still resolves via
    /// `channel.poll.end` or the timeout fallback.
    func trackDidChange() {
        trackGeneration &+= 1
        guard sessionStart != nil else { return }
        windowTask?.cancel()
        windowTask = nil
        voters.removeAll()
        sessionStart = nil
        activeChatTarget = nil
        postState()
        Log.debug(
            "SkipVoteManager: track changed, chat-tally vote session cleared",
            category: .songRequest
        )
    }

    /// Clears all session state (e.g. on Twitch disconnect).
    ///
    /// Also drops the inter-session cooldown, and bumps the lifecycle and poll
    /// generations so any vote or poll create still suspended returns without
    /// effect. A poll that exists on Twitch is forgotten locally.
    func reset() {
        windowTask?.cancel()
        windowTask = nil
        lifecycleGeneration &+= 1
        pollGeneration &+= 1
        clearPollState()
        voters.removeAll()
        sessionStart = nil
        activeChatTarget = nil
        lastSessionEnd = nil
    }

    // MARK: - Chat-tally Voting

    /// Counts one chat vote, opening a tally (and capturing its target) when
    /// none is running.
    ///
    /// The Music.app read happens before any state changes; if the track,
    /// lifecycle, enabled state, or mode changed during it, the vote is dropped.
    /// Everything after that runs without suspending until the skip itself.
    ///
    /// - Parameters:
    ///   - context: The voter.
    ///   - fallbackTarget: Target already captured by a poll request whose
    ///     create failed definitively; skips the second Music.app read.
    private func recordChatVote(
        context: BotCommandContext,
        fallbackTarget: PlaybackTarget? = nil
    ) async -> VoteOutcome {
        guard !Task.isCancelled else { return .cancelled }
        if isSubscriberOnly && !context.isSubscriber && !context.isPrivileged {
            return .subscriberOnly
        }

        let needed = minVotes
        let openingTarget: PlaybackTarget?
        if sessionStart == nil, let fallbackTarget {
            openingTarget = fallbackTarget
        } else if sessionStart == nil {
            let openingTrackGeneration = trackGeneration
            let openingLifecycleGeneration = lifecycleGeneration
            guard let captured = await targetForNewVote() else {
                return .playbackUnavailable
            }
            guard openingTrackGeneration == trackGeneration,
                  openingLifecycleGeneration == lifecycleGeneration else {
                return .playbackUnavailable
            }
            guard !Task.isCancelled else { return .cancelled }
            guard isEnabled else { return .disabled }
            guard !usePolls else { return .playbackUnavailable }
            openingTarget = captured
        } else {
            openingTarget = nil
        }

        enum Decision {
            case outcome(VoteOutcome)
            case pass(count: Int, target: PlaybackTarget)
        }

        let previousSessionEnd = lastSessionEnd
        let endingTrackGeneration = trackGeneration
        let endingLifecycleGeneration = lifecycleGeneration
        let decision: Decision = {
            let now = Date()

            // No session running, open one (subject to the inter-session cooldown).
            guard sessionStart != nil else {
                if let last = lastSessionEnd {
                    let elapsed = now.timeIntervalSince(last)
                    if elapsed < sessionCooldown {
                        return .outcome(.onCooldown(remaining: Int(ceil(sessionCooldown - elapsed))))
                    }
                }
                voters = [context.userID]
                sessionStart = now
                activeChatTarget = openingTarget
                sessionGeneration += 1
                if voters.count >= needed {
                    let count = voters.count
                    guard let target = activeChatTarget else {
                        return .outcome(.playbackUnavailable)
                    }
                    finishSession()
                    return .pass(count: count, target: target)
                }
                startWindowTask()
                return .outcome(.started(count: voters.count, needed: needed))
            }

            // Session running, add the voter unless they already voted.
            if voters.contains(context.userID) {
                return .outcome(.alreadyVoted(count: voters.count, needed: needed))
            }
            voters.insert(context.userID)
            if voters.count >= needed {
                let count = voters.count
                guard let target = activeChatTarget else {
                    return .outcome(.playbackUnavailable)
                }
                finishSession()
                return .pass(count: count, target: target)
            }
            return .outcome(.counted(count: voters.count, needed: needed))
        }()

        switch decision {
        case .outcome(let outcome):
            switch outcome {
            case .started(_, let needed):
                postState()
                onVoteEvent?(.started(needed: needed))
            case .counted:
                postState()
            default:
                break
            }
            return outcome
        case .pass(let count, let target):
            var skipped = false
            // `finishSession()` already started the cooldown. If the skip didn't
            // happen, restore the previous cooldown so a failed skip doesn't
            // lock chat out; skip the write entirely if a track change or reset
            // already moved on.
            defer {
                if trackGeneration == endingTrackGeneration,
                   lifecycleGeneration == endingLifecycleGeneration {
                    lastSessionEnd = skipped ? Date() : previousSessionEnd
                }
            }
            postState()
            guard !Task.isCancelled else { return .cancelled }
            guard await performSkip?(target) == true else {
                return .skipUnavailable
            }
            skipped = true
            guard !Task.isCancelled else { return .cancelled }
            onVoteEvent?(.passed)
            return .passed(count: count)
        }
    }

    // MARK: - Polls Voting

    /// Opens a native Twitch poll for a moderator or the broadcaster.
    ///
    /// The latch (`pollActive`) is taken before the Helix call so a second
    /// moderator can't race a duplicate create. After the call, the outcome is
    /// handled by what it proves: a created or possibly-created poll keeps the
    /// latch until poll.end or timeout, while a definitive failure releases it
    /// and falls back to a chat tally on the same target.
    private func handlePollVote(context: BotCommandContext) async -> VoteOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard context.isPrivileged else { return .pollNotAllowed }

        if pollActive { return .pollInProgress }
        let requestTrackGeneration = trackGeneration
        let requestPollGeneration = pollGeneration
        guard let target = await targetForNewVote() else {
            return .playbackUnavailable
        }
        guard !Task.isCancelled else { return .cancelled }
        guard requestTrackGeneration == trackGeneration else {
            return .pollTrackChanged
        }
        // Another moderator can claim the poll while this request is suspended
        // in Music.app. Report the active poll rather than issuing a second
        // Helix create or misclassifying the request as a reset cancellation.
        if pollActive { return .pollInProgress }
        guard requestPollGeneration == pollGeneration else {
            return .pollRequestCancelled
        }
        guard isEnabled else { return .disabled }
        guard usePolls else { return .pollRequestCancelled }
        pollGeneration &+= 1
        let generation = pollGeneration
        let targetTrackGeneration = trackGeneration
        pollActive = true
        activePollID = nil
        activePollTrackGeneration = targetTrackGeneration
        activePollTarget = target

        let creation = await createPoll?("Skip the current song?", pollDuration)
            ?? .definitiveFailure
        guard generation == pollGeneration, pollActive else {
            // reset()/disconnect deliberately invalidated this request. It says
            // nothing about a track change and must not reply or mutate a newer
            // poll generation when the suspended request eventually returns.
            return .pollRequestCancelled
        }
        guard targetTrackGeneration == trackGeneration else {
            switch creation {
            case .created(let pollID):
                // The poll exists remotely and Twitch permits only one active
                // poll. Keep its identity latched until poll.end (or timeout)
                // drains it, but its old track generation prevents any skip.
                activePollID = pollID
                startPollTimeoutTask()
            case .indeterminate:
                // A poll may exist but its ID is unknown. Latch until timeout;
                // never open a simultaneous chat tally or second Twitch poll.
                startPollTimeoutTask()
            case .pollAlreadyActive:
                // Twitch proved another native poll exists. Its identity is
                // unknown, so hold the latch until poll timeout.
                startPollTimeoutTask()
            case .definitiveFailure:
                clearPollState()
            }
            return .pollTrackChanged
        }

        if Task.isCancelled {
            switch creation {
            case .created(let pollID):
                activePollID = pollID
                startPollTimeoutTask()
            case .pollAlreadyActive, .indeterminate:
                startPollTimeoutTask()
            case .definitiveFailure:
                clearPollState()
            }
            return .cancelled
        }

        switch creation {
        case .created(let pollID):
            activePollID = pollID
            startPollTimeoutTask()
            onVoteEvent?(.pollStarted)
            return .pollStarted
        case .definitiveFailure:
            clearPollState()
            // Twitch proved this request did not create a poll, so a chat tally
            // is safe only while the same enabled Polls mode still owns the
            // request. A disable or mode change cancels without a stale reply.
            guard isEnabled else { return .disabled }
            guard usePolls else { return .pollRequestCancelled }
            sendChatMessage?("📊 Twitch couldn't open a poll, counting chat votes instead.")
            return await recordChatVote(
                context: context,
                fallbackTarget: target)
        case .pollAlreadyActive:
            startPollTimeoutTask()
            return .pollInProgress
        case .indeterminate:
            // The remote result is unknown. Treat the maybe-poll as active until
            // timeout so Twitch and chat can never run two skip votes at once.
            startPollTimeoutTask()
            return .pollStatusUnknown
        }
    }

    // MARK: - Session Helpers

    /// Captures through the configured production boundary. An entirely unwired
    /// manager uses a sentinel only so pure state-machine tests can exercise
    /// tally logic; it has no skip or poll closures capable of external effects.
    private func targetForNewVote() async -> PlaybackTarget? {
        guard let capturePlaybackTarget else {
            return PlaybackTarget(trackKey: "", revision: 0)
        }
        return await capturePlaybackTarget()
    }

    /// Tears down the active session and starts the inter-session cooldown.
    private func finishSession() {
        windowTask?.cancel()
        windowTask = nil
        voters.removeAll()
        sessionStart = nil
        activeChatTarget = nil
        lastSessionEnd = Date()
    }

    /// Spawns the window timer that fails the session if the threshold is never met.
    private func startWindowTask() {
        // Tests inject a sub-second `windowOverride`; production falls back to the
        // `voteSkipWindowSeconds` preference.
        let duration = windowOverride ?? .seconds(windowSeconds)
        let generation = sessionGeneration
        windowTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await self?.windowExpired(generation: generation)
        }
    }

    /// Called when a session's window elapses without reaching the threshold.
    /// Ignores the call if a different session has since opened (`generation`
    /// mismatch). A fast pass + zero-cooldown re-open can outrun this timer.
    private func windowExpired(generation: Int) {
        guard sessionStart != nil, generation == sessionGeneration else { return }
        let count = voters.count
        voters.removeAll()
        sessionStart = nil
        activeChatTarget = nil
        windowTask = nil
        lastSessionEnd = Date()
        postState()
        sendChatMessage?("⏳ Vote-skip failed, only \(count) of \(minVotes) needed. The song stays!")
    }

    /// Clears native-poll state. Matching poll.end, timeout, failed creation,
    /// and reset share this path; wrong poll IDs never call it.
    private func clearPollState() {
        pollTimeoutTask?.cancel()
        pollTimeoutTask = nil
        pollActive = false
        activePollID = nil
        activePollTrackGeneration = nil
        activePollTarget = nil
    }

    /// Spawns the fallback timer that clears a latched poll when the
    /// `channel.poll.end` event never arrives. EventSub does not replay events
    /// missed during a disconnect, so without this a WebSocket drop mid-poll
    /// would leave `pollActive` stuck at `true` and vote-skip permanently
    /// replying "poll in progress". Waits the poll duration plus a grace period;
    /// `handlePollEnded` and `reset()` cancel it on the happy paths.
    private func startPollTimeoutTask() {
        // Tests inject a sub-second `pollTimeoutOverride`; production waits out
        // the Twitch poll plus a grace period for the poll.end event to land.
        let duration = pollTimeoutOverride ?? .seconds(pollDuration + Self.pollEndGraceSeconds)
        let generation = pollGeneration
        pollTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await self?.pollTimedOut(generation: generation)
        }
    }

    /// Called when the poll-end fallback timer fires. A no-op unless the same
    /// poll generation is still marked active (`handlePollEnded` never ran).
    private func pollTimedOut(generation: Int) {
        guard pollActive, generation == pollGeneration else { return }
        pollActive = false
        activePollID = nil
        activePollTrackGeneration = nil
        activePollTarget = nil
        pollTimeoutTask = nil
        Log.warn(
            "SkipVoteManager: Twitch poll result never arrived; clearing stuck poll state",
            category: .songRequest
        )
    }

    /// Posts `.voteSkipStateChanged` with the current session progress (if any).
    ///
    /// Snapshots the state on the actor, then posts on the main actor in an
    /// unstructured task, so observers may see it slightly after the change.
    private func postState() {
        let state: (count: Int, needed: Int)? = sessionStart != nil
            ? (voters.count, minVotes)
            : nil
        Task { @MainActor in
            NotificationCenter.default.postVoteSkipState(state)
        }
    }
}
