//
//  RequestQueueWindow.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-11-23.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Observation

/// Hand-off between whoever wants the Request Queue window open (the menu bar,
/// the Dock menu, the Settings queue card) and the SwiftUI scene that owns it.
///
/// Mirrors ``SettingsNavigation``: AppKit entry points set a request, and
/// `WolfWaveApp` observes it and calls `openWindow(id:)`, which creates the
/// single window or brings the existing one forward.
@MainActor
@Observable
final class RequestQueueWindow {
    /// The one instance `AppDelegate` writes and `WolfWaveApp` observes.
    static let shared = RequestQueueWindow()

    /// Scene identifier for the `Window` in `WolfWaveApp`.
    static let windowID = "wolfwave-request-queue"

    /// Retains an open request until the scene receives it.
    private(set) var isOpenRequested = false

    /// Asks the scene to open (or front) the window.
    func requestOpen() {
        isOpenRequested = true
    }

    /// Takes the pending request, so repeated requests open the window once.
    func consumeOpenRequest() -> Bool {
        guard isOpenRequested else { return false }
        isOpenRequested = false
        return true
    }

    init() {}
}
