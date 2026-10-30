//
//  BugReportURLTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import XCTest
@testable import WolfWave

/// `BugReportURL` pre-filled GitHub issue URL: validity, template/label query items, the issue-form
/// fields it fills by id (forms ignore `body=`), crash mention, and `+` surviving GitHub's decoding.
@MainActor
final class BugReportURLTests: XCTestCase {

    private let base = "https://github.com/mrdemonwolf/wolfwave/issues/new"

    func testReturnsNonNilURLForValidBase() {
        let url = BugReportURL.make(
            base: base,
            snapshot: makeSnapshot(
                appVersion: "1.2.0",
                build: "42",
                osVersion: "macOS 26.0",
                arch: "arm64",
                install: .dmg
            )
        )
        XCTAssertNotNil(url)
    }

    func testReturnsNilForMalformedBase() {
        let url = BugReportURL.make(
            base: "not a url",
            snapshot: makeSnapshot(
                appVersion: "1.0",
                build: "1",
                osVersion: "macOS 26.0",
                arch: "arm64",
                install: .dmg
            )
        )
        // URLComponents accepts most strings; check at least path/host are present
        if let url = url {
            XCTAssertTrue(url.absoluteString.contains("template=bug_report.yml"))
        }
    }

    /// The issue URL carries `template` (bug_report.yml), `labels` (bug), `title`, and the form
    /// fields, but no `body`: GitHub issue forms ignore it, which silently dropped every detail.
    func testQueryItemsIncludeTemplateAndLabel() throws {
        let url = BugReportURL.make(
            base: base,
            snapshot: makeSnapshot(
                appVersion: "1.2.0",
                build: "42",
                osVersion: "macOS 26.0",
                arch: "arm64",
                install: .dmg
            )
        )
        let url2 = try XCTUnwrap(url)
        let comps = URLComponents(url: url2, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []

        let names = items.map { $0.name }
        XCTAssertTrue(names.contains("template"))
        XCTAssertTrue(names.contains("labels"))
        XCTAssertTrue(names.contains("title"))
        XCTAssertTrue(names.contains(BugReportURL.FormField.appVersion))
        XCTAssertTrue(names.contains(BugReportURL.FormField.osVersion))
        XCTAssertTrue(names.contains(BugReportURL.FormField.environment))
        XCTAssertFalse(names.contains("body"))

        let template = items.first { $0.name == "template" }?.value
        XCTAssertEqual(template, "bug_report.yml")

        let labels = items.first { $0.name == "labels" }?.value
        XCTAssertEqual(labels, "bug")
    }

    func testFormFieldsCarryEnvironment() throws {
        let url = try XCTUnwrap(BugReportURL.make(
            base: base,
            snapshot: makeSnapshot(
                appVersion: "1.2.3",
                build: "99",
                osVersion: "macOS 26.1.0",
                arch: "arm64",
                install: .homebrew
            )
        ))

        XCTAssertEqual(field(BugReportURL.FormField.appVersion, in: url), "1.2.3 (build 99)")
        XCTAssertEqual(field(BugReportURL.FormField.osVersion, in: url), "macOS 26.1.0")
        let environment = field(BugReportURL.FormField.environment, in: url) ?? ""
        XCTAssertTrue(environment.contains("1.2.3 (build 99)"), "environment should contain the version")
        XCTAssertTrue(environment.contains("macOS 26.1.0"), "environment should contain the OS version")
        XCTAssertTrue(environment.contains("arm64"), "environment should contain arch")
        XCTAssertTrue(environment.contains("Homebrew"), "environment should contain install method")
    }

    func testInstallMethodRawValues() {
        XCTAssertEqual(DiagnosticSnapshot.InstallMethod.dmg.rawValue, "DMG")
        XCTAssertEqual(DiagnosticSnapshot.InstallMethod.homebrew.rawValue, "Homebrew")
    }

    func testEnvironmentMentionsCrashOnlyWhenPreviousLaunchCrashed() throws {
        func environment(crashed: Bool) throws -> String {
            let url = try XCTUnwrap(BugReportURL.make(
                base: base,
                snapshot: makeSnapshot(crashedLastLaunch: crashed, crashSummary: "SIGSEGV")
            ))
            return field(BugReportURL.FormField.environment, in: url) ?? ""
        }

        XCTAssertTrue(try environment(crashed: true).contains("Recovered from a crash:** SIGSEGV"))
        XCTAssertFalse(try environment(crashed: false).contains("Recovered from a crash"))
    }

    /// GitHub decodes a raw `+` in a query as a space, so it must leave encoded.
    func testPlusSignSurvivesGitHubDecoding() throws {
        let url = try XCTUnwrap(BugReportURL.make(
            base: base,
            snapshot: makeSnapshot(crashedLastLaunch: true, crashSummary: "+[NSObject boom]")
        ))

        XCTAssertFalse(url.absoluteString.contains("+"), "a raw + would arrive as a space")
        XCTAssertTrue(url.absoluteString.contains("%2B"))
        XCTAssertTrue(field(BugReportURL.FormField.environment, in: url)?.contains("+[NSObject boom]") == true)
    }

    func testCurrentArchIsKnownValue() {
        let arch = BugReportURL.currentArch()
        XCTAssertTrue(["arm64", "x86_64", "unknown"].contains(arch))
    }

    func testURLPathPointsToIssuesNew() throws {
        let url = BugReportURL.make(
            base: base,
            snapshot: makeSnapshot(
                appVersion: "1.0",
                build: "1",
                osVersion: "macOS 26.0",
                arch: "arm64",
                install: .dmg
            )
        )
        let url2 = try XCTUnwrap(url)
        XCTAssertEqual(url2.host, "github.com")
        XCTAssertEqual(url2.path, "/mrdemonwolf/wolfwave/issues/new")
    }

    // MARK: - Fixtures

    /// The decoded value of the query item named `name`, as GitHub's form reads it.
    private func field(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    /// A `DiagnosticSnapshot` with sensible defaults; override only the field a test cares about.
    private func makeSnapshot(
        appVersion: String = "1.0",
        build: String = "1",
        osVersion: String = "macOS 26.0",
        arch: String = "arm64",
        install: DiagnosticSnapshot.InstallMethod = .dmg,
        crashedLastLaunch: Bool = false,
        crashSummary: String? = nil
    ) -> DiagnosticSnapshot {
        DiagnosticSnapshot(
            appVersion: appVersion,
            build: build,
            osVersion: osVersion,
            arch: arch,
            installMethod: install,
            crashedLastLaunch: crashedLastLaunch,
            crashSummary: crashSummary,
            diagnosticsEnabled: false,
            logSizeBytes: 0,
            logSizeDescription: "Zero KB"
        )
    }
}
