//
//  WebSocketAuthToken.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-23.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Network
import os

/// Manages the two per-install credentials used by WolfWave's WebSocket server.
///
/// Overlay clients receive playback state but cannot execute commands. Control
/// clients may execute commands, but the server accepts that role only from a
/// loopback peer. Both credentials are 64 hex chars, live in the macOS Keychain,
/// and travel in role-specific WebSocket subprotocols so a read-only OBS URL can
/// never be promoted into a command channel.
///
/// Credential lifecycle calls (`currentOrCreate`, `persist`, `rotate`) block on a
/// semaphore and do Keychain I/O, so call them off the main thread (callers use
/// `Task.detached`). The matching helpers below them are pure and cheap.
nonisolated enum WebSocketAuthToken {
    // MARK: - Role

    /// Which capability a credential grants: `overlay` is read-only playback
    /// state, `control` may run Stream Deck commands (loopback peers only).
    enum Role: String, CaseIterable, Sendable, Hashable {
        case overlay
        case control

        /// The role a credential must never collide with.
        ///
        /// The whole role separation rests on the two tokens being different, so
        /// the "other" role is a property of the role itself rather than
        /// something each call site works out (and can get wrong).
        var counterpart: Role {
            switch self {
            case .overlay: return .control
            case .control: return .overlay
            }
        }

        /// The `Sec-WebSocket-Protocol` prefix a client prepends to the token.
        /// `wolfwave.control.` is mirrored as `TOKEN_SUBPROTOCOL_PREFIX` in the
        /// Stream Deck plugin's `protocol.ts`; changing either breaks the handshake.
        var subprotocolPrefix: String {
            switch self {
            case .overlay:
                return "wolfwave.overlay."
            case .control:
                return "wolfwave.control."
            }
        }
    }

    // MARK: - Session Fallback State

    /// A process-only credential held while the Keychain could not be read or
    /// written.
    private struct SessionCredential: Sendable {
        /// The token handed to callers for the rest of this process (or until
        /// it is settled into the Keychain).
        let token: String
        /// False after a read failure: absence was never proven, so this token
        /// must remain process-only and may not overwrite a durable credential.
        var mayRetryPersistence: Bool
    }

    /// Stable in-process fallbacks for the rare case where Keychain access is
    /// temporarily unavailable. Keeping each role separate prevents a failed
    /// control-token operation from changing the overlay credential (and vice versa).
    private static let sessionTokens =
        OSAllocatedUnfairLock<[Role: SessionCredential]>(initialState: [:])

    /// Serializes credential lifecycle operations without holding the short-lived
    /// session-state lock across Keychain I/O.
    private static let operationGate = DispatchSemaphore(value: 1)

    // MARK: - Lifecycle

    /// Returns the stored credential for `role`, minting and persisting it only
    /// after a checked read proves the item absent or invalid. A read failure
    /// gets a stable process-only fallback that can never overwrite an existing
    /// durable credential in this process.
    ///
    /// Never fails: the worst case is a token that only lasts this process.
    /// It does not check the result against `role.counterpart`; callers that
    /// need distinct credentials compare and `rotate(_:)` themselves.
    /// Blocks on `operationGate` and touches the Keychain.
    @discardableResult
    static func currentOrCreate(for role: Role) -> String {
        operationGate.wait()
        defer { operationGate.signal() }

        // A fallback already exists for this role: keep handing it out so the
        // value stays stable, but try to settle it into the Keychain when that
        // is still allowed.
        if var session = sessionTokens.withLock({ state in state[role] }) {
            guard session.mayRetryPersistence else { return session.token }
            do {
                if let durable = try loadChecked(for: role), isValid(durable) {
                    if constantTimeEquals(durable, session.token) {
                        sessionTokens.withLock { state in state[role] = nil }
                        return durable
                    }
                    // Another writer installed a valid credential after the
                    // fallback was minted. Keep this process internally stable,
                    // but never overwrite that durable value.
                    session.mayRetryPersistence = false
                    let retainedSession = session
                    sessionTokens.withLock { state in state[role] = retainedSession }
                    return retainedSession.token
                }
                // Absence (or an invalid item) is now proven, so the
                // fallback can become the durable credential.
                try save(session.token, for: role)
                sessionTokens.withLock { state in state[role] = nil }
            } catch {
                Log.error(
                    "WebSocketAuthToken: Could not settle session "
                        + role.rawValue + " token: " + error.localizedDescription,
                    category: .websocket
                )
                return session.token
            }
            return session.token
        }

        do {
            if let existing = try loadChecked(for: role), isValid(existing) {
                return existing
            }
        } catch {
            // The read failed, so a durable credential may still exist. Mint a
            // process-only token that is never allowed to overwrite it.
            let fresh = generate()
            sessionTokens.withLock { state in
                state[role] = SessionCredential(
                    token: fresh,
                    mayRetryPersistence: false)
            }
            Log.error(
                "WebSocketAuthToken: Keychain read failed for "
                    + role.rawValue + "; using a process-only token: "
                    + error.localizedDescription,
                category: .websocket
            )
            return fresh
        }

        // Proven absent or invalid: mint and persist. If the write fails, keep
        // the token as a retryable fallback so the next call can settle it.
        let fresh = generate()
        do {
            try save(fresh, for: role)
            sessionTokens.withLock { state in state[role] = nil }
        } catch {
            Log.error(
                "WebSocketAuthToken: Failed to persist new " + role.rawValue
                    + " token: " + error.localizedDescription,
                category: .websocket
            )
            sessionTokens.withLock { state in
                state[role] = SessionCredential(
                    token: fresh,
                    mayRetryPersistence: true)
            }
        }
        return fresh
    }

    /// Persists an explicitly supplied credential for `role` and clears any
    /// temporary fallback for that role.
    ///
    /// Does not validate the format or check it against the counterpart role;
    /// the token editor (`WebSocketTokenEditorRow`) does both before calling.
    /// - Throws: The Keychain error from the write; the fallback is kept on failure.
    static func persist(_ token: String, for role: Role) throws {
        operationGate.wait()
        defer { operationGate.signal() }

        try save(token, for: role)
        sessionTokens.withLock { $0[role] = nil }
    }

    /// Mints, persists, and returns a fresh credential for `role`. The in-memory
    /// value changes only after persistence succeeds.
    ///
    /// Used to regenerate a token from Settings and to separate the control
    /// token from the overlay token when the two are found equal at launch.
    /// - Throws: The Keychain error from the write; nothing changes on failure.
    @discardableResult
    static func rotate(_ role: Role) throws -> String {
        operationGate.wait()
        defer { operationGate.signal() }

        let fresh = generate()
        try save(fresh, for: role)
        sessionTokens.withLock { state in state[role] = nil }
        return fresh
    }

    /// Test isolation for the process-only fallback state.
    static func resetSessionCredentialsForTesting() {
        sessionTokens.withLock { state in state.removeAll() }
    }

    // MARK: - Handshake Matching

    /// Returns the exact subprotocol string a client in `role` must offer.
    static func expectedSubprotocol(for token: String, role: Role) -> String {
        role.subprotocolPrefix + token
    }

    /// Resolves the authenticated role from the offered subprotocols.
    ///
    /// When both configured credentials are `nil` (the test-only legacy
    /// initializer), the connection is treated as a read-only overlay. In
    /// production an exact role-prefixed credential is required. Control wins
    /// only when its own credential was offered; an overlay token can never be
    /// promoted by changing the prefix.
    ///
    /// If the two configured tokens are equal, the control match is disabled
    /// entirely, so a shared value can only ever authenticate as overlay.
    /// Every offered value is compared in constant time.
    ///
    /// - Returns: The granted role, or `nil` to refuse the handshake.
    static func authenticationRole(
        overlayToken: String?,
        controlToken: String?,
        offeredSubprotocols: [String]
    ) -> Role? {
        guard overlayToken != nil || controlToken != nil else { return .overlay }

        var matchedOverlay = false
        var matchedControl = false
        let controlCredentialIsDistinct: Bool
        if let overlayToken, let controlToken {
            controlCredentialIsDistinct = !constantTimeEquals(overlayToken, controlToken)
        } else {
            controlCredentialIsDistinct = true
        }
        for offered in offeredSubprotocols {
            if let overlayToken,
               constantTimeEquals(offered, expectedSubprotocol(for: overlayToken, role: .overlay)) {
                matchedOverlay = true
            }
            if controlCredentialIsDistinct, let controlToken,
               constantTimeEquals(offered, expectedSubprotocol(for: controlToken, role: .control)) {
                matchedControl = true
            }
        }
        if matchedControl { return .control }
        if matchedOverlay { return .overlay }
        return nil
    }

    /// Validates the protocol Network.framework selected during the handshake
    /// and maps it back to its role.
    ///
    /// Re-runs `authenticationRole` on the single selected value rather than
    /// trusting the role decided at offer time, so the role that governs the
    /// connection is the one bound to what was actually negotiated.
    static func role(
        forSelectedSubprotocol selectedSubprotocol: String?,
        overlayToken: String?,
        controlToken: String?
    ) -> Role? {
        guard overlayToken != nil || controlToken != nil else { return .overlay }
        guard let selectedSubprotocol else { return nil }
        return authenticationRole(
            overlayToken: overlayToken,
            controlToken: controlToken,
            offeredSubprotocols: [selectedSubprotocol]
        )
    }

    /// Returns whether a Network.framework endpoint is a literal loopback IP.
    /// Unresolved hostnames are rejected; callers must not trust a name that can
    /// be changed by DNS.
    static func isLoopbackEndpoint(_ endpoint: NWEndpoint) -> Bool {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let address):
                return address.isLoopback
            case .ipv6(let address):
                return address.isLoopback
            case .name:
                return false
            @unknown default:
                return false
            }
        default:
            return false
        }
    }

    // MARK: - Peer Identity

    /// Stable peer identity for admission limits. Source ports are intentionally
    /// ignored so reconnects from one host share the same budget.
    static func peerKey(_ endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "unknown" }
        return String(describing: host).lowercased()
    }

    // MARK: - Credential Helpers

    /// Compares two strings for equality without leaking matching prefix length.
    ///
    /// Walks the longer of the two UTF-8 buffers so timing depends only on
    /// length; a length mismatch is folded into `diff` rather than returned early.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        let count = max(a.count, b.count)
        var diff: UInt8 = a.count == b.count ? 0 : 1
        var index = 0
        while index < count {
            let lhsByte: UInt8 = index < a.count ? a[index] : 0
            let rhsByte: UInt8 = index < b.count ? b[index] : 0
            diff |= lhsByte ^ rhsByte
            index += 1
        }
        return diff == 0
    }

    /// Canonical form of a token the user typed or pasted: surrounding
    /// whitespace trimmed and hex folded to lowercase, the case `generate()`
    /// mints. The token editor saves this form, so a pasted uppercase token is
    /// stored (and copied back out) in the one case clients are handed.
    static func normalizedInput(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Returns `true` for the protocol's exact 32-byte hexadecimal credential.
    ///
    /// Accepts either case so a token stored before the editor normalized
    /// input (`normalizedInput`) keeps working instead of being silently
    /// rotated. Matching in `authenticationRole` is case-sensitive, so the
    /// client must send the token exactly as stored.
    static func isValid(_ candidate: String) -> Bool {
        guard candidate.count == 64 else { return false }
        return candidate.unicodeScalars.allSatisfy { scalar in
            (scalar >= "0" && scalar <= "9")
                || (scalar >= "a" && scalar <= "f")
                || (scalar >= "A" && scalar <= "F")
        }
    }

    /// Redacts a credential for safe logging.
    static func redact(_ token: String) -> String {
        guard token.count > 4 else { return "…" }
        return token.prefix(4) + "…"
    }

    /// Mints a fresh 64-hex-char (32 random byte) lowercase credential.
    ///
    /// Falls back to `SystemRandomNumberGenerator` (also a CSPRNG) if
    /// `SecRandomCopyBytes` fails, so minting never fails.
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: 0...255, using: &rng)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Keychain Routing

    /// Reads the stored credential for `role`.
    /// - Returns: The stored value, or `nil` when the item is proven absent.
    /// - Throws: When the Keychain read itself failed (absence not proven).
    private static func loadChecked(for role: Role) throws -> String? {
        switch role {
        case .overlay:
            return try KeychainService.loadTokenChecked()
        case .control:
            return try KeychainService.loadControlTokenChecked()
        }
    }

    /// Writes `token` to the Keychain item for `role`.
    private static func save(_ token: String, for role: Role) throws {
        switch role {
        case .overlay:
            try KeychainService.saveToken(token)
        case .control:
            try KeychainService.saveControlToken(token)
        }
    }
}
