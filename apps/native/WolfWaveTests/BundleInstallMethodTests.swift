//
//  BundleInstallMethodTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest
@testable import WolfWave

/// Homebrew vs DMG detection from an app bundle path (Caskroom/Cellar on Apple Silicon, Intel, and
/// custom prefixes).
@MainActor
final class BundleInstallMethodTests: XCTestCase {

    // MARK: - DMG / Non-Homebrew Paths

    func testApplicationsPathIsNotHomebrew() {
        XCTAssertFalse(Bundle.isHomebrewPath("/Applications/WolfWave.app"))
    }

    func testDownloadsPathIsNotHomebrew() {
        XCTAssertFalse(Bundle.isHomebrewPath("/Users/alice/Downloads/WolfWave.app"))
    }

    func testUserApplicationsPathIsNotHomebrew() {
        XCTAssertFalse(Bundle.isHomebrewPath("/Users/alice/Applications/WolfWave.app"))
    }

    func testEmptyPathIsNotHomebrew() {
        XCTAssertFalse(Bundle.isHomebrewPath(""))
    }

    // MARK: - Apple Silicon Homebrew

    func testAppleSiliconCaskroomIsHomebrew() {
        XCTAssertTrue(Bundle.isHomebrewPath("/opt/homebrew/Caskroom/wolfwave/1.0.0/WolfWave.app"))
    }

    func testAppleSiliconCellarIsHomebrew() {
        XCTAssertTrue(Bundle.isHomebrewPath("/opt/homebrew/Cellar/something/1.0/bin"))
    }

    // MARK: - Intel Homebrew

    func testIntelCaskroomIsHomebrew() {
        // Regression guard: previously misclassified as DMG install.
        XCTAssertTrue(Bundle.isHomebrewPath("/usr/local/Caskroom/wolfwave/1.0.0/WolfWave.app"))
    }

    func testIntelCellarIsHomebrew() {
        XCTAssertTrue(Bundle.isHomebrewPath("/usr/local/Cellar/something/1.0/bin"))
    }

    // MARK: - Custom Prefix

    func testCustomHomebrewPrefixIsHomebrew() {
        XCTAssertTrue(Bundle.isHomebrewPath("/Users/alice/Homebrew/Caskroom/wolfwave/1.0.0/WolfWave.app"))
    }

    // MARK: - Cask Installed to Applications

    /// Probe that reports only the given paths as existing.
    private func probe(_ existing: Set<String>) -> (String) -> Bool {
        { existing.contains($0) }
    }

    func testCaskInApplicationsIsHomebrewOnAppleSilicon() {
        // The cask's default target: the bundle path carries no Homebrew
        // marker, only the Caskroom record does.
        XCTAssertTrue(Bundle.isHomebrewInstall(
            bundlePath: "/Applications/WolfWave.app",
            fileExists: probe(["/opt/homebrew/Caskroom/wolfwave"])
        ))
    }

    func testCaskInApplicationsIsHomebrewOnIntel() {
        XCTAssertTrue(Bundle.isHomebrewInstall(
            bundlePath: "/Applications/WolfWave.app",
            fileExists: probe(["/usr/local/Caskroom/wolfwave"])
        ))
    }

    func testCaskWithUserAppdirIsHomebrew() {
        XCTAssertTrue(Bundle.isHomebrewInstall(
            bundlePath: "/Users/alice/Applications/WolfWave.app",
            fileExists: probe(["/opt/homebrew/Caskroom/wolfwave"])
        ))
    }

    func testApplicationsWithoutCaskroomRecordIsDMG() {
        XCTAssertFalse(Bundle.isHomebrewInstall(
            bundlePath: "/Applications/WolfWave.app",
            fileExists: probe(["/opt/homebrew/Caskroom/other-app"])
        ))
    }

    func testBuildOutsideApplicationsIgnoresCaskroomRecord() {
        // A dev build run from DerivedData on a Mac that also has the cask.
        XCTAssertFalse(Bundle.isHomebrewInstall(
            bundlePath: "/Users/alice/Library/Developer/Xcode/DerivedData/WolfWave-abc/Build/Products/Debug/WolfWave Dev.app",
            fileExists: probe(["/opt/homebrew/Caskroom/wolfwave"])
        ))
    }

    func testEmptyBundlePathIsNotHomebrew() {
        XCTAssertFalse(Bundle.isHomebrewInstall(bundlePath: "", fileExists: { _ in true }))
    }

    func testHomebrewPathNeedsNoProbe() {
        XCTAssertTrue(Bundle.isHomebrewInstall(
            bundlePath: "/opt/homebrew/Caskroom/wolfwave/1.0.0/WolfWave.app",
            fileExists: { _ in false }
        ))
    }

}
