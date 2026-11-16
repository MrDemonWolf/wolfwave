//
//  IntegrationDashboardView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-07.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// General-pane dashboard: one row per integration (Twitch chat, Discord
/// profile, Stream Widgets) with a brand glyph, a status chip, one plain line
/// of detail, and "Configure ›".
///
/// The chips report **connections**, never what an audience can see. A
/// connected Discord session does not mean a song is showing on the profile,
/// and a running widget server does not mean OBS loaded the browser source.
/// Keep the copy inside that limit: say what WolfWave knows, then point at the
/// pane that can check the rest.
///
/// The view holds no integration state. `MusicMonitorSettingsView` passes each
/// service's live state in, `Status` turns it into chip + subtitle, and
/// "Configure ›" routes back through `configure`.
struct IntegrationDashboardView: View {

    /// Streamer Mode masks the Twitch channel and widget URL in the subtitles.
    @AppStorage(AppConstants.UserDefaults.streamerModeEnabled)
    private var streamerMode = false

    // MARK: - Inputs

    /// Whether the Twitch chat bot is connected.
    var twitchConnected: Bool
    /// Channel login shown as `@channel`; masked under Streamer Mode.
    var twitchChannel: String?
    /// The "Show on Discord" switch. Off outranks the connection state, so a
    /// switched-off integration never reads as a failed connection.
    var discordEnabled: Bool
    /// Discord IPC connection lifecycle.
    var discordState: DiscordRPCService.ConnectionState
    /// Lifecycle of the server behind Stream Widgets.
    var serverState: WebSocketServerService.ServerState
    /// Browser-source link, shown only while the server is listening; masked
    /// under Streamer Mode. Pass `WidgetLink.loopback` so custom ports show.
    var widgetURL: String
    /// Music Automation permission is denied. Every row switches to a Paused
    /// chip and explains why.
    var permissionPaused: Bool = false

    /// Routes to a specific Settings section when "Configure ›" is tapped.
    var configure: (Section) -> Void = { _ in }

    /// The settings destination behind each row's "Configure ›" button.
    enum Section { case twitch, discord, obs }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s3) {
            HStack {
                Text("Integrations")
                    .sectionHeader()
                Spacer()
                Text("Connection status and setup.")
                    .font(.system(size: DSFont.Size.body))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                row(
                    icon: brandIcon("TwitchLogo", fallback: "bubble.left.fill", color: AppConstants.Brand.twitch),
                    name: "Twitch chat",
                    status: twitchStatus,
                    action: { configure(.twitch) }
                )
                Divider().padding(.leading, DSSpace.s11)
                row(
                    icon: brandIcon("DiscordLogo", fallback: "headphones", color: AppConstants.Brand.discord),
                    name: "Discord profile",
                    status: Status.discord(
                        enabled: discordEnabled, state: discordState, permissionPaused: permissionPaused
                    ),
                    action: { configure(.discord) }
                )
                Divider().padding(.leading, DSSpace.s11)
                row(
                    icon: Image(systemName: "tv.badge.wifi")
                        .font(.system(size: DSFont.Size.md, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22),
                    name: "Stream Widgets",
                    status: widgetStatus,
                    action: { configure(.obs) }
                )
            }
            .cardStyleUnpadded()
        }
    }

    // MARK: - Row

    /// Builds a single integration row: brand icon, name + subtitle, status
    /// chip, and a "Configure" affordance that opens the corresponding
    /// settings pane.
    ///
    /// - Parameters:
    ///   - icon: View rendering the brand or fallback icon.
    ///   - name: Human-readable integration name (Twitch, Discord, etc.).
    ///   - status: Resolved chip and the line shown below the name.
    ///   - action: Closure invoked when the configure button is pressed.
    @ViewBuilder
    private func row<Icon: View>(
        icon: Icon,
        name: String,
        status: Status,
        action: @escaping () -> Void
    ) -> some View {
        let details = VStack(alignment: .leading, spacing: DSSpace.s0) {
            Text(name)
                .font(.system(size: DSFont.Size.base, weight: .medium))
            Text(status.subtitle)
                .font(.system(size: DSFont.Size.sm))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        let chip = StatusChip(text: status.text, color: status.color, systemImage: status.symbol)
        let configureButton = Button(action: action) {
            HStack(spacing: DSSpace.s0) {
                Text("Configure")
                Image(systemName: "chevron.right")
                    .font(.system(size: DSFont.Size.xs, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(.system(size: DSFont.Size.body))
        }
        .buttonStyle(.borderless)
        .pointerCursor()
        .accessibilityLabel("Configure \(name)")

        ViewThatFits(in: .horizontal) {
            HStack(spacing: DSSpace.s4) {
                icon
                details
                Spacer(minLength: DSSpace.s2)
                chip
                configureButton
            }
            .frame(minWidth: DSDimension.Settings.inlineActionsMinWidth)

            VStack(alignment: .leading, spacing: DSSpace.s3) {
                HStack(alignment: .top, spacing: DSSpace.s4) {
                    icon
                    details
                    Spacer(minLength: 0)
                }
                HStack {
                    chip
                    Spacer()
                    configureButton
                }
            }
        }
        .padding(.horizontal, DSSpace.s5)
        .padding(.vertical, DSSpace.s4)
    }

    // MARK: - Brand icon helper

    /// Cached per-asset existence check. `NSImage(named:)` allocates and decodes. Caching the
    /// boolean lookup keeps row rendering free of asset-catalog work on every redraw.
    nonisolated(unsafe) private static var brandIconExistsCache: [String: Bool] = [:]
    /// Guards `brandIconExistsCache`; the static is shared by every instance.
    private static let brandIconCacheLock = NSLock()

    /// Returns whether an asset of the given name exists in the bundle's asset
    /// catalog, caching the result so the lookup happens at most once per asset.
    private static func brandIconExists(_ asset: String) -> Bool {
        brandIconCacheLock.lock()
        defer { brandIconCacheLock.unlock() }
        if let cached = brandIconExistsCache[asset] { return cached }
        let exists = NSImage(named: asset) != nil
        brandIconExistsCache[asset] = exists
        return exists
    }

    /// Returns a brand-asset icon if the named asset exists, falling back to
    /// a colored SF Symbol otherwise. Assets render as template images so they
    /// adopt the foreground style automatically.
    ///
    /// - Parameters:
    ///   - asset: Asset-catalog name to try first.
    ///   - fallback: SF Symbol used when the asset is missing.
    ///   - color: Tint applied to both the asset and the fallback.
    @ViewBuilder
    private func brandIcon(_ asset: String, fallback: String, color: Color) -> some View {
        Group {
            if Self.brandIconExists(asset) {
                Image(asset)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(color)
            } else {
                Image(systemName: fallback)
                    .font(.system(size: DSFont.Size.md, weight: .medium))
                    .foregroundStyle(color)
            }
        }
        .frame(width: 22)
    }

    // MARK: - Masked inputs

    /// Twitch row status, with the channel masked for Streamer Mode.
    private var twitchStatus: Status {
        let channel = twitchChannel.map { StreamerMode.mask($0, style: .channel, isOn: streamerMode) }
        return Status.twitch(connected: twitchConnected, channel: channel, permissionPaused: permissionPaused)
    }

    /// Stream Widgets row status, with the link masked for Streamer Mode.
    private var widgetStatus: Status {
        let link = StreamerMode.mask(widgetURL, style: .url, isOn: streamerMode)
        return Status.widget(serverState: serverState, link: link, permissionPaused: permissionPaused)
    }
}

// MARK: - Status

extension IntegrationDashboardView {

    /// One row's chip (label, tint, glyph) and the line under the row name.
    ///
    /// Pure and `nonisolated` so every state is testable without rendering the
    /// view (same shape as `StreamDeckPaneStatus`). Each resolver reports the
    /// first thing in the user's way: missing Music permission, then the
    /// integration being off, then its connection state.
    nonisolated struct Status: Equatable {
        /// Short chip label, e.g. "Connected".
        let text: String
        /// Semantic `DSColor` tint for the chip.
        let color: Color
        /// SF Symbol name from `StatusChip.StateGlyph`.
        let symbol: String
        /// Plain-language detail shown under the row name.
        let subtitle: String

        // MARK: - Resolvers

        /// Twitch chat row.
        ///
        /// - Parameters:
        ///   - connected: Whether the chat bot is connected.
        ///   - channel: Channel login, already masked for Streamer Mode.
        ///   - permissionPaused: Music Automation permission is denied.
        static func twitch(connected: Bool, channel: String?, permissionPaused: Bool) -> Status {
            if permissionPaused { return paused("Will reply once Music permission is restored.") }
            guard connected else {
                // Not "sign in": a signed-in account can still be disconnected.
                return off("Disconnected", "Open Twitch settings to connect.")
            }
            let target = channel.map { "@\($0)" } ?? "your channel"
            return on("Connected", "Chat commands work in \(target).")
        }

        /// Discord profile row.
        ///
        /// - Parameters:
        ///   - enabled: The "Show on Discord" switch.
        ///   - state: Discord IPC connection lifecycle.
        ///   - permissionPaused: Music Automation permission is denied.
        static func discord(
            enabled: Bool,
            state: DiscordRPCService.ConnectionState,
            permissionPaused: Bool
        ) -> Status {
            if permissionPaused { return paused("Paused while Music permission is missing.") }
            guard enabled else {
                return off("Off", "Turn it on to share Apple Music on your Discord profile.")
            }
            switch state {
            case .connected:
                return on("Connected", "Your profile shows the song while music plays.")
            case .connecting:
                return starting("Connecting", "Looking for the Discord app.")
            case .disconnected:
                return off("Disconnected", "Open the Discord app, or check Discord settings.")
            }
        }

        /// Stream Widgets row.
        ///
        /// - Parameters:
        ///   - serverState: Lifecycle of the widget server.
        ///   - link: Browser-source link, already masked for Streamer Mode.
        ///   - permissionPaused: Music Automation permission is denied.
        static func widget(
            serverState: WebSocketServerService.ServerState,
            link: String,
            permissionPaused: Bool
        ) -> Status {
            if permissionPaused { return paused("Track updates are paused until Music permission is restored.") }
            switch serverState {
            case .listening:
                // "Running", not "Ready for OBS": the server can't see whether
                // a browser source ever loaded the page.
                return on("Running", "Add this to OBS as a browser source: \(link)")
            case .starting:
                return starting("Starting", "Starting the widget server.")
            case .error:
                return Status(
                    text: "Couldn't start",
                    color: DSColor.error,
                    symbol: StatusChip.StateGlyph.error,
                    subtitle: "The widget server couldn't start. Open Stream Widgets to see why."
                )
            case .stopped:
                return off("Off", "Turn on Stream Widgets to feed your overlay.")
            }
        }

        // MARK: - Private Helpers

        private static func on(_ text: String, _ subtitle: String) -> Status {
            Status(text: text, color: DSColor.success, symbol: StatusChip.StateGlyph.on, subtitle: subtitle)
        }

        private static func off(_ text: String, _ subtitle: String) -> Status {
            Status(text: text, color: DSColor.neutral, symbol: StatusChip.StateGlyph.off, subtitle: subtitle)
        }

        private static func starting(_ text: String, _ subtitle: String) -> Status {
            Status(text: text, color: DSColor.warning, symbol: StatusChip.StateGlyph.starting, subtitle: subtitle)
        }

        private static func paused(_ subtitle: String) -> Status {
            Status(text: "Paused", color: DSColor.warning, symbol: StatusChip.StateGlyph.paused, subtitle: subtitle)
        }
    }
}

#Preview("Connected") {
    IntegrationDashboardView(
        twitchConnected: true,
        twitchChannel: "nightowlstream",
        discordEnabled: true,
        discordState: .connected,
        serverState: .listening,
        widgetURL: "http://localhost:8766"
    )
    .padding()
    .frame(width: 720)
    .background(Color(nsColor: .underPageBackgroundColor))
}

#Preview("Off and failing") {
    IntegrationDashboardView(
        twitchConnected: false,
        discordEnabled: true,
        discordState: .connecting,
        serverState: .error,
        widgetURL: "http://localhost:8766"
    )
    .padding()
    .frame(width: 720)
    .background(Color(nsColor: .underPageBackgroundColor))
}
