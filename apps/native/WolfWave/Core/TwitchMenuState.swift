//
//  TwitchMenuState.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-11.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// The slice of the stored Twitch account the tray and Dock menus need.
///
/// `NSMenuDelegate.menuNeedsUpdate` runs on the main thread while the menu is
/// tracking, so it must never touch the Keychain. `AppDelegate` keeps one of
/// these in memory and refreshes it off the main thread when Twitch state
/// changes.
nonisolated struct TwitchMenuState: Sendable, Equatable {

    /// `true` when a Twitch access token is stored.
    let hasCredential: Bool

    /// The configured channel name, if any.
    let channelName: String?

    /// No account stored. Also the value before the first refresh lands.
    static let empty = TwitchMenuState(hasCredential: false, channelName: nil)

    /// Builds the menu state from a credential snapshot (`nil` = signed out).
    init(snapshot: TwitchCredentialStore.ConnectionSnapshot?) {
        self.init(hasCredential: snapshot != nil, channelName: snapshot?.channelID)
    }

    init(hasCredential: Bool, channelName: String?) {
        self.hasCredential = hasCredential
        self.channelName = channelName
    }
}
