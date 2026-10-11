//
//  MusicPermissionBanner.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-24.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Warning callout shown when Apple Music access is missing, with the button
/// that fixes it.
///
/// A thin, purpose-named wrapper over ``ErrorCallout``: it builds the
/// `music.automationDenied` ``UserFacingError`` from the caller's copy and maps
/// the two offered actions (Open System Settings, Learn More) to behavior, so
/// every pane gated on Music access reads and behaves the same.
///
/// Currently covers Apple Events automation permission (`MusicPermissionChecker`),
/// which is what `AppleMusicSource` relies on to read the currently-playing
/// track. The MusicKit `MusicAuthorization` flow used by Song Requests is
/// rendered by a separate fileprivate card in `SongRequestSettingsView`.
/// Migrating that to this banner is tracked as future cleanup.
///
/// Render conditionally: the banner does not self-gate, so callers should
/// only place it when `state == .denied`.
struct MusicPermissionBanner: View {

    // MARK: - Properties

    /// User-facing copy describing what the missing permission blocks.
    let message: String

    /// Triggered when the user taps "Open System Settings".
    var onOpenSettings: @MainActor () -> Void = { MusicPermissionChecker.openAutomationSettings() }

    // MARK: - Public Methods

    /// Stable identifier of the error this banner renders. Drives the
    /// accessibility identifiers `errorCallout.music.automationDenied` and
    /// `errorCallout.music.automationDenied.action.openAutomationSettings`.
    nonisolated static let errorID = "music.automationDenied"

    /// Troubleshooting docs anchor that explains the Automation grant.
    nonisolated static let docsAnchor = "music-permission"

    /// The structured error for `message`.
    ///
    /// Pure and static so the copy, severity, and offered actions are testable
    /// without rendering a view.
    ///
    /// - Parameter message: What the missing permission blocks, in the caller's words.
    /// - Returns: A warning whose primary action opens System Settings, with a
    ///   Learn More link to the troubleshooting page.
    nonisolated static func error(message: String) -> UserFacingError {
        UserFacingError(
            id: errorID,
            title: "Let WolfWave read what's playing",
            cause: message,
            severity: .warning,
            actions: [.openAutomationSettings],
            docsAnchor: docsAnchor
        )
    }

    // MARK: - Body

    var body: some View {
        ErrorCallout(error: Self.error(message: message)) { action in
            switch action {
            case .openAutomationSettings:
                onOpenSettings()
            case .openDocs(let anchor):
                ExternalLink.open("\(AppConstants.URLs.docs)/docs/troubleshooting#\(anchor)")
            default:
                break
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Preview

#Preview {
    MusicPermissionBanner(
        message: """
            WolfWave can't read the currently playing track. \
            Enable Apple Music automation in System Settings → Privacy & Security → Automation.
            """,
        onOpenSettings: {}
    )
    .padding()
    .frame(width: 520)
}
