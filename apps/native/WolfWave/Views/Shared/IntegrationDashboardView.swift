//
//  IntegrationDashboardView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-07.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Compact dashboard listing every place WolfWave is broadcasting right now.
/// Each row: brand glyph · plain-language status · chip · "Configure ›".
///
/// Rendered by `MusicMonitorSettingsView` on the General pane. The view is
/// stateless about the integrations: the host passes in each one's current
/// state, and "Configure ›" routes back through `configure`.
struct IntegrationDashboardView: View {

    /// Streamer Mode masks the Twitch channel and widget URL in the subtitles.
    @AppStorage(AppConstants.UserDefaults.streamerModeEnabled)
    private var streamerMode = false

    // MARK: - Inputs

    /// Whether the Twitch chat bot is connected.
    var twitchConnected: Bool
    /// Channel login shown as `@channel`; masked under Streamer Mode.
    var twitchChannel: String?
    /// Live viewer count; omitted from the subtitle when `nil` or zero.
    var twitchViewerCount: Int?
    /// Whether Discord Rich Presence is connected.
    var discordConnected: Bool
    /// Whether the widget HTTP server is up.
    var widgetRunning: Bool
    /// Browser-source URL for OBS. Falls back to a bare localhost string when
    /// `nil`; masked under Streamer Mode.
    var widgetURL: String?
    /// Whether the remote-site row reads On.
    var remoteSendingEnabled: Bool
    /// Music Automation permission is denied. Twitch, Discord, and the widget
    /// rows switch to a Paused chip and explain why; the remote row does not.
    var permissionPaused: Bool = false

    /// Routes to a specific Settings section when "Configure ›" is tapped.
    var configure: (Section) -> Void = { _ in }

    /// The settings destination behind each row's "Configure ›" button.
    enum Section { case twitch, discord, obs, advanced }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s3) {
            HStack {
                Text("Integrations")
                    .sectionHeader()
                Spacer()
                Text("Where WolfWave is broadcasting right now.")
                    .font(.system(size: DSFont.Size.body))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                row(
                    icon: brandIcon("TwitchLogo", fallback: "bubble.left.fill", color: AppConstants.Brand.twitch),
                    name: "Twitch chat",
                    chip: twitchChip,
                    subtitle: twitchSubtitle,
                    action: { configure(.twitch) }
                )
                Divider().padding(.leading, DSSpace.s11)
                row(
                    icon: brandIcon("DiscordLogo", fallback: "headphones", color: AppConstants.Brand.discord),
                    name: "Discord profile",
                    chip: discordChip,
                    subtitle: discordSubtitle,
                    action: { configure(.discord) }
                )
                Divider().padding(.leading, DSSpace.s11)
                row(
                    icon: Image(systemName: "tv.badge.wifi")
                        .font(.system(size: DSFont.Size.md, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22),
                    name: "Stream Widgets",
                    chip: widgetChip,
                    subtitle: widgetSubtitle,
                    action: { configure(.obs) }
                )
                Divider().padding(.leading, DSSpace.s11)
                row(
                    icon: Image(systemName: "wifi")
                        .font(.system(size: DSFont.Size.md, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22),
                    name: "Send to a remote site (optional)",
                    chip: remoteSendingEnabled
                        ? StatusChip(text: "On", color: DSColor.success, systemImage: StatusChip.StateGlyph.on)
                        : StatusChip(text: "Off", color: DSColor.neutral, systemImage: StatusChip.StateGlyph.off),
                    subtitle: remoteSendingEnabled
                        ? "Sending now-playing to your remote URL."
                        : "Only turn this on if your overlay lives somewhere else.",
                    action: { configure(.advanced) }
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
    ///   - chip: Status chip showing connection state.
    ///   - subtitle: One-line description shown below the name.
    ///   - action: Closure invoked when the configure button is pressed.
    @ViewBuilder
    private func row<Icon: View>(
        icon: Icon,
        name: String,
        chip: StatusChip,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        let details = VStack(alignment: .leading, spacing: DSSpace.s0) {
            Text(name)
                .font(.system(size: DSFont.Size.base, weight: .medium))
            Text(subtitle)
                .font(.system(size: DSFont.Size.sm))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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

    // MARK: - Chips & subtitles

    /// Paused, Live, or Off for the Twitch row.
    private var twitchChip: StatusChip {
        if permissionPaused {
            return StatusChip(text: "Paused", color: DSColor.warning, systemImage: StatusChip.StateGlyph.paused)
        }
        return twitchConnected
            ? StatusChip(text: "Live", color: DSColor.success, systemImage: StatusChip.StateGlyph.on)
            : StatusChip(text: "Off", color: DSColor.neutral, systemImage: StatusChip.StateGlyph.off)
    }

    /// Twitch row detail: the pause reason, the (masked) channel plus viewer
    /// count when connected, or a sign-in prompt.
    private var twitchSubtitle: String {
        if permissionPaused { return "Will reply once Music permission is restored." }
        if twitchConnected {
            let displayName = twitchChannel.map {
                StreamerMode.mask($0, style: .channel, isOn: streamerMode)
            }
            let channel = displayName.map { "@\($0)" } ?? "your channel"
            if let n = twitchViewerCount, n > 0 {
                return "Connected to \(channel) · \(n) people watching"
            }
            return "Connected to \(channel)"
        }
        return "Sign in so !song works in chat."
    }

    /// Paused, Showing now, or Off for the Discord row.
    private var discordChip: StatusChip {
        if permissionPaused {
            return StatusChip(text: "Paused", color: DSColor.warning, systemImage: StatusChip.StateGlyph.paused)
        }
        return discordConnected
            ? StatusChip(text: "Showing now", color: DSColor.success, systemImage: StatusChip.StateGlyph.on)
            : StatusChip(text: "Off", color: DSColor.neutral, systemImage: StatusChip.StateGlyph.off)
    }

    /// Discord row detail for the paused, connected, and off states.
    private var discordSubtitle: String {
        if permissionPaused { return "Paused while Music permission is missing." }
        return discordConnected
            ? "Friends can see what you're playing."
            : "Turn it on to share Apple Music on your Discord profile."
    }

    /// Paused, Ready for OBS, or Off for the Stream Widgets row.
    private var widgetChip: StatusChip {
        if permissionPaused {
            return StatusChip(text: "Paused", color: DSColor.warning, systemImage: StatusChip.StateGlyph.paused)
        }
        return widgetRunning
            ? StatusChip(text: "Ready for OBS", color: DSColor.success, systemImage: StatusChip.StateGlyph.on)
            : StatusChip(text: "Off", color: DSColor.neutral, systemImage: StatusChip.StateGlyph.off)
    }

    /// Stream Widgets row detail: the pause note, the (masked) OBS URL while
    /// running, or a prompt to turn the server on.
    private var widgetSubtitle: String {
        if permissionPaused { return "Showing the last known track until permission is fixed." }
        if widgetRunning {
            let display = StreamerMode.mask(widgetURL ?? "http://localhost", style: .url, isOn: streamerMode)
            return "Drop this URL into OBS: \(display)"
        }
        return "Turn on the widget server to feed your overlay."
    }
}

#Preview {
    IntegrationDashboardView(
        twitchConnected: true,
        twitchChannel: "nightowlstream",
        twitchViewerCount: 12,
        discordConnected: true,
        widgetRunning: true,
        widgetURL: "http://localhost:8766",
        remoteSendingEnabled: false
    )
    .padding()
    .frame(width: 720)
    .background(Color(nsColor: .underPageBackgroundColor))
}
