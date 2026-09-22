//
//  Pasteboard.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-06-01.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit

/// Thin wrapper over `NSPasteboard.general` plain-text writes.
///
/// Collapses the repeated `clearContents()` + `setString(_:forType: .string)`
/// dance into one call so there is a single place that touches the system
/// pasteboard. `CopyButton` and the ad-hoc copy affordances in the Debug,
/// About, and Advanced panes route through here.
enum Pasteboard {

    /// Long enough to paste into Stream Deck, short enough not to leave a
    /// reusable credential sitting on the shared clipboard indefinitely.
    private static let sensitiveLifetime: Duration = .seconds(30)

    /// Replaces the general pasteboard contents with `string` as plain text.
    ///
    /// - Parameter string: The text to place on the pasteboard.
    /// - Returns: `true` if the write succeeded.
    @discardableResult
    static func copy(_ string: String, sensitive: Bool = false) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(string, forType: .string) else { return false }

        if sensitive {
            let changeCount = pasteboard.changeCount
            Task { @MainActor in
                try? await Task.sleep(for: sensitiveLifetime)
                clearIfUnchanged(string, changeCount: changeCount, from: .general)
            }
        }
        return true
    }

    /// Clears only the value this app wrote. A user's newer clipboard contents
    /// must never be erased by the delayed sensitive-value cleanup.
    @discardableResult
    static func clearIfUnchanged(
        _ expectedString: String,
        changeCount: Int,
        from pasteboard: NSPasteboard
    ) -> Bool {
        guard pasteboard.changeCount == changeCount,
              pasteboard.string(forType: .string) == expectedString else { return false }
        pasteboard.clearContents()
        return true
    }
}
