//
//  SongRequestSettingsView+Blocklist.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

// Blocklist card for the Song Requests settings pane.

// MARK: - Blocklist

/// Add / remove / clear blocklist entries (song, artist, or requester).
/// The list is an `@State` copy of the actor-owned `SongBlocklist`, re-read
/// after every mutation.
struct SongRequestBlocklistCard: View {
    /// Resolves the live blocklist on each use, so a service restarted under
    /// the pane is picked up. `nil` (no service) makes every action a no-op.
    let blocklistProvider: () -> SongBlocklist?

    /// Text being typed for a new entry.
    @State private var blocklistText = ""
    /// Kind of entry the next Add creates.
    @State private var blocklistType: BlocklistItem.BlockType = .song
    /// Snapshot of the blocklist for display.
    @State private var blocklist: [BlocklistItem] = []
    /// Presents the Clear All confirmation.
    @State private var showClearAllAlert = false

    /// Field placeholder for the selected entry type.
    private var blocklistPlaceholder: String {
        switch blocklistType {
        case .song: "Song title..."
        case .artist: "Artist name..."
        case .requester: "Twitch username..."
        }
    }

    /// Row glyph for an entry type.
    private static func blocklistSymbol(for type: BlocklistItem.BlockType) -> String {
        switch type {
        case .song: "music.note"
        case .artist: "person.fill"
        case .requester: "person.slash.fill"
        }
    }

    /// Adds the typed value as the selected entry type. Shared by the Add
    /// button and Return in the text field, so both paths behave the same.
    private func addEntry() async {
        let trimmed = blocklistText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let item = BlocklistItem(value: trimmed, type: blocklistType)
        let provider = blocklistProvider()
        blocklistText = ""
        await provider?.add(item)
        blocklist = await provider?.allEntries ?? []
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            HStack {
                Text("Blocklist")
                    .font(.system(size: DSFont.Size.base, weight: .semibold))

                Spacer()

                Button(role: .destructive) {
                    showClearAllAlert = true
                } label: {
                    Label("Clear All", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(blocklist.isEmpty)
                .accessibilityIdentifier("blocklist.clearAll")
            }

            Text("Block specific songs, artists, or people from being requested.")
                .font(.system(size: DSFont.Size.sm))
                .foregroundStyle(.secondary)

            HStack(spacing: DSSpace.s2) {
                Picker("Blocklist entry type", selection: $blocklistType) {
                    Text("Song").tag(BlocklistItem.BlockType.song)
                    Text("Artist").tag(BlocklistItem.BlockType.artist)
                    Text("Person").tag(BlocklistItem.BlockType.requester)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)

                TextField(blocklistPlaceholder, text: $blocklistText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: DSFont.Size.body))
                    .onSubmit { Task { await addEntry() } }
                    .accessibilityLabel("Blocklist entry")
                    .accessibilityIdentifier("songRequests.blocklist.field")

                AsyncActionButton(
                    title: "Add",
                    style: .borderedProminent,
                    isDisabled: blocklistText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    showsSuccess: false,
                    accessibilityIdentifier: "songRequests.blocklist.add"
                ) {
                    await addEntry()
                }
            }

            if !blocklist.isEmpty {
                VStack(alignment: .leading, spacing: DSSpace.s1) {
                    ForEach(blocklist) { item in
                        HStack {
                            Image(systemName: Self.blocklistSymbol(for: item.type))
                                .font(.system(size: DSFont.Size.xs))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)

                            Text(item.value).font(.system(size: DSFont.Size.body))

                            Text(item.type.displayName)
                                .font(.system(size: DSFont.Size.xs))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, DSSpace.s2)
                                .padding(.vertical, DSSpace.s0)
                                .background(.quaternary)
                                .clipShape(Capsule())

                            Spacer()

                            DSIconButton(
                                systemImage: "xmark",
                                action: {
                                    let provider = blocklistProvider()
                                    Task {
                                        await provider?.remove(id: item.id)
                                        blocklist = await provider?.allEntries ?? []
                                    }
                                },
                                accessibilityLabel: "Remove \(item.value) from blocklist",
                                accessibilityIdentifier: "songRequests.blocklist.remove"
                            )
                            .help("Remove from blocklist")
                        }
                        .padding(.vertical, DSSpace.s0)
                    }
                }
                .padding(.top, DSSpace.s1)
            }
        }
        .cardStyle()
        .task {
            blocklist = await blocklistProvider()?.allEntries ?? []
        }
        .alert("Clear blocklist?", isPresented: $showClearAllAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                let provider = blocklistProvider()
                Task {
                    await provider?.clearAll()
                    blocklist = await provider?.allEntries ?? []
                }
            }
        } message: {
            Text("This removes every entry from your song-request blocklist. This cannot be undone.")
        }
    }
}
