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

    /// Keeps the token editor from showing an empty value while Keychain loads.
    @State private var isLoadingTokens = true

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
            Text("Control WolfWave from your Stream Deck.")
                .fieldSubtitle()

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
            isLoadingTokens = false
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

    /// The command switch with its loopback-only footnote, and a callout when
    /// the shared server is off or failed to start. The callout carries its own
    /// jump to Stream Widgets, where the fix lives.
    ///
    /// One padded card, one rhythm: the footnote belongs to the switch (the row
    /// draws it), and the callout sits one row gap below with its button inside.
    private var controlCard: some View {
        VStack(alignment: .leading, spacing: AppConstants.SettingsUI.cardRowSpacing) {
            StatusChip(text: status.text, color: status.color, systemImage: status.symbol)
                .accessibilityLabel("Stream Deck status: \(status.text)")

            ToggleSettingRow(
                title: "Allow Stream Deck commands",
                subtitle: "Let a Stream Deck key skip songs, hold the queue, and toggle your overlay.",
                isOn: $controlEnabled,
                accessibilityLabel: "Toggle Stream Deck commands",
                accessibilityIdentifier: "streamDeckControlEnabledToggle",
                hint: "Commands are only accepted from this Mac. A Stream Deck on another"
                    + " machine, or anything on your network, is refused.",
                hintSystemImage: "lock.fill"
            )

            // The coupling, stated rather than hidden. Both panes are served by
            // one WebSocketServerService on one port, so turning this on while
            // the server is off does nothing, and a key would just sit there
            // looking broken.
            if !websocketEnabled {
                CalloutBanner(
                    "Stream Deck and your overlay share one connection, and it's currently off."
                        + " Turn on Stream Widgets and your keys start working.",
                    title: "The connection is off",
                    style: .warning,
                    systemImage: "bolt.horizontal.circle"
                ) {
                    Button("Open Stream Widgets", action: openStreamWidgets)
                        .buttonStyle(.borderedProminent)
                        .tint(CalloutBanner.Style.warning.tint)
                        .pointerCursor()
                        .accessibilityIdentifier("streamDeckOpenStreamWidgetsButton")
                }
            } else if serverState == .error {
                // Switch on, server dead: a key would do nothing, so say why and
                // where the fix lives (the port is set in Stream Widgets).
                CalloutBanner(
                    "Port may be in use. Turn Stream Widgets off, pick another port, then turn it back on.",
                    title: "Couldn't start",
                    style: .error,
                    systemImage: "exclamationmark.octagon"
                ) {
                    Button("Open Stream Widgets", action: openStreamWidgets)
                        .buttonStyle(.bordered)
                        .pointerCursor()
                        .accessibilityIdentifier("streamDeckServerErrorOpenStreamWidgetsButton")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - Token Card

    /// The control-token editor, and nothing above it: the row's title, its
    /// one line, the field with Reveal and Copy, then Regenerate. Same shape as
    /// the Overlay Token row in Stream Widgets, which renders the same editor.
    ///
    /// The card used to stack an eyebrow, a paragraph, the field title, and a
    /// caption before the field: four levels of text for one value. The one
    /// line keeps the two things that matter: it's a password, and it isn't
    /// the overlay token. The setup steps below cover where to paste it.
    ///
    /// `otherToken` hands the editor the overlay token so a pasted value that
    /// matches the overlay credential is refused.
    private var tokenCard: some View {
        ZStack {
            WebSocketTokenEditorRow(
                role: .control,
                title: "Stream Deck Control Token",
                subtitle: "A password for the Stream Deck plugin. Not your overlay token.",
                currentToken: $currentControlToken,
                streamerMode: streamerMode,
                otherToken: currentOverlayToken
            )
            .skeleton(isLoadingTokens)

            if isLoadingTokens {
                LoadingRow(text: "Loading Stream Deck credentials…")
            }
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
