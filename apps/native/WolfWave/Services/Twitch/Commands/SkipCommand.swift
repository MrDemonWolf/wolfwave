//
//  SkipCommand.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-04-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Handles `!skip` / `!next`. Skips the current song request.
///
/// Restricted to moderators and the broadcaster. Replies with the next track,
/// a queue-empty notice, or a "try again" when nothing could be skipped.
final class SkipCommand: ServiceBoundCommand {
    // MARK: - BotCommand

    /// Chat triggers that invoke this command.
    var triggers: [String] { ["!skip", "!next"] }

    /// Human-readable description shown in the `!commands` listing.
    var description: String { "Skip the current song request (mod/broadcaster only)" }

    /// Channel-wide cooldown between invocations, in seconds.
    var globalCooldown: TimeInterval { 3.0 }

    /// Per-user cooldown between invocations, in seconds.
    var userCooldown: TimeInterval { 3.0 }

    /// UserDefaults key controlling whether the command is enabled.
    var enabledKey: String? { AppConstants.UserDefaults.skipCommandEnabled }

    /// UserDefaults key holding custom trigger aliases.
    var aliasesKey: String? { AppConstants.UserDefaults.skipCommandAliases }

    // MARK: - Properties

    /// Provides the active `SongRequestService`. Late-bound to break the
    /// AppDelegate ↔ command dependency cycle at startup.
    var songRequestService: (() -> SongRequestService?)?

    // MARK: - AsyncBotCommand

    /// Executes the skip action against the live song request service.
    ///
    /// - Parameters:
    ///   - message: Raw chat message (unused).
    ///   - context: Sender context; must be mod or broadcaster.
    ///   - Returns: The eventual chat response, or nil when unauthorized.
    func execute(message: String, context: BotCommandContext) async -> String? {
        guard !Task.isCancelled else { return nil }
        guard let service = requirePrivilegedService(context: context) else { return nil }

        guard !Task.isCancelled else { return nil }
        let outcome = await service.skip()
        guard !Task.isCancelled else { return nil }
        return Self.reply(for: outcome)
    }

    // MARK: - Reply Formatting

    /// Chat reply for a skip outcome. Only a real drain says the queue is
    /// empty; a skip that changed nothing says so instead of claiming success.
    ///
    /// - Parameter outcome: What `SongRequestService.skip()` did.
    /// - Returns: The chat reply.
    static func reply(for outcome: SongRequestService.SkipOutcome) -> String {
        switch outcome {
        case .started(let next):
            return "Skipped. Now playing: \"\(next.title)\" by \(next.artist) (requested by \(next.requesterUsername))"
        case .drained:
            return "Skipped. Queue is now empty."
        case .busy, .retained:
            return "Couldn't skip right now, try again."
        }
    }
}
