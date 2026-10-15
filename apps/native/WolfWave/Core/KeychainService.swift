//
//  KeychainService.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-01-08.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Secure credential storage using the macOS Keychain.
///
/// Provides a type-safe interface for storing and retrieving sensitive credentials.
/// With the system backend, all items use `kSecAttrAccessibleAfterFirstUnlock`
/// accessibility for persistence after unlock. Storage goes through
/// ``backend``: the Security framework in the app, process-local memory under
/// any test harness.
///
/// Stored Credentials:
/// - **Overlay Auth Token**: Read-only WebSocket credential used by OBS widgets
/// - **Control Auth Token**: Same-Mac WebSocket credential used by Stream Deck
/// - **Twitch account** (one item, ``TwitchCredentialGrant``): access token,
///   refresh token, bot username, bot user ID, and the normalized channel
///   login, written together so a crash can never pair fields from two
///   different accounts. Older installs kept these as separate items (and a v1
///   grant without the channel); they are migrated copy-then-delete on read.
///
/// Error Handling:
/// - All save operations throw `KeychainError` on failure
/// - Load operations return nil if not found; checked grant reads preserve failures
/// - Delete operations throw on failure and succeed silently if absent
///
/// Thread Safety:
/// - Keychain operations are thread-safe (backed by Security framework)
/// - Twitch grant reads, writes, migration, and the factory reset are
///   serialized by one `NSLock`, so a read-modify-write cannot interleave
/// - Safe to call from any thread, but every call is synchronous Keychain I/O:
///   keep it off the main thread where latency matters (e.g. menu tracking)
///
/// Usage Example:
/// ```swift
/// try KeychainService.saveTwitchCredentialGrant(
///     .init(accessToken: "oauth_token_here", channelID: "channel")
/// )
/// if let token = KeychainService.loadTwitchToken() {
///     // Use token for Twitch API calls
/// }
/// ```
nonisolated enum KeychainService {
    /// One crash-atomic Twitch account record. Keeping access, refresh, resolved
    /// identity, and the configured channel in one Keychain item prevents
    /// force-quit windows from cross-pairing different account configurations.
    ///
    /// Stored as JSON in one generic-password item. Every non-nil field must be
    /// non-empty; a record that breaks that rule is treated as malformed.
    nonisolated struct TwitchCredentialGrant: Codable, Equatable, Sendable {
        /// OAuth access token for Helix and EventSub.
        var accessToken: String?
        /// OAuth refresh token, used to renew ``accessToken``.
        var refreshToken: String?
        /// Bot account login, resolved from the token.
        var username: String?
        /// Bot account numeric user ID, resolved from the token.
        var userID: String?
        /// Legacy field name; stores a normalized channel login, not a numeric Helix ID.
        var channelID: String?

        /// No account. Saving it deletes the record.
        static let empty = TwitchCredentialGrant()

        /// Whether every field is nil.
        var isEmpty: Bool {
            accessToken == nil
                && refreshToken == nil
                && username == nil
                && userID == nil
                && channelID == nil
        }

        /// Memberwise init with every field defaulting to nil.
        init(
            accessToken: String? = nil,
            refreshToken: String? = nil,
            username: String? = nil,
            userID: String? = nil,
            channelID: String? = nil
        ) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.username = username
            self.userID = userID
            self.channelID = channelID
        }
    }

    // MARK: - Constants

    /// Service identifier for Keychain items.
    ///
    /// Scoped to the running bundle identifier so DEBUG (`…wolfwave.dev`) and
    /// release (`com.mrdemonwolf.wolfwave`) builds keep separate items. Without
    /// this, every rebuild whose code signature differs from the binary that
    /// originally wrote the item triggers a "WolfWave wants to use your
    /// confidential information stored in … keychain" ACL prompt.
    ///
    /// Release bundle ID is preserved verbatim to keep existing users' tokens
    /// readable after upgrade.
    private static let service: String = {
        let releaseBundleID = "com.mrdemonwolf.wolfwave"
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            return releaseBundleID
        }
        return bundleID
    }()

    /// Account identifier for the read-only overlay token. The legacy account
    /// name is intentionally preserved so existing OBS URLs survive upgrade.
    private static let websocketAuthToken = "websocketAuthToken"

    /// Account identifier for the privileged, loopback-only control token.
    private static let websocketControlToken = "websocketControlToken"

    /// Account identifier for Twitch OAuth token.
    private static let twitchBotAccountOauthToken = "twitchBotAccountOauthToken"

    /// Account identifier for the Twitch OAuth refresh token.
    private static let twitchBotAccountRefreshToken = AppConstants.Keychain.twitchBotAccountRefreshToken

    /// Account identifier for Twitch bot username.
    private static let twitchBotAccountUsername = "twitchBotAccountUsername"

    /// Account identifier for Twitch bot user ID.
    private static let twitchBotAccountUserID = "twitchBotAccountUserID"

    /// Versioned crash-atomic replacement for the legacy Twitch items. Version 2
    /// adds the configured channel so manual token/channel saves are one write.
    /// Internal so migration/failure tests can identify the one atomic write.
    static let twitchCredentialGrantAccount = "twitchBotCredentialGrant.v2"

    /// Version 1 held access, refresh, username, and user ID while channel was a
    /// separate item. It remains readable only as a copy-before-delete source.
    static let legacyTwitchCredentialGrantAccount = "twitchBotCredentialGrant.v1"

    /// Serializes read-modify-write access and one-time legacy migration.
    private static let twitchCredentialLock = NSLock()

    /// Precedence-preserving result of reading the pre-v2 Twitch accounts.
    private enum LegacyTwitchCredentialSource {
        /// No v1 record and no per-field items.
        case absent
        /// A complete, valid account to migrate.
        case valid(TwitchCredentialGrant)
        /// Undecodable v1, or a field stored as an empty string.
        case malformed
    }

    /// Legacy account identifier for the normalized Twitch channel login.
    private static let twitchChannelIDAccount = "twitchChannelIDAccount"

    // MARK: - Error Types

    /// Errors that can occur during Keychain operations.
    enum KeychainError: LocalizedError {
        /// Failed to save data to Keychain with given Security framework status code.
        case saveFailed(OSStatus)

        /// Failed to load data from Keychain with the Security framework status.
        case loadFailed(OSStatus)

        /// Failed to delete data from Keychain with the Security framework status.
        case deleteFailed(OSStatus)

        /// Invalid or corrupted data read from Keychain.
        case invalidData

        /// Short description for logs. Says "token" for every account, even
        /// non-token items, for historical reasons.
        var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Failed to save token to Keychain (status: \(status))"
            case .loadFailed(let status):
                return "Failed to load token from Keychain (status: \(status))"
            case .deleteFailed(let status):
                return "Failed to delete token from Keychain (status: \(status))"
            case .invalidData:
                return "Invalid token data"
            }
        }
    }

    // MARK: - Public Methods - WebSocket Tokens

    /// Saves the read-only overlay authentication token to Keychain.
    ///
    /// Uses update-or-add pattern for efficiency (single Keychain roundtrip when updating).
    ///
    /// - Parameter token: The authentication token to save.
    /// - Throws: `KeychainError.saveFailed(status)` if Keychain operation fails.
    static func saveToken(_ token: String) throws {
        try upsertItem(account: websocketAuthToken, value: token)
    }

    /// Loads the read-only overlay authentication token from Keychain.
    ///
    /// - Returns: The stored token string, or nil if not found or on error.
    static func loadToken() -> String? {
        loadItem(account: websocketAuthToken)
    }

    /// Status-bearing read for credential lifecycle code that must distinguish
    /// confirmed absence from a temporarily unavailable Keychain.
    ///
    /// - Throws: The backend's error (`loadFailed` / `invalidData`); `nil`
    ///   means confirmed absent.
    static func loadTokenChecked() throws -> String? {
        try backend.load(account: websocketAuthToken)
    }

    /// Deletes the read-only overlay authentication token from Keychain.
    ///
    /// Succeeds silently if token doesn't exist.
    static func deleteToken() throws {
        try deleteItem(account: websocketAuthToken)
    }

    /// Saves the privileged, loopback-only control token to Keychain.
    static func saveControlToken(_ token: String) throws {
        try upsertItem(account: websocketControlToken, value: token)
    }

    /// Loads the privileged, loopback-only control token from Keychain.
    static func loadControlToken() -> String? {
        loadItem(account: websocketControlToken)
    }

    /// Status-bearing counterpart to ``loadControlToken()``.
    static func loadControlTokenChecked() throws -> String? {
        try backend.load(account: websocketControlToken)
    }

    /// Deletes the privileged, loopback-only control token from Keychain.
    static func deleteControlToken() throws {
        try deleteItem(account: websocketControlToken)
    }

    // MARK: - Public Methods - Twitch Credential Reads

    /// Twitch access token from the current grant, or nil when absent or
    /// unreadable. Each call reads the whole grant; use
    /// ``loadTwitchCredentialGrant()`` when you need more than one field.
    static func loadTwitchToken() -> String? {
        loadTwitchCredentialGrant().accessToken
    }

    /// Bot account login from the current grant. See ``loadTwitchToken()``.
    static func loadTwitchUsername() -> String? {
        loadTwitchCredentialGrant().username
    }

    /// Bot account user ID from the current grant. See ``loadTwitchToken()``.
    static func loadTwitchBotUserID() -> String? {
        loadTwitchCredentialGrant().userID
    }

    // MARK: - Atomic Twitch Grant

    /// Loads one internally consistent Twitch account snapshot. Read failures
    /// fail closed (logged, returned as ``TwitchCredentialGrant/empty``) and
    /// never fall through to legacy migration.
    ///
    /// May write: the first read on an upgraded install migrates legacy items
    /// into the v2 record, and a malformed record raises the Twitch re-auth
    /// flag (and posts `twitchReauthNeededChanged` on the main actor).
    static func loadTwitchCredentialGrant() -> TwitchCredentialGrant {
        do {
            return try loadTwitchCredentialGrantChecked()
        } catch {
            Log.error(
                "KeychainService: Failed to load Twitch credential grant - \(error.localizedDescription)",
                category: .keychain)
            return .empty
        }
    }

    /// Checked variant used by account transactions that must distinguish a
    /// missing grant from an unavailable Keychain.
    static func loadTwitchCredentialGrantChecked() throws -> TwitchCredentialGrant {
        try twitchCredentialLock.withLock {
            try loadTwitchCredentialGrantLocked()
        }
    }

    /// Replaces the complete Twitch account in one atomic backend write.
    ///
    /// Saving ``TwitchCredentialGrant/empty`` deletes the account instead (see
    /// ``deleteTwitchCredentialGrant()``). After a non-empty save, leftover
    /// legacy items are removed best effort.
    ///
    /// - Throws: `invalidData` if any present field is empty, or the backend's
    ///   save/delete error.
    static func saveTwitchCredentialGrant(_ grant: TwitchCredentialGrant) throws {
        try validateTwitchCredentialGrant(grant)
        try twitchCredentialLock.withLock {
            try saveTwitchCredentialGrantLocked(grant)
            if !grant.isEmpty {
                deleteLegacyTwitchCredentialsBestEffortLocked()
            }
        }
    }

    /// Clears legacy Twitch fields first and the canonical grant last. The
    /// canonical grant therefore remains authoritative after any failed delete.
    static func deleteTwitchCredentialGrant() throws {
        try twitchCredentialLock.withLock {
            try deleteTwitchCredentialGrantLocked()
        }
    }

    /// Atomically reads, conditionally mutates, validates, and saves the complete
    /// Twitch record while holding one Keychain lock. Credential-store CAS paths
    /// use this so a concurrent channel edit can never be overwritten by a stale
    /// snapshot captured before the edit.
    ///
    /// - Parameter mutation: Edits the current grant in place and returns
    ///   whether anything should be written. Runs while holding the Twitch
    ///   lock, which is not re-entrant: calling another grant API from inside
    ///   it deadlocks.
    /// - Returns: `true` when the mutation asked to save and the save succeeded.
    /// - Throws: Load errors, errors thrown by `mutation`, `invalidData` for an
    ///   invalid result, or the backend's save error.
    @discardableResult
    static func mutateTwitchCredentialGrant(
        _ mutation: (inout TwitchCredentialGrant) throws -> Bool
    ) throws -> Bool {
        try twitchCredentialLock.withLock {
            var grant = try loadTwitchCredentialGrantLocked()
            guard try mutation(&grant) else { return false }
            try validateTwitchCredentialGrant(grant)
            try saveTwitchCredentialGrantLocked(grant)
            if !grant.isEmpty {
                deleteLegacyTwitchCredentialsBestEffortLocked()
            }
            return true
        }
    }

    /// Read path behind every grant load. Caller holds ``twitchCredentialLock``.
    ///
    /// Order: the v2 record wins whenever it exists; otherwise the legacy
    /// sources are read and, when valid, migrated (best effort) before being
    /// returned.
    private static func loadTwitchCredentialGrantLocked() throws -> TwitchCredentialGrant {
        // A backend error is not "not found": return it without inspecting or
        // mutating legacy fields, which might belong to an older account.
        if let encoded = try backend.load(account: twitchCredentialGrantAccount) {
            return decodeCurrentTwitchCredentialGrantOrFailClosed(encoded)
        }

        switch try loadLegacyTwitchCredentialSourceLocked() {
        case .absent:
            return .empty
        case .malformed:
            markMalformedTwitchCredentialsForReauthentication()
            return .empty
        case .valid(let legacy):
            migrateTwitchCredentialGrantBestEffortLocked(legacy)
            return legacy
        }
    }

    /// Reads legacy sources without mutating them. Version 1 remains
    /// authoritative over per-field values even when malformed, preventing a
    /// stale partial account from becoming visible on a later read.
    private static func loadLegacyTwitchCredentialSourceLocked() throws
        -> LegacyTwitchCredentialSource {
        if let encoded = try backend.load(
            account: legacyTwitchCredentialGrantAccount
        ) {
            guard let data = encoded.data(using: .utf8),
                  var migrated = try? JSONDecoder().decode(
                    TwitchCredentialGrant.self,
                    from: data
                  ),
                  (try? validateTwitchCredentialGrant(migrated)) != nil else {
                return .malformed
            }
            if migrated.channelID == nil {
                migrated.channelID = try backend.load(account: twitchChannelIDAccount)
            }
            guard (try? validateTwitchCredentialGrant(migrated)) != nil else {
                return .malformed
            }
            return .valid(migrated)
        }

        let legacy = TwitchCredentialGrant(
            accessToken: try backend.load(account: twitchBotAccountOauthToken),
            refreshToken: try backend.load(account: twitchBotAccountRefreshToken),
            username: try backend.load(account: twitchBotAccountUsername),
            userID: try backend.load(account: twitchBotAccountUserID),
            channelID: try backend.load(account: twitchChannelIDAccount)
        )
        guard !legacy.isEmpty else { return .absent }
        guard (try? validateTwitchCredentialGrant(legacy)) != nil else {
            return .malformed
        }
        return .valid(legacy)
    }

    /// Decodes a stored v2 record. An undecodable or invalid record raises the
    /// re-auth flag and reads as empty, leaving the stored bytes untouched.
    private static func decodeCurrentTwitchCredentialGrantOrFailClosed(
        _ encoded: String
    ) -> TwitchCredentialGrant {
        guard let data = encoded.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(
                TwitchCredentialGrant.self,
                from: data
              ),
              (try? validateTwitchCredentialGrant(decoded)) != nil else {
            markMalformedTwitchCredentialsForReauthentication()
            return .empty
        }
        // A v2 record is authoritative even when its channel is nil. Never
        // re-adopt a stale separate channel left by best-effort cleanup.
        return decoded
    }

    /// Copies a legacy account into the v2 record, then deletes the legacy
    /// items. A failed save is logged and left for the next read to retry.
    private static func migrateTwitchCredentialGrantBestEffortLocked(
        _ grant: TwitchCredentialGrant
    ) {
        do {
            try saveTwitchCredentialGrantLocked(grant)
            deleteLegacyTwitchCredentialsBestEffortLocked()
        } catch {
            // Migration is copy-then-delete. Returning the unchanged in-memory
            // snapshot preserves existing users and retries on the next read.
            Log.error(
                "KeychainService: Twitch credential migration deferred - \(error.localizedDescription)",
                category: .keychain
            )
        }
    }

    /// Asks the user to sign in to Twitch again without touching the malformed
    /// source. Runs on every read that hits it, so the flag stays raised.
    private static func markMalformedTwitchCredentialsForReauthentication() {
        // Retain the malformed authoritative source unchanged. Partially deleting
        // v1/per-field sources could expose a valid-looking stale fragment on the
        // next launch. A later valid v2 commit or factory reset safely cleans it.
        requireTwitchReauthentication()
    }

    /// Saves a grant, routing an empty one to a full delete so "no account"
    /// never leaves an empty-but-present record behind. Caller holds the lock.
    private static func saveTwitchCredentialGrantLocked(
        _ grant: TwitchCredentialGrant
    ) throws {
        guard !grant.isEmpty else {
            try deleteTwitchCredentialGrantLocked()
            return
        }
        try saveTwitchCredentialGrantRecordLocked(grant)
    }

    /// Writes an authoritative v2 record, including the encoded-empty tombstone
    /// used as a clear barrier when legacy input is malformed.
    private static func saveTwitchCredentialGrantRecordLocked(
        _ grant: TwitchCredentialGrant
    ) throws {
        try validateTwitchCredentialGrant(grant)
        let data = try JSONEncoder().encode(grant)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        try backend.save(account: twitchCredentialGrantAccount, value: encoded)
    }

    /// Rejects a grant with any field set to an empty string. Nil fields pass.
    ///
    /// - Throws: `KeychainError.invalidData`.
    private static func validateTwitchCredentialGrant(
        _ grant: TwitchCredentialGrant
    ) throws {
        let values = [
            grant.accessToken,
            grant.refreshToken,
            grant.username,
            grant.userID,
            grant.channelID,
        ]
        guard values.compactMap({ $0 }).allSatisfy({ !$0.isEmpty }) else {
            throw KeychainError.invalidData
        }
    }

    /// Every pre-v2 account: the v1 grant plus the five per-field items.
    private static var legacyTwitchCredentialAccounts: [String] {
        [
            legacyTwitchCredentialGrantAccount,
            twitchBotAccountOauthToken,
            twitchBotAccountRefreshToken,
            twitchBotAccountUsername,
            twitchBotAccountUserID,
            twitchChannelIDAccount,
        ]
    }

    /// Deletes the Twitch account across every storage generation. Caller
    /// holds the lock.
    ///
    /// When no v2 record exists yet, one is written first (the legacy account,
    /// or an empty tombstone for malformed input) so that if a later delete
    /// fails, the next read sees the v2 record instead of a half-deleted
    /// legacy set. Legacy items go before the v2 record for the same reason.
    private static func deleteTwitchCredentialGrantLocked() throws {
        if try backend.load(account: twitchCredentialGrantAccount) == nil {
            switch try loadLegacyTwitchCredentialSourceLocked() {
            case .absent:
                break
            case .valid(let grant):
                // Publish the complete legacy snapshot before the first delete.
                try saveTwitchCredentialGrantRecordLocked(grant)
            case .malformed:
                // An encoded-empty v2 item is an authoritative tombstone. It
                // blocks partially deleted malformed sources from exposing a
                // stale fallback if any subsequent delete fails.
                markMalformedTwitchCredentialsForReauthentication()
                try saveTwitchCredentialGrantRecordLocked(.empty)
            }
        }
        for account in legacyTwitchCredentialAccounts {
            try backend.delete(account: account)
        }
        try backend.delete(account: twitchCredentialGrantAccount)
    }

    /// Cleanup after a successful canonical save is best effort because the
    /// canonical record wins every future read even if a stale legacy field
    /// cannot be removed immediately.
    private static func deleteLegacyTwitchCredentialsBestEffortLocked() {
        for account in legacyTwitchCredentialAccounts {
            do {
                try backend.delete(account: account)
            } catch {
                Log.error(
                    "KeychainService: Could not remove legacy Twitch item '\(account)' - \(error.localizedDescription)",
                    category: .keychain)
            }
        }
    }

    /// Sets the persisted re-auth flag synchronously, then posts
    /// `twitchReauthNeededChanged` from a main-actor task (so observers run
    /// later, on main, not inside the Keychain lock).
    private static func requireTwitchReauthentication() {
        Preferences.setTwitchReauthNeeded(true)
        Task { @MainActor in
            NotificationCenter.default.post(
                name: Notification.Name.twitchReauthNeededChanged,
                object: nil
            )
        }
    }

    /// Configured channel login (not a numeric ID, despite the name) from the
    /// current grant. See ``loadTwitchToken()``.
    static func loadTwitchChannelID() -> String? {
        loadTwitchCredentialGrant().channelID
    }

    // MARK: - Public Methods - Factory Reset

    /// Deletes every WolfWave credential from the Keychain in one sweep.
    ///
    /// Wipes the entire generic-password class for the app's service, so it
    /// covers both WebSocket tokens, all Twitch tokens, and any credential
    /// added later without needing a per-account call. Used by the factory
    /// reset. Succeeds silently if nothing is stored and throws on failure.
    /// Takes the Twitch lock so it cannot interleave with a grant transaction.
    static func deleteAll() throws {
        try twitchCredentialLock.withLock {
            try backend.deleteAll()
        }
    }

    // MARK: - Backend Injection

    /// Mutable holder so a scoped backend can be swapped in place without
    /// leaving the task tree that owns it.
    ///
    /// `@unchecked Sendable`: ``stored`` is only touched under ``lock``.
    nonisolated final class BackendBox: @unchecked Sendable {
        /// Guards ``stored``.
        private let lock = NSLock()
        /// The scoped backend.
        private var stored: KeychainBackend

        /// Wraps `backend` for binding to ``KeychainService/backendBox``.
        init(_ backend: KeychainBackend) { stored = backend }

        /// Lock-guarded access to the scoped backend.
        var backend: KeychainBackend {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// Task-scoped backend override. Always nil in the app; a test suite binds
    /// one so its backend is visible only inside its own task tree.
    ///
    /// The process-wide variable alone is not enough for a parallel test bundle.
    /// Swift Testing runs suites concurrently, so a suite that installed an
    /// inspectable backend was observable by every other suite, including
    /// mid-transaction: a concurrent grant read could complete its legacy-field
    /// probes against a backend that appeared underneath it.
    @TaskLocal static var backendBox: BackendBox?

    /// Process-wide fallback used by the app and by XCTest suites, which have no
    /// task scope to bind. Initialized lazily on first access, as in-memory under
    /// any test harness (hosted unit tests or a UI-test launch).
    nonisolated(unsafe) private static var processBackend: KeychainBackend = makeDefaultBackend(
        isRunningTests: UITestMode.isUnderTestHarness
    )

    /// Raw storage backing every credential operation.
    ///
    /// Test hosts default to process-local storage so no test can touch the
    /// user's real Keychain before a suite installs its own backend. Normal app
    /// launches use the Security framework. Reads and writes resolve to the
    /// task-scoped box when one is bound, otherwise to the process-wide value.
    static var backend: KeychainBackend {
        get { backendBox?.backend ?? processBackend }
        set {
            if let box = backendBox {
                box.backend = newValue
            } else {
                processBackend = newValue
            }
        }
    }

    /// Chooses the default backend: in-memory under a test harness, otherwise
    /// the Security framework scoped to ``service``. Kept internal so the test
    /// suite can pin the security-sensitive branch.
    static func makeDefaultBackend(isRunningTests: Bool) -> KeychainBackend {
        if isRunningTests {
            return InMemoryKeychainBackend()
        }
        return SystemKeychainBackend(service: service)
    }

    // MARK: - Private Helpers

    /// Validates then stores a value via the active backend.
    ///
    /// Empty-value rejection lives here (not in the backend) so the rule holds
    /// regardless of backend and stays unit-testable without the Keychain.
    private static func upsertItem(account: String, value: String) throws {
        guard !value.isEmpty else {
            Log.warn("Keychain: Attempted to save empty value for account \(account)", category: .keychain)
            throw KeychainError.invalidData
        }
        try backend.save(account: account, value: value)
    }

    /// Loads a string value for the given account via the active backend.
    /// Errors are logged and collapse to nil, so callers that must tell
    /// "absent" from "unavailable" use the backend directly (`…Checked`).
    private static func loadItem(account: String) -> String? {
        do {
            return try backend.load(account: account)
        } catch {
            Log.error(
                "KeychainService: Failed to load item '\(account)' - \(error.localizedDescription)",
                category: .keychain)
            return nil
        }
    }

    /// Deletes the item for the given account via the active backend.
    private static func deleteItem(account: String) throws {
        try backend.delete(account: account)
    }
}
