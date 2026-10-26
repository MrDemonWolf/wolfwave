//
//  QRCodeImage.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-29.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - QRCodeImage

/// Renders a string (typically a URL) as a crisp QR code.
///
/// CoreImage emits a tiny matrix; we scale it up with nearest-neighbor
/// interpolation (`.interpolation(.none)`) so the modules stay sharp at any
/// frame size, including when captured by `ImageRenderer` for share exports.
struct QRCodeImage: View {

    /// The payload encoded into the QR (e.g. a docs URL).
    let string: String

    /// Rendered edge length of the (square) code.
    let size: CGFloat

    // Hidden from VoiceOver in both branches: the code is decorative, so any
    // spoken equivalent of the payload has to come from the caller's layout.
    var body: some View {
        if let cgImage = Self.qrCode(for: string) {
            Image(decorative: cgImage, scale: 1, orientation: .up)
                .interpolation(.none)
                .resizable()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            // Degrade gracefully: keep the footer layout stable if encoding fails.
            Color.clear
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Encoding

    /// One rendering context for every code. A `CIContext` is expensive to
    /// create and safe to reuse.
    private static let context = CIContext()

    /// Rendered codes keyed by payload, so a body re-evaluation (or several
    /// views showing the same URL) does not re-run the filter chain.
    /// `NSCache` evicts under memory pressure on its own.
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 16
        return cache
    }()

    /// The cached code for `string`, encoding it on first use.
    private static func qrCode(for string: String) -> CGImage? {
        let key = string as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = makeQRCode(from: string) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Builds a white-modules-on-transparent `CGImage` for the payload so it
    /// reads on dark gradients without a background plate. Returns `nil` when
    /// the string can't be encoded.
    ///
    /// Uses error-correction level "M" (about 15% of modules recoverable), a
    /// middle ground between density and tolerance for a URL-sized payload.
    private static func makeQRCode(from string: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }

        // CoreImage emits black modules on white. Invert so modules are white
        // and the background black, then map luminance to alpha: white modules
        // become opaque, the black background becomes transparent.
        let baked = output
            .applyingFilter("CIColorInvert")
            .applyingFilter("CIMaskToAlpha")

        return context.createCGImage(baked, from: baked.extent)
    }
}

// MARK: - Preview

#Preview {
    QRCodeImage(string: "https://wolfwave.mrdemonwolf.dev", size: 120)
        .padding()
        .background(Color.black)
}
