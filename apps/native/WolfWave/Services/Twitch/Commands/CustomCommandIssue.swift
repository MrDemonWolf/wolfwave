//
//  CustomCommandIssue.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-11.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Why a custom command draft can't be saved yet.
///
/// Returned by ``CustomCommandStore/validationIssue(for:)`` so the editor can
/// say what is wrong and put the message under the field that needs fixing,
/// instead of one generic "must be unique" line for every cause.
nonisolated enum CustomCommandIssue: Equatable, Sendable {

    /// The trigger has no usable characters yet.
    case emptyTrigger
    /// A trigger or alias contains a space, so chat could never match it.
    /// Carries the normalized token (e.g. `!hug me`).
    case hasSpaces(String)
    /// An alias is empty (two commas in a row), repeated, or the same as this
    /// command's own trigger. Carries the normalized alias, or `""` when empty.
    case badAlias(String)
    /// `token` is already claimed by another command, named by its primary
    /// trigger in `owner`.
    case duplicate(String, owner: String)
    /// `token` belongs to a built-in command, named by its primary trigger in
    /// `builtIn` (e.g. `!np` → `!song`). Custom commands are matched first, so
    /// allowing it would quietly replace the built-in.
    case reservedTrigger(String, builtIn: String)
    /// The reply is empty, so the command would never answer.
    case emptyReply
    /// The reply is longer than Twitch allows in one message.
    case replyTooLong(count: Int)

    // MARK: - Field

    /// Which editor field an issue belongs under, so the message renders
    /// directly beneath it.
    enum Field: Hashable, Sendable {
        case trigger
        case aliases
        case reply
    }

    /// The field that owns this issue. A token issue belongs to the trigger
    /// when it names the primary trigger, otherwise to the aliases.
    ///
    /// - Parameter trigger: The draft's normalized primary trigger.
    func field(trigger: String) -> Field {
        switch self {
        case .emptyTrigger:
            return .trigger
        case .hasSpaces(let token), .duplicate(let token, _), .reservedTrigger(let token, _):
            return token == trigger ? .trigger : .aliases
        case .badAlias:
            return .aliases
        case .emptyReply, .replyTooLong:
            return .reply
        }
    }

    // MARK: - Copy

    /// Short, plain message for the editor.
    var message: String {
        switch self {
        case .emptyTrigger:
            return "Add a trigger, like !hug."
        case .hasSpaces:
            return "Triggers and aliases can't contain spaces."
        case .badAlias(let alias):
            return alias.isEmpty
                ? "Remove the empty alias between the commas."
                : "\(alias) is used twice in this command."
        case .duplicate(let token, let owner):
            return token == owner
                ? "\(token) is already a command."
                : "\(token) is already used by \(owner)."
        case .reservedTrigger(let token, let builtIn):
            return token == builtIn
                ? "\(token) is a built-in command. Pick another trigger."
                : "\(token) is already used by the built-in \(builtIn)."
        case .emptyReply:
            return "Add a reply."
        case .replyTooLong:
            return "Replies max out at \(AppConstants.Twitch.maxMessageLength) characters."
        }
    }

    /// Whether this is guidance for a field not filled in yet, rather than a
    /// mistake. Rendered neutral instead of in the error color.
    var isNeutralHint: Bool {
        switch self {
        case .emptyTrigger, .emptyReply: return true
        default: return false
        }
    }
}
