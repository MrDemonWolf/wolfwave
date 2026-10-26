//
//  ThrowawayDefaultsTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-26.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Testing

@testable import WolfWave

/// Pins the contract of ``ThrowawayDefaults``: a test's private store never
/// touches the host app's `Library/Preferences/`.
///
/// Suites opened by name there could not be cleaned up reliably (cfprefsd
/// rewrites the emptied plist after any delete), which is how the dev
/// container reached ~16,000 files. If the helper ever goes back to named
/// suites, the first test here fails instead of the folder quietly growing.
@Suite("ThrowawayDefaults")
struct ThrowawayDefaultsTests {

    @Test("A written suite never lands in Library/Preferences")
    func neverWritesToPreferences() async throws {
        let scratch = ThrowawayDefaults("ThrowawayDefaultsTests")
        defer { scratch.destroy() }
        scratch.defaults.set("value", forKey: "probe")

        // cfprefsd writes asynchronously; wait (bounded) for the file to land in
        // the scratch directory, so the check below sees a settled write.
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: scratch.fileURL.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(FileManager.default.fileExists(atPath: scratch.fileURL.path))
        #expect(scratch.suiteName.hasPrefix(ThrowawayDefaults.root.path))
        let preferences = try #require(
            FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        ).appendingPathComponent("Preferences")
        let leaked = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        let fileName = URL(fileURLWithPath: scratch.suiteName).lastPathComponent
        #expect(!leaked.contains { $0.contains(fileName) })
    }

    @Test("Suites are isolated from each other and start empty")
    func suitesAreIsolated() {
        let first = ThrowawayDefaults("ThrowawayDefaultsTests")
        let second = ThrowawayDefaults("ThrowawayDefaultsTests")
        defer {
            first.destroy()
            second.destroy()
        }

        #expect(first.suiteName != second.suiteName)
        #expect(first.defaults.object(forKey: "probe") == nil)
        first.defaults.set(1, forKey: "probe")
        #expect(first.defaults.integer(forKey: "probe") == 1)
        #expect(second.defaults.object(forKey: "probe") == nil)
    }

    @Test("destroy() empties the suite and is safe to call twice")
    func destroyEmptiesSuite() {
        let scratch = ThrowawayDefaults("ThrowawayDefaultsTests")
        scratch.defaults.set("value", forKey: "probe")
        scratch.destroy()
        scratch.destroy()
        #expect(scratch.defaults.object(forKey: "probe") == nil)
    }
}
