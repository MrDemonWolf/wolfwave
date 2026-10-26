//
//  WebSocketSettingsView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-01-13.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import CoreText
import Network
import SwiftUI

/// Stream Widgets pane: the shared server switch, the OBS browser-source link,
/// widget appearance, and the raw WebSocket feed for custom overlays.
///
/// The view is decomposed into four sibling cards so a state change in one card doesn't
/// invalidate the others. This parent owns only what several cards share: the live server
/// state (so the header chip and `WebSocketServerCard` can't disagree) and the LAN IP.
/// Network IP discovery is cached in `@State` and refreshed off-main via `NWPathMonitor`
/// to avoid running `getifaddrs` on every render.
struct WebSocketSettingsView: View {
    /// Shared server switch. Re-keys the refresh `.task` so state and IP are
    /// re-read after every flip.
    @AppStorage(AppConstants.UserDefaults.websocketEnabled)
    private var websocketEnabled = false

    /// State-change animations collapse under Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - State

    // Seed from live services + cached IP so the first frame already reflects reality
    // instead of flashing "Stopped" or an empty Network Address row.
    @State private var serverState: WebSocketServerService.ServerState =
        AppDelegate.shared?.websocketServer?.state ?? .stopped
    @State private var clientCount: Int =
        AppDelegate.shared?.websocketServer?.connectionCount ?? 0
    @State private var localNetworkIP: String? = NetworkInfoService.cachedIPv4

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: AppConstants.SettingsUI.sectionSpacing) {
            SectionHeaderWithStatus(
                title: "Stream Widgets",
                subtitle: "Put your current song on screen in OBS.",
                statusText: serverStatusText,
                statusColor: serverStatusColor,
                statusSymbol: serverStatusSymbol
            )

            // Card order is the decision order, not the implementation order.
            // Turn it on, then take the ready-made widget (which is what almost
            // everyone wants), then style it. The raw WebSocket feed is last
            // because it is only for people building their own overlay, and
            // leading with it made a two-click setup look like a programming
            // task.
            WebSocketServerCard(serverState: serverState, localNetworkIP: localNetworkIP)
                .deepLinkSection("server")

            WebSocketBrowserSourceCard(localNetworkIP: localNetworkIP)
                .deepLinkSection("browser-source")
                .transition(.opacity)

            WebSocketWidgetAppearanceCard()
                .deepLinkSection("appearance")
                .transition(.opacity)

            WebSocketCustomOverlayCard(localNetworkIP: localNetworkIP)
                .deepLinkSection("custom-overlay")
                .transition(.opacity)
        }
        .task(id: websocketEnabled) {
            refreshServerState()
            await refreshLocalIP()
        }
        .task {
            await monitorNetworkPath()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name.websocketServerStateChanged
            )
        ) { notification in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.base)) {
                if let rawValue = notification.stateString,
                   let state = WebSocketServerService.ServerState(rawValue: rawValue) {
                    serverState = state
                }
                if let clients = notification.clientsCount {
                    clientCount = clients
                }
            }
        }
    }

    // MARK: - Status helpers

    /// Header chip label; shows the client count while listening.
    private var serverStatusText: String {
        switch serverState {
        case .listening:
            return clientCount > 0 ? "\(clientCount) connected" : "Listening"
        case .starting:
            return "Starting"
        case .error:
            return "Couldn't start"
        case .stopped:
            return "Stopped"
        }
    }

    /// Header chip tint for `serverState`.
    private var serverStatusColor: Color {
        switch serverState {
        case .listening: return DSColor.success
        case .starting:  return DSColor.warning
        case .error:     return DSColor.error
        case .stopped:   return DSColor.neutral
        }
    }

    /// Leading chip glyph so server state reads through shape as well as color.
    private var serverStatusSymbol: String {
        switch serverState {
        case .listening: return StatusChip.StateGlyph.on
        case .starting:  return StatusChip.StateGlyph.starting
        case .error:     return StatusChip.StateGlyph.error
        case .stopped:   return StatusChip.StateGlyph.off
        }
    }

    /// Pulls the latest server state + client count from the shared
    /// `WebSocketServerService` so the view's chips stay in sync with the
    /// service's actual state.
    private func refreshServerState() {
        guard let appDelegate = AppDelegate.shared else { return }
        serverState = appDelegate.websocketServer?.state ?? .stopped
        clientCount = appDelegate.websocketServer?.connectionCount ?? 0
    }

    /// Re-queries the cached LAN IPv4 address on the main actor and animates
    /// the change when the value differs from the current view state.
    private func refreshLocalIP() async {
        let ip = await NetworkInfoService.shared.refreshIPv4()
        await MainActor.run {
            guard ip != localNetworkIP else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.base)) {
                localNetworkIP = ip
            }
        }
    }

    /// Watches the system network path and refreshes the cached LAN IP when it changes.
    /// Subscribes to the process-wide `NetworkInfoService.pathUpdates()` stream so re-entering
    /// this settings pane doesn't pay `NWPathMonitor.start` again.
    private func monitorNetworkPath() async {
        for await _ in NetworkInfoService.pathUpdates() {
            await refreshLocalIP()
        }
    }
}

// MARK: - Browser Source Card

/// "Widget Setup": the widget HTTP server switch, its port, the OBS
/// browser-source links (local and LAN), and the recommended OBS size for the
/// current layout. The widget page needs the WebSocket server on to work, so
/// its switch is locked until Stream Widgets is on.
fileprivate struct WebSocketBrowserSourceCard: View {
    /// The LAN row slides in unless Reduce Motion is on.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Masks the URLs and disables Open / Copy on camera.
    @AppStorage(AppConstants.UserDefaults.streamerModeEnabled)
    private var streamerMode = false

    /// Shared WebSocket server switch.
    @AppStorage(AppConstants.UserDefaults.websocketEnabled)
    private var websocketEnabled = false

    /// Widget HTTP server switch (default off). Changes post
    /// `widgetHTTPServerChanged`.
    @AppStorage(AppConstants.UserDefaults.widgetHTTPEnabled)
    private var widgetHTTPEnabled = false

    /// Applied widget layout; picks the recommended OBS dimensions.
    @AppStorage(AppConstants.UserDefaults.widgetLayout)
    private var widgetLayout = AppConstants.Widget.Defaults.layout

    /// Persisted widget HTTP port; written only by `applyWidgetPort()`.
    @AppStorage(AppConstants.UserDefaults.widgetPort)
    private var storedWidgetPort: Int = Int(AppConstants.WebSocketServer.widgetDefaultPort)

    /// Port field text; may hold an uncommitted entry until `applyWidgetPort()`.
    @State private var widgetPortText: String = ""

    /// Result of the last port commit ("Saved" or "Not saved, kept X"), shown
    /// until the field is focused again.
    @State private var widgetPortFeedback: FieldValidationRow.State = .idle

    /// Commits a typed widget port when the field loses focus, so Tab or a
    /// click elsewhere keeps the edit instead of silently discarding it.
    @FocusState private var widgetPortFocused: Bool

    /// Cached read-only overlay token. Loaded once by `.task` so a SwiftUI recompute
    /// never reaches into the Keychain (which `WebSocketAuthToken.currentOrCreate()`
    /// would otherwise do, with side effects, on every render).
    @State private var currentToken: String = ""

    /// This Mac's LAN IPv4 address; `nil` hides the Network Address row.
    let localNetworkIP: String?

    /// Shorthand for the standard settings card inset.
    private let cardPadding = AppConstants.SettingsUI.cardPadding

    /// The port the widget server actually listens on: the same fallback and
    /// clamping as `Preferences.resolvePort`, so a stored value above the valid
    /// range can't produce a link the server isn't on.
    private var resolvedWidgetPort: UInt16 {
        Preferences.resolvePort(storedWidgetPort, default: AppConstants.WebSocketServer.widgetDefaultPort)
    }

    /// Loopback widget URL. Carries no token: `WidgetHTTPService` injects the
    /// overlay token itself for literal-loopback requests. A stored port of
    /// zero or less falls back to the default.
    private var widgetURL: String {
        let port = resolvedWidgetPort
        return "http://localhost:\(port)"
    }

    /// LAN widget URL. Unlike the loopback link it must carry the token in the
    /// query, so it stays hidden until the token has loaded.
    private var networkWidgetURL: String? {
        guard let ip = localNetworkIP, !currentToken.isEmpty else { return nil }
        let port = resolvedWidgetPort
        return "http://\(ip):\(port)/?token=\(currentToken)"
    }

    /// Why the Widget Webpage toggle is greyed out. One string so the visible
    /// hint, the tooltip, and the VoiceOver hint can never drift.
    private static let widgetToggleDisabledHint =
        "Turn on Stream Widgets above first. The widget page runs on that server."

    /// Why the widget links are not copyable right now, for the disabled-button
    /// tooltip. Names the switch the user actually needs to flip.
    private var widgetLinkDisabledReason: String {
        websocketEnabled
            ? "Turn on Enable Widget Webpage to copy."
            : "Turn on Stream Widgets to copy."
    }

    /// Whether `widgetPortText` is a port inside the allowed range.
    private var isWidgetPortValid: Bool {
        guard let port = UInt16(widgetPortText) else { return false }
        return port >= AppConstants.WebSocketServer.minPort
            && port <= AppConstants.WebSocketServer.maxPort
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s6) {
            widgetSetupHeader
            widgetSetupCard
        }
        .onAppear {
            widgetPortText = String(storedWidgetPort)
        }
        .task {
            // `.task` re-runs on every structural identity change; skip the
            // Keychain round-trip once the token is already loaded. In-session
            // saves/regenerations arrive via `.websocketAuthTokenChanged` below.
            guard currentToken.isEmpty else { return }
            await reloadToken()
        }
        .onReceive(NotificationCenter.default.publisher(for: .websocketAuthTokenChanged)) { _ in
            Task { await reloadToken() }
        }
    }

    /// Section header for the card.
    private var widgetSetupHeader: some View {
        SectionHeaderWithStatus(
            title: "Widget Setup",
            subtitle: "Use this link in OBS (Browser Source) or open it in any browser.",
            prominence: .section
        )
    }

    /// Switch, port, links, and the OBS sizing callout.
    private var widgetSetupCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToggleSettingRow(
                title: "Enable Widget Webpage",
                subtitle: "Hosts the page you'll add to OBS",
                isOn: $widgetHTTPEnabled,
                isDisabled: !websocketEnabled,
                accessibilityLabel: "Toggle Widget Webpage",
                accessibilityIdentifier: "widgetHTTPEnabledToggle",
                accessibilityHint: websocketEnabled ? nil : Self.widgetToggleDisabledHint,
                onChange: { _ in
                    NotificationCenter.default.post(
                        name: Notification.Name.widgetHTTPServerChanged,
                        object: nil
                    )
                }
            )
            .padding(.horizontal, cardPadding)
            .padding(.vertical, DSSpace.s4)
            .opacity(websocketEnabled ? 1.0 : 0.5)
            .help(websocketEnabled ? "" : Self.widgetToggleDisabledHint)

            if !websocketEnabled {
                HintRow(Self.widgetToggleDisabledHint, systemImage: "lock.fill")
                    .padding(.horizontal, cardPadding)
                    .padding(.bottom, DSSpace.s4)
            }

            Divider().padding(.leading, cardPadding)

            HStack(spacing: DSSpace.s4) {
                VStack(alignment: .leading, spacing: DSSpace.s0) {
                    Text("Widget Port (Advanced)").font(.system(size: DSFont.Size.base, weight: .medium))
                    Text(verbatim: "Default: \(AppConstants.WebSocketServer.widgetDefaultPort)")
                        .font(.system(size: DSFont.Size.sm))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                TextField("Port", text: $widgetPortText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .multilineTextAlignment(.center)
                    .disabled(widgetHTTPEnabled)
                    .focused($widgetPortFocused)
                    .accessibilityLabel("Widget server port")
                    .accessibilityIdentifier("widgetPortField")
                    .onSubmit { applyWidgetPort() }
                    .onChange(of: widgetPortFocused) { _, focused in
                        if focused {
                            widgetPortFeedback = .idle
                        } else {
                            applyWidgetPort()
                        }
                    }
                    .onChange(of: widgetHTTPEnabled) { _, enabled in
                        // Turning the server on locks the field; keep a typed port
                        // the click on the toggle would otherwise skip.
                        if enabled { applyWidgetPort() }
                    }
            }
            .padding(.horizontal, cardPadding)
            .padding(.vertical, DSSpace.s4)
            .opacity(websocketEnabled && widgetHTTPEnabled ? 1.0 : 0.5)

            if !widgetPortText.isEmpty && !isWidgetPortValid {
                FieldValidationRow(
                    state: .invalid(
                        "Port must be between \(AppConstants.WebSocketServer.minPort) "
                            + "and \(AppConstants.WebSocketServer.maxPort).")
                )
                .padding(.horizontal, cardPadding)
                .padding(.bottom, DSSpace.s2)
            } else if widgetPortFeedback != .idle {
                FieldValidationRow(state: widgetPortFeedback)
                    .padding(.horizontal, cardPadding)
                    .padding(.bottom, DSSpace.s2)
            }

            if widgetHTTPEnabled {
                // The field is locked by the Enable Widget Webpage switch above,
                // so the hint names that switch.
                HintRow("Turn off Enable Widget Webpage to change the port.", systemImage: "lock.fill")
                    .padding(.horizontal, cardPadding)
                    .padding(.bottom, DSSpace.s2)
            }

            Divider().padding(.leading, cardPadding)

            CopyableURLRow(
                url: widgetURL,
                isStreamerMode: streamerMode,
                actionsDisabled: !websocketEnabled || !widgetHTTPEnabled,
                actionsDisabledReason: widgetLinkDisabledReason,
                urlLineLimit: 2,
                copyLabel: "Copy Link",
                copiedLabel: "Copied",
                copyAccessibilityLabel: "Copy widget URL",
                copyAccessibilityIdentifier: "copyWidgetURLButton"
            ) {
                OpenInBrowserButton(
                    urlString: widgetURL,
                    isDisabled: !websocketEnabled || !widgetHTTPEnabled || streamerMode,
                    accessibilityLabel: "Open widget in browser",
                    accessibilityHint: "Opens the widget in your default browser",
                    accessibilityIdentifier: "openWidgetURLButton"
                )
            }
            .padding(.horizontal, cardPadding)
            .padding(.vertical, DSSpace.s4)

            Group {
                if let networkWidget = networkWidgetURL {
                    VStack(spacing: 0) {
                        Divider().padding(.leading, cardPadding)
                        CopyableURLRow(
                            label: "Network Address",
                            url: networkWidget,
                            subtitle: "Use this for two-PC setups. The localhost link above is safer. This one sends your token over the network unencrypted, so only share it on a network you trust.",
                            isStreamerMode: streamerMode,
                            actionsDisabled: !websocketEnabled || !widgetHTTPEnabled,
                            actionsDisabledReason: widgetLinkDisabledReason,
                            copyLabel: "Copy Link",
                            copiedLabel: "Copied",
                            copyAccessibilityLabel: "Copy network widget URL",
                            copyAccessibilityIdentifier: "copyNetworkWidgetURLButton"
                        ) {
                            OpenInBrowserButton(
                                urlString: networkWidget,
                                isDisabled: !websocketEnabled || !widgetHTTPEnabled || streamerMode,
                                accessibilityLabel: "Open network widget in browser",
                                accessibilityIdentifier: "openNetworkWidgetURLButton"
                            )
                        }
                        .padding(.horizontal, cardPadding)
                        .padding(.vertical, DSSpace.s4)
                    }
                    .id(networkWidget)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.base), value: localNetworkIP)

            Divider().padding(.leading, cardPadding)

            CalloutBanner(
                "In OBS, set Width and Height to "
                    + "**\(AppConstants.Widget.recommendedDimensionsText(for: widgetLayout))** "
                    + "for the \(widgetLayout) layout. "
                    + "Enable \"Shutdown source when not visible\" "
                    + "so the widget reconnects properly.",
                style: .info
            )
            .padding(.horizontal, cardPadding)
            .padding(.top, DSSpace.s4)
            .padding(.bottom, cardPadding)
        }
        .cardStyleUnpadded()
    }

    /// Commits the widget HTTP port text field.
    ///
    /// A valid, changed port is persisted and `widgetHTTPServerChanged` is posted
    /// so the widget server restarts on it. An invalid entry is reverted to the
    /// stored port instead of being left on screen looking applied, and the
    /// feedback line says which of the two happened.
    private func applyWidgetPort() {
        guard isWidgetPortValid, let port = UInt16(widgetPortText) else {
            let kept = storedWidgetPort
            widgetPortText = String(kept)
            widgetPortFeedback = .invalid("Not saved. Kept port \(kept).")
            return
        }
        guard Int(port) != storedWidgetPort else { return }
        storedWidgetPort = Int(port)
        widgetPortFeedback = .valid("Saved. Widget port is \(port).")
        NotificationCenter.default.post(
            name: Notification.Name.widgetHTTPServerChanged,
            object: nil
        )
    }

    /// Re-reads the read-only overlay token off the main thread (Keychain I/O) and
    /// publishes it into the card's state. Called on first appearance and
    /// whenever `.websocketAuthTokenChanged` reports a save/regeneration.
    private func reloadToken() async {
        let token = await Task.detached(priority: .userInitiated) {
            WebSocketAuthToken.currentOrCreate(for: .overlay)
        }.value
        currentToken = token
    }
}

// MARK: - Widget Appearance Card

/// Theme, layout, colors, and font for the overlay, edited as a draft with an
/// explicit Apply (Command-S) / Revert, plus the live web preview.
fileprivate struct WebSocketWidgetAppearanceCard: View {
    /// The Apply bar's dirty-state change animates unless Reduce Motion is on.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Applied (persisted) values. These are the source of truth the overlay
    // reads via `WebSocketServerService.broadcastWidgetConfig()`. The card never
    // writes them on every keystroke, only when the user taps Apply.
    @AppStorage(AppConstants.UserDefaults.widgetTheme)
    private var widgetTheme = AppConstants.Widget.Defaults.theme

    @AppStorage(AppConstants.UserDefaults.widgetLayout)
    private var widgetLayout = AppConstants.Widget.Defaults.layout

    @AppStorage(AppConstants.UserDefaults.widgetTextColor)
    private var widgetTextColor = AppConstants.Widget.Defaults.textColor

    @AppStorage(AppConstants.UserDefaults.widgetBackgroundColor)
    private var widgetBackgroundColor = AppConstants.Widget.Defaults.backgroundColor

    @AppStorage(AppConstants.UserDefaults.widgetFontFamily)
    private var widgetFontFamily = AppConstants.Widget.Defaults.fontFamily

    /// Live edits. Every control binds here and the preview renders this, so
    /// tweaks show instantly without touching the live overlay. `Apply` copies
    /// this into the `@AppStorage` values above and broadcasts; `Revert` drops it.
    @State private var draft: WidgetAppearanceConfig

    /// Font family list loaded off-main on first appear. `availableFontFamilies` enumerates every
    /// installed font (hundreds of entries on design-heavy Macs) and blocks ~100-400ms if invoked
    /// inside `body`. Keep it lazy + off the main thread.
    @State private var fontFamilies: [String] = []

    /// Shorthand for the standard settings card inset.
    private let cardPadding = AppConstants.SettingsUI.cardPadding

    /// Seeds `draft` from the applied values.
    init() {
        // Seed the draft from whatever's currently applied. The `@AppStorage`
        // wrappers initialize from their declared defaults; only the draft is
        // overridden here.
        _draft = State(initialValue: WidgetAppearanceConfig.loadApplied())
    }

    /// The currently-applied config, rebuilt from `@AppStorage` so it tracks any
    /// external change. `draft` is compared against this to detect edits.
    private var applied: WidgetAppearanceConfig {
        WidgetAppearanceConfig(
            theme: widgetTheme,
            layout: widgetLayout,
            textColor: widgetTextColor,
            backgroundColor: widgetBackgroundColor,
            fontFamily: widgetFontFamily
        )
    }

    /// True when the draft has edits not yet applied. Drives the Apply bar.
    private var isDirty: Bool { draft != applied }

    /// Color-picker binding over `draft.textColor` (a hex string). An
    /// unparseable stored value shows as white; a color that can't be
    /// converted to hex is ignored.
    private var textColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: draft.textColor) ?? .white },
            set: { newColor in
                if let hex = newColor.toHex() { draft.textColor = hex }
            }
        )
    }

    /// Same as `textColorBinding` for the background, falling back to black.
    private var backgroundColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: draft.backgroundColor) ?? .black },
            set: { newColor in
                if let hex = newColor.toHex() { draft.backgroundColor = hex }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s6) {
            widgetAppearanceHeader
            widgetAppearanceCard
            applyBar
            WidgetAppearancePreview(config: draft)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.fast), value: isDirty)
        // Font enumeration is slow; run it once, off the main actor.
        .task {
            guard fontFamilies.isEmpty else { return }
            let families = await Task.detached(priority: .userInitiated) {
                CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
            }.value
            fontFamilies = families
        }
    }

    /// Section header for the card.
    private var widgetAppearanceHeader: some View {
        SectionHeaderWithStatus(
            title: "Widget Appearance",
            subtitle: "Tweak colors, fonts, and layout for your widget.",
            prominence: .section
        )
    }

    /// Theme / layout pickers, the color row, and the font picker, all bound
    /// to `draft`.
    private var widgetAppearanceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            twoColumnRow {
                controlCell("Theme") {
                    Picker("", selection: $draft.theme) {
                        ForEach(AppConstants.Widget.themes, id: \.self) { theme in
                            Text(theme).tag(theme)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Widget theme")
                    .accessibilityIdentifier("widgetThemePicker")
                }
            } trailing: {
                controlCell("Layout") {
                    Picker("", selection: $draft.layout) {
                        ForEach(AppConstants.Widget.layouts, id: \.self) { layout in
                            Text(layout).tag(layout)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Widget layout")
                    .accessibilityIdentifier("widgetLayoutPicker")
                }
            }

            Divider().padding(.leading, cardPadding)

            // The color row is *always* present (just disabled for preset
            // themes) so switching themes never adds or removes a row. A
            // changing card height shifts everything below it and makes the
            // settings pane scroll-jump.
            twoColumnRow {
                controlCell("Text") {
                    ColorPicker("", selection: textColorBinding, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 40)
                        .accessibilityLabel("Widget text color")
                        .accessibilityIdentifier("widgetTextColorPicker")
                }
            } trailing: {
                controlCell("Background") {
                    ColorPicker("", selection: backgroundColorBinding, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 40)
                        .accessibilityLabel("Widget background color")
                        .accessibilityIdentifier("widgetBackgroundColorPicker")
                }
            }
            .disabled(!draft.themeCustomizable)
            .opacity(draft.themeCustomizable ? 1 : 0.45)

            Text(draft.themeCustomizable
                 ? "Default, Glass, and WolfWave let you pick custom colors."
                 : "\(draft.theme) is a preset. Its colors are fixed.")
                .captionText()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, cardPadding)
                .padding(.bottom, DSSpace.s4)

            Divider().padding(.leading, cardPadding)

            // Font spans the full width (the family name needs the room) but
            // reuses `controlCell` so it reads as a deliberate row, not a
            // leftover beneath the paired controls above.
            controlCell("Font") {
                Picker("", selection: $draft.fontFamily) {
                    Text("System Default").tag("System Default")
                    if !fontFamilies.isEmpty {
                        Divider()
                        ForEach(fontFamilies, id: \.self) { font in
                            Text(font).tag(font)
                        }
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Widget font")
                .accessibilityIdentifier("widgetFontPicker")
            }
            .padding(.vertical, DSSpace.s4)
        }
        .cardStyleUnpadded()
    }

    // MARK: - Apply Bar

    /// Pending-changes footer: an unsaved hint plus Revert / Apply. Everything
    /// above edits `draft`; nothing reaches the live overlay until Apply.
    private var applyBar: some View {
        HStack(spacing: DSSpace.s3) {
            if isDirty {
                Circle()
                    .fill(Color(nsColor: .controlAccentColor))
                    .frame(width: DSSpace.s2, height: DSSpace.s2)
                Text("Unsaved changes").fieldSubtitle()
            } else {
                Text("Overlay is up to date.").fieldSubtitle()
            }
            Spacer(minLength: DSSpace.s2)
            Button("Revert") { draft = applied }
                .disabled(!isDirty)
                .accessibilityIdentifier("widgetAppearanceRevertButton")
            Button("Apply", action: applyChanges)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty)
                .accessibilityIdentifier("widgetAppearanceApplyButton")
        }
    }

    /// Commit the draft: copy it into the persisted `@AppStorage` values, then
    /// push the new config to every connected overlay. The values are written
    /// before the broadcast because the server reads them from defaults.
    private func applyChanges() {
        widgetTheme = draft.theme
        widgetLayout = draft.layout
        widgetTextColor = draft.textColor
        widgetBackgroundColor = draft.backgroundColor
        widgetFontFamily = draft.fontFamily
        broadcastWidgetConfig()
    }

    // MARK: - Layout Helpers

    /// One label-left / control-right cell. Shared by both columns and the
    /// full-width Font row so every appearance control aligns identically.
    @ViewBuilder
    private func controlCell<Control: View>(
        _ label: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: DSSpace.s2) {
            Text(label).font(.system(size: DSFont.Size.base, weight: .medium))
            Spacer(minLength: DSSpace.s2)
            control()
        }
        .padding(.horizontal, cardPadding)
    }

    /// Two equal-width cells split by a hairline divider, matching the app's
    /// other paired settings rows (e.g. Startup / Display Mode).
    @ViewBuilder
    private func twoColumnRow<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 0) {
            leading().frame(maxWidth: .infinity)
            Divider()
            trailing().frame(maxWidth: .infinity)
        }
        .padding(.vertical, DSSpace.s4)
    }

    /// Pushes the current widget theme/layout/font/color values to every
    /// connected overlay via `WebSocketServerService.broadcastWidgetConfig()`.
    /// Called from `applyChanges()` when the user taps Apply.
    private func broadcastWidgetConfig() {
        let server = AppDelegate.shared?.websocketServer
        Task { await server?.broadcastWidgetConfig() }
    }
}

// MARK: - Preview

#Preview("WebSocket Listening with Clients") {
    @Previewable @AppStorage(AppConstants.UserDefaults.websocketEnabled) var websocketEnabled = true
    @Previewable @AppStorage(AppConstants.UserDefaults.widgetHTTPEnabled) var widgetHTTPEnabled = true

    WebSocketSettingsView()
        .padding()
        .frame(width: 700)
        .onAppear {
            NotificationCenter.default.postWebSocketServerState("listening", clients: 2)
        }
}

#Preview("WebSocket Stopped") {
    @Previewable @AppStorage(AppConstants.UserDefaults.websocketEnabled) var websocketEnabled = false
    WebSocketSettingsView()
        .padding()
        .frame(width: 700)
}
