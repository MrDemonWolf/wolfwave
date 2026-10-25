//
//  SongRequestServiceTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-04-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import MusicKit
import XCTest

@testable import WolfWave

// MARK: - Mock AppleMusicController

/// Scriptable `AppleMusicControlling` stand-in. State flags drive what the service
/// sees; `*Called` / `*CallCount` fields record what it asked for. Nothing here
/// touches Music.app. Shared with other song-request suites in this target.
final class MockAppleMusicController: AppleMusicControlling {
    var isPlaying = false
    var isPaused = false
    var isAuthorized = true
    var isMusicAppRunning = true
    var currentTrackID: String?
    var authStatus: AppleMusicController.AuthStatus = .authorized

    /// Optional override for `playbackSnapshot()`. When set, it is invoked for
    /// every snapshot read, so a test can script a flaky read sequence (e.g. a
    /// `nil` track key on some ticks). When `nil`, the snapshot is derived from
    /// `isPlaying` / `isPaused` / `currentTrackID` so existing tests keep working.
    var snapshotProvider: (() -> PlaybackSnapshot?)?
    var playbackSnapshotCallCount = 0

    var playNowCalled = false
    var playNowCallCount = 0
    var skipCalled = false
    var clearCalled = false
    var clearCallCount = 0
    var clearRequestsPlaylistCalled = false
    var shouldThrowClearRequestsPlaylist = false
    var clearRequestsPlaylistHandler: (() async -> Void)?
    var rebuildCalled = false
    var playFallbackCalled = false
    var fallbackPlaylistName: String?
    var shouldThrowMusicAppNotRunning = false
    var shouldThrowNotPlayable = false
    var searchProvider: ((String) async -> AppleMusicController.SearchResult)?
    var candidateSearchProvider: ((String, Int) async -> (songs: [Song], error: String?))?
    /// When > 0, `playNow` throws `notPlayable` and decrements; once 0 it succeeds.
    var notPlayableThrowsRemaining = 0
    /// Optional suspension seam for deterministic native-clear races.
    var clearPlayerQueueHandler: (() async -> Void)?
    /// Optional same-event target mutation seam for vote-skip race tests.
    var targetedPlaybackHandler:
        ((TargetedPlaybackAction, String) async throws -> Bool)?

    func search(query: String) async -> AppleMusicController.SearchResult {
        if let searchProvider { return await searchProvider(query) }
        return .notFound
    }

    /// Makes `search` resolve, so `processRequest` gets past its `.notFound`
    /// branch and actually reaches the queue-add and auto-play gates.
    ///
    /// Without this every request short-circuits, and any test that asserts
    /// `playNowCalled == false` afterwards passes no matter what the gate under
    /// test does. Call it in any test whose subject is downstream of the search.
    ///
    /// Each distinct query resolves to a distinct song, so two different
    /// requests in one test do not collide on the queue's duplicate check.
    /// Pass `title` only when a test needs one fixed title.
    func stubSearchSuccess(title: String? = nil, artist: String = "Test Artist") {
        searchProvider = { query in
            .found(makeTestSong(
                id: testSongID(for: query),
                title: title ?? query,
                artist: artist
            ))
        }
    }
    func resolve(url: URL) async -> AppleMusicController.SearchResult { .notFound }
    func searchCandidates(query: String, limit: Int) async -> (songs: [Song], error: String?) {
        if let candidateSearchProvider { return await candidateSearchProvider(query, limit) }
        switch await search(query: query) {
        case .found(let song): return ([song], nil)
        case .notFound: return ([], nil)
        case .error(let message): return ([], message)
        }
    }
    func playbackSnapshot() async -> PlaybackSnapshot? {
        playbackSnapshotCallCount += 1
        if let snapshotProvider { return snapshotProvider() }
        let state: PlaybackSnapshot.State = isPlaying ? .playing : (isPaused ? .paused : .stopped)
        return PlaybackSnapshot(state: state, trackKey: currentTrackID)
    }
    func playNow(song: Song) async throws {
        playNowCallCount += 1
        if shouldThrowMusicAppNotRunning { throw PlaybackError.musicAppNotRunning }
        if notPlayableThrowsRemaining > 0 {
            notPlayableThrowsRemaining -= 1
            throw PlaybackError.notPlayable(title: song.title)
        }
        if shouldThrowNotPlayable { throw PlaybackError.notPlayable(title: song.title) }
        playNowCalled = true
    }
    func skipToNext() async throws { skipCalled = true }
    func performTargetedPlayback(
        _ action: TargetedPlaybackAction,
        ifCurrentTrackKeyEquals targetTrackKey: String
    ) async throws -> Bool {
        if let targetedPlaybackHandler {
            return try await targetedPlaybackHandler(action, targetTrackKey)
        }
        guard currentTrackID == targetTrackKey else { return false }
        switch action {
        case .nextTrack:
            skipCalled = true
        case .request:
            playNowCalled = true
            playNowCallCount += 1
        case .fallbackPlaylist(let name):
            playFallbackCalled = true
            fallbackPlaylistName = name
        case .stop:
            clearCalled = true
            clearCallCount += 1
        }
        return true
    }
    func previousTrack() async throws { /* no-op for tests */ }
    func playPause() async throws { /* no-op for tests */ }
    func clearPlayerQueue() async {
        clearCalled = true
        clearCallCount += 1
        await clearPlayerQueueHandler?()
    }
    func clearRequestsPlaylist() async throws {
        clearRequestsPlaylistCalled = true
        await clearRequestsPlaylistHandler?()
        if shouldThrowClearRequestsPlaylist {
            throw PlaybackError.commandFailed(command: "clear requests playlist", message: "test failure")
        }
    }
    func rebuildPlayerQueue(from songs: [Song]) async throws { rebuildCalled = true }
    func playFallbackPlaylist(name: String) async throws {
        playFallbackCalled = true
        fallbackPlaylistName = name
    }
}

/// Deterministically suspends an injected playback operation until a test has
/// performed the queue mutation it wants to race against the eventual result.
actor PlaybackGate {
    private var hasStarted = false
    private var wasReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            if wasReleased {
                continuation.resume()
            } else {
                releaseWaiter = continuation
            }
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        wasReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

// MARK: - SongRequestServiceTests

/// `SongRequestService` request pipeline: access gates (enabled, audience), skip and
/// clear semantics, hold mode, auto-advance and fallback playlist, Music.app-closed
/// buffering, playback-monitor lifecycle, boost, vote-skip application, and chat messages. Uses
/// `MockAppleMusicController` and in-memory storage.
/// Subclasses `WolfWaveTestCase` because the service reads its gates from
/// `DefaultsStore.store`, which other suites also write.
@MainActor
final class SongRequestServiceTests: WolfWaveTestCase {

    var queue: SongRequestQueue!
    var mockController: MockAppleMusicController!
    var service: SongRequestService!

    /// Builds a chat-command request source with sensible defaults.
    func chatSource(
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

    /// Removes every access, queue, and playback setting these tests write, so each test starts
    /// from defaults.
    func clearAccessDefaults() {
        let defaults = DefaultsStore.store
        defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestSubscriberOnly)
        defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestChatAudience)
        defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestMaxQueueSize)
        defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestPerUserLimit)
        defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestHoldEnabled)
        defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestEnabled)
        defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestAutoAdvance)
        defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestAutoplayWhenEmpty)
        defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)
    }

    /// A service whose queue holds one request while a streamer's own track (`streamer-track`) is
    /// playing, for polling tests.
    func makeServiceWithLiveRequest(
        pollInterval: Duration
    ) -> SongRequestService {
        _ = queue.add(makeTestRequestItem(
            title: "Later", artist: "Artist", requesterUsername: "viewer"))
        mockController.isPlaying = true
        mockController.currentTrackID = "streamer-track"
        return SongRequestService(
            queue: queue,
            musicController: mockController,
            pollInterval: pollInterval
        )
    }

    override func setUp() async throws {
        try await super.setUp()
        queue = SongRequestQueue()
        mockController = MockAppleMusicController()
        service = SongRequestService(
            queue: queue,
            musicController: mockController
        )
        clearAccessDefaults()
        // The master toggle defaults off (feature hidden until a streamer turns
        // it on). These tests exercise the request pipeline, so turn it on after
        // clearing defaults; the feature-disabled gate is covered explicitly.
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)
    }

    override func tearDown() async throws {
        service.stopPlaybackMonitoring()
        service = nil
        mockController = nil
        queue = nil
        clearAccessDefaults()
        try await super.tearDown()
    }

    // MARK: - Bit Boost

    func testBoostMovesUsersEarliestItemToFront() async {
        _ = queue.add(makeTestRequestItem(title: "B", artist: "y", requesterUsername: "bob"))
        _ = queue.add(makeTestRequestItem(title: "A", artist: "x", requesterUsername: "alice"))
        _ = queue.add(makeTestRequestItem(title: "C", artist: "z", requesterUsername: "alice"))
        // Streamer's own track is playing, so boost only reorders (no takeover).
        mockController.isMusicAppRunning = true
        mockController.isPlaying = true

        let boosted = await service.boost(username: "alice")

        // Alice's *earliest* queued request (A) jumps the line, not her newest (C).
        XCTAssertEqual(boosted?.title, "A")
        XCTAssertEqual(queue.items.first?.title, "A", "Boosted item should jump to the front")
    }

    func testBoostRejectedWhenFeatureDisabled() async {
        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.songRequestEnabled)
        _ = queue.add(makeTestRequestItem(title: "A", artist: "x", requesterUsername: "alice"))

        let boosted = await service.boost(username: "alice")
        XCTAssertNil(boosted, "Boost must be rejected while the feature is off")
    }

    // MARK: - Fallback On Natural Drain

    func testFallbackPlaylistStartsWhenLastRequestEnds() async {
        service = SongRequestService(
            queue: queue, musicController: mockController, pollInterval: .milliseconds(20))
        DefaultsStore.store.set(
            "Gaming Vibes", forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)

        mockController.isMusicAppRunning = true
        mockController.isPlaying = false
        mockController.isPaused = false

        _ = queue.add(makeTestRequestItem(title: "Last", artist: "a", requesterUsername: "u"))
        queue.dequeue() // nowPlaying = Last, queue now empty

        service.startPlaybackMonitoring()
        let started = await waitUntil(timeout: .seconds(1)) { self.mockController.playFallbackCalled }
        service.stopPlaybackMonitoring()

        XCTAssertTrue(started, "Fallback playlist should start when the queue drains during playback")

        DefaultsStore.store.removeObject(
            forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)
    }

    func testMusicLaunchIgnoredWhenFeatureOff() async {
        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.songRequestEnabled)
        _ = queue.add(makeTestRequestItem(title: "Buffered", artist: "Artist", requesterUsername: "viewer"))
        await service.handleMusicAppLaunched()
        XCTAssertFalse(mockController.playNowCalled)
        XCTAssertEqual(queue.items.count, 1)
    }

    func testMusicLaunchIgnoredWhenAutoAdvanceOff() async {
        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.songRequestAutoAdvance)
        defer { DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.songRequestAutoAdvance) }
        _ = queue.add(makeTestRequestItem(title: "Buffered", artist: "Artist", requesterUsername: "viewer"))
        await service.handleMusicAppLaunched()
        XCTAssertFalse(mockController.playNowCalled)
        XCTAssertEqual(queue.items.count, 1)
    }

    func testMusicLaunchDoesNotStartFallbackWhenNowPlaying() async {
        DefaultsStore.store.set("Fallback", forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)
        defer { DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist) }
        _ = queue.add(makeTestRequestItem(title: "Playing", artist: "Artist", requesterUsername: "viewer"))
        let playing = queue.dequeue()
        mockController.isPlaying = true
        await service.handleMusicAppLaunched()
        XCTAssertFalse(mockController.playFallbackCalled)
        XCTAssertEqual(queue.nowPlaying?.id, playing?.id)
    }

    func testMusicLaunchClearsStaleNowPlayingBeforeFallback() async {
        DefaultsStore.store.set("Fallback", forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist)
        defer { DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.songRequestFallbackPlaylist) }
        _ = queue.add(makeTestRequestItem(title: "Old", artist: "Artist", requesterUsername: "viewer"))
        _ = queue.dequeue()
        mockController.isPlaying = false
        mockController.isPaused = false
        await service.handleMusicAppLaunched()
        XCTAssertNil(queue.nowPlaying)
        XCTAssertTrue(mockController.playFallbackCalled)
    }

    // MARK: - Audience Gate

    func testProcessRequestSubscriberAudienceBlocksViewer() async {
        DefaultsStore.store.set(
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

    func testProcessRequestSubscriberAudienceAllowsSubscriber() async {
        DefaultsStore.store.set(
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

    func testProcessRequestSubscriberAudienceAllowsModerator() async {
        DefaultsStore.store.set(
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

    func testProcessRequestVipAudienceBlocksRegularViewer() async {
        DefaultsStore.store.set(
            RequestAudience.vipsAndSubs.rawValue,
            forKey: AppConstants.UserDefaults.songRequestChatAudience)

        let result = await service.processRequest(
            query: "any song", username: "viewer", source: chatSource(username: "viewer"))
        guard case .error = result else {
            XCTFail("Expected .error blocking a non-VIP/non-sub, got \(result)")
            return
        }
    }

    func testProcessRequestVipAudienceAllowsVIP() async {
        DefaultsStore.store.set(
            RequestAudience.vipsAndSubs.rawValue,
            forKey: AppConstants.UserDefaults.songRequestChatAudience)

        let result = await service.processRequest(
            query: "any song", username: "vip",
            source: chatSource(username: "vip", isVIP: true))
        if case .error(let msg) = result {
            XCTAssertFalse(msg.contains("VIPs"), "VIP should pass the VIPs & Subscribers gate")
        }
    }

    func testProcessRequestRedemptionSourcesBypassAudienceGate() async {
        // Even with the strictest audience, points/bits sources are not gated here.
        //
        // This test used to prove nothing twice over. Its assertions sat inside
        // `if case .error`, which never matched because search resolved to
        // `.notFound` long before any audience decision; and the substring it
        // looked for ("Mods") does not appear in the real denial text
        // ("Only mods can request songs right now."). Moving the audience check
        // to cover every source would have rejected every channel-point and bit
        // request on a mods-only channel with this test still green.
        mockController.stubSearchSuccess()
        DefaultsStore.store.set(
            RequestAudience.modsOnly.rawValue,
            forKey: AppConstants.UserDefaults.songRequestChatAudience)

        // Distinct queries so the second request is not rejected as a duplicate
        // of the first, which would hide the audience answer behind a queue answer.
        let pointsResult = await service.processRequest(
            query: "points song", username: "viewer",
            source: .channelPoints(redemptionID: "r", rewardID: "rw"))
        guard case .added = pointsResult else {
            return XCTFail("channel-point request must bypass the audience gate, got \(pointsResult)")
        }

        let bitsResult = await service.processRequest(
            query: "bits song", username: "viewer", source: .bits(amount: 100))
        guard case .added = bitsResult else {
            return XCTFail("bit request must bypass the audience gate, got \(bitsResult)")
        }

        // The gate really is closed for chat on this channel, so the two passes
        // above are a bypass and not an audience setting that never applied.
        let chatResult = await service.processRequest(
            query: "chat song", username: "viewer", source: chatSource(username: "viewer"))
        if case .error = chatResult {
            // expected: a plain viewer is blocked on a mods-only channel
        } else {
            XCTFail("mods-only audience should block a plain chat viewer, got \(chatResult)")
        }
    }

    // MARK: - Feature Master Gate

    func testProcessRequestRejectedWhenFeatureDisabled() async {
        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.songRequestEnabled)

        let result = await service.processRequest(
            query: "any song", username: "viewer", source: chatSource(username: "viewer"))
        guard case .featureDisabled = result else {
            XCTFail("Expected .featureDisabled when master toggle is off, got \(result)")
            return
        }
        XCTAssertFalse(mockController.playNowCalled, "Disabled feature must not play anything")
        XCTAssertTrue(queue.isEmpty, "Disabled feature must not queue anything")
    }

    func testRedemptionRejectedWhenFeatureDisabled() async {
        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.songRequestEnabled)

        let result = await service.processRequest(
            query: "any song", username: "viewer",
            source: .channelPoints(redemptionID: "r", rewardID: "rw"))
        guard case .featureDisabled = result else {
            XCTFail("Expected .featureDisabled for a redemption while off, got \(result)")
            return
        }
    }

    // MARK: - Access Migration

    func testMigrateAccessSettingsConvertsLegacySubscriberOnly() {
        let defaults = DefaultsStore.store
        defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestChatAudience)
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestSubscriberOnly)

        SongRequestService.migrateAccessSettings()

        XCTAssertEqual(
            defaults.string(forKey: AppConstants.UserDefaults.songRequestChatAudience),
            RequestAudience.subscribers.rawValue)
    }

    func testMigrateAccessSettingsDefaultsToEveryone() {
        let defaults = DefaultsStore.store
        defaults.removeObject(forKey: AppConstants.UserDefaults.songRequestChatAudience)
        defaults.set(false, forKey: AppConstants.UserDefaults.songRequestSubscriberOnly)

        SongRequestService.migrateAccessSettings()

        XCTAssertEqual(
            defaults.string(forKey: AppConstants.UserDefaults.songRequestChatAudience),
            RequestAudience.everyone.rawValue)
    }

    // MARK: - Auth Check

    func testProcessRequestNotAuthorizedReturnsError() async {
        mockController.isAuthorized = false
        mockController.authStatus = .denied

        let result = await service.processRequest(
            query: "any song", username: "user", source: chatSource(username: "user"))
        guard case .notAuthorized = result else {
            XCTFail("Expected .notAuthorized, got \(result)")
            return
        }
    }
}

// MARK: - Vote-skip helper

/// Test shorthand for the capture-then-apply pair used by vote-skip.
@MainActor
extension SongRequestService {
    /// Captures the loaded track and applies a passed vote to it, the same
    /// capture-then-apply pair `AppDelegate` wires into `SkipVoteManager`.
    @discardableResult
    func captureAndVoteSkip() async -> Bool {
        guard let target = await capturePlaybackTarget() else { return false }
        return await voteSkip(target: target)
    }
}
