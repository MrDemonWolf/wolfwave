//
//  AppDelegate+TwitchTokenValidation.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import Foundation

// MARK: - Twitch Token Validation

/// Owns the app-lifetime Twitch token validation schedule. Every callback
/// re-checks a generation counter and the current stored credential, so a
/// result for a replaced or signed-out account is dropped instead of applied.
extension AppDelegate {

    /// Writes the re-auth flag and posts `twitchReauthNeededChanged` only when
    /// the value actually changed, so observers aren't woken on every
    /// hourly confirmation.
    @MainActor
    private func setReauthNeeded(_ needed: Bool) {
        let changed = Preferences.twitchReauthNeeded != needed
        Preferences.setTwitchReauthNeeded(needed)
        if changed {
            NotificationCenter.default.post(
                name: Notification.Name.twitchReauthNeededChanged,
                object: nil
            )
        }
    }

    /// Posts the "Twitch session expired" banner via `NotificationService`.
    ///
    /// Never requests notification authorization: this runs from the
    /// unattended boot-path token check, and prompting belongs only to the
    /// primed onboarding / settings buttons. `NotificationService` drops the
    /// banner unless authorization was already granted (`.notDetermined` is
    /// treated like `.denied`); the in-app re-auth banner covers that case.
    private func showTwitchAuthNotification() {
        Task {
            await NotificationService.shared.postTwitchReauthNeeded()
        }
    }

    /// Opens Settings on the Twitch pane after the token was rejected, so
    /// the sign-in button is in front of the user.
    private func openSettingsToTwitch() {
        navigateSettings(to: SettingsDeepLink(pane: .twitchIntegration))
    }

    /// Starts the app-lifetime Twitch validation owner. Kept async so the
    /// existing launch/onboarding call sites can retain their structured task;
    /// the cadence itself lives in `twitchBootValidationTask` and returns here.
    func validateTwitchTokenOnBoot() async {
        restartTwitchTokenValidationSchedule()
    }

    /// Restarts startup + hourly validation for the currently stored account.
    /// Credential replacement/logout notifications and app shutdown all route
    /// through this single owner, so stale network results cannot mutate the
    /// replacement account.
    ///
    /// With no stored credential it clears the re-auth flag and schedules
    /// nothing. Outcomes: valid clears the flag (adopting a refreshed token
    /// into the live service and auto-reconnecting on the first valid result
    /// for an account); invalid sets the flag, posts the system banner, and
    /// opens Settings; missing scopes and outages only log.
    func restartTwitchTokenValidationSchedule() {
        cancelTwitchBootValidation()

        twitchBootValidationGeneration &+= 1
        let generation = twitchBootValidationGeneration
        let service = twitchService
        let clientID = TwitchChatService.resolveClientID() ?? ""
        let task = Task { [weak self] in
            let credential = await Self.loadTwitchValidationCredential()
            guard !Task.isCancelled,
                  self?.twitchBootValidationGeneration == generation else { return }
            guard credential != nil else {
                self?.setReauthNeeded(false)
                self?.twitchBootValidationTask = nil
                return
            }
            await TwitchBootTokenValidationRunner.runSchedule(
                credentials: { Self.currentTwitchValidationCredential() },
                validate: { candidate in
                    await service?.validateToken(candidate) ?? .temporarilyUnavailable
                },
                refresh: { rejected in
                    try await TwitchTokenRefresher.attemptReactiveRefresh(
                        clientID: clientID,
                        expected: rejected.accessExpectation
                    )
                },
                onValid: {
                    [weak self] credential, isFirstValidForAccount, rotatedFrom in
                    await self?.handleValidatedTwitchCredential(
                        credential, rotatedFrom: rotatedFrom,
                        isFirstValidForAccount: isFirstValidForAccount,
                        generation: generation, service: service
                    )
                },
                onInvalid: { [weak self] credential in
                    guard let self,
                          await Self.loadTwitchValidationCredential() == credential,
                          !Task.isCancelled,
                          self.twitchBootValidationGeneration == generation else { return }
                    self.setReauthNeeded(true)
                    self.showTwitchAuthNotification()
                    self.openSettingsToTwitch()
                },
                onMissingScopes: { [weak self] credential, scopes in
                    guard let self,
                          await Self.loadTwitchValidationCredential() == credential,
                          !Task.isCancelled,
                          self.twitchBootValidationGeneration == generation else { return }
                    // Explicitly NOT setReauthNeeded: the session is live, chat
                    // keeps working, and that flag would also stop the hourly
                    // validator. Only the feature needing the scope is affected,
                    // and it surfaces its own banner where it is configured.
                    Log.warn(
                        "AppDelegate: Twitch token is valid but missing scopes",
                        category: .twitchAuth,
                        fields: ["scopes": scopes.joined(separator: ",")]
                    )
                },
                onTemporarilyUnavailable: { credential in
                    guard await Self.loadTwitchValidationCredential() == credential,
                          !Task.isCancelled else { return }
                    Log.warn(
                        "AppDelegate: Twitch token validation temporarily unavailable; keeping credentials",
                        category: .twitch)
                }
            )

            guard let self, self.twitchBootValidationGeneration == generation else { return }
            self.twitchBootValidationTask = nil
        }
        twitchBootValidationTask = task
    }

    private func handleValidatedTwitchCredential(
        _ credential: TwitchBootTokenValidationRunner.Credential,
        rotatedFrom: TwitchBootTokenValidationRunner.Credential?,
        isFirstValidForAccount: Bool,
        generation: UInt64,
        service: TwitchChatService?
    ) async {
        guard await Self.loadTwitchValidationCredential() == credential,
              !Task.isCancelled,
              twitchBootValidationGeneration == generation else { return }

        if let rotatedFrom, let service {
            let adopted = await service.adoptRefreshedAccessCredential(
                credential.accessExpectation,
                replacing: rotatedFrom.accessExpectation
            )
            guard await Self.loadTwitchValidationCredential() == credential,
                  !Task.isCancelled,
                  twitchBootValidationGeneration == generation else { return }
            if !adopted {
                Log.debug(
                    "AppDelegate: Rotated Twitch credential had no matching active service state",
                    category: .twitch
                )
            }
        }

        setReauthNeeded(false)
        guard await Self.loadTwitchValidationCredential() == credential,
              !Task.isCancelled,
              twitchBootValidationGeneration == generation else { return }
        if isFirstValidForAccount, service?.currentlyConnected != true {
            await autoReconnectTwitchIfPossible(credential: credential)
        }
    }

    /// Cancels any app-lifetime validation that an account change or shutdown
    /// superseded.
    func cancelTwitchBootValidation() {
        twitchBootValidationGeneration &+= 1
        twitchBootValidationTask?.cancel()
        twitchBootValidationTask = nil
    }

    /// Reads access token and account revision in one credential-store critical
    /// section so the hourly runner never constructs a cross-revision pair.
    @concurrent
    private static func loadTwitchValidationCredential() async
        -> TwitchBootTokenValidationRunner.Credential? {
        currentTwitchValidationCredential()
    }

    nonisolated private static func currentTwitchValidationCredential()
        -> TwitchBootTokenValidationRunner.Credential? {
        guard let snapshot = TwitchCredentialStore.shared
            .connectionSnapshot() else { return nil }
        return TwitchBootTokenValidationRunner.Credential(
            token: snapshot.accessToken,
            revision: snapshot.revision
        )
    }

    /// Auto-reconnects EventSub on launch when a valid token + channel name exist.
    ///
    /// Suppresses the "I'm online" chat ping that fires on explicit user-driven
    /// connects. Auto-reconnect is silent. Called only after the token has been
    /// validated against Twitch.
    func autoReconnectTwitchIfPossible(
        credential: TwitchBootTokenValidationRunner.Credential
    ) async {
        guard let service = twitchService else { return }
        guard let clientID = TwitchChatService.resolveClientID(), !clientID.isEmpty else {
            Log.debug("AppDelegate: Skipping Twitch auto-reconnect: no Client ID", category: .twitch)
            return
        }
        guard let snapshot = await TwitchCredentialStore.shared.loadConnectionSnapshot(
            matchingAccessToken: credential.token
        ),
              snapshot.revision == credential.revision,
              let channel = snapshot.channelID,
              !channel.isEmpty else {
            Log.debug("AppDelegate: Skipping Twitch auto-reconnect: no stored channel name", category: .twitch)
            return
        }

        Log.info("AppDelegate: Auto-reconnecting Twitch to channel \(channel)", category: .twitch)
        guard await TwitchCredentialStore.shared.loadConnectionSnapshot() == snapshot,
              !Task.isCancelled else { return }
        await service.setShouldSendConnectionMessageOnSubscribe(false)
        guard await TwitchCredentialStore.shared.loadConnectionSnapshot() == snapshot,
              !Task.isCancelled else { return }
        do {
            try await service.connectToChannel(
                channelName: channel,
                token: credential.token,
                clientID: clientID,
                expectedCredentialRevision: credential.revision
            )
        } catch {
            Log.error(
                "AppDelegate: Twitch auto-reconnect failed - \(error.localizedDescription)",
                category: .twitch
            )
        }
    }
}
