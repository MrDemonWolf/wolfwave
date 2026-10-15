//
//  CustomBotCommand.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-07-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Runtime adapter that turns a stored ``CustomCommand`` definition into a
/// dispatchable ``AsyncBotCommand``.
///
/// It is async because the reply may interpolate live state (`$song`) fetched
/// through the same providers the built-in `!song` command uses. Permission is
/// enforced by the dispatcher via ``isAllowed(context:)`` before the cooldown is
/// recorded, so a denied viewer can't burn the shared cooldown.
///
/// Instances are throwaway: the dispatcher builds a fresh one per message from
/// ``CustomCommandStore/enabledCommands``. Cooldowns come straight from the
/// definition (no `UserDefaults` override keys) and are keyed on the primary
/// trigger, so a custom command that shadows a built-in trigger shares that
/// built-in's cooldown slot.
final class CustomBotCommand: AsyncBotCommand {

    // MARK: - Properties

    /// The stored command this adapter runs.
    let definition: CustomCommand

    /// Fetches live substitution values (current/last song) at send time.
    private let variables: @Sendable () async -> CustomCommandVariables

    /// - Parameters:
    ///   - definition: The stored command.
    ///   - variables: Provider for `$song` / `$lastsong`, awaited on each run.
    init(
        definition: CustomCommand,
        variables: @escaping @Sendable () async -> CustomCommandVariables
    ) {
        self.definition = definition
        self.variables = variables
    }

    // MARK: - BotCommand

    /// Just the primary trigger, so it is the canonical cooldown key.
    var triggers: [String] { [definition.normalizedTrigger] }
    /// The streamer's chosen delivery (reply, message, or announcement).
    var delivery: ReplyDelivery { definition.delivery }

    var description: String { "Custom command \(definition.normalizedTrigger)" }

    var globalCooldown: TimeInterval { definition.globalCooldown }

    var userCooldown: TimeInterval { definition.userCooldown }

    /// Primary trigger plus the definition's aliases. Overrides the protocol
    /// default (which reads aliases from a `UserDefaults` key) because a custom
    /// command carries its aliases inline.
    var allTriggers: [String] { definition.allTriggerTokens }

    /// Enforced by the dispatcher before the command runs.
    func isAllowed(context: BotCommandContext) -> Bool {
        definition.permission.allows(context)
    }

    // MARK: - AsyncBotCommand

    /// Renders the template for this message. Returns `nil` when the rendered
    /// text is empty (e.g. a reply that is only `$1` with no argument), so the
    /// bot stays silent rather than sending a blank line.
    func execute(message: String, context: BotCommandContext) async -> String? {
        let vars = await variables()
        let text = CustomCommandRenderer.render(
            template: definition.response,
            sender: context.username,
            args: CustomCommandRenderer.arguments(from: message),
            vars: vars
        )
        return text.isEmpty ? nil : text
    }
}
