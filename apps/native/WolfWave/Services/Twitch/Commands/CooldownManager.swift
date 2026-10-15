//
//  CooldownManager.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-02-20.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

// MARK: - Cooldown Claim

/// A cooldown slot taken by `CooldownManager.tryClaim`.
///
/// Carries the timestamps the claim overwrote so `CooldownManager.release` can
/// put them back when the command ends up producing no reply.
nonisolated struct CooldownClaim: Sendable, Equatable {
    /// Canonical command trigger the slot belongs to.
    let trigger: String
    /// Per-user cooldown key (`"userID:trigger"`).
    let userKey: String
    /// Global timestamp in place before the claim, or `nil` if there was none.
    let previousGlobal: Date?
    /// Per-user timestamp in place before the claim, or `nil` if there was none.
    let previousUser: Date?
    /// Timestamp the claim wrote to both maps.
    let claimedAt: Date
}

// MARK: - Cooldown Manager

/// Manages global and per-user cooldowns for bot commands.
///
/// Tracks last-use timestamps per command (global) and per user+command to prevent
/// command spam in Twitch chat. Moderators can bypass cooldowns.
///
/// MainActor-isolated (project default isolation). The `NSLock` is retained as a
/// defense-in-depth guard around the timestamp dictionaries.
final class CooldownManager {

    // MARK: - Properties

    /// Maximum number of per-user cooldown entries kept at any one time.
    /// Exceeding this causes the oldest half to be evicted, capping memory use
    /// even in long streams with many unique chatters.
    private let maxUserCooldownEntries = 2000

    /// Global cooldowns: key = command trigger, value = last use timestamp.
    private var globalCooldowns: [String: Date] = [:]

    /// Per-user cooldowns: key = "userID:trigger", value = last use timestamp.
    private var userCooldowns: [String: Date] = [:]

    /// Longest cooldown window (seconds) any caller has asked about so far.
    /// Pruning keeps every entry younger than this, so an entry is only
    /// forgotten once no cooldown in force could still need it.
    private var longestCooldownInForce: TimeInterval = 0

    /// Lock protecting all cooldown state.
    private let lock = NSLock()

    /// Clock seam; tests inject a controllable one.
    private let now: () -> Date

    // MARK: - Initialization

    /// - Parameter now: Current-time source. Defaults to the system clock.
    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    // MARK: - Public API

    /// Checks whether a command is on cooldown for the given context.
    ///
    /// - Parameters:
    ///   - trigger: The command trigger string (e.g., "!song").
    ///   - userID: The Twitch user ID of the caller.
    ///   - isModerator: Whether the user has moderator badge (bypasses cooldowns).
    ///   - bypassesCooldown: Whether the caller earned a cooldown bypass (e.g. the
    ///     Sub/VIP song-request perk). Treated the same as a moderator bypass.
    ///   - globalCooldown: Global cooldown duration in seconds (0 = disabled).
    ///   - userCooldown: Per-user cooldown duration in seconds (0 = disabled).
    /// - Returns: `true` if the command is on cooldown and should be skipped.
    func isOnCooldown(
        trigger: String,
        userID: String,
        isModerator: Bool,
        bypassesCooldown: Bool = false,
        globalCooldown: TimeInterval,
        userCooldown: TimeInterval
    ) -> Bool {
        // Moderators and perk-bypassers skip all cooldowns
        if isModerator || bypassesCooldown { return false }

        let now = self.now()

        return lock.withLock {
            noteCooldownsLocked(globalCooldown, userCooldown)
            return isCoolingDownLocked(
                trigger: trigger,
                userKey: Self.userKey(userID: userID, trigger: trigger),
                globalCooldown: globalCooldown,
                userCooldown: userCooldown,
                now: now
            )
        }
    }

    /// Checks the cooldown and, when it is free, records the use, as one atomic step.
    ///
    /// Use this instead of `isOnCooldown` + `recordUse` whenever the command
    /// suspends between the two. Checking first and recording after an `await`
    /// lets every message that arrives during the suspension pass the check.
    /// Moderators and perk-bypassers skip the check but are still recorded, the
    /// same as `recordUse` after a bypassed `isOnCooldown`.
    ///
    /// - Parameters:
    ///   - trigger: The command trigger string (canonical key).
    ///   - userID: The Twitch user ID of the caller.
    ///   - isModerator: Whether the user has moderator badge (skips the check).
    ///   - bypassesCooldown: Whether the caller earned a cooldown bypass.
    ///   - globalCooldown: Global cooldown duration in seconds (0 = disabled).
    ///   - userCooldown: Per-user cooldown duration in seconds (0 = disabled).
    /// - Returns: The claim to hand to `release` if the command ends up silent,
    ///   or `nil` when the command is on cooldown and should be skipped.
    func tryClaim(
        trigger: String,
        userID: String,
        isModerator: Bool,
        bypassesCooldown: Bool = false,
        globalCooldown: TimeInterval,
        userCooldown: TimeInterval
    ) -> CooldownClaim? {
        let now = self.now()
        let userKey = Self.userKey(userID: userID, trigger: trigger)
        let bypass = isModerator || bypassesCooldown

        return lock.withLock {
            noteCooldownsLocked(globalCooldown, userCooldown)
            if !bypass, isCoolingDownLocked(
                trigger: trigger,
                userKey: userKey,
                globalCooldown: globalCooldown,
                userCooldown: userCooldown,
                now: now
            ) {
                return nil
            }

            let claim = CooldownClaim(
                trigger: trigger,
                userKey: userKey,
                previousGlobal: globalCooldowns[trigger],
                previousUser: userCooldowns[userKey],
                claimedAt: now
            )
            globalCooldowns[trigger] = now
            userCooldowns[userKey] = now
            pruneExpiredCooldownsIfNeeded()
            return claim
        }
    }

    /// Gives back a slot taken by `tryClaim`, restoring the timestamps it replaced.
    ///
    /// Each map is restored only while it still holds this claim's timestamp, so
    /// a later claim that overwrote the slot in the meantime is left intact.
    ///
    /// - Parameter claim: The value `tryClaim` returned.
    func release(_ claim: CooldownClaim) {
        lock.withLock {
            if globalCooldowns[claim.trigger] == claim.claimedAt {
                globalCooldowns[claim.trigger] = claim.previousGlobal
            }
            if userCooldowns[claim.userKey] == claim.claimedAt {
                userCooldowns[claim.userKey] = claim.previousUser
            }
        }
    }

    /// Records a command use for cooldown tracking.
    ///
    /// Non-atomic with `isOnCooldown`; the dispatcher uses `tryClaim` instead.
    ///
    /// - Parameters:
    ///   - trigger: The command trigger string.
    ///   - userID: The Twitch user ID of the caller.
    func recordUse(trigger: String, userID: String) {
        let now = self.now()
        let userKey = Self.userKey(userID: userID, trigger: trigger)

        lock.withLock {
            globalCooldowns[trigger] = now
            userCooldowns[userKey] = now
            pruneExpiredCooldownsIfNeeded()
        }
    }

    // MARK: - Private Helpers

    /// Per-user cooldown dictionary key.
    private static func userKey(userID: String, trigger: String) -> String {
        "\(userID):\(trigger)"
    }

    /// Raises ``longestCooldownInForce`` to cover the given windows. Must be
    /// called while holding `lock`. Non-finite values are ignored.
    private func noteCooldownsLocked(_ windows: TimeInterval...) {
        for window in windows where window.isFinite && window > longestCooldownInForce {
            longestCooldownInForce = window
        }
    }

    /// Whether either cooldown window is still open. Must be called while holding `lock`.
    private func isCoolingDownLocked(
        trigger: String,
        userKey: String,
        globalCooldown: TimeInterval,
        userCooldown: TimeInterval,
        now: Date
    ) -> Bool {
        if globalCooldown > 0, let lastGlobal = globalCooldowns[trigger],
           now.timeIntervalSince(lastGlobal) < globalCooldown {
            return true
        }
        if userCooldown > 0, let lastUser = userCooldowns[userKey],
           now.timeIntervalSince(lastUser) < userCooldown {
            return true
        }
        return false
    }

    /// Prunes per-user cooldown entries to prevent unbounded memory growth.
    ///
    /// Two-pass strategy (must be called while holding `lock`):
    /// Runs only once there are more than 100 per-user entries, so short
    /// streams never pay for the filter.
    /// 1. Remove entries older than ``longestCooldownInForce``, the longest
    ///    cooldown any caller has checked against. No such entry can still
    ///    block a command. Global entries are pruned the same way.
    /// 2. If the dictionary still exceeds `maxUserCooldownEntries` after the
    ///    time-based pass (i.e. many chatters are still within their cooldown
    ///    window), evict the oldest half so the dictionary cannot grow without
    ///    bound over a long stream.
    private func pruneExpiredCooldownsIfNeeded() {
        guard userCooldowns.count > 100 else { return }
        let cutoff = now().addingTimeInterval(-longestCooldownInForce)
        userCooldowns = userCooldowns.filter { $0.value > cutoff }
        globalCooldowns = globalCooldowns.filter { $0.value > cutoff }

        // Hard cap: evict the oldest half when fresh entries alone exceed the limit.
        if userCooldowns.count > maxUserCooldownEntries {
            let sorted = userCooldowns.sorted { $0.value < $1.value }
            let keepFrom = sorted.count / 2
            userCooldowns = Dictionary(uniqueKeysWithValues: sorted[keepFrom...].map { ($0.key, $0.value) })
        }
    }

    /// Returns remaining cooldown times for debug logging.
    ///
    /// - Parameters:
    ///   - trigger: The command trigger string (canonical key).
    ///   - userID: The Twitch user ID of the caller.
    ///   - globalCooldown: Global cooldown duration in seconds.
    ///   - userCooldown: Per-user cooldown duration in seconds.
    /// - Returns: Tuple of remaining global and per-user cooldown seconds.
    func remainingCooldown(
        trigger: String,
        userID: String,
        globalCooldown: TimeInterval,
        userCooldown: TimeInterval
    ) -> (global: TimeInterval, perUser: TimeInterval) {
        let now = self.now()
        return lock.withLock {
            let globalRemaining: TimeInterval
            if globalCooldown > 0, let lastGlobal = globalCooldowns[trigger] {
                globalRemaining = max(0, globalCooldown - now.timeIntervalSince(lastGlobal))
            } else {
                globalRemaining = 0
            }

            let perUserRemaining: TimeInterval
            if userCooldown > 0, let lastUser = userCooldowns[Self.userKey(userID: userID, trigger: trigger)] {
                perUserRemaining = max(0, userCooldown - now.timeIntervalSince(lastUser))
            } else {
                perUserRemaining = 0
            }

            return (globalRemaining, perUserRemaining)
        }
    }

    /// Clears all cooldown state. Not wired to any production event today
    /// (cooldowns survive a reconnect); kept for tests that need a clean slate.
    func reset() {
        lock.withLock {
            globalCooldowns.removeAll()
            userCooldowns.removeAll()
        }
    }
}
