//
//  SongRequestService+PlaybackMonitoring.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import Foundation

/// Auto-advance monitoring: the Music.app launch and queue observers, the
/// on-demand polling task, and the poll tick that advances the queue.
extension SongRequestService {

    // MARK: - Lifecycle

    /// Begins watching Apple Music playback and the Music.app launch state.
    ///
    /// Installs lightweight launch/queue observers. The 2-second auto-advance
    /// polling task exists only while auto-advance is enabled, hold is off, and
    /// the live queue has a pending or current request.
    ///
    /// - Important: Idempotent. Calling twice cancels and re-creates observers.
    func startPlaybackMonitoring() {
        stopPlaybackMonitoring()
        isPlaybackMonitoringEnabled = true

        // Watch for Music.app launching so buffered requests flush automatically.
        musicAppLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == AppConstants.Music.bundleIdentifier else { return }
            Task { await self?.handleMusicAppLaunched() }
        }

        // Queue mutations already publish this notification. Use it to keep the
        // 2-second task completely absent while there is no queued/current request.
        queueChangeObserver = NotificationCenter.default.addObserver(
            forName: .songRequestQueueChanged,
            object: queue,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcilePlaybackMonitoring()
            }
        }

        reconcilePlaybackMonitoring()
    }

    /// Reconciles the polling task after a queue or playback-setting change.
    /// The settings view calls this after updating its `@AppStorage` binding.
    /// A stopped service remains stopped; reconciliation never starts lifecycle.
    func reconcilePlaybackMonitoring() {
        updatePlaybackPolling()
    }

    /// Starts or stops the auto-advance task to match current queue activity.
    /// Pending-approval items do not need playback observation until approved.
    private func updatePlaybackPolling() {
        let hasLiveRequest = queue.nowPlaying != nil || !queue.isEmpty
        let needsPolling = isPlaybackMonitoringEnabled
            && isAutoAdvanceEnabled
            && !isHoldEnabled
            && hasLiveRequest
        guard needsPolling else {
            playbackObserver?.cancel()
            playbackObserver = nil
            return
        }
        guard playbackObserver == nil else { return }

        playbackObserver = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                // Auto-advance polling is not time-critical. A 20% tolerance lets
                // macOS coalesce the wakeup (0.4s at the default 2s cadence).
                do {
                    try await Task.sleep(
                        for: self.pollInterval,
                        tolerance: self.pollInterval / 5)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.pollTick()
            }
        }
    }

    /// One auto-advance poll evaluation: reads a playback snapshot and applies
    /// the advance / takeover / fallback rules. The monitoring loop calls this
    /// every `pollInterval`.
    ///
    /// Internal (not private) on purpose: tests drive ticks through this method
    /// directly, so debounce and yield behavior is asserted per-tick instead of
    /// racing the wall-clock polling task (which gets starved on loaded CI hosts).
    func pollTick() async {
        guard isAutoAdvanceEnabled else { return }
        guard !isHoldEnabled else { return }
        // Music.app closed: nothing to advance, and probing player state
        // would relaunch the app the user just quit. Buffered requests
        // flush via the didLaunchApplication observer when Music reopens.
        guard musicController.isMusicAppRunning else { return }

        // Idle early-out: with no request playing and an empty queue there is
        // nothing to advance or take over, so skip the AppleScript round trip
        // entirely (these are NSLock-guarded in-memory reads). Reset the streak
        // counters so the two-consecutive-reads debounce restarts cleanly when
        // activity resumes.
        if queue.nowPlaying == nil, queue.isEmpty {
            resetTakeoverTracking()
            resetRequestPlaybackTracking()
            stoppedPollStreak = 0
            return
        }

        // One atomic read of player state + the loaded track's identity.
        // A nil snapshot means the AppleScript read failed this tick
        // (Apple Events to Music.app time out intermittently on macOS 26):
        // treat it as "no information" and skip the tick entirely, so a
        // flaky read can never be mistaken for a stop or a track change and
        // cut a song off mid-play. Streak counters are left untouched so a
        // single dropped read doesn't reset an in-progress debounce.
        guard let snapshot = await musicController.playbackSnapshot() else { return }

        // Debounce stopped detection: require two consecutive stopped reads
        // before advancing/taking over, so one flaky read can't skip a track.
        let confirmedStopped: Bool
        if snapshot.state == .stopped {
            stoppedPollStreak += 1
            confirmedStopped = stoppedPollStreak >= pollConfirmations
        } else {
            stoppedPollStreak = 0
            confirmedStopped = false
        }

        if queue.nowPlaying != nil {
            // A request is playing.
            resetTakeoverTracking()

            // Playback clearly stopped (two reads): advance, or drain.
            if confirmedStopped {
                resetRequestPlaybackTracking()
                if !queue.isEmpty {
                    await advanceQueue()
                } else {
                    await handleQueueEmptied()
                }
                return
            }

            // Still playing: hand off to the next request the moment the
            // request's own track is replaced: the request ended and Music
            // autoplayed the next track, or the streamer skipped inside
            // Music.app. Music never reports "stopped" in either case.
            if snapshot.state == .playing {
                await handleRequestPlaybackDivergence(currentKey: snapshot.trackKey)
            }
            return
        }

        // No request is playing.
        resetRequestPlaybackTracking()

        // Nothing to do unless requests wait.
        guard !queue.isEmpty else {
            resetTakeoverTracking()
            return
        }

        if confirmedStopped || isPlayingFallback {
            // Silence, or the fallback playlist is filling: start the first
            // queued request. The fallback is explicit filler that yields to
            // a real request right away.
            resetTakeoverTracking()
            await advanceQueue()
        } else if snapshot.state == .playing {
            // The streamer's own track is playing. Honor "play when the
            // current song ends": remember the loaded track, then take over
            // only once it changes to a different, confirmed track, never on
            // a single transient read that would cut the song off mid-play.
            await handleStreamerTrackTakeover(currentKey: snapshot.trackKey)
        }
        // Paused, or an unconfirmed stopped read: wait.
    }

    /// Stops the polling task and removes the Music.app/queue observers.
    /// Safe to call when no monitoring is active.
    func stopPlaybackMonitoring() {
        isPlaybackMonitoringEnabled = false
        playbackObserver?.cancel()
        playbackObserver = nil
        if let observer = musicAppLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            musicAppLaunchObserver = nil
        }
        if let observer = queueChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            queueChangeObserver = nil
        }
    }
}
