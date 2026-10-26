//
//  FreshInstallDefaultsTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-26.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Testing
@testable import WolfWave

/// Pins the "don't surprise existing users" rule: day-one values reach fresh
/// installs only, and an upgrade keeps exactly what it already had.
///
/// Every test owns a `ThrowawayDefaults` suite, so none touch
/// `DefaultsStore.store` or the shared-state lock.
struct FreshInstallDefaultsTests {

    private typealias Keys = AppConstants.UserDefaults

    /// Runs `body` against a fresh, empty throwaway store, then deletes it.
    private func withStore(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = ThrowawayDefaults("FreshInstallDefaultsTests")
        defer { suite.destroy() }
        try body(suite.defaults)
    }

    @Test("A fresh install gets !song and !last on")
    func freshInstallGetsDayOneValues() {
        withStore { store in
            FreshInstallDefaults.apply(to: store)

            #expect(store.object(forKey: Keys.currentSongCommandEnabled) as? Bool == true)
            #expect(store.object(forKey: Keys.lastSongCommandEnabled) as? Bool == true)
            #expect(store.integer(forKey: Keys.freshInstallDefaultsVersion) == FreshInstallDefaults.version)
        }
    }

    @Test("An install that finished onboarding keeps its old values, written explicitly")
    func existingInstallIsPinned() {
        withStore { store in
            store.set(true, forKey: Keys.hasCompletedOnboarding)
            FreshInstallDefaults.apply(to: store)

            #expect(store.object(forKey: Keys.currentSongCommandEnabled) as? Bool == false)
            #expect(store.object(forKey: Keys.lastSongCommandEnabled) as? Bool == false)
        }
    }

    @Test("A saved Twitch channel also marks an existing install")
    func savedChannelMarksExistingInstall() {
        withStore { store in
            store.set("somechannel", forKey: Keys.twitchChannelName)
            #expect(FreshInstallDefaults.isExistingInstall(store))

            FreshInstallDefaults.apply(to: store)
            #expect(store.object(forKey: Keys.currentSongCommandEnabled) as? Bool == false)
        }
    }

    @Test("A value the user already set is never overwritten", arguments: [false, true])
    func explicitValueSurvives(onboarded: Bool) {
        withStore { store in
            store.set(onboarded, forKey: Keys.hasCompletedOnboarding)
            store.set(!onboarded, forKey: Keys.currentSongCommandEnabled)
            FreshInstallDefaults.apply(to: store)

            #expect(store.object(forKey: Keys.currentSongCommandEnabled) as? Bool == !onboarded)
        }
    }

    @Test("The pass runs once: a later change is not reverted on the next launch")
    func runsOnce() {
        withStore { store in
            FreshInstallDefaults.apply(to: store)
            store.removeObject(forKey: Keys.currentSongCommandEnabled)

            FreshInstallDefaults.apply(to: store)
            #expect(store.object(forKey: Keys.currentSongCommandEnabled) == nil)
        }
    }

    @Test("Every entry really differs between fresh and upgraded installs")
    func entriesDiffer() {
        for entry in FreshInstallDefaults.values {
            #expect(entry.freshValue != entry.legacyValue, "\(entry.key) needs no fresh-install entry")
        }
        #expect(FreshInstallDefaults.values.map(\.key).contains(Keys.streamDeckControlEnabled) == false)
    }

    @Test("The marker never travels in a backup")
    func markerIsRuntimeState() {
        #expect(Keys.runtimeStateKeys.contains(Keys.freshInstallDefaultsVersion))
        #expect(Keys.allKeys.contains(Keys.freshInstallDefaultsVersion))
    }
}
