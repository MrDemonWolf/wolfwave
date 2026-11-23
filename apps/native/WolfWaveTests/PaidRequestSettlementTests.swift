//
//  PaidRequestSettlementTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-11-23.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation
@testable import WolfWave

/// Channel points are spent only when the song plays. The queue reports each
/// paid request once (played, or left without playing), and the Twitch service
/// keeps the redemption open until then, fulfilling or refunding it. Replay,
/// duplicate delivery, and teardown must not refund a song that's still waiting.
@Suite("Paid request settlement", .serialized, .isolatedSharedTestState)
@MainActor
struct PaidRequestSettlementTests {

    // MARK: - Helpers

    /// Stores reward `reward` owned by broadcaster `broadcaster`.
    private func installManagedRewardIdentity() {
        clearManagedRewardIdentity()
        #expect(TwitchManagedRewardStore.store(
            .init(rewardID: "reward", broadcasterID: "broadcaster"), replacing: .none))
    }

    /// Removes the stored reward id and its owner identity.
    private func clearManagedRewardIdentity() {
        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.songRequestChannelPointsRewardID)
        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.songRequestChannelPointsRewardIdentity)
    }

    /// A channel-point request item.
    private func paidItem(_ title: String, user: String = "viewer") -> SongRequestItem {
        SongRequestItem(
            song: makeTestSong(id: testSongID(for: title), title: title),
            requesterUsername: user,
            channelPointRedemption: .init(redemptionID: "r-\(title)", rewardID: "reward"))
    }

    /// A FIFO queue recording every settlement report as (redemptionID, played).
    private func recordingQueue() -> (SongRequestQueue, ThreadSafeBox<[String]>) {
        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.songRequestFairShare)
        let queue = SongRequestQueue()
        let reports = ThreadSafeBox<[String]>([])
        queue.onPaidRequestSettled = { redemption, played in
            reports.mutate { $0.append("\(redemption.redemptionID):\(played ? "played" : "refund")") }
        }
        return (queue, reports)
    }

    // MARK: - Queue reports

    @Test("a paid song that starts playing is reported as played, once")
    func commitReportsPlayed() throws {
        let (queue, reports) = recordingQueue()
        _ = queue.add(paidItem("A"))
        let head = try #require(queue.peekNext())

        queue.commitNext(id: head.id)
        queue.clearNowPlaying()

        #expect(reports.value == ["r-A:played"])
    }

    @Test("every way a paid song leaves without playing reports a refund")
    func removalsReportRefund() throws {
        let (queue, reports) = recordingQueue()
        for title in ["A", "B", "C", "D", "E"] { _ = queue.add(paidItem(title)) }
        queue.addPending(paidItem("P"))
        queue.addPending(paidItem("Q"))

        let head = try #require(queue.peekNext())
        queue.removeNext(id: head.id)                       // unplayable: A
        queue.remove(atPosition: 1)                         // mod #1: B
        let third = try #require(queue.items.first)
        queue.remove(id: third.id)                          // settings remove: C
        let pending = try #require(queue.pending.first)
        queue.declinePending(id: pending.id)                // decline: P
        queue.clear()                                       // clear: D, E, Q

        #expect(reports.value == [
            "r-A:refund", "r-B:refund", "r-C:refund", "r-P:refund",
            "r-D:refund", "r-E:refund", "r-Q:refund"
        ])
    }

    @Test("approving a paid request doesn't settle it; it still waits to play")
    func approvalDoesNotSettle() throws {
        let (queue, reports) = recordingQueue()
        queue.addPending(paidItem("A"))
        let pending = try #require(queue.pending.first)

        let item = try #require(queue.takePending(id: pending.id))
        queue.addApproved(item)

        #expect(reports.value.isEmpty)
    }

    @Test("chat requests are never reported")
    func chatRequestsNotReported() {
        let (queue, reports) = recordingQueue()
        _ = queue.add(makeTestRequestItem(title: "Chat", artist: "Artist", requesterUsername: "viewer"))
        queue.clear()
        #expect(reports.value.isEmpty)
    }

    // MARK: - Which results wait

    @Test("queued and pending songs keep their redemption open; playing now and refusals don't")
    func waitsForPlayback() {
        let item = paidItem("A")
        #expect(TwitchChatService.waitsForPlayback(.added(item: item, position: 2, wait: .minutes(4))))
        #expect(TwitchChatService.waitsForPlayback(.added(item: item, position: 1, wait: .onHold)))
        #expect(TwitchChatService.waitsForPlayback(.pendingApproval(item: item)))
        #expect(!TwitchChatService.waitsForPlayback(.added(item: item, position: 1, wait: .playingNow)))
        #expect(!TwitchChatService.waitsForPlayback(.queueFull(max: 10)))
        #expect(!TwitchChatService.waitsForPlayback(.explicitBlocked))
    }

    // MARK: - Twitch service

    /// What ``makeTwitch(prefix:)`` hands back.
    private struct Harness {
        let service: TwitchChatService
        let outbox: TwitchRedemptionResolutionOutbox
        let patches: ThreadSafeBox<[String]>
        let directory: URL
    }

    /// A chat service over a fresh outbox whose Helix calls all succeed,
    /// recording PATCH bodies. Credentials match the "broadcaster" account.
    private func makeTwitch(prefix: String) async throws -> Harness {
        try KeychainService.saveTwitchCredentialGrant(.init(accessToken: "token", userID: "broadcaster"))
        let directory = makeIsolatedTempDirectory(prefix: prefix)
        let outbox = TwitchRedemptionResolutionOutbox(fileURL: directory.appending(path: "outbox.json"))
        let patches = ThreadSafeBox<[String]>([])
        let handler: MockURLProtocol.Handler = { request in
            if request.httpMethod == "PATCH" { patches.mutate { $0.append(requestBodyString(request)) } }
            return (MockURLProtocol.httpResponse(for: request, status: 204), Data())
        }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(session: MockURLProtocol.makeSession(handler: handler)),
            redemptionResolutionOutbox: outbox)
        await service.configureBroadcasterRedemptionCredentialsForTesting(broadcasterID: "broadcaster")
        return Harness(service: service, outbox: outbox, patches: patches, directory: directory)
    }

    @Test("a waiting song's redemption survives replay and is fulfilled when it plays")
    func replaySkipsWaitingThenFulfils() async throws {
        installManagedRewardIdentity()
        defer { clearManagedRewardIdentity() }
        let harness = try await makeTwitch(prefix: "paid-replay")
        let (service, outbox, patches) = (harness.service, harness.outbox, harness.patches)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let intake = try outbox.enqueueIntake(
            broadcasterID: "broadcaster", rewardID: "reward", redemptionID: "waiting").item

        await service.holdRedemptionUntilPlayback(intake)
        await service.replayPendingRedemptionResolutions()

        #expect(outbox.pendingItems().first?.isIntake == true)
        #expect(patches.value.isEmpty)

        await service.settleQueuedRedemption(redemptionID: "waiting", rewardID: "reward", played: true)
        #expect(await waitUntil { outbox.pendingItems().isEmpty })
        #expect(patches.value.contains { $0.contains(#""status":"FULFILLED""#) })
        #expect(!patches.value.contains { $0.contains(#""status":"CANCELED""#) })
    }

    @Test("a waiting song removed before it plays is refunded, and a late report can't flip it")
    func removalRefundsOnce() async throws {
        installManagedRewardIdentity()
        defer { clearManagedRewardIdentity() }
        let harness = try await makeTwitch(prefix: "paid-refund")
        let (service, outbox, patches) = (harness.service, harness.outbox, harness.patches)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let intake = try outbox.enqueueIntake(
            broadcasterID: "broadcaster", rewardID: "reward", redemptionID: "removed").item
        await service.holdRedemptionUntilPlayback(intake)

        await service.settleQueuedRedemption(redemptionID: "removed", rewardID: "reward", played: false)
        await service.settleQueuedRedemption(redemptionID: "removed", rewardID: "reward", played: true)

        #expect(await waitUntil { outbox.pendingItems().isEmpty })
        #expect(patches.value.filter { $0.contains(#""status":"CANCELED""#) }.count == 1)
        #expect(!patches.value.contains { $0.contains(#""status":"FULFILLED""#) })
    }

    @Test("leftover intake with no waiting song is refunded on replay (quit or crash)")
    func unownedIntakeStillRefunds() async throws {
        installManagedRewardIdentity()
        defer { clearManagedRewardIdentity() }
        let harness = try await makeTwitch(prefix: "paid-orphan")
        let (service, outbox, patches) = (harness.service, harness.outbox, harness.patches)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        _ = try outbox.enqueueIntake(broadcasterID: "broadcaster", rewardID: "reward", redemptionID: "orphan")

        await service.replayPendingRedemptionResolutions()

        #expect(await waitUntil { outbox.pendingItems().isEmpty })
        #expect(patches.value.contains { $0.contains(#""status":"CANCELED""#) })
    }

    @Test("a duplicate delivery for a waiting song doesn't refund it")
    func duplicateDeliveryKeepsWaitingSong() async throws {
        installManagedRewardIdentity()
        defer { clearManagedRewardIdentity() }
        let harness = try await makeTwitch(prefix: "paid-duplicate")
        let (service, outbox, patches) = (harness.service, harness.outbox, harness.patches)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let intake = try outbox.enqueueIntake(
            broadcasterID: "broadcaster", rewardID: "reward", redemptionID: "dup").item
        await service.holdRedemptionUntilPlayback(intake)

        await service.handleChannelPointsRedemption(TwitchChatServiceTests.redemptionPayload(id: "dup"))

        #expect(outbox.pendingItems().first?.isIntake == true)
        #expect(patches.value.isEmpty)
    }

    @Test("signing out fulfils a waiting song's redemption, since the song still plays")
    func teardownFulfilsWaitingSong() async throws {
        installManagedRewardIdentity()
        defer { clearManagedRewardIdentity() }
        let harness = try await makeTwitch(prefix: "paid-teardown")
        let (service, outbox, patches) = (harness.service, harness.outbox, harness.patches)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let intake = try outbox.enqueueIntake(
            broadcasterID: "broadcaster", rewardID: "reward", redemptionID: "teardown").item
        await service.holdRedemptionUntilPlayback(intake)

        let settled = await service.settleRedemptionWorkBeforeCredentialTeardown(broadcasterID: "broadcaster")

        #expect(settled)
        #expect(outbox.pendingItems().isEmpty)
        #expect(patches.value.contains { $0.contains(#""status":"FULFILLED""#) })
        #expect(!(await service.intakeAwaitsPlayback(intake.id)))
    }
}
