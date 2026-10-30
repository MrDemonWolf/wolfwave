//
//  RetentionImpact.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-30.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// What switching History to a finite retention window would delete.
///
/// Built by ``ListeningHistoryService/retentionImpact(retentionDays:now:)`` and
/// read by the History & Stats retention picker, which asks before applying a
/// change that deletes anything. Counting the lifetime tally matters: a finite
/// window deletes it whole, so leaving Forever could erase the All time and
/// Top totals without a single detailed play being old enough to prompt.
///
/// Pure, so the confirmation copy is testable without SwiftUI.
nonisolated struct RetentionImpact: Equatable, Sendable {
    /// Detailed plays older than the new window's cutoff.
    let expiredPlays: Int
    /// Plays kept only in the lifetime tally (folded past the detailed-play
    /// cap), which feed All time and Top. Any finite window deletes them all.
    let lifetimeTallyPlays: Int

    /// Nothing would be deleted.
    static let empty = RetentionImpact(expiredPlays: 0, lifetimeTallyPlays: 0)

    /// Whether applying the change deletes anything, so it must confirm first.
    var deletesData: Bool { expiredPlays > 0 || lifetimeTallyPlays > 0 }

    /// Alert title for keeping `days` of history.
    func confirmationTitle(days: Int) -> String {
        if expiredPlays > 0 {
            return "Remove \(Self.plays(expiredPlays)) older than \(days) days?"
        }
        return "Drop \(Self.plays(lifetimeTallyPlays)) from All time and Top?"
    }

    /// Alert body for keeping `days` of history: what goes, in plain words.
    func confirmationMessage(days: Int) -> String {
        switch (expiredPlays > 0, lifetimeTallyPlays > 0) {
        case (true, true):
            return "These plays will be removed from history and statistics, and All time "
                + "and Top drop \(Self.plays(lifetimeTallyPlays)) more. Can't be undone."
        case (false, true):
            return "WolfWave keeps those older plays only as totals, and a \(days)-day "
                + "history removes them. Can't be undone."
        default:
            return "These plays will be removed from history and statistics. Can't be undone."
        }
    }

    /// "1 play" / "1,234 plays", grouped for the current locale.
    private static func plays(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "play" : "plays")"
    }
}
