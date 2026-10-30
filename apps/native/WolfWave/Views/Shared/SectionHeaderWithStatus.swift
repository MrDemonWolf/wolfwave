//
//  SectionHeaderWithStatus.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-04-04.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// A reusable section header with title, subtitle, and an optional status chip.
///
/// Used across settings views (Discord, Twitch, WebSocket) for a consistent
/// top-level section layout. When no status is provided, the chip is omitted
/// and the header renders as a simple title + subtitle pair.
///
/// Usage:
/// ```swift
/// SectionHeaderWithStatus(
///     title: "Discord Status",
///     subtitle: "Show your music on your Discord profile.",
///     statusText: "Connected",
///     statusColor: DSColor.success
/// )
/// ```
struct SectionHeaderWithStatus: View {

    // MARK: - Prominence

    /// Which heading level this header renders at.
    ///
    /// `.pane` is a standalone content title (22pt via `.paneTitle()`) for a view
    /// with no window toolbar above it, such as a sheet. Settings panes do not use
    /// it: the window toolbar already names the selected pane.
    /// `.section` is an H2 for a section inside a pane (17pt via
    /// `.sectionHeader()`), which is what every Settings call site passes.
    enum Prominence {
        /// Standalone title (22pt). Not for a Settings pane.
        case pane
        /// Section heading inside a pane (H2).
        case section
    }

    // MARK: - Properties

    /// Heading text.
    let title: String
    /// One-line description under the heading.
    let subtitle: String
    /// Heading level. Defaults to `.pane`, so a Settings call site passes `.section`.
    var prominence: Prominence = .pane
    /// Chip label. The chip shows only when both this and `statusColor` are set.
    var statusText: String?
    /// Chip tint. Use a `DSColor` semantic token (the `raw-status-color` lint
    /// rule rejects raw system colors here).
    var statusColor: Color?
    /// Optional leading SF Symbol for the status chip, so state is not conveyed
    /// by color alone. Passed straight through to `StatusChip`.
    var statusSymbol: String?

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s1h) {
            HStack(alignment: .center, spacing: DSSpace.s3) {
                titleText

                if let statusText, let statusColor {
                    Spacer()

                    StatusChip(text: statusText, color: statusColor, systemImage: statusSymbol)
                        .accessibilityLabel("\(title) status: \(statusText)")
                }
            }

            Text(subtitle)
                .fieldSubtitle()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Title

    /// The title styled for `prominence`.
    @ViewBuilder
    private var titleText: some View {
        switch prominence {
        case .pane:
            Text(title).paneTitle()
        case .section:
            Text(title).sectionHeader()
        }
    }
}

// MARK: - Previews

#Preview("With status") {
    SectionHeaderWithStatus(
        title: "Discord Status",
        subtitle: "Show your music on your Discord profile.",
        statusText: "Connected",
        statusColor: DSColor.success
    )
    .padding()
    .frame(width: 480)
}

#Preview("Without status") {
    SectionHeaderWithStatus(
        title: "About WolfWave",
        subtitle: "Native macOS menu bar app for Apple Music streamers."
    )
    .padding()
    .frame(width: 480)
}
