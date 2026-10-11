//
//  SettingsNavRailGroupTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-11.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Testing
@testable import WolfWave

/// Pins `SettingsRailGroup`'s `ForEach` identity.
///
/// The rail used to key its groups by array offset, so reordering or inserting
/// a group handed an existing group's identity to a different one. The id is
/// now derived from the group's own content; these cases keep it unique,
/// stable, and independent of position. Nothing here touches process-global
/// state.
@MainActor
@Suite("SettingsNavRail group identity")
struct SettingsNavRailGroupTests {

    // MARK: - Fixtures

    private enum Section: String, CaseIterable, SettingsRailSection {
        case alpha, bravo, charlie, delta

        var title: String { rawValue.capitalized }
        var icon: String { "circle" }
    }

    // MARK: - Tests

    @Test("Titled groups get distinct ids")
    func titledGroupsAreDistinct() {
        let groups = [
            SettingsRailGroup(title: "One", sections: [Section.alpha, .bravo]),
            SettingsRailGroup(title: "Two", sections: [Section.charlie, .delta])
        ]
        #expect(Set(groups.map(\.id)).count == groups.count)
    }

    @Test("Untitled groups stay distinct through their first section")
    func untitledGroupsAreDistinct() {
        let groups = [
            SettingsRailGroup(sections: [Section.alpha, .bravo]),
            SettingsRailGroup(sections: [Section.charlie, .delta])
        ]
        #expect(Set(groups.map(\.id)).count == groups.count)
    }

    @Test("A group's id does not change when the groups are reordered")
    func idSurvivesReordering() {
        let first = SettingsRailGroup(title: "One", sections: [Section.alpha])
        let second = SettingsRailGroup(title: "Two", sections: [Section.bravo])
        let forward = [first, second].map(\.id)
        let reversed = [second, first].map(\.id)
        #expect(forward == reversed.reversed())
    }

    @Test("Rebuilding the same group yields the same id")
    func idIsDeterministic() {
        let a = SettingsRailGroup(title: "One", sections: [Section.alpha, .bravo])
        let b = SettingsRailGroup(title: "One", sections: [Section.alpha, .bravo])
        #expect(a.id == b.id)
    }
}
