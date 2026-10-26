//
//  BotCommand.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-01-08.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Protocol for Twitch bot command implementations.
///
/// Implementations must be thread-safe and validate input.
/// Replies are capped at Twitch's 500-character limit: commands that build
/// long text truncate with `truncatedForChat()`, and the chat send path in
/// `TwitchChatService+Sending` truncates again. The dispatcher only bounds the
/// inbound message length.
///
/// Most protocol members have defaults in the extensions below, so a
/// conformer usually supplies just `triggers`, `description`, and `execute`.
protocol BotCommand {
    /// The command triggers that activate this command (e.g., ["!song", "!currentsong"]).
    /// Triggers are case-insensitive. The first entry is the canonical name:
    /// the dispatcher keys cooldowns on it, so aliases share one cooldown.
    var triggers: [String] { get }

    /// Description of what the command does. Informational only: no chat
    /// command or settings view lists it today.
    var description: String { get }

    /// How the response is sent to chat. Built-ins reply to the chatter.
    var delivery: ReplyDelivery { get }

    /// Global cooldown in seconds between any uses of this command (0 = disabled).
    var globalCooldown: TimeInterval { get }

    /// Per-user cooldown in seconds between uses by the same user (0 = disabled).
    var userCooldown: TimeInterval { get }

    /// UserDefaults key for the global cooldown override. nil = use `globalCooldown` default.
    var globalCooldownKey: String? { get }

    /// UserDefaults key for the per-user cooldown override. nil = use `userCooldown` default.
    var userCooldownKey: String? { get }

    /// UserDefaults key controlling whether this command is enabled. nil = always enabled.
    var enabledKey: String? { get }

    /// UserDefaults key storing custom alias triggers (comma-separated). nil = no custom aliases.
    var aliasesKey: String? { get }

    /// Every trigger this command answers to: base triggers plus any aliases.
    /// A protocol requirement (not just an extension) so commands that carry
    /// their aliases inline (e.g. ``CustomBotCommand``) can override the default
    /// `UserDefaults`-backed implementation.
    var allTriggers: [String] { get }

    /// Whether `context` is permitted to run this command. Checked by the
    /// dispatcher before recording the cooldown, so a denied viewer can't warm
    /// the shared cooldown. Default: allow everyone.
    func isAllowed(context: BotCommandContext) -> Bool

    /// Whether this caller may bypass the command's cooldown (like moderators do).
    /// Lets a command grant a per-role perk (e.g. the Sub/VIP song-request
    /// priority). `context` is nil on non-chat dispatch paths. Default: no bypass.
    func bypassesCooldown(context: BotCommandContext?) -> Bool

    /// Execute the command and return the response message.
    /// Keep response time under 100ms for responsive chat experience.
    ///
    /// - Parameter message: The whitespace-trimmed chat line, trigger included.
    /// - Returns: The reply, or `nil` to stay silent. A `nil` releases the
    ///   cooldown slot the dispatcher claimed for this call.
    func execute(message: String) -> String?
}

// MARK: - Default Cooldown Values

extension BotCommand {
    /// Default: a threaded reply to the chatter. Only custom commands override it.
    var delivery: ReplyDelivery { .reply }
    /// Default global cooldown: 15 seconds between any uses.
    var globalCooldown: TimeInterval { 15.0 }

    /// Default per-user cooldown: 15 seconds between uses by the same user.
    var userCooldown: TimeInterval { 15.0 }

    /// Default: no UserDefaults override.
    var globalCooldownKey: String? { nil }

    /// Default: no UserDefaults override.
    var userCooldownKey: String? { nil }
}

// MARK: - Enable/Disable & Aliases

extension BotCommand {
    /// Default: no enable/disable key (always enabled).
    var enabledKey: String? { nil }

    /// Default: no custom aliases.
    var aliasesKey: String? { nil }

    /// Combined triggers: original triggers + any user-configured aliases from UserDefaults.
    ///
    /// Aliases are stored comma-separated; each is trimmed, lowercased, and
    /// given a leading `!` if the user omitted it. Read on every call (the
    /// dispatcher calls it per message), so an alias edit applies immediately.
    var allTriggers: [String] {
        var result = triggers
        if let key = aliasesKey,
           let custom = DefaultsStore.store.string(forKey: key) {
            result += BuiltInCommandCatalog.parseAliases(custom)
        }
        return result
    }

    /// Default: no permission gate; every viewer may run the command.
    func isAllowed(context: BotCommandContext) -> Bool { true }

    /// Default: no cooldown bypass; every caller waits out the cooldown.
    func bypassesCooldown(context: BotCommandContext?) -> Bool { false }

    /// Whether this command is currently enabled. An unset `enabledKey`
    /// counts as enabled, so a command is on until the user turns it off.
    var isCommandEnabled: Bool {
        guard let key = enabledKey else { return true }
        // Use object(forKey:) to distinguish "not set" (default true) from explicit false
        let defaults = DefaultsStore.store
        if defaults.object(forKey: key) == nil { return true }
        return defaults.bool(forKey: key)
    }
}

// MARK: - Trigger Matching

extension BotCommand {
    /// The lowercased first whitespace-delimited token of `message` — the part
    /// matched against ``allTriggers``. Falls back to the whole lowercased
    /// string when the message has no whitespace. Shared by the command
    /// implementations that gate on their own trigger set.
    ///
    /// The dispatcher deliberately does not use this: its hot path computes the
    /// token once and fast-exits on a missing `!` prefix before the snapshot copy.
    func commandToken(in message: String) -> String {
        let lowered = message.lowercased()
        return lowered.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? lowered
    }
}

// MARK: - ServiceBoundCommand

/// Mixin for async commands that require a `SongRequestService` and mod/broadcaster privilege.
///
/// Conforming types get `requirePrivilegedService(context:)` for free, eliminating
/// the repeated guard/service-binding boilerplate in SkipCommand, ClearQueueCommand, etc.
protocol ServiceBoundCommand: AsyncBotCommand {
    /// Late-bound accessor for the live service, wired by
    /// `BotCommandDispatcher.setSongRequestService(callback:)`. `nil` until
    /// wired; the closure itself returns `nil` while song requests are down.
    var songRequestService: (() -> SongRequestService?)? { get set }
}

extension ServiceBoundCommand {
    /// Rejects non-privileged callers before the dispatcher reserves a cooldown.
    /// Individual commands retain their execute-time guard as defense in depth.
    func isAllowed(context: BotCommandContext) -> Bool {
        context.isPrivileged
    }

    /// Returns the service only if the context is privileged (mod or broadcaster).
    /// Silently returns `nil` for non-privileged users, matching the established pattern.
    func requirePrivilegedService(context: BotCommandContext) -> SongRequestService? {
        guard context.isPrivileged else { return nil }
        return songRequestService?()
    }
}
