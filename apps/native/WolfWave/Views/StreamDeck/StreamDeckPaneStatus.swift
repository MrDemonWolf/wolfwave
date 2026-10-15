//
//  StreamDeckPaneStatus.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-08-19.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Resolves the Stream Deck pane's header chip from the two switches that gate
/// a working key and the live state of the shared server.
///
/// Pure and `nonisolated` so the precedence rule is testable without standing up
/// the view. The chip reports the *first* thing in the user's way, in this order:
/// server switch off, server failed, server still starting, commands switch off,
/// then Ready. "Ready" is only ever shown for a server that is actually
/// `.listening`: a switch being on says what the user asked for, not what the
/// server did, and a port clash left the old chip reading Ready over a dead key.
nonisolated enum StreamDeckPaneStatus {

    // MARK: - Resolved

    /// One chip's worth of state: label, tint, and the glyph that carries the
    /// same meaning through shape (WCAG 1.4.1).
    struct Resolved: Equatable {
        /// Short chip label, e.g. "Server off".
        let text: String
        /// Semantic `DSColor` tint for the chip.
        let color: Color
        /// SF Symbol name from `StatusChip.StateGlyph`.
        let symbol: String
    }

    // MARK: - Public Methods

    /// Resolves the chip for the current switch positions and server state.
    ///
    /// - Parameters:
    ///   - controlEnabled: Whether Stream Deck commands are allowed.
    ///   - serverEnabled: Whether the shared WebSocket server (Stream Widgets)
    ///     is on. Outranks everything else; both panes are served by one
    ///     `WebSocketServerService` on one port.
    ///   - serverState: The live lifecycle state of that server. Only consulted
    ///     when `serverEnabled` is on. `.stopped` while the switch is on is the
    ///     brief gap before the service reports `.starting`, so it reads as
    ///     "Starting" rather than claiming the server is ready.
    /// - Returns: The label, tint, and glyph for the header chip.
    static func resolve(
        controlEnabled: Bool,
        serverEnabled: Bool,
        serverState: WebSocketServerService.ServerState
    ) -> Resolved {
        guard serverEnabled else {
            return Resolved(
                text: "Server off",
                color: DSColor.neutral,
                symbol: StatusChip.StateGlyph.off
            )
        }

        switch serverState {
        case .error:
            return Resolved(
                text: "Server error",
                color: DSColor.error,
                symbol: StatusChip.StateGlyph.error
            )
        case .starting, .stopped:
            return Resolved(
                text: "Starting",
                color: DSColor.warning,
                symbol: StatusChip.StateGlyph.starting
            )
        case .listening:
            break
        }

        guard controlEnabled else {
            return Resolved(
                text: "Commands off",
                color: DSColor.warning,
                symbol: StatusChip.StateGlyph.starting
            )
        }

        return Resolved(
            text: "Ready",
            color: DSColor.success,
            symbol: StatusChip.StateGlyph.on
        )
    }
}
