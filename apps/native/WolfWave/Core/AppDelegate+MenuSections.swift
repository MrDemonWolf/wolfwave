//
//  AppDelegate+MenuSections.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit

/// Tray menu section builders: song requests, service toggles, streamer
/// quick actions, and the Settings / Help / About / Quit items. Called in
/// on-screen order from `menuNeedsUpdate(_:)`.
extension AppDelegate {

    // MARK: - Song Requests

    /// Adds the song-request section when the feature is on and the service exists.
    ///
    /// Hold/Resume always shows at the top level. The rest is either flat
    /// (now-playing request, queue count, actions) or folded into a
    /// "Song Requests (N)" submenu once
    /// `MenuStatusFormatter.shouldCollapseSongRequests` says the queue is busy.
    /// Skip and Clear appear only when there is something to act on.
    func buildSongRequestSection(into menu: NSMenu) {
        guard FeatureFlags.songRequestEnabled,
              let srQueue = songRequestService?.queue else { return }

        let queueCount = srQueue.count
        let nowPlaying = srQueue.nowPlaying
        let hasNowPlaying = nowPlaying != nil
        let holdEnabled = songRequestService?.isHoldEnabled ?? false

        // Hold/Resume is the live-streamer button, always promoted to the
        // top level, even when the rest of the section is collapsed.
        let holdItem = NSMenuItem(
            title: holdEnabled ? "Resume Song Requests" : "Hold Song Requests",
            action: #selector(toggleSongRequestHold),
            keyEquivalent: ""
        )
        holdItem.image = NSImage(
            systemSymbolName: holdEnabled ? "play.circle" : "pause.circle",
            accessibilityDescription: holdEnabled ? "Resume" : "Hold"
        )
        menu.addItem(holdItem)

        let collapse = MenuStatusFormatter.shouldCollapseSongRequests(
            queueCount: queueCount,
            hasNowPlaying: hasNowPlaying
        )

        if collapse {
            let parentTitle = "Song Requests (\(queueCount))"
            let parent = NSMenuItem(title: parentTitle, action: nil, keyEquivalent: "")
            parent.image = NSImage(
                systemSymbolName: "music.note.list",
                accessibilityDescription: "Song Requests"
            )
            parent.submenu = buildSongRequestSubmenu(
                nowPlaying: nowPlaying,
                queueCount: queueCount
            )
            menu.addItem(parent)
        } else {
            if let nowPlaying {
                let requestLabel = "\(nowPlaying.title) · \(nowPlaying.artist)"
                let requestItem = NSMenuItem(
                    title: MenuTitleFormatting.clamped(requestLabel),
                    action: nil,
                    keyEquivalent: ""
                )
                requestItem.toolTip = MenuTitleFormatting.tooltip(for: requestLabel)
                requestItem.isEnabled = false
                menu.addItem(requestItem)
            }
            if queueCount > 0 {
                let queueLabel = NSMenuItem(
                    title: "\(queueCount) song\(queueCount == 1 ? "" : "s") in queue",
                    action: nil,
                    keyEquivalent: ""
                )
                queueLabel.isEnabled = false
                menu.addItem(queueLabel)
            }
            if hasNowPlaying || queueCount > 0 {
                addSongRequestActions(into: menu)
            }
        }

        menu.addItem(.separator())
    }

    /// Builds the collapsed "Song Requests (N)" submenu: the playing request,
    /// the queue count, then the Skip and Clear actions.
    private func buildSongRequestSubmenu(
        nowPlaying: SongRequestItem?,
        queueCount: Int
    ) -> NSMenu {
        let submenu = NSMenu()
        if let nowPlaying {
            let nowLabel = "Now: \(nowPlaying.title) · \(nowPlaying.artist)"
            let nowItem = NSMenuItem(
                title: MenuTitleFormatting.clamped(nowLabel),
                action: nil,
                keyEquivalent: ""
            )
            nowItem.toolTip = MenuTitleFormatting.tooltip(for: nowLabel)
            nowItem.isEnabled = false
            submenu.addItem(nowItem)
        }
        if queueCount > 0 {
            let queueLabel = NSMenuItem(
                title: "\(queueCount) song\(queueCount == 1 ? "" : "s") in queue",
                action: nil,
                keyEquivalent: ""
            )
            queueLabel.isEnabled = false
            submenu.addItem(queueLabel)
        }
        submenu.addItem(.separator())
        addSongRequestActions(into: submenu)
        return submenu
    }

    /// Appends Skip Song Request and Clear Queue to `menu`, split by a separator.
    private func addSongRequestActions(into menu: NSMenu) {
        let skipItem = NSMenuItem(
            title: "Skip Song Request",
            action: #selector(skipSongRequest),
            keyEquivalent: ""
        )
        skipItem.image = NSImage(
            systemSymbolName: "forward.fill",
            accessibilityDescription: "Skip"
        )
        menu.addItem(skipItem)

        // Destructive: keep it apart from Skip so a slip doesn't wipe the queue.
        menu.addItem(.separator())

        let clearItem = NSMenuItem(
            title: "Clear Queue\u{2026}",
            action: #selector(clearSongRequestQueue),
            keyEquivalent: ""
        )
        clearItem.image = NSImage(
            systemSymbolName: "trash",
            accessibilityDescription: "Clear Queue"
        )
        menu.addItem(clearItem)
    }

    // MARK: - Service Toggles

    /// Adds one status row per integration: Apple Music, Twitch, Discord, and
    /// OBS Overlay.
    ///
    /// The Twitch row appears only when `twitchMenuState` says a credential is
    /// stored, and its channel name goes through Streamer Mode masking. A row's
    /// checkmark tracks the user's toggle except Twitch, where it tracks the
    /// live connection.
    func buildServiceToggles(into menu: NSMenu) {
        let trackingOn = FeatureFlags.trackingEnabled
        let trackingItem = makeStatusItem(
            title: "Apple Music",
            status: MenuStatusFormatter.musicStatus(trackingEnabled: trackingOn),
            action: #selector(toggleTracking),
            on: trackingOn,
            image: menuItemIcon(named: "AppleMusicLogo")
        )
        menu.addItem(trackingItem)

        if twitchMenuState.hasCredential {
            let connected = twitchService?.currentlyConnected ?? false
            let channel = twitchMenuState.channelName.map {
                StreamerMode.mask($0, style: .channel, isOn: StreamerMode.isEnabled)
            }
            let twitchItem = makeStatusItem(
                title: "Twitch",
                status: MenuStatusFormatter.twitchStatus(isConnected: connected, channelName: channel),
                action: #selector(toggleTwitchConnection),
                on: connected,
                image: menuItemIcon(named: "TwitchLogo")
            )
            menu.addItem(twitchItem)
        }

        let discordEnabled = FeatureFlags.discordEnabled
        let discordState: MenuStatusFormatter.DiscordState = {
            switch discordService?.stateSnapshot {
            case .connected: return .connected
            case .connecting: return .connecting
            case .disconnected, .none: return .disconnected
            }
        }()
        let discordItem = makeStatusItem(
            title: "Discord",
            status: MenuStatusFormatter.discordStatus(enabled: discordEnabled, state: discordState),
            action: #selector(toggleDiscordPresence),
            on: discordEnabled,
            image: menuItemIcon(named: "DiscordLogo")
        )
        menu.addItem(discordItem)

        let widgetsEnabled = FeatureFlags.websocketEnabled
        let widgetPort = Preferences.resolvedWidgetPort
        let clientCount = websocketServer?.connectedClientCount ?? 0
        let overlayItem = makeStatusItem(
            title: "OBS Overlay",
            status: MenuStatusFormatter.widgetsStatus(
                enabled: widgetsEnabled,
                widgetPort: widgetPort,
                clientCount: clientCount
            ),
            action: #selector(toggleWebSocket),
            on: widgetsEnabled,
            image: menuItemIcon(named: "OBSLogo")
        )
        menu.addItem(overlayItem)

        menu.addItem(.separator())
    }

    // MARK: - Streamer Quick Actions

    /// Adds the Streamer Mode toggle, the widget link actions (only while the
    /// overlay is on), and Restart Integrations.
    func buildStreamerActions(into menu: NSMenu) {
        let streamerModeOn = StreamerMode.isEnabled
        let streamerModeItem = NSMenuItem(
            title: "Streamer Mode",
            action: #selector(toggleStreamerMode),
            keyEquivalent: ""
        )
        streamerModeItem.state = streamerModeOn ? .on : .off
        streamerModeItem.image = NSImage(
            systemSymbolName: streamerModeOn ? "eye.slash.fill" : "eye.slash",
            accessibilityDescription: "Streamer Mode"
        )
        streamerModeItem.toolTip = "Hide channel name, overlay URL, and other sensitive details from the WolfWave UI while you're on stream."
        menu.addItem(streamerModeItem)

        let widgetsEnabled = FeatureFlags.websocketEnabled
        if widgetsEnabled {
            let copyItem = NSMenuItem(
                title: "Copy Widget Link",
                action: #selector(copyWidgetURL),
                keyEquivalent: ""
            )
            copyItem.image = NSImage(
                systemSymbolName: "link",
                accessibilityDescription: "Copy Widget Link"
            )
            menu.addItem(copyItem)

            let openItem = NSMenuItem(
                title: "Open Widget in Browser",
                action: #selector(openWidgetInBrowser),
                keyEquivalent: ""
            )
            openItem.image = NSImage(
                systemSymbolName: "safari",
                accessibilityDescription: "Open Widget in Browser"
            )
            menu.addItem(openItem)
        }

        let reconnectItem = NSMenuItem(
            title: "Restart Integrations\u{2026}",
            action: #selector(reconnectAllServices),
            keyEquivalent: ""
        )
        reconnectItem.image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "Restart Integrations"
        )
        menu.addItem(reconnectItem)

        menu.addItem(.separator())
    }

    // MARK: - App Items (Settings · Help ▸ · About · Quit)

    /// Adds Settings (Cmd-comma), the Help submenu, About, and Quit (Cmd-Q).
    func buildAppItems(into menu: NSMenu) {
        let settingsItem = NSMenuItem(
            title: AppConstants.MenuLabels.settings,
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: "Settings"
        )
        menu.addItem(settingsItem)

        let helpParent = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        helpParent.image = NSImage(
            systemSymbolName: "questionmark.circle",
            accessibilityDescription: "Help"
        )
        helpParent.submenu = buildHelpSubmenu()
        menu.addItem(helpParent)

        let aboutItem = NSMenuItem(
            title: "About \(appName)",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.image = NSImage(
            systemSymbolName: "info.circle",
            accessibilityDescription: "About"
        )
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: AppConstants.MenuLabels.quit,
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.image = NSImage(
            systemSymbolName: "power",
            accessibilityDescription: "Quit"
        )
        menu.addItem(quitItem)
    }

    /// Builds the Help submenu: What's New, Check for Updates, docs and
    /// community links, bug report, GitHub, and the optional Sponsor link.
    private func buildHelpSubmenu() -> NSMenu {
        let submenu = NSMenu()

        let whatsNew = NSMenuItem(
            title: "What's New",
            action: #selector(showWhatsNewFromMenu),
            keyEquivalent: ""
        )
        whatsNew.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        submenu.addItem(whatsNew)

        // Homebrew installs are gated inside the updater: the action falls
        // back to the Releases page when Sparkle is unavailable.
        let updates = NSMenuItem(
            title: "Check for Updates\u{2026}",
            action: #selector(checkForUpdatesFromMenu),
            keyEquivalent: ""
        )
        updates.image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: nil
        )
        submenu.addItem(updates)

        submenu.addItem(.separator())

        let docs = NSMenuItem(
            title: "Documentation",
            action: #selector(openDocs),
            keyEquivalent: ""
        )
        docs.image = NSImage(systemSymbolName: "book", accessibilityDescription: nil)
        submenu.addItem(docs)

        let community = NSMenuItem(
            title: "Community Discord",
            action: #selector(openCommunityDiscord),
            keyEquivalent: ""
        )
        community.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil)
        submenu.addItem(community)

        submenu.addItem(.separator())

        let bug = NSMenuItem(
            title: "Report a Bug",
            action: #selector(reportBug),
            keyEquivalent: ""
        )
        bug.image = NSImage(systemSymbolName: "ant", accessibilityDescription: nil)
        submenu.addItem(bug)

        let github = NSMenuItem(
            title: "Star on GitHub",
            action: #selector(openGitHub),
            keyEquivalent: ""
        )
        github.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        submenu.addItem(github)

        // Opt-out lives in the About pane. The menu is rebuilt on every open
        // (NSMenuDelegate), so flipping the toggle takes effect immediately.
        if FeatureFlags.sponsorLinksEnabled {
            let sponsor = NSMenuItem(
                title: "Sponsor \(appName)",
                action: #selector(openSponsorPage),
                keyEquivalent: ""
            )
            sponsor.image = NSImage(systemSymbolName: "heart", accessibilityDescription: nil)
            submenu.addItem(sponsor)
        }

        return submenu
    }
}
