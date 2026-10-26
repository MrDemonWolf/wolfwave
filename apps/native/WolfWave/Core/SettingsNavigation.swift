//
//  SettingsNavigation.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-09-01.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Observation

/// Hand-off between whoever wants Settings opened somewhere specific (a deep
/// link, the menu bar, a Twitch re-auth banner) and the live `SettingsView`.
///
/// Replaces the old `selectedSettingsSection` UserDefaults hint, which was
/// read once on pane appear and so did nothing when the window was already
/// open. `SettingsView` observes `pending`, navigates, then clears it.
@MainActor
@Observable
final class SettingsNavigation {
    /// The one instance `AppDelegate` writes and `SettingsView` observes.
    static let shared = SettingsNavigation()

    /// Destination waiting to be applied by `SettingsView`.
    var pending: SettingsDeepLink?

    /// Retains an open request until the scene bridge is ready to receive it.
    private(set) var isOpenRequested = false

    func requestOpen() {
        isOpenRequested = true
    }

    /// Coalesces repeated requests while a scene is being created.
    func consumeOpenRequest() -> Bool {
        guard isOpenRequested else { return false }
        isOpenRequested = false
        return true
    }

    /// Section slug currently flashing its highlight ring, if any.
    var highlighted: String?

    init() {}
}
