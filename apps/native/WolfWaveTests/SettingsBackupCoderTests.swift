//
//  SettingsBackupCoderTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-06-02.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Testing
@testable import WolfWave

/// Pure-logic coverage for the settings backup encode/decode/apply core.
/// No UserDefaults, Keychain, file system, or network is touched.
struct SettingsBackupCoderTests {

    let coder = SettingsBackupCoder()
    var exportable: [AppConstants.UserDefaults.ExportablePreference] {
        AppConstants.UserDefaults.exportablePreferences
    }

    func makeBackup(
        snapshot: [String: Any],
        twitchChannelName: String? = nil
    ) -> SettingsBackup {
        coder.makeBackup(
            snapshot: snapshot,
            exportablePreferences: exportable,
            twitchChannelName: twitchChannelName,
            appVersion: "1.0.0",
            appBuild: "1",
            exportedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func freeTextOverCapRejected() {
        let key = AppConstants.UserDefaults.discordButton1Label
        var backup = makeBackup(snapshot: [:])
        backup.settings[key] = .string(String(repeating: "x", count: 257))
        let plan = coder.makeApplyPlan(
            backup: backup,
            choices: .init(),
            exportablePreferences: exportable)
        #expect(plan.set[key] == nil)
        #expect(plan.ignoredKeyCount == 1)
    }

    @Test func songListURLRequiresHTTPS() {
        let key = AppConstants.UserDefaults.songRequestSongListURL
        var backup = makeBackup(snapshot: [:])
        backup.settings[key] = .string("http://example.com/list")
        let plan = coder.makeApplyPlan(
            backup: backup,
            choices: .init(),
            exportablePreferences: exportable)
        #expect(plan.set[key] == nil)
        #expect(plan.ignoredKeyCount == 1)
        #expect(Preferences.normalizedHTTPSURL("javascript:alert(1)") == nil)
        #expect(Preferences.normalizedHTTPSURL("https://") == nil)
        #expect(Preferences.normalizedHTTPSURL("https://example.com/" + String(repeating: "a", count: 2_048)) == nil)
        #expect(Preferences.normalizedHTTPSURL(" https://example.com/list ") == "https://example.com/list")
        backup.settings[key] = .string("")
        let cleared = coder.makeApplyPlan(backup: backup, choices: .init(), exportablePreferences: exportable)
        #expect(cleared.set[key] == .string(""))
    }

    @Test func customCommandArrayOverLimitRejected() throws {
        let key = AppConstants.UserDefaults.customCommands
        let command = CustomCommand(trigger: "one", response: "ok")
        var backup = makeBackup(snapshot: [:])
        backup.settings[key] = .data(try JSONCoders.defaultEncoder.encode(
            Array(repeating: command, count: 101)))
        let plan = coder.makeApplyPlan(
            backup: backup,
            choices: .init(),
            exportablePreferences: exportable)
        #expect(plan.set[key] == nil)
    }

    @Test func exposureKeysNotAppliedFromFileImport() {
        let keys = AppConstants.UserDefaults.self
        var backup = makeBackup(snapshot: [
            keys.shareDiagnosticsEnabled: true,
            keys.websocketEnabled: true,
            keys.widgetPort: 8765
        ])
        let plan = coder.makeApplyPlan(
            backup: backup,
            choices: .init(includeLocalSharingSettings: false),
            exportablePreferences: exportable)
        #expect(plan.set[keys.shareDiagnosticsEnabled] == nil)
        #expect(plan.set[keys.websocketEnabled] == nil)
        #expect(plan.set[keys.widgetPort] == nil)
        #expect(plan.ignoredKeyCount == 3)
        backup = makeBackup(snapshot: [keys.websocketEnabled: true])
        let cloudPlan = coder.makeApplyPlan(
            backup: backup,
            choices: .init(),
            exportablePreferences: exportable)
        #expect(cloudPlan.set[keys.websocketEnabled] == .bool(true))
    }

    // MARK: - BackupValue typing

    @Test func backupValueClassifiesSupportedTypes() {
        #expect(BackupValue.make(from: true) == .bool(true))
        #expect(BackupValue.make(from: false) == .bool(false))
        #expect(BackupValue.make(from: 8765) == .int(8765))
        #expect(BackupValue.make(from: 15.0) == .double(15.0))
        #expect(BackupValue.make(from: 30.5) == .double(30.5))
        #expect(BackupValue.make(from: "Neon") == .string("Neon"))
        #expect(BackupValue.make(from: Data([0x01, 0x02])) == .data(Data([0x01, 0x02])))
    }

    @Test func backupValueRejectsUnsupportedTypes() {
        #expect(BackupValue.make(from: Date()) == nil)
        #expect(BackupValue.make(from: [1, 2, 3]) == nil)
    }

    // MARK: - Round trip

    /// Encode then decode keeps each value's tagged type (bool, int, double, string, raw
    /// `Data`), including the portable collections, plus the format and schema version.
    @MainActor
    @Test func roundTripPreservesValueTypes() throws {
        let keys = AppConstants.UserDefaults.self
        let customCommands = Data("[]".utf8)
        let blocklist = try JSONCoders.camelCaseEncoder.encode([
            BlocklistItem(value: "Blocked Song", type: .song)
        ])
        let snapshot: [String: Any] = [
            keys.trackingEnabled: true,
            keys.websocketServerPort: 8765,
            keys.songCommandGlobalCooldown: 15.0,
            keys.widgetTheme: "Neon",
            keys.customCommands: customCommands,
            keys.songRequestBlocklist: blocklist
        ]
        let data = try coder.encode(makeBackup(snapshot: snapshot))
        let decoded = try coder.decode(data)

        #expect(decoded.settings[keys.trackingEnabled] == .bool(true))
        #expect(decoded.settings[keys.websocketServerPort] == .int(8765))
        #expect(decoded.settings[keys.songCommandGlobalCooldown] == .double(15.0))
        #expect(decoded.settings[keys.widgetTheme] == .string("Neon"))
        #expect(decoded.settings[keys.customCommands] == .data(customCommands))
        guard case .data(let roundTrippedBlocklist)? =
            decoded.settings[keys.songRequestBlocklist] else {
            Issue.record("Expected blocklist Data")
            return
        }
        let expectedBlocklist = try JSONCoders.camelCase.decode(
            [BlocklistItem].self,
            from: blocklist
        )
        let actualBlocklist = try JSONCoders.camelCase.decode(
            [BlocklistItem].self,
            from: roundTrippedBlocklist
        )
        #expect(actualBlocklist == expectedBlocklist)
        #expect(decoded.format == SettingsBackup.currentFormat)
        #expect(decoded.schemaVersion == SettingsBackup.currentSchemaVersion)
    }

    // MARK: - Export allow-list

    @Test func exportExcludesAccountAndRuntimeKeys() {
        let keys = AppConstants.UserDefaults.self
        var snapshot: [String: Any] = [keys.trackingEnabled: true]
        for key in keys.accountLinkedKeys { snapshot[key] = "sensitive" }
        for key in keys.runtimeStateKeys { snapshot[key] = "transient" }

        let backup = makeBackup(snapshot: snapshot, twitchChannelName: "mrdemonwolf")

        // Portable key survives.
        #expect(backup.settings[keys.trackingEnabled] == .bool(true))
        // No account or runtime key leaks into the payload.
        for key in keys.accountLinkedKeys { #expect(backup.settings[key] == nil) }
        for key in keys.runtimeStateKeys { #expect(backup.settings[key] == nil) }
        // The only account identity recorded is the public channel name.
        #expect(backup.integrations.twitch?.channelName == "mrdemonwolf")
    }

    @Test func exportSkipsUnsupportedValueTypes() {
        let keys = AppConstants.UserDefaults.self
        let backup = makeBackup(snapshot: [keys.trackingEnabled: Date()])
        #expect(backup.settings[keys.trackingEnabled] == nil)
    }

    @Test func exportUsesTheSameTypeAndEnumSchemaAsImport() {
        let keys = AppConstants.UserDefaults.self
        let commandData = Data("[]".utf8)
        let backup = makeBackup(snapshot: [
            keys.trackingEnabled: "true",
            keys.dockVisibility: "floating",
            keys.customCommands: commandData
        ])

        #expect(backup.settings[keys.trackingEnabled] == nil)
        #expect(backup.settings[keys.dockVisibility] == nil)
        #expect(backup.settings[keys.customCommands] == .data(commandData))
    }

    @Test func exportOmitsTwitchWhenChannelEmpty() {
        let backup = makeBackup(snapshot: [:], twitchChannelName: "  ")
        #expect(backup.integrations.twitch == nil)
    }

    // MARK: - Decode validation

    @Test func decodeRejectsNonJSON() {
        let data = Data("definitely not json".utf8)
        #expect(throws: SettingsBackupCoder.BackupError.notReadable) {
            try coder.decode(data)
        }
    }

    @Test func decodeRejectsForeignFormat() throws {
        let json = """
        {"format":"com.example.other","schemaVersion":1,"appVersion":"1",\
        "appBuild":"1","exportedAt":"2026-01-01T00:00:00Z","settings":{},\
        "integrations":{}}
        """
        #expect(throws: SettingsBackupCoder.BackupError.notWolfWaveFile) {
            try coder.decode(Data(json.utf8))
        }
    }

    @Test func decodeRejectsNewerSchema() throws {
        let json = """
        {"format":"\(SettingsBackup.currentFormat)","schemaVersion":99,\
        "appVersion":"9","appBuild":"9","exportedAt":"2026-01-01T00:00:00Z",\
        "settings":{},"integrations":{}}
        """
        #expect(throws: SettingsBackupCoder.BackupError.unsupportedNewerSchema(99)) {
            try coder.decode(Data(json.utf8))
        }
    }

    @Test func decodeAcceptsCurrentSchemaRoundTrip() throws {
        let data = try coder.encode(makeBackup(snapshot: [:]))
        let decoded = try coder.decode(data)
        #expect(decoded.format == SettingsBackup.currentFormat)
    }

    @Test func decodeAcceptsHandWrittenHistoricalSchemaOneBackup() throws {
        let historicalSchemaOneJSON = """
        {
          "format": "com.mrdemonwolf.wolfwave.settings",
          "schemaVersion": 1,
          "appVersion": "1.0.0",
          "appBuild": "42",
          "exportedAt": "2026-06-02T00:00:00Z",
          "settings": {
            "trackingEnabled": {"type": "bool", "value": true}
          },
          "integrations": {
            "twitch": {"channelName": "legacy_streamer"}
          }
        }
        """

        let decoded = try coder.decode(Data(historicalSchemaOneJSON.utf8))

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.settings[AppConstants.UserDefaults.trackingEnabled] == .bool(true))
        #expect(decoded.integrations.twitch?.channelName == "legacy_streamer")
    }

    @Test func decodeRejectsSchemasOlderThanOne() {
        for version in [0, -1] {
            let json = """
            {"format":"\(SettingsBackup.currentFormat)","schemaVersion":\(version)}
            """
            #expect(throws: SettingsBackupCoder.BackupError.unsupportedOlderSchema(version)) {
                try coder.decode(Data(json.utf8))
            }
        }
    }
}
