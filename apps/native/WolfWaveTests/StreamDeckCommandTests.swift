//
//  StreamDeckCommandTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-07-18.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
@testable import WolfWave

// MARK: - StreamDeckControl.parse

/// `StreamDeckControl.parse` envelope decoding (type, protocol version and action
/// gating, args) and the `CommandAck` JSON shape. Must stay in step with the TypeScript mirror in
/// `apps/streamdeck/src/wolfwave/`.
struct StreamDeckCommandTests {

    /// A command envelope as JSON, at the current protocol version unless overridden.
    private func frame(_ action: String, protocolVersion: Int = StreamDeckControl.protocolVersion) -> String {
        #"{"type":"command","action":"\#(action)","protocol":\#(protocolVersion)}"#
    }

    @Test func validCommandParses() {
        let result = StreamDeckControl.parse(frame("skip"))
        #expect(result == .command(StreamDeckCommand(action: .skip, args: [:])))
    }

    @Test func everyActionRoundTrips() {
        for action in StreamDeckAction.allCases {
            let result = StreamDeckControl.parse(frame(action.rawValue))
            #expect(result == .command(StreamDeckCommand(action: action, args: [:])))
        }
    }

    @Test func argsAreParsed() {
        let version = StreamDeckControl.protocolVersion
        let text = #"{"type":"command","action":"skip","protocol":\#(version),"args":{"reason":"boring"}}"#
        let result = StreamDeckControl.parse(text)
        #expect(result == .command(StreamDeckCommand(action: .skip, args: ["reason": "boring"])))
    }

    @Test func unknownActionRejected() {
        let result = StreamDeckControl.parse(frame("teleport"))
        #expect(result == .reject(.failure("teleport", "unknown_action")))
    }

    @Test func protocolMismatchRejectedBeforeAction() {
        // Even an unknown action returns a protocol error first, so an out-of-date
        // plugin gets the clearest "update me" signal.
        let result = StreamDeckControl.parse(frame("teleport", protocolVersion: 99))
        #expect(result == .reject(.failure("teleport", "protocol")))
    }

    @Test func missingProtocolRejected() {
        let result = StreamDeckControl.parse(#"{"type":"command","action":"skip"}"#)
        #expect(result == .reject(.failure("skip", "protocol")))
    }

    @Test func nonCommandTypeIgnored() {
        #expect(StreamDeckControl.parse(#"{"type":"hello"}"#) == .ignore)
    }

    @Test func malformedJSONIgnored() {
        #expect(StreamDeckControl.parse("not json") == .ignore)
        #expect(StreamDeckControl.parse("") == .ignore)
    }

    // MARK: - CommandAck JSON shape

    @Test func successAckOmitsError() {
        let obj = CommandAck.success(.skip).jsonObject
        #expect(obj["type"] as? String == "ack")
        #expect(obj["action"] as? String == "skip")
        #expect(obj["ok"] as? Bool == true)
        #expect(obj["error"] == nil)
    }

    @Test func failureAckCarriesError() {
        let obj = CommandAck.failure("skip", "music").jsonObject
        #expect(obj["ok"] as? Bool == false)
        #expect(obj["error"] as? String == "music")
    }
}
