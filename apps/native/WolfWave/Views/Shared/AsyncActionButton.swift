//
//  AsyncActionButton.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-08-19.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// A button that owns the lifecycle of one `async` action: it swaps its label
/// for a spinner while the work runs, disables itself so the action cannot be
/// double-fired, and shows a brief checkmark on success.
///
/// This is the macOS-native shape of the pattern (App Store "Get", Xcode,
/// System Settings): the spinner *replaces* the label rather than sitting
/// beside it, and the control never changes width between states. The width
/// lock comes from `stableWidth(ghosts:)`, which measures the idle label, the
/// spinner, and the checkmark and pins the button to the widest of the three.
///
/// Error *presentation* stays with the caller. A thrown error returns the
/// button to idle without a checkmark; the surrounding view is expected to own
/// its own `CalloutBanner` or status string, as the settings panes already do.
///
/// ```swift
/// AsyncActionButton(title: "Join Channel", systemImage: "checkmark.circle.fill") {
///     try await viewModel.joinChannel()
/// }
/// ```
struct AsyncActionButton: View {

    // MARK: - Nested Types

    /// Visual treatment. Mirrors the styles the settings panes already use;
    /// applied through a private `ViewModifier` because `buttonStyle` returns
    /// different opaque types per branch.
    enum Style {
        /// `.bordered`: the neutral default for settings rows.
        case bordered
        /// `.borderedProminent`: the primary action in a group.
        case borderedProminent
        /// `.borderless`: inline actions inside dense rows.
        case borderless
    }

    /// Where the button is in the action lifecycle.
    enum Phase: Equatable {
        /// Waiting for a tap; shows the title label.
        case idle
        /// The action is in flight; shows the spinner and disables the control.
        case running
        /// The action finished without throwing; shows the checkmark for
        /// `successDuration` seconds, then returns to `.idle`.
        case succeeded
    }

    // MARK: - Properties

    /// Idle label text. Also the VoiceOver label.
    let title: String

    /// Optional leading SF Symbol for the idle label.
    var systemImage: String? = nil

    /// Set `.destructive` to tint the label with `DSColor.error`. Matches
    /// `DestructiveButton`: the red lives on the label, never as a `.tint`
    /// that would fill the whole control.
    var role: ButtonRole? = nil

    /// Button style applied through `AsyncActionButtonStyleModifier`.
    var style: Style = .bordered

    /// Control size passed to `.controlSize(_:)`. Small by default to match
    /// the settings rows.
    var size: ControlSize = .small

    /// Caller-owned disable reason (an unmet precondition, a dirty-state gate,
    /// a view-model teardown flag). Combined with the in-flight disable.
    var isDisabled: Bool = false

    /// Semantic tint for the control (green "approve", orange "hold"). Left nil
    /// for the neutral bordered look most settings rows use.
    var tint: Color? = nil

    /// Label point size. `DSFont.Size.body` matches the settings panes;
    /// `DSFont.Size.sm` matches the denser queue rows.
    var labelSize: CGFloat = DSFont.Size.body

    /// Stretch to the container's width, as the debug cards and full-width
    /// action rows do. A stretched button cannot resize when the label swaps,
    /// so it skips the `stableWidth` lock entirely.
    var fillsWidth: Bool = false

    /// Set `false` for actions whose result is obvious on screen anyway, so the
    /// checkmark would be noise.
    var showsSuccess: Bool = true

    /// How long the success checkmark holds before reverting to idle, in seconds.
    var successDuration: TimeInterval = 2.0

    /// UI-test identifier. Applied only when non-nil, via
    /// `accessibilityIdentifier(optional:)`.
    var accessibilityIdentifier: String? = nil

    /// The work to run. A thrown error returns the button to idle.
    let action: () async throws -> Void

    /// Current lifecycle phase; drives which label is shown and the disable.
    @State private var phase: Phase = .idle
    /// The in-flight action (plus its success hold). Cancelled on disappear so
    /// a closed pane does not keep running the work or flip state later.
    @State private var task: Task<Void, Never>?
    /// Bumped per run and on disappear; a run only writes `phase` while its
    /// id is still current.
    @State private var runID = 0

    /// Gates the label cross-fade; under Reduce Motion the swap is instant.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Body

    var body: some View {
        let button = Button(role: role, action: run) {
            label
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: DSMotion.Duration.base),
                    value: phase
                )
        }
        .modifier(AsyncActionButtonStyleModifier(style: style, size: size))
        .tint(tint)
        .disabled(isDisabled || phase == .running)
        .pointerCursor()
        .modifier(AsyncActionButtonWidthModifier(fillsWidth: fillsWidth, ghosts: {
            idleLabel
            spinnerLabel
            successLabel
        }))
        .onDisappear {
            task?.cancel()
            task = nil
            runID &+= 1
            phase = .idle
        }
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)

        button.accessibilityIdentifier(optional: accessibilityIdentifier)
    }

    // MARK: - Private Views

    /// The label for the current phase. All three variants are also rendered
    /// as hidden ghosts so the width never changes between them.
    @ViewBuilder
    private var label: some View {
        switch phase {
        case .idle:
            idleLabel
        case .running:
            spinnerLabel
        case .succeeded:
            successLabel
        }
    }

    /// Title (with the optional leading symbol) in the caller's label size.
    private var idleLabel: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(.system(size: labelSize, weight: .medium))
        .foregroundStyle(labelStyle)
        .frame(maxWidth: fillsWidth ? .infinity : nil)
    }

    /// Mini circular spinner. Hidden from VoiceOver; the "Working" accessibility
    /// value announces the state instead.
    private var spinnerLabel: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.mini)
            .accessibilityHidden(true)
    }

    /// Success checkmark in `DSColor.success`. Hidden from VoiceOver; the
    /// "Done" accessibility value announces it.
    private var successLabel: some View {
        Image(systemName: "checkmark")
            .font(.system(size: labelSize, weight: .semibold))
            .foregroundStyle(DSColor.success)
            .accessibilityHidden(true)
    }

    /// Destructive labels carry the red themselves. A tinted control lets the
    /// button style colour its own label, so we stay out of the way there.
    private var labelStyle: AnyShapeStyle {
        if role == .destructive {
            AnyShapeStyle(DSColor.error)
        } else if tint != nil {
            AnyShapeStyle(.tint)
        } else {
            AnyShapeStyle(.primary)
        }
    }

    /// VoiceOver value for the phase. The label stays `title` throughout, so
    /// the control keeps one stable name while its value changes.
    private var accessibilityValue: String {
        switch phase {
        case .idle: ""
        case .running: "Working"
        case .succeeded: "Done"
        }
    }

    // MARK: - Private Helpers

    /// Starts the action. Re-entrant taps are dropped: the button is disabled
    /// while running, and this guard covers the keyboard-activation race.
    ///
    /// Every run ends in a phase: a throw or a cancellation goes back to
    /// `.idle`, success to `.succeeded` (then `.idle`). `@State` outlives
    /// `onDisappear`, so a cancelled run that left `.running` behind would
    /// bring the button back as a disabled spinner; `onDisappear` resets it too.
    /// `runID` drops writes from a superseded run, so a late finish can never
    /// overwrite a newer one.
    private func run() {
        guard phase != .running else { return }
        task?.cancel()
        runID &+= 1
        let id = runID
        phase = .running
        task = Task { @MainActor in
            var threw = false
            do {
                try await action()
            } catch {
                threw = true
            }
            guard runID == id else { return }
            phase = Self.completionPhase(
                threw: threw, cancelled: Task.isCancelled, showsSuccess: showsSuccess)
            guard phase == .succeeded else { return }
            try? await Task.sleep(for: .seconds(successDuration))
            guard runID == id else { return }
            phase = .idle
        }
    }

    /// The phase a finished action lands in. Only an uncancelled, non-throwing
    /// run that wants the checkmark shows it; everything else is idle, so the
    /// button can never be left spinning.
    static func completionPhase(threw: Bool, cancelled: Bool, showsSuccess: Bool) -> Phase {
        threw || cancelled || !showsSuccess ? .idle : .succeeded
    }
}

// MARK: - Width Modifier

/// Applies the `stableWidth` lock only when the button sizes to its label. A
/// `fillsWidth` button takes the container's width, and `stableWidth` ends in
/// `fixedSize(horizontal: true)`, which would fight that.
private struct AsyncActionButtonWidthModifier<Ghosts: View>: ViewModifier {
    let fillsWidth: Bool
    @ViewBuilder let ghosts: () -> Ghosts

    func body(content: Content) -> some View {
        if fillsWidth {
            content.frame(maxWidth: .infinity)
        } else {
            content.stableWidth(ghosts: ghosts)
        }
    }
}

// MARK: - Style Modifier

/// Maps `AsyncActionButton.Style` to a concrete `buttonStyle`. Lives in a
/// modifier because each `buttonStyle` call returns a different opaque type,
/// which a plain `switch` in `body` cannot unify.
private struct AsyncActionButtonStyleModifier: ViewModifier {
    let style: AsyncActionButton.Style
    let size: ControlSize

    func body(content: Content) -> some View {
        switch style {
        case .bordered:
            content.buttonStyle(.bordered).controlSize(size)
        case .borderedProminent:
            content.buttonStyle(.borderedProminent).controlSize(size)
        case .borderless:
            content.buttonStyle(.borderless).controlSize(size)
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: DSSpace.s4) {
        AsyncActionButton(title: "Join Channel", systemImage: "checkmark.circle.fill") {
            try await Task.sleep(for: .seconds(2))
        }
        AsyncActionButton(title: "Fetch link", style: .borderedProminent) {
            try await Task.sleep(for: .seconds(2))
        }
        AsyncActionButton(title: "Clear Queue", role: .destructive) {
            try await Task.sleep(for: .seconds(1))
        }
        AsyncActionButton(title: "Always fails") {
            try await Task.sleep(for: .seconds(1))
            throw CocoaError(.fileNoSuchFile)
        }
        AsyncActionButton(title: "Blocked", isDisabled: true) {}
    }
    .padding()
    .frame(width: 320)
}
