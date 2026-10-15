//
//  AsyncBotCommand.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-04-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// A bot command whose work participates in the caller's task.
///
/// Implementations return their eventual chat reply instead of spawning an
/// untracked Task or retaining a reply closure. The production dispatcher
/// awaits this method, so cancellation propagates from the active Twitch
/// receive session through command execution.
protocol AsyncBotCommand: BotCommand {
    /// Executes the command and returns the reply, or nil to stay silent.
    ///
    /// - Parameters:
    ///   - message: The whitespace-trimmed chat line, trigger included.
    ///   - context: Who sent it. Only called when the dispatcher has a
    ///     context; a context-less dispatch skips async commands entirely.
    /// - Returns: The reply text, or `nil`. The dispatcher keeps the cooldown
    ///   claimed even on `nil`, because the command may already have acted.
    func execute(message: String, context: BotCommandContext) async -> String?
}

// MARK: - Sync Compatibility

extension AsyncBotCommand {
    /// Satisfies BotCommand for legacy sync-only dispatch and focused tests.
    ///
    /// A synchronous caller cannot safely block on async work, so it receives
    /// nil. Production always routes this conformance through
    /// `BotCommandDispatcher.processMessageReplyAsync`.
    func execute(message: String) -> String? {
        nil
    }
}
