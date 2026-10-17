//
//  TwitchChannelPointsService+Helpers.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation

/// Reward creation, managed-identity checks, and the Helix lookups the
/// reward lifecycle and redemption methods share.
nonisolated extension TwitchChannelPointsService {

    // MARK: - Private Helpers

    /// Creates (or adopts a same-title) reward on Twitch, then CAS-stores it
    /// bound to these credentials.
    ///
    /// If the CAS fails but the store already holds this exact identity (a
    /// concurrent caller won with the same result), that still counts as
    /// success. Any other outcome throws `ownershipUnverified`, leaving the
    /// newly created remote reward unrecorded.
    func createAndStoreReward(
        credentials: Credentials,
        cost: Int,
        replacing expected: TwitchManagedRewardStore.Snapshot
    ) async throws -> String {
        let rewardID = try await createReward(credentials: credentials, cost: cost)
        let identity = TwitchManagedRewardStore.Identity(
            rewardID: rewardID,
            broadcasterID: credentials.broadcasterID)
        guard TwitchManagedRewardStore.store(
            identity,
            replacing: expected
        ) || TwitchManagedRewardStore.matches(identity) else {
            throw RewardError.ownershipUnverified
        }
        return rewardID
    }

    /// Gate for every reward mutation: the stored owned identity must belong to
    /// these credentials, name `rewardID`, and still be current after the await.
    ///
    /// - Throws: `RewardError.ownershipUnverified` (or a Helix error while
    ///   migrating a legacy ID).
    func requireManagedRewardIdentity(
        credentials: Credentials,
        rewardID: String
    ) async throws -> TwitchManagedRewardStore.Identity {
        guard let identity = try await managedRewardIdentity(
            credentials: credentials),
              identity.rewardID == rewardID,
              TwitchManagedRewardStore.matches(identity) else {
            throw RewardError.ownershipUnverified
        }
        return identity
    }

    /// ``requireManagedRewardIdentity(credentials:rewardID:)`` with its errors
    /// re-typed as `RedemptionResolutionError`, for the outbox worker's paths.
    func requireResolutionManagedRewardIdentity(
        credentials: Credentials,
        rewardID: String
    ) async throws {
        do {
            _ = try await requireManagedRewardIdentity(
                credentials: credentials,
                rewardID: rewardID)
        } catch let error as RewardError {
            switch error {
            case let .http(status, body):
                throw RedemptionResolutionError.http(
                    status: status,
                    body: body,
                    retryAfter: nil)
            case let .transport(underlying):
                throw RedemptionResolutionError.transport(
                    underlying.localizedDescription)
            case .malformedResponse:
                throw RedemptionResolutionError.malformedResponse
            case .ownershipUnverified:
                throw RedemptionResolutionError.ownershipUnverified
            }
        }
    }

    /// Builds a Helix `custom_rewards` URL with the common `broadcaster_id`
    /// query plus the optional `id` / `only_manageable_rewards` filters. Returns
    /// `nil` on the (practically impossible) malformed-URL case so each caller
    /// keeps its own distinct failure branch (throw / `false` / `nil`). The
    /// `/redemptions` path is deliberately not routed through this.
    func customRewardsURL(
        broadcasterID: String,
        id: String? = nil,
        onlyManageable: Bool = false
    ) -> URL? {
        var components = URLComponents(string: baseURL + "/channel_points/custom_rewards")
        var items = [URLQueryItem(name: "broadcaster_id", value: broadcasterID)]
        if let id { items.append(URLQueryItem(name: "id", value: id)) }
        if onlyManageable {
            items.append(URLQueryItem(name: "only_manageable_rewards", value: "true"))
        }
        components?.queryItems = items
        return components?.url
    }

    /// Checks whether a reward ID still exists and is manageable by this client.
    ///
    /// - Returns: `false` on an empty `data` array, a 404, or an unbuildable
    ///   URL. Other Helix errors throw as a mapped `RewardError`.
    func rewardExists(credentials: Credentials, rewardID: String) async throws -> Bool {
        guard let url = customRewardsURL(
            broadcasterID: credentials.broadcasterID, id: rewardID, onlyManageable: true
        ) else { return false }

        do {
            let json = try await helix.sendJSON(
                url: url, method: "GET",
                credentials: credentials.helix)
            let data = json?["data"] as? [[String: Any]] ?? []
            return !data.isEmpty
        } catch let HelixClient.HelixError.http(status, _) where status == 404 {
            return false
        } catch let error as HelixClient.HelixError {
            throw RewardError.from(error)
        }
    }

    /// Creates the "Request a Song" reward and returns its ID.
    ///
    /// The reward is created with `is_enabled = false`; it only becomes
    /// redeemable when reconciliation unpauses it via ``setRewardPaused``,
    /// after the outbox has proved it can persist intake.
    private func createReward(credentials: Credentials, cost: Int) async throws -> String {
        guard let url = customRewardsURL(
            broadcasterID: credentials.broadcasterID
        ) else { throw RewardError.malformedResponse }

        let body: [String: Any] = [
            "title": AppConstants.Twitch.songRequestRewardTitle,
            "cost": cost,
            "prompt": "Type a song name or paste an Apple Music / Spotify / YouTube link.",
            "is_user_input_required": true,
            "is_enabled": false
        ]

        let json: [String: Any]?
        do {
            json = try await helix.sendJSON(
                url: url, method: "POST",
                credentials: credentials.helix,
                body: body)
        } catch let HelixClient.HelixError.http(status, errorBody) where status == 400 {
            // A 400 here is almost always a duplicate-title reward left over from
            // a previous install or client-ID change. Adopt the existing managed
            // reward instead of failing and leaving the streamer with none.
            if let existing = try await findManagedRewardByTitle(
                credentials: credentials, title: AppConstants.Twitch.songRequestRewardTitle) {
                return existing
            }
            throw RewardError.http(status: status, body: errorBody)
        } catch let error as HelixClient.HelixError {
            throw RewardError.from(error)
        }
        guard let data = json?["data"] as? [[String: Any]],
            let id = data.first?["id"] as? String, !id.isEmpty
        else {
            throw RewardError.malformedResponse
        }
        return id
    }

    /// Finds an existing WolfWave-manageable reward by title, used to adopt a
    /// duplicate left over from a prior install rather than failing to create.
    private func findManagedRewardByTitle(
        credentials: Credentials, title: String
    ) async throws -> String? {
        guard let url = customRewardsURL(
            broadcasterID: credentials.broadcasterID, onlyManageable: true
        ) else { return nil }

        do {
            let json = try await helix.sendJSON(
                url: url, method: "GET",
                credentials: credentials.helix)
            let data = json?["data"] as? [[String: Any]] ?? []
            return data.first(where: { ($0["title"] as? String) == title })?["id"] as? String
        } catch let error as HelixClient.HelixError {
            throw RewardError.from(error)
        }
    }
}
