//
//  IntegrationDashboardViewTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-11-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Testing
@testable import WolfWave

/// The General dashboard reports connections, not what an audience can see.
/// These pin the precedence (Music permission, then the switch, then the
/// connection) and keep the copy from claiming more than WolfWave knows.
@Suite("Integration dashboard status")
struct IntegrationDashboardViewTests {
    private typealias Status = IntegrationDashboardView.Status

    // MARK: - Twitch

    @Test("Twitch names the channel when connected and never says sign in when not")
    func twitch() {
        let connected = Status.twitch(connected: true, channel: "nightowlstream", permissionPaused: false)
        #expect(connected.text == "Connected")
        #expect(connected.subtitle.contains("@nightowlstream"))

        let noChannel = Status.twitch(connected: true, channel: nil, permissionPaused: false)
        #expect(noChannel.subtitle.contains("your channel"))

        let disconnected = Status.twitch(connected: false, channel: "nightowlstream", permissionPaused: false)
        #expect(disconnected.text == "Disconnected")
        #expect(!disconnected.subtitle.localizedCaseInsensitiveContains("sign in"))
    }

    // MARK: - Discord

    @Test("Discord: the switch outranks the connection state")
    func discordSwitchOff() {
        for state in [DiscordRPCService.ConnectionState.connected, .connecting, .disconnected] {
            #expect(Status.discord(enabled: false, state: state, permissionPaused: false).text == "Off")
        }
    }

    @Test(
        "Discord: each connection state has its own chip",
        arguments: [
            (DiscordRPCService.ConnectionState.connected, "Connected"),
            (.connecting, "Connecting"),
            (.disconnected, "Disconnected"),
        ]
    )
    func discordStates(state: DiscordRPCService.ConnectionState, text: String) {
        #expect(Status.discord(enabled: true, state: state, permissionPaused: false).text == text)
    }

    // MARK: - Stream Widgets

    @Test(
        "Stream Widgets: each server state has its own chip",
        arguments: [
            (WebSocketServerService.ServerState.listening, "Running"),
            (.starting, "Starting"),
            (.error, "Couldn't start"),
            (.stopped, "Off"),
        ]
    )
    func widgetStates(state: WebSocketServerService.ServerState, text: String) {
        #expect(Status.widget(serverState: state, link: "http://localhost:8766", permissionPaused: false).text == text)
    }

    @Test("Stream Widgets: the link shows only while the server is listening")
    func widgetLink() {
        let link = "http://localhost:8766"
        #expect(Status.widget(serverState: .listening, link: link, permissionPaused: false).subtitle.contains(link))
        for state in [WebSocketServerService.ServerState.starting, .error, .stopped] {
            #expect(!Status.widget(serverState: state, link: link, permissionPaused: false).subtitle.contains(link))
        }
    }

    @Test("A listening server never claims OBS loaded the widget")
    func widgetDoesNotClaimOBS() {
        let status = Status.widget(serverState: .listening, link: "http://localhost:8766", permissionPaused: false)
        #expect(!status.text.localizedCaseInsensitiveContains("OBS"))
        #expect(!status.text.localizedCaseInsensitiveContains("connected"))
    }

    // MARK: - Music permission

    @Test("Missing Music permission pauses every row, whatever its state")
    func permissionPausesEverything() {
        let rows = [
            Status.twitch(connected: true, channel: "nightowlstream", permissionPaused: true),
            Status.discord(enabled: true, state: .connected, permissionPaused: true),
            Status.discord(enabled: false, state: .disconnected, permissionPaused: true),
            Status.widget(serverState: .error, link: "http://localhost:8766", permissionPaused: true),
        ]
        for row in rows {
            #expect(row.text == "Paused")
            #expect(row.symbol == StatusChip.StateGlyph.paused)
        }
    }
}
