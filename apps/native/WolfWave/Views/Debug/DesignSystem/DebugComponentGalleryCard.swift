//
//  DebugComponentGalleryCard.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-08-22.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

#if DEBUG
import SwiftUI

/// DEBUG-only gallery that renders every view in `Views/Shared/` live.
///
/// Each entry mirrors the states its own `#Preview` blocks declare (same
/// strings, same variants) so the gallery and the canvas previews share one
/// state vocabulary. Documented-but-unpreviewed states are added where the
/// component's API names them (`StatusChip.StateGlyph.paused`, for example).
///
/// Groups live in one `extension` file each (`ComponentGallery+Buttons.swift`,
/// …) so no single file carries every component. Bindings come from `@State`
/// on this card, the same `Wrapper` pattern the binding previews use.
///
/// When a view is added to `Views/Shared/`, add a `GalleryEntry` for it to the
/// matching group extension; nothing enforces that automatically.
struct DebugComponentGalleryCard: View {

    // MARK: Binding hosts (Rows & fields)

    // These are `internal` rather than `private` because the group extensions
    // live in other files and bind to them (`$aliases`, `$songOn`, ...).

    @State var aliases = "np, track"
    @State var songOn = true
    @State var lastOn = false
    @State var infoOn = true
    @State var songGlobal: Double = 15
    @State var songUser: Double = 15
    @State var songAliases = "np, track"
    @State var replyStyle = "credit"
    @State var everyone: Double = 15
    @State var perUser: Double = 30
    /// Deliberately outside the picker's tag set, to show `snapped(to:fallback:)` recovering.
    @State var unsnappedWindow = 99

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s6) {
            Text("""
                Every view in Views/Shared/, in the states its #Preview blocks declare. \
                Buttons are live: copy writes the pasteboard, Open launches the browser.
                """)
                .font(.system(size: DSFont.Size.body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            group("Buttons") { buttonsSection }
            Divider()
            group("Rows & fields") { rowsSection }
            Divider()
            group("Banners & callouts") { bannersSection }
            Divider()
            group("Status & headers") { statusSection }
            Divider()
            group("Cards & media") { cardsSection }
            Divider()
            group("Chrome") { chromeSection }
        }
        .cardStyle()
    }

    /// Wraps one component group under a section eyebrow marked as a VoiceOver
    /// header, so the rotor can jump between groups.
    ///
    /// - Parameters:
    ///   - title: The visible group name.
    ///   - content: The group's `GalleryEntry` rows.
    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.s5) {
            Text(title)
                .sectionEyebrow()
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

// MARK: - Entry

/// One gallery entry: the type name in monospace, an optional note, and the demo
/// capped at a house preview width (it shrinks with the window, never overflows).
struct GalleryEntry<Content: View>: View {

    /// The component's Swift type name, shown verbatim so it can be searched for.
    let typeName: String
    /// Maximum width of the demo. Defaults to the standard preview width.
    var width: CGFloat = GalleryWidth.standard
    /// Optional caption beside the type name (for example why actions are inert).
    var note: String?
    /// The live component sample(s).
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s2) {
            HStack(alignment: .firstTextBaseline, spacing: DSSpace.s2) {
                Text(typeName)
                    .font(.system(size: DSFont.Size.sm, weight: .semibold, design: .monospaced))
                if let note {
                    Text(note)
                        .captionText()
                }
            }
            content()
                .frame(maxWidth: width, alignment: .leading)
        }
    }
}

/// The house `#Preview` widths (320 / 360 / 500) plus "fill the card". Gallery
/// layout only, not design tokens: they size the samples, not the product.
enum GalleryWidth {
    static let narrow: CGFloat = 320
    static let standard: CGFloat = 360
    static let wide: CGFloat = 500
    static let full: CGFloat = .infinity
}

#Preview {
    DebugComponentGalleryCard()
        .padding()
        .frame(width: 600)
}
#endif
