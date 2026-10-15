//
//  MotionGallerySection.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

#if DEBUG
import SwiftUI

/// Visual gallery for the polished SwiftUI transitions added in the
/// Apple/SwiftUI modernization pass. Designers can verify `contentTransition`,
/// `symbolEffect`, input-driven progress, and the `AsyncImage` phased loading without
/// triggering real Twitch/Discord state.
///
/// To validate Reduce Motion: flip System Settings → Accessibility → Reduce
/// Motion. The "Reduce Motion" chip at the top mirrors the system value, and
/// every demo here respects it.
///
/// Rendered by `DebugTokenGalleryCard` under its Motion section, after the
/// duration and spring token demos.
struct MotionGallerySection: View {

    // MARK: Properties

    /// System Reduce Motion setting; pauses the chip auto-cycle and drives the mirror chip.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Current state of the auto-cycling `StatusChip` demo.
    @State private var chipState: ChipDemoState = .off
    /// Whether the chip demo is on screen. The cycle loop only runs while it is.
    @State private var chipCycleVisible = false
    /// Index into `demoTracks`; wraps with modulo, so it can grow without bound.
    @State private var trackIndex: Int = 0
    /// Simulated playback position for the hero card scrubber, in seconds.
    @State private var elapsed: TimeInterval = 0
    /// Remote image for the phased-load demo. `let`, never mutated.
    ///
    /// A neutral placeholder image (not real album art), so the `AsyncImage`
    /// phased load is exercisable without shipping a third-party music artwork URL.
    ///
    /// Offline this silently falls back to the branded placeholder, which makes
    /// the phased-load demo indistinguishable from the fallback demo. That is a
    /// known limit of using a network image here, not a bug in AlbumArtView.
    private let artURL: URL? = URL(string: "https://picsum.photos/seed/wolfwave/512")
    /// Load counter for the remote image. `0` means "never loaded" (no request
    /// fires); each press bumps it and changes the URL's `v` query, defeating the
    /// `URLCache` so the phased load runs again.
    @State private var cacheBuster: Int = 0

    // MARK: Demo data

    /// The four states the chip demo cycles through, in order.
    private enum ChipDemoState: CaseIterable {
        case off, connecting, live, error

        /// Chip label for this state.
        var text: String {
            switch self {
            case .off:        return "Off"
            case .connecting: return "Connecting…"
            case .live:       return "Live"
            case .error:      return "Error"
            }
        }

        /// Semantic status token for this state (never a raw system color).
        var color: Color {
            switch self {
            case .off:        return DSColor.neutral
            case .connecting: return DSColor.warning
            case .live:       return DSColor.success
            case .error:      return DSColor.error
            }
        }

        /// The following state, wrapping from `.error` back to `.off`.
        func next() -> ChipDemoState {
            let all = ChipDemoState.allCases
            let i = all.firstIndex(of: self) ?? 0
            return all[(i + 1) % all.count]
        }
    }

    /// Invented track metadata for the hero card demo. `duration` is in seconds.
    private struct DemoTrack {
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval
    }

    // Invented demo tracks: made-up titles/albums with real wolf species as the
    // "artist". Mirrors the marketing house style in
    // `apps/docs/app/(home)/_widgets/sample-tracks.ts` so no real recording
    // artist, song, or album ever ships in a preview.
    private static let demoTracks: [DemoTrack] = [
        DemoTrack(title: "Moonlit Howl", artist: "Arctic Wolf", album: "Tundra Sessions", duration: 218),
        DemoTrack(title: "Lone Runner", artist: "Timber Wolf", album: "Northern Pines", duration: 247),
        DemoTrack(title: "Silver Pelt", artist: "Gray Wolf", album: "Den of Echoes", duration: 191),
        DemoTrack(title: "Pack Mentality", artist: "Maned Wolf", album: "Wild Frontier", duration: 263)
    ]

    /// The track at `trackIndex`, wrapping around the list.
    private var currentTrack: DemoTrack {
        Self.demoTracks[trackIndex % Self.demoTracks.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s5) {
            reduceMotionMirror
            Divider()
            chipCycleDemo
            Divider()
            trackSwapDemo
            Divider()
            albumArtPhasedDemo
        }
    }

    // MARK: Reduce-motion mirror

    /// Shows the live Reduce Motion value, so a tester can confirm the toggle took.
    private var reduceMotionMirror: some View {
        HStack(spacing: DSSpace.s2) {
            Text("System setting:")
                .font(.system(size: DSFont.Size.sm))
                .foregroundStyle(.secondary)
            StatusChip(
                text: reduceMotion ? "Reduce Motion: On" : "Reduce Motion: Off",
                color: reduceMotion ? DSColor.warning : DSColor.success
            )
            Spacer()
        }
    }

    // MARK: Chip cycle

    /// `StatusChip` stepping through its states, exercising its text and color
    /// transitions. Auto-advances on a timer when allowed; Advance steps by hand.
    private var chipCycleDemo: some View {
        VStack(alignment: .leading, spacing: DSSpace.s2) {
            Text(reduceMotion ? "StatusChip: auto-cycle paused (Reduce Motion)" : "StatusChip: auto-cycles every 1.2s")
                .font(.system(size: DSFont.Size.sm, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: DSSpace.s4) {
                StatusChip(text: chipState.text, color: chipState.color)
                Button("Advance") {
                    chipState = chipState.next()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            // Pause offscreen or under Reduce Motion; manual Advance always works.
            // The task id flips whenever either condition changes, which cancels
            // the running loop and restarts (or skips) it.
            .task(id: reduceMotion || !chipCycleVisible) {
                guard !reduceMotion, chipCycleVisible else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(1200))
                    guard !Task.isCancelled else { return }
                    chipState = chipState.next()
                }
            }
        }
        .onScrollVisibilityChange(threshold: 0.01) { chipCycleVisible = $0 }
    }

    // MARK: Track swap

    /// `NowPlayingHeroCard` driven by buttons: Next track swaps the title (its
    /// `contentTransition`), and the skip buttons move `elapsed`, clamped to
    /// the track's length, to show the input-driven scrubber.
    private var trackSwapDemo: some View {
        VStack(alignment: .leading, spacing: DSSpace.s2) {
            Text("NowPlayingHeroCard: title contentTransition + input-driven scrubber")
                .font(.system(size: DSFont.Size.sm, weight: .semibold))
                .foregroundStyle(.secondary)

            NowPlayingHeroCard(
                track: currentTrack.title,
                artist: currentTrack.artist,
                album: currentTrack.album,
                elapsed: elapsed,
                duration: currentTrack.duration
            )

            HStack(spacing: DSSpace.s2) {
                Button("Next track") {
                    trackIndex += 1
                    elapsed = 0
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("+5s") {
                    elapsed = min(elapsed + 5, currentTrack.duration)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("-5s") {
                    elapsed = max(elapsed - 5, 0)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }
        }
    }

    // MARK: AlbumArt phased load

    /// `AlbumArtView` side by side: the branded fallback, and a URL-backed
    /// instance that only starts loading once the button is pressed.
    private var albumArtPhasedDemo: some View {
        VStack(alignment: .leading, spacing: DSSpace.s2) {
            Text("AlbumArtView: direct image vs URL phased load")
                .font(.system(size: DSFont.Size.sm, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: DSSpace.s5) {
                VStack(spacing: DSSpace.s1) {
                    AlbumArtView(size: 92)
                    Text("Branded fallback")
                        .font(.system(size: DSFont.Size.xs))
                        .foregroundStyle(.tertiary)
                }

                VStack(spacing: DSSpace.s1) {
                    // Opt-in: the Debug tab mounts this section on open, and a
                    // third-party request should not fire until someone asks.
                    AlbumArtView(url: cacheBuster > 0 ? bustedURL : nil, size: 92)
                    Text(cacheBuster > 0 ? "AsyncImage(url:)" : "AsyncImage(url:) · not loaded")
                        .font(.system(size: DSFont.Size.xs))
                        .foregroundStyle(.tertiary)
                }

                VStack(spacing: DSSpace.s2) {
                    Button(cacheBuster > 0 ? "Bust cache & reload" : "Load remote image") {
                        cacheBuster += 1
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Text("Fetches a placeholder from picsum.photos; each press changes the URL query.")
                        .font(.system(size: DSFont.Size.xs))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
        }
    }

    /// `artURL` with its query replaced by `v=<cacheBuster>`. Falls back to the
    /// plain URL if it cannot be decomposed.
    private var bustedURL: URL? {
        guard let base = artURL,
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return artURL }
        comps.queryItems = [URLQueryItem(name: "v", value: String(cacheBuster))]
        return comps.url
    }
}

#Preview {
    MotionGallerySection()
        .padding()
        .frame(width: 600)
}
#endif
