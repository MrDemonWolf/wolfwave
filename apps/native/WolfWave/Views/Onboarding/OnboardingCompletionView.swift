//
//  OnboardingCompletionView.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-03-20.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// The screen every onboarding ending reaches (Finish and Skip setup): a short
/// headline, then where WolfWave lives, shown as a drawn menu bar with an arrow
/// at the wolf. That pointer used to be its own last step, which Skip setup
/// jumped past; here nobody misses it.
///
/// Dismisses itself after `autoDismissDelay` unless VoiceOver is running (a
/// screen reader user needs time to hear it). The **Done** button, bound to
/// Return, always closes it right away.
struct OnboardingCompletionView: View {

    // MARK: - Types

    /// Which ending the wizard reached.
    enum Style: Equatable {
        /// The user walked (or finished) the wizard.
        case completed
        /// The user chose Skip setup. Lighter copy, same exit.
        case skipped

        /// Large headline.
        var title: String {
            switch self {
            case .completed: return "Howl yeah, you're set."
            case .skipped: return "No problem."
            }
        }

        /// Secondary line under the headline.
        var message: String {
            switch self {
            case .completed:
                return "WolfWave lives in your menu bar. Click the wolf to see what's playing or open Settings."
            case .skipped:
                return "Set things up any time in Settings. Click the wolf in your menu bar to open it."
            }
        }

        /// What VoiceOver reads for the headline + message group, replacing both.
        var accessibilitySummary: String {
            switch self {
            case .completed: return "Setup complete. WolfWave is in your menu bar."
            case .skipped: return "Setup skipped. WolfWave is in your menu bar. Finish setup any time in Settings."
            }
        }
    }

    // MARK: - Properties

    /// Called after the animation sequence to dismiss the onboarding window.
    var onDismiss: () -> Void

    /// Which ending to show. Defaults to the full celebration.
    var style: Style = .completed

    // MARK: - Animation State

    /// Drives the hero mark's drop-in. Set first by the entrance `.task`.
    @State private var showHero = false
    /// Drives the fade-in of the text, pointer, Done button, and copyright line.
    /// Set after a short beat so the text lands once the mark has settled.
    @State private var showText = false

    /// Guards `onDismiss` so the auto-timer and a manual tap can't both fire it.
    @State private var didDismiss = false

    /// When on, both flags flip at once with no animation, and the auto-dismiss
    /// wait is the delay alone.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Layout Constants

    /// Hero mark edge: the onboarding brand tile size plus `DSSpace.s6`.
    private static let heroSize: CGFloat = DSDimension.Onboarding.brandTileSize + DSSpace.s6

    /// How long the screen stays up on its own: long enough to read the
    /// headline and find the wolf in the menu bar.
    static let autoDismissDelay: Duration = .seconds(5)

    // MARK: - Body

    var body: some View {
        VStack(spacing: DSSpace.s7) {
            Spacer(minLength: DSSpace.s6)

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
                    .frame(maxWidth: DSDimension.Onboarding.contentMaxWidth)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(style.accessibilitySummary)
            .accessibilityAddTraits(.isHeader)
                .modifier(FadeIn(isVisible: showText, reduceMotion: reduceMotion))

            MenuBarPointer()
                .padding(.horizontal, DSSpace.s10)
                .modifier(FadeIn(isVisible: showText, reduceMotion: reduceMotion))

            Button("Done") { dismissOnce() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .pointerCursor()
                .accessibilityHint("Closes setup")
                .accessibilityIdentifier("onboarding.done")
                .modifier(FadeIn(isVisible: showText, reduceMotion: reduceMotion))

            Spacer(minLength: DSSpace.s6)

            Text(Self.copyrightLine)
                .font(.system(size: DSFont.Size.xs))
                .foregroundStyle(.secondary)
                .padding(.bottom, DSSpace.s4)
                .modifier(FadeIn(isVisible: showText, reduceMotion: reduceMotion))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // Click anywhere to dismiss early instead of waiting out the timer.
        // Pointer-only convenience: keyboard and VoiceOver users have Done.
        .contentShape(Rectangle())
        .onTapGesture { dismissOnce() }
        // Entrance sequence. The `.task` is cancelled if the view goes away,
        // and each sleep is followed by a cancellation check so a closed window
        // never fires `onDismiss` late.
        .task {
            let autoDismiss = Self.shouldAutoDismiss(
                voiceOverEnabled: NSWorkspace.shared.isVoiceOverEnabled
            ) && !UITestMode.holdsCompletion
            showHero = true
            if reduceMotion {
                showText = true
            } else {
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled else { return }
                showText = true
            }
            guard autoDismiss else { return }
            try? await Task.sleep(for: Self.autoDismissDelay)
            guard !Task.isCancelled else { return }
            dismissOnce()
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

    /// Footer line with the current year and the configured holder.
    private static var copyrightLine: String {
        copyrightLine(year: Calendar.current.component(.year, from: Date()))
    }

    /// Builds the footer line. The holder defaults to
    /// `AppConstants.AppInfo.copyrightHolder` (overridable through
    /// `COPYRIGHT_HOLDER`), so a fork's name shows here as it does in About.
    static func copyrightLine(
        year: Int,
        holder: String = AppConstants.AppInfo.copyrightHolder
    ) -> String {
        "© \(year) \(holder)"
    }
}

// MARK: - Fade In

/// The text, pointer, and button fade in together once the hero has landed.
private struct FadeIn: ViewModifier {
    let isVisible: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .animation(
                reduceMotion ? .none : .easeOut(duration: DSMotion.Duration.long),
                value: isVisible
            )
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
