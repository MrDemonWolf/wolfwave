//
//  StringFormatting.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-06-04.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Small, shared `String` shaping helpers for chat replies and UI labels.
///
/// Centralizes the truncation idioms that were duplicated across the Twitch
/// command replies (`!sr` not-found messages, bit-cheer fallbacks) so the
/// length cap and ellipsis live in one place instead of repeated inline
/// `count > 30 ? prefix(30) + "..."` expressions.
nonisolated enum StringFormatting {

    /// Truncates `text` to `maxLength` characters, appending an ellipsis when it
    /// was shortened. Returns the original string when it already fits.
    ///
    /// Counts `Character`s, and the three-dot suffix is added on top of
    /// `maxLength`. For the hard Twitch limit use `truncatedForChat()` instead.
    ///
    /// Used for echoing a viewer's search query back into chat without letting a
    /// pasted wall of text blow past Twitch's message limit.
    static func truncatedWithEllipsis(_ text: String, maxLength: Int = 30) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength)) + "..."
    }
}

// MARK: - Twitch Chat Truncation

nonisolated extension String {
    /// Truncates the string so it fits within Twitch chat's 500-character
    /// per-message limit, appending the configured truncation suffix
    /// (`AppConstants.Twitch.messageTruncationSuffix`) when shortened.
    ///
    /// Shared by the bot command replies (`TrackInfoCommand`, `InfoCommand`,
    /// `SongListCommand`, custom commands) and `TwitchChatService`'s outbound
    /// send path.
    ///
    /// Twitch measures the limit in Unicode code points, not in what Swift
    /// calls a `Character`. A family emoji or a flag is one `Character` but
    /// several scalars, so a grapheme count let an emoji-heavy reply through
    /// that Twitch then rejected. The cut is still made on a `Character`
    /// boundary, so an emoji is never split into a broken half.
    ///
    /// - Returns: `self` when it fits, otherwise a prefix of whole `Character`s
    ///   plus the suffix whose `unicodeScalars` count does not exceed
    ///   `AppConstants.Twitch.maxMessageLength`.
    func truncatedForChat() -> String {
        let maxLen = AppConstants.Twitch.maxMessageLength
        guard unicodeScalars.count > maxLen else { return self }
        let suffix = AppConstants.Twitch.messageTruncationSuffix
        let budget = max(maxLen - suffix.unicodeScalars.count, 0)

        var used = 0
        var end = startIndex
        for character in self {
            let cost = character.unicodeScalars.count
            guard used + cost <= budget else { break }
            used += cost
            end = index(after: end)
        }
        return String(self[..<end]) + suffix
    }
}
