//
//  RemoveSongCommand.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-11-23.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Handles `!removesong`: removes one song by queue position (`!removesong 3`
/// or `!removesong #3`) or every waiting request from one viewer
/// (`!removesong @name`). The song playing now is left alone; `!skip` is for that.
///
/// Restricted to moderators and the broadcaster. Silent while Song Requests
/// is off (``SongRequestGatedCommand``).
final class RemoveSongCommand: ServiceBoundCommand, SongRequestGatedCommand {
    // MARK: - BotCommand

    /// Chat triggers that invoke this command.
    var triggers: [String] { ["!removesong"] }

    /// Human-readable description (informational; no chat command lists it).
    var description: String { "Remove a song request by position or viewer (mod/broadcaster only)" }

    /// Channel-wide cooldown between invocations, in seconds.
    var globalCooldown: TimeInterval { 2.0 }

    /// Per-user cooldown between invocations, in seconds.
    var userCooldown: TimeInterval { 2.0 }

    /// UserDefaults key controlling whether the command is enabled.
    var enabledKey: String? { AppConstants.UserDefaults.removeSongCommandEnabled }

    /// UserDefaults key holding custom trigger aliases.
    var aliasesKey: String? { AppConstants.UserDefaults.removeSongCommandAliases }

    // MARK: - Properties

    /// Provides the active `SongRequestService`. Late-bound to break the
    /// AppDelegate ↔ command dependency cycle at startup.
    var songRequestService: (() -> SongRequestService?)?

    // MARK: - AsyncBotCommand

    /// Removes the targeted requests.
    ///
    /// Non-privileged callers are already refused by `isAllowed(context:)`;
    /// the guard here is defense in depth.
    ///
    /// - Parameters:
    ///   - message: Raw chat message, for example `!removesong 3` or `!removesong @name`.
    ///   - context: Sender context; must be mod or broadcaster.
    /// - Returns: The chat reply, or nil when unauthorized.
    func execute(message: String, context: BotCommandContext) async -> String? {
        guard !Task.isCancelled else { return nil }
        guard let service = requirePrivilegedService(context: context) else { return nil }
        guard let target = Self.target(from: message) else { return Self.usage }
        return Self.reply(for: target, removed: service.removeRequests(target))
    }

    // MARK: - Parsing

    /// Reply for a missing or unreadable target.
    static let usage = "Usage: !removesong <position> or !removesong @viewer"

    /// Reads the target after the trigger: a number (with or without `#`) is a
    /// position, anything else is a Twitch login (a leading `@` is dropped).
    ///
    /// - Parameter message: The full chat message.
    /// - Returns: The target, or `nil` when there isn't one.
    static func target(from message: String) -> SongRequestService.RemoveTarget? {
        let parts = message.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2 else { return nil }
        var raw = String(parts[1])
        if raw.hasPrefix("#") { raw.removeFirst() }
        if let position = Int(raw) { return position >= 1 ? .position(position) : nil }
        if raw.hasPrefix("@") { raw.removeFirst() }
        guard !raw.isEmpty else { return nil }
        return .requester(raw.lowercased())
    }

    // MARK: - Reply Formatting

    /// Chat reply for a removal. Pure so tests can pin it.
    static func reply(
        for target: SongRequestService.RemoveTarget,
        removed: [SongRequestItem]
    ) -> String {
        switch (target, removed.count) {
        case (.position(let position), 0):
            return "There's no song at #\(position)."
        case (.requester(let login), 0):
            return "\(login) has no songs waiting."
        case (_, 1):
            let item = removed[0]
            return "Removed \"\(item.title)\" (requested by \(item.requesterUsername))."
        case (.requester(let login), let count):
            return "Removed \(count) songs from \(login)."
        case (.position, let count):
            return "Removed \(count) songs."
        }
    }
}
