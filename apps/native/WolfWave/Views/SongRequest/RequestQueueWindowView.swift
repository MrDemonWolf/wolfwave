//
//  RequestQueueWindowView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-11-23.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import MusicKit
import SwiftUI

/// The live song-request queue in its own small window, so the streamer can
/// approve, reorder, and remove requests mid-stream without opening Settings.
///
/// A native `List` with selection: right-click for the actions that apply,
/// drag to reorder, Delete removes, Return or double-click approves a waiting
/// request (or plays a queued one next). Skip, Hold, Keep on Top, and Clear
/// live in the toolbar. Refreshes on the same queue notifications as the
/// Settings queue card.
struct RequestQueueWindowView: View {
    // MARK: - Dependencies

    /// The service that runs skip, hold, approve, and clear (`nil` in previews).
    private var service: SongRequestService? { AppDelegate.shared?.songRequestService }

    /// The live queue.
    private var queue: SongRequestQueue? { service?.queue }

    // MARK: - State

    @State private var items: [SongRequestItem] = []
    @State private var pending: [SongRequestItem] = []
    @State private var nowPlaying: SongRequestItem?
    @State private var isHeld = false
    @State private var waitText: String?
    @State private var selection = Set<UUID>()
    @State private var showingClearConfirm = false

    /// Floats the window above others; read by `WolfWaveApp`'s scene.
    @AppStorage(AppConstants.UserDefaults.requestQueueWindowOnTop) private var keepOnTop = false

    /// Nothing playing, queued, or waiting.
    private var isEmpty: Bool { items.isEmpty && pending.isEmpty && nowPlaying == nil }

    // MARK: - Body

    var body: some View {
        List(selection: $selection) {
            if let nowPlaying {
                Section("Playing Now") {
                    row(nowPlaying, detail: "requested by \(nowPlaying.requesterUsername)")
                        .tag(nowPlaying.id)
                }
            }
            if !pending.isEmpty {
                Section("Needs Approval (\(pending.count))") {
                    ForEach(pending) { item in
                        pendingRow(item).tag(item.id)
                    }
                }
            }
            if !items.isEmpty {
                Section(upNextTitle) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item, detail: "#\(index + 1) · \(item.requesterUsername)")
                            .tag(item.id)
                    }
                    .onMove { source, destination in
                        queue?.move(fromOffsets: source, toOffset: destination)
                        refresh()
                    }
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            Task { await primaryAction(ids) }
        }
        .onDeleteCommand { removeSelected() }
        .overlay { if isEmpty { emptyState } }
        .toolbar { toolbarContent }
        .navigationTitle("Request Queue")
        .navigationSubtitle(subtitle)
        .frame(minWidth: 340, minHeight: 300)
        .confirmationDialog(
            "Clear the queue and request playlist?",
            isPresented: $showingClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Requests", role: .destructive) {
                Task {
                    _ = await service?.clearQueueAndRequestsPlaylist()
                    refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Songs stay in your Apple Music library. Channel points for songs that haven't played are refunded.")
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .songRequestQueueChanged)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .songRequestHoldChanged)) { _ in refresh() }
    }

    // MARK: - Rows

    /// One request: artwork, title, artist, and a detail line.
    private func row(_ item: SongRequestItem, detail: String) -> some View {
        HStack(spacing: DSSpace.s3) {
            AlbumArtView(url: item.song.artwork?.url(width: 80, height: 80), size: 36)
            VStack(alignment: .leading, spacing: DSSpace.s0) {
                Text(item.title)
                    .font(.system(size: DSFont.Size.base, weight: .medium))
                    .lineLimit(1)
                Text("\(item.artist) · \(detail)")
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DSSpace.s0)
        .accessibilityElement(children: .combine)
    }

    /// A waiting request with inline Approve and Decline buttons.
    private func pendingRow(_ item: SongRequestItem) -> some View {
        HStack(spacing: DSSpace.s2) {
            row(item, detail: "requested by \(item.requesterUsername)")
            Button("Approve", systemImage: "checkmark") {
                Task { await approve(item.id) }
            }
            .labelStyle(.iconOnly)
            .help("Approve")
            .accessibilityLabel("Approve \(item.title)")
            Button("Decline", systemImage: "xmark") { decline(item.id) }
                .labelStyle(.iconOnly)
                .help("Decline")
                .accessibilityLabel("Decline \(item.title)")
        }
    }

    /// Shown when nothing is playing, queued, or waiting.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Requests Yet", systemImage: "music.note.list")
        } description: {
            Text(isHeld ? "Requests are on hold. New ones still join the queue." : "Chat requests songs with !sr.")
        }
    }

    // MARK: - Context Menu

    /// The actions that apply to the clicked or selected rows. Items that
    /// don't apply are left out rather than dimmed (HIG: context menus).
    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        let queued = items.filter { ids.contains($0.id) }
        let waiting = pending.filter { ids.contains($0.id) }
        let playing = nowPlaying.flatMap { ids.contains($0.id) ? $0 : nil }

        if !waiting.isEmpty {
            Button(waiting.count == 1 ? "Approve" : "Approve \(waiting.count)") {
                Task { for item in waiting { await approve(item.id) } }
            }
            Button(waiting.count == 1 ? "Decline" : "Decline \(waiting.count)") {
                waiting.forEach { decline($0.id) }
            }
        }
        if queued.count == 1, let item = queued.first {
            Button("Play Next") { queue?.moveToFront(id: item.id); refresh() }
        }
        if !queued.isEmpty {
            Button(queued.count == 1 ? "Remove" : "Remove \(queued.count)") { remove(queued) }
        }
        if playing != nil {
            Button("Skip") { Task { _ = await service?.skip(); refresh() } }
        }
        let all = queued + waiting + (playing.map { [$0] } ?? [])
        if all.count == 1, let item = all.first {
            Divider()
            if let url = item.song.url {
                Button("Open in Apple Music") { NSWorkspace.shared.open(url) }
            }
            Button("Block Song") { block(item.title, as: .song) }
            Button("Block \(item.requesterUsername)") { block(item.requesterUsername, as: .requester) }
        }
    }

    /// Return or double-click: approve waiting rows, play a queued row next.
    private func primaryAction(_ ids: Set<UUID>) async {
        let waiting = pending.filter { ids.contains($0.id) }
        if !waiting.isEmpty {
            for item in waiting { await approve(item.id) }
        } else if ids.count == 1, let id = ids.first, items.contains(where: { $0.id == id }) {
            queue?.moveToFront(id: id)
            refresh()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Skip", systemImage: "forward.fill") {
                Task { _ = await service?.skip(); refresh() }
            }
            .disabled(nowPlaying == nil)
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .help("Skip the request playing now (⌘→)")

            Button(isHeld ? "Resume" : "Hold", systemImage: isHeld ? "play.fill" : "pause.fill") {
                Task { await service?.setHold(!isHeld); refresh() }
            }
            .help(isHeld ? "Resume requests" : "Hold requests: they still queue, but nothing plays")

            Toggle("Keep on Top", systemImage: "pin", isOn: $keepOnTop)
                .help("Keep this window above other windows")

            Button("Clear Requests", systemImage: "trash") { showingClearConfirm = true }
                .disabled(isEmpty)
                .help("Clear the queue and the WolfWave Requests playlist")
        }
    }

    // MARK: - Text

    /// "Up Next (4) · about 14 min" when the queue has a known length.
    private var upNextTitle: String {
        guard let waitText else { return "Up Next (\(items.count))" }
        return "Up Next (\(items.count)) · \(waitText)"
    }

    /// Window subtitle: hold state, or how many requests are waiting.
    private var subtitle: String {
        if isHeld { return "On hold" }
        let waiting = items.count + pending.count
        return waiting == 0 ? "Empty" : "\(waiting) waiting"
    }

    // MARK: - Actions

    private func approve(_ id: UUID) async {
        _ = await service?.approve(id: id)
        selection.remove(id)
        refresh()
    }

    private func decline(_ id: UUID) {
        _ = service?.reject(id: id)
        selection.remove(id)
        refresh()
    }

    private func remove(_ targets: [SongRequestItem]) {
        for item in targets { queue?.remove(id: item.id) }
        selection.subtract(targets.map(\.id))
        refresh()
    }

    /// Delete key: removes selected queued rows and declines selected waiting ones.
    private func removeSelected() {
        remove(items.filter { selection.contains($0.id) })
        pending.filter { selection.contains($0.id) }.forEach { decline($0.id) }
    }

    private func block(_ value: String, as type: BlocklistItem.BlockType) {
        guard let blocklist = service?.blocklist else { return }
        Task { await blocklist.add(BlocklistItem(value: value, type: type)) }
    }

    // MARK: - Refresh

    /// Snapshots the live queue. Assigns only on change, so a burst of queue
    /// notifications doesn't re-diff the list each time.
    private func refresh() {
        let newItems = queue?.items ?? []
        if newItems.map(\.id) != items.map(\.id) { items = newItems }
        let newPending = queue?.pending ?? []
        if newPending.map(\.id) != pending.map(\.id) { pending = newPending }
        let newNowPlaying = queue?.nowPlaying
        if newNowPlaying?.id != nowPlaying?.id { nowPlaying = newNowPlaying }
        let newHeld = service?.isHoldEnabled ?? false
        if newHeld != isHeld { isHeld = newHeld }

        let newWait: String? = {
            guard let service, !newItems.isEmpty, !newHeld else { return nil }
            if case .minutes(let minutes) = service.estimatedWait(forPosition: newItems.count + 1) {
                return "about \(minutes) min"
            }
            return nil
        }()
        if newWait != waitText { waitText = newWait }

        let live = Set(newItems.map(\.id) + newPending.map(\.id) + [newNowPlaying?.id].compactMap { $0 })
        if !selection.isSubset(of: live) { selection.formIntersection(live) }
    }
}

// MARK: - Preview

#Preview("Request Queue (empty)") {
    RequestQueueWindowView()
        .frame(width: 400, height: 480)
}
