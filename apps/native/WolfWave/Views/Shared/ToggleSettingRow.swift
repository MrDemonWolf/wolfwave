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
///
/// Pass `hint` for a footnote that belongs to this switch (e.g. who the setting
/// lets in). The row draws it as a ``HintRow`` under the title column at a fixed
/// gap, so a caller never stacks a divider, padding, and a hint by hand.
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
    /// Optional live state for what this switch controls (server listening,
    /// connected, failed). Drawn as a ``StatusChip`` beside the switch, on the
    /// row it describes, so a pane never spends a line of its own on a chip.
    /// VoiceOver hears it as part of the switch's value.
    var status: StatusChip.Descriptor?
    /// Every label `status` can carry on this row. Pass it whenever the state
    /// changes while the pane is open, so the chip keeps one width and the
    /// row never shifts. See ``StatusChip/sizingLabels``.
    var statusLabels: [String] = []
    /// Called with the new value whenever `isOn` changes. Fires for any change
    /// to the binding, not only a click on this switch, so a write from
    /// elsewhere (another view, a defaults change) triggers it too.
    var onChange: ((Bool) -> Void)?
    /// Optional footnote under the row, drawn as a ``HintRow``. `nil` draws nothing.
    var hint: String?
    /// The hint's leading SF Symbol.
    var hintSystemImage: String = "info.circle.fill"

    // MARK: - Body

    var body: some View {
        if let hint {
            // Outside the Toggle on purpose: inside its label the hint would
            // join the control's VoiceOver label and its click target.
            VStack(alignment: .leading, spacing: DSSpace.s1h) {
                toggle
                HintRow(hint, systemImage: hintSystemImage)
            }
        } else {
            toggle
        }
    }

    // MARK: - Private Views

    /// Title over subtitle, filling the row's leading side.
    private var labelText: some View {
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

    /// Switch position, plus the live status when the row carries one.
    private var accessibilityValueText: String {
        let position = isOn ? "Enabled" : "Disabled"
        guard let status else { return position }
        return "\(position), \(status.text)"
    }

    /// Keep the label inside the native control for keyboard and VoiceOver routing.
    @ViewBuilder
    private var toggle: some View {
        let base = Toggle(isOn: $isOn) {
            if let status {
                // Chip beside the switch when the row is wide enough to keep
                // the title on one line; under the text in a narrow window,
                // where an inline chip squeezed the title into a tall column.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: DSSpace.s4) {
                        labelText
                        StatusChip(status, sizingLabels: statusLabels)
                    }
                    .frame(minWidth: DSDimension.Settings.inlineActionsMinWidth)

                    VStack(alignment: .leading, spacing: DSSpace.s2) {
                        labelText
                        StatusChip(status, sizingLabels: statusLabels)
                    }
                }
            } else {
                labelText
            }
        }
            .toggleStyle(.switch)
            .controlSize(controlSize)
            .disabled(isDisabled)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityIdentifier)
            .accessibilityValue(accessibilityValueText)
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

        ToggleSettingRow(
            title: "Allow Stream Deck commands",
            subtitle: "Let a Stream Deck key skip songs and hold the queue.",
            isOn: .constant(true),
            accessibilityLabel: "Toggle Stream Deck commands",
            accessibilityIdentifier: "hintedToggle",
            hint: "Commands are only accepted from this Mac.",
            hintSystemImage: "lock.fill"
        )
        .cardStyle()

        ToggleSettingRow(
            title: "Enable Stream Widgets",
            subtitle: "Show live song updates in your overlay.",
            isOn: .constant(true),
            accessibilityLabel: "Toggle Stream Widgets",
            accessibilityIdentifier: "statusToggle",
            status: .init(text: "Listening", color: DSColor.success, symbol: StatusChip.StateGlyph.on)
        )
        .cardStyle()
    }
    .padding()
    .frame(width: 400)
}
