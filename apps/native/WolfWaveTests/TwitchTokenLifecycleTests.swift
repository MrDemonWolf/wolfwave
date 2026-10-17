//
//  TwitchTokenLifecycleTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-08-12.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

// MARK: - TwitchTokenLifecycleTests

/// Covers credential persistence, OAuth validation ownership, reactive refresh,
/// token adoption, and EventSub reconnect behavior.
@MainActor
final class TwitchTokenLifecycleTests: WolfWaveTestCase {

    let handlerStore = MockURLProtocol.HandlerStore()

    override func setUp() async throws {
        // Acquires the shared-state lock (released by a teardown block) and
        // resets settings before anything below touches DefaultsStore.store.
        try await super.setUp()
        handlerStore.handler = nil
        Self.resetRedemptionDefaults()
        let previousBackend = KeychainService.backend
        KeychainService.backend = InMemoryKeychainBackend()
        // Teardown blocks run last-in-first-out, so this restores the backend
        // and clears the redemption keys before the base class releases the lock.
        let handlerStore = handlerStore
        addTeardownBlock {
            Self.resetRedemptionDefaults()
            handlerStore.handler = nil
            KeychainService.backend = previousBackend
        }
    }

    /// Removes the Song Request and managed-reward keys these tests write, so each test starts from
    /// defaults.
    nonisolated private static func resetRedemptionDefaults() {
        let defaults = DefaultsStore.store
        [
            AppConstants.UserDefaults.songRequestEnabled,
            AppConstants.UserDefaults.songRequestChannelPointsEnabled,
            AppConstants.UserDefaults.songRequestBitsEnabled,
            AppConstants.UserDefaults.songRequestChannelPointsRewardID,
            AppConstants.UserDefaults.songRequestChannelPointsRewardIdentity,
            AppConstants.UserDefaults.songRequestChannelPointsCost,
            AppConstants.UserDefaults.songRequestRedemptionStatus,
            AppConstants.UserDefaults.twitchPendingImportedChannelName
        ].forEach { defaults.removeObject(forKey: $0) }
    }

    // MARK: - attemptReactiveRefresh (persistence)

    /// A Keychain write failure while committing a new device grant must leave the
    /// previous grant (all fields) intact and its credential revision still current.
    func testAtomicDeviceGrantWriteFailurePreservesCompletePriorAccount() throws {
        let failingBackend = InspectableKeychainBackend()
        KeychainService.backend = failingBackend
        let prior = KeychainService.TwitchCredentialGrant(
            accessToken: "OLD_ACCESS",
            refreshToken: "OLD_REFRESH",
            username: "old_user",
            userID: "old_id",
            channelID: "old_channel"
        )
        try KeychainService.saveTwitchCredentialGrant(prior)
        let revision = TwitchCredentialStore.shared.supersede()
        failingBackend.failNextSave(
            for: KeychainService.twitchCredentialGrantAccount)

        XCTAssertThrowsError(
            try TwitchCredentialStore.shared.commitDeviceGrant(
                TwitchTokenResponse(
                    accessToken: "NEW_ACCESS",
                    refreshToken: "NEW_REFRESH",
                    expiresIn: nil
                ),
                expectedRevision: revision
            )
        )
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant(), prior)
        XCTAssertEqual(
            TwitchCredentialStore.shared.revision(
                matchingAccessToken: "OLD_ACCESS"),
            revision
        )
    }

    /// Cancelling OAuth mid-request (the token endpoint is held open with semaphores)
    /// restarts the token-validation schedule exactly once and leaves the prior grant untouched.
    func testOAuthReplacementCancelRestoresOnlyCurrentValidationOwner() async throws {
        let prior = KeychainService.TwitchCredentialGrant(
            accessToken: "OLD_ACCESS",
            refreshToken: "OLD_REFRESH",
            username: "old_user",
            userID: "old_id",
            channelID: "old_channel"
        )
        try KeychainService.saveTwitchCredentialGrant(prior)

        let requestEntered = DispatchSemaphore(value: 0)
        let releaseRequest = DispatchSemaphore(value: 0)
        let auth = TwitchDeviceAuth(
            clientID: "client",
            scopes: AppConstants.Twitch.allScopes,
            session: MockURLProtocol.makeSession { request in
                requestEntered.signal()
                _ = releaseRequest.wait(timeout: .now() + 2)
                return (
                    MockURLProtocol.httpResponse(for: request, status: 503),
                    Data("temporary".utf8)
                )
            }
        )
        let cancellations = ThreadSafeBox(0)
        let restarts = ThreadSafeBox(0)
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {
                cancellations.mutate { $0 += 1 }
            },
            restartTokenValidationSchedule: {
                restarts.mutate { $0 += 1 }
            },
            makeOAuthClient: { ("client", auth) }
        )

        viewModel.startOAuth()
        let flow = try XCTUnwrap(viewModel.oAuthTask)
        XCTAssertEqual(cancellations.value, 1)
        let requestDidStart = await waitForSemaphore(
            requestEntered, timeout: .now() + 2)
        XCTAssertTrue(requestDidStart)

        let cancellation = Task { @MainActor in
            await viewModel.cancelOAuth()
        }
        releaseRequest.signal()
        await cancellation.value
        await flow.value

        XCTAssertEqual(restarts.value, 1)
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant(), prior)
        XCTAssertEqual(viewModel.authState, .idle)
    }

    /// `cancelOAuth()` must not finish, or restart validation, while the account-leave
    /// step is still blocked; both happen only after the gate is released.
    func testCancelOAuthWaitsForBlockedLeaveBeforeRestoringValidation() async throws {
        let prior = KeychainService.TwitchCredentialGrant(
            accessToken: "OLD_ACCESS",
            refreshToken: "OLD_REFRESH",
            username: "old_user",
            userID: "old_id")
        try KeychainService.saveTwitchCredentialGrant(prior)
        let gate = OAuthIdentityGate()
        let cancellations = ThreadSafeBox(0)
        let restarts = ThreadSafeBox(0)
        let cancellationFinished = ThreadSafeBox(false)
        let auth = TwitchDeviceAuth(
            clientID: "client",
            scopes: AppConstants.Twitch.allScopes,
            session: MockURLProtocol.makeSession { request in
                (
                    MockURLProtocol.httpResponse(for: request, status: 503),
                    Data("temporary".utf8))
            })
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {
                cancellations.mutate { $0 += 1 }
            },
            restartTokenValidationSchedule: {
                restarts.mutate { $0 += 1 }
            },
            makeOAuthClient: { ("client", auth) },
            leaveAccountService: { _, _ in
                await gate.suspend()
                return false
            })

        viewModel.startOAuth()
        let leaveDidSuspend = await waitUntil { await gate.suspended }
        XCTAssertTrue(leaveDidSuspend)
        XCTAssertEqual(cancellations.value, 1)

        let cancellation = Task { @MainActor in
            await viewModel.cancelOAuth()
            cancellationFinished.value = true
        }
        await Task.yield()

        XCTAssertFalse(cancellationFinished.value)
        XCTAssertEqual(restarts.value, 0)
        await gate.resume()
        await cancellation.value

        XCTAssertTrue(cancellationFinished.value)
        XCTAssertEqual(restarts.value, 1)
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant(), prior)
        XCTAssertEqual(viewModel.authState, .idle)
        XCTAssertNil(viewModel.connectionError)
    }

    /// Only the window that started the flow (settings vs onboarding owner) can cancel
    /// it on close; a close from another owner returns nil and changes nothing.
    func testOnlyOwningWindowCloseCancelsOAuthAndRestoresValidation() async throws {
        let settingsOwner = TwitchViewModel.OAuthPresentationOwner.settings(UUID())
        let onboardingOwner = TwitchViewModel.OAuthPresentationOwner.onboarding(UUID())
        let prior = KeychainService.TwitchCredentialGrant(
            accessToken: "OLD_ACCESS",
            refreshToken: "OLD_REFRESH",
            username: "old_user",
            userID: "old_id"
        )
        try KeychainService.saveTwitchCredentialGrant(prior)
        let requestEntered = DispatchSemaphore(value: 0)
        let releaseRequest = DispatchSemaphore(value: 0)
        let auth = TwitchDeviceAuth(
            clientID: "client",
            scopes: AppConstants.Twitch.allScopes,
            session: MockURLProtocol.makeSession { request in
                requestEntered.signal()
                _ = releaseRequest.wait(timeout: .now() + 2)
                return (
                    MockURLProtocol.httpResponse(for: request, status: 503),
                    Data("temporary".utf8)
                )
            }
        )
        let cancellations = ThreadSafeBox(0)
        let restarts = ThreadSafeBox(0)
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {
                cancellations.mutate { $0 += 1 }
            },
            restartTokenValidationSchedule: {
                restarts.mutate { $0 += 1 }
            },
            makeOAuthClient: { ("client", auth) }
        )

        viewModel.startOAuth(owner: settingsOwner)
        let flow = try XCTUnwrap(viewModel.oAuthTask)
        XCTAssertEqual(cancellations.value, 1)
        let requestDidStart = await waitForSemaphore(
            requestEntered,
            timeout: .now() + 2
        )
        XCTAssertTrue(requestDidStart)

        XCTAssertNil(
            viewModel.requestOAuthCancellation(ifOwnedBy: onboardingOwner)
        )
        XCTAssertFalse(flow.isCancelled)
        XCTAssertEqual(restarts.value, 0)

        let close = try XCTUnwrap(
            viewModel.requestOAuthCancellation(ifOwnedBy: settingsOwner)
        )
        releaseRequest.signal()
        await close.value
        await flow.value

        XCTAssertEqual(restarts.value, 1)
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant(), prior)
        XCTAssertEqual(viewModel.authState, .idle)
    }

    /// A close queued by an old presentation must not cancel a newer flow started by a
    /// replacement owner, and the old owner can no longer request cancellation.
    func testStaleSettingsPresentationCannotCancelReplacementOAuth() async throws {
        let oldOwner = TwitchViewModel.OAuthPresentationOwner.settings(UUID())
        let replacementOwner = TwitchViewModel.OAuthPresentationOwner.settings(UUID())
        let auth = TwitchDeviceAuth(
            clientID: "client",
            scopes: AppConstants.Twitch.allScopes,
            session: MockURLProtocol.makeSession { request in
                (
                    MockURLProtocol.httpResponse(for: request, status: 503),
                    Data("temporary".utf8)
                )
            }
        )
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {},
            makeOAuthClient: { ("client", auth) }
        )

        viewModel.startOAuth(owner: oldOwner)
        let queuedOldClose = try XCTUnwrap(
            viewModel.requestOAuthCancellation(ifOwnedBy: oldOwner)
        )

        viewModel.startOAuth(owner: replacementOwner)
        let replacement = try XCTUnwrap(viewModel.oAuthTask)
        await queuedOldClose.value

        XCTAssertNil(
            viewModel.requestOAuthCancellation(ifOwnedBy: oldOwner)
        )
        XCTAssertFalse(replacement.isCancelled)
        await replacement.value
    }

    /// When the device-code request fails outright (503), validation is restarted for
    /// the surviving grant and the failure stays visible in `authState`.
    func testOAuthRequestFailureRestoresSurvivingGrantValidationOwner() async throws {
        let prior = KeychainService.TwitchCredentialGrant(
            accessToken: "OLD_ACCESS",
            refreshToken: "OLD_REFRESH",
            username: "old_user",
            userID: "old_id"
        )
        try KeychainService.saveTwitchCredentialGrant(prior)
        let auth = TwitchDeviceAuth(
            clientID: "client",
            scopes: AppConstants.Twitch.allScopes,
            session: MockURLProtocol.makeSession { request in
                (
                    MockURLProtocol.httpResponse(for: request, status: 503),
                    Data("temporary".utf8)
                )
            }
        )
        let cancellations = ThreadSafeBox(0)
        let restarts = ThreadSafeBox(0)
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {
                cancellations.mutate { $0 += 1 }
            },
            restartTokenValidationSchedule: {
                restarts.mutate { $0 += 1 }
            },
            makeOAuthClient: { ("client", auth) }
        )

        viewModel.startOAuth()
        await viewModel.oAuthTask?.value

        XCTAssertEqual(cancellations.value, 1)
        XCTAssertEqual(restarts.value, 1)
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant(), prior)
        if case .error = viewModel.authState {
            // expected
        } else {
            XCTFail("Terminal device-code failure should remain visible")
        }
    }
}
