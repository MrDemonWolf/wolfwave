//
//  MenuTitleFormatting.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-11.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Pure helpers that keep tray / Dock menu rows a sane width.
///
/// A song or request title can be hundreds of characters long, and a menu
/// row grows to fit it. Clamp the visible title and keep the full text in the
/// item's tooltip.
nonisolated enum MenuTitleFormatting {

    /// Longest visible title, in characters, before the row is clamped.
    static let maxTitleLength = 40

    /// Returns `text` unchanged when it fits, otherwise the first
    /// `maxLength - 1` characters followed by a single ellipsis character
    /// (so the result is never longer than `maxLength`).
    static func clamped(_ text: String, maxLength: Int = maxTitleLength) -> String {
        guard maxLength > 1, text.count > maxLength else { return text }
        return String(text.prefix(maxLength - 1)) + "\u{2026}"
    }

    /// The tooltip for a clamped row: the full text when it was shortened,
    /// `nil` when the row already shows everything.
    static func tooltip(for text: String, maxLength: Int = maxTitleLength) -> String? {
        text.count > maxLength ? text : nil
    }
}
