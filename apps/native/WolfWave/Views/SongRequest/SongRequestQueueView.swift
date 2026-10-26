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
/// Rows are not reorderable; the order is whatever `SongRequestQueue` decides
/// (fair-share rounds, Sub/VIP priority, bit-cheer boosts).
///
/// The view keeps `@State` snapshots of the live queue and refreshes them on
/// `songRequestQueueChanged` / `songRequestHoldChanged`, after each action,
/// and on Music.app launch / quit.
struct SongRequestQueueView: View {
    // MARK: - Properties

    /// The running app delegate (`nil` in previews).
    private var appDelegate: AppDelegate? {
        AppDelegate.shared
    }

    /// Live queue owned by the song-request service.
    private var queue: SongRequestQueue? {
        appDelegate?.songRequestService?.queue
    }

    /// The service that runs skip, hold, approve, and clear.
    private var service: SongRequestService? {
        appDelegate?.songRequestService
    }

    /// Upcoming requests, in play order.
    @State private var items: [SongRequestItem] = []
    /// Requests waiting for approval (approval mode only).
    @State private var pending: [SongRequestItem] = []
    /// The request currently playing, if any.
    @State private var nowPlaying: SongRequestItem?
    /// Presents the clear-queue confirmation.
    @State private var showingClearConfirm = false
    /// Shows playlist cleanup progress and any Apple Music failure.
    @State private var isClearingRequests = false
    @State private var requestPlaylistClearFailed = false
    /// Music.app isn't running; requests buffer until it opens.
    @State private var isMusicAppClosed = false
    /// Hold mode: requests queue but nothing plays.
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
                }
            }

            // Keep playback controls above the list even when many requests arrive.
            actionButtons

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

            // Upcoming excludes the playing request and requests awaiting approval.
            Text("Up next · \(items.count)")
                .sectionEyebrow()
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("songRequestQueue.upNext")

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

            if isClearingRequests {
                LoadingRow(text: "Clearing queue and request playlist…")
            } else if requestPlaylistClearFailed {
                CalloutBanner(
                    "The queue was cleared, but WolfWave Requests couldn't be cleared. "
                        + "Open Music, make sure the playlist is available, then try again.",
                    style: .error
                )
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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DSSpace.s3) {
                        pendingDetails(item)
                        Spacer(minLength: DSSpace.s2)
                        pendingActions(item)
                    }
                    .frame(minWidth: DSDimension.Settings.inlineActionsMinWidth)

                    VStack(alignment: .leading, spacing: DSSpace.s3) {
                        pendingDetails(item)
                        pendingActions(item)
                    }
                }
                .padding(.vertical, DSSpace.s1)
                .padding(.horizontal, DSSpace.s2)
                .background(DSColor.warning.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm))
            }
        }
    }

    private func pendingDetails(_ item: SongRequestItem) -> some View {
        HStack(spacing: DSSpace.s3) {
            smallArtworkPlaceholder
            VStack(alignment: .leading, spacing: DSSpace.s0) {
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
        }
    }

    private func pendingActions(_ item: SongRequestItem) -> some View {
        HStack(spacing: DSSpace.s3) {
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
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Queue List

    /// Numbered upcoming requests, each with a remove button.
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
        statusNote("On hold. Requests still queue; choose Resume to play them.")
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

    /// Shown when nothing is playing, queued, or pending; explains a hold if on.
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
                ? LocalizedStringKey("The queue is on hold. Choose Resume when you're ready.")
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

    /// Queue controls plus a confirmed playlist clear action that stays available when idle.
    private var actionButtons: some View {
        HStack(spacing: DSSpace.s2) {
            if nowPlaying != nil {
                AsyncActionButton(
                    title: "Skip",
                    systemImage: "forward.fill",
                    size: .regular,
                    labelSize: DSFont.Size.sm,
                    showsSuccess: false,
                    accessibilityIdentifier: "songRequestQueue.skip"
                ) {
                    _ = await service?.skip()
                    refreshState()
                }
            }

            AsyncActionButton(
                title: isHeld ? "Resume" : "Hold",
                systemImage: isHeld ? "play.fill" : "pause.fill",
                size: .regular,
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
                Label("Clear Requests", systemImage: "trash")
                    .font(.system(size: DSFont.Size.sm))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(isClearingRequests)
            .help("Clear the queue and WolfWave Requests playlist. Songs stay in your Apple Music library.")
            .accessibilityIdentifier("songRequestQueue.clearRequests")
            .confirmationDialog(
                "Clear the queue and request playlist?",
                isPresented: $showingClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear Requests", role: .destructive) {
                    Task {
                        guard let service else { return }
                        isClearingRequests = true
                        requestPlaylistClearFailed = false
                        let result = await service.clearQueueAndRequestsPlaylist()
                        requestPlaylistClearFailed = !result.requestPlaylistCleared
                        isClearingRequests = false
                        refreshState()
                    }
                }
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("songRequestQueue.cancelClear")
            } message: {
                Text(isQueueEmpty
                    ? "This empties WolfWave Requests, including its shared playlist link. "
                        + "Music keeps playing, and songs stay in your Apple Music library."
                    : "This clears queued, pending, and playing requests, stops Music playback, "
                        + "and empties WolfWave Requests, including its shared playlist link. "
                        + "Songs stay in your Apple Music library.")
            }

            Spacer()
        }
        .disabled(isClearingRequests)
    }

    // MARK: - Artwork Placeholders

    /// Large note tile for the now-playing row. Requests carry no artwork here.
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

    /// Small note tile for pending and queued rows.
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
    /// The rebuild runs on a task and its errors are ignored.
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
        // value still invalidates the view, so a burst of change notifications
        // would force a full ForEach diff each time even when nothing changed.
        // Comparison is by id, so an edit to an existing item's fields doesn't
        // count as a change.
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
