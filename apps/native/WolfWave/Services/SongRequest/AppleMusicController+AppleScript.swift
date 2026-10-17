//
//  AppleMusicController+AppleScript.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import Foundation

/// AppleScript plumbing: input sanitizing, script builders, the compiled-script
/// cache, focus-preserving execution, and failure mapping.
extension AppleMusicController {

    // MARK: - Private Helpers

    /// Sanitize a string for safe inclusion in an AppleScript string literal.
    ///
    /// Escapes backslashes and double quotes, then strips ASCII control characters
    /// (U+0000-U+001F, U+007F) which could break out of AppleScript string literals.
    func sanitizeForAppleScript(_ input: String) -> String {
        let escaped = input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return escaped.unicodeScalars
            .filter { $0.value >= 32 && $0.value != 127 }
            .map(String.init)
            .joined()
    }

    /// AppleScript source that reveals a playlist by name.
    ///
    /// Contains only `reveal`. Music is brought forward from Swift via
    /// `NSRunningApplication`, not an AppleScript `activate`, so macOS
    /// cooperative activation and the focus-restoration policy stay in AppKit's
    /// hands rather than being forced by the script.
    ///
    /// - Parameter playlistName: Playlist to select, sanitized before embedding.
    /// - Returns: AppleScript source addressed at Music.
    func revealScript(playlistName: String) -> String {
        Self.musicTargetedScript("""
        reveal playlist "\(sanitizeForAppleScript(playlistName))"
        """, seconds: ScriptTimeout.command)
    }

    /// AppleScript source that rejects a playback mutation unless the loaded
    /// track still has the exact name-and-artist key captured for the vote.
    ///
    /// The key is split on its tab and rebuilt as `"name" & tab & "artist"` so
    /// each half is sanitized on its own and the tab survives as a real
    /// AppleScript `tab`. On mismatch the script returns `"stale"` before the
    /// caller's mutation runs. Must be placed inside `musicTargetedScript`'s `tell`.
    func targetGuardSource(for trackKey: String) -> String {
        let expected = trackKey
            .components(separatedBy: "\t")
            .map { "\"\(sanitizeForAppleScript($0))\"" }
            .joined(separator: " & tab & ")
        return """
        set currentKey to ""
        try
            set currentKey to (get name of current track) & tab & (get artist of current track)
        end try
        if currentKey is not (\(expected)) then return "stale"
        """
    }

    /// Builds a script addressed at Music by bundle id, gated on Music actually
    /// being alive.
    ///
    /// ## Why not address by process id
    ///
    /// A raw kernel-pid descriptor is an Apple Event *address*, not an
    /// application specifier. `NSAppleScript` has no way to consume one: handed
    /// to `tell` as a value it arrives as opaque `«data kpid…»` with no
    /// terminology bound, so AppleScript evaluates the body against a
    /// meaningless object and every property read fails `-1728` while every verb
    /// fails `-1708`. Only ScriptingBridge can genuinely address by pid; see
    /// `MusicProcess`.
    ///
    /// ## Why the in-script running check
    ///
    /// A bundle-id `tell` is auto-launched by LaunchServices, which is how
    /// "WolfWave keeps reopening Music" shipped twice (PR #203, PR #273). Callers
    /// already resolve `MusicProcess.pid` first, but that leaves a check-then-send
    /// window across the Swift/AppleScript boundary. Re-checking *inside* the
    /// script narrows that window to the microseconds between two adjacent
    /// AppleScript statements. `is running` is answered without launching the
    /// target, and the `error` aborts before the `tell` block is ever entered.
    ///
    /// Raising `-600` (`procNotFound`) rather than returning a sentinel keeps a
    /// closed Music on the path callers already handle: `scriptFailure(from:)`
    /// reads the number straight out of Foundation's error dictionary, and both
    /// `requireCommandSuccess` and `playFromRequestsPlaylist` already translate
    /// `-600` into `PlaybackError.musicAppNotRunning`. This guard shipped in
    /// PR #392 and was lost in PR #410; do not remove it again.
    ///
    /// - Parameters:
    ///   - body: Music terminology to execute inside the `tell`.
    ///   - seconds: Apple Event reply timeout; see `ScriptTimeout`.
    static func musicTargetedScript(_ body: String, seconds: Int) -> String {
        """
        with timeout of \(seconds) seconds
            if application id "\(AppConstants.Music.bundleIdentifier)" is not running then error "Music is not running" number -600
            tell application id "\(AppConstants.Music.bundleIdentifier)"
        \(body)
            end tell
        end timeout
        """
    }

    /// Runs an AppleScript while preserving the user's focus when Music brings
    /// itself forward. Focus is restored only if Music is still frontmost after
    /// the short settling delay; a deliberate user switch is never overridden.
    ///
    /// The 150 ms sleep gives Music time to finish activating. If the task is
    /// cancelled during it, the script result is returned without touching focus.
    @discardableResult
    func runAppleScriptPreservingFocus(
        _ source: String,
        targetPID: pid_t
    ) async -> ScriptExecutionResult {
        let previousFrontApp = NSWorkspace.shared.frontmostApplication
        let result = runAppleScript(source, targetPID: targetPID)

        do {
            try await Task.sleep(for: .milliseconds(150))
        } catch {
            return result
        }

        let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if Self.shouldRestoreFocus(
            previousPID: previousFrontApp?.processIdentifier,
            currentPID: currentPID,
            musicPID: targetPID
        ) {
            previousFrontApp?.activate()
        }
        return result
    }

    /// Pure focus-restoration policy, internal so races are covered without
    /// activating real applications in tests.
    ///
    /// - Returns: `true` only when Music was not already frontmost before the
    ///   script and is frontmost now, i.e. the script (not the user) moved focus.
    static func shouldRestoreFocus(
        previousPID: pid_t?,
        currentPID: pid_t?,
        musicPID: pid_t
    ) -> Bool {
        guard let previousPID, let currentPID else { return false }
        return previousPID != musicPID && currentPID == musicPID
    }

    /// Runs NSAppleScript on the main actor, Foundation's documented supported
    /// execution context. ScriptTimeout bounds how long a wedged target can
    /// block that actor.
    ///
    /// `targetPID` is a cheap pre-filter, not the address: requiring it makes
    /// callers resolve Music's pid first, so a quit Music short-circuits before
    /// any script runs. The event itself is addressed by bundle id, because a
    /// raw kernel-pid descriptor is not an application specifier. See
    /// `musicTargetedScript` for why, and for the in-script `is running` guard
    /// that closes the check-then-send window this pre-filter alone would leave
    /// open.
    @MainActor
    @discardableResult
    func runAppleScript(
        _ source: String,
        targetPID _: pid_t
    ) -> ScriptExecutionResult {
        executeAppleScript(source)
    }

    /// Returns a cached compiled script, clearing the small bounded cache before
    /// dynamic track metadata can make it grow indefinitely.
    private func compiledScript(for source: String) -> NSAppleScript? {
        if let cached = compiledScripts[source] { return cached }
        guard let fresh = NSAppleScript(source: source) else { return nil }
        if compiledScripts.count >= Self.compiledScriptsCap {
            compiledScripts.removeAll(keepingCapacity: true)
        }
        compiledScripts[source] = fresh
        return fresh
    }

    /// Executes the script and preserves the Apple Event error number instead of
    /// collapsing every failure into a successful nil result.
    private func executeAppleScript(_ source: String) -> ScriptExecutionResult {
        guard let script = compiledScript(for: source) else {
            return .failure(ScriptFailure(
                number: nil,
                message: "Could not create AppleScript from source."
            ))
        }

        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            let failure = Self.scriptFailure(from: error)
            Log.warn(
                "AppleMusicController: AppleScript error \(failure.number.map(String.init) ?? "unknown"): \(failure.message)",
                category: .songRequest
            )
            return .failure(failure)
        }
        return .success(descriptor.stringValue)
    }

    /// Converts Foundation's loosely typed AppleScript dictionary into the
    /// controller's structured, Sendable error value.
    static func scriptFailure(from error: NSDictionary) -> ScriptFailure {
        let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        let message = (error[NSAppleScript.errorMessage] as? String)
            ?? (error[NSAppleScript.errorBriefMessage] as? String)
            ?? "Unknown AppleScript error"
        return ScriptFailure(number: number, message: message)
    }

    /// Throws the public playback error corresponding to a failed command.
    ///
    /// `-600` / `-609` (Music gone or quit mid-event) become
    /// `.musicAppNotRunning` so callers buffer instead of reporting an error;
    /// everything else is `.commandFailed`. Success, including a `"stale"`
    /// output, does not throw.
    func requireCommandSuccess(
        _ result: ScriptExecutionResult,
        command: String
    ) throws {
        guard case .failure(let failure) = result else { return }
        if failure.number == -600 || failure.number == -609 {
            throw PlaybackError.musicAppNotRunning
        }
        throw PlaybackError.commandFailed(command: command, message: failure.message)
    }

    /// Launches Music only for the explicit Reveal action, then waits briefly for
    /// its process identifier to become observable before dispatching the event.
    ///
    /// Polls up to 20 times at 100 ms (about 2 s). Returns silently on timeout or
    /// if Music.app isn't installed; the caller re-checks `MusicProcess.pid`.
    func ensureMusicRunningForReveal() async {
        guard MusicProcess.pid == nil else { return }
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Music"
        ) else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            )
            for _ in 0..<20 {
                if MusicProcess.pid != nil { return }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            Log.warn(
                "AppleMusicController: Could not launch Music.app: \(error.localizedDescription)",
                category: .songRequest
            )
        }
    }
}
