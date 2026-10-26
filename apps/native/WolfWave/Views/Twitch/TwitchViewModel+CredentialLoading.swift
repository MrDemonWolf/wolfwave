//
//  TwitchViewModel+CredentialLoading.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-26.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

extension TwitchViewModel {
    /// Loads saved credentials from macOS Keychain.
    ///
    /// Also loads the reauth needed flag and sets up notification observers for auth state changes.
    /// The credential read happens only once per instance (so a second surface can't overwrite a
    /// live channel draft); a Keychain read error keeps the current UI values, surfaces
    /// `Failure.keychainUnreadable()`, and leaves the load eligible to run again.
    func loadSavedCredentials() async {
        guard !hasLoadedSavedCredentials, !isLoadingSavedCredentials else { return }
        isLoadingSavedCredentials = true
        defer { isLoadingSavedCredentials = false }
        let generation = oauthGeneration
        do {
            let grant = try await Self.readSavedCredentialGrant()
            guard !Task.isCancelled, oauthGeneration == generation else { return }
            botUsername = grant.username ?? ""
            oauthToken = grant.accessToken ?? ""
            channelID = grant.channelID ?? ""
            credentialsSaved = grant.accessToken?.isEmpty == false
            hasLoadedSavedCredentials = true
        } catch {
            guard !Task.isCancelled, oauthGeneration == generation else { return }
            // A Keychain outage is not proof that the account disappeared. Keep
            // the last coherent UI snapshot and let the user retry the read.
            Log.error(
                "TwitchViewModel: Could not read saved Twitch credentials - "
                    + error.localizedDescription,
                category: .twitch
            )
            if connectionError == nil {
                connectionError = Failure.keychainUnreadable()
            }
        }

        // Load reauth needed flag from UserDefaults
        reauthNeeded = Preferences.twitchReauthNeeded

        // Idempotent: only register observers once across repeated calls.
        // Notifications already arrive on `.main` (queue: .main), so we can mutate
        // @MainActor state directly via `MainActor.assumeIsolated`, no Task hop.
        if reauthObserver == nil {
            reauthObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name.twitchReauthNeededChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reauthNeeded = Preferences.twitchReauthNeeded
                }
            }
        }

        if connectionObserver == nil {
            connectionObserver = NotificationCenter.default.addObserver(
                forName: TwitchChatService.connectionStateChanged,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let isConnected = note.isConnectedFlag
                let errorMessage = note.errorMessage
                MainActor.assumeIsolated {
                    self?.handleTwitchConnectionState(
                        isConnected: isConnected, errorMessage: errorMessage)
                }
            }
        }
    }

    @concurrent
    private static func readSavedCredentialGrant() async throws -> KeychainService.TwitchCredentialGrant {
        try KeychainService.loadTwitchCredentialGrantChecked()
    }
}
