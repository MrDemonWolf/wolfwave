//
//  SettingsPaneScroll.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-26.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

extension EnvironmentValues {
    /// Top content inset of the enclosing ``SettingsPaneScroll``: how much of
    /// the scroll view sits under the window toolbar. A view that pins itself
    /// while the pane scrolls (the Discord preview) offsets by this so it
    /// stops below the toolbar, not behind it.
    @Entry var settingsPaneTopInset: CGFloat = 0
}

/// The scrolling content column every settings pane sits in: width clamped to
/// `SettingsUI.maxContentWidth`, centered in the pane, with the standard insets.
///
/// The column's position is computed from the **scroll view's own width**, not
/// from the width left over inside it. With legacy (always-visible) scroll bars
/// a pane that overflows loses the scroller's gutter from its content width,
/// while a short pane does not, so centering inside the content shifted a short
/// pane (Software Update) a few points right of every long one. Measuring the
/// outer frame puts the column at the same x on every pane, whatever the
/// scroll-bar style and whether or not the pane scrolls. The right-hand inset
/// absorbs the gutter instead.
///
/// Used by `SettingsView`'s shared pane wrapper, General, and Song Requests.
/// Panes with a jump rail use ``SettingsNavRail`` instead.
struct SettingsPaneScroll<Content: View>: View {

    // MARK: - Properties

    /// The pane's sections, stacked with `SettingsUI.sectionSpacing`.
    @ViewBuilder let content: () -> Content

    /// Width of the scroll view itself, scroller included. Zero until the
    /// first layout pass reports it.
    @State private var paneWidth: CGFloat = 0

    /// How far the scroll view's content is inset at the top (the toolbar it
    /// scrolls under). Published to the pane as `settingsPaneTopInset`.
    @State private var topInset: CGFloat = 0

    // MARK: - Init

    /// Creates a pane column around `content`.
    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppConstants.SettingsUI.sectionSpacing) {
                content()
            }
            .frame(width: columnWidth, alignment: .topLeading)
            .frame(maxWidth: columnWidth == nil ? AppConstants.SettingsUI.maxContentWidth : nil,
                   alignment: .topLeading)
            .padding(.leading, leadingInset)
            .frame(maxWidth: .infinity, alignment: columnWidth == nil ? .center : .leading)
            .padding(.trailing, columnWidth == nil ? AppConstants.SettingsUI.contentPaddingH : 0)
            .padding(.vertical, AppConstants.SettingsUI.contentPaddingV)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            paneWidth = width
        }
        // The inset only changes when the toolbar does, so publishing it does
        // not re-render the pane while it scrolls.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentInsets.top
        } action: { _, inset in
            topInset = inset
        }
        .environment(\.settingsPaneTopInset, topInset)
    }

    // MARK: - Private Helpers

    /// The column width for the measured pane, or `nil` before the first
    /// measurement (the column then centers inside the content as a fallback).
    private var columnWidth: CGFloat? {
        guard paneWidth > 0 else { return nil }
        let available = paneWidth - 2 * AppConstants.SettingsUI.contentPaddingH
        return max(0, min(AppConstants.SettingsUI.maxContentWidth, available))
    }

    /// Leading inset that centers `columnWidth` in the full pane width.
    private var leadingInset: CGFloat {
        guard let columnWidth else { return AppConstants.SettingsUI.contentPaddingH }
        return max(AppConstants.SettingsUI.contentPaddingH, (paneWidth - columnWidth) / 2)
    }
}
