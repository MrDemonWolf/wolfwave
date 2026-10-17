//
//  NowPlayingHeroCard.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-07.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Hero "Now Playing" card with 92pt album art, title/artist/album, and a
/// scrubber. Rendered by `MusicMonitorSettingsView` at the top of the General
/// pane.
///
/// When `track` is nil this renders an empty-state card whose headline names
/// the cause (tracking off, Music closed, or nothing loaded); see
/// `emptyStateTitle(trackingEnabled:musicNotRunning:)`.
struct NowPlayingHeroCard: View {

    // MARK: - Properties

    /// Track title. `nil` switches the card to its empty state.
    let track: String?
    /// Artist credit; joined with `album` into the subtitle.
    let artist: String?
    /// Album name; joined with `artist` into the subtitle.
    let album: String?
    /// Already-loaded artwork. Takes precedence over `artworkURL` in
    /// `AlbumArtView`.
    var artwork: NSImage?
    /// Remote artwork to fetch when no `artwork` image is supplied.
    var artworkURL: URL?
    /// Playback position, in seconds.
    var elapsed: TimeInterval = 0
    /// Track length, in seconds. `0` (unknown) hides the scrubber.
    var duration: TimeInterval = 0
    /// Whether the "Sync Music" setting is on. Off changes the empty-state copy
    /// and hides the Open Music button.
    var trackingEnabled: Bool = true
    /// Renders the paused affordance: dimmed artwork, pause glyph overlay,
    /// frozen scrubber. The track text and subtitle remain at full opacity
    /// so the loaded song is still readable.
    var isPaused: Bool = false

    /// Music.app has no running process.
    ///
    /// Distinct from "nothing playing": with Music closed there is nothing for the
    /// user to do *in Music*, so the card says so plainly and offers to open it.
    /// Collapsing the two states left people staring at "Nothing playing right now"
    /// with no idea the app they needed was shut.
    var musicNotRunning: Bool = false

    /// Invoked by the Open Music button. Omit to hide the button.
    var onOpenMusic: (() -> Void)?

    // MARK: - Body

    var body: some View {
        HStack(alignment: .center, spacing: DSSpace.s6) {
            // The card label already says "Paused" / "Now playing", so the
            // artwork adds nothing for VoiceOver.
            artworkView
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DSSpace.s1) {
                // Information only: one combined VoiceOver element. The Open
                // Music button stays outside it so it remains its own control.
                VStack(alignment: .leading, spacing: DSSpace.s1) {
                    HStack(spacing: DSSpace.s2) {
                        Text(isPaused && track != nil ? "Paused" : "Now playing")
                            .sectionEyebrow()
                            .contentTransition(.opacity)
                            .id(isPaused)
                    }

                    Text(track ?? emptyStateTitle)
                        .font(.system(size: DSFont.Size.lg, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(track == nil ? .secondary : .primary)
                        .contentTransition(.opacity)
                        .id(track ?? emptyStateTitle)

                    if let subtitle = subtitleText {
                        Text(subtitle)
                            .font(.system(size: DSFont.Size.base))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                            .id(subtitle)
                    }

                    if track != nil, duration > 0 {
                        progressBar
                            .padding(.top, DSSpace.s2)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)

                if track == nil, showsOpenMusic, let onOpenMusic {
                    Button("Open Music", action: onOpenMusic)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, DSSpace.s2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DSSpace.s7)
        .cardStyleUnpadded()
        .motionSafe(.easeInOut(duration: DSMotion.Duration.base), value: track)
        // Card-level so the pause glyph's insertion/removal, the artwork dim and
        // the eyebrow swap animate even when a caller flips `isPaused` without
        // `withAnimation`.
        .motionSafe(.easeInOut(duration: DSMotion.Duration.base), value: isPaused)
    }

    // MARK: - Subviews

    /// Album art (dimmed and desaturated, with a pause glyph, while paused), or
    /// a music-note placeholder tile of the same size when there is no track.
    @ViewBuilder
    private var artworkView: some View {
        if track != nil {
            ZStack {
                AlbumArtView(image: artwork, url: artworkURL, size: 92)
                    .opacity(isPaused ? 0.55 : 1)
                    .saturation(isPaused ? 0.6 : 1)

                if isPaused {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: DSFont.Size.x3xl, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                        .transition(.opacity.combined(with: .scale))
                }
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
                    .fill(.quaternary.opacity(0.6))
                Image(systemName: "music.note")
                    .font(.system(size: DSFont.Size.x3xl, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 92, height: 92)
        }
    }

    /// Read-only scrubber plus an elapsed / total clock. The fraction is
    /// clamped to the unit range so a stale `elapsed` past `duration` cannot
    /// overflow the bar.
    @ViewBuilder
    private var progressBar: some View {
        HStack(spacing: DSSpace.s3) {
            let fraction = duration > 0 ? min(max(elapsed / duration, 0), 1) : 0
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(.primary)
                .frame(height: 3)

            Text("\(HistoryFormat.clock(elapsed)) / \(HistoryFormat.clock(duration))")
                .font(.system(size: DSFont.Size.sm, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }

    // MARK: - Helpers

    /// Headline for the no-track state.
    ///
    /// Three distinct causes, three distinct messages: tracking is switched off,
    /// Music is closed, or Music is open with nothing loaded. Each one implies a
    /// different next step for the user. Pure and `static` so the copy rules are
    /// unit-testable without rendering the view.
    static func emptyStateTitle(trackingEnabled: Bool, musicNotRunning: Bool) -> String {
        guard trackingEnabled else { return "Sync Music is off" }
        return musicNotRunning ? "Apple Music isn't open" : "Nothing playing right now"
    }

    /// Only offer to launch Music when it is actually closed and tracking is on.
    /// Offering it while tracking is off would launch Music to no effect.
    static func showsOpenMusic(trackingEnabled: Bool, musicNotRunning: Bool) -> Bool {
        trackingEnabled && musicNotRunning
    }

    /// Instance shorthand for the static rule above.
    private var emptyStateTitle: String {
        Self.emptyStateTitle(trackingEnabled: trackingEnabled, musicNotRunning: musicNotRunning)
    }

    /// Instance shorthand for the static rule above.
    private var showsOpenMusic: Bool {
        Self.showsOpenMusic(trackingEnabled: trackingEnabled, musicNotRunning: musicNotRunning)
    }

    /// Second line: "artist · album" (or whichever exists) for a track; in the
    /// empty state, a hint only when Music is closed.
    private var subtitleText: String? {
        if track == nil {
            return showsOpenMusic ? "Open it and WolfWave picks up what you play." : nil
        }
        switch (artist, album) {
        case let (a?, b?): return "\(a) · \(b)"
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    /// One spoken sentence for the combined text element: state, title,
    /// artist, album, then elapsed and remaining time when the length is known.
    private var accessibilityLabel: String {
        guard let track else { return emptyStateTitle }
        var label = isPaused ? "Paused: \(track)" : "Now playing: \(track)"
        if let artist { label += ", by \(artist)" }
        if let album { label += ", on \(album)" }
        if duration > 0 {
            let remaining = max(duration - elapsed, 0)
            label += ", \(HistoryFormat.clock(elapsed)) elapsed, \(HistoryFormat.clock(remaining)) remaining"
        }
        return label
    }
}

#Preview("Playing") {
    NowPlayingHeroCard(
        track: "Moonlit Howl",
        artist: "Arctic Wolf",
        album: "Tundra Sessions",
        elapsed: 72,
        duration: 218
    )
    .padding()
    .frame(width: 720)
    .background(Color(nsColor: .underPageBackgroundColor))
}

#Preview("Paused") {
    NowPlayingHeroCard(
        track: "Moonlit Howl",
        artist: "Arctic Wolf",
        album: "Tundra Sessions",
        elapsed: 72,
        duration: 218,
        isPaused: true
    )
    .padding()
    .frame(width: 720)
    .background(Color(nsColor: .underPageBackgroundColor))
}

#Preview("Empty") {
    NowPlayingHeroCard(track: nil, artist: nil, album: nil)
        .padding()
        .frame(width: 720)
}
