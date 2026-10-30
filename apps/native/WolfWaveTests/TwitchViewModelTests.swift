//
//  TwitchViewModelTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-02-13.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation
import SwiftUI
@testable import WolfWave

/// Comprehensive test suite for TwitchViewModel
@Suite("Twitch ViewModel Tests")
@MainActor
struct TwitchViewModelTests {
    
    // MARK: - Initialization Tests
    
    @Test("ViewModel initializes with default state")
    func testInitialization() async throws {
        let viewModel = TwitchViewModel()
        
        #expect(viewModel.botUsername == "")
        #expect(viewModel.oauthToken == "")
        #expect(viewModel.channelID == "")
        #expect(viewModel.credentialsSaved == false)
        #expect(viewModel.channelConnected == false)
        #expect(viewModel.isConnecting == false)
        #expect(viewModel.reauthNeeded == false)
        #expect(viewModel.progressMessage == "")
        #expect(viewModel.channelValidationState == .idle)
        #expect(viewModel.authState == .idle)
    }
    
    // MARK: - Auth State Tests
    
    @Test("Auth state isInProgress computed property works")
    func testAuthStateIsInProgress() async throws {
        let viewModel = TwitchViewModel()
        
        // Idle should not be in progress
        viewModel.authState = .idle
        #expect(!viewModel.authState.isInProgress)
        
        // Requesting code should be in progress
        viewModel.authState = .requestingCode
        #expect(viewModel.authState.isInProgress)
        
        // Waiting for auth should be in progress
        viewModel.authState = .waitingForAuth(userCode: "ABC123", verificationURI: "https://twitch.tv/activate")
        #expect(viewModel.authState.isInProgress)
        
        // In progress should be in progress
        viewModel.authState = .inProgress
        #expect(viewModel.authState.isInProgress)
        
        // Error should not be in progress
        viewModel.authState = .error("Test error")
        #expect(!viewModel.authState.isInProgress)
    }
    
    @Test("Auth state userCode extraction works")
    func testAuthStateUserCode() async throws {
        let viewModel = TwitchViewModel()
        
        // No user code when idle
        viewModel.authState = .idle
        #expect(viewModel.authState.userCode == "")
        
        // User code present when waiting
        viewModel.authState = .waitingForAuth(userCode: "ABCD-1234", verificationURI: "https://twitch.tv/activate")
        #expect(viewModel.authState.userCode == "ABCD-1234")
        
        // No user code in error state
        viewModel.authState = .error("Test error")
        #expect(viewModel.authState.userCode == "")
    }
    
    // MARK: - Integration State Tests
    
    @Test("Integration state reflects connection status")
    func testIntegrationStateConnected() async throws {
        let viewModel = TwitchViewModel()
        
        // Not connected initially
        switch viewModel.integrationState {
        case .notConnected:
            #expect(true)
        default:
            Issue.record("Expected notConnected state")
        }
        
        // Connected when channel is connected
        viewModel.channelConnected = true
        switch viewModel.integrationState {
        case .connected:
            #expect(true)
        default:
            Issue.record("Expected connected state")
        }
    }
    
    @Test("Integration state reflects auth progress")
    func testIntegrationStateAuthorizing() async throws {
        let viewModel = TwitchViewModel()
        
        // Authorizing when requesting code
        viewModel.authState = .requestingCode
        switch viewModel.integrationState {
        case .authorizing:
            #expect(true)
        default:
            Issue.record("Expected authorizing state")
        }
        
        // Authorizing when waiting for auth
        viewModel.authState = .waitingForAuth(userCode: "ABC", verificationURI: "https://test.com")
        switch viewModel.integrationState {
        case .authorizing:
            #expect(true)
        default:
            Issue.record("Expected authorizing state")
        }
    }
    
    @Test("Integration state reflects errors")
    func testIntegrationStateError() async throws {
        let viewModel = TwitchViewModel()
        
        viewModel.authState = .error("Test error message")
        
        switch viewModel.integrationState {
        case .error(let message):
            #expect(message == "Test error message")
        default:
            Issue.record("Expected error state")
        }
    }
    
    // MARK: - Status Chip Tests
    
    @Test("Status chip text reflects state")
    func testStatusChipText() async throws {
        let viewModel = TwitchViewModel()
        
        // Not signed in
        #expect(viewModel.statusChipText == "Not signed in")
        
        // Signed in
        viewModel.credentialsSaved = true
        #expect(viewModel.statusChipText == "Signed in")
        
        // Connected
        viewModel.channelConnected = true
        #expect(viewModel.statusChipText == "Connected")
        
        // Reauth needed (highest priority)
        viewModel.reauthNeeded = true
        #expect(viewModel.statusChipText == "Sign-in expired")
    }
    
    @Test("Status chip color reflects state")
    func testStatusChipColor() async throws {
        let viewModel = TwitchViewModel()
        
        // Not signed in = neutral, at full strength (StatusChip washes it to 10%)
        #expect(viewModel.statusChipColor == DSColor.neutral)
        
        // Signed in but not joined = info
        viewModel.credentialsSaved = true
        #expect(viewModel.statusChipColor == DSColor.info)
        
        // Connected = success
        viewModel.channelConnected = true
        #expect(viewModel.statusChipColor == DSColor.success)
        
        // Reauth needed = warning (highest priority)
        viewModel.reauthNeeded = true
        #expect(viewModel.statusChipColor == DSColor.warning)
    }
    
    // MARK: - Channel Validation State Tests
    
    @Test("Channel validation state enum equality works")
    func testChannelValidationStateEquality() async throws {
        #expect(TwitchViewModel.ChannelValidationState.idle == .idle)
        #expect(TwitchViewModel.ChannelValidationState.validating == .validating)
        #expect(TwitchViewModel.ChannelValidationState.valid == .valid)
        #expect(TwitchViewModel.ChannelValidationState.invalid == .invalid)
        #expect(TwitchViewModel.ChannelValidationState.error("msg1") == .error("msg1"))
        #expect(TwitchViewModel.ChannelValidationState.error("msg1") != .error("msg2"))
    }
    
    @Test("Temporary token validation failure preserves credentials and reauth state")
    func testTemporaryValidationFailurePreservesSession() async {
        await SharedTestStateIsolation.withIsolatedSharedState {
            let viewModel = TwitchViewModel()
            viewModel.oauthToken = "stored-token"
            viewModel.botUsername = "stored-bot"
            viewModel.credentialsSaved = true
            viewModel.reauthNeeded = false

            viewModel.applyTokenValidationResult(.temporarilyUnavailable)

            #expect(viewModel.oauthToken == "stored-token")
            #expect(viewModel.botUsername == "stored-bot")
            #expect(viewModel.credentialsSaved)
            #expect(!viewModel.reauthNeeded)
        }
    }

    @Test("Only definitive token invalidation sets reauth")
    func testDefinitiveValidationFailureSetsReauth() async {
        await SharedTestStateIsolation.withIsolatedSharedState {
            let viewModel = TwitchViewModel()
            viewModel.credentialsSaved = true

            viewModel.applyTokenValidationResult(.valid)
            #expect(!viewModel.reauthNeeded)

            viewModel.applyTokenValidationResult(.invalid)
            #expect(viewModel.reauthNeeded)
            #expect(viewModel.credentialsSaved)
        }
    }

    // MARK: - Clear Credentials Tests
    
    @Test("Clear credentials resets all state")
    func testClearCredentials() async throws {
        await SharedTestStateIsolation.withIsolatedSharedState {
            let viewModel = TwitchViewModel()

            // Set some state
            viewModel.botUsername = "testbot"
            viewModel.oauthToken = "test_token"
            viewModel.channelID = "testchannel"
            viewModel.credentialsSaved = true
            viewModel.reauthNeeded = true
            viewModel.progressMessage = "Test status"
            viewModel.authState = .inProgress
            viewModel.channelValidationState = .valid

            // Clear credentials
            await viewModel.clearCredentials()

            // Verify all state is reset
            #expect(viewModel.botUsername == "")
            #expect(viewModel.oauthToken == "")
            #expect(viewModel.channelID == "")
            #expect(viewModel.credentialsSaved == false)
            #expect(viewModel.reauthNeeded == false)
            #expect(viewModel.progressMessage == "")
            #expect(viewModel.authState == .idle)
            #expect(viewModel.channelValidationState == .idle)
        }
    }

    @Test("clearAuthOnly preserves channel ID")
    func testClearAuthOnlyPreservesChannelID() async {
        await SharedTestStateIsolation.withIsolatedSharedState {
            let viewModel = TwitchViewModel()

            viewModel.botUsername = "testbot"
            viewModel.oauthToken = "token123"
            viewModel.channelID = "mrdemonwolf"
            viewModel.credentialsSaved = true
            viewModel.reauthNeeded = true
            viewModel.progressMessage = "Test status"
            viewModel.authState = .inProgress
            viewModel.channelValidationState = .valid

            await viewModel.clearAuthOnly()

            #expect(viewModel.channelID == "mrdemonwolf")
            #expect(viewModel.botUsername == "")
            #expect(viewModel.oauthToken == "")
            #expect(viewModel.credentialsSaved == false)
            #expect(viewModel.reauthNeeded == false)
            #expect(viewModel.progressMessage == "")
            #expect(viewModel.authState == .idle)
            #expect(viewModel.channelValidationState == .idle)
        }
    }

    // MARK: - Cancel OAuth Tests
    
    @Test("Cancel OAuth resets state")
    func testCancelOAuth() async throws {
        let viewModel = TwitchViewModel()
        
        viewModel.authState = .waitingForAuth(userCode: "ABC123", verificationURI: "https://test.com")
        viewModel.progressMessage = "Waiting for auth..."
        
        await viewModel.cancelOAuth()
        
        #expect(viewModel.authState == .idle)
        #expect(viewModel.progressMessage == "")
    }
}

// MARK: - Sign-in Flow Clarity

/// Pure copy and routing helpers behind the Twitch pane's sign-in flow.
@Suite("Twitch ViewModel sign-in helpers")
@MainActor
struct TwitchViewModelSignInHelperTests {

    @Test("Expiry text rounds up to whole minutes and hides once expired")
    func deviceCodeExpiryText() {
        #expect(TwitchViewModel.deviceCodeExpiryText(remaining: 600) == "Expires in about 10 min")
        #expect(TwitchViewModel.deviceCodeExpiryText(remaining: 61) == "Expires in about 2 min")
        #expect(TwitchViewModel.deviceCodeExpiryText(remaining: 5) == "Expires in about 1 min")
        #expect(TwitchViewModel.deviceCodeExpiryText(remaining: 0) == nil)
        #expect(TwitchViewModel.deviceCodeExpiryText(remaining: -30) == nil)
    }

    @Test("Try Again re-runs the work the failure was about")
    func retryTargetRouting() {
        #expect(TwitchViewModel.retryTarget(for: TwitchViewModel.Failure.oauth("declined")) == .signIn)
        #expect(TwitchViewModel.retryTarget(for: TwitchViewModel.Failure.deviceCodeExpired()) == .signIn)
        #expect(TwitchViewModel.retryTarget(for: TwitchViewModel.Failure.credentialClearFailed()) == .signOut)
        // A channel change that couldn't leave the old channel retries the join.
        #expect(TwitchViewModel.retryTarget(for: TwitchViewModel.Failure.disconnectFailed()) == .joinChannel)
        // A sign-out that couldn't disconnect retries the sign-out: it must
        // never rejoin and put the account being removed back online.
        #expect(
            TwitchViewModel.retryTarget(for: TwitchViewModel.Failure.signOutDisconnectFailed()) == .signOut)
        // An account switch or re-auth that couldn't disconnect signs in again.
        #expect(
            TwitchViewModel.retryTarget(for: TwitchViewModel.Failure.accountSwitchDisconnectFailed()) == .signIn)
        #expect(
            TwitchViewModel.retryTarget(for: TwitchViewModel.Failure.connectionFailed("boom")) == .joinChannel)
        // A Keychain read that failed reads it again. Joining instead checks
        // the channel field, which is still empty, and blames the channel name.
        #expect(
            TwitchViewModel.retryTarget(for: TwitchViewModel.Failure.keychainUnreadable()) == .reloadCredentials)
    }

    @Test("An expired code offers a fresh sign-in, not a generic failure")
    func expiredCodeFailure() {
        let failure = TwitchViewModel.Failure.deviceCodeExpired()
        #expect(failure.id == "twitch.deviceCodeExpired")
        #expect(failure.actions == [.retry])
        #expect(failure.severity == .warning)
    }
}

/// Drives `startOAuth()` against a stubbed device-code endpoint. Holds the
/// shared-state lock because the flow touches the Keychain seam and the
/// process-wide credential revision.
@Suite("Twitch ViewModel OAuth start", .isolatedSharedTestState)
@MainActor
struct TwitchViewModelOAuthStartTests {

    /// Device-code endpoint answers with a 10-minute code; the token endpoint
    /// keeps saying "authorization pending" so the flow parks in
    /// `.waitingForAuth` until the test cancels it.
    private func makeViewModel() -> TwitchViewModel {
        let auth = TwitchDeviceAuth(
            clientID: "client",
            scopes: AppConstants.Twitch.allScopes,
            session: MockURLProtocol.makeSession { request in
                if request.url?.path.hasSuffix("/device") == true {
                    let json = #"{"device_code":"DEV","user_code":"WXYZ","#
                        + #""verification_uri":"https://twitch.tv/activate","#
                        + #""expires_in":600,"interval":5}"#
                    return (MockURLProtocol.httpResponse(for: request, status: 200), Data(json.utf8))
                }
                let pending = #"{"status":400,"message":"authorization_pending"}"#
                return (MockURLProtocol.httpResponse(for: request, status: 400), Data(pending.utf8))
            }
        )
        return TwitchViewModel(
            cancelTokenValidationSchedule: {},
            restartTokenValidationSchedule: {},
            makeOAuthClient: { ("client", auth) },
            leaveAccountService: { _, _ in true }
        )
    }

    @Test("startOAuth clears a stale error before the new attempt")
    func startOAuthClearsStaleError() async throws {
        let viewModel = makeViewModel()
        viewModel.connectionError = TwitchViewModel.Failure.oauth("Old failure")
        viewModel.authState = .error("Old failure")

        viewModel.startOAuth()

        #expect(viewModel.connectionError == nil)
        #expect(viewModel.authState == .requestingCode)
        #expect(viewModel.progressMessage == "Getting your code\u{2026}")

        let flow = viewModel.oAuthTask
        await viewModel.cancelOAuth()
        await flow?.value
    }

    @Test("A waiting device code carries its expiry")
    func authStateCarriesExpiry() async throws {
        let viewModel = makeViewModel()
        let before = Date()

        viewModel.startOAuth()
        let flow = viewModel.oAuthTask
        let waiting = await waitUntil(timeout: .seconds(3)) {
            viewModel.authState.userCode == "WXYZ"
        }
        #expect(waiting)

        let expiresAt = try #require(viewModel.deviceCodeExpiresAt)
        let lifetime = expiresAt.timeIntervalSince(before)
        #expect(lifetime > 590 && lifetime <= 601)

        await viewModel.cancelOAuth()
        await flow?.value
    }
}

/// Try Again on "Couldn't read your saved Twitch sign-in". Holds the shared-state
/// lock because loading reads the re-auth flag from `DefaultsStore`, and binds its
/// own Keychain backend so the injected read failure reaches only this test.
@Suite("Twitch ViewModel Keychain read retry", .isolatedSharedTestState)
@MainActor
struct TwitchViewModelKeychainRetryTests {

    @Test("Try Again after a failed Keychain read loads the saved sign-in")
    func failedReadReloadsOnRetry() async throws {
        let backend = InspectableKeychainBackend()
        try await KeychainService.$backendBox.withValue(KeychainService.BackendBox(backend)) {
            try KeychainService.saveTwitchCredentialGrant(.init(
                accessToken: "access", refreshToken: "refresh",
                username: "wolfbot", userID: "42", channelID: "mrdemonwolf"))
            backend.failNextLoad(for: KeychainService.twitchCredentialGrantAccount)
            let viewModel = TwitchViewModel()

            await viewModel.loadSavedCredentials()
            let failure = try #require(viewModel.connectionError)
            #expect(failure.id == "twitch.keychainUnreadable")
            #expect(TwitchViewModel.retryTarget(for: failure) == .reloadCredentials)
            #expect(!viewModel.credentialsSaved)

            // What Try Again runs for this failure (`TwitchSettingsView.retry`).
            viewModel.connectionError = nil
            await viewModel.loadSavedCredentials()
            #expect(viewModel.connectionError == nil)
            #expect(viewModel.credentialsSaved)
            #expect(viewModel.botUsername == "wolfbot")
            #expect(viewModel.channelID == "mrdemonwolf")
        }
    }
}
