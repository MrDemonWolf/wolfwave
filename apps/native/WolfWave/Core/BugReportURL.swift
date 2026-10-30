//
//  BugReportURL.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Builds a GitHub new-issue URL that opens the `bug_report.yml` issue form
/// with this install's details already filled in, so users can file bug
/// reports with minimal friction.
///
/// GitHub issue forms ignore `body=`. A form prefills only the fields a query
/// parameter names by their `id`, so each value goes to its own field (see
/// ``FormField``):
/// - App version + build
/// - macOS version
/// - The full environment block (architecture, install method, log size,
///   diagnostics opt-in, and the last crash when there was one)
///
/// Kept as a pure value type to allow unit testing without UI dependencies.
enum BugReportURL {

    // MARK: - Form Fields

    /// The issue form field ids this URL prefills.
    ///
    /// Each must match the `id:` of a text field (`input` or `textarea`) in
    /// `.github/ISSUE_TEMPLATE/bug_report.yml`; `make lint-sync` fails when one
    /// doesn't. GitHub only prefills text fields from a URL, so the required
    /// Install method dropdown is left for the reporter (the environment block
    /// names it anyway).
    enum FormField {
        /// The "App version" input.
        static let appVersion = "app-version"
        /// The "macOS version" input.
        static let osVersion = "os-version"
        /// The "Environment" textarea, which takes ``DiagnosticSnapshot/markdownBullets``.
        static let environment = "environment"
    }

    // MARK: - Building

    /// Builds the GitHub issue URL from a captured ``DiagnosticSnapshot``.
    ///
    /// The snapshot carries the crash flag, log size, and diagnostics opt-in
    /// alongside the version, OS, architecture, and install method. "Report a
    /// Bug" is the primary button on the crash-recovery callout, so the form it
    /// opens has to say something about the crash.
    ///
    /// - Parameters:
    ///   - base: Base new-issue URL (e.g. `AppConstants.URLs.githubIssuesNew`).
    ///   - snapshot: The environment to fill into the form.
    /// - Returns: A URL pointing to the GitHub issue form with its fields
    ///   prefilled, or `nil` if the base URL is malformed.
    static func make(base: String, snapshot: DiagnosticSnapshot) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }

        components.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "labels", value: "bug"),
            URLQueryItem(name: "title", value: "[Bug] "),
            URLQueryItem(name: FormField.appVersion, value: "\(snapshot.appVersion) (build \(snapshot.build))"),
            URLQueryItem(name: FormField.osVersion, value: snapshot.osVersion),
            URLQueryItem(name: FormField.environment, value: snapshot.markdownBullets)
        ]
        // URLComponents leaves `+` as is, and GitHub decodes it as a space, so a
        // crash note naming a class method (`+[NSObject foo]`) would lose it.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")

        return components.url
    }

    // MARK: - Actions

    /// Gathers the running app's environment (version, build, macOS version,
    /// architecture, install method) and opens the prefilled GitHub issue form
    /// in the default browser.
    ///
    /// Shared by the tray menu's "Report a Bug" and the About pane's
    /// "Send Feedback" so environment assembly lives in one place.
    @MainActor
    static func openPrefilledIssue() {
        // Snapshot form, so the report carries the crash flag, log size, and
        // diagnostics opt-in rather than four environment lines and no state.
        let url = make(
            base: AppConstants.URLs.githubIssuesNew,
            snapshot: DiagnosticSnapshot.capture(logSizeBytes: Log.logFileSize())
        )
        guard let url else {
            Log.error("BugReportURL: Failed to build bug report URL", category: .app)
            return
        }
        ExternalLink.open(url.absoluteString)
    }

    // MARK: - Helpers

    /// Returns the current process's CPU architecture identifier, decided at
    /// compile time (an x86_64 build under Rosetta reports `x86_64`).
    static func currentArch() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
