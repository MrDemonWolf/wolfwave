//
//  HintRowTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-06-01.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest
import SwiftUI
import AppKit
@testable import WolfWave

/// `HintRow` renders with default and custom symbols and multiline text.
@MainActor
final class HintRowTests: XCTestCase {

    func testRendersWithDefaultSymbol() {
        let host = NSHostingView(rootView: HintRow("Cooldowns don't apply to you or your mods."))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        XCTAssertGreaterThan(host.fittingSize.width, 0)
    }

    func testRendersWithCustomSymbol() {
        let host = NSHostingView(rootView: HintRow("Everything stays on this Mac.", systemImage: "lock.fill"))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    /// `ToggleSettingRow(hint:)` draws the footnote under the row; `nil` draws nothing.
    func testToggleRowHintAddsAFootnote() {
        func row(hint: String?) -> NSHostingView<ToggleSettingRow> {
            let host = NSHostingView(rootView: ToggleSettingRow(
                title: "Allow Stream Deck commands",
                subtitle: "Let a key skip songs.",
                isOn: .constant(true),
                accessibilityLabel: "Toggle",
                accessibilityIdentifier: "toggle",
                hint: hint
            ))
            host.setFrameSize(NSSize(width: 360, height: 0))
            host.layoutSubtreeIfNeeded()
            return host
        }
        XCTAssertGreaterThan(
            row(hint: "Commands are only accepted from this Mac.").fittingSize.height,
            row(hint: nil).fittingSize.height
        )
    }

    func testRendersMultilineText() {
        let long = String(repeating: "This is a long inline tip. ", count: 6)
        let host = NSHostingView(rootView: HintRow(long))
        host.setFrameSize(NSSize(width: 280, height: 0))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
}
