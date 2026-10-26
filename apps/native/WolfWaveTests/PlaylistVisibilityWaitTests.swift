//
//  PlaylistVisibilityWaitTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-26.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Testing
@testable import WolfWave

/// The bounded wait for Music.app to see the WolfWave Requests playlist, the
/// setup step's state machine on top of it, and the health check's wait policy.
///
/// Every probe and every sleep is scripted, so no Music.app and no real time
/// are involved: a "40 second" wait runs instantly and the test reads back
/// exactly how many probes ran and how long the code asked to sleep.
@MainActor
@Suite("Playlist visibility wait", .isolatedSharedTestState)
struct PlaylistVisibilityWaitTests {

    // MARK: - Fixtures

    /// Replays scripted probe answers and records every sleep request. The last
    /// answer repeats once the script runs out.
    @MainActor
    final class Script {
        private var answers: [PlaylistLocalVisibility]
        private(set) var probes = 0
        private(set) var sleeps: [Duration] = []
        /// Sleep number (1-based) that throws `CancellationError`, if any.
        var cancelOnSleep: Int?
        /// Observed state of the view model during each probe, when set.
        var onProbe: () -> Void = {}

        init(_ answers: [PlaylistLocalVisibility]) {
            self.answers = answers
        }

        func probe() async -> PlaylistLocalVisibility {
            probes += 1
            onProbe()
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }

        func sleep(_ duration: Duration) async throws {
            sleeps.append(duration)
            if let cancelOnSleep, sleeps.count >= cancelOnSleep {
                throw CancellationError()
            }
        }
    }

    /// A small wait so the attempt counting is easy to read.
    private let fiveTries = PlaylistVisibilityWait(interval: .seconds(2), maxAttempts: 5)

    // MARK: - The wait

    @Test("a playlist Music already sees ends the wait on the first probe")
    func visibleRightAway() async throws {
        let script = Script([.visible])
        let answer = try await fiveTries.run(probe: script.probe, sleep: script.sleep)
        #expect(answer == .visible)
        #expect(script.probes == 1)
        #expect(script.sleeps.isEmpty)
    }

    @Test("a playlist that syncs in a few seconds is found, not flagged")
    func appearsAfterSync() async throws {
        // The bug this fixes: the first probe right after creation says
        // "not visible" because iCloud hasn't synced yet.
        let script = Script([.notVisible, .notVisible, .visible])
        let answer = try await fiveTries.run(probe: script.probe, sleep: script.sleep)
        #expect(answer == .visible)
        #expect(script.probes == 3)
        #expect(script.sleeps == [.seconds(2), .seconds(2)])
    }

    @Test("a playlist that never shows up is reported only after every attempt")
    func neverAppears() async throws {
        let script = Script([.notVisible])
        let answer = try await fiveTries.run(probe: script.probe, sleep: script.sleep)
        #expect(answer == .notVisible)
        #expect(script.probes == 5)
        #expect(script.sleeps.count == 4)
    }

    @Test("Music closed ends the wait at once with no verdict")
    func unknownStopsImmediately() async throws {
        let script = Script([.unknown])
        let answer = try await fiveTries.run(probe: script.probe, sleep: script.sleep)
        #expect(answer == .unknown)
        #expect(script.probes == 1)
        #expect(script.sleeps.isEmpty)
    }

    @Test("Music quitting mid-wait ends it with no verdict, never a false alarm")
    func unknownMidWait() async throws {
        let script = Script([.notVisible, .unknown])
        let answer = try await fiveTries.run(probe: script.probe, sleep: script.sleep)
        #expect(answer == .unknown)
        #expect(script.probes == 2)
    }

    @Test("cancellation stops probing and throws")
    func cancellationStops() async {
        let script = Script([.notVisible])
        script.cancelOnSleep = 2
        await #expect(throws: CancellationError.self) {
            try await fiveTries.run(probe: script.probe, sleep: script.sleep)
        }
        #expect(script.probes == 2)
    }

    @Test("the single-probe preset never sleeps")
    func singleProbe() async throws {
        let script = Script([.notVisible])
        let answer = try await PlaylistVisibilityWait.singleProbe.run(probe: script.probe, sleep: script.sleep)
        #expect(answer == .notVisible)
        #expect(script.probes == 1)
        #expect(script.sleeps.isEmpty)
    }

    @Test("a zero attempt budget still probes once")
    func zeroAttemptsClamp() async throws {
        let script = Script([.notVisible])
        let wait = PlaylistVisibilityWait(interval: .seconds(1), maxAttempts: 0)
        _ = try await wait.run(probe: script.probe, sleep: script.sleep)
        #expect(script.probes == 1)
    }

    @Test("the standard wait polls every 2 seconds for 30 to 45 seconds")
    func standardBudget() {
        let wait = PlaylistVisibilityWait.standard
        #expect(wait.interval == .seconds(2))
        let total = wait.interval * (wait.maxAttempts - 1)
        #expect(total >= .seconds(30))
        #expect(total <= .seconds(45))
    }

    // MARK: - Setup step state machine

    @Test("the step shows checking while it waits, then ready in Music")
    func stepFindsPlaylist() async {
        let viewModel = SongRequestSetupViewModel(startAt: .playlist)
        let script = Script([.notVisible, .visible])
        var statesDuringProbes: [SongRequestSetupViewModel.PlaylistMusicState] = []
        script.onProbe = { statesDuringProbes.append(viewModel.playlistMusicState) }

        await viewModel.confirmPlaylistInMusic(wait: fiveTries, probe: script.probe, sleep: script.sleep)

        #expect(statesDuringProbes == [.checking, .checking])
        #expect(viewModel.playlistMusicState == .inMusic)
    }

    @Test("the Sync Library warning appears only after the full wait")
    func stepWarnsAfterWait() async {
        let viewModel = SongRequestSetupViewModel(startAt: .playlist)
        let script = Script([.notVisible])
        await viewModel.confirmPlaylistInMusic(wait: fiveTries, probe: script.probe, sleep: script.sleep)
        #expect(viewModel.playlistMusicState == .notInMusic)
        #expect(script.probes == 5)
    }

    @Test("a missing playlist in Music never blocks Next")
    func warningNeverBlocks() async {
        let viewModel = SongRequestSetupViewModel(startAt: .playlist)
        viewModel.playlistReady = true
        let script = Script([.notVisible])
        await viewModel.confirmPlaylistInMusic(wait: .singleProbe, probe: script.probe, sleep: script.sleep)
        #expect(viewModel.playlistMusicState == .notInMusic)
        #expect(viewModel.canAdvance)
    }

    @Test("Music closed is unverified, not a warning")
    func stepUnverified() async {
        let viewModel = SongRequestSetupViewModel(startAt: .playlist)
        let script = Script([.unknown])
        await viewModel.confirmPlaylistInMusic(wait: fiveTries, probe: script.probe, sleep: script.sleep)
        #expect(viewModel.playlistMusicState == .unverified)
    }

    @Test("leaving the step mid-wait resets the state so the next visit checks again")
    func stepCancelled() async {
        let viewModel = SongRequestSetupViewModel(startAt: .playlist)
        let script = Script([.notVisible])
        script.cancelOnSleep = 1
        await viewModel.confirmPlaylistInMusic(wait: fiveTries, probe: script.probe, sleep: script.sleep)
        #expect(viewModel.playlistMusicState == .unchecked)
    }

    @Test("finishing with the playlist still missing from Music keeps the warning")
    func completeCarriesWarning() async throws {
        let name = "test.sr.setup.complete.notInMusic"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let viewModel = SongRequestSetupViewModel(startAt: .done)
        viewModel.playlistMusicState = .notInMusic
        viewModel.complete(defaults: defaults)

        #expect(
            defaults.string(forKey: AppConstants.UserDefaults.songRequestPlaylistStatus)
                == PlaylistSetupStatus.playlistNotInMusic.rawValue)
        // Still a warning only: the feature turns on.
        #expect(defaults.bool(forKey: AppConstants.UserDefaults.songRequestEnabled))
    }

    @Test("finishing with Music closed records ok, not a warning")
    func completeUnverifiedIsOK() throws {
        let name = "test.sr.setup.complete.unverified"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let viewModel = SongRequestSetupViewModel(startAt: .done)
        viewModel.playlistMusicState = .unverified
        viewModel.complete(defaults: defaults)

        #expect(
            defaults.string(forKey: AppConstants.UserDefaults.songRequestPlaylistStatus)
                == PlaylistSetupStatus.ok.rawValue)
    }

    // MARK: - Health check policy

    @Test("the health check waits the first time it sees a gap")
    func healthWaitsOnFirstGap() {
        #expect(SongRequestService.visibilityWait(storedStatus: .ok, rebuilt: false, forceWait: false) == .standard)
        #expect(SongRequestService.visibilityWait(storedStatus: nil, rebuilt: false, forceWait: false) == .standard)
    }

    @Test("a gap already on the banner is re-checked with one probe")
    func healthSingleProbeWhenKnown() {
        #expect(
            SongRequestService.visibilityWait(storedStatus: .playlistNotInMusic, rebuilt: false, forceWait: false)
                == .singleProbe)
    }

    @Test("Check Again and a rebuilt playlist always wait")
    func healthForcedWait() {
        #expect(
            SongRequestService.visibilityWait(storedStatus: .playlistNotInMusic, rebuilt: false, forceWait: true)
                == .standard)
        #expect(
            SongRequestService.visibilityWait(storedStatus: .playlistNotInMusic, rebuilt: true, forceWait: false)
                == .standard)
    }
}
