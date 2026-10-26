//
//  DiscordNotPlayingChoiceTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-26.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Testing
@testable import WolfWave

/// The Discord pane's two "when the music isn't playing" choices: they round-trip
/// through the stored Bools unchanged, and the outcome table matches what
/// `DiscordRPCService` actually does with those Bools.
struct DiscordNotPlayingChoiceTests {

    @Test("Pause choice round-trips through discordClearWhilePaused", arguments: [false, true])
    func pauseRoundTrip(clearWhilePaused: Bool) {
        #expect(DiscordPauseChoice(clearWhilePaused: clearWhilePaused).clearWhilePaused == clearWhilePaused)
    }

    @Test("Stop choice round-trips through discordShowIdleStatus", arguments: [false, true])
    func stopRoundTrip(showIdleStatus: Bool) {
        #expect(DiscordStopChoice(showIdleStatus: showIdleStatus).showIdleStatus == showIdleStatus)
    }

    @Test("Stored defaults map to Keep the song and Listening to WolfWave")
    func defaultsMapToFriendlyChoices() {
        let defaults = AppConstants.UserDefaults.Defaults.self
        #expect(DiscordPauseChoice(clearWhilePaused: defaults.discordClearWhilePaused) == .keepSong)
        #expect(DiscordStopChoice(showIdleStatus: defaults.discordShowIdleStatus) == .showWolfWave)
    }

    @Test("Playing always shows the song", arguments: DiscordPauseChoice.allCases, DiscordStopChoice.allCases)
    func playingShowsSong(pause: DiscordPauseChoice, stop: DiscordStopChoice) {
        #expect(DiscordProfileOutcome.resolve(isPaused: false, isStopped: false, pause: pause, stop: stop) == .song)
    }

    @Test("Paused with Keep the song shows the song", arguments: DiscordStopChoice.allCases)
    func pausedKeep(stop: DiscordStopChoice) {
        #expect(DiscordProfileOutcome.resolve(isPaused: true, isStopped: false, pause: .keepSong, stop: stop) == .song)
    }

    @Test("Paused with Hide the song falls through to the stop choice")
    func pausedHide() {
        #expect(
            DiscordProfileOutcome.resolve(isPaused: true, isStopped: false, pause: .hideSong, stop: .showWolfWave)
                == .listeningToWolfWave
        )
        #expect(
            DiscordProfileOutcome.resolve(isPaused: true, isStopped: false, pause: .hideSong, stop: .showNothing)
                == .nothing
        )
    }

    @Test("Stopped follows the stop choice, whatever the pause choice", arguments: DiscordPauseChoice.allCases)
    func stopped(pause: DiscordPauseChoice) {
        #expect(
            DiscordProfileOutcome.resolve(isPaused: false, isStopped: true, pause: pause, stop: .showWolfWave)
                == .listeningToWolfWave
        )
        #expect(
            DiscordProfileOutcome.resolve(isPaused: false, isStopped: true, pause: pause, stop: .showNothing)
                == .nothing
        )
    }
}
