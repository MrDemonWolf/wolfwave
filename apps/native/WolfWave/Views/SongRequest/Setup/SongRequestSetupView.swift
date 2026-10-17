//
//  SongRequestSetupView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-06-08.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import MusicKit
import SwiftUI

/// Guided Song Requests setup, shown as a sheet over the settings window.
///
/// A small analog of the first-launch `OnboardingView`: progress dots, one step
/// at a time through the shared `OnboardingStepScaffold`, and a Back / Next /
/// Done bar. It walks the three essentials (Twitch, Apple Music access, the
/// WolfWave Requests playlist) and an optional `!playlist` share step, then
/// flips the master toggle on. Lives in a sheet, not its own `NSWindow`, so it
/// stays anchored to the pane that launched it.
struct SongRequestSetupView: View {

    // MARK: - State

    /// Closes the sheet (Cancel, Finish, or "Open Twitch settings").
    @Environment(\.dismiss) var dismiss

    /// Step state and the Next gate. Created once per sheet presentation.
    @State var viewModel: SongRequestSetupViewModel
    /// Jumps the settings shell to the Twitch pane; called after dismissing.
    var openTwitchSettings: () -> Void

    /// MusicKit authorization, mirrored into `viewModel.musicAuthorized`.
    /// Re-read on appear and whenever the app becomes active.
    @State var musicAuthStatus: MusicAuthorization.Status = MusicAuthorization.currentStatus
    /// True while the MusicKit permission prompt is up.
    @State var isRequestingMusicAuth = false

    /// Creates the requests playlist and resolves its share link (MusicKit).
    @State private var libraryService = AppleMusicLibraryService()
    /// Talks to Music.app (AppleScript) to check local visibility and reveal
    /// the playlist.
    @State private var musicController = AppleMusicController()

    /// True while `ensurePlaylist()` runs.
    @State var ensuringPlaylist = false
    /// Shown with a Try Again button when playlist creation failed.
    @State var playlistError: String?
    /// Whether Music.app can actually see the playlist WolfWave just created in
    /// the cloud library. Surfaced here because the cloud create succeeding is
    /// not the same thing as playback being able to find it.
    @State var playlistLocalVisibility: PlaylistLocalVisibility = .unknown

    /// Result line under the share steps after "Fetch link".
    @State var fetchStatus: String?

    /// Edge the next step slides in from: trailing for Next, leading for Back.
    @State var navigationDirection: Edge = .trailing

    /// Public playlist link for `!playlist`. Written only with a value that
    /// normalizes through `Preferences.normalizedHTTPSURL` (or blank); the
    /// field edits `songListDraft` instead.
    @AppStorage(AppConstants.UserDefaults.songRequestSongListURL)
    var songListURL = ""
    /// What the share-link field shows. Committed to `songListURL` only when
    /// it is blank or a valid HTTPS link, so a half-typed link never persists;
    /// the Next button blocks while it is invalid.
    @State var songListDraft = ""
    /// `!playlist` switch, turned on when a link is fetched.
    @AppStorage(AppConstants.UserDefaults.songListCommandEnabled)
    private var songListCommandEnabled = false

    /// Step transitions become a plain fade under Reduce Motion.
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    /// The running app delegate (`nil` in previews); source of the Twitch service.
    private var appDelegate: AppDelegate? { AppDelegate.shared }

    // MARK: - Init

    /// - Parameters:
    ///   - startAt: Step to open on. `.intro` for a fresh setup, or
    ///     `.shareLink` when launched from the "Re-share Playlist" banner.
    ///   - openTwitchSettings: Navigates to the Twitch pane.
    init(startAt: SongRequestSetupViewModel.Step = .intro, openTwitchSettings: @escaping () -> Void = {}) {
        _viewModel = State(initialValue: SongRequestSetupViewModel(startAt: startAt))
        self.openTwitchSettings = openTwitchSettings
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            progressDots
                .padding(.top, DSSpace.s7)
                .padding(.bottom, DSSpace.s6)

            ScrollView(.vertical, showsIndicators: false) {
                stepContent
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, DSSpace.s6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(DSMotion.Spring.snappy, value: viewModel.currentStep)

            Divider()

            navigationBar
                .padding(.horizontal, DSSpace.s8)
                .padding(.vertical, DSSpace.s5)
                .background(.regularMaterial)
        }
        .frame(width: 580, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            songListDraft = songListURL
            refreshTwitchState()
            syncAuth(MusicAuthorization.currentStatus)
        }
        .onChange(of: songListDraft) { _, draft in commitSongListDraft(draft) }
        .onChange(of: musicAuthStatus) { _, new in syncAuth(new) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            syncAuth(MusicAuthorization.currentStatus)
            refreshTwitchState()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.twitchConnectionStateChanged)) { note in
            if let connected = note.isConnectedFlag {
                viewModel.isTwitchConnected = connected
            }
        }
        .task(id: viewModel.currentStep) {
            if viewModel.currentStep == .playlist, !viewModel.playlistReady {
                await ensurePlaylist()
            }
        }
    }

    // MARK: - Progress Dots

    /// One dot per step (current one enlarged) plus "Step N of M · title".
    /// Read by VoiceOver as a single "Setup progress" element.
    private var progressDots: some View {
        VStack(spacing: DSSpace.s2) {
            HStack(spacing: DSSpace.s2) {
                ForEach(SongRequestSetupViewModel.Step.allCases, id: \.rawValue) { step in
                    Circle()
                        .fill(step == viewModel.currentStep
                            ? Color.accentColor
                            : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .scaleEffect(step == viewModel.currentStep ? 1.3 : 1.0)
                        .animation(DSMotion.Spring.gentle, value: viewModel.currentStep)
                        .accessibilityHidden(true)
                }
            }

            Text("Step \(viewModel.currentStep.rawValue + 1) of \(viewModel.totalSteps) \u{00B7} \(viewModel.currentStep.progressTitle)")
                .font(.system(size: DSFont.Size.xs, weight: .medium))
                .foregroundStyle(.secondary)
                .animation(.none, value: viewModel.currentStep)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setup progress")
        .accessibilityValue("Step \(viewModel.currentStep.rawValue + 1) of \(viewModel.totalSteps): \(viewModel.currentStep.accessibilityTitle)")
    }

    // MARK: - Navigation Bar

    /// Cancel, Back (hidden on the first step), and Next / Skip or the final
    /// "Turn On Song Requests", which calls `viewModel.complete()`.
    private var navigationBar: some View {
        HStack(spacing: DSSpace.s2) {
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .pointerCursor()
                .accessibilityIdentifier("songRequestSetup.cancel")

            Spacer()

            Button("Back") {
                navigationDirection = .leading
                viewModel.goToPreviousStep()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .pointerCursor()
            .opacity(viewModel.isFirstStep ? 0 : 1)
            .disabled(viewModel.isFirstStep)
            .accessibilityHidden(viewModel.isFirstStep)
            .accessibilityIdentifier("songRequestSetup.back")

            if viewModel.isLastStep {
                Button("Turn On Song Requests") {
                    viewModel.complete()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .pointerCursor()
                .accessibilityIdentifier("songRequestSetup.finish")
            } else {
                Button(nextButtonTitle) {
                    navigationDirection = .trailing
                    viewModel.goToNextStep()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .pointerCursor()
                .disabled(!viewModel.canAdvance || (viewModel.currentStep == .shareLink
                    && Preferences.normalizedHTTPSURL(songListDraft) == nil))
                .accessibilityIdentifier("songRequestSetup.next")
            }
        }
        .transaction { $0.animation = nil }
    }

    /// On the optional share step the forward button reads "Skip" until a link
    /// is present, so it's obvious the step can be passed over.
    private var nextButtonTitle: String {
        if viewModel.currentStep == .shareLink {
            return songListDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Skip" : "Next"
        }
        return "Next"
    }

    // MARK: - Shared bits

    /// Apple Music gradient tile used by the access and playlist steps.
    var appleMusicTile: some View {
        BrandTile(
            background: AnyShapeStyle(
                LinearGradient(
                    colors: [AppConstants.Brand.appleMusicGradientStart, AppConstants.Brand.appleMusicGradientEnd],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            ),
            glowColor: AppConstants.Brand.appleMusicGradientEnd,
            glyph: Image(systemName: "music.note")
                .font(BrandTileGlyph.font)
                .foregroundStyle(.white)
        )
    }

    /// One numbered step in the share flow: glyph, instruction, trailing action.
    @ViewBuilder
    func setupStep<Trailing: View>(
        _ number: Int,
        _ text: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: DSSpace.s3) {
            Image(systemName: "\(number).circle.fill")
                .font(.system(size: DSFont.Size.lg))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: DSFont.Size.body))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DSSpace.s2)
            trailing()
        }
    }

    // MARK: - Actions

    /// Seeds the Twitch gate from the live service (notifications keep it
    /// current afterwards).
    private func refreshTwitchState() {
        viewModel.isTwitchConnected = appDelegate?.twitchService?.currentlyConnected ?? false
    }

    /// Records a MusicKit status and updates the step gate.
    private func syncAuth(_ status: MusicAuthorization.Status) {
        musicAuthStatus = status
        viewModel.musicAuthorized = status == .authorized
    }

    /// Shows the MusicKit prompt, then re-reads the status (the prompt's own
    /// return value is ignored in favor of `currentStatus`).
    func requestMusicAuth() {
        isRequestingMusicAuth = true
        Task {
            _ = await MusicAuthorization.request()
            syncAuth(MusicAuthorization.currentStatus)
            isRequestingMusicAuth = false
        }
    }

    /// Ensures the WolfWave Requests playlist exists, flipping `playlistReady`
    /// so the step's Next button unlocks. Surfaces a retry on failure.
    ///
    /// The create call talks to the Apple Music cloud library; playback reads
    /// Music.app's local library. So the local visibility probe runs straight
    /// after, and a `.notVisible` answer warns instead of blocking: Sync Library
    /// can take a moment, and stranding a streamer in the wizard over a state
    /// that clears itself would be worse than letting them finish and showing the
    /// same warning in the pane.
    @MainActor
    func ensurePlaylist() async {
        ensuringPlaylist = true
        playlistError = nil
        defer { ensuringPlaylist = false }
        do {
            _ = try await libraryService.ensureRequestsPlaylist()
            viewModel.playlistReady = true
            await refreshPlaylistLocalVisibility()
        } catch {
            viewModel.playlistReady = false
            playlistError = "Couldn't create the playlist. Check your Apple Music subscription, then try again."
        }
    }

    /// Re-asks Music.app whether it can see the playlist, for the step's "Check
    /// Again" button after the streamer turns Sync Library on.
    @MainActor
    func refreshPlaylistLocalVisibility() async {
        playlistLocalVisibility = await musicController.requestsPlaylistLocalVisibility()
    }

    /// Resolves the playlist's public share link, fills the field, and turns
    /// `!playlist` on. A not-yet-public playlist resolves to a clear "do steps 1
    /// and 2 first" message. Same flow that used to live in the Commands card.
    @MainActor
    func fetchSongListLink() async {
        fetchStatus = nil
        do {
            if let url = try await libraryService.resolveRequestsPlaylistShareURL() {
                songListDraft = url
                songListCommandEnabled = true
                fetchStatus = "Got it. !playlist is on and shares this link."
            } else {
                fetchStatus = "Not public yet. Do steps 1 and 2, then Fetch again."
            }
        } catch {
            fetchStatus = "Couldn't fetch. Make sure you're signed in to Apple Music."
        }
    }

    /// Ensures the playlist exists, then reveals it in Music so the streamer can
    /// Share it (the one manual step macOS can't automate).
    @MainActor
    func openPlaylistInMusic() async {
        _ = try? await libraryService.ensureRequestsPlaylist()
        await musicController.revealRequestsPlaylist()
    }
}

// MARK: - Preview

#Preview("Intro") {
    SongRequestSetupView(startAt: .intro)
}

#Preview("Share link") {
    SongRequestSetupView(startAt: .shareLink)
}
