//
//  KeychainServiceTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-02-27.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation
@testable import WolfWave

/// Comprehensive test suite for KeychainService.
///
/// Runs against an in-memory backend (`InMemoryKeychainBackend`) so the suite
/// never touches the real Keychain. Ad-hoc test signing otherwise triggers an
/// ACL prompt that blocks cold reads and fails CI. The previous backend is
/// restored after each test so other suites see unchanged behavior.
///
/// Note: `.serialized` keeps tests sequential, matching the shared-backend model.
@Suite("Keychain Service Tests", .serialized, .isolatedKeychainBackend)
final class KeychainServiceTests {

    let previousBackend: KeychainBackend
    let previousReauthNeeded: Bool

    init() {
        SharedTestStateIsolation.acquire()
        previousBackend = KeychainService.backend
        // The suite flips this directly, and KeychainService sets it on grant
        // failure, so it must go back the way it was found or the next lock
        // holder inherits a stale value.
        previousReauthNeeded = Preferences.twitchReauthNeeded
        KeychainService.backend = InMemoryKeychainBackend()
    }

    deinit {
        Preferences.setTwitchReauthNeeded(previousReauthNeeded)
        KeychainService.backend = previousBackend
        SharedTestStateIsolation.release()
    }

    @Test("Test hosts default to process-local credentials")
    func testHostUsesInMemoryBackend() {
        #expect(WolfWaveApp.isRunningTests)
        #expect(previousBackend is InMemoryKeychainBackend)
        #expect(KeychainService.makeDefaultBackend(isRunningTests: true) is InMemoryKeychainBackend)
    }

    // MARK: - Suite Isolation

    /// Pins `.isolatedKeychainBackend`. A trait that silently stopped binding
    /// would leave every test below passing while the suite went back to sharing
    /// one process-wide backend with the suites running beside it.
    @Test("Suite runs against a task-scoped backend")
    func testSuiteBindsTaskScopedBackend() {
        #expect(KeychainService.backendBox != nil)
    }

    /// The property the whole suite depends on: a backend installed in here is
    /// unreachable from a task outside the scope, so a parallel suite can
    /// neither observe nor mutate it.
    @Test("Backends installed in the suite stay invisible to outside tasks")
    func testInstalledBackendIsInvisibleOutsideTheSuite() async {
        let originalBackend = KeychainService.backend
        let marker = InspectableKeychainBackend()
        KeychainService.backend = marker
        defer { KeychainService.backend = originalBackend }

        let outside = await Task.detached { KeychainService.backend }.value

        #expect(KeychainService.backend as AnyObject === marker)
        #expect(outside as AnyObject !== marker)
    }

    // MARK: - Token Save/Load/Delete Tests

    @Test("Save and load token successfully")
    func testSaveAndLoadToken() async throws {
        let testToken = "test_token_\(UUID().uuidString)"

        // Save token
        try KeychainService.saveToken(testToken)

        // Load token
        let loadedToken = KeychainService.loadToken()

        // Verify
        #expect(loadedToken == testToken)

        // Cleanup
        try KeychainService.deleteToken()
    }

    @Test("Delete token removes it from keychain")
    func testDeleteToken() async throws {
        let testToken = "test_token_delete"

        // Save token
        try KeychainService.saveToken(testToken)

        // Verify it exists
        #expect(KeychainService.loadToken() == testToken)

        // Delete token
        try KeychainService.deleteToken()

        // Verify it's gone
        #expect(KeychainService.loadToken() == nil)
    }

    @Test("Save empty token throws error")
    func testSaveEmptyToken() async throws {
        // Attempt to save empty token should throw
        #expect(throws: KeychainService.KeychainError.self) {
            try KeychainService.saveToken("")
        }
    }

    @Test("Update existing token")
    func testUpdateToken() async throws {
        let token1 = "first_token"
        let token2 = "second_token"

        // Save first token
        try KeychainService.saveToken(token1)
        #expect(KeychainService.loadToken() == token1)

        // Update to second token
        try KeychainService.saveToken(token2)
        #expect(KeychainService.loadToken() == token2)

        // Cleanup
        try KeychainService.deleteToken()
    }

    @Test("Control token has independent save, load, and delete lifecycle")
    func testControlTokenRoundTrip() async throws {
        let token = "control_token"

        try KeychainService.saveControlToken(token)

        #expect(KeychainService.loadControlToken() == token)
        #expect(KeychainService.loadToken() == nil)

        try KeychainService.deleteControlToken()
        #expect(KeychainService.loadControlToken() == nil)
    }

    @Test("Save empty control token throws error")
    func testSaveEmptyControlToken() async throws {
        #expect(throws: KeychainService.KeychainError.self) {
            try KeychainService.saveControlToken("")
        }
    }

    // MARK: - Special Characters Tests

    @Test("Handle special characters in saved values")
    func testSpecialCharacters() async throws {
        let specialToken = "token_with_!@#$%^&*()_+-=[]{}|;:',.<>?/~`"

        try KeychainService.saveToken(specialToken)
        let loaded = KeychainService.loadToken()

        #expect(loaded == specialToken)

        try KeychainService.deleteToken()
    }

    @Test("Handle Unicode in saved values")
    func testUnicodeCharacters() async throws {
        let unicodeUsername = "testbot_🐺🎵"

        try KeychainService.saveTwitchCredentialGrant(
            .init(accessToken: "ACCESS", username: unicodeUsername)
        )
        let loaded = KeychainService.loadTwitchUsername()

        #expect(loaded == unicodeUsername)

        try KeychainService.deleteTwitchCredentialGrant()
    }

    // MARK: - Concurrent Access Tests

    @Test("Concurrent save and load operations are thread-safe")
    func testConcurrentAccess() async throws {
        let iterations = 50
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "keychain.stress", attributes: .concurrent)
        let readResults = ThreadSafeBox<[String?]>(
            Array(repeating: nil, count: iterations))

        // These blocks run on GCD threads, outside this test's task tree, so the
        // suite's task-scoped backend does not reach them on its own. Rebinding
        // it keeps the stress on real threads rather than the cooperative pool.
        let box = KeychainService.backendBox

        // Seed with a known value first
        try KeychainService.saveToken("seed_token")

        // Concurrent writes and reads on real threads
        for i in 0..<iterations {
            group.enter()
            queue.async {
                let token = "concurrent_token_\(i)"
                KeychainService.$backendBox.withValue(box) {
                    try? KeychainService.saveToken(token)
                }
                group.leave()
            }

            group.enter()
            queue.async {
                let loaded = KeychainService.$backendBox.withValue(box) {
                    KeychainService.loadToken()
                }
                readResults.mutate { $0[i] = loaded }
                group.leave()
            }
        }

        await withCheckedContinuation { continuation in
            group.notify(queue: .global()) { continuation.resume() }
        }

        // Validate: every read should have returned a non-nil, non-empty token
        // (since we seeded and continuously wrote valid tokens)
        for (index, result) in readResults.value.enumerated() {
            #expect(result != nil, "Read at index \(index) returned nil: possible corruption")
            if let value = result {
                #expect(!value.isEmpty, "Read at index \(index) returned empty string: possible corruption")
            }
        }

        // Final state: a valid token should be loadable
        let finalToken = KeychainService.loadToken()
        #expect(finalToken != nil, "Final read after concurrent stress should return a valid token")

        // Cleanup
        try KeychainService.deleteToken()
    }

    // MARK: - Error Handling Tests

    @Test("KeychainError has correct descriptions")
    func testKeychainErrorDescriptions() async throws {
        let saveError = KeychainService.KeychainError.saveFailed(-25300)
        #expect(saveError.errorDescription == "Failed to save item to Keychain (status: -25300)")

        let loadError = KeychainService.KeychainError.loadFailed(-25308)
        #expect(loadError.errorDescription == "Failed to load item from Keychain (status: -25308)")

        let deleteError = KeychainService.KeychainError.deleteFailed(-25308)
        #expect(deleteError.errorDescription == "Failed to delete item from Keychain (status: -25308)")

        let invalidError = KeychainService.KeychainError.invalidData
        #expect(invalidError.errorDescription == "Invalid Keychain item data")
    }

    @Test("Save failed errors with different status codes are distinct")
    func testSaveFailedWithDifferentStatus() async throws {
        let error1 = KeychainService.KeychainError.saveFailed(-25299)
        let error2 = KeychainService.KeychainError.saveFailed(-25300)
        #expect(error1.errorDescription != error2.errorDescription)
    }

    @Test("Delete nonexistent key does not throw")
    func testDeleteNonexistentKeyDoesNotThrow() async throws {
        try KeychainService.deleteTwitchCredentialGrant()
        try KeychainService.deleteTwitchCredentialGrant()
        // Should succeed silently
        #expect(true)
    }

    // MARK: - Overwrite Contract

    @Test("saveToken overwrites a pre-existing value")
    func testSaveTokenOverwritesExistingValue() async throws {
        // Seed a stale value, then overwrite via the public API. The upsert path
        // must replace it without throwing. (The SystemKeychainBackend's
        // duplicate-add race fallback performs a value-only update without
        // deleting the existing ACL/accessibility metadata. That Security-only
        // path is exercised in integration, not by the in-memory backend.)
        try KeychainService.saveToken("stale_token")
        #expect(KeychainService.loadToken() == "stale_token")

        let fresh = "fresh_token_\(UUID().uuidString)"
        try KeychainService.saveToken(fresh)
        #expect(KeychainService.loadToken() == fresh)

        try KeychainService.deleteToken()
    }

    // MARK: - Factory Reset

    @Test("deleteAll removes every stored credential")
    func testDeleteAllRemovesEveryCredential() async throws {
        // Seed one of each credential the factory reset must wipe.
        try KeychainService.saveToken("ws_token")
        try KeychainService.saveControlToken("ws_control_token")
        try KeychainService.saveTwitchCredentialGrant(
            .init(
                accessToken: "twitch_oauth",
                refreshToken: "twitch_refresh",
                username: "wolf",
                userID: "12345",
                channelID: "67890"
            )
        )

        try KeychainService.deleteAll()

        #expect(KeychainService.loadToken() == nil)
        #expect(KeychainService.loadControlToken() == nil)
        #expect(KeychainService.loadTwitchToken() == nil)
        #expect(KeychainService.loadTwitchCredentialGrant().refreshToken == nil)
        #expect(KeychainService.loadTwitchUsername() == nil)
        #expect(KeychainService.loadTwitchBotUserID() == nil)
        #expect(KeychainService.loadTwitchChannelID() == nil)
    }

    @Test("deleteAll on an empty store succeeds silently")
    func testDeleteAllWhenEmpty() async throws {
        try KeychainService.deleteAll()
        #expect(KeychainService.loadToken() == nil)
        #expect(KeychainService.loadControlToken() == nil)
    }
}
