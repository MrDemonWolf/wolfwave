//
//  LoggerClearTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest
@testable import WolfWave

@MainActor
final class LoggerClearTests: XCTestCase {

    func testLogFileSizeIsNonNegative() {
        let size = Log.logFileSize()
        XCTAssertGreaterThanOrEqual(size, 0)
    }

    func testLogLineCountIsNonNegative() {
        let count = Log.logLineCount()
        XCTAssertGreaterThanOrEqual(count, 0)
    }

    func testClearLogFileTruncatesAndWritesHeader() throws {
        // Clear an isolated temp file, not the process-global log. The global
        // file is shared by every suite, so truncating it from a test races
        // other suites' reads (it once truncated the file mid-read in
        // LoggerTests, a CI flake). A private file makes this deterministic.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wolfwave-clear-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try "[old] line one\n[old] line two\n".write(to: url, atomically: true, encoding: .utf8)

        Log.clearLogFileForTesting(at: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)

        XCTAssertEqual(lines.count, 1, "Cleared file should contain exactly the header line")
        XCTAssertTrue(content.contains("Log cleared by user"), "Header line should be present")
        XCTAssertFalse(content.contains("line one"), "Pre-clear content should be truncated")
    }
}
