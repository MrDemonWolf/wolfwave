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
    /// Whether this bundle's path looks like a Homebrew install.
    ///
    /// Purely path-based: a bundle that was moved or copied into
    /// `/Applications` (the default Homebrew cask target) does not match
    /// any marker and reports `false`.
    var isHomebrewInstall: Bool {
        Bundle.isHomebrewPath(bundlePath)
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
