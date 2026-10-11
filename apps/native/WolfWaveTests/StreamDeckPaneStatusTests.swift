//
//  StreamDeckPaneStatusTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-08-19.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI
import Testing

@testable import WolfWave

/// Pins the Stream Deck header chip's precedence rule.
///
/// The pane has two switches and a live server state but the chip has one slot,
/// so the ordering is the whole behavior: server switch, then server failure,
/// then server still starting, then the command switch, then Ready. Ready is
/// only ever reported for a server that is actually listening.
/// Touches no process-wide state, so it needs no shared-state isolation.
@Suite("Stream Deck Pane Status")
struct StreamDeckPaneStatusTests {

    @Test("Server off outranks the command switch")
    func serverOffWinsOverCommandsOn() {
        let status = StreamDeckPaneStatus.resolve(
            controlEnabled: true, serverEnabled: false, serverState: .stopped)

        #expect(status.text == "Server off")
        #expect(status.color == DSColor.neutral)
        #expect(status.symbol == StatusChip.StateGlyph.off)
    }

    @Test("Server off reports the server, not the commands, when both are off")
    func serverOffWinsOverCommandsOff() {
        let status = StreamDeckPaneStatus.resolve(
            controlEnabled: false, serverEnabled: false, serverState: .stopped)

        #expect(status.text == "Server off")
        #expect(status.color == DSColor.neutral)
    }

    @Test("A stale error state is ignored while the server switch is off")
    func serverOffIgnoresStaleError() {
        let status = StreamDeckPaneStatus.resolve(
            controlEnabled: true, serverEnabled: false, serverState: .error)

        #expect(status.text == "Server off")
    }

    @Test("Commands off is reported only once the server is listening")
    func commandsOff() {
        let status = StreamDeckPaneStatus.resolve(
            controlEnabled: false, serverEnabled: true, serverState: .listening)

        #expect(status.text == "Commands off")
        #expect(status.color == DSColor.warning)
        #expect(status.symbol == StatusChip.StateGlyph.starting)
    }

    @Test("Listening with commands on reads Ready")
    func ready() {
        let status = StreamDeckPaneStatus.resolve(
            controlEnabled: true, serverEnabled: true, serverState: .listening)

        #expect(status.text == "Ready")
        #expect(status.color == DSColor.success)
        #expect(status.symbol == StatusChip.StateGlyph.on)
    }

    @Test("Ready only when the server is listening")
    func readyOnlyWhenListening() {
        let states: [WebSocketServerService.ServerState] = [.stopped, .starting, .listening, .error]
        let ready = states.filter {
            StreamDeckPaneStatus.resolve(
                controlEnabled: true, serverEnabled: true, serverState: $0
            ).text == "Ready"
        }

        #expect(ready == [.listening])
    }

    @Test("A server error shows Server error in the error color, even with commands off")
    func errorStateShowsServerError() {
        for controlEnabled in [true, false] {
            let status = StreamDeckPaneStatus.resolve(
                controlEnabled: controlEnabled, serverEnabled: true, serverState: .error)

            #expect(status.text == "Server error")
            #expect(status.color == DSColor.error)
            #expect(status.symbol == StatusChip.StateGlyph.error)
        }
    }

    @Test("A starting server shows Starting rather than Ready")
    func startingStateShowsStarting() {
        let status = StreamDeckPaneStatus.resolve(
            controlEnabled: true, serverEnabled: true, serverState: .starting)

        #expect(status.text == "Starting")
        #expect(status.color == DSColor.warning)
        #expect(status.symbol == StatusChip.StateGlyph.starting)
    }

    @Test("Switch on but server stopped reads Starting, never Ready")
    func stoppedWhileEnabledIsNotReady() {
        let status = StreamDeckPaneStatus.resolve(
            controlEnabled: true, serverEnabled: true, serverState: .stopped)

        #expect(status.text == "Starting")
    }

    @Test("Off, error, and ready carry distinct glyphs so the chip reads without color")
    func glyphsAreDistinct() {
        let symbols = [
            StreamDeckPaneStatus.resolve(
                controlEnabled: true, serverEnabled: false, serverState: .stopped).symbol,
            StreamDeckPaneStatus.resolve(
                controlEnabled: true, serverEnabled: true, serverState: .error).symbol,
            StreamDeckPaneStatus.resolve(
                controlEnabled: true, serverEnabled: true, serverState: .listening).symbol
        ]

        #expect(Set(symbols).count == symbols.count)
    }
}
