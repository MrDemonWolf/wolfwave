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
            description: "A quick walk-through so viewers can request songs in your Twitch chat. You can change all of this later in settings.",
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
                Group {
                    if viewModel.isTwitchConnected {
                        CalloutBanner("Twitch is connected. You're good to go.", style: .success)
                    } else {
                        CalloutBanner(
                            "Next unlocks once Twitch is connected. Song requests arrive through your chat.",
                            style: .info,
                            systemImage: "lock.fill"
                        )
                        Button("Open Twitch settings") {
                            dismiss()
                            openTwitchSettings()
                        }
                        .pointerCursor()
                        .accessibilityIdentifier("songRequestSetupOpenTwitchSettings")
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
            description: "WolfWave searches Apple Music for requested songs and plays them in Music.app.",
            icon: { appleMusicTile },
            extras: {
                Group {
                    if musicAuthStatus == .authorized {
                        CalloutBanner("Apple Music access granted.", style: .success)
                    } else if musicAuthStatus == .denied {
                        CalloutBanner(
                            "Apple Music access was denied. Turn it on in System Settings, Privacy & Security, then Media & Apple Music.",
                            style: .warning
                        )
                        Button("Open System Settings") {
                            ExternalLink.open(AppConstants.URLs.systemMusicSettings)
                        }
                        .pointerCursor()
                    } else if musicAuthStatus == .restricted {
                        CalloutBanner(
                            "Apple Music access is restricted on this Mac. Check parental controls or ask its administrator.",
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

    /// Creates the playlist on entry (see `.task(id:)` in `body`) and reports
    /// progress, success, a local-visibility warning, or a retryable error.
    private var playlistStep: some View {
        OnboardingStepScaffold(
            title: "Create your requests playlist",
            description: "Requested songs go into one playlist called \(AppConstants.Music.requestsPlaylistName) so your library stays tidy. WolfWave makes it for you.",
            icon: { appleMusicTile },
            extras: {
                VStack(spacing: DSSpace.s3) {
                    if ensuringPlaylist {
                        HStack(spacing: DSSpace.s2) {
                            ProgressView().controlSize(.small)
                            Text("Setting up \(AppConstants.Music.requestsPlaylistName)\u{2026}")
                                .font(.system(size: DSFont.Size.body))
                                .foregroundStyle(.secondary)
                        }
                    } else if viewModel.playlistReady {
                        if playlistLocalVisibility == .notVisible {
                            CalloutBanner(
                                "\(AppConstants.Music.requestsPlaylistName) was made in your Apple Music library, but Music on this Mac can't see it yet. Songs play out of Music, so turn on Sync Library in Music, Settings, General, then check again.",
                                style: .warning
                            )
                            AsyncActionButton(title: "Check Again", showsSuccess: false) {
                                await refreshPlaylistLocalVisibility()
                            }
                        } else {
                            CalloutBanner("\(AppConstants.Music.requestsPlaylistName) is ready.", style: .success)
                        }
                        Text("Made by WolfWave, with a description so chat knows what it is. Apple builds the cover from the songs as they come in.")
                            .font(.system(size: DSFont.Size.xs))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let playlistError {
                        VStack(spacing: DSSpace.s3) {
                            CalloutBanner(playlistError, style: .warning)
                            AsyncActionButton(title: "Try Again", showsSuccess: false) {
                                await ensurePlaylist()
                            }
                        }
                    }
                }
            }
        )
    }

    // MARK: Step 4 - Optional share link

    /// Three-step guide to making the playlist public, a fetch button, and a
    /// paste-your-own field. Blank skips; an invalid link blocks Next.
    private var shareLinkStep: some View {
        OnboardingStepScaffold(
            title: "Share your playlist",
            description: "Optional. Turn this on if you want !playlist to drop a link to your requests playlist in chat.",
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
                VStack(alignment: .leading, spacing: DSSpace.s4) {
                    VStack(alignment: .leading, spacing: DSSpace.s3) {
                        setupStep(1, "Open your requests playlist") {
                            AsyncActionButton(title: "Open in Music", showsSuccess: false) {
                                await openPlaylistInMusic()
                            }
                        }
                        setupStep(2, "In Music: tap Share, then Show on Profile") { EmptyView() }
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
                        FieldValidationRow(state: .invalid("Use an HTTPS link with a host, up to 2,048 characters."))
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
            description: "Viewers can request songs with !sr. Fine-tune who can request, queue limits, and commands anytime in settings.",
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
                VStack(alignment: .leading, spacing: DSSpace.s4) {
                    VStack(alignment: .leading, spacing: DSSpace.s2) {
                        recapRow(viewModel.isTwitchConnected, "Twitch connected")
                        recapRow(viewModel.musicAuthorized, "Apple Music access granted")
                        recapRow(viewModel.playlistReady, "\(AppConstants.Music.requestsPlaylistName) created")
                        recapRow(hasSongListLink, hasSongListLink ? "!playlist link shared" : "Song list link (skipped)")
                    }
                    .padding(DSSpace.s4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .subtleCardShell()

                    Text("Turning this on enables song requests right away. You can switch it off whenever you like.")
                        .font(.system(size: DSFont.Size.sm))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        )
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
