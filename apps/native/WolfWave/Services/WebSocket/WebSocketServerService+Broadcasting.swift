//
//  WebSocketServerService+Broadcasting.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Network

/// Outbound frames for ``WebSocketServerService``: per-connection replay on
/// connect, role-filtered fan-out of playback state, the progress timer that
/// drives `progress` frames, and the JSON send helpers.
extension WebSocketServerService {

    // MARK: - Message Broadcasting

    /// Sends the initial `welcome` envelope (server identity + version) to a
    /// freshly-accepted connection.
    func sendWelcome(to connection: NWConnection) {
        Self.sendJSON(
            ["type": "welcome", "server": "WolfWave", "version": AppConstants.AppInfo.shortVersion],
            to: connection
        )
    }

    /// Sends the current widget theme/layout config to a newly connected client.
    func sendWidgetConfig(to connection: NWConnection) {
        Self.sendJSON(widgetConfigPayload(), to: connection)
    }

    /// Builds the `overlay_visibility` frame (`data.visible`).
    private func overlayVisibilityPayload() -> [String: Any] {
        ["type": "overlay_visibility", "data": ["visible": isOverlayVisible]]
    }

    /// Sends the current overlay visibility to one new client.
    func sendOverlayVisibility(to connection: NWConnection) {
        Self.sendJSON(overlayVisibilityPayload(), to: connection)
    }

    /// Broadcasts the current overlay visibility to every client.
    func broadcastOverlayVisibility() {
        broadcastJSON(overlayVisibilityPayload())
    }

    /// Builds the `now_playing` message from the stored track/artist/album plus
    /// timing and artwork. Returns `nil` when no complete track is stored.
    ///
    /// `elapsed` is parameterized because the replay path interpolates an
    /// estimate (`estimatedElapsed()`) while the live broadcast uses the raw
    /// `currentElapsed`. Safe on this actor: called synchronously with no
    /// suspension between the property reads.
    private func nowPlayingPayload(elapsed: TimeInterval) -> [String: Any]? {
        guard let track = currentTrack,
              let artist = currentArtist,
              let album = currentAlbum else { return nil }
        return [
            "type": "now_playing",
            "data": [
                "track": track, "artist": artist, "album": album,
                "duration": currentDuration, "elapsed": elapsed,
                "isPlaying": isPlaying, "artworkURL": currentArtworkURL ?? ""
            ]
        ]
    }

    /// Sends the full current playback snapshot to a newly connected client.
    ///
    /// A hidden overlay withholds the replay from overlay clients so a browser
    /// source cannot paint a card the streamer has turned off. Control clients
    /// are exempt: hiding the overlay is not a reason for a Stream Deck to stop
    /// knowing what is playing.
    func sendCurrentState(to connection: NWConnection, role: WebSocketAuthToken.Role) {
        guard isOverlayVisible || role == .control else { return }
        guard let message = nowPlayingPayload(elapsed: estimatedElapsed()) else {
            Log.debug(
                "WebSocketServerService: No playback state to replay on connect",
                category: .websocket
            )
            Self.sendJSON(
                [
                    "type": "playback_state",
                    "data": ["isPlaying": false, "track": "", "artist": "", "album": ""]
                ],
                to: connection
            )
            return
        }
        Log.debug(
            "WebSocketServerService: Replaying last-known state to new client (track=\(currentTrack ?? ""))",
            category: .websocket
        )
        Self.sendJSON(message, to: connection)
    }

    /// Sends a `now_playing` snapshot (track/artist/album/timing/artwork) to
    /// every connected client. No-op when no track has been stored yet.
    ///
    /// While the overlay is hidden this narrows to control clients rather than
    /// stopping: the browser source must not paint a hidden card, but a Stream
    /// Deck that went silent on every track change for the whole time the
    /// overlay was off would just be showing the streamer stale information.
    func broadcastNowPlaying() {
        guard let message = nowPlayingPayload(elapsed: currentElapsed) else { return }
        if isOverlayVisible {
            broadcastJSON(message)
        } else {
            broadcastJSON(message, to: controlConnections())
        }
    }

    /// The connected clients holding the control credential.
    private func controlConnections() -> [NWConnection] {
        connections.filter { connectionRoles[ObjectIdentifier($0)] == .control }
    }

    /// Count of clients rendering the overlay, i.e. everything except Stream Deck.
    private func overlayConnectionCount() -> Int {
        connections.count { connectionRoles[ObjectIdentifier($0)] != .control }
    }

    /// Sends a lightweight `playback_state` update to every connected client.
    /// Used by `clearNowPlaying()` (empty track, `isPlaying: false`) and when
    /// the overlay is re-shown with no track loaded. Pause/resume of a loaded
    /// track goes out as `now_playing` instead. Not narrowed by overlay
    /// visibility.
    func broadcastPlaybackState() {
        broadcastJSON([
            "type": "playback_state",
            "data": [
                "isPlaying": isPlaying,
                "track": currentTrack ?? "",
                "artist": currentArtist ?? "",
                "album": currentAlbum ?? ""
            ]
        ])
    }

    /// Sends a `progress` tick (elapsed/duration) to every connected client
    /// while playback is active. Driven by the periodic progress task.
    private func broadcastProgress() {
        // No clients = nothing to do. Skipping the serialization when no overlay
        // is connected (the common idle case) avoids per-tick work.
        guard Self.shouldRunProgressTimer(
            isEnabled: isEnabled,
            isOverlayVisible: isOverlayVisible,
            isPlaying: isPlaying,
            duration: currentDuration,
            connectionCount: overlayConnectionCount()
        ) else { return }
        broadcastJSON([
            "type": "progress",
            "data": [
                "elapsed": estimatedElapsed(),
                "duration": currentDuration,
                "isPlaying": isPlaying
            ]
        ])
    }

    /// Interpolates elapsed time using the wall clock: `currentElapsed` plus
    /// time since `lastElapsedUpdate` while playing, clamped to the duration.
    /// Returns `currentElapsed` unchanged when paused.
    private func estimatedElapsed() -> TimeInterval {
        guard let lastUpdate = lastElapsedUpdate, isPlaying else { return currentElapsed }
        return min(currentElapsed + Date().timeIntervalSince(lastUpdate), currentDuration)
    }

    // MARK: - Progress Timer

    /// Pure policy shared by every progress-loop entry point and regression tests.
    ///
    /// The timer runs only while enabled, visible, playing a track with a
    /// finite positive duration, and serving at least one client.
    /// `connectionCount` should count overlay clients only.
    nonisolated static func shouldRunProgressTimer(
        isEnabled: Bool,
        isOverlayVisible: Bool,
        isPlaying: Bool,
        duration: TimeInterval,
        connectionCount: Int
    ) -> Bool {
        isEnabled
            && isOverlayVisible
            && isPlaying
            && duration.isFinite
            && duration > 0
            && connectionCount > 0
    }

    /// Starts or stops the periodic task so disabled, hidden, paused, and
    /// client-free states have no timer wakeups at all.
    func reconcileProgressTimer() {
        // Only overlay clients consume `progress`; a lone Stream Deck ignores
        // the frame, so its presence must not keep the timer awake.
        let shouldRun = Self.shouldRunProgressTimer(
            isEnabled: isEnabled,
            isOverlayVisible: isOverlayVisible,
            isPlaying: isPlaying,
            duration: currentDuration,
            connectionCount: overlayConnectionCount())
        if shouldRun {
            if progressTask == nil { startProgressTimer() }
        } else {
            stopProgressTimer()
        }
    }

    /// Starts (or restarts) the periodic progress broadcast loop using the
    /// current interval. Cancels any running loop before scheduling.
    func startProgressTimer() {
        stopProgressTimer()
        guard Self.shouldRunProgressTimer(
            isEnabled: isEnabled,
            isOverlayVisible: isOverlayVisible,
            isPlaying: isPlaying,
            duration: currentDuration,
            connectionCount: overlayConnectionCount()
        ) else { return }

        let interval = currentProgressInterval
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                // Progress ticks tolerate ~10% jitter; the tolerance lets macOS
                // coalesce the wakeup with other timers.
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.1))
                if Task.isCancelled { return }
                await self?.broadcastProgress()
            }
        }
    }

    /// Cancels and clears the progress broadcast task if one is active.
    func stopProgressTimer() {
        progressTask?.cancel()
        progressTask = nil
    }

    /// Exposed internally for deterministic lifecycle tests.
    var isProgressTimerActive: Bool { progressTask != nil }

    /// Exposed internally for artwork identity regression tests.
    var artworkState: (track: String?, artist: String?, url: String?) {
        (currentTrack, currentArtist, currentArtworkURL)
    }

    // MARK: - JSON Helpers

    /// Serializes `dict` to JSON and sends it as a single WebSocket text frame.
    /// Nonisolated. Does not touch actor state.
    static func sendJSON(_ dict: [String: Any], to connection: NWConnection) {
        // Guards a malformed leaf from raising an ObjC exception inside
        // `data(withJSONObject:)` (uncatchable by `try?`).
        guard let jsonData = JSONObjectSerialization.data(from: dict) else { return }
        sendJSONData(jsonData, to: connection)
    }

    /// Sends already-encoded JSON so fan-out does not serialize or copy the
    /// identical payload once per connection.
    private static func sendJSONData(_ jsonData: Data, to connection: NWConnection) {
        MetricsService.shared.recordWebSocketMessage(byteCount: jsonData.count)

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "websocket", metadata: [metadata])

        connection.send(
            content: jsonData,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in
                if let error { Log.debug("WebSocketServerService: Send failed: \(error)", category: .websocket) }
            }
        )
    }

    /// Fan-outs a JSON payload to every active connection in a single pass.
    ///
    /// - Parameter dict: Top-level JSON object to serialize and broadcast.
    func broadcastJSON(_ dict: [String: Any]) {
        broadcastJSON(dict, to: connections)
    }

    /// Fan-outs to a subset of clients, encoding once for the whole set.
    ///
    /// - Parameters:
    ///   - dict: Top-level JSON object to serialize and send.
    ///   - targets: Connections to send to. Empty is a no-op.
    private func broadcastJSON(_ dict: [String: Any], to targets: [NWConnection]) {
        guard !targets.isEmpty else { return }
        guard let jsonData = JSONObjectSerialization.data(from: dict) else { return }
        for connection in targets { Self.sendJSONData(jsonData, to: connection) }
    }
}
