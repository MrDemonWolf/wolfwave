//
//  SongRequestSettingsView+ContentFilters.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-11-23.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

// MARK: - Content Filters

/// The explicit-song filter and the max song length. Both apply to every
/// request path (`!sr`, channel points, Bits); refused channel points are
/// refunded. The service reads them per request, so no notification is needed.
struct SongRequestContentFilterCard: View {
    /// Refuse songs Apple Music marks explicit.
    @AppStorage(AppConstants.UserDefaults.songRequestBlockExplicit)
    private var blockExplicit = AppConstants.UserDefaults.Defaults.songRequestBlockExplicit

    /// Longest allowed song in seconds; `0` = no limit.
    @AppStorage(AppConstants.UserDefaults.songRequestMaxSongSeconds)
    private var maxSongSeconds = AppConstants.UserDefaults.Defaults.songRequestMaxSongSeconds

    private static let lengthOptions = AppConstants.UserDefaults.Defaults.songRequestMaxSongSecondsOptions

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            Text("Content Filters")
                .font(.system(size: DSFont.Size.base, weight: .semibold))

            ToggleSettingRow(
                title: "Block Explicit Songs",
                subtitle: "Refuses songs Apple Music marks explicit. Viewers are told to try the clean version.",
                isOn: $blockExplicit,
                accessibilityLabel: "Block explicit songs",
                accessibilityIdentifier: "songRequests.blockExplicit"
            )

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: DSSpace.s0) {
                    Text("Max song length")
                        .font(.system(size: DSFont.Size.body))
                    Text("Longer songs are refused, and channel points are refunded.")
                        .font(.system(size: DSFont.Size.xs))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Picker(
                    "Max song length",
                    selection: $maxSongSeconds.snapped(
                        to: Self.lengthOptions,
                        fallback: AppConstants.UserDefaults.Defaults.songRequestMaxSongSeconds)
                ) {
                    ForEach(Self.lengthOptions, id: \.self) { seconds in
                        Text(Self.label(for: seconds)).tag(seconds)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 110)
                .accessibilityIdentifier("songRequests.maxSongLength")
            }
        }
        .cardStyle()
    }

    /// Picker label for a length option, for example "6 min" or "No limit".
    static func label(for seconds: Int) -> String {
        seconds > 0 ? "\(seconds / 60) min" : "No limit"
    }
}
