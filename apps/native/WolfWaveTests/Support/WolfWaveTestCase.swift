//
//  WolfWaveTestCase.swift
//  WolfWaveTests
//
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//
//  Shared base class for WolfWave unit tests. Centralizes UserDefaults reset
//  and temp-directory plumbing so individual test files stop reinventing
//  setUp/tearDown boilerplate (and stop forgetting keys their target writes).
//

import XCTest

@testable import WolfWave

/// Base test case that wipes every persisted setting before and after each test.
///
/// Inherit from this instead of `XCTestCase` for any test that touches
/// `UserDefaults`. The reset uses `AppConstants.UserDefaults.allKeys` as its
/// source of truth, so adding a new key automatically participates in cleanup.
/// Intentionally **not** annotated `@MainActor` at the class level. Subclasses
/// that need main-actor isolation should declare it themselves (matching the
/// project default), and tests that exercise `@Sendable` callbacks running on
/// background queues need the base class to stay nonisolated so their static
/// helpers can be called from those closures.
class WolfWaveTestCase: XCTestCase {

    /// Temp directories registered for cleanup in `tearDown`.
    private var trackedTempDirs: [URL] = []

    override func setUp() {
        super.setUp()
        resetAllSettings()
    }

    override func tearDown() {
        cleanupTrackedTempDirs()
        resetAllSettings()
        super.tearDown()
    }

    // MARK: - UserDefaults

    /// Removes every key listed in `AppConstants.UserDefaults.allKeys`.
    func resetAllSettings() {
        let defaults = Foundation.UserDefaults.standard
        for key in AppConstants.UserDefaults.allKeys {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Temp directories

    /// Returns a fresh, unique temp directory and registers it for cleanup at tearDown.
    @discardableResult
    func makeTempDir(file: StaticString = #file) -> URL {
        let dir = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("wolfwave-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        trackedTempDirs.append(dir)
        return dir
    }

    private func cleanupTrackedTempDirs() {
        for url in trackedTempDirs {
            try? FileManager.default.removeItem(at: url)
        }
        trackedTempDirs.removeAll()
    }
}
