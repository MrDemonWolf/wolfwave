//
//  SongRequestSetupView+Steps.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import MusicKit
import SwiftUI

/// The five steps of the Song Requests guided setup: intro, Apple Music access,
/// the requests playlist, the optional share link, and the done recap.
extension SongRequestSetupView {

    // MARK: - Step Content

    /// The current step's view, re-identified per step so it slides in the
    /// direction of travel.
    @ViewBuilder
    var stepContent: some View {
        Group {
            switch viewModel.currentStep {
            case .intro: introStep
            case .appleMusic: appleMusicStep
            case .playlist: playlistStep
            case .shareLink: shareLinkStep
            case .done: doneStep
            }
        }
        .id(viewModel.currentStep)
        .transition(reduceMotion
            ? AnyTransition.opacity
            : .asymmetric(
                insertion: .move(edge: navigationDirection).combined(with: .opacity),
                removal: .move(edge: navigationDirection == .trailing ? .leading : .trailing).combined(with: .opacity)
            )
        )
    }

    // MARK: Step 1 - Intro

    /// Explains the feature; offers a jump to Twitch settings until connected.
    private var introStep: some View {
        OnboardingStepScaffold(
            title: "Set up Song Requests",
            description: "A quick walk-through so viewers can request songs from your Twitch chat. "
                + "You can change all of it later.",
            icon: {
                BrandTile(
                    background: AnyShapeStyle(AppConstants.Brand.twitch),
                    glowColor: AppConstants.Brand.twitch,
                    glyph: Image(systemName: "music.note.list")
                        .font(BrandTileGlyph.font)
                        .foregroundStyle(.white)
                )
            },
            extras: {
                stepExtras {
                    if viewModel.isTwitchConnected {
                        CalloutBanner("Twitch is connected.", style: .success)
                    } else {
                        CalloutBanner(
                            "Connect Twitch first. Requests come in through your chat.",
                            style: .info,
                            systemImage: "lock.fill"
                        ) {
                            Button("Open Twitch Settings") {
                                dismiss()
                                openTwitchSettings()
                            }
                            .buttonStyle(.bordered)
                            .pointerCursor()
                            .accessibilityIdentifier("songRequestSetupOpenTwitchSettings")
                        }
                    }
                }
            }
        )
    }

    // MARK: Step 2 - Apple Music access

    /// MusicKit authorization: grant button, or the matching granted /
    /// denied / restricted message.
    private var appleMusicStep: some View {
        OnboardingStepScaffold(
            title: "Allow Apple Music access",
            description: "WolfWave finds requested songs on Apple Music and plays them in Music.",
            icon: { appleMusicTile },
            extras: {
                stepExtras {
                    if musicAuthStatus == .authorized {
                        CalloutBanner("Apple Music access granted.", style: .success)
                    } else if musicAuthStatus == .denied {
                        CalloutBanner(
                            "Apple Music access is off. Turn it on in "
                                + "System Settings › Privacy & Security › Media & Apple Music.",
                            style: .warning
                        ) {
                            Button("Open System Settings") {
                                ExternalLink.open(AppConstants.URLs.systemMusicSettings)
                            }
                            .buttonStyle(.bordered)
                            .pointerCursor()
                            .accessibilityIdentifier("songRequestSetup.openMusicPrivacy")
                        }
                    } else if musicAuthStatus == .restricted {
                        CalloutBanner(
                            "Apple Music access is blocked on this Mac. "
                                + "Check Screen Time, or ask whoever manages this Mac.",
                            style: .warning
                        )
                    } else {
                        PillButton(
                            background: AnyShapeStyle(
                                LinearGradient(
                                    colors: [AppConstants.Brand.appleMusicGradientStart, AppConstants.Brand.appleMusicGradientEnd],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            ),
                            disabled: isRequestingMusicAuth,
                            action: { requestMusicAuth() },
                            label: {
                                HStack(spacing: DSSpace.s1h) {
                                    if isRequestingMusicAuth { ProgressView().controlSize(.small) }
                                    Text("Grant Apple Music Access")
                                }
                            }
                        )
                    }
                }
            }
        )
    }

    // MARK: Step 3 - Requests playlist

    /// Makes the playlist on entry (see `.task(id:)` in `body`), then waits for
    /// Music to pick it up. Shows progress, success, a Sync Library warning only
    /// after the full wait, or a retryable error.
    private var playlistStep: some View {
        OnboardingStepScaffold(
            title: "Create your requests playlist",
            description: "Requested songs go into one playlist, "
                + "\(AppConstants.Music.requestsPlaylistName). WolfWave makes it for you.",
            icon: { appleMusicTile },
            extras: {
                stepExtras {
                    if ensuringPlaylist {
                        progressRow("Making \(AppConstants.Music.requestsPlaylistName)\u{2026}")
                    } else if viewModel.playlistReady {
                        playlistReadyState
                    } else if let playlistError {
                        CalloutBanner(playlistError, style: .warning) {
                            AsyncActionButton(title: "Try Again", showsSuccess: false) {
                                await ensurePlaylist()
                            }
                        }
                    }
                }
            }
        )
    }

    /// The playlist exists in Apple Music; this is where it stands in Music on
    /// this Mac. Only `notInMusic`, reached after the full wait, warns.
    @ViewBuilder
    private var playlistReadyState: some View {
        let name = AppConstants.Music.requestsPlaylistName
        switch viewModel.playlistMusicState {
        case .unchecked, .checking:
            progressRow("Adding it to Music\u{2026} This can take a few seconds.")
        case .inMusic:
            CalloutBanner("\(name) is ready in Music.", style: .success)
        case .unverified:
            CalloutBanner("\(name) is ready. Open Music before you go live.", style: .success)
        case .notInMusic:
            CalloutBanner(
                "Turn on Music › Settings › General › Sync Library, then check again. "
                    + "You can finish setup now and fix this later.",
                title: "Music can't see \(name) yet",
                style: .warning
            ) {
                Button("Check Again") { checkPlaylistAgain() }
                    .buttonStyle(.bordered)
                    .pointerCursor()
                    .accessibilityIdentifier("songRequestSetup.checkPlaylistAgain")
            }
        }
    }

    /// A small spinner with a calm status line, for work that needs no input.
    private func progressRow(_ text: String) -> some View {
        HStack(spacing: DSSpace.s2) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.system(size: DSFont.Size.body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Step 4 - Optional share link

    /// Three-step guide to making the playlist public, a fetch button, and a
    /// paste-your-own field. Blank skips; an invalid link blocks Next.
    private var shareLinkStep: some View {
        OnboardingStepScaffold(
            title: "Share your playlist",
            description: "Want !playlist to post a link to your requests playlist in chat? "
                + "Make it public here, or skip.",
            isOptional: true,
            icon: {
                BrandTile(
                    background: AnyShapeStyle(AppConstants.Brand.twitch),
                    glowColor: AppConstants.Brand.twitch,
                    glyph: Image(systemName: "square.and.arrow.up")
                        .font(BrandTileGlyph.font)
                        .foregroundStyle(.white)
                )
            },
            extras: {
                stepExtras(alignment: .leading) {
                    VStack(alignment: .leading, spacing: DSSpace.s3) {
                        setupStep(1, "Open your requests playlist") {
                            AsyncActionButton(title: "Open in Music", showsSuccess: false) {
                                await openPlaylistInMusic()
                            }
                        }
                        setupStep(2, "In Music, click Share, then Show on Profile") { EmptyView() }
                        setupStep(3, "Grab the link") {
                            AsyncActionButton(
                                title: "Fetch link",
                                style: .borderedProminent,
                                showsSuccess: false
                            ) {
                                await fetchSongListLink()
                            }
                        }
                    }
                    .padding(DSSpace.s4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .subtleCardShell()

                    if let fetchStatus {
                        Text(fetchStatus)
                            .font(.system(size: DSFont.Size.xs))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    TextField("Link shows up here, or paste your own", text: $songListDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: DSFont.Size.body))

                    Text("Leave blank to skip. !playlist stays off until a link is set.")
                        .font(.system(size: DSFont.Size.xs))
                        .foregroundStyle(.secondary)
                    if Preferences.normalizedHTTPSURL(songListDraft) == nil {
                        FieldValidationRow(state: .invalid("Use a full https:// link."))
                    }
                }
            }
        )
    }

    // MARK: Step 5 - Done

    /// Recap of each step's outcome before the finish button.
    private var doneStep: some View {
        OnboardingStepScaffold(
            title: "You're all set",
            description: "Viewers request songs with !sr. "
                + "Change who can request, queue limits, and commands anytime in settings.",
            icon: {
                BrandTile(
                    background: AnyShapeStyle(DSColor.success),
                    glowColor: DSColor.success,
                    glyph: Image(systemName: "checkmark")
                        .font(BrandTileGlyph.font)
                        .foregroundStyle(.white)
                )
            },
            extras: {
                stepExtras(alignment: .leading) {
                    VStack(alignment: .leading, spacing: DSSpace.s2) {
                        recapRow(viewModel.isTwitchConnected, "Twitch connected")
                        recapRow(viewModel.musicAuthorized, "Apple Music access allowed")
                        recapRow(viewModel.playlistReady, "\(AppConstants.Music.requestsPlaylistName) made")
                        recapRow(hasSongListLink, hasSongListLink ? "!playlist link shared" : "Song list link (skipped)")
                    }
                    .padding(DSSpace.s4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .subtleCardShell()

                    if viewModel.playlistMusicState == .notInMusic {
                        CalloutBanner(
                            "Music can't see \(AppConstants.Music.requestsPlaylistName) yet, so requests won't play. "
                                + "Turn on Music › Settings › General › Sync Library.",
                            style: .warning
                        )
                    }

                    Text("Song requests start as soon as you turn them on. Switch them off anytime.")
                        .font(.system(size: DSFont.Size.sm))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        )
    }

    /// Wraps a step's extras: one consistent stack, pinned to the top of the
    /// scaffold's extras slot. The scaffold centers short extras in a tall
    /// slot, which left a large gap under the header; filling the slot from
    /// the top keeps every step's content right under its description. It also
    /// keeps multi-view extras in one stack, where a bare `Group` let the
    /// scaffold frame each child separately.
    func stepExtras<Content: View>(
        alignment: HorizontalAlignment = .center,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: alignment, spacing: DSSpace.s3) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
        .frame(minHeight: DSDimension.Onboarding.stepContentMinHeight, alignment: .top)
    }

    /// Persists the share-link draft when it is blank or a valid HTTPS link
    /// (stored in its normalized form). An invalid draft leaves the stored
    /// link untouched.
    func commitSongListDraft(_ draft: String) {
        guard let normalized = Preferences.normalizedHTTPSURL(draft) else { return }
        if songListURL != normalized { songListURL = normalized }
    }

    /// Whether a `!playlist` share link is configured (drives the Done recap).
    private var hasSongListLink: Bool {
        guard let link = Preferences.normalizedHTTPSURL(songListURL) else { return false }
        return !link.isEmpty
    }

    /// One line in the Done-step recap: a filled check when done, a hollow circle
    /// when skipped or not yet satisfied.
    @ViewBuilder
    private func recapRow(_ done: Bool, _ text: String) -> some View {
        HStack(spacing: DSSpace.s2) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: DSFont.Size.body))
                .foregroundStyle(done ? DSColor.success : Color.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: DSFont.Size.body))
                .foregroundStyle(done ? .primary : .secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(text), \(done ? "done" : "skipped")")
    }
}
