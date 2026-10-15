//
//  SharePickerButton.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-06-01.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI
import AppKit

// MARK: - SharePickerButton

/// AppKit-backed button that presents the macOS share sheet
/// (`NSSharingServicePicker`: Messages, Mail, AirDrop, Notes, etc.).
///
/// `NSSharingServicePicker.show(relativeTo:of:preferredEdge:)` must anchor to a
/// real `NSView`, which a SwiftUI `Button` can't hand back, so this wraps an
/// `NSButton` and anchors the picker to it.
struct SharePickerButton: NSViewRepresentable {

    // MARK: - Properties

    /// Visible button title. Defaults to "Share".
    var title: String = "Share"

    /// SF Symbol shown leading the title.
    var systemImage: String = "square.and.arrow.up"

    /// When `true`, fills the button with the accent color and white label.
    /// Matches SwiftUI's `.borderedProminent` so it can sit beside one.
    var isProminent: Bool = false

    /// Called after cancellation, successful sharing, or a sharing failure, with
    /// the items that were offered. Use it for cleanup such as deleting a temp
    /// file written by `makeItems`; it does not say which outcome happened.
    var onCompletion: (([Any]) -> Void)?

    /// Produces the items to share when the button is clicked. Runs on the main
    /// thread. Return `nil` (or an empty array) to suppress the picker. e.g.
    /// when a render step failed and there's nothing to share.
    let makeItems: () -> [Any]?

    // MARK: - NSViewRepresentable

    /// Builds the `NSButton` and wires its action to the coordinator.
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .rounded
        button.imagePosition = .imageLeading
        button.target = context.coordinator
        button.action = #selector(Coordinator.share(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        applyStyle(to: button)
        return button
    }

    /// Re-applies the style and hands the coordinator the latest closures, so a
    /// click always uses the current `makeItems` rather than the first one.
    func updateNSView(_ nsView: NSButton, context: Context) {
        applyStyle(to: nsView)
        context.coordinator.makeItems = makeItems
        context.coordinator.onCompletion = onCompletion
    }

    /// Applies title, icon, and prominent fill so make/update stay in sync.
    ///
    /// The icon color is baked into the symbol image via `SymbolConfiguration`
    /// rather than `contentTintColor`: a rounded bezel button with an explicit
    /// `bezelColor` ignores `contentTintColor` for its image, which left the
    /// prominent share glyph rendering in the default `labelColor` (dark on the
    /// accent fill, and flipping per light/dark appearance) while the title was
    /// forced white. Baking the color keeps glyph and label in sync.
    private func applyStyle(to button: NSButton) {
        let symbol = NSImage(systemSymbolName: systemImage,
                             accessibilityDescription: title)

        if isProminent {
            // Bake white into the glyph; the accent fill is colored in both
            // appearances, so white reads correctly without flipping.
            button.image = symbol?.withSymbolConfiguration(.init(paletteColors: [.white]))
            button.bezelColor = .controlAccentColor
            button.contentTintColor = .white
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: NSColor.white])
        } else {
            // Plain template image tints with the button's label color and
            // adapts to light/dark on its own.
            button.image = symbol
            button.bezelColor = nil
            button.contentTintColor = nil
            button.title = title
        }
    }

    /// Creates the coordinator that owns the picker and its delegate callbacks.
    func makeCoordinator() -> Coordinator {
        Coordinator(makeItems: makeItems, onCompletion: onCompletion)
    }

    // MARK: - Coordinator

    /// Button target plus picker and service delegate.
    ///
    /// One share runs at a time: `sharingLifetime` is set when a share starts and
    /// cleared by `finishSharing()`, and a click while it is set is ignored. The
    /// self-reference also keeps the coordinator alive if SwiftUI tears the
    /// button down mid-share, so `onCompletion` still fires.
    final class Coordinator: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        /// Latest item factory, refreshed by `updateNSView`.
        var makeItems: () -> [Any]?
        /// Latest completion handler, refreshed by `updateNSView`.
        var onCompletion: (([Any]) -> Void)?
        /// The pending completion for the current share, bound to its items.
        /// Called once, then cleared.
        private var completion: (() -> Void)?
        /// Strong reference to the visible picker for the duration of a share.
        private var picker: NSSharingServicePicker?
        // Keep the delegate alive if the SwiftUI sheet closes during sharing.
        private var sharingLifetime: Coordinator?

        /// - Parameters:
        ///   - makeItems: Produces the items to share at click time.
        ///   - onCompletion: Called once a share ends, however it ends.
        init(makeItems: @escaping () -> [Any]?, onCompletion: (([Any]) -> Void)? = nil) {
            self.makeItems = makeItems
            self.onCompletion = onCompletion
        }

        /// Button action: builds the items and shows the picker under the button.
        /// Does nothing while a share is in flight or when there is nothing to share.
        @objc func share(_ sender: NSButton) {
            guard sharingLifetime == nil else { return }
            guard let items = makeItems(), !items.isEmpty else { return }
            prepareSharing(items)
            let picker = NSSharingServicePicker(items: items)
            self.picker = picker
            picker.delegate = self
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }

        /// Captures the completion for `items` (using the handler current at
        /// click time) and pins the coordinator alive until the share ends.
        func prepareSharing(_ items: [Any]) {
            let callback = onCompletion
            completion = { callback?(items) }
            sharingLifetime = self
        }

        /// A `nil` service means the picker was dismissed without a choice, which
        /// ends the share. A chosen service ends it later, through the
        /// `NSSharingServiceDelegate` callbacks below.
        func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            if service == nil { finishSharing() }
        }

        func sharingServicePicker(
            _ picker: NSSharingServicePicker, delegateFor service: NSSharingService
        ) -> (any NSSharingServiceDelegate)? {
            // Become the service's delegate so success and failure reach us.
            self
        }

        /// The chosen service finished sharing.
        func sharingService(_ service: NSSharingService, didShareItems items: [Any]) {
            finishSharing()
        }

        /// The chosen service failed or was cancelled; still ends the share.
        func sharingService(_ service: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
            finishSharing()
        }

        /// Clears the in-flight state, then fires the completion. State is reset
        /// first so the completion may start another share.
        private func finishSharing() {
            let callback = completion
            completion = nil
            picker = nil
            sharingLifetime = nil
            callback?()
        }
    }
}
