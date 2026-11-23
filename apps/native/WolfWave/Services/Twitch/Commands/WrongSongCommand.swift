//
//  WrongSongCommand.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-11-23.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Handles `!wrongsong`: removes the viewer's most recent request
/// that hasn't started playing, so a wrong search match can be fixed.
///
/// Any viewer may use it, on their own requests only. Silent while Song
/// Requests is off (``SongRequestGatedCommand``).
final class WrongSongCommand: AsyncBotCommand, SongRequestGatedCommand {
    // MARK: - BotCommand

    /// Chat triggers that invoke this command.
    var triggers: [String] { ["!wrongsong"] }

    /// Human-readable description (informational; no chat command lists it).
    var description: String { "Remove your latest song request" }

    /// Channel-wide cooldown between invocations, in seconds.
    var globalCooldown: TimeInterval { 2.0 }

    /// Per-user cooldown between invocations, in seconds.
    var userCooldown: TimeInterval { 10.0 }

    /// UserDefaults key controlling whether the command is enabled.
    var enabledKey: String? { AppConstants.UserDefaults.wrongSongCommandEnabled }

    /// UserDefaults key holding custom trigger aliases.
    var aliasesKey: String? { AppConstants.UserDefaults.wrongSongCommandAliases }

    // MARK: - Properties

    /// Provides the live `SongRequestService`. Late-bound to break the
    /// AppDelegate ↔ command dependency cycle at startup.
    var songRequestService: (() -> SongRequestService?)?

    // MARK: - AsyncBotCommand

    /// Removes the sender's latest waiting request.
    ///
    /// - Parameters:
    ///   - message: Raw chat message (unused).
    ///   - context: Sender context; `requesterLogin` is the identity `!sr` stores.
    /// - Returns: The chat reply, or nil when song requests are unavailable.
    func execute(message: String, context: BotCommandContext) async -> String? {
        guard !Task.isCancelled, let service = songRequestService?() else { return nil }
        return Self.reply(for: service.undoLatestRequest(requesterLogin: context.requesterLogin))
    }

    // MARK: - Reply Formatting

    /// Chat reply for an undo outcome. Pure so tests can pin it.
    static func reply(for outcome: SongRequestService.UndoOutcome) -> String {
        switch outcome {
        case .removed(let item):
            return "Removed \"\(item.title)\". Try again with the artist and title, or paste an Apple Music link."
        case .paidRequest(let item):
            return "\"\(item.title)\" was a channel-point request, so it stays. Ask a mod to remove it."
        case .nothingToUndo:
            return "You don't have a request waiting to undo."
        }
    }
}
