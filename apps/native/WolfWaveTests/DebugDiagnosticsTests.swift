//
//  DebugDiagnosticsTests.swift
//  WolfWaveTests
//
//  Created by MrDemonWolf, Inc. on 5/25/26.
//

#if DEBUG
import XCTest
@testable import WolfWave

@MainActor
final class DebugDiagnosticsTests: XCTestCase {

    private func sampleSnapshot(
        appVersion: String = "1.2.3",
        build: String = "42",
        logSizeBytes: Int64 = 1024,
        logLineCount: Int = 100,
        twitchConnected: Bool = true,
        discordConnected: Bool = false,
        widgetEnabled: Bool = true,
        musicTrackingEnabled: Bool = true
    ) -> DebugDiagnostics.Snapshot {
        DebugDiagnostics.Snapshot(
            appVersion: appVersion,
            build: build,
            osVersion: "macOS 26.0",
            arch: "arm64",
            installMethod: "DMG",
            logSizeBytes: logSizeBytes,
            logLineCount: logLineCount,
            twitchConnected: twitchConnected,
            discordConnected: discordConnected,
            widgetEnabled: widgetEnabled,
            musicTrackingEnabled: musicTrackingEnabled
        )
    }

    func testIncludesEnvironmentAndServiceStateHeadings() {
        let md = DebugDiagnostics.markdown(sampleSnapshot())
        XCTAssertTrue(md.contains("## Environment"))
        XCTAssertTrue(md.contains("## Service State"))
    }

    func testEnvironmentFieldsAppearVerbatim() {
        let md = DebugDiagnostics.markdown(sampleSnapshot(appVersion: "9.9.9", build: "777"))
        XCTAssertTrue(md.contains("9.9.9 (build 777)"))
        XCTAssertTrue(md.contains("macOS 26.0"))
        XCTAssertTrue(md.contains("arm64"))
        XCTAssertTrue(md.contains("DMG"))
        XCTAssertTrue(md.contains("100"))
    }

    func testLogSizeFormattedViaByteCountFormatter() {
        let md = DebugDiagnostics.markdown(sampleSnapshot(logSizeBytes: 1024))
        let expected = ByteCountFormatter.string(fromByteCount: 1024, countStyle: .file)
        XCTAssertTrue(md.contains(expected), "expected formatted size \(expected) in markdown")
    }

    func testServiceFlagsRenderAsYesNo() {
        let md = DebugDiagnostics.markdown(sampleSnapshot(
            twitchConnected: true,
            discordConnected: false,
            widgetEnabled: true,
            musicTrackingEnabled: false
        ))
        XCTAssertTrue(md.contains("| Twitch | Yes |"))
        XCTAssertTrue(md.contains("| Discord | No |"))
        XCTAssertTrue(md.contains("| Widget HTTP | Yes |"))
        XCTAssertTrue(md.contains("| Music tracking | No |"))
    }

    func testEmptyVersionAndZeroLogStatsTolerated() {
        let md = DebugDiagnostics.markdown(sampleSnapshot(
            appVersion: "",
            build: "",
            logSizeBytes: 0,
            logLineCount: 0
        ))
        XCTAssertTrue(md.contains("(build )"))
        XCTAssertTrue(md.contains("| Log line count | 0 |"))
        let zero = ByteCountFormatter.string(fromByteCount: 0, countStyle: .file)
        XCTAssertTrue(md.contains(zero))
    }

    func testOutputIsMarkdownTable() {
        let md = DebugDiagnostics.markdown(sampleSnapshot())
        XCTAssertTrue(md.contains("| Field | Value |"))
        XCTAssertTrue(md.contains("| Service | State |"))
        XCTAssertTrue(md.contains("|---|---|"))
    }
}
#endif
