//
//  TrackInfoCommandTestsBase.swift
//  WolfWaveTests
//
//  Created by MrDemonWolf, Inc. on 4/16/26.
//

import XCTest
@testable import WolfWave

/// Shared test suite for `TrackInfoCommand` variants (`!song`, `!last`, etc.).
///
/// Concrete subclasses override `spec` to configure triggers + default message.
/// Behaviours invariant across variants (case-insensitivity, truncation,
/// enable/disable, default message) are defined once here.
///
/// Abstract-class handling: `defaultTestSuite` returns an empty suite for the
/// base class itself so only concrete subclasses contribute tests.
class TrackInfoCommandTestsBase: XCTestCase {

    struct Spec {
        let triggers: [String]
        let description: String
        let defaultMessage: String
        /// A trigger string with mixed case to exercise case-insensitive matching.
        let mixedCaseTrigger: String
        /// An uppercased trigger string.
        let upperCaseTrigger: String
        /// Sample track info returned by the callback in tests.
        let sampleTrackInfo: String
        /// A sample callback response used for value-equality assertions.
        let sampleCallbackValue: String
    }

    /// Concrete subclasses must override to supply a non-nil spec.
    var spec: Spec { fatalError("Override spec in subclass") }

    var command: TrackInfoCommand!

    override class var defaultTestSuite: XCTestSuite {
        // Skip tests for the abstract base class itself.
        if self == TrackInfoCommandTestsBase.self {
            return XCTestSuite(name: "TrackInfoCommandTestsBase (abstract)")
        }
        return super.defaultTestSuite
    }

    override func setUp() {
        super.setUp()
        command = TrackInfoCommand(
            triggers: spec.triggers,
            description: spec.description,
            defaultMessage: spec.defaultMessage
        )
    }

    override func tearDown() {
        command = nil
        super.tearDown()
    }

    // MARK: - Trigger Tests

    func testAllTriggersMatch() {
        command.getTrackInfo = { [sample = spec.sampleTrackInfo] in sample }
        for trigger in spec.triggers {
            XCTAssertNotNil(command.execute(message: trigger),
                            "Trigger \(trigger) should match")
        }
    }

    func testTriggerCaseInsensitiveUppercase() {
        command.getTrackInfo = { "Artist - Song" }
        XCTAssertNotNil(command.execute(message: spec.upperCaseTrigger))
    }

    func testTriggerCaseInsensitiveMixed() {
        command.getTrackInfo = { "Artist - Song" }
        XCTAssertNotNil(command.execute(message: spec.mixedCaseTrigger))
    }

    func testNonMatchingMessageReturnsNil() {
        command.getTrackInfo = { "Artist - Song" }
        XCTAssertNil(command.execute(message: "hello world"))
    }

    // MARK: - Callback Tests

    func testNoCallbackReturnsDefaultMessage() {
        let primary = spec.triggers[0]
        let result = command.execute(message: primary)
        XCTAssertEqual(result, spec.defaultMessage)
    }

    func testWithCallbackReturnsCallbackValue() {
        let primary = spec.triggers[0]
        command.getTrackInfo = { [value = spec.sampleCallbackValue] in value }
        let result = command.execute(message: primary)
        XCTAssertEqual(result, spec.sampleCallbackValue)
    }

    // MARK: - Enable/Disable Tests

    func testDisabledReturnsNil() {
        let primary = spec.triggers[0]
        command.getTrackInfo = { "Artist - Song" }
        command.isEnabled = { false }
        XCTAssertNil(command.execute(message: primary))
    }

    func testEnabledReturnsResponse() {
        let primary = spec.triggers[0]
        command.getTrackInfo = { "Artist - Song" }
        command.isEnabled = { true }
        XCTAssertNotNil(command.execute(message: primary))
    }

    func testIsEnabledNotSetDefaultsToEnabled() {
        let primary = spec.triggers[0]
        command.getTrackInfo = { "Artist - Song" }
        XCTAssertNotNil(command.execute(message: primary))
    }

    // MARK: - Truncation Tests

    func testLongResponseTruncatedTo500() {
        let primary = spec.triggers[0]
        let longString = String(repeating: "a", count: 600)
        command.getTrackInfo = { longString }
        guard let result = command.execute(message: primary) else {
            XCTFail("Expected non-nil result")
            return
        }
        XCTAssertEqual(result.count, 500)
        XCTAssertTrue(result.hasSuffix("..."))
    }

    func testExactly500CharsNotTruncated() {
        let primary = spec.triggers[0]
        let exact = String(repeating: "a", count: 500)
        command.getTrackInfo = { exact }
        guard let result = command.execute(message: primary) else {
            XCTFail("Expected non-nil result")
            return
        }
        XCTAssertEqual(result.count, 500)
        XCTAssertFalse(result.hasSuffix("..."))
    }

    // MARK: - Edge Cases

    func testTriggerWithTrailingText() {
        let primary = spec.triggers[0]
        command.getTrackInfo = { "Artist - Song" }
        XCTAssertNotNil(command.execute(message: "\(primary) extra stuff"))
    }

    func testTriggersArrayContents() {
        XCTAssertEqual(command.triggers, spec.triggers)
    }

    func testDescriptionValue() {
        XCTAssertEqual(command.description, spec.description)
    }
}
