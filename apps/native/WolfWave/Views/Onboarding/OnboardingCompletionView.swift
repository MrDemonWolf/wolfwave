//
//  OnboardingCompletionView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-03-20.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Celebration screen shown after onboarding completes. The canonical
/// `WolfHeroMark` entrance is the celebration cue. No separate checkmark.
///
/// Dismisses itself after the animation unless VoiceOver is running (a screen
/// reader user needs time to hear it). The **Done** button, bound to Return,
/// always closes it right away.
struct OnboardingCompletionView: View {

    // MARK: - Types

    /// Which ending the wizard reached.
    enum Style: Equatable {
        /// The user walked (or finished) the wizard.
        case completed
        /// The user chose Skip All. Lighter copy, same exit.
        case skipped

        var title: String {
            switch self {
            case .completed: return "Howl yeah, you're set."
            case .skipped: return "Skipped."
            }
        }

        var message: String {
            switch self {
            case .completed: return "WolfWave's in your menu bar. Click the wolf any time."
            case .skipped: return "Finish setup any time in Settings."
            }
        }

        var accessibilitySummary: String {
            switch self {
            case .completed: return "Setup complete. WolfWave is in your menu bar."
            case .skipped: return "Setup skipped. Finish setup any time in Settings."
            }
        }
    }

    // MARK: - Properties

    /// Called after the animation sequence to dismiss the onboarding window.
    var onDismiss: () -> Void

    /// Which ending to show. Defaults to the full celebration.
    var style: Style = .completed

    // MARK: - Animation State

    @State private var showHero = false
    @State private var showText = false

    /// Guards `onDismiss` so the auto-timer and a manual tap can't both fire it.
    @State private var didDismiss = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Layout Constants

    private static let heroSize: CGFloat = DSDimension.Onboarding.brandTileSize + DSSpace.s10

    // MARK: - Body

    var body: some View {
        VStack(spacing: DSSpace.s7) {
            Spacer()

            WolfHeroMark(
                size: Self.heroSize,
                style: .brandGradient
            )
            .offset(y: showHero ? 0 : -DSSpace.s10)
            .opacity(showHero ? 1 : 0)
            .animation(
                reduceMotion
                    ? .none
                    : .interpolatingSpring(stiffness: 200, damping: 14),
                value: showHero
            )

            VStack(spacing: DSSpace.s2) {
                Text(style.title)
                    .font(.system(size: DSFont.Size.x3xl, weight: .bold))
                    .multilineTextAlignment(.center)

                Text(style.message)
                    .font(.system(size: DSFont.Size.base))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .opacity(showText ? 1 : 0)
            .animation(
                reduceMotion ? .none : .easeOut(duration: DSMotion.Duration.long),
                value: showText
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(style.accessibilitySummary)

            Button("Done") { dismissOnce() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .pointerCursor()
                .opacity(showText ? 1 : 0)
                .animation(
                    reduceMotion ? .none : .easeOut(duration: DSMotion.Duration.long),
                    value: showText
                )
                .accessibilityHint("Closes setup")
                .accessibilityIdentifier("onboarding.done")

            Spacer()

            Text(Self.copyrightLine)
                .font(.system(size: DSFont.Size.xs))
                .foregroundStyle(.tertiary)
                .padding(.bottom, DSSpace.s4)
                .opacity(showText ? 1 : 0)
                .animation(
                    reduceMotion ? .none : .easeOut(duration: DSMotion.Duration.long),
                    value: showText
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // Click anywhere to dismiss early instead of waiting out the timer.
        // Pointer-only convenience: keyboard and VoiceOver users have Done.
        .contentShape(Rectangle())
        .onTapGesture { dismissOnce() }
        .task {
            let autoDismiss = Self.shouldAutoDismiss(
                voiceOverEnabled: NSWorkspace.shared.isVoiceOverEnabled
            )
            if reduceMotion {
                showHero = true
                showText = true
                guard autoDismiss else { return }
                try? await Task.sleep(for: .milliseconds(1200))
                guard !Task.isCancelled else { return }
                dismissOnce()
            } else {
                showHero = true
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled else { return }
                showText = true
                guard autoDismiss else { return }
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled else { return }
                dismissOnce()
            }
        }
    }

    // MARK: - Auto-Dismiss Policy

    /// Whether the screen should close itself after the animation.
    ///
    /// VoiceOver users need the time to hear the message and can press Done
    /// when ready, so the timer is off while VoiceOver runs.
    static func shouldAutoDismiss(voiceOverEnabled: Bool) -> Bool {
        !voiceOverEnabled
    }

    // MARK: - Dismiss

    /// Fires `onDismiss` at most once, whether triggered by the auto-timer or a
    /// manual tap.
    private func dismissOnce() {
        guard !didDismiss else { return }
        didDismiss = true
        onDismiss()
    }

    // MARK: - Copyright

    /// Hardcoded for now. When the config refactor lands a `COPYRIGHT_HOLDER`
    /// key, swap to `AppConstants.copyrightHolder`.
    private static var copyrightLine: String {
        let year = Calendar.current.component(.year, from: Date())
        return "© \(year) MrDemonWolf, Inc."
    }
}

// MARK: - Previews

#Preview("Completed") {
    OnboardingCompletionView(onDismiss: {})
        .frame(
            width: AppConstants.OnboardingUI.windowWidth,
            height: AppConstants.OnboardingUI.windowHeight
        )
}

#Preview("Skipped") {
    OnboardingCompletionView(onDismiss: {}, style: .skipped)
        .frame(
            width: AppConstants.OnboardingUI.windowWidth,
            height: AppConstants.OnboardingUI.windowHeight
        )
}
