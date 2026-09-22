//
//  PasteboardTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-09-22.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import XCTest
@testable import WolfWave

@MainActor
final class PasteboardTests: XCTestCase {

    func testSensitiveCleanupClearsOnlyTheCopiedValue() {
        let pasteboard = NSPasteboard(name: .init("com.mrdemonwolf.wolfwave.tests.sensitive"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("secret", forType: .string))
        let changeCount = pasteboard.changeCount

        XCTAssertTrue(Pasteboard.clearIfUnchanged(
            "secret",
            changeCount: changeCount,
            from: pasteboard
        ))
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testSensitiveCleanupPreservesNewerClipboardContents() {
        let pasteboard = NSPasteboard(name: .init("com.mrdemonwolf.wolfwave.tests.replaced"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("secret", forType: .string))
        let staleChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("new value", forType: .string))

        XCTAssertFalse(Pasteboard.clearIfUnchanged(
            "secret",
            changeCount: staleChangeCount,
            from: pasteboard
        ))
        XCTAssertEqual(pasteboard.string(forType: .string), "new value")
    }

    func testSensitiveCleanupPreservesRewrittenMatchingValue() {
        let pasteboard = NSPasteboard(name: .init("com.mrdemonwolf.wolfwave.tests.rewritten"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("secret", forType: .string))
        let staleChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("secret", forType: .string))

        XCTAssertFalse(Pasteboard.clearIfUnchanged(
            "secret",
            changeCount: staleChangeCount,
            from: pasteboard
        ))
        XCTAssertEqual(pasteboard.string(forType: .string), "secret")
    }
}
