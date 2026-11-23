//
//  SongContentFilterTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-11-23.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation
@testable import WolfWave

/// The explicit filter and max song length: the pure rule, how it is read from
/// settings, what setup writes, how the service applies it, and the chat replies
/// for each refusal (plus the separate blocked-requester reply).
@Suite("Song content filter", .serialized, .isolatedSharedTestState)
@MainActor
struct SongContentFilterTests {

    private let viewer = BotCommandContext(
        userID: "viewer-1",
        username: "viewer",
        isModerator: false,
        isBroadcaster: false,
        isSubscriber: false,
        isVIP: false,
        messageID: "m1")

    // MARK: - Pure rule

    @Test("explicit songs are refused only while the filter is on")
    func explicitRule() {
        let blocking = SongContentFilter(blocksExplicit: true, maxSeconds: 0)
        let allowing = SongContentFilter(blocksExplicit: false, maxSeconds: 0)

        #expect(blocking.refusal(isExplicit: true, durationSeconds: 200) == .explicit)
        #expect(blocking.refusal(isExplicit: false, durationSeconds: 200) == nil)
        #expect(allowing.refusal(isExplicit: true, durationSeconds: 200) == nil)
    }

    @Test(
        "songs over the max are refused; at the max, unknown, or no limit pass",
        arguments: [
            (360, 361.0 as Double?, true),
            (360, 360.0 as Double?, false),
            (360, 360.4 as Double?, false),
            (360, nil as Double?, false),
            (0, 3_600.0 as Double?, false)
        ])
    func lengthRule(maxSeconds: Int, duration: Double?, refused: Bool) {
        let filter = SongContentFilter(blocksExplicit: false, maxSeconds: maxSeconds)
        #expect((filter.refusal(isExplicit: false, durationSeconds: duration) != nil) == refused)
    }

    @Test("explicit wins when a song breaks both rules")
    func explicitCheckedFirst() {
        let filter = SongContentFilter(blocksExplicit: true, maxSeconds: 60)
        #expect(filter.refusal(isExplicit: true, durationSeconds: 600) == .explicit)
    }

    @Test("clock formats whole seconds as m:ss", arguments: [(581, "9:41"), (360, "6:00"), (5, "0:05")])
    func clock(seconds: Int, expected: String) {
        #expect(SongContentFilter.clock(seconds) == expected)
    }

    // MARK: - Stored settings

    @Test("unset settings read as off, so an existing setup never changes")
    func unsetReadsOff() {
        let scratch = ThrowawayDefaults("SongContentFilterTests.unset")
        defer { scratch.destroy() }

        #expect(SongContentFilter.current(in: scratch.defaults)
            == SongContentFilter(blocksExplicit: false, maxSeconds: 0))
    }

    @Test("setup fills unset rules with explicit blocked and a 6 min max")
    func setupFillsUnsetRules() {
        let scratch = ThrowawayDefaults("SongContentFilterTests.setupFills")
        defer { scratch.destroy() }

        #expect(SongRequestSetupViewModel.contentRulesAfterSetup(defaults: scratch.defaults)
            == SongContentFilter(blocksExplicit: true, maxSeconds: 360))
    }

    @Test("setup keeps rules the streamer already chose")
    func setupKeepsChoices() {
        let scratch = ThrowawayDefaults("SongContentFilterTests.setupKeeps")
        defer { scratch.destroy() }
        scratch.defaults.set(false, forKey: AppConstants.UserDefaults.songRequestBlockExplicit)
        scratch.defaults.set(0, forKey: AppConstants.UserDefaults.songRequestMaxSongSeconds)

        #expect(SongRequestSetupViewModel.contentRulesAfterSetup(defaults: scratch.defaults)
            == SongContentFilter(blocksExplicit: false, maxSeconds: 0))
    }

    // MARK: - Service

    /// A live service whose every search resolves to one fixed song.
    private func service(
        durationInMillis: Int = 180_000,
        contentRating: String? = nil,
        blocklist: SongBlocklist = SongBlocklist(storage: InMemoryBlocklistStorage())
    ) -> SongRequestService {
        let music = MockAppleMusicController()
        music.searchProvider = { query in
            .found(makeTestSong(
                id: testSongID(for: query),
                title: query,
                durationInMillis: durationInMillis,
                contentRating: contentRating))
        }
        return SongRequestService(blocklist: blocklist, musicController: music)
    }

    @Test("the service refuses an explicit song while the filter is on")
    func serviceRefusesExplicit() async {
        let defaults = DefaultsStore.store
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestBlockExplicit)

        let result = await service(contentRating: "explicit").processRequest(
            query: "loud song", username: "viewer", source: .chatCommand(viewer))

        guard case .explicitBlocked = result else {
            Issue.record("Expected .explicitBlocked, got \(result)")
            return
        }
    }

    @Test("the service refuses a song over the max length")
    func serviceRefusesLongSong() async {
        let defaults = DefaultsStore.store
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)
        defaults.set(360, forKey: AppConstants.UserDefaults.songRequestMaxSongSeconds)

        let result = await service(durationInMillis: 581_000).processRequest(
            query: "long song", username: "viewer", source: .chatCommand(viewer))

        guard case let .tooLong(durationSeconds, maxSeconds) = result else {
            Issue.record("Expected .tooLong, got \(result)")
            return
        }
        #expect(durationSeconds == 581)
        #expect(maxSeconds == 360)
    }

    @Test("a clean song inside the limit is still queued")
    func serviceQueuesAllowedSong() async {
        let defaults = DefaultsStore.store
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)
        defaults.set(true, forKey: AppConstants.UserDefaults.songRequestBlockExplicit)
        defaults.set(360, forKey: AppConstants.UserDefaults.songRequestMaxSongSeconds)

        let result = await service(contentRating: "clean").processRequest(
            query: "nice song", username: "viewer", source: .chatCommand(viewer))

        guard case .added = result else {
            Issue.record("Expected .added, got \(result)")
            return
        }
    }

    @Test("a blocked person gets the requester result, not the song one")
    func serviceReportsBlockedRequester() async {
        DefaultsStore.store.set(true, forKey: AppConstants.UserDefaults.songRequestEnabled)
        let blocklist = SongBlocklist(storage: InMemoryBlocklistStorage())
        await blocklist.add(BlocklistItem(value: "viewer", type: .requester))

        let result = await service(blocklist: blocklist).processRequest(
            query: "any song", username: "viewer", source: .chatCommand(viewer))

        guard case .requesterBlocked = result else {
            Issue.record("Expected .requesterBlocked, got \(result)")
            return
        }
    }

    // MARK: - Replies

    @Test("!sr explains each refusal in plain words")
    func chatReplies() {
        #expect(SongRequestCommand.reply(for: .requesterBlocked) == "Sorry, you can't request songs here.")
        #expect(SongRequestCommand.reply(for: .explicitBlocked)
            == "That song is marked explicit. Try the clean version!")
        #expect(SongRequestCommand.reply(for: .tooLong(durationSeconds: 581, maxSeconds: 360))
            == "That song is 9:41. The max here is 6:00.")
    }

    @Test("channel points are refunded for every content refusal; Bits say why")
    func paidReplies() async {
        let twitch = TwitchChatService()

        for result: SongRequestService.RequestResult in [
            .requesterBlocked, .explicitBlocked, .tooLong(durationSeconds: 581, maxSeconds: 360)
        ] {
            let points = await twitch.redemptionOutcome(for: result, username: "viewer")
            #expect(points.resolution == .canceled)
            #expect(points.message.hasSuffix("Refunding your points."))
        }

        let bits = await twitch.bitsOutcomeMessage(
            for: .tooLong(durationSeconds: 581, maxSeconds: 360), username: "viewer")
        #expect(bits == "@viewer That song is 9:41. The max here is 6:00.")
    }
}
