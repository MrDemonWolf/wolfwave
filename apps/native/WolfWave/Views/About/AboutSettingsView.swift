//
//  AboutSettingsView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-15.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import SwiftUI

/// About pane shown in the Settings sidebar. Single source of truth for app
/// identity, quick actions, and legal links. Replaces the legacy standalone
/// About window. Uses the same section-header + `.cardStyle()` rhythm as
/// `AdvancedSettingsView` / `GeneralSettingsView`.
struct AboutSettingsView: View {

    // MARK: - Environment

    /// Drops the copy-confirmation animation when Reduce Motion is on.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - State

    /// True for about 1.5 seconds after the version pill is clicked; swaps
    /// its glyph to a checkmark.
    @State private var versionCopied = false

    // MARK: - Settings

    /// Opt-out for every sponsorship link in the app. The toggle itself stays
    /// visible so it can be turned back on.
    @AppStorage(AppConstants.UserDefaults.sponsorLinksEnabled)
    private var sponsorLinksEnabled = AppConstants.UserDefaults.Defaults.sponsorLinksEnabled

    // MARK: - Bundle Info (shared with the menu bar's standard About panel)

    /// Bundle display name (see `AboutCopy.appName`).
    private var appName: String { AboutCopy.appName }
    /// "Version X (build)" label for the pill.
    private var versionString: String { AboutCopy.versionString }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: AppConstants.SettingsUI.sectionSpacing) {
            identityCard
            actionsCard
            linksCard
            acknowledgementsCard
        }
        .accessibilityIdentifier("about-settings.root")
    }

    // MARK: - Identity Card

    /// Card wrapping the icon / name / version hero.
    private var identityCard: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            VStack(alignment: .leading, spacing: DSSpace.s1) {
                Text("Identity")
                    .font(.system(size: DSFont.Size.base, weight: .semibold))
                Text("App name, version, and quick-copy build info.")
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.secondary)
            }

            hero
        }
        .cardStyle()
    }

    /// Identity hero: app icon on the leading edge, name + version pill stacked
    /// on the trailing side. Mirrors the system standard About panel's
    /// icon-left / text-right layout.
    private var hero: some View {
        HStack(alignment: .center, spacing: DSSpace.s5) {
            Image(AboutCopy.iconAssetName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DSSpace.s2) {
                Text(appName)
                    .font(.system(size: DSFont.Size.x2xl, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                versionPill
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Bordered button showing the version; clicking copies
    /// `AboutCopy.versionClipboardPayload` for bug reports.
    private var versionPill: some View {
        Button(action: copyVersion) {
            HStack(spacing: DSSpace.s1h) {
                Text(versionString)
                    .font(.system(size: DSFont.Size.body, weight: .medium))
                Image(systemName: versionCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: DSFont.Size.xs, weight: .semibold))
                    .foregroundStyle(versionCopied ? .green : .secondary)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .pointerCursor()
        .help("Copy version info to clipboard")
        .accessibilityLabel("\(versionString). Click to copy.")
        .accessibilityIdentifier("about-settings.versionPill")
    }

    // MARK: - Actions Card

    /// Quick links (release notes, docs, feedback, optional sponsor) plus the
    /// sponsor-links opt-out.
    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            VStack(alignment: .leading, spacing: DSSpace.s1) {
                Text("Quick actions")
                    .font(.system(size: DSFont.Size.base, weight: .semibold))
                Text(sponsorLinksEnabled
                     ? "Release notes, docs, feedback, and sponsorship."
                     : "Release notes, docs, and feedback.")
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.secondary)
            }

            actionGrid
            sponsorToggle
        }
        .cardStyle()
    }

    /// Two-column grid of quick actions. The Sponsor cell is omitted when
    /// sponsor links are turned off, leaving Send Feedback alone in its row.
    private var actionGrid: some View {
        ActionGrid {
            GridRow {
                ActionGridButton(title: "Release Notes", systemImage: "list.bullet.rectangle", action: openReleaseNotes,
                                 accessibilityIdentifier: "about-settings.action.Release Notes")
                ActionGridButton(title: "Docs", systemImage: "book", action: openDocs,
                                 accessibilityIdentifier: "about-settings.action.Docs")
            }
            GridRow {
                ActionGridButton(title: "Send Feedback", systemImage: "envelope", action: sendFeedback,
                                 accessibilityIdentifier: "about-settings.action.Send Feedback")
                if sponsorLinksEnabled {
                    ActionGridButton(title: "Sponsor on GitHub", systemImage: "heart.fill", action: openSponsor,
                                     accessibilityIdentifier: "about-settings.action.Sponsor on GitHub")
                }
            }
        }
    }

    /// Owns the opt-out for every sponsorship link in the app. Lives here, next
    /// to the button it hides, so turning it back on is findable.
    private var sponsorToggle: some View {
        ToggleSettingRow(
            title: "Show sponsor links",
            subtitle: "Adds a Sponsor item here, in the menu bar, and in the Help menu. WolfWave is free either way.",
            isOn: $sponsorLinksEnabled,
            accessibilityLabel: "Show sponsor links",
            accessibilityIdentifier: "about-settings.sponsorLinksToggle",
            accessibilityHint: "Hides every sponsorship link in the app. This toggle stays here."
        )
    }

    // MARK: - Links & Legal Card

    /// Privacy / Terms links above the independence, trademark, and copyright text.
    private var linksCard: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            VStack(alignment: .leading, spacing: DSSpace.s1) {
                Text("Links & legal")
                    .font(.system(size: DSFont.Size.base, weight: .semibold))
                Text("Privacy, terms, and attributions.")
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: DSSpace.s3) {
                legalLinksRow
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cardStyle()
    }

    // MARK: - Legal Links

    /// "Privacy · Terms" link row. A link whose URL constant fails to parse is
    /// simply omitted.
    private var legalLinksRow: some View {
        HStack(spacing: DSSpace.s3) {
            if let url = URL(string: AppConstants.URLs.privacyPolicy) {
                Link("Privacy", destination: url)
                    .accessibilityLabel("Open privacy policy")
                    .accessibilityIdentifier("about-settings.link.privacy")
            }
            Text("·").foregroundStyle(.tertiary)
            if let url = URL(string: AppConstants.URLs.termsOfService) {
                Link("Terms", destination: url)
                    .accessibilityLabel("Open terms of service")
                    .accessibilityIdentifier("about-settings.link.terms")
            }
        }
        .font(.system(size: DSFont.Size.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// Legal text from `AboutCopy`, shared with the standard About panel.
    private var footer: some View {
        VStack(alignment: .leading, spacing: DSSpace.s1h) {
            Text(AboutCopy.independenceNotice)
                .font(.system(size: DSFont.Size.xs))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Text(AboutCopy.trademarkNotice)
                .font(.system(size: DSFont.Size.xs))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Text(AboutCopy.copyrightLine)
                .font(.system(size: DSFont.Size.xs))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Acknowledgements Card

    /// Third-party services and open-source dependencies, plus a link to the
    /// full license notices. Keep the lists in step with what the app actually
    /// calls and links.
    private var acknowledgementsCard: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            VStack(alignment: .leading, spacing: DSSpace.s1) {
                Text("Acknowledgements")
                    .font(.system(size: DSFont.Size.base, weight: .semibold))
                Text("Third-party services and open-source software WolfWave depends on.")
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: DSSpace.s4) {
                acknowledgementsSection(
                    title: "Third-party services",
                    rows: [
                        "Twitch: EventSub WebSocket + Helix API",
                        "Discord: local IPC Rich Presence",
                        "Apple Music: ScriptingBridge and MusicKit",
                        "Odesli (song.link): link target only, no API calls",
                        "Spotify and YouTube oEmbed: titles for pasted song request links",
                        "iTunes Search API: album artwork and Apple Music URLs"
                    ]
                )

                acknowledgementsSection(
                    title: "Open source",
                    rows: [
                        "Sparkle: auto-update framework (MIT license)"
                    ]
                )

                if let url = URL(string: AppConstants.URLs.acknowledgements) {
                    Link("View full licenses and notices", destination: url)
                        .font(.system(size: DSFont.Size.sm))
                        .accessibilityLabel("Open acknowledgements and license notices")
                        .accessibilityIdentifier("about-settings.link.acknowledgements")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cardStyle()
    }

    /// A small heading followed by one bulleted line per row.
    private func acknowledgementsSection(title: String, rows: [String]) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.s2) {
            Text(title)
                .font(.system(size: DSFont.Size.sm, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(rows, id: \.self) { row in
                Text("• \(row)")
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    /// Copies the version payload and shows the checkmark, then reverts it
    /// after 1.5 seconds.
    private func copyVersion() {
        let payload = AboutCopy.versionClipboardPayload
        Pasteboard.copy(payload)

        withAnimation(reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.fast)) { versionCopied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            withAnimation(reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.base)) { versionCopied = false }
        }
    }

    /// Opens the web changelog.
    private func openReleaseNotes() {
        ExternalLink.open(AppConstants.URLs.changelog)
    }

    /// Opens the GitHub Sponsors page.
    private func openSponsor() {
        ExternalLink.open(AppConstants.URLs.githubSponsors)
    }

    /// The single entry to the documentation site. Website and Documentation
    /// used to be two controls that opened the same URL.
    private func openDocs() {
        ExternalLink.open(AppConstants.URLs.docs)
    }

    /// Opens a pre-filled GitHub issue (environment details included).
    private func sendFeedback() {
        BugReportURL.openPrefilledIssue()
    }
}

// MARK: - Preview

#Preview {
    AboutSettingsView()
        .padding()
        .frame(width: 700)
}
