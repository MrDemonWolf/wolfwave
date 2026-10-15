//
//  DiscordProcArgsParsingTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Testing
@testable import WolfWave

/// `DiscordRPCService.tmpDir(fromProcArgs2:)` against crafted `KERN_PROCARGS2` buffers:
/// the environment starts after exactly `argc` argv strings, even when one is empty or
/// not valid UTF-8.
@Suite("Discord KERN_PROCARGS2 parsing")
struct DiscordProcArgsParsingTests {

    // MARK: - Helpers

    /// Builds `[argc][exec_path\0][padding][argv...\0][env...\0][\0]`.
    private func buffer(execPath: String, argv: [[UInt8]], env: [String], padding: Int = 3) -> [UInt8] {
        var bytes = withUnsafeBytes(of: Int32(argv.count)) { Array($0) }
        bytes += Array(execPath.utf8) + [0]
        bytes += [UInt8](repeating: 0, count: padding)
        for arg in argv { bytes += arg + [0] }
        for entry in env { bytes += Array(entry.utf8) + [0] }
        bytes += [0]
        return bytes
    }

    // MARK: - Tests

    @Test("Reads TMPDIR when it is the first environment entry")
    func readsFirstEnvironmentEntry() {
        let bytes = buffer(
            execPath: "/Applications/Discord.app/Contents/MacOS/Discord",
            argv: [Array("Discord".utf8)],
            env: ["TMPDIR=/var/folders/ab/xyz/T/", "HOME=/Users/wolf"])
        #expect(DiscordRPCService.tmpDir(fromProcArgs2: bytes) == "/var/folders/ab/xyz/T/")
    }

    @Test("An empty argv entry does not shift where the environment starts")
    func emptyArgvEntry() {
        let bytes = buffer(
            execPath: "/Applications/Discord.app/Contents/MacOS/Discord",
            argv: [Array("Discord".utf8), [], Array("--flag".utf8)],
            env: ["TMPDIR=/var/folders/cd/abc/T/", "PATH=/usr/bin"])
        #expect(DiscordRPCService.tmpDir(fromProcArgs2: bytes) == "/var/folders/cd/abc/T/")
    }

    @Test("A non-UTF-8 argv entry does not shift where the environment starts")
    func nonUTF8ArgvEntry() {
        let bytes = buffer(
            execPath: "/Applications/Discord.app/Contents/MacOS/Discord",
            argv: [Array("Discord".utf8), [0xFF, 0xFE]],
            env: ["TMPDIR=/var/folders/ef/def/T/"])
        #expect(DiscordRPCService.tmpDir(fromProcArgs2: bytes) == "/var/folders/ef/def/T/")
    }

    @Test("An argv string that looks like TMPDIR is not read as the environment")
    func argvLookalikeIgnored() {
        let bytes = buffer(
            execPath: "/Discord",
            argv: [Array("Discord".utf8), Array("TMPDIR=/wrong".utf8)],
            env: ["TMPDIR=/right"])
        #expect(DiscordRPCService.tmpDir(fromProcArgs2: bytes) == "/right")
    }

    @Test("Strings after the environment terminator are not read")
    func stopsAtEnvironmentTerminator() {
        var bytes = buffer(execPath: "/Discord", argv: [Array("Discord".utf8)], env: ["HOME=/Users/wolf"])
        bytes += Array("TMPDIR=/apple-string".utf8) + [0]
        #expect(DiscordRPCService.tmpDir(fromProcArgs2: bytes) == nil)
    }

    /// Little-endian `argc` header followed by `rest`.
    private static func header(_ argc: Int32, _ rest: [UInt8]) -> [UInt8] {
        let argcBytes: [UInt8] = withUnsafeBytes(of: argc) { Array($0) }
        return argcBytes + rest
    }

    private static let malformedBuffers: [[UInt8]] = [
        [],
        [1, 0, 0],
        header(-1, Array("/Discord".utf8) + [0]),
        header(5, Array("/Discord".utf8) + [0, 0, 0x61, 0]),
    ]

    @Test("Malformed buffers return nil", arguments: malformedBuffers)
    func malformed(bytes: [UInt8]) {
        #expect(DiscordRPCService.tmpDir(fromProcArgs2: bytes) == nil)
    }
}
