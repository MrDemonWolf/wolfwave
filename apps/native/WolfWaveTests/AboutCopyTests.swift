//
//  AboutCopyTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Testing
@testable import WolfWave

/// The About pane's copyright year comes from `NSHumanReadableCopyright`, so
/// it can't drift from the line the standard About panel shows.
@MainActor
@Suite("About Copy")
struct AboutCopyTests {
    @Test("Year is taken from the bundle copyright string")
    func yearFromBundleCopyright() {
        let line = AboutCopy.copyrightLine(
            bundleCopyright: "© 2031 MrDemonWolf, Inc. All rights reserved.",
            holder: "Fork Co.",
            fallbackYear: 1999
        )
        #expect(line == "© 2031 Fork Co. All rights reserved.")
    }

    @Test("A year range is kept whole")
    func yearRange() {
        #expect(AboutCopy.copyrightYear(in: "© 2025-2027 MrDemonWolf, Inc.") == "2025-2027")
    }

    @Test("Missing or yearless copyright falls back")
    func fallbackYear() {
        #expect(AboutCopy.copyrightLine(bundleCopyright: nil, holder: "X", fallbackYear: 2040)
            == "© 2040 X All rights reserved.")
        #expect(AboutCopy.copyrightLine(bundleCopyright: "All rights reserved.", holder: "X", fallbackYear: 2040)
            == "© 2040 X All rights reserved.")
    }

    @Test("The live line matches the host bundle's copyright year")
    func liveLineMatchesBundle() throws {
        let bundleCopyright = try #require(
            Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
        )
        let year = try #require(AboutCopy.copyrightYear(in: bundleCopyright))
        #expect(AboutCopy.copyrightLine.hasPrefix("© \(year) "))
    }
}
