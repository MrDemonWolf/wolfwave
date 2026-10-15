//
//  CustomCommandStore.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-07-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Persists the user's custom chat commands as JSON in `UserDefaults` and exposes
/// them as an observable list for the settings UI.
///
/// The dispatcher reads ``enabledCommands`` on the MainActor each time it matches
/// a message, so edits take effect on the next chat line without re-registration.
@Observable
@MainActor
final class CustomCommandStore {

    /// Shared instance read by the dispatcher and the settings pane.
    static let shared = CustomCommandStore()

    /// All commands, in display/persistence order.
    private(set) var commands: [CustomCommand] = []

    /// Enabled commands with a usable trigger. This is what the dispatcher runs.
    var enabledCommands: [CustomCommand] {
        commands.filter { $0.enabled && !$0.normalizedTrigger.isEmpty }
    }

    /// Backing store. Never `UserDefaults.standard` in tests (see the init).
    private let defaults: UserDefaults
    /// Defaults key holding the JSON-encoded `[CustomCommand]`.
    private let key = AppConstants.UserDefaults.customCommands

    /// Loads (and, if needed, repairs) the stored commands synchronously.
    ///
    /// - Parameter defaults: Injection seam for tests; defaults to
    ///   ``DefaultsStore/store``.
    init(defaults: UserDefaults = DefaultsStore.store) {
        self.defaults = defaults
        load()
    }

    // MARK: - Mutation

    /// Appends a new command and persists.
    ///
    /// The draft must pass ``validationIssue(for:)`` (trigger, aliases,
    /// clashes, reply) and the combined set the import rules (identity and
    /// cooldown bounds). A valid draft is stored in normalized form, so the
    /// saved trigger may differ from what was typed.
    ///
    /// - Returns: `false` when the draft or the combined set would be invalid,
    ///   in which case nothing changes.
    @discardableResult
    func add(_ command: CustomCommand) -> Bool {
        guard validationIssue(for: command) == nil,
              let normalized = CustomCommand.normalizedForImport(commands + [command]) else {
            return false
        }
        commands = normalized
        save()
        return true
    }

    /// Replaces the command with the same `id` and persists.
    ///
    /// Checked by ``validationIssue(for:)`` and the import rules, as in ``add(_:)``,
    /// with one exception: turning a command off without changing anything else
    /// skips ``validationIssue(for:)``. A command loaded from old storage or an
    /// import can already fail it (an empty reply, say), and the list toggle must
    /// still be able to switch that command off.
    ///
    /// - Returns: `false` when no command has that `id` or the result would be
    ///   invalid, in which case nothing changes.
    @discardableResult
    func update(_ command: CustomCommand) -> Bool {
        guard let index = commands.firstIndex(where: { $0.id == command.id }) else { return false }
        var unchangedExceptEnabled = command
        unchangedExceptEnabled.enabled = commands[index].enabled
        let isDisableOnly = !command.enabled && unchangedExceptEnabled == commands[index]
        guard isDisableOnly || validationIssue(for: command) == nil else { return false }
        var updated = commands
        updated[index] = command
        guard let normalized = CustomCommand.normalizedForImport(updated) else { return false }
        commands = normalized
        save()
        return true
    }

    /// Removes the command with `id` and persists. No-op (apart from the
    /// re-save) when the id is unknown.
    func delete(id: UUID) {
        commands.removeAll { $0.id == id }
        save()
    }

    /// Removes every command and persists the empty live snapshot.
    ///
    /// Factory reset calls this before deleting the backing preference so the
    /// shared store cannot later re-save a stale in-memory command list after a
    /// failed relaunch.
    func clearAll() {
        commands.removeAll()
        save()
    }

    /// The first reason `candidate` can't be saved, or `nil` when it can.
    ///
    /// Checks run in the order the editor fields read: trigger, aliases, clashes
    /// with other commands, then the reply. A trigger or alias claimed by a
    /// command other than `candidate` is reported with that command's name,
    /// because the dispatcher resolves overlaps by first match and the second
    /// command would silently never fire.
    func validationIssue(for candidate: CustomCommand) -> CustomCommandIssue? {
        let trigger = candidate.normalizedTrigger
        guard !trigger.isEmpty else { return .emptyTrigger }
        if CustomCommand.containsWhitespace(trigger) { return .hasSpaces(trigger) }

        if !candidate.aliases.trimmingCharacters(in: .whitespaces).isEmpty {
            var seen: Set<String> = [trigger]
            for raw in candidate.aliases.split(separator: ",", omittingEmptySubsequences: false) {
                let alias = CustomCommand.normalizeTrigger(String(raw))
                if alias.isEmpty { return .badAlias("") }
                if CustomCommand.containsWhitespace(alias) { return .hasSpaces(alias) }
                if !seen.insert(alias).inserted { return .badAlias(alias) }
            }
        }

        let candidateTokens = candidate.allTriggerTokens
        for other in commands where other.id != candidate.id {
            let claimed = Set(other.allTriggerTokens)
            if let clash = candidateTokens.first(where: { claimed.contains($0) }) {
                return .duplicate(clash, owner: other.normalizedTrigger)
            }
        }

        if candidate.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyReply
        }
        // `chatLength` (Unicode scalars) is the measure Twitch and
        // `truncatedForChat()` use, so a reply that passes here is never
        // truncated on send (a flag emoji is one Character but two scalars).
        let length = candidate.response.chatLength
        if length > AppConstants.Twitch.maxMessageLength {
            return .replyTooLong(count: length)
        }
        return nil
    }

    // MARK: - Persistence

    /// Reads, decodes, and repairs the stored list.
    ///
    /// Undecodable or unrepairable bytes leave the list empty in memory but
    /// are not overwritten here, so the original JSON survives until the next
    /// mutation saves. A successful repair is written back immediately.
    private func load() {
        guard let data = defaults.data(forKey: key) else {
            commands = []
            return
        }
        guard let decoded = try? JSONCoders.default.decode([CustomCommand].self, from: data),
              let normalized = CustomCommand.normalizedForExistingStorage(decoded) else {
            commands = []
            return
        }
        commands = normalized
        if normalized != decoded { save() }
    }

    /// Atomically replaces the live and persisted command snapshot during
    /// settings import. Invalid bytes leave the current commands untouched.
    ///
    /// - Parameter data: JSON-encoded `[CustomCommand]` from a backup.
    /// - Returns: `false` when the data doesn't decode or fails import validation.
    @discardableResult
    func replaceFromImportedData(_ data: Data) -> Bool {
        guard let decoded = try? JSONCoders.default.decode(
            [CustomCommand].self,
            from: data
        ),
        let imported = CustomCommand.normalizedForImport(decoded),
        let normalizedData = try? JSONCoders.defaultEncoder.encode(imported)
        else { return false }
        commands = imported
        defaults.set(normalizedData, forKey: key)
        return true
    }

    /// Encodes and writes the current list. An encoding failure is dropped
    /// silently and leaves the previous bytes in place.
    private func save() {
        guard let data = try? JSONCoders.defaultEncoder.encode(commands) else { return }
        defaults.set(data, forKey: key)
    }
}

// MARK: - Trigger tokens

nonisolated extension CustomCommand {
    /// The normalized primary trigger plus every normalized alias.
    ///
    /// Empty entries are dropped. Matched against the first token of a chat
    /// line, so this is the command's full trigger set.
    var allTriggerTokens: [String] {
        var tokens = [normalizedTrigger]
        tokens += aliases.split(separator: ",")
            .map { CustomCommand.normalizeTrigger(String($0)) }
        return tokens.filter { !$0.isEmpty }
    }
}

// MARK: - Off-main reads

extension CustomCommandStore {
    /// Whether any enabled stored command is set to announcement delivery. Reads the
    /// persisted JSON directly so actor-isolated callers (token validation)
    /// don't need a MainActor hop.
    nonisolated static func storedCommandsUseAnnounce(defaults: UserDefaults) -> Bool {
        guard let data = defaults.data(forKey: AppConstants.UserDefaults.customCommands),
              let commands = try? JSONCoders.default.decode([CustomCommand].self, from: data) else {
            return false
        }
        return commands.contains { $0.enabled && $0.delivery == .announce }
    }
}
