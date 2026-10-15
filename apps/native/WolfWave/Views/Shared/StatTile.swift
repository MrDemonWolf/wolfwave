//
//  StatTile.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-27.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Vertical stat tile: large primary value, optional secondary value,
/// sentence-case caption beneath. Used in the History & Stats summary row
/// ("129 / 27m / This week") and any other place that previously stacked
/// number + ALL-CAPS label by hand.
///
/// Replaces the ad-hoc `summaryStat(value:unit:label:)` helper. Combines all
/// three text rows into a single accessibility element with a caption-first
/// label, so VoiceOver reads "This week: 129, 27m" as one stat.
struct StatTile: View {

    // MARK: - Properties

    /// The large primary value, already formatted.
    let value: String
    /// Optional smaller line under the value (for example a duration).
    var secondary: String? = nil
    /// Sentence-case label under the value(s).
    let caption: String
    /// UI-test identifier. Defaults to `statTile.<caption>`.
    var accessibilityIdentifier: String? = nil

    // MARK: - Body

    var body: some View {
        VStack(spacing: DSSpace.s0) {
            Text(value)
                .font(.system(size: DSFont.Size.x2xl, weight: .bold))
                .foregroundStyle(.primary)
                .monospacedDigit()

            if let secondary {
                Text(secondary)
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.secondary)
            }

            Text(caption)
                .font(.system(size: DSFont.Size.sm, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier ?? "statTile.\(caption)")
    }

    /// Caption first, then value, then the secondary line if present.
    private var accessibilityLabel: String {
        if let secondary {
            return "\(caption): \(value), \(secondary)"
        }
        return "\(caption): \(value)"
    }
}

// MARK: - Preview

#Preview {
    HStack(spacing: 0) {
        StatTile(value: "129", secondary: "27m", caption: "This week")
        Divider().frame(height: 40)
        StatTile(value: "22", secondary: "4m", caption: "Today")
        Divider().frame(height: 40)
        StatTile(value: "129", secondary: "27m", caption: "All time")
    }
    .padding()
    .frame(width: 500)
}
