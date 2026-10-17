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
    /// Switch size; small by default to match settings rows.
    var controlSize: ControlSize = .small
    /// Disables the switch and dims the whole row.
    var isDisabled: Bool = false
    /// VoiceOver label for the switch (the visible title is not attached to it).
    var accessibilityLabel: String
    /// UI-test identifier for the switch.
    var accessibilityIdentifier: String
    /// Optional VoiceOver hint; omitted entirely when `nil`.
    var accessibilityHint: String?
    /// Called with the new value whenever `isOn` changes. Fires for any change
    /// to the binding, not only a click on this switch, so a write from
    /// elsewhere (another view, a defaults change) triggers it too.
    var onChange: ((Bool) -> Void)?

    /// Inherited enabled state. The row dims when either this or `isDisabled`
    /// turns it off, so a `.disabled(_:)` on an ancestor dims it too.
    @Environment(\.isEnabled) private var isEnabled

    // MARK: - Body

    var body: some View {
        HStack(spacing: DSSpace.s4) {
            VStack(alignment: .leading, spacing: DSSpace.s0) {
                Text(title)
                    .font(.system(size: DSFont.Size.base, weight: .medium))
                Text(subtitle)
                    .font(.system(size: DSFont.Size.sm))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            toggle
        }
        .opacity(!isEnabled || isDisabled ? 0.5 : 1.0)
    }

    // MARK: - Private Views

    /// The label-hidden switch carrying the accessibility contract.
    @ViewBuilder
    private var toggle: some View {
        let base = Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(controlSize)
            .pointerCursor()
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
