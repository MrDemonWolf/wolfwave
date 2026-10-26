//
//  SettingsNavigationTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-26.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
@testable import WolfWave

@MainActor
struct SettingsNavigationTests {
    @Test("Opening Settings survives a late scene subscriber and coalesces repeated requests")
    func pendingOpenIsConsumedOnce() {
        let navigation = SettingsNavigation()
        #expect(!navigation.consumeOpenRequest())
        navigation.requestOpen()
        navigation.requestOpen()
        #expect(navigation.isOpenRequested)
        #expect(navigation.consumeOpenRequest())
        #expect(!navigation.consumeOpenRequest())
        navigation.requestOpen()
        #expect(navigation.consumeOpenRequest())
    }
}
