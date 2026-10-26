//
//  ThrowawayDefaults.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-26.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// A private `UserDefaults` store for one test, kept out of the app's
/// `Library/Preferences/` entirely.
///
/// This is the only place in the test bundle allowed to call
/// `UserDefaults(suiteName:)` (enforced by the `throwaway_defaults` SwiftLint
/// rule). Every test that needs its own settings store gets one from here.
///
/// ## Why the suite is a file path
///
/// The bundle is hosted in `WolfWave Dev.app`, so a suite opened by *name*
/// becomes `<name>.plist` in the host's `Library/Preferences/` (the app
/// container when the host is sandboxed, `~/Library/Preferences/` when it is
/// not). Those files cannot be cleaned up reliably:
/// `removePersistentDomain(forName:)` empties the domain, and cfprefsd then
/// writes the empty domain back to disk on its own schedule, anywhere from
/// immediately to several seconds later. A delete that runs first is simply
/// undone, and `synchronize()` does not order the two either; measured, the
/// same delete sequence left 0 files on one pass and 36 of 60 on the next.
/// With a UUID in every name, the dev container collected almost 16,000.
///
/// CFPreferences treats a domain that is an absolute path as that plist file.
/// So each suite here is a file inside one per-process temporary directory,
/// nothing is ever written to `Library/Preferences/`, and a late cfprefsd write
/// can only land in that directory, which is removed when the process exits.
/// The suites are fully isolated from each other and from the live app domain.
nonisolated final class ThrowawayDefaults: @unchecked Sendable {

    // MARK: - Properties

    /// Prefix of every per-process root directory, so a stale one left by a
    /// killed run can be found and removed by the next run.
    static let rootPrefix = "WolfWaveTests-ThrowawayDefaults-"

    /// Directory holding this process's suites. Created on first use.
    static let root: URL = {
        let fileManager = FileManager.default
        let temp = fileManager.temporaryDirectory
        removeStaleRoots(in: temp)
        let dir = temp.appendingPathComponent("\(rootPrefix)\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: ThrowawayDefaults.root) }
        return dir
    }()

    /// The suite's domain: an absolute path to its plist inside ``root``.
    let suiteName: String

    /// The isolated store. Hand this to the code under test.
    let defaults: UserDefaults

    // MARK: - Lifecycle

    /// Opens a fresh, empty suite.
    ///
    /// - Parameter label: Identifies the owning test in the file name, e.g.
    ///   `"SettingsBackupServiceTests"`. A UUID is appended, so labels need not
    ///   be unique.
    init(_ label: String) {
        let name = Self.root.appendingPathComponent("\(label).\(UUID().uuidString)").path
        guard let store = UserDefaults(suiteName: name) else {
            // Only the global domain's name is refused, and this name is not it.
            preconditionFailure("UserDefaults(suiteName: \(name)) returned nil")
        }
        suiteName = name
        defaults = store
    }

    // MARK: - Cleanup

    /// Empties the suite and deletes its file. Safe to call twice.
    ///
    /// Best effort by design: if cfprefsd writes the file again afterwards, it
    /// lands in ``root`` and goes when the process exits.
    func destroy() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Where cfprefsd writes the suite: the domain path plus `.plist`.
    var fileURL: URL {
        URL(fileURLWithPath: suiteName + ".plist")
    }

    /// Removes root directories left by earlier test processes that were killed
    /// before their exit handler ran. Only directories untouched for an hour, so
    /// a test run in another worktree sharing this container keeps its own.
    private static func removeStaleRoots(in temp: URL) {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        let entries = (try? fileManager.contentsOfDirectory(
            at: temp,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix(rootPrefix) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}
