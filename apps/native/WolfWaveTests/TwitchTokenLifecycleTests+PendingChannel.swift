//
//  TwitchTokenLifecycleTests+PendingChannel.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

/// Promoting a pending imported channel, Keychain read failure, and join teardown.
extension TwitchTokenLifecycleTests {
    /// A channel restored from backup (a pending hint in UserDefaults) is verified via
    /// Helix and committed with the new account in one record, then the hint is cleared.
    func testOAuthCommitAtomicallyPromotesPendingImportedChannel() async throws {
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "OLD_ACCESS",
                refreshToken: "OLD_REFRESH",
                username: "old_user",
                userID: "old_id",
                channelID: "old_channel"
            )
        )
        DefaultsStore.store.set(
            "  Imported_Channel  ",
            forKey: AppConstants.UserDefaults.twitchPendingImportedChannelName
        )
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {},
            resolveBotIdentity: { token, _, revision in
                guard try TwitchCredentialStore.shared.commitIdentity(
                    username: "new_user",
                    userID: "new_id",
                    matchingAccessToken: token,
                    expectedRevision: revision
                ) else {
                    throw CancellationError()
                }
            }
        )
        viewModel.twitchService = TwitchChatService(
            helixHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession { request in
                    let body =
                        #"{"data":[{"id":"channel-id","login":"imported_channel","display_name":"Imported Channel"}]}"#
                    return (
                        MockURLProtocol.httpResponse(for: request, status: 200),
                        Data(body.utf8)
                    )
                }
            )
        )
        viewModel.channelID = "visible_draft"
        let revision = TwitchCredentialStore.shared.supersede()

        await viewModel.handleOAuthSuccess(
            grant: .init(
                accessToken: "NEW_ACCESS",
                refreshToken: "NEW_REFRESH",
                expiresIn: nil
            ),
            clientID: "client",
            generation: 0,
            credentialRevision: revision
        )

        XCTAssertEqual(
            try KeychainService.loadTwitchCredentialGrantChecked(),
            .init(
                accessToken: "NEW_ACCESS",
                refreshToken: "NEW_REFRESH",
                username: "new_user",
                userID: "new_id",
                channelID: "imported_channel"
            )
        )
        XCTAssertEqual(viewModel.channelID, "imported_channel")
        XCTAssertEqual(Preferences.pendingImportedTwitchChannelName, "")
    }

    /// If Helix says the pending imported channel does not exist, the new account is
    /// committed with its old channel, the hint stays pending, and a not-found error shows.
    func testOAuthDoesNotPromoteMissingPendingChannel() async throws {
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "OLD_ACCESS",
                refreshToken: "OLD_REFRESH",
                username: "old_user",
                userID: "old_id",
                channelID: "old_channel"
            )
        )
        DefaultsStore.store.set(
            "missing_channel",
            forKey: AppConstants.UserDefaults.twitchPendingImportedChannelName
        )
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {},
            resolveBotIdentity: { token, _, revision in
                guard try TwitchCredentialStore.shared.commitIdentity(
                    username: "new_user",
                    userID: "new_id",
                    matchingAccessToken: token,
                    expectedRevision: revision
                ) else {
                    throw CancellationError()
                }
            }
        )
        viewModel.twitchService = TwitchChatService(
            helixHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession { request in
                    (
                        MockURLProtocol.httpResponse(for: request, status: 200),
                        Data(#"{"data":[]}"#.utf8)
                    )
                }
            )
        )
        let revision = TwitchCredentialStore.shared.supersede()

        await viewModel.handleOAuthSuccess(
            grant: .init(
                accessToken: "NEW_ACCESS",
                refreshToken: "NEW_REFRESH",
                expiresIn: nil
            ),
            clientID: "client",
            generation: 0,
            credentialRevision: revision
        )

        let committed = try KeychainService.loadTwitchCredentialGrantChecked()
        XCTAssertEqual(committed.accessToken, "NEW_ACCESS")
        XCTAssertEqual(committed.refreshToken, "NEW_REFRESH")
        XCTAssertEqual(committed.channelID, "old_channel")
        XCTAssertEqual(Preferences.pendingImportedTwitchChannelName, "missing_channel")
        XCTAssertEqual(viewModel.channelValidationState, .invalid)
        XCTAssertEqual(viewModel.connectionError?.id, "twitch.channelNotFound")
    }

    /// A Helix outage (503) while verifying the pending channel must not promote it: the
    /// account commits with its old channel and the hint stays pending.
    func testOAuthDoesNotPromotePendingChannelOnValidationOutage() async throws {
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "OLD_ACCESS",
                refreshToken: "OLD_REFRESH",
                username: "old_user",
                userID: "old_id",
                channelID: "old_channel"
            )
        )
        DefaultsStore.store.set(
            "pending_channel",
            forKey: AppConstants.UserDefaults.twitchPendingImportedChannelName
        )
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {},
            resolveBotIdentity: { token, _, revision in
                guard try TwitchCredentialStore.shared.commitIdentity(
                    username: "new_user",
                    userID: "new_id",
                    matchingAccessToken: token,
                    expectedRevision: revision
                ) else {
                    throw CancellationError()
                }
            }
        )
        viewModel.twitchService = TwitchChatService(
            helixHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession { request in
                    (
                        MockURLProtocol.httpResponse(for: request, status: 503),
                        Data("temporary".utf8)
                    )
                }
            )
        )
        let revision = TwitchCredentialStore.shared.supersede()

        await viewModel.handleOAuthSuccess(
            grant: .init(
                accessToken: "NEW_ACCESS",
                refreshToken: "NEW_REFRESH",
                expiresIn: nil
            ),
            clientID: "client",
            generation: 0,
            credentialRevision: revision
        )

        let committed = try KeychainService.loadTwitchCredentialGrantChecked()
        XCTAssertEqual(committed.accessToken, "NEW_ACCESS")
        XCTAssertEqual(committed.channelID, "old_channel")
        XCTAssertEqual(Preferences.pendingImportedTwitchChannelName, "pending_channel")
        // A 503 means Twitch accepted the token and could not answer, so the
        // copy now says the sign-in is fine instead of "verification failed",
        // which read as though the credentials were suspect. The safety
        // property is unchanged and asserted above: the pending channel is not
        // promoted on an outage.
        XCTAssertEqual(
            viewModel.channelValidationState,
            .error(TwitchViewModel.notPermittedMessage(status: 503))
        )
        XCTAssertEqual(viewModel.connectionError?.id, "twitch.lookupRefused")
    }

    /// If the user edits the channel while the pending one is being verified, the stale
    /// verification result is dropped: the edit wins and the old channel stays committed.
    func testOAuthDoesNotPromoteChannelChangedDuringValidation() async throws {
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "OLD_ACCESS",
                refreshToken: "OLD_REFRESH",
                username: "old_user",
                userID: "old_id",
                channelID: "old_channel"
            )
        )
        DefaultsStore.store.set(
            "first_channel",
            forKey: AppConstants.UserDefaults.twitchPendingImportedChannelName
        )
        let requestEntered = DispatchSemaphore(value: 0)
        let releaseRequest = DispatchSemaphore(value: 0)
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {},
            resolveBotIdentity: { token, _, revision in
                guard try TwitchCredentialStore.shared.commitIdentity(
                    username: "new_user",
                    userID: "new_id",
                    matchingAccessToken: token,
                    expectedRevision: revision
                ) else {
                    throw CancellationError()
                }
            }
        )
        viewModel.twitchService = TwitchChatService(
            helixHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession { request in
                    requestEntered.signal()
                    _ = releaseRequest.wait(timeout: .now() + 2)
                    let body =
                        #"{"data":[{"id":"channel-id","login":"first_channel","display_name":"First Channel"}]}"#
                    return (
                        MockURLProtocol.httpResponse(for: request, status: 200),
                        Data(body.utf8)
                    )
                }
            )
        )
        let revision = TwitchCredentialStore.shared.supersede()
        let completion = Task { @MainActor in
            await viewModel.handleOAuthSuccess(
                grant: .init(
                    accessToken: "NEW_ACCESS",
                    refreshToken: "NEW_REFRESH",
                    expiresIn: nil
                ),
                clientID: "client",
                generation: 0,
                credentialRevision: revision
            )
        }
        let requestDidStart = await waitForSemaphore(
            requestEntered,
            timeout: .now() + 2
        )
        XCTAssertTrue(requestDidStart)
        viewModel.channelID = "replacement_channel"
        viewModel.channelDraftChanged()
        releaseRequest.signal()
        _ = await completion.value

        let committed = try KeychainService.loadTwitchCredentialGrantChecked()
        XCTAssertEqual(committed.accessToken, "NEW_ACCESS")
        XCTAssertEqual(committed.channelID, "old_channel")
        XCTAssertEqual(
            Preferences.pendingImportedTwitchChannelName,
            ""
        )
        XCTAssertEqual(viewModel.channelID, "replacement_channel")
        XCTAssertEqual(viewModel.channelValidationState, .idle)
    }

    /// When the stored grant cannot be read, restoring the validation schedule errs
    /// toward restarting it (and does not cancel) instead of leaving it stopped.
    func testKeychainReadFailureConservativelyRestoresValidationOwner() throws {
        let failingBackend = InspectableKeychainBackend()
        KeychainService.backend = failingBackend
        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "ACCESS", channelID: "channel")
        )
        let cancellations = ThreadSafeBox(0)
        let restarts = ThreadSafeBox(0)
        let viewModel = TwitchViewModel(
            cancelTokenValidationSchedule: {
                cancellations.mutate { $0 += 1 }
            },
            restartTokenValidationSchedule: {
                restarts.mutate { $0 += 1 }
            }
        )
        failingBackend.failNextLoad(
            for: KeychainService.twitchCredentialGrantAccount
        )

        viewModel.restoreTokenValidationScheduleForStoredCredential()

        XCTAssertEqual(cancellations.value, 0)
        XCTAssertEqual(restarts.value, 1)
    }

    /// If the old connection cannot be torn down when switching channels, the stored
    /// channel is unchanged, the user stays signed in, and a disconnect-failed error shows.
    func testJoinTeardownFailureKeepsCanonicalChannelAndSignedInUI() async throws {
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "ACCESS",
                refreshToken: "REFRESH",
                username: "bot",
                userID: "bot-id",
                channelID: "old_channel"
            )
        )
        let validationRequests = ThreadSafeBox(0)
        let service = TwitchChatService(
            helixHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession { request in
                    validationRequests.mutate { $0 += 1 }
                    let body = #"{"data":[{"id":"new-id","login":"new_channel","display_name":"New Channel"}]}"#
                    return (
                        MockURLProtocol.httpResponse(for: request, status: 200),
                        Data(body.utf8)
                    )
                }
            )
        )
        let teardownAttempts = ThreadSafeBox(0)
        let viewModel = TwitchViewModel(
            twitchClientIDProvider: { "client" },
            leaveAccountService: { _, _ in
                teardownAttempts.mutate { $0 += 1 }
                return false
            }
        )
        viewModel.twitchService = service
        viewModel.credentialsSaved = true
        viewModel.channelID = "new_channel"

        viewModel.joinChannel()
        let finished = await waitUntil {
            await MainActor.run {
                !viewModel.isConnecting
                    && viewModel.connectionError?.id == "twitch.disconnectFailed"
            }
        }

        XCTAssertTrue(finished)
        XCTAssertEqual(validationRequests.value, 1)
        XCTAssertEqual(teardownAttempts.value, 1)
        XCTAssertEqual(viewModel.authState, .idle)
        XCTAssertEqual(viewModel.channelValidationState, .error("Could not safely disconnect"))
        XCTAssertEqual(
            try KeychainService.loadTwitchCredentialGrantChecked().channelID,
            "old_channel"
        )
    }

    /// A channel that Helix cannot find is rejected before any teardown, so the working
    /// connection and stored channel are untouched.
    func testInvalidJoinDraftNeverTearsDownOrCommitsCanonicalChannel() async throws {
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "ACCESS",
                refreshToken: "REFRESH",
                username: "bot",
                userID: "bot-id",
                channelID: "old_channel"
            )
        )
        let service = TwitchChatService(
            helixHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession { request in
                    (
                        MockURLProtocol.httpResponse(for: request, status: 200),
                        Data(#"{"data":[]}"#.utf8)
                    )
                }
            )
        )
        let teardownAttempts = ThreadSafeBox(0)
        let viewModel = TwitchViewModel(
            twitchClientIDProvider: { "client" },
            leaveAccountService: { _, _ in
                teardownAttempts.mutate { $0 += 1 }
                return true
            }
        )
        viewModel.twitchService = service
        viewModel.credentialsSaved = true
        viewModel.channelID = "missing_channel"

        viewModel.joinChannel()
        let finished = await waitUntil {
            await MainActor.run {
                !viewModel.isConnecting
                    && viewModel.channelValidationState == .invalid
            }
        }

        XCTAssertTrue(finished)
        XCTAssertEqual(teardownAttempts.value, 0)
        XCTAssertEqual(viewModel.channelValidationState, .invalid)
        XCTAssertEqual(viewModel.connectionError?.id, "twitch.channelNotFound")
        XCTAssertEqual(
            try KeychainService.loadTwitchCredentialGrantChecked().channelID,
            "old_channel"
        )
    }

    /// Join is refused with a "Finish or cancel" message while a sign-in is running (no
    /// network, teardown or pending-hint change). Once OAuth is idle, join succeeds, commits
    /// the channel, clears the pending hint, and restarts validation once.
    func testJoinWaitsForOAuthThenClearsPendingAndRestartsValidation() async throws {
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "ACCESS",
                refreshToken: "REFRESH",
                username: "bot",
                userID: "bot_id",
                channelID: "old_channel"
            )
        )
        DefaultsStore.store.set(
            "pending_channel",
            forKey: AppConstants.UserDefaults.twitchPendingImportedChannelName
        )
        let requests = ThreadSafeBox(0)
        let socketSession = URLSession(configuration: .ephemeral)
        defer { socketSession.invalidateAndCancel() }
        let socket = socketSession.webSocketTask(
            with: try XCTUnwrap(URL(string: "wss://eventsub.wss.twitch.tv/join"))
        )
        let service = TwitchChatService(
            helixHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession { request in
                    requests.mutate { $0 += 1 }
                    let body =
                        #"{"data":[{"id":"new_id","login":"new_channel","display_name":"New Channel"}]}"#
                    return (
                        MockURLProtocol.httpResponse(for: request, status: 200),
                        Data(body.utf8)
                    )
                }
            ),
            eventSubWebSocketFactory: { _ in socket },
            eventSubWebSocketResume: { _ in },
            eventSubWebSocketReceive: { _ in
                try await Task.sleep(for: .seconds(3_600))
                throw CancellationError()
            }
        )
        let restarts = ThreadSafeBox(0)
        let teardownAttempts = ThreadSafeBox(0)
        let viewModel = TwitchViewModel(
            restartTokenValidationSchedule: {
                restarts.mutate { $0 += 1 }
            },
            twitchClientIDProvider: { "client" },
            leaveAccountService: { _, _ in
                teardownAttempts.mutate { $0 += 1 }
                return true
            }
        )
        viewModel.twitchService = service
        viewModel.credentialsSaved = true
        viewModel.channelID = "new_channel"
        viewModel.authState = .requestingCode

        viewModel.joinChannel()

        XCTAssertEqual(requests.value, 0)
        XCTAssertEqual(teardownAttempts.value, 0)
        XCTAssertEqual(restarts.value, 0)
        XCTAssertEqual(Preferences.pendingImportedTwitchChannelName, "pending_channel")
        XCTAssertTrue(viewModel.progressMessage.contains("Finish or cancel"))

        viewModel.authState = .idle
        viewModel.joinChannel()
        let finished = await waitUntil(timeout: .seconds(4)) {
            await MainActor.run {
                viewModel.progressMessage == "Waiting for connection..."
            }
        }

        XCTAssertTrue(finished)
        XCTAssertEqual(requests.value, 2)
        XCTAssertEqual(teardownAttempts.value, 1)
        XCTAssertEqual(restarts.value, 1)
        XCTAssertEqual(Preferences.pendingImportedTwitchChannelName, "")
        XCTAssertEqual(
            try KeychainService.loadTwitchCredentialGrantChecked().channelID,
            "new_channel"
        )
        _ = await service.leaveChannel()
    }
}
