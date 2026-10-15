//
//  StreamDeckCommand.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-07-18.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

// MARK: - StreamDeckAction

/// An action a Stream Deck key can trigger over the control WebSocket.
///
/// Raw values are the wire tokens the plugin sends in a command envelope, so
/// renaming a case is a protocol change (bump `StreamDeckControl.protocolVersion`).
///
/// Mirrored by `ACTIONS` in `apps/streamdeck/src/wolfwave/protocol.ts`: add,
/// rename, or remove a case on both sides in the same change. The command
/// router that runs each action is `AppDelegate+StreamDeck.swift`.
nonisolated enum StreamDeckAction: String, Codable, CaseIterable, Sendable {
    case playPause = "play_pause"
    case skip
    case holdQueue = "hold_queue"
    case resumeQueue = "resume_queue"
    case approveNext = "approve_next"
    case clearQueue = "clear_queue"
    case blockCurrent = "block_current"
    case overlayToggle = "overlay_toggle"
    case announceSong = "announce_song"
    case rejectCurrent = "reject_current"
    case blockRequester = "block_requester"
    case cycleAudience = "cycle_audience"
}

// MARK: - StreamDeckCommand

/// A decoded, validated inbound command ready to run.
///
/// Produced only by `StreamDeckControl.parse(_:)`, so `action` is always a
/// known token and the envelope's protocol version already matched.
nonisolated struct StreamDeckCommand: Sendable, Equatable {
    let action: StreamDeckAction
    /// Optional string args from the envelope (unused by the v3 actions; carried
    /// so a future action can take a parameter without a protocol bump).
    /// A missing or non-object `args` decodes as empty; within an object, each
    /// string entry is kept and any non-string entry is dropped on its own.
    let args: [String: String]
}

// MARK: - CommandAck

/// The reply sent back on the originating connection after a command is handled.
///
/// Decoded by `parseFrame` (`kind: "ack"`) in the plugin's `protocol.ts`, which
/// correlates it to the pending press by `action`.
nonisolated struct CommandAck: Sendable, Equatable {
    /// The action token echoed back. A `String`, not `StreamDeckAction`, so a
    /// rejection can echo an unknown or out-of-protocol token verbatim.
    let action: String
    /// `true` when the action ran.
    let ok: Bool
    /// Short machine-readable reason when `ok` is `false`, e.g. `"protocol"`,
    /// `"unknown_action"`, `"unauthorized"`, `"disabled"`, `"unavailable"`,
    /// `"empty"`, `"full"` (`approve_next` with the live request queue at its
    /// cap). The plugin keys its key states off these, so treat them as
    /// part of the wire contract. `nil` on success (and omitted from the JSON).
    let error: String?

    /// JSON object form for `WebSocketServerService.sendJSON`.
    var jsonObject: [String: Any] {
        var obj: [String: Any] = ["type": "ack", "action": action, "ok": ok]
        if let error { obj["error"] = error }
        return obj
    }

    /// An `ok: true` ack for a command that ran.
    static func success(_ action: StreamDeckAction) -> CommandAck {
        CommandAck(action: action.rawValue, ok: true, error: nil)
    }

    /// An `ok: false` ack.
    ///
    /// - Parameters:
    ///   - action: The token to echo, raw so unparseable actions can be echoed.
    ///   - error: The reason code (see ``error``).
    static func failure(_ action: String, _ error: String) -> CommandAck {
        CommandAck(action: action, ok: false, error: error)
    }
}

// MARK: - StreamDeckControl

/// Pure decode of inbound control frames. No I/O, no state, so it is trivially
/// unit-testable and safe to call from the nonisolated Network.framework
/// receive callback.
nonisolated enum StreamDeckControl {

    /// Command protocol version. Bump on any breaking envelope change so an
    /// out-of-date plugin can detect the mismatch (ack `error:"protocol"`) and
    /// prompt for an update instead of silently misbehaving.
    /// v3 dropped `discord_toggle`, `music_sync_toggle`, and `cycle_theme`:
    /// set-once preferences that never earned a key on a deck where slots are
    /// the scarce resource.
    /// Must equal `PROTOCOL_VERSION` in the plugin's `protocol.ts`.
    static let protocolVersion = 3

    /// Outcome of decoding one inbound WebSocket text frame.
    enum InboundFrame: Equatable {
        /// A valid command to run; reply with the handler's ack.
        case command(StreamDeckCommand)
        /// A command frame we understood but refused; send this ack, don't run.
        case reject(CommandAck)
        /// Not a command frame (or unparseable) — do nothing, don't ack.
        case ignore
    }

    /// Decodes a raw text frame.
    ///
    /// Gates in order so an out-of-date plugin gets the clearest signal:
    /// 1. `type == "command"` (anything else → `.ignore`, no ack noise)
    /// 2. `protocol == protocolVersion` (mismatch → `.reject` `"protocol"`)
    /// 3. a known `action` (unknown → `.reject` `"unknown_action"`)
    ///
    /// Authorization is not checked here: the caller decides whether the
    /// connection may run commands before acting on a `.command` result.
    static func parse(_ text: String) -> InboundFrame {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "command" else {
            return .ignore
        }

        let actionToken = (obj["action"] as? String) ?? ""

        guard (obj["protocol"] as? Int) == protocolVersion else {
            return .reject(.failure(actionToken, "protocol"))
        }
        guard let action = StreamDeckAction(rawValue: actionToken) else {
            return .reject(.failure(actionToken, "unknown_action"))
        }

        // Keep each string entry; a non-string value drops only that key.
        let rawArgs = (obj["args"] as? [String: Any]) ?? [:]
        let args = rawArgs.compactMapValues { $0 as? String }
        return .command(StreamDeckCommand(action: action, args: args))
    }
}
