//
//  TwitchConnectionNotice.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-06-05.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import SwiftUI

/// Inline gate banner shown when a pane's feature depends on a live Twitch
/// connection.
///
/// Twitch auth has two "not ready" states that read very differently to a
/// streamer: a sign-in that *expired* (their fault is nothing, the token just
/// aged out) versus Twitch *never being connected*. Before this, the Twitch
/// pane's Bot Commands card and the Song Requests pane each hand-rolled the same
/// `CalloutBanner(style:systemImage:)` split, and they had drifted: Song
/// Requests showed the calm blue "Connect with Twitch" info note even when the
/// sign-in had actually expired, so it never surfaced the orange "reconnect"
/// warning the Twitch pane did.
///
/// This is the one place that maps `(isConnected, reauthNeeded)` to a banner:
/// expired → `.warning` (orange triangle), disconnected → `.info` + lock glyph,
/// connected-and-valid → nothing. Call sites pass copy for their own feature so
/// the wording stays specific ("…to enable song requests" vs "…chat commands").
///
/// An expired sign-in is a failure the user can fix, so when the caller passes
/// `onReconnect` it renders as an ``ErrorCallout`` with a "Reconnect with
/// Twitch" button (`twitch.signInExpired`). Without a handler there is nothing
/// to press, so it stays a plain ``CalloutBanner`` note, as does the
/// never-connected state, which is guidance rather than an error.
///
/// ```swift
/// TwitchConnectionNotice(
///     isConnected: viewModel.channelConnected,
///     reauthNeeded: viewModel.reauthNeeded,
///     expiredMessage: "Chat commands are paused until you reconnect.",
///     disconnectedMessage: "Connect with Twitch above to let people use these chat commands.",
///     onReconnect: reconnectTwitch
/// )
/// ```
struct TwitchConnectionNotice: View {

    // MARK: - State

    /// Which banner (if any) the current Twitch flags resolve to.
    ///
    /// Pure so the branching is unit-testable without rendering a view.
    /// `reauthNeeded` wins over `isConnected`: an expired sign-in can briefly
    /// coexist with a still-open socket, and the warning is the more urgent read.
    /// `nonisolated` so the pure resolver and its `Equatable` conformance stay
    /// callable off the main actor. The module defaults to `MainActor` isolation,
    /// which would otherwise pin this value type to the main actor and block the
    /// nonisolated unit tests from touching it.
    nonisolated enum State: Equatable {
        /// Sign-in expired; reconnect needed.
        case expired
        /// Twitch was never connected (or is not connected now).
        case disconnected
        /// Connected with a valid sign-in; renders nothing.
        case ready

        /// Maps the two flags to a state, with `reauthNeeded` taking priority.
        static func resolve(isConnected: Bool, reauthNeeded: Bool) -> State {
            if reauthNeeded { return .expired }
            if !isConnected { return .disconnected }
            return .ready
        }
    }

    // MARK: - Properties

    /// Whether Twitch chat is currently connected.
    let isConnected: Bool
    /// Whether the stored Twitch token expired and a reconnect is required.
    let reauthNeeded: Bool
    /// Copy shown when the sign-in expired (orange warning).
    let expiredMessage: String
    /// Copy shown when Twitch was never connected (blue info + lock glyph).
    let disconnectedMessage: String
    /// Starts the Twitch reconnect. When set, the expired state offers a
    /// "Reconnect with Twitch" button; when `nil`, it is a note with no action.
    let onReconnect: (@MainActor () -> Void)?

    // MARK: - Init

    /// - Parameters:
    ///   - isConnected: Whether Twitch chat is connected.
    ///   - reauthNeeded: Whether the stored sign-in expired.
    ///   - expiredMessage: Feature-specific copy for the expired state.
    ///   - disconnectedMessage: Feature-specific copy for the never-connected state.
    ///   - onReconnect: Optional reconnect handler; adds the reconnect button.
    init(
        isConnected: Bool,
        reauthNeeded: Bool,
        expiredMessage: String,
        disconnectedMessage: String,
        onReconnect: (@MainActor () -> Void)? = nil
    ) {
        self.isConnected = isConnected
        self.reauthNeeded = reauthNeeded
        self.expiredMessage = expiredMessage
        self.disconnectedMessage = disconnectedMessage
        self.onReconnect = onReconnect
    }

    // MARK: - Public Methods

    /// Stable identifier of the expired-sign-in error, shared with the Twitch
    /// pane's own `twitch.signInExpired` callout.
    nonisolated static let expiredErrorID = "twitch.signInExpired"

    /// The structured error the expired state renders when a reconnect handler
    /// is supplied.
    ///
    /// Pure and static so the copy, severity, and offered action are testable
    /// without rendering a view.
    ///
    /// - Parameter message: The caller's feature-specific expired copy. The
    ///   title already says the sign-in expired, so the message should say what
    ///   stopped working.
    /// - Returns: A warning whose only action is ``ErrorAction/reconnectTwitch``.
    nonisolated static func expiredError(message: String) -> UserFacingError {
        UserFacingError(
            id: expiredErrorID,
            title: "Twitch sign-in expired",
            cause: message,
            severity: .warning,
            actions: [.reconnectTwitch]
        )
    }

    // MARK: - Body

    @ViewBuilder
    var body: some View {
        switch State.resolve(isConnected: isConnected, reauthNeeded: reauthNeeded) {
        case .expired:
            if let onReconnect {
                ErrorCallout(error: Self.expiredError(message: expiredMessage)) { action in
                    if action == .reconnectTwitch { onReconnect() }
                }
            } else {
                CalloutBanner(expiredMessage, style: .warning)
            }
        case .disconnected:
            CalloutBanner(disconnectedMessage, style: .info, systemImage: "lock.fill")
        case .ready:
            EmptyView()
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: DSSpace.s4) {
        TwitchConnectionNotice(
            isConnected: false,
            reauthNeeded: true,
            expiredMessage: "Song requests stopped. Reconnect and they pick up where they left off.",
            disconnectedMessage: "Connect with Twitch to enable song requests.",
            onReconnect: {}
        )
        TwitchConnectionNotice(
            isConnected: false,
            reauthNeeded: true,
            expiredMessage: "Your Twitch sign-in expired. Reconnect to keep song requests working.",
            disconnectedMessage: "Connect with Twitch to enable song requests."
        )
        TwitchConnectionNotice(
            isConnected: false,
            reauthNeeded: false,
            expiredMessage: "Your Twitch sign-in expired. Reconnect to keep song requests working.",
            disconnectedMessage: "Connect with Twitch to enable song requests."
        )
    }
    .padding()
    .frame(width: 480)
}
