//
//  CustomCommandTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-07-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation
@testable import WolfWave

// MARK: - Context Fixture

/// Chat context for `username` with the given badges. The user id is fixed at "123".
private func makeContext(
    username: String = "viewer",
    isModerator: Bool = false,
    isBroadcaster: Bool = false,
    isSubscriber: Bool = false,
    isVIP: Bool = false
) -> BotCommandContext {
    BotCommandContext(
        userID: "123",
        username: username,
        isModerator: isModerator,
        isBroadcaster: isBroadcaster,
        isSubscriber: isSubscriber,
        isVIP: isVIP,
        messageID: "m1"
    )
}

// MARK: - Permission

/// `CommandPermission` gating: which chat roles each level admits.
@Suite("CommandPermission")
struct CommandPermissionTests {

    @Test("everyone always allows")
    func everyone() {
        #expect(CommandPermission.everyone.allows(makeContext()))
    }

    @Test("subscriber allows subs, VIPs, mods, broadcaster; not plain viewers")
    func subscriber() {
        let perm = CommandPermission.subscriber
        #expect(!perm.allows(makeContext()))
        #expect(perm.allows(makeContext(isSubscriber: true)))
        #expect(perm.allows(makeContext(isVIP: true)))
        #expect(perm.allows(makeContext(isModerator: true)))
        #expect(perm.allows(makeContext(isBroadcaster: true)))
    }

    @Test("vip allows VIPs and privileged, not subs")
    func vip() {
        let perm = CommandPermission.vip
        #expect(!perm.allows(makeContext(isSubscriber: true)))
        #expect(perm.allows(makeContext(isVIP: true)))
        #expect(perm.allows(makeContext(isModerator: true)))
    }

    @Test("moderator allows mods and broadcaster only")
    func moderator() {
        let perm = CommandPermission.moderator
        #expect(!perm.allows(makeContext(isVIP: true)))
        #expect(perm.allows(makeContext(isModerator: true)))
        #expect(perm.allows(makeContext(isBroadcaster: true)))
    }

    @Test("broadcaster allows only the broadcaster")
    func broadcaster() {
        let perm = CommandPermission.broadcaster
        #expect(!perm.allows(makeContext(isModerator: true)))
        #expect(perm.allows(makeContext(isBroadcaster: true)))
    }
}

// MARK: - Renderer

/// `CustomCommandRenderer` variable substitution (`$user`, `$touser`, `$args`,
/// `$1`-`$9`, `$song`, `$lastsong`), literal insertion of user-controlled tokens,
/// neutralized leading command punctuation, and truncation to Twitch's limit.
@Suite("CustomCommandRenderer")
struct CustomCommandRendererTests {

    private let vars = CustomCommandVariables(currentSong: "Howl", lastSong: "Moonrise")

    @Test("substitutes sender for $user and $sender")
    func user() {
        let out = CustomCommandRenderer.render(
            template: "hi $user / $sender", sender: "Luna", args: [], vars: .empty)
        #expect(out == "hi Luna / Luna")
    }

    @Test("$touser uses first arg with @ stripped, else sender")
    func touser() {
        let hit = CustomCommandRenderer.render(
            template: "$user hugs $touser", sender: "Luna", args: ["@Bob"], vars: .empty)
        #expect(hit == "Luna hugs Bob")

        let fallback = CustomCommandRenderer.render(
            template: "$touser", sender: "Luna", args: [], vars: .empty)
        #expect(fallback == "Luna")
    }

    @Test("$args joins all arguments, $1..$9 are positional")
    func args() {
        let out = CustomCommandRenderer.render(
            template: "[$args] first=$1 third=$3", sender: "x",
            args: ["a", "b", "c"], vars: .empty)
        #expect(out == "[a b c] first=a third=c")
    }

    @Test("absent positional args resolve to empty")
    func missingPositional() {
        let out = CustomCommandRenderer.render(
            template: "x$2y", sender: "x", args: ["only"], vars: .empty)
        #expect(out == "xy")
    }

    @Test("$song and $lastsong pull from variables")
    func song() {
        let out = CustomCommandRenderer.render(
            template: "now $song, was $lastsong", sender: "x", args: [], vars: vars)
        #expect(out == "now Howl, was Moonrise")
    }

    @Test("argument tokens are inserted literally")
    func argsContainingSongTokenAreLiteral() {
        let out = CustomCommandRenderer.render(
            template: "$args", sender: "x", args: ["$song"], vars: vars)
        #expect(out == "$song")
    }

    @Test("positional argument tokens are inserted literally")
    func argsContainingPositionalTokenAreLiteral() {
        let out = CustomCommandRenderer.render(
            template: "$1", sender: "x", args: ["$1"], vars: vars)
        #expect(out == "$1")
    }

    @Test("longest named token wins")
    func longestTokenWins() {
        let out = CustomCommandRenderer.render(
            template: "$lastsong/$song", sender: "x", args: [], vars: vars)
        #expect(out == "Moonrise/Howl")
    }

    @Test("leading command punctuation from user values is neutralized")
    func leadingSlashFromUserValueIsNeutralised() {
        let out = CustomCommandRenderer.render(
            template: "$1", sender: "x", args: ["/ban viewer"], vars: vars)
        #expect(out == "\u{2063}/ban viewer")
    }

    @Test("arguments(from:) drops the trigger token")
    func arguments() {
        #expect(CustomCommandRenderer.arguments(from: "!hug @bob tightly") == ["@bob", "tightly"])
        #expect(CustomCommandRenderer.arguments(from: "!hug").isEmpty)
    }

    @Test("output is truncated to Twitch's limit")
    func truncation() {
        let long = String(repeating: "z", count: 600)
        let out = CustomCommandRenderer.render(
            template: long, sender: "x", args: [], vars: .empty)
        #expect(out.count <= AppConstants.Twitch.maxMessageLength)
    }
}

// MARK: - Normalization

/// Trigger/alias normalization, and how whitespace-containing triggers are
/// refused on import but repaired when already in storage.
@Suite("CustomCommand normalization")
struct CustomCommandNormalizationTests {

    @Test("trigger gains a single leading !, lowercased, trimmed")
    func normalize() {
        #expect(CustomCommand(trigger: "Hug").normalizedTrigger == "!hug")
        #expect(CustomCommand(trigger: "!!HUG").normalizedTrigger == "!hug")
        #expect(CustomCommand(trigger: "  raid  ").normalizedTrigger == "!raid")
        #expect(CustomCommand(trigger: "!").normalizedTrigger == "")
        #expect(CustomCommand(trigger: "").normalizedTrigger == "")
    }

    @Test("allTriggerTokens includes normalized aliases")
    func aliasTokens() {
        let cmd = CustomCommand(trigger: "hug", aliases: "embrace, !squeeze , ")
        #expect(cmd.allTriggerTokens == ["!hug", "!embrace", "!squeeze"])
    }

    // Chat matches only the first whitespace-delimited token, so a trigger or
    // alias with a space could be saved but never fire.

    @Test("import rejects a trigger containing a space")
    func importRejectsSpacedTrigger() {
        #expect(CustomCommand.normalizedForImport([CustomCommand(trigger: "!hug me")]) == nil)
    }

    @Test("import rejects an alias containing a space")
    func importRejectsSpacedAlias() {
        #expect(CustomCommand.normalizedForImport(
            [CustomCommand(trigger: "hug", aliases: "hug me")]) == nil)
    }

    @Test("existing storage keeps the other commands when one trigger has a space")
    func storageKeepsOthersAroundSpacedTrigger() throws {
        let good = CustomCommand(trigger: "!wave", response: "hi")
        let spaced = CustomCommand(trigger: "!hug me", response: "hug")
        let result = try #require(CustomCommand.normalizedForExistingStorage([spaced, good]))

        #expect(result.contains(good))
        // The dead command is repaired, not lost: spaces removed, turned off.
        let repaired = try #require(result.first { $0.id == spaced.id })
        #expect(repaired.trigger == "!hugme")
        #expect(!repaired.enabled)
        #expect(repaired.response == "hug")
    }

    @Test("existing storage drops a repaired trigger that would take another's name")
    func storageDropsCollidingRepair() throws {
        let owner = CustomCommand(trigger: "!hugme", response: "mine")
        let spaced = CustomCommand(trigger: "hug me", response: "dead")
        let result = try #require(CustomCommand.normalizedForExistingStorage([spaced, owner]))
        #expect(result == [owner])
    }

    @Test("existing storage drops an alias containing a space")
    func storageDropsSpacedAlias() throws {
        let command = CustomCommand(trigger: "hug", aliases: "big hug, squeeze")
        let result = try #require(CustomCommand.normalizedForExistingStorage([command]))
        #expect(result.first?.aliases == "squeeze")
        #expect(result.first?.enabled == true)
    }
}

// MARK: - Command execution

/// `CustomBotCommand`, the `AsyncBotCommand` adapter rebuilt from a `CustomCommand` definition per
/// message.
@Suite("CustomBotCommand")
@MainActor
struct CustomBotCommandTests {

    @Test("returns the rendered reply")
    func execute() async {
        let definition = CustomCommand(trigger: "hug", response: "$user hugs $touser")
        let command = CustomBotCommand(definition: definition, variables: { .empty })
        let ctx = makeContext(username: "Luna")

        let reply = await command.execute(message: "!hug @Bob", context: ctx)
        #expect(reply == "Luna hugs Bob")
    }

    @Test("permission gate reflects the definition")
    func permission() {
        let modOnly = CustomBotCommand(
            definition: CustomCommand(trigger: "raid", permission: .moderator),
            variables: { .empty })
        #expect(!modOnly.isAllowed(context: makeContext()))
        #expect(modOnly.isAllowed(context: makeContext(isModerator: true)))
    }

    @Test("allTriggers and cooldowns come from the definition")
    func metadata() {
        let command = CustomBotCommand(
            definition: CustomCommand(
                trigger: "hug", aliases: "embrace",
                globalCooldown: 7, userCooldown: 12),
            variables: { .empty })
        #expect(command.allTriggers == ["!hug", "!embrace"])
        #expect(command.globalCooldown == 7)
        #expect(command.userCooldown == 12)
    }
}

// MARK: - Store

/// `CustomCommandStore` persistence and the single `validationIssue(for:)` draft
/// check. The `.isolatedSharedTestState` trait serializes it against every other
/// suite that touches `DefaultsStore.store`.
@Suite("CustomCommandStore", .isolatedSharedTestState)
@MainActor
struct CustomCommandStoreTests {

    /// A store backed by a uniquely named throwaway `UserDefaults` suite, returned with it so a
    /// test can inspect or reload from it.
    private func makeStore() -> (CustomCommandStore, UserDefaults) {
        let suite = "test.customcommands.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (CustomCommandStore(defaults: defaults), defaults)
    }

    @Test("add / update / delete mutate the list")
    func crud() {
        let (store, _) = makeStore()
        var cmd = CustomCommand(trigger: "hug", response: "hi")
        store.add(cmd)
        #expect(store.commands.count == 1)

        cmd.response = "updated"
        store.update(cmd)
        #expect(store.commands.first?.response == "updated")

        store.delete(id: cmd.id)
        #expect(store.commands.isEmpty)
    }

    @Test("commands persist and reload from the same defaults")
    func persistence() {
        let (store, defaults) = makeStore()
        store.add(CustomCommand(trigger: "hug", response: "hi"))

        let reloaded = CustomCommandStore(defaults: defaults)
        #expect(reloaded.commands.count == 1)
        #expect(reloaded.commands.first?.normalizedTrigger == "!hug")
    }

    @Test("clearAll replaces the live and persisted snapshot")
    func clearAll() throws {
        let (store, defaults) = makeStore()
        store.add(CustomCommand(trigger: "hug", response: "hi"))

        store.clearAll()

        #expect(store.commands.isEmpty)
        let data = try #require(
            defaults.data(forKey: AppConstants.UserDefaults.customCommands)
        )
        #expect(try JSONCoders.default.decode([CustomCommand].self, from: data).isEmpty)

        let later = CustomCommand(trigger: "!wave", response: "hello")
        store.add(later)
        let reloaded = CustomCommandStore(defaults: defaults)
        #expect(reloaded.commands == [later])
    }

    @Test("enabledCommands drops disabled and triggerless entries")
    func enabledFilter() {
        let (store, _) = makeStore()
        store.add(CustomCommand(trigger: "on", response: "x", enabled: true))
        store.add(CustomCommand(trigger: "off", response: "x", enabled: false))
        store.add(CustomCommand(trigger: "", response: "x", enabled: true))
        #expect(store.enabledCommands.map(\.normalizedTrigger) == ["!on"])
    }

    @Test("validationIssue detects primary and alias overlap")
    func conflicts() {
        let (store, _) = makeStore()
        let existing = CustomCommand(trigger: "hug", response: "hi", aliases: "embrace")
        store.add(existing)

        #expect(store.validationIssue(for: CustomCommand(trigger: "hug", response: "x"))
            == .duplicate("!hug", owner: "!hug"))
        #expect(store.validationIssue(for: CustomCommand(trigger: "wave", response: "x", aliases: "embrace"))
            == .duplicate("!embrace", owner: "!hug"))
        #expect(store.validationIssue(for: CustomCommand(trigger: "wave", response: "x", aliases: "cheer, cheer"))
            == .badAlias("!cheer"))
        #expect(store.validationIssue(for: CustomCommand(trigger: "wave", response: "x")) == nil)
        #expect(store.validationIssue(for: existing) == nil)
    }

    @Test("a duplicate names the other command, not the clashing alias")
    func validationReasonDuplicateNamesOther() {
        let (store, _) = makeStore()
        store.add(CustomCommand(trigger: "hug", response: "hi", aliases: "squeeze"))

        let issue = store.validationIssue(
            for: CustomCommand(trigger: "cuddle", response: "aw", aliases: "squeeze"))
        #expect(issue == .duplicate("!squeeze", owner: "!hug"))
        #expect(issue?.message == "!squeeze is already used by !hug.")
        #expect(issue?.field(trigger: "!cuddle") == .aliases)
    }

    @Test("an empty or blank reply blocks save")
    func emptyReplyBlocksSave() {
        let (store, _) = makeStore()
        #expect(store.validationIssue(for: CustomCommand(trigger: "hug")) == .emptyReply)
        #expect(store.validationIssue(for: CustomCommand(trigger: "hug", response: "  \n ")) == .emptyReply)
        #expect(CustomCommandIssue.emptyReply.field(trigger: "!hug") == .reply)
        #expect(CustomCommandIssue.emptyReply.isNeutralHint)
    }

    @Test("a reply over Twitch's limit blocks save")
    func replyTooLongBlocksSave() {
        let (store, _) = makeStore()
        let limit = AppConstants.Twitch.maxMessageLength
        let atLimit = String(repeating: "a", count: limit)
        #expect(store.validationIssue(for: CustomCommand(trigger: "hug", response: atLimit)) == nil)
        #expect(store.validationIssue(for: CustomCommand(trigger: "hug", response: atLimit + "a"))
            == .replyTooLong(count: limit + 1))
    }

    @Test("reply length is measured in Unicode scalars, like the send-time truncation")
    func replyLengthCountsScalars() {
        let (store, _) = makeStore()
        let limit = AppConstants.Twitch.maxMessageLength
        // A flag is one Character but two scalars: 260 flags are 520 scalars,
        // which Twitch would truncate, even though they are only 260 graphemes.
        let flags = String(repeating: "\u{1F1FA}\u{1F1F8}", count: limit / 2 + 10)
        #expect(flags.count < limit)
        #expect(store.validationIssue(for: CustomCommand(trigger: "hug", response: flags))
            == .replyTooLong(count: flags.unicodeScalars.count))
        // Anything that passes the gate is never truncated on send.
        let fits = String(repeating: "\u{1F1FA}\u{1F1F8}", count: limit / 2)
        #expect(store.validationIssue(for: CustomCommand(trigger: "hug", response: fits)) == nil)
        #expect(fits.truncatedForChat() == fits)
    }

    @Test("empty triggers, spaces, and empty aliases are each named")
    func triggerAndAliasIssues() {
        let (store, _) = makeStore()
        #expect(store.validationIssue(for: CustomCommand(trigger: "!", response: "x")) == .emptyTrigger)
        #expect(CustomCommandIssue.emptyTrigger.isNeutralHint)

        let spacedTrigger = store.validationIssue(for: CustomCommand(trigger: "hug me", response: "x"))
        #expect(spacedTrigger == .hasSpaces("!hug me"))
        #expect(spacedTrigger?.field(trigger: "!hug me") == .trigger)
        #expect(spacedTrigger?.message == "Triggers and aliases can't contain spaces.")

        let spacedAlias = store.validationIssue(
            for: CustomCommand(trigger: "hug", response: "x", aliases: "big hug"))
        #expect(spacedAlias == .hasSpaces("!big hug"))
        #expect(spacedAlias?.field(trigger: "!hug") == .aliases)

        #expect(store.validationIssue(for: CustomCommand(trigger: "hug", response: "x", aliases: "a,,b"))
            == .badAlias(""))
        #expect(store.validationIssue(for: CustomCommand(trigger: "hug", response: "x", aliases: "hug"))
            == .badAlias("!hug"))
    }

    @Test("add and update report whether they stored the command")
    func mutationsReportOutcome() {
        let (store, _) = makeStore()
        let hug = CustomCommand(trigger: "hug", response: "hi")
        #expect(store.add(hug))
        #expect(!store.add(CustomCommand(trigger: "hug", response: "again")))
        #expect(!store.update(CustomCommand(trigger: "ghost", response: "x")))
        var edited = hug
        edited.response = "hello"
        #expect(store.update(edited))
    }

    @Test("direct mutations reject invalid or overlapping command definitions")
    func rejectsInvalidMutations() {
        let (store, _) = makeStore()
        let existing = CustomCommand(trigger: "!hug", response: "hi", aliases: "embrace")
        store.add(existing)
        store.add(CustomCommand(trigger: "wave", response: "hi", aliases: "embrace"))
        #expect(store.commands == [existing])

        var invalidUpdate = existing
        invalidUpdate.aliases = "wave, wave"
        store.update(invalidUpdate)
        #expect(store.commands == [existing])
    }

    @Test("add and update refuse an empty or too-long reply, not just the editor")
    func mutationsCheckReply() {
        let (store, _) = makeStore()
        let limit = AppConstants.Twitch.maxMessageLength
        #expect(!store.add(CustomCommand(trigger: "blank", response: "  ")))
        #expect(!store.add(CustomCommand(
            trigger: "long", response: String(repeating: "a", count: limit + 1))))
        #expect(store.commands.isEmpty)

        let hug = CustomCommand(trigger: "hug", response: "hi")
        #expect(store.add(hug))
        var emptied = hug
        emptied.response = ""
        #expect(!store.update(emptied))
        var flags = hug
        flags.response = String(repeating: "\u{1F1FA}\u{1F1F8}", count: limit / 2 + 1)
        #expect(!store.update(flags))
        #expect(store.commands.map(\.response) == ["hi"])
    }

    /// A stored command can already fail validation (old storage, an import).
    /// The list toggle must still switch it off, but not back on.
    @Test("an invalid stored command can still be turned off, but not on")
    func invalidStoredCommandCanBeDisabled() throws {
        let (_, defaults) = makeStore()
        let legacy = CustomCommand(trigger: "blank", response: "")
        let raw = try JSONCoders.defaultEncoder.encode([legacy])
        defaults.set(raw, forKey: AppConstants.UserDefaults.customCommands)
        let store = CustomCommandStore(defaults: defaults)
        let stored = try #require(store.commands.first)
        try #require(stored.enabled)

        var off = stored
        off.enabled = false
        #expect(store.update(off))
        #expect(store.commands.first?.enabled == false)

        var on = off
        on.enabled = true
        #expect(!store.update(on))
        #expect(store.commands.first?.enabled == false)
    }

    @Test("load migrates shadowed legacy aliases without dropping commands")
    func migratesLegacyAliases() throws {
        let (_, defaults) = makeStore()
        let first = CustomCommand(trigger: "hug", aliases: "wave, hug, , cheer")
        let second = CustomCommand(trigger: "wave", aliases: "cheer, salute")
        let raw = try JSONCoders.defaultEncoder.encode([first, second])
        defaults.set(raw, forKey: AppConstants.UserDefaults.customCommands)

        let migrated = CustomCommandStore(defaults: defaults)
        #expect(migrated.commands.count == 2)
        #expect(migrated.commands[0].aliases == "cheer")
        #expect(migrated.commands[1].aliases == "salute")

        let persisted = try #require(
            defaults.data(forKey: AppConstants.UserDefaults.customCommands)
        )
        #expect(try JSONCoders.default.decode([CustomCommand].self, from: persisted) == migrated.commands)
    }

    @Test("load decodes commands stored before delivery existed as reply")
    func legacyStorageDefaultsDeliveryToReply() throws {
        let (_, defaults) = makeStore()
        let legacy = """
        [{"id":"6B5C5D7A-0F3B-4E0B-9D62-0B8E0A6F1C01","trigger":"!hug","response":"hug","aliases":"",
        "permission":"everyone","enabled":true,"globalCooldown":15,"userCooldown":15}]
        """
        defaults.set(Data(legacy.utf8), forKey: AppConstants.UserDefaults.customCommands)

        let store = CustomCommandStore(defaults: defaults)
        #expect(store.commands.count == 1)
        #expect(store.commands[0].delivery == .reply)
    }

    @Test("storedCommandsUseAnnounce reads the persisted blob")
    func storedCommandsUseAnnounce() {
        let (store, defaults) = makeStore()
        #expect(!CustomCommandStore.storedCommandsUseAnnounce(defaults: defaults))
        store.add(CustomCommand(trigger: "hug", response: "hug"))
        #expect(!CustomCommandStore.storedCommandsUseAnnounce(defaults: defaults))
        store.add(CustomCommand(trigger: "hype", response: "HYPE", delivery: .announce))
        #expect(CustomCommandStore.storedCommandsUseAnnounce(defaults: defaults))
        store.clearAll()
        store.add(CustomCommand(trigger: "off", response: "x", enabled: false, delivery: .announce))
        #expect(!CustomCommandStore.storedCommandsUseAnnounce(defaults: defaults))
    }

    @Test("delivery round-trips through storage")
    func deliveryRoundTrips() throws {
        let (store, defaults) = makeStore()
        store.add(CustomCommand(trigger: "hype", response: "HYPE", delivery: .announce))
        #expect(CustomCommandStore(defaults: defaults).commands[0].delivery == .announce)
    }
}

/// `ReplyDelivery`: stable raw values (they are storage keys), distinct labels, and the `.reply`
/// default.
@Suite("ReplyDelivery")
struct ReplyDeliveryTests {
    @Test("raw values are stable storage keys")
    func rawValues() {
        #expect(ReplyDelivery.reply.rawValue == "reply")
        #expect(ReplyDelivery.message.rawValue == "message")
        #expect(ReplyDelivery.announce.rawValue == "announce")
        #expect(ReplyDelivery.allCases.count == 3)
    }

    @Test("every case has distinct label and help")
    func labels() {
        #expect(Set(ReplyDelivery.allCases.map(\.label)).count == 3)
        #expect(Set(ReplyDelivery.allCases.map(\.help)).count == 3)
    }

    @Test("new commands default to reply")
    func defaultDelivery() {
        #expect(CustomCommand(trigger: "x").delivery == .reply)
    }
}
