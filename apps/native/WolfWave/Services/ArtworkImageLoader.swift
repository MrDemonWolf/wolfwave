//
//  ArtworkImageLoader.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-26.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import Observation

/// Keeps the displayed bitmap until its replacement finishes loading. URLSession's
/// shared cache handles bytes; each visible tile retains only its current image.
@MainActor
@Observable
final class ArtworkImageLoader {
    private(set) var image: NSImage?
    private(set) var revision = 0
    private var generation = 0
    private let fetchData: @Sendable (URL) async throws -> Data

    init(fetchData: @escaping @Sendable (URL) async throws -> Data = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }) {
        self.fetchData = fetchData
    }

    func load(_ url: URL?) async {
        generation += 1
        let request = generation
        guard let url else {
            image = nil
            revision += 1
            return
        }
        let replacement: NSImage?
        do {
            let data = try await fetchData(url)
            replacement = NSImage(data: data)
        } catch {
            // A cancelled view task must not erase the previous cover.
            guard !Task.isCancelled else { return }
            replacement = nil
        }
        guard request == generation, !Task.isCancelled else { return }
        // A completed miss/error clears old art rather than mislabelling the track.
        image = replacement
        revision += 1
    }
}
