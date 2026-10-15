//
//  AlbumArtView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-07.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Sized album-art tile. Falls back to the WolfWave-branded placeholder (the
/// wolf mark on a brand-blue gradient) when no artwork is supplied.
///
/// Used by the now-playing hero in the Music Monitor pane (`NowPlayingHeroCard`),
/// and intended for any other album thumbnail the design adds.
///
/// Source precedence: `image` wins over `url`; with neither, the placeholder
/// shows. A URL load that is still pending or failed also shows the placeholder,
/// so a broken link never leaves an empty box.
struct AlbumArtView: View {

    // MARK: - Properties

    /// Artwork already in memory. Takes precedence over `url`.
    var image: NSImage? = nil
    /// Remote artwork, loaded with `AsyncImage` (fades in unless Reduce Motion is on).
    var url: URL? = nil
    /// Edge length of the square tile, in points.
    var size: CGFloat = 64
    /// Corner radius override. `nil` scales the radius with `size`, with a small
    /// floor so tiny thumbnails stay rounded.
    var cornerRadius: CGFloat? = nil

    /// Disables the `AsyncImage` fade-in transaction.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Body

    var body: some View {
        let radius = cornerRadius ?? max(4, size * 0.10)
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if let url {
                AsyncImage(url: url, transaction: Transaction(animation: reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.base))) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                    case .empty, .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
        // Decorative. The track/artist text alongside the artwork carries
        // the semantic content. Hiding here keeps VoiceOver from announcing
        // "image" before the song title.
        .accessibilityHidden(true)
    }

    /// Branded fallback: the wolf mark over a brand-blue diagonal gradient, the
    /// mark scaled to about half the tile.
    @ViewBuilder
    private var placeholder: some View {
        LinearGradient(
            colors: [DSColor.brand500, DSColor.brand800],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .center) {
            Image("WolfMark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size * 0.52, height: size * 0.52)
                .foregroundStyle(.white)
        }
    }

}

#Preview("Branded fallback") {
    HStack(spacing: DSSpace.s4) {
        AlbumArtView(size: 92)
        AlbumArtView(size: 64)
        AlbumArtView(size: 36)
    }
    .padding()
}
