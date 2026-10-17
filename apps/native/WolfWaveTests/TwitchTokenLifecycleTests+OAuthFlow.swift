//
//  TwitchTokenLifecycleTests+OAuthFlow.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// OAuth flow supersession, commit, and validation-owner restoration.
extension TwitchTokenLifecycleTests {
    /// Starting a second flow while the first is in flight: the superseded flow's late
    /// completion must not restart validation over the retry (one restart total, not two).
    func testSupersededOAuthFlowCannotRestartValidationOverRetry() async throws {
        let prior = KeychainService.TwitchCredentialGrant(
            accessToken: "OLD_ACCESS",
            refreshToken: "OLD_REFRESH",
            username: "old_user",
            userID: "old_id"
        )
        try KeychainService.saveTwitchCredentialGrant(prior)

        let firstRequestEntered = DispatchSemaphore(value: 0)
        let releaseFirstRequest = DispatchSemaphore(value: 0)
        let firstAuth = TwitchDeviceAuth(
            clientID: "client",
            scopes: AppConstants.Twitch.allScopes,
            session: MockURLProtocol.makeSession { request in
                firstRequestEntered.signal()
                _ = releaseFirstRequest.wait(timeout: .now() + 2)
                return (
                    MockURLProtocol.httpResponse(for: request, status: 503),
                    Data("first".utf8)
                )
            }
        )
        let secondAuth = TwitchDeviceAuth(
            clientID: "client",
            scopes: AppConstants.Twitch.allScopes,
            session: MockURLProtocol.makeSession { request in
                (
                    MockURLProtocol.httpResponse(for: request, status: 503),
                    Data("second".utf8)
                )
            }
        )
        let factoryCalls = ThreadSafeBox(0)
        let cancellations = ThreadSafeBox(0)
        let restarts = ThreadSafeBox(0)
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {
                cancellations.mutate { $0 += 1 }
            },
            restartTokenValidationSchedule: {
                restarts.mutate { $0 += 1 }
            },
            makeOAuthClient: {
                let call = factoryCalls.value
                factoryCalls.set(call + 1)
                return ("client", call == 0 ? firstAuth : secondAuth)
            }
        )

        viewModel.startOAuth()
        let firstFlow = try XCTUnwrap(viewModel.oAuthTask)
        let firstRequestDidStart = await waitForSemaphore(
            firstRequestEntered, timeout: .now() + 2)
        XCTAssertTrue(firstRequestDidStart)

        viewModel.startOAuth()
        let secondFlow = try XCTUnwrap(viewModel.oAuthTask)
        releaseFirstRequest.signal()
        await firstFlow.value
        await secondFlow.value

        XCTAssertEqual(cancellations.value, 2)
        XCTAssertEqual(restarts.value, 1)
        XCTAssertEqual(factoryCalls.value, 2)
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant(), prior)
    }

    /// A full successful device flow stores the grant and identity and ends with one
    /// validation restart.
    func testSuccessfulOAuthFlowInstallsSingleValidationOwner() async throws {
        let requests = ThreadSafeBox(0)
        let auth = TwitchDeviceAuth(
            clientID: "client",
            scopes: AppConstants.Twitch.allScopes,
            session: MockURLProtocol.makeSession { request in
                requests.mutate { $0 += 1 }
                if request.url?.absoluteString == AppConstants.API.twitchOAuthDevice {
                    let json = #"""
                    {"device_code":"DEV","user_code":"CODE",
                     "verification_uri":"https://twitch.tv/activate",
                     "expires_in":600,"interval":1}
                    """#
                    return (
                        MockURLProtocol.httpResponse(for: request, status: 200),
                        Data(json.utf8)
                    )
                }
                let json = #"{"access_token":"ACCESS","refresh_token":"REFRESH"}"#
                return (
                    MockURLProtocol.httpResponse(for: request, status: 200),
                    Data(json.utf8)
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
            makeOAuthClient: { ("client", auth) },
            resolveBotIdentity: { token, _, revision in
                _ = try TwitchCredentialStore.shared.commitIdentity(
                    username: "wolfwave",
                    userID: "broadcaster",
                    matchingAccessToken: token,
                    expectedRevision: revision
                )
            }
        )

        viewModel.startOAuth()
        let flow = try XCTUnwrap(viewModel.oAuthTask)
        await flow.value

        XCTAssertEqual(requests.value, 2)
        XCTAssertEqual(cancellations.value, 2)
        XCTAssertEqual(restarts.value, 1)
        XCTAssertEqual(KeychainService.loadTwitchToken(), "ACCESS")
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant().refreshToken, "REFRESH")
        XCTAssertEqual(viewModel.botUsername, "wolfwave")
        XCTAssertEqual(viewModel.authState, .idle)
    }

    /// Validation restarts as soon as the grant is committed, so a later identity-lookup
    /// failure still leaves the stored grant covered and the error visible.
    func testOAuthCommitRestartsValidationBeforeIdentityFailure() async throws {
        enum IdentityFailure: Error {
            case injected
        }

        let restarts = ThreadSafeBox(0)
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {
                restarts.mutate { $0 += 1 }
            },
            resolveBotIdentity: { _, _, _ in
                throw IdentityFailure.injected
            }
        )
        let revision = TwitchCredentialStore.shared.supersede()
        await viewModel.handleOAuthSuccess(
            grant: TwitchTokenResponse(
                accessToken: "ACCESS",
                refreshToken: "REFRESH",
                expiresIn: nil
            ),
            clientID: "client",
            generation: 0,
            credentialRevision: revision
        )

        XCTAssertEqual(restarts.value, 1)
        XCTAssertEqual(KeychainService.loadTwitchToken(), "ACCESS")
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant().refreshToken, "REFRESH")
        if case .error = viewModel.authState {
            // expected
        } else {
            XCTFail("Identity failure should remain visible to the user")
        }
    }

    /// Cancelling the task while the identity lookup is suspended must not restart
    /// validation again or discard the already-committed grant.
    func testOAuthCommitKeepsValidationOwnerWhenIdentityTaskIsCancelled() async throws {
        let restarts = ThreadSafeBox(0)
        let gate = OAuthIdentityGate()
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {
                restarts.mutate { $0 += 1 }
            },
            resolveBotIdentity: { _, _, _ in
                await gate.suspend()
                try Task.checkCancellation()
            }
        )
        let revision = TwitchCredentialStore.shared.supersede()
        let completion = Task { @MainActor in
            await viewModel.handleOAuthSuccess(
                grant: TwitchTokenResponse(
                    accessToken: "ACCESS",
                    refreshToken: "REFRESH",
                    expiresIn: nil
                ),
                clientID: "client",
                generation: 0,
                credentialRevision: revision
            )
        }

        let identityLookupSuspended = await waitUntil { await gate.suspended }
        XCTAssertTrue(identityLookupSuspended)
        XCTAssertEqual(restarts.value, 1)
        XCTAssertEqual(KeychainService.loadTwitchToken(), "ACCESS")
        completion.cancel()
        await gate.resume()
        _ = await completion.value

        XCTAssertEqual(restarts.value, 1)
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant().accessToken, "ACCESS")
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant().refreshToken, "REFRESH")
    }

    /// Once the grant is committed, closing the owning window can no longer cancel the
    /// flow (cancellation returns nil), so the in-flight identity lookup completes and is stored.
    func testWindowCloseAfterGrantCommitAllowsIdentityToFinish() async throws {
        let settingsOwner = TwitchViewModel.OAuthPresentationOwner.settings(UUID())
        let auth = TwitchDeviceAuth(
            clientID: "client",
            scopes: AppConstants.Twitch.allScopes,
            session: MockURLProtocol.makeSession { request in
                if request.url?.absoluteString == AppConstants.API.twitchOAuthDevice {
                    let body = #"""
                    {"device_code":"DEV","user_code":"CODE",
                     "verification_uri":"https://twitch.tv/activate",
                     "expires_in":600,"interval":1}
                    """#
                    return (
                        MockURLProtocol.httpResponse(for: request, status: 200),
                        Data(body.utf8)
                    )
                }
                return (
                    MockURLProtocol.httpResponse(for: request, status: 200),
                    Data(#"{"access_token":"ACCESS","refresh_token":"REFRESH"}"#.utf8)
                )
            }
        )
        let gate = OAuthIdentityGate()
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {},
            makeOAuthClient: { ("client", auth) },
            resolveBotIdentity: { token, _, revision in
                await gate.suspend()
                guard try TwitchCredentialStore.shared.commitIdentity(
                    username: "wolfwave",
                    userID: "broadcaster",
                    matchingAccessToken: token,
                    expectedRevision: revision
                ) else {
                    throw CancellationError()
                }
            }
        )

        viewModel.startOAuth(owner: settingsOwner)
        let flow = try XCTUnwrap(viewModel.oAuthTask)
        let identityLookupSuspended = await waitUntil { await gate.suspended }
        XCTAssertTrue(identityLookupSuspended)
        XCTAssertNil(
            viewModel.requestOAuthCancellation(ifOwnedBy: settingsOwner)
        )

        await gate.resume()
        await flow.value

        let stored = try KeychainService.loadTwitchCredentialGrantChecked()
        XCTAssertEqual(stored.username, "wolfwave")
        XCTAssertEqual(stored.userID, "broadcaster")
        XCTAssertEqual(viewModel.botUsername, "wolfwave")
        XCTAssertTrue(viewModel.credentialsSaved)
        XCTAssertEqual(viewModel.authState, .idle)
    }

    /// If committing the new grant fails, the prior grant is kept, no identity lookup
    /// runs, and the pending imported channel hint is not consumed.
    func testOAuthCommitFailureRestoresPriorGrantValidationOwner() async throws {
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
        DefaultsStore.store.set(
            "imported_channel",
            forKey: AppConstants.UserDefaults.twitchPendingImportedChannelName
        )
        failingBackend.failNextSave(
            for: KeychainService.twitchCredentialGrantAccount)
        let restarts = ThreadSafeBox(0)
        let identityCalls = ThreadSafeBox(0)
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {
                restarts.mutate { $0 += 1 }
            },
            resolveBotIdentity: { _, _, _ in
                identityCalls.mutate { $0 += 1 }
            }
        )
        let revision = TwitchCredentialStore.shared.supersede()

        await viewModel.handleOAuthSuccess(
            grant: TwitchTokenResponse(
                accessToken: "NEW_ACCESS",
                refreshToken: "NEW_REFRESH",
                expiresIn: nil
            ),
            clientID: "client",
            generation: 0,
            credentialRevision: revision
        )

        XCTAssertEqual(restarts.value, 1)
        XCTAssertEqual(identityCalls.value, 0)
        XCTAssertEqual(KeychainService.loadTwitchCredentialGrant(), prior)
        XCTAssertEqual(
            Preferences.pendingImportedTwitchChannelName,
            "imported_channel"
        )
    }
}
