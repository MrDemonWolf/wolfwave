//
//  SettingsPaneScroll.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-26.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

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
