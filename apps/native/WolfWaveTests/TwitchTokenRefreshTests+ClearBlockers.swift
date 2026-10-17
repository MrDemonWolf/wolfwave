//
//  TwitchTokenRefreshTests+ClearBlockers.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// Credential clear versus in-flight redemption work, teardown ordering, and opaque outbox risk.
extension TwitchTokenRefreshTests {
    /// A persisted refund that is still retrying (Helix keeps returning 503, the retry sleep
    /// is cancelled) blocks sign-out and stays in the outbox.
    func testRetryingPersistedRedemptionBlocksCredentialClear() async throws {
        storeManagedRewardIdentity(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "ACCESS",
                refreshToken: "REFRESH",
                username: "wolf",
                userID: "broadcaster"))
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-retrying-outbox-teardown")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"))
        _ = try outbox.enqueue(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption",
            resolution: .canceled)
        let handler: MockURLProtocol.Handler = { request in
            let body = Self.bodyString(of: request)
            let status = body.contains(#""status":"CANCELED""#) ? 503 : 204
            return (
                MockURLProtocol.httpResponse(for: request, status: status),
                Data())
        }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: handler)),
            redemptionResolutionOutbox: outbox,
            redemptionClientIDProvider: { "client" })
        await service.configureManagedRedemptionSessionForTesting()
        await service.setRedemptionResolutionSleep { _ in
            throw CancellationError()
        }
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {})
        viewModel.twitchService = service

        let cleared = await viewModel.clearCredentials()

        XCTAssertFalse(cleared)
        XCTAssertEqual(KeychainService.loadTwitchToken(), "ACCESS")
        XCTAssertEqual(outbox.pendingItems().count, 1)
    }

    /// Sign-out waits for an in-flight live intake task to settle, then drains the
    /// resulting refund before deleting credentials. Checked by holding the intake open
    /// and confirming the clear has not finished.
    func testLiveRedemptionIntakeSettlesAndDrainsBeforeCredentialClear() async throws {
        storeManagedRewardIdentity(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "ACCESS",
                refreshToken: "REFRESH",
                username: "wolf",
                userID: "broadcaster"))
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-live-intake-teardown")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"))
        let intake = try outbox.enqueueIntake(
            broadcasterID: "broadcaster",
            rewardID: "reward",
            redemptionID: "redemption").item
        let requests = ThreadSafeBox<[String]>([])
        let handler: MockURLProtocol.Handler = { request in
            if let response = Self.emptyUnfulfilledRedemptionsResponse(
                for: request) {
                return response
            }
            requests.mutate { $0.append(Self.bodyString(of: request)) }
            return (
                MockURLProtocol.httpResponse(for: request, status: 204),
                Data())
        }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: handler)),
            redemptionResolutionOutbox: outbox,
            redemptionClientIDProvider: { "client" })
        await service.configureManagedRedemptionSessionForTesting()
        let intakeGate = OAuthIdentityGate()
        await service.installTeardownLiveIntakeForTesting(item: intake) {
            await intakeGate.suspend()
            _ = try? outbox.updateResolution(intake.id, to: .canceled)
        }
        let intakeDidSuspend = await waitUntil { await intakeGate.suspended }
        XCTAssertTrue(intakeDidSuspend)

        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {})
        viewModel.twitchService = service
        let clearResult = ThreadSafeBox<Bool?>(nil)
        let clearing = Task { @MainActor in
            clearResult.value = await viewModel.clearCredentials()
        }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(clearResult.value)
        XCTAssertEqual(KeychainService.loadTwitchToken(), "ACCESS")

        await intakeGate.resume()
        await clearing.value

        XCTAssertEqual(clearResult.value, true)
        XCTAssertNil(KeychainService.loadTwitchToken())
        XCTAssertTrue(outbox.pendingItems().isEmpty)
        XCTAssertTrue(requests.value.contains {
            $0.contains(#""status":"CANCELED""#)
        })
    }

    /// A setup-time unpause still in flight must finish before the teardown pause is sent
    /// (operations are exactly `["unpause", "pause"]`), so the reward cannot end up unpaused after
    /// sign-out.
    func testDelayedSetupUnpauseCompletesBeforeFinalTeardownPause() async throws {
        storeManagedRewardIdentity(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "ACCESS",
                refreshToken: "REFRESH",
                username: "wolf",
                userID: "broadcaster"))
        let unpauseEntered = DispatchSemaphore(value: 0)
        let releaseUnpause = DispatchSemaphore(value: 0)
        let operations = ThreadSafeBox<[String]>([])
        let handler: MockURLProtocol.Handler = { request in
            if let response = Self.emptyUnfulfilledRedemptionsResponse(
                for: request) {
                return response
            }
            let body = Self.bodyString(of: request)
            if body.contains(#""is_paused":false"#) {
                operations.mutate { $0.append("unpause") }
                unpauseEntered.signal()
                guard releaseUnpause.wait(timeout: .now() + 2) == .success else {
                    throw URLError(.timedOut)
                }
            } else if body.contains(#""is_paused":true"#) {
                operations.mutate { $0.append("pause") }
            }
            return (
                MockURLProtocol.httpResponse(for: request, status: 204),
                Data())
        }
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-setup-teardown-order")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: handler)),
            redemptionResolutionOutbox: TwitchRedemptionResolutionOutbox(
                fileURL: directory.appending(path: "outbox.json")),
            redemptionClientIDProvider: { "client" })
        await service.configureManagedRedemptionSessionForTesting()
        let unpausing = Task {
            try await service.runManagedRewardUnpauseUnderSetupLeaseForTesting(
                rewardID: "reward")
        }
        let unpauseDidStart = await waitForSemaphore(
            unpauseEntered,
            timeout: .now() + 2)
        XCTAssertTrue(unpauseDidStart)

        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {})
        viewModel.twitchService = service
        let clearing = Task { @MainActor in
            await viewModel.clearCredentials()
        }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(operations.value, ["unpause"])
        XCTAssertEqual(KeychainService.loadTwitchToken(), "ACCESS")

        releaseUnpause.signal()
        try await unpausing.value
        let cleared = await clearing.value

        XCTAssertTrue(cleared)
        XCTAssertEqual(operations.value, ["unpause", "pause"])
        XCTAssertNil(KeychainService.loadTwitchToken())
    }

    /// A redemption whose first outbox write failed and whose refund call fails is held in
    /// memory and retried; sign-out is refused until that retry succeeds, then allowed.
    func testFailedUnpersistedRefundBlocksClearUntilRetrySettles() async throws {
        storeManagedRewardIdentity(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "ACCESS",
                refreshToken: "REFRESH",
                username: "wolf",
                userID: "broadcaster"))
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-containment-teardown")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writeAttempts = ThreadSafeBox(0)
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: directory.appending(path: "outbox.json"),
            atomicWriter: { data, url in
                var attempt = 0
                writeAttempts.mutate {
                    $0 += 1
                    attempt = $0
                }
                if attempt == 1 {
                    throw URLError(.cannotWriteToFile)
                }
                try data.write(to: url, options: .atomic)
            })
        let refundFails = ThreadSafeBox(true)
        let handler: MockURLProtocol.Handler = { request in
            if let response = Self.emptyUnfulfilledRedemptionsResponse(
                for: request) {
                return response
            }
            let body = Self.bodyString(of: request)
            let isRefund = body.contains(#""status":"CANCELED""#)
            let status = isRefund && refundFails.value ? 500 : 204
            return (
                MockURLProtocol.httpResponse(for: request, status: status),
                Data())
        }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: handler)),
            redemptionResolutionOutbox: outbox,
            redemptionClientIDProvider: { "client" })
        await service.configureManagedRedemptionSessionForTesting()
        let retryGate = OAuthIdentityGate()
        await service.setRedemptionResolutionSleep { _ in
            await retryGate.suspend()
        }
        await service.handleChannelPointsRedemption([
            "event": [
                "id": "redemption",
                "broadcaster_user_id": "broadcaster",
                "user_name": "Viewer",
                "user_input": "A song",
                "reward": ["id": "reward"]
            ]
        ])
        let retryDidSuspend = await waitUntil { await retryGate.suspended }
        XCTAssertTrue(retryDidSuspend)

        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {})
        viewModel.twitchService = service

        let firstClear = await viewModel.clearCredentials()

        XCTAssertFalse(firstClear)
        XCTAssertEqual(KeychainService.loadTwitchToken(), "ACCESS")

        refundFails.value = false
        await retryGate.resume()
        await service.awaitPaidRedemptionTasksForTeardownTesting()
        let secondClear = await viewModel.clearCredentials()

        XCTAssertTrue(secondClear)
        XCTAssertNil(KeychainService.loadTwitchToken())
    }

    /// A corrupt outbox that cannot be quarantined blocks a normal sign-out (the reward is still
    /// paused), but a factory reset (`discardOpaqueRedemptionRecovery: true`) may discard it.
    func testOpaqueOutboxRiskBlocksNormalClearButFactoryOverrideCanDiscard()
        async throws {
        storeManagedRewardIdentity(rewardID: "reward")
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "ACCESS",
                refreshToken: "REFRESH",
                username: "wolf",
                userID: "broadcaster"))
        enum InjectedFailure: Error {
            case quarantine
        }
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-opaque-teardown")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "outbox.json")
        try Data("not-json".utf8).write(to: file, options: .atomic)
        let outbox = TwitchRedemptionResolutionOutbox(
            fileURL: file,
            quarantineMover: { _, _ in throw InjectedFailure.quarantine })
        XCTAssertTrue(outbox.hasOpaqueRecoveryRisk())
        let pauses = ThreadSafeBox(0)
        let handler: MockURLProtocol.Handler = { request in
            if let response = Self.emptyUnfulfilledRedemptionsResponse(
                for: request) {
                return response
            }
            pauses.mutate { $0 += 1 }
            return (
                MockURLProtocol.httpResponse(for: request, status: 204),
                Data())
        }
        let service = TwitchChatService(
            channelPointsService: TwitchChannelPointsService(
                session: MockURLProtocol.makeSession(handler: handler)),
            redemptionResolutionOutbox: outbox,
            redemptionClientIDProvider: { "client" })
        await service.configureManagedRedemptionSessionForTesting()
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {})
        viewModel.twitchService = service

        let normalClear = await viewModel.clearCredentials()

        XCTAssertFalse(normalClear)
        XCTAssertEqual(KeychainService.loadTwitchToken(), "ACCESS")
        XCTAssertEqual(pauses.value, 1)

        let factoryClear = await viewModel.clearCredentials(
            discardOpaqueRedemptionRecovery: true)

        XCTAssertTrue(factoryClear)
        XCTAssertNil(KeychainService.loadTwitchToken())
        XCTAssertEqual(pauses.value, 2)
    }

    /// With no credentials and no reward, an unquarantinable corrupt outbox must still not
    /// be reported safe to tear down.
    func testCredentiallessNoRewardOpaqueOutboxCannotReportSafe() async throws {
        enum InjectedFailure: Error {
            case quarantine
        }
        let directory = makeIsolatedTempDirectory(prefix: "wolfwave-opaque-fast-path")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "outbox.json")
        try Data("not-json".utf8).write(to: file, options: .atomic)
        let service = TwitchChatService(
            redemptionResolutionOutbox: TwitchRedemptionResolutionOutbox(
                fileURL: file,
                quarantineMover: { _, _ in throw InjectedFailure.quarantine }))

        let safe = await service.pauseManagedRewardBeforeCredentialTeardown()

        XCTAssertFalse(safe)
    }
}
