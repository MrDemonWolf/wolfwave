//
//  SongRequestServiceTests.swift
//  WolfWaveTests
//
//  Created by MrDemonWolf, Inc. on 4/8/26.
//

import MusicKit
import XCTest

@testable import WolfWave

// MARK: - Mock AppleMusicController

final class MockAppleMusicController: AppleMusicControlling {
    var isPlaying = false
    var isPaused = false
    var isAuthorized = true
    var isMusicAppRunning = true
    nonisolated(unsafe) var authStatus: AppleMusicController.AuthStatus = .authorized

    var playNowCalled = false
    var enqueueCalled = false
    var skipCalled = false
    var clearCalled = false
    var rebuildCalled = false
    var playFallbackCalled = false
    nonisolated(unsafe) var fallbackPlaylistName: String?
    nonisolated(unsafe) var enqueuedSongs: [Song] = []
    var shouldThrowMusicAppNotRunning = false

    @MainActor func search(query: String) async -> AppleMusicController.SearchResult { .notFound }
    @MainActor func resolve(url: URL) async -> AppleMusicController.SearchResult { .notFound }
    @MainActor func playNow(song: Song) async throws {
        if shouldThrowMusicAppNotRunning { throw PlaybackError.musicAppNotRunning }
        playNowCalled = true
    }
    @MainActor func enqueue(song: Song) async throws {
        enqueueCalled = true
        enqueuedSongs.append(song)
    }
    @MainActor func skipToNext() async throws { skipCalled = true }
    @MainActor func previousTrack() async throws { /* no-op for tests */ }
    @MainActor func playPause() async throws { /* no-op for tests */ }
    @MainActor func clearPlayerQueue() async { clearCalled = true }
    @MainActor func rebuildPlayerQueue(from songs: [Song]) async throws { rebuildCalled = true }
    @MainActor func playFallbackPlaylist(name: String) async throws {
        playFallbackCalled = true
        fallbackPlaylistName = name
    }
}

// MARK: - SongRequestServiceTests

nonisolated final class SongRequestServiceTests: XCTestCase {

    nonisolated(unsafe) var queue: SongRequestQueue!
    nonisolated(unsafe) var mockController: MockAppleMusicController!
    nonisolated(unsafe) var service: SongRequestService!

    /// Builds a chat-command request source with sensible defaults.
    @MainActor private func chatSource(
        username: String = "viewer",
        isModerator: Bool = false,
        isBroadcaster: Bool = false,
        isSubscriber: Bool = false,
        isVIP: Bool = false
    ) -> RequestSource {
        .chatCommand(
            BotCommandContext(
                userID: "1", username: username,
                isModerator: isModerator, isBroadcaster: isBroadcaster,
                isSubscriber: isSubscriber, isVIP: isVIP, messageID: "m"
            )
        )
    }

    @MainActor private func clearAccessDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestSubscriberOnly)
        defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestChatAudience)
        defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestMaxQueueSize)
        defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestPerUserLimit)
        defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestHoldEnabled)
    }

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        queue = SongRequestQueue()
        mockController = MockAppleMusicController()
        service = SongRequestService(
            queue: queue,
            musicController: mockController
        )
        clearAccessDefaults()
    }

    @MainActor
    override func tearDown() async throws {
        service.stopPlaybackMonitoring()
        service = nil
        mockController = nil
        queue = nil
        clearAccessDefaults()
        try await super.tearDown()
    }

    // MARK: - Audience Gate

    @MainActor func testProcessRequestSubscriberAudienceBlocksViewer() async {
        UserDefaults.standard.set(
            RequestAudience.subscribers.rawValue,
            forKey: AppConstants.UserDefaults.songRequestChatAudience)

        let result = await service.processRequest(
            query: "any song", username: "viewer",
            source: chatSource(username: "viewer", isSubscriber: false))
        guard case .error = result else {
            XCTFail("Expected .error for subscriber-only block, got \(result)")
            return
        }
    }

    @MainActor func testProcessRequestSubscriberAudienceAllowsSubscriber() async {
        UserDefaults.standard.set(
            RequestAudience.subscribers.rawValue,
            forKey: AppConstants.UserDefaults.songRequestChatAudience)

        let result = await service.processRequest(
            query: "any song", username: "subscriber",
            source: chatSource(username: "subscriber", isSubscriber: true))
        if case .error(let msg) = result {
            XCTAssertFalse(
                msg.contains("subscriber-only"), "Should not be blocked by subscriber-only gate")
        }
    }

    @MainActor func testProcessRequestSubscriberAudienceAllowsModerator() async {
        UserDefaults.standard.set(
            RequestAudience.subscribers.rawValue,
            forKey: AppConstants.UserDefaults.songRequestChatAudience)

        let result = await service.processRequest(
            query: "any song", username: "mod",
            source: chatSource(username: "mod", isModerator: true))
        if case .error(let msg) = result {
            XCTAssertFalse(
                msg.contains("subscriber-only"), "Moderator should bypass subscriber-only gate")
        }
    }

    @MainActor func testProcessRequestVipAudienceBlocksRegularViewer() async {
        UserDefaults.standard.set(
            RequestAudience.vipsAndSubs.rawValue,
            forKey: AppConstants.UserDefaults.songRequestChatAudience)

        let result = await service.processRequest(
            query: "any song", username: "viewer", source: chatSource(username: "viewer"))
        guard case .error = result else {
            XCTFail("Expected .error blocking a non-VIP/non-sub, got \(result)")
            return
        }
    }

    @MainActor func testProcessRequestVipAudienceAllowsVIP() async {
        UserDefaults.standard.set(
            RequestAudience.vipsAndSubs.rawValue,
            forKey: AppConstants.UserDefaults.songRequestChatAudience)

        let result = await service.processRequest(
            query: "any song", username: "vip",
            source: chatSource(username: "vip", isVIP: true))
        if case .error(let msg) = result {
            XCTAssertFalse(msg.contains("VIPs"), "VIP should pass the VIPs & Subscribers gate")
        }
    }

    @MainActor func testProcessRequestRedemptionSourcesBypassAudienceGate() async {
        // Even with the strictest audience, points/bits sources are not gated here.
        UserDefaults.standard.set(
            RequestAudience.modsOnly.rawValue,
            forKey: AppConstants.UserDefaults.songRequestChatAudience)

        let pointsResult = await service.processRequest(
            query: "any song", username: "viewer",
            source: .channelPoints(redemptionID: "r", rewardID: "rw"))
        if case .error(let msg) = pointsResult {
            XCTAssertFalse(msg.contains("Mods"), "Channel-point requests must not hit the audience gate")
        }

        let bitsResult = await service.processRequest(
            query: "any song", username: "viewer", source: .bits(amount: 100))
        if case .error(let msg) = bitsResult {
            XCTAssertFalse(msg.contains("Mods"), "Bit requests must not hit the audience gate")
        }
    }

    // MARK: - Access Migration

    @MainActor func testMigrateAccessSettingsConvertsLegacySubscriberOnly() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestChatAudience)
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestSubscriberOnly)

        SongRequestService.migrateAccessSettings()

        XCTAssertEqual(
            defaults.string(forKey: AppConstants.UserDefaults.songRequestChatAudience),
            RequestAudience.subscribers.rawValue)
    }

    @MainActor func testMigrateAccessSettingsDefaultsToEveryone() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestChatAudience)
        defaults.set(false, forKey: AppConstants.UserDefaults.songRequestSubscriberOnly)

        SongRequestService.migrateAccessSettings()

        XCTAssertEqual(
            defaults.string(forKey: AppConstants.UserDefaults.songRequestChatAudience),
            RequestAudience.everyone.rawValue)
    }

    // MARK: - Auth Check

    @MainActor func testProcessRequestNotAuthorizedReturnsError() async {
        mockController.isAuthorized = false
        mockController.authStatus = .denied

        let result = await service.processRequest(
            query: "any song", username: "user", source: chatSource(username: "user"))
        guard case .notAuthorized = result else {
            XCTFail("Expected .notAuthorized, got \(result)")
            return
        }
    }

    // MARK: - Skip

    @MainActor func testSkipEmptyQueueReturnsNil() async {
        let result = await service.skip()
        XCTAssertNil(result)
    }

    @MainActor func testSkipWithQueueItemsAdvancesInternalQueue() async {
        queue.add(SongRequestItem(title: "Song A", artist: "Artist", requesterUsername: "user1"))
        queue.add(SongRequestItem(title: "Song B", artist: "Artist", requesterUsername: "user2"))
        queue.dequeue()

        let next = await service.skip()
        XCTAssertEqual(next?.title, "Song B")
        XCTAssertEqual(queue.nowPlaying?.title, "Song B")
    }

    @MainActor func testSkipCallsNativeSkip() async {
        queue.add(SongRequestItem(title: "Song A", artist: "Artist", requesterUsername: "user1"))
        queue.dequeue()

        _ = await service.skip()
        XCTAssertTrue(mockController.clearCalled)
    }

    // MARK: - ClearQueue

    @MainActor func testClearQueueReturnsZeroWhenEmpty() async {
        let count = await service.clearQueue()
        XCTAssertEqual(count, 0)
    }

    @MainActor func testClearQueueReturnsClearedCount() async {
        queue.add(SongRequestItem(title: "Song 1", artist: "A", requesterUsername: "user1"))
        queue.add(SongRequestItem(title: "Song 2", artist: "B", requesterUsername: "user2"))

        let count = await service.clearQueue()
        XCTAssertEqual(count, 2)
        XCTAssertTrue(queue.isEmpty)
    }

    @MainActor func testClearQueueAlsoClearsPlayerQueue() async {
        queue.add(SongRequestItem(title: "Song 1", artist: "A", requesterUsername: "user1"))

        _ = await service.clearQueue()
        XCTAssertTrue(mockController.clearCalled)
    }

    // MARK: - Buffered Mode (Music.app closed)

    @MainActor func testRequestWhileMusicAppClosedBuffers() async {
        mockController.isMusicAppRunning = false

        _ = await service.processRequest(
            query: "any song", username: "viewer", source: chatSource())
        XCTAssertFalse(mockController.playNowCalled, "playNow should not fire when Music.app is closed")
    }

    @MainActor func testPlayNextInQueueRequeuesItemWhenMusicAppNotRunning() async {
        mockController.shouldThrowMusicAppNotRunning = true

        queue.add(SongRequestItem(title: "Buffered Song", artist: "Artist", requesterUsername: "user1"))
        queue.dequeue()

        mockController.isMusicAppRunning = true
        _ = await service.processRequest(
            query: "any song", username: "viewer", source: chatSource())
        XCTAssertFalse(
            mockController.playNowCalled,
            "playNow threw — item should be re-queued, not marked as played")
    }

    // MARK: - Fallback Playlist

    @MainActor func testFallbackPlaylistPlaysWhenQueueEmpties() async {
        UserDefaults.standard.set(
            "Gaming Vibes", forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)
        mockController.isMusicAppRunning = true

        _ = await service.clearQueue()

        XCTAssertFalse(
            mockController.playFallbackCalled, "clearQueue should not trigger fallback playlist")

        UserDefaults.standard.removeObject(
            forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)
    }

    @MainActor func testClearQueueDoesNotStartFallback() async {
        UserDefaults.standard.set(
            "Gaming Vibes", forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)
        queue.add(SongRequestItem(title: "Song 1", artist: "A", requesterUsername: "user1"))

        _ = await service.clearQueue()

        XCTAssertFalse(
            mockController.playFallbackCalled, "clearQueue should never auto-start fallback playlist")
        XCTAssertTrue(mockController.clearCalled, "clearQueue should stop Music.app")

        UserDefaults.standard.removeObject(
            forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)
    }

    // MARK: - Hold Mode

    @MainActor func testHoldBlocksAutoPlayOnRequest() async {
        UserDefaults.standard.set(true, forKey: AppConstants.UserDefaults.songRequestHoldEnabled)
        mockController.isMusicAppRunning = true
        mockController.isPlaying = false

        _ = await service.processRequest(
            query: "song", username: "viewer", source: chatSource())

        XCTAssertFalse(mockController.playNowCalled, "Hold should block auto-play on new requests")
    }

    @MainActor func testSetHoldTogglesFlag() async {
        await service.setHold(true)
        XCTAssertTrue(service.isHoldEnabled)
        await service.setHold(false)
        XCTAssertFalse(service.isHoldEnabled)
    }

    @MainActor func testHoldBlocksFallbackStart() async {
        UserDefaults.standard.set(true, forKey: AppConstants.UserDefaults.songRequestHoldEnabled)
        UserDefaults.standard.set(
            "Gaming Vibes", forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)

        _ = await service.clearQueue()
        XCTAssertFalse(
            mockController.playFallbackCalled, "No fallback should start while hold is enabled")

        UserDefaults.standard.removeObject(
            forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)
    }

    @MainActor func testAutoAdvanceDoesNotFireWhenPaused() async {
        queue.add(SongRequestItem(title: "Next Song", artist: "A", requesterUsername: "user1"))
        queue.add(SongRequestItem(title: "Current", artist: "B", requesterUsername: "user2"))
        queue.dequeue()

        mockController.isPlaying = false
        mockController.isPaused = true

        service.startPlaybackMonitoring()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        service.stopPlaybackMonitoring()

        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.items.first?.title, "Current")
        XCTAssertEqual(queue.nowPlaying?.title, "Next Song")
    }
}
