//
//  SkipVoteManager+Types.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// The values `SkipVoteManager` hands back: the outcome of a `!voteskip` and
/// the lifecycle events reported to `onVoteEvent`.
extension SkipVoteManager {

    // MARK: - Types

    /// The result of recording a `!voteskip`. Returned as a value (not a string) so
    /// the logic stays unit-testable; `VoteSkipCommand` formats the chat reply.
    enum VoteOutcome: Equatable, Sendable {
        /// The invoking command was cancelled before state could be mutated.
        case cancelled
        /// The feature master toggle is off, the command should stay silent.
        case disabled
        /// Subscriber-only voting is on and the voter is not a subscriber.
        case subscriberOnly
        /// A previous session ended too recently. `remaining` is whole seconds left.
        case onCooldown(remaining: Int)
        /// This vote opened a new session.
        case started(count: Int, needed: Int)
        /// This vote was added to the running session.
        case counted(count: Int, needed: Int)
        /// The voter had already voted in this session.
        case alreadyVoted(count: Int, needed: Int)
        /// The vote reached the threshold, the song is being skipped.
        case passed(count: Int)
        /// Polls mode: a Twitch poll was created.
        case pollStarted
        /// Polls mode: a Twitch poll is already running.
        case pollInProgress
        /// The target track changed while Twitch was creating the poll.
        case pollTrackChanged
        /// Twitch may have created the poll, so another mechanism is blocked.
        case pollStatusUnknown
        /// Poll creation was invalidated by reset/disconnect; stay silent.
        case pollRequestCancelled
        /// Polls mode: a non-moderator tried to start a poll.
        case pollNotAllowed
        /// Music.app's current track could not be bound safely.
        case playbackUnavailable
        /// The bound target changed or Music rejected the final skip command.
        case skipUnavailable
    }

    /// A lifecycle signal emitted to the optional `onVoteEvent` hook so a consumer
    /// (e.g. `AppDelegate`) can post a macOS notification. The manager stays "dumb":
    /// it knows nothing about notifications or user preferences. It only reports
    /// that the event happened.
    enum VoteEvent: Sendable {
        /// A chat-tally session just opened. `needed` is the vote threshold.
        case started(needed: Int)
        /// A native Twitch poll just opened.
        case pollStarted
        /// A vote (chat tally or poll) reached the threshold, song is being skipped.
        case passed
    }
}
