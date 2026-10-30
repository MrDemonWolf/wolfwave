//
//  BotCommandDispatcher.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-01-08.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

// MARK: - CommandReply

/// A command's rendered response plus how it should reach chat.
///
/// `TwitchChatService+EventSub` routes on `delivery`: `.announce` goes through
/// the Helix announcements endpoint, the rest through Send Chat Message.
nonisolated struct CommandReply: Sendable, Equatable {
    let text: String
    let delivery: ReplyDelivery
}

// MARK: - Preflight Denial

/// Why a command refused a caller before the dispatcher reserved its cooldown.
nonisolated enum PreflightDenial: Sendable, Equatable {
    /// Refuse without replying.
    case silent
    /// Refuse with this chat reply. The dispatcher throttles it per user, on a
    /// key separate from the command's own cooldown.
    case reply(String)
}

/// A command that can refuse a caller before the dispatcher claims its cooldown.
///
/// `isAllowed(context:)` refuses silently. This hook can also answer chat
/// ("Song requests are subscriber-only right now.") while leaving the
/// command's shared global and per-user cooldown free for allowed viewers.
protocol PreflightCheckedCommand: BotCommand {
    /// Returns a denial when `context` must not run the command right now, or
    /// `nil` to let the dispatcher claim the cooldown and execute.
    func preflightDenial(context: BotCommandContext) -> PreflightDenial?
}

/// A song-request chat command that stays silent while the Song Requests
/// master switch is off.
///
/// The default ``preflightDenial(context:)`` refuses before the dispatcher
/// claims a cooldown, so a moderator's `!skip` can't start the fallback
/// playlist, `!resume` can't start playback, and `!queue` can't answer for a
/// feature the streamer turned off. `!sr` keeps its own check, because it also
/// gates the audience and can reply.
protocol SongRequestGatedCommand: PreflightCheckedCommand {}

extension SongRequestGatedCommand {
    /// A silent refusal while song requests are off, else `nil`.
    func preflightDenial(context: BotCommandContext) -> PreflightDenial? {
        FeatureFlags.songRequestEnabled ? nil : .silent
    }
}

/// Routes chat messages to appropriate bot command handlers.
///
/// The full built-in command suite is registered automatically at init (see
/// `registerDefaultCommands`). Includes cooldown enforcement with moderator bypass.
/// MainActor-isolated (project default isolation); the `NSLock` is retained as a
/// defense-in-depth guard around the command table.
///
/// Matching: the first whitespace-delimited token of a message must equal a
/// trigger exactly (case-insensitive). Commands are tried in table order
/// (custom commands, then built-ins in registration order), and the first
/// enabled, permitted match that replies wins.
final class BotCommandDispatcher {

    // MARK: - Properties

    /// Guards `commands`, `globalGate`, `customCommandVariables`, and the
    /// closures wired into the built-in commands.
    private let lock = NSLock()
    /// Registered built-in commands, in match order.
    private var commands: [BotCommand] = []

    /// Global pre-flight gate evaluated before any command runs. Returns `true`
    /// when commands are allowed to respond. Wired by `TwitchChatService` to the
    /// "commands only while live" setting folded with stream-live state. Default
    /// `{ true }` so a bare dispatcher (and unit tests) respond unconditionally.
    private var globalGate: () -> Bool = { true }

    /// Fetches live substitution values for custom-command variables (`$song`,
    /// `$lastsong`). Wired by `TwitchChatService`; defaults to empty strings so a
    /// bare dispatcher still renders custom commands (just without live values).
    private var customCommandVariables: @Sendable () async -> CustomCommandVariables = { .empty }
    /// `!song` / `!currentsong` / `!nowplaying`.
    private let songCommand = TrackInfoCommand(
        triggers: ["!song", "!currentsong", "!nowplaying"],
        description: "Displays the currently playing track",
        defaultMessage: "No track currently playing",
        globalCooldownKey: AppConstants.UserDefaults.songCommandGlobalCooldown,
        userCooldownKey: AppConstants.UserDefaults.songCommandUserCooldown,
        aliasesKey: AppConstants.UserDefaults.songCommandAliases
    )
    /// `!last` / `!lastsong` / `!prevsong`.
    private let lastSongCommand = TrackInfoCommand(
        triggers: ["!last", "!lastsong", "!prevsong"],
        description: "Displays the last played track",
        defaultMessage: "No previous track available",
        globalCooldownKey: AppConstants.UserDefaults.lastSongCommandGlobalCooldown,
        userCooldownKey: AppConstants.UserDefaults.lastSongCommandUserCooldown,
        aliasesKey: AppConstants.UserDefaults.lastSongCommandAliases
    )
    /// `!stats` / `!musicstats`. Enabled state comes from the callback wired by
    /// `setStatsCommandEnabled(callback:)`; like every command it only waits
    /// for a live stream when "Only reply while live" (`globalGate`) is on.
    private let statsCommand = TrackInfoCommand(
        triggers: ["!stats", "!musicstats"],
        description: "Displays your listening stats",
        defaultMessage: "No listening stats yet",
        globalCooldownKey: AppConstants.UserDefaults.statsCommandGlobalCooldown,
        userCooldownKey: AppConstants.UserDefaults.statsCommandUserCooldown,
        aliasesKey: AppConstants.UserDefaults.statsCommandAliases
    )
    /// `!wolfwave`: static info reply in the user's chosen style.
    private let wolfwaveCommand = InfoCommand(
        triggers: ["!wolfwave"],
        description: "Shows what WolfWave is and where to get it",
        enabledDefaultsKey: AppConstants.UserDefaults.wolfwaveCommandEnabled,
        globalCooldownKey: AppConstants.UserDefaults.wolfwaveCommandGlobalCooldown,
        userCooldownKey: AppConstants.UserDefaults.wolfwaveCommandUserCooldown,
        aliasesKey: AppConstants.UserDefaults.wolfwaveCommandAliases,
        messageProvider: { WolfWaveReplyStyle.current().message }
    )
    /// Shared cooldown ledger for every command, plus the `#denied` refusal keys.
    private let cooldownManager = CooldownManager()

    // Song request commands. Their late-bound services are wired via the
    // setters below.
    let srCommand = SongRequestCommand()
    let queueCommand = QueueCommand()
    let myQueueCommand = MyQueueCommand()
    let skipCommand = SkipCommand()
    let clearQueueCommand = ClearQueueCommand()
    let holdCommand = HoldCommand()
    let voteSkipCommand = VoteSkipCommand()
    let songListCommand = SongListCommand()

    // MARK: - Lifecycle

    /// Creates a dispatcher pre-loaded with every built-in command.
    init() {
        registerDefaultCommands()
    }

    /// Registers the built-in command suite (`!song`, `!last`, `!stats`,
    /// `!wolfwave`, `!sr`, `!queue`, `!myqueue`, `!skip`, `!clearqueue`,
    /// `!hold`, `!voteskip`, `!playlist`). Called once from `init`.
    private func registerDefaultCommands() {
        register(songCommand)
        register(lastSongCommand)
        register(statsCommand)
        register(wolfwaveCommand)
        register(srCommand)
        register(queueCommand)
        register(myQueueCommand)
        register(skipCommand)
        register(clearQueueCommand)
        register(holdCommand)
        register(voteSkipCommand)
        register(songListCommand)
    }

    // MARK: - Registration & Wiring

    /// Adds a `BotCommand` to the dispatch table. Thread-safe.
    ///
    /// - Parameter command: Command instance, appended to the end of the
    ///   table. Duplicate triggers are not detected; matching walks the table
    ///   in order, so the earlier-registered command wins unless it is
    ///   disabled, denies the caller, or returns no reply.
    func register(_ command: BotCommand) {
        lock.withLock {
            commands.append(command)
        }
    }

    /// The registered built-in commands, in match order. Read by
    /// `BuiltInCommandCatalogTests` to keep ``BuiltInCommandCatalog`` in step.
    var builtInCommands: [BotCommand] {
        lock.withLock { commands }
    }

    /// Wires the enabled-state provider for the `!song` command.
    ///
    /// - Parameter callback: Closure returning `true` if `!song` should respond.
    func setCurrentSongCommandEnabled(callback: @escaping () -> Bool) {
        lock.withLock {
            songCommand.isEnabled = callback
        }
    }

    /// Wires the enabled-state provider for the `!last` command.
    ///
    /// - Parameter callback: Closure returning `true` if `!last` should respond.
    func setLastSongCommandEnabled(callback: @escaping () -> Bool) {
        lock.withLock {
            lastSongCommand.isEnabled = callback
        }
    }

    // MARK: - Async Provider Wiring

    /// Wires the async `!song` provider. Awaited by `processMessageReplyAsync`;
    /// bridges MainActor-isolated AppDelegate state without the deprecated
    /// `runSync` semaphore that previously deadlocked MainActor.
    func setCurrentSongInfoAsync(callback: @Sendable @escaping () async -> String) {
        lock.withLock {
            songCommand.getTrackInfoAsync = callback
        }
    }

    /// Wires the async `!last` provider. See `setCurrentSongInfoAsync` for the
    /// deadlock rationale.
    func setLastSongInfoAsync(callback: @Sendable @escaping () async -> String) {
        lock.withLock {
            lastSongCommand.getTrackInfoAsync = callback
        }
    }

    /// Wires the async `!stats` provider. See `setCurrentSongInfoAsync` for the
    /// deadlock rationale.
    func setStatsInfoAsync(callback: @Sendable @escaping () async -> String) {
        lock.withLock {
            statsCommand.getTrackInfoAsync = callback
        }
    }

    /// Wires the enabled-state provider for the `!stats` command.
    ///
    /// - Parameter callback: Closure returning `true` if `!stats` should respond
    ///   (Stats feature on and command on). Live-only replies are the global
    ///   gate's job, not this callback's.
    func setStatsCommandEnabled(callback: @escaping () -> Bool) {
        lock.withLock {
            statsCommand.isEnabled = callback
        }
    }

    // MARK: - Song Request Command Wiring

    /// Injects the live `SongRequestService` reference into every command
    /// that mutates the queue (`!sr`, `!skip`, `!clearqueue`, `!hold`).
    func setSongRequestService(callback: @escaping () -> SongRequestService?) {
        lock.withLock {
            srCommand.songRequestService = callback
            skipCommand.songRequestService = callback
            clearQueueCommand.songRequestService = callback
            holdCommand.songRequestService = callback
        }
    }

    /// Injects the live `SongRequestQueue` reference into every read-only
    /// queue command (`!queue`, `!myqueue`).
    func setSongRequestQueue(callback: @escaping () -> SongRequestQueue?) {
        lock.withLock {
            queueCommand.getQueue = callback
            myQueueCommand.getQueue = callback
        }
    }

    /// Injects the live `SkipVoteManager` reference into the `!voteskip` command.
    func setSkipVoteManager(callback: @escaping () -> SkipVoteManager?) {
        lock.withLock {
            voteSkipCommand.skipVoteManager = callback
        }
    }

    /// Wires the global pre-flight gate (the "commands only while live" switch).
    ///
    /// - Parameter callback: Closure returning `true` when commands may respond.
    ///   Evaluated once per message before trigger matching, so toggling the
    ///   setting or going live/offline takes effect on the next message.
    func setGlobalGate(callback: @escaping () -> Bool) {
        lock.withLock {
            globalGate = callback
        }
    }

    /// Wires the live-value provider for custom-command variables.
    ///
    /// - Parameter provider: Async closure returning the current/last song used
    ///   to interpolate `$song` / `$lastsong` in custom command replies.
    func setCustomCommandVariablesProvider(
        _ provider: @escaping @Sendable () async -> CustomCommandVariables
    ) {
        lock.withLock {
            customCommandVariables = provider
        }
    }

    /// The full command table for a message: the user's enabled custom commands
    /// first, then the built-in commands. Rebuilt each message so edits in
    /// Settings apply on the next chat line without re-registration.
    ///
    /// `CustomCommandStore` keeps custom commands off every built-in trigger and
    /// alias (`BuiltInCommandCatalog`), so the order only matters for a clash
    /// created after load, such as a built-in alias added that a custom command
    /// already uses. That clash is turned off on the next launch.
    private func commandSnapshot() -> [BotCommand] {
        let builtins = lock.withLock { commands }
        let vars = lock.withLock { customCommandVariables }
        let custom = CustomCommandStore.shared.enabledCommands.map {
            CustomBotCommand(definition: $0, variables: vars)
        }
        return custom + builtins
    }

    // MARK: - Dispatch

    /// `processMessageReplyAsync` without the delivery mode. Test convenience:
    /// production calls `processMessageReplyAsync` directly, so this exercises the
    /// exact path chat messages take.
    func processMessageAsync(
        _ message: String,
        userID: String = "",
        isModerator: Bool = false,
        context: BotCommandContext?
    ) async -> String? {
        await processMessageReplyAsync(message, userID: userID, isModerator: isModerator, context: context)?.text
    }

    /// Production chat-message path. Awaits `TrackInfoCommand.executeAsync`, so
    /// async providers (`setCurrentSongInfoAsync`, etc.) can reach
    /// MainActor-isolated app state without the deprecated `runSync` semaphore
    /// bridge, and reports how the matched command wants its response delivered
    /// (reply / plain message / announcement).
    ///
    /// The cooldown slot is claimed atomically (`CooldownManager.tryClaim`)
    /// before any `await`. The dispatcher is MainActor-isolated, so each await
    /// is a reentrancy point: checking first and recording only after the await
    /// let a burst of concurrent `!song` messages all pass the check and all
    /// reply. A claimed slot is released again when a sync or track-info
    /// command produces no reply, so a silent command never warms the
    /// cooldown. Async commands keep the slot (see the inline note).
    ///
    /// - Parameters:
    ///   - message: The raw chat line. Lines that are empty after trimming or
    ///     longer than `AppConstants.Twitch.maxMessageLength` are ignored.
    ///   - userID: Sender ID used for the per-user cooldown key.
    ///   - isModerator: Whether the sender bypasses cooldowns. Passed
    ///     separately from `context` so context-less callers can still set it.
    ///   - context: Sender details. `nil` skips permission and preflight
    ///     checks and makes async commands unreachable.
    /// - Returns: The reply and its delivery mode, or `nil` to stay silent.
    func processMessageReplyAsync(
        _ message: String,
        userID: String = "",
        isModerator: Bool = false,
        context: BotCommandContext?
    ) async -> CommandReply? {
        guard !Task.isCancelled else { return nil }
        Log.debug("BotCommandDispatcher: processMessageAsync enter msg=\(message.prefix(40))", category: .twitchChat)
        let trimmedMessage = message.trimmingCharacters(in: .whitespaces)

        guard !trimmedMessage.isEmpty, trimmedMessage.count <= AppConstants.Twitch.maxMessageLength else {
            Log.debug("BotCommandDispatcher: processMessageAsync: empty/too-long, bail", category: .twitchChat)
            return nil
        }

        // Global pre-flight gate ("commands only while live"). Closed → every
        // command stays silent regardless of its own enable state.
        let gate = lock.withLock { globalGate }
        guard gate() else {
            Log.debug(
                "BotCommandDispatcher: global gate closed (live-only, stream offline), bail",
                category: .twitchChat)
            return nil
        }

        let lowered = trimmedMessage.lowercased()
        // First-token equality, not `hasPrefix`, so `!songs` can't fire `!song`
        // and an alias can't collide with a longer trigger.
        let commandToken = lowered.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? lowered

        // Triggers are all "!"-prefixed, so skip the snapshot copy + alias
        // reads for non-command lines (the vast majority of chat).
        guard commandToken.hasPrefix("!") else { return nil }

        let snapshot = commandSnapshot()
        for command in snapshot {
            let triggers = command.allTriggers
            for trigger in triggers {
                let triggerLowered = trigger.lowercased()
                if commandToken == triggerLowered {
                    Log.debug("BotCommandDispatcher: matched trigger \(trigger)", category: .twitchChat)
                    // `break` (not `return nil`) so a disabled/denied command
                    // falls through to another match on the same trigger (e.g. a
                    // disabled custom command → its shadowed built-in).
                    guard command.isCommandEnabled else {
                        Log.debug(
                            "BotCommandDispatcher: command \(trigger) disabled, try next match",
                            category: .twitchChat)
                        break
                    }

                    if let context, !command.isAllowed(context: context) {
                        Log.debug(
                            "BotCommandDispatcher: command \(trigger) denied by permission, try next match",
                            category: .twitchChat)
                        break
                    }

                    // Cooldowns key on the first base trigger, so `!song` and
                    // `!nowplaying` share one cooldown.
                    let canonical = command.triggers.first ?? trigger
                    let (globalCD, userCD) = cooldownValues(for: command)

                    // Refusals that still reply (audience, feature off) are
                    // decided before the claim, so a refused viewer never warms
                    // the cooldown the allowed viewers share.
                    if let context,
                       let checked = command as? PreflightCheckedCommand,
                       let denial = checked.preflightDenial(context: context) {
                        Log.debug(
                            "BotCommandDispatcher: command \(trigger) refused before cooldown",
                            category: .twitchChat)
                        return denialReply(
                            denial,
                            canonical: canonical,
                            userID: userID,
                            isModerator: isModerator,
                            globalCooldown: globalCD,
                            userCooldown: userCD,
                            delivery: command.delivery)
                    }

                    guard let claim = cooldownManager.tryClaim(
                        trigger: canonical,
                        userID: userID,
                        isModerator: isModerator,
                        bypassesCooldown: command.bypassesCooldown(context: context),
                        globalCooldown: globalCD,
                        userCooldown: userCD
                    ) else {
                        let remaining = cooldownManager.remainingCooldown(
                            trigger: canonical,
                            userID: userID,
                            globalCooldown: globalCD,
                            userCooldown: userCD
                        )
                        Log.debug(
                            "BotCommandDispatcher: Command '\(trigger)' (group: \(canonical)) on cooldown for user \(userID), global: \(String(format: "%.1f", remaining.global))s remaining, per-user: \(String(format: "%.1f", remaining.perUser))s remaining",
                            category: .twitchChat)
                        return nil
                    }

                    // Without a context an async command falls to the sync
                    // shim below, which returns nil (slot released, try next match).
                    if let asyncCommand = command as? AsyncBotCommand, let ctx = context {
                        guard !Task.isCancelled else {
                            cooldownManager.release(claim)
                            return nil
                        }
                        // Async commands keep the slot even when they return nil:
                        // they may already have acted (queued, skipped) before
                        // deciding to stay silent.
                        let response = await asyncCommand.execute(message: trimmedMessage, context: ctx)
                        guard !Task.isCancelled else { return nil }
                        Log.debug(
                            "BotCommandDispatcher: Async command \(trigger) completed (group: \(canonical))",
                            category: .twitchChat)
                        return response.map { CommandReply(text: $0, delivery: command.delivery) }
                    }

                    let response: String?
                    if let track = command as? TrackInfoCommand {
                        guard !Task.isCancelled else {
                            cooldownManager.release(claim)
                            return nil
                        }
                        Log.debug(
                            "BotCommandDispatcher: TrackInfoCommand.executeAsync start \(trigger)",
                            category: .twitchChat)
                        let trackResponse = await track.executeAsync(message: trimmedMessage)
                        Log.debug(
                            "BotCommandDispatcher: TrackInfoCommand.executeAsync done",
                            category: .twitchChat,
                            fields: [
                                "trigger": trigger,
                                "response": trackResponse?.prefix(40) ?? "nil"
                            ])
                        guard !Task.isCancelled else {
                            cooldownManager.release(claim)
                            return nil
                        }
                        response = trackResponse
                    } else {
                        response = command.execute(message: trimmedMessage)
                    }

                    if let response {
                        Log.debug(
                            "BotCommandDispatcher: Command '\(trigger)' (group: \(canonical)) executed, cooldown set: global=\(String(format: "%.1f", globalCD))s, per-user=\(String(format: "%.1f", userCD))s",
                            category: .twitchChat)
                        return CommandReply(text: response, delivery: command.delivery)
                    }
                    // Silent sync command: give the slot back and let a later
                    // command with the same trigger have a go.
                    cooldownManager.release(claim)
                    break
                }
            }
        }

        return nil
    }

    // MARK: - Private Helpers

    /// Suffix for the per-user key that throttles preflight denial replies.
    private static let denialThrottleSuffix = "#denied"

    /// Shortest gap between two denial replies to the same viewer, so a viewer
    /// with no permission can't make the bot flood chat even when the
    /// command's own per-user cooldown is set to 0.
    private static let minimumDenialReplyInterval: TimeInterval = 10

    /// Shortest gap between two denial replies channel-wide. Without it, a
    /// raid of distinct viewers each typing a refused command gets one reply
    /// apiece and pushes the bot into Twitch's send rate limit.
    private static let minimumDenialGlobalInterval: TimeInterval = 5

    /// Turns a preflight denial into the reply to send, if any.
    ///
    /// The throttle windows are the command's own cooldowns floored at
    /// ``minimumDenialGlobalInterval`` / ``minimumDenialReplyInterval``.
    /// Moderators bypass the throttle like any cooldown.
    ///
    /// - Returns: The refusal reply, or `nil` for `.silent` or while throttled.
    ///
    /// The reply is throttled per user and globally on its own key (`<trigger>#denied`), never
    /// on the command's cooldown, so the refusal neither starts nor extends the
    /// cooldown allowed viewers wait on.
    private func denialReply(
        _ denial: PreflightDenial,
        canonical: String,
        userID: String,
        isModerator: Bool,
        globalCooldown: TimeInterval,
        userCooldown: TimeInterval,
        delivery: ReplyDelivery
    ) -> CommandReply? {
        guard case .reply(let text) = denial else { return nil }
        // Its own key, so throttling refusals never touches the cooldown the
        // allowed viewers share; but it is throttled globally as well as per
        // viewer, so the refusal stream is capped channel-wide.
        let claim = cooldownManager.tryClaim(
            trigger: canonical + Self.denialThrottleSuffix,
            userID: userID,
            isModerator: isModerator,
            globalCooldown: max(globalCooldown, Self.minimumDenialGlobalInterval),
            userCooldown: max(userCooldown, Self.minimumDenialReplyInterval)
        )
        guard claim != nil else { return nil }
        return CommandReply(text: text, delivery: delivery)
    }

    /// Returns the effective cooldown values for a command, checking UserDefaults overrides.
    ///
    /// Commands declare their own UserDefaults keys via `globalCooldownKey`/`userCooldownKey`.
    /// If a key is nil or the stored value is absent, the command's default is used.
    private func cooldownValues(for command: BotCommand) -> (TimeInterval, TimeInterval) {
        let defaults = DefaultsStore.store
        let globalCD = command.globalCooldownKey
            .flatMap { defaults.object(forKey: $0) as? TimeInterval }
            ?? command.globalCooldown
        let userCD = command.userCooldownKey
            .flatMap { defaults.object(forKey: $0) as? TimeInterval }
            ?? command.userCooldown
        return (globalCD, userCD)
    }
}
