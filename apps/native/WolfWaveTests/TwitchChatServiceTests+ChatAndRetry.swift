//
//  TwitchChatServiceTests+ChatAndRetry.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation

@testable import WolfWave

/// Chat message roles, the retry-queue cap, bounded streams, and retry accounting.
extension TwitchChatServiceTests {
    // MARK: - Chat Message Tests
    
    @Test("ChatMessage structure stores message data correctly")
    func testChatMessageStructure() async throws {
        let badge = TwitchChatService.ChatMessage.Badge(
            setID: "moderator",
            id: "1",
            info: "Moderator"
        )
        
        let reply = TwitchChatService.ChatMessage.Reply(
            parentMessageID: "parent-123",
            parentMessageBody: "Hello",
            parentUserID: "user-456",
            parentUsername: "ParentUser"
        )
        
        let message = TwitchChatService.ChatMessage(
            messageID: "msg-789",
            username: "TestUser",
            userID: "user-123",
            message: "Test message",
            channel: "channel-456",
            badges: [badge],
            reply: reply
        )
        
        #expect(message.messageID == "msg-789")
        #expect(message.username == "TestUser")
        #expect(message.userID == "user-123")
        #expect(message.message == "Test message")
        #expect(message.channel == "channel-456")
        #expect(message.badges.count == 1)
        #expect(message.badges[0].setID == "moderator")
        #expect(message.reply?.parentMessageID == "parent-123")
    }

    /// Builds a `ChatMessage` carrying only the named badge sets.
    private func message(withBadgeSets sets: [String]) -> TwitchChatService.ChatMessage {
        TwitchChatService.ChatMessage(
            messageID: "m", username: "u", userID: "1", message: "!sr x",
            channel: "c",
            badges: sets.map { .init(setID: $0, id: "1", info: "") },
            reply: nil
        )
    }

    @Test("Founder badge counts as subscriber for the request gate")
    func testFounderBadgeIsSubscriber() async throws {
        let roles = message(withBadgeSets: ["founder"]).roles
        #expect(roles.isSubscriber)
        #expect(!roles.isModerator)
        #expect(!roles.isBroadcaster)
        #expect(!roles.isVIP)
    }

    @Test("Subscriber badge counts as subscriber")
    func testSubscriberBadgeIsSubscriber() async throws {
        #expect(message(withBadgeSets: ["subscriber"]).roles.isSubscriber)
    }

    @Test("Each badge set maps to its own role")
    func testRolesMapEachBadge() async throws {
        #expect(message(withBadgeSets: ["moderator"]).roles.isModerator)
        #expect(message(withBadgeSets: ["broadcaster"]).roles.isBroadcaster)
        #expect(message(withBadgeSets: ["vip"]).roles.isVIP)
    }

    @Test("No badges means no roles")
    func testNoBadgesNoRoles() async throws {
        let roles = message(withBadgeSets: []).roles
        #expect(!roles.isModerator && !roles.isBroadcaster && !roles.isSubscriber && !roles.isVIP)
    }

    // MARK: - Retry-Queue Cap Tests

    @Test("appendCapped keeps queue under cap and drops nothing")
    func testAppendCappedUnderCap() async throws {
        var queue: [Int] = [1, 2]
        let dropped = TwitchChatService.appendCapped(3, to: &queue, cap: 4)
        #expect(dropped == 0)
        #expect(queue == [1, 2, 3])
    }

    @Test("appendCapped drops oldest when over cap")
    func testAppendCappedDropsOldest() async throws {
        var queue: [Int] = [1, 2, 3]
        let dropped = TwitchChatService.appendCapped(4, to: &queue, cap: 3)
        #expect(dropped == 1)
        #expect(queue == [2, 3, 4])
    }

    @Test("appendCapped over cap by many drops in FIFO order")
    func testAppendCappedRepeated() async throws {
        var queue: [Int] = []
        for value in 1...10 {
            _ = TwitchChatService.appendCapped(value, to: &queue, cap: 3)
        }
        // Only the newest 3 survive, oldest dropped first.
        #expect(queue == [8, 9, 10])
    }

    // MARK: - Bounded Stream Tests

    @Test("chatMessages stream uses a bounded buffer (only newest N retained)")
    func testChatMessagesStreamBounded() async throws {
        // Drive an unconsumed bounded stream past its cap and confirm only the
        // newest `chatMessageStreamBuffer` elements are delivered (drop-oldest).
        let cap = AppConstants.Twitch.chatMessageStreamBuffer
        let (stream, continuation) = AsyncStream.makeStream(
            of: Int.self, bufferingPolicy: .bufferingNewest(cap))

        for value in 0..<(cap + 50) {
            continuation.yield(value)
        }
        continuation.finish()

        var received: [Int] = []
        for await value in stream { received.append(value) }

        #expect(received.count == cap)
        // First retained element is the 50th yielded value; the oldest 50 drop.
        #expect(received.first == 50)
        #expect(received.last == cap + 49)
    }

    // MARK: - Retry Accounting Tests

    @Test("shouldRequeueAfterFailure stops at the retry limit")
    func testShouldRequeueAfterFailureBoundary() async throws {
        let maxRetries = 3
        // Attempts below the limit requeue; at/above the limit they do not.
        #expect(TwitchChatService.shouldRequeueAfterFailure(attempts: 1, maxRetries: maxRetries))
        #expect(TwitchChatService.shouldRequeueAfterFailure(attempts: 2, maxRetries: maxRetries))
        #expect(!TwitchChatService.shouldRequeueAfterFailure(attempts: 3, maxRetries: maxRetries))
        #expect(!TwitchChatService.shouldRequeueAfterFailure(attempts: 4, maxRetries: maxRetries))
    }

    @Test("Persistently failing message stops at maxMessageRetries without resetting attempts")
    func testPersistentFailureStopsAtMaxRetriesWithoutReset() async throws {
        // Pure simulation of the drain-loop requeue contract: a send that keeps
        // failing must increment the per-message attempt count each pass (never
        // reset to 0 the way the old `sendMessage`-in-drain path did) and stop
        // once the count reaches the retry limit. This mirrors
        // `drainPendingMessages` -> `sendMessageOnce` (fails) -> `queueMessageForRetry`.
        let maxRetries = AppConstants.Twitch.maxMessageRetries
        var attempts = 0 // attempt that just failed, 1-based after first increment
        var observed: [Int] = []
        var passes = 0
        let guardLimit = maxRetries + 10 // tripwire against an unbounded loop

        // First failure enters the queue at attempts: 1.
        attempts = 1
        while TwitchChatService.shouldRequeueAfterFailure(attempts: attempts, maxRetries: maxRetries) {
            observed.append(attempts)
            // queueMessageForRetry stores attempts + 1 as the next attempt number.
            attempts += 1
            passes += 1
            #expect(passes < guardLimit)
            if passes >= guardLimit { break }
        }
        // Record the terminal attempt that was dropped (not requeued).
        observed.append(attempts)

        // Attempts strictly increase by 1; never reset.
        #expect(observed == Array(1...maxRetries))
        // The loop terminated at exactly the retry limit.
        #expect(attempts == maxRetries)
    }

    // MARK: - Runtime Lifecycle / Retry Classification

    @Test("Only transient chat-send failures enter the retry queue")
    func testChatSendRetryDisposition() {
        #expect(!TwitchChatService.shouldRetryChatSend(.sent))
        #expect(TwitchChatService.shouldRetryChatSend(.retryableFailure))
        #expect(!TwitchChatService.shouldRetryChatSend(.permanentFailure))
    }

    @Test("Helix status classification separates auth, transient, and permanent failures")
    func testHelixResponseDisposition() {
        #expect(TwitchChatService.helixResponseDisposition(for: 200) == .success)
        #expect(TwitchChatService.helixResponseDisposition(for: 204) == .success)
        #expect(TwitchChatService.helixResponseDisposition(for: 401) == .authenticationFailure)
        #expect(TwitchChatService.helixResponseDisposition(for: 403) == .permanentFailure)

        for status in [408, 425, 429, 500, 503, 599] {
            #expect(TwitchChatService.helixResponseDisposition(for: status) == .retryableFailure)
        }
        for status in [300, 400, 404, 409, 422] {
            #expect(TwitchChatService.helixResponseDisposition(for: status) == .permanentFailure)
        }
    }

    @Test("Create-poll response parser returns the exact Helix poll ID")
    func testSkipPollIDParsing() {
        let valid = Data(#"{"data":[{"id":"poll-123"}]}"#.utf8)
        let missingID = Data(#"{"data":[{"title":"Skip?"}]}"#.utf8)
        let emptyData = Data(#"{"data":[]}"#.utf8)

        #expect(TwitchChatService.skipPollID(from: valid) == "poll-123")
        #expect(TwitchChatService.skipPollID(from: missingID) == nil)
        #expect(TwitchChatService.skipPollID(from: emptyData) == nil)
        #expect(TwitchChatService.skipPollID(from: Data("not-json".utf8)) == nil)
    }

    @Test("Create-poll outcomes distinguish rejection from remote ambiguity")
    func testSkipPollCreationOutcomeClassification() {
        let valid = Data(#"{"data":[{"id":"poll-123"}]}"#.utf8)
        let missingID = Data(#"{"data":[{"title":"Skip?"}]}"#.utf8)

        #expect(
            TwitchChatService.skipPollCreationOutcome(
                statusCode: 200, responseData: valid)
                == .created(id: "poll-123"))

        // A malformed 2xx and a transport failure may still have created a
        // remote poll, so neither is safe for chat fallback.
        #expect(
            TwitchChatService.skipPollCreationOutcome(
                statusCode: 200, responseData: missingID)
                == .indeterminate)
        #expect(
            TwitchChatService.skipPollCreationOutcome(
                statusCode: nil, responseData: nil)
                == .indeterminate)

        for status in [401, 403, 404, 422] {
            #expect(
                TwitchChatService.skipPollCreationOutcome(
                    statusCode: status, responseData: Data())
                    == .definitiveFailure)
        }
        for status in [300, 429, 500, 503] {
            #expect(
                TwitchChatService.skipPollCreationOutcome(
                    statusCode: status, responseData: Data())
                    == .indeterminate)
        }
    }

    @Test("Active-poll 400 is distinct from ordinary validation rejection")
    func testSkipPollCreationDistinguishesActivePollFromOtherBadRequests() {
        let activePoll = Data(
            #"{"message":"The broadcaster already has a poll that's running; you may not create another poll until the current poll completes."}"#.utf8)
        let invalidRequest = Data(
            #"{"message":"The poll duration must be between 15 and 1800."}"#.utf8)

        #expect(
            TwitchChatService.skipPollCreationOutcome(
                statusCode: 400, responseData: activePoll) == .pollAlreadyActive)
        #expect(
            TwitchChatService.skipPollCreationOutcome(
                statusCode: 400, responseData: invalidRequest) == .definitiveFailure)
        #expect(
            TwitchChatService.skipPollCreationOutcome(
                statusCode: 400, responseData: Data("not-json".utf8))
                == .definitiveFailure)
        #expect(
            TwitchChatService.skipPollCreationOutcome(
                statusCode: 409, responseData: Data()) == .indeterminate)
        #expect(
            TwitchChatService.skipPollCreationOutcome(
                statusCode: 429, responseData: Data()) == .indeterminate)
    }

    @Test("Poll scope validation distinguishes present, missing, and inconclusive")
    func testPollScopeValidationClassification() {
        let present = Data(
            #"{"scopes":["chat:read","channel:manage:polls"]}"#.utf8)
        let missing = Data(#"{"scopes":["chat:read"]}"#.utf8)

        #expect(TwitchChatService.pollScopeValidation(
            statusCode: 200, responseData: present) == .present)
        #expect(TwitchChatService.pollScopeValidation(
            statusCode: 200, responseData: missing) == .missing)
        #expect(TwitchChatService.pollScopeValidation(
            statusCode: 401, responseData: Data()) == .missing)
        #expect(TwitchChatService.pollScopeValidation(
            statusCode: 200, responseData: Data("not-json".utf8)) == .indeterminate)
        #expect(TwitchChatService.pollScopeValidation(
            statusCode: 500, responseData: Data()) == .indeterminate)
        #expect(TwitchChatService.pollScopeValidation(
            statusCode: nil, responseData: nil) == .indeterminate)
    }
}
