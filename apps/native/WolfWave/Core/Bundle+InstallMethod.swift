//
//  Bundle+InstallMethod.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Install-method detection. Drives whether Sparkle runs (`SparkleUpdaterService`
/// disables itself for Homebrew so the two updaters never fight) and the
/// "Homebrew" vs "DMG" label in diagnostics and the Software Update pane.
extension Bundle {
    // MARK: - Constants

    /// The cask token in the `MrDemonWolf/homebrew-den` tap (`Casks/wolfwave.rb`).
    static let homebrewCaskToken = "wolfwave"

    /// Caskroom directories Homebrew records an installed cask under: Apple
    /// Silicon `/opt/homebrew` and Intel `/usr/local`. A custom prefix can't be
    /// probed without listing the disk, so it is caught only by the path check.
    static let homebrewCaskroomPaths = [
        "/opt/homebrew/Caskroom",
        "/usr/local/Caskroom"
    ]

    // MARK: - Detection

    /// Whether this bundle was installed by Homebrew.
    ///
    /// The cask's `app` stanza moves the bundle into `/Applications`, so the
    /// bundle path alone almost never says Homebrew. Homebrew also keeps a
    /// `Caskroom/wolfwave` directory for as long as the cask is installed, and
    /// that is what this checks. The App Sandbox allows the metadata read
    /// (`stat`) behind `fileExists` on any path, even though it denies listing
    /// the directory, so the probe works in the shipped sandboxed app.
    var isHomebrewInstall: Bool {
        Bundle.isHomebrewInstall(bundlePath: bundlePath) { FileManager.default.fileExists(atPath: $0) }
    }

    /// Pure install-method decision, with the filesystem probe injected for tests.
    ///
    /// - Parameters:
    ///   - bundlePath: The running app's absolute bundle path.
    ///   - fileExists: Reports whether a path exists (`FileManager.fileExists` in production).
    /// - Returns: `true` when the bundle path itself is under a Homebrew prefix,
    ///   or when the bundle sits directly in an `Applications` folder (the cask
    ///   target, system or `~/Applications` via `--appdir`) and a
    ///   `Caskroom/wolfwave` record exists. The `Applications` condition keeps a
    ///   build run from Xcode's DerivedData or Downloads from being taken for
    ///   the cask just because the cask is also installed on that Mac.
    static func isHomebrewInstall(bundlePath: String, fileExists: (String) -> Bool) -> Bool {
        if isHomebrewPath(bundlePath) { return true }

        let parent = (bundlePath as NSString).deletingLastPathComponent
        guard !bundlePath.isEmpty, (parent as NSString).lastPathComponent == "Applications" else {
            return false
        }
        return homebrewCaskroomPaths.contains { root in
            fileExists("\(root)/\(homebrewCaskToken)")
        }
    }

    /// Path-matching helper exposed for testing.
    ///
    /// - Parameter path: An absolute bundle path.
    /// - Returns: `true` when the path contains a Homebrew prefix: Apple
    ///   Silicon `/opt/homebrew/`, Intel `/usr/local/Caskroom/` or
    ///   `/usr/local/Cellar/`, or any custom `/Homebrew/` prefix.
    static func isHomebrewPath(_ path: String) -> Bool {
        let homebrewMarkers = [
            "/opt/homebrew/",
            "/usr/local/Caskroom/",
            "/usr/local/Cellar/",
            "/Homebrew/"
        ]
        return homebrewMarkers.contains { path.contains($0) }
    }
}
