//
//  SongRequestService+SetupHealth.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Song-request setup gate: the one-time grandfather migration and the
/// Requests playlist health check that keeps the stored share link honest.
extension SongRequestService {

    // MARK: - Setup Gate & Playlist Health

    /// One-time grandfather of the setup gate. Anyone who already had song
    /// requests turned on (or a song-list link configured) before the guided
    /// setup existed is marked complete, so the update never bounces an existing
    /// streamer back through setup. No-op once `songRequestSetupComplete` has
    /// been written. Mirrors `migrateAccessSettings`.
    static func migrateSetupState(defaults: Foundation.UserDefaults = DefaultsStore.store) {
        guard defaults.object(forKey: AppConstants.UserDefaults.songRequestSetupComplete) == nil else { return }
        let alreadyEnabled = defaults.bool(forKey: AppConstants.UserDefaults.songRequestEnabled)
        let link = defaults.string(forKey: AppConstants.UserDefaults.songRequestSongListURL) ?? ""
        let hasLink = !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if alreadyEnabled || hasLink {
            defaults.set(true, forKey: AppConstants.UserDefaults.songRequestSetupComplete)
        }
        // Fresh installs are left unset (false) so they go through the wizard.
    }

    /// The fallback to apply after a health check. Pure data so the policy is
    /// unit-testable without touching UserDefaults or the network.
    struct HealthOutcome: Equatable {
        /// Status written to `songRequestPlaylistStatus` (drives the banner).
        var status: PlaylistSetupStatus
        /// Turn off `!playlist` (cosmetic link break).
        var disableLink = false
        /// Re-engage the setup gate and stop the feature (essential break).
        var reEngageGate = false
        /// Write a refreshed public share URL when the playlist was republished.
        var updatedShareURL: String?
    }

    /// Maps a playlist probe to the fallback policy. Returns `nil` for an
    /// unreachable API so a network blip never clears a real banner or flips a
    /// toggle. Pure: the only inputs are the probe and the currently stored link.
    ///
    /// - `.missing` is an essential break (the rebuild attempt already failed by
    ///   the time the caller passes `.missing` here) so it re-engages the gate.
    /// - `.notPublic` only matters when a link was stored; then it's a cosmetic
    ///   `!playlist` break. With no stored link, a private playlist is fine.
    /// - `.ok` refreshes the stored link if the public URL changed (republished).
    ///
    /// `localVisibility` is the second, independent layer. The probe above only
    /// proves the playlist exists in the Apple Music **cloud** library, while
    /// playback resolves it through AppleScript against Music.app's **local**
    /// library, so a cloud-healthy playlist can still be unplayable. A definitive
    /// `.notVisible` relabels an otherwise-cosmetic outcome to
    /// `.playlistNotInMusic` while leaving every side effect intact: it must not
    /// escalate to an essential break, because Sync Library latency and an
    /// empty-playlist edge case can both produce a `.notVisible` that clears
    /// itself, and holding the whole feature on that would be worse than the
    /// banner. `.unknown` (Music closed, probe failed) changes nothing.
    static func resolveHealth(
        probe: AppleMusicLibraryService.PlaylistProbe,
        storedShareURL: String,
        localVisibility: PlaylistLocalVisibility = .unknown
    ) -> HealthOutcome? {
        let trimmed = storedShareURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLink = !trimmed.isEmpty
        var outcome: HealthOutcome
        switch probe {
        case .unreachable:
            return nil
        case .missing:
            outcome = HealthOutcome(status: .playlistMissing, reEngageGate: true)
        case .notPublic:
            outcome = hasLink
                ? HealthOutcome(status: .linkUnshared, disableLink: true)
                : HealthOutcome(status: .ok)
        case .ok(let url):
            if hasLink, let url, url != trimmed {
                outcome = HealthOutcome(status: .ok, updatedShareURL: url)
            } else {
                outcome = HealthOutcome(status: .ok)
            }
        }
        if localVisibility == .notVisible, !outcome.status.isEssential {
            outcome.status = .playlistNotInMusic
        }
        return outcome
    }

    /// Checks that the song-request playlist setup is still healthy and applies
    /// the fallback when it is not. Safe to call on launch and whenever the pane
    /// appears.
    ///
    /// Order of checks, cheapest and most essential first: setup not finished →
    /// nothing to police; Apple Music access lost → prompt a re-grant; otherwise
    /// probe the playlist (rebuilding it once if it was deleted) and resolve the
    /// link state. An unreachable API changes nothing.
    func runSetupHealthCheck() async {
        let defaults = DefaultsStore.store

        // Before setup is finished the pane shows the "Set up" call to action,
        // not a banner, so there is nothing to police yet.
        guard defaults.bool(forKey: AppConstants.UserDefaults.songRequestSetupComplete) else {
            setPlaylistStatus(.ok)
            return
        }

        // Apple Music access is the first essential. Non-destructive: requests
        // already guard on auth, and re-granting clears this on the next check.
        guard musicController.isAuthorized else {
            applyHealth(HealthOutcome(status: .musicAccessLost))
            return
        }

        let library = AppleMusicLibraryService()
        let storedURL = defaults.string(forKey: AppConstants.UserDefaults.songRequestSongListURL) ?? ""
        var probe = await library.probeRequestsPlaylist()

        // A deleted playlist self-heals: rebuild it once before treating the loss
        // as an essential break. After a rebuild the new playlist is private, so
        // re-probe to capture the (not-yet-public) link state.
        if case .missing = probe {
            library.resetCachedPlaylistID()
            if (try? await library.ensureRequestsPlaylist()) != nil {
                probe = await library.probeRequestsPlaylist()
            }
        }

        // Second layer: the cloud probe above can say "healthy" about a playlist
        // Music.app cannot see, and AppleScript playback only ever reads the local
        // library. Ask Music directly, in the terminology playback uses.
        let localVisibility = await musicController.requestsPlaylistLocalVisibility()

        guard let outcome = Self.resolveHealth(
            probe: probe,
            storedShareURL: storedURL,
            localVisibility: localVisibility
        ) else { return }
        applyHealth(outcome)
    }

    /// Persists a `HealthOutcome`: updates a refreshed link, turns off `!playlist`
    /// on a cosmetic break, re-engages the gate and stops the feature on an
    /// essential break, then records the status that drives the banner.
    private func applyHealth(_ outcome: HealthOutcome) {
        let defaults = DefaultsStore.store
        if let updated = outcome.updatedShareURL {
            defaults.set(updated, forKey: AppConstants.UserDefaults.songRequestSongListURL)
        }
        if outcome.disableLink {
            defaults.set(false, forKey: AppConstants.UserDefaults.songListCommandEnabled)
        }
        if outcome.reEngageGate {
            defaults.set(false, forKey: AppConstants.UserDefaults.songRequestSetupComplete)
            defaults.set(false, forKey: AppConstants.UserDefaults.songRequestEnabled)
            NotificationCenter.default.postEnabled(.songRequestSettingChanged, enabled: false)
            Log.info("SongRequestService: Playlist setup broke; re-engaging setup gate", category: .songRequest)
        }
        setPlaylistStatus(outcome.status)
    }

    /// Writes the playlist health status that backs the pane's `@AppStorage`
    /// banner. Only writes on a change to avoid waking observers needlessly.
    private func setPlaylistStatus(_ status: PlaylistSetupStatus) {
        let defaults = DefaultsStore.store
        let key = AppConstants.UserDefaults.songRequestPlaylistStatus
        guard defaults.string(forKey: key) != status.rawValue else { return }
        defaults.set(status.rawValue, forKey: key)
    }
}
