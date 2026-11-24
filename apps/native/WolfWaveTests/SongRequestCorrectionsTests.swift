//
//  SongRequestCorrectionsTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-11-23.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation
@testable import WolfWave

/// Fixing the queue from chat and the wait estimate: `!wrongsong` undo,
/// `!removesong` by position or viewer, the queue helpers behind them, and the
/// "plays in about N min" text in replies.
@Suite("Song request corrections and wait estimate", .serialized, .isolatedSharedTestState)
@MainActor
struct SongRequestCorrectionsTests {

    // MARK: - Helpers

    /// A FIFO queue (fair-share off) holding one item per entry, in order.
    private func makeQueue(_ entries: [(title: String, user: String)]) -> SongRequestQueue {
        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.songRequestFairShare)
        let queue = SongRequestQueue()
        for entry in entries {
            _ = queue.add(makeTestRequestItem(title: entry.title, artist: "Artist", requesterUsername: entry.user))
        }
        return queue
    }

    /// A service over `queue` whose Music app reports as running.
    private func makeService(queue: SongRequestQueue, musicRunning: Bool = true) -> SongRequestService {
        let music = MockAppleMusicController()
        music.isMusicAppRunning = musicRunning
        return SongRequestService(
            queue: queue,
            blocklist: SongBlocklist(storage: InMemoryBlocklistStorage()),
            musicController: music)
    }

    /// A channel-point request item for `user`.
    private func paidItem(title: String, user: String) -> SongRequestItem {
        SongRequestItem(
            song: makeTestSong(id: testSongID(for: title), title: title),
            requesterUsername: user,
            channelPointRedemption: .init(redemptionID: "r-\(title)", rewardID: "reward"))
    }

    // MARK: - Queue helpers

    @Test("latestWaiting finds the newest request across the queue and the approval pen")
    func latestWaitingSpansPending() {
        let queue = makeQueue([("A", "alice"), ("B", "bob")])
        let pending = makeTestRequestItem(title: "C", artist: "Artist", requesterUsername: "Alice")
        queue.addPending(pending)

        #expect(queue.latestWaiting(requester: "ALICE")?.id == pending.id)
        #expect(queue.latestWaiting(requester: "nobody") == nil)
    }

    @Test("removeWaiting never touches the song playing now")
    func removeWaitingSkipsNowPlaying() throws {
        let queue = makeQueue([("A", "alice"), ("B", "alice")])
        let playing = try #require(queue.dequeue())

        #expect(queue.removeWaiting(id: playing.id) == nil)
        #expect(queue.nowPlaying?.id == playing.id)
    }

    @Test("remove(atPosition:) uses the 1-based #N chat shows")
    func removeAtPosition() {
        let queue = makeQueue([("A", "alice"), ("B", "bob"), ("C", "cara")])

        #expect(queue.remove(atPosition: 2)?.title == "B")
        #expect(queue.remove(atPosition: 0) == nil)
        #expect(queue.remove(atPosition: 9) == nil)
        #expect(queue.items.map(\.title) == ["A", "C"])
    }

    @Test("removeAll(requester:) clears one viewer's queued and pending songs")
    func removeAllForRequester() {
        let queue = makeQueue([("A", "alice"), ("B", "bob"), ("C", "alice")])
        queue.addPending(makeTestRequestItem(title: "D", artist: "Artist", requesterUsername: "alice"))

        let removed = queue.removeAll(requester: "Alice")

        #expect(removed.map(\.title) == ["A", "C", "D"])
        #expect(queue.items.map(\.title) == ["B"])
        #expect(queue.pendingCount == 0)
    }

    @Test("secondsAhead adds up the songs before a position")
    func secondsAhead() {
        let queue = makeQueue([("A", "alice"), ("B", "bob"), ("C", "cara")])

        // makeTestSong defaults to 3:00 songs.
        #expect(queue.secondsAhead(ofPosition: 1) == 0)
        #expect(queue.secondsAhead(ofPosition: 3) == 360)
    }

    // MARK: - Undo

    @Test("!wrongsong removes the viewer's latest waiting request")
    func undoRemovesLatest() {
        let queue = makeQueue([("A", "alice"), ("B", "bob"), ("C", "alice")])
        let service = makeService(queue: queue)

        let outcome = service.undoLatestRequest(requesterLogin: "alice")

        guard case .removed(let item) = outcome else {
            Issue.record("Expected .removed, got \(outcome)")
            return
        }
        #expect(item.title == "C")
        #expect(queue.items.map(\.title) == ["A", "B"])
    }

    @Test("!wrongsong removes a channel-point request and reports it for a refund")
    func undoRefundsPaidRequest() {
        let queue = makeQueue([("A", "alice")])
        _ = queue.add(paidItem(title: "Paid", user: "alice"))
        let settled = ThreadSafeBox<[(String, Bool)]>([])
        queue.onPaidRequestSettled = { redemption, played in
            settled.mutate { $0.append((redemption.redemptionID, played)) }
        }
        let service = makeService(queue: queue)

        let outcome = service.undoLatestRequest(requesterLogin: "alice")

        guard case .removed(let item) = outcome else {
            Issue.record("Expected .removed, got \(outcome)")
            return
        }
        #expect(item.title == "Paid")
        #expect(queue.count == 1)
        #expect(settled.value.map(\.0) == ["r-Paid"])
        #expect(settled.value.map(\.1) == [false])
    }

    @Test("!wrongsong with nothing waiting says so")
    func undoNothing() {
        let service = makeService(queue: makeQueue([("A", "bob")]))
        #expect(service.undoLatestRequest(requesterLogin: "alice") == .nothingToUndo)
    }

    @Test("undo replies are plain and point at the fix")
    func undoReplies() {
        let item = makeTestRequestItem(title: "Wrong One", artist: "Artist", requesterUsername: "alice")

        #expect(WrongSongCommand.reply(for: .removed(item))
            == "Removed \"Wrong One\". Try again with the artist and title, or paste an Apple Music link.")
        let paid = SongRequestItem(
            song: makeTestSong(id: "paid", title: "Paid One"),
            requesterUsername: "alice",
            channelPointRedemption: .init(redemptionID: "r", rewardID: "reward"))
        #expect(WrongSongCommand.reply(for: .removed(paid))
            == "Removed \"Paid One\" and refunded your points. "
                + "Try again with the artist and title, or paste an Apple Music link.")
        #expect(WrongSongCommand.reply(for: .nothingToUndo) == "You don't have a request waiting to undo.")
    }

    // MARK: - Mod remove

    @Test(
        "!removesong reads a position or a viewer",
        arguments: [
            ("!removesong 3", SongRequestService.RemoveTarget.position(3)),
            ("!removesong #2", .position(2)),
            ("!removesong @Alice", .requester("alice")),
            ("!removesong bob", .requester("bob"))
        ])
    func removeTargetParsing(message: String, expected: SongRequestService.RemoveTarget) {
        #expect(RemoveSongCommand.target(from: message) == expected)
    }

    @Test("!removesong with no target or a bad position gets usage")
    func removeTargetMissing() {
        #expect(RemoveSongCommand.target(from: "!removesong") == nil)
        #expect(RemoveSongCommand.target(from: "!removesong 0") == nil)
        #expect(RemoveSongCommand.target(from: "!removesong @") == nil)
    }

    @Test("!removesong removes by position and by viewer")
    func removeRequests() {
        let queue = makeQueue([("A", "alice"), ("B", "bob"), ("C", "alice")])
        let service = makeService(queue: queue)

        #expect(service.removeRequests(.position(2)).map(\.title) == ["B"])
        #expect(service.removeRequests(.requester("alice")).map(\.title) == ["A", "C"])
        #expect(queue.isEmpty)
    }

    @Test("!removesong replies name what happened")
    func removeReplies() {
        let item = makeTestRequestItem(title: "Song", artist: "Artist", requesterUsername: "alice")

        #expect(RemoveSongCommand.reply(for: .position(4), removed: []) == "There's no song at #4.")
        #expect(RemoveSongCommand.reply(for: .requester("bob"), removed: []) == "bob has no songs waiting.")
        #expect(RemoveSongCommand.reply(for: .position(1), removed: [item])
            == "Removed \"Song\" (requested by alice).")
        #expect(RemoveSongCommand.reply(for: .requester("alice"), removed: [item, item])
            == "Removed 2 songs from alice.")
    }

    // MARK: - Wait estimate

    @Test(
        "waits under a minute are up next; longer ones round to whole minutes",
        arguments: [
            (0.0, SongRequestService.RequestWait.upNext),
            (59.0, .upNext),
            (60.0, .minutes(1)),
            (89.0, .minutes(1)),
            (90.0, .minutes(2)),
            (540.0, .minutes(9))
        ])
    func waitBuckets(seconds: Double, expected: SongRequestService.RequestWait) {
        #expect(SongRequestService.wait(forSeconds: seconds) == expected)
    }

    @Test("the estimate adds the current track's time left to the songs ahead")
    func estimateUsesRemainingTime() {
        let queue = makeQueue([("A", "alice"), ("B", "bob")])
        let service = makeService(queue: queue)
        service.currentTrackRemaining = { 120 }

        // 2:00 left + one 3:00 song ahead = 5 min.
        #expect(service.estimatedWait(forPosition: 2) == .minutes(5))
    }

    @Test("no estimate while held or while Music is closed")
    func estimateHeldOrClosed() {
        let held = makeService(queue: makeQueue([("A", "alice")]))
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.songRequestHoldEnabled)
        #expect(held.estimatedWait(forPosition: 1) == .onHold)

        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.songRequestHoldEnabled)
        let closed = makeService(queue: makeQueue([("A", "alice")]), musicRunning: false)
        #expect(closed.estimatedWait(forPosition: 1) == .whenMusicStarts)
    }

    @Test("replies carry the wait after the queue position")
    func repliesShowWait() {
        let item = makeTestRequestItem(title: "Howl", artist: "Gray Wolf", requesterUsername: "alice")

        #expect(SongRequestCommand.reply(for: .added(item: item, position: 3, wait: .minutes(9)))
            == "Added \"Howl\" by Gray Wolf, #3 in queue · plays in about 9 min")
        #expect(SongRequestCommand.reply(for: .added(item: item, position: 1, wait: .whenMusicStarts))
            == "Added \"Howl\" by Gray Wolf, #1 in queue · plays when the music starts")
        #expect(MyQueueCommand.reply(positions: [(position: 2, item: item)], pending: [], wait: { _ in .upNext })
            == "Your requests: #2 \"Howl\" · Gray Wolf · up next")
    }
}
