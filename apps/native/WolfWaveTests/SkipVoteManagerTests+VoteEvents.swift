//
//  SkipVoteManagerTests+VoteEvents.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// The `onVoteEvent` hook fired as sessions open and pass.
extension SkipVoteManagerTests {
    // MARK: - Vote Event Hook

    func testOnVoteEventFiresStartedWhenSessionOpens() async {
        enableFeature(minVotes: 3)
        let manager = SkipVoteManager()
        let events = ThreadSafeBox<[String]>([])
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: nil,
            sendChatMessage: nil,
            createPoll: nil,
            onVoteEvent: { event in
                if case .started(let needed) = event {
                    events.mutate { $0.append("started:\(needed)") }
                }
            }
        )

        _ = await manager.recordVote(context: context(userID: "1"))
        XCTAssertEqual(events.value, ["started:3"])
    }

    func testOnVoteEventFiresPassedOnThreshold() async {
        enableFeature(minVotes: 2)
        let manager = SkipVoteManager()
        let events = ThreadSafeBox<[String]>([])
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: { _ in true },
            sendChatMessage: nil,
            createPoll: nil,
            onVoteEvent: { event in
                switch event {
                case .started: events.mutate { $0.append("started") }
                case .passed: events.mutate { $0.append("passed") }
                case .pollStarted: events.mutate { $0.append("pollStarted") }
                }
            }
        )

        _ = await manager.recordVote(context: context(userID: "1"))
        _ = await manager.recordVote(context: context(userID: "2"))
        XCTAssertEqual(events.value, ["started", "passed"])
    }

    func testOnVoteEventFiresPassedFromPollResult() async {
        enableFeature(minVotes: 3)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.voteSkipUsePolls)
        let manager = SkipVoteManager()
        let events = ThreadSafeBox<[String]>([])
        await manager.configure(
            capturePlaybackTarget: { PlaybackTarget(trackKey: "target\tartist", revision: 0) },
            performSkip: { _ in true },
            sendChatMessage: nil,
            createPoll: { _, _ in .created(id: "poll-1") },
            onVoteEvent: { event in
                if case .passed = event { events.mutate { $0.append("passed") } }
            }
        )

        _ = await manager.recordVote(context: context(userID: "1", isModerator: true))
        await manager.handlePollEnded(pollID: "poll-1", skipVotes: 9, keepVotes: 2)
        XCTAssertEqual(events.value, ["passed"])
    }
}
