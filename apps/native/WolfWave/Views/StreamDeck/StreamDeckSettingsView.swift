//
//  StreamDeckSettingsView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-08-17.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Stream Deck control: the capability switch, the credential, and how to set up
/// the plugin.
///
/// Split out of Stream Widgets, which had both credentials one divider apart in
/// a single card. They share a server and a port but not a threat model: the
/// overlay token is read-only and reachable across the LAN, while this one runs
/// commands and is refused from anything but literal loopback. Rendering them as
/// siblings said, through proximity alone, that they were interchangeable.
struct StreamDeckSettingsView: View {

    /// Sends the user to Stream Widgets, which owns the shared server switch.
    let openStreamWidgets: () -> Void

    // MARK: - Properties

    /// The Stream Deck command capability. Defaults to **on** (see
    /// `Defaults.streamDeckControlEnabled`); commands are still gated by the
    /// control token and loopback-only transport.
    @AppStorage(AppConstants.UserDefaults.streamDeckControlEnabled)
    private var controlEnabled = AppConstants.UserDefaults.Defaults.streamDeckControlEnabled

    /// The shared WebSocket server switch, owned by the Stream Widgets pane.
    /// Read here to explain why keys would do nothing while it is off.
    @AppStorage(AppConstants.UserDefaults.websocketEnabled)
    private var websocketEnabled = false

    /// Masks the control token on camera.
    @AppStorage(AppConstants.UserDefaults.streamerModeEnabled)
    private var streamerMode = false

    /// The control credential (`wolfwave.control.<hex>`). Empty until the
    /// first `.task` loads or creates it off the main actor (Keychain I/O);
    /// the editor writes rotations back through this binding.
    @State private var currentControlToken: String = ""

    /// The overlay credential, read but never shown here. The editor needs it to
    /// reject a control token that collides with it.
    @State private var currentOverlayToken: String = ""

    /// Collapses the server-state chip animation under Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Live state of the shared server, seeded from the running service so the
    /// first frame already reflects reality, then kept current by
    /// `.websocketServerStateChanged`. The chip reads Ready only for `.listening`.
    @State private var serverState: WebSocketServerService.ServerState =
        AppDelegate.shared?.websocketServer?.state ?? .stopped

    /// Shorthand for the standard settings card inset.
    private let cardPadding = AppConstants.SettingsUI.cardPadding

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: AppConstants.SettingsUI.sectionSpacing) {
            SectionHeaderWithStatus(
                title: "Stream Deck",
                subtitle: "Run WolfWave from a Stream Deck key.",
                statusText: status.text,
                statusColor: status.color,
                statusSymbol: status.symbol
            )

            controlCard
                .deepLinkSection("control")
            tokenCard
                .deepLinkSection("token")
            setupCard
                .deepLinkSection("setup")
        }
        .task {
            guard currentControlToken.isEmpty || currentOverlayToken.isEmpty else { return }
            let tokens = await Task.detached(priority: .userInitiated) {
                (
                    WebSocketAuthToken.currentOrCreate(for: .control),
                    WebSocketAuthToken.currentOrCreate(for: .overlay)
                )
            }.value
            currentControlToken = tokens.0
            currentOverlayToken = tokens.1
        }
        .task(id: websocketEnabled) {
            // Re-seed when the switch flips: the notification may have fired
            // while this pane was not on screen.
            serverState = AppDelegate.shared?.websocketServer?.state ?? .stopped
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name.websocketServerStateChanged
            )
        ) { notification in
            guard let rawValue = notification.stateString,
                  let state = WebSocketServerService.ServerState(rawValue: rawValue) else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.base)) {
                serverState = state
            }
        }
    }

    // MARK: - Status

    /// Reports the first thing standing between the user and a working key, so
    /// the chip is never a bare "Off" that leaves them hunting for which switch.
    /// Resolution lives in ``StreamDeckPaneStatus`` so the precedence rule is
    /// testable without the view.
    private var status: StreamDeckPaneStatus.Resolved {
        StreamDeckPaneStatus.resolve(
            controlEnabled: controlEnabled,
            serverEnabled: websocketEnabled,
            serverState: serverState
        )
    }

    // MARK: - Control Card

    /// The command switch, the loopback-only note, and a callout when the
    /// shared server is off or failed to start (each with a jump to Stream
    /// Widgets, where the fix lives).
    private var controlCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToggleSettingRow(
                title: "Allow Stream Deck commands",
                subtitle: "Let a Stream Deck key skip songs, hold the queue, and toggle your overlay.",
                isOn: $controlEnabled,
                accessibilityLabel: "Toggle Stream Deck commands",
                accessibilityIdentifier: "streamDeckControlEnabledToggle"
            )
            .padding(.horizontal, cardPadding)
            .padding(.vertical, DSSpace.s4)

            Divider().padding(.leading, cardPadding)

            HintRow(
                "Commands are only accepted from this Mac. A Stream Deck on another"
                    + " machine, or anything on your network, is refused.",
                systemImage: "lock.laptopcomputer"
            )
            .padding(.horizontal, cardPadding)
            .padding(.bottom, DSSpace.s4)

            // The coupling, stated rather than hidden. Both panes are served by
            // one WebSocketServerService on one port, so turning this on while
            // the server is off does nothing, and a key would just sit there
            // looking broken.
            if !websocketEnabled {
                VStack(alignment: .leading, spacing: DSSpace.s2) {
                    CalloutBanner(
                        "Stream Deck and your overlay share one connection, and it's currently off."
                            + " Turn on Stream Widgets and your keys start working.",
                        title: "The connection is off",
                        style: .warning,
                        systemImage: "bolt.horizontal.circle"
                    )
                    Button("Open Stream Widgets", action: openStreamWidgets)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("streamDeckOpenStreamWidgetsButton")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, cardPadding)
                .padding(.bottom, DSSpace.s4)
            } else if serverState == .error {
                // Switch on, server dead: a key would do nothing, so say why and
                // where the fix lives (the port is set in Stream Widgets).
                VStack(alignment: .leading, spacing: DSSpace.s2) {
                    CalloutBanner(
                        "Port may be in use. Turn Stream Widgets off, pick another port, then turn it back on.",
                        title: "Couldn't start",
                        style: .error,
                        systemImage: "exclamationmark.octagon"
                    )
                    Button("Open Stream Widgets", action: openStreamWidgets)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("streamDeckServerErrorOpenStreamWidgetsButton")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, cardPadding)
                .padding(.bottom, DSSpace.s4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyleUnpadded()
    }

    // MARK: - Token Card

    /// The control-token editor. `otherToken` hands it the overlay token so a
    /// pasted value that matches the overlay credential is refused.
    private var tokenCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DSSpace.s1) {
                CardEyebrowHeader("Control token", systemImage: "key.fill")
                Text("Paste this into the plugin's settings in the Stream Deck app. Treat it like a password: anything holding it can drive WolfWave from this Mac.")
                    .fieldSubtitle()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, cardPadding)
            .padding(.top, DSSpace.s4)

            // No divider: the eyebrow above is this card's only header, and the
            // row below carries its own field label. A rule between them read as
            // two separate headed sections stacked in one card.
            WebSocketTokenEditorRow(
                role: .control,
                title: "Stream Deck Control Token",
                subtitle: "Different from your overlay token, and it must stay different.",
                currentToken: $currentControlToken,
                streamerMode: streamerMode,
                otherToken: currentOverlayToken
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyleUnpadded()
    }

    // MARK: - Setup Card

    /// Numbered install steps, a mobile-app hint, and the setup guide link.
    private var setupCard: some View {
        VStack(alignment: .leading, spacing: DSSpace.s3) {
            CardEyebrowHeader("Setting it up", systemImage: "list.number")

            VStack(alignment: .leading, spacing: DSSpace.s2) {
                ForEach(Array(Self.setupSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: DSSpace.s2) {
                        Text(verbatim: "\(index + 1).")
                            .font(.system(size: DSFont.Size.sm, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(
                                width: DSDimension.Settings.stepNumberGutter,
                                alignment: .trailing
                            )
                        Text(step)
                            .fieldSubtitle()
                    }
                    // Combined so VoiceOver announces "1. Build the plugin…" as
                    // one item instead of reading the numeral on its own.
                    .accessibilityElement(children: .combine)
                }
            }

            HintRow(
                "No Stream Deck hardware? The Stream Deck mobile app gives you six keys for free.",
                systemImage: "iphone"
            )

            OpenInBrowserButton(
                urlString: AppConstants.URLs.streamDeckGuide,
                title: "Stream Deck Setup Guide",
                accessibilityLabel: "Open the Stream Deck setup guide",
                accessibilityIdentifier: "streamDeckDocsButton"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(cardPadding)
        .cardStyleUnpadded()
    }

    /// Kept as plain data so the copy is reviewable in one place rather than
    /// scattered through the view builder.
    ///
    /// Step 1 says "build it" rather than naming the Elgato Marketplace: the
    /// plugin is not listed there yet, and this pane was the only place in the
    /// product claiming otherwise. Step 4 names the port alone because the
    /// plugin pins the host to loopback and exposes no field for it.
    private static let setupSteps = [
        "Build the plugin from the repo and double-click it to install. The guide below has the commands.",
        "Drag a WolfWave key onto a page in the Stream Deck app.",
        "Open the key's settings and paste the control token above.",
        "Leave the port alone unless you changed it in Stream Widgets."
    ]
}
