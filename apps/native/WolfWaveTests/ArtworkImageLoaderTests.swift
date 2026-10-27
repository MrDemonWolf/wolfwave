//
//  ArtworkImageLoaderTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-26.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import XCTest
@testable import WolfWave

@MainActor
final class ArtworkImageLoaderTests: XCTestCase {
    private let first = URL(fileURLWithPath: "/first.png")
    private let second = URL(fileURLWithPath: "/second.png")

    private func imageData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testRetainsCoverUntilDelayedReplacementCompletes() async throws {
        let gate = ArtworkImageResponseGate()
        let loader = ArtworkImageLoader { try await gate.fetch($0) }
        let data = try imageData()
        let initial = Task { await loader.load(first) }
        await gate.waitForRequest(first)
        await gate.finish(first, data: data)
        await initial.value
        let previous = try XCTUnwrap(loader.image)
        let revision = loader.revision

        let next = Task { await loader.load(second) }
        await gate.waitForRequest(second)
        XCTAssertTrue(loader.image === previous, "Pending replacement must not flash the placeholder")
        XCTAssertEqual(loader.revision, revision)
        await gate.finish(second, data: data)
        await next.value
        XCTAssertNotNil(loader.image)
        XCTAssertFalse(loader.image === previous)
        XCTAssertEqual(loader.revision, revision + 1)
    }

    func testLateResponseCannotReplaceNewerCover() async throws {
        let gate = ArtworkImageResponseGate()
        let loader = ArtworkImageLoader { try await gate.fetch($0) }
        let old = Task { await loader.load(first) }
        await gate.waitForRequest(first)
        let next = Task { await loader.load(second) }
        await gate.waitForRequest(second)
        await gate.finish(second, data: try imageData())
        await next.value
        let current = try XCTUnwrap(loader.image)
        let revision = loader.revision
        await gate.finish(first, data: try imageData())
        await old.value
        XCTAssertTrue(loader.image === current)
        XCTAssertEqual(loader.revision, revision)
    }

    func testResolvedNoArtworkClearsCoverAndInvalidatesPendingResponse() async throws {
        let gate = ArtworkImageResponseGate()
        let loader = ArtworkImageLoader { try await gate.fetch($0) }
        let initial = Task { await loader.load(first) }
        await gate.waitForRequest(first)
        await gate.finish(first, data: try imageData())
        await initial.value
        XCTAssertNotNil(loader.image)
        let next = Task { await loader.load(second) }
        await gate.waitForRequest(second)
        await loader.load(nil)
        XCTAssertNil(loader.image)
        let revision = loader.revision
        await gate.finish(second, data: try imageData())
        await next.value
        XCTAssertNil(loader.image)
        XCTAssertEqual(loader.revision, revision)
    }

    func testFailedReplacementClearsOldCover() async throws {
        let data = try imageData()
        let loader = ArtworkImageLoader { url in
            if url.lastPathComponent == "first.png" { return data }
            throw URLError(.cannotConnectToHost)
        }
        await loader.load(first)
        XCTAssertNotNil(loader.image)
        await loader.load(second)
        XCTAssertNil(loader.image)
    }

    func testCancelledResponseDoesNotEraseDisplayedCover() async throws {
        let gate = ArtworkImageResponseGate()
        let loader = ArtworkImageLoader { try await gate.fetch($0) }
        let initial = Task { await loader.load(first) }
        await gate.waitForRequest(first)
        await gate.finish(first, data: try imageData())
        await initial.value
        let previous = try XCTUnwrap(loader.image)
        let next = Task { await loader.load(second) }
        await gate.waitForRequest(second)
        next.cancel()
        await gate.finish(second, data: Data())
        await next.value
        XCTAssertTrue(loader.image === previous)
    }
}

/// Explicit gates keep ordering deterministic without network calls or sleeps.
private actor ArtworkImageResponseGate {
    private var responses: [URL: CheckedContinuation<Data, Error>] = [:]
    private var observers: [URL: CheckedContinuation<Void, Never>] = [:]

    func fetch(_ url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            responses[url] = continuation
            observers.removeValue(forKey: url)?.resume()
        }
    }

    func waitForRequest(_ url: URL) async {
        if responses[url] != nil { return }
        await withCheckedContinuation { observers[url] = $0 }
    }

    func finish(_ url: URL, data: Data) {
        responses.removeValue(forKey: url)?.resume(returning: data)
    }
}
