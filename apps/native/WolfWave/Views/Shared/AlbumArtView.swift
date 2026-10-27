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
/// shows. While a replacement loads, the previous cover stays visible; a resolved
/// failure uses the placeholder.
struct AlbumArtView: View {

    // MARK: - Properties

    /// Artwork already in memory. Takes precedence over `url`.
    var image: NSImage?
    /// Remote artwork, crossfaded after loading unless Reduce Motion is on.
    var url: URL?
    /// Edge length of the square tile, in points.
    var size: CGFloat = 64
    /// Corner radius override. `nil` scales the radius with `size`, with a small
    /// floor so tiny thumbnails stay rounded.
    var cornerRadius: CGFloat?

    @State private var loader = ArtworkImageLoader()

    /// Disables artwork crossfades.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Body

    var body: some View {
        let radius = cornerRadius ?? max(4, size * 0.10)
        ZStack {
            if let displayed = image ?? loader.image {
                Image(nsImage: displayed)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .id(image == nil ? loader.revision : 0)
                    .transition(.opacity)
            } else {
                placeholder.transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.base), value: loader.revision)
        .transaction { if reduceMotion { $0.animation = nil } }
        .task(id: image == nil ? url : nil) { await loader.load(image == nil ? url : nil) }
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
