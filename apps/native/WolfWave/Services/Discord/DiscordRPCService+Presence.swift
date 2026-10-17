//
//  DiscordRPCService+Presence.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import Foundation

/// Presence send path for ``DiscordRPCService``: clearing the card, the
/// rate-limited `SET_ACTIVITY` queue, retries after a rejection, and
/// refreshes when presence settings change.
extension DiscordRPCService {

    // MARK: - Presence Helpers

    /// Drops any queued activity and sends a `SET_ACTIVITY` with no `activity`,
    /// which clears the profile card. Not rate-limited: a clear always goes out
    /// immediately.
    ///
    /// - Parameter preservingLastPresence: Keep ``lastPresence`` so the track
    ///   can be restored later.
    func performClearPresence(preservingLastPresence: Bool = false) async {
        cancelPendingPresence()
        if !preservingLastPresence {
            lastPresence = nil
        }
        guard state == .connected else { return }

        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": pid
            ],
            "nonce": UUID().uuidString
        ]

        await sendCommandFrame(payload)
    }

    /// Builds and sends a SET_ACTIVITY frame with the given track metadata.
    ///
    /// - Parameters:
    ///   - track: Song title.
    ///   - artist: Artist name.
    ///   - album: Album name (used as large image tooltip).
    ///   - playlist: Current Apple Music playlist name (empty if none / unknown).
    ///   - artworkURL: Optional iTunes artwork URL. If nil, falls back to a source-specific
    ///     asset uploaded in the Discord Developer Portal.
    ///   - duration: Total track duration in seconds (0 if unknown).
    ///   - elapsed: Elapsed time in seconds (0 if unknown).
    ///   - appleMusicURL: Target for the first button, if resolved.
    ///   - songLinkURL: Target for the second button, if resolved.
    ///   - isPaused: Shows the paused badge and drops timestamps.
    func sendPresenceActivity(
        track: String,
        artist: String,
        album: String,
        playlist: String,
        artworkURL: String?,
        duration: TimeInterval,
        elapsed: TimeInterval,
        appleMusicURL: String? = nil,
        songLinkURL: String? = nil,
        isPaused: Bool = false
    ) async {
        let activity = DiscordPresenceBuilder.buildActivity(
            track: track,
            artist: artist,
            album: album,
            playlist: playlist,
            artworkURL: artworkURL,
            duration: duration,
            elapsed: elapsed,
            appleMusicURL: appleMusicURL,
            songLinkURL: songLinkURL,
            isPaused: isPaused,
            defaults: DefaultsStore.store,
            now: Date()
        )

        await sendActivityFrame(activity)
    }

    /// Records the latest track snapshot (stamped with the current time) so
    /// settings changes and reconnects can re-send it.
    func cachePresence(
        track: String,
        artist: String,
        album: String,
        playlist: String,
        duration: TimeInterval,
        elapsed: TimeInterval,
        isPaused: Bool
    ) {
        lastPresence = LastPresence(
            track: track, artist: artist, album: album, playlist: playlist,
            duration: duration, elapsed: elapsed,
            isPaused: isPaused, capturedAt: Date()
        )
    }

    /// Wraps an `activity` dictionary in a `SET_ACTIVITY` frame and sends it.
    ///
    /// Rate-limited: inside ``presenceMinimumInterval`` of the last send, the
    /// activity replaces any pending one and goes out when the window ends.
    /// No-op unless enabled and connected.
    func sendActivityFrame(_ activity: [String: Any]) async {
        guard isEnabled, state == .connected else { return }
        pendingActivity = activity
        presenceRetryUsed = false
        if presenceSendTask != nil { return }
        if let lastActivitySentAt, Date().timeIntervalSince(lastActivitySentAt) < presenceMinimumInterval {
            schedulePendingPresence()
        } else {
            await flushPendingPresence(generation: connectionGeneration)
        }
    }

    /// Schedules a flush of ``pendingActivity`` when the rate-limit window
    /// ends. Only the latest pending payload survives a burst. Clear and
    /// disconnect cancel it. The flush is pinned to the current
    /// ``connectionGeneration`` so it never writes to a later connection.
    private func schedulePendingPresence() {
        guard presenceSendTask == nil else { return }
        let generation = connectionGeneration
        let delay = max(0, presenceMinimumInterval - Date().timeIntervalSince(lastActivitySentAt ?? .distantPast))
        presenceSendTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.flushPendingPresence(generation: generation)
        }
    }

    /// Sends ``pendingActivity`` with a fresh nonce, if the connection that
    /// scheduled it is still current.
    private func flushPendingPresence(generation: UInt64) async {
        guard generation == connectionGeneration, isEnabled, state == .connected else { return }
        presenceSendTask = nil
        guard let activity = pendingActivity else { return }
        pendingActivity = nil
        let nonce = UUID().uuidString
        lastActivityNonce = nonce
        lastActivitySentAt = Date()
        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": pid,
                "activity": activity
            ],
            "nonce": nonce
        ]

        await sendCommandFrame(payload)
    }

    /// Cancels the scheduled flush and forgets the pending activity and its
    /// nonce, so a late ERROR reply for it is not retried.
    func cancelPendingPresence() {
        presenceSendTask?.cancel()
        presenceSendTask = nil
        pendingActivity = nil
        lastActivityNonce = nil
    }

    /// A rejected activity gets one delayed retry; newer updates own the pending slot.
    ///
    /// Called from ``sendCommandFrame(_:)`` when Discord answers ERROR. Skipped
    /// when `nonce` is not the latest send, the retry was already used, a
    /// newer activity is pending, or there is no track to show.
    func retryRejectedPresence(_ activity: [String: Any], nonce: String) {
        guard isEnabled, state == .connected, lastPresence != nil,
              nonce == lastActivityNonce, !presenceRetryUsed, pendingActivity == nil else { return }
        presenceRetryUsed = true
        pendingActivity = activity
        schedulePendingPresence()
    }

    /// Re-sends the most recent presence with current settings applied.
    ///
    /// Called when `discordPresenceSettingsChanged` fires (e.g. user toggled a button
    /// in settings), after a connect, and after a link lookup. Re-uses cached
    /// `TrackLinks` via `ArtworkService.shared` so no network round-trip is
    /// required. With no snapshot, applies the no-track preference (idle or
    /// clear) instead.
    func refreshPresenceFromSettings(
        showIdleStatus: Bool = FeatureFlags.discordShowIdleStatus,
        clearWhilePaused: Bool = FeatureFlags.discordClearWhilePaused
    ) async {
        guard isEnabled, state == .connected else { return }
        guard let snap = lastPresence else {
            await sendNoTrackPresence(
                showIdleStatus: showIdleStatus,
                preservingLastPresence: false
            )
            return
        }
        resolveLinksIfNeeded(track: snap.track, artist: snap.artist)
        if snap.isPaused && clearWhilePaused {
            await sendNoTrackPresence(
                showIdleStatus: showIdleStatus,
                preservingLastPresence: true
            )
            return
        }

        // Recompute elapsed from the captured timestamp so the progress bar stays accurate.
        let drift = Date().timeIntervalSince(snap.capturedAt)
        let elapsed = snap.isPaused ? snap.elapsed : snap.duration > 0
            ? min(snap.elapsed + drift, snap.duration)
            : snap.elapsed

        let cached = ArtworkService.shared.cachedTrackLinks(track: snap.track, artist: snap.artist)
        await sendPresenceActivity(
            track: snap.track,
            artist: snap.artist,
            album: snap.album,
            playlist: snap.playlist,
            artworkURL: cached.artworkURL,
            duration: snap.duration,
            elapsed: elapsed,
            appleMusicURL: cached.trackViewURL,
            songLinkURL: cached.songLinkURL,
            isPaused: snap.isPaused
        )
    }

    /// Applies the current no-track preference after a display setting changes.
    func sendNoTrackPresence(
        showIdleStatus: Bool,
        preservingLastPresence: Bool
    ) async {
        if showIdleStatus {
            await performShowIdleStatus(preservingLastPresence: preservingLastPresence)
        } else {
            await performClearPresence(preservingLastPresence: preservingLastPresence)
        }
    }

    // Presence payload + playlist-resolution builders (buildActivity,
    // buildIdleActivity, resolveButton, buttonKeys, PlaylistDisplay,
    // resolvePlaylistDisplay, stateLine, smallText) live in
    // DiscordPresenceBuilder.swift.
}
