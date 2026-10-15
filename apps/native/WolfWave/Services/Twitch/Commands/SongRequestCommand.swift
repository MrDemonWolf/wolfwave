//
//  SongRequestCommand.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-04-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Handles `!sr` / `!request` / `!songrequest`. Searches and queues a song.
///
/// Accepts plain text queries and Apple Music, Spotify, and YouTube links
/// (resolved by `SongRequestService` / `LinkResolverService`). The dispatcher
/// awaits the whole lookup, so chat gets exactly one reply describing the
/// outcome; there is no separate "searching..." acknowledgment.
///
/// Conforms to ``PreflightCheckedCommand`` so a viewer refused by the audience
/// gate or the feature switch never starts the shared `!sr` cooldown.
final class SongRequestCommand: AsyncBotCommand, PreflightCheckedCommand {
    // MARK: - BotCommand

    /// Chat triggers that invoke this command.
    var triggers: [String] { ["!sr", "!request", "!songrequest"] }

    /// Human-readable description (informational; no chat command lists it).
    var description: String { "Request a song by name or Spotify/YouTube link" }

    /// Channel-wide cooldown between invocations, in seconds.
    var globalCooldown: TimeInterval { 5.0 }

    /// Per-user cooldown between invocations, in seconds.
    var userCooldown: TimeInterval { 30.0 }

    /// UserDefaults key for the user-configurable global cooldown override.
    var globalCooldownKey: String? { AppConstants.UserDefaults.songRequestGlobalCooldown }

    /// UserDefaults key for the user-configurable per-user cooldown override.
    var userCooldownKey: String? { AppConstants.UserDefaults.songRequestUserCooldown }

    /// UserDefaults key controlling whether the command is enabled.
    var enabledKey: String? { AppConstants.UserDefaults.srCommandEnabled }

    /// UserDefaults key holding custom trigger aliases.
    var aliasesKey: String? { AppConstants.UserDefaults.srCommandAliases }

    // MARK: - Properties

    /// Provides the active `SongRequestService`. Late-bound to break the
    /// AppDelegate ↔ command dependency cycle at startup.
    var songRequestService: (() -> SongRequestService?)?

    /// Subscribers/VIPs skip the request cooldown when the priority perk is set to
    /// cooldown-skip or queue-jump. Mirrors the moderator bypass the dispatcher
    /// already honors.
    func bypassesCooldown(context: BotCommandContext?) -> Bool {
        guard let context else { return false }
        return SongRequestPriority.mode().skipsCooldown && SongRequestPriority.qualifies(context)
    }

    // MARK: - PreflightCheckedCommand

    /// Chat reply when the feature is off and the streamer opted into replying.
    static let disabledReply = "Song requests are off right now."

    /// Refuses `!sr` before the dispatcher claims its cooldown when song
    /// requests are off or the sender is outside the chat audience, so a refused
    /// viewer never starts the cooldown allowed viewers share.
    /// `SongRequestService.processRequest` repeats both checks as defense in depth.
    ///
    /// - Parameter context: The sender's chat context.
    /// - Returns: The refusal, or `nil` when the request may proceed.
    func preflightDenial(context: BotCommandContext) -> PreflightDenial? {
        let defaults = DefaultsStore.store
        guard defaults.bool(forKey: AppConstants.UserDefaults.songRequestEnabled) else {
            return defaults.bool(forKey: AppConstants.UserDefaults.songRequestDisabledReplyEnabled)
                ? .reply(Self.disabledReply)
                : .silent
        }
        let audience = RequestAudience.current(in: defaults)
        guard audience.permits(context) else { return .reply(audience.denialMessage) }
        return nil
    }

    // MARK: - AsyncBotCommand

    /// Parses the search query, dispatches to the resolver, and formats the
    /// chat reply for every `RequestResult` case.
    ///
    /// - Parameters:
    ///   - message: Raw chat message; trigger prefix is stripped to recover the query.
    ///   - context: Sender context. The service keys queue ownership on
    ///     `requesterLogin` and checks the requester blocklist against both
    ///     the login and the display name.
    /// - Returns: The eventual chat response, or nil to stay silent.
    func execute(message: String, context: BotCommandContext) async -> String? {
        guard !Task.isCancelled else { return nil }
        // Master feature gate. When song requests are off, the empty-query
        // "Usage:" hint below would otherwise leak even though requests can't
        // flow, so bail here first. Default is silence; the streamer can opt into
        // a "requests are off" reply.
        let defaults = DefaultsStore.store
        guard defaults.bool(forKey: AppConstants.UserDefaults.songRequestEnabled) else {
            return defaults.bool(forKey: AppConstants.UserDefaults.songRequestDisabledReplyEnabled)
                ? Self.disabledReply
                : nil
        }

        // Extract the query (everything after the trigger)
        let query = Self.extractQuery(from: message)

        guard !query.isEmpty else {
            return "Usage: !sr <song name or Spotify/YouTube link>"
        }

        guard let service = songRequestService?() else {
            return "Song requests aren't available right now."
        }

        guard !Task.isCancelled else { return nil }
        let result = await service.processRequest(
            query: query,
            username: context.username,
            source: .chatCommand(context)
        )
        guard !Task.isCancelled else { return nil }

        let response: String
        switch result {
        // The task was torn down mid-request; say nothing rather than reply
        // into a session that is going away.
        case .cancelled:
            return nil
        case .added(let item, let position):
            response = "Added \"\(item.title)\" by \(item.artist), #\(position) in queue"

        case .pendingApproval(let item):
            response = "Sent \"\(item.title)\" by \(item.artist) to the streamer for approval."

        case .queueFull(let max):
            response = "Queue is full (\(max)/\(max)). Try again later!"

        case .userLimitReached(let max):
            response = "You already have \(max) songs queued. Wait for one to play!"

        case .alreadyInQueue:
            response = "That song is already in your queue."

        case .blocked:
            response = "Sorry, that song/artist is on the blocklist."

        case .notFound(let query):
            let truncated = StringFormatting.truncatedWithEllipsis(query)
            response = "No results for \"\(truncated)\". Try a different search!"

        case .linkNotFound:
            response = "Couldn't find that on Apple Music. Try a song name instead!"

        case .notAuthorized:
            response = "Song requests aren't available right now."

        case .featureDisabled:
            response = Self.disabledReply

        // Already chat-ready text from the service (e.g. the audience denial).
        case .error(let message):
            response = message
        }

        return response
    }

    // MARK: - Query Parsing

    /// Drops the first whitespace-delimited token (the trigger) and returns the
    /// rest as the search query, trimmed of surrounding whitespace.
    ///
    /// The dispatcher routes on exact first-token equality, so that token is
    /// already one of this command's triggers. Stripping by token instead of by
    /// prefix keeps an alias that extends a base trigger (`!srq`, `!request2`)
    /// from losing its tail characters to the shorter `!sr` / `!request`.
    ///
    /// - Parameter message: Full chat message including the trigger.
    /// - Returns: The query portion, or an empty string when there is none.
    static func extractQuery(from message: String) -> String {
        let parts = message.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count > 1 else { return "" }
        return String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
