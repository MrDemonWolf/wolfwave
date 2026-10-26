//
//  MenuBarPointer.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-07.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// A drawn menu-bar strip with the wolf mark highlighted and an arrow pointing
/// up at it, so the user knows where WolfWave lives once setup closes.
///
/// Shown on the onboarding completion screen, which every ending (Finish and
/// Skip setup) reaches. The strip is a drawing, not a capture of the real menu
/// bar, so the mark's position in it is illustrative. Decorative: hidden from
/// VoiceOver, so place it next to text that says the same thing.
struct MenuBarPointer: View {

    // MARK: - Animation State

    /// Toggled once on appear inside a repeating animation; the arrow's offset
    /// follows it up and down while the view is visible.
    @State private var arrowBobbing = false
    /// Same pattern as `arrowBobbing`, driving the mark's highlight and glow.
    @State private var iconPulsing = false

    /// When on, neither loop starts and the arrow and mark stay still.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Body

    var body: some View {
        VStack(spacing: DSSpace.s1) {
            menuBarPreview
            arrowSlot
        }
        // The arrow is drawn in an overlay at the mark's x position, read through
        // `IconCenterAnchorKey`, so it lines up with the mark however wide the
        // strip lays out. `arrowSlot` keeps room for it in the stack.
        .overlayPreferenceValue(IconCenterAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor {
                    let point = proxy[anchor]
                    arrow
                        .position(x: point.x, y: point.y + arrowVerticalGap)
                }
            }
            .allowsHitTesting(false)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: DSMotion.Duration.pulse).repeatForever(autoreverses: true)) {
                arrowBobbing = true
            }
            withAnimation(.easeInOut(duration: DSMotion.Duration.pulseSlow).repeatForever(autoreverses: true)) {
                iconPulsing = true
            }
        }
        .onDisappear {
            // Stop the repeating loops once the view goes away.
            withAnimation(.linear(duration: DSMotion.Duration.instant)) {
                arrowBobbing = false
                iconPulsing = false
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Menu Bar Preview

    /// Mock menu bar strip: placeholder status icons around the WolfWave mark,
    /// then a clock. The mark publishes its center through `IconCenterAnchorKey`.
    private var menuBarPreview: some View {
        HStack(spacing: DSSpace.s2) {
            Spacer()

            ForEach(0..<3, id: \.self) { _ in
                placeholderIcon
            }

            ZStack {
                RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                    .fill(Color.accentColor.opacity(iconPulsing ? 0.20 : 0.08))
                    .frame(width: 26, height: 22)

                Image("WolfMark")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.primary)
            }
            .shadow(
                color: Color.accentColor.opacity(iconPulsing ? 0.40 : 0),
                radius: 10, x: 0, y: 0
            )
            .anchorPreference(key: IconCenterAnchorKey.self, value: .center) { $0 }

            ForEach(0..<2, id: \.self) { _ in
                placeholderIcon
            }

            Text(currentTime)
                .font(.system(size: DSFont.Size.body, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.leading, DSSpace.s1)
        }
        .padding(.horizontal, DSSpace.s5)
        .padding(.vertical, DSSpace.s2)
        .frame(maxWidth: DSDimension.Onboarding.contentMaxWidth)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
    }

    /// One grey stand-in for another app's status item.
    private var placeholderIcon: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 14, height: 14)
    }

    // MARK: - Arrow

    /// Reserves vertical space in the layout flow for the arrow, which is rendered
    /// via overlayPreferenceValue and positioned at the icon's x-coordinate.
    private var arrowSlot: some View {
        Color.clear
            .frame(height: 30)
    }

    /// Up arrow under the mark.
    private var arrow: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: DSFont.Size.x2xl, weight: .bold))
            .foregroundStyle(Color.accentColor)
            .offset(y: arrowBobbing ? -4 : 4)
    }

    /// Vertical distance from the icon center down to the arrow center.
    private var arrowVerticalGap: CGFloat { 36 }

    // MARK: - Helpers

    /// Clock format for the mock strip, for example "Tue 9:41 AM", following
    /// the user's 12/24-hour setting.
    private static let menuBarClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
        return formatter
    }()

    /// The time at render. It does not tick; it only changes if the view
    /// re-renders for another reason.
    private var currentTime: String {
        Self.menuBarClockFormatter.string(from: Date())
    }
}

// MARK: - Preference Key

/// Carries the center anchor of the mock menu-bar mark up to the overlay,
/// which positions the arrow under it. Keeps the first value reported.
private struct IconCenterAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGPoint>? = nil
    static func reduce(value: inout Anchor<CGPoint>?, nextValue: () -> Anchor<CGPoint>?) {
        value = value ?? nextValue()
    }
}

// MARK: - Preview

#Preview {
    MenuBarPointer()
        .padding(DSSpace.s8)
        .frame(width: 600)
}
