//
//  ToggleSettingRow.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-03-27.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// A reusable toggle row with a title, subtitle, and switch control.
/// Used across settings views and onboarding for consistent toggle presentation.
struct ToggleSettingRow: View {

    // MARK: - Properties

    /// Row title.
    let title: String
    /// One-line description under the title.
    let subtitle: String
    /// The setting being toggled.
    @Binding var isOn: Bool
    /// Standard macOS control size; compact callers can explicitly opt into small.
    var controlSize: ControlSize = .regular
    /// Disables the switch and dims the whole row.
    var isDisabled: Bool = false
    /// VoiceOver label for the toggle.
    var accessibilityLabel: String
    /// UI-test identifier for the switch.
    var accessibilityIdentifier: String
    /// Optional VoiceOver hint; omitted entirely when `nil`.
    var accessibilityHint: String?
    /// Called with the new value whenever `isOn` changes. Fires for any change
    /// to the binding, not only a click on this switch, so a write from
    /// elsewhere (another view, a defaults change) triggers it too.
    var onChange: ((Bool) -> Void)?

    // MARK: - Body

    var body: some View {
        toggle
    }

    // MARK: - Private Views

    /// Keep the label inside the native control for keyboard and VoiceOver routing.
    @ViewBuilder
    private var toggle: some View {
        let base = Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: DSSpace.s0) {
                Text(title)
                    .font(.system(size: DSFont.Size.base, weight: .medium))
                Text(subtitle)
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
            .toggleStyle(.switch)
            .controlSize(controlSize)
            .disabled(isDisabled)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityIdentifier)
            .accessibilityValue(isOn ? "Enabled" : "Disabled")
            .onChange(of: isOn) { _, newValue in
                onChange?(newValue)
            }

        if let accessibilityHint {
            base.accessibilityHint(accessibilityHint)
        } else {
            base
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: DSSpace.s6) {
        ToggleSettingRow(
            title: "Enable Feature",
            subtitle: "A short description of what this does",
            isOn: .constant(true),
            accessibilityLabel: "Enable Feature",
            accessibilityIdentifier: "featureToggle"
        )
        .cardStyle()

        ToggleSettingRow(
            title: "Disabled Feature",
            subtitle: "This one is disabled",
            isOn: .constant(false),
            isDisabled: true,
            accessibilityLabel: "Disabled Feature",
            accessibilityIdentifier: "disabledToggle"
        )
        .cardStyle()
    }
    .padding()
    .frame(width: 400)
}
