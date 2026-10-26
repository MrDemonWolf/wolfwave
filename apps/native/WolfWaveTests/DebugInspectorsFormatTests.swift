//
//  DebugInspectorsFormatTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

#if DEBUG
import Foundation
import Testing
@testable import WolfWave

/// How the Debug tab's UserDefaults inspector renders a stored value. An integer stored as 0 or 1
/// must read as a number, not as false / true.
@MainActor
@Suite("Debug inspector value formatting")
struct DebugInspectorsFormatTests {

    @Test("An integer 0 or 1 reads as a number, not a boolean")
    func integerZeroAndOneStayNumbers() {
        #expect(DebugInspectorsCard.formatValue(NSNumber(value: 0)) == "0")
        #expect(DebugInspectorsCard.formatValue(NSNumber(value: 1)) == "1")
        #expect(DebugInspectorsCard.formatValue(1 as Int) == "1")
    }

    @Test("A stored boolean reads as true / false")
    func booleansStayBooleans() {
        #expect(DebugInspectorsCard.formatValue(true) == "true")
        #expect(DebugInspectorsCard.formatValue(NSNumber(value: false)) == "false")
    }

    @Test("Strings are quoted, other numbers use their value, nil is unset")
    func otherValues() {
        #expect(DebugInspectorsCard.formatValue("wolf") == "\"wolf\"")
        #expect(DebugInspectorsCard.formatValue(NSNumber(value: 9090)) == "9090")
        #expect(DebugInspectorsCard.formatValue(nil) == "<unset>")
    }

    @Test("A value read back from defaults keeps its integer-vs-boolean identity")
    func roundTripThroughDefaults() throws {
        let scratch = ThrowawayDefaults("DebugInspectorsFormatTests")
        defer { scratch.destroy() }
        let defaults = scratch.defaults
        defaults.set(1, forKey: "int")
        defaults.set(true, forKey: "bool")

        #expect(DebugInspectorsCard.formatValue(defaults.object(forKey: "int")) == "1")
        #expect(DebugInspectorsCard.formatValue(defaults.object(forKey: "bool")) == "true")
    }
}
#endif
