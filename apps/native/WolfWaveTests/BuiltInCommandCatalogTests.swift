//
//  BuiltInCommandCatalogTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-26.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation
@testable import WolfWave

/// Custom commands can't claim a built-in trigger or alias: the catalog stays in
/// step with the dispatcher, the editor names the built-in, and stored or
/// imported clashes are switched off rather than dropped.
@Suite("Built-in command triggers", .isolatedSharedTestState)
@MainActor
struct BuiltInCommandCatalogTests {

    /// A store over a throwaway suite, returned with the suite so a test can
    /// set built-in alias fields or seed stored commands.
    private func makeStore(
        seed: [CustomCommand]? = nil,
        songAliases: String? = nil
    ) throws -> (CustomCommandStore, UserDefaults) {
        let suite = "test.builtincatalog.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        if let songAliases {
            defaults.set(songAliases, forKey: AppConstants.UserDefaults.songCommandAliases)
        }
        if let seed {
            defaults.set(
                try JSONCoders.defaultEncoder.encode(seed),
                forKey: AppConstants.UserDefaults.customCommands
            )
        }
        return (CustomCommandStore(defaults: defaults), defaults)
    }

    // MARK: - Catalog

    @Test("catalog matches the dispatcher's built-in commands, in order")
    func catalogMatchesDispatcher() {
        let builtIns = BotCommandDispatcher().builtInCommands
        #expect(BuiltInCommandCatalog.entries.map(\.triggers) == builtIns.map(\.triggers))
        #expect(BuiltInCommandCatalog.entries.map(\.aliasesKey) == builtIns.map(\.aliasesKey))
    }

    @Test("reserved tokens include base triggers and the streamer's aliases")
    func reservedIncludesAliases() throws {
        let (_, defaults) = try makeStore(songAliases: "np, !Track, ")
        let reserved = BuiltInCommandCatalog.reservedTriggers(in: defaults)
        #expect(reserved["!song"] == "!song")
        #expect(reserved["!nowplaying"] == "!song")
        #expect(reserved["!np"] == "!song")
        #expect(reserved["!track"] == "!song")
        #expect(reserved["!sr"] == "!sr")
        #expect(reserved["!resume"] == "!hold")
        #expect(reserved["!hug"] == nil)
    }

    // MARK: - Editor validation

    @Test("a built-in trigger is refused under the trigger field")
    func builtInTriggerRefused() throws {
        let (store, _) = try makeStore()
        let issue = store.validationIssue(for: CustomCommand(trigger: "Song", response: "x"))
        #expect(issue == .reservedTrigger("!song", builtIn: "!song"))
        #expect(issue?.field(trigger: "!song") == .trigger)
        #expect(issue?.message == "!song is a built-in command. Pick another trigger.")
        #expect(issue?.isNeutralHint == false)

        #expect(store.validationIssue(for: CustomCommand(trigger: "queue", response: "x"))
            == .reservedTrigger("!queue", builtIn: "!queue"))
    }

    @Test("a built-in alias is refused under the aliases field, naming the built-in")
    func builtInAliasRefused() throws {
        let (store, _) = try makeStore(songAliases: "np")
        let custom = store.validationIssue(
            for: CustomCommand(trigger: "hug", response: "x", aliases: "np"))
        #expect(custom == .reservedTrigger("!np", builtIn: "!song"))
        #expect(custom?.field(trigger: "!hug") == .aliases)
        #expect(custom?.message == "!np is already used by the built-in !song.")

        let base = store.validationIssue(
            for: CustomCommand(trigger: "np2", response: "x", aliases: "request"))
        #expect(base == .reservedTrigger("!request", builtIn: "!sr"))
    }

    @Test("add refuses a built-in trigger and leaves the list unchanged")
    func addRefusesBuiltIn() throws {
        let (store, _) = try makeStore()
        #expect(!store.add(CustomCommand(trigger: "sr", response: "x")))
        #expect(store.commands.isEmpty)
        #expect(store.add(CustomCommand(trigger: "hug", response: "x")))
    }

    // MARK: - Stored and imported clashes

    @Test("load turns off a stored clash, keeps it, and persists the repair")
    func loadDisablesStoredClash() throws {
        let clash = CustomCommand(trigger: "!song", response: "mine")
        let aliasClash = CustomCommand(trigger: "!hug", response: "hi", aliases: "np")
        let clean = CustomCommand(trigger: "!wave", response: "o/")
        let (store, defaults) = try makeStore(seed: [clash, aliasClash, clean], songAliases: "np")

        #expect(store.commands.map(\.id) == [clash.id, aliasClash.id, clean.id])
        #expect(store.commands.map(\.enabled) == [false, false, true])
        #expect(store.commands[0].trigger == "!song")
        #expect(store.commands[1].aliases == "np")
        #expect(store.enabledCommands.map(\.id) == [clean.id])

        let persisted = try #require(defaults.data(forKey: AppConstants.UserDefaults.customCommands))
        #expect(try JSONCoders.default.decode([CustomCommand].self, from: persisted) == store.commands)

        // It can't be switched back on until the trigger changes.
        var reenabled = store.commands[0]
        reenabled.enabled = true
        #expect(!store.update(reenabled))
        reenabled.trigger = "mysong"
        #expect(store.update(reenabled))
        #expect(store.commands[0].enabled)
    }

    @Test("an imported clash is kept but switched off")
    func importDisablesClash() throws {
        let (store, _) = try makeStore()
        let clash = CustomCommand(trigger: "!skip", response: "nope")
        let clean = CustomCommand(trigger: "!wave", response: "o/")
        let data = try JSONCoders.defaultEncoder.encode([clash, clean])

        #expect(store.replaceFromImportedData(data))
        #expect(store.commands.map(\.enabled) == [false, true])
    }
}
