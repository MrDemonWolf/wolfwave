//
//  TwitchChatServiceTests+RedemptionFailures.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation

@testable import WolfWave

/// Redemption storage failures that fail closed, and the containment rules.
extension TwitchChatServiceTests {
    #if DEBUG
    @Test("Acknowledgement write failure immediately exposes failure and pauses only")
    func testAcknowledgementWriteFailureImmediatelyFailsClosed() async throws {
        enum InjectedFailure: Error {
            case write
        }

        let directory = makeIsolatedTempDirectory(prefix: "redemption-ack-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = ThreadSafeBox(0)
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"),
            atomicWriter: { data, url in
                var attempt = 0
                writes.mutate {
                    $0 += 1
                    attempt = $0
                }
                if attempt == 2 { throw InjectedFailure.write }
                try data.write(to: url, options: .atomic)
            }
        )
        let item = try outbox.enqueue(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "ack-failure",
            resolution: .canceled)
        let defaults = DefaultsStore.store
        let statusKey = AppConstants.UserDefaults.songRequestRedemptionStatus
        installManagedRewardIdentity()
        defaults.removeObject(forKey: statusKey)
        defer {
            clearManagedRewardIdentity()
            defaults.removeObject(forKey: statusKey)
        }

        let operations = ThreadSafeBox<[(url: String, body: String)]>([])
        let handler: MockURLProtocol.Handler = { request in
            operations.mutate {
                $0.append((
                    url: request.url?.absoluteString ?? "",
                    body: requestBodyString(request)
                ))
            }
            return (MockURLProtocol.httpResponse(for: request, status: 204), Data())
        }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: handler)),
            redemptionResolutionOutbox: outbox)
        await service.configureBroadcasterRedemptionCredentialsForTesting(
            broadcasterID: "broadcaster")

        await service.acknowledgeRedemptionResolutionForTesting(item)
        await service.awaitPaidRedemptionTasksForTesting()

        #expect(writes.value == 2)
        #expect(outbox.intakeStorageIsUnavailable())
        #expect(outbox.pendingItems() == [item])
        #expect(
            RedemptionStatus(rawValue: defaults.string(forKey: statusKey) ?? "")
                == .storageUnavailable)
        #expect(operations.value.contains {
            $0.url.contains("/channel_points/custom_rewards?")
                && !$0.url.contains("/redemptions")
                && $0.body.contains(#""is_paused":true"#)
        })
        #expect(!operations.value.contains { $0.url.contains("/redemptions?") })
    }

    @Test("Containment ends instead of retrying when the managed reward is gone")
    func testContainmentEndsWhenManagedRewardIdentityIsGone() async throws {
        // Nothing on this machine claims the reward, so the identity clause of
        // the guard is what stops the pause/refund.
        try await assertContainmentEndsWithoutRetrying(
            installingManagedRewardIdentity: false,
            activeBroadcasterID: "broadcaster")
    }

    @Test("Containment ends instead of retrying when the account has moved on")
    func testContainmentEndsWhenBroadcasterCredentialsNoLongerMatch() async throws {
        // The reward is still ours, but the signed-in account is a different
        // broadcaster, so the credential clauses are what stop the pause/refund.
        // This is the account-switch case that produced the original hot loop.
        try await assertContainmentEndsWithoutRetrying(
            installingManagedRewardIdentity: true,
            activeBroadcasterID: "replacement-broadcaster")
    }

    /// Shared body for two cases. An abandoned (owner-less or foreign) canceled item whose
    /// acknowledgement write fails must end containment: no backoff, no request, no live paid task,
    /// no containment left. The item stays on disk for a later owning session.
    private func assertContainmentEndsWithoutRetrying(
        installingManagedRewardIdentity: Bool,
        activeBroadcasterID: String
    ) async throws {
        enum InjectedFailure: Error {
            case write
        }

        let directory = makeIsolatedTempDirectory(prefix: "redemption-containment-abandon")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = ThreadSafeBox(0)
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"),
            atomicWriter: { data, url in
                var attempt = 0
                writes.mutate {
                    $0 += 1
                    attempt = $0
                }
                if attempt == 2 { throw InjectedFailure.write }
                try data.write(to: url, options: .atomic)
            }
        )
        let item = try outbox.enqueue(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "abandoned",
            resolution: .canceled)
        let defaults = DefaultsStore.store
        let statusKey = AppConstants.UserDefaults.songRequestRedemptionStatus
        if installingManagedRewardIdentity {
            installManagedRewardIdentity()
        } else {
            clearManagedRewardIdentity()
        }
        defaults.removeObject(forKey: statusKey)
        defer {
            clearManagedRewardIdentity()
            defaults.removeObject(forKey: statusKey)
        }

        let requests = ThreadSafeBox(0)
        let handler: MockURLProtocol.Handler = { request in
            requests.mutate { $0 += 1 }
            return (MockURLProtocol.httpResponse(for: request, status: 204), Data())
        }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: handler)),
            redemptionResolutionOutbox: outbox)
        await service.configureBroadcasterRedemptionCredentialsForTesting(
            broadcasterID: activeBroadcasterID)
        // Throwing keeps a regression bounded: an unresolvable containment that
        // starts backing off again fails this test instead of spinning forever.
        let backoffs = ThreadSafeBox(0)
        await service.setRedemptionResolutionSleep { _ in
            backoffs.mutate { $0 += 1 }
            throw CancellationError()
        }

        await service.acknowledgeRedemptionResolutionForTesting(item)
        await service.awaitPaidRedemptionTasksForTesting()

        #expect(backoffs.value == 0)
        #expect(requests.value == 0)
        #expect(await service.activePaidRedemptionTaskCount == 0)
        #expect(!TwitchRedemptionTeardownGate.hasContainment(
            serviceID: ObjectIdentifier(service),
            broadcasterID: "broadcaster"))
        // The refund is deferred, not dropped: the item stays on disk and Twitch
        // still lists the redemption as unfulfilled for the next owning session.
        #expect(outbox.pendingItems() == [item])
    }
    #endif

    /// Shared body for outbox write failures on live redemption intake. The first redemption pauses
    /// the reward and is refunded, the status becomes `.storageUnavailable`, and a second
    /// redemption is refunded without another outbox write.
    func assertRedemptionStorageFailureFailsClosed(
        outbox: TwitchRedemptionResolutionOutbox,
        intakeWrites: ThreadSafeBox<Int>,
        expectedWriteAttempts: Int
    ) async {
        let defaults = DefaultsStore.store
        let statusKey = AppConstants.UserDefaults.songRequestRedemptionStatus
        installManagedRewardIdentity()
        defaults.removeObject(forKey: statusKey)
        defer {
            clearManagedRewardIdentity()
            defaults.removeObject(forKey: statusKey)
        }

        let operations = ThreadSafeBox<[(url: String, body: String)]>([])
        let handler: MockURLProtocol.Handler = { request in
            operations.mutate {
                $0.append((
                    url: request.url?.absoluteString ?? "",
                    body: requestBodyString(request)
                ))
            }
            return (
                MockURLProtocol.httpResponse(for: request, status: 204),
                Data()
            )
        }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: handler)),
            redemptionResolutionOutbox: outbox)
        await service.configureBroadcasterRedemptionCredentialsForTesting(
            broadcasterID: "broadcaster")

        await service.handleChannelPointsRedemption(
            Self.redemptionPayload(id: "redemption-1"))
        await service.awaitPaidRedemptionTasksForTesting()

        #expect(intakeWrites.value == expectedWriteAttempts)
        #expect(outbox.pendingItems().isEmpty)
        #expect(
            RedemptionStatus(
                rawValue: defaults.string(forKey: statusKey) ?? "")
                == .storageUnavailable)
        #expect(RedemptionStatus.storageUnavailable.bannerMessage != nil)
        #expect(RedemptionStatus.resolutionStuck.bannerMessage != nil)
        // Twitch opened Channel Points beyond Affiliates and Partners, so the
        // banner points at the dashboard switch instead of a status.
        #expect(RedemptionStatus.notAffiliate.bannerMessage?.contains("Creator Dashboard") == true)
        #expect(RedemptionStatus.notAffiliate.bannerMessage?.contains("Affiliate") == false)
        #expect(operations.value.contains {
            $0.url.contains("/channel_points/custom_rewards?")
                && !$0.url.contains("/redemptions")
                && $0.body.contains(#""is_paused":true"#)
        })
        #expect(operations.value.contains {
            $0.url.contains("/redemptions?")
                && $0.url.contains("id=redemption-1")
                && $0.body.contains(#""status":"CANCELED""#)
        })

        // A later delivery must not attempt another outbox write or enter the
        // song-request pipeline. It is contained and refunded while the durable
        // status keeps the integration visibly failed.
        await service.handleChannelPointsRedemption(
            Self.redemptionPayload(id: "redemption-2"))
        await service.awaitPaidRedemptionTasksForTesting()

        #expect(intakeWrites.value == expectedWriteAttempts)
        #expect(outbox.pendingItems().isEmpty)
        #expect(operations.value.contains {
            $0.url.contains("/redemptions?")
                && $0.url.contains("id=redemption-2")
                && $0.body.contains(#""status":"CANCELED""#)
        })
    }

    /// A `channel.bits.use` event: 100 bits from "Viewer" in channel `channel`, message "Cheer100 a
    /// song".
    nonisolated static func bitsPayload() -> [String: Any] {
        [
            "event": [
                "type": "cheer",
                "bits": 100,
                "broadcaster_user_id": "channel",
                "user_name": "Viewer",
                "message": ["text": "Cheer100 a song"]
            ]
        ]
    }

    /// A channel-point redemption event for reward `reward` on broadcaster `broadcaster`, with song
    /// text "A song".
    nonisolated static func redemptionPayload(id: String) -> [String: Any] {
        [
            "event": [
                "id": id,
                "broadcaster_user_id": "broadcaster",
                "user_name": "Viewer",
                "user_input": "A song",
                "reward": ["id": "reward"]
            ]
        ]
    }
}
