//
//  LogTailCursor.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-08-14.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Tracks position while tailing the log file, so a reader only ever pulls the
/// bytes it has not seen.
///
/// Split out from the view because this is the part that actually goes wrong:
/// re-reading the whole file every tick, losing the tail of a line that
/// straddles two reads, and silently reading past the end after the file
/// rotates or is cleared. All three are decided here, with no file I/O, so they
/// can be tested directly.
///
/// The caller owns the `FileHandle`: ask ``planRead(fileSize:primingBytes:)``
/// what to read, read it, then hand the bytes to ``consume(bytes:)``.
///
/// `planRead` advances ``offset`` as if the read will succeed. The cursor is a
/// value, so a caller whose read fails keeps its pre-`planRead` copy and the
/// same range is tried again on the next poll instead of being skipped.
nonisolated struct LogTailCursor: Equatable {

    /// Byte offset already consumed. Everything before this has been returned.
    private(set) var offset: UInt64 = 0

    /// Trailing partial line held back until its newline arrives.
    private(set) var carry: String = ""

    /// Whether the first (priming) read has happened.
    private(set) var primed = false

    /// Decides which byte range to read next.
    ///
    /// - On the first call, primes from the last `primingBytes` of the file
    ///   rather than the whole thing: a 5 MB log would otherwise be parsed in
    ///   full just to show the most recent screenful.
    /// - When the file has shrunk, the log was cleared or rotated out from under
    ///   us. Reading from the old offset would seek past the end and return
    ///   nothing forever, so the cursor re-primes against the new file.
    /// - Otherwise, reads only what was appended since last time.
    ///
    /// - Parameters:
    ///   - fileSize: Current size of the log file in bytes.
    ///   - primingBytes: How much history to pull on the first read or after a
    ///     rotation.
    /// - Returns: The range to read, or `nil` when there is nothing new.
    mutating func planRead(fileSize: UInt64, primingBytes: UInt64) -> Range<UInt64>? {
        // First read, or the file shrank (cleared / rotated): start over from a
        // bounded window at the end.
        if !primed || fileSize < offset {
            primed = true
            carry = ""
            let start = fileSize > primingBytes ? fileSize - primingBytes : 0
            offset = fileSize
            return start < fileSize ? start..<fileSize : nil
        }

        guard fileSize > offset else { return nil }
        let start = offset
        offset = fileSize
        return start..<fileSize
    }

    /// Decodes newly read bytes and splits them into complete lines.
    ///
    /// Reads are byte ranges, so either edge can cut a multi-byte UTF-8
    /// character in half, and strict decoding would then reject the whole chunk:
    ///
    /// - A priming window starts at an arbitrary byte. Leading continuation
    ///   bytes (the tail of a character whose start is outside the window) are
    ///   dropped; that partial first line was never going to parse anyway.
    /// - A read can land while a character is half written. An incomplete
    ///   trailing sequence is not consumed: ``offset`` steps back over it so
    ///   the next read starts on the character's first byte.
    ///
    /// Anything still invalid in the middle decodes as U+FFFD rather than
    /// failing, so one corrupt byte can never wedge the tail.
    ///
    /// - Parameter bytes: The bytes of the range `planRead` returned.
    /// - Returns: Only the lines terminated by a newline.
    mutating func consume(bytes: Data) -> [String] {
        var body = bytes[...]
        // Valid UTF-8 never starts with a continuation byte, and a sequence is at
        // most four bytes, so at most three can belong to a cut character.
        var dropped = 0
        while dropped < 3, let first = body.first, Self.isContinuation(first) {
            body = body.dropFirst()
            dropped += 1
        }

        let held = Self.incompleteTrailingCount(body)
        if held > 0 {
            body = body.dropLast(held)
            offset -= min(offset, UInt64(held))
        }

        return consume(String(decoding: body, as: UTF8.self))
    }

    /// Splits newly read text into complete lines.
    ///
    /// A read can land mid-line. The incomplete tail is held in ``carry`` and
    /// prepended to the next chunk, so a record is never handed to the parser in
    /// two halves (which would drop it, since half a line does not match the
    /// record header).
    ///
    /// - Parameter chunk: Text decoded from the planned byte range.
    /// - Returns: Only the lines terminated by a newline.
    mutating func consume(_ chunk: String) -> [String] {
        var pieces = (carry + chunk).components(separatedBy: "\n")
        // `components` always yields at least one element; the last is whatever
        // followed the final newline, which is "" when the chunk ended cleanly.
        carry = pieces.removeLast()
        return pieces
    }

    // MARK: - UTF-8 Helpers

    /// `10xxxxxx`: a byte that continues a multi-byte sequence.
    private static func isContinuation(_ byte: UInt8) -> Bool {
        byte & 0b1100_0000 == 0b1000_0000
    }

    /// How many bytes at the end of `bytes` form a multi-byte sequence whose
    /// remaining bytes have not been read yet. `0` when the chunk ends cleanly.
    private static func incompleteTrailingCount(_ bytes: Data.SubSequence) -> Int {
        // Walk back over continuation bytes to the sequence's lead byte.
        var index = bytes.endIndex
        var trailing = 0
        while index > bytes.startIndex, trailing < 4 {
            index = bytes.index(before: index)
            trailing += 1
            let byte = bytes[index]
            guard isContinuation(byte) else {
                let expected: Int
                switch byte {
                case 0b1100_0000...0b1101_1111: expected = 2
                case 0b1110_0000...0b1110_1111: expected = 3
                case 0b1111_0000...0b1111_0111: expected = 4
                default: expected = 1 // ASCII, or an invalid lead U+FFFD covers
                }
                return trailing < expected ? trailing : 0
            }
        }
        return 0
    }
}
