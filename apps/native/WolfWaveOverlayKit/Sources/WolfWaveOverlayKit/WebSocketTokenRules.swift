//
//  WebSocketTokenRules.swift
//  WolfWaveOverlayKit
//
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Pure, dependency-free rules for the per-install overlay auth token. Split out
/// of the app's `WebSocketAuthToken` (which also touches Keychain) so both the
/// server and the unit tests can use the validation/handshake logic without the
/// app module. The app keeps minting/persistence (`currentOrCreate`/`rotate`).
public enum WebSocketTokenRules {

    /// Subprotocol prefix advertised by the widget on `new WebSocket(url, [...])`
    /// and checked server-side.
    public static let subprotocolPrefix = "wolfwave.token."

    /// Returns the subprotocol string a client must offer to be accepted.
    public static func expectedSubprotocol(for token: String) -> String {
        subprotocolPrefix + token
    }

    /// Decides whether a handshake should be accepted given the server's
    /// configured token and the subprotocols the client offered.
    ///
    /// - When `expectedToken` is `nil`, any handshake passes (test-only).
    /// - Otherwise the client must have offered `wolfwave.token.<expected>`.
    public static func shouldAccept(expectedToken: String?, offeredSubprotocols: [String]) -> Bool {
        guard let expected = expectedToken else { return true }
        return offeredSubprotocols.contains(expectedSubprotocol(for: expected))
    }

    /// Returns `true` when `candidate` is a non-empty hex string (`[0-9a-fA-F]+`)
    /// between 16 and 128 characters. Gates substitution into the served
    /// `widget.html` so a token can never contain `</script>` or other
    /// characters that would break out of the JS string context.
    public static func isValid(_ candidate: String) -> Bool {
        guard (16...128).contains(candidate.count) else { return false }
        return candidate.unicodeScalars.allSatisfy { scalar in
            (scalar >= "0" && scalar <= "9")
                || (scalar >= "a" && scalar <= "f")
                || (scalar >= "A" && scalar <= "F")
        }
    }

    /// Redacts a token for safe logging — keeps the first 4 chars and an ellipsis.
    public static func redact(_ token: String) -> String {
        guard token.count > 4 else { return "…" }
        return token.prefix(4) + "…"
    }
}
