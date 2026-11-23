//
//  MyQueueCommand.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-04-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Handles `!myqueue` / `!mysongs`: shows the requester's songs in the queue.
///
/// Silent while Song Requests is off (``SongRequestGatedCommand``).
final class MyQueueCommand: AsyncBotCommand, SongRequestGatedCommand {
    // MARK: - BotCommand

    /// Chat triggers that invoke this command.
    var triggers: [String] { ["!myqueue", "!mysongs"] }

    /// Human-readable description (informational; no chat command lists it).
    var description: String { "Show your requested songs and positions in queue" }

    /// Channel-wide cooldown between invocations, in seconds.
    var globalCooldown: TimeInterval { 10.0 }

    /// Per-user cooldown between invocations, in seconds.
    var userCooldown: TimeInterval { 15.0 }

    /// UserDefaults key controlling whether the command is enabled.
    var enabledKey: String? { AppConstants.UserDefaults.myQueueCommandEnabled }

    /// UserDefaults key holding custom trigger aliases.
    var aliasesKey: String? { AppConstants.UserDefaults.myQueueCommandAliases }

    // MARK: - Properties

    /// Provides the live `SongRequestQueue`. Late-bound to break the
    /// AppDelegate ↔ command dependency cycle at startup.
    var getQueue: (() -> SongRequestQueue?)?

    /// Provides the live `SongRequestService` for the wait estimate. Optional:
    /// without it the reply simply leaves the wait out.
    var songRequestService: (() -> SongRequestService?)?

    // MARK: - AsyncBotCommand

    /// Looks up the sender's queued songs and returns their positions.
    /// Read-only; any viewer may run it.
    ///
    /// - Parameters:
    ///   - message: Raw chat message (unused).
    ///   - context: Sender context; `requesterLogin` is matched against queue
    ///     entries (the same identity `!sr` stores).
    /// - Returns: The formatted queue response, or nil when unavailable.
    func execute(message: String, context: BotCommandContext) async -> String? {
        guard let queue = getQueue?() else { return nil }

        let service = songRequestService?()
        return Self.reply(
            positions: queue.positions(for: context.requesterLogin),
            pending: queue.pendingItems(for: context.requesterLogin),
            wait: { service?.estimatedWait(forPosition: $0) })
    }

    /// Formats the viewer's queued and pending requests. Pure so tests can pin it.
    ///
    /// - Parameters:
    ///   - positions: The viewer's live-queue entries with 1-based positions.
    ///   - pending: The viewer's requests waiting for approval.
    /// - Returns: The chat reply.
    ///   - wait: The rough wait for a 1-based position, or `nil` to leave it out.
    static func reply(
        positions: [(position: Int, item: SongRequestItem)],
        pending: [SongRequestItem],
        wait: (Int) -> SongRequestService.RequestWait? = { _ in nil }
    ) -> String {
        guard !positions.isEmpty || !pending.isEmpty else {
            return "You don't have any songs in the queue. Use !sr <song name> to request one!"
        }

        let queued = positions.map { entry in
            let suffix = wait(entry.position).map(SongRequestCommand.waitSuffix) ?? ""
            return "#\(entry.position) \"\(entry.item.title)\" · \(entry.item.artist)\(suffix)"
        }
        let waiting = pending.map { "\"\($0.title)\" · \($0.artist) (waiting for approval)" }
        return "Your requests: \((queued + waiting).joined(separator: ", "))"
    }
}
