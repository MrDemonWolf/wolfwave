//
//  RequestQueueReorderTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-11-23.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation
@testable import WolfWave

/// Reordering the live queue from the Request Queue window: drag (`move`) and
/// "Play Next" (`moveToFront`), plus the window's open-request hand-off.
@Suite("Request queue reorder", .serialized, .isolatedSharedTestState)
@MainActor
struct RequestQueueReorderTests {

    /// A FIFO queue of songs titled by `titles`, in order.
    private func makeQueue(_ titles: [String]) -> SongRequestQueue {
        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.songRequestFairShare)
        let queue = SongRequestQueue()
        for title in titles {
            _ = queue.add(makeTestRequestItem(title: title, artist: "Artist", requesterUsername: "user-\(title)"))
        }
        return queue
    }

    @Test(
        "move follows SwiftUI's onMove offsets",
        arguments: [
            (IndexSet(integer: 0), 3, ["B", "C", "A", "D"]),
            (IndexSet(integer: 3), 0, ["D", "A", "B", "C"]),
            (IndexSet([0, 2]), 4, ["B", "D", "A", "C"]),
            (IndexSet(integer: 1), 2, ["A", "B", "C", "D"])
        ])
    func move(source: IndexSet, destination: Int, expected: [String]) {
        let queue = makeQueue(["A", "B", "C", "D"])
        queue.move(fromOffsets: source, toOffset: destination)
        #expect(queue.items.map(\.title) == expected)
    }

    @Test("a no-op or out-of-range move reports no change")
    func moveNoChange() {
        let queue = makeQueue(["A", "B"])
        #expect(!queue.move(fromOffsets: IndexSet(integer: 0), toOffset: 0))
        #expect(!queue.move(fromOffsets: IndexSet(integer: 5), toOffset: 0))
        #expect(queue.items.map(\.title) == ["A", "B"])
    }

    @Test("Play Next moves a song to the front, and does nothing for the head")
    func moveToFront() throws {
        let queue = makeQueue(["A", "B", "C"])
        let last = try #require(queue.items.last)

        #expect(queue.moveToFront(id: last.id))
        #expect(queue.items.map(\.title) == ["C", "A", "B"])
        #expect(!queue.moveToFront(id: last.id))
    }

    @Test("moving the head mid-start makes the pending commit a no-op")
    func moveInvalidatesReservedHead() throws {
        let queue = makeQueue(["A", "B"])
        let head = try #require(queue.peekNext())

        queue.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)

        #expect(queue.commitNext(id: head.id) == nil)
        #expect(queue.items.map(\.title) == ["B", "A"])
    }

    @Test("the window's open request is taken once")
    func openRequestConsumedOnce() {
        let window = RequestQueueWindow()
        #expect(!window.consumeOpenRequest())
        window.requestOpen()
        window.requestOpen()
        #expect(window.consumeOpenRequest())
        #expect(!window.consumeOpenRequest())
    }
}
