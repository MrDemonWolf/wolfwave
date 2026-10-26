//
//  TwitchChatServiceTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-03-18.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation
@testable import WolfWave

/// Holds one EventSub subscription attempt open so a second refresh can race
/// it deterministically and prove the per-session in-flight latch is effective.
actor PollSubscriptionGate {
    private var sessions: [String] = []
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func subscribe(sessionID: String) async -> Bool {
        sessions.append(sessionID)
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                releaseWaiter = continuation
            }
        }
        return true
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func subscribedSessions() -> [String] {
        sessions
    }
}

/// Comprehensive test suite for TwitchChatService
@MainActor
@Suite("Twitch Chat Service Tests", .serialized, .isolatedSharedTestState)
struct TwitchChatServiceTests {

    let handlerStore = MockURLProtocol.HandlerStore()

    /// Reset UserDefaults keys that tests depend on to prevent cross-test contamination.
    init() {
        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.twitchReauthNeeded)
        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.currentSongCommandEnabled)
        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.lastSongCommandEnabled)
        clearManagedRewardIdentity()
    }

    /// Stores reward `reward` owned by broadcaster `broadcaster`, replacing any previous identity.
    func installManagedRewardIdentity() {
        clearManagedRewardIdentity()
        #expect(
            TwitchManagedRewardStore.store(
                .init(
                    rewardID: "reward",
                    broadcasterID: "broadcaster"),
                replacing: .none))
    }

    /// Removes the stored reward id and its owner identity.
    func clearManagedRewardIdentity() {
        DefaultsStore.store.removeObject(
            forKey: AppConstants.UserDefaults.songRequestChannelPointsRewardID)
        DefaultsStore.store.removeObject(
            forKey: AppConstants.UserDefaults.songRequestChannelPointsRewardIdentity)
    }

    @Test("Channel normalization rejects query delimiters and non-login characters")
    func testChannelNameNormalization() {
        #expect(TwitchChatService.normalizedChannelName("  Wolf_Name42  ") == "wolf_name42")
        #expect(TwitchChatService.normalizedChannelName("abc") == "abc")
        let maximumLengthLogin = String(repeating: "a", count: 25)
        #expect(TwitchChatService.normalizedChannelName(maximumLengthLogin) == maximumLengthLogin)
        for invalid in [
            "wolf-name",
            "wolf&login=other",
            "wolf=other",
            "wolf name",
            "wolf/name",
            "wölf",
            String(repeating: "a", count: 26)
        ] {
            #expect(TwitchChatService.normalizedChannelName(invalid) == nil)
        }
    }

    @Test("Username lookup encodes one normalized login and rejects injection before I/O")
    func testUsernameLookupQueryConstruction() async throws {
        let requests = ThreadSafeBox<[URLRequest]>([])
        let service = TwitchChatService(
            helixHTTPClient: HTTPClient(
                session: MockURLProtocol.makeSession { request in
                    requests.mutate { $0.append(request) }
                    let body = #"""
                    {"data":[{"id":"user_id","login":"wolf_name42",
                    "display_name":"Wolf Name"}]}
                    """#
                    return (
                        MockURLProtocol.httpResponse(for: request, status: 200),
                        Data(body.utf8)
                    )
                }
            )
        )

        let userID = try await service.resolveUsername(
            "  Wolf_Name42  ",
            token: "token",
            clientID: "client"
        )

        #expect(userID == "user_id")
        let request = try #require(requests.value.first)
        let url = try #require(request.url)
        let queryItems = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        )
        #expect(queryItems.count == 1)
        #expect(queryItems.first?.name == "login")
        #expect(queryItems.first?.value == "wolf_name42")

        do {
            _ = try await service.resolveUsername(
                "wolf&login=other",
                token: "token",
                clientID: "client"
            )
            Issue.record("Expected invalid username rejection")
        } catch is TwitchChatService.ConnectionError {
            // Expected before the HTTP client is invoked.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(requests.value.count == 1)
    }

    #if DEBUG
    @Test("Debug viewer simulation matches canonical login and display-name fallback")
    func testDebugViewerSimulationUsernameMatching() {
        let scratch = ThrowawayDefaults("TwitchChatServiceTests.viewer")
        defer { scratch.destroy() }
        let defaults = scratch.defaults

        defaults.set(
            " other, SOMEHANDLE ",
            forKey: AppConstants.UserDefaults.debugViewerUsernames
        )
        #expect(TwitchChatService.shouldTreatAsViewer(
            event: ["chatter_user_login": "somehandle", "chatter_user_name": "Localized Name"],
            defaults: defaults
        ))
        #expect(TwitchChatService.shouldTreatAsViewer(
            event: ["chatter_user_name": "Other"],
            defaults: defaults
        ))
        #expect(!TwitchChatService.shouldTreatAsViewer(
            event: ["chatter_user_login": "different"],
            defaults: defaults
        ))

        defaults.set(true, forKey: AppConstants.UserDefaults.debugTreatAllChattersAsViewers)
        #expect(TwitchChatService.shouldTreatAsViewer(
            event: ["chatter_user_login": "anyone"],
            defaults: defaults
        ))
    }
    #endif

    /// Wraps `payload` in an EventSub metadata envelope (message type and id, stamped now) and
    /// returns it as a JSON string.
    static func eventSubEnvelope(
        messageType: String,
        messageID: String,
        payload: [String: Any]
    ) throws -> String {
        let object: [String: Any] = [
            "metadata": [
                "message_type": messageType,
                "message_id": messageID,
                "message_timestamp": ISO8601DateFormatter().string(from: Date())
            ],
            "payload": payload
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    @Test("Service initializes with default values")
    func testServiceInitialization() async throws {
        let service = TwitchChatService()

        #expect(await service.commandsEnabled == true)
        #expect(await service.isConnected == false)
        #expect(service.currentSongCommandEnabled == false)
        #expect(service.lastSongCommandEnabled == false)
    }
    
    // MARK: - Connection Error Tests
    
    @Test("Connection error has correct descriptions")
    func testConnectionErrorDescriptions() async throws {
        let invalidCreds = TwitchChatService.ConnectionError.invalidCredentials
        #expect(invalidCreds.errorDescription == "Invalid Twitch credentials")
        
        let missingClient = TwitchChatService.ConnectionError.missingClientID
        #expect(missingClient.errorDescription == "Twitch Client ID is not configured")
        
        let networkError = TwitchChatService.ConnectionError.networkError("Test error")
        #expect(networkError.errorDescription == "Network error: Test error")
        
        let authFailed = TwitchChatService.ConnectionError.authenticationFailed
        #expect(authFailed.errorDescription == "Failed to authenticate with Twitch")
    }
    
    // MARK: - Token Validation Tests

    @Test("Token validation accepts a decoded 200 response with required scopes")
    func testTokenValidationValid() async throws {
        let scopes = [
            "user:read:chat",
            "user:write:chat",
            AppConstants.Twitch.pollsScope,
            AppConstants.Twitch.channelPointsScope,
            AppConstants.Twitch.bitsScope
        ]
        let body = try JSONSerialization.data(withJSONObject: ["scopes": scopes])

        let result = await validateToken(status: 200, body: body)

        #expect(result == .valid)
    }

    @Test("Only Twitch 401 definitively invalidates a token")
    func testTokenValidationInvalidOn401() async {
        let result = await validateToken(status: 401, body: Data())
        #expect(result == .invalid)
    }

    @Test("Rate limits and server failures keep token validity unknown")
    func testTokenValidationTransientHTTPFailures() async {
        for status in [429, 500, 503] {
            let result = await validateToken(status: status, body: Data())
            #expect(result == .temporarilyUnavailable)
        }
    }

    @Test("Malformed validate payload keeps token validity unknown")
    func testTokenValidationMalformedPayload() async {
        let result = await validateToken(status: 200, body: Data("not-json".utf8))
        #expect(result == .temporarilyUnavailable)
    }

    @Test("Transport failure keeps token validity unknown")
    func testTokenValidationTransportFailure() async {
        handlerStore.handler = { _ in throw URLError(.notConnectedToInternet) }
        defer { handlerStore.handler = nil }
        let client = HTTPClient(session: MockURLProtocol.makeSession(handlerStore: handlerStore))
        let service = TwitchChatService()

        let result = await service.validateToken(
            "stored-token", expectedClientID: nil, http: client)

        #expect(result == .temporarilyUnavailable)
    }

    /// Twitch answered 200, so the token is live. Reporting a scope gap as
    /// `.invalid` told the user their session had expired, and the re-auth flag
    /// that followed also stopped the hourly validator, leaving a working token
    /// unchecked from then on. Only Twitch rejecting the token may invalidate a
    /// local grant.
    @Test("Missing required scopes reports the gap without invalidating the grant")
    func testTokenValidationMissingScopeReportsScopes() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["scopes": []])
        let result = await validateToken(
            status: 200,
            body: body,
            requiredScopes: ["user:read:chat"])
        #expect(result == .missingScopes(["user:read:chat"]))
        #expect(result != .invalid)
    }

    @Test("Token validation enforces the configured Twitch client ID")
    func testTokenValidationClientIDBinding() async throws {
        let scopes = ["user:read:chat", "user:write:chat"]
        let matching = try JSONSerialization.data(withJSONObject: [
            "client_id": "expected", "scopes": scopes
        ])
        let mismatch = try JSONSerialization.data(withJSONObject: [
            "client_id": "different", "scopes": scopes
        ])
        let missing = try JSONSerialization.data(withJSONObject: ["scopes": scopes])

        let matchingResult = await validateToken(
            status: 200, body: matching, expectedClientID: "expected")
        let mismatchResult = await validateToken(
            status: 200, body: mismatch, expectedClientID: "expected")
        let missingResult = await validateToken(
            status: 200, body: missing, expectedClientID: "expected")
        #expect(matchingResult == .valid)
        #expect(mismatchResult == .invalid)
        #expect(missingResult == .temporarilyUnavailable)
    }

    /// Runs token validation against a canned Helix response (`status`, `body`), then clears the
    /// handler.
    private func validateToken(
        status: Int,
        body: Data,
        requiredScopes: [String] = ["user:read:chat", "user:write:chat"],
        expectedClientID: String? = nil
    ) async -> TwitchChatService.TokenValidationResult {
        handlerStore.handler = { request in
            (MockURLProtocol.httpResponse(for: request, status: status), body)
        }
        defer { handlerStore.handler = nil }
        let client = HTTPClient(session: MockURLProtocol.makeSession(handlerStore: handlerStore))
        let service = TwitchChatService()
        return await service.validateToken(
            "stored-token",
            requiredScopes: requiredScopes,
            expectedClientID: expectedClientID,
            http: client)
    }

    // MARK: - UserDefaults Persistence Bridge Tests
    
    @Test("Current song command enabled reads from UserDefaults")
    func testCurrentSongCommandEnabledUserDefaults() async throws {
        let service = TwitchChatService()
        
        // Clear any existing value
        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.currentSongCommandEnabled)
        defer { DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.currentSongCommandEnabled) }
        
        // Should default to false
        #expect(service.currentSongCommandEnabled == false)
        
        // Set to true
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.currentSongCommandEnabled)
        
        // Should now read true
        #expect(service.currentSongCommandEnabled == true)
        
    }
    
    @Test("Last song command enabled reads from UserDefaults")
    func testLastSongCommandEnabledUserDefaults() async throws {
        let service = TwitchChatService()

        // Clear any existing value
        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.lastSongCommandEnabled)
        defer { DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.lastSongCommandEnabled) }

        // Should default to false
        #expect(service.lastSongCommandEnabled == false)

        // Set to true
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.lastSongCommandEnabled)

        // Should now read true
        #expect(service.lastSongCommandEnabled == true)

    }

    // MARK: - Toggle Tests

    @Test("Commands enabled toggle works")
    func testCommandsEnabledToggle() async throws {
        let service = TwitchChatService()
        #expect(await service.commandsEnabled == true)
        await service.setCommandsEnabledForTesting(false)
        #expect(await service.commandsEnabled == false)
        await service.setCommandsEnabledForTesting(true)
        #expect(await service.commandsEnabled == true)
    }

    // MARK: - Connection Error Distinctness Tests

    @Test("Connection error cases are distinct")
    func testConnectionErrorCasesAreDistinct() async throws {
        let errors: [TwitchChatService.ConnectionError] = [
            .invalidCredentials,
            .missingClientID,
            .networkError("test"),
            .authenticationFailed
        ]

        let descriptions = errors.compactMap { $0.errorDescription }
        #expect(descriptions.count == errors.count)

        // All descriptions should be unique
        let uniqueDescriptions = Set(descriptions)
        #expect(uniqueDescriptions.count == descriptions.count)
    }
}

/// Test-only seams that install fake EventSub transport state (sockets, sessions,
/// reconnect tasks) on the actor so migration and teardown paths run without a network.
extension TwitchChatService {
    var hasEventSubTransportForTesting: Bool {
        webSocketTask != nil || migrationSourceWebSocketTask != nil
    }

    /// Installs `source` as the live socket and welcomed session, with a parked receive task, so a
    /// test can migrate away from it.
    func installPollMigrationSourceForTesting(
        _ source: URLSessionWebSocketTask
    ) -> EventSubReceiveContext {
        webSocketTask = source
        welcomedWebSocketTask = source
        sessionID = "source-session"
        setConnected(true)
        receiveTask = Task {
            try? await Task.sleep(for: .seconds(3_600))
        }
        return EventSubReceiveContext(
            generation: connectionGeneration,
            webSocketTask: source
        )
    }

    /// A receive context for `task` at the current connection generation.
    func pollMigrationContextForTesting(
        _ task: URLSessionWebSocketTask
    ) -> EventSubReceiveContext {
        EventSubReceiveContext(
            generation: connectionGeneration,
            webSocketTask: task
        )
    }

    var activeRedemptionPipelineCountForTesting: Int {
        redemptionTasks.count
    }

    /// Registers `operation` as the in-flight pipeline task for `item`, removed again when it
    /// finishes.
    func installRedemptionPipelineForTesting(
        item: TwitchRedemptionResolutionOutbox.Item,
        operation: @escaping @Sendable () async -> Void
    ) {
        redemptionTasks[item.id] = Task { [weak self] in
            await operation()
            await self?.finishRedemptionPipelineForTesting(item.id)
        }
    }

    func finishRedemptionPipelineForTesting(_ id: UUID) {
        redemptionTasks[id] = nil
    }

    /// Starts a connection attempt and fills in the identity, token, and reconnect fields chat
    /// sending needs. Returns the connection generation.
    func configureChatSendForTesting(broadcasterID: String) -> UInt64 {
        let generation = beginConnectionAttempt()
        self.broadcasterID = broadcasterID
        botID = "bot"
        oauthToken = "token"
        clientID = "client"
        reconnectChannelName = broadcasterID
        reconnectToken = "token"
        reconnectClientID = "client"
        return generation
    }

    /// Sets up a session where the broadcaster is also the bot, with a fixed token and client id.
    func configureBroadcasterRedemptionCredentialsForTesting(
        broadcasterID: String
    ) {
        _ = beginConnectionAttempt()
        self.broadcasterID = broadcasterID
        botID = broadcasterID
        oauthToken = "token"
        clientID = "client"
    }

    /// Waits for every task in `paidRedemptionTasks`: the paid-event pipelines, which outlive a
    /// socket session.
    func awaitPaidRedemptionTasksForTesting() async {
        let tasks = Array(paidRedemptionTasks.values)
        for task in tasks {
            await task.value
        }
    }

    /// Waits for every registered redemption pipeline task.
    func awaitRedemptionPipelinesForTesting() async {
        let tasks = Array(redemptionTasks.values)
        for task in tasks {
            await task.value
        }
    }

    /// Changes the broadcaster (and reconnect channel) mid-session to model an account switch.
    func switchBroadcasterForTesting(to broadcasterID: String) {
        self.broadcasterID = broadcasterID
        reconnectChannelName = broadcasterID
    }

    /// Sets the reconnect attempt count and the session-migration flag.
    func configureReconnectStateForTesting(attempts: Int, migrating: Bool) {
        reconnectionAttempts = attempts
        isMigratingSession = migrating
    }

    /// Gives the service a reconnect channel so retry paths have one to use.
    func configureRetryChannelForTesting() {
        reconnectChannelName = "test-channel"
    }

    /// Starts a connection attempt for `broadcasterID` for command dispatch tests. Returns the
    /// connection generation.
    func configureCommandSessionForTesting(broadcasterID: String) -> UInt64 {
        let generation = beginConnectionAttempt()
        self.broadcasterID = broadcasterID
        reconnectChannelName = broadcasterID
        return generation
    }

    /// Fills the reconnect channel, token, and client id.
    func configureReconnectCredentialsForTesting() {
        reconnectChannelName = "test-channel"
        reconnectToken = "test-token"
        reconnectClientID = "test-client"
    }

    /// Puts the service at its maximum reconnection attempts with the network reachable.
    func configureExhaustedReconnectForTesting() {
        isNetworkReachable = true
        reconnectionAttempts = maxReconnectionAttempts
    }

    var hasScheduledReconnectForTesting: Bool {
        reconnectTask != nil
    }

    /// Models a network outage: unreachable, `attempts` already used, no recovery cycles, last
    /// reconnect stamped now.
    func configureNetworkRecoveryForTesting(attempts: Int) {
        reconnectionAttempts = attempts
        networkReconnectCycles = 0
        isNetworkReachable = false
        lastNetworkReconnectTime = Date().timeIntervalSince1970
    }
}

/// Parks a command in `waitForCancellation()` until its task is cancelled; `wasCancelled`
/// records that cancellation (not completion) ended it.
actor SuspendedCommandGate {
    private(set) var started = false
    private(set) var wasCancelled = false

    func waitForCancellation() async {
        started = true
        do {
            try await Task.sleep(for: .seconds(3_600))
        } catch {
            wasCancelled = true
        }
    }
}

/// Parks the caller in `suspend()` until `resume()`, giving tests a fixed ordering
/// point inside an async path. `suspended` flips true once the caller has parked.
actor DeterministicAsyncGate {
    private(set) var suspended = false
    private var released = false
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        suspended = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            resumeWaiters.append(continuation)
        }
    }

    func resume() {
        released = true
        resumeWaiters.forEach { $0.resume() }
        resumeWaiters.removeAll()
    }
}

/// Async command that blocks on a `SuspendedCommandGate`. If its session is torn down
/// the cancelled command must not deliver its "stale reply".
@MainActor
final class SuspendedTestCommand: @MainActor AsyncBotCommand {
    let triggers = ["!suspend"]
    let description = "Suspends until its owning session is canceled"
    let globalCooldown: TimeInterval = 0
    let userCooldown: TimeInterval = 0

    private let gate: SuspendedCommandGate

    init(gate: SuspendedCommandGate) {
        self.gate = gate
    }

    func execute(message: String, context: BotCommandContext) async -> String? {
        await gate.waitForCancellation()
        return "stale reply"
    }
}
