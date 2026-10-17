//
//  TwitchChatServiceTests+Redemptions.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation

@testable import WolfWave

/// Channel-point intake, reconciliation, and recovery.
extension TwitchChatServiceTests {
    @Test("Bits storage failure uses one non-evicting process fallback")
    func testBitsStorageFailureUsesSingleProcessFallback() async {
        enum InjectedFailure: Error {
            case write
        }

        let directory = makeIsolatedTempDirectory(prefix: "bits-fallback")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"),
            atomicWriter: { _, _ in throw InjectedFailure.write })
        let searches = ThreadSafeBox(0)
        let music = MockAppleMusicController()
        music.searchProvider = { _ in
            searches.mutate { $0 += 1 }
            return .notFound
        }
        let chatHandler: MockURLProtocol.Handler = { request in
            (
                MockURLProtocol.httpResponse(for: request, status: 200),
                Data(#"{"data":[{"is_sent":true}]}"#.utf8)
            )
        }
        let service = TwitchChatService(
            helixHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession(handler: chatHandler)),
            redemptionResolutionOutbox: outbox)
        let defaults = DefaultsStore.store
        let statusKey = AppConstants.UserDefaults.songRequestRedemptionStatus
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestBitsEnabled)
        defaults.set(1, forKey: AppConstants.UserDefaults.songRequestBitsMinimum)
        defaults.removeObject(forKey: statusKey)
        defer {
            defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestEnabled)
            defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestBitsEnabled)
            defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestBitsMinimum)
            defaults.removeObject(forKey: statusKey)
        }

        _ = await service.configureChatSendForTesting(broadcasterID: "channel")
        await service.setSongRequestServiceReference(
            SongRequestService(musicController: music))
        await service.handleBitsUse(
            Self.bitsPayload(), eventSubMessageID: "bits-fallback")
        await service.handleBitsUse(
            Self.bitsPayload(), eventSubMessageID: "bits-fallback")
        await service.awaitPaidRedemptionTasksForTesting()
        await service.handleBitsUse(
            Self.bitsPayload(), eventSubMessageID: "bits-fallback")
        await service.awaitPaidRedemptionTasksForTesting()

        #expect(searches.value == 1)
        #expect(outbox.pendingBitsItems().isEmpty)
        #expect(
            RedemptionStatus(rawValue: defaults.string(forKey: statusKey) ?? "")
                == .storageUnavailable)
    }

    @Test("A Bits item whose acknowledgement gave up is acknowledged, not re-applied, on replay")
    func testAppliedBitsItemIsNotReappliedAfterAcknowledgementGivesUp() async throws {
        enum InjectedFailure: Error {
            case write
            case sleepCancelled
        }

        let directory = makeIsolatedTempDirectory(prefix: "bits-ack-giveup")
        defer { try? FileManager.default.removeItem(at: directory) }
        let failWrites = ThreadSafeBox(false)
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"),
            atomicWriter: { data, url in
                if failWrites.value { throw InjectedFailure.write }
                try data.write(to: url, options: .atomic)
            })
        let searches = ThreadSafeBox(0)
        let music = MockAppleMusicController()
        music.searchProvider = { _ in
            searches.mutate { $0 += 1 }
            // The first search lands after the durable intake write, so the
            // acknowledgement that follows it is the write that fails.
            failWrites.value = true
            return .notFound
        }
        let requests = SongRequestService(musicController: music)
        let chatHandler: MockURLProtocol.Handler = { request in
            (
                MockURLProtocol.httpResponse(for: request, status: 200),
                Data(#"{"data":[{"is_sent":true}]}"#.utf8)
            )
        }
        let service = TwitchChatService(
            helixHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession(handler: chatHandler)),
            redemptionResolutionOutbox: outbox)
        // A sleep that throws stands in for a cancelled acknowledgement retry.
        await service.setRedemptionResolutionSleep { _ in
            throw InjectedFailure.sleepCancelled
        }
        let defaults = DefaultsStore.store
        let statusKey = AppConstants.UserDefaults.songRequestRedemptionStatus
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestBitsEnabled)
        defaults.set(1, forKey: AppConstants.UserDefaults.songRequestBitsMinimum)
        defer {
            defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestEnabled)
            defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestBitsEnabled)
            defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestBitsMinimum)
            defaults.removeObject(forKey: statusKey)
        }

        _ = await service.configureChatSendForTesting(broadcasterID: "channel")
        await service.setSongRequestServiceReference(requests)
        await service.handleBitsUse(
            Self.bitsPayload(), eventSubMessageID: "bits-ack-giveup")
        await service.awaitPaidRedemptionTasksForTesting()

        // Applied once, but the acknowledgement never reached disk.
        #expect(searches.value == 1)
        #expect(outbox.pendingBitsItems().count == 1)
        #expect(await service.activePaidRedemptionTaskCount == 0)

        // A replay in the same process (service rewired, rejoin) must not
        // repeat the paid request, while the item stays on disk.
        await service.setSongRequestServiceReference(requests)
        await service.awaitPaidRedemptionTasksForTesting()
        #expect(searches.value == 1)
        #expect(outbox.pendingBitsItems().count == 1)

        // Once storage recovers, replay only writes the acknowledgement.
        failWrites.value = false
        await service.setSongRequestServiceReference(requests)
        await service.awaitPaidRedemptionTasksForTesting()
        #expect(searches.value == 1)
        #expect(outbox.pendingBitsItems().isEmpty)
    }

    @Test("A terminal EventSub revocation disarms wake and network reconnects")
    func testTerminalRevocationDisarmsWakeReconnect() async throws {
        Preferences.setTwitchReauthNeeded(false)
        let service = TwitchChatService()
        _ = await service.configureChatSendForTesting(broadcasterID: "channel")

        await service.handleWebSocketMessage(
            try Self.eventSubEnvelope(
                messageType: "revocation",
                messageID: "terminal-revocation",
                payload: [
                    "subscription": [
                        "type": "channel.chat.message",
                        "status": "user_removed"
                    ]
                ]))

        #expect(await service.reconnectChannelName == nil)
        #expect(await service.reconnectToken == nil)
        #expect(await service.reconnectClientID == nil)

        await service.handleSystemWake()
        #expect(await service.reconnectTask == nil)
        await service.scheduleReconnect()
        #expect(await service.reconnectTask == nil)
    }

    @Test("Bits handler ignores power-up event variants")
    func testBitsHandlerIgnoresPowerUpVariants() async {
        let directory = makeIsolatedTempDirectory(prefix: "bits-subtypes")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"))
        let searches = ThreadSafeBox(0)
        let music = MockAppleMusicController()
        music.searchProvider = { _ in
            searches.mutate { $0 += 1 }
            return .notFound
        }
        let service = TwitchChatService(redemptionResolutionOutbox: outbox)
        let defaults = DefaultsStore.store
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestBitsEnabled)
        defaults.set(1, forKey: AppConstants.UserDefaults.songRequestBitsMinimum)
        defer {
            defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestEnabled)
            defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestBitsEnabled)
            defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestBitsMinimum)
        }

        _ = await service.configureChatSendForTesting(broadcasterID: "channel")
        await service.setSongRequestServiceReference(
            SongRequestService(musicController: music))
        for type in ["power_up", "custom_power_up"] {
            await service.handleBitsUse(
                [
                    "event": [
                        "type": type,
                        "bits": 100,
                        "broadcaster_user_id": "channel",
                        "user_name": "Viewer",
                        "message": ["text": "a song"]
                    ]
                ],
                eventSubMessageID: "bits-\(type)")
        }

        #expect(searches.value == 0)
        #expect(outbox.pendingBitsItems().isEmpty)
        #expect(await service.activePaidRedemptionTaskCount == 0)
    }

    @Test("Channel-point intake keeps its processor across reconnect replay and duplicate delivery")
    func testChannelPointIntakeKeepsOwnerAcrossReconnectAndReplay() async throws {
        let directory = makeIsolatedTempDirectory(prefix: "redemption-owner")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"))
        let service = TwitchChatService(redemptionResolutionOutbox: outbox)
        let gate = DeterministicAsyncGate()
        let mutations = ThreadSafeBox(0)
        let processorWasCancelled = ThreadSafeBox(false)
        installManagedRewardIdentity()
        defer { clearManagedRewardIdentity() }

        _ = await service.configureChatSendForTesting(broadcasterID: "broadcaster")
        let intake = try outbox.enqueueIntake(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption"
        ).item
        await service.installRedemptionPipelineForTesting(item: intake) {
            await gate.suspend()
            processorWasCancelled.value = Task.isCancelled
            mutations.mutate { $0 += 1 }
            _ = try? outbox.updateResolution(intake.id, to: .fulfilled)
        }
        #expect(await waitUntil { await gate.suspended })

        // Socket invalidation used to cancel and erase the durable-intake
        // owner. Replay could then persist CANCELED while that suspended task
        // later mutated the queue and tried to fulfil the same redemption.
        _ = await service.beginConnectionAttempt()
        await service.replayPendingRedemptionResolutions()
        await service.handleChannelPointsRedemption([
            "event": [
                "id": "redemption",
                "broadcaster_user_id": "broadcaster",
                "user_name": "Viewer",
                "user_input": "A song",
                "reward": ["id": "reward"]
            ]
        ])

        #expect(outbox.pendingItems() == [intake])
        #expect(await service.activeRedemptionPipelineCountForTesting == 1)
        #expect(mutations.value == 0)

        await gate.resume()
        #expect(await waitUntil {
            await service.activeRedemptionPipelineCountForTesting == 0
        })
        #expect(!processorWasCancelled.value)
        #expect(mutations.value == 1)
        #expect(outbox.pendingItems().first?.resolution == .fulfilled)
    }

    @Test("Non-unfulfilled channel-point events skip refund claims")
    func testNonUnfulfilledEventStatusSkipsRefundClaim() async {
        let directory = makeIsolatedTempDirectory(prefix: "redemption-event-status")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"))
        let service = TwitchChatService(redemptionResolutionOutbox: outbox)
        installManagedRewardIdentity()
        defer { clearManagedRewardIdentity() }

        await service.configureBroadcasterRedemptionCredentialsForTesting(
            broadcasterID: "broadcaster")
        var payload = Self.redemptionPayload(id: "already-fulfilled")
        if var event = payload["event"] as? [String: Any] {
            event["status"] = "FULFILLED"
            payload["event"] = event
        }
        await service.handleChannelPointsRedemption(payload)

        #expect(outbox.pendingItems().isEmpty)
        #expect(await service.activeRedemptionPipelineCountForTesting == 0)
    }

    @Test("Reconciliation waits for the live queue result before resuming recovery")
    func testReconcileAwaitsInFlightPipelineBeforeUnpause() async throws {
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "token", userID: "broadcaster"))
        let directory = makeIsolatedTempDirectory(prefix: "redemption-reconcile-live")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(fileURL: directory.appending(path: "outbox.json"))
        let intake = try outbox.enqueueIntake(
            broadcasterID: "broadcaster", rewardID: "reward", redemptionID: "live").item
        let gate = DeterministicAsyncGate()
        let fetched = ThreadSafeBox(false)
        let patches = ThreadSafeBox<[String]>([])
        let handler: MockURLProtocol.Handler = { request in
            if request.httpMethod == "GET" {
                fetched.value = true
                return (MockURLProtocol.httpResponse(for: request, status: 200),
                        Data(#"{"data":[{"id":"live"}],"pagination":{}}"#.utf8))
            }
            patches.mutate { $0.append(requestBodyString(request)) }
            return (MockURLProtocol.httpResponse(for: request, status: 204), Data())
        }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(session: MockURLProtocol.makeSession(handler: handler)),
            redemptionResolutionOutbox: outbox)
        installManagedRewardIdentity()
        defer { clearManagedRewardIdentity() }
        await service.configureBroadcasterRedemptionCredentialsForTesting(broadcasterID: "broadcaster")
        await service.installRedemptionPipelineForTesting(item: intake) {
            await gate.suspend()
            _ = try? outbox.updateResolution(intake.id, to: .fulfilled)
        }
        #expect(await waitUntil { await gate.suspended })
        let recovery = Task {
            await service.reconcileManagedRewardRedemptions(
                credentials: .init(broadcasterID: "broadcaster", token: "token", clientID: "client"),
                rewardID: "reward", receiveContext: nil)
        }
        #expect(await waitUntil { fetched.value })
        await gate.resume()
        #expect(await recovery.value != nil)
        #expect(outbox.pendingItems().isEmpty)
        #expect(patches.value.contains { $0.contains(#""status":"FULFILLED""#) })
        #expect(!patches.value.contains { $0.contains(#""status":"CANCELED""#) })
    }

    @Test("Recovery does not re-enqueue an acknowledged redemption")
    func testRecoveryEnqueueSkipsAcknowledgedTombstone() async throws {
        let directory = makeIsolatedTempDirectory(prefix: "redemption-reconcile-tombstone")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(fileURL: directory.appending(path: "outbox.json"))
        let intake = try outbox.enqueueIntake(
            broadcasterID: "broadcaster", rewardID: "reward", redemptionID: "settled").item
        try outbox.acknowledge(intake.id)
        let patches = ThreadSafeBox(0)
        let handler: MockURLProtocol.Handler = { request in
            if request.httpMethod == "PATCH" { patches.mutate { $0 += 1 } }
            return (MockURLProtocol.httpResponse(for: request, status: 200),
                    Data(#"{"data":[{"id":"settled"}],"pagination":{}}"#.utf8))
        }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(session: MockURLProtocol.makeSession(handler: handler)),
            redemptionResolutionOutbox: outbox)
        installManagedRewardIdentity()
        defer { clearManagedRewardIdentity() }
        await service.configureBroadcasterRedemptionCredentialsForTesting(broadcasterID: "broadcaster")
        let result = await service.reconcileManagedRewardRedemptions(
            credentials: .init(broadcasterID: "broadcaster", token: "token", clientID: "client"),
            rewardID: "reward", receiveContext: nil)
        #expect(result != nil)
        #expect(outbox.pendingItems().isEmpty)
        #expect(patches.value == 0)
    }

    @Test("Atomic intake write failure pauses reward, exposes failure, and blocks later intake")
    func testAtomicIntakeWriteFailureFailsClosed() async {
        enum InjectedFailure: Error {
            case write
        }

        let directory = makeIsolatedTempDirectory(prefix: "redemption-write-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = ThreadSafeBox(0)
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"),
            atomicWriter: { _, _ in
                writes.mutate { $0 += 1 }
                throw InjectedFailure.write
            }
        )

        await assertRedemptionStorageFailureFailsClosed(
            outbox: outbox,
            intakeWrites: writes,
            expectedWriteAttempts: 1)
    }

    @Test("Unquarantinable redemption store pauses reward, exposes failure, and blocks intake")
    func testQuarantineFailureFailsClosed() async throws {
        enum InjectedFailure: Error {
            case quarantine
        }

        let directory = makeIsolatedTempDirectory(prefix: "redemption-quarantine-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "outbox.json")
        try Data("not-json".utf8).write(to: file, options: .atomic)
        let writes = ThreadSafeBox(0)
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: file,
            atomicWriter: { data, url in
                writes.mutate { $0 += 1 }
                try data.write(to: url, options: .atomic)
            },
            quarantineMover: { _, _ in throw InjectedFailure.quarantine }
        )

        await assertRedemptionStorageFailureFailsClosed(
            outbox: outbox,
            intakeWrites: writes,
            expectedWriteAttempts: 0)
    }

    @Test("Outcome write failure preserves the queue result while failing closed", arguments: [false, true])
    func testOutboxWriteFailureAfterQueueAddKeepsFulfilled(queueSucceeds: Bool) async {
        enum InjectedFailure: Error {
            case write
        }

        let directory = makeIsolatedTempDirectory(prefix: "redemption-outcome-failure")
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
        let defaults = DefaultsStore.store
        let statusKey = AppConstants.UserDefaults.songRequestRedemptionStatus
        installManagedRewardIdentity()
        defaults.removeObject(forKey: statusKey)
        defer {
            clearManagedRewardIdentity()
            defaults.removeObject(forKey: statusKey)
            defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestEnabled)
            defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestChannelPointsEnabled)
            defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestHoldEnabled)
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

        let music = MockAppleMusicController()
        music.stubSearchSuccess()
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestChannelPointsEnabled)
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestHoldEnabled)
        let requests = SongRequestService(musicController: music)
        if queueSucceeds {
            await service.setSongRequestServiceReference(requests)
        }
        await service.handleChannelPointsRedemption(
            Self.redemptionPayload(id: "outcome-failure"))
        await service.awaitRedemptionPipelinesForTesting()
        await service.awaitPaidRedemptionTasksForTesting()

        #expect(writes.value == 2)
        #expect(outbox.intakeStorageIsUnavailable())
        #expect(outbox.pendingItems().count == 1)
        #expect(requests.queue.count == (queueSucceeds ? 1 : 0))
        #expect(
            RedemptionStatus(rawValue: defaults.string(forKey: statusKey) ?? "")
                == .storageUnavailable)
        #expect(operations.value.contains {
            $0.url.contains("/channel_points/custom_rewards?")
                && !$0.url.contains("/redemptions")
                && $0.body.contains(#""is_paused":true"#)
        })
        #expect(operations.value.contains {
            $0.url.contains("/redemptions?")
                && $0.url.contains("id=outcome-failure")
                && $0.body.contains(queueSucceeds ? #""status":"FULFILLED""# : #""status":"CANCELED""#)
        })
    }
}
