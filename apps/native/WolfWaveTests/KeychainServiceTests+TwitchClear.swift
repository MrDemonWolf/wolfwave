//
//  KeychainServiceTests+TwitchClear.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation

@testable import WolfWave

/// Twitch grant clear prefixes, channel compare-and-swap, and credential clearing.
extension KeychainServiceTests {
    @Test("Every version-one clear prefix materializes the complete v2 grant")
    func testVersionOneClearPrefixesRemainCoherent() throws {
        let originalBackend = KeychainService.backend
        defer { KeychainService.backend = originalBackend }
        let legacyAccounts = [
            KeychainService.legacyTwitchCredentialGrantAccount,
            "twitchBotAccountOauthToken",
            AppConstants.Keychain.twitchBotAccountRefreshToken,
            "twitchBotAccountUsername",
            "twitchBotAccountUserID",
            "twitchChannelIDAccount",
            KeychainService.twitchCredentialGrantAccount
        ]
        let versionOne = KeychainService.TwitchCredentialGrant(
            accessToken: "ACCESS",
            refreshToken: "REFRESH",
            username: "wolf",
            userID: "123"
        )
        let encoded = try #require(
            String(data: JSONEncoder().encode(versionOne), encoding: .utf8)
        )
        let expected = KeychainService.TwitchCredentialGrant(
            accessToken: "ACCESS",
            refreshToken: "REFRESH",
            username: "wolf",
            userID: "123",
            channelID: "channel"
        )

        for failingAccount in legacyAccounts {
            let backend = InspectableKeychainBackend()
            KeychainService.backend = backend
            backend.seed(
                account: KeychainService.legacyTwitchCredentialGrantAccount,
                value: encoded
            )
            backend.seed(account: "twitchChannelIDAccount", value: "channel")
            backend.failNextDelete(for: failingAccount)

            #expect(throws: KeychainService.KeychainError.self) {
                try KeychainService.deleteTwitchCredentialGrant()
            }
            #expect(
                try KeychainService.loadTwitchCredentialGrantChecked()
                    == expected
            )
        }
    }

    @Test("Every per-field clear prefix materializes the complete v2 grant")
    func testPerFieldClearPrefixesRemainCoherent() throws {
        let originalBackend = KeychainService.backend
        defer { KeychainService.backend = originalBackend }
        let legacyValues = [
            "twitchBotAccountOauthToken": "ACCESS",
            AppConstants.Keychain.twitchBotAccountRefreshToken: "REFRESH",
            "twitchBotAccountUsername": "wolf",
            "twitchBotAccountUserID": "123",
            "twitchChannelIDAccount": "channel"
        ]
        let deleteAccounts = [
            KeychainService.legacyTwitchCredentialGrantAccount,
            "twitchBotAccountOauthToken",
            AppConstants.Keychain.twitchBotAccountRefreshToken,
            "twitchBotAccountUsername",
            "twitchBotAccountUserID",
            "twitchChannelIDAccount",
            KeychainService.twitchCredentialGrantAccount
        ]
        let expected = KeychainService.TwitchCredentialGrant(
            accessToken: "ACCESS",
            refreshToken: "REFRESH",
            username: "wolf",
            userID: "123",
            channelID: "channel"
        )

        for failingAccount in deleteAccounts {
            let backend = InspectableKeychainBackend()
            KeychainService.backend = backend
            for (account, value) in legacyValues {
                backend.seed(account: account, value: value)
            }
            backend.failNextDelete(for: failingAccount)

            #expect(throws: KeychainService.KeychainError.self) {
                try KeychainService.deleteTwitchCredentialGrant()
            }
            #expect(
                try KeychainService.loadTwitchCredentialGrantChecked()
                    == expected
            )
        }
    }

    @Test("Malformed legacy clear prefixes remain behind an authoritative tombstone")
    func testMalformedLegacyClearPrefixesNeverExposeFallback() throws {
        let originalBackend = KeychainService.backend
        defer {
            Preferences.setTwitchReauthNeeded(false)
            KeychainService.backend = originalBackend
        }
        let deleteAccounts = [
            KeychainService.legacyTwitchCredentialGrantAccount,
            "twitchBotAccountOauthToken",
            AppConstants.Keychain.twitchBotAccountRefreshToken,
            "twitchBotAccountUsername",
            "twitchBotAccountUserID",
            "twitchChannelIDAccount",
            KeychainService.twitchCredentialGrantAccount
        ]

        for failingAccount in deleteAccounts {
            let backend = InspectableKeychainBackend()
            KeychainService.backend = backend
            Preferences.setTwitchReauthNeeded(false)
            backend.seed(
                account: KeychainService.legacyTwitchCredentialGrantAccount,
                value: "not-json"
            )
            backend.seed(account: "twitchBotAccountOauthToken", value: "STALE_ACCESS")
            backend.seed(account: "twitchChannelIDAccount", value: "stale-channel")
            backend.failNextDelete(for: failingAccount)

            #expect(throws: KeychainService.KeychainError.self) {
                try KeychainService.deleteTwitchCredentialGrant()
            }
            #expect(try KeychainService.loadTwitchCredentialGrantChecked() == .empty)
            #expect(
                backend.rawValue(
                    account: KeychainService.twitchCredentialGrantAccount) != nil
            )
            #expect(Preferences.twitchReauthNeeded)
        }
    }

    @Test("Clear aborts before deleting legacy data when the v2 barrier cannot save")
    func testLegacyClearBarrierSaveFailurePreservesEverySource() throws {
        let originalBackend = KeychainService.backend
        let backend = InspectableKeychainBackend()
        KeychainService.backend = backend
        defer { KeychainService.backend = originalBackend }
        let fields = [
            "twitchBotAccountOauthToken": "ACCESS",
            AppConstants.Keychain.twitchBotAccountRefreshToken: "REFRESH",
            "twitchBotAccountUsername": "wolf",
            "twitchBotAccountUserID": "123",
            "twitchChannelIDAccount": "channel"
        ]
        for (account, value) in fields {
            backend.seed(account: account, value: value)
        }
        backend.failNextSave(for: KeychainService.twitchCredentialGrantAccount)

        #expect(throws: InspectableKeychainBackend.InjectedError.self) {
            try KeychainService.deleteTwitchCredentialGrant()
        }

        for (account, value) in fields {
            #expect(backend.rawValue(account: account) == value)
        }
        #expect(backend.rawValue(account: KeychainService.twitchCredentialGrantAccount) == nil)
    }

    @Test("Channel-preserving clear failure preserves the account and revision")
    func testChannelPreservingClearFailurePreservesAccountAndRevision() throws {
        let originalBackend = KeychainService.backend
        let backend = InspectableKeychainBackend()
        KeychainService.backend = backend
        defer { KeychainService.backend = originalBackend }
        let grant = KeychainService.TwitchCredentialGrant(
            accessToken: "ACCESS",
            refreshToken: "REFRESH",
            username: "wolf",
            userID: "123",
            channelID: "channel")
        try KeychainService.saveTwitchCredentialGrant(grant)
        let snapshot = try #require(
            TwitchCredentialStore.shared.connectionSnapshot(
                matchingAccessToken: "ACCESS"))
        backend.failNextSave(
            for: KeychainService.twitchCredentialGrantAccount)

        #expect(throws: InspectableKeychainBackend.InjectedError.self) {
            try TwitchCredentialStore.shared.clearCredentials(
                includingChannel: false)
        }

        #expect(try KeychainService.loadTwitchCredentialGrantChecked() == grant)
        #expect(
            TwitchCredentialStore.shared.revision(
                matchingAccessToken: "ACCESS") == snapshot.revision)
    }

    @Test("Channel-preserving clear atomically leaves only the channel")
    func testChannelPreservingClearLeavesChannelOnly() throws {
        let originalBackend = KeychainService.backend
        let backend = InspectableKeychainBackend()
        KeychainService.backend = backend
        defer { KeychainService.backend = originalBackend }
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "ACCESS",
                refreshToken: "REFRESH",
                username: "wolf",
                userID: "123",
                channelID: "channel"
            )
        )

        try TwitchCredentialStore.shared.clearCredentials(includingChannel: false)

        #expect(
            try KeychainService.loadTwitchCredentialGrantChecked()
                == .init(channelID: "channel"))
        #expect(KeychainService.loadTwitchToken() == nil)
        #expect(KeychainService.loadTwitchChannelID() == "channel")
    }

    @Test("Full clear failure preserves the complete account and revision")
    func testFullClearFailurePreservesAccountAndRevision() throws {
        let originalBackend = KeychainService.backend
        let backend = InspectableKeychainBackend()
        KeychainService.backend = backend
        defer { KeychainService.backend = originalBackend }
        let grant = KeychainService.TwitchCredentialGrant(
            accessToken: "ACCESS",
            refreshToken: "REFRESH",
            username: "wolf",
            userID: "123",
            channelID: "channel"
        )
        try KeychainService.saveTwitchCredentialGrant(grant)
        let snapshot = try #require(
            TwitchCredentialStore.shared.connectionSnapshot(
                matchingAccessToken: "ACCESS")
        )
        backend.failNextDelete(
            for: KeychainService.twitchCredentialGrantAccount
        )

        #expect(throws: KeychainService.KeychainError.self) {
            try TwitchCredentialStore.shared.clearCredentials(
                includingChannel: true)
        }

        #expect(try KeychainService.loadTwitchCredentialGrantChecked() == grant)
        #expect(
            TwitchCredentialStore.shared.connectionSnapshot(
                matchingAccessToken: "ACCESS") == snapshot
        )
    }

    @Test("Channel updates preserve the grant and stale CAS cannot overwrite it")
    func testChannelUpdateAndCompareAndSwap() throws {
        let originalBackend = KeychainService.backend
        let backend = InspectableKeychainBackend()
        KeychainService.backend = backend
        defer { KeychainService.backend = originalBackend }
        let grant = KeychainService.TwitchCredentialGrant(
            accessToken: "ACCESS",
            refreshToken: "REFRESH",
            username: "wolf",
            userID: "123",
            channelID: "old-channel"
        )
        try KeychainService.saveTwitchCredentialGrant(grant)
        let original = try #require(
            TwitchCredentialStore.shared.connectionSnapshot(
                matchingAccessToken: "ACCESS")
        )

        try TwitchCredentialStore.shared.updateChannelID("old-channel")
        #expect(
            TwitchCredentialStore.shared.connectionSnapshot(
                matchingAccessToken: "ACCESS") == original
        )

        try TwitchCredentialStore.shared.updateChannelID("new-channel")
        let updated = try KeychainService.loadTwitchCredentialGrantChecked()
        #expect(updated.accessToken == grant.accessToken)
        #expect(updated.refreshToken == grant.refreshToken)
        #expect(updated.username == grant.username)
        #expect(updated.userID == grant.userID)
        #expect(updated.channelID == "new-channel")
        let staleCommit = try TwitchCredentialStore.shared.commitChannelID(
            "stale-channel",
            expected: original
        )
        #expect(staleCommit == nil)
        #expect(
            try KeychainService.loadTwitchCredentialGrantChecked().channelID
                == "new-channel"
        )
    }

    @Test("Channel CAS commits once, no-ops unchanged, and preserves state on failure")
    func testChannelCompareAndSwapCommitLifecycle() throws {
        let originalBackend = KeychainService.backend
        let backend = InspectableKeychainBackend()
        KeychainService.backend = backend
        defer { KeychainService.backend = originalBackend }
        let originalGrant = KeychainService.TwitchCredentialGrant(
            accessToken: "ACCESS",
            refreshToken: "REFRESH",
            username: "wolf",
            userID: "123",
            channelID: "old-channel"
        )
        try KeychainService.saveTwitchCredentialGrant(originalGrant)
        let originalSnapshot = try #require(
            TwitchCredentialStore.shared.connectionSnapshot(
                matchingAccessToken: "ACCESS")
        )

        let commitResult = try TwitchCredentialStore.shared.commitChannelID(
            "new-channel",
            expected: originalSnapshot
        )
        let committed = try #require(commitResult)
        #expect(committed.channelID == "new-channel")
        #expect(committed.revision == originalSnapshot.revision &+ 1)
        let afterCommit = try KeychainService.loadTwitchCredentialGrantChecked()
        #expect(afterCommit.accessToken == originalGrant.accessToken)
        #expect(afterCommit.refreshToken == originalGrant.refreshToken)
        #expect(afterCommit.username == originalGrant.username)
        #expect(afterCommit.userID == originalGrant.userID)
        #expect(afterCommit.channelID == "new-channel")

        let unchangedResult = try TwitchCredentialStore.shared.commitChannelID(
            "new-channel",
            expected: committed
        )
        let unchanged = try #require(unchangedResult)
        #expect(unchanged == committed)

        backend.failNextSave(
            for: KeychainService.twitchCredentialGrantAccount
        )
        #expect(throws: InspectableKeychainBackend.InjectedError.self) {
            try TwitchCredentialStore.shared.commitChannelID(
                "failed-channel",
                expected: unchanged
            )
        }
        #expect(try KeychainService.loadTwitchCredentialGrantChecked() == afterCommit)
        #expect(
            TwitchCredentialStore.shared.connectionSnapshot(
                matchingAccessToken: "ACCESS") == unchanged
        )
    }

    @Test("Credential clear removes every legacy field and canonical grant")
    func testCredentialClearRemovesLegacyAndCanonicalItems() throws {
        let originalBackend = KeychainService.backend
        let backend = InspectableKeychainBackend()
        KeychainService.backend = backend
        defer { KeychainService.backend = originalBackend }
        let legacyAccounts = [
            KeychainService.legacyTwitchCredentialGrantAccount,
            "twitchBotAccountOauthToken",
            AppConstants.Keychain.twitchBotAccountRefreshToken,
            "twitchBotAccountUsername",
            "twitchBotAccountUserID",
            "twitchChannelIDAccount"
        ]
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "ACCESS",
                refreshToken: "REFRESH",
                username: "wolf",
                userID: "123"))
        for account in legacyAccounts {
            backend.seed(account: account, value: "legacy")
        }

        try KeychainService.deleteTwitchCredentialGrant()

        for account in legacyAccounts {
            #expect(backend.rawValue(account: account) == nil)
        }
        #expect(
            backend.rawValue(
                account: KeychainService.twitchCredentialGrantAccount) == nil)
        #expect(try KeychainService.loadTwitchCredentialGrantChecked() == .empty)
    }

    @Test("Factory reset Keychain deletion failure preserves stored data")
    func testDeleteAllFailurePreservesCredentials() throws {
        let originalBackend = KeychainService.backend
        let backend = InspectableKeychainBackend()
        KeychainService.backend = backend
        defer { KeychainService.backend = originalBackend }
        try KeychainService.saveToken("overlay-token")
        backend.failNextDeleteAll(status: -25308)

        #expect(throws: KeychainService.KeychainError.self) {
            try KeychainService.deleteAll()
        }
        #expect(KeychainService.loadToken() == "overlay-token")
    }

    @Test("Auth clear failure preserves credentials, UI, and validation owner")
    func testClearAuthFailurePreservesState() async throws {
        let originalBackend = KeychainService.backend
        let backend = InspectableKeychainBackend()
        KeychainService.backend = backend
        defer { KeychainService.backend = originalBackend }
        let grant = KeychainService.TwitchCredentialGrant(
            accessToken: "ACCESS",
            refreshToken: "REFRESH",
            username: "wolf",
            userID: "123",
            channelID: "channel")
        try KeychainService.saveTwitchCredentialGrant(grant)
        let revision = try #require(
            TwitchCredentialStore.shared.revision(
                matchingAccessToken: "ACCESS"))
        let cancellations = ThreadSafeBox(0)
        let restarts = ThreadSafeBox(0)
        let viewModel = await MainActor.run {
            let viewModel = TwitchViewModel(
                cancelTokenValidationSchedule: {
                    cancellations.mutate { $0 += 1 }
                },
                restartTokenValidationSchedule: {
                    restarts.mutate { $0 += 1 }
                },
                leaveAccountService: { _, _ in true })
            viewModel.botUsername = "wolf"
            viewModel.oauthToken = "ACCESS"
            viewModel.channelID = "channel"
            viewModel.credentialsSaved = true
            return viewModel
        }
        backend.failNextSave(
            for: KeychainService.twitchCredentialGrantAccount)

        let cleared = await viewModel.clearAuthOnly()
        let viewState = await MainActor.run {
            (
                botUsername: viewModel.botUsername,
                oauthToken: viewModel.oauthToken,
                channelID: viewModel.channelID,
                credentialsSaved: viewModel.credentialsSaved,
                errorID: viewModel.connectionError?.id,
                isAccountTeardownInProgress: viewModel.isAccountTeardownInProgress
            )
        }

        #expect(!cleared)
        #expect(viewState.botUsername == "wolf")
        #expect(viewState.oauthToken == "ACCESS")
        #expect(viewState.channelID == "channel")
        #expect(viewState.credentialsSaved)
        #expect(viewState.errorID == "twitch.credentialClearFailed")
        #expect(!viewState.isAccountTeardownInProgress)
        #expect(cancellations.value == 1)
        #expect(restarts.value == 1)
        #expect(try KeychainService.loadTwitchCredentialGrantChecked() == grant)
        #expect(
            TwitchCredentialStore.shared.revision(
                matchingAccessToken: "ACCESS") == revision)
    }

    @Test("Full Twitch grant backs every read convenience")
    func testFullTwitchGrantReadConveniences() throws {
        let grant = KeychainService.TwitchCredentialGrant(
            accessToken: "ACCESS",
            refreshToken: "REFRESH",
            username: "wolf",
            userID: "123",
            channelID: "channel"
        )

        try KeychainService.saveTwitchCredentialGrant(grant)

        #expect(KeychainService.loadTwitchToken() == "ACCESS")
        #expect(KeychainService.loadTwitchCredentialGrant().refreshToken == "REFRESH")
        #expect(KeychainService.loadTwitchUsername() == "wolf")
        #expect(KeychainService.loadTwitchBotUserID() == "123")
        #expect(KeychainService.loadTwitchChannelID() == "channel")
    }

    @Test("Empty field in full Twitch grant throws error")
    func testEmptyTwitchGrantFieldThrows() {
        #expect(throws: KeychainService.KeychainError.self) {
            try KeychainService.saveTwitchCredentialGrant(.init(accessToken: ""))
        }
    }
}
