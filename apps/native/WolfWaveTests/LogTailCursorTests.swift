//
//  LogTailCursorTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-08-14.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
import Foundation
@testable import WolfWave

/// Tests for the log-tailing cursor.
///
/// These pin the three failure modes the cursor exists to prevent: re-reading
/// the whole file every tick, losing a line that straddles two reads, and
/// reading past the end forever after the log is cleared or rotated.
@Suite("LogTailCursor Tests")
struct LogTailCursorTests {

    private static let priming: UInt64 = 1_000

    // MARK: - Priming

    @Test("First read primes from a bounded window, not the whole file")
    func testPrimingIsBounded() {
        var cursor = LogTailCursor()

        let range = cursor.planRead(fileSize: 5_000_000, primingBytes: Self.priming)

        #expect(range == 4_999_000..<5_000_000,
            "A 5 MB log must not be read in full just to show the last screenful")
        #expect(cursor.offset == 5_000_000)
    }

    @Test("A file smaller than the priming window is read from the start")
    func testPrimingSmallFile() {
        var cursor = LogTailCursor()

        #expect(cursor.planRead(fileSize: 120, primingBytes: Self.priming) == 0..<120)
    }

    @Test("An empty file yields nothing to read")
    func testEmptyFile() {
        var cursor = LogTailCursor()

        #expect(cursor.planRead(fileSize: 0, primingBytes: Self.priming) == nil)
        #expect(cursor.primed, "Still counts as primed, so the next append is a delta read")
    }

    // MARK: - Incremental Reads

    @Test("Subsequent reads pull only what was appended")
    func testDeltaRead() {
        var cursor = LogTailCursor()
        _ = cursor.planRead(fileSize: 500, primingBytes: Self.priming)

        #expect(cursor.planRead(fileSize: 640, primingBytes: Self.priming) == 500..<640)
        #expect(cursor.offset == 640)
    }

    @Test("An unchanged file yields nothing")
    func testNoChange() {
        var cursor = LogTailCursor()
        _ = cursor.planRead(fileSize: 500, primingBytes: Self.priming)

        #expect(cursor.planRead(fileSize: 500, primingBytes: Self.priming) == nil)
        #expect(cursor.planRead(fileSize: 500, primingBytes: Self.priming) == nil)
    }

    // MARK: - Truncation and Rotation

    @Test("A shrunken file re-primes instead of seeking past the end")
    func testTruncationReprimes() {
        var cursor = LogTailCursor()
        _ = cursor.planRead(fileSize: 900_000, primingBytes: Self.priming)

        // Clear Log, or a rotation, leaves a much smaller file. Reading from the
        // old offset would seek past EOF and return nothing forever.
        let range = cursor.planRead(fileSize: 200, primingBytes: Self.priming)

        #expect(range == 0..<200)
        #expect(cursor.offset == 200)
    }

    @Test("Truncation drops a half-line held from the previous file")
    func testTruncationClearsCarry() {
        var cursor = LogTailCursor()
        _ = cursor.planRead(fileSize: 500, primingBytes: Self.priming)
        _ = cursor.consume("complete line\npartial tail")
        #expect(!cursor.carry.isEmpty)

        _ = cursor.planRead(fileSize: 10, primingBytes: Self.priming)

        #expect(cursor.carry.isEmpty,
            "A partial line from the old file must not be glued onto the new one")
    }

    // MARK: - Line Assembly

    @Test("Complete lines are returned and the partial tail is held back")
    func testPartialLineHeldBack() {
        var cursor = LogTailCursor()

        let first = cursor.consume("alpha\nbravo\nchar")

        #expect(first == ["alpha", "bravo"])
        #expect(cursor.carry == "char")
    }

    @Test("A line split across two reads is reassembled, not dropped")
    func testSplitLineReassembled() {
        var cursor = LogTailCursor()

        // A record cut in half by a read boundary would not match the record
        // header on either side, so both halves would be discarded.
        _ = cursor.consume("2026-08-14T10:00:00.000Z  INFO   App  ")
        let second = cursor.consume("F.swift:1  hello\n")

        #expect(second == ["2026-08-14T10:00:00.000Z  INFO   App  F.swift:1  hello"])
        #expect(LogRecord.parse(second[0])?.message == "hello")
    }

    @Test("A chunk ending exactly on a newline holds nothing back")
    func testCleanBoundary() {
        var cursor = LogTailCursor()

        #expect(cursor.consume("one\ntwo\n") == ["one", "two"])
        #expect(cursor.carry.isEmpty)
    }

    @Test("A chunk with no newline yields no lines yet")
    func testNoNewlineYet() {
        var cursor = LogTailCursor()

        #expect(cursor.consume("still writing").isEmpty)
        #expect(cursor.carry == "still writing")
    }

    // MARK: - Byte Decoding

    @Test("A priming window that starts inside a character still yields its lines")
    func testWindowStartingMidCharacterDecodes() {
        var cursor = LogTailCursor()
        // "é" is C3 A9. A window starting on A9 used to fail strict decoding and
        // drop the whole chunk.
        let file = Data("café\nnext line\n".utf8)
        let window = file.dropFirst(4) // starts on the A9 continuation byte
        _ = cursor.planRead(fileSize: UInt64(file.count), primingBytes: UInt64(window.count))

        let lines = cursor.consume(bytes: Data(window))

        #expect(lines == ["", "next line"])
        #expect(cursor.offset == UInt64(file.count))
    }

    @Test("A character cut at the end of a read is held back and finished next read")
    func testTrailingPartialCharacterHeldBack() {
        var cursor = LogTailCursor()
        // "wolf " is 5 bytes, the emoji 4 (F0 9F 90 BA), then the newline: 10.
        let full = Data("wolf 🐺\n".utf8)
        let firstRead = full.prefix(7) // "wolf " plus the emoji's first two bytes
        _ = cursor.planRead(fileSize: 7, primingBytes: Self.priming)

        #expect(cursor.consume(bytes: Data(firstRead)).isEmpty)
        #expect(cursor.carry == "wolf ")
        #expect(cursor.offset == 5, "The emoji's bytes must be re-read, not skipped")

        let range = cursor.planRead(fileSize: 10, primingBytes: Self.priming)
        #expect(range == 5..<10)
        #expect(cursor.consume(bytes: Data(full.suffix(5))) == ["wolf 🐺"])
    }

    @Test("A corrupt byte mid-chunk decodes as a replacement, not a skipped chunk")
    func testInvalidByteDoesNotWedge() {
        var cursor = LogTailCursor()
        var bytes = Data("bad ".utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: Data(" byte\n".utf8))

        #expect(cursor.consume(bytes: bytes) == ["bad \u{FFFD} byte"])
    }

    // MARK: - End to End

    @Test("A realistic append sequence yields each record exactly once")
    func testAppendSequenceYieldsEachRecordOnce() {
        var cursor = LogTailCursor()
        var seen: [String] = []

        // Prime against an empty file, then append two records in three writes,
        // the middle one splitting a line.
        _ = cursor.planRead(fileSize: 0, primingBytes: Self.priming)
        seen += cursor.consume("2026-08-14T10:00:00.000Z  INFO   App  F.swift:1  first\n")
        seen += cursor.consume("2026-08-14T10:00:01.000Z  WARN   App  F.swift:2  sec")
        seen += cursor.consume("ond\n")

        let records = LogRecord.parse(contents: seen.joined(separator: "\n"))
        #expect(records.map(\.message) == ["first", "second"])
    }
}
