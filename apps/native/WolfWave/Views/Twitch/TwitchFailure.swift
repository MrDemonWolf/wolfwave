//
//  TwitchFailure.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-11.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

extension TwitchViewModel {

    /// Builds the errors this view model can surface.
    ///
    /// Grouped in one place so the copy stays consistent and each failure keeps
    /// the action that actually fixes it. Reconnect is offered only where a new
    /// sign-in genuinely helps.
    enum Failure {
        /// The stored grant exists but the Keychain read failed (not "no
        /// credentials"), so Try Again is offered before a new sign-in.
        static func keychainUnreadable() -> UserFacingError {
            UserFacingError(
                id: "twitch.keychainUnreadable",
                title: "Couldn't read your saved Twitch sign-in",
                cause: "macOS blocked WolfWave from reading the Keychain.",
                fix: "Try again. If it keeps happening, sign in once more.",
                severity: .error,
                actions: [.retry, .reportBug]
            )
        }

        /// Sign-in succeeded but the grant couldn't be saved, so it won't
        /// survive a relaunch.
        static func keychainWriteFailed() -> UserFacingError {
            UserFacingError(
                id: "twitch.keychainWriteFailed",
                title: "Couldn't save your Twitch sign-in",
                cause: "macOS blocked WolfWave from writing to the Keychain.",
                fix: "You'll be asked to sign in again next launch.",
                severity: .error,
                actions: [.reconnectTwitch, .reportBug],
                docsAnchor: "keychain-write-failed"
            )
        }

        /// Signing out could not remove the stored grant, so the account is
        /// still signed in. Says so plainly rather than implying it worked.
        static func credentialClearFailed() -> UserFacingError {
            UserFacingError(
                id: "twitch.credentialClearFailed",
                title: "Couldn't sign out of Twitch",
                cause: "macOS wouldn't let WolfWave remove the saved sign-in, "
                    + "so you are still signed in.",
                fix: "Try again. If it keeps failing, restart your Mac.",
                severity: .error,
                actions: [.retry, .reportBug],
                docsAnchor: "keychain-write-failed"
            )
        }

        /// The build has no `TWITCH_CLIENT_ID`; nothing the user does in-app
        /// can fix it, so the only action is the docs.
        static func missingClientID() -> UserFacingError {
            UserFacingError(
                id: "twitch.missingClientID",
                title: "WolfWave isn't set up for Twitch",
                cause: "This build has no Twitch Client ID.",
                fix: "Reinstall from the website, or set TWITCH_CLIENT_ID in Config.xcconfig.",
                severity: .error,
                actions: [.openDocs(anchor: "twitch-client-id")],
                docsAnchor: "twitch-client-id"
            )
        }

        /// The token was rejected (401) or could not be refreshed. Reconnect
        /// is the fix.
        static func signInExpired() -> UserFacingError {
            UserFacingError(
                id: "twitch.signInExpired",
                title: "Twitch sign-in expired",
                cause: "Chat commands stopped working.",
                fix: "Reconnect and WolfWave picks up where it left off.",
                severity: .warning,
                actions: [.reconnectTwitch],
                docsAnchor: "twitch-sign-in-expired"
            )
        }

        /// Join was attempted with no stored sign-in.
        static func noCredentials() -> UserFacingError {
            UserFacingError(
                id: "twitch.noCredentials",
                title: "Not signed in to Twitch",
                fix: "Connect with Twitch to get started.",
                severity: .info,
                actions: [.reconnectTwitch]
            )
        }

        /// Local validation of the typed channel failed.
        ///
        /// - Parameter reason: The specific rule that failed, shown as the cause.
        static func channelNameInvalid(_ reason: String) -> UserFacingError {
            UserFacingError(
                id: "twitch.channelNameInvalid",
                title: "That channel name won't work",
                cause: reason,
                severity: .error
            )
        }

        /// Twitch has no user by that login. The name is masked under Streamer
        /// Mode because this text can be on screen.
        static func channelNotFound(_ channel: String) -> UserFacingError {
            UserFacingError(
                id: "twitch.channelNotFound",
                title: "No Twitch channel by that name",
                cause: "Nothing on Twitch matches \(StreamerMode.mask(channel, style: .channel, isOn: StreamerMode.isEnabled)).",
                fix: "Check the spelling, then choose Join.",
                severity: .error,
                docsAnchor: "channel-not-found"
            )
        }

        /// Twitch accepted the sign-in and refused the lookup, so a reconnect
        /// is deliberately not offered.
        static func lookupRefused(status: Int) -> UserFacingError {
            UserFacingError(
                id: "twitch.lookupRefused",
                title: status == 429
                    ? "Your sign-in is fine, we're being rate limited"
                    : "Your sign-in is fine, Twitch isn't",
                cause: TwitchViewModel.notPermittedMessage(status: status),
                severity: .warning,
                actions: [.retry],
                docsAnchor: "sign-in-is-fine"
            )
        }

        /// Joining chat failed for a reason other than a timeout.
        ///
        /// - Parameter detail: The underlying error text, shown as the cause.
        static func connectionFailed(_ detail: String) -> UserFacingError {
            UserFacingError(
                id: "twitch.connectionFailed",
                title: "Couldn't connect to Twitch chat",
                cause: detail,
                fix: "Try again in a moment.",
                severity: .error,
                actions: [.retry]
            )
        }

        /// Joining chat timed out.
        static func connectionTimedOut() -> UserFacingError {
            UserFacingError(
                id: "twitch.connectionTimedOut",
                title: "Twitch didn't respond",
                cause: "The connection timed out. A firewall or VPN can cause this.",
                severity: .warning,
                actions: [.retry]
            )
        }

        /// Leaving the previous channel failed while switching channels.
        static func disconnectFailed() -> UserFacingError {
            UserFacingError(
                id: "twitch.disconnectFailed",
                title: "Couldn't switch channels cleanly",
                cause: "WolfWave couldn't leave the old channel.",
                fix: "Choose Join again.",
                severity: .warning,
                actions: [.retry]
            )
        }

        /// Signing out could not take the live Twitch connection down, so the
        /// account is still signed in and online. Try Again retries the sign-out.
        static func signOutDisconnectFailed() -> UserFacingError {
            UserFacingError(
                id: "twitch.signOutDisconnectFailed",
                title: "Couldn't sign out of Twitch",
                cause: "WolfWave couldn't disconnect from Twitch, "
                    + "so you are still signed in.",
                fix: "Try again.",
                severity: .error,
                actions: [.retry, .reportBug]
            )
        }

        /// Switching or re-linking accounts could not take the old connection
        /// down first. Try Again restarts the sign-in, which redoes the teardown.
        static func accountSwitchDisconnectFailed() -> UserFacingError {
            UserFacingError(
                id: "twitch.accountSwitchDisconnectFailed",
                title: "Couldn't switch Twitch accounts",
                cause: "WolfWave couldn't disconnect the current account first.",
                fix: "Try signing in again.",
                severity: .warning,
                actions: [.retry]
            )
        }

        /// The signed-in account's user ID couldn't be resolved, so WolfWave
        /// can't tell which account it posts as.
        static func botIdentityUnresolved() -> UserFacingError {
            UserFacingError(
                id: "twitch.botIdentityUnresolved",
                title: "Couldn't confirm which account is posting",
                fix: "Reconnect with Twitch.",
                severity: .warning,
                actions: [.reconnectTwitch]
            )
        }

        /// The app delegate had no Twitch service to connect with.
        static func serviceUnavailable() -> UserFacingError {
            UserFacingError(
                id: "twitch.serviceUnavailable",
                title: "WolfWave couldn't start its Twitch connection",
                fix: "Restart WolfWave.",
                severity: .error,
                actions: [.reportBug]
            )
        }

        /// The device code timed out before the user approved it. Retrying
        /// fetches a new code, so the fix says exactly that.
        static func deviceCodeExpired() -> UserFacingError {
            UserFacingError(
                id: "twitch.deviceCodeExpired",
                title: "That code expired",
                cause: "Twitch codes last only a few minutes.",
                fix: "Get a new code and try again.",
                severity: .warning,
                actions: [.retry]
            )
        }

        /// Any other device-flow failure.
        ///
        /// - Parameter message: Human-readable reason, shown as the cause.
        static func oauth(_ message: String) -> UserFacingError {
            UserFacingError(
                id: "twitch.oauthFailed",
                title: "Twitch sign-in didn't finish",
                cause: message,
                severity: .warning,
                actions: [.retry]
            )
        }
    }
}
