//
//  SongRequestCommandTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-04-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest

@testable import WolfWave

@MainActor
final class SongRequestCommandTests: WolfWaveTestCase {

    override func setUp() {
        super.setUp()
        resetAllSettings()
    }

    override func tearDown() {
        resetAllSettings()
        super.tearDown()
    }

    // MARK: - SongRequestCommand Triggers

    func testSongRequestCommandTriggers() {
        let command = SongRequestCommand()
        XCTAssertEqual(command.triggers, ["!sr", "!request", "!songrequest"])
    }

    func testSongRequestCommandDefaultEnabled() {
        let command = SongRequestCommand()
        XCTAssertTrue(command.isCommandEnabled)
    }

    func testSongRequestCommandDisabled() {
        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.srCommandEnabled)
        let command = SongRequestCommand()
        XCTAssertFalse(command.isCommandEnabled)
    }

    func testSongRequestCommandSyncExecuteReturnsNil() {
        let command = SongRequestCommand()
        // AsyncBotCommand sync execute should return nil
        XCTAssertNil(command.execute(message: "!sr test"))
    }

    // MARK: - QueueCommand Triggers

    func testQueueCommandTriggers() {
        let command = QueueCommand()
        XCTAssertEqual(command.triggers, ["!queue", "!songlist", "!requests"])
    }

    func testQueueCommandEmptyResponse() {
        let command = QueueCommand()
        let queue = SongRequestQueue()
        command.getQueue = { queue }
        let response = command.execute(message: "!queue")
        XCTAssertEqual(response, "Queue is empty. Request a song with !sr <song name>")
    }

    // MARK: - SkipCommand

    func testSkipCommandTriggers() {
        let command = SkipCommand()
        XCTAssertEqual(command.triggers, ["!skip", "!next"])
    }

    // MARK: - ClearQueueCommand

    func testClearQueueCommandTriggers() {
        let command = ClearQueueCommand()
        XCTAssertEqual(command.triggers, ["!clearqueue", "!cq"])
    }

    // MARK: - MyQueueCommand

    func testMyQueueCommandTriggers() {
        let command = MyQueueCommand()
        XCTAssertEqual(command.triggers, ["!myqueue", "!mysongs"])
    }

    // MARK: - Custom Aliases

    func testCustomAliasesAdded() {
        DefaultsStore.store.set("play, add", forKey: AppConstants.UserDefaults.srCommandAliases)
        let command = SongRequestCommand()
        let allTriggers = command.allTriggers
        XCTAssertTrue(allTriggers.contains("!play"))
        XCTAssertTrue(allTriggers.contains("!add"))
        // Original triggers still present
        XCTAssertTrue(allTriggers.contains("!sr"))
        XCTAssertTrue(allTriggers.contains("!request"))
    }

    func testCustomAliasesWithBangPrefix() {
        DefaultsStore.store.set("!play", forKey: AppConstants.UserDefaults.srCommandAliases)
        let command = SongRequestCommand()
        let allTriggers = command.allTriggers
        XCTAssertTrue(allTriggers.contains("!play"))
        // Should not double-prefix
        XCTAssertFalse(allTriggers.contains("!!play"))
    }

    func testEmptyAliases() {
        DefaultsStore.store.set("", forKey: AppConstants.UserDefaults.srCommandAliases)
        let command = SongRequestCommand()
        // Should just have original triggers
        XCTAssertEqual(command.allTriggers.count, command.triggers.count)
    }

    // MARK: - Query Extraction

    func testExtractQueryDropsOnlyTheTriggerToken() {
        XCTAssertEqual(SongRequestCommand.extractQuery(from: "!sr hello world"), "hello world")
        XCTAssertEqual(SongRequestCommand.extractQuery(from: "!SR   spaced out  "), "spaced out")
        XCTAssertEqual(SongRequestCommand.extractQuery(from: "!sr"), "")
        XCTAssertEqual(SongRequestCommand.extractQuery(from: "!request2 abc"), "abc")
    }

    /// An alias that extends a base trigger (`!srq` vs `!sr`) used to be
    /// stripped by the shorter prefix, sending "q hello world" to the search.
    func testAliasExtendingBaseTriggerKeepsFullQuery() async {
        let defaults = DefaultsStore.store
        defaults.set("srq", forKey: AppConstants.UserDefaults.srCommandAliases)
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)
        let queries = ThreadSafeBox<[String]>([])
        let music = MockAppleMusicController()
        music.searchProvider = { query in
            queries.mutate { $0.append(query) }
            return .notFound
        }
        let service = SongRequestService(
            blocklist: SongBlocklist(storage: InMemoryBlocklistStorage()),
            musicController: music)
        let dispatcher = BotCommandDispatcher()
        dispatcher.setSongRequestService { service }
        let viewer = BotCommandContext(
            userID: "1", username: "viewer",
            isModerator: false, isBroadcaster: false,
            isSubscriber: false, isVIP: false, messageID: "m")

        _ = await dispatcher.processMessageAsync("!srq hello world", userID: "1", context: viewer)

        XCTAssertEqual(queries.value, ["hello world"])
    }

    // MARK: - Preflight

    private func viewer(subscriber: Bool = false, moderator: Bool = false) -> BotCommandContext {
        BotCommandContext(
            userID: "1", username: "viewer",
            isModerator: moderator, isBroadcaster: false,
            isSubscriber: subscriber, isVIP: false, messageID: "m")
    }

    func testPreflightSilentWhenFeatureOff() {
        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.songRequestEnabled)
        XCTAssertEqual(SongRequestCommand().preflightDenial(context: viewer()), .silent)
    }

    func testPreflightRepliesWhenFeatureOffAndReplyOptedIn() {
        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.songRequestEnabled)
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.songRequestDisabledReplyEnabled)
        XCTAssertEqual(
            SongRequestCommand().preflightDenial(context: viewer()),
            .reply(SongRequestCommand.disabledReply))
    }

    func testPreflightDeniesViewerOutsideAudience() {
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)
        DefaultsStore.store.set(
            RequestAudience.subscribers.rawValue, forKey: AppConstants.UserDefaults.songRequestChatAudience)
        let command = SongRequestCommand()
        XCTAssertEqual(
            command.preflightDenial(context: viewer()),
            .reply(RequestAudience.subscribers.denialMessage))
        XCTAssertNil(command.preflightDenial(context: viewer(subscriber: true)))
        XCTAssertNil(command.preflightDenial(context: viewer(moderator: true)))
    }

    // MARK: - Enable/Disable via Dispatcher

    func testDispatcherSkipsDisabledCommand() async {
        DefaultsStore.store.set(false, forKey: AppConstants.UserDefaults.queueCommandEnabled)
        let dispatcher = BotCommandDispatcher()
        let result = await dispatcher.processMessageAsync("!queue", context: nil)
        XCTAssertNil(result)
    }

    // MARK: - BotCommandContext

    func testContextPrivileged() {
        let modContext = BotCommandContext(
            userID: "123", username: "moduser",
            isModerator: true, isBroadcaster: false,
            isSubscriber: false, isVIP: false, messageID: "msg1"
        )
        XCTAssertTrue(modContext.isPrivileged)

        let broadcasterContext = BotCommandContext(
            userID: "456", username: "streamer",
            isModerator: false, isBroadcaster: true,
            isSubscriber: false, isVIP: false, messageID: "msg2"
        )
        XCTAssertTrue(broadcasterContext.isPrivileged)

        let viewerContext = BotCommandContext(
            userID: "789", username: "viewer",
            isModerator: false, isBroadcaster: false,
            isSubscriber: true, isVIP: false, messageID: "msg3"
        )
        XCTAssertFalse(viewerContext.isPrivileged)
    }

    // MARK: - Link Detection

    func testSpotifyLinkDetection() {
        XCTAssertEqual(LinkResolverService.detectedService(in: "https://open.spotify.com/track/abc123"), .spotify)
        XCTAssertNotEqual(LinkResolverService.detectedService(in: "bohemian rhapsody"), .spotify)
        XCTAssertNotEqual(LinkResolverService.detectedService(in: "https://youtube.com/watch?v=abc"), .spotify)
    }

    func testYouTubeLinkDetection() {
        XCTAssertEqual(LinkResolverService.detectedService(in: "https://youtube.com/watch?v=abc123"), .youtube)
        XCTAssertEqual(LinkResolverService.detectedService(in: "https://youtu.be/abc123"), .youtube)
        XCTAssertEqual(LinkResolverService.detectedService(in: "https://music.youtube.com/watch?v=abc"), .youtube)
        XCTAssertNotEqual(LinkResolverService.detectedService(in: "bohemian rhapsody"), .youtube)
    }

    func testAppleMusicLinkDetection() {
        XCTAssertEqual(LinkResolverService.detectedService(in: "https://music.apple.com/us/album/song/123?i=456"), .appleMusic)
        XCTAssertNotEqual(LinkResolverService.detectedService(in: "bohemian rhapsody"), .appleMusic)
        XCTAssertNotEqual(LinkResolverService.detectedService(in: "https://open.spotify.com/track/abc"), .appleMusic)
    }

    func testMusicLinkDetection() {
        XCTAssertNotNil(LinkResolverService.extractURL(from: "https://open.spotify.com/track/abc123"))
        XCTAssertNotNil(LinkResolverService.extractURL(from: "https://youtu.be/abc123"))
        XCTAssertNotNil(LinkResolverService.extractURL(from: "https://music.apple.com/us/album/song/123?i=456"))
        XCTAssertNil(LinkResolverService.extractURL(from: "just a song name"))
    }

    func testExtractURL() {
        XCTAssertEqual(
            LinkResolverService.extractURL(from: "!sr https://open.spotify.com/track/abc123"),
            "https://open.spotify.com/track/abc123"
        )
        XCTAssertNil(LinkResolverService.extractURL(from: "!sr bohemian rhapsody"))
    }

    // MARK: - Blocklist

    func testBlocklistAddAndCheck() async {
        let blocklist = SongBlocklist(storage: InMemoryBlocklistStorage())
        await blocklist.clearAll()

        let songItem = BlocklistItem(value: "Bad Song", type: .song)
        await blocklist.add(songItem)
        let blocked1 = await blocklist.isBlocked(title: "Bad Song", artist: "Any Artist")
        let blocked2 = await blocklist.isBlocked(title: "bad song", artist: "Any Artist")
        let blocked3 = await blocklist.isBlocked(title: "Good Song", artist: "Any Artist")
        XCTAssertTrue(blocked1)
        XCTAssertTrue(blocked2)
        XCTAssertFalse(blocked3)

        let artistItem = BlocklistItem(value: "Bad Artist", type: .artist)
        await blocklist.add(artistItem)
        let blocked4 = await blocklist.isBlocked(title: "Any Song", artist: "Bad Artist")
        let blocked5 = await blocklist.isBlocked(title: "Any Song", artist: "bad artist")
        let blocked6 = await blocklist.isBlocked(title: "Any Song", artist: "Good Artist")
        XCTAssertTrue(blocked4)
        XCTAssertTrue(blocked5)
        XCTAssertFalse(blocked6)

        await blocklist.clearAll()
    }

    func testBlocklistRemove() async {
        let blocklist = SongBlocklist(storage: InMemoryBlocklistStorage())
        await blocklist.clearAll()

        let item = BlocklistItem(value: "Remove Me", type: .song)
        await blocklist.add(item)
        let before = await blocklist.isBlocked(title: "Remove Me", artist: "")
        XCTAssertTrue(before)

        await blocklist.remove(id: item.id)
        let after = await blocklist.isBlocked(title: "Remove Me", artist: "")
        XCTAssertFalse(after)

        await blocklist.clearAll()
    }

    func testBlocklistNoDuplicates() async {
        let blocklist = SongBlocklist(storage: InMemoryBlocklistStorage())
        await blocklist.clearAll()

        let item1 = BlocklistItem(value: "Duplicate", type: .song)
        let item2 = BlocklistItem(value: "duplicate", type: .song)
        await blocklist.add(item1)
        await blocklist.add(item2) // Should be ignored (case-insensitive)
        let count = await blocklist.allEntries.count
        XCTAssertEqual(count, 1)

        await blocklist.clearAll()
    }

    // MARK: - QueueCommand Output

    func testQueueCommandWithNowPlayingAndItems() {
        let command = QueueCommand()
        let queue = SongRequestQueue()
        command.getQueue = { queue }

        // Set up: dequeue one item as now-playing, leave one in queue
        _ = queue.add(makeTestRequestItem(title: "Playing Song", artist: "Artist A", requesterUsername: "viewer1"))
        _ = queue.add(makeTestRequestItem(title: "Next Song", artist: "Artist B", requesterUsername: "viewer2"))
        queue.dequeue() // moves "Playing Song" to nowPlaying

        let response = command.execute(message: "!queue")
        XCTAssertNotNil(response)
        XCTAssertTrue(response!.contains("Now playing:"))
        XCTAssertTrue(response!.contains("Playing Song"))
        XCTAssertTrue(response!.contains("Next Song"))
        XCTAssertTrue(response!.contains("Queue (1):"))
    }

    func testQueueCommandShowsUpToFiveItems() {
        let command = QueueCommand()
        let queue = SongRequestQueue()
        command.getQueue = { queue }
        DefaultsStore.store.set(10, forKey: AppConstants.UserDefaults.songRequestMaxQueueSize)
        DefaultsStore.store.set(10, forKey: AppConstants.UserDefaults.songRequestPerUserLimit)

        for i in 1...7 {
            _ = queue.add(makeTestRequestItem(title: "Song \(i)", artist: "Artist", requesterUsername: "user\(i)"))
        }

        let response = command.execute(message: "!queue")
        XCTAssertNotNil(response)
        XCTAssertTrue(response!.contains("...and 2 more"))

        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.songRequestMaxQueueSize)
        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.songRequestPerUserLimit)
    }

    func testQueueCommandExactlyFiveItemsNoOverflow() {
        let command = QueueCommand()
        let queue = SongRequestQueue()
        command.getQueue = { queue }
        DefaultsStore.store.set(10, forKey: AppConstants.UserDefaults.songRequestMaxQueueSize)
        DefaultsStore.store.set(10, forKey: AppConstants.UserDefaults.songRequestPerUserLimit)

        for i in 1...5 {
            _ = queue.add(makeTestRequestItem(title: "Song \(i)", artist: "Artist", requesterUsername: "user\(i)"))
        }

        let response = command.execute(message: "!queue")
        XCTAssertNotNil(response)
        XCTAssertFalse(response!.contains("more"))

        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.songRequestMaxQueueSize)
        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.songRequestPerUserLimit)
    }

    // MARK: - MyQueueCommand Output

    func testMyQueueCommandWithItems() async {
        let command = MyQueueCommand()
        let queue = SongRequestQueue()
        command.getQueue = { queue }
        DefaultsStore.store.set(10, forKey: AppConstants.UserDefaults.songRequestPerUserLimit)

        _ = queue.add(makeTestRequestItem(title: "My Song 1", artist: "Artist", requesterUsername: "testuser"))
        _ = queue.add(makeTestRequestItem(title: "Other Song", artist: "Artist", requesterUsername: "other"))
        _ = queue.add(makeTestRequestItem(title: "My Song 2", artist: "Artist2", requesterUsername: "testuser"))

        let context = BotCommandContext(
            userID: "999", username: "testuser",
            isModerator: false, isBroadcaster: false,
            isSubscriber: false, isVIP: false, messageID: "m1"
        )

        let reply = await command.execute(message: "!myqueue", context: context)

        XCTAssertNotNil(reply)
        XCTAssertTrue(reply!.contains("My Song 1"))
        XCTAssertTrue(reply!.contains("My Song 2"))
        XCTAssertFalse(reply!.contains("Other Song"))
        XCTAssertTrue(reply!.contains("#1"))
        XCTAssertTrue(reply!.contains("#3"))

        DefaultsStore.store.removeObject(forKey: AppConstants.UserDefaults.songRequestPerUserLimit)
    }

    func testMyQueueCommandNoItemsPrompt() async {
        let command = MyQueueCommand()
        let queue = SongRequestQueue()
        command.getQueue = { queue }

        let context = BotCommandContext(
            userID: "999", username: "emptyuser",
            isModerator: false, isBroadcaster: false,
            isSubscriber: false, isVIP: false, messageID: "m2"
        )

        let reply = await command.execute(message: "!myqueue", context: context)

        XCTAssertNotNil(reply)
        XCTAssertTrue(reply!.contains("!sr"))
    }

    // MARK: - Privilege Checks (silent ignore)

    func testSkipCommandSilentlyIgnoresNonPrivileged() async {
        let command = SkipCommand()
        let context = BotCommandContext(
            userID: "1", username: "viewer",
            isModerator: false, isBroadcaster: false,
            isSubscriber: false, isVIP: false, messageID: "m")
        let reply = await command.execute(message: "!skip", context: context)
        XCTAssertNil(reply)
    }

    func testClearQueueCommandSilentlyIgnoresNonPrivileged() async {
        let command = ClearQueueCommand()
        let context = BotCommandContext(
            userID: "1", username: "viewer",
            isModerator: false, isBroadcaster: false,
            isSubscriber: false, isVIP: false, messageID: "m")
        let reply = await command.execute(message: "!clearqueue", context: context)
        XCTAssertNil(reply)
    }
}
