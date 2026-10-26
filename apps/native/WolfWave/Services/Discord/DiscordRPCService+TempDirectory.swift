//
//  DiscordRPCService+TempDirectory.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import Foundation

/// Discovery of the temp directories Discord may expose its IPC sockets
/// under, including reading a running Discord process's own `TMPDIR`.
extension DiscordRPCService {

    // MARK: - Temp Directory

    /// Known Discord bundle identifiers (stable, Canary, PTB).
    static let discordBundleIDs = [
        "com.hnc.Discord",
        "com.hnc.Discord.Canary",
        "com.hnc.Discord.PTB"
    ]

    /// Returns candidate temp directory paths for locating Discord's IPC socket.
    ///
    /// In a sandboxed app, `$TMPDIR`, `NSTemporaryDirectory()`, and `confstr` all
    /// return the container path (`~/Library/Containers/<id>/Data/tmp/`), but Discord
    /// places its IPC socket in the OS-level temp directory (`/var/folders/.../T/`).
    ///
    /// Strategy (in priority order):
    /// 1. Read the real `TMPDIR` from a running Discord process via `sysctl(KERN_PROCARGS2)`.
    ///    This kernel query is not blocked by App Sandbox.
    /// 2. Fall back to `confstr(_CS_DARWIN_USER_TEMP_DIR)` (works for non-sandboxed apps).
    ///
    /// All returned paths are resolved through symlinks so the sandbox sees the
    /// canonical form (e.g., `/private/var/folders/…` instead of `/var/folders/…`).
    ///
    /// - Returns: Array of directory paths to search, most likely first.
    ///
    /// Widened from `private` so `connectIfNeeded` in `DiscordRPCService+IPC.swift`
    /// can call it across files.
    func tempDirectoryCandidates() -> [String] {
        var candidates: [String] = []

        // 1. Read the REAL TMPDIR from Discord's own process environment.
        //    sysctl(KERN_PROCARGS2) returns argv + environ for same-user processes
        //    and is NOT redirected by App Sandbox.
        //    Result is cached for `discordTmpDirTTL` seconds. Discord's TMPDIR
        //    doesn't change while it's running, so calling sysctl on every
        //    connect attempt is wasteful.
        let now = Date()
        let discordTmpDir: String?
        if let cached = cachedDiscordTmpDir, now.timeIntervalSince(cachedDiscordTmpDirAt) < discordTmpDirTTL {
            discordTmpDir = cached
        } else {
            discordTmpDir = readDiscordTmpDir()
            cachedDiscordTmpDir = discordTmpDir
            cachedDiscordTmpDirAt = now
        }

        if let discordTmpDir {
            let resolved = Self.resolveSymlinks(discordTmpDir)
            candidates.append(resolved)
        }

        // 2. confstr: works outside sandbox, returns container path inside sandbox.
        let len = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        if len > 0 {
            var buf = [CChar](repeating: 0, count: len)
            confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, len)
            let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let resolved = Self.resolveSymlinks(String(decoding: bytes, as: UTF8.self))
            if !candidates.contains(resolved) {
                candidates.append(resolved)
            }
        }

        return candidates
    }

    /// Resolves symlinks in a path to produce the canonical filesystem path.
    ///
    /// On macOS, `/var` is a symlink to `/private/var`. The App Sandbox checks
    /// against canonical paths, so `connect()` to `/var/folders/.../discord-ipc-0`
    /// won't match an SBPL rule for `/private/var/folders/...`. This method
    /// ensures paths use the real, resolved form.
    nonisolated private static func resolveSymlinks(_ path: String) -> String {
        // URL.resolvingSymlinksInPath() resolves all symlinks and also
        // standardizes the path (removes trailing slashes, `.`, `..`).
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Reads the `TMPDIR` environment variable from a running Discord process.
    ///
    /// Uses `sysctl(KERN_PROCARGS2)` which returns the command-line arguments and
    /// environment of any same-user process. This is a kernel info query, not a
    /// file-system operation, so App Sandbox does not block it.
    ///
    /// - Returns: Discord's TMPDIR value, or nil if Discord is not running or
    ///   the environment cannot be read.
    private func readDiscordTmpDir() -> String? {
        // Find a running Discord process
        var discordPID: pid_t = 0
        for bundleID in Self.discordBundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                discordPID = app.processIdentifier
                break
            }
        }
        guard discordPID > 0 else { return nil }

        // Query the size of the process args buffer
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, discordPID]
        var size: size_t = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        // Read the process args buffer
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        guard let value = Self.tmpDir(fromProcArgs2: Array(buffer.prefix(size))) else { return nil }
        Log.debug("DiscordRPCService: Read TMPDIR from Discord process: \(value)", category: .discord)
        return value
    }

    /// Extracts `TMPDIR` from a `KERN_PROCARGS2` buffer.
    ///
    /// Layout: `[argc: Int32][exec_path\0][\0 padding...][argv[0]\0]...[argv[argc-1]\0][env[0]\0]...[\0]`.
    /// Exactly `argc` argv strings are skipped, including empty or non-UTF-8 ones,
    /// so the environment always starts at the right entry. The environment ends
    /// at the first empty string or the end of the buffer.
    ///
    /// - Parameter buffer: The raw sysctl result, trimmed to the returned size.
    /// - Returns: The `TMPDIR` value, or nil when the buffer is malformed or has none.
    nonisolated static func tmpDir(fromProcArgs2 buffer: [UInt8]) -> String? {
        let header = MemoryLayout<Int32>.size
        guard buffer.count > header else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }

        var index = header
        // exec_path
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        // NUL padding before argv[0]
        while index < buffer.count, buffer[index] == 0 { index += 1 }

        // Skip exactly argc argv strings, empty ones included.
        for _ in 0..<argc {
            guard index < buffer.count else { return nil }
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            index += 1
        }

        // Environment: NUL-terminated strings until an empty one.
        let prefix = Array("TMPDIR=".utf8)
        while index < buffer.count {
            let entryStart = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            let entry = buffer[entryStart..<index]
            index += 1
            if entry.isEmpty { break }
            if entry.starts(with: prefix) {
                return String(bytes: entry.dropFirst(prefix.count), encoding: .utf8)
            }
        }
        return nil
    }
}
