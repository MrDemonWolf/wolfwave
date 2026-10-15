//
//  WebSocketServerCard.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-11.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

// MARK: - Server Card

/// Stream Widgets server switch, its reach summary, and the "Couldn't start"
/// callout. Rendered by ``WebSocketSettingsView``.
struct WebSocketServerCard: View {
    // MARK: - Properties

    /// The toggle's change notification animates unless Reduce Motion is on.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The shared server switch (overlay and Stream Deck both ride on it).
    @AppStorage(AppConstants.UserDefaults.websocketEnabled)
    private var websocketEnabled = false

    /// Hides the LAN address in the reach summary; it does not change reach.
    @AppStorage(AppConstants.UserDefaults.streamerModeEnabled)
    private var streamerMode = false

    /// Stored WebSocket port, used only for display here (edited in
    /// `WebSocketCustomOverlayCard`). Not re-clamped, so it shows the raw value.
    @AppStorage(AppConstants.UserDefaults.websocketServerPort)
    private var storedPort: Int = Int(AppConstants.WebSocketServer.defaultPort)

    /// Live server state, owned by the parent so the header chip and this card
    /// can never disagree about whether the server came up.
    let serverState: WebSocketServerService.ServerState

    /// This Mac's LAN IPv4 address, or `nil` when there is none (the summary
    /// then says "this Mac" only).
    let localNetworkIP: String?

    /// Shorthand for the standard settings card inset.
    private let cardPadding = AppConstants.SettingsUI.cardPadding

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToggleSettingRow(
                title: "Enable Stream Widgets",
                subtitle: "Show live song updates in your overlay.",
                isOn: $websocketEnabled,
                accessibilityLabel: "Toggle Stream Widgets",
                accessibilityIdentifier: "websocketEnabledToggle",
                onChange: { _ in
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.base)) {
                        notifyServerSettingChanged()
                    }
                }
            )
            .padding(.horizontal, cardPadding)
            .padding(.vertical, DSSpace.s4)

            Divider().padding(.leading, cardPadding)

            // States the reach of what the switch just turned on. The server is
            // bound on the LAN, not only on this Mac, and nothing in the pane
            // said so — a detail worth knowing before you put the address in a
            // browser source on a shared network.
            HintRow(serverReachSummary, systemImage: "network")
            .padding(.horizontal, cardPadding)
            .padding(.bottom, DSSpace.s4)

            // The switch is on but the listener is not: usually the port is
            // taken. Say so here, next to the switch, instead of leaving a
            // green-looking toggle over a dead overlay.
            if websocketEnabled && serverState == .error {
                CalloutBanner(
                    "Port \(storedPort) may be in use. Turn this off, pick another port, then turn it back on.",
                    title: "Couldn't start",
                    style: .error,
                    systemImage: "exclamationmark.octagon"
                )
                .padding(.horizontal, cardPadding)
                .padding(.bottom, DSSpace.s4)
                .transition(.opacity)
            }
        }
        .cardStyleUnpadded()
    }

    // MARK: - Private Helpers

    /// One sentence describing where the server can be reached right now.
    ///
    /// Streamer Mode masks the address, it does not change the reach. An earlier
    /// version returned "Serving on this Mac" whenever masking was on, which told
    /// the user the server was local-only while it was still bound on the LAN.
    /// Masking a value must never restate the fact it is hiding.
    private var serverReachSummary: String {
        guard websocketEnabled else {
            return "Nothing is served while this is off. Your song data stays on this Mac."
        }
        guard let ip = localNetworkIP else {
            return "Serving on this Mac at port \(storedPort)."
        }
        guard !streamerMode else {
            return "Serving on this Mac and on your local network, port \(storedPort)."
        }
        return "Serving on this Mac and to \(ip) on your local network, port \(storedPort)."
    }

    /// Posts a `websocketServerChanged` notification without altering settings.
    /// Used after a setting change persists, to nudge the service to re-read.
    private func notifyServerSettingChanged() {
        NotificationCenter.default.postWebSocketServerChanged()
    }
}
