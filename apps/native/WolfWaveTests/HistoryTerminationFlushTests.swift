//
//  HistoryTerminationFlushTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest
@testable import WolfWave

/// The quit-time history flush must honor the once-per-play guard. Turning
/// History off mid-track already records the play; turning it back on and
/// quitting on the same track used to record it a second time.
@MainActor
final class HistoryTerminationFlushTests: WolfWaveTestCase {

    // MARK: - Helpers

    private func makeDelegate(directory: URL) -> AppDelegate {
        let delegate = AppDelegate()
        delegate.historyService = ListeningHistoryService(
            store: PlayLogStore(directory: directory),
            tallyStore: LifetimeTallyStore(directory: directory),
            enabled: true
        )
        delegate.currentSong = "Moonlit Howl"
        delegate.currentArtist = "Gray Wolf"
        delegate.currentAlbum = "Pack"
        delegate.currentDuration = 200
        delegate.currentElapsed = 150
        return delegate
    }

    private func historyToggled(_ enabled: Bool) -> Notification {
        Notification(
            name: Notification.Name("ListeningHistorySettingChanged"),
            object: nil,
            userInfo: [NotificationKeys.enabled: enabled]
        )
    }

    // MARK: - Tests

    func testQuitAfterHistoryOffOnDoesNotRecordPlayTwice() {
        let dir = makeIsolatedTempDirectory(prefix: "history-quit-test")
        defer { try? FileManager.default.removeItem(at: dir) }
        let delegate = makeDelegate(directory: dir)

        delegate.listeningHistorySettingChanged(historyToggled(false))
        delegate.listeningHistorySettingChanged(historyToggled(true))
        delegate.finalizeHistoryForTermination()

        XCTAssertEqual(PlayLogStore(directory: dir).loadAll().count, 1,
                       "The play flushed when History turned off must not be recorded again at quit")
    }

    func testQuitRecordsAnUnflushedPlay() {
        let dir = makeIsolatedTempDirectory(prefix: "history-quit-test")
        defer { try? FileManager.default.removeItem(at: dir) }
        let delegate = makeDelegate(directory: dir)

        delegate.finalizeHistoryForTermination()

        XCTAssertEqual(PlayLogStore(directory: dir).loadAll().count, 1)
    }
}
