//
//  TwitchConnectionNoticeTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-06-05.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import SwiftUI
import Testing

@testable import WolfWave

/// Covers `TwitchConnectionNotice.State.resolve`, the pure mapping from the two
/// Twitch auth flags to which gate banner renders. The reauth flag must win over
/// the connection flag so an expired-but-still-socketed state shows the warning.
@Suite("TwitchConnectionNotice State")
struct TwitchConnectionNoticeTests {

    @Test("Expired sign-in resolves to .expired regardless of connection")
    func expiredWinsOverConnection() {
        #expect(
            TwitchConnectionNotice.State.resolve(isConnected: false, reauthNeeded: true) == .expired)
        #expect(
            TwitchConnectionNotice.State.resolve(isConnected: true, reauthNeeded: true) == .expired)
    }

    @Test("Not connected and not expired resolves to .disconnected")
    func disconnectedWhenNotConnected() {
        #expect(
            TwitchConnectionNotice.State.resolve(isConnected: false, reauthNeeded: false)
                == .disconnected)
    }

    @Test("Connected and not expired resolves to .ready (no banner)")
    func readyWhenConnected() {
        #expect(
            TwitchConnectionNotice.State.resolve(isConnected: true, reauthNeeded: false) == .ready)
    }

    // MARK: - Expired error

    @Test("Expired error offers only Reconnect with Twitch, as a warning")
    func expiredErrorOffersReconnect() {
        let error = TwitchConnectionNotice.expiredError(message: "Song requests stopped.")
        #expect(error.id == "twitch.signInExpired")
        #expect(error.severity == .warning)
        #expect(error.resolvedActions == [.reconnectTwitch])
        #expect(error.message == "Song requests stopped.")
    }

    /// With a reconnect handler the expired state gains an action row, so it
    /// must lay out taller than the plain note it replaces.
    @Test("A reconnect handler adds the action row below the banner")
    @MainActor
    func reconnectHandlerAddsActionRow() {
        func height(_ notice: TwitchConnectionNotice) -> CGFloat {
            let host = NSHostingView(rootView: notice)
            host.setFrameSize(NSSize(width: 480, height: 0))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let note = TwitchConnectionNotice(
            isConnected: false, reauthNeeded: true,
            expiredMessage: "Song requests stopped.", disconnectedMessage: "Connect.")
        let actionable = TwitchConnectionNotice(
            isConnected: false, reauthNeeded: true,
            expiredMessage: "Song requests stopped.", disconnectedMessage: "Connect.",
            onReconnect: {})
        #expect(height(actionable) > height(note))
    }
}
