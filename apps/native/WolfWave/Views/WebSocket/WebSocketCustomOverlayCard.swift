//
//  WebSocketCustomOverlayCard.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-08-17.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// The raw WebSocket feed: port, overlay credential, and the two addresses a
/// hand-built overlay connects to.
///
/// Split out of the connection card, and placed last in the pane, because it
/// serves a different person. Someone who just wants a now-playing box on stream
/// needs the Browser Source card above and nothing here; only someone writing
/// their own overlay needs an address and a token. Leading with these rows made
/// a two-click setup look like a programming task.
struct WebSocketCustomOverlayCard: View {
    // MARK: - Properties

    /// The network-address row slides in unless Reduce Motion is on.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Shared server switch. While on, the port field is locked and the copy
    /// buttons work; while off, copying is disabled.
    @AppStorage(AppConstants.UserDefaults.websocketEnabled)
    private var websocketEnabled = false

    /// Masks the token and addresses on camera.
    @AppStorage(AppConstants.UserDefaults.streamerModeEnabled)
    private var streamerMode = false

    /// Persisted WebSocket port; written only by `applyPort()`.
    @AppStorage(AppConstants.UserDefaults.websocketServerPort)
    private var storedPort: Int = Int(AppConstants.WebSocketServer.defaultPort)

    /// Port field text. Seeded from `storedPort` on appear; may hold an
    /// uncommitted or invalid entry until `applyPort()` runs.
    @State private var portText: String = ""

    /// Result of the last port commit ("Saved" or "Not saved, kept X"), shown
    /// until the field is focused again.
    @State private var portFeedback: FieldValidationRow.State = .idle

    /// Commits a typed port when the field loses focus, so Tab or a click
    /// elsewhere keeps the edit instead of silently discarding it.
    @FocusState private var portFocused: Bool

    /// Currently-persisted overlay token. Seeded empty so struct init doesn't hit
    /// the Keychain. Populated by `.task` off-main on first appear, and re-read
    /// after edits or regenerations so the address rows stay in sync.
    @State private var currentToken: String = ""

    /// The control credential, read but never shown here. The editor needs it to
    /// reject an overlay token that collides with it; the two must stay distinct
    /// or the role separation in `WebSocketAuthToken` collapses.
    @State private var currentControlToken: String = ""

    /// This Mac's LAN IPv4 address; `nil` hides the Network Address row.
    let localNetworkIP: String?

    /// Shorthand for the standard settings card inset.
    private let cardPadding = AppConstants.SettingsUI.cardPadding

    /// `nil` until the token is loaded.
    ///
    /// `currentToken` starts empty and is filled by `.task` after the view
    /// appears, so on the first frame these rendered a URL ending in `?token=`.
    /// Copying during that window hands OBS an address that authenticates as
    /// nothing and fails silently, which is a far worse outcome than briefly
    /// showing no address at all.
    private var connectionURL: String? {
        guard !currentToken.isEmpty else { return nil }
        return "ws://localhost:\(storedPort)/?token=\(currentToken)"
    }

    /// LAN variant of `connectionURL`; `nil` without an IP or before the
    /// token loads.
    private var networkConnectionURL: String? {
        guard let ip = localNetworkIP, !currentToken.isEmpty else { return nil }
        return "ws://\(ip):\(storedPort)/?token=\(currentToken)"
    }

    /// Whether `portText` parses as a port inside the allowed
    /// `WebSocketServer.minPort ... maxPort` range.
    private var isPortValid: Bool {
        guard let port = UInt16(portText) else { return false }
        return port >= AppConstants.WebSocketServer.minPort
            && port <= AppConstants.WebSocketServer.maxPort
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DSSpace.s1) {
                CardEyebrowHeader("Build your own overlay", systemImage: "curlybraces")
                Text("Skip this unless you're writing your own overlay. Connect to the address below and WolfWave sends a JSON message on every track change.")
                    .fieldSubtitle()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, cardPadding)
            .padding(.top, DSSpace.s4)
            .padding(.bottom, DSSpace.s3)

            Divider().padding(.leading, cardPadding)

            portRow

            Divider().padding(.leading, cardPadding)

            WebSocketTokenEditorRow(
                role: .overlay,
                title: "Overlay Token",
                subtitle: "Read-only. Anything holding it can watch your now-playing, nothing more.",
                currentToken: $currentToken,
                streamerMode: streamerMode,
                otherToken: currentControlToken
            )

            Divider().padding(.leading, cardPadding)

            if let connectionURL {
                CopyableURLRow(
                    label: "Local Address",
                    url: connectionURL,
                    subtitle: "For an overlay running on this Mac.",
                    isStreamerMode: streamerMode,
                    actionsDisabled: !websocketEnabled,
                    actionsDisabledReason: "Turn on Stream Widgets to copy.",
                    copyAccessibilityLabel: "Copy local connection URL",
                    copyAccessibilityIdentifier: "copyConnectionURLButton"
                )
                .padding(.horizontal, cardPadding)
                .padding(.vertical, DSSpace.s4)
            } else {
                LoadingRow(text: "Loading address\u{2026}")
                    .padding(.horizontal, cardPadding)
                    .padding(.vertical, DSSpace.s4)
            }

            Group {
                if let networkURL = networkConnectionURL {
                    VStack(spacing: 0) {
                        Divider().padding(.leading, cardPadding)
                        CopyableURLRow(
                            label: "Network Address",
                            url: networkURL,
                            subtitle: "For an overlay on a second PC, on the same network.",
                            isStreamerMode: streamerMode,
                            actionsDisabled: !websocketEnabled,
                            actionsDisabledReason: "Turn on Stream Widgets to copy.",
                            copyAccessibilityLabel: "Copy network connection URL",
                            copyAccessibilityIdentifier: "copyNetworkConnectionURLButton"
                        )
                        .padding(.horizontal, cardPadding)
                        .padding(.vertical, DSSpace.s4)
                    }
                    .id(networkURL)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.base), value: localNetworkIP)
        }
        .cardStyleUnpadded()
        .onAppear {
            portText = String(storedPort)
        }
        .task {
            guard currentToken.isEmpty || currentControlToken.isEmpty else { return }
            let tokens = await Task.detached(priority: .userInitiated) {
                (
                    WebSocketAuthToken.currentOrCreate(for: .overlay),
                    WebSocketAuthToken.currentOrCreate(for: .control)
                )
            }.value
            currentToken = tokens.0
            currentControlToken = tokens.1
        }
    }

    // MARK: - Port

    /// The port field, plus the reason it is locked when it is.
    ///
    /// The lock note is rendered *above* the disabled field rather than below it.
    /// Underneath, it was only found after the user had already tried to type
    /// into a greyed-out box and wondered what was broken.
    private var portRow: some View {
        VStack(alignment: .leading, spacing: DSSpace.s2) {
            if websocketEnabled {
                HintRow(
                    "Turn Stream Widgets off to change the port.",
                    systemImage: "lock.fill"
                )
            }

            HStack(spacing: DSSpace.s4) {
                VStack(alignment: .leading, spacing: DSSpace.s0) {
                    Text("Port").font(.system(size: DSFont.Size.base, weight: .medium))
                    Text(verbatim: "Default: \(AppConstants.WebSocketServer.defaultPort)")
                        .font(.system(size: DSFont.Size.sm))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                TextField("Port", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .multilineTextAlignment(.center)
                    .disabled(websocketEnabled)
                    .focused($portFocused)
                    .accessibilityLabel("Server port")
                    .accessibilityIdentifier("websocketPortField")
                    .onSubmit { applyPort() }
                    .onChange(of: portFocused) { _, focused in
                        if focused {
                            portFeedback = .idle
                        } else {
                            applyPort()
                        }
                    }
                    .onChange(of: websocketEnabled) { _, enabled in
                        // Turning the server on locks the field; keep a typed port
                        // the click on the toggle would otherwise skip.
                        if enabled { applyPort() }
                    }
            }
            .opacity(websocketEnabled ? 0.5 : 1.0)

            if !portText.isEmpty && !isPortValid {
                FieldValidationRow(
                    state: .invalid(
                        "Port must be between \(AppConstants.WebSocketServer.minPort) "
                            + "and \(AppConstants.WebSocketServer.maxPort).")
                )
            } else if portFeedback != .idle {
                FieldValidationRow(state: portFeedback)
            }
        }
        .padding(.horizontal, cardPadding)
        .padding(.vertical, DSSpace.s4)
    }

    /// Commits the port text field.
    ///
    /// A valid, changed port is persisted and `websocketServerChanged` is posted
    /// so the server restarts on it. An invalid entry is reverted to the stored
    /// port instead of being left on screen looking applied, and the feedback
    /// line says which of the two happened.
    private func applyPort() {
        guard isPortValid, let port = UInt16(portText) else {
            let kept = storedPort
            portText = String(kept)
            portFeedback = .invalid("Not saved. Kept port \(kept).")
            return
        }
        guard Int(port) != storedPort else { return }
        storedPort = Int(port)
        portFeedback = .valid("Saved. Port is \(port).")
        NotificationCenter.default.postWebSocketServerChanged(port: port)
    }
}
