//
//  BuiltInCommandCatalog.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-26.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// The chat triggers WolfWave's built-in commands answer to, so a custom
/// command can't claim one.
///
/// Custom commands are matched before the built-ins, so a custom `!song` (or a
/// custom alias equal to a built-in alias the streamer typed) would quietly
/// replace the built-in. ``CustomCommandStore`` checks drafts and stored
/// commands against ``reservedTriggers(in:)`` instead.
///
/// Kept in step with `BotCommandDispatcher.registerDefaultCommands()` by
/// `BuiltInCommandCatalogTests`.
nonisolated enum BuiltInCommandCatalog {

    /// One built-in command: its fixed triggers and the defaults key holding
    /// the streamer's extra aliases, if it has one.
    struct Entry: Sendable, Equatable {
        /// Base triggers. The first one names the command in messages.
        let triggers: [String]
        /// `UserDefaults` key for comma-separated aliases, or `nil`.
        let aliasesKey: String?
    }

    /// Every built-in command, in dispatcher registration order.
    static let entries: [Entry] = [
        Entry(triggers: ["!song", "!currentsong", "!nowplaying"],
              aliasesKey: AppConstants.UserDefaults.songCommandAliases),
        Entry(triggers: ["!last", "!lastsong", "!prevsong"],
              aliasesKey: AppConstants.UserDefaults.lastSongCommandAliases),
        Entry(triggers: ["!stats", "!musicstats"],
              aliasesKey: AppConstants.UserDefaults.statsCommandAliases),
        Entry(triggers: ["!wolfwave"],
              aliasesKey: AppConstants.UserDefaults.wolfwaveCommandAliases),
        Entry(triggers: ["!sr", "!request", "!songrequest"],
              aliasesKey: AppConstants.UserDefaults.srCommandAliases),
        Entry(triggers: ["!queue", "!songlist", "!requests"],
              aliasesKey: AppConstants.UserDefaults.queueCommandAliases),
        Entry(triggers: ["!myqueue", "!mysongs"],
              aliasesKey: AppConstants.UserDefaults.myQueueCommandAliases),
        Entry(triggers: ["!skip", "!next"],
              aliasesKey: AppConstants.UserDefaults.skipCommandAliases),
        Entry(triggers: ["!clearqueue", "!cq"],
              aliasesKey: AppConstants.UserDefaults.clearQueueCommandAliases),
        Entry(triggers: ["!hold", "!resume", "!unhold"],
              aliasesKey: nil),
        Entry(triggers: ["!voteskip", "!vs"],
              aliasesKey: AppConstants.UserDefaults.voteSkipCommandAliases),
        Entry(triggers: ["!playlist"],
              aliasesKey: AppConstants.UserDefaults.songListCommandAliases)
    ]

    /// Parses a built-in alias field: comma-separated, each entry trimmed,
    /// lowercased, and given a leading `!` when the streamer left it off.
    /// Empty entries are dropped. Shared with `BotCommand.allTriggers`.
    static func parseAliases(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("!") ? $0 : "!\($0)" }
    }

    /// Every token a built-in answers to, mapped to that built-in's primary
    /// trigger (e.g. `"!np"` → `"!song"`).
    ///
    /// Reserved whether or not the built-in is switched on, so turning it on
    /// later never makes a custom command stop answering. Aliases go through
    /// ``parseAliases(_:)``, like `BotCommand.allTriggers`, so the set matches
    /// what the dispatcher would match.
    ///
    /// - Parameter defaults: Where the built-in alias fields are stored.
    static func reservedTriggers(in defaults: UserDefaults) -> [String: String] {
        var reserved: [String: String] = [:]
        for entry in entries {
            guard let owner = entry.triggers.first else { continue }
            var tokens = entry.triggers
            if let key = entry.aliasesKey, let raw = defaults.string(forKey: key) {
                tokens += parseAliases(raw)
            }
            for token in tokens where reserved[token] == nil {
                reserved[token] = owner
            }
        }
        return reserved
    }
}
