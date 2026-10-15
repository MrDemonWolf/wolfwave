//
//  SongBlocklist.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-04-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Pluggable byte-level persistence for `SongBlocklist`.
///
/// Production wires this to UserDefaults; tests inject an in-memory
/// implementation to avoid the macos-26 GitHub runner's JSON-via-defaults
/// crash that surfaces as `malloc: pointer being freed was not allocated`
/// the first time the blocklist persists state inside an xctest host.
nonisolated protocol BlocklistStorage: AnyObject, Sendable {
    /// The encoded `[BlocklistItem]` JSON, or `nil` when nothing is stored.
    func read() -> Data?
    /// Replaces the stored bytes. Called from the `SongBlocklist` actor.
    func write(_ data: Data)
}

/// Default UserDefaults-backed storage used by the running app.
///
/// `@unchecked Sendable`: `UserDefaults` is thread-safe but not declared
/// `Sendable`, and both stored properties are immutable.
nonisolated final class UserDefaultsBlocklistStorage: BlocklistStorage, @unchecked Sendable {
    private let key: String
    private let defaults: UserDefaults

    /// Creates storage over one `UserDefaults` key.
    ///
    /// - Parameters:
    ///   - key: UserDefaults key holding the encoded blocklist.
    ///   - defaults: UserDefaults store to read/write. Defaults to
    ///     ``DefaultsStore/store``.
    init(
        key: String = AppConstants.UserDefaults.songRequestBlocklist,
        defaults: UserDefaults = DefaultsStore.store
    ) {
        self.key = key
        self.defaults = defaults
    }

    /// Returns the raw stored bytes, or `nil` when the key is unset.
    func read() -> Data? { defaults.data(forKey: key) }

    /// Persists `data` under the configured key.
    func write(_ data: Data) { defaults.set(data, forKey: key) }
}

/// In-memory storage suitable for unit tests, no UserDefaults round-trip.
nonisolated final class InMemoryBlocklistStorage: BlocklistStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    /// Creates storage holding `initialData` until the first write.
    ///
    /// - Parameter initialData: Optional seed payload returned by the first `read()`.
    init(initialData: Data? = nil) { self.data = initialData }

    /// Returns the currently-held payload (thread-safe via NSLock).
    func read() -> Data? { lock.withLock { data } }

    /// Replaces the held payload atomically.
    func write(_ data: Data) { lock.withLock { self.data = data } }
}

/// Manages a persistent blocklist of songs and artists.
///
/// Blocked entries are stored as JSON via the injected `BlocklistStorage`.
/// Matching is case-insensitive. Implemented as an `actor` so mutation safety
/// is enforced by the compiler. Replaces the prior `final class + NSLock`.
///
/// Three entry kinds share one list: `.song` and `.artist` are checked by
/// ``isBlocked(title:artist:)`` after a request resolves; `.requester` is
/// checked by ``isBlockedRequester(_:)`` before any lookup.
actor SongBlocklist {
    // MARK: - Properties

    /// Entries in insertion order, as persisted.
    private var entries: [BlocklistItem] = []
    private let storage: BlocklistStorage
    /// Cleared for good by ``prepareForFactoryReset()``; every mutator checks it.
    private var acceptsMutations = true

    // MARK: - Init

    /// Creates a blocklist backed by `storage`.
    ///
    /// Loads synchronously. Unreadable stored bytes start an empty list (they
    /// are not overwritten until the next mutation).
    ///
    /// - Parameter storage: Pluggable byte-level persistence. Defaults to
    ///   `UserDefaultsBlocklistStorage`. Tests inject `InMemoryBlocklistStorage`.
    init(storage: BlocklistStorage = UserDefaultsBlocklistStorage()) {
        self.storage = storage
        // Inline the load logic, calling an actor-isolated method from a
        // nonisolated init is a Swift 6 error. Mutating stored properties
        // directly during init is allowed and equivalent.
        if let data = storage.read(),
           let decoded = try? JSONCoders.camelCase.decode([BlocklistItem].self, from: data) {
            self.entries = decoded
        }
    }

    // MARK: - Public API

    /// All current blocklist entries.
    var allEntries: [BlocklistItem] { entries }

    /// Drains earlier actor work, clears persistence, and permanently rejects
    /// later writes from UI or Stream Deck tasks that captured this owner before
    /// factory reset detached it. The app discards this instance after reset.
    func prepareForFactoryReset() {
        acceptsMutations = false
        entries.removeAll()
        save()
    }

    /// Atomically replaces the actor-isolated and persisted blocklist during
    /// settings import. Invalid bytes leave the current entries untouched.
    ///
    /// - Parameter data: Encoded `[BlocklistItem]`. Must pass
    ///   `BlocklistItem.normalizedForImport` (no duplicate IDs or entries).
    /// - Returns: `false` when the data was rejected or the list is retired
    ///   for factory reset.
    @discardableResult
    func replaceFromImportedData(_ data: Data) -> Bool {
        guard acceptsMutations else { return false }
        guard let decoded = try? JSONCoders.camelCase.decode(
            [BlocklistItem].self,
            from: data
        ),
        let imported = BlocklistItem.normalizedForImport(decoded),
        let normalizedData = try? JSONCoders.camelCaseEncoder.encode(imported)
        else { return false }
        entries = imported
        storage.write(normalizedData)
        return true
    }

    /// Check if a song is blocked by title or artist.
    ///
    /// A `.song` entry matches on normalized title alone, so it blocks every
    /// song with that title whatever the artist. Bracketed suffixes such as
    /// "(Remastered)" are ignored on both sides (see ``TrackTextNormalizer/title(_:)``).
    /// An `.artist` entry matches any name in the credit (see
    /// ``TrackTextNormalizer/artistCandidates(_:)``).
    ///
    /// - Parameters:
    ///   - title: The song title to check.
    ///   - artist: The artist name to check.
    /// - Returns: `true` if the song or its artist is on the blocklist.
    func isBlocked(title: String, artist: String) -> Bool {
        let loweredTitle = TrackTextNormalizer.title(title)
        let artistCandidates = TrackTextNormalizer.artistCandidates(artist)
        return entries.contains { entry in
            switch entry.type {
            case .song:
                return TrackTextNormalizer.title(entry.value) == loweredTitle
            case .artist:
                return artistCandidates.contains(TrackTextNormalizer.text(entry.value))
            case .requester:
                // A person, not a song. Checked by `isBlockedRequester`.
                return false
            }
        }
    }

    /// Whether this viewer is barred from requesting anything.
    ///
    /// Separate from ``isBlocked(title:artist:)`` because it answers a
    /// different question at a different point: the requester is known before a
    /// query is resolved, so a blocked person costs no MusicKit lookup.
    ///
    /// - Parameter username: Twitch username, matched case-insensitively.
    /// - Returns: `true` when the username is on the blocklist.
    func isBlockedRequester(_ username: String) -> Bool {
        let lowered = TrackTextNormalizer.text(username)
        guard !lowered.isEmpty else { return false }
        return entries.contains { $0.type == .requester && TrackTextNormalizer.text($0.value) == lowered }
    }

    /// Add a song, artist, or requester to the blocklist.
    ///
    /// The value is trimmed; blank values and case- / diacritic-insensitive
    /// duplicates of the same type are ignored. The same text may exist once
    /// per type (blocking a person never blocks a song of the same name).
    ///
    /// - Parameter item: The blocklist entry to add.
    func add(_ item: BlocklistItem) {
        guard acceptsMutations else { return }
        let trimmed = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !entries.contains(where: {
            $0.type == item.type && TrackTextNormalizer.text($0.value) == TrackTextNormalizer.text(trimmed)
        }) else { return }
        entries.append(BlocklistItem(id: item.id, value: trimmed, type: item.type, addedAt: item.addedAt))
        save()
    }

    /// Remove an entry from the blocklist by its identifier.
    ///
    /// - Parameter id: Identifier of the `BlocklistItem` to delete. Unknown
    ///   IDs are a silent no-op.
    func remove(id: UUID) {
        guard acceptsMutations else { return }
        entries.removeAll { $0.id == id }
        save()
    }

    /// Remove all entries from the blocklist.
    func clearAll() {
        guard acceptsMutations else { return }
        entries.removeAll()
        save()
    }

    // MARK: - Persistence

    /// Encodes a snapshot of `entries` and writes it through `storage`.
    /// Called after every mutation.
    private func save() {
        guard let data = try? JSONCoders.camelCaseEncoder.encode(entries) else { return }
        storage.write(data)
    }
}

/// Shared comparison rules for track metadata and user-entered blocklist values.
///
/// Also used outside the blocklist (for example `ArtworkService` matching
/// iTunes results), so changing a rule changes those matches too.
nonisolated enum TrackTextNormalizer {
    /// Case- and diacritic-folded text with runs of whitespace collapsed to one
    /// space and the ends trimmed. POSIX locale keeps folding identical on
    /// every Mac regardless of the user's language.
    static func text(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Separators between credited artists, as they appear after ``text(_:)``.
    static let artistSeparators = [" & ", ", ", " feat. ", " ft. ", " featuring ", " x "]

    /// Every name an artist blocklist entry may match for one track's artist
    /// credit: the whole credit, each single credited name, and each run of
    /// adjacent names re-joined with the separators that really sat between
    /// them.
    ///
    /// The runs are what keep a comma-named act blockable inside a
    /// collaboration: for "Tyler, The Creator & Kali Uchis" the candidates
    /// include "tyler, the creator". Splitting alone would only offer "tyler",
    /// "the creator" and "kali uchis", so the entry would never match.
    ///
    /// Known limit: a single word of a comma-named act still matches, so an
    /// entry "Wind" blocks "Earth, Wind & Fire". Strings can't tell a
    /// comma-named act from a comma-separated collaboration; only per-artist
    /// catalog identity could.
    ///
    /// - Parameter artist: The raw artist credit from the catalog.
    /// - Returns: Normalized candidate names.
    static func artistCandidates(_ artist: String) -> Set<String> {
        let credit = text(artist)
        var candidates: Set<String> = [credit]
        let pieceRanges = artistPieceRanges(in: credit)
        for start in pieceRanges.indices {
            for end in start..<pieceRanges.count {
                // Slicing the credit keeps the original separators in each run.
                let run = text(String(credit[pieceRanges[start].lowerBound..<pieceRanges[end].upperBound]))
                if !run.isEmpty { candidates.insert(run) }
            }
        }
        return candidates
    }

    /// Splits a normalized credit into the ranges of its individual names,
    /// scanning left to right for the earliest separator (longest on a tie).
    private static func artistPieceRanges(in credit: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var pieceStart = credit.startIndex
        var searchStart = credit.startIndex
        while searchStart < credit.endIndex {
            let next = artistSeparators
                .compactMap { credit.range(of: $0, range: searchStart..<credit.endIndex) }
                .min { lhs, rhs in
                    lhs.lowerBound != rhs.lowerBound
                        ? lhs.lowerBound < rhs.lowerBound
                        : lhs.upperBound > rhs.upperBound
                }
            guard let separator = next else { break }
            ranges.append(pieceStart..<separator.lowerBound)
            pieceStart = separator.upperBound
            searchStart = separator.upperBound
        }
        ranges.append(pieceStart..<credit.endIndex)
        return ranges
    }

    /// ``text(_:)`` for a song title after removing every `(…)` and `[…]`
    /// group (one nesting level) and a trailing YouTube-style " - Topic", so
    /// "Song (Remastered 2011)" and "Song [Live]" compare equal to "Song".
    static func title(_ value: String) -> String {
        text(value.replacingOccurrences(
            of: #"\([^()]*\)|\[[^\[\]]*\]"#,
            with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+-\s+Topic\s*$"#, with: "", options: .regularExpression))
    }
}
