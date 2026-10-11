//
//  SongRequestQueueView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-04-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import MusicKit
import SwiftUI

/// Displays the song request queue with per-row remove actions.
///
/// Shows the currently playing request (if any) and the upcoming queue.
/// Provides skip, hold/resume, and clear-queue actions for the streamer.
/// Rows are not reorderable; ordering follows request arrival (with bit-cheer
/// boosts handled upstream in `SongRequestQueue`).
struct SongRequestQueueView: View {
    // MARK: - Properties

    private var appDelegate: AppDelegate? {
        AppDelegate.shared
    }

    private var queue: SongRequestQueue? {
        appDelegate?.songRequestService?.queue
    }

    private var service: SongRequestService? {
        appDelegate?.songRequestService
    }

    @State private var items: [SongRequestItem] = []
    @State private var pending: [SongRequestItem] = []
    @State private var nowPlaying: SongRequestItem?
    @State private var showingClearConfirm = false
    @State private var isMusicAppClosed = false
    @State private var isHeld = false

    /// Nothing playing, queued, or waiting for approval.
    private var isQueueEmpty: Bool {
        items.isEmpty && nowPlaying == nil && pending.isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s6) {
            // Header
            HStack {
                Text("Song Request Queue")
                    .font(.system(size: DSFont.Size.base, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                if isHeld {
                    StatusChip(
                        text: "On hold",
                        color: DSColor.warning,
                        systemImage: StatusChip.StateGlyph.paused
                    )
                } else if isMusicAppClosed {
                    StatusChip(
                        text: "Music closed",
                        color: DSColor.warning,
                        systemImage: StatusChip.StateGlyph.paused
                    )
                } else if !items.isEmpty {
                    StatusChip(text: "\(items.count) in queue", color: DSColor.neutral)
                }
            }

            // Why nothing plays. Shown under the header so the chip's short
            // label always has a plain-language reason next to it. An empty
            // queue explains the hold in its own empty state instead.
            if isHeld {
                if !isQueueEmpty { heldNote }
            } else if isMusicAppClosed {
                statusNote("Music is closed. Requests are saved and play when it opens.")
            }

            // Pending approval (only populated when approval mode is on)
            if !pending.isEmpty {
                pendingSection
            }

            // Now Playing
            if let nowPlaying {
                nowPlayingRow(nowPlaying)
            }

            // Queue
            if isQueueEmpty {
                emptyState
            } else if items.isEmpty && nowPlaying != nil {
                Text("Queue is empty, this is the last requested song.")
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DSSpace.s2)
            } else if !items.isEmpty {
                queueList
            }

            // Actions. Held always shows them, so Resume stays reachable even
            // with an empty queue.
            if nowPlaying != nil || !items.isEmpty || !pending.isEmpty || isHeld {
                actionButtons
            }
        }
        .cardStyle()
        .onAppear { refreshState() }
        .onReceive(NotificationCenter.default.publisher(for: .songRequestQueueChanged)) { _ in
            refreshState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .songRequestHoldChanged)) { _ in
            refreshState()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { note in
            if (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == AppConstants.Music.bundleIdentifier {
                isMusicAppClosed = false
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { note in
            if (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == AppConstants.Music.bundleIdentifier {
                isMusicAppClosed = true
            }
        }
    }

    // MARK: - Now Playing Row

    /// Builds the highlighted "Now Playing" row at the top of the queue list,
    /// showing the artwork placeholder, waveform icon, title, artist, and
    /// requester username.
    ///
    /// - Parameter item: The currently-playing song request.
    /// - Returns: A styled row view.
    private func nowPlayingRow(_ item: SongRequestItem) -> some View {
        HStack(spacing: DSSpace.s3) {
            artworkPlaceholder

            VStack(alignment: .leading, spacing: DSSpace.s0) {
                HStack(spacing: DSSpace.s1h) {
                    Image(systemName: "waveform")
                        .font(.system(size: DSFont.Size.xs))
                        .foregroundStyle(DSColor.success)
                    // Primary, not the success tint: green text on the green
                    // wash is too faint to read. The glyph carries the accent.
                    Text("Now Playing")
                        .font(.system(size: DSFont.Size.xs, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                Text(item.title)
                    .font(.system(size: DSFont.Size.body, weight: .medium))
                    .lineLimit(1)
                Text("\(item.artist) · requested by \(item.requesterUsername)")
                    .font(.system(size: DSFont.Size.xs))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(DSSpace.s2)
        .background(DSColor.success.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Now playing: \(item.title), \(item.artist), requested by \(item.requesterUsername)"
        )
    }

    // MARK: - Pending Approval

    /// Requests waiting for the streamer to approve or decline. Each row offers a
    /// green Approve and a plain Decline. Only shown in approval mode.
    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: DSSpace.s1) {
            Text("Waiting for approval (\(pending.count))")
                .font(.system(size: DSFont.Size.xs, weight: .semibold))
                .foregroundStyle(DSColor.warning)

            ForEach(pending, id: \.id) { item in
                HStack(spacing: DSSpace.s3) {
                    smallArtworkPlaceholder

                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.system(size: DSFont.Size.body))
                            .lineLimit(1)
                        Text("\(item.artist) · requested by \(item.requesterUsername)")
                            .font(.system(size: DSFont.Size.xs))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "Awaiting approval: \(item.title), \(item.artist), requested by \(item.requesterUsername)"
                    )

                    Spacer()

                    AsyncActionButton(
                        title: "Approve",
                        systemImage: "checkmark",
                        tint: DSColor.success,
                        labelSize: DSFont.Size.sm,
                        showsSuccess: false,
                        accessibilityIdentifier: "songRequestQueue.approve"
                    ) {
                        _ = await service?.approve(id: item.id)
                        refreshState()
                    }
                    .accessibilityLabel("Approve \(item.title)")

                    DSIconButton(
                        systemImage: "xmark",
                        action: {
                            service?.reject(id: item.id)
                            refreshState()
                        },
                        accessibilityLabel: "Decline \(item.title)",
                        accessibilityIdentifier: "songRequestQueue.decline"
                    )
                    .help("Decline request")
                }
                .padding(.vertical, DSSpace.s1)
                .padding(.horizontal, DSSpace.s2)
                .background(DSColor.warning.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm))
            }
        }
    }

    // MARK: - Queue List

    private var queueList: some View {
        VStack(spacing: DSSpace.s1) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: DSSpace.s3) {
                    HStack(spacing: DSSpace.s3) {
                        Text("\(index + 1)")
                            .font(.system(size: DSFont.Size.sm, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 20)

                        smallArtworkPlaceholder

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.system(size: DSFont.Size.body))
                                .lineLimit(1)
                            Text("\(item.artist) · requested by \(item.requesterUsername)")
                                .font(.system(size: DSFont.Size.xs))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "Number \(index + 1): \(item.title), \(item.artist), requested by \(item.requesterUsername)"
                    )

                    DSIconButton(
                        systemImage: "xmark",
                        action: { remove(item) },
                        accessibilityLabel: "Remove \(item.title) from queue",
                        accessibilityIdentifier: "songRequestQueue.remove"
                    )
                    .help("Remove from queue")
                }
                .padding(.vertical, DSSpace.s1)
                .padding(.horizontal, DSSpace.s2)
            }
        }
    }

    // MARK: - Status Notes

    /// Plain-language reason the queue is held, with the way out.
    private var heldNote: some View {
        statusNote("On hold. Requests still queue, but nothing plays until you tap Resume.")
            .accessibilityIdentifier("songRequestQueue.heldNote")
    }

    /// One short secondary line explaining a paused state.
    private func statusNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: DSFont.Size.sm))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DSSpace.s2) {
            Image(systemName: isHeld ? "pause.circle" : "music.note.list")
                .font(.system(size: DSFont.Size.x2xl))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("No song requests yet")
                .font(.system(size: DSFont.Size.body))
                .foregroundStyle(.secondary)
            // `LocalizedStringKey`, not `String`, so the `!sr` code span renders.
            Text(isHeld
                ? LocalizedStringKey("The queue is on hold. Tap Resume when you're ready.")
                : LocalizedStringKey("Viewers can request songs with `!sr` in Twitch chat"))
                .font(.system(size: DSFont.Size.sm))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DSSpace.s7)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("songRequestQueue.empty")
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: DSSpace.s2) {
            AsyncActionButton(
                title: "Skip",
                systemImage: "forward.fill",
                isDisabled: nowPlaying == nil,
                labelSize: DSFont.Size.sm,
                showsSuccess: false,
                accessibilityIdentifier: "songRequestQueue.skip"
            ) {
                _ = await service?.skip()
                refreshState()
            }

            AsyncActionButton(
                title: isHeld ? "Resume" : "Hold",
                systemImage: isHeld ? "play.fill" : "pause.fill",
                tint: isHeld ? DSColor.success : DSColor.warning,
                labelSize: DSFont.Size.sm,
                showsSuccess: false,
                accessibilityIdentifier: "songRequestQueue.hold"
            ) {
                await service?.setHold(!isHeld)
                refreshState()
            }

            Button {
                showingClearConfirm = true
            } label: {
                Label("Clear Queue", systemImage: "trash")
                    .font(.system(size: DSFont.Size.sm))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isQueueEmpty)
            .confirmationDialog(
                "Clear all song requests?",
                isPresented: $showingClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear Queue", role: .destructive) {
                    Task { _ = await service?.clearQueue(); refreshState() }
                }
            }

            Spacer()
        }
    }

    // MARK: - Artwork Placeholders

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: DSRadius.sm)
            .fill(.quaternary)
            .frame(width: 40, height: 40)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: DSFont.Size.lg))
                    .foregroundStyle(.tertiary)
            }
            .accessibilityHidden(true)
    }

    private var smallArtworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: DSRadius.xs)
            .fill(.quaternary)
            .frame(width: 30, height: 30)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: DSFont.Size.body))
                    .foregroundStyle(.tertiary)
            }
            .accessibilityHidden(true)
    }

    // MARK: - Actions

    /// Removes one queued request and rebuilds Music's player queue to match.
    private func remove(_ item: SongRequestItem) {
        queue?.remove(id: item.id)
        let remainingSongs = queue?.items.map(\.song) ?? []
        Task {
            try? await service?.musicController.rebuildPlayerQueue(from: remainingSongs)
        }
        refreshState()
    }

    // MARK: - Refresh

    /// Snapshots the live queue + now-playing into the view's `@State`.
    private func refreshState() {
        // Only mutate @State when the value actually changes. Assigning the same
        // value still invalidates the view, so a 2-second tick would force a full
        // ForEach diff every cycle even when nothing changed.
        let newItems = queue?.items ?? []
        if newItems.map(\.id) != items.map(\.id) {
            items = newItems
        }
        let newPending = queue?.pending ?? []
        if newPending.map(\.id) != pending.map(\.id) {
            pending = newPending
        }
        let newNowPlaying = queue?.nowPlaying
        if newNowPlaying?.id != nowPlaying?.id {
            nowPlaying = newNowPlaying
        }
        let newMusicAppClosed = !(service?.musicController.isMusicAppRunning ?? true)
        if newMusicAppClosed != isMusicAppClosed {
            isMusicAppClosed = newMusicAppClosed
        }
        let newHeld = service?.isHoldEnabled ?? false
        if newHeld != isHeld {
            isHeld = newHeld
        }
    }
}

// MARK: - Preview

#Preview("Song Request Queue") {
    SongRequestQueueView()
        .padding()
        .frame(width: 500)
}
