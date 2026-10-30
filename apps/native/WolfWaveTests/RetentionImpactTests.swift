//
//  RetentionImpactTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-30.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation
@testable import WolfWave

/// The History retention confirmation: when it is needed, and that its copy names
/// the All time and Top totals whenever a finite window would delete them.
@Suite("Retention impact")
struct RetentionImpactTests {

    @Test("Nothing to delete needs no confirmation")
    func emptyImpactDeletesNothing() {
        #expect(!RetentionImpact.empty.deletesData)
        #expect(RetentionImpact(expiredPlays: 1, lifetimeTallyPlays: 0).deletesData)
        #expect(RetentionImpact(expiredPlays: 0, lifetimeTallyPlays: 1).deletesData)
    }

    @Test("The title leads with expired plays, else the totals", arguments: [
        (RetentionImpact(expiredPlays: 2, lifetimeTallyPlays: 0), "Remove 2 plays older than 7 days?"),
        (RetentionImpact(expiredPlays: 1, lifetimeTallyPlays: 5), "Remove 1 play older than 7 days?"),
        (RetentionImpact(expiredPlays: 0, lifetimeTallyPlays: 1), "Drop 1 play from All time and Top?")
    ])
    func title(impact: RetentionImpact, expected: String) {
        #expect(impact.confirmationTitle(days: 7) == expected)
    }

    @Test("Expired plays alone keep the original message")
    func expiredOnlyMessage() {
        let impact = RetentionImpact(expiredPlays: 2, lifetimeTallyPlays: 0)
        #expect(impact.confirmationMessage(days: 7)
            == "These plays will be removed from history and statistics. Can't be undone.")
    }

    @Test("A tally with no expired plays explains why the totals go")
    func tallyOnlyMessage() {
        let message = RetentionImpact(expiredPlays: 0, lifetimeTallyPlays: 1).confirmationMessage(days: 30)
        #expect(message.contains("only as totals"))
        #expect(message.contains("a 30-day history removes them"))
        #expect(message.hasSuffix("Can't be undone."))
    }

    @Test("Expired plays and a tally mention both, with a grouped count")
    func expiredAndTallyMessage() {
        let message = RetentionImpact(expiredPlays: 1, lifetimeTallyPlays: 1_234).confirmationMessage(days: 90)
        #expect(message.hasPrefix("These plays will be removed from history and statistics"))
        #expect(message.contains("All time and Top drop \(1_234.formatted()) plays more"))
        #expect(message.hasSuffix("Can't be undone."))
    }
}
