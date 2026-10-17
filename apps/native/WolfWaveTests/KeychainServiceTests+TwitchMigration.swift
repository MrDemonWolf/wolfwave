//
//  KeychainServiceTests+TwitchMigration.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation

@testable import WolfWave

/// Twitch grant migration (legacy and version one), malformed grants, and the reauth transition.
extension KeychainServiceTests {
    // MARK: - Twitch Token Tests

    @Test("Legacy Twitch fields migrate only after the atomic grant saves")
    func testLegacyTwitchCredentialsMigrateCopyThenDelete() {
        let originalBackend = KeychainService.backend
        let backend = InspectableKeychainBackend()
        KeychainService.backend = backend
        defer { KeychainService.backend = originalBackend }

        backend.seed(account: "twitchBotAccountOauthToken", value: "ACCESS")
        backend.seed(
            account: AppConstants.Keychain.twitchBotAccountRefreshToken,
            value: "REFRESH")
        backend.seed(account: "twitchBotAccountUsername", value: "wolf")
        backend.seed(account: "twitchBotAccountUserID", value: "123")
        backend.seed(account: "twitchChannelIDAccount", value: "channel")

        #expect(
            KeychainService.loadTwitchCredentialGrant()
                == .init(
                    accessToken: "ACCESS",
                    refreshToken: "REFRESH",
                    username: "wolf",
                    userID: "123",
                    channelID: "channel")
        )
        #expect(backend.rawValue(account: KeychainService.twitchCredentialGrantAccount) != nil)
        #expect(backend.rawValue(account: "twitchBotAccountOauthToken") == nil)
        #expect(
            backend.rawValue(
                account: AppConstants.Keychain.twitchBotAccountRefreshToken) == nil)
        #expect(backend.rawValue(account: "twitchBotAccountUsername") == nil)
        #expect(backend.rawValue(account: "twitchBotAccountUserID") == nil)
        #expect(backend.rawValue(account: "twitchChannelIDAccount") == nil)
    }

    @Test("Version-one grant and separate channel migrate copy-then-delete")
    func testVersionOneGrantAndChannelMigrateCopyThenDelete() throws {
        let originalBackend = KeychainService.backend
        let backend = InspectableKeychainBackend()
        KeychainService.backend = backend
        defer { KeychainService.backend = originalBackend }
        let versionOne = KeychainService.TwitchCredentialGrant(
            accessToken: "ACCESS",
            refreshToken: "REFRESH",
            username: "wolf",
            userID: "123"
        )
        let encoded = try #require(
            String(data: JSONEncoder().encode(versionOne), encoding: .utf8)
        )
        backend.seed(
            account: KeychainService.legacyTwitchCredentialGrantAccount,
            value: encoded
        )
        backend.seed(account: "twitchChannelIDAccount", value: "channel")

        let migrated = try KeychainService.loadTwitchCredentialGrantChecked()

        #expect(migrated == .init(
            accessToken: "ACCESS",
            refreshToken: "REFRESH",
            username: "wolf",
            userID: "123",
            channelID: "channel"
        ))
        #expect(backend.rawValue(account: KeychainService.twitchCredentialGrantAccount) != nil)
        #expect(
            backend.rawValue(
                account: KeychainService.legacyTwitchCredentialGrantAccount) == nil)
        #expect(backend.rawValue(account: "twitchChannelIDAccount") == nil)
    }

    @Test("Failed version-one migration preserves both sources for retry")
    func testVersionOneMigrationFailurePreservesGrantAndChannel() throws {
        let originalBackend = KeychainService.backend
        let backend = InspectableKeychainBackend()
        KeychainService.backend = backend
        defer { KeychainService.backend = originalBackend }
        let versionOne = KeychainService.TwitchCredentialGrant(
            accessToken: "ACCESS",
            refreshToken: "REFRESH"
        )
        let encoded = try #require(
            String(data: JSONEncoder().encode(versionOne), encoding: .utf8)
        )
        backend.seed(
            account: KeychainService.legacyTwitchCredentialGrantAccount,
            value: encoded
        )
        backend.seed(account: "twitchChannelIDAccount", value: "channel")
        backend.failNextSave(for: KeychainService.twitchCredentialGrantAccount)

        let inMemory = try KeychainService.loadTwitchCredentialGrantChecked()

        #expect(inMemory.channelID == "channel")
        #expect(backend.rawValue(account: KeychainService.twitchCredentialGrantAccount) == nil)
        #expect(
            backend.rawValue(
                account: KeychainService.legacyTwitchCredentialGrantAccount) == encoded)
        #expect(backend.rawValue(account: "twitchChannelIDAccount") == "channel")
        #expect(try KeychainService.loadTwitchCredentialGrantChecked() == inMemory)
        #expect(backend.rawValue(account: KeychainService.twitchCredentialGrantAccount) != nil)
        #expect(
            backend.rawValue(
                account: KeychainService.legacyTwitchCredentialGrantAccount) == nil)
        #expect(backend.rawValue(account: "twitchChannelIDAccount") == nil)
    }

    @Test("Version-two grant never adopts a stale separate channel")
    func testCurrentGrantWinsOverStaleLegacyChannel() throws {
        let originalBackend = KeychainService.backend
        let backend = InspectableKeychainBackend()
        KeychainService.backend = backend
        defer { KeychainService.backend = originalBackend }
        let current = KeychainService.TwitchCredentialGrant(accessToken: "ACCESS")
        try KeychainService.saveTwitchCredentialGrant(current)
        backend.seed(account: "twitchChannelIDAccount", value: "stale-channel")

        #expect(try KeychainService.loadTwitchCredentialGrantChecked() == current)
        #expect(KeychainService.loadTwitchChannelID() == nil)
    }

    @Test("Failed atomic migration leaves every legacy field for retry")
    func testLegacyTwitchMigrationFailurePreservesSourceFields() {
        let originalBackend = KeychainService.backend
        let backend = InspectableKeychainBackend()
        KeychainService.backend = backend
        defer { KeychainService.backend = originalBackend }

        backend.seed(account: "twitchBotAccountOauthToken", value: "ACCESS")
        backend.seed(
            account: AppConstants.Keychain.twitchBotAccountRefreshToken,
            value: "REFRESH")
        backend.seed(account: "twitchBotAccountUsername", value: "wolf")
        backend.seed(account: "twitchBotAccountUserID", value: "123")
        backend.seed(account: "twitchChannelIDAccount", value: "channel")
        backend.failNextSave(for: KeychainService.twitchCredentialGrantAccount)

        let legacy = KeychainService.loadTwitchCredentialGrant()
        #expect(legacy.accessToken == "ACCESS")
        #expect(legacy.refreshToken == "REFRESH")
        #expect(legacy.channelID == "channel")
        #expect(backend.rawValue(account: KeychainService.twitchCredentialGrantAccount) == nil)
        #expect(backend.rawValue(account: "twitchBotAccountOauthToken") == "ACCESS")
        #expect(
            backend.rawValue(
                account: AppConstants.Keychain.twitchBotAccountRefreshToken) == "REFRESH")
        #expect(backend.rawValue(account: "twitchBotAccountUsername") == "wolf")
        #expect(backend.rawValue(account: "twitchBotAccountUserID") == "123")
        #expect(backend.rawValue(account: "twitchChannelIDAccount") == "channel")

        // The one-shot failure is gone, so the next read retries migration.
        #expect(KeychainService.loadTwitchCredentialGrant() == legacy)
        #expect(backend.rawValue(account: KeychainService.twitchCredentialGrantAccount) != nil)
        #expect(backend.rawValue(account: "twitchBotAccountOauthToken") == nil)
        #expect(backend.rawValue(account: "twitchBotAccountUsername") == nil)
        #expect(backend.rawValue(account: "twitchBotAccountUserID") == nil)
        #expect(backend.rawValue(account: "twitchChannelIDAccount") == nil)
    }

    @Test("Malformed atomic Twitch grant fails closed instead of mixing legacy fields")
    func testMalformedAtomicTwitchGrantRequiresReauthentication() {
        let originalBackend = KeychainService.backend
        let backend = InspectableKeychainBackend()
        KeychainService.backend = backend
        Preferences.setTwitchReauthNeeded(false)
        defer {
            Preferences.setTwitchReauthNeeded(false)
            KeychainService.backend = originalBackend
        }

        backend.seed(
            account: KeychainService.twitchCredentialGrantAccount,
            value: "not-json")
        backend.seed(account: "twitchBotAccountOauthToken", value: "STALE_ACCESS")

        #expect(KeychainService.loadTwitchCredentialGrant() == .empty)
        #expect(KeychainService.loadTwitchCredentialGrant() == .empty)
        #expect(Preferences.twitchReauthNeeded)
        #expect(
            backend.rawValue(
                account: KeychainService.twitchCredentialGrantAccount) == "not-json")
        #expect(backend.rawValue(account: "twitchBotAccountOauthToken") == "STALE_ACCESS")
    }

    @Test("Repeated reads of a malformed grant post the re-auth change once")
    func testMalformedGrantPostsReauthChangeOnlyOnTransition() async throws {
        let originalBackend = KeychainService.backend
        let backend = InspectableKeychainBackend()
        KeychainService.backend = backend
        Preferences.setTwitchReauthNeeded(false)
        defer {
            Preferences.setTwitchReauthNeeded(false)
            KeychainService.backend = originalBackend
        }
        backend.seed(account: KeychainService.twitchCredentialGrantAccount, value: "not-json")

        let posts = Atomic(0)
        // Posted from a main-actor task, so deliveries arrive on main one at a time.
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name.twitchReauthNeededChanged,
            object: nil,
            queue: nil
        ) { _ in posts.set(posts.value + 1) }
        defer { NotificationCenter.default.removeObserver(observer) }

        for _ in 0..<3 {
            _ = KeychainService.loadTwitchCredentialGrant()
        }

        // Poll rather than hop onto main: a hosted XCTest suite can be parked
        // on the main thread, and awaiting MainActor here would wait on it.
        let deadline = ContinuousClock.now + .seconds(5)
        while posts.value == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        // Give any extra (buggy) posts time to land too.
        try await Task.sleep(for: .milliseconds(300))

        #expect(Preferences.twitchReauthNeeded)
        #expect(posts.value == 1)
    }

    @Test("Malformed version-one grant stays authoritative across repeated reads")
    func testMalformedVersionOneGrantNeverExposesPerFieldFallback() {
        let originalBackend = KeychainService.backend
        let backend = InspectableKeychainBackend()
        KeychainService.backend = backend
        Preferences.setTwitchReauthNeeded(false)
        defer {
            Preferences.setTwitchReauthNeeded(false)
            KeychainService.backend = originalBackend
        }
        backend.seed(
            account: KeychainService.legacyTwitchCredentialGrantAccount,
            value: "not-json"
        )
        backend.seed(account: "twitchBotAccountOauthToken", value: "STALE_ACCESS")
        backend.seed(account: "twitchChannelIDAccount", value: "stale-channel")

        #expect(KeychainService.loadTwitchCredentialGrant() == .empty)
        #expect(KeychainService.loadTwitchCredentialGrant() == .empty)
        #expect(Preferences.twitchReauthNeeded)
        #expect(
            backend.rawValue(
                account: KeychainService.legacyTwitchCredentialGrantAccount)
                == "not-json"
        )
        #expect(backend.rawValue(account: "twitchBotAccountOauthToken") == "STALE_ACCESS")
        #expect(backend.rawValue(account: "twitchChannelIDAccount") == "stale-channel")
        #expect(backend.rawValue(account: KeychainService.twitchCredentialGrantAccount) == nil)
    }

    @Test("Malformed per-field grant remains intact across repeated reads")
    func testMalformedPerFieldGrantNeverExposesPartialCredential() {
        let originalBackend = KeychainService.backend
        let backend = InspectableKeychainBackend()
        KeychainService.backend = backend
        Preferences.setTwitchReauthNeeded(false)
        defer {
            Preferences.setTwitchReauthNeeded(false)
            KeychainService.backend = originalBackend
        }
        backend.seed(account: "twitchBotAccountOauthToken", value: "")
        backend.seed(
            account: AppConstants.Keychain.twitchBotAccountRefreshToken,
            value: "REFRESH"
        )
        backend.seed(account: "twitchChannelIDAccount", value: "channel")

        #expect(KeychainService.loadTwitchCredentialGrant() == .empty)
        #expect(KeychainService.loadTwitchCredentialGrant() == .empty)
        #expect(Preferences.twitchReauthNeeded)
        #expect(backend.rawValue(account: "twitchBotAccountOauthToken") == "")
        #expect(
            backend.rawValue(
                account: AppConstants.Keychain.twitchBotAccountRefreshToken)
                == "REFRESH"
        )
        #expect(backend.rawValue(account: "twitchChannelIDAccount") == "channel")
        #expect(backend.rawValue(account: KeychainService.twitchCredentialGrantAccount) == nil)
    }

    @Test("Atomic grant read failure never probes or mutates legacy credentials")
    func testAtomicGrantLoadFailureDoesNotInspectLegacy() throws {
        let originalBackend = KeychainService.backend
        let backend = InspectableKeychainBackend()
        KeychainService.backend = backend
        defer { KeychainService.backend = originalBackend }

        let legacyFields = [
            (KeychainService.legacyTwitchCredentialGrantAccount, "v1"),
            ("twitchBotAccountOauthToken", "ACCESS"),
            (AppConstants.Keychain.twitchBotAccountRefreshToken, "REFRESH"),
            ("twitchBotAccountUsername", "wolf"),
            ("twitchBotAccountUserID", "123"),
            ("twitchChannelIDAccount", "channel")
        ]
        for (account, value) in legacyFields {
            backend.seed(account: account, value: value)
        }
        backend.failNextLoad(
            for: KeychainService.twitchCredentialGrantAccount,
            status: -25308)

        #expect(throws: KeychainService.KeychainError.self) {
            _ = try KeychainService.loadTwitchCredentialGrantChecked()
        }
        #expect(
            backend.loadCount(
                account: KeychainService.twitchCredentialGrantAccount) == 1)
        for (account, value) in legacyFields {
            #expect(backend.loadCount(account: account) == 0)
            #expect(backend.rawValue(account: account) == value)
        }
    }

    @Test("Every legacy delete failure preserves the canonical Twitch grant")
    func testLegacyDeleteFailuresPreserveCanonicalGrant() throws {
        let originalBackend = KeychainService.backend
        defer { KeychainService.backend = originalBackend }
        let legacyAccounts = [
            KeychainService.legacyTwitchCredentialGrantAccount,
            "twitchBotAccountOauthToken",
            AppConstants.Keychain.twitchBotAccountRefreshToken,
            "twitchBotAccountUsername",
            "twitchBotAccountUserID",
            "twitchChannelIDAccount"
        ]
        let grant = KeychainService.TwitchCredentialGrant(
            accessToken: "ACCESS",
            refreshToken: "REFRESH",
            username: "wolf",
            userID: "123")

        for failingAccount in legacyAccounts {
            let backend = InspectableKeychainBackend()
            KeychainService.backend = backend
            try KeychainService.saveTwitchCredentialGrant(grant)
            for account in legacyAccounts {
                backend.seed(account: account, value: "legacy-\(account)")
            }
            let canonical = backend.rawValue(
                account: KeychainService.twitchCredentialGrantAccount)
            backend.failNextDelete(for: failingAccount)

            #expect(throws: KeychainService.KeychainError.self) {
                try KeychainService.deleteTwitchCredentialGrant()
            }
            #expect(
                backend.rawValue(
                    account: KeychainService.twitchCredentialGrantAccount)
                    == canonical)
            let surviving = try KeychainService.loadTwitchCredentialGrantChecked()
            #expect(surviving == grant)
        }
    }
}
