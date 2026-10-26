//
//  CalloutBanner.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-06-01.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Inline tinted callout used to flag a state (info / success / warning /
/// error / neutral) inside settings panes.
///
/// One component for every "icon + text in a tinted rounded box" pattern that
/// had drifted across the app: info-blue "How it works" notes, orange caution
/// banners, green confirmations, red destructive warnings. Tint, icon, and
/// corner radius all resolve from one place, so call sites can't reintroduce
/// the radius drift (`DSRadius.sm` vs `.md` vs literal `8`) or the tint-opacity
/// drift (`0.07` vs `0.12`) that the audit found scattered across the views.
///
/// Pass a ``Style`` for the semantic tint plus a default SF Symbol; override
/// `systemImage` for a custom glyph. Supply `title` for a bold lead line above
/// the body (e.g. "How it works"). `message` is parsed as Markdown so inline
/// `**bold**` renders. `strokeVisible` overlays a 1pt tint stroke, used in the
/// Debug pane to mark developer-only tooling.
///
/// When the callout has a fix, pass it in the trailing `actions` builder. The
/// buttons render **inside** the box, under the message and on its text
/// column, at the small control size. A button left outside floated on its own
/// left edge with its own gap, and read as unrelated to the note it answers.
///
/// ```swift
/// CalloutBanner("Updates are managed by Homebrew.", style: .info)
/// CalloutBanner("Viewers type **!sr song name**.", title: "How it works", style: .info)
/// CalloutBanner("The connection is off.", style: .warning) {
///     Button("Open Stream Widgets", action: openStreamWidgets)
/// }
/// ```
struct CalloutBanner: View {

    // MARK: - Style

    /// Semantic callout intent. Drives the tint color and default icon.
    enum Style {
        case info
        case success
        case warning
        case error
        case neutral

        /// Design-system tint for the icon, background wash, and optional stroke.
        var tint: Color {
            switch self {
            case .info: return DSColor.info
            case .success: return DSColor.success
            case .warning: return DSColor.warning
            case .error: return DSColor.error
            case .neutral: return DSColor.neutral
            }
        }

        /// Icon color for this style on its own wash. In light appearance the
        /// bright semantic tints fall under 3:1 on that wash, so the glyph uses
        /// the darker `glyph…Light` token; dark appearance keeps the tint.
        func glyph(in colorScheme: ColorScheme) -> Color {
            DSColor.glyph(for: tint, in: colorScheme)
        }

        /// SF Symbol used when the caller does not supply `systemImage`.
        var defaultSymbol: String {
            switch self {
            case .info, .neutral: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "exclamationmark.octagon.fill"
            }
        }
    }

    // MARK: - Properties

    /// Body text; inline Markdown is rendered. Drawn one size smaller when a
    /// `title` is present, so the title leads.
    let message: String
    /// Optional bold lead line above the message.
    var title: String?
    /// Semantic intent. Defaults to `.warning`.
    var style: Style = .warning
    /// Overrides the style's default SF Symbol when non-nil.
    var systemImage: String?
    /// Adds a thin tint-colored border around the box.
    var strokeVisible: Bool = false
    /// Buttons that act on the callout, drawn inside the box under the message.
    /// `nil` for a plain note. Type-erased so `CalloutBanner` stays non-generic
    /// and `CalloutBanner.Style` keeps working as a plain nested type.
    var actions: AnyView?

    /// Picks the light- or dark-appearance glyph color.
    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Init

    /// - Parameters:
    ///   - message: Body text; inline Markdown is rendered.
    ///   - title: Optional bold lead line.
    ///   - style: Semantic intent; `.warning` by default.
    ///   - systemImage: Custom SF Symbol; `nil` uses the style's default.
    ///   - strokeVisible: Draws a tinted border.
    init(
        _ message: String,
        title: String? = nil,
        style: Style = .warning,
        systemImage: String? = nil,
        strokeVisible: Bool = false
    ) {
        self.message = message
        self.title = title
        self.style = style
        self.systemImage = systemImage
        self.strokeVisible = strokeVisible
        self.actions = nil
    }

    /// A callout with buttons that act on it, drawn inside the box.
    ///
    /// - Parameters:
    ///   - message: Body text; inline Markdown is rendered.
    ///   - title: Optional bold lead line.
    ///   - style: Semantic intent; `.warning` by default.
    ///   - systemImage: Custom SF Symbol; `nil` uses the style's default.
    ///   - strokeVisible: Draws a tinted border.
    ///   - actions: The buttons, laid out in a row at the small control size.
    ///     Callers pick each button's style (`.borderedProminent` for the one
    ///     obvious fix).
    init<Actions: View>(
        _ message: String,
        title: String? = nil,
        style: Style = .warning,
        systemImage: String? = nil,
        strokeVisible: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) {
        self.message = message
        self.title = title
        self.style = style
        self.systemImage = systemImage
        self.strokeVisible = strokeVisible
        self.actions = AnyView(actions())
    }

    // MARK: - Private Helpers

    /// Shorthand for the style's tint (wash and stroke).
    private var tint: Color { style.tint }
    /// The caller's symbol, or the style's default.
    private var symbol: String { systemImage ?? style.defaultSymbol }

    // MARK: - Body

    var body: some View {
        // First-baseline alignment pins the icon to the first line of text
        // (the title, or the message when there is none) instead of to the
        // top of the text frame, where it sat a couple of points high.
        HStack(alignment: .firstTextBaseline, spacing: DSSpace.s2) {
            Image(systemName: symbol)
                .font(.system(size: DSFont.Size.body))
                .foregroundStyle(style.glyph(in: colorScheme))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DSSpace.s2) {
                VStack(alignment: .leading, spacing: DSSpace.s1) {
                    if let title {
                        Text(title)
                            .font(.system(size: DSFont.Size.body, weight: .semibold))
                    }
                    Text(InlineMarkdown.attributed(message))
                        .font(.system(size: title == nil ? DSFont.Size.body : DSFont.Size.sm))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Title and message stay one VoiceOver element even when the
                // buttons below must stay separately reachable.
                .accessibilityElement(children: .combine)

                if let actions {
                    HStack(spacing: DSSpace.s2) {
                        actions
                    }
                    .controlSize(.small)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DSSpace.s4)
        .padding(.vertical, DSSpace.s3)
        .background(tint.opacity(DSOpacity.wash))
        .clipShape(RoundedRectangle(cornerRadius: AppConstants.SettingsUI.cardCornerRadius))
        .overlay {
            if strokeVisible {
                RoundedRectangle(cornerRadius: AppConstants.SettingsUI.cardCornerRadius)
                    .stroke(tint.opacity(0.25), lineWidth: 1)
            }
        }
        // A plain note is one VoiceOver element: title then message. With
        // actions, `.contain` keeps each button its own focusable element; a
        // `.combine` would fold them into the text and make them unpressable.
        // The icon is hidden either way, so put the severity in the words.
        .accessibilityElement(children: actions == nil ? .combine : .contain)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: DSSpace.s4) {
        CalloutBanner(
            "Viewers type **!sr song name** in chat and WolfWave adds it to the queue.",
            title: "How it works",
            style: .info
        )
        CalloutBanner("Updates are managed by Homebrew. Run brew upgrade to update.", style: .info)
        CalloutBanner("Diagnostics build. Sparkle points at the bundled dev-appcast.", style: .warning)
        CalloutBanner("You're on the latest version.", style: .success)
        CalloutBanner("These tools mutate live state. Use at your own risk.", style: .warning, strokeVisible: true)
        CalloutBanner("Deleting the queue cannot be undone.", style: .error)
        CalloutBanner("Nothing is uploaded. Everything stays on this Mac.", style: .neutral)
        CalloutBanner(
            "Stream Deck and your overlay share one connection, and it's currently off.",
            title: "The connection is off",
            style: .warning
        ) {
            Button("Open Stream Widgets") {}
                .buttonStyle(.borderedProminent)
        }
    }
    .padding()
    .frame(width: 480)
}
